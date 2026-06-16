#!/usr/bin/env bash
set -euo pipefail

echo "=== Restaurant Clocking Patch 11: Manager Cleanup, Delete-All, and Payroll Clarity ==="
echo "Adds:"
echo "  - Delete all clock events for selected date in Manager Corrections"
echo "  - Removes Staff Clocking button from manager landing page header"
echo "  - Adds clearer weekly payroll wording and status explanation"
echo "  - Adds Review/Fix guidance for weekly payroll rows"
echo

if [ ! -f "manage.py" ]; then
  echo "ERROR: Run from Django project root: cd ~/restaurant_clocking"
  exit 1
fi

stamp=$(date +%Y%m%d_%H%M%S)
mkdir -p "patch_backups_11_$stamp"
cp -f core/views.py "patch_backups_11_$stamp/views.py.before_patch11"
cp -f templates/home.html "patch_backups_11_$stamp/home.html.before_patch11" 2>/dev/null || true
cp -f templates/manager_corrections.html "patch_backups_11_$stamp/manager_corrections.html.before_patch11" 2>/dev/null || true
cp -f templates/weekly_summary.html "patch_backups_11_$stamp/weekly_summary.html.before_patch11" 2>/dev/null || true

# ------------------------------------------------------------------
# 1) Patch manager_corrections view to support delete_all_for_date.
# ------------------------------------------------------------------
cat > /tmp/patch11_views.py <<'PY'
from pathlib import Path
import re

p = Path("core/views.py")
s = p.read_text()

matches = list(re.finditer(r"^def manager_corrections\(request\):", s, flags=re.M))
if matches:
    start = matches[-1].start()
    m = re.search(r"\n(?=def |class |# -------------------------------------------------------------------)", s[start+1:])
    end = len(s) if not m else start + 1 + m.start()
    func = s[start:end]

    if 'action == "delete_all_for_date"' not in func:
        marker = '        elif action == "delete_event":'
        insert = '''        elif action == "delete_all_for_date":
            confirm = request.POST.get("confirm_delete_all")
            reason = (request.POST.get("reason") or "").strip()

            if confirm != "yes":
                message = "Please tick the confirmation box before deleting all events for this date."
            elif not reason:
                message = "Please enter a reason before deleting all events."
            else:
                qs = ClockEvent.objects.filter(timestamp__date=selected_date)
                count = qs.count()
                qs.delete()
                message = f"Deleted {count} clock event(s) for {selected_date}. Reason: {reason}"

'''
        if marker in func:
            func = func.replace(marker, insert + marker)
        else:
            # Fallback: insert after action assignment.
            func = func.replace(
                '        action = request.POST.get("action")\n',
                '        action = request.POST.get("action")\n\n' + insert,
                1
            )

        s = s[:start] + func + s[end:]
        p.write_text(s)
else:
    print("WARNING: manager_corrections view not found; skipping view patch.")
PY

python3 /tmp/patch11_views.py

# ------------------------------------------------------------------
# 2) Remove Staff Clocking from manager landing page header.
# ------------------------------------------------------------------
if [ -f templates/home.html ]; then
python3 <<'PY'
from pathlib import Path
p = Path("templates/home.html")
s = p.read_text()
s = s.replace('            <a class="button" href="/clock/">Staff Clocking</a>\n', '')
s = s.replace('            <a class="button" href="/manager/today/">Full Today View</a>', '            <a class="button" href="/manager/today/">Full Today View</a>')
p.write_text(s)
PY
fi

# ------------------------------------------------------------------
# 3) Patch Manager Corrections template with Delete All For Date.
# ------------------------------------------------------------------
if [ -f templates/manager_corrections.html ]; then
python3 <<'PY'
from pathlib import Path

p = Path("templates/manager_corrections.html")
s = p.read_text()

if "delete_all_for_date" not in s:
    block = '''
    <div class="section" style="border: 2px solid #b42318;">
        <h2>Delete all clock events for {{ selected_date }}</h2>
        <p class="warn">
            Use this only for clearing test data or a badly entered day.
            This deletes every clock event shown on this corrections page for the selected date.
        </p>
        <form method="post" onsubmit="return confirm('Delete ALL clock events for this date? This cannot be undone.');">
            {% csrf_token %}
            <input type="hidden" name="action" value="delete_all_for_date">
            <p>
                <label><input type="checkbox" name="confirm_delete_all" value="yes"> I understand this deletes all clock events for this date</label>
            </p>
            <p>
                <label>Reason</label><br>
                <textarea name="reason" required placeholder="Example: clearing test data before entering real records"></textarea>
            </p>
            <button class="danger" type="submit">Delete All Events For This Date</button>
        </form>
    </div>
'''
    # Put the delete-all tool after the event table if possible, before bottom navigation.
    if '<p>\n        <a class="button" href="/">' in s:
        s = s.replace('<p>\n        <a class="button" href="/">', block + '\n<p>\n        <a class="button" href="/">', 1)
    elif "</body>" in s:
        s = s.replace("</body>", block + "\n</body>", 1)
    else:
        s += block

if ".danger" not in s:
    s = s.replace("</style>", ".danger { background: #b42318; color: white; }\n.warn { color: #b42318; font-weight: bold; }\n</style>")

p.write_text(s)
PY
else
    echo "WARNING: templates/manager_corrections.html not found; skipping template patch."
fi

# ------------------------------------------------------------------
# 4) Add a clearer explanation to Weekly Summary.
# ------------------------------------------------------------------
if [ -f templates/weekly_summary.html ]; then
python3 <<'PY'
from pathlib import Path
p = Path("templates/weekly_summary.html")
s = p.read_text()

if "What the status means" not in s:
    explanation = '''
<div class="section">
    <h2>What the status means</h2>
    <p class="muted">
        <strong>OK</strong> means there are no clocking problems detected for that employee for this week.
        It does not mean they worked all rostered hours; it means payroll can calculate from the clock events available.
    </p>
    <p class="muted">
        Red warnings such as <strong>Rostered but absent</strong>, <strong>Missing clock-out</strong>,
        <strong>Check clock sequence</strong>, or <strong>Working but not rostered</strong> should be reviewed before payroll export.
    </p>
    <p class="muted">
        If a row is wrong, use <strong>Payroll Problems</strong> or <strong>Manager Corrections</strong> to edit/delete/add clock events.
    </p>
</div>
'''
    # Insert after first header/container if possible.
    if "<h1" in s:
        pos = s.find("</h1>")
        if pos != -1:
            pos = s.find("\n", pos)
            s = s[:pos] + "\n" + explanation + s[pos:]
        else:
            s = explanation + s
    else:
        s = explanation + s

# Rename Warning column wording if present.
s = s.replace(">Warning<", ">Status / Issue<")
s = s.replace(">Warnings<", ">Status / Issue<")

# Add simple CSS if no section/muted styles exist.
if ".section" not in s and "</style>" in s:
    s = s.replace("</style>", ".section { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 18px; margin: 18px 0; }\n.muted { color: #666; }\n</style>")

p.write_text(s)
PY
fi

echo "Checking Python syntax..."
python -m py_compile core/views.py

echo "Running Django checks..."
python manage.py check

echo
echo "Patch 11 complete."
echo "Restart:"
echo "  sudo systemctl restart restaurant_clocking"
