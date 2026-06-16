#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-$PWD}"
cd "$APP_DIR"

if [ ! -f manage.py ] || [ ! -d core ] || [ ! -d templates ]; then
  echo "Run this from the restaurant_clocking project root, or set APP_DIR=/path/to/restaurant_clocking" >&2
  exit 1
fi

STAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="backups_patch_29_${STAMP}"
mkdir -p "$BACKUP_DIR/templates" "$BACKUP_DIR/core"
cp templates/home.html "$BACKUP_DIR/templates/home.html" 2>/dev/null || true
cp templates/manager_today.html "$BACKUP_DIR/templates/manager_today.html" 2>/dev/null || true
cp core/views.py "$BACKUP_DIR/core/views.py" 2>/dev/null || true

cat > templates/home.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Restaurant Operations Dashboard</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 18px; color: #06152b; }
        .container { max-width: 1320px; margin: auto; }
        .header, .section { background: white; border: 1px solid #dde3ea; border-radius: 13px; padding: 22px; margin-bottom: 16px; }
        h1 { margin: 0 0 12px 0; font-size: 32px; }
        h2 { margin-top: 0; font-size: 25px; }
        .muted { color: #475467; }
        .actions { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 18px; }
        .button { display: inline-block; padding: 11px 16px; background: #4b5563; color: white; text-decoration: none; border-radius: 7px; font-weight: bold; }
        .button-primary { background: #2563eb; }
        .button-danger { background: #b42318; }
        .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 14px; margin: 18px 0; }
        .card { background: white; border: 1px solid #dde3ea; border-radius: 13px; padding: 18px; }
        .card-title { font-size: 15px; }
        .number { font-size: 36px; font-weight: bold; margin-top: 8px; color: #06152b; }
        .green { color: #087f3f; }
        .orange { color: #b7791f; }
        .red { color: #b42318; }
        table { width: 100%; border-collapse: collapse; margin-top: 12px; }
        th, td { border-bottom: 1px solid #dde3ea; padding: 11px 10px; text-align: left; vertical-align: top; }
        th { background: #f8fafc; }
        .badge { display: inline-block; padding: 5px 9px; border-radius: 999px; font-size: 13px; font-weight: bold; white-space: nowrap; }
        .badge-working, .break-ok { background: #dcfce7; color: #166534; }
        .badge-break, .break-on, .break-warn { background: #ffedd5; color: #9a3412; }
        .badge-out { background: #dbeafe; color: #1e40af; }
        .badge-missing, .break-urgent { background: #fee2e2; color: #991b1b; }
        .urgent { color: #b42318; font-weight: bold; }
        .operational { color: #b7791f; font-weight: bold; }
        .ok { color: #087f3f; font-weight: bold; }
        .small { font-size: 13px; color: #667085; margin-top: 5px; }
        .section-title-line { display: flex; justify-content: space-between; align-items: baseline; gap: 12px; flex-wrap: wrap; }
    </style>
</head>
<body>
<div class="container">

    <div class="header">
        <h1>Restaurant Operations Dashboard</h1>
        <p class="muted">Service day: {{ today|date:"F j, Y" }}. Current time: {{ now_time|date:"H:i" }}. Live staff and urgent actions first.</p>
        <div class="actions">
            <a class="button" href="/manager/upload-roster/">Roster Manager</a>
            <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Payroll</a>
            <a class="button" href="/admin/">Admin / Setup</a>
            <a class="button button-primary" href="/clock/">Staff Clocking</a>
        </div>
    </div>

    <div class="cards">
        <div class="card"><div class="card-title">👥 Working Now</div><div class="number green">{{ currently_working }}</div></div>
        <div class="card"><div class="card-title">☕ On Break Now</div><div class="number orange">{{ on_break }}</div></div>
        <div class="card"><div class="card-title">⏰ Late / Absent Now</div><div class="number {% if not_arrived_now_count > 0 %}red{% else %}green{% endif %}">{{ not_arrived_now_count }}</div></div>
        <div class="card"><div class="card-title">☕ Breaks Needing Action</div><div class="number {% if break_attention_count > 0 %}orange{% else %}green{% endif %}">{{ break_attention_count }}</div></div>
        <div class="card"><div class="card-title">⚠ Payroll Blockers</div><div class="number {% if payroll_problem_count > 0 %}red{% else %}green{% endif %}">{{ payroll_problem_count }}</div></div>
    </div>

    <div class="section">
        <h2>Current Staff</h2>
        <p class="muted">Who is clocked in or on break now. Late-night shifts stay here until clock-out.</p>
        <table>
            <tr><th>Employee</th><th>Status</th><th>Roster</th><th>Clocked In</th><th>Worked</th><th>Break Taken</th><th>Break Status</th><th>Manager Action</th></tr>
            {% for row in live_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{% if row.is_on_break %}<span class="badge badge-break">On Break</span>{% else %}<span class="badge badge-working">Working</span>{% endif %}</td>
                <td>{{ row.roster }}</td>
                <td>{{ row.first_in }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td>{{ row.break_minutes }} mins</td>
                <td><span class="badge {{ row.break_css }}">{{ row.break_status }}</span></td>
                <td>{{ row.break_action }}</td>
            </tr>
            {% empty %}
            <tr><td colspan="8">No staff are currently clocked in or on break.</td></tr>
            {% endfor %}
        </table>
    </div>

    {% if break_attention_count > 0 %}
    <div class="section">
        <h2>Breaks Needing Action</h2>
        <table>
            <tr><th>Employee</th><th>Roster</th><th>Status</th><th>Worked</th><th>Break Taken</th><th>Break Status</th><th>Manager Action</th></tr>
            {% for row in break_attention_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{{ row.roster }}</td>
                <td>{{ row.status }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td>{{ row.break_minutes }} mins</td>
                <td><span class="badge {{ row.break_css }}">{{ row.break_status }}</span></td>
                <td class="operational">{{ row.break_action }}</td>
            </tr>
            {% endfor %}
        </table>
    </div>
    {% endif %}

    <div class="section">
        <div class="section-title-line">
            <h2>Service Day Roster</h2>
            <span class="muted">Rostered: {{ rostered_count }}</span>
        </div>
        <p class="muted">Full roster for this service day. Use this for review; the top of the page is for what needs attention now.</p>
        <table>
            <tr><th>Employee</th><th>Roster</th><th>Status</th><th>Clocked In</th><th>Issue</th><th>Worked</th><th>Break</th><th>Break Status</th></tr>
            {% for row in roster_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{{ row.roster }}</td>
                <td>
                    {% if row.is_working %}<span class="badge badge-working">Working</span>
                    {% elif row.is_on_break %}<span class="badge badge-break">On Break</span>
                    {% elif row.has_activity %}<span class="badge badge-out">Finished / Activity</span>
                    {% elif row.is_operational %}<span class="badge badge-missing">Late / Absent</span>
                    {% else %}<span class="badge badge-out">Due Later</span>{% endif %}
                </td>
                <td>{{ row.first_in }}</td>
                <td class="{% if row.is_urgent %}urgent{% elif row.is_operational %}operational{% else %}ok{% endif %}">{{ row.issue }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td>{{ row.break_minutes }} mins</td>
                <td><span class="badge {{ row.break_css }}">{{ row.break_status }}</span><div class="small">{{ row.break_action }}</div></td>
            </tr>
            {% empty %}
            <tr><td colspan="8">No roster or clock activity for this service day.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Payroll Readiness</h2>
        {% if payroll_problem_count > 0 %}
            <p class="urgent"><strong>Payroll is NOT READY.</strong> {{ payroll_problem_count }} blocker(s) must be fixed before Sage export.</p>
            <a class="button button-danger" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Review Payroll Problems</a>
        {% else %}
            <p class="ok"><strong>Payroll looks clean</strong> for the current week.</p>
            <a class="button button-primary" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Open Weekly Payroll</a>
        {% endif %}
    </div>

</div>
</body>
</html>
HTML

python - <<'PY'
from pathlib import Path
p = Path('templates/manager_today.html')
if p.exists():
    s = p.read_text()
    s = s.replace('☕ Break Attention', '☕ Breaks Needing Action')
    s = s.replace('⏰ Late / Absent', '⏰ Late / Absent Now')
    s = s.replace('Live Manager Dashboard', 'Current Manager Dashboard')
    s = s.replace('Operational day view. Live issues first; old morning lateness stays in Review Today unless it affects payroll.', 'Live staff and urgent actions first. The full service-day roster is for review underneath.')
    s = s.replace('<h2>Live Now</h2>', '<h2>Current Staff</h2>')
    s = s.replace('<h2>Breaks - Needs Attention</h2>', '<h2>Breaks Needing Action</h2>')
    s = s.replace('<h2>Review Today</h2>', '<h2>Service Day Roster Review</h2>')
    s = s.replace('No live staff or live issues.', 'No staff are currently clocked in or on break.')
    p.write_text(s)
PY

python -m py_compile core/views.py

echo "Patch 29 applied. Backup saved to $BACKUP_DIR"
echo "What changed: dashboard wording and ordering are now manager-first: current staff/actions at the top, full service-day roster underneath, and no developer explanation text."
