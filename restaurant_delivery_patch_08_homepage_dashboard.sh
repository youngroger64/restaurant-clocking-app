#!/usr/bin/env bash
set -euo pipefail

echo "=== Restaurant Clocking Patch 08: Landing Homepage Dashboard Redesign ==="
echo "This patch updates the page at / — the Restaurant Operations Dashboard."
echo "It changes the manager's first view from issue-first to operations-first."
echo

if [ ! -f "manage.py" ]; then
  echo "ERROR: Run this from Django project root: cd ~/restaurant_clocking"
  exit 1
fi

stamp=$(date +%Y%m%d_%H%M%S)
mkdir -p "patch_backups_08_$stamp"
cp -f core/views.py "patch_backups_08_$stamp/views.py.before_home_dashboard"
cp -f templates/home.html "patch_backups_08_$stamp/home.html.before_home_dashboard"

python3 <<'PY'
from pathlib import Path
import re

views_path = Path("core/views.py")
views = views_path.read_text()

new_home = """def home_page(request):
    # Restaurant Operations Dashboard landing page.
    # Owner questions answered here:
    # - Who is working now?
    # - Who is on break?
    # - Who is late or absent?
    # - Are there payroll issues?
    # - What needs attention?
    from core.compliance import get_day_rows, get_week_rows

    today = timezone.localdate()
    week_start = today - timedelta(days=today.weekday())

    rows = get_day_rows(today)
    week_rows = get_week_rows(week_start, 39)

    working_rows = [
        row for row in rows
        if row.get("is_working") or row.get("is_on_break")
    ]

    urgent_rows = [row for row in rows if row.get("is_urgent")]
    operational_rows = [row for row in rows if row.get("is_operational")]
    needs_attention_rows = urgent_rows + operational_rows

    unrostered_rows = [
        row for row in working_rows
        if not row.get("rostered")
    ]

    late_count = sum(
        1 for row in needs_attention_rows
        if "late" in row.get("issue", "").lower()
    )

    not_arrived_count = sum(
        1 for row in needs_attention_rows
        if (
            "not arrived" in row.get("issue", "").lower()
            or "absent" in row.get("issue", "").lower()
            or "no clock-in" in row.get("issue", "").lower()
        )
    )

    payroll_problem_rows = [
        row for row in week_rows
        if row.get("warning") != "OK"
    ]

    rostered_count = sum(1 for row in rows if row.get("rostered"))
    currently_working = sum(1 for row in rows if row.get("is_working"))
    on_break = sum(1 for row in rows if row.get("is_on_break"))

    payroll_issue_count = len(payroll_problem_rows)
    payroll_ready = 100
    if week_rows:
        payroll_ready = max(
            0,
            min(100, round(((len(week_rows) - payroll_issue_count) / len(week_rows)) * 100))
        )

    return render(request, "home.html", {
        "today": today,
        "week_start": week_start,
        "rows": rows,
        "working_rows": working_rows,
        "needs_attention_rows": needs_attention_rows[:8],
        "unrostered_rows": unrostered_rows[:8],
        "rostered_count": rostered_count,
        "currently_working": currently_working,
        "on_break": on_break,
        "late_count": late_count,
        "not_arrived_count": not_arrived_count,
        "urgent_count": len(urgent_rows),
        "operational_count": len(operational_rows),
        "payroll_problem_count": payroll_issue_count,
        "payroll_ready": payroll_ready,
    })
"""

matches = list(re.finditer(r"^def home_page\(request\):", views, flags=re.M))
if not matches:
    raise SystemExit("Could not find home_page in core/views.py")

start = matches[-1].start()
next_match = re.search(r"\n(?=def |class |# -------------------------------------------------------------------)", views[start+1:])
end = len(views) if not next_match else start + 1 + next_match.start()

views = views[:start] + new_home + "\n\n" + views[end:]
views_path.write_text(views)
PY

cat > templates/home.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Restaurant Operations Dashboard</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #111827; }
        .container { max-width: 1250px; margin: auto; }
        .header, .section { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 22px; margin-bottom: 18px; }
        h1 { margin: 0 0 8px 0; font-size: 32px; }
        h2 { margin: 0 0 8px 0; }
        .muted { color: #666; }
        .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(165px, 1fr)); gap: 14px; margin: 18px 0; }
        .card { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 18px; }
        .card-title { font-size: 15px; }
        .number { font-size: 36px; font-weight: bold; margin-top: 8px; }
        .green { color: #1a7f37; font-weight: bold; }
        .red { color: #b42318; font-weight: bold; }
        .orange { color: #b7791f; font-weight: bold; }
        table { width: 100%; border-collapse: collapse; margin-top: 12px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 11px; text-align: left; }
        th { background: #f9fafb; }
        .button { display: inline-block; padding: 11px 14px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin: 5px 8px 5px 0; }
        .secondary { background: #4b5563; }
        .danger { background: #b42318; }
        .badge { display: inline-block; padding: 4px 8px; border-radius: 999px; font-size: 13px; font-weight: bold; }
        .badge-green { background: #dcfce7; color: #166534; }
        .badge-orange { background: #ffedd5; color: #9a3412; }
        .badge-red { background: #fee2e2; color: #991b1b; }
        .summary { background: #f9fafb; padding: 12px; border-radius: 8px; margin-top: 10px; }
        .actions { margin-top: 14px; }
    </style>
</head>
<body>
<div class="container">

    <div class="header">
        <h1>Restaurant Operations Dashboard</h1>
        <p class="muted">
            Today: {{ today|date:"F j, Y" }}.
            Start here to see who is working, who is on break, who is late, and whether payroll needs attention.
        </p>
        <div class="actions">
            <a class="button" href="/clock/">Staff Clocking</a>
            <a class="button" href="/manager/today/">Full Today View</a>
            <a class="button secondary" href="/manager/upload-roster/">Upload Roster</a>
            <a class="button secondary" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Payroll</a>
        </div>
    </div>

    <div class="cards">
        <div class="card">
            <div class="card-title">👥 Working Now</div>
            <div class="number">{{ currently_working }}</div>
        </div>
        <div class="card">
            <div class="card-title">☕ On Break</div>
            <div class="number orange">{{ on_break }}</div>
        </div>
        <div class="card">
            <div class="card-title">⏰ Late</div>
            <div class="number {% if late_count > 0 %}red{% endif %}">{{ late_count }}</div>
        </div>
        <div class="card">
            <div class="card-title">🚫 Not Arrived</div>
            <div class="number {% if not_arrived_count > 0 %}red{% endif %}">{{ not_arrived_count }}</div>
        </div>
        <div class="card">
            <div class="card-title">⚠ Payroll Issues</div>
            <div class="number {% if payroll_problem_count > 0 %}red{% else %}green{% endif %}">{{ payroll_problem_count }}</div>
        </div>
        <div class="card">
            <div class="card-title">✅ Payroll Ready</div>
            <div class="number {% if payroll_ready < 80 %}red{% elif payroll_ready < 100 %}orange{% else %}green{% endif %}">{{ payroll_ready }}%</div>
        </div>
    </div>

    <div class="section">
        <h2>Staff Working Now</h2>
        <p class="muted">This is the main floor view. It shows who is currently clocked in or on break.</p>
        <table>
            <tr>
                <th>Employee</th>
                <th>Status</th>
                <th>Roster</th>
                <th>First In</th>
                <th>Worked</th>
                <th>Break</th>
            </tr>
            {% for row in working_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>
                    {% if row.is_on_break %}
                        <span class="badge badge-orange">On Break</span>
                    {% else %}
                        <span class="badge badge-green">{{ row.status }}</span>
                    {% endif %}
                </td>
                <td>{{ row.roster }}</td>
                <td>{{ row.first_in }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td>{{ row.break_minutes }} mins</td>
            </tr>
            {% empty %}
            <tr><td colspan="6" class="muted">No staff are currently clocked in.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Needs Attention</h2>
        <p class="muted">Items the manager may need to check. Payroll issues are red; operational notes are amber.</p>
        <table>
            <tr>
                <th>Employee</th>
                <th>Type</th>
                <th>Status</th>
                <th>Issue</th>
                <th>Worked</th>
                <th>Break</th>
            </tr>
            {% for row in needs_attention_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>
                    {% if row.is_urgent %}
                        <span class="badge badge-red">Payroll</span>
                    {% else %}
                        <span class="badge badge-orange">Operational</span>
                    {% endif %}
                </td>
                <td>{{ row.status }}</td>
                <td class="{% if row.is_urgent %}red{% else %}orange{% endif %}">{{ row.issue }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td>{{ row.break_minutes }} mins</td>
            </tr>
            {% empty %}
            <tr><td colspan="6" class="green">No issues need attention.</td></tr>
            {% endfor %}
        </table>
        <div class="actions">
            <a class="button danger" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Review Payroll Problems</a>
            <a class="button secondary" href="/manager/corrections/">Manager Corrections</a>
        </div>
    </div>

    <div class="section">
        <h2>Today Staffing Summary</h2>
        <div class="summary">
            <strong>Rostered today:</strong> {{ rostered_count }} &nbsp; | &nbsp;
            <strong>Working now:</strong> {{ currently_working }} &nbsp; | &nbsp;
            <strong>On break:</strong> {{ on_break }} &nbsp; | &nbsp;
            <strong>Late:</strong> {{ late_count }} &nbsp; | &nbsp;
            <strong>Not arrived:</strong> {{ not_arrived_count }}
        </div>
    </div>

    <div class="section">
        <h2>Payroll Readiness</h2>
        <p>
            <strong>Payroll Ready:</strong>
            <span class="{% if payroll_ready < 80 %}red{% elif payroll_ready < 100 %}orange{% else %}green{% endif %}">
                {{ payroll_ready }}%
            </span>
        </p>
        <p><strong>Payroll issues remaining this week:</strong> {{ payroll_problem_count }}</p>
        <p class="muted">Resolve payroll issues before exporting weekly payroll.</p>
        <div class="actions">
            <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Open Weekly Payroll</a>
            <a class="button secondary" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Open Payroll Problems</a>
        </div>
    </div>

    <div class="section">
        <h2>Staff Exceptions</h2>
        <p class="muted">Less common exceptions, such as staff clocked in without being on today's roster.</p>
        <table>
            <tr>
                <th>Employee</th>
                <th>Status</th>
                <th>Worked</th>
                <th>Break</th>
                <th>Issue</th>
            </tr>
            {% for row in unrostered_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{{ row.status }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td>{{ row.break_minutes }} mins</td>
                <td class="orange">Working but not rostered</td>
            </tr>
            {% empty %}
            <tr><td colspan="5" class="green">No unrostered staff are currently working.</td></tr>
            {% endfor %}
        </table>
    </div>

</div>
</body>
</html>
HTML

echo "Checking Python syntax..."
python -m py_compile core/views.py

echo "Running Django checks..."
python manage.py check

echo
echo "Patch 08 complete."
echo "Restart:"
echo "  sudo systemctl restart restaurant_clocking"
