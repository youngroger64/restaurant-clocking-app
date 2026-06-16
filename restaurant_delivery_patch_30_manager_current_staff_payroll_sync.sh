#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-$PWD}"
cd "$APP_DIR"

if [ ! -f manage.py ] || [ ! -d core ] || [ ! -d templates ]; then
  echo "Run this from the restaurant_clocking project root, or set APP_DIR=/path/to/restaurant_clocking" >&2
  exit 1
fi

STAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="backups_patch_30_${STAMP}"
mkdir -p "$BACKUP_DIR/core" "$BACKUP_DIR/templates"
cp core/compliance.py "$BACKUP_DIR/core/compliance.py" 2>/dev/null || true
cp core/views.py "$BACKUP_DIR/core/views.py" 2>/dev/null || true
cp templates/home.html "$BACKUP_DIR/templates/home.html" 2>/dev/null || true
cp templates/manager_today.html "$BACKUP_DIR/templates/manager_today.html" 2>/dev/null || true
cp templates/payroll_problems.html "$BACKUP_DIR/templates/payroll_problems.html" 2>/dev/null || true
cp templates/manager_fix_day.html "$BACKUP_DIR/templates/manager_fix_day.html" 2>/dev/null || true

cat > core/compliance.py <<'PY'
from datetime import datetime, time, timedelta

from django.utils import timezone

from .models import Employee, ClockEvent, RosterShift


OPERATIONAL_DAY_START_HOUR = 5


def current_operational_date():
    local_now = timezone.localtime(timezone.now())
    if local_now.time() < time(OPERATIONAL_DAY_START_HOUR, 0):
        return local_now.date() - timedelta(days=1)
    return local_now.date()


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
    if worked_minutes > 360:
        return 30
    if worked_minutes > 270:
        return 15
    return 0


def operational_window(selected_date):
    start = timezone.make_aware(datetime.combine(selected_date, time(OPERATIONAL_DAY_START_HOUR, 0)))
    return start, start + timedelta(days=1)


def _local_hhmm(dt):
    if not dt:
        return "-"
    return timezone.localtime(dt).strftime("%H:%M")


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


def get_roster_info(employee, selected_date):
    shifts = RosterShift.objects.filter(employee=employee, shift_date=selected_date).order_by("start_time")
    rostered = shifts.exists()
    roster_text = "Not rostered"
    planned_start = None
    planned_end = None
    rostered_minutes = 0

    if rostered:
        parts = []
        for shift in shifts:
            parts.append(f"{shift.start_time.strftime('%H:%M')} - {shift.end_time.strftime('%H:%M')}")
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
    return ClockEvent.objects.filter(employee=employee, timestamp__gte=start, timestamp__lt=end).order_by("timestamp")


def build_break_status(worked_minutes, break_minutes, is_working, is_on_break, invalid_sequence=False):
    if invalid_sequence:
        return {
            "break_status": "Check clock events",
            "break_css": "break-urgent",
            "break_action": "Fix the clock times before payroll.",
            "required_break": required_break_minutes(worked_minutes),
        }

    required_break = required_break_minutes(worked_minutes)
    remaining_to_15 = max(0, 271 - worked_minutes)
    remaining_to_30 = max(0, 361 - worked_minutes)

    if is_on_break:
        return {
            "break_status": "On break now",
            "break_css": "break-on",
            "break_action": "No action unless break runs too long.",
            "required_break": required_break,
        }

    if required_break and break_minutes >= required_break:
        return {
            "break_status": "OK",
            "break_css": "break-ok",
            "break_action": "No action.",
            "required_break": required_break,
        }

    if worked_minutes > 360 and break_minutes < 30:
        return {
            "break_status": "30 min break overdue",
            "break_css": "break-urgent",
            "break_action": "Give or record the break.",
            "required_break": 30,
        }

    if worked_minutes > 270 and break_minutes < 15:
        return {
            "break_status": "15 min break overdue",
            "break_css": "break-urgent",
            "break_action": "Give or record the break.",
            "required_break": 15,
        }

    if is_working and worked_minutes >= 345 and break_minutes < 30:
        return {
            "break_status": f"30 min break due in {format_minutes(remaining_to_30)}",
            "break_css": "break-warn",
            "break_action": "Plan break soon.",
            "required_break": 30,
        }

    if is_working and worked_minutes >= 255 and break_minutes < 15:
        return {
            "break_status": f"15 min break due in {format_minutes(remaining_to_15)}",
            "break_css": "break-warn",
            "break_action": "Plan break soon.",
            "required_break": 15,
        }

    if is_working and worked_minutes >= 240 and break_minutes < 15:
        return {
            "break_status": f"Break in {format_minutes(remaining_to_15)}",
            "break_css": "break-warn",
            "break_action": "Plan break soon.",
            "required_break": 15,
        }

    return {
        "break_status": "OK for now",
        "break_css": "break-ok",
        "break_action": "No action.",
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
                worked_minutes += max(0, int((event.timestamp - work_start).total_seconds() / 60))
                work_start = None
            else:
                invalid_sequence = True
            if break_start is not None:
                invalid_sequence = True
            break_start = event.timestamp

        elif event.clock_type == "BREAK_END":
            if break_start is not None:
                break_minutes += max(0, int((event.timestamp - break_start).total_seconds() / 60))
                break_start = None
            else:
                invalid_sequence = True
            work_start = event.timestamp

        elif event.clock_type == "OUT":
            last_out = event.timestamp
            if work_start is not None:
                worked_minutes += max(0, int((event.timestamp - work_start).total_seconds() / 60))
                work_start = None
            elif break_start is not None:
                # A clock-out straight from break is usually a manager correction case.
                break_minutes += max(0, int((event.timestamp - break_start).total_seconds() / 60))
                break_start = None
                invalid_sequence = True
            else:
                invalid_sequence = True

    now = timezone.now()
    today = current_operational_date()
    currently_open_work = work_start is not None
    currently_open_break = break_start is not None

    if include_live and selected_date == today:
        if currently_open_work:
            worked_minutes += max(0, int((now - work_start).total_seconds() / 60))
        elif currently_open_break:
            break_minutes += max(0, int((now - break_start).total_seconds() / 60))

    if break_minutes > worked_minutes and worked_minutes < 60:
        invalid_sequence = True

    status = "No activity"
    if latest_event:
        status = {
            "IN": "Working now",
            "BREAK_START": "On break",
            "BREAK_END": "Working now",
            "OUT": "Finished",
        }.get(latest_event.clock_type, "No activity")

    is_working = bool(latest_event and latest_event.clock_type in ["IN", "BREAK_END"])
    is_on_break = bool(latest_event and latest_event.clock_type == "BREAK_START")
    is_clocked_out = bool(latest_event and latest_event.clock_type == "OUT")

    break_info = build_break_status(worked_minutes, break_minutes, is_working, is_on_break, invalid_sequence)
    required_break = break_info["required_break"]

    urgent_issues = []
    operational_issues = []

    if invalid_sequence:
        urgent_issues.append("Check clock events")

    if latest_event and not roster["rostered"]:
        urgent_issues.append("Unrostered shift")

    # Absent/late is a review item only. It is not shown as a top-card count.
    if roster["rostered"] and not latest_event and selected_date == today and roster["planned_start"]:
        planned_dt = _planned_start_dt(selected_date, roster["planned_start"])
        if now > planned_dt + timedelta(minutes=30):
            operational_issues.append("Absent")
        elif now > planned_dt + timedelta(minutes=10):
            operational_issues.append("Late")

    if is_working:
        if worked_minutes > 360 and break_minutes < 30:
            urgent_issues.append("30 min break overdue")
        elif worked_minutes > 270 and break_minutes < 15:
            urgent_issues.append("15 min break overdue")
        elif break_info["break_css"] == "break-warn":
            operational_issues.append(break_info["break_status"])

    if is_clocked_out and required_break > 0 and break_minutes < required_break:
        urgent_issues.append("Break missing or too short")

    if latest_event and latest_event.clock_type in ["IN", "BREAK_START", "BREAK_END"]:
        if selected_date < today:
            urgent_issues.append("Missing clock-out")
        elif worked_minutes > 14 * 60:
            urgent_issues.append("Very long open shift")

    if first_in and roster["planned_start"]:
        planned_start_dt = _planned_start_dt(selected_date, roster["planned_start"])
        planned_end_dt = _planned_end_dt(selected_date, roster["planned_start"], roster["planned_end"])
        late_minutes = int((first_in - planned_start_dt).total_seconds() / 60)
        if planned_end_dt and first_in > planned_end_dt:
            operational_issues.append("Clocked in after shift ended")
        elif late_minutes > 10:
            operational_issues.append(f"Late by {late_minutes} mins")
        elif late_minutes < -15:
            operational_issues.append(f"Clocked in {abs(late_minutes)} mins early")

    if worked_minutes > 12 * 60:
        operational_issues.append("Long shift")

    issue_type = "OK"
    issue_text = "OK"
    if urgent_issues:
        issue_type = "Urgent"
        issue_text = "; ".join(dict.fromkeys([x for x in urgent_issues if x]))
    elif operational_issues:
        issue_type = "Operational"
        issue_text = "; ".join(dict.fromkeys([x for x in operational_issues if x]))

    paid_minutes = max(0, worked_minutes)

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
        "missing_clock_out": bool(latest_event and latest_event.clock_type in ["IN", "BREAK_START", "BREAK_END"] and selected_date < today),
        "invalid_sequence": invalid_sequence,
    }


def get_day_rows(selected_date):
    return [calculate_employee_day(employee, selected_date, include_live=True) for employee in Employee.objects.filter(active=True).order_by("name")]


def get_payroll_problem_rows(week_start):
    rows = []
    for employee in Employee.objects.filter(active=True).order_by("name"):
        for i in range(7):
            day = week_start + timedelta(days=i)
            d = calculate_employee_day(employee, day, include_live=True)
            problems = []
            if d.get("missing_clock_out"):
                problems.append("Missing clock-out")
            if d.get("invalid_sequence"):
                problems.append("Check clock events")
            if d.get("is_urgent"):
                problems.append(d.get("issue"))
            if d.get("worked_minutes", 0) > 12 * 60:
                problems.append("Long shift")
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
    return [calculate_employee_week(employee, week_start, standard_hours) for employee in Employee.objects.filter(active=True).order_by("name")]
PY

cat > templates/home.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Restaurant Operations Dashboard</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 18px; color: #06152b; }
        .container { max-width: 1320px; margin: auto; }
        .header, .section { background: white; border: 1px solid #dde3ea; border-radius: 13px; padding: 22px; margin-bottom: 16px; }
        h1 { margin: 0 0 12px 0; font-size: 32px; }
        h2 { margin-top: 0; font-size: 25px; }
        .muted { color: #475467; }
        .actions { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 18px; }
        .button { display: inline-block; padding: 11px 16px; background: #4b5563; color: white; text-decoration: none; border-radius: 7px; font-weight: bold; }
        .button-primary { background: #2563eb; }
        .button-danger { background: #b42318; }
        .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 14px; margin: 18px 0; }
        .card { background: white; border: 1px solid #dde3ea; border-radius: 13px; padding: 18px; }
        .card-title { font-size: 15px; }
        .number { font-size: 36px; font-weight: bold; margin-top: 8px; color: #06152b; }
        .green { color: #087f3f; }
        .orange { color: #b7791f; }
        .red { color: #b42318; }
        table { width: 100%; border-collapse: collapse; margin-top: 12px; }
        th, td { border-bottom: 1px solid #dde3ea; padding: 11px 10px; text-align: left; vertical-align: top; }
        th { background: #f8fafc; }
        .badge { display: inline-block; padding: 5px 9px; border-radius: 999px; font-size: 13px; font-weight: bold; white-space: nowrap; }
        .badge-working, .break-ok { background: #dcfce7; color: #166534; }
        .badge-break, .break-on, .break-warn { background: #ffedd5; color: #9a3412; }
        .badge-out { background: #dbeafe; color: #1e40af; }
        .badge-missing, .break-urgent { background: #fee2e2; color: #991b1b; }
        .urgent { color: #b42318; font-weight: bold; }
        .operational { color: #b7791f; font-weight: bold; }
        .ok { color: #087f3f; font-weight: bold; }
        .small { font-size: 13px; color: #667085; margin-top: 5px; }
        .section-title-line { display: flex; justify-content: space-between; align-items: baseline; gap: 12px; flex-wrap: wrap; }
    </style>
</head>
<body>
<div class="container">
    <div class="header">
        <h1>Restaurant Operations Dashboard</h1>
        <p class="muted">Service day: {{ today|date:"F j, Y" }}. Current time: {{ now_time|date:"H:i" }}.</p>
        <div class="actions">
            <a class="button" href="/manager/upload-roster/">Roster Manager</a>
            <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Payroll</a>
            <a class="button" href="/admin/">Admin / Setup</a>
            <a class="button button-primary" href="/clock/">Staff Clocking</a>
        </div>
    </div>

    <div class="cards">
        <div class="card"><div class="card-title">👥 Working Now</div><div class="number green">{{ currently_working }}</div></div>
        <div class="card"><div class="card-title">☕ On Break Now</div><div class="number orange">{{ on_break }}</div></div>
        <div class="card"><div class="card-title">☕ Breaks Needing Action</div><div class="number {% if break_attention_count > 0 %}orange{% else %}green{% endif %}">{{ break_attention_count }}</div></div>
        <div class="card"><div class="card-title">⚠ Payroll Issues</div><div class="number {% if payroll_problem_count > 0 %}red{% else %}green{% endif %}">{{ payroll_problem_count }}</div></div>
    </div>

    <div class="section">
        <h2>Current Staff</h2>
        <p class="muted">Anyone still clocked in appears here, including late-night shifts from the same service day.</p>
        <table>
            <tr><th>Employee</th><th>Status</th><th>Roster</th><th>Clocked In</th><th>Worked</th><th>Break Taken</th><th>Break Status</th><th>Action</th><th>Issue</th></tr>
            {% for row in live_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{% if row.is_on_break %}<span class="badge badge-break">On Break</span>{% else %}<span class="badge badge-working">Working</span>{% endif %}</td>
                <td>{{ row.roster }}</td>
                <td>{{ row.first_in }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td>{{ row.break_minutes }} mins</td>
                <td><span class="badge {{ row.break_css }}">{{ row.break_status }}</span></td>
                <td>{{ row.break_action }}</td>
                <td class="{% if row.is_urgent %}urgent{% elif row.is_operational %}operational{% else %}ok{% endif %}">{{ row.issue }}</td>
            </tr>
            {% empty %}
            <tr><td colspan="9">No staff are currently clocked in or on break.</td></tr>
            {% endfor %}
        </table>
    </div>

    {% if break_attention_count > 0 %}
    <div class="section">
        <h2>Breaks Needing Action</h2>
        <table>
            <tr><th>Employee</th><th>Roster</th><th>Status</th><th>Worked</th><th>Break Taken</th><th>Break Status</th><th>Action</th></tr>
            {% for row in break_attention_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{{ row.roster }}</td>
                <td>{{ row.status }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td>{{ row.break_minutes }} mins</td>
                <td><span class="badge {{ row.break_css }}">{{ row.break_status }}</span></td>
                <td class="operational">{{ row.break_action }}</td>
            </tr>
            {% endfor %}
        </table>
    </div>
    {% endif %}

    <div class="section">
        <div class="section-title-line">
            <h2>Service Day Roster</h2>
            <span class="muted">Rostered: {{ rostered_count }}</span>
        </div>
        <p class="muted">Use this for review. Current staff and urgent actions are at the top.</p>
        <table>
            <tr><th>Employee</th><th>Roster</th><th>Status</th><th>Clocked In</th><th>Issue</th><th>Worked</th><th>Break</th><th>Break Status</th></tr>
            {% for row in roster_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{{ row.roster }}</td>
                <td>
                    {% if row.is_on_break %}<span class="badge badge-break">On Break</span>
                    {% elif row.is_working %}<span class="badge badge-working">Working</span>
                    {% elif row.has_activity %}<span class="badge badge-out">Finished</span>
                    {% elif row.is_operational %}<span class="badge badge-missing">{{ row.issue }}</span>
                    {% else %}<span class="badge badge-out">Due Later</span>{% endif %}
                </td>
                <td>{{ row.first_in }}</td>
                <td class="{% if row.is_urgent %}urgent{% elif row.is_operational %}operational{% else %}ok{% endif %}">{{ row.issue }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td>{{ row.break_minutes }} mins</td>
                <td><span class="badge {{ row.break_css }}">{{ row.break_status }}</span><div class="small">{{ row.break_action }}</div></td>
            </tr>
            {% empty %}
            <tr><td colspan="8">No roster or clock activity for this service day.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Payroll Status</h2>
        {% if payroll_problem_count > 0 %}
            <p class="urgent"><strong>Payroll is not ready.</strong> {{ payroll_problem_count }} issue(s) must be fixed before Sage export.</p>
            <a class="button button-danger" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Review Payroll Issues</a>
        {% else %}
            <p class="ok"><strong>Payroll looks ready</strong> for the current week.</p>
            <a class="button button-primary" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Open Weekly Payroll</a>
        {% endif %}
    </div>
</div>
</body>
</html>
HTML

cat > templates/manager_today.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Manager Dashboard</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 18px; color: #06152b; }
        .container { max-width: 1320px; margin: auto; }
        .header, .section { background: white; border: 1px solid #dde3ea; border-radius: 13px; padding: 22px; margin-bottom: 16px; }
        .muted { color: #475467; }
        .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 14px; margin: 18px 0; }
        .card { background: white; border: 1px solid #dde3ea; border-radius: 13px; padding: 18px; }
        .number { font-size: 36px; font-weight: bold; margin-top: 8px; }
        .green { color: #087f3f; } .orange { color: #b7791f; } .red { color: #b42318; }
        table { width: 100%; border-collapse: collapse; margin-top: 12px; }
        th, td { border-bottom: 1px solid #dde3ea; padding: 11px 10px; text-align: left; vertical-align: top; }
        th { background: #f8fafc; }
        .badge { display: inline-block; padding: 5px 9px; border-radius: 999px; font-size: 13px; font-weight: bold; white-space: nowrap; }
        .badge-working, .break-ok { background: #dcfce7; color: #166534; }
        .badge-break, .break-on, .break-warn { background: #ffedd5; color: #9a3412; }
        .badge-out { background: #dbeafe; color: #1e40af; }
        .badge-missing, .break-urgent { background: #fee2e2; color: #991b1b; }
        .urgent { color: #b42318; font-weight: bold; }
        .operational { color: #b7791f; font-weight: bold; }
        .ok { color: #087f3f; font-weight: bold; }
        .button { display: inline-block; padding: 10px 13px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 8px; margin-bottom: 8px; }
        .secondary { background: #4b5563; }
        input, button { padding: 8px; }
        .small { font-size: 13px; color: #667085; margin-top: 5px; }
    </style>
</head>
<body>
<div class="container">
    <div class="header">
        <h1>Manager Dashboard</h1>
        <p class="muted">Current staff and urgent actions first. Roster review is underneath.</p>
        <form method="get">Service Date: <input type="date" name="date" value="{{ selected_date|date:'Y-m-d' }}"> <button type="submit">View Date</button></form>
        <p><a class="button secondary" href="/">Home</a><a class="button secondary" href="/clock/">Staff Clocking</a><a class="button secondary" href="/manager/upload-roster/">Upload Roster</a></p>
    </div>

    <div class="cards">
        <div class="card"><div>👥 Working Now</div><div class="number green">{{ currently_working }}</div></div>
        <div class="card"><div>☕ On Break Now</div><div class="number orange">{{ on_break }}</div></div>
        <div class="card"><div>☕ Breaks Needing Action</div><div class="number {% if break_attention_count > 0 %}orange{% else %}green{% endif %}">{{ break_attention_count }}</div></div>
        <div class="card"><div>⚠ Payroll Issues</div><div class="number {% if payroll_issues_count > 0 %}red{% else %}green{% endif %}">{{ payroll_issues_count }}</div></div>
    </div>

    <div class="section">
        <h2>Current Staff</h2>
        <table>
            <tr><th>Employee</th><th>Status</th><th>Roster</th><th>Clocked In</th><th>Worked</th><th>Break Taken</th><th>Break Status</th><th>Action</th><th>Issue</th></tr>
            {% for row in live_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{% if row.is_on_break %}<span class="badge badge-break">On Break</span>{% else %}<span class="badge badge-working">Working</span>{% endif %}</td>
                <td>{{ row.roster }}</td><td>{{ row.first_in }}</td><td>{{ row.worked_hours }}h</td><td>{{ row.break_minutes }} mins</td>
                <td><span class="badge {{ row.break_css }}">{{ row.break_status }}</span></td>
                <td>{{ row.break_action }}</td>
                <td class="{% if row.is_urgent %}urgent{% elif row.is_operational %}operational{% else %}ok{% endif %}">{{ row.issue }}</td>
            </tr>
            {% empty %}<tr><td colspan="9">No staff are currently clocked in or on break.</td></tr>{% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Breaks Needing Action</h2>
        <table>
            <tr><th>Employee</th><th>Status</th><th>Worked</th><th>Break Taken</th><th>Break Status</th><th>Action</th></tr>
            {% for row in break_attention_rows %}
            <tr><td>{{ row.employee }}</td><td>{{ row.status }}</td><td>{{ row.worked_hours }}h</td><td>{{ row.break_minutes }} mins</td><td><span class="badge {{ row.break_css }}">{{ row.break_status }}</span></td><td class="operational">{{ row.break_action }}</td></tr>
            {% empty %}<tr><td colspan="6" class="ok">No break issues right now.</td></tr>{% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Service Day Roster Review</h2>
        <table>
            <tr><th>No</th><th>Employee</th><th>Roster</th><th>First In</th><th>Last Out</th><th>Status</th><th>Worked</th><th>Break</th><th>Break Status</th><th>Issue</th><th>Action</th></tr>
            {% for row in review_rows %}
            <tr>
                <td>{{ row.employee_number }}</td><td>{{ row.employee }}</td><td>{{ row.roster }}</td><td>{{ row.first_in }}</td><td>{{ row.last_out }}</td><td>{{ row.status }}</td><td>{{ row.worked_hours }}h</td><td>{{ row.break_minutes }} mins</td>
                <td><span class="badge {{ row.break_css }}">{{ row.break_status }}</span><div class="small">{{ row.break_action }}</div></td>
                <td class="{% if row.is_urgent %}urgent{% elif row.is_operational %}operational{% else %}ok{% endif %}">{{ row.issue }}</td>
                <td><a class="button secondary" href="/manager/fix-day/?employee_number={{ row.employee_number }}&event_date={{ row.date|date:'Y-m-d' }}">Fix / Edit</a></td>
            </tr>
            {% empty %}<tr><td colspan="11">No roster or clock activity for this date.</td></tr>{% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Payroll Status</h2>
        {% if payroll_issues_count > 0 %}
            <p class="urgent"><strong>Payroll is not ready.</strong> {{ payroll_issues_count }} issue(s) must be fixed before Sage export.</p>
            <a class="button" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Review Payroll Issues</a>
        {% else %}
            <p class="ok"><strong>Payroll looks ready</strong> for the week starting {{ week_start }}.</p>
            <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Open Weekly Summary</a>
        {% endif %}
    </div>
</div>
</body>
</html>
HTML

cat > templates/payroll_problems.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Payroll Issues</title>
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
<h1>Payroll Issues</h1>
<p>Fix these before Sage export.</p>

<form method="get">
    Week Start: <input type="date" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
    <button type="submit">View Week</button>
</form>

<h2>{{ week_start }} to {{ week_end }}</h2>

{% if problem_count == 0 %}
    <div class="ready"><strong>Payroll ready.</strong> No issues found for this week.</div>
{% else %}
    <div class="note"><strong>Payroll not ready: {{ problem_count }} issue(s) found.</strong></div>
{% endif %}

<table>
    <tr><th>Date</th><th>Employee</th><th>Roster</th><th>Status</th><th>Worked</th><th>Break Taken</th><th>Break Status</th><th>Problem</th><th>Action</th></tr>
    {% for row in rows %}
    <tr>
        <td>{{ row.date }}</td><td>{{ row.employee }}</td><td>{{ row.roster }}</td><td>{{ row.status }}</td><td>{{ row.worked_hours }}h</td><td>{{ row.break_minutes }} mins</td><td>{{ row.break_status }}</td><td class="warn">{{ row.problem }}</td>
        <td><a class="button fix" href="/manager/fix-day/?employee_number={{ row.employee_number }}&event_date={{ row.date|date:'Y-m-d' }}&week_start={{ week_start|date:'Y-m-d' }}">Fix / Edit</a></td>
    </tr>
    {% empty %}
    <tr><td colspan="9" class="ok">No issues found.</td></tr>
    {% endfor %}
</table>

<p>
    <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Summary</a>
    <a class="button secondary" href="/manager/today/">Manager Dashboard</a>
    <a class="button secondary" href="/">Home</a>
</p>
</div>
</body>
</html>
HTML

# Clean any broken Django template comment markers left by earlier patches.
python - <<'PY'
from pathlib import Path
for p in Path('templates').glob('*.html'):
    s = p.read_text()
    s = s.replace('{#', '').replace('#}', '')
    s = s.replace('Finished / Activity', 'Finished')
    s = s.replace('Working but not rostered', 'Unrostered shift')
    s = s.replace('No break needed yet', 'OK for now')
    p.write_text(s)
PY

cat >> core/views.py <<'PY'

# -------------------------------------------------------------------
# Delivery patch 30: manager-first current staff and synced payroll issues
# -------------------------------------------------------------------
from core.compliance import (
    current_operational_date as _dp30_current_operational_date,
    get_day_rows as _dp30_get_day_rows,
    payroll_is_ready as _dp30_payroll_is_ready,
)


def _dp30_week_start(day):
    return day - timedelta(days=day.weekday())


def _dp30_live_rows(rows):
    # Current Staff means people still clocked in now. Do not include old/finished issues here.
    return [row for row in rows if row.get("is_working") or row.get("is_on_break")]


def _dp30_break_attention_rows(rows):
    return [
        row for row in rows
        if (row.get("is_working") or row.get("is_on_break"))
        and row.get("break_css") in ["break-warn", "break-urgent"]
    ]


def _dp30_roster_rows(rows):
    return [row for row in rows if row.get("rostered") or row.get("has_activity")]


def home_page(request):
    today = _dp30_current_operational_date()
    week_start = _dp30_week_start(today)
    rows = _dp30_get_day_rows(today)
    live_rows = _dp30_live_rows(rows)
    break_attention_rows = _dp30_break_attention_rows(rows)
    roster_rows = _dp30_roster_rows(rows)
    payroll_ready_bool, payroll_problem_rows = _dp30_payroll_is_ready(week_start)

    return render(request, "home.html", {
        "today": today,
        "now_time": timezone.localtime(timezone.now()),
        "week_start": week_start,
        "rows": rows,
        "live_rows": live_rows,
        "break_attention_rows": break_attention_rows,
        "roster_rows": roster_rows,
        "currently_working": sum(1 for row in rows if row.get("is_working")),
        "on_break": sum(1 for row in rows if row.get("is_on_break")),
        "rostered_count": sum(1 for row in rows if row.get("rostered")),
        "break_attention_count": len(break_attention_rows),
        "payroll_problem_count": len(payroll_problem_rows),
        "payroll_ready": payroll_ready_bool,
    })


@_dp27_login_required
def manager_today_dashboard(request):
    default_date = _dp30_current_operational_date()
    selected_date_str = request.GET.get("date", default_date.strftime("%Y-%m-%d"))
    selected_date = datetime.strptime(selected_date_str, "%Y-%m-%d").date()
    week_start = _dp30_week_start(selected_date)
    rows = _dp30_get_day_rows(selected_date)
    live_rows = _dp30_live_rows(rows)
    break_attention_rows = _dp30_break_attention_rows(rows)
    review_rows = _dp30_roster_rows(rows)
    payroll_ready_bool, payroll_problem_rows = _dp30_payroll_is_ready(week_start)

    return render(request, "manager_today.html", {
        "selected_date": selected_date,
        "week_start": week_start,
        "rows": rows,
        "live_rows": live_rows,
        "break_attention_rows": break_attention_rows,
        "review_rows": review_rows,
        "currently_working": sum(1 for row in rows if row.get("is_working")),
        "on_break": sum(1 for row in rows if row.get("is_on_break")),
        "rostered_count": sum(1 for row in rows if row.get("rostered")),
        "break_attention_count": len(break_attention_rows),
        "payroll_issues_count": len(payroll_problem_rows),
        "payroll_ready": 100 if payroll_ready_bool else 0,
    })
PY

python -m py_compile core/compliance.py core/views.py
python - <<'PY'
from pathlib import Path
bad = []
for p in Path('templates').glob('*.html'):
    s = p.read_text()
    if '{#' in s or '#}' in s or 'Finished / Activity' in s or 'Late / Absent Now' in s:
        bad.append(str(p))
if bad:
    raise SystemExit('Template cleanup failed: ' + ', '.join(bad))
PY

echo "Patch 30 applied. Backup saved to $BACKUP_DIR"
echo "Current Staff now means still clocked in now. Top cards show only current/action items. Payroll pages use the same issue wording as the dashboard."
