from django.shortcuts import render
from django.utils import timezone

from .models import ClockEvent, Employee, RosterShift


def _clock_state_for_employee(employee):
    today = timezone.localdate()
    now = timezone.now()

    # Staff clocking must reflect what has happened up to this moment only.
    # Manager corrections, demo data, or roster simulations may contain later events
    # for today. If we include future events here, a staff member can press Clock In
    # and still appear Clocked Out because a later OUT already exists in the day.
    latest = ClockEvent.objects.filter(
        employee=employee,
        timestamp__date=today,
        timestamp__lte=now,
    ).order_by("-timestamp", "-id").first()

    events = ClockEvent.objects.filter(
        employee=employee,
        timestamp__date=today,
        timestamp__lte=now,
    ).order_by("timestamp", "id")

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

