#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-$PWD}"
cd "$APP_DIR"

if [ ! -f manage.py ] || [ ! -d core ] || [ ! -d templates ]; then
  echo "Run this from the restaurant_clocking project root, or set APP_DIR=/path/to/restaurant_clocking" >&2
  exit 1
fi

STAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="backups_patch_26_${STAMP}"
mkdir -p "$BACKUP_DIR/core" "$BACKUP_DIR/templates"
cp core/compliance.py "$BACKUP_DIR/core/compliance.py"
cp core/views.py "$BACKUP_DIR/core/views.py"
cp templates/manager_today.html "$BACKUP_DIR/templates/manager_today.html"
cp templates/weekly_summary.html "$BACKUP_DIR/templates/weekly_summary.html"
cp templates/payroll_problems.html "$BACKUP_DIR/templates/payroll_problems.html"

cat > core/compliance.py <<'PY'
from datetime import datetime, time, timedelta

from django.utils import timezone

from .models import Employee, ClockEvent, RosterShift


# Restaurant operational day starts at 05:00. This keeps late-night shifts
# such as 16:00-01:00 on the same manager review day.
OPERATIONAL_DAY_START_HOUR = 5


def format_minutes(minutes):
    minutes = int(minutes or 0)
    if minutes < 60:
        return f"{minutes} mins"
    hours = minutes // 60
    mins = minutes % 60
    if mins == 0:
        return f"{hours}h"
    return f"{hours}h {mins}m"


def required_break_minutes(worked_minutes):
    """
    Ireland working-time break guide:
    - more than 4.5 hours worked: at least 15 minutes
    - more than 6 hours worked: at least 30 minutes total
    """
    if worked_minutes > 360:
        return 30
    if worked_minutes > 270:
        return 15
    return 0


def operational_window(selected_date):
    start = timezone.make_aware(
        datetime.combine(selected_date, time(OPERATIONAL_DAY_START_HOUR, 0))
    )
    end = start + timedelta(days=1)
    return start, end


def _local_hhmm(dt):
    if not dt:
        return "-"
    return timezone.localtime(dt).strftime("%H:%M")


def get_roster_info(employee, selected_date):
    shifts = RosterShift.objects.filter(
        employee=employee,
        shift_date=selected_date,
    ).order_by("start_time")

    rostered = shifts.exists()
    roster_text = "Not rostered"
    planned_start = None
    planned_end = None
    rostered_minutes = 0

    if rostered:
        parts = []
        for shift in shifts:
            parts.append(
                f"{shift.start_time.strftime('%H:%M')} - {shift.end_time.strftime('%H:%M')}"
            )
            if planned_start is None or shift.start_time < planned_start:
                planned_start = shift.start_time
            if planned_end is None or shift.end_time > planned_end:
                planned_end = shift.end_time

            start_dt = datetime.combine(shift.shift_date, shift.start_time)
            end_dt = datetime.combine(shift.shift_date, shift.end_time)
            if end_dt <= start_dt:
                end_dt += timedelta(days=1)
            rostered_minutes += int((end_dt - start_dt).total_seconds() / 60)
            rostered_minutes -= int(shift.break_minutes or 0)
        roster_text = ", ".join(parts)

    return {
        "rostered": rostered,
        "roster_text": roster_text,
        "planned_start": planned_start,
        "planned_end": planned_end,
        "rostered_minutes": max(0, rostered_minutes),
    }


def _events_for_operational_day(employee, selected_date):
    start, end = operational_window(selected_date)
    return ClockEvent.objects.filter(
        employee=employee,
        timestamp__gte=start,
        timestamp__lt=end,
    ).order_by("timestamp")


def _planned_start_dt(selected_date, planned_start):
    return timezone.make_aware(datetime.combine(selected_date, planned_start))


def _planned_end_dt(selected_date, planned_start, planned_end):
    if not planned_end:
        return None
    start_dt = _planned_start_dt(selected_date, planned_start)
    end_dt = timezone.make_aware(datetime.combine(selected_date, planned_end))
    if end_dt <= start_dt:
        end_dt += timedelta(days=1)
    return end_dt


def build_break_status(worked_minutes, break_minutes, is_working, is_on_break):
    required_break = required_break_minutes(worked_minutes)
    remaining_to_15 = max(0, 271 - worked_minutes)
    remaining_to_30 = max(0, 361 - worked_minutes)

    if is_on_break:
        return {
            "break_status": "On break now",
            "break_css": "break-on",
            "break_action": "Staff member is currently on break.",
            "required_break": required_break,
        }

    if required_break and break_minutes >= required_break:
        return {
            "break_status": "OK",
            "break_css": "break-ok",
            "break_action": "Required break has been taken.",
            "required_break": required_break,
        }

    if worked_minutes > 360 and break_minutes < 30:
        return {
            "break_status": "Urgent: 30 min break needed",
            "break_css": "break-urgent",
            "break_action": "Arrange/record a 30 minute total break before payroll is signed off.",
            "required_break": 30,
        }

    if worked_minutes > 270 and break_minutes < 15:
        return {
            "break_status": "Overdue: 15 min break needed",
            "break_css": "break-urgent",
            "break_action": "Arrange/record a 15 minute break now.",
            "required_break": 15,
        }

    if is_working and worked_minutes >= 345 and break_minutes < 30:
        return {
            "break_status": f"30 min break due in {format_minutes(remaining_to_30)}",
            "break_css": "break-warn",
            "break_action": "Plan the 30 minute total break soon.",
            "required_break": 30,
        }

    if is_working and worked_minutes >= 255 and break_minutes < 15:
        return {
            "break_status": f"15 min break due in {format_minutes(remaining_to_15)}",
            "break_css": "break-warn",
            "break_action": "Plan a 15 minute break soon.",
            "required_break": 15,
        }

    if is_working and worked_minutes >= 240 and break_minutes < 15:
        return {
            "break_status": f"Heads-up: break in {format_minutes(remaining_to_15)}",
            "break_css": "break-warn",
            "break_action": "Heads-up only; no breach yet.",
            "required_break": 15,
        }

    return {
        "break_status": "No break needed yet",
        "break_css": "break-ok",
        "break_action": "No action needed.",
        "required_break": required_break,
    }


def calculate_employee_day(employee, selected_date, include_live=True):
    events = _events_for_operational_day(employee, selected_date)
    roster = get_roster_info(employee, selected_date)

    first_in = None
    last_out = None
    latest_event = events.last()
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

        elif event.clock_type == "BREAK_START":
            if work_start is not None:
                worked_minutes += int((event.timestamp - work_start).total_seconds() / 60)
                work_start = None
            else:
                invalid_sequence = True
            if break_start is not None:
                invalid_sequence = True
            break_start = event.timestamp

        elif event.clock_type == "BREAK_END":
            if break_start is not None:
                break_minutes += int((event.timestamp - break_start).total_seconds() / 60)
                break_start = None
            else:
                invalid_sequence = True
            work_start = event.timestamp

        elif event.clock_type == "OUT":
            last_out = event.timestamp
            if work_start is not None:
                worked_minutes += int((event.timestamp - work_start).total_seconds() / 60)
                work_start = None
            elif break_start is not None:
                break_minutes += int((event.timestamp - break_start).total_seconds() / 60)
                break_start = None
            else:
                invalid_sequence = True

    now = timezone.now()
    today = timezone.localdate()
    currently_open_work = work_start is not None
    currently_open_break = break_start is not None

    if include_live and selected_date == today:
        if currently_open_work:
            worked_minutes += max(0, int((now - work_start).total_seconds() / 60))
        elif currently_open_break:
            break_minutes += max(0, int((now - break_start).total_seconds() / 60))

    status = "No activity"
    if latest_event:
        status = {
            "IN": "Working now",
            "BREAK_START": "On break",
            "BREAK_END": "Back from break",
            "OUT": "Clocked out",
        }.get(latest_event.clock_type, "No activity")

    is_working = status in ["Working now", "Back from break"]
    is_on_break = status == "On break"
    is_clocked_out = status == "Clocked out"
    break_info = build_break_status(worked_minutes, break_minutes, is_working, is_on_break)
    required_break = break_info["required_break"]

    urgent_issues = []
    operational_issues = []

    if invalid_sequence:
        urgent_issues.append("Check clock sequence")

    if latest_event and not roster["rostered"]:
        urgent_issues.append("Working but not rostered")

    if roster["rostered"] and not latest_event and selected_date == today and roster["planned_start"]:
        planned_dt = _planned_start_dt(selected_date, roster["planned_start"])
        if now > planned_dt + timedelta(minutes=30):
            operational_issues.append("Rostered but absent")
        elif now > planned_dt + timedelta(minutes=10):
            operational_issues.append("Late / not arrived")

    if is_working:
        if worked_minutes > 360 and break_minutes < 30:
            urgent_issues.append("Worked over 6h with less than 30 mins break")
        elif worked_minutes > 270 and break_minutes < 15:
            urgent_issues.append("Worked over 4.5h with less than 15 mins break")
        elif break_info["break_css"] == "break-warn":
            operational_issues.append(break_info["break_status"])

    if is_clocked_out and required_break > 0 and break_minutes < required_break:
        urgent_issues.append("Break missing or too short")

    # Missing clock-out: past operational days, or very long open live shift.
    if latest_event and latest_event.clock_type in ["IN", "BREAK_START", "BREAK_END"]:
        if selected_date < today:
            urgent_issues.append("Missing clock-out")
        elif worked_minutes > 14 * 60:
            urgent_issues.append("Unusually long open shift / possible missing clock-out")

    if first_in and roster["planned_start"]:
        planned_start_dt = _planned_start_dt(selected_date, roster["planned_start"])
        planned_end_dt = _planned_end_dt(selected_date, roster["planned_start"], roster["planned_end"])
        late_minutes = int((first_in - planned_start_dt).total_seconds() / 60)
        if planned_end_dt and first_in > planned_end_dt:
            operational_issues.append("Clocked in after rostered shift ended")
        elif late_minutes > 10:
            operational_issues.append(f"Late by {late_minutes} mins")
        elif late_minutes < -15:
            operational_issues.append(f"Clocked in {abs(late_minutes)} mins early")

    if worked_minutes > 12 * 60:
        operational_issues.append("Unusually long shift")

    issue_type = "OK"
    issue_text = "OK"
    if urgent_issues:
        issue_type = "Urgent"
        issue_text = "; ".join(dict.fromkeys(urgent_issues))
    elif operational_issues:
        issue_type = "Operational"
        issue_text = "; ".join(dict.fromkeys(operational_issues))

    paid_minutes = worked_minutes

    return {
        "employee_number": employee.employee_number,
        "employee": employee.name,
        "employee_obj": employee,
        "date": selected_date,
        "roster": roster["roster_text"],
        "rostered": roster["rostered"],
        "rostered_minutes": roster["rostered_minutes"],
        "first_in": _local_hhmm(first_in),
        "last_out": _local_hhmm(last_out),
        "status": status,
        "worked_minutes": worked_minutes,
        "break_minutes": break_minutes,
        "paid_minutes": paid_minutes,
        "worked_hours": round(worked_minutes / 60, 2),
        "break_hours": round(break_minutes / 60, 2),
        "paid_hours": round(paid_minutes / 60, 2),
        "required_break": required_break,
        "break_status": break_info["break_status"],
        "break_css": break_info["break_css"],
        "break_action": break_info["break_action"],
        "issue_type": issue_type,
        "issue": issue_text,
        "is_urgent": issue_type == "Urgent",
        "is_operational": issue_type == "Operational",
        "is_working": is_working,
        "is_on_break": is_on_break,
        "is_clocked_out": is_clocked_out,
        "has_activity": latest_event is not None,
        "missing_clock_out": bool(
            latest_event
            and latest_event.clock_type in ["IN", "BREAK_START", "BREAK_END"]
            and selected_date < today
        ),
        "invalid_sequence": invalid_sequence,
    }


def get_day_rows(selected_date):
    employees = Employee.objects.filter(active=True).order_by("name")
    return [calculate_employee_day(employee, selected_date, include_live=True) for employee in employees]


def get_payroll_problem_rows(week_start):
    rows = []
    week_end = week_start + timedelta(days=6)
    for employee in Employee.objects.filter(active=True).order_by("name"):
        for i in range(7):
            day = week_start + timedelta(days=i)
            d = calculate_employee_day(employee, day, include_live=True)
            problems = []
            if d.get("missing_clock_out"):
                problems.append("Missing clock-out")
            if d.get("invalid_sequence"):
                problems.append("Check clock sequence")
            if d.get("is_urgent"):
                problems.append(d.get("issue"))
            if d.get("worked_minutes", 0) > 12 * 60:
                problems.append("Unusually long shift")
            if d.get("paid_minutes", 0) > 0 and not d.get("employee_number"):
                problems.append("Missing Sage employee number")
            if problems:
                rows.append({
                    "date": day,
                    "employee_number": employee.employee_number,
                    "employee": employee.name,
                    "roster": d.get("roster"),
                    "status": d.get("status"),
                    "worked_hours": d.get("worked_hours"),
                    "break_minutes": d.get("break_minutes"),
                    "break_status": d.get("break_status"),
                    "problem": "; ".join(dict.fromkeys([p for p in problems if p])),
                })
    return rows


def payroll_is_ready(week_start):
    problems = get_payroll_problem_rows(week_start)
    return len(problems) == 0, problems


def calculate_employee_week(employee, week_start, standard_hours=39):
    standard_minutes = int(float(standard_hours) * 60)
    rostered_minutes = 0
    worked_minutes = 0
    break_minutes = 0
    paid_minutes = 0
    sunday_minutes = 0
    warnings = []

    for i in range(7):
        day = week_start + timedelta(days=i)
        day_row = calculate_employee_day(employee, day, include_live=True)
        rostered_minutes += day_row["rostered_minutes"]
        worked_minutes += day_row["worked_minutes"]
        break_minutes += day_row["break_minutes"]
        paid_minutes += day_row["paid_minutes"]
        if day.weekday() == 6:
            sunday_minutes += day_row["paid_minutes"]
        if day_row["is_urgent"]:
            warnings.append(f"{day}: {day_row['issue']}")

    overtime_minutes = max(0, paid_minutes - standard_minutes)
    normal_minutes = max(0, paid_minutes - overtime_minutes - sunday_minutes)
    difference_minutes = paid_minutes - rostered_minutes

    return {
        "employee": employee.name,
        "employee_number": employee.employee_number,
        "rostered_hours": round(rostered_minutes / 60, 2),
        "worked_hours": round(worked_minutes / 60, 2),
        "break_hours": round(break_minutes / 60, 2),
        "paid_hours": round(paid_minutes / 60, 2),
        "normal_hours": round(normal_minutes / 60, 2),
        "sunday_hours": round(sunday_minutes / 60, 2),
        "overtime_hours": round(overtime_minutes / 60, 2),
        "difference": round(difference_minutes / 60, 2),
        "warning": "; ".join(warnings) if warnings else "OK",
        "paid_minutes": paid_minutes,
        "normal_minutes": normal_minutes,
        "sunday_minutes": sunday_minutes,
        "overtime_minutes": overtime_minutes,
    }


def get_week_rows(week_start, standard_hours=39):
    employees = Employee.objects.filter(active=True).order_by("name")
    return [calculate_employee_week(employee, week_start, standard_hours) for employee in employees]
PY

cat > templates/manager_today.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Live Manager Dashboard</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #222; }
        .container { max-width: 1300px; margin: auto; }
        .header, .section { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 22px; margin-bottom: 18px; }
        .muted { color: #667085; }
        .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(165px, 1fr)); gap: 14px; margin: 18px 0; }
        .card { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 18px; }
        .card-title { font-size: 15px; color: #111827; }
        .number { font-size: 36px; font-weight: bold; margin-top: 8px; }
        .red { color: #b42318; }
        .green { color: #1a7f37; }
        .orange { color: #b7791f; }
        table { width: 100%; border-collapse: collapse; margin-top: 12px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 11px; text-align: left; vertical-align: top; }
        th { background: #f9fafb; }
        .urgent { color: #b42318; font-weight: bold; }
        .operational { color: #b7791f; font-weight: bold; }
        .ok { color: #1a7f37; font-weight: bold; }
        .button { display: inline-block; padding: 10px 13px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 8px; margin-bottom: 8px; }
        .secondary { background: #4b5563; }
        input, button { padding: 8px; }
        .badge { display: inline-block; padding: 4px 8px; border-radius: 999px; font-size: 13px; font-weight: bold; }
        .badge-green, .break-ok { background: #dcfce7; color: #166534; }
        .badge-orange, .break-warn, .break-on { background: #ffedd5; color: #9a3412; }
        .break-urgent { background: #fee2e2; color: #991b1b; }
        .priority-note { background: #f9fafb; padding: 10px; border-radius: 8px; margin-top: 10px; }
    </style>
</head>
<body>
<div class="container">
    <div class="header">
        <h1>Live Manager Dashboard</h1>
        <p class="muted">The top table is the live floor view. The review tables below are for exceptions and payroll readiness.</p>
        <form method="get">Date: <input type="date" name="date" value="{{ selected_date|date:'Y-m-d' }}"> <button type="submit">View Date</button></form>
    </div>

    <div class="cards">
        <div class="card"><div class="card-title">👥 Working Now</div><div class="number">{{ currently_working }}</div></div>
        <div class="card"><div class="card-title">☕ On Break</div><div class="number orange">{{ on_break }}</div></div>
        <div class="card"><div class="card-title">⏰ Late / Absent</div><div class="number {% if late_absent_count > 0 %}red{% endif %}">{{ late_absent_count }}</div></div>
        <div class="card"><div class="card-title">⚠ Payroll Blockers</div><div class="number {% if payroll_issues_count > 0 %}red{% else %}green{% endif %}">{{ payroll_issues_count }}</div></div>
        <div class="card"><div class="card-title">✅ Payroll Ready</div><div class="number {% if payroll_ready < 100 %}red{% else %}green{% endif %}">{{ payroll_ready }}%</div></div>
    </div>

    <div class="section">
        <h2>Live Now</h2>
        <p class="muted">Use this during service. At 10:30pm this shows who is still active, on break, or creating a live issue — not every old morning note.</p>
        <table>
            <tr><th>Employee</th><th>Status</th><th>Roster</th><th>First In</th><th>Worked</th><th>Break Taken</th><th>Break Status</th><th>Issue</th></tr>
            {% for row in live_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{% if row.is_on_break %}<span class="badge badge-orange">On Break</span>{% else %}<span class="badge badge-green">{{ row.status }}</span>{% endif %}</td>
                <td>{{ row.roster }}</td>
                <td>{{ row.first_in }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td>{{ row.break_minutes }} mins</td>
                <td><span class="badge {{ row.break_css }}">{{ row.break_status }}</span></td>
                <td class="{% if row.is_urgent %}urgent{% elif row.is_operational %}operational{% else %}ok{% endif %}">{{ row.issue }}</td>
            </tr>
            {% empty %}
            <tr><td colspan="8">No staff currently clocked in and no live issues.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Needs Attention</h2>
        <p class="muted">Red items can block payroll export. Amber items are operational notes such as late arrival or break due soon.</p>
        <table>
            <tr><th>Employee</th><th>Type</th><th>Roster</th><th>Status</th><th>Issue</th><th>Worked</th><th>Break Status</th><th>Action</th></tr>
            {% for row in needs_attention_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{% if row.is_urgent %}<span class="urgent">Payroll</span>{% else %}<span class="operational">Operational</span>{% endif %}</td>
                <td>{{ row.roster }}</td>
                <td>{{ row.status }}</td>
                <td class="{% if row.is_urgent %}urgent{% else %}operational{% endif %}">{{ row.issue }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td><span class="badge {{ row.break_css }}">{{ row.break_status }}</span></td>
                <td><a class="button secondary" href="/manager/fix-day/?employee_number={{ row.employee_number }}&event_date={{ row.date|date:'Y-m-d' }}">Fix / Edit</a></td>
            </tr>
            {% empty %}
            <tr><td colspan="8" class="ok">No issues need attention.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Review Today</h2>
        <p class="muted">Full day review for the selected operational day. Use this at end of day or before payroll.</p>
        <div class="priority-note">
            <strong>Rostered:</strong> {{ rostered_count }} &nbsp; | &nbsp;
            <strong>Working:</strong> {{ currently_working }} &nbsp; | &nbsp;
            <strong>On Break:</strong> {{ on_break }} &nbsp; | &nbsp;
            <strong>Late:</strong> {{ late_count }} &nbsp; | &nbsp;
            <strong>Absent:</strong> {{ not_arrived_count }}
        </div>
        <table>
            <tr><th>No</th><th>Employee</th><th>Roster</th><th>First In</th><th>Last Out</th><th>Status</th><th>Worked</th><th>Break</th><th>Issue</th></tr>
            {% for row in review_rows %}
            <tr>
                <td>{{ row.employee_number }}</td>
                <td>{{ row.employee }}</td>
                <td>{{ row.roster }}</td>
                <td>{{ row.first_in }}</td>
                <td>{{ row.last_out }}</td>
                <td>{{ row.status }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td><span class="badge {{ row.break_css }}">{{ row.break_status }}</span></td>
                <td class="{% if row.is_urgent %}urgent{% elif row.is_operational %}operational{% else %}ok{% endif %}">{{ row.issue }}</td>
            </tr>
            {% empty %}
            <tr><td colspan="9">No rostered staff or clock activity for this date.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Payroll Status</h2>
        {% if payroll_issues_count > 0 %}
            <p class="urgent"><strong>Payroll is NOT READY.</strong> {{ payroll_issues_count }} blocker(s) must be fixed before Sage export.</p>
            <a class="button" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Review Payroll Problems</a>
        {% else %}
            <p class="ok"><strong>Payroll looks ready</strong> for the week starting {{ week_start }}.</p>
            <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Open Weekly Summary</a>
        {% endif %}
        <a class="button secondary" href="/clock/">Staff Clocking</a>
        <a class="button secondary" href="/manager/upload-roster/">Upload Roster</a>
        <a class="button secondary" href="/">Home</a>
    </div>
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
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #222; }
        .container { max-width: 1250px; margin: auto; background: white; padding: 24px; border-radius: 14px; border: 1px solid #e5e7eb; }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 10px; text-align: left; vertical-align: top; }
        th { background: #f9fafb; }
        .ok { color: #1a7f37; font-weight: bold; }
        .warn { color: #b42318; font-weight: bold; }
        .button { display: inline-block; padding: 10px 13px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 8px; margin-bottom: 8px; }
        .secondary { background: #4b5563; }
        .disabled { background: #9ca3af; cursor: not-allowed; }
        input, button { padding: 8px; }
        .note { background:#fffbeb; border-left:4px solid #f59e0b; padding:12px; margin:12px 0; }
        .ready { background:#f0fdf4; border-left:4px solid #22c55e; padding:12px; margin:12px 0; }
    </style>
</head>
<body>
<div class="container">
<h1>Weekly Payroll Summary</h1>
<p>This page prepares Sage-ready hours from clock records. Breaks are unpaid. Sunday hours are separated. Overtime is calculated above the standard weekly hours entered below.</p>

<form method="get">
    Week Start:
    <input type="date" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
    Standard Weekly Hours:
    <input type="number" step="0.5" name="standard_hours" value="{{ standard_hours }}">
    <button type="submit">View Week</button>
</form>

<h2>{{ week_start }} to {{ week_end }}</h2>

{% if payroll_ready %}
<div class="ready"><strong>Payroll READY.</strong> The Sage CSV export is enabled for this week.</div>
<p><a class="button" href="/manager/export-sage-payroll/?week_start={{ week_start|date:'Y-m-d' }}&period=1&standard_hours={{ standard_hours }}">Download Sage Payroll CSV</a></p>
{% else %}
<div class="note"><strong>Payroll NOT READY.</strong> {{ unresolved_problem_count }} blocker(s) found. Fix them before exporting to Sage.</div>
<p><a class="button" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Review Payroll Problems</a> <span class="button disabled">Sage CSV Disabled</span></p>
{% endif %}

<table>
    <tr>
        <th>Employee No</th><th>Employee</th><th>Rostered</th><th>Worked</th><th>Unpaid Breaks</th><th>Paid Hours</th><th>Normal</th><th>Sunday</th><th>Overtime</th><th>Difference</th><th>Status</th>
    </tr>
    {% for row in summary_rows %}
    <tr>
        <td>{{ row.employee_number }}</td><td>{{ row.employee }}</td><td>{{ row.rostered_hours }}</td><td>{{ row.worked_hours }}</td><td>{{ row.break_hours }}</td><td>{{ row.paid_hours }}</td><td>{{ row.normal_hours }}</td><td>{{ row.sunday_hours }}</td><td>{{ row.overtime_hours }}</td><td>{{ row.difference }}</td>
        <td class="{% if row.warning == 'OK' %}ok{% else %}warn{% endif %}">{{ row.warning }}</td>
    </tr>
    {% endfor %}
</table>

<p>
    <a class="button secondary" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Payroll Problems</a>
    <a class="button secondary" href="/manager/today/">Live Dashboard</a>
    <a class="button secondary" href="/manager/upload-roster/">Upload Roster</a>
    <a class="button secondary" href="/">Home</a>
</p>
</div>
</body>
</html>
HTML

cat > templates/payroll_problems.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Payroll Problems</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #222; }
        .container { max-width: 1250px; margin: auto; background: white; padding: 24px; border-radius: 14px; border: 1px solid #e5e7eb; }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 10px; text-align: left; vertical-align: top; }
        th { background: #f9fafb; }
        .warn { color: #b42318; font-weight: bold; }
        .ok { color: #1a7f37; font-weight: bold; }
        .button { display: inline-block; padding: 10px 13px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 8px; margin-bottom: 8px; }
        .secondary { background: #4b5563; }
        .fix { background: #b45309; }
        input, button { padding: 8px; }
        .note { background: #fffbeb; border-left: 4px solid #f59e0b; padding: 10px; margin: 12px 0; }
        .ready { background:#f0fdf4; border-left:4px solid #22c55e; padding:12px; margin:12px 0; }
    </style>
</head>
<body>
<div class="container">
<h1>Payroll Problems</h1>
<p>These are the blockers that should be fixed before Sage export: missing clock-outs, invalid sequences, break breaches, unapproved unrostered work, and unusually long shifts.</p>

<form method="get">
    Week Start: <input type="date" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
    <button type="submit">View Week</button>
</form>

<h2>{{ week_start }} to {{ week_end }}</h2>

{% if problem_count == 0 %}
    <div class="ready"><strong>Payroll READY.</strong> No blockers found for this week.</div>
{% else %}
    <div class="note"><strong>Payroll NOT READY: {{ problem_count }} blocker(s) found.</strong> Fix these before exporting to Sage.</div>
{% endif %}

<table>
    <tr><th>Date</th><th>Employee</th><th>Roster</th><th>Status</th><th>Worked</th><th>Break Taken</th><th>Break Status</th><th>Problem</th><th>Action</th></tr>
    {% for row in rows %}
    <tr>
        <td>{{ row.date }}</td><td>{{ row.employee }}</td><td>{{ row.roster }}</td><td>{{ row.status }}</td><td>{{ row.worked_hours }}h</td><td>{{ row.break_minutes }} mins</td><td>{{ row.break_status }}</td><td class="warn">{{ row.problem }}</td>
        <td><a class="button fix" href="/manager/fix-day/?employee_number={{ row.employee_number }}&event_date={{ row.date|date:'Y-m-d' }}&week_start={{ week_start|date:'Y-m-d' }}">Fix / Edit</a></td>
    </tr>
    {% empty %}
    <tr><td colspan="9" class="ok">No problems found.</td></tr>
    {% endfor %}
</table>

<p>
    <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Summary</a>
    <a class="button secondary" href="/manager/today/">Live Dashboard</a>
    <a class="button secondary" href="/">Home</a>
</p>
</div>
</body>
</html>
HTML

if ! grep -q 'Delivery patch 26: live dashboard' core/views.py; then
cat >> core/views.py <<'PYVIEWS'

# Delivery patch 26: live dashboard, break compliance, payroll readiness
# -------------------------------------------------------------------
from django.contrib.auth.decorators import login_required as _dp26_login_required
from core.compliance import (
    get_day_rows as _dp26_get_day_rows,
    get_week_rows as _dp26_get_week_rows,
    get_payroll_problem_rows as _dp26_get_payroll_problem_rows,
    payroll_is_ready as _dp26_payroll_is_ready,
)


def _dp26_week_start_from_request(request):
    week_start_str = request.GET.get("week_start")
    if week_start_str:
        return datetime.strptime(week_start_str, "%Y-%m-%d").date()
    today = timezone.localdate()
    return today - timedelta(days=today.weekday())


@_dp26_login_required
def manager_today_dashboard(request):
    selected_date_str = request.GET.get("date", timezone.localdate().strftime("%Y-%m-%d"))
    selected_date = datetime.strptime(selected_date_str, "%Y-%m-%d").date()
    rows = _dp26_get_day_rows(selected_date)

    urgent_rows = [row for row in rows if row["is_urgent"]]
    operational_rows = [row for row in rows if row["is_operational"]]
    working_rows = [row for row in rows if row["is_working"] or row["is_on_break"]]
    needs_attention_rows = urgent_rows + operational_rows

    # Live screen should stay clean during service: active staff + urgent live blockers.
    live_rows = []
    seen = set()
    for row in working_rows + urgent_rows:
        key = row["employee_number"]
        if key not in seen:
            live_rows.append(row)
            seen.add(key)

    review_rows = [row for row in rows if row["rostered"] or row["has_activity"]]

    late_count = sum(1 for row in operational_rows if "late" in row.get("issue", "").lower())
    not_arrived_count = sum(
        1 for row in operational_rows
        if "absent" in row.get("issue", "").lower() or "not arrived" in row.get("issue", "").lower()
    )

    week_start = selected_date - timedelta(days=selected_date.weekday())
    payroll_ready_bool, payroll_problem_rows = _dp26_payroll_is_ready(week_start)
    payroll_issues_count = len(payroll_problem_rows)
    payroll_ready = 100 if payroll_ready_bool else 0

    return render(request, "manager_today.html", {
        "selected_date": selected_date,
        "week_start": week_start,
        "rows": rows,
        "live_rows": live_rows,
        "review_rows": review_rows,
        "urgent_rows": urgent_rows,
        "operational_rows": operational_rows,
        "working_rows": working_rows,
        "needs_attention_rows": needs_attention_rows,
        "late_count": late_count,
        "not_arrived_count": not_arrived_count,
        "late_absent_count": late_count + not_arrived_count,
        "payroll_issues_count": payroll_issues_count,
        "payroll_ready": payroll_ready,
        "rostered_count": sum(1 for row in rows if row["rostered"]),
        "currently_working": sum(1 for row in rows if row["is_working"]),
        "on_break": sum(1 for row in rows if row["is_on_break"]),
        "clocked_out": sum(1 for row in rows if row["is_clocked_out"]),
        "urgent_count": len(urgent_rows),
        "operational_count": len(operational_rows),
    })


@_dp26_login_required
def payroll_problems(request):
    week_start = _dp26_week_start_from_request(request)
    week_end = week_start + timedelta(days=6)
    rows = _dp26_get_payroll_problem_rows(week_start)
    return render(request, "payroll_problems.html", {
        "week_start": week_start,
        "week_end": week_end,
        "rows": rows,
        "problem_count": len(rows),
    })


@_dp26_login_required
def manager_weekly_summary(request):
    week_start = _dp26_week_start_from_request(request)
    week_end = week_start + timedelta(days=6)
    standard_hours = float(request.GET.get("standard_hours", "39"))
    summary_rows = _dp26_get_week_rows(week_start, standard_hours)
    payroll_ready_bool, payroll_problem_rows = _dp26_payroll_is_ready(week_start)

    return render(request, "weekly_summary.html", {
        "week_start": week_start,
        "week_end": week_end,
        "summary_rows": summary_rows,
        "standard_hours": standard_hours,
        "payroll_ready": payroll_ready_bool,
        "unresolved_problem_count": len(payroll_problem_rows),
    })


@_dp26_login_required
def export_sage_payroll_csv(request):
    week_start = _dp26_week_start_from_request(request)
    period_number = request.GET.get("period", "1")
    standard_hours = float(request.GET.get("standard_hours", "39"))
    include_header = request.GET.get("include_header") == "1"

    payroll_ready_bool, payroll_problem_rows = _dp26_payroll_is_ready(week_start)
    if not payroll_ready_bool:
        response = HttpResponse(content_type="text/plain", status=409)
        response.write("Payroll export blocked. Fix payroll problems first:\n\n")
        for problem in payroll_problem_rows:
            response.write(f"{problem['date']} - {problem['employee']}: {problem['problem']}\n")
        return response

    rows = _dp26_get_week_rows(week_start, standard_hours)
    response = HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = 'attachment; filename="sage_payroll_export.csv"'
    writer = csv.writer(response)

    # Sage Payroll IE single-timesheet import order:
    # period number, employee number, 0000, payment element 1, payment element 2, payment element 3.
    # Header is OFF by default because Sage imports often expect raw rows only.
    if include_header:
        writer.writerow(["PeriodNumber", "EmployeeNumber", "0000", "NormalHours", "SundayHours", "OvertimeHours"])

    for row in rows:
        if row["paid_minutes"] == 0:
            continue
        writer.writerow([
            period_number,
            row["employee_number"],
            "0000",
            row["normal_hours"],
            row["sunday_hours"],
            row["overtime_hours"],
        ])
    return response
PYVIEWS
else
  echo "Patch 26 view overrides already present; not appending again."
fi

python -m py_compile core/compliance.py core/views.py
echo "Patch 26 applied. Backup saved to $BACKUP_DIR"
