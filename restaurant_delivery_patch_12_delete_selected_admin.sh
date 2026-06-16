#!/usr/bin/env bash
set -euo pipefail

echo "=== Restaurant Clocking Patch 12: Delete Selected + Admin Setup Button ==="
echo "Changes:"
echo "  - Adds Admin / Setup button back to homepage"
echo "  - Removes old Delete All blocks from correction pages"
echo "  - Adds checkbox-based Delete Selected to Manager Corrections"
echo "  - Adds checkbox-based Delete Selected to Fix Day page"
echo "  - Changes 'Clocked out' wording on homepage to 'Finished Shift'"
echo

if [ ! -f "manage.py" ]; then
  echo "ERROR: Run from Django project root: cd ~/restaurant_clocking"
  exit 1
fi

stamp=$(date +%Y%m%d_%H%M%S)
mkdir -p "patch_backups_12_$stamp"
cp -f core/views.py "patch_backups_12_$stamp/views.py.before_patch12"
cp -f templates/home.html "patch_backups_12_$stamp/home.html.before_patch12" 2>/dev/null || true
cp -f templates/manager_corrections.html "patch_backups_12_$stamp/manager_corrections.html.before_patch12" 2>/dev/null || true
cp -f templates/manager_fix_day.html "patch_backups_12_$stamp/manager_fix_day.html.before_patch12" 2>/dev/null || true

# ------------------------------------------------------------------
# Patch views: manager_corrections + manager_fix_day support delete_selected.
# ------------------------------------------------------------------
cat > /tmp/patch12_views.py <<'PY'
from pathlib import Path
import re

p = Path("core/views.py")
s = p.read_text()

# Remove older delete-all branches added previously.
s = re.sub(
    r'\n\s*elif action == "delete_all_for_date":[\s\S]*?(?=\n\s*elif action == "delete_event":)',
    "\n",
    s
)
s = re.sub(
    r'\n\s*elif mode == "delete_all":[\s\S]*?(?=\n\s*elif mode == "delete":)',
    "\n",
    s
)

# Patch manager_corrections action handling.
matches = list(re.finditer(r"^def manager_corrections\(request\):", s, flags=re.M))
if matches:
    start = matches[-1].start()
    m = re.search(r"\n(?=def |class |# -------------------------------------------------------------------)", s[start+1:])
    end = len(s) if not m else start + 1 + m.start()
    func = s[start:end]

    if 'action == "delete_selected"' not in func:
        marker = '        elif action == "delete_event":'
        insert = '''        elif action == "delete_selected":
            ids = request.POST.getlist("selected_events")
            if not ids:
                message = "No events selected."
            else:
                qs = ClockEvent.objects.filter(id__in=ids, timestamp__date=selected_date)
                count = qs.count()
                qs.delete()
                message = f"Deleted {count} selected event(s)."

'''
        if marker in func:
            func = func.replace(marker, insert + marker)
        else:
            func = func.replace(
                '        action = request.POST.get("action")\n',
                '        action = request.POST.get("action")\n\n' + insert,
                1
            )
    s = s[:start] + func + s[end:]

# Patch manager_fix_day mode handling.
matches = list(re.finditer(r"^def manager_fix_day\(request\):", s, flags=re.M))
if matches:
    start = matches[-1].start()
    m = re.search(r"\n(?=def |class |# -------------------------------------------------------------------)", s[start+1:])
    end = len(s) if not m else start + 1 + m.start()
    func = s[start:end]

    if 'mode == "delete_selected"' not in func:
        marker = '        elif mode == "delete":'
        insert = '''        elif mode == "delete_selected":
            ids = request.POST.getlist("selected_events")
            if not ids:
                error = "No events selected."
            else:
                qs = ClockEvent.objects.filter(
                    id__in=ids,
                    employee=employee,
                    timestamp__date=event_date
                )
                count = qs.count()
                qs.delete()
                message = f"Deleted {count} selected event(s) for {employee.name}."

'''
        if marker in func:
            func = func.replace(marker, insert + marker)
        else:
            func = func.replace(
                '        mode = request.POST.get("mode")\n',
                '        mode = request.POST.get("mode")\n\n' + insert,
                1
            )
    s = s[:start] + func + s[end:]

p.write_text(s)
PY

python3 /tmp/patch12_views.py

# ------------------------------------------------------------------
# Homepage: add Admin / Setup button and improve completed shift wording.
# ------------------------------------------------------------------
if [ -f templates/home.html ]; then
python3 <<'PY'
from pathlib import Path
p = Path("templates/home.html")
s = p.read_text()

# Add Admin / Setup if missing.
if 'href="/admin/"' not in s:
    anchor = '<a class="button secondary" href="/manager/weekly-summary/?week_start={{ week_start|date:\'Y-m-d\' }}">Weekly Payroll</a>'
    replacement = anchor + '\n            <a class="button secondary" href="/admin/">Admin / Setup</a>'
    if anchor in s:
        s = s.replace(anchor, replacement, 1)
    else:
        s = s.replace('</div>\n    </div>\n\n    <div class="cards">', '<a class="button secondary" href="/admin/">Admin / Setup</a>\n        </div>\n    </div>\n\n    <div class="cards">', 1)

# Manager-friendly wording.
s = s.replace('Clocked out', 'Finished Shift')
s = s.replace('Clocked Out', 'Finished Shift')
s = s.replace('{{ row.status }}', '{% if row.status == "Clocked out" %}Finished Shift{% else %}{{ row.status }}{% endif %}')

p.write_text(s)
PY
fi

# ------------------------------------------------------------------
# Manager Corrections template: replace individual Delete-only flow with checkboxes + Delete Selected.
# Keep individual Delete as backup if already present, but add selection.
# Remove delete-all block.
# ------------------------------------------------------------------
if [ -f templates/manager_corrections.html ]; then
python3 <<'PY'
from pathlib import Path
import re

p = Path("templates/manager_corrections.html")
s = p.read_text()

# Remove previously added delete-all blocks.
s = re.sub(
    r'\s*<div class="section"[^>]*>\s*<h2>Delete all clock events for \{\{ selected_date \}\}</h2>[\s\S]*?</div>\s*',
    '\n',
    s
)

# Add CSS for danger if missing.
if ".danger" not in s and "</style>" in s:
    s = s.replace("</style>", ".danger { background: #b42318; color: white; }\n</style>")

# Add Select column header.
s = s.replace("<tr>\n                <th>Employee</th>", "<tr>\n                <th>Select</th>\n                <th>Employee</th>")
s = s.replace("<tr><th>Employee</th>", "<tr><th>Select</th><th>Employee</th>")

# Add checkbox at event row start if not already.
if 'name="selected_events"' not in s:
    s = s.replace(
        "{% for event in events %}\n            <tr>\n                <td>{{ event.employee.name }}</td>",
        "{% for event in events %}\n            <tr>\n                <td><input type=\"checkbox\" name=\"selected_events\" value=\"{{ event.id }}\" form=\"delete-selected-form\"></td>\n                <td>{{ event.employee.name }}</td>"
    )
    s = s.replace(
        "{% for event in events %}\n            <tr><td>{{ event.employee.name }}</td>",
        "{% for event in events %}\n            <tr><td><input type=\"checkbox\" name=\"selected_events\" value=\"{{ event.id }}\" form=\"delete-selected-form\"></td><td>{{ event.employee.name }}</td>"
    )

# Insert Delete Selected form after the events table.
if 'id="delete-selected-form"' not in s:
    form = '''
        <form id="delete-selected-form" method="post" onsubmit="return confirm('Delete selected clock events?');" style="margin-top: 12px;">
            {% csrf_token %}
            <input type="hidden" name="action" value="delete_selected">
            <button class="danger" type="submit">Delete Selected</button>
        </form>
'''
    # Put after first table in Clock Events section.
    idx = s.find("</table>")
    if idx != -1:
        s = s[:idx+8] + form + s[idx+8:]
    else:
        s += form

# Update colspan if old empty rows have too few columns.
s = re.sub(r'colspan="5"', 'colspan="6"', s)
s = re.sub(r'colspan="4"', 'colspan="5"', s)

p.write_text(s)
PY
fi

# ------------------------------------------------------------------
# Fix Day template: add Delete Selected to the event list and remove delete all employee/day block.
# ------------------------------------------------------------------
if [ -f templates/manager_fix_day.html ]; then
python3 <<'PY'
from pathlib import Path
import re

p = Path("templates/manager_fix_day.html")
s = p.read_text()

# Remove old delete-all block.
s = re.sub(
    r'\s*<div class="section"[^>]*>\s*<h2>Delete all events for this day</h2>[\s\S]*?</div>\s*',
    '\n',
    s
)

if ".danger" not in s and "</style>" in s:
    s = s.replace("</style>", ".danger { background: #b42318; color: white; }\n</style>")

# Add Select header.
s = s.replace("<tr>\n                <th>Type</th>", "<tr>\n                <th>Select</th>\n                <th>Type</th>")
s = s.replace("<tr><th>Type</th>", "<tr><th>Select</th><th>Type</th>")
s = s.replace("<tr>\n                <th>Employee</th>", "<tr>\n                <th>Select</th>\n                <th>Employee</th>")

# Add checkbox to event rows.
if 'name="selected_events"' not in s:
    s = s.replace(
        "{% for event in events %}\n            <tr>\n                <td>{{ event.clock_type }}</td>",
        "{% for event in events %}\n            <tr>\n                <td><input type=\"checkbox\" name=\"selected_events\" value=\"{{ event.id }}\" form=\"delete-selected-form\"></td>\n                <td>{{ event.clock_type }}</td>"
    )
    s = s.replace(
        "{% for event in events %}\n            <tr>\n                <td>{{ event.employee.name }}</td>",
        "{% for event in events %}\n            <tr>\n                <td><input type=\"checkbox\" name=\"selected_events\" value=\"{{ event.id }}\" form=\"delete-selected-form\"></td>\n                <td>{{ event.employee.name }}</td>"
    )

# Insert Delete Selected form after event table.
if 'id="delete-selected-form"' not in s:
    form = '''
        <form id="delete-selected-form" method="post" onsubmit="return confirm('Delete selected clock events for this employee/day?');" style="margin-top: 12px;">
            {% csrf_token %}
            <input type="hidden" name="mode" value="delete_selected">
            <input type="hidden" name="employee_number" value="{{ employee.employee_number }}">
            <input type="hidden" name="event_date" value="{{ event_date|date:'Y-m-d' }}">
            <input type="hidden" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
            <button class="danger" type="submit">Delete Selected</button>
        </form>
'''
    idx = s.find("</table>")
    if idx != -1:
        s = s[:idx+8] + form + s[idx+8:]
    else:
        s += form

s = re.sub(r'colspan="5"', 'colspan="6"', s)
s = re.sub(r'colspan="4"', 'colspan="5"', s)

p.write_text(s)
PY
fi

echo "Checking Python syntax..."
python -m py_compile core/views.py

echo "Running Django checks..."
python manage.py check

echo
echo "Patch 12 complete."
echo "Restart:"
echo "  sudo systemctl restart restaurant_clocking"
