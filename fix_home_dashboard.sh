#!/bin/bash
set -e

echo "Backing up current home template..."
cp templates/home.html templates/home.html.before_home_fix

cat > templates/home.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Restaurant Operations Dashboard</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #222; }
        .container { max-width: 1250px; margin: auto; }
        .header, .section { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 22px; margin-bottom: 18px; }
        h1 { margin: 0 0 8px 0; }
        .muted { color: #666; }
        .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 14px; margin: 18px 0; }
        .card { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 18px; }
        .number { font-size: 36px; font-weight: bold; margin-top: 8px; }
        .good { color: #1a7f37; font-weight: bold; }
        .warn { color: #b7791f; font-weight: bold; }
        .urgent { color: #b42318; font-weight: bold; }
        .actions { display: flex; flex-wrap: wrap; gap: 10px; }
        .button { display: inline-block; padding: 10px 13px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 8px; margin-top: 8px; }
        .secondary { background: #4b5563; }
        .danger { background: #b42318; }
        table { width: 100%; border-collapse: collapse; margin-top: 12px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 10px; text-align: left; }
        th { background: #f9fafb; }
    </style>
</head>
<body>

<div class="container">

    <div class="header">
        <h1>Restaurant Operations Dashboard</h1>
        <p class="muted">
            Today: {{ today }}. This is the manager's start page for live staff status, payroll issues and quick fixes.
        </p>
    </div>

    <div class="cards">
        <div class="card">
            <div>Health Score</div>
            <div class="number {% if health_score >= 90 %}good{% elif health_score >= 70 %}warn{% else %}urgent{% endif %}">
                {{ health_score }}%
            </div>
        </div>
        <div class="card"><div>Rostered Today</div><div class="number">{{ rostered_count }}</div></div>
        <div class="card"><div>Working Now</div><div class="number good">{{ currently_working }}</div></div>
        <div class="card"><div>On Break</div><div class="number warn">{{ on_break }}</div></div>
        <div class="card"><div>Urgent Issues</div><div class="number urgent">{{ urgent_count }}</div></div>
        <div class="card"><div>Payroll Issues</div><div class="number {% if payroll_problem_count > 0 %}urgent{% else %}good{% endif %}">{{ payroll_problem_count }}</div></div>
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
        <h2>Working Without Scheduled Shift</h2>
        <p class="muted">Staff currently working but not on today's roster.</p>

        <table>
            <tr>
                <th>Employee</th>
                <th>Status</th>
                <th>Worked</th>
                <th>Issue</th>
                <th>Manager Fix</th>
            </tr>

            {% for row in unrostered_working_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{{ row.status }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td class="urgent">{{ row.issue }}</td>
                <td><a class="button danger" href="/manager/corrections/?date={{ today|date:'Y-m-d' }}">Fix</a></td>
            </tr>
            {% empty %}
            <tr><td colspan="5" class="good">No unrostered staff currently working.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Manager Action Required</h2>
        <p class="muted">These should be reviewed first.</p>

        <table>
            <tr>
                <th>Employee</th>
                <th>Status</th>
                <th>Issue</th>
                <th>Worked</th>
                <th>Break</th>
                <th>Manager Fix</th>
            </tr>

            {% for row in urgent_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{{ row.status }}</td>
                <td class="urgent">{{ row.issue }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td>{{ row.break_minutes }} mins</td>
                <td><a class="button danger" href="/manager/corrections/?date={{ today|date:'Y-m-d' }}">Fix</a></td>
            </tr>
            {% empty %}
            <tr><td colspan="6" class="good">No urgent issues right now.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Payroll Status</h2>

        {% if payroll_problem_count > 0 %}
            <p class="urgent">{{ payroll_problem_count }} payroll issue(s) need review before export.</p>
            <a class="button danger" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Review Payroll Issues</a>
        {% else %}
            <p class="good">Payroll looks clean for the current week.</p>
            <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Open Weekly Payroll</a>
        {% endif %}
    </div>

    <div class="section">
        <h2>Operational Notes</h2>

        <table>
            <tr>
                <th>Employee</th>
                <th>Status</th>
                <th>Note</th>
            </tr>

            {% for row in operational_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{{ row.status }}</td>
                <td class="warn">{{ row.issue }}</td>
            </tr>
            {% empty %}
            <tr><td colspan="3" class="good">No operational notes.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Quick Actions</h2>
        <div class="actions">
            <a class="button" href="/manager/dashboard/">Dashboard</a>
            <a class="button" href="/clock/">Staff Clocking</a>
            <a class="button" href="/manager/upload-roster/">Upload Roster</a>
            <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Payroll</a>
            <a class="button" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Payroll Issues</a>
            <a class="button" href="/manager/corrections/?date={{ today|date:'Y-m-d' }}">Manager Corrections</a>
            <a class="button secondary" href="/admin/">System Admin</a>
            <a class="button secondary" href="/manager/logout/">Logout</a>
        </div>
    </div>

</div>

</body>
</html>
HTML

echo "Checking app..."
python manage.py check

echo "Restarting app..."
sudo systemctl restart restaurant_clocking

echo "Home dashboard fixed. Open /"
