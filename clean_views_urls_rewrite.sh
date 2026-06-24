#!/bin/bash
set -e

echo "Backing up messy files..."
cp core/views.py core/views_before_cleanup.py
cp core/urls.py core/urls_before_cleanup.py
cp core/compliance.py core/compliance_before_cleanup.py 2>/dev/null || true

echo "Writing clean core/compliance.py..."
cat > core/compliance.py <<'PY'
from datetime import datetime, timedelta

from django.utils import timezone

from .models import Employee, ClockEvent, RosterShift


def required_break_minutes(worked_minutes):
    if worked_minutes > 360:
        return 30
    if worked_minutes > 270:
        return 15
    return 0


def format_minutes(minutes):
    minutes = int(minutes or 0)
    if minutes < 60:
        return f"{minutes} mins"
    h = minutes // 60
    m = minutes % 60
    return f"{h}h" if m == 0 else f"{h}h {m}m"


def get_roster_info(employee, selected_date):
    shifts = RosterShift.objects.filter(
        employee=employee,
        shift_date=selected_date
    ).order_by("start_time")

    rostered = shifts.exists()
    roster_text = "Not rostered"
    planned_start = None
    planned_end = None
    rostered_minutes = 0

    if rostered:
        parts = []
        for shift in shifts:
            parts.append(f"{shift.start_time.strftime('%H:%M')} - {shift.end_time.strftime('%H:%M')}")

            if planned_start is None or shift.start_time < planned_start:
                planned_start = shift.start_time
            if planned_end is None or shift.end_time > planned_end:
                planned_end = shift.end_time

            start_dt = datetime.combine(shift.shift_date, shift.start_time)
            end_dt = datetime.combine(shift.shift_date, shift.end_time)
            if end_dt <= start_dt:
                end_dt += timedelta(days=1)

            rostered_minutes += int((end_dt - start_dt).total_seconds() / 60)
            rostered_minutes -= shift.break_minutes

        roster_text = ", ".join(parts)

    return {
        "rostered": rostered,
        "roster": roster_text,
        "planned_start": planned_start,
        "planned_end": planned_end,
        "rostered_minutes": max(0, rostered_minutes),
    }


def calculate_employee_day(employee, selected_date, include_live=True):
    events = ClockEvent.objects.filter(
        employee=employee,
        timestamp__date=selected_date
    ).order_by("timestamp")

    roster = get_roster_info(employee, selected_date)

    first_event = events.first()
    latest_event = events.last()
    first_in = None
    last_out = None

    worked_minutes = 0
    break_minutes = 0
    work_start = None
    break_start = None
    invalid_sequence = False

    for event in events:
        if event.clock_type == "IN":
            if first_in is None:
                first_in = event.timestamp
            if work_start is not None:
                invalid_sequence = True
            work_start = event.timestamp

        elif event.clock_type == "BREAK_START":
            if work_start is not None:
                worked_minutes += int((event.timestamp - work_start).total_seconds() / 60)
                work_start = None
            else:
                invalid_sequence = True
            break_start = event.timestamp

        elif event.clock_type == "BREAK_END":
            if break_start is not None:
                break_minutes += int((event.timestamp - break_start).total_seconds() / 60)
                break_start = None
            else:
                invalid_sequence = True
            work_start = event.timestamp

        elif event.clock_type == "OUT":
            last_out = event.timestamp
            if work_start is not None:
                worked_minutes += int((event.timestamp - work_start).total_seconds() / 60)
                work_start = None
            elif break_start is not None:
                break_minutes += int((event.timestamp - break_start).total_seconds() / 60)
                break_start = None
            else:
                # OUT with no IN is allowed as a payroll review item
                if first_event and first_event.id == event.id:
                    pass
                else:
                    invalid_sequence = True

    now = timezone.now()
    if include_live and selected_date == timezone.localdate():
        if work_start is not None:
            worked_minutes += int((now - work_start).total_seconds() / 60)
        elif break_start is not None:
            break_minutes += int((now - break_start).total_seconds() / 60)

    status = "No activity"
    if latest_event:
        if latest_event.clock_type == "IN":
            status = "Working"
        elif latest_event.clock_type == "BREAK_START":
            status = "On Break"
        elif latest_event.clock_type == "BREAK_END":
            status = "Working"
        elif latest_event.clock_type == "OUT":
            status = "Clocked Out"

    required_break = required_break_minutes(worked_minutes)

    urgent_issues = []
    operational_issues = []

    if first_event and first_event.clock_type == "OUT" and first_in is None:
        urgent_issues.append("Missing clock-in; employee clocked out only")

    if invalid_sequence:
        urgent_issues.append("Check clock sequence")

    if latest_event and not roster["rostered"]:
        urgent_issues.append("Working without a scheduled shift")

    if roster["rostered"] and not latest_event and selected_date == timezone.localdate() and roster["planned_start"]:
        planned_dt = timezone.make_aware(datetime.combine(selected_date, roster["planned_start"]))
        if now > planned_dt + timedelta(minutes=30):
            urgent_issues.append("Rostered but absent")
        elif now > planned_dt + timedelta(minutes=10):
            operational_issues.append("Late / not arrived")

    if latest_event and latest_event.clock_type in ["IN", "BREAK_END"]:
        if required_break > 0 and break_minutes < required_break:
            urgent_issues.append(f"Worked {format_minutes(worked_minutes)} with only {break_minutes} mins break")

    if latest_event and latest_event.clock_type == "OUT":
        if worked_minutes > 0 and required_break > 0 and break_minutes < required_break:
            urgent_issues.append("Break missing or too short")

    if selected_date < timezone.localdate() and latest_event and latest_event.clock_type in ["IN", "BREAK_START", "BREAK_END"]:
        urgent_issues.append("Missing clock-out")

    if first_in and roster["planned_start"]:
        planned_start_dt = timezone.make_aware(datetime.combine(selected_date, roster["planned_start"]))

        planned_end_dt = None
        if roster["planned_end"]:
            planned_end_dt = timezone.make_aware(datetime.combine(selected_date, roster["planned_end"]))
            if planned_end_dt <= planned_start_dt:
                planned_end_dt += timedelta(days=1)

        late_minutes = int((first_in - planned_start_dt).total_seconds() / 60)

        if planned_end_dt and first_in > planned_end_dt:
            operational_issues.append("Clocked in after rostered shift ended")
        elif late_minutes > 10:
            operational_issues.append(f"Late by {late_minutes} mins")
        elif late_minutes < -15:
            operational_issues.append(f"Clocked in {abs(late_minutes)} mins early")

    issue_type = "OK"
    issue = "OK"
    if urgent_issues:
        issue_type = "Urgent"
        issue = "; ".join(sorted(set(urgent_issues)))
    elif operational_issues:
        issue_type = "Operational"
        issue = "; ".join(sorted(set(operational_issues)))

    return {
        "employee_number": employee.employee_number,
        "employee": employee.name,
        "employee_obj": employee,
        "date": selected_date,
        "roster": roster["roster"],
        "rostered": roster["rostered"],
        "rostered_minutes": roster["rostered_minutes"],
        "first_in": first_in.strftime("%H:%M") if first_in else "-",
        "last_out": last_out.strftime("%H:%M") if last_out else "-",
        "status": status,
        "worked_minutes": worked_minutes,
        "break_minutes": break_minutes,
        "paid_minutes": worked_minutes,
        "worked_hours": round(worked_minutes / 60, 2),
        "break_hours": round(break_minutes / 60, 2),
        "paid_hours": round(worked_minutes / 60, 2),
        "required_break": required_break,
        "issue_type": issue_type,
        "issue": issue,
        "is_urgent": issue_type == "Urgent",
        "is_operational": issue_type == "Operational",
        "is_working": status == "Working",
        "is_on_break": status == "On Break",
        "is_clocked_out": status == "Clocked Out",
        "has_activity": latest_event is not None,
        "missing_clock_out": selected_date < timezone.localdate() and latest_event is not None and latest_event.clock_type in ["IN", "BREAK_START", "BREAK_END"],
        "invalid_sequence": invalid_sequence,
    }


def get_day_rows(selected_date):
    return [
        calculate_employee_day(employee, selected_date, include_live=True)
        for employee in Employee.objects.filter(active=True).order_by("name")
    ]


def calculate_employee_week(employee, week_start, standard_hours=39):
    standard_minutes = int(float(standard_hours) * 60)

    rostered_minutes = 0
    worked_minutes = 0
    break_minutes = 0
    paid_minutes = 0
    sunday_minutes = 0
    warnings = []

    for i in range(7):
        day = week_start + timedelta(days=i)
        row = calculate_employee_day(employee, day, include_live=True)

        rostered_minutes += row["rostered_minutes"]
        worked_minutes += row["worked_minutes"]
        break_minutes += row["break_minutes"]
        paid_minutes += row["paid_minutes"]

        if day.weekday() == 6:
            sunday_minutes += row["paid_minutes"]

        if row["is_urgent"]:
            warnings.append(f"{day}: {row['issue']}")

    overtime_minutes = max(0, paid_minutes - standard_minutes)
    normal_minutes = max(0, paid_minutes - overtime_minutes - sunday_minutes)

    return {
        "employee": employee.name,
        "employee_number": employee.employee_number,
        "rostered_hours": round(rostered_minutes / 60, 2),
        "worked_hours": round(worked_minutes / 60, 2),
        "break_hours": round(break_minutes / 60, 2),
        "paid_hours": round(paid_minutes / 60, 2),
        "normal_hours": round(normal_minutes / 60, 2),
        "sunday_hours": round(sunday_minutes / 60, 2),
        "overtime_hours": round(overtime_minutes / 60, 2),
        "difference": round((paid_minutes - rostered_minutes) / 60, 2),
        "warning": "; ".join(warnings) if warnings else "OK",
        "paid_minutes": paid_minutes,
        "normal_minutes": normal_minutes,
        "sunday_minutes": sunday_minutes,
        "overtime_minutes": overtime_minutes,
    }


def get_week_rows(week_start, standard_hours=39):
    return [
        calculate_employee_week(employee, week_start, standard_hours)
        for employee in Employee.objects.filter(active=True).order_by("name")
    ]
PY

echo "Writing clean core/views.py..."
cat > core/views.py <<'PY'
import csv
from datetime import datetime, timedelta

from django.contrib.auth import logout
from django.contrib.auth.decorators import login_required
from django.contrib.auth.views import LoginView
from django.http import HttpResponse
from django.shortcuts import redirect, render
from django.urls import reverse_lazy
from django.utils import timezone

from .models import ClockEvent, Employee, RosterShift
from .compliance import get_day_rows, get_week_rows, calculate_employee_day


class ManagerLoginView(LoginView):
    template_name = "manager_login.html"
    redirect_authenticated_user = True

    def get_success_url(self):
        return reverse_lazy("home")


def manager_logout(request):
    logout(request)
    return render(request, "manager_logged_out.html")


@login_required(login_url="/manager/login/")
def home_page(request):
    today = timezone.localdate()
    week_start = today - timedelta(days=today.weekday())

    rows = get_day_rows(today)
    week_rows = get_week_rows(week_start, 39)

    urgent_rows = [row for row in rows if row["is_urgent"]]
    operational_rows = [row for row in rows if row["is_operational"]]
    working_rows = [row for row in rows if row["is_working"] or row["is_on_break"]]
    unrostered_working_rows = [row for row in working_rows if not row["rostered"]]
    payroll_problem_rows = [row for row in week_rows if row["warning"] != "OK"]

    total_staff = len(rows)
    urgent_count = len(urgent_rows)
    health_score = int(((total_staff - urgent_count) / total_staff) * 100) if total_staff else 100

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


def _clock_state_for_employee(employee):
    today = timezone.localdate()
    events = ClockEvent.objects.filter(employee=employee, timestamp__date=today).order_by("timestamp")
    latest = events.last()

    current_state = "CLOCKED_OUT"
    status_label = "⚫ Clocked Out"
    valid_actions = ["IN", "OUT_MISSING_IN"]

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

    clocked_in_time = None
    break_started_time = None
    worked_minutes = 0
    break_minutes = 0
    work_start = None
    break_start = None

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

    shift = RosterShift.objects.filter(employee=employee, shift_date=today).order_by("start_time").first()
    roster_text = f"{shift.start_time.strftime('%H:%M')} - {shift.end_time.strftime('%H:%M')}" if shift else "Not rostered today"

    return {
        "current_state": current_state,
        "status_label": status_label,
        "valid_actions": valid_actions,
        "clocked_in_time": clocked_in_time,
        "break_started_time": break_started_time,
        "worked_hours": round(worked_minutes / 60, 2),
        "break_minutes": break_minutes,
        "roster_text": roster_text,
    }


def smart_clock_page(request):
    message = ""
    warning = ""
    employee = None
    identified = False
    state = {
        "current_state": "CLOCKED_OUT",
        "status_label": "⚫ Clocked Out",
        "valid_actions": [],
        "clocked_in_time": None,
        "break_started_time": None,
        "worked_hours": 0,
        "break_minutes": 0,
        "roster_text": "",
    }

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

        try:
            employee = Employee.objects.get(employee_number=emp_no, pin=pin, active=True)
            identified = True
            state = _clock_state_for_employee(employee)

            if action:
                if action not in state["valid_actions"]:
                    message = "That action is not available for your current status."
                elif state["current_state"] == "ON_BREAK" and action == "OUT" and request.POST.get("confirm_break_clockout") != "yes":
                    message = "You are currently on break. Tick the confirmation box to clock out."
                else:
                    now = timezone.localtime()
                    if state["current_state"] == "ON_BREAK" and action == "OUT":
                        ClockEvent.objects.create(employee=employee, clock_type="BREAK_END", method="QR_AUTO")

                    actual_clock_type = "OUT" if action == "OUT_MISSING_IN" else action
                    notes = "Missing clock-in reported by employee" if action == "OUT_MISSING_IN" else ""

                    ClockEvent.objects.create(
                        employee=employee,
                        clock_type=actual_clock_type,
                        method="QR",
                        notes=notes,
                    )

                    message = action_messages[action].format(name=employee.name, time=now.strftime("%H:%M"))

                    if action == "OUT_MISSING_IN":
                        warning = "Your manager will add the missing clock-in time before payroll."

                    state = _clock_state_for_employee(employee)

        except Employee.DoesNotExist:
            message = "Invalid employee number or PIN."

    return render(request, "clock.html", {
        "message": message,
        "warning": warning,
        "employee": employee,
        "identified": identified,
        "state": state,
    })


@login_required(login_url="/manager/login/")
def upload_roster(request):
    message = ""

    if request.method == "POST" and request.FILES.get("roster_file"):
        file = request.FILES["roster_file"].read().decode("utf-8-sig").splitlines()
        reader = csv.DictReader(file)

        count = 0
        skipped = 0

        for row in reader:
            try:
                employee_number = (row.get("EmployeeNumber") or row.get("employee_number") or "").strip()
                employee = Employee.objects.get(employee_number=employee_number)

                shift_date = datetime.strptime((row.get("Date") or "").strip(), "%Y-%m-%d").date()
                start_time = datetime.strptime((row.get("StartTime") or "").strip(), "%H:%M").time()
                end_time = datetime.strptime((row.get("EndTime") or "").strip(), "%H:%M").time()
                break_minutes = int(row.get("BreakMinutes") or 30)

                RosterShift.objects.update_or_create(
                    employee=employee,
                    shift_date=shift_date,
                    start_time=start_time,
                    defaults={
                        "end_time": end_time,
                        "break_minutes": break_minutes,
                    }
                )
                count += 1
            except Exception:
                skipped += 1

        message = f"Uploaded {count} roster shifts. Skipped {skipped} rows."

    return render(request, "upload_roster.html", {"message": message})


@login_required(login_url="/manager/login/")
def manager_today_dashboard(request):
    selected_date_str = request.GET.get("date", timezone.localdate().strftime("%Y-%m-%d"))
    selected_date = datetime.strptime(selected_date_str, "%Y-%m-%d").date()

    rows = get_day_rows(selected_date)
    urgent_rows = [row for row in rows if row["is_urgent"]]
    operational_rows = [row for row in rows if row["is_operational"]]
    working_rows = [row for row in rows if row["is_working"]]

    return render(request, "manager_today.html", {
        "selected_date": selected_date,
        "rows": rows,
        "urgent_rows": urgent_rows,
        "operational_rows": operational_rows,
        "working_rows": working_rows,
        "rostered_count": sum(1 for row in rows if row["rostered"]),
        "currently_working": len(working_rows),
        "on_break": sum(1 for row in rows if row["is_on_break"]),
        "clocked_out": sum(1 for row in rows if row["is_clocked_out"]),
        "urgent_count": len(urgent_rows),
        "operational_count": len(operational_rows),
    })


@login_required(login_url="/manager/login/")
def manager_weekly_summary(request):
    week_start_str = request.GET.get("week_start")
    if week_start_str:
        week_start = datetime.strptime(week_start_str, "%Y-%m-%d").date()
    else:
        today = timezone.localdate()
        week_start = today - timedelta(days=today.weekday())

    week_end = week_start + timedelta(days=6)
    standard_hours = float(request.GET.get("standard_hours", "39"))
    summary_rows = get_week_rows(week_start, standard_hours)

    return render(request, "weekly_summary.html", {
        "week_start": week_start,
        "week_end": week_end,
        "summary_rows": summary_rows,
        "standard_hours": standard_hours,
    })


@login_required(login_url="/manager/login/")
def payroll_problems(request):
    week_start_str = request.GET.get("week_start")
    if week_start_str:
        week_start = datetime.strptime(week_start_str, "%Y-%m-%d").date()
    else:
        today = timezone.localdate()
        week_start = today - timedelta(days=today.weekday())

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


@login_required(login_url="/manager/login/")
def manager_corrections(request):
    selected_date_str = request.GET.get("date", timezone.localdate().strftime("%Y-%m-%d"))
    selected_date = datetime.strptime(selected_date_str, "%Y-%m-%d").date()
    message = ""

    if request.method == "POST":
        action = request.POST.get("action")

        if action == "add_event":
            try:
                employee = Employee.objects.get(employee_number=request.POST.get("employee_number"), active=True)
                naive_dt = datetime.strptime(
                    f"{request.POST.get('event_date')} {request.POST.get('event_time')}",
                    "%Y-%m-%d %H:%M"
                )
                event_dt = timezone.make_aware(naive_dt)
                ClockEvent.objects.create(
                    employee=employee,
                    clock_type=request.POST.get("clock_type"),
                    timestamp=event_dt,
                    method="MANAGER",
                    notes=request.POST.get("reason", "Manager correction"),
                )
                message = f"Added event for {employee.name}."
            except Exception as e:
                message = f"Could not add event: {e}"

        elif action == "delete_event":
            try:
                event = ClockEvent.objects.get(id=request.POST.get("event_id"))
                details = f"{event.employee.name} {event.clock_type} {event.timestamp}"
                event.delete()
                message = f"Deleted event: {details}"
            except Exception as e:
                message = f"Could not delete event: {e}"

    employees = Employee.objects.filter(active=True).order_by("name")
    events = ClockEvent.objects.select_related("employee").filter(timestamp__date=selected_date).order_by("-timestamp")

    return render(request, "manager_corrections.html", {
        "selected_date": selected_date,
        "employees": employees,
        "events": events,
        "message": message,
    })


@login_required(login_url="/manager/login/")
def manager_add_missing_event(request):
    return manager_corrections(request)


@login_required(login_url="/manager/login/")
def export_sage_payroll_csv(request):
    week_start_str = request.GET.get("week_start")
    if week_start_str:
        week_start = datetime.strptime(week_start_str, "%Y-%m-%d").date()
    else:
        today = timezone.localdate()
        week_start = today - timedelta(days=today.weekday())

    period_number = request.GET.get("period", "1")
    standard_hours = float(request.GET.get("standard_hours", "39"))
    rows = get_week_rows(week_start, standard_hours)

    response = HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = 'attachment; filename="sage_payroll_export.csv"'

    writer = csv.writer(response)
    writer.writerow(["PeriodNumber", "EmployeeNumber", "0000", "NormalHours", "SundayHours", "OvertimeHours"])

    for row in rows:
        if row["paid_minutes"] == 0:
            continue
        writer.writerow([
            period_number,
            row["employee_number"],
            "0000",
            row["normal_hours"],
            row["sunday_hours"],
            row["overtime_hours"],
        ])

    return response


@login_required(login_url="/manager/login/")
def export_clock_events_csv(request):
    response = HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = 'attachment; filename="clock_events.csv"'

    writer = csv.writer(response)
    writer.writerow(["EmployeeNumber", "Employee", "ClockType", "Timestamp", "Method", "Notes"])

    for event in ClockEvent.objects.select_related("employee").order_by("-timestamp"):
        writer.writerow([
            event.employee.employee_number,
            event.employee.name,
            event.clock_type,
            timezone.localtime(event.timestamp).strftime("%Y-%m-%d %H:%M"),
            event.method,
            event.notes,
        ])

    return response


@login_required(login_url="/manager/login/")
def manager_daily_monitor(request):
    return manager_today_dashboard(request)


@login_required(login_url="/manager/login/")
def manager_dashboard(request):
    return manager_today_dashboard(request)


@login_required(login_url="/manager/login/")
def generate_test_clock_events(request):
    return redirect("manager_today_dashboard")
PY

echo "Writing clean core/urls.py..."
cat > core/urls.py <<'PY'
from django.urls import path

from .views import (
    ManagerLoginView,
    export_clock_events_csv,
    export_sage_payroll_csv,
    generate_test_clock_events,
    home_page,
    manager_add_missing_event,
    manager_corrections,
    manager_daily_monitor,
    manager_dashboard,
    manager_logout,
    manager_today_dashboard,
    manager_weekly_summary,
    payroll_problems,
    smart_clock_page,
    upload_roster,
)

urlpatterns = [
    path("", home_page, name="home"),
    path("clock/", smart_clock_page, name="clock"),

    path("manager/login/", ManagerLoginView.as_view(), name="manager_login"),
    path("manager/logout/", manager_logout, name="manager_logout"),

    path("manager/today/", manager_today_dashboard, name="manager_today_dashboard"),
    path("manager/dashboard/", manager_dashboard, name="manager_dashboard"),
    path("manager/upload-roster/", upload_roster, name="upload_roster"),
    path("manager/weekly-summary/", manager_weekly_summary, name="manager_weekly_summary"),
    path("manager/payroll-problems/", payroll_problems, name="payroll_problems"),
    path("manager/corrections/", manager_corrections, name="manager_corrections"),
    path("manager/add-missing-event/", manager_add_missing_event, name="manager_add_missing_event"),
    path("manager/daily-monitor/", manager_daily_monitor, name="manager_daily_monitor"),
    path("manager/generate-test-events/", generate_test_clock_events, name="generate_test_clock_events"),

    path("export/clock-events/", export_clock_events_csv, name="export_clock_events_csv"),
    path("manager/export-sage-payroll/", export_sage_payroll_csv, name="export_sage_payroll_csv"),
]
PY

echo "Running checks..."
python manage.py check

echo "Restarting service..."
sudo systemctl restart restaurant_clocking

echo "Clean rewrite complete."
echo "Check duplicates with:"
echo "grep -n 'def smart_clock_page' core/views.py"
