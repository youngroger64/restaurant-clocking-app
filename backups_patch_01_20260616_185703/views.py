import csv
from datetime import datetime, timedelta

from django.shortcuts import render
from django.http import HttpResponse
from django.utils import timezone

from .models import Employee, ClockEvent, RosterShift


def home_page(request):
    return render(request, "home.html")


def clock_page(request):
    message = ""

    action_labels = {
        "IN": "clocked IN",
        "BREAK_START": "started BREAK",
        "BREAK_END": "ended BREAK",
        "OUT": "clocked OUT",
    }

    valid_next_actions = {
        None: ["IN"],
        "IN": ["BREAK_START", "OUT"],
        "BREAK_START": ["BREAK_END"],
        "BREAK_END": ["BREAK_START", "OUT"],
        "OUT": ["IN"],
    }

    if request.method == "POST":
        emp_no = request.POST.get("employee_number")
        pin = request.POST.get("pin")
        action = request.POST.get("action")

        try:
            employee = Employee.objects.get(
                employee_number=emp_no,
                pin=pin,
                active=True
            )

            latest_event = ClockEvent.objects.filter(
                employee=employee
            ).order_by("-timestamp").first()

            latest_type = latest_event.clock_type if latest_event else None

            if action not in valid_next_actions.get(latest_type, []):
                latest_label = latest_type if latest_type else "NO PREVIOUS EVENT"
                message = (
                    f"Invalid action. {employee.name}'s latest status is "
                    f"{latest_label}. You cannot do {action} now."
                )
            else:
                ClockEvent.objects.create(
                    employee=employee,
                    clock_type=action,
                    method="QR"
                )

                message = f"{employee.name} {action_labels[action]} successfully."

        except Employee.DoesNotExist:
            message = "Invalid employee number or PIN"

    return render(request, "clock.html", {"message": message})

def export_clock_events_csv(request):
    response = HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = 'attachment; filename="clock_events.csv"'

    writer = csv.writer(response)
    writer.writerow([
        "Employee Number",
        "Employee Name",
        "Clock Type",
        "Timestamp",
        "Method"
    ])

    events = ClockEvent.objects.select_related("employee").order_by("timestamp")

    for event in events:
        writer.writerow([
            event.employee.employee_number,
            event.employee.name,
            event.clock_type,
            event.timestamp.strftime("%Y-%m-%d %H:%M:%S"),
            event.method
        ])

    return response


def upload_roster(request):
    message = ""

    if request.method == "POST":
        roster_file = request.FILES.get("roster_file")

        if roster_file:
            decoded_file = roster_file.read().decode("utf-8").splitlines()
            reader = csv.DictReader(decoded_file)

            count = 0

            for row in reader:
                emp_no = row["EmployeeNumber"].strip()
                name = row["EmployeeName"].strip()

                employee, created = Employee.objects.get_or_create(
                    employee_number=emp_no,
                    defaults={
                        "name": name,
                        "pin": emp_no,
                        "active": True,
                    }
                )

                RosterShift.objects.create(
                    employee=employee,
                    shift_date=datetime.strptime(row["Date"], "%Y-%m-%d").date(),
                    start_time=datetime.strptime(row["StartTime"], "%H:%M").time(),
                    end_time=datetime.strptime(row["EndTime"], "%H:%M").time(),
                    break_minutes=int(row["BreakMinutes"]),
                )

                count += 1

            message = f"Uploaded {count} roster shifts."

    return render(request, "upload_roster.html", {"message": message})


def manager_dashboard(request):
    today = timezone.localdate()

    roster_today = RosterShift.objects.filter(
        shift_date=today
    ).select_related("employee").order_by("start_time")

    recent_events = ClockEvent.objects.select_related(
        "employee"
    ).order_by("-timestamp")[:20]

    dashboard_rows = []

    for shift in roster_today:
        latest_event = ClockEvent.objects.filter(
            employee=shift.employee,
            timestamp__date=today
        ).order_by("-timestamp").first()

        if latest_event is None:
            status = "Not arrived"
            last_event_time = "-"
        elif latest_event.clock_type == "IN":
            status = "Currently IN"
            last_event_time = latest_event.timestamp.strftime("%H:%M")
        else:
            status = "Clocked OUT"
            last_event_time = latest_event.timestamp.strftime("%H:%M")

        dashboard_rows.append({
            "employee": shift.employee.name,
            "start": shift.start_time.strftime("%H:%M"),
            "end": shift.end_time.strftime("%H:%M"),
            "status": status,
            "last_event_time": last_event_time,
        })

    return render(request, "manager_dashboard.html", {
        "today": today,
        "dashboard_rows": dashboard_rows,
        "recent_events": recent_events,
    })


def manager_weekly_summary(request):
    week_start_str = request.GET.get("week_start", "2026-06-15")
    week_start = datetime.strptime(week_start_str, "%Y-%m-%d").date()
    week_end = week_start + timedelta(days=6)

    employees = Employee.objects.filter(active=True).order_by("name")
    summary_rows = []

    for employee in employees:
        shifts = RosterShift.objects.filter(
            employee=employee,
            shift_date__range=[week_start, week_end]
        )

        rostered_minutes = 0

        for shift in shifts:
            start_dt = datetime.combine(shift.shift_date, shift.start_time)
            end_dt = datetime.combine(shift.shift_date, shift.end_time)
            shift_minutes = int((end_dt - start_dt).total_seconds() / 60)
            shift_minutes -= shift.break_minutes
            rostered_minutes += shift_minutes

        events = ClockEvent.objects.filter(
            employee=employee,
            timestamp__date__range=[week_start, week_end]
        ).order_by("timestamp")

        worked_minutes = 0
        last_in = None
        missing_clock_out = False

        for event in events:
            if event.clock_type == "IN":
                last_in = event.timestamp
            elif event.clock_type == "OUT" and last_in:
                diff = event.timestamp - last_in
                worked_minutes += int(diff.total_seconds() / 60)
                last_in = None

        if last_in:
            missing_clock_out = True

        rostered_hours = round(rostered_minutes / 60, 2)
        worked_hours = round(worked_minutes / 60, 2)
        difference = round(worked_hours - rostered_hours, 2)

        if missing_clock_out:
            warning = "Missing clock-out"
        elif rostered_hours > 0 and worked_hours == 0:
            warning = "No clock events for rostered week"
        elif difference > 0.25:
            warning = "Possible overtime"
        elif difference < -0.25:
            warning = "Worked less than rostered"
        else:
            warning = "OK"

        summary_rows.append({
            "employee": employee.name,
            "employee_number": employee.employee_number,
            "rostered_hours": rostered_hours,
            "worked_hours": worked_hours,
            "difference": difference,
            "warning": warning,
        })

    return render(request, "weekly_summary.html", {
        "week_start": week_start,
        "week_end": week_end,
        "summary_rows": summary_rows,
    })
def generate_test_clock_events(request):
    week_start_str = request.GET.get("week_start", "2026-06-15")
    week_start = datetime.strptime(week_start_str, "%Y-%m-%d").date()
    week_end = week_start + timedelta(days=6)

    shifts = RosterShift.objects.filter(
        shift_date__range=[week_start, week_end]
    ).select_related("employee")

    ClockEvent.objects.filter(
        timestamp__date__range=[week_start, week_end]
    ).delete()

    count = 0

    for shift in shifts:
        start_dt = timezone.make_aware(
            datetime.combine(shift.shift_date, shift.start_time)
        )
        end_dt = timezone.make_aware(
            datetime.combine(shift.shift_date, shift.end_time)
        )

        # Add small realistic variations
        clock_in_time = start_dt + timedelta(minutes=3)
        clock_out_time = end_dt + timedelta(minutes=12)

        ClockEvent.objects.create(
            employee=shift.employee,
            clock_type="IN",
            timestamp=clock_in_time,
            method="TEST"
        )

        ClockEvent.objects.create(
            employee=shift.employee,
            clock_type="OUT",
            timestamp=clock_out_time,
            method="TEST"
        )

        count += 2

    return render(request, "generate_test_events.html", {
        "count": count,
        "week_start": week_start,
        "week_end": week_end,
    })
def manager_daily_monitor(request):
    selected_date_str = request.GET.get(
        "date",
        timezone.localdate().strftime("%Y-%m-%d")
    )

    selected_date = datetime.strptime(selected_date_str, "%Y-%m-%d").date()

    employees = Employee.objects.filter(active=True).order_by("name")
    monitor_rows = []

    for employee in employees:
        events = ClockEvent.objects.filter(
            employee=employee,
            timestamp__date=selected_date
        ).order_by("timestamp")

        shifts = RosterShift.objects.filter(
            employee=employee,
            shift_date=selected_date
        ).order_by("start_time")

        roster_text = "Not rostered"

        if shifts.exists():
            roster_parts = []
            for shift in shifts:
                roster_parts.append(
                    f"{shift.start_time.strftime('%H:%M')} - {shift.end_time.strftime('%H:%M')}"
                )
            roster_text = ", ".join(roster_parts)

        first_in = None
        last_out = None
        worked_minutes = 0
        last_in = None
        in_count = 0
        out_count = 0

        for event in events:
            if event.clock_type == "IN":
                in_count += 1
                if first_in is None:
                    first_in = event.timestamp
                last_in = event.timestamp

            elif event.clock_type == "OUT":
                out_count += 1
                last_out = event.timestamp

                if last_in:
                    worked_minutes += int((event.timestamp - last_in).total_seconds() / 60)
                    last_in = None

        if last_in:
            status = "Currently IN / Missing OUT"
        elif in_count == 0 and out_count == 0 and shifts.exists():
            status = "Rostered but no clock-in"
        elif in_count == 0 and out_count == 0:
            status = "No activity"
        elif in_count > out_count:
            status = "Missing clock-out"
        elif out_count > in_count:
            status = "Clock-out without clock-in"
        else:
            status = "Clocked OUT"

        worked_hours = round(worked_minutes / 60, 2)

        monitor_rows.append({
            "employee_number": employee.employee_number,
            "employee": employee.name,
            "roster": roster_text,
            "first_in": first_in.strftime("%H:%M") if first_in else "-",
            "last_out": last_out.strftime("%H:%M") if last_out else "-",
            "worked_hours": worked_hours,
            "status": status,
            "event_count": events.count(),
        })

    recent_events = ClockEvent.objects.select_related("employee").filter(
        timestamp__date=selected_date
    ).order_by("-timestamp")[:20]

    return render(request, "daily_monitor.html", {
        "selected_date": selected_date,
        "monitor_rows": monitor_rows,
        "recent_events": recent_events,
    })
def calculate_day_metrics(employee, selected_date):
    events = ClockEvent.objects.filter(
        employee=employee,
        timestamp__date=selected_date
    ).order_by("timestamp")

    shifts = RosterShift.objects.filter(
        employee=employee,
        shift_date=selected_date
    ).order_by("start_time")

    roster_text = "Not rostered"

    if shifts.exists():
        roster_parts = []
        for shift in shifts:
            roster_parts.append(
                f"{shift.start_time.strftime('%H:%M')} - {shift.end_time.strftime('%H:%M')}"
            )
        roster_text = ", ".join(roster_parts)

    first_in = None
    last_out = None
    latest_event = events.last()

    worked_minutes = 0
    break_minutes = 0

    work_start = None
    break_start = None
    invalid_sequence = False

    for event in events:
        if event.clock_type == "IN":
            if first_in is None:
                first_in = event.timestamp
            work_start = event.timestamp

        elif event.clock_type == "BREAK_START":
            if work_start:
                worked_minutes += int((event.timestamp - work_start).total_seconds() / 60)
                work_start = None
            else:
                invalid_sequence = True
            break_start = event.timestamp

        elif event.clock_type == "BREAK_END":
            if break_start:
                break_minutes += int((event.timestamp - break_start).total_seconds() / 60)
                break_start = None
            else:
                invalid_sequence = True
            work_start = event.timestamp

        elif event.clock_type == "OUT":
            last_out = event.timestamp

            if work_start:
                worked_minutes += int((event.timestamp - work_start).total_seconds() / 60)
                work_start = None
            elif break_start:
                break_minutes += int((event.timestamp - break_start).total_seconds() / 60)
                break_start = None
            else:
                invalid_sequence = True

    status = "No activity"

    if latest_event:
        if latest_event.clock_type == "IN":
            status = "Currently working"
        elif latest_event.clock_type == "BREAK_START":
            status = "On break"
        elif latest_event.clock_type == "BREAK_END":
            status = "Back from break"
        elif latest_event.clock_type == "OUT":
            status = "Clocked out"

    required_break = 0

    if worked_minutes > 360:
        required_break = 30
    elif worked_minutes > 270:
        required_break = 15

    compliance = "OK"
    attention = False

    if invalid_sequence:
        compliance = "Check clock sequence"
        attention = True
    elif latest_event and not shifts.exists():
        compliance = "Worked but not rostered"
        attention = True
    elif shifts.exists() and not latest_event:
        compliance = "Rostered but no clock-in"
        attention = True
    elif required_break > 0 and break_minutes < required_break:
        compliance = "Break missing or too short"
        attention = True

    return {
        "employee_number": employee.employee_number,
        "employee": employee.name,
        "roster": roster_text,
        "first_in": first_in.strftime("%H:%M") if first_in else "-",
        "last_out": last_out.strftime("%H:%M") if last_out else "-",
        "status": status,
        "worked_hours": round(worked_minutes / 60, 2),
        "break_minutes": break_minutes,
        "paid_hours": round(worked_minutes / 60, 2),
        "required_break": required_break,
        "compliance": compliance,
        "attention": attention,
    }


def compliance_dashboard(request):
    selected_date_str = request.GET.get(
        "date",
        timezone.localdate().strftime("%Y-%m-%d")
    )

    selected_date = datetime.strptime(selected_date_str, "%Y-%m-%d").date()

    employees = Employee.objects.filter(active=True).order_by("name")

    rows = [
        calculate_day_metrics(employee, selected_date)
        for employee in employees
    ]

    attention_rows = [row for row in rows if row["attention"]]

    currently_working = sum(
        1 for row in rows if row["status"] in ["Currently working", "Back from break"]
    )

    on_break = sum(
        1 for row in rows if row["status"] == "On break"
    )

    break_issues = sum(
        1 for row in rows if "Break" in row["compliance"] or "break" in row["compliance"]
    )

    return render(request, "compliance_dashboard.html", {
        "selected_date": selected_date,
        "rows": rows,
        "attention_rows": attention_rows,
        "currently_working": currently_working,
        "on_break": on_break,
        "requiring_attention": len(attention_rows),
        "break_issues": break_issues,
    })


def _mins(start_dt, end_dt):
    return max(0, int((end_dt - start_dt).total_seconds() / 60))


def _break_required(worked_minutes):
    if worked_minutes > 360:
        return 30
    if worked_minutes > 270:
        return 15
    return 0


def _staff_day_status(employee, selected_date):
    events = ClockEvent.objects.filter(employee=employee, timestamp__date=selected_date).order_by("timestamp")
    shifts = RosterShift.objects.filter(employee=employee, shift_date=selected_date).order_by("start_time")

    roster_text = "Not rostered"
    planned_start = None

    if shifts.exists():
        parts = []
        for shift in shifts:
            parts.append(f"{shift.start_time.strftime('%H:%M')} - {shift.end_time.strftime('%H:%M')}")
            if planned_start is None or shift.start_time < planned_start:
                planned_start = shift.start_time
        roster_text = ", ".join(parts)

    first_in = None
    last_out = None
    latest_event = events.last()

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
                worked_minutes += _mins(work_start, event.timestamp)
                work_start = None
            else:
                invalid_sequence = True
            break_start = event.timestamp

        elif event.clock_type == "BREAK_END":
            if break_start is not None:
                break_minutes += _mins(break_start, event.timestamp)
                break_start = None
            else:
                invalid_sequence = True
            work_start = event.timestamp

        elif event.clock_type == "OUT":
            last_out = event.timestamp
            if work_start is not None:
                worked_minutes += _mins(work_start, event.timestamp)
                work_start = None
            elif break_start is not None:
                break_minutes += _mins(break_start, event.timestamp)
                break_start = None
            else:
                invalid_sequence = True

    now = timezone.now()
    if selected_date == timezone.localdate():
        if work_start is not None:
            worked_minutes += _mins(work_start, now)
        elif break_start is not None:
            break_minutes += _mins(break_start, now)

    status = "No activity"
    if latest_event:
        if latest_event.clock_type == "IN":
            status = "Working now"
        elif latest_event.clock_type == "BREAK_START":
            status = "On break"
        elif latest_event.clock_type == "BREAK_END":
            status = "Back from break"
        elif latest_event.clock_type == "OUT":
            status = "Clocked out"

    required_break = _break_required(worked_minutes)
    issues = []

    if invalid_sequence:
        issues.append("Check clock sequence")
    if shifts.exists() and not latest_event:
        issues.append("Rostered but no clock-in")
    if latest_event and not shifts.exists():
        issues.append("Worked but not rostered")
    if latest_event and latest_event.clock_type == "IN" and required_break > 0 and break_minutes == 0:
        issues.append("Break due / overdue")
    if latest_event and latest_event.clock_type == "OUT" and required_break > 0 and break_minutes < required_break:
        issues.append("Break missing or too short")
    if planned_start and not first_in and selected_date == timezone.localdate():
        planned_dt = timezone.make_aware(datetime.combine(selected_date, planned_start))
        if now > planned_dt + timedelta(minutes=10):
            issues.append("Late / not arrived")
    if first_in and planned_start:
        planned_dt = timezone.make_aware(datetime.combine(selected_date, planned_start))
        if first_in > planned_dt + timedelta(minutes=10):
            issues.append("Arrived late")

    issue_text = "; ".join(issues) if issues else "OK"

    return {
        "employee_number": employee.employee_number,
        "employee": employee.name,
        "roster": roster_text,
        "first_in": first_in.strftime("%H:%M") if first_in else "-",
        "last_out": last_out.strftime("%H:%M") if last_out else "-",
        "status": status,
        "worked_hours": round(worked_minutes / 60, 2),
        "break_minutes": break_minutes,
        "paid_hours": round(worked_minutes / 60, 2),
        "required_break": required_break,
        "issue": issue_text,
        "needs_attention": issue_text != "OK",
        "is_working": status in ["Working now", "Back from break"],
        "is_on_break": status == "On break",
        "is_clocked_out": status == "Clocked out",
        "has_activity": latest_event is not None,
        "rostered": shifts.exists(),
    }


def manager_today_dashboard(request):
    selected_date_str = request.GET.get("date", timezone.localdate().strftime("%Y-%m-%d"))
    selected_date = datetime.strptime(selected_date_str, "%Y-%m-%d").date()

    employees = Employee.objects.filter(active=True).order_by("name")
    rows = [_staff_day_status(employee, selected_date) for employee in employees]

    attention_rows = [row for row in rows if row["needs_attention"]]
    working_rows = [row for row in rows if row["is_working"]]

    return render(request, "manager_today.html", {
        "selected_date": selected_date,
        "rows": rows,
        "attention_rows": attention_rows,
        "working_rows": working_rows,
        "rostered_count": sum(1 for row in rows if row["rostered"]),
        "currently_working": len(working_rows),
        "on_break": sum(1 for row in rows if row["is_on_break"]),
        "clocked_out": sum(1 for row in rows if row["is_clocked_out"]),
        "need_attention": len(attention_rows),
    })


# -------------------------------------------------------------------
# Payroll upgrade: paid hours, unpaid breaks, Sunday hours and Sage CSV
# -------------------------------------------------------------------

def _event_day_metrics(employee, selected_date):
    events = ClockEvent.objects.filter(
        employee=employee,
        timestamp__date=selected_date
    ).order_by("timestamp")

    worked_minutes = 0
    break_minutes = 0
    invalid_sequence = False
    work_start = None
    break_start = None

    for event in events:
        if event.clock_type == "IN":
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
            if work_start is not None:
                worked_minutes += int((event.timestamp - work_start).total_seconds() / 60)
                work_start = None
            elif break_start is not None:
                break_minutes += int((event.timestamp - break_start).total_seconds() / 60)
                break_start = None
            else:
                invalid_sequence = True

    missing_clock_out = work_start is not None or break_start is not None
    paid_minutes = worked_minutes

    return {
        "worked_minutes": worked_minutes,
        "break_minutes": break_minutes,
        "paid_minutes": paid_minutes,
        "missing_clock_out": missing_clock_out,
        "invalid_sequence": invalid_sequence,
    }


def _rostered_minutes_for_week(employee, week_start, week_end):
    shifts = RosterShift.objects.filter(
        employee=employee,
        shift_date__range=[week_start, week_end]
    )

    total = 0

    for shift in shifts:
        start_dt = datetime.combine(shift.shift_date, shift.start_time)
        end_dt = datetime.combine(shift.shift_date, shift.end_time)

        if end_dt <= start_dt:
            end_dt += timedelta(days=1)

        total += int((end_dt - start_dt).total_seconds() / 60)
        total -= shift.break_minutes

    return total


def manager_weekly_summary(request):
    week_start_str = request.GET.get("week_start", "2026-06-15")
    week_start = datetime.strptime(week_start_str, "%Y-%m-%d").date()
    week_end = week_start + timedelta(days=6)

    standard_hours = float(request.GET.get("standard_hours", "39"))
    standard_minutes = int(standard_hours * 60)

    employees = Employee.objects.filter(active=True).order_by("name")
    summary_rows = []

    for employee in employees:
        rostered_minutes = _rostered_minutes_for_week(employee, week_start, week_end)

        worked_minutes = 0
        break_minutes = 0
        paid_minutes = 0
        sunday_minutes = 0
        warnings = []

        for i in range(7):
            day = week_start + timedelta(days=i)
            metrics = _event_day_metrics(employee, day)

            worked_minutes += metrics["worked_minutes"]
            break_minutes += metrics["break_minutes"]
            paid_minutes += metrics["paid_minutes"]

            if day.weekday() == 6:
                sunday_minutes += metrics["paid_minutes"]

            if metrics["missing_clock_out"]:
                warnings.append(f"{day}: missing clock-out")
            if metrics["invalid_sequence"]:
                warnings.append(f"{day}: check clock sequence")

        overtime_minutes = max(0, paid_minutes - standard_minutes)
        normal_minutes = max(0, paid_minutes - overtime_minutes - sunday_minutes)

        if rostered_minutes > 0 and paid_minutes == 0:
            warnings.append("No clock events for rostered week")

        difference_minutes = paid_minutes - rostered_minutes

        summary_rows.append({
            "employee": employee.name,
            "employee_number": employee.employee_number,
            "rostered_hours": round(rostered_minutes / 60, 2),
            "worked_hours": round(worked_minutes / 60, 2),
            "break_hours": round(break_minutes / 60, 2),
            "paid_hours": round(paid_minutes / 60, 2),
            "normal_hours": round(normal_minutes / 60, 2),
            "sunday_hours": round(sunday_minutes / 60, 2),
            "overtime_hours": round(overtime_minutes / 60, 2),
            "difference": round(difference_minutes / 60, 2),
            "warning": "; ".join(warnings) if warnings else "OK",
        })

    return render(request, "weekly_summary.html", {
        "week_start": week_start,
        "week_end": week_end,
        "summary_rows": summary_rows,
        "standard_hours": standard_hours,
    })


def export_sage_payroll_csv(request):
    week_start_str = request.GET.get("week_start", "2026-06-15")
    period_number = request.GET.get("period", "1")
    standard_hours = float(request.GET.get("standard_hours", "39"))

    week_start = datetime.strptime(week_start_str, "%Y-%m-%d").date()
    week_end = week_start + timedelta(days=6)
    standard_minutes = int(standard_hours * 60)

    response = HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = 'attachment; filename="sage_payroll_export.csv"'

    writer = csv.writer(response)

    # Sage Payroll Ireland-style timesheet import:
    # PeriodNumber, EmployeeNumber, 0000, Payment1, Payment2, Payment3
    # Payment1 = normal hours, Payment2 = Sunday hours, Payment3 = overtime hours
    writer.writerow([
        "PeriodNumber",
        "EmployeeNumber",
        "0000",
        "NormalHours",
        "SundayHours",
        "OvertimeHours",
    ])

    employees = Employee.objects.filter(active=True).order_by("name")

    for employee in employees:
        paid_minutes = 0
        sunday_minutes = 0

        for i in range(7):
            day = week_start + timedelta(days=i)
            metrics = _event_day_metrics(employee, day)
            paid_minutes += metrics["paid_minutes"]

            if day.weekday() == 6:
                sunday_minutes += metrics["paid_minutes"]

        overtime_minutes = max(0, paid_minutes - standard_minutes)
        normal_minutes = max(0, paid_minutes - overtime_minutes - sunday_minutes)

        if paid_minutes == 0:
            continue

        writer.writerow([
            period_number,
            employee.employee_number,
            "0000",
            round(normal_minutes / 60, 2),
            round(sunday_minutes / 60, 2),
            round(overtime_minutes / 60, 2),
        ])

    return response


# -------------------------------------------------------------------
# Manager issue classification: urgent vs operational
# -------------------------------------------------------------------

def _format_minutes(minutes):
    if minutes < 60:
        return f"{minutes} mins"
    hours = minutes // 60
    mins = minutes % 60
    if mins == 0:
        return f"{hours}h"
    return f"{hours}h {mins}m"


def _manager_issue_rows(selected_date):
    rows = []

    for employee in Employee.objects.filter(active=True).order_by("name"):
        events = ClockEvent.objects.filter(
            employee=employee,
            timestamp__date=selected_date
        ).order_by("timestamp")

        shifts = RosterShift.objects.filter(
            employee=employee,
            shift_date=selected_date
        ).order_by("start_time")

        rostered = shifts.exists()
        roster_text = "Not rostered"
        planned_start = None
        planned_end = None

        if rostered:
            parts = []
            for shift in shifts:
                parts.append(f"{shift.start_time.strftime('%H:%M')} - {shift.end_time.strftime('%H:%M')}")
                if planned_start is None or shift.start_time < planned_start:
                    planned_start = shift.start_time
                if planned_end is None or shift.end_time > planned_end:
                    planned_end = shift.end_time
            roster_text = ", ".join(parts)

        first_in = None
        last_out = None
        latest_event = events.last()

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
                    invalid_sequence = True

        now = timezone.now()

        # Live time if currently working or currently on break
        if selected_date == timezone.localdate():
            if work_start is not None:
                worked_minutes += int((now - work_start).total_seconds() / 60)
            elif break_start is not None:
                break_minutes += int((now - break_start).total_seconds() / 60)

        status = "No activity"
        if latest_event:
            if latest_event.clock_type == "IN":
                status = "Working now"
            elif latest_event.clock_type == "BREAK_START":
                status = "On break"
            elif latest_event.clock_type == "BREAK_END":
                status = "Back from break"
            elif latest_event.clock_type == "OUT":
                status = "Clocked out"

        required_break = 0
        if worked_minutes > 360:
            required_break = 30
        elif worked_minutes > 270:
            required_break = 15

        urgent_issues = []
        operational_issues = []

        if invalid_sequence:
            urgent_issues.append("Check clock sequence")

        if latest_event and not rostered:
            urgent_issues.append("Working but not rostered")

        if rostered and not latest_event and selected_date == timezone.localdate() and planned_start:
            planned_dt = timezone.make_aware(datetime.combine(selected_date, planned_start))
            if now > planned_dt + timedelta(minutes=30):
                urgent_issues.append("Rostered but absent")
            elif now > planned_dt + timedelta(minutes=10):
                operational_issues.append("Late / not arrived")

        if latest_event and latest_event.clock_type in ["IN", "BREAK_END"]:
            if required_break > 0 and break_minutes < required_break:
                urgent_issues.append(
                    f"Worked {_format_minutes(worked_minutes)} with only {break_minutes} mins break"
                )

        if latest_event and latest_event.clock_type == "OUT":
            if required_break > 0 and break_minutes < required_break:
                urgent_issues.append("Break missing or too short")

        if latest_event and latest_event.clock_type in ["IN", "BREAK_START", "BREAK_END"]:
            if planned_end and selected_date < timezone.localdate():
                urgent_issues.append("Missing clock-out")

        if first_in and planned_start:
            planned_dt = timezone.make_aware(datetime.combine(selected_date, planned_start))
            late_minutes = int((first_in - planned_dt).total_seconds() / 60)
            if late_minutes > 10:
                operational_issues.append(f"Late by {late_minutes} mins")

        issue_type = "OK"
        issue_text = "OK"

        if urgent_issues:
            issue_type = "Urgent"
            issue_text = "; ".join(urgent_issues)
        elif operational_issues:
            issue_type = "Operational"
            issue_text = "; ".join(operational_issues)

        rows.append({
            "employee_number": employee.employee_number,
            "employee": employee.name,
            "roster": roster_text,
            "first_in": first_in.strftime("%H:%M") if first_in else "-",
            "last_out": last_out.strftime("%H:%M") if last_out else "-",
            "status": status,
            "worked_hours": round(worked_minutes / 60, 2),
            "break_minutes": break_minutes,
            "paid_hours": round(worked_minutes / 60, 2),
            "issue_type": issue_type,
            "issue": issue_text,
            "is_urgent": issue_type == "Urgent",
            "is_operational": issue_type == "Operational",
            "is_working": status in ["Working now", "Back from break"],
            "is_on_break": status == "On break",
            "is_clocked_out": status == "Clocked out",
            "has_activity": latest_event is not None,
            "rostered": rostered,
        })

    return rows


def manager_today_dashboard(request):
    selected_date_str = request.GET.get(
        "date",
        timezone.localdate().strftime("%Y-%m-%d")
    )
    selected_date = datetime.strptime(selected_date_str, "%Y-%m-%d").date()

    rows = _manager_issue_rows(selected_date)

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


# -------------------------------------------------------------------
# Unified calculation engine override
# Uses core/compliance.py so dashboard, weekly summary, email alerts
# and Sage export all agree.
# -------------------------------------------------------------------

from core.compliance import get_day_rows, get_week_rows


def manager_today_dashboard(request):
    selected_date_str = request.GET.get(
        "date",
        timezone.localdate().strftime("%Y-%m-%d")
    )
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


def manager_weekly_summary(request):
    week_start_str = request.GET.get("week_start", "2026-06-15")
    week_start = datetime.strptime(week_start_str, "%Y-%m-%d").date()
    week_end = week_start + timedelta(days=6)
    standard_hours = float(request.GET.get("standard_hours", "39"))

    summary_rows = get_week_rows(week_start, standard_hours)

    return render(request, "weekly_summary.html", {
        "week_start": week_start,
        "week_end": week_end,
        "summary_rows": summary_rows,
        "standard_hours": standard_hours,
    })


def export_sage_payroll_csv(request):
    week_start_str = request.GET.get("week_start", "2026-06-15")
    period_number = request.GET.get("period", "1")
    standard_hours = float(request.GET.get("standard_hours", "39"))

    week_start = datetime.strptime(week_start_str, "%Y-%m-%d").date()
    rows = get_week_rows(week_start, standard_hours)

    response = HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = 'attachment; filename="sage_payroll_export.csv"'

    writer = csv.writer(response)

    writer.writerow([
        "PeriodNumber",
        "EmployeeNumber",
        "0000",
        "NormalHours",
        "SundayHours",
        "OvertimeHours",
    ])

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


# -------------------------------------------------------------------
# Manager Operations Homepage
# -------------------------------------------------------------------

from core.compliance import get_day_rows, get_week_rows


def home_page(request):
    today = timezone.localdate()
    week_start = today - timedelta(days=today.weekday())

    rows = get_day_rows(today)
    week_rows = get_week_rows(week_start, 39)

    rostered_now = 0
    clocked_in_now = 0
    missing_now = []

    now_time = timezone.localtime().time()

    for row in rows:
        if row["rostered"] and row["roster"] != "Not rostered":
            # Simple approximation for MVP: count rostered staff with activity/working status
            rostered_now += 1

            if row["is_working"] or row["is_on_break"]:
                clocked_in_now += 1
            elif not row["has_activity"]:
                missing_now.append(row["employee"])

    urgent_rows = [row for row in rows if row["is_urgent"]]
    operational_rows = [row for row in rows if row["is_operational"]]

    payroll_problem_rows = [
        row for row in week_rows
        if row["warning"] != "OK"
    ]

    total_staff = len(rows)
    urgent_count = len(urgent_rows)
    operational_count = len(operational_rows)
    payroll_problem_count = len(payroll_problem_rows)

    if total_staff > 0:
        health_score = int(((total_staff - urgent_count) / total_staff) * 100)
    else:
        health_score = 100

    return render(request, "home.html", {
        "today": today,
        "week_start": week_start,
        "rows": rows,
        "urgent_rows": urgent_rows[:5],
        "operational_rows": operational_rows[:5],
        "rostered_count": sum(1 for row in rows if row["rostered"]),
        "currently_working": sum(1 for row in rows if row["is_working"]),
        "on_break": sum(1 for row in rows if row["is_on_break"]),
        "clocked_out": sum(1 for row in rows if row["is_clocked_out"]),
        "urgent_count": urgent_count,
        "operational_count": operational_count,
        "health_score": health_score,
        "payroll_problem_count": payroll_problem_count,
        "rostered_now": rostered_now,
        "clocked_in_now": clocked_in_now,
        "missing_now": missing_now[:5],
    })


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
