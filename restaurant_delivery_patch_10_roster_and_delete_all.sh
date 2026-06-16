#!/usr/bin/env bash
set -euo pipefail

echo "=== Restaurant Clocking Patch 10: Manager Roster View + Delete All Events ==="
echo "Adds:"
echo "  - Delete all clock events for selected employee/day on Fix Day page"
echo "  - Homepage: Today's Roster section showing who is in, not arrived, late, clocked in time"
echo "  - Needs Attention stays focused on shift/roster issues"
echo

if [ ! -f "manage.py" ]; then
  echo "ERROR: Run this from Django project root: cd ~/restaurant_clocking"
  exit 1
fi

stamp=$(date +%Y%m%d_%H%M%S)
mkdir -p "patch_backups_10_$stamp"
cp -f core/views.py "patch_backups_10_$stamp/views.py.before_patch10"
cp -f templates/home.html "patch_backups_10_$stamp/home.html.before_patch10"
cp -f templates/manager_fix_day.html "patch_backups_10_$stamp/manager_fix_day.html.before_patch10" 2>/dev/null || true

cat > /tmp/patch10_views.py <<'PY'
from pathlib import Path
import re

p = Path("core/views.py")
s = p.read_text()

# ------------------------------------------------------------------
# Replace home_page with a version that includes roster_rows.
# ------------------------------------------------------------------
new_home = '''def home_page(request):
    # Restaurant Operations Dashboard landing page.
    # The key manager view is: who is rostered, who is in, who is missing, and what needs attention.
    from core.compliance import get_day_rows, get_week_rows

    today = timezone.localdate()
    week_start = today - timedelta(days=today.weekday())

    rows = get_day_rows(today)
    week_rows = get_week_rows(week_start, 39)

    working_rows = [
        row for row in rows
        if row.get("is_working") or row.get("is_on_break")
    ]

    roster_rows = [
        row for row in rows
        if row.get("rostered")
    ]

    urgent_rows = [row for row in rows if row.get("is_urgent")]
    operational_rows = [row for row in rows if row.get("is_operational")]
    needs_attention_rows = urgent_rows + operational_rows

    unrostered_rows = [
        row for row in working_rows
        if not row.get("rostered")
    ]

    rostered_count = len(roster_rows)
    currently_working = sum(1 for row in rows if row.get("is_working"))
    on_break = sum(1 for row in rows if row.get("is_on_break"))

    not_arrived_count = sum(
        1 for row in roster_rows
        if not row.get("has_activity")
        and (
            "not arrived" in row.get("issue", "").lower()
            or "absent" in row.get("issue", "").lower()
            or "no clock-in" in row.get("issue", "").lower()
            or row.get("status") == "No activity"
        )
    )

    arrived_count = sum(
        1 for row in roster_rows
        if row.get("has_activity")
    )

    late_count = sum(
        1 for row in needs_attention_rows
        if "late" in row.get("issue", "").lower()
    )

    payroll_problem_rows = [
        row for row in week_rows
        if row.get("warning") != "OK"
    ]
    payroll_issue_count = len(payroll_problem_rows)

    return render(request, "home.html", {
        "today": today,
        "week_start": week_start,
        "rows": rows,
        "roster_rows": roster_rows,
        "working_rows": working_rows,
        "needs_attention_rows": needs_attention_rows[:8],
        "unrostered_rows": unrostered_rows[:8],
        "rostered_count": rostered_count,
        "arrived_count": arrived_count,
        "currently_working": currently_working,
        "on_break": on_break,
        "not_arrived_count": not_arrived_count,
        "late_count": late_count,
        "urgent_count": len(urgent_rows),
        "operational_count": len(operational_rows),
        "payroll_problem_count": payroll_issue_count,
    })
'''

matches = list(re.finditer(r"^def home_page\(request\):", s, flags=re.M))
if not matches:
    raise SystemExit("Could not find home_page in core/views.py")
start = matches[-1].start()
m = re.search(r"\n(?=def |class |# -------------------------------------------------------------------)", s[start+1:])
end = len(s) if not m else start + 1 + m.start()
s = s[:start] + new_home + "\n\n" + s[end:]


# ------------------------------------------------------------------
# Patch manager_fix_day to support delete_all_for_day.
# ------------------------------------------------------------------
matches = list(re.finditer(r"^def manager_fix_day\(request\):", s, flags=re.M))
if not matches:
    raise SystemExit("Could not find manager_fix_day in core/views.py")

start = matches[-1].start()
m = re.search(r"\n(?=def |class |# -------------------------------------------------------------------)", s[start+1:])
end = len(s) if not m else start + 1 + m.start()
func = s[start:end]

# Insert delete_all branch before delete branch if not present.
if 'mode == "delete_all"' not in func:
    marker = '        elif mode == "delete":'
    insert = '''        elif mode == "delete_all":
            reason = (request.POST.get("reason") or "").strip()
            confirm = request.POST.get("confirm_delete_all")

            if confirm != "yes":
                error = "Please tick the confirmation box before deleting all events for this day."
            elif not reason:
                error = "Please enter a reason before deleting all events."
            else:
                qs = ClockEvent.objects.filter(
                    employee=employee,
                    timestamp__date=event_date
                )
                count = qs.count()
                qs.delete()
                message = f"Deleted {count} event(s) for {employee.name} on {event_date}. Reason: {reason}"

'''
    if marker not in func:
        raise SystemExit("Could not find delete branch in manager_fix_day.")
    func = func.replace(marker, insert + marker)

s = s[:start] + func + s[end:]
p.write_text(s)
PY

python3 /tmp/patch10_views.py

# ------------------------------------------------------------------
# Replace homepage template.
# ------------------------------------------------------------------
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
        .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 14px; margin: 18px 0; }
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
            The main job of this page is to show who was rostered, who has arrived, and who needs a follow-up.
        </p>
        <div class="actions">
            <a class="button" href="/clock/">Staff Clocking</a>
            <a class="button" href="/manager/today/">Full Today View</a>
            <a class="button secondary" href="/manager/upload-roster/">Upload Roster</a>
            <a class="button secondary" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Payroll</a>
        </div>
    </div>

    <div class="cards">
        <div class="card"><div class="card-title">📋 Rostered Today</div><div class="number">{{ rostered_count }}</div></div>
        <div class="card"><div class="card-title">✅ Arrived</div><div class="number green">{{ arrived_count }}</div></div>
        <div class="card"><div class="card-title">👥 Working</div><div class="number">{{ currently_working }}</div></div>
        <div class="card"><div class="card-title">☕ On Break</div><div class="number orange">{{ on_break }}</div></div>
        <div class="card"><div class="card-title">🚫 Not Arrived</div><div class="number {% if not_arrived_count > 0 %}red{% endif %}">{{ not_arrived_count }}</div></div>
        <div class="card"><div class="card-title">⚠ Payroll Issues</div><div class="number {% if payroll_problem_count > 0 %}red{% else %}green{% endif %}">{{ payroll_problem_count }}</div></div>
    </div>

    <div class="section">
        <h2>Today's Roster</h2>
        <p class="muted">
            This is the manager's main view: who was rostered, whether they are in, and when they clocked in.
            Blue means on time. Red means late or absent.
        </p>
        <table>
            <tr>
                <th>Employee</th>
                <th>Roster</th>
                <th>Status</th>
                <th>Clocked In</th>
                <th>Punctuality</th>
                <th>Worked</th>
                <th>Break</th>
            </tr>
            {% for row in roster_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{{ row.roster }}</td>
                <td>
                    {% if row.is_on_break %}
                        <span class="badge badge-orange">On Break</span>
                    {% elif row.is_working %}
                        <span class="badge badge-green">Working</span>
                    {% elif row.has_activity %}
                        <span class="badge badge-blue">{{ row.status }}</span>
                    {% else %}
                        <span class="badge badge-red">Not Arrived</span>
                    {% endif %}
                </td>
                <td>{{ row.first_in }}</td>
                <td>
                    {% if not row.has_activity %}
                        <span class="badge badge-red">Not arrived</span>
                    {% elif "late" in row.issue|lower %}
                        <span class="badge badge-red">Late</span>
                    {% else %}
                        <span class="badge badge-blue">On time</span>
                    {% endif %}
                </td>
                <td>{{ row.worked_hours }}h</td>
                <td>{{ row.break_minutes }} mins</td>
            </tr>
            {% empty %}
            <tr><td colspan="7" class="muted">No roster has been uploaded for today.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Staff Working Now</h2>
        <p class="muted">A shorter live floor view of staff currently clocked in or on break.</p>
        <table>
            <tr>
                <th>Employee</th>
                <th>Status</th>
                <th>Roster</th>
                <th>Clocked In</th>
                <th>Worked</th>
                <th>Break</th>
            </tr>
            {% for row in working_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{% if row.is_on_break %}<span class="badge badge-orange">On Break</span>{% else %}<span class="badge badge-green">Working</span>{% endif %}</td>
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
        <p class="muted">
            Shift-specific issues: not arrived, late arrivals, break due, missed breaks, unrostered work, and clock-in/out problems.
        </p>
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
                <td>{% if row.is_urgent %}<span class="badge badge-red">Payroll</span>{% else %}<span class="badge badge-orange">Operational</span>{% endif %}</td>
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
        <h2>Payroll Status</h2>
        <p>
            {% if payroll_problem_count > 0 %}
                <span class="red">⚠ {{ payroll_problem_count }} payroll issue{{ payroll_problem_count|pluralize }} need review before export.</span>
            {% else %}
                <span class="green">✓ Payroll looks ready for export.</span>
            {% endif %}
        </p>
        <p class="muted">Payroll issues may include missing clock-outs, invalid clock sequences, long shifts, or unresolved corrections for the current week.</p>
        <div class="actions">
            <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Open Weekly Payroll</a>
            <a class="button secondary" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Open Payroll Problems</a>
        </div>
    </div>

    <div class="section">
        <h2>Staff Exceptions</h2>
        <p class="muted">Less common exceptions, such as staff clocked in without being on today's roster.</p>
        <table>
            <tr><th>Employee</th><th>Status</th><th>Worked</th><th>Break</th><th>Issue</th></tr>
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

# ------------------------------------------------------------------
# Patch manager_fix_day.html to include Delete All.
# ------------------------------------------------------------------
if [ -f templates/manager_fix_day.html ]; then
python3 <<'PY'
from pathlib import Path

p = Path("templates/manager_fix_day.html")
s = p.read_text()

if "delete_all" not in s:
    insert = '''
    <div class="section" style="border: 2px solid #b42318;">
        <h2>Delete all events for this day</h2>
        <p class="warn">
            Use this when test data or a badly entered day should be cleared and rebuilt.
            This deletes all events shown above for this employee on this date.
        </p>
        <form method="post" onsubmit="return confirm('Delete ALL events for this employee on this date?');">
            {% csrf_token %}
            <input type="hidden" name="mode" value="delete_all">
            <input type="hidden" name="employee_number" value="{{ employee.employee_number }}">
            <input type="hidden" name="event_date" value="{{ event_date|date:'Y-m-d' }}">
            <p>
                <label><input type="checkbox" name="confirm_delete_all" value="yes"> I understand this will delete all events for this employee on this day</label>
            </p>
            <p>
                <label>Reason</label><br>
                <textarea name="reason" required placeholder="Example: clearing test events before entering correct shift"></textarea>
            </p>
            <button class="danger" type="submit">Delete All Events For This Day</button>
        </form>
    </div>
'''
    # Put before Add missing event if possible, otherwise before final links.
    if "<h2>Add missing event</h2>" in s:
        s = s.replace("<h2>Add missing event</h2>", insert + "\n<h2>Add missing event</h2>", 1)
    elif "</body>" in s:
        s = s.replace("</body>", insert + "\n</body>", 1)
    else:
        s += insert

# Ensure danger CSS exists.
if ".danger" not in s:
    s = s.replace("</style>", ".danger { background: #b42318; color: white; }\n</style>")

p.write_text(s)
PY
else
    echo "WARNING: templates/manager_fix_day.html not found; delete-all UI not patched."
fi

echo "Checking Python syntax..."
python -m py_compile core/views.py

echo "Running Django checks..."
python manage.py check

echo
echo "Patch 10 complete."
echo "Restart:"
echo "  sudo systemctl restart restaurant_clocking"
