#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-$(pwd)}"
cd "$APP_DIR"

STAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="backups_patch_36_${STAMP}"
mkdir -p "$BACKUP_DIR"

cp core/views.py "$BACKUP_DIR/views.py.bak"
cp templates/payroll_problems.html "$BACKUP_DIR/payroll_problems.html.bak" 2>/dev/null || true
cp templates/weekly_summary.html "$BACKUP_DIR/weekly_summary.html.bak" 2>/dev/null || true

cat >> core/views.py <<'PYCODE'

# -------------------------------------------------------------------
# Delivery patch 36: manager-first payroll quick fixes
# -------------------------------------------------------------------
from datetime import datetime as _dp36_datetime, timedelta as _dp36_timedelta, time as _dp36_time
from django.contrib import messages as _dp36_messages
from django.shortcuts import redirect as _dp36_redirect
from django.utils import timezone as _dp36_timezone
from core.models import Employee as _dp36_Employee, ClockEvent as _dp36_ClockEvent, RosterShift as _dp36_RosterShift
from core.compliance import calculate_employee_day as _dp36_calculate_employee_day


def _dp36_parse_day(day_raw):
    return _dp36_datetime.strptime(day_raw, "%Y-%m-%d").date()


def _dp36_make_aware(day, clock_time):
    return _dp36_timezone.make_aware(_dp36_datetime.combine(day, clock_time))


def _dp36_service_window(day):
    """Restaurant service day: 05:00 to 05:00 next day."""
    start = _dp36_timezone.make_aware(_dp36_datetime.combine(day, _dp36_time(5, 0)))
    end = start + _dp36_timedelta(days=1)
    return start, end


def _dp36_events(employee, day):
    start, end = _dp36_service_window(day)
    return list(_dp36_ClockEvent.objects.filter(employee=employee, timestamp__gte=start, timestamp__lt=end).order_by("timestamp"))


def _dp36_has_event(employee, day, clock_type):
    start, end = _dp36_service_window(day)
    return _dp36_ClockEvent.objects.filter(employee=employee, timestamp__gte=start, timestamp__lt=end, clock_type=clock_type).exists()


def _dp36_roster_shift(employee, day):
    shifts = list(_dp36_RosterShift.objects.filter(employee=employee, shift_date=day).order_by("start_time"))
    if not shifts:
        return None
    first = shifts[0]
    last = shifts[-1]
    start_dt = _dp36_make_aware(day, first.start_time)
    end_dt = _dp36_make_aware(day, last.end_time)
    if end_dt <= start_dt:
        end_dt += _dp36_timedelta(days=1)
    minutes = int((end_dt - start_dt).total_seconds() // 60)
    return {
        "start": start_dt,
        "end": end_dt,
        "start_label": first.start_time.strftime("%H:%M"),
        "end_label": last.end_time.strftime("%H:%M"),
        "label": f"{first.start_time.strftime('%H:%M')} - {last.end_time.strftime('%H:%M')}",
        "hours_label": f"{round(minutes / 60, 2)}h",
        "break_minutes": getattr(first, "break_minutes", 0) or 0,
    }


def _dp36_create_event(employee, clock_type, timestamp, note):
    return _dp36_ClockEvent.objects.create(
        employee=employee,
        clock_type=clock_type,
        timestamp=timestamp,
        method="MANAGER",
        notes=f"Manager quick fix: {note}",
    )


def _dp36_first_in_last_out(employee, day):
    events = _dp36_events(employee, day)
    ins = [e for e in events if e.clock_type == "IN"]
    outs = [e for e in events if e.clock_type == "OUT"]
    return (ins[0] if ins else None), (outs[-1] if outs else None)


def _dp36_apply_quick_fix(request):
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
                _dp36_messages.error(request, "No roster shift found for this employee.")
            else:
                added = []
                if not _dp36_has_event(employee, day, "IN"):
                    _dp36_create_event(employee, "IN", shift["start"], f"paid roster shift start {shift['start_label']}")
                    added.append(f"clock-in {shift['start_label']}")
                if not _dp36_has_event(employee, day, "OUT"):
                    _dp36_create_event(employee, "OUT", shift["end"], f"paid roster shift finish {shift['end_label']}")
                    added.append(f"clock-out {shift['end_label']}")
                if added:
                    _dp36_messages.success(request, f"{employee.name}: roster shift used for payroll ({shift['label']}).")
                else:
                    _dp36_messages.info(request, f"{employee.name}: roster shift already has clock records.")

        elif mode == "clock_out_roster_finish":
            if not shift:
                _dp36_messages.error(request, "No roster finish time found for this shift.")
            elif _dp36_has_event(employee, day, "OUT"):
                _dp36_messages.info(request, f"{employee.name} already has a clock-out for this day.")
            else:
                _dp36_create_event(employee, "OUT", shift["end"], f"clocked out at roster finish {shift['end_label']}")
                _dp36_messages.success(request, f"{employee.name}: clock-out added at {shift['end_label']}.")

        elif mode == "enter_actual_finish":
            actual_time = request.POST.get("actual_time")
            if not actual_time:
                _dp36_messages.error(request, "Enter the finish time.")
            else:
                target_dt = _dp36_make_aware(day, _dp36_datetime.strptime(actual_time, "%H:%M").time())
                if shift and target_dt <= shift["start"]:
                    target_dt += _dp36_timedelta(days=1)
                _dp36_create_event(employee, "OUT", target_dt, f"entered actual finish {actual_time}")
                _dp36_messages.success(request, f"{employee.name}: clock-out added at {actual_time}.")

        elif mode == "enter_actual_shift":
            start_time = request.POST.get("start_time")
            finish_time = request.POST.get("finish_time")
            if not start_time or not finish_time:
                _dp36_messages.error(request, "Enter both start and finish times.")
            else:
                start_dt = _dp36_make_aware(day, _dp36_datetime.strptime(start_time, "%H:%M").time())
                finish_dt = _dp36_make_aware(day, _dp36_datetime.strptime(finish_time, "%H:%M").time())
                if finish_dt <= start_dt:
                    finish_dt += _dp36_timedelta(days=1)
                if not _dp36_has_event(employee, day, "IN"):
                    _dp36_create_event(employee, "IN", start_dt, f"entered actual start {start_time}")
                if not _dp36_has_event(employee, day, "OUT"):
                    _dp36_create_event(employee, "OUT", finish_dt, f"entered actual finish {finish_time}")
                _dp36_messages.success(request, f"{employee.name}: actual shift added ({start_time} - {finish_time}).")

        elif mode == "approve_unrostered_shift":
            first_in, last_out = _dp36_first_in_last_out(employee, day)
            if not first_in or not last_out:
                _dp36_messages.error(request, "This shift needs a start and finish time before it can be approved.")
            elif _dp36_RosterShift.objects.filter(employee=employee, shift_date=day).exists():
                _dp36_messages.info(request, f"{employee.name} already has a roster shift for this day.")
            else:
                start_time = _dp36_timezone.localtime(first_in.timestamp).time().replace(second=0, microsecond=0)
                finish_time = _dp36_timezone.localtime(last_out.timestamp).time().replace(second=0, microsecond=0)
                _dp36_RosterShift.objects.create(
                    employee=employee,
                    shift_date=day,
                    start_time=start_time,
                    end_time=finish_time,
                    break_minutes=0,
                )
                _dp36_messages.success(request, f"{employee.name}: unrostered shift approved for payroll.")

        else:
            _dp36_messages.error(request, "Unknown quick fix.")

    except Exception as exc:
        _dp36_messages.error(request, f"Could not apply quick fix: {exc}")

    return _dp36_redirect(f"/manager/payroll-problems/?week_start={week_start}")


def _dp36_payroll_problem_rows(week_start):
    rows = []
    today = _dp33_current_operational_date() if "_dp33_current_operational_date" in globals() else _dp36_timezone.localdate()

    for employee in _dp36_Employee.objects.filter(active=True).order_by("name"):
        for i in range(7):
            day = week_start + _dp36_timedelta(days=i)
            if day > today:
                continue

            d = _dp36_calculate_employee_day(employee, day, include_live=True)
            shift = _dp36_roster_shift(employee, day)
            problems = []
            quick = []

            # True payroll blockers only. Break warnings are not payroll blockers.
            if d.get("rostered") and not d.get("has_activity") and day < today:
                problems.append("No clock records")
                if shift:
                    quick.append({"mode": "pay_roster_shift", "label": f"Pay roster shift ({shift['label']})"})
                    quick.append({"mode": "enter_actual_shift", "label": "Enter actual times"})

            if d.get("missing_clock_out"):
                problems.append("Missing clock-out")
                if shift:
                    quick.append({"mode": "clock_out_roster_finish", "label": f"Clock out at {shift['end_label']}"})
                quick.append({"mode": "enter_actual_finish", "label": "Enter finish"})

            if d.get("invalid_sequence"):
                problems.append("Check clock events")

            if d.get("worked_minutes", 0) > 12 * 60:
                problems.append("Long shift")

            if d.get("has_activity") and not d.get("rostered"):
                problems.append("Unrostered shift")
                first_in, last_out = _dp36_first_in_last_out(employee, day)
                if first_in and last_out and not d.get("invalid_sequence"):
                    quick.append({"mode": "approve_unrostered_shift", "label": "Approve shift"})

            # Remove duplicates and ignore break/compliance warnings on the payroll blocker page.
            cleaned = []
            for p in problems:
                if not p or p == "OK":
                    continue
                if "break" in p.lower():
                    continue
                if p not in cleaned:
                    cleaned.append(p)
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


@_dp31_login_required
def payroll_problems(request):
    if request.method == "POST":
        return _dp36_apply_quick_fix(request)

    week_start = _patch_parse_week_start(request)
    week_end = week_start + _dp36_timedelta(days=6)
    rows = _dp36_payroll_problem_rows(week_start)
    return render(request, "payroll_problems.html", {
        "week_start": week_start,
        "week_end": week_end,
        "rows": rows,
        "problem_count": len(rows),
    })


def _dp36_weekly_rows(week_start, standard_hours):
    raw_rows = _patch_get_week_rows(week_start, standard_hours)
    current_day = _dp33_current_operational_date() if "_dp33_current_operational_date" in globals() else _dp36_timezone.localdate()
    week_end = week_start + _dp36_timedelta(days=6)
    problem_rows = _dp36_payroll_problem_rows(week_start)
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
        elif rostered_minutes > 0 and paid_minutes == 0 and week_end < current_day:
            row["review_status"] = "Review"
            row["review_reason"] = "Rostered but no paid hours"
            row["status_css"] = "warn"
        elif abs(difference_minutes) > 4 * 60 and week_end < current_day:
            row["review_status"] = "Review"
            row["review_reason"] = f"Variance {_dp33_minutes_to_hours_label(abs(difference_minutes)) if '_dp33_minutes_to_hours_label' in globals() else round(abs(difference_minutes)/60,2)}"
            row["status_css"] = "warn"
        elif abs(difference_minutes) > 60 and week_end < current_day:
            row["review_status"] = "Check"
            row["review_reason"] = f"Variance {_dp33_minutes_to_hours_label(abs(difference_minutes)) if '_dp33_minutes_to_hours_label' in globals() else round(abs(difference_minutes)/60,2)}"
            row["status_css"] = "check"
        else:
            row["review_status"] = "OK"
            row["review_reason"] = ""
            row["status_css"] = "ok"
    return raw_rows


@_dp31_login_required
def manager_weekly_summary(request):
    week_start = _patch_parse_week_start(request)
    week_end = week_start + _dp36_timedelta(days=6)
    standard_hours = float(request.GET.get("standard_hours", "39"))
    period_number = request.GET.get("period", "1")
    summary_rows = _dp36_weekly_rows(week_start, standard_hours)
    summary_rows, export_rows = _dp31_add_export_strings(summary_rows)
    payroll_issue_rows = _dp36_payroll_problem_rows(week_start)
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
        .quick-row { display:flex; flex-wrap:wrap; gap:8px; align-items:center; }
        .actual-form { display:inline-flex; gap:6px; align-items:center; margin-top:6px; }
        .advanced { font-size:13px; color:#4b5563; }
        .help { color:#667085; font-size:14px; }
    </style>
</head>
<body>
<div class="container">
<h1>Payroll Issues</h1>
<p>Fix the common payroll issues here. When you click a quick fix, the issue should disappear from this list.</p>

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
    <div class="ready"><strong>Payroll ready.</strong> No payroll issues found for this week.</div>
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
                    <a class="advanced" href="/manager/fix-day/?employee_number={{ row.employee_number }}&event_date={{ row.date|date:'Y-m-d' }}&week_start={{ week_start|date:'Y-m-d' }}">Review</a>
                {% elif action.mode == 'enter_actual_finish' %}
                    <form class="actual-form" method="post">
                        {% csrf_token %}
                        <input type="hidden" name="mode" value="enter_actual_finish">
                        <input type="hidden" name="employee_number" value="{{ row.employee_number }}">
                        <input type="hidden" name="event_date" value="{{ row.date|date:'Y-m-d' }}">
                        <input type="hidden" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
                        <input type="time" name="actual_time" required>
                        <button class="button fix smallfix" type="submit">{{ action.label }}</button>
                    </form>
                {% elif action.mode == 'enter_actual_shift' %}
                    <form class="actual-form" method="post">
                        {% csrf_token %}
                        <input type="hidden" name="mode" value="enter_actual_shift">
                        <input type="hidden" name="employee_number" value="{{ row.employee_number }}">
                        <input type="hidden" name="event_date" value="{{ row.date|date:'Y-m-d' }}">
                        <input type="hidden" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
                        <input type="time" name="start_time" required>
                        <span>to</span>
                        <input type="time" name="finish_time" required>
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
            <a class="advanced" href="/manager/fix-day/?employee_number={{ row.employee_number }}&event_date={{ row.date|date:'Y-m-d' }}&week_start={{ week_start|date:'Y-m-d' }}">Advanced</a>
            </div>
        </td>
    </tr>
    {% empty %}
    <tr><td colspan="7" class="ok">No payroll issues found.</td></tr>
    {% endfor %}
</table>

<p class="help">Break warnings are handled on the live dashboard. They do not block payroll export unless the clock records themselves are wrong.</p>

<p>
    <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Summary</a>
    <a class="button secondary" href="/manager/today/">Manager Dashboard</a>
    <a class="button secondary" href="/">Home</a>
</p>
</div>
</body>
</html>
HTML

python -m py_compile core/views.py
python manage.py check

echo "Patch 36 applied. Backup saved to $BACKUP_DIR"
echo "Payroll quick fixes are clearer: Pay roster shift, Clock out at roster finish, Approve unrostered shift. Break warnings no longer block payroll."
