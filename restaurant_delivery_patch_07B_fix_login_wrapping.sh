#!/usr/bin/env bash
set -euo pipefail

echo "=== Restaurant Clocking Patch 07B: Fix login_required wrapping order ==="
echo "Patch 07 removed duplicate functions but left the login_required wrapping before some final functions were defined."
echo "This moves the wrapping block to the end of core/views.py."
echo

if [ ! -f "manage.py" ]; then
  echo "ERROR: Run this from Django project root: cd ~/restaurant_clocking"
  exit 1
fi

stamp=$(date +%Y%m%d_%H%M%S)
mkdir -p "patch_backups_07b_$stamp"
cp -f core/views.py "patch_backups_07b_$stamp/views.py.before_wrap_fix"

python3 <<'PY'
from pathlib import Path
import re

path = Path("core/views.py")
s = path.read_text()

wrap_lines = [
    "manager_today_dashboard = login_required(manager_today_dashboard)",
    "upload_roster = login_required(upload_roster)",
    "manager_weekly_summary = login_required(manager_weekly_summary)",
    "manager_daily_monitor = login_required(manager_daily_monitor)",
    "payroll_problems = login_required(payroll_problems)",
    "manager_add_missing_event = login_required(manager_add_missing_event)",
    "export_sage_payroll_csv = login_required(export_sage_payroll_csv)",
]

# Remove existing wrapping lines wherever they are.
for line in wrap_lines:
    s = s.replace(line + "\n", "")

# Remove orphan heading/comment if left behind.
s = re.sub(
    r"\n# Re-wrap manager views so manager pages require login\.\n\s*\n",
    "\n",
    s
)

# Ensure login_required import exists.
if "from django.contrib.auth.decorators import login_required" not in s:
    s += "\nfrom django.contrib.auth.decorators import login_required\n"

# Append wrapping at the very end, after all final functions are defined.
s = s.rstrip() + """

# -------------------------------------------------------------------
# Final manager view protection
# This must stay at the END of the file so all final view functions exist.
# -------------------------------------------------------------------
manager_today_dashboard = login_required(manager_today_dashboard)
upload_roster = login_required(upload_roster)
manager_weekly_summary = login_required(manager_weekly_summary)
manager_daily_monitor = login_required(manager_daily_monitor)
payroll_problems = login_required(payroll_problems)
manager_add_missing_event = login_required(manager_add_missing_event)
export_sage_payroll_csv = login_required(export_sage_payroll_csv)
manager_corrections = login_required(manager_corrections)
manager_fix_day = login_required(manager_fix_day)
export_clock_events_csv = login_required(export_clock_events_csv)
"""

path.write_text(s)
PY

echo "Checking Python syntax..."
python -m py_compile core/views.py

echo "Running Django checks..."
python manage.py check

echo
echo "Patch 07B complete."
echo "Backup saved in patch_backups_07b_$stamp/"
echo
echo "Now restart:"
echo "  sudo systemctl restart restaurant_clocking"
