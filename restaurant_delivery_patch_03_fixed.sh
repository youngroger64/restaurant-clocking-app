#!/usr/bin/env bash
set -euo pipefail

echo "=== Restaurant Clocking Hotfix Patch 03 ==="
echo "Fixes the failed Patch 02 and the ClockEvent.notes NOT NULL issue."

if [ ! -f "manage.py" ]; then
  echo "ERROR: Run this from the Django project root: cd ~/restaurant_clocking"
  exit 1
fi

mkdir -p patch_backups_03
cp -f core/models.py patch_backups_03/models.py.bak
cp -f core/views.py patch_backups_03/views.py.bak

python3 <<'PY'
from pathlib import Path
import re

models_path = Path("core/models.py")
views_path = Path("core/views.py")

models = models_path.read_text()
views = views_path.read_text()

# ---- MODEL FIXES ----

# Ensure clock_type can store BREAK_START / BREAK_END
models = re.sub(
    r"clock_type\s*=\s*models\.CharField\([^\n]*max_length\s*=\s*\d+([^\n]*)\)",
    lambda m: re.sub(r"max_length\s*=\s*\d+", "max_length=20", m.group(0)),
    models
)

# Ensure ClockEvent.notes is nullable-safe at application level.
if re.search(r"notes\s*=\s*models\.TextField\(", models):
    models = re.sub(
        r"notes\s*=\s*models\.TextField\([^\n]*\)",
        'notes = models.TextField(blank=True, default="")',
        models
    )
else:
    # Add notes after method field if possible.
    models = re.sub(
        r"(method\s*=\s*models\.[A-Za-z]+Field\([^\n]*\)\n)",
        r'\1    notes = models.TextField(blank=True, default="")\n',
        models,
        count=1
    )

models_path.write_text(models)

# ---- VIEW FIXES ----

# Every ClockEvent.objects.create block should include notes="" unless notes is already supplied.
def fix_create_block(match):
    block = match.group(0)
    if "notes=" in block:
        return block
    end = block.rfind(")")
    return block[:end].rstrip() + ',\n        notes="",\n    )'

views = re.sub(
    r"ClockEvent\.objects\.create\([\s\S]*?\n\s*\)",
    fix_create_block,
    views
)

# Add a conservative session helper if not present.
if "def _get_session_clock_employee" not in views:
    helper = '''
def _get_session_clock_employee(request):
    employee_id = request.session.get("clock_employee_id")
    if not employee_id:
        return None
    try:
        return Employee.objects.get(id=employee_id)
    except Employee.DoesNotExist:
        request.session.pop("clock_employee_id", None)
        return None

'''
    first_def = views.find("def ")
    if first_def != -1:
        views = views[:first_def] + helper + views[first_def:]

# Try to enhance smart_clock_page session persistence safely.
if "def smart_clock_page(request):" in views and "session_employee = _get_session_clock_employee(request)" not in views:
    views = views.replace(
        "def smart_clock_page(request):",
        "def smart_clock_page(request):\n    session_employee = _get_session_clock_employee(request)",
        1
    )

    views = views.replace(
        "employee_number = request.POST.get('employee_number')",
        "employee_number = request.POST.get('employee_number') or (str(session_employee.employee_number) if session_employee else '')"
    )
    views = views.replace(
        'employee_number = request.POST.get("employee_number")',
        'employee_number = request.POST.get("employee_number") or (str(session_employee.employee_number) if session_employee else "")'
    )
    views = views.replace(
        "pin = request.POST.get('pin')",
        "pin = request.POST.get('pin') or ('__SESSION_AUTH__' if session_employee else '')"
    )
    views = views.replace(
        'pin = request.POST.get("pin")',
        'pin = request.POST.get("pin") or ("__SESSION_AUTH__" if session_employee else "")'
    )

    views = views.replace(
        "Employee.objects.get(employee_number=employee_number, pin=pin)",
        "session_employee if pin == '__SESSION_AUTH__' and session_employee else Employee.objects.get(employee_number=employee_number, pin=pin)"
    )

# Store employee in session after successful employee lookup if possible.
if "request.session['clock_employee_id'] = employee.id" not in views:
    views = re.sub(
        r"(employee\s*=\s*(?:session_employee if[^
]+|Employee\.objects\.get\([^\n]+\))\n)",
        r"\1        request.session['clock_employee_id'] = employee.id\n",
        views,
        count=1
    )

views_path.write_text(views)
PY

echo "Creating migrations if needed..."
python manage.py makemigrations core || true

echo "Applying migrations..."
python manage.py migrate

echo "Backfilling any NULL notes values..."
python manage.py shell <<'PY'
from core.models import ClockEvent
ClockEvent.objects.filter(notes__isnull=True).update(notes="")
print("NULL notes fixed:", ClockEvent.objects.filter(notes__isnull=True).count())
PY

echo "Running checks..."
python manage.py check

echo
echo "Patch 03 complete. Restart your Django service/gunicorn now."
