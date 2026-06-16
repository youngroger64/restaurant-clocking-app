#!/usr/bin/env bash
set -euo pipefail

echo "=== Restaurant Clocking Patch 19: Separate Payroll, Attendance, and Roster Exceptions ==="
echo "Manager-focused changes:"
echo "  - Rostered but absent is no longer treated as a payroll blocker"
echo "  - Working but not rostered becomes a roster exception, not a payroll blocker"
echo "  - Issue Review page has three sections"
echo

if [ ! -f "manage.py" ]; then
  echo "ERROR: Run from Django project root: cd ~/restaurant_clocking"
  exit 1
fi

stamp=$(date +%Y%m%d_%H%M%S)
mkdir -p "patch_backups_19_$stamp"
cp -f core/views.py "patch_backups_19_$stamp/views.py.before_patch19"
cp -f templates/payroll_problems.html "patch_backups_19_$stamp/payroll_problems.html.before_patch19" 2>/dev/null || true
cp -f templates/manager_fix_day.html "patch_backups_19_$stamp/manager_fix_day.html.before_patch19" 2>/dev/null || true

cat > /tmp/patch19_views.py <<'PY'
from pathlib import Path
import re

p = Path("core/views.py")
s = p.read_text()

new_func = '''def payroll_problems(request):
    # Manager-focused issue review.
    # Not every issue is a payroll blocker.
    from core.compliance import get_week_rows

    week_start = _patch_parse_week_start(request)
    week_end = week_start + timedelta(days=6)

    rows = get_week_rows(week_start, 39)
    issue_rows = [row for row in rows if row.get("warning") != "OK"]

    payroll_blockers = []
    attendance_issues = []
    roster_exceptions = []

    for row in issue_rows:
        issue = row.get("warning") or row.get("issue") or ""
        issue_l = issue.lower()
        row["issue_text"] = issue

        if (
            "rostered but absent" in issue_l
            or "not arrived" in issue_l
            or "didn't clock in" in issue_l
            or "did not clock in" in issue_l
        ):
            row["category"] = "Attendance"
            row["manager_explanation"] = "This affects staffing, but payroll can calculate 0 worked hours unless leave is paid."
            attendance_issues.append(row)

        elif (
            "working but not rostered" in issue_l
            or "not rostered" in issue_l
        ):
            row["category"] = "Roster Exception"
            row["manager_explanation"] = "The hours can be calculated, but the manager should confirm this was approved cover or add it to the roster."
            roster_exceptions.append(row)

        else:
            row["category"] = "Payroll"
            row["manager_explanation"] = "Clock records need review before payroll export."
            payroll_blockers.append(row)

    return render(request, "payroll_problems.html", {
        "week_start": week_start,
        "week_end": week_end,
        "rows": issue_rows,
        "payroll_blockers": payroll_blockers,
        "attendance_issues": attendance_issues,
        "roster_exceptions": roster_exceptions,
        "payroll_blocker_count": len(payroll_blockers),
        "attendance_issue_count": len(attendance_issues),
        "roster_exception_count": len(roster_exceptions),
        "total_issue_count": len(issue_rows),
    })
'''

matches = list(re.finditer(r"^def payroll_problems\(request\):", s, flags=re.M))
if not matches:
    raise SystemExit("Could not find payroll_problems in core/views.py")

start = matches[-1].start()
m = re.search(r"\n(?=def |class |# -------------------------------------------------------------------)", s[start+1:])
end = len(s) if not m else start + 1 + m.start()

s = s[:start] + new_func + "\n\n" + s[end:]
p.write_text(s)
PY

python3 /tmp/patch19_views.py

cat > templates/payroll_problems.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Issue Review</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #111827; }
        .container { max-width: 1250px; margin: auto; }
        .section { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 22px; margin-bottom: 18px; }
        h1 { margin: 0 0 8px 0; }
        .muted { color: #666; }
        .red { color: #b42318; font-weight: bold; }
        .orange { color: #b7791f; font-weight: bold; }
        .green { color: #1a7f37; font-weight: bold; }
        .blue { color: #2563eb; font-weight: bold; }
        table { width: 100%; border-collapse: collapse; margin-top: 12px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 11px; text-align: left; vertical-align: top; }
        th { background: #f9fafb; }
        input { padding: 8px; }
        .button { display: inline-block; padding: 10px 13px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 8px; margin-bottom: 8px; }
        .secondary { background: #4b5563; }
        .danger { background: #b42318; }
        .amber { background: #b7791f; }
        .summary { background: #f9fafb; padding: 12px; border-radius: 8px; margin-top: 10px; }
    </style>
</head>
<body>
<div class="container">

    <div class="section">
        <h1>Issue Review</h1>
        <p class="muted">
            This page separates issues into payroll blockers, attendance issues, and roster exceptions.
            Only payroll blockers normally stop payroll export.
        </p>

        <form method="get">
            <label>Week Start:</label>
            <input type="date" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
            <button class="button" type="submit">View Week</button>
        </form>

        <h2>{{ week_start|date:"F j, Y" }} to {{ week_end|date:"F j, Y" }}</h2>

        <div class="summary">
            <strong class="{% if payroll_blocker_count > 0 %}red{% else %}green{% endif %}">
                Payroll blockers: {{ payroll_blocker_count }}
            </strong>
            &nbsp; | &nbsp;
            <strong class="orange">Attendance issues: {{ attendance_issue_count }}</strong>
            &nbsp; | &nbsp;
            <strong class="blue">Roster exceptions: {{ roster_exception_count }}</strong>
        </div>
    </div>

    <div class="section">
        <h2>Payroll Blockers</h2>
        <p class="muted">These are clocking problems that can affect pay calculations. Review before exporting payroll.</p>
        <table>
            <tr>
                <th>Date</th><th>Employee</th><th>Roster</th><th>Status</th><th>Worked</th><th>Break</th><th>Problem</th><th>Action</th>
            </tr>
            {% for row in payroll_blockers %}
            <tr>
                <td>{{ row.date|date:"F j, Y" }}</td>
                <td>{{ row.employee }}</td>
                <td>{{ row.roster }}</td>
                <td>{{ row.status }}</td>
                <td>{{ row.worked_hours }}</td>
                <td>{{ row.break_minutes }} mins</td>
                <td class="red">{{ row.issue_text }}<br><span class="muted">{{ row.manager_explanation }}</span></td>
                <td><a class="button danger" href="/manager/fix-day/?employee_number={{ row.employee_number }}&date={{ row.date|date:'Y-m-d' }}&week_start={{ week_start|date:'Y-m-d' }}">Fix / Edit</a></td>
            </tr>
            {% empty %}
            <tr><td colspan="8" class="green">No payroll blockers found.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Attendance Issues</h2>
        <p class="muted">
            These are staffing issues, not payroll calculation errors. Payroll can calculate 0 worked hours unless the manager records paid leave separately.
        </p>
        <table>
            <tr>
                <th>Date</th><th>Employee</th><th>Roster</th><th>Status</th><th>Issue</th><th>Manager Action</th>
            </tr>
            {% for row in attendance_issues %}
            <tr>
                <td>{{ row.date|date:"F j, Y" }}</td>
                <td>{{ row.employee }}</td>
                <td>{{ row.roster }}</td>
                <td>{{ row.status }}</td>
                <td class="orange">{{ row.issue_text }}<br><span class="muted">{{ row.manager_explanation }}</span></td>
                <td><a class="button amber" href="/manager/fix-day/?employee_number={{ row.employee_number }}&date={{ row.date|date:'Y-m-d' }}&week_start={{ week_start|date:'Y-m-d' }}">Review</a></td>
            </tr>
            {% empty %}
            <tr><td colspan="6" class="green">No attendance issues found.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Roster Exceptions</h2>
        <p class="muted">
            These usually mean someone worked without a matching roster shift. This may be valid cover, but the manager should approve it or update the roster.
        </p>
        <table>
            <tr>
                <th>Date</th><th>Employee</th><th>Roster</th><th>Status</th><th>Worked</th><th>Issue</th><th>Manager Action</th>
            </tr>
            {% for row in roster_exceptions %}
            <tr>
                <td>{{ row.date|date:"F j, Y" }}</td>
                <td>{{ row.employee }}</td>
                <td>{{ row.roster }}</td>
                <td>{{ row.status }}</td>
                <td>{{ row.worked_hours }}</td>
                <td class="blue">{{ row.issue_text }}<br><span class="muted">{{ row.manager_explanation }}</span></td>
                <td>
                    <a class="button" href="/manager/upload-roster/?week_start={{ week_start|date:'Y-m-d' }}">Update Roster</a>
                    <a class="button secondary" href="/manager/fix-day/?employee_number={{ row.employee_number }}&date={{ row.date|date:'Y-m-d' }}&week_start={{ week_start|date:'Y-m-d' }}">Review Events</a>
                </td>
            </tr>
            {% empty %}
            <tr><td colspan="7" class="green">No roster exceptions found.</td></tr>
            {% endfor %}
        </table>
    </div>

    <p>
        <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Summary</a>
        <a class="button secondary" href="/">Today's Dashboard</a>
        <a class="button secondary" href="/manager/upload-roster/?week_start={{ week_start|date:'Y-m-d' }}">Roster Manager</a>
    </p>

</div>
</body>
</html>
HTML

# Improve Fix Day guidance for roster exceptions.
cat > /tmp/patch19_fixday.py <<'PY'
from pathlib import Path

p = Path("templates/manager_fix_day.html")
if not p.exists():
    raise SystemExit(0)

s = p.read_text()

if "This employee worked without a matching roster shift" not in s:
    marker = '<h2>Recommended manager action</h2>'
    replacement = '''<h2>Recommended manager action</h2>
        {% if "working but not rostered" in day.issue|lower %}
            <p class="warn">This employee worked without a matching roster shift.</p>
            <p>This may be valid cover. If it was approved, update the roster or leave the clock events as they are. Do not delete valid worked hours.</p>
            <p><a class="button" href="/manager/upload-roster/?week_start={{ week_start|date:'Y-m-d' }}">Open Roster Manager</a></p>
        {% elif "absent" in day.issue|lower or "not arrived" in day.issue|lower %}
            <p class="warn">This employee was rostered but has not clocked in.</p>
            <p>This is an attendance issue, not normally a payroll calculation problem. Contact the employee or shift manager. Only add a clock-in if the employee actually worked and forgot to clock in.</p>
        {% elif "clock" in day.issue|lower %}
            <p class="warn">The clock records look wrong. Review the events below and delete or add records as needed.</p>
        {% elif "late" in day.issue|lower %}
            <p class="warn">This employee arrived late. No clock correction is needed unless the clock-in time is wrong.</p>
        {% else %}
            <p class="ok">No obvious correction is required for this day.</p>
        {% endif %}
        {#'''
    if marker in s:
        s = s.replace(marker, replacement, 1)
        # comment out the old conditional until the end of that block by adding closing comment before Events section
        s = s.replace('<div class="section">\n        <h2>Events on this day</h2>', '#}\n    </div>\n\n    <div class="section">\n        <h2>Events on this day</h2>', 1)

p.write_text(s)
PY

python3 /tmp/patch19_fixday.py

echo "Checking Python syntax..."
python -m py_compile core/views.py

echo "Running Django checks..."
python manage.py check

echo
echo "Patch 19 complete."
echo "Restart:"
echo "  sudo systemctl restart restaurant_clocking"
