#!/usr/bin/env bash
set -euo pipefail

echo "=== Restaurant Clocking Patch 07: Clean duplicate view functions ==="
echo "This patch removes earlier duplicate function definitions from core/views.py."
echo "It keeps the LAST definition of each function, which is what Python was already using."
echo

if [ ! -f "manage.py" ]; then
  echo "ERROR: Run this from Django project root: cd ~/restaurant_clocking"
  exit 1
fi

stamp=$(date +%Y%m%d_%H%M%S)
mkdir -p "patch_backups_07_$stamp"
cp -f core/views.py "patch_backups_07_$stamp/views.py.before_duplicate_cleanup"

echo "Before cleanup:"
grep -n "^def " core/views.py || true

python3 <<'PY'
from pathlib import Path
import re
from collections import Counter

path = Path("core/views.py")
lines = path.read_text().splitlines(keepends=True)

# Identify top-level def blocks. Include immediately preceding decorators.
blocks = []
for i, line in enumerate(lines):
    m = re.match(r"^def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", line)
    if not m:
        continue

    name = m.group(1)

    start = i
    # Include decorators directly above the def.
    j = i - 1
    while j >= 0 and re.match(r"^@[A-Za-z_]", lines[j]):
        start = j
        j -= 1

    # End at next top-level def/class. Keep comments and imports outside blocks.
    end = len(lines)
    for k in range(i + 1, len(lines)):
        if re.match(r"^(def|class)\s+", lines[k]):
            end = k
            break

    blocks.append({
        "name": name,
        "start": start,
        "def_line": i,
        "end": end,
    })

counts = Counter(b["name"] for b in blocks)
last_block_for_name = {}
for idx, b in enumerate(blocks):
    last_block_for_name[b["name"]] = idx

remove_ranges = []
removed = []
for idx, b in enumerate(blocks):
    if counts[b["name"]] > 1 and idx != last_block_for_name[b["name"]]:
        remove_ranges.append((b["start"], b["end"]))
        removed.append((b["name"], b["def_line"] + 1, b["end"]))

# Merge overlapping ranges
remove_ranges.sort()
merged = []
for start, end in remove_ranges:
    if not merged or start > merged[-1][1]:
        merged.append([start, end])
    else:
        merged[-1][1] = max(merged[-1][1], end)

keep = [True] * len(lines)
for start, end in merged:
    for i in range(start, end):
        keep[i] = False

new_lines = [line for i, line in enumerate(lines) if keep[i]]
path.write_text("".join(new_lines))

print("Removed duplicate earlier definitions:")
if removed:
    for name, line_no, end in removed:
        print(f"  - {name} starting near line {line_no}")
else:
    print("  None found.")

# Sanity check: report remaining duplicate top-level defs.
new_text = path.read_text()
names = re.findall(r"^def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", new_text, flags=re.M)
dupes = [name for name, count in Counter(names).items() if count > 1]
if dupes:
    print("WARNING: duplicates still remain:", ", ".join(dupes))
else:
    print("No duplicate top-level function definitions remain.")
PY

echo
echo "After cleanup:"
grep -n "^def " core/views.py || true

echo
echo "Checking Python syntax..."
python -m py_compile core/views.py

echo
echo "Running Django checks..."
python manage.py check

echo
echo "Patch 07 complete."
echo "Backup saved in patch_backups_07_$stamp/"
echo
echo "Now restart:"
echo "  sudo systemctl restart restaurant_clocking"
