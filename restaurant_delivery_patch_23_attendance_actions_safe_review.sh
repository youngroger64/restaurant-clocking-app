#!/usr/bin/env bash
set -euo pipefail

echo "=== Restaurant Clocking Patch 23: Attendance Actions and Safe Issue Review ==="
echo "Manager-focused changes:"
echo "  - Attendance issues no longer link to broken Fix/Edit clock page"
echo "  - Attendance rows explain: no clock edit needed unless they actually worked"
echo "  - Adds clear actions: Open Roster Manager / no payroll action needed"
echo "  - Strips date prefixes from issue text where possible"
echo "  - Makes Fix Day page safer if opened without employee/date"
echo

if [ ! -f "manage.py" ]; then
  echo "ERROR: Run from Django project root: cd ~/restaurant_clocking"
  exit 1
fi

stamp=$(date +%Y%m%d_%H%M%S)
mkdir -p "patch_backups_23_$stamp"
cp -f core/views.py "patch_backups_23_$stamp/views.py.before_patch23"
cp -f templates/payroll_problems.html "patch_backups_23_$stamp/payroll_problems.html.before_patch23" 2>/dev/null || true
cp -f templates/manager_fix_day.html "patch_backups_23_$stamp/manager_fix_day.html.before_patch23" 2>/dev/null || true

cat > /tmp/patch23_views.py <<'PY'
from pathlib import Path
import re

p = Path("core/views.py")
s = p.read_text()

new_func = '''def payroll_problems(request):
    # Manager-focused issue review.
    # Attendance issues and roster exceptions are not automatically payroll blockers.
    from core.compliance import get_week_rows
    import re as _re

    week_start = _patch_parse_week_start(request)
    week_end = week_start + timedelta(days=6)

    rows = get_week_rows(week_start, 39)
    issue_rows = [row for row in rows if row.get("warning") != "OK"]

    payroll_blockers = []
    attendance_issues = []
    roster_exceptions = []

    for row in issue_rows:
        raw_issue = row.get("warning") or row.get("issue") or ""
        issue = _re.sub(r"^\\\\d{4}-\\\\d{2}-\\\\d{2}:\\\\s*", "", raw_issue).strip()
        issue_l = issue.lower()

        row["issue_text"] = issue
        row["raw_issue_text"] = raw_issue

        if (
            "rostered but absent" in issue_l
            or "not arrived" in issue_l
            or "didn't clock in" in issue_l
            or "did not clock in" in issue_l
        ):
            row["category"] = "Attendance"
            row["issue_text"] = "Didn't clock in for scheduled shift"
            row["manager_explanation"] = "This is a staffing record. Payroll can calculate 0 worked hours unless this should be paid leave."
            row["manager_action"] = "No clock edit is needed unless the employee actually worked."
            attendance_issues.append(row)

        elif (
            "working but not rostered" in issue_l
            or "not rostered" in issue_l
        ):
            row["category"] = "Roster Exception"
            row["issue_text"] = "Worked without matching roster shift"
            row["manager_explanation"] = "The worked hours can be calculated, but the manager should confirm this was approved cover or update the roster."
            row["manager_action"] = "Update the roster if this was approved cover. Do not delete valid worked hours."
            roster_exceptions.append(row)

        else:
            row["category"] = "Payroll"
            row["manager_explanation"] = "Clock records need review before payroll export."
            row["manager_action"] = "Fix the clock events before payroll export."
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

matches = list(re.finditer(r"^def payroll_problems\\(request\\):", s, flags=re.M))
if not matches:
    raise SystemExit("Could not find payroll_problems in core/views.py")

start = matches[-1].start()
m = re.search(r"\\n(?=def |class |# -------------------------------------------------------------------)", s[start+1:])
end = len(s) if not m else start + 1 + m.start()

s = s[:start] + new_func + "\\n\\n" + s[end:]
p.write_text(s)
PY

python3 /tmp/patch23_views.py

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
        .note { background: #fff7ed; border-left: 4px solid #f59e0b; padding: 12px; margin-top: 12px; }
    </style>
</head>
<body>
<div class="container">

    <div class="section">
        <h1>Issue Review</h1>
        <p class="muted">
            This is not just a payroll page. It separates issues into payroll blockers, attendance issues, and roster exceptions.
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
                <td>
                    {% if row.employee_number and row.date %}
                        <a class="button danger" href="/manager/fix-day/?employee_number={{ row.employee_number }}&date={{ row.date|date:'Y-m-d' }}&week_start={{ week_start|date:'Y-m-d' }}">Fix Clock Events</a>
                    {% else %}
                        <a class="button danger" href="/manager/corrections/">Open Corrections</a>
                    {% endif %}
                </td>
            </tr>
            {% empty %}
            <tr><td colspan="8" class="green">No payroll blockers found.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Attendance Issues</h2>
        <p class="muted">
            These are staffing records, not clocking errors. If someone did not work, payroll can calculate 0 hours.
        </p>
        <div class="note">
            For a missed shift, the manager decision is usually: leave as no-show, update the roster, or record paid leave elsewhere.
            Do not add fake clock events just to remove the warning.
        </div>
        <table>
            <tr>
                <th>Employee</th>
                <th>Roster</th>
                <th>Issue</th>
                <th>Manager Action</th>
            </tr>
            {% for row in attendance_issues %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{{ row.roster }}</td>
                <td class="orange">{{ row.issue_text }}<br><span class="muted">{{ row.manager_explanation }}</span></td>
                <td>
                    <span class="muted">{{ row.manager_action }}</span><br>
                    <a class="button secondary" href="/manager/upload-roster/?week_start={{ week_start|date:'Y-m-d' }}">Open Roster Manager</a>
                </td>
            </tr>
            {% empty %}
            <tr><td colspan="4" class="green">No attendance issues found.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Roster Exceptions</h2>
        <p class="muted">
            These usually mean someone worked without a matching roster shift. That can be valid cover, but it should be manager-approved.
        </p>
        <table>
            <tr>
                <th>Employee</th>
                <th>Status</th>
                <th>Worked</th>
                <th>Break</th>
                <th>Issue</th>
                <th>Manager Action</th>
            </tr>
            {% for row in roster_exceptions %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{{ row.status }}</td>
                <td>{{ row.worked_hours }}</td>
                <td>{{ row.break_minutes }} mins</td>
                <td class="blue">{{ row.issue_text }}<br><span class="muted">{{ row.manager_explanation }}</span></td>
                <td>
                    <span class="muted">{{ row.manager_action }}</span><br>
                    <a class="button" href="/manager/upload-roster/?week_start={{ week_start|date:'Y-m-d' }}">Open Roster Manager</a>
                    <a class="button secondary" href="/manager/corrections/">Open Corrections</a>
                </td>
            </tr>
            {% empty %}
            <tr><td colspan="6" class="green">No roster exceptions found.</td></tr>
            {% endfor %}
        </table>
    </div>

    <p>
        <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Summary</a>
        <a class="button secondary" href="/">Dashboard</a>
        <a class="button secondary" href="/manager/upload-roster/?week_start={{ week_start|date:'Y-m-d' }}">Roster Manager</a>
    </p>

</div>
</body>
</html>
HTML

python3 <<'PY'
from pathlib import Path

p = Path("templates/manager_fix_day.html")
if p.exists():
    s = p.read_text()

    if "Cannot review this day" not in s:
        s = s.replace(
            '{% if error %}<p class="warn">{{ error }}</p>{% endif %}',
            '''{% if error %}
        <p class="warn">{{ error }}</p>
        {% if "Missing employee number or date" in error %}
            <div class="section warning">
                <h2>Cannot review this day</h2>
                <p>This page needs both an employee and a date. Go back to Issue Review or Manager Corrections and choose a specific row.</p>
                <p>
                    <a class="button secondary" href="/manager/payroll-problems/">Issue Review</a>
                    <a class="button secondary" href="/manager/corrections/">Manager Corrections</a>
                </p>
            </div>
        {% endif %}
    {% endif %}'''
        )

    p.write_text(s)
PY

echo "Checking Python syntax..."
python -m py_compile core/views.py

echo "Running Django checks..."
python manage.py check

echo
echo "Patch 23 complete."
echo "Restart:"
echo "  sudo systemctl restart restaurant_clocking"
