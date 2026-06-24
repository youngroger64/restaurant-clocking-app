#!/bin/bash
set -e

echo "Backing up files..."
cp core/views.py core/views.py.missing_clockin_checkout_bak
cp core/compliance.py core/compliance.py.missing_clockin_checkout_bak 2>/dev/null || true
cp templates/clock.html templates/clock.html.missing_clockin_checkout_bak 2>/dev/null || true

echo "Patching compliance logic for missing clock-in..."

python - <<'PY'
from pathlib import Path

path = Path("core/compliance.py")
text = path.read_text()

needle = '''    if invalid_sequence:
        urgent_issues.append("Check clock sequence")
'''

insert = '''    first_event = events.first()

    if roster["rostered"] and first_event and first_event.clock_type == "OUT":
        urgent_issues.append("Missing clock-in; employee clocked out only")

    if invalid_sequence:
        urgent_issues.append("Check clock sequence")
'''

if needle in text and "Missing clock-in; employee clocked out only" not in text:
    text = text.replace(needle, insert)
    path.write_text(text)
    print("Compliance logic updated.")
else:
    print("Compliance logic already updated or expected block not found.")
PY

echo "Adding employee-friendly clock-out-with-missing-clock-in flow..."

cat >> core/views.py <<'PY'


# -------------------------------------------------------------------
# Override smart clock page: allow clock-out if rostered but no IN exists
# -------------------------------------------------------------------

def _rostered_today_for_employee(employee):
    return RosterShift.objects.filter(
        employee=employee,
        shift_date=timezone.localdate()
    ).order_by("start_time").first()


def smart_clock_page(request):
    message = ""
    warning = ""
    employee = None

    state = {
        "current_state": "CLOCKED_OUT",
        "status_label": "⚫ Clocked Out",
        "valid_actions": ["IN"],
        "clocked_in_time": None,
        "break_started_time": None,
        "worked_hours": 0,
        "break_minutes": 0,
        "roster_text": "",
        "allow_missing_clockin_out": False,
    }

    def get_state(emp):
        base = _clock_state_for_employee(emp)
        shift = _rostered_today_for_employee(emp)

        if shift:
            base["roster_text"] = f"{shift.start_time.strftime('%H:%M')} - {shift.end_time.strftime('%H:%M')}"
        else:
            base["roster_text"] = "Not rostered today"

        latest = ClockEvent.objects.filter(
            employee=emp,
            timestamp__date=timezone.localdate()
        ).order_by("-timestamp").first()

        # If rostered today but no clock-in exists, let the employee clock out.
        # This captures the real finish time and creates a payroll review issue.
        if shift and latest is None:
            base["valid_actions"] = ["IN", "OUT_MISSING_IN"]
            base["allow_missing_clockin_out"] = True

        return base

    action_messages = {
        "IN": "✅ {name} clocked in successfully at {time}.",
        "BREAK_START": "☕ {name} started break at {time}.",
        "BREAK_END": "✅ {name} returned from break at {time}.",
        "OUT": "👋 {name} clocked out successfully at {time}.",
        "OUT_MISSING_IN": "👋 {name} clocked out at {time}. A payroll review has been created for your manager.",
    }

    if request.method == "POST":
        emp_no = request.POST.get("employee_number")
        pin = request.POST.get("pin")
        action = request.POST.get("action")
        confirm_break_clockout = request.POST.get("confirm_break_clockout")

        try:
            employee = Employee.objects.get(employee_number=emp_no, pin=pin, active=True)
            state = get_state(employee)

            if action:
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
                            method="QR_AUTO"
                        )

                    actual_clock_type = "OUT" if action == "OUT_MISSING_IN" else action

                    ClockEvent.objects.create(
                        employee=employee,
                        clock_type=actual_clock_type,
                        method="QR"
                    )

                    message = action_messages[action].format(
                        name=employee.name,
                        time=now.strftime("%H:%M")
                    )

                    if action == "OUT_MISSING_IN":
                        warning = "Your manager will review and add the missing clock-in time before payroll."

                    state = get_state(employee)

        except Employee.DoesNotExist:
            message = "Invalid employee number or PIN."

    return render(request, "clock.html", {
        "message": message,
        "warning": warning,
        "employee": employee,
        "state": state,
    })
PY

echo "Replacing clock.html..."
cat > templates/clock.html <<'HTML'
<!DOCTYPE html>
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
        .message { margin-top: 18px; padding: 12px; background: #eef5ff; border-left: 4px solid #2563eb; }
        .warning { margin-top: 18px; padding: 12px; background: #fff7ed; border-left: 4px solid #f59e0b; }
        .state { padding: 14px; background: #f9fafb; border-radius: 8px; margin: 12px 0; font-size: 18px; }
        .confirm { background: #fff7ed; padding: 12px; border-left: 4px solid #f59e0b; margin: 12px 0; }
        .small { color: #666; font-size: 14px; }
    </style>
</head>
<body>
<div class="box">
<h1>Staff Clocking</h1>
<p class="small">Enter your employee number and PIN. Only valid options are shown.</p>

<form method="post">
    {% csrf_token %}
    <p><strong>Employee Number</strong><br><input type="text" name="employee_number" required></p>
    <p><strong>PIN</strong><br><input type="password" name="pin" required></p>

    {% if employee %}
        <div class="state">
            <strong>{{ employee.name }}</strong><br>
            Status: <strong>{{ state.status_label }}</strong><br>
            Roster: {{ state.roster_text }}<br>
            {% if state.clocked_in_time %}
                Clocked in: {{ state.clocked_in_time|date:"H:i" }}<br>
            {% endif %}
            {% if state.break_started_time %}
                Break started: {{ state.break_started_time|date:"H:i" }}<br>
            {% endif %}
            Worked today: {{ state.worked_hours }}h<br>
            Break today: {{ state.break_minutes }} mins
        </div>
    {% endif %}

    {% if "IN" in state.valid_actions or not employee %}
        <button class="in" type="submit" name="action" value="IN">Clock In</button>
    {% endif %}

    {% if "BREAK_START" in state.valid_actions %}
        <button class="break" type="submit" name="action" value="BREAK_START">Start Break</button>
    {% endif %}

    {% if "BREAK_END" in state.valid_actions %}
        <button class="break" type="submit" name="action" value="BREAK_END">End Break</button>
    {% endif %}

    {% if "OUT_MISSING_IN" in state.valid_actions %}
        <div class="warning">
            No clock-in is recorded for today. If you worked your shift and are leaving now, clock out below.
            Your manager will review and add the missing start time before payroll.
        </div>
        <button class="out" type="submit" name="action" value="OUT_MISSING_IN">Clock Out</button>
    {% endif %}

    {% if "OUT" in state.valid_actions %}
        {% if state.current_state == "ON_BREAK" %}
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
{% if warning %}<div class="warning"><strong>{{ warning }}</strong></div>{% endif %}

<p><a href="/">Home</a></p>
</div>
</body>
</html>
HTML

echo "Running Django check..."
python manage.py check

echo "Restarting app..."
sudo systemctl restart restaurant_clocking

echo "Done. Test with a rostered employee who has no IN event today."
