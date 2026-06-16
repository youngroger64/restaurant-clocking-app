#!/usr/bin/env bash
set -euo pipefail

echo "=== Restaurant Clocking Patch 14: Simplify Manager Homepage Further ==="
echo "Changes:"
echo "  - Removes Payroll Status section from homepage"
echo "  - Removes Staff Exceptions section from homepage"
echo "  - Simplifies Needs Attention action buttons"
echo "  - Displays 'Back from break' as 'Working'"
echo

if [ ! -f "manage.py" ]; then
  echo "ERROR: Run from Django project root: cd ~/restaurant_clocking"
  exit 1
fi

stamp=$(date +%Y%m%d_%H%M%S)
mkdir -p "patch_backups_14_$stamp"
cp -f templates/home.html "patch_backups_14_$stamp/home.html.before_patch14" 2>/dev/null || true

cat > /tmp/patch14.py <<'PY'
from pathlib import Path
import re

p = Path("templates/home.html")
if not p.exists():
    raise SystemExit("templates/home.html not found")

s = p.read_text()

# Remove Payroll Status section entirely.
s = re.sub(
    r'\n\s*<div class="section">\s*<h2>Payroll Status</h2>[\s\S]*?</div>\s*(?=\n\s*<div class="section">|\n\s*</div>\s*</body>)',
    '\n',
    s,
    count=1
)

# Remove Staff Exceptions section entirely.
s = re.sub(
    r'\n\s*<div class="section">\s*<h2>Staff Exceptions</h2>[\s\S]*?</div>\s*(?=\n\s*</div>\s*</body>)',
    '\n',
    s,
    count=1
)

# Simplify Needs Attention wording.
s = s.replace(
    "Shift-specific issues: not arrived, late arrivals, break due, missed breaks, unrostered work, and clock-in/out problems.",
    "Only items that may need manager action are shown here."
)

# Remove Manager Corrections button from Needs Attention if present.
s = re.sub(
    r'\s*<a class="button secondary" href="/manager/corrections/">Manager Corrections</a>',
    '',
    s
)

# Rename Review Payroll Problems to Review Issues.
s = s.replace("Review Payroll Problems", "Review Issues")

# Make status wording more manager-friendly in Needs Attention.
s = s.replace("{{ row.status }}", '{% if row.status == "Back from break" %}Working{% elif row.status == "Clocked out" %}Finished Shift{% else %}{{ row.status }}{% endif %}')

# If empty Staff Exceptions text remains from failed regex, remove it.
s = s.replace("No unrostered staff are currently working.", "")

p.write_text(s)
PY

python3 /tmp/patch14.py

echo "Running Django checks..."
python manage.py check

echo
echo "Patch 14 complete."
echo "Restart:"
echo "  sudo systemctl restart restaurant_clocking"
