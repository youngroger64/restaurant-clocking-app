#!/bin/bash
set -e

echo "Backing up files..."
cp core/views.py core/views.py.working_not_rostered_bak
cp core/urls.py core/urls.py.working_not_rostered_bak
cp templates/home.html templates/home.html.working_not_rostered_bak 2>/dev/null || true

echo "Adding manager corrections and improved dashboard sections..."

cat >> core/views.py <<'PY'


# -------------------------------------------------------------------
# Manager corrections centre + improved homepage override
# -------------------------------------------------------------------

from django.contrib.auth.decorators import login_required
from core.compliance import get_day_rows, get_week_rows


@login_required
def manager_corrections(request):
    selected_date_str = request.GET.get(
        "date",
        timezone.localdate().strftime("%Y-%m-%d")
    )
    selected_date = datetime.strptime(selected_date_str, "%Y-%m-%d").date()
    message = ""

    if request.method == "POST":
        action = request.POST.get("action")

        if action == "add_event":
            emp_no = request.POST.get("employee_number")
            clock_type = request.POST.get("clock_type")
            event_date = request.POST.get("event_date")
            event_time = request.POST.get("event_time")

            try:
                employee = Employee.objects.get(employee_number=emp_no, active=True)
                naive_dt = datetime.strptime(f"{event_date} {event_time}", "%Y-%m-%d %H:%M")
                event_dt = timezone.make_aware(naive_dt)

                ClockEvent.objects.create(
                    employee=employee,
                    clock_type=clock_type,
                    timestamp=event_dt,
                    method="MANAGER"
                )

                message = f"Added {clock_type} for {employee.name} at {event_time}."

            except Exception as e:
                message = f"Could not add event: {e}"

        elif action == "delete_event":
            event_id = request.POST.get("event_id")

            try:
                event = ClockEvent.objects.get(id=event_id)
                details = f"{event.employee.name} {event.clock_type} {event.timestamp}"
                event.delete()
                message = f"Deleted event: {details}"

            except Exception as e:
                message = f"Could not delete event: {e}"

    employees = Employee.objects.filter(active=True).order_by("name")

    events = ClockEvent.objects.select_related("employee").filter(
        timestamp__date=selected_date
    ).order_by("-timestamp")

    return render(request, "manager_corrections.html", {
        "selected_date": selected_date,
        "employees": employees,
        "events": events,
        "message": message,
    })


def home_page(request):
    today = timezone.localdate()
    week_start = today - timedelta(days=today.weekday())

    rows = get_day_rows(today)
    week_rows = get_week_rows(week_start, 39)

    urgent_rows = [row for row in rows if row["is_urgent"]]
    operational_rows = [row for row in rows if row["is_operational"]]
    working_rows = [row for row in rows if row["is_working"] or row["is_on_break"]]
    unrostered_working_rows = [
        row for row in working_rows
        if not row["rostered"]
    ]

    payroll_problem_rows = [
        row for row in week_rows
        if row["warning"] != "OK"
    ]

    total_staff = len(rows)
    urgent_count = len(urgent_rows)

    if total_staff > 0:
        health_score = int(((total_staff - urgent_count) / total_staff) * 100)
    else:
        health_score = 100

    return render(request, "home.html", {
        "today": today,
        "week_start": week_start,
        "rows": rows,
        "urgent_rows": urgent_rows[:8],
        "operational_rows": operational_rows[:8],
        "working_rows": working_rows,
        "unrostered_working_rows": unrostered_working_rows,
        "rostered_count": sum(1 for row in rows if row["rostered"]),
        "currently_working": sum(1 for row in rows if row["is_working"]),
        "on_break": sum(1 for row in rows if row["is_on_break"]),
        "clocked_out": sum(1 for row in rows if row["is_clocked_out"]),
        "urgent_count": urgent_count,
        "operational_count": len(operational_rows),
        "health_score": health_score,
        "payroll_problem_count": len(payroll_problem_rows),
    })
PY

echo "Updating URLs safely..."
python - <<'PY'
from pathlib import Path

path = Path("core/urls.py")
text = path.read_text()

if "manager_corrections" not in text.split("urlpatterns")[0]:
    # Add to import block after manager_add_missing_event if present, otherwise before closing import.
    if "manager_add_missing_event," in text:
        text = text.replace("manager_add_missing_event,", "manager_add_missing_event,\n    manager_corrections,")
    else:
        text = text.replace(")", "    manager_corrections,\n)", 1)

if "manager/corrections" not in text:
    text = text.replace(
        "]",
        "    path('manager/corrections/', manager_corrections, name='manager_corrections'),\n]"
    )

path.write_text(text)
PY

echo "Writing manager corrections template..."
cat > templates/manager_corrections.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Manager Corrections</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #222; }
        .container { max-width: 1200px; margin: auto; }
        .section { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 22px; margin-bottom: 18px; }
        table { width: 100%; border-collapse: collapse; margin-top: 12px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 10px; text-align: left; }
        th { background: #f9fafb; }
        input, select, button, textarea { padding: 9px; margin: 4px 0; }
        .button { display: inline-block; padding: 10px 13px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 8px; }
        .secondary { background: #4b5563; }
        .danger { background: #b42318; color: white; border: none; border-radius: 6px; cursor: pointer; }
        .message { padding: 12px; background: #eef5ff; border-left: 4px solid #2563eb; margin-bottom: 15px; }
        .warn { color: #b42318; font-weight: bold; }
    </style>
</head>
<body>
<div class="container">

    <div class="section">
        <h1>Manager Corrections</h1>
        <p>
            Use this page to fix bad or missing clock records before payroll.
            For the PoC this records manager-added events as method <strong>MANAGER</strong>.
        </p>

        {% if message %}
            <div class="message">{{ message }}</div>
        {% endif %}

        <form method="get">
            Date:
            <input type="date" name="date" value="{{ selected_date|date:'Y-m-d' }}">
            <button type="submit">View Date</button>
        </form>
    </div>

    <div class="section">
        <h2>Add Missing Event</h2>
        <form method="post">
            {% csrf_token %}
            <input type="hidden" name="action" value="add_event">

            <p>
                Employee<br>
                <select name="employee_number" required>
                    {% for employee in employees %}
                        <option value="{{ employee.employee_number }}">
                            {{ employee.employee_number }} - {{ employee.name }}
                        </option>
                    {% endfor %}
                </select>
            </p>

            <p>
                Event Type<br>
                <select name="clock_type" required>
                    <option value="IN">Clock In</option>
                    <option value="BREAK_START">Start Break</option>
                    <option value="BREAK_END">End Break</option>
                    <option value="OUT">Clock Out</option>
                </select>
            </p>

            <p>
                Date<br>
                <input type="date" name="event_date" value="{{ selected_date|date:'Y-m-d' }}" required>
            </p>

            <p>
                Time<br>
                <input type="time" name="event_time" required>
            </p>

            <button type="submit">Add Event</button>
        </form>
    </div>

    <div class="section">
        <h2>Clock Events for {{ selected_date }}</h2>
        <p class="warn">Delete only obvious mistakes. Full audit log will be added in the next production version.</p>

        <table>
            <tr>
                <th>Employee</th>
                <th>Type</th>
                <th>Time</th>
                <th>Method</th>
                <th>Action</th>
            </tr>

            {% for event in events %}
            <tr>
                <td>{{ event.employee.name }}</td>
                <td>{{ event.clock_type }}</td>
                <td>{{ event.timestamp|date:"H:i" }}</td>
                <td>{{ event.method }}</td>
                <td>
                    <form method="post" onsubmit="return confirm('Delete this clock event?');">
                        {% csrf_token %}
                        <input type="hidden" name="action" value="delete_event">
                        <input type="hidden" name="event_id" value="{{ event.id }}">
                        <button class="danger" type="submit">Delete</button>
                    </form>
                </td>
            </tr>
            {% empty %}
            <tr>
                <td colspan="5">No clock events for this date.</td>
            </tr>
            {% endfor %}
        </table>
    </div>

    <p>
        <a class="button" href="/">Home</a>
        <a class="button" href="/manager/today/">Today's Dashboard</a>
        <a class="button" href="/manager/payroll-problems/">Payroll Problems</a>
        <a class="button secondary" href="/admin/">Admin</a>
    </p>

</div>
</body>
</html>
HTML

echo "Writing improved home dashboard template..."
cat > templates/home.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Restaurant Operations Dashboard</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #222; }
        .container { max-width: 1250px; margin: auto; }
        .header, .section { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 22px; margin-bottom: 18px; }
        h1 { margin: 0 0 8px 0; }
        .muted { color: #666; }
        .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 14px; margin: 18px 0; }
        .card { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 18px; }
        .number { font-size: 36px; font-weight: bold; margin-top: 8px; }
        .good { color: #1a7f37; font-weight: bold; }
        .warn { color: #b7791f; font-weight: bold; }
        .urgent { color: #b42318; font-weight: bold; }
        .actions { display: flex; flex-wrap: wrap; gap: 10px; }
        .button { display: inline-block; padding: 12px 14px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; }
        .secondary { background: #4b5563; }
        .danger { background: #b42318; }
        table { width: 100%; border-collapse: collapse; margin-top: 12px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 10px; text-align: left; }
        th { background: #f9fafb; }
    </style>
</head>
<body>

<div class="container">

    <div class="header">
        <h1>Restaurant Operations Dashboard</h1>
        <p class="muted">Today: {{ today }}. Start here to see staff status, urgent issues, roster coverage and payroll readiness.</p>
    </div>

    <div class="cards">
        <div class="card"><div>Health Score</div><div class="number {% if health_score >= 90 %}good{% elif health_score >= 70 %}warn{% else %}urgent{% endif %}">{{ health_score }}%</div></div>
        <div class="card"><div>Rostered Today</div><div class="number">{{ rostered_count }}</div></div>
        <div class="card"><div>Working Now</div><div class="number">{{ currently_working }}</div></div>
        <div class="card"><div>On Break</div><div class="number">{{ on_break }}</div></div>
        <div class="card"><div>Urgent Issues</div><div class="number urgent">{{ urgent_count }}</div></div>
        <div class="card"><div>Payroll Problems</div><div class="number {% if payroll_problem_count > 0 %}urgent{% else %}good{% endif %}">{{ payroll_problem_count }}</div></div>
    </div>

    <div class="section">
        <h2>Working But Not Rostered</h2>
        <p class="muted">Staff currently clocked in but not on today's roster.</p>

        {% if unrostered_working_rows %}
            <table>
                <tr><th>Employee</th><th>Status</th><th>Worked</th><th>Break</th><th>Issue</th></tr>
                {% for row in unrostered_working_rows %}
                <tr>
                    <td>{{ row.employee }}</td>
                    <td>{{ row.status }}</td>
                    <td>{{ row.worked_hours }}h</td>
                    <td>{{ row.break_minutes }} mins</td>
                    <td class="urgent">{{ row.issue }}</td>
                </tr>
                {% endfor %}
            </table>
        {% else %}
            <p class="good">No unrostered staff are currently working.</p>
        {% endif %}
    </div>

    <div class="section">
        <h2>Manager Action Required</h2>
        <p class="muted">These are the items to check first.</p>

        {% if urgent_rows %}
            <table>
                <tr><th>Employee</th><th>Status</th><th>Issue</th><th>Worked</th><th>Break</th></tr>
                {% for row in urgent_rows %}
                <tr>
                    <td>{{ row.employee }}</td>
                    <td>{{ row.status }}</td>
                    <td class="urgent">{{ row.issue }}</td>
                    <td>{{ row.worked_hours }}h</td>
                    <td>{{ row.break_minutes }} mins</td>
                </tr>
                {% endfor %}
            </table>
            <p><a class="button danger" href="/manager/today/">Open Today's Dashboard</a></p>
        {% else %}
            <p class="good">No urgent issues right now.</p>
        {% endif %}
    </div>

    <div class="section">
        <h2>Staff Working Now</h2>

        {% if working_rows %}
            <table>
                <tr><th>Employee</th><th>Roster</th><th>Status</th><th>Worked</th><th>Break</th><th>Issue</th></tr>
                {% for row in working_rows %}
                <tr>
                    <td>{{ row.employee }}</td>
                    <td>{{ row.roster }}</td>
                    <td>{{ row.status }}</td>
                    <td>{{ row.worked_hours }}h</td>
                    <td>{{ row.break_minutes }} mins</td>
                    <td class="{% if row.is_urgent %}urgent{% elif row.is_operational %}warn{% else %}good{% endif %}">{{ row.issue }}</td>
                </tr>
                {% endfor %}
            </table>
        {% else %}
            <p>No staff currently clocked in.</p>
        {% endif %}
    </div>

    <div class="section">
        <h2>Payroll Status</h2>

        {% if payroll_problem_count > 0 %}
            <p class="urgent">{{ payroll_problem_count }} payroll issue(s) need review before export.</p>
            <a class="button danger" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Review Payroll Problems</a>
        {% else %}
            <p class="good">Payroll looks clean for the current week.</p>
            <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Open Weekly Payroll</a>
        {% endif %}
    </div>

    <div class="section">
        <h2>Operational Notes</h2>
        <p class="muted">Useful notes such as late arrivals. These are not urgent compliance alerts.</p>

        {% if operational_rows %}
            <table>
                <tr><th>Employee</th><th>Status</th><th>Note</th></tr>
                {% for row in operational_rows %}
                <tr>
                    <td>{{ row.employee }}</td>
                    <td>{{ row.status }}</td>
                    <td class="warn">{{ row.issue }}</td>
                </tr>
                {% endfor %}
            </table>
        {% else %}
            <p class="good">No operational notes.</p>
        {% endif %}
    </div>

    <div class="section">
        <h2>Quick Actions</h2>
        <div class="actions">
            <a class="button" href="/manager/today/">Today's Staff</a>
            <a class="button" href="/clock/">Staff Clocking</a>
            <a class="button" href="/manager/upload-roster/">Upload Roster</a>
            <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Payroll</a>
            <a class="button" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Payroll Problems</a>
            <a class="button" href="/manager/corrections/">Manager Corrections</a>
            <a class="button secondary" href="/admin/">System Admin</a>
            <a class="button secondary" href="/manager/logout/">Logout</a>
        </div>
    </div>

</div>

</body>
</html>
HTML

echo "Running Django check..."
python manage.py check

echo "Restarting app..."
sudo systemctl restart restaurant_clocking

echo "Done."
echo "Open / and /manager/corrections/"
