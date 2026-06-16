#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-$PWD}"
cd "$APP_DIR"

if [ ! -f manage.py ] || [ ! -d templates ]; then
  echo "Run this from the restaurant_clocking project root, or set APP_DIR=/path/to/restaurant_clocking" >&2
  exit 1
fi

STAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="backups_patch_32_${STAMP}"
mkdir -p "$BACKUP_DIR/templates"
cp templates/home.html "$BACKUP_DIR/templates/home.html" 2>/dev/null || true
cp templates/manager_today.html "$BACKUP_DIR/templates/manager_today.html" 2>/dev/null || true

python - <<'PY'
from pathlib import Path
import re


def remove_dangling_break_if_before_roster(text: str) -> str:
    """Patch 31 could leave an opening break_attention if immediately before Service Day Roster."""
    patterns = [
        r"\n\s*\{%\s*if\s+break_attention_count\s*>\s*0\s*%\}\s*\n\s*(<div class=\"section\"[^>]*>\s*\n\s*<div class=\"section-title-line\"[^>]*>\s*\n\s*<h2>Service Day Roster</h2>)",
        r"\n\s*\{%\s*if\s+break_attention_count\s*>\s*0\s*%\}\s*\n\s*(<div class=\"section\"[^>]*>\s*\n\s*<h2>Service Day Roster)",
        r"\n\s*\{%\s*if\s+break_attention_count\s*>\s*0\s*%\}\s*\n\s*(<div class=\"section\"[^>]*>\s*\n\s*<h2>Service Day Roster Review)",
    ]
    for pat in patterns:
        text = re.sub(pat, r"\n\1", text, flags=re.S)
    return text


def remove_duplicate_break_section(text: str) -> str:
    # If a full duplicate section still exists, remove only that section. The top card can remain.
    headings = ["Breaks Needing Action", "Break Attention"]
    for heading in headings:
        marker = f"<h2>{heading}</h2>"
        while marker in text:
            pos = text.find(marker)
            start = text.rfind('<div class="section"', 0, pos)
            if start == -1:
                break
            next_start = text.find('<div class="section"', pos + len(marker))
            if next_start == -1:
                # remove to end only if clearly before a following major section cannot be found
                break
            text = text[:start] + text[next_start:]
    return text

for template_name in ["home.html", "manager_today.html"]:
    path = Path("templates") / template_name
    if not path.exists():
        continue
    s = path.read_text()
    s = remove_duplicate_break_section(s)
    s = remove_dangling_break_if_before_roster(s)
    # Remove any broken Django comment markers left by earlier patches.
    s = s.replace("{#", "").replace("#}", "")
    path.write_text(s)

# Lightweight Django-template block balance check for the edited templates.
# This catches the exact production error: an if without endif.
for template_name in ["home.html", "manager_today.html", "weekly_summary.html", "payroll_problems.html"]:
    path = Path("templates") / template_name
    if not path.exists():
        continue
    text = path.read_text()
    stack = []
    for m in re.finditer(r"\{%\s*(if|elif|else|endif|for|empty|endfor)\b[^%]*%\}", text):
        tag = m.group(1)
        line = text.count("\n", 0, m.start()) + 1
        if tag in ("if", "for"):
            stack.append((tag, line))
        elif tag in ("elif", "else"):
            if not stack or stack[-1][0] != "if":
                raise SystemExit(f"Template check failed in {template_name}: {tag} at line {line} has no matching if")
        elif tag == "endif":
            if not stack or stack[-1][0] != "if":
                raise SystemExit(f"Template check failed in {template_name}: endif at line {line} has no matching if")
            stack.pop()
        elif tag == "empty":
            if not stack or stack[-1][0] != "for":
                raise SystemExit(f"Template check failed in {template_name}: empty at line {line} has no matching for")
        elif tag == "endfor":
            if not stack or stack[-1][0] != "for":
                raise SystemExit(f"Template check failed in {template_name}: endfor at line {line} has no matching for")
            stack.pop()
    if stack:
        tag, line = stack[-1]
        raise SystemExit(f"Template check failed in {template_name}: unclosed {tag} from line {line}")

print("Template block check passed.")
PY

# Compile Python as a quick sanity check if core exists.
if [ -f core/views.py ]; then
  python -m py_compile core/views.py
fi

echo "Patch 32 applied. Backup saved to $BACKUP_DIR"
echo "Fixed the home page template error from the dangling break_attention if block."
