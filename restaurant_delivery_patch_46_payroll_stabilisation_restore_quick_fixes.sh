#!/usr/bin/env bash
set -euo pipefail

echo "== patch_46_payroll_stabilisation_restore_quick_fixes =="

if [ ! -f manage.py ]; then
  echo "ERROR: run this from the Django project root, e.g. cd ~/restaurant_clocking"
  exit 1
fi

stamp=$(date +%Y%m%d_%H%M%S)
mkdir -p "backups_patch_46_$stamp"
cp -f core/services/payroll.py "backups_patch_46_$stamp/payroll.py.before_patch46" 2>/dev/null || true
cp -f core/views.py "backups_patch_46_$stamp/views.py.before_patch46"
cp -f templates/payroll_problems.html "backups_patch_46_$stamp/payroll_problems.html.before_patch46" 2>/dev/null || true

mkdir -p core/services
[ -f core/services/__init__.py ] || touch core/services/__init__.py

cat > core/services/payroll.py <<'PY'
"""
Payroll stabilisation service.

This is the single source used by:
- Weekly Payroll count
- Payroll Issues detail page
- Payroll quick-fix actions
- Sage export safety check

Rule: if the manager sees a count, the detail page must show the same rows.
"""
from __future__ import annotations

import csv
from datetime import datetime, timedelta
from typing import List, Optional, Tuple

from django.contrib import messages
from django.http import HttpResponse
from django.shortcuts import get_object_or_404
from django.utils import timezone

from core.models import ClockEvent, Employee, RosterShift
from core.compliance import (
    calculate_employee_day,
    current_operational_date,
    get_week_rows,
    operational_window,
)

CLOCK_TYPES = {"IN", "BREAK_START", "BREAK_END", "OUT"}
WORK_TYPES = {"IN", "OUT"}


def parse_week_start(request):
    raw = request.GET.get("week_start") or request.POST.get("week_start")
    if raw:
        return datetime.strptime(raw, "%Y-%m-%d").date()
    today = timezone.localdate()
    return today - timedelta(days=today.weekday())


def _day_range(week_start):
    return [week_start + timedelta(days=i) for i in range(7)]


def _make_aware(day, clock_time):
    return timezone.make_aware(datetime.combine(day, clock_time))


def _event_minute(event):
    return timezone.localtime(event.timestamp).replace(second=0, microsecond=0)


def _events_for_day(employee, day):
    """Return clock events for the app's operational day with exact duplicates collapsed."""
    start_dt, end_dt = operational_window(day)
    events = (
        ClockEvent.objects
        .filter(employee=employee, timestamp__gte=start_dt, timestamp__lt=end_dt)
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


def _employees_for_week(week_start):
    """Include active employees plus anyone with roster/events in the week."""
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


def _roster_shift(employee, day):
    """Return a single combined roster window for the employee/day, or None."""
    shifts = list(
        RosterShift.objects
        .filter(employee=employee, shift_date=day)
        .order_by("start_time", "end_time")
    )
    if not shifts:
        return None

    first = shifts[0]
    last = shifts[-1]
    start_dt = _make_aware(day, first.start_time)
    end_dt = _make_aware(day, last.end_time)
    if end_dt <= start_dt:
        end_dt += timedelta(days=1)

    return {
        "start": start_dt,
        "end": end_dt,
        "start_label": timezone.localtime(start_dt).strftime("%H:%M"),
        "end_label": timezone.localtime(end_dt).strftime("%H:%M"),
        "label": f"{first.start_time.strftime('%H:%M')} - {last.end_time.strftime('%H:%M')}",
    }


def _first_in_last_out(events):
    ins = [event for event in events if event.clock_type == "IN"]
    outs = [event for event in events if event.clock_type == "OUT"]
    return (ins[0] if ins else None), (outs[-1] if outs else None)


def _first_and_last_any(events):
    if not events:
        return None, None
    return events[0], events[-1]


def _clock_sequence_issue(events):
    """Return the payroll-blocking clock issue, or None."""
    if not events:
        return None

    work = [event.clock_type for event in events if event.clock_type in WORK_TYPES]
    if work:
        if "IN" not in work:
            return "Missing clock-in"
        if "OUT" not in work:
            return "Missing clock-out"
        if work[0] != "IN" or work[-1] != "OUT":
            return "Check clock event order"
        if work.count("IN") != work.count("OUT"):
            return "Check clock event sequence"
        if work.count("IN") > 1 or work.count("OUT") > 1:
            return "Multiple clock-ins/outs on same day"

    break_balance = 0
    for event in events:
        if event.clock_type == "BREAK_START":
            break_balance += 1
        elif event.clock_type == "BREAK_END":
            if break_balance <= 0:
                return "Break ended without a break start"
            break_balance -= 1
    if break_balance:
        return "Break was not ended"

    return None


def _quick_actions_for_issue(issue, shift, events):
    """Manager-facing quick actions for each issue row."""
    issue_l = (issue or "").lower()
    first_in, last_out = _first_in_last_out(events)
    actions = []

    if "missing clock-in" in issue_l:
        if shift:
            actions.append({"mode": "clock_in_roster_start", "label": f"Use roster clock-in ({shift['start_label']})"})
            actions.append({"mode": "pay_roster_shift", "label": f"Pay roster shift ({shift['label']})"})
        actions.append({"mode": "enter_actual_shift", "label": "Enter actual times"})

    elif "missing clock-out" in issue_l:
        if shift:
            actions.append({"mode": "clock_out_roster_finish", "label": f"Use roster clock-out ({shift['end_label']})"})
            actions.append({"mode": "pay_roster_shift", "label": f"Pay roster shift ({shift['label']})"})
        actions.append({"mode": "enter_actual_finish", "label": "Enter finish"})
        actions.append({"mode": "enter_actual_shift", "label": "Enter actual times"})

    elif "long shift" in issue_l or "unusually" in issue_l:
        actions.append({"mode": "pay_actual_time", "label": "Use first and last clock"})
        if shift:
            actions.append({"mode": "pay_roster_shift", "label": f"Pay roster shift ({shift['label']})"})
        actions.append({"mode": "enter_actual_shift", "label": "Enter correct times"})

    else:
        actions.append({"mode": "pay_actual_time", "label": "Use first and last clock"})
        if shift:
            actions.append({"mode": "pay_roster_shift", "label": f"Pay roster shift ({shift['label']})"})
        actions.append({"mode": "enter_actual_shift", "label": "Enter correct times"})
        actions.append({"mode": "delete_day_events", "label": "Delete bad events"})

    # Keep Advanced as a link in the template; no need to duplicate it here.
    return actions


def _delete_day_events(employee, day):
    start_dt, end_dt = operational_window(day)
    return ClockEvent.objects.filter(employee=employee, timestamp__gte=start_dt, timestamp__lt=end_dt).delete()[0]


def _create_event(employee, clock_type, timestamp, note):
    return ClockEvent.objects.create(
        employee=employee,
        clock_type=clock_type,
        timestamp=timestamp,
        method="MANAGER",
        notes=note,
    )


def _create_clean_shift(employee, start_dt, end_dt, note):
    if end_dt <= start_dt:
        end_dt += timedelta(days=1)
    _create_event(employee, "IN", start_dt, f"Manager fix: {note} start")
    _create_event(employee, "OUT", end_dt, f"Manager fix: {note} finish")


def get_payroll_issue_rows(week_start):
    """The one source of payroll issue rows. Counts must come from this only."""
    rows = []
    today = current_operational_date()

    for employee in _employees_for_week(week_start):
        for day in _day_range(week_start):
            if day > today:
                continue

            events = _events_for_day(employee, day)
            if not events:
                # No clock records is not automatically a payroll blocker; a no-show may be correct.
                continue

            issue = _clock_sequence_issue(events)
            day_row = calculate_employee_day(employee, day, include_live=False)
            shift = _roster_shift(employee, day)

            if not issue and int(day_row.get("worked_minutes") or 0) > 14 * 60:
                issue = "Unusually long shift"

            if not issue:
                continue

            rows.append({
                "date": day,
                "employee_number": employee.employee_number,
                "employee": employee.name,
                "roster": day_row.get("roster") or (shift["label"] if shift else "Not rostered"),
                "status": day_row.get("status") or "Check",
                "worked_hours": day_row.get("worked_hours") or 0,
                "break_minutes": day_row.get("break_minutes") or 0,
                "problem": issue,
                "quick_actions": _quick_actions_for_issue(issue, shift, events),
                "source": "payroll_engine",
            })

    return rows


def payroll_is_ready(week_start):
    rows = get_payroll_issue_rows(week_start)
    return len(rows) == 0, rows


def apply_payroll_quick_fix_from_request(request):
    """Apply the manager's selected quick fix. Returns the week_start to redirect/render."""
    week_start = parse_week_start(request)
    employee_number = request.POST.get("employee_number")
    day_raw = request.POST.get("event_date")
    mode = request.POST.get("mode")

    employee = get_object_or_404(Employee, employee_number=employee_number)
    day = datetime.strptime(day_raw, "%Y-%m-%d").date()
    events = _events_for_day(employee, day)
    shift = _roster_shift(employee, day)
    first_in, last_out = _first_in_last_out(events)
    first_any, last_any = _first_and_last_any(events)

    try:
        if mode == "clock_in_roster_start":
            if not shift:
                messages.error(request, "No roster start time found for this employee.")
            else:
                finish_dt = last_out.timestamp if last_out else shift["end"]
                _delete_day_events(employee, day)
                _create_clean_shift(employee, shift["start"], finish_dt, f"used roster clock-in {shift['start_label']}")
                messages.success(request, f"{employee.name}: roster clock-in time used ({shift['start_label']}).")

        elif mode == "clock_out_roster_finish":
            if not shift:
                messages.error(request, "No roster finish time found for this employee.")
            else:
                start_dt = first_in.timestamp if first_in else shift["start"]
                _delete_day_events(employee, day)
                _create_clean_shift(employee, start_dt, shift["end"], f"used roster clock-out {shift['end_label']}")
                messages.success(request, f"{employee.name}: roster clock-out time used ({shift['end_label']}).")

        elif mode == "pay_roster_shift":
            if not shift:
                messages.error(request, "No roster shift found for this employee.")
            else:
                _delete_day_events(employee, day)
                _create_clean_shift(employee, shift["start"], shift["end"], f"paid roster shift {shift['label']}")
                messages.success(request, f"{employee.name}: paid roster shift ({shift['label']}).")

        elif mode == "enter_actual_finish":
            actual = request.POST.get("actual_time")
            if not actual:
                messages.error(request, "Enter the finish time.")
            else:
                finish_dt = _make_aware(day, datetime.strptime(actual, "%H:%M").time())
                start_dt = first_in.timestamp if first_in else (shift["start"] if shift else None)
                if not start_dt:
                    messages.error(request, "No start time found. Use Enter actual times instead.")
                else:
                    _delete_day_events(employee, day)
                    _create_clean_shift(employee, start_dt, finish_dt, f"manager entered finish {actual}")
                    messages.success(request, f"{employee.name}: finish set to {actual}.")

        elif mode == "enter_actual_shift":
            start_raw = request.POST.get("start_time")
            finish_raw = request.POST.get("finish_time")
            if not start_raw or not finish_raw:
                messages.error(request, "Enter start and finish times.")
            else:
                start_dt = _make_aware(day, datetime.strptime(start_raw, "%H:%M").time())
                finish_dt = _make_aware(day, datetime.strptime(finish_raw, "%H:%M").time())
                _delete_day_events(employee, day)
                _create_clean_shift(employee, start_dt, finish_dt, f"manager entered actual shift {start_raw}-{finish_raw}")
                messages.success(request, f"{employee.name}: actual times set to {start_raw} - {finish_raw}.")

        elif mode == "pay_actual_time":
            if not first_any or not last_any or first_any.timestamp == last_any.timestamp:
                messages.error(request, "Not enough clock information. Enter actual times instead.")
            else:
                _delete_day_events(employee, day)
                _create_clean_shift(employee, first_any.timestamp, last_any.timestamp, "used first and last clock")
                messages.success(
                    request,
                    f"{employee.name}: paid first-to-last clock span "
                    f"{timezone.localtime(first_any.timestamp).strftime('%H:%M')} - "
                    f"{timezone.localtime(last_any.timestamp).strftime('%H:%M')}.",
                )

        elif mode == "delete_day_events":
            deleted = _delete_day_events(employee, day)
            messages.success(request, f"{employee.name}: deleted {deleted} clock event(s) for {day}.")

        else:
            messages.error(request, "Unknown payroll fix action.")

    except Exception as exc:
        messages.error(request, f"Could not apply payroll fix: {exc}")

    return week_start


def _hours(value):
    return round(float(value or 0), 2)


def _minutes_to_decimal_string(minutes):
    return f"{round((int(minutes or 0)) / 60, 2):.2f}"


def get_weekly_summary_rows(week_start, standard_hours=39):
    rows = get_week_rows(week_start, standard_hours)
    payroll_issue_rows = get_payroll_issue_rows(week_start)
    issue_map = {}
    for issue in payroll_issue_rows:
        issue_map.setdefault(issue["employee_number"], []).append(
            f"{issue['date'].strftime('%a')}: {issue['problem']}"
        )

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

        issues = issue_map.get(row.get("employee_number"), [])
        if issues:
            row["review_status"] = "Review"
            row["review_reason"] = "; ".join(issues[:3])
            row["status_css"] = "warn"
        elif not row.get("review_status"):
            row["review_status"] = "OK"
            row["review_reason"] = ""
            row["status_css"] = "ok"
        if not row.get("warning"):
            row["warning"] = "OK"
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
PY

python3 <<'PY'
from pathlib import Path
import re

p = Path("core/views.py")
s = p.read_text()

# Ensure the p45 import includes the quick-fix applicator.
s = s.replace(
    "build_sage_csv_response as _p45_build_sage_csv_response,\n)",
    "build_sage_csv_response as _p45_build_sage_csv_response,\n    apply_payroll_quick_fix_from_request as _p46_apply_payroll_quick_fix_from_request,\n)"
)

# Replace the final patch-45 payroll_problems function so POST quick fixes are handled.
pattern = re.compile(
    r"@_p45_login_required\ndef payroll_problems\(request\):\n.*?\n\n(?=@_p45_login_required\ndef manager_weekly_summary)",
    re.S,
)
replacement = '''@_p45_login_required
def payroll_problems(request):
    if request.method == "POST":
        week_start = _p46_apply_payroll_quick_fix_from_request(request)
        return _p45_redirect(f"/manager/payroll-problems/?week_start={week_start.isoformat()}")

    week_start = _p45_parse_week_start(request)
    week_end = week_start + timedelta(days=6)
    rows = _p45_get_payroll_issue_rows(week_start)
    return _p45_render(request, "payroll_problems.html", {
        "week_start": week_start,
        "week_end": week_end,
        "rows": rows,
        "problem_count": len(rows),
        "payroll_problem_count": len(rows),
        "unresolved_problem_count": len(rows),
    })


'''
if not pattern.search(s):
    raise SystemExit("Could not locate final patch-45 payroll_problems block in core/views.py")
s = pattern.sub(replacement, s, count=1)

p.write_text(s)
PY

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
        .danger { background: #991b1b; }
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
<p>Fix the clock records that would affect payroll. Choose the option that matches what the employee should be paid.</p>

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
    <tr><th>Date</th><th>Employee</th><th>Roster</th><th>Status</th><th>Worked</th><th>Problem</th><th>Manager Fix</th></tr>
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
                {% if action.mode == 'enter_actual_finish' %}
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
                        <button class="button {% if action.mode == 'delete_day_events' %}danger{% else %}fix{% endif %} smallfix" type="submit">{{ action.label }}</button>
                    </form>
                {% endif %}
            {% endfor %}
            <a class="advanced" href="/manager/fix-day/?employee_number={{ row.employee_number }}&event_date={{ row.date|date:'Y-m-d' }}&week_start={{ week_start|date:'Y-m-d' }}">Advanced edit</a>
            </div>
        </td>
    </tr>
    {% empty %}
    <tr><td colspan="7" class="ok">No payroll issues found.</td></tr>
    {% endfor %}
</table>

<p class="help">Break reminders and late arrivals are operational issues for the live dashboard. This page only blocks payroll when the clock records themselves need fixing.</p>

<p>
    <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Payroll</a>
    <a class="button secondary" href="/manager/today/">Manager Dashboard</a>
    <a class="button secondary" href="/">Home</a>
</p>
</div>
</body>
</html>
HTML

python -m py_compile core/services/payroll.py core/views.py
python manage.py check

echo
cat <<'EOF'
Patch 46 complete.

What changed:
  - Restored manager quick fixes on Payroll Issues.
  - Kept one payroll issue source for Weekly Payroll, Payroll Issues and Sage export.
  - Added fixes for: use roster clock-in, use roster clock-out, pay roster shift, enter actual times, use first/last clock, delete bad events.

Next:
  sudo systemctl restart restaurant_clocking
EOF
