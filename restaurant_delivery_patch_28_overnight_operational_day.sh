#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-$PWD}"
cd "$APP_DIR"

if [ ! -f manage.py ] || [ ! -d core ] || [ ! -d templates ]; then
  echo "Run this from the restaurant_clocking project root, or set APP_DIR=/path/to/restaurant_clocking" >&2
  exit 1
fi

STAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="backups_patch_28_${STAMP}"
mkdir -p "$BACKUP_DIR/core" "$BACKUP_DIR/templates"
cp core/compliance.py "$BACKUP_DIR/core/compliance.py" 2>/dev/null || true
cp core/views.py "$BACKUP_DIR/core/views.py" 2>/dev/null || true
cp templates/home.html "$BACKUP_DIR/templates/home.html" 2>/dev/null || true
cp templates/manager_today.html "$BACKUP_DIR/templates/manager_today.html" 2>/dev/null || true

python - <<'PY'
from pathlib import Path
p = Path('core/compliance.py')
s = p.read_text()

# Add a single source of truth for the manager's operational day.
# Between midnight and 04:59, the restaurant is still working the previous service day.
marker = "OPERATIONAL_DAY_START_HOUR = 5\n"
insert = '''OPERATIONAL_DAY_START_HOUR = 5\n\n\ndef current_operational_date():\n    \"\"\"\n    Return the restaurant service date for live operations.\n\n    Example: at 00:06 on June 17, the active restaurant day is still\n    June 16 because late shifts are commonly still finishing/clocking out.\n    The operational day rolls over at OPERATIONAL_DAY_START_HOUR.\n    \"\"\"\n    local_now = timezone.localtime(timezone.now())\n    if local_now.time() < time(OPERATIONAL_DAY_START_HOUR, 0):\n        return local_now.date() - timedelta(days=1)\n    return local_now.date()\n'''
if 'def current_operational_date' not in s:
    s = s.replace(marker, insert)

# Replace local calendar-date logic in compliance calculations with operational-date logic.
s = s.replace('today = timezone.localdate()\n    currently_open_work = work_start is not None',
              'today = current_operational_date()\n    currently_open_work = work_start is not None')

# If a previous patch already changed spacing, catch the simple assignment too.
s = s.replace('today = timezone.localdate()\n', 'today = current_operational_date()\n')

p.write_text(s)
PY

# Make the dashboard default to the current operational day, not the calendar day after midnight.
cat >> core/views.py <<'PY'

# -------------------------------------------------------------------
# Delivery patch 28: overnight operational day fix
# -------------------------------------------------------------------
# Real restaurant behaviour: at 00:06, a 16:00-23:00 or 23:00-00:00 shift
# has not magically become yesterday's payroll error. The live dashboard must
# keep showing open staff until the operational day rolls over at 05:00.
from core.compliance import current_operational_date as _dp28_current_operational_date


def home_page(request):
    today = _dp28_current_operational_date()
    week_start = _dp27_week_start(today)
    rows = _dp27_get_day_rows(today)
    live_rows = _dp27_live_rows(rows)
    break_attention_rows = _dp27_break_attention_rows(rows)
    roster_rows = _dp27_roster_rows(rows)
    not_arrived_rows = _dp27_not_arrived_now(rows)
    payroll_ready_bool, payroll_problem_rows = _dp27_payroll_is_ready(week_start)

    return render(request, "home.html", {
        "today": today,
        "operational_day_start_hour": 5,
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
    default_date = _dp28_current_operational_date()
    selected_date_str = request.GET.get("date", default_date.strftime("%Y-%m-%d"))
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
        "operational_day_start_hour": 5,
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

python - <<'PY'
from pathlib import Path
for fname in ['templates/home.html', 'templates/manager_today.html']:
    p = Path(fname)
    if not p.exists():
        continue
    s = p.read_text()
    s = s.replace('Today: {{ today|date:"F j, Y" }}. Current time:', 'Operational day: {{ today|date:"F j, Y" }}. Current time:')
    s = s.replace('Today: {{ selected_date|date:"F j, Y" }}. Current time:', 'Operational day: {{ selected_date|date:"F j, Y" }}. Current time:')
    s = s.replace('Live team first, then today\'s roster.', 'Live team first, then this service day\'s roster. Day rolls over at 05:00.')
    s = s.replace('Full-day roster. Future shifts show as Due Later. Past shifts with no clock-in show as Didn\'t Clock In.', 'Service-day roster. After midnight, late-night open shifts still belong to the previous operational day until 05:00.')
    p.write_text(s)
PY

python -m py_compile core/compliance.py core/views.py

echo "Patch 28 applied. Backup saved to $BACKUP_DIR"
echo "What changed: after midnight the live dashboard and payroll blocker logic keep using the previous service day until 05:00. Open shifts stay live instead of becoming missing clock-outs."
