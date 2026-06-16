#!/usr/bin/env bash
set -euo pipefail

echo "=== Restaurant Clocking Patch 05: Staff Session Clock Page ==="
echo "Adds staff session flow so PIN is entered once per browser session."

if [ ! -f "manage.py" ]; then
  echo "ERROR: Run this from Django project root: cd ~/restaurant_clocking"
  exit 1
fi

mkdir -p patch_backups_05
cp -f core/views.py patch_backups_05/views.py.bak
cp -f templates/clock.html patch_backups_05/clock.html.bak

python3 <<'PY'

from pathlib import Path
import re

views_path = Path("core/views.py")
template_path = Path("templates/clock.html")
views = views_path.read_text()

new_func = """def smart_clock_page(request):
    # Staff clocking page:
    # - identify once with employee number + PIN
    # - store employee id in browser session
    # - allow further actions without re-entering PIN
    # - allow clearing session with 'Not you? Start again'
    message = ""
    employee = None
    state = {
        "current_state": "CLOCKED_OUT",
        "status_label": "⚫ Clocked Out",
        "valid_actions": ["IN"],
        "clocked_in_time": None,
        "break_started_time": None,
        "worked_hours": 0,
        "break_minutes": 0,
    }

    action_messages = {
        "IN": "✅ {name} clocked in successfully at {time}.",
        "BREAK_START": "☕ {name} started break at {time}.",
        "BREAK_END": "✅ {name} returned from break at {time}.",
        "OUT": "👋 {name} clocked out successfully at {time}.",
    }

    if request.method == "POST" and request.POST.get("reset_clock_session") == "yes":
        request.session.pop("clock_employee_id", None)
        message = "Session cleared. Please enter your employee number and PIN."
        return render(request, "clock.html", {
            "message": message,
            "employee": None,
            "state": state,
        })

    session_employee_id = request.session.get("clock_employee_id")
    if session_employee_id:
        try:
            employee = Employee.objects.get(id=session_employee_id, active=True)
            state = _clock_state_for_employee(employee)
        except Employee.DoesNotExist:
            request.session.pop("clock_employee_id", None)
            employee = None

    if request.method == "POST":
        action = request.POST.get("action")
        confirm_break_clockout = request.POST.get("confirm_break_clockout")

        if employee is None:
            emp_no = (request.POST.get("employee_number") or "").strip()
            pin = (request.POST.get("pin") or "").strip()

            if not emp_no or not pin:
                message = "Please enter your employee number and PIN."
            else:
                try:
                    employee = Employee.objects.get(employee_number=emp_no, pin=pin, active=True)
                    request.session["clock_employee_id"] = employee.id
                    request.session.modified = True
                    state = _clock_state_for_employee(employee)
                    if not action:
                        message = f"Welcome {employee.name}. Choose an option below."
                except Employee.DoesNotExist:
                    message = "Invalid employee number or PIN."
                    employee = None

        if employee is not None and action:
            state = _clock_state_for_employee(employee)

            if action not in state["valid_actions"]:
                message = "That action is not available for your current status."

            elif state["current_state"] == "ON_BREAK" and action == "OUT" and confirm_break_clockout != "yes":
                message = "You are currently on break. Tick the confirmation box to clock out."

            else:
                now = timezone.localtime()

                if state["current_state"] == "ON_BREAK" and action == "OUT":
                    ClockEvent.objects.create(
                        employee=employee,
                        clock_type="BREAK_END",
                        method="QR_AUTO",
                        notes="Auto-ended break because employee clocked out while on break.",
                    )

                ClockEvent.objects.create(
                    employee=employee,
                    clock_type=action,
                    method="QR",
                    notes="",
                )

                message = action_messages[action].format(
                    name=employee.name,
                    time=now.strftime("%H:%M")
                )

                state = _clock_state_for_employee(employee)

    return render(request, "clock.html", {
        "message": message,
        "employee": employee,
        "state": state,
    })
"""

matches = list(re.finditer(r"def smart_clock_page\(request\):", views))
if not matches:
    raise SystemExit("Could not find smart_clock_page in core/views.py")
start = matches[-1].start()
next_match = re.search(r"\n(?=class ManagerLoginView|def manager_logout|# Re-wrap manager views)", views[start:])
if not next_match:
    raise SystemExit("Could not find end of smart_clock_page in core/views.py")
end = start + next_match.start()
views = views[:start] + new_func + "\n\n" + views[end:]
views_path.write_text(views)

clock_html = """<!DOCTYPE html>
<html>
<head>
    <title>Staff Clocking</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #222; }
        .box { max-width: 520px; margin: 30px auto; background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 24px; }
        input { width: 100%; padding: 12px; font-size: 18px; margin-top: 5px; box-sizing: border-box; }
        button { width: 100%; padding: 14px; margin: 8px 0; font-size: 18px; border: none; border-radius: 8px; cursor: pointer; font-weight: bold; }
        .in { background: #2563eb; color: white; }
        .break { background: #f59e0b; color: black; }
        .out { background: #4b5563; color: white; }
        .secondary { background: #e5e7eb; color: #111827; }
        .message { margin-top: 18px; padding: 12px; background: #eef5ff; border-left: 4px solid #2563eb; }
        .state { padding: 16px; background: #f9fafb; border-radius: 8px; margin: 12px 0; font-size: 18px; line-height: 1.5; }
        .confirm { background: #fff7ed; padding: 12px; border-left: 4px solid #f59e0b; margin: 12px 0; }
        .small { color: #666; font-size: 14px; }
        .name { font-size: 26px; font-weight: bold; margin-bottom: 6px; }
        .status { font-size: 22px; margin-bottom: 8px; }
        .top-actions { margin-top: 12px; }
        a { color: #2563eb; }
    </style>
</head>
<body>
<div class="box">
<h1>Staff Clocking</h1>

{% if employee %}
    <div class="state">
        <div class="name">{{ employee.name }}</div>
        <div class="status">{{ state.status_label }}</div>

        {% if state.clocked_in_time %}
            Clocked in: <strong>{{ state.clocked_in_time|date:"H:i" }}</strong><br>
        {% endif %}
        {% if state.break_started_time %}
            Break started: <strong>{{ state.break_started_time|date:"H:i" }}</strong><br>
        {% endif %}

        Worked today: <strong>{{ state.worked_hours }}h</strong><br>
        Break today: <strong>{{ state.break_minutes }} mins</strong>
    </div>

    <form method="post">
        {% csrf_token %}

        {% if "IN" in state.valid_actions %}
            <button class="in" type="submit" name="action" value="IN">Clock In</button>
        {% endif %}

        {% if "BREAK_START" in state.valid_actions %}
            <button class="break" type="submit" name="action" value="BREAK_START">Start Break</button>
        {% endif %}

        {% if "BREAK_END" in state.valid_actions %}
            <button class="break" type="submit" name="action" value="BREAK_END">End Break</button>
        {% endif %}

        {% if "OUT" in state.valid_actions %}
            {% if state.current_state == "ON_BREAK" %}
                <div class="confirm">
                    You are currently on break.<br>
                    If you clock out now, the system will end your break and clock you out.
                    <br><br>
                    <label><input type="checkbox" name="confirm_break_clockout" value="yes" style="width:auto;"> I understand</label>
                </div>
            {% endif %}
            <button class="out" type="submit" name="action" value="OUT">Clock Out</button>
        {% endif %}
    </form>

    <form method="post" class="top-actions">
        {% csrf_token %}
        <input type="hidden" name="reset_clock_session" value="yes">
        <button class="secondary" type="submit">Not {{ employee.name }}? Start again</button>
    </form>

{% else %}
    <p class="small">Enter your employee number and PIN once. This screen will then remember you on this device/browser session.</p>

    <form method="post">
        {% csrf_token %}
        <p><strong>Employee Number</strong><br><input type="text" name="employee_number" required autofocus></p>
        <p><strong>PIN</strong><br><input type="password" name="pin" required></p>
        <button class="in" type="submit">Continue</button>
    </form>
{% endif %}

{% if message %}<div class="message"><strong>{{ message }}</strong></div>{% endif %}

<p><a href="/">Home</a></p>
</div>
</body>
</html>
"""
template_path.write_text(clock_html)
PY

echo "Running Django checks..."
python manage.py check

echo
echo "Patch 05 complete."
echo "Restart Django/gunicorn:"
echo "  sudo systemctl restart restaurant_clocking"
echo "Test: enter employee number/PIN once, then use clock actions without re-entering details."
