#!/usr/bin/env bash
set -euo pipefail

echo "== patch_41_payroll_export_safety_manager_flow =="
ROOT="$(pwd)"
echo "Project root: $ROOT"

if [ ! -f manage.py ] || [ ! -f core/views.py ]; then
  echo "ERROR: run this from the Django project root, e.g. cd ~/restaurant_clocking"
  exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="backups_patch_41_${STAMP}"
mkdir -p "$BACKUP_DIR"
cp core/views.py "$BACKUP_DIR/views.py"
cp templates/weekly_summary.html "$BACKUP_DIR/weekly_summary.html" 2>/dev/null || true
cp templates/payroll_problems.html "$BACKUP_DIR/payroll_problems.html" 2>/dev/null || true

python3 <<'PY'
from pathlib import Path

views = Path("core/views.py")
text = views.read_text()
old = '''@_patch_login_required\ndef export_sage_payroll_csv(request):\n    week_start = _patch_parse_week_start(request)\n    period_number = request.GET.get("period", "1")\n    standard_hours = float(request.GET.get("standard_hours", "39"))\n    include_header = request.GET.get("include_header") == "1"\n    rows = _patch_get_week_rows(week_start, standard_hours)\n\n    response = HttpResponse(content_type="text/csv")\n    response["Content-Disposition"] = 'attachment; filename="sage_payroll_export.csv"'\n    writer = csv.writer(response)\n\n    # Sage Payroll IE single-timesheet import order:\n    # period number, employee number, 0000, payment element 1, payment element 2, payment element 3.\n    # Header is OFF by default because Sage imports usually expect raw rows only.\n    if include_header:\n        writer.writerow(["PeriodNumber", "EmployeeNumber", "0000", "NormalHours", "SundayHours", "OvertimeHours"])\n\n    for row in rows:\n        if row["paid_minutes"] == 0:\n            continue\n        writer.writerow([\n            period_number,\n            row["employee_number"],\n            "0000",\n            row["normal_hours"],\n            row["sunday_hours"],\n            row["overtime_hours"],\n        ])\n\n    return response\n'''
new = '''@_patch_login_required\ndef export_sage_payroll_csv(request):\n    week_start = _patch_parse_week_start(request)\n    week_end = week_start + timedelta(days=6)\n    period_number = request.GET.get("period", "1")\n    standard_hours = float(request.GET.get("standard_hours", "39"))\n    include_header = request.GET.get("include_header") == "1"\n    force_export = request.GET.get("force") == "1"\n    rows = _patch_get_week_rows(week_start, standard_hours)\n\n    unresolved_rows = [row for row in rows if row.get("warning") != "OK"]\n\n    # Production safety: do not silently export payroll when the manager still has\n    # warnings to review. The manager can still force an export, but only after\n    # seeing a clear warning page.\n    if unresolved_rows and not force_export:\n        return render(request, "sage_export_review.html", {\n            "week_start": week_start,\n            "week_end": week_end,\n            "period_number": period_number,\n            "standard_hours": standard_hours,\n            "unresolved_rows": unresolved_rows,\n            "unresolved_count": len(unresolved_rows),\n        })\n\n    filename = f"sage_payroll_{week_start.strftime('%Y_%m_%d')}.csv"\n    response = HttpResponse(content_type="text/csv")\n    response["Content-Disposition"] = f'attachment; filename="{filename}"'\n    writer = csv.writer(response)\n\n    # Sage Payroll IE single-timesheet import order:\n    # period number, employee number, 0000, payment element 1, payment element 2, payment element 3.\n    # Header is OFF by default because Sage imports usually expect raw rows only.\n    if include_header:\n        writer.writerow(["PeriodNumber", "EmployeeNumber", "0000", "NormalHours", "SundayHours", "OvertimeHours"])\n\n    for row in rows:\n        if row["paid_minutes"] == 0:\n            continue\n        writer.writerow([\n            period_number,\n            row["employee_number"],\n            "0000",\n            row["normal_hours"],\n            row["sunday_hours"],\n            row["overtime_hours"],\n        ])\n\n    return response\n'''
if old not in text:
    raise SystemExit("Could not find expected export_sage_payroll_csv block. No changes made.")
views.write_text(text.replace(old, new))
PY

cat > templates/sage_export_review.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Review Before Sage Export</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #222; }
        .container { max-width: 1150px; margin: auto; background: white; padding: 24px; border-radius: 14px; border: 1px solid #e5e7eb; }
        .warning { background: #fffbeb; border-left: 5px solid #f59e0b; padding: 14px; margin: 14px 0; }
        .danger { background: #fee2e2; border-left: 5px solid #dc2626; padding: 14px; margin: 14px 0; }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 10px; text-align: left; vertical-align: top; }
        th { background: #f9fafb; }
        .button { display: inline-block; padding: 10px 13px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin: 5px 8px 5px 0; }
        .secondary { background: #4b5563; }
        .danger-button { background: #b42318; }
        .muted { color: #6b7280; }
    </style>
</head>
<body>
<div class="container">
    <h1>Review Before Sage Export</h1>

    <div class="danger">
        <strong>{{ unresolved_count }} payroll warning(s) found for {{ week_start }} to {{ week_end }}.</strong><br>
        A manager should review these before downloading the Sage CSV.
    </div>

    <p>This protects payroll from missed clock-outs, unusual hours, or roster mismatches being exported by mistake.</p>

    <p>
        <a class="button" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Fix Payroll Problems</a>
        <a class="button secondary" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}&standard_hours={{ standard_hours }}">Back to Weekly Payroll</a>
    </p>

    <h2>Warnings to Review</h2>
    <table>
        <tr>
            <th>Employee No</th>
            <th>Employee</th>
            <th>Rostered</th>
            <th>Paid Hours</th>
            <th>Difference</th>
            <th>Status</th>
        </tr>
        {% for row in unresolved_rows %}
        <tr>
            <td>{{ row.employee_number }}</td>
            <td>{{ row.employee }}</td>
            <td>{{ row.rostered_hours }}</td>
            <td>{{ row.paid_hours }}</td>
            <td>{{ row.difference }}</td>
            <td>{{ row.warning }}</td>
        </tr>
        {% endfor %}
    </table>

    <div class="warning">
        <strong>Manager override:</strong> only use this if you have checked the warnings and still want the file now.
    </div>

    <p>
        <a class="button danger-button" href="/manager/export-sage-payroll/?week_start={{ week_start|date:'Y-m-d' }}&period={{ period_number }}&standard_hours={{ standard_hours }}&force=1">Download Anyway</a>
    </p>
</div>
</body>
</html>
HTML

python3 <<'PY'
from pathlib import Path
p = Path("templates/weekly_summary.html")
text = p.read_text()
old = '''<p>\n    <a class="button" href="/manager/export-sage-payroll/?week_start={{ week_start|date:'Y-m-d' }}&period=1&standard_hours={{ standard_hours }}">\n        Download Sage Payroll CSV\n    </a>\n</p>'''
new = '''{% if unresolved_problem_count and unresolved_problem_count > 0 %}\n<p>\n    <a class="button" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">\n        Fix Payroll Problems First\n    </a>\n    <a class="button secondary" href="/manager/export-sage-payroll/?week_start={{ week_start|date:'Y-m-d' }}&period=1&standard_hours={{ standard_hours }}">\n        Review Sage Export\n    </a>\n</p>\n{% else %}\n<p>\n    <a class="button" href="/manager/export-sage-payroll/?week_start={{ week_start|date:'Y-m-d' }}&period=1&standard_hours={{ standard_hours }}">\n        Download Sage Payroll CSV\n    </a>\n</p>\n{% endif %}'''
if old not in text:
    raise SystemExit("Could not find expected weekly summary export button block.")
p.write_text(text.replace(old, new))
PY

python3 <<'PY'
from pathlib import Path
p = Path("templates/payroll_problems.html")
text = p.read_text()
text = text.replace(
    "<p>Review and fix missing clock-outs, unended breaks, unusual shifts and urgent issues before payroll export.</p>",
    "<p>Use this page before payroll. Fix anything that could make a Sage export wrong.</p>"
)
text = text.replace(
    '<div class="note"><strong>{{ problem_count }} problem(s) found.</strong> Fix or review these before exporting payroll. Each row has a Fix/Edit button for that employee and date.</div>',
    '<div class="note"><strong>{{ problem_count }} problem(s) found.</strong> Fix these before downloading the Sage CSV. Use Fix / Edit for the employee and date.</div>'
)
p.write_text(text)
PY

python3 manage.py check

echo ""
echo "Patch 41 complete."
echo "What changed:"
echo "  - Sage CSV export now shows a warning page if payroll warnings exist."
echo "  - Manager can still Download Anyway, but only after seeing the warning."
echo "  - Weekly Payroll now guides managers to fix problems first."
echo ""
echo "Recommended next commands:"
echo "  git status"
echo "  git add ."
echo "  git commit -m 'Patch 41 payroll export safety manager flow'"
echo "  git push"
echo "  sudo systemctl restart restaurant_clocking"
