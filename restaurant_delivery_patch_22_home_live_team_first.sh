#!/usr/bin/env bash
set -euo pipefail

echo "=== Restaurant Clocking Patch 22: Home Page Final Manager Flow ==="
echo "Changes:"
echo "  - Home page becomes live-team first"
echo "  - Removes Full Today View button from homepage"
echo "  - Working Now counts anyone currently clocked in, even if they are past roster time"
echo

if [ ! -f "manage.py" ]; then
  echo "ERROR: Run from Django project root: cd ~/restaurant_clocking"
  exit 1
fi

stamp=$(date +%Y%m%d_%H%M%S)
mkdir -p "patch_backups_22_$stamp"
cp -f core/views.py "patch_backups_22_$stamp/views.py.before_patch22"
cp -f templates/home.html "patch_backups_22_$stamp/home.html.before_patch22" 2>/dev/null || true

cat > /tmp/patch22_views.py <<'PY'
from pathlib import Path
import re

p = Path("core/views.py")
s = p.read_text()

new_home = '''def home_page(request):
    # Restaurant Operations Dashboard.
    # Manager logic:
    # 1) Who is physically working/on break now?
    # 2) What happened to today's roster?
    # 3) What needs manager review?
    from core.compliance import get_day_rows, get_week_rows

    today = timezone.localdate()
    now_dt = timezone.localtime()
    now_time = now_dt.time()
    week_start = today - timedelta(days=today.weekday())

    rows = get_day_rows(today)
    week_rows = get_week_rows(week_start, 39)

    roster_shifts_today = RosterShift.objects.select_related("employee").filter(
        shift_date=today
    ).order_by("start_time", "employee__name")

    later_employee_numbers = set()
    current_employee_numbers = set()
    finished_employee_numbers = set()

    for shift in roster_shifts_today:
        emp_no = str(shift.employee.employee_number)

        if shift.start_time <= shift.end_time:
            if shift.start_time <= now_time <= shift.end_time:
                current_employee_numbers.add(emp_no)
            elif now_time < shift.start_time:
                later_employee_numbers.add(emp_no)
            else:
                finished_employee_numbers.add(emp_no)
        else:
            if now_time >= shift.start_time or now_time <= shift.end_time:
                current_employee_numbers.add(emp_no)
            elif now_time < shift.start_time:
                later_employee_numbers.add(emp_no)
            else:
                finished_employee_numbers.add(emp_no)

    roster_rows = [row for row in rows if row.get("rostered")]
    live_rows = [row for row in rows if row.get("is_working") or row.get("is_on_break")]

    for row in rows:
        emp_no = str(row.get("employee_number"))
        issue = row.get("issue") or ""
        issue_l = issue.lower()
        status = row.get("status") or ""

        if row.get("is_on_break"):
            row["manager_status"] = "On Break"
            row["manager_status_class"] = "orange"
        elif row.get("is_working") or status == "Back from break":
            row["manager_status"] = "Working"
            row["manager_status_class"] = "green"
        elif emp_no in later_employee_numbers and not row.get("has_activity"):
            row["manager_status"] = "Due Later"
            row["manager_status_class"] = "blue"
        elif emp_no in current_employee_numbers and not row.get("has_activity"):
            row["manager_status"] = "Not Arrived"
            row["manager_status_class"] = "red"
        elif emp_no in finished_employee_numbers and not row.get("has_activity"):
            row["manager_status"] = "Didn't Clock In"
            row["manager_status_class"] = "red"
        elif row.get("has_activity") or status == "Clocked out":
            row["manager_status"] = "Finished Shift"
            row["manager_status_class"] = "blue"
        else:
            row["manager_status"] = "No Clock Records"
            row["manager_status_class"] = "red"

        if "rostered but absent" in issue_l:
            row["manager_issue"] = "Didn't clock in for shift"
        elif "working but not rostered" in issue_l:
            row["manager_issue"] = "Worked without matching roster shift"
        elif issue == "OK":
            row["manager_issue"] = ""
        else:
            row["manager_issue"] = issue

        if "working but not rostered" in issue_l or "not rostered" in issue_l:
            row["manager_issue_type"] = "Roster"
            row["manager_issue_type_class"] = "blue"
        elif "rostered but absent" in issue_l or "not arrived" in issue_l or "late" in issue_l:
            row["manager_issue_type"] = "Attendance"
            row["manager_issue_type_class"] = "orange"
        elif "clock" in issue_l or "break" in issue_l:
            row["manager_issue_type"] = "Clocking"
            row["manager_issue_type_class"] = "red"
        else:
            row["manager_issue_type"] = "Operational"
            row["manager_issue_type_class"] = "orange"

    needs_attention_rows = []
    for row in rows:
        issue_l = (row.get("issue") or "").lower()
        emp_no = str(row.get("employee_number"))

        include = False
        if "working but not rostered" in issue_l or "not rostered" in issue_l:
            include = True
        elif "check clock sequence" in issue_l or "missing clock" in issue_l or "open break" in issue_l:
            include = True
        elif "late" in issue_l:
            include = True
        elif ("rostered but absent" in issue_l or "not arrived" in issue_l) and emp_no in current_employee_numbers:
            include = True

        if include:
            needs_attention_rows.append(row)

    payroll_blockers = []
    for row in week_rows:
        warning = (row.get("warning") or "").lower()
        if row.get("warning") == "OK":
            continue
        if "rostered but absent" in warning or "working but not rostered" in warning or "not rostered" in warning:
            continue
        payroll_blockers.append(row)

    return render(request, "home.html", {
        "today": today,
        "now_time": now_dt,
        "week_start": week_start,
        "rows": rows,
        "roster_rows": roster_rows,
        "live_rows": live_rows,
        "needs_attention_rows": needs_attention_rows[:10],
        "rostered_today_count": len(roster_rows),
        "working_now_count": sum(1 for row in live_rows if row.get("is_working")),
        "on_break_count": sum(1 for row in live_rows if row.get("is_on_break")),
        "not_arrived_now_count": sum(1 for row in roster_rows if row.get("manager_status") == "Not Arrived"),
        "payroll_blocker_count": len(payroll_blockers),
    })
'''

matches = list(re.finditer(r"^def home_page\(request\):", s, flags=re.M))
if not matches:
    raise SystemExit("Could not find home_page in core/views.py")

start = matches[-1].start()
m = re.search(r"\n(?=def |class |# -------------------------------------------------------------------)", s[start+1:])
end = len(s) if not m else start + 1 + m.start()

s = s[:start] + new_home + "\n\n" + s[end:]
p.write_text(s)
PY

python3 /tmp/patch22_views.py

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
        .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(175px, 1fr)); gap: 14px; margin: 18px 0; }
        .card { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 18px; }
        .card-title { font-size: 15px; }
        .number { font-size: 36px; font-weight: bold; margin-top: 8px; }
        .green { color: #1a7f37; font-weight: bold; }
        .blue { color: #2563eb; font-weight: bold; }
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
        .badge-blue { background: #dbeafe; color: #1d4ed8; }
        .badge-orange { background: #ffedd5; color: #9a3412; }
        .badge-red { background: #fee2e2; color: #991b1b; }
    </style>
</head>
<body>
<div class="container">

    <div class="header">
        <h1>Restaurant Operations Dashboard</h1>
        <p class="muted">
            Today: {{ today|date:"F j, Y" }}.
            Current time: {{ now_time|date:"H:i" }}.
            Live team first, then today's roster.
        </p>
        <div>
            <a class="button secondary" href="/manager/upload-roster/">Roster Manager</a>
            <a class="button secondary" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Payroll</a>
            <a class="button secondary" href="/admin/">Admin / Setup</a>
        </div>
    </div>

    <div class="cards">
        <div class="card"><div class="card-title">👥 Working Now</div><div class="number green">{{ working_now_count }}</div></div>
        <div class="card"><div class="card-title">☕ On Break</div><div class="number orange">{{ on_break_count }}</div></div>
        <div class="card"><div class="card-title">🚫 Not Arrived Now</div><div class="number {% if not_arrived_now_count > 0 %}red{% endif %}">{{ not_arrived_now_count }}</div></div>
        <div class="card"><div class="card-title">📋 Rostered Today</div><div class="number">{{ rostered_today_count }}</div></div>
        <div class="card"><div class="card-title">⚠ Payroll Blockers</div><div class="number {% if payroll_blocker_count > 0 %}red{% else %}green{% endif %}">{{ payroll_blocker_count }}</div></div>
    </div>

    <div class="section">
        <h2>Live Team</h2>
        <p class="muted">Who is currently clocked in or on break. If a shift runs late, they stay here until they clock out.</p>
        <table>
            <tr><th>Employee</th><th>Status</th><th>Roster</th><th>Clocked In</th><th>Worked</th><th>Break</th></tr>
            {% for row in live_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td><span class="badge badge-{{ row.manager_status_class }}">{{ row.manager_status }}</span></td>
                <td>{{ row.roster }}</td>
                <td>{{ row.first_in }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td>{{ row.break_minutes }} mins</td>
            </tr>
            {% empty %}
            <tr><td colspan="6" class="muted">Nobody is currently clocked in.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Today's Roster</h2>
        <p class="muted">Full-day roster. Future shifts show as Due Later. Past shifts with no clock-in show as Didn't Clock In.</p>
        <table>
            <tr><th>Employee</th><th>Roster</th><th>Status</th><th>Clocked In</th><th>Issue</th><th>Worked</th><th>Break</th></tr>
            {% for row in roster_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{{ row.roster }}</td>
                <td><span class="badge badge-{{ row.manager_status_class }}">{{ row.manager_status }}</span></td>
                <td>{{ row.first_in }}</td>
                <td class="{% if row.manager_issue_type_class == 'red' %}red{% elif row.manager_issue_type_class == 'orange' %}orange{% else %}muted{% endif %}">{{ row.manager_issue }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td>{{ row.break_minutes }} mins</td>
            </tr>
            {% empty %}
            <tr><td colspan="7" class="muted">No roster uploaded for today.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Needs Attention</h2>
        <p class="muted">Manager review items only: late arrivals, roster exceptions, current not-arrivals, and clocking problems.</p>
        <table>
            <tr><th>Employee</th><th>Type</th><th>Status</th><th>Issue</th><th>Worked</th><th>Break</th></tr>
            {% for row in needs_attention_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td><span class="badge badge-{{ row.manager_issue_type_class }}">{{ row.manager_issue_type }}</span></td>
                <td><span class="badge badge-{{ row.manager_status_class }}">{{ row.manager_status }}</span></td>
                <td class="{% if row.manager_issue_type_class == 'red' %}red{% elif row.manager_issue_type_class == 'orange' %}orange{% else %}blue{% endif %}">{{ row.manager_issue }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td>{{ row.break_minutes }} mins</td>
            </tr>
            {% empty %}
            <tr><td colspan="6" class="green">No issues need attention.</td></tr>
            {% endfor %}
        </table>
        <p><a class="button danger" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Open Issue Review</a></p>
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
echo "Patch 22 complete."
echo "Restart:"
echo "  sudo systemctl restart restaurant_clocking"
