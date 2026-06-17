#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-$(pwd)}"
cd "$APP_DIR"

STAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="backups_patch_33_${STAMP}"
mkdir -p "$BACKUP_DIR"

cp core/views.py "$BACKUP_DIR/views.py.bak"
cp templates/payroll_problems.html "$BACKUP_DIR/payroll_problems.html.bak"
cp templates/weekly_summary.html "$BACKUP_DIR/weekly_summary.html.bak"

cat >> core/views.py <<'PYCODE'

# -------------------------------------------------------------------
# Delivery patch 33: payroll quick fixes + manager-friendly weekly review status
# -------------------------------------------------------------------
from datetime import datetime as _dp33_datetime, timedelta as _dp33_timedelta
from django.contrib import messages as _dp33_messages
from django.shortcuts import redirect as _dp33_redirect
from core.models import RosterShift as _dp33_RosterShift, ClockEvent as _dp33_ClockEvent, Employee as _dp33_Employee
from core.compliance import calculate_employee_day as _dp33_calculate_employee_day
from core.compliance import current_operational_date as _dp33_current_operational_date


def _dp33_hours(minutes):
    return round((int(minutes or 0)) / 60, 2)


def _dp33_minutes_to_hours_label(minutes):
    minutes = int(minutes or 0)
    hours = minutes // 60
    mins = minutes % 60
    if hours and mins:
        return f"{hours}h {mins}m"
    if hours:
        return f"{hours}h"
    return f"{mins}m"


def _dp33_make_aware(day, clock_time):
    return timezone.make_aware(_dp33_datetime.combine(day, clock_time))


def _dp33_shift_datetimes(employee, day):
    shifts = list(_dp33_RosterShift.objects.filter(employee=employee, shift_date=day).order_by("start_time"))
    if not shifts:
        return None
    first = shifts[0]
    last = shifts[-1]
    start_dt = _dp33_make_aware(day, first.start_time)
    end_dt = _dp33_make_aware(day, last.end_time)
    if end_dt <= start_dt:
        end_dt += _dp33_timedelta(days=1)
    return {
        "start": start_dt,
        "end": end_dt,
        "start_label": start_dt.strftime("%H:%M"),
        "end_label": end_dt.strftime("%H:%M"),
        "roster_label": f"{first.start_time.strftime('%H:%M')} - {last.end_time.strftime('%H:%M')}",
    }


def _dp33_has_clock(employee, day, clock_type):
    start, end = operational_window(day)
    return _dp33_ClockEvent.objects.filter(employee=employee, timestamp__gte=start, timestamp__lt=end, clock_type=clock_type).exists()


def _dp33_create_manager_event(employee, clock_type, timestamp, note):
    return _dp33_ClockEvent.objects.create(
        employee=employee,
        clock_type=clock_type,
        timestamp=timestamp,
        method="MANAGER",
        notes=f"Manager quick fix: {note}",
    )


def _dp33_apply_quick_fix(request):
    mode = request.POST.get("mode")
    employee_number = request.POST.get("employee_number")
    day_raw = request.POST.get("event_date")
    week_start = request.POST.get("week_start") or ""
    employee = _patch_get_object_or_404(_dp33_Employee, employee_number=employee_number)
    day = _dp33_datetime.strptime(day_raw, "%Y-%m-%d").date()
    shift = _dp33_shift_datetimes(employee, day)

    try:
        if mode == "use_roster_start":
            if not shift:
                _dp33_messages.error(request, "No roster start time found for this shift.")
            elif _dp33_has_clock(employee, day, "IN"):
                _dp33_messages.info(request, f"{employee.name} already has a clock-in for this day.")
            else:
                _dp33_create_manager_event(employee, "IN", shift["start"], f"used roster start {shift['start_label']}")
                _dp33_messages.success(request, f"Added clock-in for {employee.name} at roster start {shift['start_label']}.")

        elif mode == "use_roster_finish":
            if not shift:
                _dp33_messages.error(request, "No roster finish time found for this shift.")
            elif _dp33_has_clock(employee, day, "OUT"):
                _dp33_messages.info(request, f"{employee.name} already has a clock-out for this day.")
            else:
                _dp33_create_manager_event(employee, "OUT", shift["end"], f"used roster finish {shift['end_label']}")
                _dp33_messages.success(request, f"Added clock-out for {employee.name} at roster finish {shift['end_label']}.")

        elif mode == "use_roster_shift":
            if not shift:
                _dp33_messages.error(request, "No roster shift found for this employee on this day.")
            else:
                added = []
                if not _dp33_has_clock(employee, day, "IN"):
                    _dp33_create_manager_event(employee, "IN", shift["start"], f"used roster shift start {shift['start_label']}")
                    added.append(f"in {shift['start_label']}")
                if not _dp33_has_clock(employee, day, "OUT"):
                    _dp33_create_manager_event(employee, "OUT", shift["end"], f"used roster shift finish {shift['end_label']}")
                    added.append(f"out {shift['end_label']}")
                if added:
                    _dp33_messages.success(request, f"Added {employee.name}: " + ", ".join(added) + ".")
                else:
                    _dp33_messages.info(request, f"{employee.name} already has clock-in and clock-out records for this day.")

        elif mode == "enter_actual_time":
            clock_type = request.POST.get("clock_type")
            actual_time = request.POST.get("actual_time")
            if clock_type not in ["IN", "OUT"]:
                _dp33_messages.error(request, "Choose clock-in or clock-out.")
            elif not actual_time:
                _dp33_messages.error(request, "Enter the actual time.")
            else:
                target_dt = _dp33_make_aware(day, _dp33_datetime.strptime(actual_time, "%H:%M").time())
                if shift and clock_type == "OUT" and target_dt <= shift["start"]:
                    target_dt += _dp33_timedelta(days=1)
                _dp33_create_manager_event(employee, clock_type, target_dt, f"entered actual {clock_type.lower()} time {actual_time}")
                label = "clock-in" if clock_type == "IN" else "clock-out"
                _dp33_messages.success(request, f"Added {label} for {employee.name} at {actual_time}.")

        else:
            _dp33_messages.error(request, "Unknown quick fix.")

    except Exception as exc:
        _dp33_messages.error(request, f"Could not apply quick fix: {exc}")

    return _dp33_redirect(f"/manager/payroll-problems/?week_start={week_start}")


def _dp33_payroll_problem_rows(week_start):
    rows = []
    today = _dp33_current_operational_date()
    for employee in _dp33_Employee.objects.filter(active=True).order_by("name"):
        for i in range(7):
            day = week_start + _dp33_timedelta(days=i)
            if day > today:
                continue
            d = _dp33_calculate_employee_day(employee, day, include_live=True)
            shift = _dp33_shift_datetimes(employee, day)
            problems = []
            quick = []

            if d.get("rostered") and not d.get("has_activity") and day < today:
                problems.append("No clock records")
                if shift:
                    quick.append({"mode": "use_roster_shift", "label": f"Use roster {shift['roster_label']}"})
                    quick.append({"mode": "enter_actual_time", "label": "Enter actual times", "clock_type": "IN"})

            if d.get("missing_clock_out"):
                problems.append("Missing clock-out")
                if shift:
                    quick.append({"mode": "use_roster_finish", "label": f"Use finish {shift['end_label']}"})
                quick.append({"mode": "enter_actual_time", "label": "Enter actual finish", "clock_type": "OUT"})

            if d.get("invalid_sequence"):
                problems.append("Check clock events")

            if d.get("is_urgent"):
                for part in str(d.get("issue") or "").split(";"):
                    part = part.strip()
                    if part:
                        problems.append(part)

            if d.get("worked_minutes", 0) > 12 * 60:
                problems.append("Long shift")

            if d.get("has_activity") and not d.get("rostered"):
                problems.append("Unrostered shift")

            # Remove duplicates while keeping order.
            problems = list(dict.fromkeys([p for p in problems if p and p != "OK"]))
            if not problems:
                continue

            if not quick:
                quick.append({"mode": "advanced", "label": "Advanced edit"})

            rows.append({
                "date": day,
                "employee_number": employee.employee_number,
                "employee": employee.name,
                "roster": d.get("roster"),
                "status": d.get("status"),
                "worked_hours": d.get("worked_hours"),
                "break_minutes": d.get("break_minutes"),
                "break_status": d.get("break_status"),
                "problem": "; ".join(problems),
                "quick_actions": quick,
            })
    return rows


@_dp31_login_required
def payroll_problems(request):
    if request.method == "POST":
        return _dp33_apply_quick_fix(request)

    week_start = _patch_parse_week_start(request)
    week_end = week_start + _dp33_timedelta(days=6)
    rows = _dp33_payroll_problem_rows(week_start)
    return render(request, "payroll_problems.html", {
        "week_start": week_start,
        "week_end": week_end,
        "rows": rows,
        "problem_count": len(rows),
    })


def _dp33_weekly_rows(week_start, standard_hours):
    raw_rows = _patch_get_week_rows(week_start, standard_hours)
    current_day = _dp33_current_operational_date()
    week_end = week_start + _dp33_timedelta(days=6)
    problem_rows = _dp33_payroll_problem_rows(week_start)
    problem_map = {}
    for problem in problem_rows:
        problem_map.setdefault(problem["employee_number"], []).append(f"{problem['date'].strftime('%a')}: {problem['problem']}")

    for row in raw_rows:
        rostered_minutes = int(float(row.get("rostered_hours", 0) or 0) * 60)
        paid_minutes = int(row.get("paid_minutes", 0) or 0)
        difference_minutes = paid_minutes - rostered_minutes
        problems = problem_map.get(row.get("employee_number"), [])
        future_rostered = week_end >= current_day and rostered_minutes > paid_minutes and current_day <= week_end

        if problems:
            row["review_status"] = "Review"
            row["review_reason"] = "; ".join(problems[:3])
            row["status_css"] = "warn"
        elif week_start <= current_day <= week_end and future_rostered:
            row["review_status"] = "In progress"
            row["review_reason"] = "Week not finished"
            row["status_css"] = "progress"
        elif rostered_minutes > 0 and paid_minutes == 0:
            row["review_status"] = "Review"
            row["review_reason"] = "Rostered but no paid hours"
            row["status_css"] = "warn"
        elif abs(difference_minutes) > 4 * 60:
            row["review_status"] = "Review"
            row["review_reason"] = f"Variance {_dp33_minutes_to_hours_label(abs(difference_minutes))}"
            row["status_css"] = "warn"
        elif abs(difference_minutes) > 60:
            row["review_status"] = "Check"
            row["review_reason"] = f"Variance {_dp33_minutes_to_hours_label(abs(difference_minutes))}"
            row["status_css"] = "check"
        else:
            row["review_status"] = "OK"
            row["review_reason"] = ""
            row["status_css"] = "ok"

    return raw_rows


@_dp31_login_required
def manager_weekly_summary(request):
    week_start = _patch_parse_week_start(request)
    week_end = week_start + _dp33_timedelta(days=6)
    standard_hours = float(request.GET.get("standard_hours", "39"))
    period_number = request.GET.get("period", "1")
    summary_rows = _dp33_weekly_rows(week_start, standard_hours)
    summary_rows, export_rows = _dp31_add_export_strings(summary_rows)
    payroll_issue_rows = _dp33_payroll_problem_rows(week_start)
    payroll_ready_bool = len(payroll_issue_rows) == 0

    totals = {
        "rostered": round(sum(float(r.get("rostered_hours", 0) or 0) for r in summary_rows), 2),
        "paid": round(sum(float(r.get("paid_hours", 0) or 0) for r in summary_rows), 2),
        "normal": round(sum(float(r.get("normal_hours", 0) or 0) for r in summary_rows), 2),
        "sunday": round(sum(float(r.get("sunday_hours", 0) or 0) for r in summary_rows), 2),
        "overtime": round(sum(float(r.get("overtime_hours", 0) or 0) for r in summary_rows), 2),
    }

    return render(request, "weekly_summary.html", {
        "week_start": week_start,
        "week_end": week_end,
        "summary_rows": summary_rows,
        "export_rows": export_rows,
        "standard_hours": standard_hours,
        "period_number": period_number,
        "payroll_problem_count": len(payroll_issue_rows),
        "payroll_ready": payroll_ready_bool,
        "totals": totals,
    })
PYCODE

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
        .button { display: inline-block; padding: 10px 13px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 8px; margin-bottom: 8px; border:0; cursor:pointer; }
        .secondary { background: #4b5563; }
        .fix { background: #b45309; }
        .smallfix { padding: 7px 10px; font-size: 13px; }
        input, button { padding: 8px; }
        .note { background: #fffbeb; border-left: 4px solid #f59e0b; padding: 10px; margin: 12px 0; }
        .ready { background:#f0fdf4; border-left:4px solid #22c55e; padding:12px; margin:12px 0; }
        .messages { margin: 12px 0; }
        .msg { padding: 10px; border-radius: 8px; margin-bottom: 8px; background:#eef2ff; }
        .quick-row { display:flex; flex-wrap:wrap; gap:6px; align-items:center; }
        .actual-form { display:inline-flex; gap:6px; align-items:center; margin-top:6px; }
        .advanced { font-size:13px; color:#4b5563; }
    </style>
</head>
<body>
<div class="container">
<h1>Payroll Issues</h1>
<p>Fix the common payroll issues here. Use the roster time when that is correct, or enter the actual time.</p>

{% if messages %}
<div class="messages">
    {% for message in messages %}<div class="msg">{{ message }}</div>{% endfor %}
</div>
{% endif %}

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
    <tr><th>Date</th><th>Employee</th><th>Roster</th><th>Status</th><th>Worked</th><th>Problem</th><th>Quick Fix</th></tr>
    {% for row in rows %}
    <tr>
        <td>{{ row.date }}</td>
        <td>{{ row.employee }}</td>
        <td>{{ row.roster }}</td>
        <td>{{ row.status }}</td>
        <td>{{ row.worked_hours }}h</td>
        <td class="warn">{{ row.problem }}</td>
        <td>
            <div class="quick-row">
            {% for action in row.quick_actions %}
                {% if action.mode == 'advanced' %}
                    <a class="advanced" href="/manager/fix-day/?employee_number={{ row.employee_number }}&event_date={{ row.date|date:'Y-m-d' }}&week_start={{ week_start|date:'Y-m-d' }}">Advanced edit</a>
                {% elif action.mode == 'enter_actual_time' %}
                    <form class="actual-form" method="post">
                        {% csrf_token %}
                        <input type="hidden" name="mode" value="enter_actual_time">
                        <input type="hidden" name="employee_number" value="{{ row.employee_number }}">
                        <input type="hidden" name="event_date" value="{{ row.date|date:'Y-m-d' }}">
                        <input type="hidden" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
                        <input type="hidden" name="clock_type" value="{{ action.clock_type }}">
                        <input type="time" name="actual_time" required>
                        <button class="button fix smallfix" type="submit">{{ action.label }}</button>
                    </form>
                {% else %}
                    <form method="post" style="display:inline;">
                        {% csrf_token %}
                        <input type="hidden" name="mode" value="{{ action.mode }}">
                        <input type="hidden" name="employee_number" value="{{ row.employee_number }}">
                        <input type="hidden" name="event_date" value="{{ row.date|date:'Y-m-d' }}">
                        <input type="hidden" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
                        <button class="button fix smallfix" type="submit">{{ action.label }}</button>
                    </form>
                {% endif %}
            {% endfor %}
            <a class="advanced" href="/manager/fix-day/?employee_number={{ row.employee_number }}&event_date={{ row.date|date:'Y-m-d' }}&week_start={{ week_start|date:'Y-m-d' }}">Advanced edit</a>
            </div>
        </td>
    </tr>
    {% empty %}
    <tr><td colspan="7" class="ok">No issues found.</td></tr>
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

cat > templates/weekly_summary.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Weekly Payroll Summary</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #222; }
        .container { max-width: 1280px; margin: auto; background: white; padding: 24px; border-radius: 14px; border: 1px solid #e5e7eb; }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 10px; text-align: left; vertical-align: top; }
        th { background: #f9fafb; }
        .ok { color: #1a7f37; font-weight: bold; }
        .warn { color: #b42318; font-weight: bold; }
        .check { color: #b45309; font-weight: bold; }
        .progress { color: #2563eb; font-weight: bold; }
        .note { background:#eff6ff; border-left:4px solid #2563eb; padding:12px; margin:12px 0; }
        .block { background:#fffbeb; border-left:4px solid #f59e0b; padding:12px; margin:12px 0; }
        .button { display: inline-block; padding: 10px 13px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 8px; margin-bottom: 8px; }
        .secondary { background: #4b5563; }
        .disabled { background: #9ca3af; cursor: not-allowed; }
        input, button { padding: 8px; }
        .small { color:#667085; font-size:13px; }
        .cards { display:grid; grid-template-columns: repeat(5, minmax(130px, 1fr)); gap:12px; margin:16px 0; }
        .card { border:1px solid #e5e7eb; border-radius:10px; padding:12px; background:#f9fafb; }
        .card strong { display:block; font-size:22px; margin-top:4px; }
    </style>
</head>
<body>

<div class="container">

<h1>Weekly Payroll Summary</h1>
<p>Review exceptions first. When there are no payroll issues, download the Sage CSV.</p>

<form method="get">
    Week Start:
    <input type="date" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
    Standard Weekly Hours:
    <input type="number" step="0.5" name="standard_hours" value="{{ standard_hours }}">
    Period:
    <input type="number" name="period" value="{{ period_number }}" style="width:70px;">
    <button type="submit">View Week</button>
</form>

<h2>{{ week_start }} to {{ week_end }}</h2>

<div class="cards">
    <div class="card">Rostered<strong>{{ totals.rostered }}</strong></div>
    <div class="card">Paid Hours<strong>{{ totals.paid }}</strong></div>
    <div class="card">Normal<strong>{{ totals.normal }}</strong></div>
    <div class="card">Sunday<strong>{{ totals.sunday }}</strong></div>
    <div class="card">Overtime<strong>{{ totals.overtime }}</strong></div>
</div>

{% if payroll_problem_count and payroll_problem_count > 0 %}
<div class="block">
    <strong>Payroll not ready: {{ payroll_problem_count }} issue(s) found.</strong>
    <a href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Fix Payroll Issues</a>
</div>
{% else %}
<div class="note"><strong>Payroll ready.</strong> No blocking issues found for this week.</div>
{% endif %}

<p>
    {% if payroll_problem_count and payroll_problem_count > 0 %}
        <span class="button disabled">Download Sage CSV</span>
    {% else %}
        <a class="button" href="/manager/export-sage-payroll/?week_start={{ week_start|date:'Y-m-d' }}&period={{ period_number }}&standard_hours={{ standard_hours }}">
            Download Sage CSV
        </a>
    {% endif %}
</p>

<h2>Weekly Review</h2>
<table>
    <tr>
        <th>Employee No</th>
        <th>Employee</th>
        <th>Rostered</th>
        <th>Worked</th>
        <th>Unpaid Breaks</th>
        <th>Paid Hours</th>
        <th>Normal</th>
        <th>Sunday</th>
        <th>Overtime</th>
        <th>Difference</th>
        <th>Status</th>
    </tr>

    {% for row in summary_rows %}
    <tr>
        <td>{{ row.employee_number }}</td>
        <td>{{ row.employee }}</td>
        <td>{{ row.rostered_hours }}</td>
        <td>{{ row.worked_hours }}</td>
        <td>{{ row.break_hours }}</td>
        <td>{{ row.paid_hours }}</td>
        <td>{{ row.normal_hours }}</td>
        <td>{{ row.sunday_hours }}</td>
        <td>{{ row.overtime_hours }}</td>
        <td>{{ row.difference }}</td>
        <td class="{{ row.status_css }}">
            {{ row.review_status }}
            {% if row.review_reason %}<div class="small">{{ row.review_reason }}</div>{% endif %}
        </td>
    </tr>
    {% endfor %}
</table>

<h2>Sage Export Preview</h2>
<p class="small">Sage receives: Period, Employee No, 0000, Normal Hours, Sunday Hours, Overtime Hours. Hours are decimal: 7h 13m exports as 7.22.</p>
<table>
    <tr>
        <th>Period</th>
        <th>Employee No</th>
        <th>Code</th>
        <th>Normal</th>
        <th>Sunday</th>
        <th>Overtime</th>
        <th>Employee</th>
    </tr>
    {% for row in export_rows %}
    <tr>
        <td>{{ period_number }}</td>
        <td>{{ row.employee_number }}</td>
        <td>0000</td>
        <td>{{ row.normal_export }}</td>
        <td>{{ row.sunday_export }}</td>
        <td>{{ row.overtime_export }}</td>
        <td>{{ row.employee }}</td>
    </tr>
    {% empty %}
    <tr><td colspan="7">No paid hours to export for this week.</td></tr>
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

python - <<'PY'
from pathlib import Path
text = Path('core/views.py').read_text()
compile(text, 'core/views.py', 'exec')
print('Python syntax check passed.')
PY

python - <<'PY'
from pathlib import Path
for f in ['templates/payroll_problems.html', 'templates/weekly_summary.html']:
    s = Path(f).read_text()
    # Simple balance checks for template tags used in this patch.
    if s.count('{% if') != s.count('{% endif %}'):
        raise SystemExit(f'{f}: if/endif mismatch')
    if s.count('{% for') != s.count('{% endfor %}'):
        raise SystemExit(f'{f}: for/endfor mismatch')
print('Template block check passed.')
PY

echo "Patch 33 applied. Backup saved to $BACKUP_DIR"
echo "Added roster-based quick fixes for payroll issues and clearer Weekly Review statuses."
