#!/bin/bash
set -e

echo "Backing up homepage..."
cp templates/home.html templates/home.html.manager_home_bak 2>/dev/null || true

echo "Adding manager operations homepage..."

cat >> core/views.py <<'PY'


# -------------------------------------------------------------------
# Manager Operations Homepage
# -------------------------------------------------------------------

from core.compliance import get_day_rows, get_week_rows


def home_page(request):
    today = timezone.localdate()
    week_start = today - timedelta(days=today.weekday())

    rows = get_day_rows(today)
    week_rows = get_week_rows(week_start, 39)

    rostered_now = 0
    clocked_in_now = 0
    missing_now = []

    now_time = timezone.localtime().time()

    for row in rows:
        if row["rostered"] and row["roster"] != "Not rostered":
            # Simple approximation for MVP: count rostered staff with activity/working status
            rostered_now += 1

            if row["is_working"] or row["is_on_break"]:
                clocked_in_now += 1
            elif not row["has_activity"]:
                missing_now.append(row["employee"])

    urgent_rows = [row for row in rows if row["is_urgent"]]
    operational_rows = [row for row in rows if row["is_operational"]]

    payroll_problem_rows = [
        row for row in week_rows
        if row["warning"] != "OK"
    ]

    total_staff = len(rows)
    urgent_count = len(urgent_rows)
    operational_count = len(operational_rows)
    payroll_problem_count = len(payroll_problem_rows)

    if total_staff > 0:
        health_score = int(((total_staff - urgent_count) / total_staff) * 100)
    else:
        health_score = 100

    return render(request, "home.html", {
        "today": today,
        "week_start": week_start,
        "rows": rows,
        "urgent_rows": urgent_rows[:5],
        "operational_rows": operational_rows[:5],
        "rostered_count": sum(1 for row in rows if row["rostered"]),
        "currently_working": sum(1 for row in rows if row["is_working"]),
        "on_break": sum(1 for row in rows if row["is_on_break"]),
        "clocked_out": sum(1 for row in rows if row["is_clocked_out"]),
        "urgent_count": urgent_count,
        "operational_count": operational_count,
        "health_score": health_score,
        "payroll_problem_count": payroll_problem_count,
        "rostered_now": rostered_now,
        "clocked_in_now": clocked_in_now,
        "missing_now": missing_now[:5],
    })
PY

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
        h2 { margin-top: 0; }
        .muted { color: #666; }
        .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 14px; margin: 18px 0; }
        .card { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 18px; }
        .number { font-size: 36px; font-weight: bold; margin-top: 8px; }
        .good { color: #1a7f37; font-weight: bold; }
        .warn { color: #b7791f; font-weight: bold; }
        .urgent { color: #b42318; font-weight: bold; }
        .actions { display: flex; flex-wrap: wrap; gap: 10px; }
        .button { display: inline-block; padding: 12px 14px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; }
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
            Today: {{ today }}. Start here to see staff status, urgent issues, roster coverage and payroll readiness.
        </p>
    </div>

    <div class="cards">
        <div class="card">
            <div>Health Score</div>
            <div class="number {% if health_score >= 90 %}good{% elif health_score >= 70 %}warn{% else %}urgent{% endif %}">
                {{ health_score }}%
            </div>
        </div>
        <div class="card">
            <div>Rostered Today</div>
            <div class="number">{{ rostered_count }}</div>
        </div>
        <div class="card">
            <div>Working Now</div>
            <div class="number">{{ currently_working }}</div>
        </div>
        <div class="card">
            <div>On Break</div>
            <div class="number">{{ on_break }}</div>
        </div>
        <div class="card">
            <div>Urgent Issues</div>
            <div class="number urgent">{{ urgent_count }}</div>
        </div>
        <div class="card">
            <div>Payroll Problems</div>
            <div class="number {% if payroll_problem_count > 0 %}urgent{% else %}good{% endif %}">
                {{ payroll_problem_count }}
            </div>
        </div>
    </div>

    <div class="section">
        <h2>Manager Action Required</h2>
        <p class="muted">These are the items to check first.</p>

        {% if urgent_rows %}
            <table>
                <tr>
                    <th>Employee</th>
                    <th>Status</th>
                    <th>Issue</th>
                    <th>Worked</th>
                    <th>Break</th>
                </tr>
                {% for row in urgent_rows %}
                <tr>
                    <td>{{ row.employee }}</td>
                    <td>{{ row.status }}</td>
                    <td class="urgent">{{ row.issue }}</td>
                    <td>{{ row.worked_hours }}h</td>
                    <td>{{ row.break_minutes }} mins</td>
                </tr>
                {% endfor %}
            </table>
            <p><a class="button danger" href="/manager/today/">Open Today's Dashboard</a></p>
        {% else %}
            <p class="good">No urgent issues right now.</p>
        {% endif %}
    </div>

    <div class="section">
        <h2>Current Shift Coverage</h2>
        <p>
            Rostered today: <strong>{{ rostered_count }}</strong> |
            Working now: <strong>{{ currently_working }}</strong> |
            On break: <strong>{{ on_break }}</strong>
        </p>

        {% if missing_now %}
            <p class="urgent">Missing / not clocked in:</p>
            <ul>
                {% for name in missing_now %}
                    <li>{{ name }}</li>
                {% endfor %}
            </ul>
        {% else %}
            <p class="good">No rostered staff currently marked as missing.</p>
        {% endif %}
    </div>

    <div class="section">
        <h2>Payroll Status</h2>

        {% if payroll_problem_count > 0 %}
            <p class="urgent">{{ payroll_problem_count }} payroll issue(s) need review before export.</p>
            <a class="button danger" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">
                Review Payroll Problems
            </a>
        {% else %}
            <p class="good">Payroll looks clean for the current week.</p>
            <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">
                Open Weekly Payroll
            </a>
        {% endif %}
    </div>

    <div class="section">
        <h2>Operational Notes</h2>
        <p class="muted">Useful notes such as late arrivals. These are not urgent compliance alerts.</p>

        {% if operational_rows %}
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
                {% endfor %}
            </table>
        {% else %}
            <p class="good">No operational notes.</p>
        {% endif %}
    </div>

    <div class="section">
        <h2>Quick Actions</h2>
        <div class="actions">
            <a class="button" href="/manager/today/">Today's Staff</a>
            <a class="button" href="/clock/">Staff Clocking</a>
            <a class="button" href="/manager/upload-roster/">Upload Roster</a>
            <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Payroll</a>
            <a class="button" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Payroll Problems</a>
            <a class="button secondary" href="/manager/add-missing-event/">Add Missing Event</a>
            <a class="button secondary" href="/admin/">System Admin</a>
            <a class="button secondary" href="/manager/logout/">Logout</a>
        </div>
    </div>

</div>

</body>
</html>
HTML

echo "Running Django check..."
python manage.py check

echo "Restarting app..."
sudo systemctl restart restaurant_clocking

echo "Manager homepage upgrade complete."
echo "Open /"
