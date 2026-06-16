#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(pwd)"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="backups_patch_27_${STAMP}"
mkdir -p "$BACKUP_DIR"

cp -f core/views.py "$BACKUP_DIR/views.py" 2>/dev/null || true
cp -f templates/home.html "$BACKUP_DIR/home.html" 2>/dev/null || true
cp -f templates/manager_today.html "$BACKUP_DIR/manager_today.html" 2>/dev/null || true

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
        .explain { background: #f8fafc; border: 1px solid #e5e7eb; border-radius: 10px; padding: 12px; margin-top: 10px; }
    </style>
</head>
<body>
<div class="container">

    <div class="header">
        <h1>Restaurant Operations Dashboard</h1>
        <p class="muted">Today: {{ today|date:"F j, Y" }}. Current time: {{ now_time|date:"H:i" }}. Live team first, then today's roster.</p>
        <div class="actions">
            <a class="button" href="/manager/upload-roster/">Roster Manager</a>
            <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Payroll</a>
            <a class="button" href="/admin/">Admin / Setup</a>
            <a class="button button-primary" href="/clock/">Staff Clocking</a>
        </div>
    </div>

    <div class="cards">
        <div class="card"><div class="card-title">👥 Working Now</div><div class="number green">{{ currently_working }}</div></div>
        <div class="card"><div class="card-title">☕ On Break</div><div class="number orange">{{ on_break }}</div></div>
        <div class="card"><div class="card-title">⏰ Not Arrived Now</div><div class="number {% if not_arrived_now_count > 0 %}red{% endif %}">{{ not_arrived_now_count }}</div></div>
        <div class="card"><div class="card-title">📋 Rostered Today</div><div class="number">{{ rostered_count }}</div></div>
        <div class="card"><div class="card-title">☕ Break Attention</div><div class="number {% if break_attention_count > 0 %}orange{% else %}green{% endif %}">{{ break_attention_count }}</div></div>
        <div class="card"><div class="card-title">⚠ Payroll Blockers</div><div class="number {% if payroll_problem_count > 0 %}red{% else %}green{% endif %}">{{ payroll_problem_count }}</div></div>
    </div>

    <div class="section">
        <h2>Live Team</h2>
        <p class="muted">Who is currently clocked in or on break. If a shift runs late, they stay here until they clock out.</p>
        <table>
            <tr><th>Employee</th><th>Status</th><th>Roster</th><th>Clocked In</th><th>Worked</th><th>Break Taken</th><th>Break Status</th><th>Break Action</th></tr>
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

    <div class="section">
        <h2>Breaks - Needs Attention</h2>
        <p class="muted">This is the missing piece from the previous patch: not just break minutes, but whether a break is due soon, overdue, or OK.</p>
        <div class="explain">
            <strong>Rule used:</strong> heads-up at 4h worked, 15 min break risk after 4.5h, 30 min total break risk after 6h.
            This is calculated from clock events, not from an extra roster column.
        </div>
        <table>
            <tr><th>Employee</th><th>Roster</th><th>Status</th><th>Worked</th><th>Break Taken</th><th>Break Status</th><th>Action</th></tr>
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
            {% empty %}
            <tr><td colspan="7" class="ok">No break issues right now.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Today's Roster</h2>
        <p class="muted">Full-day roster. Future shifts show as Due Later. Past shifts with no clock-in show as Didn't Clock In. Break status is shown for every employee.</p>
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
                    {% elif row.is_operational %}<span class="badge badge-missing">Didn't Clock In</span>
                    {% else %}<span class="badge badge-out">Due Later</span>{% endif %}
                </td>
                <td>{{ row.first_in }}</td>
                <td class="{% if row.is_urgent %}urgent{% elif row.is_operational %}operational{% else %}ok{% endif %}">{{ row.issue }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td>{{ row.break_minutes }} mins</td>
                <td><span class="badge {{ row.break_css }}">{{ row.break_status }}</span><div class="small">{{ row.break_action }}</div></td>
            </tr>
            {% empty %}
            <tr><td colspan="8">No roster or clock activity for today.</td></tr>
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

cat > templates/manager_today.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Live Manager Dashboard</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 18px; color: #06152b; }
        .container { max-width: 1320px; margin: auto; }
        .header, .section { background: white; border: 1px solid #dde3ea; border-radius: 13px; padding: 22px; margin-bottom: 16px; }
        .muted { color: #475467; }
        .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 14px; margin: 18px 0; }
        .card { background: white; border: 1px solid #dde3ea; border-radius: 13px; padding: 18px; }
        .number { font-size: 36px; font-weight: bold; margin-top: 8px; }
        .green { color: #087f3f; } .orange { color: #b7791f; } .red { color: #b42318; }
        table { width: 100%; border-collapse: collapse; margin-top: 12px; }
        th, td { border-bottom: 1px solid #dde3ea; padding: 11px 10px; text-align: left; vertical-align: top; }
        th { background: #f8fafc; }
        .badge { display: inline-block; padding: 5px 9px; border-radius: 999px; font-size: 13px; font-weight: bold; white-space: nowrap; }
        .badge-working, .break-ok { background: #dcfce7; color: #166534; }
        .badge-break, .break-on, .break-warn { background: #ffedd5; color: #9a3412; }
        .badge-out { background: #dbeafe; color: #1e40af; }
        .break-urgent { background: #fee2e2; color: #991b1b; }
        .urgent { color: #b42318; font-weight: bold; }
        .operational { color: #b7791f; font-weight: bold; }
        .ok { color: #087f3f; font-weight: bold; }
        .button { display: inline-block; padding: 10px 13px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 8px; margin-bottom: 8px; }
        .secondary { background: #4b5563; }
        input, button { padding: 8px; }
        .small { font-size: 13px; color: #667085; margin-top: 5px; }
    </style>
</head>
<body>
<div class="container">
    <div class="header">
        <h1>Live Manager Dashboard</h1>
        <p class="muted">Operational day view. Live issues first; old morning lateness stays in Review Today unless it affects payroll.</p>
        <form method="get">Date: <input type="date" name="date" value="{{ selected_date|date:'Y-m-d' }}"> <button type="submit">View Date</button></form>
        <p><a class="button secondary" href="/">Home</a><a class="button secondary" href="/clock/">Staff Clocking</a><a class="button secondary" href="/manager/upload-roster/">Upload Roster</a></p>
    </div>

    <div class="cards">
        <div class="card"><div>👥 Working Now</div><div class="number green">{{ currently_working }}</div></div>
        <div class="card"><div>☕ On Break</div><div class="number orange">{{ on_break }}</div></div>
        <div class="card"><div>☕ Break Attention</div><div class="number {% if break_attention_count > 0 %}orange{% else %}green{% endif %}">{{ break_attention_count }}</div></div>
        <div class="card"><div>⏰ Late / Absent</div><div class="number {% if late_absent_count > 0 %}red{% endif %}">{{ late_absent_count }}</div></div>
        <div class="card"><div>⚠ Payroll Blockers</div><div class="number {% if payroll_issues_count > 0 %}red{% else %}green{% endif %}">{{ payroll_issues_count }}</div></div>
    </div>

    <div class="section">
        <h2>Live Now</h2>
        <table>
            <tr><th>Employee</th><th>Status</th><th>Roster</th><th>Clocked In</th><th>Worked</th><th>Break Taken</th><th>Break Status</th><th>Action</th><th>Issue</th></tr>
            {% for row in live_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{% if row.is_on_break %}<span class="badge badge-break">On Break</span>{% else %}<span class="badge badge-working">Working</span>{% endif %}</td>
                <td>{{ row.roster }}</td><td>{{ row.first_in }}</td><td>{{ row.worked_hours }}h</td><td>{{ row.break_minutes }} mins</td>
                <td><span class="badge {{ row.break_css }}">{{ row.break_status }}</span></td>
                <td>{{ row.break_action }}</td>
                <td class="{% if row.is_urgent %}urgent{% elif row.is_operational %}operational{% else %}ok{% endif %}">{{ row.issue }}</td>
            </tr>
            {% empty %}<tr><td colspan="9">No live staff or live issues.</td></tr>{% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Breaks - Needs Attention</h2>
        <table>
            <tr><th>Employee</th><th>Status</th><th>Worked</th><th>Break Taken</th><th>Break Status</th><th>Action</th></tr>
            {% for row in break_attention_rows %}
            <tr><td>{{ row.employee }}</td><td>{{ row.status }}</td><td>{{ row.worked_hours }}h</td><td>{{ row.break_minutes }} mins</td><td><span class="badge {{ row.break_css }}">{{ row.break_status }}</span></td><td class="operational">{{ row.break_action }}</td></tr>
            {% empty %}<tr><td colspan="6" class="ok">No break issues right now.</td></tr>{% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Review Today</h2>
        <table>
            <tr><th>No</th><th>Employee</th><th>Roster</th><th>First In</th><th>Last Out</th><th>Status</th><th>Worked</th><th>Break</th><th>Break Status</th><th>Issue</th><th>Action</th></tr>
            {% for row in review_rows %}
            <tr>
                <td>{{ row.employee_number }}</td><td>{{ row.employee }}</td><td>{{ row.roster }}</td><td>{{ row.first_in }}</td><td>{{ row.last_out }}</td><td>{{ row.status }}</td><td>{{ row.worked_hours }}h</td><td>{{ row.break_minutes }} mins</td>
                <td><span class="badge {{ row.break_css }}">{{ row.break_status }}</span><div class="small">{{ row.break_action }}</div></td>
                <td class="{% if row.is_urgent %}urgent{% elif row.is_operational %}operational{% else %}ok{% endif %}">{{ row.issue }}</td>
                <td><a class="button secondary" href="/manager/fix-day/?employee_number={{ row.employee_number }}&event_date={{ row.date|date:'Y-m-d' }}">Fix / Edit</a></td>
            </tr>
            {% empty %}<tr><td colspan="11">No roster or clock activity for this date.</td></tr>{% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Payroll Status</h2>
        {% if payroll_issues_count > 0 %}
            <p class="urgent"><strong>Payroll is NOT READY.</strong> {{ payroll_issues_count }} blocker(s) must be fixed before Sage export.</p>
            <a class="button" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Review Payroll Problems</a>
        {% else %}
            <p class="ok"><strong>Payroll looks ready</strong> for the week starting {{ week_start }}.</p>
            <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Open Weekly Summary</a>
        {% endif %}
    </div>
</div>
</body>
</html>
HTML

cat >> core/views.py <<'PY'

# -------------------------------------------------------------------
# Delivery patch 27: make break status visible on home/today dashboards
# -------------------------------------------------------------------
from django.contrib.auth.decorators import login_required as _dp27_login_required
from core.compliance import (
    get_day_rows as _dp27_get_day_rows,
    payroll_is_ready as _dp27_payroll_is_ready,
)


def _dp27_week_start(day):
    return day - timedelta(days=day.weekday())


def _dp27_live_rows(rows):
    live = []
    seen = set()
    for row in rows:
        if row.get("is_working") or row.get("is_on_break") or row.get("is_urgent"):
            key = row.get("employee_number")
            if key not in seen:
                live.append(row)
                seen.add(key)
    return live


def _dp27_break_attention_rows(rows):
    return [
        row for row in rows
        if row.get("is_working") or row.get("is_on_break")
        if row.get("break_css") in ["break-warn", "break-urgent", "break-on"]
    ]


def _dp27_roster_rows(rows):
    return [row for row in rows if row.get("rostered") or row.get("has_activity")]


def _dp27_not_arrived_now(rows):
    return [
        row for row in rows
        if row.get("rostered")
        and not row.get("has_activity")
        and row.get("is_operational")
    ]


def home_page(request):
    today = timezone.localdate()
    week_start = _dp27_week_start(today)
    rows = _dp27_get_day_rows(today)
    live_rows = _dp27_live_rows(rows)
    break_attention_rows = _dp27_break_attention_rows(rows)
    roster_rows = _dp27_roster_rows(rows)
    not_arrived_rows = _dp27_not_arrived_now(rows)
    payroll_ready_bool, payroll_problem_rows = _dp27_payroll_is_ready(week_start)

    return render(request, "home.html", {
        "today": today,
        "now_time": timezone.localtime(timezone.now()),
        "week_start": week_start,
        "rows": rows,
        "live_rows": live_rows,
        "break_attention_rows": break_attention_rows,
        "roster_rows": roster_rows,
        "not_arrived_now_count": len(not_arrived_rows),
        "currently_working": sum(1 for row in rows if row.get("is_working")),
        "on_break": sum(1 for row in rows if row.get("is_on_break")),
        "rostered_count": sum(1 for row in rows if row.get("rostered")),
        "break_attention_count": len(break_attention_rows),
        "payroll_problem_count": len(payroll_problem_rows),
        "payroll_ready": payroll_ready_bool,
    })


@_dp27_login_required
def manager_today_dashboard(request):
    selected_date_str = request.GET.get("date", timezone.localdate().strftime("%Y-%m-%d"))
    selected_date = datetime.strptime(selected_date_str, "%Y-%m-%d").date()
    week_start = _dp27_week_start(selected_date)
    rows = _dp27_get_day_rows(selected_date)
    live_rows = _dp27_live_rows(rows)
    break_attention_rows = _dp27_break_attention_rows(rows)
    review_rows = _dp27_roster_rows(rows)

    urgent_rows = [row for row in rows if row.get("is_urgent")]
    operational_rows = [row for row in rows if row.get("is_operational")]
    late_count = sum(1 for row in operational_rows if "late" in row.get("issue", "").lower())
    not_arrived_count = len(_dp27_not_arrived_now(rows))
    payroll_ready_bool, payroll_problem_rows = _dp27_payroll_is_ready(week_start)

    return render(request, "manager_today.html", {
        "selected_date": selected_date,
        "week_start": week_start,
        "rows": rows,
        "live_rows": live_rows,
        "break_attention_rows": break_attention_rows,
        "review_rows": review_rows,
        "urgent_rows": urgent_rows,
        "operational_rows": operational_rows,
        "late_count": late_count,
        "not_arrived_count": not_arrived_count,
        "late_absent_count": late_count + not_arrived_count,
        "currently_working": sum(1 for row in rows if row.get("is_working")),
        "on_break": sum(1 for row in rows if row.get("is_on_break")),
        "rostered_count": sum(1 for row in rows if row.get("rostered")),
        "break_attention_count": len(break_attention_rows),
        "payroll_issues_count": len(payroll_problem_rows),
        "payroll_ready": 100 if payroll_ready_bool else 0,
    })
PY

python -m py_compile core/views.py core/compliance.py

echo "Patch 27 applied. Backup saved to $BACKUP_DIR"
echo "What changed: visible Break Status + Break Action columns, Breaks Needs Attention section, and Break Attention count card."
