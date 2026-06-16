#!/bin/bash
set -e

echo "Backing up files..."
cp core/views.py core/views.py.smart_clock_bak
cp core/urls.py core/urls.py.smart_clock_bak
cp templates/clock.html templates/clock.html.smart_clock_bak 2>/dev/null || true

cat >> core/views.py <<'PY'


# -------------------------------------------------------------------
# Smart clocking + payroll problems + simple manager corrections
# -------------------------------------------------------------------

def _latest_today_event(employee):
    return ClockEvent.objects.filter(
        employee=employee,
        timestamp__date=timezone.localdate()
    ).order_by("-timestamp").first()


def smart_clock_page(request):
    message = ""
    employee = None
    current_state = "OFF_DUTY"
    valid_actions = ["IN"]

    state_actions = {
        "OFF_DUTY": ["IN"],
        "WORKING": ["BREAK_START", "OUT"],
        "ON_BREAK": ["BREAK_END", "OUT"],
    }

    labels = {
        "IN": "Clock In",
        "BREAK_START": "Start Break",
        "BREAK_END": "End Break",
        "OUT": "Clock Out",
    }

    if request.method == "POST":
        emp_no = request.POST.get("employee_number")
        pin = request.POST.get("pin")
        action = request.POST.get("action")
        confirm_break_clockout = request.POST.get("confirm_break_clockout")

        try:
            employee = Employee.objects.get(employee_number=emp_no, pin=pin, active=True)
            latest = _latest_today_event(employee)

            if latest is None or latest.clock_type == "OUT":
                current_state = "OFF_DUTY"
            elif latest.clock_type in ["IN", "BREAK_END"]:
                current_state = "WORKING"
            elif latest.clock_type == "BREAK_START":
                current_state = "ON_BREAK"

            valid_actions = state_actions[current_state]

            if action:
                if action not in valid_actions:
                    message = f"Invalid action. Current status is {current_state.replace('_', ' ').title()}."
                elif current_state == "ON_BREAK" and action == "OUT" and confirm_break_clockout != "yes":
                    message = "You are currently on break. Tick the confirmation box to clock out."
                else:
                    if current_state == "ON_BREAK" and action == "OUT":
                        ClockEvent.objects.create(employee=employee, clock_type="BREAK_END", method="QR_AUTO")

                    ClockEvent.objects.create(employee=employee, clock_type=action, method="QR")
                    message = f"{employee.name}: {labels[action]} recorded successfully."

                    latest = _latest_today_event(employee)
                    if latest is None or latest.clock_type == "OUT":
                        current_state = "OFF_DUTY"
                    elif latest.clock_type in ["IN", "BREAK_END"]:
                        current_state = "WORKING"
                    elif latest.clock_type == "BREAK_START":
                        current_state = "ON_BREAK"
                    valid_actions = state_actions[current_state]

        except Employee.DoesNotExist:
            message = "Invalid employee number or PIN."

    return render(request, "clock.html", {
        "message": message,
        "employee": employee,
        "current_state": current_state,
        "valid_actions": valid_actions,
    })


def payroll_problems(request):
    from core.compliance import calculate_employee_day

    week_start_str = request.GET.get("week_start", "2026-06-15")
    week_start = datetime.strptime(week_start_str, "%Y-%m-%d").date()
    week_end = week_start + timedelta(days=6)

    rows = []

    for employee in Employee.objects.filter(active=True).order_by("name"):
        for i in range(7):
            day = week_start + timedelta(days=i)
            d = calculate_employee_day(employee, day, include_live=True)
            problems = []

            if d["missing_clock_out"]:
                problems.append("Missing clock-out")
            if d["invalid_sequence"]:
                problems.append("Check clock sequence")
            if d["is_urgent"]:
                problems.append(d["issue"])
            if d["worked_hours"] > 12:
                problems.append("Unusually long shift")

            if problems:
                rows.append({
                    "date": day,
                    "employee": employee.name,
                    "roster": d["roster"],
                    "status": d["status"],
                    "worked_hours": d["worked_hours"],
                    "break_minutes": d["break_minutes"],
                    "problem": "; ".join(sorted(set(problems))),
                })

    return render(request, "payroll_problems.html", {
        "week_start": week_start,
        "week_end": week_end,
        "rows": rows,
        "problem_count": len(rows),
    })


def manager_add_missing_event(request):
    message = ""

    if request.method == "POST":
        emp_no = request.POST.get("employee_number")
        event_date = request.POST.get("event_date")
        event_time = request.POST.get("event_time")
        clock_type = request.POST.get("clock_type")
        reason = request.POST.get("reason", "")

        try:
            employee = Employee.objects.get(employee_number=emp_no)
            naive_dt = datetime.strptime(f"{event_date} {event_time}", "%Y-%m-%d %H:%M")
            event_dt = timezone.make_aware(naive_dt)

            ClockEvent.objects.create(
                employee=employee,
                clock_type=clock_type,
                timestamp=event_dt,
                method="MANAGER",
                notes=f"Manager correction: {reason}"
            )

            message = f"Added {clock_type} for {employee.name} at {event_dt}."

        except Employee.DoesNotExist:
            message = "Employee not found."
        except Exception as e:
            message = f"Error: {e}"

    employees = Employee.objects.filter(active=True).order_by("name")
    return render(request, "manager_add_missing_event.html", {
        "employees": employees,
        "message": message,
    })
PY

python - <<'PY'
from pathlib import Path
path = Path("core/urls.py")
text = path.read_text()

if "smart_clock_page" not in text.split("urlpatterns")[0]:
    text = text.replace(
        "clock_page,",
        "clock_page,\n    smart_clock_page,\n    payroll_problems,\n    manager_add_missing_event,"
    )

text = text.replace(
    "path('clock/', clock_page, name='clock'),",
    "path('clock/', smart_clock_page, name='clock'),"
)

if "payroll-problems" not in text:
    insert_after = "path('manager/export-sage-payroll/', export_sage_payroll_csv, name='export_sage_payroll_csv'),"
    if insert_after in text:
        text = text.replace(
            insert_after,
            insert_after + "\n    path('manager/payroll-problems/', payroll_problems, name='payroll_problems'),\n    path('manager/add-missing-event/', manager_add_missing_event, name='manager_add_missing_event'),"
        )
    else:
        text = text.replace(
            "]\n",
            "    path('manager/payroll-problems/', payroll_problems, name='payroll_problems'),\n    path('manager/add-missing-event/', manager_add_missing_event, name='manager_add_missing_event'),\n]\n"
        )

path.write_text(text)
PY

cat > templates/clock.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Staff Clocking</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #222; }
        .box { max-width: 480px; margin: 30px auto; background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 24px; }
        input { width: 100%; padding: 12px; font-size: 18px; margin-top: 5px; box-sizing: border-box; }
        button { width: 100%; padding: 14px; margin: 8px 0; font-size: 18px; border: none; border-radius: 8px; cursor: pointer; font-weight: bold; }
        .in { background: #2563eb; color: white; }
        .break { background: #f59e0b; color: black; }
        .out { background: #4b5563; color: white; }
        .message { margin-top: 18px; padding: 12px; background: #eef5ff; border-left: 4px solid #2563eb; }
        .state { padding: 10px; background: #f9fafb; border-radius: 8px; margin: 12px 0; }
        .confirm { background: #fff7ed; padding: 12px; border-left: 4px solid #f59e0b; margin: 12px 0; }
    </style>
</head>
<body>
<div class="box">
<h1>Staff Clocking</h1>
<p>Enter your employee number and PIN. Only valid actions are shown.</p>

<form method="post">
    {% csrf_token %}
    <p><strong>Employee Number</strong><br><input type="text" name="employee_number" required></p>
    <p><strong>PIN</strong><br><input type="password" name="pin" required></p>

    {% if employee %}
        <div class="state"><strong>{{ employee.name }}</strong><br>Current status: {{ current_state }}</div>
    {% endif %}

    {% if "IN" in valid_actions or not employee %}
        <button class="in" type="submit" name="action" value="IN">Clock In</button>
    {% endif %}

    {% if "BREAK_START" in valid_actions %}
        <button class="break" type="submit" name="action" value="BREAK_START">Start Break</button>
    {% endif %}

    {% if "BREAK_END" in valid_actions %}
        <button class="break" type="submit" name="action" value="BREAK_END">End Break</button>
    {% endif %}

    {% if "OUT" in valid_actions %}
        {% if current_state == "ON_BREAK" %}
            <div class="confirm">
                You are currently on break. If you clock out now, the system will end your break and clock you out.
                <br>
                <label><input type="checkbox" name="confirm_break_clockout" value="yes" style="width:auto;"> I understand</label>
            </div>
        {% endif %}
        <button class="out" type="submit" name="action" value="OUT">Clock Out</button>
    {% endif %}
</form>

{% if message %}<div class="message"><strong>{{ message }}</strong></div>{% endif %}
<p><a href="/">Home</a></p>
</div>
</body>
</html>
HTML

cat > templates/payroll_problems.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Payroll Problems</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #222; }
        .container { max-width: 1250px; margin: auto; background: white; padding: 24px; border-radius: 14px; border: 1px solid #e5e7eb; }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 10px; text-align: left; }
        th { background: #f9fafb; }
        .warn { color: #b42318; font-weight: bold; }
        .ok { color: #1a7f37; font-weight: bold; }
        .button { display: inline-block; padding: 10px 13px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 8px; }
        .secondary { background: #4b5563; }
        input, button { padding: 8px; }
    </style>
</head>
<body>
<div class="container">
<h1>Payroll Problems</h1>
<p>Review missing clock-outs, unended breaks, unusual shifts and urgent issues before payroll export.</p>

<form method="get">
    Week Start: <input type="date" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
    <button type="submit">View Week</button>
</form>

<h2>{{ week_start }} to {{ week_end }}</h2>

{% if problem_count == 0 %}
    <p class="ok">No payroll problems found for this week.</p>
{% else %}
    <p class="warn">{{ problem_count }} problem(s) found. Review before exporting payroll.</p>
{% endif %}

<table>
    <tr><th>Date</th><th>Employee</th><th>Roster</th><th>Status</th><th>Worked</th><th>Break</th><th>Problem</th></tr>
    {% for row in rows %}
    <tr><td>{{ row.date }}</td><td>{{ row.employee }}</td><td>{{ row.roster }}</td><td>{{ row.status }}</td><td>{{ row.worked_hours }}</td><td>{{ row.break_minutes }} mins</td><td class="warn">{{ row.problem }}</td></tr>
    {% empty %}
    <tr><td colspan="7" class="ok">No problems found.</td></tr>
    {% endfor %}
</table>

<p>
    <a class="button" href="/manager/add-missing-event/">Add Missing Event</a>
    <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Summary</a>
    <a class="button secondary" href="/manager/today/">Today's Dashboard</a>
    <a class="button secondary" href="/">Home</a>
</p>
</div>
</body>
</html>
HTML

cat > templates/manager_add_missing_event.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Add Missing Clock Event</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #222; }
        .container { max-width: 650px; margin: auto; background: white; padding: 24px; border-radius: 14px; border: 1px solid #e5e7eb; }
        label { font-weight: bold; display: block; margin-top: 12px; }
        input, select, textarea { width: 100%; padding: 10px; box-sizing: border-box; margin-top: 5px; }
        button { margin-top: 18px; padding: 12px; background: #2563eb; color: white; border: none; border-radius: 8px; font-weight: bold; }
        .message { margin-top: 15px; padding: 12px; background: #eef5ff; border-left: 4px solid #2563eb; }
    </style>
</head>
<body>
<div class="container">
<h1>Add Missing Clock Event</h1>
<p>Use this only to fix payroll problems such as a forgotten clock-out or unended break.</p>

<form method="post">
    {% csrf_token %}
    <label>Employee</label>
    <select name="employee_number" required>
        {% for employee in employees %}
            <option value="{{ employee.employee_number }}">{{ employee.employee_number }} - {{ employee.name }}</option>
        {% endfor %}
    </select>

    <label>Event Type</label>
    <select name="clock_type" required>
        <option value="OUT">Clock Out</option>
        <option value="BREAK_END">End Break</option>
        <option value="BREAK_START">Start Break</option>
        <option value="IN">Clock In</option>
    </select>

    <label>Date</label><input type="date" name="event_date" required>
    <label>Time</label><input type="time" name="event_time" required>
    <label>Reason</label><textarea name="reason" rows="4" placeholder="Example: Employee forgot to clock out. Manager confirmed finish time."></textarea>

    <button type="submit">Add Correction</button>
</form>

{% if message %}<div class="message">{{ message }}</div>{% endif %}
<p><a href="/manager/payroll-problems/">Back to Payroll Problems</a></p>
</div>
</body>
</html>
HTML

python manage.py check
sudo systemctl restart restaurant_clocking

echo "Upgrade complete."
echo "Open /clock/ and /manager/payroll-problems/?week_start=2026-06-15"
