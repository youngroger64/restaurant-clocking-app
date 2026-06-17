#!/usr/bin/env bash
set -euo pipefail

echo "== patch_44_sync_payroll_problem_source =="
cd "$(dirname "$0")"
PROJECT_ROOT="$(pwd)"
echo "Project root: $PROJECT_ROOT"

STAMP="$(date +%Y%m%d_%H%M%S)"
mkdir -p "backups_patch_44_${STAMP}"
cp core/views.py "backups_patch_44_${STAMP}/views.py"
[ -f templates/weekly_summary.html ] && cp templates/weekly_summary.html "backups_patch_44_${STAMP}/weekly_summary.html"
[ -f templates/payroll_problems.html ] && cp templates/payroll_problems.html "backups_patch_44_${STAMP}/payroll_problems.html"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("core/views.py")
s = p.read_text()

new_block = r'''
def _patch_payroll_problem_rows(week_start):
    """
    Single source of truth for payroll problems.

    The weekly payroll page, payroll problems page, and Sage export safety
    must all use this function. Otherwise the manager can see "2 issues" on
    Weekly Payroll, click through, and see "No payroll problems found".
    """
    rows = []

    for employee in Employee.objects.filter(active=True).order_by("name"):
        for i in range(7):
            day = week_start + timedelta(days=i)
            d = _patch_calculate_employee_day(employee, day, include_live=True)
            problems = []

            if d.get("missing_clock_out"):
                problems.append("Missing clock-out")
            if d.get("invalid_sequence"):
                problems.append("Check clock events")
            if d.get("is_urgent"):
                issue = d.get("issue")
                if issue and issue != "OK":
                    problems.append(issue)
            if d.get("worked_hours", 0) > 12:
                problems.append("Unusually long shift")

            # Do not show duplicate wording in the manager-facing problem list.
            clean = []
            for item in problems:
                if item and item not in clean:
                    clean.append(item)

            if clean:
                rows.append({
                    "date": day,
                    "employee_number": employee.employee_number,
                    "employee": employee.name,
                    "roster": d.get("roster"),
                    "status": d.get("status"),
                    "worked_hours": d.get("worked_hours"),
                    "break_minutes": d.get("break_minutes"),
                    "problem": "; ".join(clean),
                })

    return rows


@_patch_login_required
def payroll_problems(request):
    week_start = _patch_parse_week_start(request)
    week_end = week_start + timedelta(days=6)
    rows = _patch_payroll_problem_rows(week_start)

    return render(request, "payroll_problems.html", {
        "week_start": week_start,
        "week_end": week_end,
        "rows": rows,
        "problem_count": len(rows),
    })


@_patch_login_required
def manager_weekly_summary(request):
    week_start = _patch_parse_week_start(request)
    week_end = week_start + timedelta(days=6)
    standard_hours = float(request.GET.get("standard_hours", "39"))
    summary_rows = _patch_get_week_rows(week_start, standard_hours)

    # Important: this count must match the Payroll Problems page exactly.
    payroll_problem_rows = _patch_payroll_problem_rows(week_start)

    return render(request, "weekly_summary.html", {
        "week_start": week_start,
        "week_end": week_end,
        "summary_rows": summary_rows,
        "standard_hours": standard_hours,
        "unresolved_problem_count": len(payroll_problem_rows),
    })


@_patch_login_required
def export_sage_payroll_csv(request):
    week_start = _patch_parse_week_start(request)
    period_number = request.GET.get("period", "1")
    standard_hours = float(request.GET.get("standard_hours", "39"))
    include_header = request.GET.get("include_header") == "1"
    allow_unresolved = request.GET.get("allow_unresolved") == "1"

    payroll_problem_rows = _patch_payroll_problem_rows(week_start)
    if payroll_problem_rows and not allow_unresolved:
        week_end = week_start + timedelta(days=6)
        return render(request, "payroll_export_blocked.html", {
            "week_start": week_start,
            "week_end": week_end,
            "problem_count": len(payroll_problem_rows),
            "problems": payroll_problem_rows,
            "standard_hours": standard_hours,
            "period_number": period_number,
        })

    rows = _patch_get_week_rows(week_start, standard_hours)

    response = HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = 'attachment; filename="sage_payroll_export.csv"'
    writer = csv.writer(response)

    # Sage Payroll IE single-timesheet import order:
    # period number, employee number, 0000, payment element 1, payment element 2, payment element 3.
    # Header is OFF by default because Sage imports usually expect raw rows only.
    if include_header:
        writer.writerow(["PeriodNumber", "EmployeeNumber", "0000", "NormalHours", "SundayHours", "OvertimeHours"])

    for row in rows:
        if row["paid_minutes"] == 0:
            continue
        writer.writerow([
            period_number,
            row["employee_number"],
            "0000",
            row["normal_hours"],
            row["sunday_hours"],
            row["overtime_hours"],
        ])

    return response
'''

pattern = re.compile(
    r"@_patch_login_required\ndef payroll_problems\(request\):.*?\n\s*return response\n",
    re.S,
)
new_s, n = pattern.subn(new_block.lstrip() + "\n", s, count=1)
if n != 1:
    raise SystemExit("Could not replace payroll_problems/weekly/export block in core/views.py")
p.write_text(new_s)
PY

# Make weekly wording manager-friendly and guarantee link carries the same week.
python3 - <<'PY'
from pathlib import Path
p = Path("templates/weekly_summary.html")
if p.exists():
    s = p.read_text()
    s = s.replace("Payroll not ready: {{ unresolved_problem_count }} issue(s) found.", "Payroll not ready: {{ unresolved_problem_count }} issue(s) to review.")
    s = s.replace("{{ unresolved_problem_count }} payroll warning(s) found.", "{{ unresolved_problem_count }} payroll issue(s) to review.")
    s = s.replace("Review Payroll Problems before exporting to Sage.", "Fix or review these before exporting to Sage.")
    s = s.replace("Open Payroll Problems", "Fix Payroll Issues")
    # If a previous patch uses a plain Fix Payroll Issues link without week_start, fix it.
    s = s.replace('href="/manager/payroll-problems/"', 'href="/manager/payroll-problems/?week_start={{ week_start|date:\'Y-m-d\' }}"')
    p.write_text(s)
PY

python3 manage.py check

echo ""
echo "Patch 44 complete."
echo "What changed:"
echo "  - Weekly Payroll and Payroll Problems now use the same issue source."
echo "  - Sage CSV export safety uses that same source too."
echo "  - Fix Payroll Issues link keeps the selected week_start."
echo ""
echo "Next commands:"
echo "  git status"
echo "  git add ."
echo "  git commit -m 'Patch 44 sync payroll problem source'"
echo "  git push"
echo "  sudo systemctl restart restaurant_clocking"
