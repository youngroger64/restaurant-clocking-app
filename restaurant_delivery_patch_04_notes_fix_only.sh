#!/usr/bin/env bash
set -euo pipefail

echo "=== Restaurant Clocking Hotfix Patch 04 ==="
echo "Purpose: fix ClockEvent.notes NOT NULL crash cleanly."
echo "This patch intentionally does NOT attempt the session/login UI change yet."

if [ ! -f "manage.py" ]; then
  echo "ERROR: Run from Django project root: cd ~/restaurant_clocking"
  exit 1
fi

mkdir -p patch_backups_04
cp -f core/models.py patch_backups_04/models.py.bak
cp -f core/views.py patch_backups_04/views.py.bak

python3 <<'PY'
from pathlib import Path
import re

models_path = Path("core/models.py")
views_path = Path("core/views.py")

models = models_path.read_text()
views = views_path.read_text()

# 1) Ensure ClockEvent.clock_type can store BREAK_START and BREAK_END.
models = re.sub(
    r"clock_type\s*=\s*models\.CharField\(([^\n]*)max_length\s*=\s*\d+([^\n]*)\)",
    lambda m: "clock_type = models.CharField(" + m.group(1) + "max_length=20" + m.group(2) + ")",
    models
)

# 2) Ensure notes exists and has a safe default.
if re.search(r"notes\s*=\s*models\.TextField\(", models):
    models = re.sub(
        r"notes\s*=\s*models\.TextField\([^\n]*\)",
        'notes = models.TextField(blank=True, default="")',
        models
    )
else:
    # Insert notes after method field in ClockEvent.
    if re.search(r"method\s*=\s*models\.[A-Za-z]+Field\([^\n]*\)\n", models):
        models = re.sub(
            r"(method\s*=\s*models\.[A-Za-z]+Field\([^\n]*\)\n)",
            r'\1    notes = models.TextField(blank=True, default="")\n',
            models,
            count=1
        )
    else:
        raise SystemExit("Could not find ClockEvent.method field to insert notes after.")

models_path.write_text(models)

# 3) Make ordinary clock action creates include notes="".
# This specifically patches ClockEvent.objects.create(...) calls that do not already pass notes.
out = []
i = 0
needle = "ClockEvent.objects.create("
while True:
    start = views.find(needle, i)
    if start == -1:
        out.append(views[i:])
        break

    out.append(views[i:start])
    depth = 0
    end = None
    for j in range(start, len(views)):
        ch = views[j]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                end = j + 1
                break

    if end is None:
        out.append(views[start:])
        break

    block = views[start:end]
    if "notes=" not in block:
        close = block.rfind(")")
        block = block[:close].rstrip() + ',\n        notes="",\n    )'
    out.append(block)
    i = end

views = "".join(out)
views_path.write_text(views)
PY

echo "Creating migration if needed..."
python manage.py makemigrations core || true

echo "Applying migrations..."
python manage.py migrate

echo "Backfilling NULL notes if any exist..."
python manage.py shell <<'PY'
from core.models import ClockEvent
ClockEvent.objects.filter(notes__isnull=True).update(notes="")
print("Remaining NULL notes:", ClockEvent.objects.filter(notes__isnull=True).count())
PY

echo "Running Django checks..."
python manage.py check

echo
echo "Patch 04 complete."
echo "Restart your Django service/gunicorn, then test: clock in -> start break -> end break."
