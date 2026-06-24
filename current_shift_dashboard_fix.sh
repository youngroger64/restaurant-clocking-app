#!/bin/bash
set -e

echo "Backing up before current-shift dashboard fix..."
cp core/views.py core/views.py.before_current_shift_dashboard_fix
cp templates/home.html templates/home.html.before_current_shift_dashboard_fix 2>/dev/null || true

python - <<'PY'
from pathlib import Path

path = Path("core/views.py")
text = path.read_text()

start = text.index('@login_required(login_url="/manager/login/")\ndef home_page')
end = text.index("\n\ndef _clock_state_for_employee", start)

new_home = """@login_required(login_url="/manager/login/")
def home_page(request):
    today = timezone.localdate()
    now = timezone.localtime()
    week_start = today - timedelta(days=today.weekday())

    rows = get_day_rows(today)
    week_rows = get_week_rows(week_start, 39)

    current_staff = [
        row for row in rows
        if row["is_working"] or row["is_on_break"]
    ]

    urgent_rows = [row for row in rows if row["is_urgent"]]
    operational_rows = [row for row in rows if row["is_operational"]]

    payroll_problem_rows = [
        row for row in week_rows
        if row["warning"] != "OK"
    ]

    rostered_now = []
    not_clocked_in_now = []

    today_shifts = RosterShift.objects.select_related("employee").filter(
        shift_date=today,
        employee__active=True,
    ).order_by("start_time")

    for shift in today_shifts:
        start_dt = timezone.make_aware(datetime.combine(today, shift.start_time))
        end_dt = timezone.make_aware(datetime.combine(today, shift.end_time))

        if end_dt <= start_dt:
            end_dt += timedelta(days=1)

        if start_dt <= now <= end_dt:
            matching_row = next(
                (row for row in rows if row["employee_number"] == shift.employee.employee_number),
                None
            )

            if matching_row:
                rostered_now.append(matching_row)

                if not matching_row["is_working"] and not matching_row["is_on_break"]:
                    not_clocked_in_now.append(matching_row)

    unrostered_current_staff = [
        row for row in current_staff
        if not row["rostered"]
    ]

    return render(request, "home.html", {
        "today": today,
        "now": now,
        "week_start": week_start,
        "rows": rows,
        "current_staff": current_staff,
        "rostered_now": rostered_now,
        "not_clocked_in_now": not_clocked_in_now,
        "unrostered_current_staff": unrostered_current_staff,
        "urgent_rows": urgent_rows,
        "operational_rows": operational_rows,
        "current_staff_count": len(current_staff),
        "rostered_now_count": len(rostered_now),
        "not_clocked_in_now_count": len(not_clocked_in_now),
        "on_break_count": sum(1 for row in rows if row["is_on_break"]),
        "urgent_count": len(urgent_rows),
        "payroll_problem_count": len(payroll_problem_rows),
    })
"""

text = text[:start] + new_home + text[end:]
path.write_text(text)
print("home_page replaced.")
PY

cat > templates/home.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Manager Dashboard</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #222; }
        .container { max-width: 1250px; margin: auto; }
        .header, .section { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 22px; margin-bottom: 18px; }
        h1 { margin: 0 0 8px 0; }
        .muted { color: #666; }
        .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 14px; margin: 18px 0; }
        .card { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 18px; }
        .number { font-size: 36px; font-weight: bold; margin-top: 8px; }
        .good { color: #1a7f37; font-weight: bold; }
        .warn { color: #b7791f; font-weight: bold; }
        .urgent { color: #b42318; font-weight: bold; }
        table { width: 100%; border-collapse: collapse; margin-top: 12px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 10px; text-align: left; }
        th { background: #f9fafb; }
        .button { display: inline-block; padding: 10px 13px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 8px; margin-top: 8px; }
        .secondary { background: #4b5563; }
        .danger { background: #b42318; }
    </style>
</head>
<body>
<div class="container">
    <div class="header">
        <h1>Manager Dashboard</h1>
        <p class="muted">Today: {{ today }}. Current time: {{ now|date:"H:i" }}.</p>
    </div>

    <div class="cards">
        <div class="card"><div>Current Staff</div><div class="number good">{{ current_staff_count }}</div></div>
        <div class="card"><div>Rostered Now</div><div class="number">{{ rostered_now_count }}</div></div>
        <div class="card"><div>Not Clocked In</div><div class="number {% if not_clocked_in_now_count > 0 %}urgent{% else %}good{% endif %}">{{ not_clocked_in_now_count }}</div></div>
        <div class="card"><div>On Break</div><div class="number warn">{{ on_break_count }}</div></div>
        <div class="card"><div>Urgent Issues</div><div class="number urgent">{{ urgent_count }}</div></div>
        <div class="card"><div>Payroll Issues</div><div class="number urgent">{{ payroll_problem_count }}</div></div>
    </div>

    <div class="section">
        <h2>Current Staff</h2>
        <p class="muted">Only staff currently clocked in or on break appear here.</p>
        <table>
            <tr><th>Employee</th><th>Status</th><th>Roster</th><th>Clocked In</th><th>Worked</th><th>Break</th><th>Issue</th></tr>
            {% for row in current_staff %}
            <tr>
                <td>{{ row.employee }}</td><td>{{ row.status }}</td><td>{{ row.roster }}</td><td>{{ row.first_in }}</td><td>{{ row.worked_hours }}h</td><td>{{ row.break_minutes }} mins</td>
                <td class="{% if row.is_urgent %}urgent{% elif row.is_operational %}warn{% else %}good{% endif %}">{{ row.issue }}</td>
            </tr>
            {% empty %}
            <tr><td colspan="7">No staff currently clocked in or on break.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Rostered Now But Not Clocked In</h2>
        <p class="muted">Staff whose shift is active right now but who are not clocked in.</p>
        <table>
            <tr><th>Employee</th><th>Roster</th><th>Status</th><th>Issue</th><th>Manager Fix</th></tr>
            {% for row in not_clocked_in_now %}
            <tr><td>{{ row.employee }}</td><td>{{ row.roster }}</td><td>{{ row.status }}</td><td class="urgent">{{ row.issue }}</td><td><a class="button danger" href="/manager/corrections/?date={{ today|date:'Y-m-d' }}">Fix</a></td></tr>
            {% empty %}
            <tr><td colspan="5" class="good">Nobody currently rostered is missing.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Working Without Scheduled Shift</h2>
        <table>
            <tr><th>Employee</th><th>Status</th><th>Worked</th><th>Issue</th><th>Manager Fix</th></tr>
            {% for row in unrostered_current_staff %}
            <tr><td>{{ row.employee }}</td><td>{{ row.status }}</td><td>{{ row.worked_hours }}h</td><td class="urgent">{{ row.issue }}</td><td><a class="button danger" href="/manager/corrections/?date={{ today|date:'Y-m-d' }}">Fix</a></td></tr>
            {% empty %}
            <tr><td colspan="5" class="good">No unrostered staff currently working.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Urgent Issues</h2>
        <table>
            <tr><th>Employee</th><th>Status</th><th>Roster</th><th>Issue</th><th>Manager Fix</th></tr>
            {% for row in urgent_rows %}
            <tr><td>{{ row.employee }}</td><td>{{ row.status }}</td><td>{{ row.roster }}</td><td class="urgent">{{ row.issue }}</td><td><a class="button danger" href="/manager/corrections/?date={{ today|date:'Y-m-d' }}">Fix</a></td></tr>
            {% empty %}
            <tr><td colspan="5" class="good">No urgent issues.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Today’s Full Roster</h2>
        <p class="muted">Full-day view. Lower down because current staff comes first.</p>
        <table>
            <tr><th>Employee</th><th>Roster</th><th>Status</th><th>Clocked In</th><th>Clocked Out</th><th>Worked</th><th>Issue</th></tr>
            {% for row in rows %}
                {% if row.rostered %}
                <tr><td>{{ row.employee }}</td><td>{{ row.roster }}</td><td>{{ row.status }}</td><td>{{ row.first_in }}</td><td>{{ row.last_out }}</td><td>{{ row.worked_hours }}h</td><td class="{% if row.is_urgent %}urgent{% elif row.is_operational %}warn{% else %}good{% endif %}">{{ row.issue }}</td></tr>
                {% endif %}
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Quick Actions</h2>
        <a class="button" href="/clock/">Staff Clocking</a>
        <a class="button" href="/manager/upload-roster/">Upload Roster</a>
        <a class="button" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Payroll Issues</a>
        <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Payroll</a>
        <a class="button" href="/manager/corrections/?date={{ today|date:'Y-m-d' }}">Manager Corrections</a>
        <a class="button secondary" href="/admin/">System Admin</a>
        <a class="button secondary" href="/manager/logout/">Logout</a>
    </div>
</div>
</body>
</html>
HTML

python manage.py check
sudo systemctl restart restaurant_clocking
echo "Manager dashboard rebuilt around current-shift logic."
