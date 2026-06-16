#!/usr/bin/env bash
set -euo pipefail

echo "=== Restaurant Clocking Hotfix Patch 02 ==="
echo "Fixes:"
echo "  1) ClockEvent.notes NOT NULL crash when clocking actions are saved"
echo "  2) Adds default/blank notes handling at model level"
echo "  3) Adds database safety fix for SQLite"
echo "  4) Adds groundwork for keeping staff identified in session after PIN entry"
echo

PROJECT_DIR="$(pwd)"

if [ ! -f "manage.py" ]; then
  echo "ERROR: Run this from the Django project root, e.g. cd ~/restaurant_clocking"
  exit 1
fi

mkdir -p patch_backups_02
cp -f core/models.py patch_backups_02/models.py.bak
cp -f core/views.py patch_backups_02/views.py.bak

python3 <<'PY'
from pathlib import Path
import re

models_path = Path("core/models.py")
views_path = Path("core/views.py")

models = models_path.read_text()

# 1) Make sure ClockEvent has a safe notes field with default=""
if "notes =" in models and "ClockEvent" in models:
    models = re.sub(
        r"notes\s*=\s*models\.[A-Za-z]+Field\([^\n]*\)",
        'notes = models.TextField(blank=True, default="")',
        models,
    )
else:
    # Insert notes field after method if possible, otherwise after timestamp.
    if re.search(r"method\s*=\s*models\.[A-Za-z]+Field\([^\n]*\)", models):
        models = re.sub(
            r"(method\s*=\s*models\.[A-Za-z]+Field\([^\n]*\)\n)",
            r'\1    notes = models.TextField(blank=True, default="")\n',
            models,
            count=1,
        )
    else:
        models = re.sub(
            r"(timestamp\s*=\s*models\.[A-Za-z]+Field\([^\n]*\)\n)",
            r'\1    notes = models.TextField(blank=True, default="")\n',
            models,
            count=1,
        )

# 2) Ensure clock_type length is suitable for BREAK_START / BREAK_END
models = re.sub(
    r"clock_type\s*=\s*models\.CharField\(([^)]*)max_length\s*=\s*\d+([^)]*)\)",
    lambda m: "clock_type = models.CharField(" + re.sub(r"max_length\s*=\s*\d+", "max_length=20", m.group(1) + "max_length=20" + m.group(2)) + ")"
    if "choices" not in (m.group(1)+m.group(2)) else "clock_type = models.CharField(" + re.sub(r"max_length\s*=\s*\d+", "max_length=20", m.group(1)+"max_length=20"+m.group(2)) + ")",
    models,
)
# Clean possible duplicated max_length caused by unusual formatting
models = models.replace("max_length=20max_length=20", "max_length=20")

models_path.write_text(models)

views = views_path.read_text()

# 3) Ensure every ClockEvent.objects.create(...) block has notes="" if none supplied
def add_notes_to_create(match):
    block = match.group(0)
    if "notes=" in block:
        return block
    # Add before closing parenthesis of ClockEvent.objects.create()
    return block[:-1].rstrip() + ',\n        notes="",\n    )'

views = re.sub(
    r"ClockEvent\.objects\.create\(\s*(?:[^()]|\([^()]*\))*?\)",
    add_notes_to_create,
    views,
    flags=re.S,
)

# 4) Add simple session persistence inside smart_clock_page without removing PIN workflow.
# This is intentionally conservative:
# - If employee_number/PIN are posted, existing code still authenticates as before.
# - Once authenticated, staff employee id is stored in request.session["clock_employee_id"].
# - Future POSTs with only action can reuse that session employee.
if "clock_employee_id" not in views and "def smart_clock_page" in views:
    # Add a small helper after imports
    helper = 