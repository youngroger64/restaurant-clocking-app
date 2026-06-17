"""
Payroll issue engine for the restaurant clocking app.

Manager rules:
- Payroll Blockers are only clock-record problems that stop safe Sage export.
- Manager Review items are useful operational checks but do not block export.
- Staff who worked but were not rostered are review/approve items, not blockers.
- Rostered-but-no-activity is a review item, not a blocker.
- Future days in the current week do not block payroll while the week is still in progress.
"""
from __future__ import annotations

import csv
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import List, Optional, Tuple

from django.contrib import messages
from django.http import HttpResponse
from django.shortcuts import redirect
from django.utils import timezone

from core.models import ClockEvent, Employee, RosterShift
from core.compliance import calculate_employee_day, get_week_rows

CLOCK_TYPES = {"IN", "BREAK_START", "BREAK_END", "OUT"}
WORK_TYPES = {"IN", "OUT"}


def parse_week_start(request):
    raw = request.GET.get("week_start") or request.POST.get("week_start")
    if raw:
        return datetime.strptime(raw, "%Y-%m-%d").date()
    today = current_day()
    return today - timedelta(days=today.weekday())


def current_day():
    try:
        from core.compliance import current_operational_date
        return current_operational_date()
    except Exception:
        return timezone.localdate()


def _day_range(week_start):
    return [week_start + timedelta(days=i) for i in range(7)]


def _local_dt(day, clock_time):
    return timezone.make_aware(datetime.combine(day, clock_time))


def _event_minute(event):
    return timezone.localtime(event.timestamp).replace(second=0, microsecond=0)


def _events_for_day(employee, day):
    """Return clock events for the day with exact duplicate minute-level events collapsed."""
    events = (
        ClockEvent.objects
        .filter(employee=employee, timestamp__date=day)
        .order_by("timestamp", "id")
    )
    unique = []
    seen = set()
    for event in events:
        if event.clock_type not in CLOCK_TYPES:
            continue
        key = (event.clock_type, _event_minute(event))
        if key in seen:
            continue
        seen.add(key)
        unique.append(event)
    return unique


def _roster_shift(employee, day):
    shifts = list(
        RosterShift.objects
        .filter(employee=employee, shift_date=day)
        .order_by("start_time", "end_time", "id")
    )
    if not shifts:
        return None
    first = shifts[0]
    last = shifts[-1]
    start_dt = _local_dt(day, first.start_time)
    end_dt = _local_dt(day, last.end_time)
    if end_dt <= start_dt:
        end_dt += timedelta(days=1)
    return {
        "first": first,
        "start_dt": start_dt,
        "end_dt": end_dt,
        "start_time": first.start_time,
        "end_time": last.end_time,
        "label": f"{first.start_time.strftime('%H:%M')} - {last.end_time.strftime('%H:%M')}",
        "start_label": first.start_time.strftime("%H:%M"),
        "end_label": last.end_time.strftime("%H:%M"),
    }


def _employees_for_week(week_start):
    week_end = week_start + timedelta(days=6)
    ids = set(Employee.objects.filter(active=True).values_list("id", flat=True))
    ids.update(
        RosterShift.objects
        .filter(shift_date__gte=week_start, shift_date__lte=week_end)
        .values_list("employee_id", flat=True)
    )
    ids.update(
        ClockEvent.objects
        .filter(timestamp__date__gte=week_start, timestamp__date__lte=week_end)
        .values_list("employee_id", flat=True)
    )
    return Employee.objects.filter(id__in=ids).order_by("name", "employee_number")


def _first_in_last_out(events):
    ins = [event for event in events if event.clock_type == "IN"]
    outs = [event for event in events if event.clock_type == "OUT"]
    return (ins[0] if ins else None), (outs[-1] if outs else None)


def _work_sequence(events):
    return [event.clock_type for event in events if event.clock_type in WORK_TYPES]


def _break_sequence_problem(events, finished_day):
    balance = 0
    for event in events:
        if event.clock_type == "BREAK_START":
            balance += 1
        elif event.clock_type == "BREAK_END":
            if balance <= 0:
                return "Break ended without a break start"
            balance -= 1
    if balance and finished_day:
        return "Break was not ended"
    return None


def _blocker_for_events(events, day):
    """Return only issues that block payroll export."""
    if not events:
        return None

    finished_day = day < current_day()
    work = _work_sequence(events)

    if work:
        if "IN" not in work:
            return "Missing clock-in"
        if "OUT" not in work:
            # Do not block a live current shift before the day has finished.
            return "Missing clock-out" if finished_day else None
        if work[0] != "IN" or work[-1] != "OUT":
            return "Check clock event order"
        if work.count("IN") != work.count("OUT"):
            return "Check clock event sequence"
        if work.count("IN") > 1 or work.count("OUT") > 1:
            return "Multiple clock-ins/outs on same day"

    return _break_sequence_problem(events, finished_day)


def _action(mode, label):
    return {"mode": mode, "label": label}


def _blocker_actions(issue, shift):
    actions = []
    issue_l = (issue or "").lower()

    if "missing clock-in" in issue_l:
        if shift:
            actions.append(_action("clock_in_roster_start", f"Use roster start ({shift['start_label']})"))
        actions.append(_action("enter_actual_start", "Enter actual start"))

    elif "missing clock-out" in issue_l:
        if shift:
            actions.append(_action("clock_out_roster_finish", f"Use roster finish ({shift['end_label']})"))
        actions.append(_action("enter_actual_finish", "Enter actual finish"))

    elif "clock" in issue_l or "sequence" in issue_l or "order" in issue_l or "break" in issue_l:
        if shift:
            actions.append(_action("pay_roster_shift", f"Use rostered shift ({shift['label']})"))
        actions.append(_action("enter_actual_shift", "Enter actual times"))
        actions.append(_action("advanced", "Review events"))

    if not actions:
        actions.append(_action("advanced", "Review"))
    return actions


def _review_actions(review_type, shift, first_in, last_out):
    if review_type == "unrostered_work":
        return [_action("approve_unrostered_shift", "Approve worked hours"), _action("advanced", "Review/Edit")]
    if review_type == "rostered_no_activity":
        return [_action("advanced", "Add worked shift / mark absent")]
    if review_type == "long_shift":
        return [_action("advanced", "Review/Edit")]
    return [_action("advanced", "Review/Edit")]


def _row(employee, day, day_row, issue, actions, row_type="blocker", review_type=""):
    return {
        "date": day,
        "employee_number": employee.employee_number,
        "employee": employee.name,
        "roster": day_row.get("roster") or "Not rostered",
        "status": day_row.get("status") or "Check",
        "worked_hours": day_row.get("worked_hours") or 0,
        "break_minutes": day_row.get("break_minutes") or 0,
        "problem": issue,
        "quick_actions": actions,
        "row_type": row_type,
        "review_type": review_type,
    }


def get_payroll_blocker_rows(week_start):
    rows = []
    today = current_day()
    for employee in _employees_for_week(week_start):
        for day in _day_range(week_start):
            # Future days should not make payroll look broken during the current week.
            if day > today:
                continue
            events = _events_for_day(employee, day)
            issue = _blocker_for_events(events, day)
            if not issue:
                continue
            shift = _roster_shift(employee, day)
            day_row = calculate_employee_day(employee, day, include_live=False)
            rows.append(_row(employee, day, day_row, issue, _blocker_actions(issue, shift), "blocker"))
    return rows


def get_manager_review_rows(week_start):
    rows = []
    today = current_day()
    for employee in _employees_for_week(week_start):
        for day in _day_range(week_start):
            if day > today:
                continue
            events = _events_for_day(employee, day)
            shift = _roster_shift(employee, day)
            first_in, last_out = _first_in_last_out(events)
            day_row = calculate_employee_day(employee, day, include_live=False)
            issue = None
            review_type = ""

            # Not rostered but worked: review/approve, not a payroll blocker.
            if events and not shift and not _blocker_for_events(events, day):
                issue = "Worked but not rostered"
                review_type = "unrostered_work"

            # Rostered and no clock records: attendance review, not a Sage blocker.
            elif shift and not events and day < today:
                issue = "Rostered but no clock records"
                review_type = "rostered_no_activity"

            elif int(day_row.get("worked_minutes") or 0) > 14 * 60:
                issue = "Unusually long shift"
                review_type = "long_shift"

            if issue:
                rows.append(_row(employee, day, day_row, issue, _review_actions(review_type, shift, first_in, last_out), "review", review_type))
    return rows


# Backwards-compatible name: payroll-facing counts use blockers only.
def get_payroll_issue_rows(week_start):
    return get_payroll_blocker_rows(week_start)


def payroll_is_ready(week_start):
    rows = get_payroll_blocker_rows(week_start)
    return len(rows) == 0, rows


def _hours(value):
    return round(float(value or 0), 2)


def _minutes_to_decimal_string(minutes):
    return f"{round((int(minutes or 0)) / 60, 2):.2f}"


def get_weekly_summary_rows(week_start, standard_hours=39):
    rows = get_week_rows(week_start, standard_hours)
    blockers = get_payroll_blocker_rows(week_start)
    blocker_by_emp = {}
    for blocker in blockers:
        blocker_by_emp.setdefault(str(blocker["employee_number"]), []).append(f"{blocker['date'].strftime('%a')}: {blocker['problem']}")

    for row in rows:
        row["rostered_hours"] = _hours(row.get("rostered_hours"))
        row["worked_hours"] = _hours(row.get("worked_hours"))
        row["break_hours"] = _hours(row.get("break_hours"))
        row["paid_hours"] = _hours(row.get("paid_hours"))
        row["normal_hours"] = _hours(row.get("normal_hours"))
        row["sunday_hours"] = _hours(row.get("sunday_hours"))
        row["overtime_hours"] = _hours(row.get("overtime_hours"))
        row["difference"] = _hours(row.get("difference"))
        row["normal_export"] = _minutes_to_decimal_string(row.get("normal_minutes", row["normal_hours"] * 60))
        row["sunday_export"] = _minutes_to_decimal_string(row.get("sunday_minutes", row["sunday_hours"] * 60))
        row["overtime_export"] = _minutes_to_decimal_string(row.get("overtime_minutes", row["overtime_hours"] * 60))

        problems = blocker_by_emp.get(str(row.get("employee_number")), [])
        if problems:
            row["review_status"] = "Fix payroll"
            row["review_reason"] = "; ".join(problems[:3])
            row["status_css"] = "warn"
        elif not row.get("review_status"):
            row["review_status"] = "OK"
            row["review_reason"] = ""
            row["status_css"] = "ok"
    return rows


def get_export_rows(week_start, standard_hours=39):
    return [
        row for row in get_weekly_summary_rows(week_start, standard_hours)
        if int(row.get("paid_minutes") or 0) > 0
    ]


def get_weekly_totals(summary_rows):
    return {
        "rostered": round(sum(float(r.get("rostered_hours") or 0) for r in summary_rows), 2),
        "paid": round(sum(float(r.get("paid_hours") or 0) for r in summary_rows), 2),
        "normal": round(sum(float(r.get("normal_hours") or 0) for r in summary_rows), 2),
        "sunday": round(sum(float(r.get("sunday_hours") or 0) for r in summary_rows), 2),
        "overtime": round(sum(float(r.get("overtime_hours") or 0) for r in summary_rows), 2),
    }


def build_sage_csv_response(week_start, standard_hours=39, period_number="1"):
    response = HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = 'attachment; filename="sage_payroll_export.csv"'
    writer = csv.writer(response)
    for row in get_export_rows(week_start, standard_hours):
        writer.writerow([
            period_number,
            row["employee_number"],
            "0000",
            row["normal_export"],
            row["sunday_export"],
            row["overtime_export"],
        ])
    return response


def _delete_day_events(employee, day):
    ClockEvent.objects.filter(employee=employee, timestamp__date=day).delete()


def _create_event(employee, clock_type, when, note):
    ClockEvent.objects.create(employee=employee, clock_type=clock_type, timestamp=when, method="MANAGER", notes=note)


def _create_clean_shift_events(employee, start_dt, end_dt, note):
    if end_dt <= start_dt:
        end_dt += timedelta(days=1)
    _create_event(employee, "IN", start_dt, f"Manager fix: {note} start")
    _create_event(employee, "OUT", end_dt, f"Manager fix: {note} finish")


def _parse_post_day(request):
    return datetime.strptime(request.POST.get("event_date"), "%Y-%m-%d").date()


def _parse_post_time(request, name):
    return datetime.strptime(request.POST.get(name), "%H:%M").time()


def apply_quick_fix(request):
    """Apply one manager quick fix from the Payroll Issues page."""
    mode = request.POST.get("mode")
    week_start = request.POST.get("week_start") or ""
    employee_number = request.POST.get("employee_number")

    try:
        employee = Employee.objects.get(employee_number=employee_number)
        day = _parse_post_day(request)
        shift = _roster_shift(employee, day)
        events = _events_for_day(employee, day)
        first_in, last_out = _first_in_last_out(events)

        if mode == "clock_in_roster_start":
            if not shift:
                raise ValueError("No roster start time found.")
            _create_event(employee, "IN", shift["start_dt"], "used roster start")
            messages.success(request, f"{employee.name}: clock-in added at {shift['start_label']}.")

        elif mode == "clock_out_roster_finish":
            if not shift:
                raise ValueError("No roster finish time found.")
            _create_event(employee, "OUT", shift["end_dt"], "used roster finish")
            messages.success(request, f"{employee.name}: clock-out added at {shift['end_label']}.")

        elif mode == "pay_roster_shift":
            if not shift:
                raise ValueError("No rostered shift found.")
            _delete_day_events(employee, day)
            _create_clean_shift_events(employee, shift["start_dt"], shift["end_dt"], "used rostered shift")
            messages.success(request, f"{employee.name}: rostered shift {shift['label']} used for payroll.")

        elif mode == "enter_actual_start":
            actual = _local_dt(day, _parse_post_time(request, "actual_time"))
            _create_event(employee, "IN", actual, "entered actual start")
            messages.success(request, f"{employee.name}: actual start added at {actual.strftime('%H:%M')}.")

        elif mode == "enter_actual_finish":
            actual = _local_dt(day, _parse_post_time(request, "actual_time"))
            _create_event(employee, "OUT", actual, "entered actual finish")
            messages.success(request, f"{employee.name}: actual finish added at {actual.strftime('%H:%M')}.")

        elif mode == "enter_actual_shift":
            start_dt = _local_dt(day, _parse_post_time(request, "start_time"))
            end_dt = _local_dt(day, _parse_post_time(request, "finish_time"))
            _delete_day_events(employee, day)
            _create_clean_shift_events(employee, start_dt, end_dt, "entered actual shift")
            messages.success(request, f"{employee.name}: actual shift times saved.")

        elif mode == "approve_unrostered_shift":
            if not first_in or not last_out:
                raise ValueError("Cannot approve: start and finish clock times are not complete.")
            if not shift:
                start_local = timezone.localtime(first_in.timestamp)
                end_local = timezone.localtime(last_out.timestamp)
                RosterShift.objects.create(
                    employee=employee,
                    shift_date=day,
                    start_time=start_local.time().replace(second=0, microsecond=0),
                    end_time=end_local.time().replace(second=0, microsecond=0),
                    break_minutes=0,
                )
            messages.success(request, f"{employee.name}: unrostered worked hours approved for payroll review.")

        else:
            messages.info(request, "Open Review/Edit for this item.")

    except Exception as exc:
        messages.error(request, f"Could not apply fix: {exc}")

    return redirect(f"/manager/payroll-problems/?week_start={week_start}")
