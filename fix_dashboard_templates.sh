#!/bin/bash
set -e

echo "Backing up current dashboard templates..."
cp core/views.py core/views.py.dashboard_template_fix_bak
cp templates/manager_today.html templates/manager_today.html.dashboard_template_fix_bak 2>/dev/null || true
cp templates/payroll_problems.html templates/payroll_problems.html.dashboard_template_fix_bak 2>/dev/null || true

echo "Fixing manager_today_dashboard working rows to include staff on break..."
python - <<'PY'
from pathlib import Path

path = Path("core/views.py")
text = path.read_text()

old = '    working_rows = [row for row in rows if row["is_working"]]\n'
new = '    working_rows = [row for row in rows if row["is_working"] or row["is_on_break"]]\n'

if old in text:
    text = text.replace(old, new)
    path.write_text(text)
    print("Updated working_rows.")
else:
    print("working_rows line already updated or not found.")
PY

echo "Replacing manager_today.html with clean aligned template..."
cat > templates/manager_today.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Today's Staff Dashboard</title>
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
        input, button { padding: 8px; }
    </style>
</head>
<body>
<div class="container">

    <div class="header">
        <h1>Today's Staff Dashboard</h1>
        <p class="muted">Live view of who is working, who is on break, and what needs manager attention.</p>

        <form method="get">
            Date:
            <input type="date" name="date" value="{{ selected_date|date:'Y-m-d' }}">
            <button type="submit">View Date</button>
        </form>
    </div>

    <div class="cards">
        <div class="card"><div>Rostered Today</div><div class="number">{{ rostered_count }}</div></div>
        <div class="card"><div>Working Now</div><div class="number good">{{ currently_working }}</div></div>
        <div class="card"><div>On Break Now</div><div class="number warn">{{ on_break }}</div></div>
        <div class="card"><div>Clocked Out</div><div class="number">{{ clocked_out }}</div></div>
        <div class="card"><div>Urgent Issues</div><div class="number urgent">{{ urgent_count }}</div></div>
        <div class="card"><div>Operational Notes</div><div class="number warn">{{ operational_count }}</div></div>
    </div>

    <div class="section">
        <h2>Current Staff</h2>
        <p class="muted">Anyone currently clocked in or on break appears here.</p>

        <table>
            <tr>
                <th>Employee</th>
                <th>Status</th>
                <th>Roster</th>
                <th>Clocked In</th>
                <th>Worked</th>
                <th>Break Taken</th>
                <th>Issue</th>
            </tr>

            {% for row in working_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{{ row.status }}</td>
                <td>{{ row.roster }}</td>
                <td>{{ row.first_in }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td>{{ row.break_minutes }} mins</td>
                <td class="{% if row.is_urgent %}urgent{% elif row.is_operational %}warn{% else %}good{% endif %}">
                    {{ row.issue }}
                </td>
            </tr>
            {% empty %}
            <tr><td colspan="7">No staff are currently clocked in or on break.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Urgent Issues</h2>
        <p class="muted">These need manager attention first.</p>

        <table>
            <tr>
                <th>Employee</th>
                <th>Roster</th>
                <th>Status</th>
                <th>Issue</th>
                <th>Worked</th>
                <th>Break</th>
                <th>Manager Fix</th>
            </tr>

            {% for row in urgent_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{{ row.roster }}</td>
                <td>{{ row.status }}</td>
                <td class="urgent">{{ row.issue }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td>{{ row.break_minutes }} mins</td>
                <td><a class="button danger" href="/manager/corrections/?date={{ selected_date|date:'Y-m-d' }}">Fix</a></td>
            </tr>
            {% empty %}
            <tr><td colspan="7" class="good">No urgent issues.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Operational Notes</h2>
        <p class="muted">Useful notes such as late arrivals. These are not urgent compliance alerts.</p>

        <table>
            <tr>
                <th>Employee</th>
                <th>Roster</th>
                <th>Status</th>
                <th>Note</th>
                <th>Worked</th>
            </tr>

            {% for row in operational_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{{ row.roster }}</td>
                <td>{{ row.status }}</td>
                <td class="warn">{{ row.issue }}</td>
                <td>{{ row.worked_hours }}h</td>
            </tr>
            {% empty %}
            <tr><td colspan="5" class="good">No operational notes.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>All Staff Today</h2>
        <table>
            <tr>
                <th>Employee No</th>
                <th>Employee</th>
                <th>Roster</th>
                <th>Status</th>
                <th>First In</th>
                <th>Last Out</th>
                <th>Worked</th>
                <th>Break</th>
                <th>Issue</th>
            </tr>

            {% for row in rows %}
            <tr>
                <td>{{ row.employee_number }}</td>
                <td>{{ row.employee }}</td>
                <td>{{ row.roster }}</td>
                <td>{{ row.status }}</td>
                <td>{{ row.first_in }}</td>
                <td>{{ row.last_out }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td>{{ row.break_minutes }} mins</td>
                <td class="{% if row.is_urgent %}urgent{% elif row.is_operational %}warn{% else %}good{% endif %}">
                    {{ row.issue }}
                </td>
            </tr>
            {% endfor %}
        </table>
    </div>

    <p>
        <a class="button secondary" href="/">Home</a>
        <a class="button" href="/manager/payroll-problems/?week_start={{ selected_date|date:'Y-m-d' }}">Payroll Problems</a>
        <a class="button" href="/manager/corrections/?date={{ selected_date|date:'Y-m-d' }}">Manager Corrections</a>
        <a class="button secondary" href="/clock/">Staff Clocking</a>
    </p>

</div>
</body>
</html>
HTML

echo "Replacing payroll_problems.html with manager fix links..."
cat > templates/payroll_problems.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Payroll Review Queue</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #222; }
        .container { max-width: 1250px; margin: auto; background: white; padding: 24px; border-radius: 14px; border: 1px solid #e5e7eb; }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 10px; text-align: left; }
        th { background: #f9fafb; }
        .warn { color: #b42318; font-weight: bold; }
        .ok { color: #1a7f37; font-weight: bold; }
        .button { display: inline-block; padding: 10px 13px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 8px; margin-top: 8px; }
        .secondary { background: #4b5563; }
        .danger { background: #b42318; }
        input, button { padding: 8px; }
    </style>
</head>
<body>
<div class="container">
<h1>Payroll Review Queue</h1>

<p>
This page shows clocking issues that should be reviewed before payroll export:
missing clock-ins, missing clock-outs, open breaks, unusual shifts, and manual corrections.
</p>

<form method="get">
    Week Start:
    <input type="date" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
    <button type="submit">View Week</button>
</form>

<h2>{{ week_start }} to {{ week_end }}</h2>

{% if problem_count == 0 %}
    <p class="ok">No payroll problems found for this week.</p>
{% else %}
    <p class="warn">{{ problem_count }} payroll review item(s) found. Review before exporting payroll.</p>
{% endif %}

<table>
    <tr>
        <th>Date</th>
        <th>Employee</th>
        <th>Roster</th>
        <th>Status</th>
        <th>Worked</th>
        <th>Break</th>
        <th>Problem</th>
        <th>Manager Fix</th>
    </tr>

    {% for row in rows %}
    <tr>
        <td>{{ row.date }}</td>
        <td>{{ row.employee }}</td>
        <td>{{ row.roster }}</td>
        <td>{{ row.status }}</td>
        <td>{{ row.worked_hours }}h</td>
        <td>{{ row.break_minutes }} mins</td>
        <td class="warn">{{ row.problem }}</td>
        <td><a class="button danger" href="/manager/corrections/?date={{ row.date|date:'Y-m-d' }}">Fix Events</a></td>
    </tr>
    {% empty %}
    <tr><td colspan="8" class="ok">No problems found.</td></tr>
    {% endfor %}
</table>

<p>
    <a class="button" href="/manager/corrections/">Manager Corrections</a>
    <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Payroll</a>
    <a class="button secondary" href="/manager/today/">Today's Dashboard</a>
    <a class="button secondary" href="/">Home</a>
</p>

</div>
</body>
</html>
HTML

echo "Running checks..."
python manage.py check

echo "Restarting app..."
sudo systemctl restart restaurant_clocking

echo "Dashboard template fix complete."
