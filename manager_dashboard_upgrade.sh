#!/bin/bash
set -e

echo "Backing up files..."
cp core/urls.py core/urls.py.bak
cp core/views.py core/views.py.bak
cp templates/home.html templates/home.html.bak 2>/dev/null || true

cat > core/urls.py <<'PY'
from django.urls import path

from .views import (
    home_page,
    clock_page,
    export_clock_events_csv,
    upload_roster,
    manager_dashboard,
    manager_weekly_summary,
    generate_test_clock_events,
    manager_daily_monitor,
    manager_today_dashboard,
)

urlpatterns = [
    path('', home_page, name='home'),
    path('clock/', clock_page, name='clock'),
    path('export/clock-events/', export_clock_events_csv, name='export_clock_events_csv'),
    path('manager/upload-roster/', upload_roster, name='upload_roster'),
    path('manager/dashboard/', manager_dashboard, name='manager_dashboard'),
    path('manager/weekly-summary/', manager_weekly_summary, name='manager_weekly_summary'),
    path('manager/generate-test-events/', generate_test_clock_events, name='generate_test_clock_events'),
    path('manager/daily-monitor/', manager_daily_monitor, name='manager_daily_monitor'),
    path('manager/today/', manager_today_dashboard, name='manager_today_dashboard'),
]
PY

if ! grep -q "def manager_today_dashboard" core/views.py; then
cat >> core/views.py <<'PY'


def _mins(start_dt, end_dt):
    return max(0, int((end_dt - start_dt).total_seconds() / 60))


def _break_required(worked_minutes):
    if worked_minutes > 360:
        return 30
    if worked_minutes > 270:
        return 15
    return 0


def _staff_day_status(employee, selected_date):
    events = ClockEvent.objects.filter(employee=employee, timestamp__date=selected_date).order_by("timestamp")
    shifts = RosterShift.objects.filter(employee=employee, shift_date=selected_date).order_by("start_time")

    roster_text = "Not rostered"
    planned_start = None

    if shifts.exists():
        parts = []
        for shift in shifts:
            parts.append(f"{shift.start_time.strftime('%H:%M')} - {shift.end_time.strftime('%H:%M')}")
            if planned_start is None or shift.start_time < planned_start:
                planned_start = shift.start_time
        roster_text = ", ".join(parts)

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
            if work_start is not None:
                invalid_sequence = True
            work_start = event.timestamp

        elif event.clock_type == "BREAK_START":
            if work_start is not None:
                worked_minutes += _mins(work_start, event.timestamp)
                work_start = None
            else:
                invalid_sequence = True
            break_start = event.timestamp

        elif event.clock_type == "BREAK_END":
            if break_start is not None:
                break_minutes += _mins(break_start, event.timestamp)
                break_start = None
            else:
                invalid_sequence = True
            work_start = event.timestamp

        elif event.clock_type == "OUT":
            last_out = event.timestamp
            if work_start is not None:
                worked_minutes += _mins(work_start, event.timestamp)
                work_start = None
            elif break_start is not None:
                break_minutes += _mins(break_start, event.timestamp)
                break_start = None
            else:
                invalid_sequence = True

    now = timezone.now()
    if selected_date == timezone.localdate():
        if work_start is not None:
            worked_minutes += _mins(work_start, now)
        elif break_start is not None:
            break_minutes += _mins(break_start, now)

    status = "No activity"
    if latest_event:
        if latest_event.clock_type == "IN":
            status = "Working now"
        elif latest_event.clock_type == "BREAK_START":
            status = "On break"
        elif latest_event.clock_type == "BREAK_END":
            status = "Back from break"
        elif latest_event.clock_type == "OUT":
            status = "Clocked out"

    required_break = _break_required(worked_minutes)
    issues = []

    if invalid_sequence:
        issues.append("Check clock sequence")
    if shifts.exists() and not latest_event:
        issues.append("Rostered but no clock-in")
    if latest_event and not shifts.exists():
        issues.append("Worked but not rostered")
    if latest_event and latest_event.clock_type == "IN" and required_break > 0 and break_minutes == 0:
        issues.append("Break due / overdue")
    if latest_event and latest_event.clock_type == "OUT" and required_break > 0 and break_minutes < required_break:
        issues.append("Break missing or too short")
    if planned_start and not first_in and selected_date == timezone.localdate():
        planned_dt = timezone.make_aware(datetime.combine(selected_date, planned_start))
        if now > planned_dt + timedelta(minutes=10):
            issues.append("Late / not arrived")
    if first_in and planned_start:
        planned_dt = timezone.make_aware(datetime.combine(selected_date, planned_start))
        if first_in > planned_dt + timedelta(minutes=10):
            issues.append("Arrived late")

    issue_text = "; ".join(issues) if issues else "OK"

    return {
        "employee_number": employee.employee_number,
        "employee": employee.name,
        "roster": roster_text,
        "first_in": first_in.strftime("%H:%M") if first_in else "-",
        "last_out": last_out.strftime("%H:%M") if last_out else "-",
        "status": status,
        "worked_hours": round(worked_minutes / 60, 2),
        "break_minutes": break_minutes,
        "paid_hours": round(worked_minutes / 60, 2),
        "required_break": required_break,
        "issue": issue_text,
        "needs_attention": issue_text != "OK",
        "is_working": status in ["Working now", "Back from break"],
        "is_on_break": status == "On break",
        "is_clocked_out": status == "Clocked out",
        "has_activity": latest_event is not None,
        "rostered": shifts.exists(),
    }


def manager_today_dashboard(request):
    selected_date_str = request.GET.get("date", timezone.localdate().strftime("%Y-%m-%d"))
    selected_date = datetime.strptime(selected_date_str, "%Y-%m-%d").date()

    employees = Employee.objects.filter(active=True).order_by("name")
    rows = [_staff_day_status(employee, selected_date) for employee in employees]

    attention_rows = [row for row in rows if row["needs_attention"]]
    working_rows = [row for row in rows if row["is_working"]]

    return render(request, "manager_today.html", {
        "selected_date": selected_date,
        "rows": rows,
        "attention_rows": attention_rows,
        "working_rows": working_rows,
        "rostered_count": sum(1 for row in rows if row["rostered"]),
        "currently_working": len(working_rows),
        "on_break": sum(1 for row in rows if row["is_on_break"]),
        "clocked_out": sum(1 for row in rows if row["is_clocked_out"]),
        "need_attention": len(attention_rows),
    })
PY
fi

cat > templates/home.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Restaurant Staff Manager</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 30px; color: #222; }
        .container { max-width: 1050px; margin: auto; }
        .header { background: white; padding: 28px; border-radius: 14px; margin-bottom: 18px; border: 1px solid #e5e7eb; }
        .header h1 { margin: 0 0 8px 0; font-size: 32px; }
        .muted { color: #666; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 18px; }
        .card { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 22px; }
        .card h2 { margin-top: 0; font-size: 22px; }
        .button { display: inline-block; padding: 13px 16px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; }
        .secondary { background: #4b5563; }
        .small { font-size: 14px; }
    </style>
</head>
<body>
<div class="container">
    <div class="header">
        <h1>Restaurant Staff Manager</h1>
        <p class="muted">Simple daily view for attendance, unpaid breaks, roster tracking and payroll preparation.</p>
    </div>
    <div class="grid">
        <div class="card"><h2>Today's Dashboard</h2><p>Start here. See who is working, who is on break, who is late, and what needs attention.</p><a class="button" href="/manager/today/">Open Today's Dashboard</a></div>
        <div class="card"><h2>Staff Clocking</h2><p>Staff use this after scanning the QR code to clock in, start/end breaks, and clock out.</p><a class="button" href="/clock/">Open Staff Clocking</a></div>
        <div class="card"><h2>Upload Weekly Roster</h2><p>Upload the weekly roster CSV so the system can compare planned hours with actual hours.</p><a class="button" href="/manager/upload-roster/">Upload Roster</a></div>
        <div class="card"><h2>Weekly Payroll Hours</h2><p>Review worked hours, rostered hours, differences, missing clock-outs and payroll-ready totals.</p><a class="button" href="/manager/weekly-summary/?week_start=2026-06-15">View Weekly Summary</a></div>
        <div class="card"><h2>Detailed Records</h2><p>Use this only when checking specific clock-ins, clock-outs or unusual activity.</p><a class="button secondary" href="/manager/daily-monitor/">Open Daily Monitor</a></div>
        <div class="card"><h2>System Admin</h2><p class="small">For setup only: employees, raw clock events and technical admin.</p><a class="button secondary" href="/admin/">Admin Area</a></div>
    </div>
</div>
</body>
</html>
HTML

cat > templates/manager_today.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Today's Dashboard</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #222; }
        .container { max-width: 1250px; margin: auto; }
        .header, .section { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 20px; margin: 18px 0; }
        h1 { margin: 0 0 8px 0; } .muted { color: #666; }
        .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 14px; margin: 18px 0; }
        .card { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 18px; }
        .number { font-size: 34px; font-weight: bold; margin-top: 8px; }
        table { width: 100%; border-collapse: collapse; margin-top: 12px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 11px; text-align: left; }
        th { background: #f9fafb; } .warn { color: #b42318; font-weight: bold; } .ok { color: #1a7f37; font-weight: bold; }
        .button { display: inline-block; padding: 10px 13px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 8px; }
        .secondary { background: #4b5563; } input, button { padding: 8px; }
    </style>
</head>
<body>
<div class="container">
    <div class="header">
        <h1>Today's Dashboard</h1>
        <p class="muted">Main screen for staff status, breaks, late arrivals and issues needing attention.</p>
        <form method="get">Date: <input type="date" name="date" value="{{ selected_date|date:'Y-m-d' }}"> <button type="submit">View Date</button></form>
    </div>

    <div class="cards">
        <div class="card"><div>Rostered Today</div><div class="number">{{ rostered_count }}</div></div>
        <div class="card"><div>Working Now</div><div class="number">{{ currently_working }}</div></div>
        <div class="card"><div>On Break</div><div class="number">{{ on_break }}</div></div>
        <div class="card"><div>Clocked Out</div><div class="number">{{ clocked_out }}</div></div>
        <div class="card"><div>Need Attention</div><div class="number">{{ need_attention }}</div></div>
    </div>

    <div class="section">
        <h2>Attention Required</h2>
        <p class="muted">Check these first.</p>
        <table>
            <tr><th>Employee</th><th>Roster</th><th>Status</th><th>Issue</th><th>Worked</th><th>Break</th><th>Paid</th></tr>
            {% for row in attention_rows %}
            <tr><td>{{ row.employee }}</td><td>{{ row.roster }}</td><td>{{ row.status }}</td><td class="warn">{{ row.issue }}</td><td>{{ row.worked_hours }}</td><td>{{ row.break_minutes }} mins</td><td>{{ row.paid_hours }}</td></tr>
            {% empty %}
            <tr><td colspan="7" class="ok">No issues requiring attention.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Currently Working</h2>
        <table>
            <tr><th>Employee</th><th>Roster</th><th>First In</th><th>Status</th><th>Worked</th><th>Break</th></tr>
            {% for row in working_rows %}
            <tr><td>{{ row.employee }}</td><td>{{ row.roster }}</td><td>{{ row.first_in }}</td><td>{{ row.status }}</td><td>{{ row.worked_hours }}</td><td>{{ row.break_minutes }} mins</td></tr>
            {% empty %}
            <tr><td colspan="6">No staff currently clocked in.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>All Staff Today</h2>
        <table>
            <tr><th>No</th><th>Employee</th><th>Roster</th><th>First In</th><th>Last Out</th><th>Status</th><th>Worked</th><th>Break</th><th>Paid</th><th>Issue</th></tr>
            {% for row in rows %}
            <tr><td>{{ row.employee_number }}</td><td>{{ row.employee }}</td><td>{{ row.roster }}</td><td>{{ row.first_in }}</td><td>{{ row.last_out }}</td><td>{{ row.status }}</td><td>{{ row.worked_hours }}</td><td>{{ row.break_minutes }} mins</td><td>{{ row.paid_hours }}</td><td class="{% if row.needs_attention %}warn{% else %}ok{% endif %}">{{ row.issue }}</td></tr>
            {% endfor %}
        </table>
    </div>

    <p><a class="button" href="/clock/">Staff Clocking</a><a class="button" href="/manager/upload-roster/">Upload Roster</a><a class="button" href="/manager/weekly-summary/?week_start=2026-06-15">Weekly Summary</a><a class="button secondary" href="/">Home</a></p>
</div>
</body>
</html>
HTML

echo "Upgrade complete. Open /manager/today/"
