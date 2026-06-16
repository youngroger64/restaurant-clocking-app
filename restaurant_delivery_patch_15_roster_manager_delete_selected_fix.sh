#!/usr/bin/env bash
set -euo pipefail

echo "=== Restaurant Clocking Patch 15: Delete Selected Fix + Roster Manager ==="
echo "Adds delete-selected checkboxes on Fix Day and turns upload roster into a Roster Manager."
echo

if [ ! -f "manage.py" ]; then
  echo "ERROR: Run from Django project root: cd ~/restaurant_clocking"
  exit 1
fi

stamp=$(date +%Y%m%d_%H%M%S)
mkdir -p "patch_backups_15_$stamp"
cp -f core/views.py "patch_backups_15_$stamp/views.py.before_patch15"
cp -f core/urls.py "patch_backups_15_$stamp/urls.py.before_patch15"
cp -f templates/manager_fix_day.html "patch_backups_15_$stamp/manager_fix_day.html.before_patch15" 2>/dev/null || true
cp -f templates/upload_roster.html "patch_backups_15_$stamp/upload_roster.html.before_patch15" 2>/dev/null || true

cat > /tmp/patch15.py <<'PY'
from pathlib import Path
import re

views_path = Path("core/views.py")
urls_path = Path("core/urls.py")
views = views_path.read_text()
urls = urls_path.read_text()

# 1) manager_fix_day delete_selected support
matches = list(re.finditer(r"^def manager_fix_day\(request\):", views, flags=re.M))
if matches:
    start = matches[-1].start()
    m = re.search(r"\n(?=def |class |# -------------------------------------------------------------------)", views[start+1:])
    end = len(views) if not m else start + 1 + m.start()
    func = views[start:end]

    if 'mode == "delete_selected"' not in func:
        marker = '        elif mode == "delete":'
        insert = """        elif mode == "delete_selected":
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

"""
        if marker in func:
            func = func.replace(marker, insert + marker)
        else:
            func = func.replace(
                '        mode = request.POST.get("mode")\n',
                '        mode = request.POST.get("mode")\n\n' + insert,
                1
            )
    views = views[:start] + func + views[end:]

# 2) Add roster manager views
if "def roster_manager" not in views:
    views += """

# -------------------------------------------------------------------
# Patch 15: Roster Manager helpers
# -------------------------------------------------------------------

from django.shortcuts import redirect as _patch15_redirect
from django.views.decorators.http import require_POST as _patch15_require_POST


def _patch15_current_week_start():
    today = timezone.localdate()
    return today - timedelta(days=today.weekday())


def _patch15_week_start_from_request(request):
    raw = request.GET.get("week_start") or request.POST.get("week_start")
    if raw:
        return datetime.strptime(raw, "%Y-%m-%d").date()
    return _patch15_current_week_start()


def roster_manager(request):
    week_start = _patch15_week_start_from_request(request)
    week_end = week_start + timedelta(days=6)

    # If a CSV is posted to this page, reuse the old upload_roster logic.
    if request.method == "POST" and request.FILES.get("roster_file"):
        return upload_roster(request)

    employees = Employee.objects.filter(active=True).order_by("name")
    shifts = RosterShift.objects.select_related("employee").filter(
        shift_date__gte=week_start,
        shift_date__lte=week_end,
    ).order_by("shift_date", "start_time", "employee__name")

    return render(request, "upload_roster.html", {
        "week_start": week_start,
        "week_end": week_end,
        "employees": employees,
        "shifts": shifts,
    })


@_patch15_require_POST
def roster_add_shift(request):
    week_start = _patch15_week_start_from_request(request)
    employee_id = request.POST.get("employee_id")
    shift_date = request.POST.get("shift_date")
    start_time = request.POST.get("start_time")
    end_time = request.POST.get("end_time")

    employee = Employee.objects.get(id=employee_id, active=True)
    RosterShift.objects.create(
        employee=employee,
        shift_date=datetime.strptime(shift_date, "%Y-%m-%d").date(),
        start_time=start_time,
        end_time=end_time,
    )

    return _patch15_redirect(f"/manager/upload-roster/?week_start={week_start.isoformat()}")


@_patch15_require_POST
def roster_update_shift(request, shift_id):
    week_start = _patch15_week_start_from_request(request)
    shift = RosterShift.objects.get(id=shift_id)
    employee_id = request.POST.get("employee_id")
    start_time = request.POST.get("start_time")
    end_time = request.POST.get("end_time")
    shift_date = request.POST.get("shift_date")

    if employee_id:
        shift.employee = Employee.objects.get(id=employee_id, active=True)
    if shift_date:
        shift.shift_date = datetime.strptime(shift_date, "%Y-%m-%d").date()
    if start_time:
        shift.start_time = start_time
    if end_time:
        shift.end_time = end_time

    shift.save()
    return _patch15_redirect(f"/manager/upload-roster/?week_start={week_start.isoformat()}")


@_patch15_require_POST
def roster_delete_shift(request, shift_id):
    week_start = _patch15_week_start_from_request(request)
    RosterShift.objects.filter(id=shift_id).delete()
    return _patch15_redirect(f"/manager/upload-roster/?week_start={week_start.isoformat()}")
"""

# 3) Patch URLs
m = re.search(r"from \.views import \(([\s\S]*?)\)", urls)
if m:
    block = m.group(1)
    for name in ["roster_manager", "roster_add_shift", "roster_update_shift", "roster_delete_shift"]:
        if name not in block:
            block += f"    {name},\n"
    urls = urls[:m.start(1)] + block + urls[m.end(1):]

urls = re.sub(
    r"path\('manager/upload-roster/',\s*upload_roster,\s*name='upload_roster'\)",
    "path('manager/upload-roster/', roster_manager, name='upload_roster')",
    urls
)

if "manager/roster/add-shift/" not in urls:
    extra = """    path('manager/roster/add-shift/', roster_add_shift, name='roster_add_shift'),
    path('manager/roster/update-shift/<int:shift_id>/', roster_update_shift, name='roster_update_shift'),
    path('manager/roster/delete-shift/<int:shift_id>/', roster_delete_shift, name='roster_delete_shift'),
"""
    urls = urls.replace("urlpatterns = [\n", "urlpatterns = [\n" + extra, 1)

views_path.write_text(views)
urls_path.write_text(urls)
PY

python3 /tmp/patch15.py

cat > templates/manager_fix_day.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Fix Employee Day</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #111827; }
        .container { max-width: 1050px; margin: auto; background: white; padding: 24px; border-radius: 14px; border: 1px solid #e5e7eb; }
        .section { background: #fff; border: 1px solid #e5e7eb; border-radius: 12px; padding: 18px; margin: 18px 0; }
        .info { background: #f9fafb; }
        .warning { background: #fff7ed; border-left: 4px solid #f59e0b; }
        .muted { color: #666; }
        .warn { color: #b42318; font-weight: bold; }
        .ok { color: #1a7f37; font-weight: bold; }
        table { width: 100%; border-collapse: collapse; margin-top: 12px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 10px; text-align: left; }
        th { background: #f9fafb; }
        input, select, textarea { padding: 8px; width: 100%; box-sizing: border-box; }
        textarea { min-height: 70px; }
        button, .button { display: inline-block; padding: 10px 14px; background: #2563eb; color: white; border: none; text-decoration: none; border-radius: 8px; font-weight: bold; cursor: pointer; }
        .secondary { background: #4b5563; }
        .danger { background: #b42318; color: white; }
        .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 18px; }
        .checkbox { width: auto; }
    </style>
</head>
<body>
<div class="container">

    <h1>Review {{ employee.name }} — {{ event_date|date:"F j, Y" }}</h1>

    {% if error %}<p class="warn">{{ error }}</p>{% endif %}
    {% if message %}<p class="ok">{{ message }}</p>{% endif %}

    <div class="section info">
        <h2>Current shift result</h2>
        <p><strong>Status:</strong>
            {% if day.status == "No activity" and "absent" in day.issue|lower %}
                Not Arrived
            {% elif day.status == "No activity" %}
                No clock records
            {% elif day.status == "Clocked out" %}
                Finished Shift
            {% elif day.status == "Back from break" %}
                Working
            {% else %}
                {{ day.status }}
            {% endif %}
        </p>
        <p><strong>Roster:</strong> {{ day.roster }}</p>
        <p><strong>Worked:</strong> {{ day.worked_hours }} hours</p>
        <p><strong>Break:</strong> {{ day.break_minutes }} mins</p>
        <p><strong>Issue:</strong> <span class="{% if day.is_urgent %}warn{% else %}muted{% endif %}">{{ day.issue }}</span></p>
    </div>

    <div class="section warning">
        <h2>Recommended manager action</h2>
        {% if "absent" in day.issue|lower or "not arrived" in day.issue|lower %}
            <p class="warn">This employee was rostered but has not clocked in.</p>
            <p>Contact the employee or shift manager. Only add a clock-in if the employee actually worked and forgot to clock in.</p>
        {% elif "clock" in day.issue|lower %}
            <p class="warn">The clock records look wrong. Review the events below and delete or add records as needed.</p>
        {% elif "late" in day.issue|lower %}
            <p class="warn">This employee arrived late. No clock correction is needed unless the clock-in time is wrong.</p>
        {% else %}
            <p class="ok">No obvious correction is required for this day.</p>
        {% endif %}
    </div>

    <div class="section">
        <h2>Events on this day</h2>

        <form id="delete-selected-form" method="post" onsubmit="return confirm('Delete selected clock events?');">
            {% csrf_token %}
            <input type="hidden" name="mode" value="delete_selected">
            <input type="hidden" name="employee_number" value="{{ employee.employee_number }}">
            <input type="hidden" name="event_date" value="{{ event_date|date:'Y-m-d' }}">
            <input type="hidden" name="week_start" value="{{ week_start|date:'Y-m-d' }}">

            <table>
                <tr>
                    <th>Select</th>
                    <th>Time</th>
                    <th>Type</th>
                    <th>Method</th>
                    <th>Notes</th>
                </tr>
                {% for event in events %}
                <tr>
                    <td><input class="checkbox" type="checkbox" name="selected_events" value="{{ event.id }}"></td>
                    <td>{{ event.timestamp|date:"H:i" }}</td>
                    <td>{{ event.get_clock_type_display }}</td>
                    <td>{{ event.method }}</td>
                    <td>{{ event.notes }}</td>
                </tr>
                {% empty %}
                <tr><td colspan="5" class="muted">No clock records for this employee on this day.</td></tr>
                {% endfor %}
            </table>

            {% if events %}
                <p><button class="danger" type="submit">Delete Selected</button></p>
            {% endif %}
        </form>
    </div>

    <div class="section">
        <h2>Add confirmed missing clock event</h2>
        <p class="muted">Use this only when the employee actually worked and a clock event is missing.</p>

        <form method="post">
            {% csrf_token %}
            <input type="hidden" name="mode" value="add">
            <input type="hidden" name="employee_number" value="{{ employee.employee_number }}">
            <input type="hidden" name="event_date" value="{{ event_date|date:'Y-m-d' }}">
            <input type="hidden" name="week_start" value="{{ week_start|date:'Y-m-d' }}">

            <div class="grid">
                <p>
                    <label>Event type</label><br>
                    <select name="clock_type" required>
                        <option value="IN">Clock In</option>
                        <option value="BREAK_START">Break Start</option>
                        <option value="BREAK_END">Break End</option>
                        <option value="OUT">Clock Out</option>
                    </select>
                </p>
                <p>
                    <label>Time</label><br>
                    <input type="time" name="event_time" required>
                </p>
            </div>

            <p>
                <label>Reason for correction</label><br>
                <textarea name="reason" required placeholder="Example: employee forgot to clock out; manager confirmed finish time was 22:15"></textarea>
            </p>

            <button type="submit">Add Event</button>
        </form>
    </div>

    <p>
        <a class="button secondary" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Back to Payroll Problems</a>
        <a class="button secondary" href="/">Home</a>
    </p>

</div>
</body>
</html>
HTML

cat > templates/upload_roster.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Roster Manager</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #111827; }
        .container { max-width: 1250px; margin: auto; }
        .section { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 22px; margin-bottom: 18px; }
        .muted { color: #666; }
        .warn { color: #b42318; font-weight: bold; }
        .ok { color: #1a7f37; font-weight: bold; }
        table { width: 100%; border-collapse: collapse; margin-top: 12px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 9px; text-align: left; vertical-align: top; }
        th { background: #f9fafb; }
        input, select { padding: 7px; box-sizing: border-box; }
        button, .button { display: inline-block; padding: 9px 12px; background: #2563eb; color: white; border: none; text-decoration: none; border-radius: 8px; font-weight: bold; cursor: pointer; }
        .secondary { background: #4b5563; }
        .danger { background: #b42318; }
        .small { font-size: 13px; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; }
    </style>
</head>
<body>
<div class="container">

    <div class="section">
        <h1>Roster Manager</h1>
        <p class="muted">
            Upload a roster, then review or adjust shifts here. This is useful when someone calls in sick,
            a shift is covered by someone else, or a clocked-in employee needs to be matched to the roster.
        </p>
        <p>
            <a class="button secondary" href="/">Home</a>
            <a class="button secondary" href="/manager/today/">Full Today View</a>
            <a class="button secondary" href="/admin/">Admin / Setup</a>
        </p>
    </div>

    <div class="section">
        <h2>Choose week</h2>
        <form method="get">
            <label>Week starting</label>
            <input type="date" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
            <button type="submit">View Week</button>
        </form>
    </div>

    <div class="section">
        <h2>Upload roster CSV</h2>
        <p class="muted">Upload is still useful for the weekly rota. After upload, check the table below and make any edits.</p>
        <form method="post" enctype="multipart/form-data" action="/manager/upload-roster/">
            {% csrf_token %}
            <input type="hidden" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
            <input type="file" name="roster_file" required>
            <button type="submit">Upload CSV</button>
        </form>
    </div>

    <div class="section">
        <h2>Add shift manually</h2>
        <form method="post" action="/manager/roster/add-shift/">
            {% csrf_token %}
            <input type="hidden" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
            <div class="grid">
                <p>
                    <label>Employee</label><br>
                    <select name="employee_id" required>
                        {% for employee in employees %}
                            <option value="{{ employee.id }}">{{ employee.name }} ({{ employee.employee_number }})</option>
                        {% endfor %}
                    </select>
                </p>
                <p><label>Date</label><br><input type="date" name="shift_date" value="{{ week_start|date:'Y-m-d' }}" required></p>
                <p><label>Start</label><br><input type="time" name="start_time" required></p>
                <p><label>End</label><br><input type="time" name="end_time" required></p>
            </div>
            <button type="submit">Add Shift</button>
        </form>
    </div>

    <div class="section">
        <h2>Roster for {{ week_start|date:"M j" }} - {{ week_end|date:"M j, Y" }}</h2>
        <p class="muted">
            Edit names/times here when cover is arranged or a mistake is spotted.
            If someone calls in sick, reassign the shift to the cover person or delete/cancel the shift.
        </p>

        <table>
            <tr>
                <th>Date</th>
                <th>Employee</th>
                <th>Start</th>
                <th>End</th>
                <th>Update</th>
                <th>Delete</th>
            </tr>
            {% for shift in shifts %}
            <tr>
                <form method="post" action="/manager/roster/update-shift/{{ shift.id }}/">
                    {% csrf_token %}
                    <input type="hidden" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
                    <td><input type="date" name="shift_date" value="{{ shift.shift_date|date:'Y-m-d' }}"></td>
                    <td>
                        <select name="employee_id">
                            {% for employee in employees %}
                                <option value="{{ employee.id }}" {% if employee.id == shift.employee.id %}selected{% endif %}>{{ employee.name }}</option>
                            {% endfor %}
                        </select>
                    </td>
                    <td><input type="time" name="start_time" value="{{ shift.start_time|time:'H:i' }}"></td>
                    <td><input type="time" name="end_time" value="{{ shift.end_time|time:'H:i' }}"></td>
                    <td><button type="submit">Save</button></td>
                </form>
                <td>
                    <form method="post" action="/manager/roster/delete-shift/{{ shift.id }}/" onsubmit="return confirm('Delete this roster shift?');">
                        {% csrf_token %}
                        <input type="hidden" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
                        <button class="danger" type="submit">Delete</button>
                    </form>
                </td>
            </tr>
            {% empty %}
            <tr><td colspan="6" class="muted">No shifts for this week yet.</td></tr>
            {% endfor %}
        </table>
    </div>

</div>
</body>
</html>
HTML

echo "Checking Python syntax..."
python -m py_compile core/views.py

echo "Running Django checks..."
python manage.py check

echo
echo "Patch 15 complete."
echo "Restart:"
echo "  sudo systemctl restart restaurant_clocking"
