#!/usr/bin/env bash
set -euo pipefail

echo "=== Restaurant Clocking Patch 13: Simplify homepage + clearer correction page ==="
echo "Changes:"
echo "  - Removes duplicate Staff Working Now section from homepage"
echo "  - Makes Fix Day page clearer for absent/not-arrived staff"
echo "  - Hides Delete Selected when there are no events"
echo "  - Adds guidance: contact employee; only add clock events if they actually worked"
echo

if [ ! -f "manage.py" ]; then
  echo "ERROR: Run from Django project root: cd ~/restaurant_clocking"
  exit 1
fi

stamp=$(date +%Y%m%d_%H%M%S)
mkdir -p "patch_backups_13_$stamp"
cp -f templates/home.html "patch_backups_13_$stamp/home.html.before_patch13" 2>/dev/null || true
cp -f templates/manager_fix_day.html "patch_backups_13_$stamp/manager_fix_day.html.before_patch13" 2>/dev/null || true

cat > /tmp/patch13.py <<'PY'
from pathlib import Path
import re

home = Path("templates/home.html")
if home.exists():
    s = home.read_text()

    s = re.sub(
        r'\n\s*<div class="section">\s*<h2>Staff Working Now</h2>[\s\S]*?</div>\s*(?=\n\s*<div class="section">)',
        '\n',
        s,
        count=1
    )

    s = s.replace(
        "The main job of this page is to show who was rostered, who has arrived, and who needs a follow-up.",
        "Start here: who was rostered, who arrived, who has not arrived, and what needs attention."
    )

    home.write_text(s)


fix = Path("templates/manager_fix_day.html")
if fix.exists():
    s = fix.read_text()

    s = s.replace("Current calculated result", "Current shift result")

    status_replacement = '''<strong>Status:</strong>
        {% if day.status == "No activity" and "Rostered but absent" in day.issue %}
            Not Arrived
        {% elif day.status == "No activity" %}
            No clock records
        {% elif day.status == "Clocked out" %}
            Finished Shift
        {% else %}
            {{ day.status }}
        {% endif %}'''

    s = re.sub(
        r"<strong>Status:</strong>\s*\{\{\s*day\.status\s*\}\}",
        status_replacement,
        s
    )

    s = s.replace("Rostered but absent", "Rostered but not arrived")

    if "Recommended manager action" not in s:
        guidance = '''
<div class="section">
    <h2>Recommended manager action</h2>
    {% if "not arrived" in day.issue|lower or "absent" in day.issue|lower %}
        <p class="warn">
            This employee was rostered but has not clocked in. Contact the employee or shift manager.
        </p>
        <p class="muted">
            Do not add a clock-in unless the employee actually worked and simply forgot to clock in.
        </p>
        {% if employee.phone_number %}
            <p><a class="button" href="tel:{{ employee.phone_number }}">Call Employee</a></p>
        {% endif %}
    {% elif day.missing_clock_out %}
        <p class="warn">This looks like a missing clock-out. Add the correct clock-out time if the finish time has been confirmed.</p>
    {% elif day.invalid_sequence %}
        <p class="warn">The clock sequence looks wrong. Review the events below and delete or add records as needed.</p>
    {% else %}
        <p class="ok">No obvious correction is required for this day.</p>
    {% endif %}
</div>
'''
        if "Use this page to correct the day" in s:
            s = s.replace("Use this page to correct the day", guidance + "\nUse this page to correct the day", 1)
        elif "<h2>Events on this day</h2>" in s:
            s = s.replace("<h2>Events on this day</h2>", guidance + "\n<h2>Events on this day</h2>", 1)
        else:
            s += guidance

    s = s.replace(
        "Use this page to correct the day, not just to add random events. After adding or deleting an event, the calculated result above should make sense before payroll is exported.",
        "Use this page only when the clock records are wrong. After a correction, the shift result above should make sense before payroll is exported."
    )

    if 'id="delete-selected-form"' in s and "{% if events %}" not in s:
        s = re.sub(
            r'(\s*<form id="delete-selected-form"[\s\S]*?</form>)',
            r'\n{% if events %}\1\n{% endif %}',
            s,
            count=1
        )

    s = s.replace("No clock events recorded for this day.", "No clock records for this employee on this day.")
    s = s.replace("<h2>Add missing event</h2>", "<h2>Add confirmed missing clock event</h2>")
    s = s.replace("Add missing event", "Add confirmed missing clock event")

    if "</style>" in s and ".muted" not in s:
        s = s.replace("</style>", ".muted { color: #666; }\n.warn { color: #b42318; font-weight: bold; }\n.ok { color: #1a7f37; font-weight: bold; }\n</style>")

    fix.write_text(s)
PY

python3 /tmp/patch13.py

echo "Running Django checks..."
python manage.py check

echo
echo "Patch 13 complete."
echo "Restart:"
echo "  sudo systemctl restart restaurant_clocking"
