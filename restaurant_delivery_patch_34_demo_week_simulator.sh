#!/usr/bin/env bash
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="backups_patch_34_${TS}"
mkdir -p "$BACKUP_DIR"

cp core/views.py "$BACKUP_DIR/views.py"
cp core/urls.py "$BACKUP_DIR/urls.py"
[ -f templates/home.html ] && cp templates/home.html "$BACKUP_DIR/home.html" || true

cat >> core/views.py <<'PYCODE'

# -------------------------------------------------------------------
# Patch 34: Demo Week Simulator
# -------------------------------------------------------------------
# Purpose: create a realistic demo week from the uploaded roster so the
# product can be shown end-to-end: roster -> clocking -> payroll issues
# -> quick fixes -> Sage export.

from django.contrib.auth.decorators import login_required as _demo_login_required


def _demo_week_monday(d=None):
    from django.utils import timezone as _tz
    if d is None:
        d = _tz.localdate()
    return d - timedelta(days=d.weekday())


def _demo_shift_datetimes(shift):
    """Return aware start/end datetimes for a roster shift, handling overnight shifts."""
    from datetime import datetime as _dt, timedelta as _td
    from django.utils import timezone as _tz

    start = _dt.combine(shift.shift_date, shift.start_time)
    end = _dt.combine(shift.shift_date, shift.end_time)
    if end <= start:
        end = end + _td(days=1)
    return _tz.make_aware(start), _tz.make_aware(end)


def _demo_add_event(employee, clock_type, when, note):
    ClockEvent.objects.create(
        employee=employee,
        clock_type=clock_type,
        timestamp=when,
        method="DEMO",
        notes=note,
    )


def _demo_make_normal_shift(shift, late_mins=0, finish_delta_mins=0, add_break=True, note="Demo shift"):
    from datetime import timedelta as _td
    start, end = _demo_shift_datetimes(shift)
    employee = shift.employee
    in_time = start + _td(minutes=late_mins)
    out_time = end + _td(minutes=finish_delta_mins)

    _demo_add_event(employee, "IN", in_time, note)

    shift_minutes = max(0, int((out_time - in_time).total_seconds() // 60))
    if add_break and shift_minutes > 270:
        # Normal restaurant-style break around the middle of the shift.
        break_start = in_time + _td(minutes=min(270, max(180, shift_minutes // 2)))
        break_length = 30 if shift_minutes > 360 else 15
        break_end = break_start + _td(minutes=break_length)
        if break_end < out_time:
            _demo_add_event(employee, "BREAK_START", break_start, note)
            _demo_add_event(employee, "BREAK_END", break_end, note)

    _demo_add_event(employee, "OUT", out_time, note)


def _demo_clear_week_events(week_start):
    from datetime import datetime as _dt, time as _time, timedelta as _td
    from django.utils import timezone as _tz
    start_dt = _tz.make_aware(_dt.combine(week_start, _time.min))
    end_dt = start_dt + _td(days=8)  # includes overnight Sunday shifts
    return ClockEvent.objects.filter(
        timestamp__gte=start_dt,
        timestamp__lt=end_dt,
        method="DEMO",
    ).delete()[0]


def _demo_create_week(week_start, scenario):
    from datetime import datetime as _dt, time as _time, timedelta as _td
    from django.utils import timezone as _tz

    week_end = week_start + _td(days=6)
    shifts = list(
        RosterShift.objects.select_related("employee")
        .filter(shift_date__gte=week_start, shift_date__lte=week_end, employee__active=True)
        .order_by("shift_date", "start_time", "employee__name")
    )

    if not shifts:
        return {"created": 0, "message": "No roster shifts found for this week."}

    _demo_clear_week_events(week_start)
    created_before = ClockEvent.objects.filter(method="DEMO").count()

    # Pick a small number of realistic issues. The demo should show value without
    # making the app look chaotic.
    issue_counts = {
        "clean": {"missing_out": 0, "no_records": 0, "missed_break": 0, "worked_late": 0, "late": 0, "cover": 0},
        "normal": {"missing_out": 1, "no_records": 1, "missed_break": 1, "worked_late": 1, "late": 2, "cover": 1},
        "messy": {"missing_out": 2, "no_records": 2, "missed_break": 2, "worked_late": 2, "late": 4, "cover": 1},
    }.get(scenario, {"missing_out": 1, "no_records": 1, "missed_break": 1, "worked_late": 1, "late": 2, "cover": 1})

    assigned = set()
    notes = []

    def take_shift(label):
        for s in shifts:
            if s.id not in assigned:
                assigned.add(s.id)
                notes.append(label)
                return s
        return None

    # Missing clock-out: very common. Staff clock in, but no OUT event.
    for _ in range(issue_counts["missing_out"]):
        s = take_shift("Missing clock-out")
        if s:
            start, end = _demo_shift_datetimes(s)
            _demo_add_event(s.employee, "IN", start + _td(minutes=3), "Demo: forgot to clock out")
            if int((end - start).total_seconds() // 60) > 270:
                b = start + _td(hours=4)
                _demo_add_event(s.employee, "BREAK_START", b, "Demo: forgot to clock out")
                _demo_add_event(s.employee, "BREAK_END", b + _td(minutes=30), "Demo: forgot to clock out")

    # No records for a rostered shift: common enough when someone forgets to clock in.
    for _ in range(issue_counts["no_records"]):
        s = take_shift("No clock records")
        if s:
            # Intentionally create no events. Payroll quick fix should offer Use roster shift.
            pass

    # Missed break: staff worked the shift but did not record a break.
    for _ in range(issue_counts["missed_break"]):
        s = take_shift("Missed break")
        if s:
            _demo_make_normal_shift(s, late_mins=0, finish_delta_mins=0, add_break=False, note="Demo: no break recorded")

    # Worked late: actual time should usually be accepted by manager.
    for _ in range(issue_counts["worked_late"]):
        s = take_shift("Worked late")
        if s:
            _demo_make_normal_shift(s, late_mins=0, finish_delta_mins=35, add_break=True, note="Demo: worked late")

    # Late arrival: common, but not always a payroll blocker.
    for i in range(issue_counts["late"]):
        s = take_shift("Late arrival")
        if s:
            _demo_make_normal_shift(s, late_mins=8 + (i * 7), finish_delta_mins=0, add_break=True, note="Demo: arrived late")

    # Everything else is clean.
    for s in shifts:
        if s.id not in assigned:
            _demo_make_normal_shift(s, late_mins=0, finish_delta_mins=0, add_break=True, note="Demo: clean shift")

    # One unrostered cover shift if there is a suitable employee.
    if issue_counts["cover"]:
        employee = Employee.objects.filter(active=True).order_by("name").first()
        if employee:
            cover_day = week_start + _td(days=2)
            cover_start = _tz.make_aware(_dt.combine(cover_day, _time(18, 0)))
            cover_end = cover_start + _td(hours=3)
            _demo_add_event(employee, "IN", cover_start, "Demo: unrostered cover shift")
            _demo_add_event(employee, "OUT", cover_end, "Demo: unrostered cover shift")
            notes.append("Unrostered cover shift")

    created_after = ClockEvent.objects.filter(method="DEMO").count()
    return {
        "created": max(0, created_after - created_before),
        "message": f"Demo week created from {len(shifts)} roster shifts.",
        "notes": notes,
    }


@_demo_login_required
def manager_demo_week_simulator(request):
    from datetime import datetime as _dt, timedelta as _td
    from django.contrib import messages as _messages
    from django.shortcuts import redirect as _redirect
    from django.urls import reverse as _reverse
    from django.utils import timezone as _tz

    default_week = _demo_week_monday(_tz.localdate())
    week_start_raw = request.POST.get("week_start") or request.GET.get("week_start") or default_week.isoformat()
    try:
        week_start = _dt.strptime(week_start_raw, "%Y-%m-%d").date()
    except ValueError:
        week_start = default_week
    week_end = week_start + _td(days=6)

    if request.method == "POST":
        action = request.POST.get("action")
        if action == "clear":
            deleted = _demo_clear_week_events(week_start)
            _messages.success(request, f"Demo clock events cleared for this week ({deleted} event(s) removed).")
            return _redirect(f"{_reverse('manager_demo_week_simulator')}?week_start={week_start.isoformat()}")
        if action == "simulate":
            scenario = request.POST.get("scenario", "normal")
            result = _demo_create_week(week_start, scenario)
            if result["created"]:
                _messages.success(request, f"{result['message']} {result['created']} demo clock event(s) created.")
            else:
                _messages.warning(request, result["message"])
            return _redirect(f"{_reverse('manager_demo_week_simulator')}?week_start={week_start.isoformat()}")

    roster_count = RosterShift.objects.filter(shift_date__gte=week_start, shift_date__lte=week_end).count()
    demo_event_count = ClockEvent.objects.filter(
        method="DEMO",
        timestamp__date__gte=week_start,
        timestamp__date__lte=week_end + _td(days=1),
    ).count()
    sample_shifts = list(
        RosterShift.objects.select_related("employee")
        .filter(shift_date__gte=week_start, shift_date__lte=week_end)
        .order_by("shift_date", "start_time", "employee__name")[:12]
    )

    return render(request, "manager_demo_week.html", {
        "week_start": week_start,
        "week_end": week_end,
        "roster_count": roster_count,
        "demo_event_count": demo_event_count,
        "sample_shifts": sample_shifts,
    })
PYCODE

cat > templates/manager_demo_week.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Demo Week Simulator</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; background: #f4f6f8; color: #001b3a; }
        .page { max-width: 1180px; margin: 0 auto; padding: 22px; }
        .card { background: white; border: 1px solid #d9e0e8; border-radius: 12px; padding: 20px; margin-bottom: 18px; }
        .actions { display: flex; gap: 12px; flex-wrap: wrap; align-items: end; }
        .btn { display: inline-block; padding: 11px 16px; border-radius: 8px; text-decoration: none; border: 0; color: white; font-weight: bold; cursor: pointer; }
        .btn-primary { background: #2563eb; }
        .btn-grey { background: #4b5563; }
        .btn-red { background: #b91c1c; }
        label { display: block; font-weight: bold; margin-bottom: 5px; }
        input, select { padding: 9px; border: 1px solid #aeb7c2; border-radius: 6px; }
        table { width: 100%; border-collapse: collapse; background: white; }
        th, td { text-align: left; padding: 10px; border-bottom: 1px solid #d9e0e8; }
        th { background: #f8fafc; }
        .muted { color: #475569; }
        .notice { border-left: 4px solid #f59e0b; background: #fff7ed; padding: 14px; margin-bottom: 14px; }
        .success { border-left: 4px solid #16a34a; background: #f0fdf4; padding: 12px; margin-bottom: 10px; }
        .warning { border-left: 4px solid #d97706; background: #fffbeb; padding: 12px; margin-bottom: 10px; }
        .steps li { margin-bottom: 8px; }
    </style>
</head>
<body>
<div class="page">
    <div class="card">
        <h1>Demo Week Simulator</h1>
        <p class="muted">Create a realistic demo week from the uploaded roster. Use this to show the full flow: roster, clocking, payroll issues, quick fixes, and Sage export.</p>
        <p>
            <a class="btn btn-grey" href="/">Manager Dashboard</a>
            <a class="btn btn-grey" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Payroll</a>
            <a class="btn btn-grey" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Payroll Issues</a>
            <a class="btn btn-grey" href="/manager/upload-roster/">Roster Manager</a>
        </p>
    </div>

    {% if messages %}
        {% for message in messages %}
            <div class="{% if message.tags == 'success' %}success{% else %}warning{% endif %}">{{ message }}</div>
        {% endfor %}
    {% endif %}

    <div class="card">
        <h2>Create demo clock-ins</h2>
        <div class="notice">
            <strong>Safe demo mode:</strong> this only creates clock events marked as <strong>DEMO</strong>. You can clear them again from this page.
        </div>
        <form method="post">
            {% csrf_token %}
            <div class="actions">
                <div>
                    <label for="week_start">Week start</label>
                    <input id="week_start" type="date" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
                </div>
                <div>
                    <label for="scenario">Scenario</label>
                    <select id="scenario" name="scenario">
                        <option value="normal">Normal restaurant week</option>
                        <option value="clean">Clean week</option>
                        <option value="messy">Messy week</option>
                    </select>
                </div>
                <button class="btn btn-primary" type="submit" name="action" value="simulate">Create Demo Week</button>
                <button class="btn btn-red" type="submit" name="action" value="clear">Clear Demo Events</button>
            </div>
        </form>
    </div>

    <div class="card">
        <h2>Demo status</h2>
        <p><strong>Week:</strong> {{ week_start|date:"M j, Y" }} to {{ week_end|date:"M j, Y" }}</p>
        <p><strong>Roster shifts:</strong> {{ roster_count }}</p>
        <p><strong>Demo clock events:</strong> {{ demo_event_count }}</p>
    </div>

    <div class="card">
        <h2>How to demo the app</h2>
        <ol class="steps">
            <li>Upload or confirm the weekly roster.</li>
            <li>Click <strong>Create Demo Week</strong>.</li>
            <li>Open <strong>Payroll Issues</strong> and fix the few exceptions.</li>
            <li>Open <strong>Weekly Payroll</strong> and check that the week is ready.</li>
            <li>Export the Sage CSV.</li>
        </ol>
        <p class="muted">The point of the demo is simple: the manager fixes exceptions, not timesheets.</p>
    </div>

    <div class="card">
        <h2>Sample roster shifts</h2>
        <table>
            <tr><th>Date</th><th>Employee</th><th>Roster</th><th>Break</th></tr>
            {% for shift in sample_shifts %}
            <tr>
                <td>{{ shift.shift_date|date:"M j" }}</td>
                <td>{{ shift.employee.name }}</td>
                <td>{{ shift.start_time|time:"H:i" }} - {{ shift.end_time|time:"H:i" }}</td>
                <td>{{ shift.break_minutes }} mins</td>
            </tr>
            {% empty %}
            <tr><td colspan="4">No roster shifts found for this week. Upload a roster first.</td></tr>
            {% endfor %}
        </table>
    </div>
</div>
</body>
</html>
HTML

python3 - <<'PY'
from pathlib import Path
p = Path('core/urls.py')
s = p.read_text()
if 'manager_demo_week_simulator' not in s:
    s = s.replace('manager_corrections,', 'manager_corrections,\n    manager_demo_week_simulator,')
    marker = "    path('manager/corrections/', manager_corrections, name='manager_corrections'),"
    new = marker + "\n    path('manager/demo-week/', manager_demo_week_simulator, name='manager_demo_week_simulator'),"
    if marker in s:
        s = s.replace(marker, new)
    else:
        s = s.replace(']', "    path('manager/demo-week/', manager_demo_week_simulator, name='manager_demo_week_simulator'),\n]")
p.write_text(s)

# Add a manager-facing button to home.html if possible.
home = Path('templates/home.html')
if home.exists():
    hs = home.read_text()
    if '/manager/demo-week/' not in hs:
        # Try to place beside Admin / Setup, otherwise after Weekly Payroll, otherwise near top of body.
        if 'Admin / Setup' in hs:
            hs = hs.replace('Admin / Setup</a>', 'Admin / Setup</a>\n        <a class="btn" href="/manager/demo-week/">Demo Week</a>', 1)
        elif 'Weekly Payroll' in hs:
            hs = hs.replace('Weekly Payroll</a>', 'Weekly Payroll</a>\n        <a class="btn" href="/manager/demo-week/">Demo Week</a>', 1)
        elif '<body>' in hs:
            hs = hs.replace('<body>', '<body>\n<p><a href="/manager/demo-week/">Demo Week Simulator</a></p>', 1)
        home.write_text(hs)
PY

python3 -m py_compile core/views.py
python3 - <<'PY'
# Basic sanity check that URL import name exists in views.py
from pathlib import Path
views = Path('core/views.py').read_text()
urls = Path('core/urls.py').read_text()
assert 'def manager_demo_week_simulator' in views
assert 'manager/demo-week/' in urls
print('Patch 34 checks passed.')
PY

echo "Patch 34 applied. Backup saved to $BACKUP_DIR"
echo "Demo Week Simulator added at /manager/demo-week/."
