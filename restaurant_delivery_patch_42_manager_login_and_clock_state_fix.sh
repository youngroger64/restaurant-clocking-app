#!/usr/bin/env bash
set -euo pipefail

echo "== patch_42_manager_login_and_clock_state_fix =="
ROOT="$(pwd)"
echo "Project root: $ROOT"

if [ ! -f manage.py ] || [ ! -f core/views.py ] || [ ! -f config/settings.py ]; then
  echo "ERROR: run this from the Django project root, e.g. cd ~/restaurant_clocking"
  exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="backups_patch_42_${STAMP}"
mkdir -p "$BACKUP_DIR"
cp core/views.py "$BACKUP_DIR/views.py"
cp config/settings.py "$BACKUP_DIR/settings.py"

python3 <<'PY'
from pathlib import Path

settings = Path("config/settings.py")
text = settings.read_text()

# Django's @login_required defaults to /accounts/login/. This app uses /manager/login/.
# Without this, manager links can show a plain Not Found page instead of the manager login page.
if "LOGIN_URL" not in text:
    text += "\n\n# Manager login route used by protected manager/payroll pages.\nLOGIN_URL = '/manager/login/'\nLOGIN_REDIRECT_URL = '/manager/today/'\nLOGOUT_REDIRECT_URL = '/manager/login/'\n"
else:
    # Keep this conservative: only replace obvious old/default login settings if present.
    import re
    text = re.sub(r"^LOGIN_URL\s*=\s*['\"][^'\"]*['\"]", "LOGIN_URL = '/manager/login/'", text, flags=re.M)
    if "LOGIN_REDIRECT_URL" not in text:
        text += "\nLOGIN_REDIRECT_URL = '/manager/today/'\n"
    if "LOGOUT_REDIRECT_URL" not in text:
        text += "LOGOUT_REDIRECT_URL = '/manager/login/'\n"

settings.write_text(text)
PY

python3 <<'PY'
from pathlib import Path

views = Path("core/views.py")
text = views.read_text()

old = '''def _clock_state_for_employee(employee):
    today = timezone.localdate()
    latest = ClockEvent.objects.filter(
        employee=employee,
        timestamp__date=today
    ).order_by("-timestamp").first()

    events = ClockEvent.objects.filter(
        employee=employee,
        timestamp__date=today
    ).order_by("timestamp")
'''

new = '''def _clock_state_for_employee(employee):
    today = timezone.localdate()
    now = timezone.now()

    # Staff clocking must reflect what has happened up to this moment only.
    # Manager corrections, demo data, or roster simulations may contain later events
    # for today. If we include future events here, a staff member can press Clock In
    # and still appear Clocked Out because a later OUT already exists in the day.
    latest = ClockEvent.objects.filter(
        employee=employee,
        timestamp__date=today,
        timestamp__lte=now,
    ).order_by("-timestamp", "-id").first()

    events = ClockEvent.objects.filter(
        employee=employee,
        timestamp__date=today,
        timestamp__lte=now,
    ).order_by("timestamp", "id")
'''

if old not in text:
    raise SystemExit("Could not find expected _clock_state_for_employee block. No changes made.")

text = text.replace(old, new, 1)

# The function previously created a second local 'now' later on. Remove that duplicate assignment
# so the same point-in-time value is used throughout the status calculation.
text = text.replace('''    now = timezone.now()\n    if current_state == "WORKING" and work_start:\n''', '''    if current_state == "WORKING" and work_start:\n''', 1)

views.write_text(text)
PY

python3 manage.py check

echo ""
echo "Patch 42 complete."
echo "Fixes:"
echo "  - Manager pages now redirect to /manager/login/ instead of missing /accounts/login/."
echo "  - Staff clocking status now ignores future events later today, so Clock In updates the visible state properly."
echo ""
echo "Recommended next commands:"
echo "  git status"
echo "  git add ."
echo "  git commit -m 'Patch 42 fix manager login redirect and clock state'"
echo "  git push"
echo "  sudo systemctl restart restaurant_clocking"
