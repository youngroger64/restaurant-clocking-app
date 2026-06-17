#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-$PWD}"
cd "$APP_DIR"

STAMP=$(date +%Y%m%d_%H%M%S)
BACKUP="backups_cleanup_39_$STAMP"
mkdir -p "$BACKUP"
cp -a core templates "$BACKUP"/

cat > core/compliance.py <<'PY'
from datetime import datetime, time, timedelta

from django.utils import timezone

from .models import Employee, ClockEvent, RosterShift

OPERATIONAL_DAY_START_HOUR = 5
APPROVED_UNROSTERED_TOKEN = "APPROVED_UNROSTERED"


def local_now():
    return timezone.localtime(timezone.now())


def current_service_date():
    now = local_now()
    if now.time() < time(OPERATIONAL_DAY_START_HOUR, 0):
        return now.date() - timedelta(days=1)
    return now.date()


def service_window(service_date):
    start_naive = datetime.combine(service_date, time(OPERATIONAL_DAY_START_HOUR, 0))
    end_naive = start_naive + timedelta(days=1)
    return timezone.make_aware(start_naive), timezone.make_aware(end_naive)


def event_service_date(event):
    local_ts = timezone.localtime(event.timestamp)
    if local_ts.time() < time(OPERATIONAL_DAY_START_HOUR, 0):
        return local_ts.date() - timedelta(days=1)
    return local_ts.date()


def format_minutes(minutes):
    minutes = int(minutes or 0)
    if minutes < 60:
        return f"{minutes} mins"
    hours = minutes // 60
    mins = minutes % 60
    return f"{hours}h" if mins == 0 else f"{hours}h {mins}m"


def hours(minutes):
    return round((minutes or 0) / 60, 2)


def get_roster_shifts(employee, service_date):
    return list(RosterShift.objects.filter(employee=employee, shift_date=service_date).order_by("start_time"))


def get_roster_info(employee, service_date):
    shifts = get_roster_shifts(employee, service_date)
    rostered = bool(shifts)
    parts = []
    planned_start = None
    planned_end = None
    rostered_minutes = 0
    roster_break_minutes = 0

    for shift in shifts:
        parts.append(f"{shift.start_time.strftime('%H:%M')} - {shift.end_time.strftime('%H:%M')}")
        planned_start = shift.start_time if planned_start is None or shift.start_time < planned_start else planned_start
        planned_end = shift.end_time if planned_end is None or shift.end_time > planned_end else planned_end

        start_dt = datetime.combine(shift.shift_date, shift.start_time)
        end_dt = datetime.combine(shift.shift_date, shift.end_time)
        if end_dt <= start_dt:
            end_dt += timedelta(days=1)
        shift_minutes = int((end_dt - start_dt).total_seconds() // 60)
        roster_break_minutes += int(shift.break_minutes or 0)
        rostered_minutes += max(0, shift_minutes - int(shift.break_minutes or 0))

    return {
        "rostered": rostered,
        "roster_text": ", ".join(parts) if parts else "Not rostered",
        "planned_start": planned_start,
        "planned_end": planned_end,
        "rostered_minutes": max(0, rostered_minutes),
        "roster_break_minutes": max(0, roster_break_minutes),
        "shifts": shifts,
    }


def roster_start_end_datetimes(employee, service_date):
    shifts = get_roster_shifts(employee, service_date)
    if not shifts:
        return None, None, 0
    start_shift = min(shifts, key=lambda s: s.start_time)
    end_shift = max(shifts, key=lambda s: s.end_time)
    start_dt = timezone.make_aware(datetime.combine(service_date, start_shift.start_time))
    end_dt = timezone.make_aware(datetime.combine(service_date, end_shift.end_time))
    if end_dt <= start_dt:
        end_dt += timedelta(days=1)
    break_minutes = sum(int(s.break_minutes or 0) for s in shifts)
    return start_dt, end_dt, break_minutes


def get_service_events(employee, service_date):
    start_dt, end_dt = service_window(service_date)
    return list(ClockEvent.objects.filter(employee=employee, timestamp__gte=start_dt, timestamp__lt=end_dt).order_by("timestamp", "id"))


def is_unrostered_approved(events):
    return any(APPROVED_UNROSTERED_TOKEN in (e.notes or "") for e in events)


def calculate_employee_day(employee, service_date, include_live=True):
    events = get_service_events(employee, service_date)
    roster = get_roster_info(employee, service_date)
    latest_event = events[-1] if events else None

    first_in = None
    last_out = None
    worked_minutes = 0
    break_minutes = 0
    work_start = None
    break_start = None
    invalid_sequence = False

    for event in events:
        if event.clock_type == "IN":
            if first_in is None:
                first_in = event.timestamp
            if work_start is not None or break_start is not None:
                invalid_sequence = True
            work_start = event.timestamp
            break_start = None

        elif event.clock_type == "BREAK_START":
            if work_start is None:
                invalid_sequence = True
            else:
                worked_minutes += max(0, int((event.timestamp - work_start).total_seconds() // 60))
                work_start = None
            if break_start is not None:
                invalid_sequence = True
            break_start = event.timestamp

        elif event.clock_type == "BREAK_END":
            if break_start is None:
                invalid_sequence = True
            else:
                break_minutes += max(0, int((event.timestamp - break_start).total_seconds() // 60))
            break_start = None
            work_start = event.timestamp

        elif event.clock_type == "OUT":
            last_out = event.timestamp
            if work_start is not None:
                worked_minutes += max(0, int((event.timestamp - work_start).total_seconds() // 60))
                work_start = None
            elif break_start is not None:
                break_minutes += max(0, int((event.timestamp - break_start).total_seconds() // 60))
                break_start = None
            else:
                invalid_sequence = True

    now = timezone.now()
    open_work = work_start is not None
    open_break = break_start is not None
    is_current_service_day = service_date == current_service_date()

    if include_live and is_current_service_day:
        if open_work:
            worked_minutes += max(0, int((now - work_start).total_seconds() // 60))
        elif open_break:
            break_minutes += max(0, int((now - break_start).total_seconds() // 60))

    status = "No activity"
    if latest_event:
        status = {
            "IN": "Working now",
            "BREAK_START": "On break",
            "BREAK_END": "Working now",
            "OUT": "Finished",
        }.get(latest_event.clock_type, "Activity")

    service_day_ended = service_date < current_service_date()
    missing_clock_out = bool(service_day_ended and latest_event and latest_event.clock_type != "OUT")
    no_clock_records = bool(service_day_ended and roster["rostered"] and not events)
    unrostered_shift = bool(events and not roster["rostered"] and not is_unrostered_approved(events))

    payroll_issues = []
    if no_clock_records:
        payroll_issues.append("No clock records")
    if invalid_sequence:
        payroll_issues.append("Check clock events")
    if missing_clock_out:
        payroll_issues.append("Missing clock-out")
    if unrostered_shift:
        payroll_issues.append("Unrostered shift")
    if worked_minutes > 12 * 60:
        payroll_issues.append("Long shift")

    operational_warnings = []
    if latest_event and latest_event.clock_type != "OUT":
        # Irish break warning is operational/compliance, not a payroll blocker.
        if worked_minutes > 270 and break_minutes < 15:
            operational_warnings.append("Break due")
        if worked_minutes > 360 and break_minutes < 30:
            operational_warnings.append("Break due")

    if first_in and roster["planned_start"]:
        planned_dt = timezone.make_aware(datetime.combine(service_date, roster["planned_start"]))
        late = int((first_in - planned_dt).total_seconds() // 60)
        if late > 10:
            operational_warnings.append(f"Late by {late} mins")

    issue_text = "; ".join(payroll_issues) if payroll_issues else "OK"

    return {
        "employee_number": employee.employee_number,
        "employee": employee.name,
        "employee_obj": employee,
        "date": service_date,
        "events": events,
        "roster": roster["roster_text"],
        "rostered": roster["rostered"],
        "rostered_minutes": roster["rostered_minutes"],
        "roster_break_minutes": roster["roster_break_minutes"],
        "first_in": timezone.localtime(first_in).strftime("%H:%M") if first_in else "-",
        "last_out": timezone.localtime(last_out).strftime("%H:%M") if last_out else "-",
        "status": status,
        "worked_minutes": worked_minutes,
        "break_minutes": break_minutes,
        "paid_minutes": worked_minutes,
        "worked_hours": hours(worked_minutes),
        "break_hours": hours(break_minutes),
        "paid_hours": hours(worked_minutes),
        "issue": issue_text,
        "payroll_issues": payroll_issues,
        "payroll_issue": issue_text,
        "has_payroll_issue": bool(payroll_issues),
        "operational_warnings": operational_warnings,
        "operational_warning": "; ".join(sorted(set(operational_warnings))) if operational_warnings else "OK",
        "is_working": latest_event is not None and latest_event.clock_type in ["IN", "BREAK_END"],
        "is_on_break": latest_event is not None and latest_event.clock_type == "BREAK_START",
        "is_clocked_out": latest_event is not None and latest_event.clock_type == "OUT",
        "has_activity": bool(events),
        "missing_clock_out": missing_clock_out,
        "invalid_sequence": invalid_sequence,
        "no_clock_records": no_clock_records,
        "unrostered_shift": unrostered_shift,
        "approved_unrostered": is_unrostered_approved(events),
    }


def get_day_rows(service_date):
    rostered_ids = set(RosterShift.objects.filter(shift_date=service_date).values_list("employee_id", flat=True))
    start_dt, end_dt = service_window(service_date)
    event_ids = set(ClockEvent.objects.filter(timestamp__gte=start_dt, timestamp__lt=end_dt).values_list("employee_id", flat=True))
    employees = Employee.objects.filter(active=True, id__in=(rostered_ids | event_ids)).order_by("name")
    return [calculate_employee_day(employee, service_date, include_live=True) for employee in employees]


def get_open_staff_rows():
    rows = []
    for employee in Employee.objects.filter(active=True).order_by("name"):
        latest = ClockEvent.objects.filter(employee=employee).order_by("-timestamp", "-id").first()
        if latest and latest.clock_type != "OUT":
            service_date = event_service_date(latest)
            rows.append(calculate_employee_day(employee, service_date, include_live=True))
    return rows


def payroll_issue_rows(week_start):
    rows = []
    for employee in Employee.objects.filter(active=True).order_by("name"):
        for i in range(7):
            day = week_start + timedelta(days=i)
            row = calculate_employee_day(employee, day, include_live=False)
            if row["has_payroll_issue"]:
                rows.append(row)
    return rows


def calculate_employee_week(employee, week_start, standard_hours=39):
    rostered_minutes = worked_minutes = break_minutes = paid_minutes = sunday_minutes = 0
    issues = []
    for i in range(7):
        day = week_start + timedelta(days=i)
        d = calculate_employee_day(employee, day, include_live=False)
        rostered_minutes += d["rostered_minutes"]
        worked_minutes += d["worked_minutes"]
        break_minutes += d["break_minutes"]
        paid_minutes += d["paid_minutes"]
        if day.weekday() == 6:
            sunday_minutes += d["paid_minutes"]
        if d["has_payroll_issue"]:
            issues.append(f"{day}: {d['payroll_issue']}")

    standard_minutes = int(float(standard_hours) * 60)
    overtime_minutes = max(0, paid_minutes - standard_minutes)
    normal_minutes = max(0, paid_minutes - overtime_minutes - sunday_minutes)
    difference_minutes = paid_minutes - rostered_minutes

    if issues:
        status = "; ".join(issues)
    elif abs(difference_minutes) > 240:
        status = "Review"
    elif abs(difference_minutes) > 60:
        status = "Check"
    else:
        status = "OK"

    return {
        "employee": employee.name,
        "employee_number": employee.employee_number,
        "rostered_hours": hours(rostered_minutes),
        "worked_hours": hours(worked_minutes),
        "break_hours": hours(break_minutes),
        "paid_hours": hours(paid_minutes),
        "normal_hours": hours(normal_minutes),
        "sunday_hours": hours(sunday_minutes),
        "overtime_hours": hours(overtime_minutes),
        "difference": hours(difference_minutes),
        "warning": status,
        "paid_minutes": paid_minutes,
        "normal_minutes": normal_minutes,
        "sunday_minutes": sunday_minutes,
        "overtime_minutes": overtime_minutes,
    }


def get_week_rows(week_start, standard_hours=39):
    return [calculate_employee_week(e, week_start, standard_hours) for e in Employee.objects.filter(active=True).order_by("name")]


def replace_day_with_clean_shift(employee, service_date, start_dt, end_dt, break_minutes=0, note="Manager payroll correction"):
    start_window, end_window = service_window(service_date)
    ClockEvent.objects.filter(employee=employee, timestamp__gte=start_window, timestamp__lt=end_window).delete()
    ClockEvent.objects.create(employee=employee, clock_type="IN", timestamp=start_dt, method="MANAGER", notes=note)
    if break_minutes and break_minutes > 0 and (end_dt - start_dt).total_seconds() > break_minutes * 60:
        midpoint = start_dt + ((end_dt - start_dt) / 2)
        break_start = midpoint - timedelta(minutes=break_minutes // 2)
        break_end = break_start + timedelta(minutes=break_minutes)
        if break_start > start_dt and break_end < end_dt:
            ClockEvent.objects.create(employee=employee, clock_type="BREAK_START", timestamp=break_start, method="MANAGER", notes=note)
            ClockEvent.objects.create(employee=employee, clock_type="BREAK_END", timestamp=break_end, method="MANAGER", notes=note)
    ClockEvent.objects.create(employee=employee, clock_type="OUT", timestamp=end_dt, method="MANAGER", notes=note)
PY

cat > core/views.py <<'PY'
import csv
from datetime import datetime, timedelta

from django.contrib.auth.decorators import login_required
from django.contrib.auth.views import LoginView
from django.http import HttpResponse, HttpResponseRedirect
from django.shortcuts import get_object_or_404, redirect, render
from django.urls import reverse_lazy
from django.utils import timezone

from .models import ClockEvent, Employee, RosterShift
from .compliance import (
    APPROVED_UNROSTERED_TOKEN,
    calculate_employee_day,
    current_service_date,
    event_service_date,
    get_day_rows,
    get_open_staff_rows,
    get_roster_info,
    get_week_rows,
    payroll_issue_rows,
    replace_day_with_clean_shift,
    roster_start_end_datetimes,
    service_window,
)


class ManagerLoginView(LoginView):
    template_name = "manager_login.html"
    redirect_authenticated_user = True

    def get_success_url(self):
        return reverse_lazy("manager_today_dashboard")


def _parse_week_start(request):
    raw = request.GET.get("week_start") or request.POST.get("week_start")
    if raw:
        return datetime.strptime(raw, "%Y-%m-%d").date()
    today = current_service_date()
    return today - timedelta(days=today.weekday())


def _aware(service_date, hhmm):
    dt = datetime.strptime(f"{service_date} {hhmm}", "%Y-%m-%d %H:%M")
    return timezone.make_aware(dt)


def _redirect_payroll(week_start):
    return HttpResponseRedirect(f"/manager/payroll-problems/?week_start={week_start:%Y-%m-%d}")


def _employee_clock_state(employee):
    latest = ClockEvent.objects.filter(employee=employee).order_by("-timestamp", "-id").first()
    service_date = event_service_date(latest) if latest else current_service_date()
    day = calculate_employee_day(employee, service_date, include_live=True)
    current_state = "OUT"
    valid_actions = ["IN"]
    if latest and latest.clock_type in ["IN", "BREAK_END"]:
        current_state = "WORKING"
        valid_actions = ["BREAK_START", "OUT"]
    elif latest and latest.clock_type == "BREAK_START":
        current_state = "ON_BREAK"
        valid_actions = ["BREAK_END", "OUT"]
    status_label = {
        "OUT": "Ready to clock in",
        "WORKING": "Clocked in",
        "ON_BREAK": "On break",
    }[current_state]
    return {
        "current_state": current_state,
        "valid_actions": valid_actions,
        "status_label": status_label,
        "clocked_in_time": next((e.timestamp for e in day["events"] if e.clock_type == "IN"), None),
        "break_started_time": latest.timestamp if latest and latest.clock_type == "BREAK_START" else None,
        "worked_hours": day["worked_hours"],
        "break_minutes": day["break_minutes"],
    }


def smart_clock_page(request):
    message = ""
    employee_id = request.session.get("clock_employee_id")
    employee = Employee.objects.filter(id=employee_id, active=True).first() if employee_id else None

    if request.method == "POST" and request.POST.get("reset_clock_session") == "yes":
        request.session.pop("clock_employee_id", None)
        return redirect("clock")

    if request.method == "POST" and not employee:
        emp_no = (request.POST.get("employee_number") or "").strip()
        pin = (request.POST.get("pin") or "").strip()
        employee = Employee.objects.filter(employee_number=emp_no, pin=pin, active=True).first()
        if employee:
            request.session["clock_employee_id"] = employee.id
            message = f"Welcome {employee.name}."
        else:
            message = "Employee number or PIN not recognised."

    elif request.method == "POST" and employee:
        action = request.POST.get("action")
        state = _employee_clock_state(employee)
        if action not in state["valid_actions"]:
            message = "That clock action is not available right now."
        else:
            if action == "OUT" and state["current_state"] == "ON_BREAK":
                if request.POST.get("confirm_break_clockout") != "yes":
                    message = "Tick the confirmation box before clocking out from break."
                else:
                    ClockEvent.objects.create(employee=employee, clock_type="BREAK_END", method="QR")
                    ClockEvent.objects.create(employee=employee, clock_type="OUT", method="QR")
                    message = "Break ended and clocked out."
            else:
                ClockEvent.objects.create(employee=employee, clock_type=action, method="QR")
                message = {
                    "IN": "Clocked in.",
                    "BREAK_START": "Break started.",
                    "BREAK_END": "Break ended.",
                    "OUT": "Clocked out.",
                }.get(action, "Saved.")

    state = _employee_clock_state(employee) if employee else None
    return render(request, "clock.html", {"message": message, "employee": employee, "state": state})


def home_page(request):
    service_date = current_service_date()
    week_start = service_date - timedelta(days=service_date.weekday())
    current_rows = get_open_staff_rows()
    roster_rows = get_day_rows(service_date)
    issue_count = len(payroll_issue_rows(week_start))
    return render(request, "home.html", {
        "today": service_date,
        "week_start": week_start,
        "current_rows": current_rows,
        "roster_rows": roster_rows,
        "currently_working": sum(1 for r in current_rows if r["is_working"]),
        "on_break": sum(1 for r in current_rows if r["is_on_break"]),
        "break_attention_count": sum(1 for r in current_rows if r["operational_warning"] != "OK"),
        "payroll_problem_count": issue_count,
    })


@login_required
def manager_today_dashboard(request):
    selected = request.GET.get("date")
    service_date = datetime.strptime(selected, "%Y-%m-%d").date() if selected else current_service_date()
    return render(request, "manager_today.html", {"selected_date": service_date, "rows": get_day_rows(service_date)})


@login_required
def upload_roster(request):
    message = ""
    if request.method == "POST" and request.FILES.get("roster_file"):
        f = request.FILES["roster_file"]
        decoded = f.read().decode("utf-8-sig").splitlines()
        reader = csv.DictReader(decoded)
        rows = list(reader)
        replace_week = request.POST.get("replace_week") == "yes"
        if replace_week and rows:
            dates = [datetime.strptime(r["Date"], "%Y-%m-%d").date() for r in rows if r.get("Date")]
            if dates:
                RosterShift.objects.filter(shift_date__gte=min(dates), shift_date__lte=max(dates)).delete()
        count = 0
        for r in rows:
            emp_no = (r.get("EmployeeNumber") or "").strip()
            name = (r.get("EmployeeName") or "").strip()
            if not emp_no or not name:
                continue
            employee, _ = Employee.objects.get_or_create(employee_number=emp_no, defaults={"name": name, "pin": emp_no[-4:]})
            if employee.name != name:
                employee.name = name
                employee.save(update_fields=["name"])
            RosterShift.objects.create(
                employee=employee,
                shift_date=datetime.strptime(r["Date"], "%Y-%m-%d").date(),
                start_time=datetime.strptime(r["StartTime"], "%H:%M").time(),
                end_time=datetime.strptime(r["EndTime"], "%H:%M").time(),
                break_minutes=int(r.get("BreakMinutes") or 0),
            )
            count += 1
        message = f"Roster uploaded. {count} shift(s) saved."
    return render(request, "upload_roster.html", {"message": message})


@login_required
def payroll_problems(request):
    week_start = _parse_week_start(request)
    week_end = week_start + timedelta(days=6)

    if request.method == "POST":
        action = request.POST.get("action")
        employee = get_object_or_404(Employee, employee_number=request.POST.get("employee_number"))
        service_date = datetime.strptime(request.POST.get("event_date"), "%Y-%m-%d").date()

        if action == "pay_roster":
            start_dt, end_dt, break_mins = roster_start_end_datetimes(employee, service_date)
            if start_dt and end_dt:
                replace_day_with_clean_shift(employee, service_date, start_dt, end_dt, break_mins, "Manager chose: pay roster hours")

        elif action == "clock_out_roster":
            _start, end_dt, _break_mins = roster_start_end_datetimes(employee, service_date)
            if end_dt:
                latest = ClockEvent.objects.filter(employee=employee, timestamp__lt=end_dt + timedelta(hours=12)).order_by("-timestamp", "-id").first()
                if latest and latest.clock_type == "BREAK_START":
                    ClockEvent.objects.create(employee=employee, clock_type="BREAK_END", timestamp=end_dt, method="MANAGER", notes="Manager chose: clock out at roster finish")
                if not latest or latest.clock_type != "OUT":
                    ClockEvent.objects.create(employee=employee, clock_type="OUT", timestamp=end_dt, method="MANAGER", notes="Manager chose: clock out at roster finish")

        elif action == "approve_unrostered":
            start_dt, end_dt = service_window(service_date)
            for event in ClockEvent.objects.filter(employee=employee, timestamp__gte=start_dt, timestamp__lt=end_dt):
                notes = event.notes or ""
                if APPROVED_UNROSTERED_TOKEN not in notes:
                    event.notes = (notes + " " + APPROVED_UNROSTERED_TOKEN + " Manager approved unrostered shift").strip()
                    event.save(update_fields=["notes"])

        elif action == "actual_times":
            start_raw = request.POST.get("actual_start")
            end_raw = request.POST.get("actual_end")
            if start_raw and end_raw:
                start_dt = _aware(service_date, start_raw)
                end_dt = _aware(service_date, end_raw)
                if end_dt <= start_dt:
                    end_dt += timedelta(days=1)
                replace_day_with_clean_shift(employee, service_date, start_dt, end_dt, 0, "Manager entered actual paid times")

        return _redirect_payroll(week_start)

    rows = payroll_issue_rows(week_start)
    return render(request, "payroll_problems.html", {"week_start": week_start, "week_end": week_end, "rows": rows, "problem_count": len(rows)})


@login_required
def manager_weekly_summary(request):
    week_start = _parse_week_start(request)
    week_end = week_start + timedelta(days=6)
    standard_hours = float(request.GET.get("standard_hours", "39"))
    summary_rows = get_week_rows(week_start, standard_hours)
    issue_count = len(payroll_issue_rows(week_start))
    totals = {
        "rostered": round(sum(r["rostered_hours"] for r in summary_rows), 2),
        "paid": round(sum(r["paid_hours"] for r in summary_rows), 2),
        "normal": round(sum(r["normal_hours"] for r in summary_rows), 2),
        "sunday": round(sum(r["sunday_hours"] for r in summary_rows), 2),
        "overtime": round(sum(r["overtime_hours"] for r in summary_rows), 2),
    }
    return render(request, "weekly_summary.html", {"week_start": week_start, "week_end": week_end, "summary_rows": summary_rows, "standard_hours": standard_hours, "unresolved_problem_count": issue_count, "totals": totals})


@login_required
def export_sage_payroll_csv(request):
    week_start = _parse_week_start(request)
    issues = payroll_issue_rows(week_start)
    if issues:
        lines = ["Payroll is not ready. Fix payroll issues before exporting the Sage CSV.", ""]
        for row in issues:
            lines.append(f"{row['date']} - {row['employee']}: {row['payroll_issue']}")
        return HttpResponse("\n".join(lines), content_type="text/plain")

    period_number = request.GET.get("period", "1")
    standard_hours = float(request.GET.get("standard_hours", "39"))
    include_header = request.GET.get("include_header") == "1"
    rows = get_week_rows(week_start, standard_hours)
    response = HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = 'attachment; filename="sage_payroll_export.csv"'
    writer = csv.writer(response)
    if include_header:
        writer.writerow(["PeriodNumber", "EmployeeNumber", "0000", "NormalHours", "SundayHours", "OvertimeHours"])
    for row in rows:
        if row["paid_minutes"] <= 0:
            continue
        writer.writerow([period_number, row["employee_number"], "0000", row["normal_hours"], row["sunday_hours"], row["overtime_hours"]])
    return response


@login_required
def manager_fix_day(request):
    employee = get_object_or_404(Employee, employee_number=(request.GET.get("employee_number") or request.POST.get("employee_number")))
    service_date = datetime.strptime((request.GET.get("event_date") or request.POST.get("event_date")), "%Y-%m-%d").date()
    week_start = _parse_week_start(request)
    message = ""

    if request.method == "POST":
        mode = request.POST.get("mode")
        if mode == "delete":
            event = get_object_or_404(ClockEvent, id=request.POST.get("event_id"), employee=employee)
            event.delete()
            message = "Deleted selected clock event."
        elif mode == "add":
            clock_type = request.POST.get("clock_type")
            event_time = request.POST.get("event_time")
            reason = (request.POST.get("reason") or "Manager correction").strip()
            ClockEvent.objects.create(employee=employee, clock_type=clock_type, timestamp=_aware(service_date, event_time), method="MANAGER", notes=f"Manager correction: {reason}")
            message = "Clock event added."

    events = get_day_events_for_template(employee, service_date)
    day = calculate_employee_day(employee, service_date, include_live=False)
    return render(request, "manager_fix_day.html", {"employee": employee, "event_date": service_date, "events": events, "day": day, "message": message, "week_start": week_start})


def get_day_events_for_template(employee, service_date):
    start_dt, end_dt = service_window(service_date)
    events = list(ClockEvent.objects.filter(employee=employee, timestamp__gte=start_dt, timestamp__lt=end_dt).order_by("timestamp", "id"))
    for event in events:
        event.local_time = timezone.localtime(event.timestamp).strftime("%H:%M")
    return events


@login_required
def manager_corrections(request):
    selected = request.GET.get("date")
    service_date = datetime.strptime(selected, "%Y-%m-%d").date() if selected else current_service_date()
    events = []
    start_dt, end_dt = service_window(service_date)
    events = ClockEvent.objects.select_related("employee").filter(timestamp__gte=start_dt, timestamp__lt=end_dt).order_by("-timestamp")
    employees = Employee.objects.filter(active=True).order_by("name")
    return render(request, "manager_corrections.html", {"selected_date": service_date, "events": events, "employees": employees, "message": ""})


@login_required
def manager_add_missing_event(request):
    return redirect("manager_corrections")


@login_required
def manager_dashboard(request):
    return redirect("manager_today_dashboard")


@login_required
def manager_daily_monitor(request):
    return redirect("manager_today_dashboard")


@login_required
def generate_test_clock_events(request):
    return render(request, "generate_test_events.html", {"message": "Use the Demo Week Simulator patch only on a demo database."})


def export_clock_events_csv(request):
    response = HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = 'attachment; filename="clock_events.csv"'
    writer = csv.writer(response)
    writer.writerow(["EmployeeNumber", "Employee", "Timestamp", "Type", "Method", "Notes"])
    for event in ClockEvent.objects.select_related("employee").order_by("timestamp"):
        writer.writerow([event.employee.employee_number, event.employee.name, timezone.localtime(event.timestamp).strftime("%Y-%m-%d %H:%M"), event.clock_type, event.method, event.notes])
    return response


def manager_logout(request):
    from django.contrib.auth import logout
    logout(request)
    return render(request, "manager_logged_out.html")
PY

cat > core/urls.py <<'PY'
from django.urls import path

from .views import (
    ManagerLoginView,
    export_clock_events_csv,
    export_sage_payroll_csv,
    generate_test_clock_events,
    home_page,
    manager_add_missing_event,
    manager_corrections,
    manager_daily_monitor,
    manager_dashboard,
    manager_fix_day,
    manager_logout,
    manager_today_dashboard,
    manager_weekly_summary,
    payroll_problems,
    smart_clock_page,
    upload_roster,
)

urlpatterns = [
    path('', home_page, name='home'),
    path('clock/', smart_clock_page, name='clock'),
    path('manager/login/', ManagerLoginView.as_view(), name='manager_login'),
    path('manager/logout/', manager_logout, name='manager_logout'),
    path('export/clock-events/', export_clock_events_csv, name='export_clock_events_csv'),
    path('manager/upload-roster/', upload_roster, name='upload_roster'),
    path('manager/dashboard/', manager_dashboard, name='manager_dashboard'),
    path('manager/weekly-summary/', manager_weekly_summary, name='manager_weekly_summary'),
    path('manager/generate-test-events/', generate_test_clock_events, name='generate_test_clock_events'),
    path('manager/daily-monitor/', manager_daily_monitor, name='manager_daily_monitor'),
    path('manager/today/', manager_today_dashboard, name='manager_today_dashboard'),
    path('manager/export-sage-payroll/', export_sage_payroll_csv, name='export_sage_payroll_csv'),
    path('manager/payroll-problems/', payroll_problems, name='payroll_problems'),
    path('manager/add-missing-event/', manager_add_missing_event, name='manager_add_missing_event'),
    path('manager/fix-day/', manager_fix_day, name='manager_fix_day'),
    path('manager/corrections/', manager_corrections, name='manager_corrections'),
]
PY

cat > templates/payroll_problems.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Payroll Issues</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #111827; }
        .container { max-width: 1250px; margin: auto; background: white; padding: 24px; border-radius: 14px; border: 1px solid #e5e7eb; }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 10px; text-align: left; vertical-align: top; }
        th { background: #f9fafb; }
        .warn { color: #b42318; font-weight: bold; }
        .okbox { background:#ecfdf3; border-left:4px solid #22c55e; padding:12px; margin:14px 0; }
        .notready { background:#fffbeb; border-left:4px solid #f59e0b; padding:12px; margin:14px 0; }
        .button, button { display: inline-block; padding: 9px 12px; background: #2563eb; color: white; text-decoration: none; border: none; border-radius: 8px; font-weight: bold; margin: 2px; cursor: pointer; }
        .secondary { background: #4b5563; }
        .fix { background: #b45309; }
        .link { background: transparent; color: #2563eb; padding: 0; font-weight: normal; text-decoration: underline; }
        input { padding: 8px; }
        .small { color:#64748b; font-size: 14px; }
        form.inline { display:inline-block; margin:0 4px 4px 0; }
    </style>
</head>
<body>
<div class="container">
<h1>Payroll Issues</h1>
<p>Fix the common payroll issues here. Use the quick fix that matches what should be paid.</p>

<form method="get">
    Week Start: <input type="date" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
    <button type="submit">View Week</button>
</form>

<h2>{{ week_start }} to {{ week_end }}</h2>

{% if problem_count == 0 %}
    <div class="okbox"><strong>Payroll ready.</strong> No payroll issues found for this week.</div>
{% else %}
    <div class="notready"><strong>Payroll not ready: {{ problem_count }} issue(s) found.</strong></div>
{% endif %}

<table>
    <tr>
        <th>Date</th><th>Employee</th><th>Roster</th><th>Status</th><th>Worked</th><th>Problem</th><th>Quick Fix</th>
    </tr>
    {% for row in rows %}
    <tr>
        <td>{{ row.date }}</td>
        <td>{{ row.employee }}</td>
        <td>{{ row.roster }}</td>
        <td>{{ row.status }}</td>
        <td>{{ row.worked_hours }}h</td>
        <td class="warn">{{ row.payroll_issue }}</td>
        <td>
            {% if row.no_clock_records %}
                <form class="inline" method="post">{% csrf_token %}
                    <input type="hidden" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
                    <input type="hidden" name="employee_number" value="{{ row.employee_number }}">
                    <input type="hidden" name="event_date" value="{{ row.date|date:'Y-m-d' }}">
                    <input type="hidden" name="action" value="pay_roster">
                    <button class="fix" type="submit">Pay roster hours</button>
                </form>
            {% endif %}

            {% if row.missing_clock_out %}
                <form class="inline" method="post">{% csrf_token %}
                    <input type="hidden" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
                    <input type="hidden" name="employee_number" value="{{ row.employee_number }}">
                    <input type="hidden" name="event_date" value="{{ row.date|date:'Y-m-d' }}">
                    <input type="hidden" name="action" value="clock_out_roster">
                    <button class="fix" type="submit">Clock out at roster finish</button>
                </form>
            {% endif %}

            {% if row.unrostered_shift %}
                <form class="inline" method="post">{% csrf_token %}
                    <input type="hidden" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
                    <input type="hidden" name="employee_number" value="{{ row.employee_number }}">
                    <input type="hidden" name="event_date" value="{{ row.date|date:'Y-m-d' }}">
                    <input type="hidden" name="action" value="approve_unrostered">
                    <button class="fix" type="submit">Approve shift</button>
                </form>
            {% endif %}

            <form class="inline" method="post">{% csrf_token %}
                <input type="hidden" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
                <input type="hidden" name="employee_number" value="{{ row.employee_number }}">
                <input type="hidden" name="event_date" value="{{ row.date|date:'Y-m-d' }}">
                <input type="hidden" name="action" value="actual_times">
                <input type="time" name="actual_start" aria-label="Actual start">
                <input type="time" name="actual_end" aria-label="Actual finish">
                <button class="fix" type="submit">Enter actual times</button>
            </form>

            <br><a href="/manager/fix-day/?employee_number={{ row.employee_number }}&event_date={{ row.date|date:'Y-m-d' }}&week_start={{ week_start|date:'Y-m-d' }}">Advanced</a>
        </td>
    </tr>
    {% empty %}
    <tr><td colspan="7" class="okbox">No payroll issues found.</td></tr>
    {% endfor %}
</table>

<p class="small">Break warnings are handled on the live dashboard. They do not block payroll export unless the clock records themselves are wrong.</p>
<p>
    <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Summary</a>
    <a class="button secondary" href="/manager/today/">Manager Dashboard</a>
    <a class="button secondary" href="/">Home</a>
</p>
</div>
</body>
</html>
HTML

cat > templates/weekly_summary.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Weekly Payroll Summary</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #111827; }
        .container { max-width: 1250px; margin: auto; background: white; padding: 24px; border-radius: 14px; border: 1px solid #e5e7eb; }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 10px; text-align: left; }
        th { background: #f9fafb; }
        .ok { color: #1a7f37; font-weight: bold; }
        .warn { color: #b42318; font-weight: bold; }
        .button { display: inline-block; padding: 10px 13px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 8px; }
        .secondary { background: #4b5563; }
        .disabled { background:#9ca3af; pointer-events:none; }
        input, button { padding: 8px; }
        .cards { display:flex; gap:12px; margin:18px 0; flex-wrap:wrap; }
        .card { border:1px solid #e5e7eb; border-radius:10px; padding:14px; min-width:150px; background:#f9fafb; }
        .num { font-size:24px; font-weight:bold; }
        .notready { background:#fffbeb; border-left:4px solid #f59e0b; padding:12px; margin:14px 0; }
        .ready { background:#ecfdf3; border-left:4px solid #22c55e; padding:12px; margin:14px 0; }
    </style>
</head>
<body>
<div class="container">
<h1>Weekly Payroll Summary</h1>
<p>Review paid hours, fix payroll issues, then export the Sage CSV.</p>

<form method="get">
    Week Start: <input type="date" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
    Standard Weekly Hours: <input type="number" step="0.5" name="standard_hours" value="{{ standard_hours }}">
    <button type="submit">View Week</button>
</form>

<h2>{{ week_start }} to {{ week_end }}</h2>

<div class="cards">
    <div class="card">Rostered<div class="num">{{ totals.rostered }}</div></div>
    <div class="card">Paid Hours<div class="num">{{ totals.paid }}</div></div>
    <div class="card">Normal<div class="num">{{ totals.normal }}</div></div>
    <div class="card">Sunday<div class="num">{{ totals.sunday }}</div></div>
    <div class="card">Overtime<div class="num">{{ totals.overtime }}</div></div>
</div>

{% if unresolved_problem_count > 0 %}
<div class="notready"><strong>Payroll not ready: {{ unresolved_problem_count }} issue(s) found.</strong> <a href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Fix Payroll Issues</a></div>
<a class="button disabled">Download Sage CSV</a>
{% else %}
<div class="ready"><strong>Payroll ready.</strong> You can export the Sage CSV.</div>
<a class="button" href="/manager/export-sage-payroll/?week_start={{ week_start|date:'Y-m-d' }}&period=1&standard_hours={{ standard_hours }}">Download Sage CSV</a>
{% endif %}

<h2>Weekly Review</h2>
<table>
<tr><th>Employee No</th><th>Employee</th><th>Rostered</th><th>Worked</th><th>Unpaid Breaks</th><th>Paid Hours</th><th>Normal</th><th>Sunday</th><th>Overtime</th><th>Difference</th><th>Status</th></tr>
{% for row in summary_rows %}
<tr>
    <td>{{ row.employee_number }}</td><td>{{ row.employee }}</td><td>{{ row.rostered_hours }}</td><td>{{ row.worked_hours }}</td><td>{{ row.break_hours }}</td><td>{{ row.paid_hours }}</td><td>{{ row.normal_hours }}</td><td>{{ row.sunday_hours }}</td><td>{{ row.overtime_hours }}</td><td>{{ row.difference }}</td>
    <td class="{% if row.warning == 'OK' %}ok{% else %}warn{% endif %}">{{ row.warning }}</td>
</tr>
{% endfor %}
</table>

<p>
    <a class="button secondary" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Payroll Issues</a>
    <a class="button secondary" href="/manager/today/">Manager Dashboard</a>
    <a class="button secondary" href="/manager/upload-roster/">Upload Roster</a>
    <a class="button secondary" href="/">Home</a>
</p>
</div>
</body>
</html>
HTML

cat > templates/home.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Restaurant Operations Dashboard</title>
    <style>
        body { font-family: Arial, sans-serif; background:#f4f6f8; margin:0; color:#06152d; }
        .section { background:white; margin:16px; padding:22px; border:1px solid #e5e7eb; border-radius:12px; }
        .cards { display:flex; gap:14px; margin:16px; flex-wrap:wrap; }
        .card { background:white; border:1px solid #e5e7eb; border-radius:12px; padding:18px; min-width:180px; }
        .num { font-size:34px; font-weight:bold; color:#047857; }
        .bad { color:#b42318; }
        table { width:100%; border-collapse:collapse; margin-top:12px; }
        th,td { padding:10px; border-bottom:1px solid #e5e7eb; text-align:left; }
        th { background:#f9fafb; }
        .button { display:inline-block; background:#4b5563; color:white; text-decoration:none; padding:11px 15px; border-radius:7px; font-weight:bold; margin-right:8px; }
        .primary { background:#2563eb; }
        .badge { padding:5px 9px; border-radius:999px; background:#dcfce7; color:#166534; font-weight:bold; }
        .warn { color:#b45309; font-weight:bold; }
    </style>
</head>
<body>
<div class="section">
    <h1>Restaurant Operations Dashboard</h1>
    <p>Service day: {{ today }}. Current staff first, payroll issues separate.</p>
    <a class="button" href="/manager/upload-roster/">Roster Manager</a>
    <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Payroll</a>
    <a class="button primary" href="/clock/">Staff Clocking</a>
</div>

<div class="cards">
    <div class="card">Working Now<div class="num">{{ currently_working }}</div></div>
    <div class="card">On Break Now<div class="num">{{ on_break }}</div></div>
    <div class="card">Breaks Needing Action<div class="num">{{ break_attention_count }}</div></div>
    <div class="card">Payroll Issues<div class="num {% if payroll_problem_count > 0 %}bad{% endif %}">{{ payroll_problem_count }}</div></div>
</div>

<div class="section">
<h2>Current Staff</h2>
<p>Anyone still clocked in appears here, including late-night shifts.</p>
<table>
<tr><th>Employee</th><th>Status</th><th>Roster</th><th>Clocked In</th><th>Worked</th><th>Break</th><th>Issue</th></tr>
{% for row in current_rows %}
<tr><td>{{ row.employee }}</td><td><span class="badge">{{ row.status }}</span></td><td>{{ row.roster }}</td><td>{{ row.first_in }}</td><td>{{ row.worked_hours }}h</td><td>{{ row.break_minutes }} mins</td><td class="warn">{% if row.payroll_issue != 'OK' %}{{ row.payroll_issue }}{% elif row.operational_warning != 'OK' %}{{ row.operational_warning }}{% else %}OK{% endif %}</td></tr>
{% empty %}<tr><td colspan="7">No staff are currently clocked in.</td></tr>{% endfor %}
</table>
</div>

<div class="section">
<h2>Service Day Roster</h2>
<table>
<tr><th>Employee</th><th>Roster</th><th>Status</th><th>Clocked In</th><th>Worked</th><th>Issue</th></tr>
{% for row in roster_rows %}
<tr><td>{{ row.employee }}</td><td>{{ row.roster }}</td><td>{{ row.status }}</td><td>{{ row.first_in }}</td><td>{{ row.worked_hours }}h</td><td class="warn">{% if row.payroll_issue != 'OK' %}{{ row.payroll_issue }}{% elif row.operational_warning != 'OK' %}{{ row.operational_warning }}{% else %}OK{% endif %}</td></tr>
{% empty %}<tr><td colspan="6">No roster or clock records for this service day.</td></tr>{% endfor %}
</table>
</div>
</body>
</html>
HTML

# Remove patch clutter and backup clutter from the working tree. The backup for this cleanup is kept.
rm -rf backups_patch_* || true
rm -f restaurant_delivery_patch_*.sh || true
rm -f core/*.working_not_rostered_bak templates/*.working_not_rostered_bak templates/*.manager_home_bak || true
rm -f restaurant_dashboard_patch.diff manager_homepage_dashboard.sh payroll_problems_smart_clocking.sh demo_simulation_tool.sh || true

python -m py_compile core/views.py core/compliance.py core/urls.py
python manage.py check

echo "Patch 39 applied. Backup saved to $BACKUP"
echo "The app now has one clean views.py, one payroll issue source, synced Payroll Issues / Weekly Summary / Sage export, and old patch clutter removed."
