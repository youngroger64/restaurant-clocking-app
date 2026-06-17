#!/usr/bin/env bash
set -euo pipefail

echo "== patch_47_live_dashboard_ignore_future_events =="
echo "Purpose: make the live dashboard use the same 'events up to now' rule as staff clocking."
echo "This does NOT add another dashboard function and does NOT change payroll templates."

if [ ! -f manage.py ] || [ ! -f core/compliance.py ]; then
  echo "ERROR: run from Django project root, e.g. cd ~/restaurant_clocking"
  exit 1
fi

stamp=$(date +%Y%m%d_%H%M%S)
mkdir -p "patch_backups_47_$stamp"
cp -f core/compliance.py "patch_backups_47_$stamp/compliance.py.before_patch47"

python3 <<'PY'
from pathlib import Path

p = Path("core/compliance.py")
s = p.read_text()

old = '''def calculate_employee_day(employee, selected_date, include_live=True):
    events = _events_for_operational_day(employee, selected_date)
    roster = get_roster_info(employee, selected_date)
'''
new = '''def calculate_employee_day(employee, selected_date, include_live=True):
    events = _events_for_operational_day(employee, selected_date)
    roster = get_roster_info(employee, selected_date)

    # Live screens must not be affected by future demo/manager events.
    # Example: if a demo OUT exists for 19:00 but it is only 12:55 now,
    # the staff member should still appear as Working/On Break on the dashboard.
    # Payroll/full-day review can still call include_live=False to use the whole day.
    now = timezone.now()
    today = current_operational_date()
    if include_live and selected_date == today:
        events = events.filter(timestamp__lte=now)
'''
if old not in s:
    raise SystemExit("Could not find calculate_employee_day opening block; no changes made.")
s = s.replace(old, new, 1)

# Remove the later duplicate now/today assignment inside the same function if present.
old2 = '''    now = timezone.now()
    today = current_operational_date()
    currently_open_work = work_start is not None
'''
new2 = '''    currently_open_work = work_start is not None
'''
if old2 in s:
    s = s.replace(old2, new2, 1)
else:
    print("NOTE: later now/today block was not found; leaving file otherwise unchanged.")

p.write_text(s)
PY

echo "Checking syntax..."
python3 -m py_compile core/compliance.py

echo "Running Django check..."
python3 manage.py check

echo
cat <<'MSG'
Patch 47 complete.

What changed:
  - calculate_employee_day(..., include_live=True) now ignores future events for the current operational day.
  - Staff Clocking and Current Staff should now agree.
  - Payroll/full-day calculations can still use include_live=False for the full day.

Next commands:
  git status
  git add core/compliance.py
  git commit -m "Patch 47 fix live dashboard future events"
  git push
  sudo systemctl restart restaurant_clocking

Test:
  Open Staff Clocking for a working/on-break employee.
  Open Manager Dashboard.
  They should appear in Current Staff.
MSG
