#!/bin/bash
set -e

echo "Creating cleanup branch if needed..."
git checkout -B cleanup-demo

echo "Backing up current files..."
mkdir -p cleanup_backup_$(date +%Y%m%d_%H%M%S)
BACKUP_DIR=$(ls -td cleanup_backup_* | head -1)
cp core/views.py "$BACKUP_DIR/views.py"
cp core/urls.py "$BACKUP_DIR/urls.py"
cp core/compliance.py "$BACKUP_DIR/compliance.py" 2>/dev/null || true
cp templates/home.html "$BACKUP_DIR/home.html" 2>/dev/null || true
cp templates/clock.html "$BACKUP_DIR/clock.html" 2>/dev/null || true
cp templates/payroll_problems.html "$BACKUP_DIR/payroll_problems.html" 2>/dev/null || true
cp templates/manager_corrections.html "$BACKUP_DIR/manager_corrections.html" 2>/dev/null || true

echo "Writing clean compliance engine..."
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
        if latest_event.clock_type in ["IN", "BREAK_END"]:
            status = "Working"
        elif latest_event.clock_type == "BREAK_START":
            status = "On Break"
        elif latest_event.clock_type == "OUT":
            status = "Clocked Out"

    required_break = required_break_minutes(worked_minutes)

    urgent_issues = []
    operational_issues = []

    if first_event and first_event.clock_type == "OUT" and first_in is None:
        urgent_issues.append("Missing clock-in; employee clocked out only")

    if invalid_sequence:
        urgent_issues.append("Check clock sequence")

    if latest_event and latest_event.clock_type in ["IN", "BREAK_START", "BREAK_END"] and not roster["rostered"]:
        urgent_issues.append("Working without scheduled shift")

    if roster["rostered"] and not latest_event and selected_date == timezone.localdate() and roster["planned_start"]:
        planned_dt = timezone.make_aware(datetime.combine(selected_date, roster["planned_start"]))
        now = timezone.now()
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
            operational_issues.append("Clocked in after scheduled shift ended")
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

echo "Writing clean views..."
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
from .compliance import calculate_employee_day, get_day_rows, get_week_rows


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
    now = timezone.localtime()
    week_start = today - timedelta(days=today.weekday())

    rows = get_day_rows(today)
    week_rows = get_week_rows(week_start, 39)

    current_staff = [row for row in rows if row["is_working"] or row["is_on_break"]]
    urgent_rows = [row for row in rows if row["is_urgent"]]
    payroll_problem_rows = [row for row in week_rows if row["warning"] != "OK"]

    rostered_now = []
    not_clocked_in_now = []

    for shift in RosterShift.objects.select_related("employee").filter(shift_date=today, employee__active=True).order_by("start_time"):
        start_dt = timezone.make_aware(datetime.combine(today, shift.start_time))
        end_dt = timezone.make_aware(datetime.combine(today, shift.end_time))
        if end_dt <= start_dt:
            end_dt += timedelta(days=1)

        if start_dt <= now <= end_dt:
            row = next((r for r in rows if r["employee_number"] == shift.employee.employee_number), None)
            if row:
                rostered_now.append(row)
                if not row["is_working"] and not row["is_on_break"]:
                    not_clocked_in_now.append(row)

    attention_rows = []
    seen = set()

    for row in not_clocked_in_now + urgent_rows:
        key = row["employee_number"] + row["issue"]
        if key not in seen:
            attention_rows.append(row)
            seen.add(key)

    return render(request, "home.html", {
        "today": today,
        "now": now,
        "week_start": week_start,
        "current_staff": current_staff,
        "attention_rows": attention_rows,
        "rostered_now_count": len(rostered_now),
        "current_staff_count": len(current_staff),
        "not_clocked_in_now_count": len(not_clocked_in_now),
        "on_break_count": sum(1 for row in rows if row["is_on_break"]),
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
            valid_actions = ["IN", "OUT_MISSING_IN"]

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
        "OUT_MISSING_IN": "👋 {name} clocked out at {time}. Manager review required for missing clock-in.",
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

                    ClockEvent.objects.create(employee=employee, clock_type=actual_clock_type, method="QR", notes=notes)
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
def manager_corrections(request):
    selected_date_str = request.GET.get("date", timezone.localdate().strftime("%Y-%m-%d"))
    selected_date = datetime.strptime(selected_date_str, "%Y-%m-%d").date()
    selected_employee_number = request.GET.get("employee_number", "")
    message = ""

    if request.method == "POST":
        action = request.POST.get("action")
        selected_employee_number = request.POST.get("employee_number") or selected_employee_number

        if action == "add_event":
            try:
                employee = Employee.objects.get(employee_number=selected_employee_number, active=True)
                event_dt = timezone.make_aware(datetime.strptime(f"{request.POST.get('event_date')} {request.POST.get('event_time')}", "%Y-%m-%d %H:%M"))
                ClockEvent.objects.create(
                    employee=employee,
                    clock_type=request.POST.get("clock_type"),
                    timestamp=event_dt,
                    method="MANAGER",
                    notes=request.POST.get("reason", "Manager correction"),
                )
                selected_date = event_dt.date()
                message = f"Added {request.POST.get('clock_type')} for {employee.name}."
            except Exception as e:
                message = f"Could not add event: {e}"

        elif action == "delete_event":
            try:
                event = ClockEvent.objects.get(id=request.POST.get("event_id"))
                selected_employee_number = event.employee.employee_number
                selected_date = timezone.localtime(event.timestamp).date()
                details = f"{event.employee.name} {event.clock_type} {timezone.localtime(event.timestamp).strftime('%H:%M')}"
                event.delete()
                message = f"Deleted event: {details}"
            except Exception as e:
                message = f"Could not delete event: {e}"

    selected_employee = Employee.objects.filter(employee_number=selected_employee_number, active=True).first() if selected_employee_number else None
    employees = Employee.objects.filter(active=True).order_by("name")

    events = ClockEvent.objects.none()
    if selected_employee:
        events = ClockEvent.objects.filter(employee=selected_employee, timestamp__date=selected_date).order_by("timestamp")

    return render(request, "manager_corrections.html", {
        "selected_date": selected_date,
        "selected_employee": selected_employee,
        "selected_employee_number": selected_employee_number,
        "employees": employees,
        "events": events,
        "message": message,
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
                    defaults={"end_time": end_time, "break_minutes": break_minutes}
                )
                count += 1
            except Exception:
                skipped += 1

        message = f"Uploaded {count} roster shifts. Skipped {skipped} rows."

    return render(request, "upload_roster.html", {"message": message})


@login_required(login_url="/manager/login/")
def manager_today_dashboard(request):
    return home_page(request)


@login_required(login_url="/manager/login/")
def manager_dashboard(request):
    return home_page(request)


@login_required(login_url="/manager/login/")
def manager_daily_monitor(request):
    return home_page(request)


@login_required(login_url="/manager/login/")
def manager_weekly_summary(request):
    week_start_str = request.GET.get("week_start")
    week_start = datetime.strptime(week_start_str, "%Y-%m-%d").date() if week_start_str else timezone.localdate() - timedelta(days=timezone.localdate().weekday())
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
    week_start = datetime.strptime(week_start_str, "%Y-%m-%d").date() if week_start_str else timezone.localdate() - timedelta(days=timezone.localdate().weekday())
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
                    "employee_number": employee.employee_number,
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
def manager_add_missing_event(request):
    return manager_corrections(request)


@login_required(login_url="/manager/login/")
def export_sage_payroll_csv(request):
    week_start_str = request.GET.get("week_start")
    week_start = datetime.strptime(week_start_str, "%Y-%m-%d").date() if week_start_str else timezone.localdate() - timedelta(days=timezone.localdate().weekday())
    rows = get_week_rows(week_start, float(request.GET.get("standard_hours", "39")))
    period_number = request.GET.get("period", "1")

    response = HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = 'attachment; filename="sage_payroll_export.csv"'
    writer = csv.writer(response)
    writer.writerow(["PeriodNumber", "EmployeeNumber", "0000", "NormalHours", "SundayHours", "OvertimeHours"])

    for row in rows:
        if row["paid_minutes"] == 0:
            continue
        writer.writerow([period_number, row["employee_number"], "0000", row["normal_hours"], row["sunday_hours"], row["overtime_hours"]])

    return response


@login_required(login_url="/manager/login/")
def export_clock_events_csv(request):
    response = HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = 'attachment; filename="clock_events.csv"'
    writer = csv.writer(response)
    writer.writerow(["EmployeeNumber", "Employee", "ClockType", "Timestamp", "Method", "Notes"])

    for event in ClockEvent.objects.select_related("employee").order_by("-timestamp"):
        writer.writerow([event.employee.employee_number, event.employee.name, event.clock_type, timezone.localtime(event.timestamp).strftime("%Y-%m-%d %H:%M"), event.method, event.notes])

    return response


@login_required(login_url="/manager/login/")
def generate_test_clock_events(request):
    return redirect("home")
PY

echo "Writing clean urls..."
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
    path("manager/dashboard/", manager_dashboard, name="manager_dashboard"),
    path("manager/today/", manager_today_dashboard, name="manager_today_dashboard"),
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

echo "Writing simple manager dashboard..."
cat > templates/home.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Manager Dashboard</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 24px; color: #222; }
        .container { max-width: 1080px; margin: auto; }
        .header, .section { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 20px; margin-bottom: 16px; }
        h1 { margin: 0 0 8px 0; }
        .muted { color: #666; }
        .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; margin: 16px 0; }
        .card { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 16px; }
        .number { font-size: 32px; font-weight: bold; margin-top: 6px; }
        .good { color: #1a7f37; font-weight: bold; }
        .warn { color: #b7791f; font-weight: bold; }
        .urgent { color: #b42318; font-weight: bold; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 9px; text-align: left; vertical-align: top; }
        th { background: #f9fafb; }
        .button { display: inline-block; padding: 8px 11px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 7px; margin-top: 8px; }
        .secondary { background: #4b5563; }
        .danger { background: #b42318; }
    </style>
</head>
<body>
<div class="container">

    <div class="header">
        <h1>Manager Dashboard</h1>
        <p class="muted">Today: {{ today }}. Current time: {{ now|date:"H:i" }}.</p>
    </div>

    <div class="cards">
        <div class="card"><div>Current Staff</div><div class="number good">{{ current_staff_count }}</div></div>
        <div class="card"><div>On Break</div><div class="number warn">{{ on_break_count }}</div></div>
        <div class="card"><div>Rostered Now</div><div class="number">{{ rostered_now_count }}</div></div>
        <div class="card"><div>Not Clocked In</div><div class="number {% if not_clocked_in_now_count > 0 %}urgent{% else %}good{% endif %}">{{ not_clocked_in_now_count }}</div></div>
    </div>

    <div class="section">
        <h2>Current Staff</h2>
        <p class="muted">Who is clocked in or on break right now.</p>
        <table>
            <tr><th>Employee</th><th>Status</th><th>Roster</th><th>Clocked In</th><th>Worked</th><th>Break</th><th>Note</th></tr>
            {% for row in current_staff %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{{ row.status }}</td>
                <td>{{ row.roster }}</td>
                <td>{{ row.first_in }}</td>
                <td>{{ row.worked_hours }}h</td>
                <td>{{ row.break_minutes }} mins</td>
                <td class="{% if row.is_urgent %}urgent{% elif row.is_operational %}warn{% else %}good{% endif %}">{{ row.issue }}</td>
            </tr>
            {% empty %}
            <tr><td colspan="7">No staff currently clocked in or on break.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Needs Attention</h2>
        <p class="muted">Manager decisions or payroll corrections.</p>
        <table>
            <tr><th>Employee</th><th>Status</th><th>Issue</th><th>Fix</th></tr>
            {% for row in attention_rows %}
            <tr>
                <td>{{ row.employee }}</td>
                <td>{{ row.status }}</td>
                <td class="urgent">{{ row.issue }}</td>
                <td><a class="button danger" href="/manager/corrections/?date={{ today|date:'Y-m-d' }}&employee_number={{ row.employee_number }}">Fix</a></td>
            </tr>
            {% empty %}
            <tr><td colspan="4" class="good">No items needing attention.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Quick Actions</h2>
        <a class="button" href="/clock/">Staff Clocking</a>
        <a class="button" href="/manager/upload-roster/">Upload Roster</a>
        <a class="button" href="/manager/payroll-problems/?week_start={{ week_start|date:'Y-m-d' }}">Payroll Issues</a>
        <a class="button" href="/manager/weekly-summary/?week_start={{ week_start|date:'Y-m-d' }}">Weekly Payroll</a>
        <a class="button" href="/manager/corrections/?date={{ today|date:'Y-m-d' }}">Manager Corrections</a>
        <a class="button secondary" href="/admin/">System Admin</a>
    </div>

</div>
</body>
</html>
HTML

echo "Writing focused corrections page..."
cat > templates/manager_corrections.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Manager Corrections</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 24px; color: #222; }
        .container { max-width: 900px; margin: auto; }
        .section { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 20px; margin-bottom: 16px; }
        input, select, textarea, button { padding: 9px; margin: 4px 0; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 9px; text-align: left; }
        th { background: #f9fafb; }
        .button { display: inline-block; padding: 8px 11px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 7px; margin-top: 8px; }
        .danger { background: #b42318; color: white; border: none; border-radius: 8px; }
        .message { background: #eef5ff; border-left: 4px solid #2563eb; padding: 10px; margin: 10px 0; }
    </style>
</head>
<body>
<div class="container">

<div class="section">
<h1>Manager Corrections</h1>
<p>Choose one employee and add the missing clock event.</p>

{% if message %}<div class="message">{{ message }}</div>{% endif %}

<form method="get">
    Date:
    <input type="date" name="date" value="{{ selected_date|date:'Y-m-d' }}">
    Employee:
    <select name="employee_number">
        <option value="">Select employee</option>
        {% for employee in employees %}
            <option value="{{ employee.employee_number }}" {% if employee.employee_number == selected_employee_number %}selected{% endif %}>{{ employee.name }}</option>
        {% endfor %}
    </select>
    <button type="submit">Load</button>
</form>
</div>

{% if selected_employee %}
<div class="section">
<h2>{{ selected_employee.name }}</h2>

<h3>Add Missing Event</h3>
<form method="post">
    {% csrf_token %}
    <input type="hidden" name="action" value="add_event">
    <input type="hidden" name="employee_number" value="{{ selected_employee.employee_number }}">
    <input type="hidden" name="event_date" value="{{ selected_date|date:'Y-m-d' }}">

    Type:
    <select name="clock_type">
        <option value="IN">Clock In</option>
        <option value="BREAK_START">Start Break</option>
        <option value="BREAK_END">End Break</option>
        <option value="OUT">Clock Out</option>
    </select>

    Time:
    <input type="time" name="event_time" required>

    Reason:
    <input type="text" name="reason" placeholder="e.g. forgot to clock in">

    <button type="submit">Add Event</button>
</form>

<h3>Events for {{ selected_date }}</h3>
<table>
    <tr><th>Type</th><th>Time</th><th>Method</th><th>Action</th></tr>
    {% for event in events %}
    <tr>
        <td>{{ event.clock_type }}</td>
        <td>{{ event.timestamp|date:"H:i" }}</td>
        <td>{{ event.method }}</td>
        <td>
            <form method="post" onsubmit="return confirm('Delete this event?');">
                {% csrf_token %}
                <input type="hidden" name="action" value="delete_event">
                <input type="hidden" name="event_id" value="{{ event.id }}">
                <button class="danger" type="submit">Delete</button>
            </form>
        </td>
    </tr>
    {% empty %}
    <tr><td colspan="4">No events for this employee on this date.</td></tr>
    {% endfor %}
</table>
</div>
{% endif %}

<p>
    <a class="button" href="/">Dashboard</a>
    <a class="button" href="/manager/payroll-problems/">Payroll Issues</a>
</p>

</div>
</body>
</html>
HTML

echo "Checking..."
python manage.py check

echo "Restarting..."
sudo systemctl restart restaurant_clocking

echo "Done. Verify function duplicates:"
grep -n "def smart_clock_page" core/views.py
grep -n "def home_page" core/views.py
