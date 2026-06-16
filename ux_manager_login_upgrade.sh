#!/bin/bash
set -e

echo "Backing up files..."
cp core/views.py core/views.py.ux_login_bak
cp core/urls.py core/urls.py.ux_login_bak
cp templates/clock.html templates/clock.html.ux_login_bak 2>/dev/null || true
cp templates/manager_today.html templates/manager_today.html.ux_login_bak 2>/dev/null || true
cp templates/home.html templates/home.html.ux_login_bak 2>/dev/null || true

echo "Adding polished staff clocking page and manager login protection..."

cat >> core/views.py <<'PY'


# -------------------------------------------------------------------
# UX polish + protected manager views
# -------------------------------------------------------------------

from django.contrib.auth.decorators import login_required
from django.contrib.auth.views import LoginView, LogoutView
from django.utils.decorators import method_decorator
from django.urls import reverse_lazy


def _clock_state_for_employee(employee):
    today = timezone.localdate()
    latest = ClockEvent.objects.filter(
        employee=employee,
        timestamp__date=today
    ).order_by("-timestamp").first()

    events = ClockEvent.objects.filter(
        employee=employee,
        timestamp__date=today
    ).order_by("timestamp")

    current_state = "CLOCKED_OUT"
    status_label = "⚫ Clocked Out"
    valid_actions = ["IN"]
    clocked_in_time = None
    break_started_time = None
    worked_minutes = 0
    break_minutes = 0
    work_start = None
    break_start = None

    if latest:
        if latest.clock_type in ["IN", "BREAK_END"]:
            current_state = "WORKING"
            status_label = "🟢 Working"
            valid_actions = ["BREAK_START", "OUT"]
        elif latest.clock_type == "BREAK_START":
            current_state = "ON_BREAK"
            status_label = "🟠 On Break"
            valid_actions = ["BREAK_END", "OUT"]
        elif latest.clock_type == "OUT":
            current_state = "CLOCKED_OUT"
            status_label = "⚫ Clocked Out"
            valid_actions = ["IN"]

    for event in events:
        if event.clock_type == "IN":
            if clocked_in_time is None:
                clocked_in_time = event.timestamp
            work_start = event.timestamp

        elif event.clock_type == "BREAK_START":
            if work_start:
                worked_minutes += int((event.timestamp - work_start).total_seconds() / 60)
                work_start = None
            break_start = event.timestamp
            break_started_time = event.timestamp

        elif event.clock_type == "BREAK_END":
            if break_start:
                break_minutes += int((event.timestamp - break_start).total_seconds() / 60)
                break_start = None
            work_start = event.timestamp
            break_started_time = None

        elif event.clock_type == "OUT":
            if work_start:
                worked_minutes += int((event.timestamp - work_start).total_seconds() / 60)
                work_start = None
            elif break_start:
                break_minutes += int((event.timestamp - break_start).total_seconds() / 60)
                break_start = None
            break_started_time = None

    now = timezone.now()
    if current_state == "WORKING" and work_start:
        worked_minutes += int((now - work_start).total_seconds() / 60)
    elif current_state == "ON_BREAK" and break_start:
        break_minutes += int((now - break_start).total_seconds() / 60)

    return {
        "current_state": current_state,
        "status_label": status_label,
        "valid_actions": valid_actions,
        "clocked_in_time": clocked_in_time,
        "break_started_time": break_started_time,
        "worked_hours": round(worked_minutes / 60, 2),
        "break_minutes": break_minutes,
    }


def smart_clock_page(request):
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

    if request.method == "POST":
        emp_no = request.POST.get("employee_number")
        pin = request.POST.get("pin")
        action = request.POST.get("action")
        confirm_break_clockout = request.POST.get("confirm_break_clockout")

        try:
            employee = Employee.objects.get(employee_number=emp_no, pin=pin, active=True)
            state = _clock_state_for_employee(employee)

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

                    ClockEvent.objects.create(
                        employee=employee,
                        clock_type=action,
                        method="QR"
                    )

                    message = action_messages[action].format(
                        name=employee.name,
                        time=now.strftime("%H:%M")
                    )

                    state = _clock_state_for_employee(employee)

        except Employee.DoesNotExist:
            message = "Invalid employee number or PIN."

    return render(request, "clock.html", {
        "message": message,
        "employee": employee,
        "state": state,
    })


class ManagerLoginView(LoginView):
    template_name = "manager_login.html"
    redirect_authenticated_user = True

    def get_success_url(self):
        return reverse_lazy("manager_today_dashboard")


def manager_logout(request):
    from django.contrib.auth import logout
    logout(request)
    return render(request, "manager_logged_out.html")


# Re-wrap manager views so manager pages require login.
manager_today_dashboard = login_required(manager_today_dashboard)
upload_roster = login_required(upload_roster)
manager_weekly_summary = login_required(manager_weekly_summary)
manager_daily_monitor = login_required(manager_daily_monitor)
payroll_problems = login_required(payroll_problems)
manager_add_missing_event = login_required(manager_add_missing_event)
export_sage_payroll_csv = login_required(export_sage_payroll_csv)
PY

echo "Updating routes..."
python - <<'PY'
from pathlib import Path
path = Path("core/urls.py")
text = path.read_text()

if "ManagerLoginView" not in text.split("urlpatterns")[0]:
    text = text.replace(
        "manager_add_missing_event,",
        "manager_add_missing_event,\n    ManagerLoginView,\n    manager_logout,"
    )

text = text.replace(
    "path('clock/', clock_page, name='clock'),",
    "path('clock/', smart_clock_page, name='clock'),"
)

text = text.replace(
    "path('clock/', smart_clock_page, name='clock'),",
    "path('clock/', smart_clock_page, name='clock'),"
)

if "manager/login" not in text:
    text = text.replace(
        "urlpatterns = [",
        "urlpatterns = [\n    path('manager/login/', ManagerLoginView.as_view(), name='manager_login'),\n    path('manager/logout/', manager_logout, name='manager_logout'),"
    )

path.write_text(text)
PY

echo "Replacing clock.html..."
cat > templates/clock.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Staff Clocking</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #222; }
        .box { max-width: 500px; margin: 30px auto; background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 24px; }
        input { width: 100%; padding: 12px; font-size: 18px; margin-top: 5px; box-sizing: border-box; }
        button { width: 100%; padding: 14px; margin: 8px 0; font-size: 18px; border: none; border-radius: 8px; cursor: pointer; font-weight: bold; }
        .in { background: #2563eb; color: white; }
        .break { background: #f59e0b; color: black; }
        .out { background: #4b5563; color: white; }
        .message { margin-top: 18px; padding: 12px; background: #eef5ff; border-left: 4px solid #2563eb; }
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
<p><a href="/">Home</a></p>
</div>
</body>
</html>
HTML

echo "Creating manager login templates..."
cat > templates/manager_login.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Manager Login</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; }
        .box { max-width: 420px; margin: 60px auto; background: white; padding: 24px; border-radius: 14px; border: 1px solid #e5e7eb; }
        input { width: 100%; padding: 12px; box-sizing: border-box; margin: 6px 0 12px 0; }
        button { width: 100%; padding: 12px; background: #2563eb; color: white; border: none; border-radius: 8px; font-weight: bold; }
        .error { color: #b42318; font-weight: bold; }
    </style>
</head>
<body>
<div class="box">
<h1>Manager Login</h1>
<p>Manager access is required for dashboards, roster uploads, payroll and corrections.</p>

{% if form.errors %}
<p class="error">Invalid username or password.</p>
{% endif %}

<form method="post">
    {% csrf_token %}
    <label>Username</label>
    {{ form.username }}
    <label>Password</label>
    {{ form.password }}
    <button type="submit">Login</button>
</form>

<p><a href="/clock/">Staff Clocking</a></p>
</div>
</body>
</html>
HTML

cat > templates/manager_logged_out.html <<'HTML'
<!DOCTYPE html>
<html>
<head><title>Logged Out</title></head>
<body style="font-family: Arial, sans-serif;">
<h1>You are logged out</h1>
<p><a href="/manager/login/">Login again</a></p>
<p><a href="/clock/">Staff Clocking</a></p>
</body>
</html>
HTML

echo "Improving today's dashboard health card..."
python - <<'PY'
from pathlib import Path
path = Path("templates/manager_today.html")
if path.exists():
    text = path.read_text()
    if "Today's Health" not in text:
        text = text.replace(
            '<div class="cards">',
            '<div class="section"><h2>Today\\'s Health</h2><p class="muted">Use the cards below to quickly see how the day is going.</p></div>\\n\\n    <div class="cards">'
        )
    if "manager/logout" not in text:
        text = text.replace(
            '<a class="button secondary" href="/">Home</a>',
            '<a class="button secondary" href="/">Home</a><a class="button secondary" href="/manager/logout/">Logout</a>'
        )
    path.write_text(text)
PY

echo "Running Django check..."
python manage.py check

echo "Restarting app..."
sudo systemctl restart restaurant_clocking

echo "UX/login upgrade complete."
echo "Open /clock/ and /manager/today/"
