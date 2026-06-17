#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-$(pwd)}"
cd "$APP_DIR"

STAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="backups_patch_38_${STAMP}"
mkdir -p "$BACKUP_DIR"

cp core/views.py "$BACKUP_DIR/views.py.bak"
cp templates/payroll_problems.html "$BACKUP_DIR/payroll_problems.html.bak" 2>/dev/null || true
cp templates/fix_day.html "$BACKUP_DIR/fix_day.html.bak" 2>/dev/null || true

cat >> core/views.py <<'PYCODE'

# -------------------------------------------------------------------
# Delivery patch 38: one payroll issue engine + manager-first fixes
# -------------------------------------------------------------------
from datetime import datetime as _dp38_datetime, timedelta as _dp38_timedelta
from django.contrib import messages as _dp38_messages
from django.http import HttpResponse as _dp38_HttpResponse
from django.shortcuts import redirect as _dp38_redirect, render as _dp38_render
from django.utils import timezone as _dp38_timezone
import csv as _dp38_csv


def _dp38_event_minute(ev):
    return _dp38_timezone.localtime(ev.timestamp).replace(second=0, microsecond=0)


def _dp38_events_unique(employee, day):
    """Return events with exact duplicate clock records collapsed for issue detection."""
    unique = []
    seen = set()
    for ev in _dp36_events(employee, day):
        key = (ev.clock_type, _dp38_event_minute(ev))
        if key in seen:
            continue
        seen.add(key)
        unique.append(ev)
    return unique


def _dp38_first_and_last_any(employee, day):
    events = _dp38_events_unique(employee, day)
    if not events:
        return None, None
    return events[0], events[-1]


def _dp38_first_in_last_out_unique(employee, day):
    events = _dp38_events_unique(employee, day)
    ins = [e for e in events if e.clock_type == "IN"]
    outs = [e for e in events if e.clock_type == "OUT"]
    return (ins[0] if ins else None), (outs[-1] if outs else None)


def _dp38_sequence_problem(employee, day):
    """Only flags genuinely odd payroll-blocking event sequences."""
    events = _dp38_events_unique(employee, day)
    if not events:
        return False

    # Valid simple payroll sequence after ignoring break events: IN ... OUT
    work_events = [e.clock_type for e in events if e.clock_type in ("IN", "OUT")]
    if not work_events:
        return True
    if work_events.count("IN") != 1 or work_events.count("OUT") != 1:
        return True
    if work_events[0] != "IN" or work_events[-1] != "OUT":
        return True

    # Breaks should not block payroll, but impossible ordering should be reviewed.
    break_balance = 0
    for ev in events:
        if ev.clock_type == "BREAK_START":
            break_balance += 1
        elif ev.clock_type == "BREAK_END":
            if break_balance <= 0:
                return True
            break_balance -= 1
    return False


def _dp38_delete_day_events(employee, day):
    start, end = _dp36_service_window(day)
    _dp36_ClockEvent.objects.filter(employee=employee, timestamp__gte=start, timestamp__lt=end).delete()


def _dp38_create_clean_shift(employee, start_dt, end_dt, note):
    if end_dt <= start_dt:
        end_dt += _dp38_timedelta(days=1)
    _dp36_create_event(employee, "IN", start_dt, f"{note} start")
    _dp36_create_event(employee, "OUT", end_dt, f"{note} finish")


def _dp38_apply_quick_fix(request):
    mode = request.POST.get("mode")
    employee_number = request.POST.get("employee_number")
    day_raw = request.POST.get("event_date")
    week_start = request.POST.get("week_start") or ""

    employee = _patch_get_object_or_404(_dp36_Employee, employee_number=employee_number)
    day = _dp36_parse_day(day_raw)
    shift = _dp36_roster_shift(employee, day)

    try:
        if mode == "pay_roster_shift":
            if not shift:
                _dp38_messages.error(request, "No roster shift found for this employee.")
            else:
                _dp38_delete_day_events(employee, day)
                _dp38_create_clean_shift(employee, shift["start"], shift["end"], f"paid roster hours {shift['label']}")
                _dp38_messages.success(request, f"{employee.name}: paid roster hours ({shift['label']}).")

        elif mode == "clock_out_roster_finish":
            if not shift:
                _dp38_messages.error(request, "No roster finish time found.")
            else:
                first_in, _last_out = _dp38_first_in_last_out_unique(employee, day)
                # Keep the real clock-in where possible, but rebuild a clean payroll sequence.
                start_dt = first_in.timestamp if first_in else shift["start"]
                _dp38_delete_day_events(employee, day)
                _dp38_create_clean_shift(employee, start_dt, shift["end"], f"clocked out at roster finish {shift['end_label']}")
                _dp38_messages.success(request, f"{employee.name}: clocked out at {shift['end_label']}.")

        elif mode == "enter_actual_finish":
            actual = request.POST.get("actual_time")
            if not actual:
                _dp38_messages.error(request, "Enter the finish time.")
            else:
                finish_dt = _dp36_make_aware(day, _dp38_datetime.strptime(actual, "%H:%M").time())
                first_in, _last_out = _dp38_first_in_last_out_unique(employee, day)
                start_dt = first_in.timestamp if first_in else (shift["start"] if shift else None)
                if not start_dt:
                    _dp38_messages.error(request, "No start time found. Use Enter actual times instead.")
                else:
                    if finish_dt <= start_dt:
                        finish_dt += _dp38_timedelta(days=1)
                    _dp38_delete_day_events(employee, day)
                    _dp38_create_clean_shift(employee, start_dt, finish_dt, f"actual finish entered by manager {actual}")
                    _dp38_messages.success(request, f"{employee.name}: finish set to {actual}.")

        elif mode == "enter_actual_shift":
            start_raw = request.POST.get("start_time")
            finish_raw = request.POST.get("finish_time")
            if not start_raw or not finish_raw:
                _dp38_messages.error(request, "Enter start and finish times.")
            else:
                start_dt = _dp36_make_aware(day, _dp38_datetime.strptime(start_raw, "%H:%M").time())
                finish_dt = _dp36_make_aware(day, _dp38_datetime.strptime(finish_raw, "%H:%M").time())
                _dp38_delete_day_events(employee, day)
                _dp38_create_clean_shift(employee, start_dt, finish_dt, f"actual shift entered by manager {start_raw}-{finish_raw}")
                _dp38_messages.success(request, f"{employee.name}: paid actual times {start_raw} - {finish_raw}.")

        elif mode == "approve_unrostered_shift":
            first_in, last_out = _dp38_first_in_last_out_unique(employee, day)
            if not first_in or not last_out:
                _dp38_messages.error(request, "This shift needs a clock-in and clock-out before it can be approved.")
            else:
                if not _dp36_roster_shift(employee, day):
                    start_time = _dp38_timezone.localtime(first_in.timestamp).time().replace(second=0, microsecond=0)
                    finish_time = _dp38_timezone.localtime(last_out.timestamp).time().replace(second=0, microsecond=0)
                    _dp36_RosterShift.objects.create(
                        employee=employee,
                        shift_date=day,
                        start_time=start_time,
                        end_time=finish_time,
                        break_minutes=0,
                    )
                _dp38_messages.success(request, f"{employee.name}: cover shift approved for payroll.")

        elif mode == "pay_actual_time":
            first, last = _dp38_first_and_last_any(employee, day)
            if not first or not last or first.timestamp == last.timestamp:
                _dp38_messages.error(request, "Not enough clock information. Enter actual times instead.")
            else:
                start_dt = first.timestamp
                end_dt = last.timestamp
                _dp38_delete_day_events(employee, day)
                _dp38_create_clean_shift(employee, start_dt, end_dt, "paid actual clock span")
                _dp38_messages.success(
                    request,
                    f"{employee.name}: paid actual time {_dp38_timezone.localtime(start_dt).strftime('%H:%M')} - {_dp38_timezone.localtime(end_dt).strftime('%H:%M')}.",
                )

        else:
            _dp38_messages.error(request, "Unknown quick fix.")

    except Exception as exc:
        _dp38_messages.error(request, f"Could not apply quick fix: {exc}")

    return _dp38_redirect(f"/manager/payroll-problems/?week_start={week_start}")


def _dp38_payroll_problem_rows(week_start):
    """Single issue list used by Payroll Issues, Weekly Review and Sage export."""
    rows = []
    today = _dp33_current_operational_date() if "_dp33_current_operational_date" in globals() else _dp36_timezone.localdate()

    for employee in _dp36_Employee.objects.filter(active=True).order_by("name"):
        for i in range(7):
            day = week_start + _dp36_timedelta(days=i)
            if day > today:
                continue

            d = _dp36_calculate_employee_day(employee, day, include_live=True)
            shift = _dp36_roster_shift(employee, day)
            events = _dp38_events_unique(employee, day)
            first_in, last_out = _dp38_first_in_last_out_unique(employee, day)
            problems = []
            quick = []

            # Common restaurant cases first. These are the things a manager can fix quickly.
            if shift and not events and day < today:
                problems.append("No clock records")
                quick.append({"mode": "pay_roster_shift", "label": f"Pay roster hours ({shift['label']})"})
                quick.append({"mode": "enter_actual_shift", "label": "Enter actual times"})

            elif shift and first_in and not last_out:
                problems.append("Missing clock-out")
                quick.append({"mode": "clock_out_roster_finish", "label": f"Clock out at {shift['end_label']}"})
                quick.append({"mode": "enter_actual_finish", "label": "Enter finish"})

            elif events and not shift:
                if first_in and last_out and not _dp38_sequence_problem(employee, day):
                    problems.append("Unrostered shift")
                    quick.append({"mode": "approve_unrostered_shift", "label": "Approve shift"})
                else:
                    problems.append("Check clock events")
                    quick.append({"mode": "pay_actual_time", "label": "Pay actual time"})
                    quick.append({"mode": "enter_actual_shift", "label": "Enter correct times"})

            elif events and _dp38_sequence_problem(employee, day):
                problems.append("Check clock events")
                quick.append({"mode": "pay_actual_time", "label": "Pay actual time"})
                quick.append({"mode": "enter_actual_shift", "label": "Enter correct times"})

            # Long paid shifts are worth reviewing, but breaks alone do not block payroll.
            if d.get("worked_minutes", 0) > 12 * 60:
                problems.append("Long shift")

            cleaned = []
            for problem in problems:
                if not problem:
                    continue
                if "break" in problem.lower():
                    continue
                if problem not in cleaned:
                    cleaned.append(problem)
            problems = cleaned

            if not problems:
                continue

            if not quick:
                quick.append({"mode": "advanced", "label": "Review"})

            rows.append({
                "date": day,
                "employee_number": employee.employee_number,
                "employee": employee.name,
                "roster": d.get("roster"),
                "status": d.get("status"),
                "worked_hours": d.get("worked_hours"),
                "problem": "; ".join(problems),
                "quick_actions": quick,
            })
    return rows


def _dp30_payroll_is_ready(week_start):
    rows = _dp38_payroll_problem_rows(week_start)
    return (len(rows) == 0), rows


@_dp31_login_required
def payroll_problems(request):
    if request.method == "POST":
        return _dp38_apply_quick_fix(request)

    week_start = _patch_parse_week_start(request)
    week_end = week_start + _dp36_timedelta(days=6)
    rows = _dp38_payroll_problem_rows(week_start)
    return _dp38_render(request, "payroll_problems.html", {
        "week_start": week_start,
        "week_end": week_end,
        "rows": rows,
        "problem_count": len(rows),
    })


def _dp38_weekly_rows(week_start, standard_hours):
    raw_rows = _patch_get_week_rows(week_start, standard_hours)
    current_day = _dp33_current_operational_date() if "_dp33_current_operational_date" in globals() else _dp36_timezone.localdate()
    week_end = week_start + _dp36_timedelta(days=6)
    problem_rows = _dp38_payroll_problem_rows(week_start)
    problem_map = {}
    for problem in problem_rows:
        problem_map.setdefault(problem["employee_number"], []).append(f"{problem['date'].strftime('%a')}: {problem['problem']}")

    for row in raw_rows:
        rostered_minutes = int(float(row.get("rostered_hours", 0) or 0) * 60)
        paid_minutes = int(row.get("paid_minutes", 0) or 0)
        difference_minutes = paid_minutes - rostered_minutes
        problems = problem_map.get(row.get("employee_number"), [])
        future_rostered = week_start <= current_day <= week_end and rostered_minutes > paid_minutes

        if problems:
            row["review_status"] = "Review"
            row["review_reason"] = "; ".join(problems[:3])
            row["status_css"] = "warn"
        elif future_rostered:
            row["review_status"] = "In progress"
            row["review_reason"] = "Week not finished"
            row["status_css"] = "progress"
        elif rostered_minutes > 0 and paid_minutes == 0 and week_end < current_day:
            row["review_status"] = "Review"
            row["review_reason"] = "Rostered but no paid hours"
            row["status_css"] = "warn"
        elif abs(difference_minutes) > 4 * 60:
            row["review_status"] = "Review"
            row["review_reason"] = f"Variance {_dp33_minutes_to_hours_label(abs(difference_minutes))}" if "_dp33_minutes_to_hours_label" in globals() else "Large variance"
            row["status_css"] = "warn"
        elif abs(difference_minutes) > 60:
            row["review_status"] = "Check"
            row["review_reason"] = f"Variance {_dp33_minutes_to_hours_label(abs(difference_minutes))}" if "_dp33_minutes_to_hours_label" in globals() else "Variance"
            row["status_css"] = "check"
        else:
            row["review_status"] = "OK"
            row["review_reason"] = ""
            row["status_css"] = "ok"
    return raw_rows


def _dp33_weekly_rows(week_start, standard_hours):
    return _dp38_weekly_rows(week_start, standard_hours)


def export_sage_payroll_csv(request):
    week_start = _patch_parse_week_start(request)
    period_number = request.GET.get("period", "1")
    standard_hours = float(request.GET.get("standard_hours", "39"))

    payroll_ready_bool, payroll_problem_rows = _dp30_payroll_is_ready(week_start)
    if not payroll_ready_bool:
        response = _dp38_HttpResponse(content_type="text/plain", status=400)
        response.write("Payroll is not ready. Fix the payroll issues shown on the Payroll Issues page.\n")
        for row in payroll_problem_rows:
            response.write(f"{row.get('date')} - {row.get('employee')}: {row.get('problem')}\n")
        return response

    rows = _patch_get_week_rows(week_start, standard_hours)
    response = _dp38_HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = 'attachment; filename="sage_payroll_export.csv"'
    writer = _dp38_csv.writer(response)
    for row in rows:
        employee_number = row.get("employee_number")
        normal = _dp31_minutes_to_decimal_string(row.get("normal_minutes", 0)) if "_dp31_minutes_to_decimal_string" in globals() else str(row.get("normal_hours", 0))
        sunday = _dp31_minutes_to_decimal_string(row.get("sunday_minutes", 0)) if "_dp31_minutes_to_decimal_string" in globals() else str(row.get("sunday_hours", 0))
        overtime = _dp31_minutes_to_decimal_string(row.get("overtime_minutes", 0)) if "_dp31_minutes_to_decimal_string" in globals() else str(row.get("overtime_hours", 0))
        if normal == "0.00" and sunday == "0.00" and overtime == "0.00":
            continue
        writer.writerow([period_number, employee_number, "0000", normal, sunday, overtime])
    return response
PYCODE

python - <<'PY'
from pathlib import Path

p = Path('templates/payroll_problems.html')
if p.exists():
    text = p.read_text()
    text = text.replace('Fix the common payroll issues here. When you click a quick fix, the issue should disappear from this list.', 'Fix the common payroll issues here. Use the quick fix that matches what should be paid.')
    text = text.replace('Fix the common payroll issues here. Use the quick fix that matches what should be paid.', 'Fix the common payroll issues here. Use the quick fix that matches what should be paid.')
    # Avoid duplicate Review + Advanced links when the only quick action is advanced.
    text = text.replace("""{% if action.mode == 'advanced' %}\n                    <a class=\"advanced\" href=\"/manager/fix-day/?employee_number={{ row.employee_number }}&event_date={{ row.date|date:'Y-m-d' }}&week_start={{ week_start|date:'Y-m-d' }}\">Review</a>""", """{% if action.mode == 'advanced' %}\n                    <a class=\"advanced\" href=\"/manager/fix-day/?employee_number={{ row.employee_number }}&event_date={{ row.date|date:'Y-m-d' }}&week_start={{ week_start|date:'Y-m-d' }}\">Review</a>""")
    p.write_text(text)

p = Path('templates/fix_day.html')
if p.exists():
    text = p.read_text()
    text = text.replace('The clock records look wrong. Review the events below and delete or add records as needed.\nThe clock records look wrong. Review the events below and delete or add records as needed.', 'The clock records look wrong. Use Payroll Issues for quick fixes, or edit events here only when needed.')
    text = text.replace('The clock records look wrong. Review the events below and delete or add records as needed.', 'The clock records look wrong. Use Payroll Issues for quick fixes, or edit events here only when needed.')
    text = text.replace('Recommended manager action', 'Advanced clock-event review')
    text = text.replace('Events on this day', 'Clock records for this day')
    p.write_text(text)
PY

python -m py_compile core/views.py
python manage.py check

echo "Patch 38 applied. Backup saved to $BACKUP_DIR"
echo "Payroll Issues, Weekly Review and Sage export now use the same issue logic. Break warnings no longer block Sage export. Quick fixes rebuild clean payroll records so fixed rows disappear."
