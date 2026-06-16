#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-$PWD}"
cd "$APP_DIR"

if [ ! -f manage.py ] || [ ! -d core ] || [ ! -d templates ]; then
  echo "Run this from the restaurant_clocking project root, or set APP_DIR=/path/to/restaurant_clocking" >&2
  exit 1
fi

STAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="backups_patch_31_${STAMP}"
mkdir -p "$BACKUP_DIR/core" "$BACKUP_DIR/templates"
cp core/views.py "$BACKUP_DIR/core/views.py" 2>/dev/null || true
cp core/compliance.py "$BACKUP_DIR/core/compliance.py" 2>/dev/null || true
cp templates/home.html "$BACKUP_DIR/templates/home.html" 2>/dev/null || true
cp templates/manager_today.html "$BACKUP_DIR/templates/manager_today.html" 2>/dev/null || true
cp templates/weekly_summary.html "$BACKUP_DIR/templates/weekly_summary.html" 2>/dev/null || true

python - <<'PY'
from pathlib import Path

# Remove the duplicate Breaks Needing Action section. The Current Staff table already carries the break status.
def remove_section(text, heading):
    marker = f"<h2>{heading}</h2>"
    pos = text.find(marker)
    if pos == -1:
        return text
    start = text.rfind('<div class="section"', 0, pos)
    if start == -1:
        return text
    next_start = text.find('<div class="section"', pos + len(marker))
    if next_start == -1:
        return text
    return text[:start] + text[next_start:]

for name in ["home.html", "manager_today.html"]:
    p = Path("templates") / name
    if p.exists():
        s = p.read_text()
        s = remove_section(s, "Breaks Needing Action")
        s = s.replace("<th>Action</th><th>Issue</th>", "<th>Issue</th>")
        s = s.replace("<td>{{ row.break_action }}</td>\n                <td class=", "<td class=")
        s = s.replace("<tr><td colspan=\"9\">No staff are currently clocked in or on break.</td></tr>", "<tr><td colspan=\"8\">No staff are currently clocked in or on break.</td></tr>")
        s = s.replace("<tr><th>Employee</th><th>Status</th><th>Roster</th><th>Clocked In</th><th>Worked</th><th>Break Taken</th><th>Break Status</th><th>Action</th><th>Issue</th></tr>",
                      "<tr><th>Employee</th><th>Status</th><th>Roster</th><th>Clocked In</th><th>Worked</th><th>Break Taken</th><th>Break Status</th><th>Issue</th></tr>")
        s = s.replace('{#', '').replace('#}', '')
        p.write_text(s)
PY

cat > templates/weekly_summary.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Weekly Payroll Summary</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #222; }
        .container { max-width: 1280px; margin: auto; background: white; padding: 24px; border-radius: 14px; border: 1px solid #e5e7eb; }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 10px; text-align: left; vertical-align: top; }
        th { background: #f9fafb; }
        .ok { color: #1a7f37; font-weight: bold; }
        .warn { color: #b42318; font-weight: bold; }
        .note { background:#eff6ff; border-left:4px solid #2563eb; padding:12px; margin:12px 0; }
        .block { background:#fffbeb; border-left:4px solid #f59e0b; padding:12px; margin:12px 0; }
        .button { display: inline-block; padding: 10px 13px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 8px; margin-bottom: 8px; }
        .secondary { background: #4b5563; }
        .disabled { background: #9ca3af; cursor: not-allowed; }
        input, button { padding: 8px; }
        .small { color:#667085; font-size:13px; }
    </style>
</head>
<body>

<div class="container">

<h1>Weekly Payroll Summary</h1>

<p>Review the week, then export the Sage CSV when payroll is ready.</p>

<form method="get">
    Week Start:
    <input type="date" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
    Standard Weekly Hours:
    <input type="number" step="0.5" name="standard_hours" value="{{ standard_hours }}">
    Period:
    <input type="number" name="period" value="{{ period_number }}" style="width:70px;">
    <button type="submit">View Week</button>
</form>

<h2>{{ week_start }} to {{ week_end }}</h2>

<div class="note">
    <strong>Sage CSV format:</strong> Period, Employee No, 0000, Normal Hours, Sunday Hours, Overtime Hours.<br>
    Hours are exported as decimal hours. Example: 7 hours 13 minutes exports as 7.22, not 7.13.
</div>

{% if payroll_problem_count and payroll_problem_count > 0 %}
<div class="block">
    <strong>Payroll not ready: {{ payroll_problem_count }} issue(s) found.</strong>
    Fix these before downloading the Sage CSV.
    <a href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Open Payroll Issues</a>
</div>
{% else %}
<div class="note"><strong>Payroll ready.</strong> No blocking issues found for this week.</div>
{% endif %}

<p>
    {% if payroll_problem_count and payroll_problem_count > 0 %}
        <span class="button disabled">Download Sage CSV</span>
    {% else %}
        <a class="button" href="/manager/export-sage-payroll/?week_start={{ week_start|date:'Y-m-d' }}&period={{ period_number }}&standard_hours={{ standard_hours }}">
            Download Sage CSV
        </a>
    {% endif %}
</p>

<h2>Sage Export Preview</h2>
<table>
    <tr>
        <th>Period</th>
        <th>Employee No</th>
        <th>Code</th>
        <th>Normal</th>
        <th>Sunday</th>
        <th>Overtime</th>
        <th>Employee</th>
    </tr>
    {% for row in export_rows %}
    <tr>
        <td>{{ period_number }}</td>
        <td>{{ row.employee_number }}</td>
        <td>0000</td>
        <td>{{ row.normal_export }}</td>
        <td>{{ row.sunday_export }}</td>
        <td>{{ row.overtime_export }}</td>
        <td>{{ row.employee }}</td>
    </tr>
    {% empty %}
    <tr><td colspan="7">No paid hours to export for this week.</td></tr>
    {% endfor %}
</table>

<h2>Weekly Review</h2>
<table>
    <tr>
        <th>Employee No</th>
        <th>Employee</th>
        <th>Rostered</th>
        <th>Worked</th>
        <th>Unpaid Breaks</th>
        <th>Paid Hours</th>
        <th>Normal</th>
        <th>Sunday</th>
        <th>Overtime</th>
        <th>Difference</th>
        <th>Status</th>
    </tr>

    {% for row in summary_rows %}
    <tr>
        <td>{{ row.employee_number }}</td>
        <td>{{ row.employee }}</td>
        <td>{{ row.rostered_hours }}</td>
        <td>{{ row.worked_hours }}</td>
        <td>{{ row.break_hours }}</td>
        <td>{{ row.paid_hours }}</td>
        <td>{{ row.normal_hours }}</td>
        <td>{{ row.sunday_hours }}</td>
        <td>{{ row.overtime_hours }}</td>
        <td>{{ row.difference }}</td>
        <td class="{% if row.warning == 'OK' %}ok{% else %}warn{% endif %}">{{ row.warning }}</td>
    </tr>
    {% endfor %}
</table>

<p>
    <a class="button secondary" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Payroll Issues</a>
    <a class="button secondary" href="/manager/today/">Manager Dashboard</a>
    <a class="button secondary" href="/manager/upload-roster/">Upload Roster</a>
    <a class="button secondary" href="/">Home</a>
</p>

</div>

</body>
</html>
HTML

cat >> core/views.py <<'PY'

# -------------------------------------------------------------------
# Delivery patch 31: dashboard cleanup and Sage decimal export safety
# -------------------------------------------------------------------
from decimal import Decimal, ROUND_HALF_UP
from django.contrib.auth.decorators import login_required as _dp31_login_required


def _dp31_week_start(day):
    return day - timedelta(days=day.weekday())


def _dp31_minutes_to_decimal_string(minutes):
    """Return Sage-ready decimal hours, fixed to 2 dp: 7h13m -> 7.22."""
    minutes = int(minutes or 0)
    value = (Decimal(minutes) / Decimal(60)).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    return format(value, ".2f")


def _dp31_add_export_strings(rows):
    export_rows = []
    for row in rows:
        row["normal_export"] = _dp31_minutes_to_decimal_string(row.get("normal_minutes", 0))
        row["sunday_export"] = _dp31_minutes_to_decimal_string(row.get("sunday_minutes", 0))
        row["overtime_export"] = _dp31_minutes_to_decimal_string(row.get("overtime_minutes", 0))
        if int(row.get("paid_minutes", 0) or 0) > 0:
            export_rows.append(row)
    return rows, export_rows


# Override patch 30 helpers: current staff keeps break status, but no duplicate break section below.
def _dp30_break_attention_rows(rows):
    return [
        row for row in rows
        if (row.get("is_working") or row.get("is_on_break"))
        and row.get("break_css") in ["break-warn", "break-urgent"]
    ]


@_dp31_login_required
def manager_weekly_summary(request):
    week_start = _patch_parse_week_start(request)
    week_end = week_start + timedelta(days=6)
    standard_hours = float(request.GET.get("standard_hours", "39"))
    period_number = request.GET.get("period", "1")
    summary_rows = _patch_get_week_rows(week_start, standard_hours)
    summary_rows, export_rows = _dp31_add_export_strings(summary_rows)
    payroll_ready_bool, payroll_problem_rows = _dp30_payroll_is_ready(week_start)

    return render(request, "weekly_summary.html", {
        "week_start": week_start,
        "week_end": week_end,
        "summary_rows": summary_rows,
        "export_rows": export_rows,
        "standard_hours": standard_hours,
        "period_number": period_number,
        "payroll_problem_count": len(payroll_problem_rows),
        "payroll_ready": payroll_ready_bool,
    })


@_dp31_login_required
def export_sage_payroll_csv(request):
    week_start = _patch_parse_week_start(request)
    period_number = request.GET.get("period", "1")
    standard_hours = float(request.GET.get("standard_hours", "39"))

    payroll_ready_bool, payroll_problem_rows = _dp30_payroll_is_ready(week_start)
    if not payroll_ready_bool:
        response = HttpResponse(content_type="text/plain", status=400)
        response.write("Payroll is not ready. Fix payroll issues before exporting the Sage CSV.\n")
        for row in payroll_problem_rows:
            response.write(f"{row.get('date')} - {row.get('employee')}: {row.get('problem')}\n")
        return response

    rows = _patch_get_week_rows(week_start, standard_hours)

    response = HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = 'attachment; filename="sage_payroll_export.csv"'
    writer = csv.writer(response)

    # Sage Payroll IE single-timesheet import order:
    # period number, employee number, 0000, payment element 1, payment element 2, payment element 3.
    # Values are decimal hours, not HH.MM. Example: 7h13m = 7.22.
    for row in rows:
        if int(row.get("paid_minutes", 0) or 0) == 0:
            continue
        writer.writerow([
            period_number,
            row["employee_number"],
            "0000",
            _dp31_minutes_to_decimal_string(row.get("normal_minutes", 0)),
            _dp31_minutes_to_decimal_string(row.get("sunday_minutes", 0)),
            _dp31_minutes_to_decimal_string(row.get("overtime_minutes", 0)),
        ])

    return response
PY

python -m py_compile core/views.py core/compliance.py
python - <<'PY'
from pathlib import Path
for p in [Path('templates/home.html'), Path('templates/manager_today.html')]:
    s = p.read_text()
    if '<h2>Breaks Needing Action</h2>' in s:
        raise SystemExit(f'Duplicate break section still present in {p}')
    if '{#' in s or '#}' in s:
        raise SystemExit(f'Broken template comment marker still present in {p}')
PY

echo "Patch 31 applied. Backup saved to $BACKUP_DIR"
echo "Removed duplicate break sections. Sage export now previews and exports fixed decimal hours, and blocks export if payroll issues remain."
