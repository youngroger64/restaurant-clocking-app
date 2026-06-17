#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")" 2>/dev/null || true
# If run from project root, stay there. If downloaded elsewhere, user should run from ~/restaurant_clocking.
if [ ! -f "manage.py" ]; then
  echo "Please run this from the Django project root, e.g. cd ~/restaurant_clocking"
  exit 1
fi

STAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="backups_patch_35_${STAMP}"
mkdir -p "$BACKUP_DIR"
cp core/urls.py "$BACKUP_DIR/urls.py.before"

python3 - <<'PY'
from pathlib import Path
import re

p = Path('core/urls.py')
s = p.read_text()

# Fix the bad urlpatterns entry created by patch 34:
# path('manager/corrections/', manager_corrections,
#      manager_demo_week_simulator, name='manager_corrections'),
s = re.sub(
    r"path\(\s*['\"]manager/corrections/['\"]\s*,\s*manager_corrections\s*,\s*manager_demo_week_simulator\s*,\s*name\s*=\s*['\"]manager_corrections['\"]\s*\)\s*,",
    "path('manager/corrections/', manager_corrections, name='manager_corrections'),",
    s,
    flags=re.S,
)

# Remove duplicate demo-week URL entries if patch has been applied more than once.
demo_line = "path('manager/demo-week/', manager_demo_week_simulator, name='manager_demo_week_simulator'),"
lines = s.splitlines()
new_lines = []
seen_demo = False
for line in lines:
    if "manager/demo-week/" in line and "manager_demo_week_simulator" in line:
        if not seen_demo:
            indent = re.match(r"\s*", line).group(0) or "    "
            new_lines.append(indent + demo_line)
            seen_demo = True
        continue
    new_lines.append(line)
s = "\n".join(new_lines) + "\n"

# Add demo-week URL if missing.
if "manager/demo-week/" not in s:
    marker = "path('manager/corrections/', manager_corrections, name='manager_corrections'),"
    if marker in s:
        s = s.replace(marker, marker + "\n    " + demo_line)
    else:
        s = s.replace("urlpatterns = [", "urlpatterns = [\n    " + demo_line, 1)

# Ensure the view is imported without corrupting other imports.
if "manager_demo_week_simulator" not in s.split("urlpatterns", 1)[0]:
    # Best case: existing multiline import from .views import (...)
    m = re.search(r"from\s+\.views\s+import\s*\((.*?)\)", s, flags=re.S)
    if m:
        body = m.group(1)
        if "manager_demo_week_simulator" not in body:
            body = body.rstrip() + ",\n    manager_demo_week_simulator\n"
            s = s[:m.start(1)] + body + s[m.end(1):]
    else:
        # Single-line import: append to it.
        s = re.sub(
            r"^(from\s+\.views\s+import\s+)(.+)$",
            lambda mm: mm.group(1) + mm.group(2).rstrip() + ", manager_demo_week_simulator",
            s,
            count=1,
            flags=re.M,
        )

p.write_text(s)
PY

python manage.py check

echo "Patch 35 applied. core/urls.py fixed. Backup saved to $BACKUP_DIR"
