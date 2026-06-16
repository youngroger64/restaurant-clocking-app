#!/usr/bin/env bash
set -euo pipefail

echo "=== Restaurant Clocking Patch 25: Shared Live Roster Calculations ==="
echo "Manager-focused fix:"
echo "  - All pages now use the live RosterShift table for roster matching"
echo "  - Weekly Payroll no longer treats missed shifts as payroll blockers"
echo "  - Worked-but-not-rostered becomes a roster exception, not a payroll blocker"
echo "  - Weekly Payroll wording is updated"
echo

if [ ! -f "manage.py" ]; then
  echo "ERROR: Run from Django project root: cd ~/restaurant_clocking"
  exit 1
fi

stamp=$(date +%Y%m%d_%H%M%S)
mkdir -p "patch_backups_25_$stamp"
cp -f core/compliance.py "patch_backups_25_$stamp/compliance.py.before_patch25" 2>/dev/null || true
cp -f core/views.py "patch_backups_25_$stamp/views.py.before_patch25"
cp -f templates/weekly_summary.html "patch_backups_25_$stamp/weekly_summary.html.before_patch25" 2>/dev/null || true

cat >> core/compliance.py <<'PY'

# -------------------------------------------------------------------
# Patch 25: shared live roster calculations
# -------------------------------------------------------------------
# This section intentionally redefines get_day_rows/get_week_rows so the
# dashboard, issue review, and weekly payroll all calculate against the
# current RosterShift table instead of stale/duplicated logic.

from datetime import datetime as _p25_datetime, timedelta as _p25_timedelta
from django.utils import timezone as _p25_timezone
from core.models import Employee as _P25Employee, RosterShift as _P25RosterShift, ClockEvent as _P25ClockEvent


def _p25_round_hours(minutes):
    return round((minutes or 0) / 60, 2)


def _p25_minutes_between(start_dt, end_dt):
    if not start_dt or not end_dt:
        return 0
    return max(0, int((end_dt - start_dt).total_seconds() // 60))


def _p25_shift_datetimes(shift):
    start_dt = _p25_timezone.make_aware(_p25_datetime.combine(shift.shift_date, shift.start_time))
    end_date = shift.shift_date
    if shift.end_time <= shift.start_time:
        end_date = shift.shift_date + _p25_timedelta(days=1)
    end_dt = _p25_timezone.make_aware(_p25_datetime.combine(end_date, shift.end_time))
    return start_dt, end_dt


def _p25_format_shift(shifts):
    if not shifts:
        return "Not rostered"
    return "; ".join([f"{s.start_time.strftime('%H:%M')} - {s.end_time.strftime('%H:%M')}" for s in shifts])


def _p25_rostered_minutes(shifts):
    total = 0
    for shift in shifts:
        start_dt, end_dt = _p25_shift_datetimes(shift)
        total += _p25_minutes_between(start_dt, end_dt)
    return total


def _p25_shift_relation(shifts, selected_date):
    # Return later/current/finished for today's UI, or finished for past dates.
    now = _p25_timezone.localtime()
    today = _p25_timezone.localdate()

    if not shifts:
        return "none"
    if selected_date < today:
        return "finished"
    if selected_date > today:
        return "later"

    any_later = False
    any_finished = False

    for shift in shifts:
        start_dt, end_dt = _p25_shift_datetimes(shift)
        if start_dt <= now <= end_dt:
            return "current"
        if now < start_dt:
            any_later = True
        if now > end_dt:
            any_finished = True

    if any_later and not any_finished:
        return "later"
    return "finished"


def _p25_event_metrics(employee, selected_date):
    events = list(
        _P25ClockEvent.objects.filter(
            employee=employee,
            timestamp__date=selected_date
        ).order_by("timestamp", "id")
    )

    worked_minutes = 0
    break_minutes = 0
    first_in = None
    open_in = None
    open_break = None
    invalid_sequence = False

    for event in events:
        typ = (event.clock_type or "").upper()
        ts = event.timestamp

        if typ == "IN":
            if not first_in:
                first_in = ts
            if open_in is not None:
                invalid_sequence = True
            open_in = ts

        elif typ == "BREAK_START":
            if open_in is None:
                invalid_sequence = True
            if open_break is not None:
                invalid_sequence = True
            open_break = ts

        elif typ == "BREAK_END":
            if open_break is None:
                invalid_sequence = True
            else:
                break_minutes += _p25_minutes_between(open_break, ts)
                open_break = None

        elif typ == "OUT":
            if open_break is not None:
                break_minutes += _p25_minutes_between(open_break, ts)
                open_break = None
            if open_in is None:
                invalid_sequence = True
            else:
                worked_minutes += _p25_minutes_between(open_in, ts)
                open_in = None

    today = _p25_timezone.localdate()
    now = _p25_timezone.localtime()

    is_current_day = selected_date == today
    is_working = open_in is not None and open_break is None
    is_on_break = open_in is not None and open_break is not None

    if open_in is not None and is_current_day:
        worked_minutes += _p25_minutes_between(open_in, now)
        if open_break is not None:
            break_minutes += _p25_minutes_between(open_break, now)

    missing_clock_out = open_in is not None and not is_current_day
    open_break_historic = open_break is not None and not is_current_day

    if is_on_break:
        status = "On Break"
    elif is_working:
        status = "Working"
    elif events:
        status = "Finished Shift"
    else:
        status = "No Clock Records"

    return {
        "events": events,
        "has_activity": bool(events),
        "first_in_dt": first_in,
        "first_in": first_in.strftime("%H:%M") if first_in else "-",
        "worked_minutes": worked_minutes,
        "break_minutes": break_minutes,
        "worked_hours": _p25_round_hours(worked_minutes),
        "break_hours": _p25_round_hours(break_minutes),
        "is_working": is_working,
        "is_on_break": is_on_break,
        "status": status,
        "invalid_sequence": invalid_sequence,
        "missing_clock_out": missing_clock_out,
        "open_break_historic": open_break_historic,
    }


def get_day_rows(selected_date):
    # Single shared day calculation used by dashboard/issue review/payroll.
    shifts = list(
        _P25RosterShift.objects.select_related("employee")
        .filter(shift_date=selected_date)
        .order_by("start_time", "employee__name")
    )

    roster_by_emp_id = {}
    for shift in shifts:
        roster_by_emp_id.setdefault(shift.employee_id, []).append(shift)

    event_emp_ids = set(
        _P25ClockEvent.objects.filter(timestamp__date=selected_date)
        .values_list("employee_id", flat=True)
    )

    employee_ids = set(roster_by_emp_id.keys()) | event_emp_ids
    employees = list(_P25Employee.objects.filter(id__in=employee_ids).order_by("name"))

    rows = []

    for employee in employees:
        emp_shifts = roster_by_emp_id.get(employee.id, [])
        rostered = bool(emp_shifts)
        relation = _p25_shift_relation(emp_shifts, selected_date)
        metrics = _p25_event_metrics(employee, selected_date)

        rostered_minutes = _p25_rostered_minutes(emp_shifts)
        issue = "OK"
        issue_type = "OK"
        is_payroll_blocker = False
        is_roster_exception = False
        is_attendance_issue = False
        is_operational = False
        is_urgent = False

        if metrics["invalid_sequence"]:
            issue = "Check clock sequence"
            issue_type = "Clocking"
            is_payroll_blocker = True
            is_urgent = True

        elif metrics["missing_clock_out"]:
            issue = "Missing clock-out"
            issue_type = "Clocking"
            is_payroll_blocker = True
            is_urgent = True

        elif metrics["open_break_historic"]:
            issue = "Break was not ended"
            issue_type = "Clocking"
            is_payroll_blocker = True
            is_urgent = True

        elif metrics["has_activity"] and not rostered:
            issue = "Roster exception: worked but not rostered"
            issue_type = "Roster"
            is_roster_exception = True
            is_operational = True

        elif rostered and not metrics["has_activity"]:
            if relation == "later":
                issue = "OK"
                metrics["status"] = "Due Later"
            elif relation == "current":
                issue = "Not arrived for current shift"
                issue_type = "Attendance"
                is_attendance_issue = True
                is_operational = True
                metrics["status"] = "Not Arrived"
            else:
                issue = "Didn't clock in for scheduled shift"
                issue_type = "Attendance"
                is_attendance_issue = True
                metrics["status"] = "Didn't Clock In"

        elif rostered and metrics["first_in_dt"]:
            first_start = sorted(emp_shifts, key=lambda s: s.start_time)[0].start_time
            scheduled_start = _p25_timezone.make_aware(_p25_datetime.combine(selected_date, first_start))
            late_minutes = _p25_minutes_between(scheduled_start, metrics["first_in_dt"])
            if late_minutes > 10:
                issue = f"Late by {late_minutes} mins"
                issue_type = "Attendance"
                is_attendance_issue = True
                is_operational = True

        row = {
            "date": selected_date,
            "employee_number": employee.employee_number,
            "employee": employee.name,
            "employee_id": employee.id,
            "roster": _p25_format_shift(emp_shifts),
            "rostered": rostered,
            "rostered_minutes": rostered_minutes,
            "rostered_hours": _p25_round_hours(rostered_minutes),
            "status": metrics["status"],
            "first_in": metrics["first_in"],
            "worked_minutes": metrics["worked_minutes"],
            "worked_hours": metrics["worked_hours"],
            "break_minutes": metrics["break_minutes"],
            "break_hours": metrics["break_hours"],
            "paid_hours": metrics["worked_hours"],
            "is_working": metrics["is_working"],
            "is_on_break": metrics["is_on_break"],
            "has_activity": metrics["has_activity"],
            "issue": issue,
            "warning": issue,
            "issue_type": issue_type,
            "is_payroll_blocker": is_payroll_blocker,
            "is_roster_exception": is_roster_exception,
            "is_attendance_issue": is_attendance_issue,
            "is_operational": is_operational,
            "is_urgent": is_urgent,
        }

        row["manager_issue"] = "" if issue == "OK" else issue
        row["manager_issue_type"] = issue_type if issue_type != "OK" else "Operational"

        if issue_type == "Clocking":
            row["manager_issue_type_class"] = "red"
        elif issue_type == "Roster":
            row["manager_issue_type_class"] = "blue"
        elif issue_type == "Attendance":
            row["manager_issue_type_class"] = "orange"
        else:
            row["manager_issue_type_class"] = "orange"

        if row["status"] == "Working":
            row["manager_status"] = "Working"
            row["manager_status_class"] = "green"
        elif row["status"] == "On Break":
            row["manager_status"] = "On Break"
            row["manager_status_class"] = "orange"
        elif row["status"] in ("Due Later", "Finished Shift"):
            row["manager_status"] = row["status"]
            row["manager_status_class"] = "blue"
        elif row["status"] in ("Not Arrived", "Didn't Clock In"):
            row["manager_status"] = row["status"]
            row["manager_status_class"] = "red"
        else:
            row["manager_status"] = row["status"]
            row["manager_status_class"] = "blue" if metrics["has_activity"] else "red"

        rows.append(row)

    return rows


def get_week_rows(week_start, days=7):
    # Weekly summary built from get_day_rows, so roster edits sync everywhere.
    employees = list(_P25Employee.objects.all().order_by("name"))
    by_emp = {}

    for employee in employees:
        by_emp[employee.id] = {
            "employee_number": employee.employee_number,
            "employee": employee.name,
            "rostered_hours": 0.0,
            "worked_hours": 0.0,
            "break_hours": 0.0,
            "paid_hours": 0.0,
            "regular_hours": 0.0,
            "overtime_hours": 0.0,
            "unpaid_break_hours": 0.0,
            "variance_hours": 0.0,
            "warning": "OK",
            "warnings": [],
            "payroll_blockers": [],
            "roster_exceptions": [],
            "attendance_notes": [],
        }

    for i in range(days):
        day = week_start + _p25_timedelta(days=i)
        for row in get_day_rows(day):
            emp_id = row["employee_id"]
            if emp_id not in by_emp:
                by_emp[emp_id] = {
                    "employee_number": row["employee_number"],
                    "employee": row["employee"],
                    "rostered_hours": 0.0,
                    "worked_hours": 0.0,
                    "break_hours": 0.0,
                    "paid_hours": 0.0,
                    "regular_hours": 0.0,
                    "overtime_hours": 0.0,
                    "unpaid_break_hours": 0.0,
                    "variance_hours": 0.0,
                    "warning": "OK",
                    "warnings": [],
                    "payroll_blockers": [],
                    "roster_exceptions": [],
                    "attendance_notes": [],
                }

            agg = by_emp[emp_id]
            agg["rostered_hours"] += row["rostered_hours"]
            agg["worked_hours"] += row["worked_hours"]
            agg["break_hours"] += row["break_hours"]
            agg["paid_hours"] += row["paid_hours"]

            if row["issue"] != "OK":
                dated_issue = f"{day.isoformat()}: {row['issue']}"
                agg["warnings"].append(dated_issue)

                if row["is_payroll_blocker"]:
                    agg["payroll_blockers"].append(dated_issue)
                elif row["is_roster_exception"]:
                    agg["roster_exceptions"].append(dated_issue)
                elif row["is_attendance_issue"]:
                    agg["attendance_notes"].append(dated_issue)

    output = []
    for agg in by_emp.values():
        agg["rostered_hours"] = round(agg["rostered_hours"], 2)
        agg["worked_hours"] = round(agg["worked_hours"], 2)
        agg["break_hours"] = round(agg["break_hours"], 2)
        agg["paid_hours"] = round(agg["paid_hours"], 2)
        agg["regular_hours"] = round(min(agg["paid_hours"], 39.0), 2)
        agg["overtime_hours"] = round(max(0.0, agg["paid_hours"] - 39.0), 2)
        agg["variance_hours"] = round(agg["worked_hours"] - agg["rostered_hours"], 2)

        if agg["payroll_blockers"]:
            agg["warning"] = "; ".join(agg["payroll_blockers"])
            agg["warning_type"] = "Payroll"
            agg["warning_class"] = "red"
        elif agg["roster_exceptions"]:
            agg["warning"] = "; ".join(agg["roster_exceptions"])
            agg["warning_type"] = "Roster"
            agg["warning_class"] = "blue"
        else:
            agg["warning"] = "OK"
            agg["warning_type"] = "OK"
            agg["warning_class"] = "green"

        output.append(agg)

    return sorted(output, key=lambda r: str(r["employee"]))
PY

cat >> core/views.py <<'PY'

# -------------------------------------------------------------------
# Patch 25: weekly payroll uses shared live roster calculations
# -------------------------------------------------------------------

def manager_weekly_summary(request):
    from core.compliance import get_week_rows

    week_start = _patch_parse_week_start(request)
    week_end = week_start + timedelta(days=6)
    rows = get_week_rows(week_start, 7)

    payroll_blockers = sum(1 for row in rows if row.get("warning_type") == "Payroll")
    roster_exceptions = sum(1 for row in rows if row.get("warning_type") == "Roster")

    return render(request, "weekly_summary.html", {
        "week_start": week_start,
        "week_end": week_end,
        "rows": rows,
        "payroll_blockers": payroll_blockers,
        "roster_exceptions": roster_exceptions,
    })


manager_weekly_summary = login_required(manager_weekly_summary)
PY

cat > templates/weekly_summary.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Weekly Payroll Summary</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #111827; }
        .container { max-width: 1250px; margin: auto; }
        .section { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 22px; margin-bottom: 18px; }
        h1 { margin: 0 0 8px 0; }
        .muted { color: #666; }
        .red { color: #b42318; font-weight: bold; }
        .blue { color: #2563eb; font-weight: bold; }
        .green { color: #1a7f37; font-weight: bold; }
        table { width: 100%; border-collapse: collapse; margin-top: 12px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 10px; text-align: left; }
        th { background: #f9fafb; }
        input { padding: 8px; }
        .button { display: inline-block; padding: 10px 13px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 8px; margin-bottom: 8px; }
        .secondary { background: #4b5563; }
        .summary { background: #f9fafb; padding: 12px; border-radius: 8px; margin-top: 10px; }
    </style>
</head>
<body>
<div class="container">

    <div class="section">
        <h1>Weekly Payroll Summary</h1>
        <p class="muted">
            This page is for payroll totals. Missed rostered shifts do not block payroll because they calculate as 0 worked hours.
            Roster exceptions are shown separately from payroll blockers.
        </p>

        <form method="get">
            <label>Week Start:</label>
            <input type="date" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
            <button class="button" type="submit">View Week</button>
        </form>

        <h2>{{ week_start|date:"F j, Y" }} to {{ week_end|date:"F j, Y" }}</h2>

        <div class="summary">
            <strong class="{% if payroll_blockers > 0 %}red{% else %}green{% endif %}">
                Payroll blockers: {{ payroll_blockers }}
            </strong>
            &nbsp; | &nbsp;
            <strong class="blue">Roster exceptions: {{ roster_exceptions }}</strong>
        </div>
    </div>

    <div class="section">
        <h2>What the status means</h2>
        <p class="muted">
            <strong>OK</strong> means payroll can calculate from the available clock records.
            <strong class="red">Payroll blockers</strong> are clocking problems such as missing clock-outs, open breaks, or invalid clock sequences.
            <strong class="blue">Roster exceptions</strong> mean someone worked without a matching roster shift; the hours can still be calculated, but the manager may want to update the roster.
        </p>
    </div>

    <div class="section">
        <table>
            <tr>
                <th>No.</th>
                <th>Employee</th>
                <th>Rostered</th>
                <th>Worked</th>
                <th>Break</th>
                <th>Paid</th>
                <th>Regular</th>
                <th>Overtime</th>
                <th>Variance</th>
                <th>Status / Issue</th>
            </tr>
            {% for row in rows %}
            <tr>
                <td>{{ row.employee_number }}</td>
                <td>{{ row.employee }}</td>
                <td>{{ row.rostered_hours }}</td>
                <td>{{ row.worked_hours }}</td>
                <td>{{ row.break_hours }}</td>
                <td>{{ row.paid_hours }}</td>
                <td>{{ row.regular_hours }}</td>
                <td>{{ row.overtime_hours }}</td>
                <td>{{ row.variance_hours }}</td>
                <td class="{{ row.warning_class }}">{{ row.warning }}</td>
            </tr>
            {% empty %}
            <tr><td colspan="10" class="muted">No employees found.</td></tr>
            {% endfor %}
        </table>
    </div>

    <p>
        <a class="button" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Payroll and Roster Review</a>
        <a class="button secondary" href="/manager/upload-roster/?week_start={{ week_start|date:'Y-m-d' }}">Roster Manager</a>
        <a class="button secondary" href="/">Dashboard</a>
    </p>

</div>
</body>
</html>
HTML

echo "Checking Python syntax..."
python -m py_compile core/compliance.py
python -m py_compile core/views.py

echo "Running Django checks..."
python manage.py check

echo
echo "Patch 25 complete."
echo "Restart:"
echo "  sudo systemctl restart restaurant_clocking"
