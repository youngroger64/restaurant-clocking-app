import csv
from datetime import datetime, timedelta

from django.shortcuts import render
from django.http import HttpResponse
from django.utils import timezone

from .models import Employee, ClockEvent, RosterShift


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
                    method="QR",
        notes="",
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
            method="TEST",
        notes="",
    )

        ClockEvent.objects.create(
            employee=shift.employee,
            clock_type="OUT",
            timestamp=clock_out_time,
            method="TEST",
        notes="",
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

    rows = get_day_rows(selected_date)

    urgent_rows = [row for row in rows if row["is_urgent"]]
    operational_rows = [row for row in rows if row["is_operational"]]
    working_rows = [row for row in rows if row["is_working"]]
    needs_attention_rows = urgent_rows + operational_rows

    late_count = sum(
        1 for row in needs_attention_rows
        if "late" in row.get("issue", "").lower()
    )

    not_arrived_count = sum(
        1 for row in needs_attention_rows
        if (
            "not arrived" in row.get("issue", "").lower()
            or "absent" in row.get("issue", "").lower()
            or "no clock-in" in row.get("issue", "").lower()
        )
    )

    payroll_issues_count = len(urgent_rows)
    rostered_count = sum(1 for row in rows if row["rostered"])
    payroll_ready = 100
    if rostered_count > 0:
        payroll_ready = max(0, min(100, round(((rostered_count - payroll_issues_count) / rostered_count) * 100)))


    return render(request, "manager_today.html", {
        "selected_date": selected_date,
        "rows": rows,
        "urgent_rows": urgent_rows,
        "operational_rows": operational_rows,
        "working_rows": working_rows,
        "needs_attention_rows": needs_attention_rows,
        "late_count": late_count,
        "not_arrived_count": not_arrived_count,
        "payroll_issues_count": payroll_issues_count,
        "payroll_ready": payroll_ready,
        "rostered_count": rostered_count,
        "currently_working": len(working_rows),
        "on_break": sum(1 for row in rows if row["is_on_break"]),
        "clocked_out": sum(1 for row in rows if row["is_clocked_out"]),
        "urgent_count": len(urgent_rows),
        "operational_count": len(operational_rows),
    })


def _latest_today_event(employee):
    return ClockEvent.objects.filter(
        employee=employee,
        timestamp__date=timezone.localdate()
    ).order_by("-timestamp").first()


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


# -------------------------------------------------------------------
# Manager Operations Homepage
# -------------------------------------------------------------------

from core.compliance import get_day_rows, get_week_rows


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
                    method="MANAGER",
        notes="",
    )

                message = f"Added {clock_type} for {employee.name} at {event_time}."

            except Exception as e:
                message = f"Could not add event: {e}"


        elif action == "delete_selected":
            ids = request.POST.getlist("selected_events")
            if not ids:
                message = "No events selected."
            else:
                qs = ClockEvent.objects.filter(id__in=ids, timestamp__date=selected_date)
                count = qs.count()
                qs.delete()
                message = f"Deleted {count} selected event(s)."

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
    # Restaurant Operations Dashboard.
    # Manager logic:
    # 1) Who is physically working/on break now?
    # 2) What happened to today's roster?
    # 3) What needs manager review?
    from core.compliance import get_day_rows, get_week_rows

    today = timezone.localdate()
    now_dt = timezone.localtime()
    now_time = now_dt.time()
    week_start = today - timedelta(days=today.weekday())

    rows = get_day_rows(today)
    week_rows = get_week_rows(week_start, 39)

    roster_shifts_today = RosterShift.objects.select_related("employee").filter(
        shift_date=today
    ).order_by("start_time", "employee__name")

    later_employee_numbers = set()
    current_employee_numbers = set()
    finished_employee_numbers = set()

    for shift in roster_shifts_today:
        emp_no = str(shift.employee.employee_number)

        if shift.start_time <= shift.end_time:
            if shift.start_time <= now_time <= shift.end_time:
                current_employee_numbers.add(emp_no)
            elif now_time < shift.start_time:
                later_employee_numbers.add(emp_no)
            else:
                finished_employee_numbers.add(emp_no)
        else:
            if now_time >= shift.start_time or now_time <= shift.end_time:
                current_employee_numbers.add(emp_no)
            elif now_time < shift.start_time:
                later_employee_numbers.add(emp_no)
            else:
                finished_employee_numbers.add(emp_no)

    roster_rows = [row for row in rows if row.get("rostered")]
    live_rows = [row for row in rows if row.get("is_working") or row.get("is_on_break")]

    for row in rows:
        emp_no = str(row.get("employee_number"))
        issue = row.get("issue") or ""
        issue_l = issue.lower()
        status = row.get("status") or ""

        if row.get("is_on_break"):
            row["manager_status"] = "On Break"
            row["manager_status_class"] = "orange"
        elif row.get("is_working") or status == "Back from break":
            row["manager_status"] = "Working"
            row["manager_status_class"] = "green"
        elif emp_no in later_employee_numbers and not row.get("has_activity"):
            row["manager_status"] = "Due Later"
            row["manager_status_class"] = "blue"
        elif emp_no in current_employee_numbers and not row.get("has_activity"):
            row["manager_status"] = "Not Arrived"
            row["manager_status_class"] = "red"
        elif emp_no in finished_employee_numbers and not row.get("has_activity"):
            row["manager_status"] = "Didn't Clock In"
            row["manager_status_class"] = "red"
        elif row.get("has_activity") or status == "Clocked out":
            row["manager_status"] = "Finished Shift"
            row["manager_status_class"] = "blue"
        else:
            row["manager_status"] = "No Clock Records"
            row["manager_status_class"] = "red"

        if "rostered but absent" in issue_l:
            row["manager_issue"] = "Didn't clock in for shift"
        elif "working but not rostered" in issue_l:
            row["manager_issue"] = "Worked without matching roster shift"
        elif issue == "OK":
            row["manager_issue"] = ""
        else:
            row["manager_issue"] = issue

        if "working but not rostered" in issue_l or "not rostered" in issue_l:
            row["manager_issue_type"] = "Roster"
            row["manager_issue_type_class"] = "blue"
        elif "rostered but absent" in issue_l or "not arrived" in issue_l or "late" in issue_l:
            row["manager_issue_type"] = "Attendance"
            row["manager_issue_type_class"] = "orange"
        elif "clock" in issue_l or "break" in issue_l:
            row["manager_issue_type"] = "Clocking"
            row["manager_issue_type_class"] = "red"
        else:
            row["manager_issue_type"] = "Operational"
            row["manager_issue_type_class"] = "orange"

    needs_attention_rows = []
    for row in rows:
        issue_l = (row.get("issue") or "").lower()
        emp_no = str(row.get("employee_number"))

        include = False
        if "working but not rostered" in issue_l or "not rostered" in issue_l:
            include = True
        elif "check clock sequence" in issue_l or "missing clock" in issue_l or "open break" in issue_l:
            include = True
        elif "late" in issue_l:
            include = True
        elif ("rostered but absent" in issue_l or "not arrived" in issue_l) and emp_no in current_employee_numbers:
            include = True

        if include:
            needs_attention_rows.append(row)

    payroll_blockers = []
    for row in week_rows:
        warning = (row.get("warning") or "").lower()
        if row.get("warning") == "OK":
            continue
        if "rostered but absent" in warning or "working but not rostered" in warning or "not rostered" in warning:
            continue
        payroll_blockers.append(row)

    return render(request, "home.html", {
        "today": today,
        "now_time": now_dt,
        "week_start": week_start,
        "rows": rows,
        "roster_rows": roster_rows,
        "live_rows": live_rows,
        "needs_attention_rows": needs_attention_rows[:10],
        "rostered_today_count": len(roster_rows),
        "working_now_count": sum(1 for row in live_rows if row.get("is_working")),
        "on_break_count": sum(1 for row in live_rows if row.get("is_on_break")),
        "not_arrived_now_count": sum(1 for row in roster_rows if row.get("manager_status") == "Not Arrived"),
        "payroll_blocker_count": len(payroll_blockers),
    })



# -------------------------------------------------------------------
# Delivery patch 01: row-level payroll corrections + safer payroll export
# -------------------------------------------------------------------

from django.contrib.auth.decorators import login_required as _patch_login_required
from django.shortcuts import get_object_or_404 as _patch_get_object_or_404
from django.http import HttpResponseRedirect as _patch_HttpResponseRedirect
from core.compliance import calculate_employee_day as _patch_calculate_employee_day
from core.compliance import get_week_rows as _patch_get_week_rows


def _patch_current_week_start():
    today = timezone.localdate()
    return today - timedelta(days=today.weekday())


def _patch_parse_week_start(request):
    raw = request.GET.get("week_start") or request.POST.get("week_start")
    if raw:
        return datetime.strptime(raw, "%Y-%m-%d").date()
    return _patch_current_week_start()


@_patch_login_required
def manager_fix_day(request):
    emp_no = request.GET.get("employee_number") or request.POST.get("employee_number")
    date_raw = request.GET.get("event_date") or request.POST.get("event_date")
    week_start = _patch_parse_week_start(request)

    if not emp_no or not date_raw:
        return render(request, "manager_fix_day.html", {
            "error": "Missing employee number or date.",
            "employee": None,
            "event_date": None,
            "events": [],
            "day": {},
            "week_start": week_start,
        })

    employee = _patch_get_object_or_404(Employee, employee_number=emp_no)
    event_date = datetime.strptime(date_raw, "%Y-%m-%d").date()
    message = ""
    error = ""

    if request.method == "POST":
        mode = request.POST.get("mode")

        if mode == "add":
            clock_type = request.POST.get("clock_type")
            event_time = request.POST.get("event_time")
            reason = (request.POST.get("reason") or "").strip()

            if clock_type not in ["IN", "BREAK_START", "BREAK_END", "OUT"]:
                error = "Invalid event type."
            elif not reason:
                error = "A correction reason is required."
            else:
                naive_dt = datetime.strptime(f"{event_date} {event_time}", "%Y-%m-%d %H:%M")
                event_dt = timezone.make_aware(naive_dt)
                ClockEvent.objects.create(
                    employee=employee,
                    clock_type=clock_type,
                    timestamp=event_dt,
                    method="MANAGER",
                    notes=f"Manager correction: {reason}",
                )
                message = f"Added {clock_type} for {employee.name} at {event_time}."


        elif mode == "delete_selected":
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

        elif mode == "delete":
            event_id = request.POST.get("event_id")
            event = _patch_get_object_or_404(ClockEvent, id=event_id, employee=employee, timestamp__date=event_date)
            old = f"{timezone.localtime(event.timestamp).strftime('%H:%M')} {event.clock_type}"
            event.delete()
            message = f"Deleted event: {old}."

    events = list(ClockEvent.objects.filter(employee=employee, timestamp__date=event_date).order_by("timestamp"))
    for event in events:
        event.local_time = timezone.localtime(event.timestamp).strftime("H:%M").replace("H", "%H") if False else timezone.localtime(event.timestamp).strftime("%H:%M")

    day = _patch_calculate_employee_day(employee, event_date, include_live=True)

    return render(request, "manager_fix_day.html", {
        "employee": employee,
        "event_date": event_date,
        "events": events,
        "day": day,
        "message": message,
        "error": error,
        "week_start": week_start,
    })


@_patch_login_required
def payroll_problems(request):
    # Manager-focused issue review.
    # Not every issue is a payroll blocker.
    from core.compliance import get_week_rows

    week_start = _patch_parse_week_start(request)
    week_end = week_start + timedelta(days=6)

    rows = get_week_rows(week_start, 39)
    issue_rows = [row for row in rows if row.get("warning") != "OK"]

    payroll_blockers = []
    attendance_issues = []
    roster_exceptions = []

    for row in issue_rows:
        issue = row.get("warning") or row.get("issue") or ""
        issue_l = issue.lower()
        row["issue_text"] = issue

        if (
            "rostered but absent" in issue_l
            or "not arrived" in issue_l
            or "didn't clock in" in issue_l
            or "did not clock in" in issue_l
        ):
            row["category"] = "Attendance"
            row["manager_explanation"] = "This affects staffing, but payroll can calculate 0 worked hours unless leave is paid."
            attendance_issues.append(row)

        elif (
            "working but not rostered" in issue_l
            or "not rostered" in issue_l
        ):
            row["category"] = "Roster Exception"
            row["manager_explanation"] = "The hours can be calculated, but the manager should confirm this was approved cover or add it to the roster."
            roster_exceptions.append(row)

        else:
            row["category"] = "Payroll"
            row["manager_explanation"] = "Clock records need review before payroll export."
            payroll_blockers.append(row)

    return render(request, "payroll_problems.html", {
        "week_start": week_start,
        "week_end": week_end,
        "rows": issue_rows,
        "payroll_blockers": payroll_blockers,
        "attendance_issues": attendance_issues,
        "roster_exceptions": roster_exceptions,
        "payroll_blocker_count": len(payroll_blockers),
        "attendance_issue_count": len(attendance_issues),
        "roster_exception_count": len(roster_exceptions),
        "total_issue_count": len(issue_rows),
    })



def manager_weekly_summary(request):
    week_start = _patch_parse_week_start(request)
    week_end = week_start + timedelta(days=6)
    standard_hours = float(request.GET.get("standard_hours", "39"))
    summary_rows = _patch_get_week_rows(week_start, standard_hours)

    unresolved = [row for row in summary_rows if row.get("warning") != "OK"]

    return render(request, "weekly_summary.html", {
        "week_start": week_start,
        "week_end": week_end,
        "summary_rows": summary_rows,
        "standard_hours": standard_hours,
        "unresolved_problem_count": len(unresolved),
    })


@_patch_login_required
def export_sage_payroll_csv(request):
    week_start = _patch_parse_week_start(request)
    week_end = week_start + timedelta(days=6)
    period_number = request.GET.get("period", "1")
    standard_hours = float(request.GET.get("standard_hours", "39"))
    include_header = request.GET.get("include_header") == "1"
    force_export = request.GET.get("force") == "1"
    rows = _patch_get_week_rows(week_start, standard_hours)

    unresolved_rows = [row for row in rows if row.get("warning") != "OK"]

    # Production safety: do not silently export payroll when the manager still has
    # warnings to review. The manager can still force an export, but only after
    # seeing a clear warning page.
    if unresolved_rows and not force_export:
        return render(request, "sage_export_review.html", {
            "week_start": week_start,
            "week_end": week_end,
            "period_number": period_number,
            "standard_hours": standard_hours,
            "unresolved_rows": unresolved_rows,
            "unresolved_count": len(unresolved_rows),
        })

    filename = f"sage_payroll_{week_start.strftime('%Y_%m_%d')}.csv"
    response = HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = f'attachment; filename="{filename}"'
    writer = csv.writer(response)

    # Sage Payroll IE single-timesheet import order:
    # period number, employee number, 0000, payment element 1, payment element 2, payment element 3.
    # Header is OFF by default because Sage imports usually expect raw rows only.
    if include_header:
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

# Final manager view protection - must stay at end
manager_today_dashboard = login_required(manager_today_dashboard)
upload_roster = login_required(upload_roster)
manager_weekly_summary = login_required(manager_weekly_summary)
manager_daily_monitor = login_required(manager_daily_monitor)
payroll_problems = login_required(payroll_problems)
manager_add_missing_event = login_required(manager_add_missing_event)
export_sage_payroll_csv = login_required(export_sage_payroll_csv)
manager_corrections = login_required(manager_corrections)
manager_fix_day = login_required(manager_fix_day)
export_clock_events_csv = login_required(export_clock_events_csv)


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

# -------------------------------------------------------------------
# Patch 16: safer roster manager upload
# Replaces roster shifts for the selected/imported week and redirects
# back to the roster manager so the uploaded roster is visible.
# -------------------------------------------------------------------

from django.contrib.auth.decorators import login_required as _patch16_login_required
from django.shortcuts import redirect as _patch16_redirect


def _patch16_parse_date(value):
    value = (value or "").strip()
    for fmt in ("%Y-%m-%d", "%d/%m/%Y", "%d-%m-%Y"):
        try:
            return datetime.strptime(value, fmt).date()
        except ValueError:
            pass
    raise ValueError(f"Invalid date format: {value}. Use YYYY-MM-DD.")


def _patch16_parse_time(value):
    value = (value or "").strip()
    for fmt in ("%H:%M", "%H:%M:%S"):
        try:
            return datetime.strptime(value, fmt).time()
        except ValueError:
            pass
    raise ValueError(f"Invalid time format: {value}. Use HH:MM.")


def _patch16_week_start_for_date(day):
    return day - timedelta(days=day.weekday())


@_patch16_login_required
def roster_manager(request):
    message = ""
    error = ""

    raw_week_start = request.GET.get("week_start") or request.POST.get("week_start")
    if raw_week_start:
        week_start = datetime.strptime(raw_week_start, "%Y-%m-%d").date()
    else:
        week_start = timezone.localdate() - timedelta(days=timezone.localdate().weekday())

    # CSV upload: replace the roster for the detected/selected week.
    if request.method == "POST" and request.FILES.get("roster_file"):
        roster_file = request.FILES["roster_file"]

        try:
            decoded_file = roster_file.read().decode("utf-8-sig").splitlines()
            reader = csv.DictReader(decoded_file)

            required = {"EmployeeNumber", "EmployeeName", "Date", "StartTime", "EndTime"}
            missing = required - set(reader.fieldnames or [])
            if missing:
                raise ValueError("Missing CSV columns: " + ", ".join(sorted(missing)))

            parsed_rows = []
            for row in reader:
                shift_date = _patch16_parse_date(row.get("Date"))
                parsed_rows.append({
                    "employee_number": (row.get("EmployeeNumber") or "").strip(),
                    "employee_name": (row.get("EmployeeName") or "").strip(),
                    "shift_date": shift_date,
                    "start_time": _patch16_parse_time(row.get("StartTime")),
                    "end_time": _patch16_parse_time(row.get("EndTime")),
                    "break_minutes": int((row.get("BreakMinutes") or "0").strip() or "0"),
                })

            if not parsed_rows:
                raise ValueError("CSV contained no roster rows.")

            # Use the week of the first imported shift unless a week_start was explicitly supplied.
            if not raw_week_start:
                week_start = _patch16_week_start_for_date(parsed_rows[0]["shift_date"])

            week_end = week_start + timedelta(days=6)

            # Replace roster shifts for this week only. Do not delete clock events.
            RosterShift.objects.filter(
                shift_date__gte=week_start,
                shift_date__lte=week_end,
            ).delete()

            count = 0
            for row in parsed_rows:
                employee, _created = Employee.objects.get_or_create(
                    employee_number=row["employee_number"],
                    defaults={
                        "name": row["employee_name"] or row["employee_number"],
                        "pin": row["employee_number"],
                        "active": True,
                    }
                )

                # Keep employee name fresh if CSV has a better name.
                if row["employee_name"] and employee.name != row["employee_name"]:
                    employee.name = row["employee_name"]
                    employee.save()

                RosterShift.objects.create(
                    employee=employee,
                    shift_date=row["shift_date"],
                    start_time=row["start_time"],
                    end_time=row["end_time"],
                    break_minutes=row["break_minutes"],
                )
                count += 1

            return _patch16_redirect(f"/manager/upload-roster/?week_start={week_start.isoformat()}&uploaded={count}")

        except Exception as exc:
            error = f"Roster upload failed: {exc}"

    uploaded = request.GET.get("uploaded")
    if uploaded:
        message = f"Uploaded {uploaded} roster shift(s). Existing roster shifts for this week were replaced."

    week_end = week_start + timedelta(days=6)
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
        "message": message,
        "error": error,
    })

# -------------------------------------------------------------------
# Patch 21: manager-facing Today Dashboard
# Keeps status wording consistent across dashboard pages.
# -------------------------------------------------------------------

def manager_today_dashboard(request):
    from core.compliance import get_day_rows, get_week_rows

    raw_date = request.GET.get("date")
    if raw_date:
        selected_date = datetime.strptime(raw_date, "%Y-%m-%d").date()
    else:
        selected_date = timezone.localdate()

    today = timezone.localdate()
    now_dt = timezone.localtime()
    now_time = now_dt.time()
    week_start = selected_date - timedelta(days=selected_date.weekday())

    rows = get_day_rows(selected_date)
    week_rows = get_week_rows(week_start, 39)

    roster_shifts = RosterShift.objects.select_related("employee").filter(
        shift_date=selected_date
    ).order_by("start_time", "employee__name")

    current_employee_numbers = set()
    later_employee_numbers = set()
    finished_employee_numbers = set()
    is_today = selected_date == today

    for shift in roster_shifts:
        emp_no = str(shift.employee.employee_number)

        if not is_today:
            if selected_date < today:
                finished_employee_numbers.add(emp_no)
            else:
                later_employee_numbers.add(emp_no)
            continue

        if shift.start_time <= shift.end_time:
            if shift.start_time <= now_time <= shift.end_time:
                current_employee_numbers.add(emp_no)
            elif now_time < shift.start_time:
                later_employee_numbers.add(emp_no)
            else:
                finished_employee_numbers.add(emp_no)
        else:
            if now_time >= shift.start_time or now_time <= shift.end_time:
                current_employee_numbers.add(emp_no)
            elif now_time < shift.start_time:
                later_employee_numbers.add(emp_no)
            else:
                finished_employee_numbers.add(emp_no)

    roster_rows = [row for row in rows if row.get("rostered")]

    for row in rows:
        emp_no = str(row.get("employee_number"))
        issue = row.get("issue") or ""
        issue_l = issue.lower()
        status = row.get("status") or ""

        if row.get("is_on_break"):
            row["manager_status"] = "On Break"
            row["manager_status_class"] = "orange"
        elif row.get("is_working") or status == "Back from break":
            row["manager_status"] = "Working"
            row["manager_status_class"] = "green"
        elif emp_no in later_employee_numbers and not row.get("has_activity"):
            row["manager_status"] = "Due Later"
            row["manager_status_class"] = "blue"
        elif emp_no in current_employee_numbers and not row.get("has_activity"):
            row["manager_status"] = "Not Arrived"
            row["manager_status_class"] = "red"
        elif emp_no in finished_employee_numbers and not row.get("has_activity"):
            row["manager_status"] = "Didn't Clock In"
            row["manager_status_class"] = "red"
        elif row.get("has_activity") or status == "Clocked out":
            row["manager_status"] = "Finished Shift"
            row["manager_status_class"] = "blue"
        else:
            row["manager_status"] = "No Clock Records"
            row["manager_status_class"] = "red"

        if "rostered but absent" in issue_l:
            row["manager_issue"] = "Didn't clock in for shift"
        elif "working but not rostered" in issue_l:
            row["manager_issue"] = "Worked without matching roster shift"
        elif issue == "OK":
            row["manager_issue"] = ""
        else:
            row["manager_issue"] = issue

        if "working but not rostered" in issue_l or "not rostered" in issue_l:
            row["manager_issue_type"] = "Roster"
            row["manager_issue_type_class"] = "blue"
        elif "rostered but absent" in issue_l or "not arrived" in issue_l:
            row["manager_issue_type"] = "Attendance"
            row["manager_issue_type_class"] = "orange"
        elif "late" in issue_l:
            row["manager_issue_type"] = "Attendance"
            row["manager_issue_type_class"] = "orange"
        elif "clock" in issue_l or "break" in issue_l:
            row["manager_issue_type"] = "Clocking"
            row["manager_issue_type_class"] = "red"
        else:
            row["manager_issue_type"] = "Operational"
            row["manager_issue_type_class"] = "orange"

    live_rows = [
        row for row in rows
        if row.get("is_working") or row.get("is_on_break")
    ]

    needs_attention_rows = []
    for row in rows:
        issue = row.get("issue") or ""
        issue_l = issue.lower()
        emp_no = str(row.get("employee_number"))
        include = False

        if "working but not rostered" in issue_l or "not rostered" in issue_l:
            include = True
        elif "check clock sequence" in issue_l or "missing clock" in issue_l or "open break" in issue_l:
            include = True
        elif "late" in issue_l:
            include = True
        elif ("rostered but absent" in issue_l or "not arrived" in issue_l) and (not is_today or emp_no in current_employee_numbers or emp_no in finished_employee_numbers):
            include = True

        if include:
            needs_attention_rows.append(row)

    payroll_blockers = []
    for row in week_rows:
        warning = (row.get("warning") or "").lower()
        if row.get("warning") == "OK":
            continue
        if "rostered but absent" in warning or "working but not rostered" in warning or "not rostered" in warning:
            continue
        payroll_blockers.append(row)

    return render(request, "manager_today.html", {
        "selected_date": selected_date,
        "today": today,
        "now_time": now_dt,
        "is_today": is_today,
        "rows": rows,
        "roster_rows": roster_rows,
        "live_rows": live_rows,
        "needs_attention_rows": needs_attention_rows,
        "rostered_count": len(roster_rows),
        "working_count": sum(1 for row in live_rows if row.get("is_working")),
        "on_break_count": sum(1 for row in live_rows if row.get("is_on_break")),
        "not_arrived_now_count": sum(1 for row in roster_rows if row.get("manager_status") == "Not Arrived"),
        "payroll_blocker_count": len(payroll_blockers),
        "week_start": week_start,
    })


manager_today_dashboard = login_required(manager_today_dashboard)

# -------------------------------------------------------------------
# Patch 25: weekly payroll uses shared live roster calculations
# -------------------------------------------------------------------

def manager_weekly_summary(request):
    from core.compliance import get_week_rows

    week_start = _patch_parse_week_start(request)
    week_end = week_start + timedelta(days=6)
    rows = get_week_rows(week_start, 7)

    payroll_blockers = sum(1 for row in rows if row.get("warning_type") == "Payroll")
    roster_exceptions = sum(1 for row in rows if row.get("warning_type") == "Roster")

    return render(request, "weekly_summary.html", {
        "week_start": week_start,
        "week_end": week_end,
        "rows": rows,
        "payroll_blockers": payroll_blockers,
        "roster_exceptions": roster_exceptions,
    })


manager_weekly_summary = login_required(manager_weekly_summary)

# Delivery patch 26: live dashboard, break compliance, payroll readiness
# -------------------------------------------------------------------
from django.contrib.auth.decorators import login_required as _dp26_login_required
from core.compliance import (
    get_day_rows as _dp26_get_day_rows,
    get_week_rows as _dp26_get_week_rows,
    get_payroll_problem_rows as _dp26_get_payroll_problem_rows,
    payroll_is_ready as _dp26_payroll_is_ready,
)


def _dp26_week_start_from_request(request):
    week_start_str = request.GET.get("week_start")
    if week_start_str:
        return datetime.strptime(week_start_str, "%Y-%m-%d").date()
    today = timezone.localdate()
    return today - timedelta(days=today.weekday())


@_dp26_login_required
def manager_today_dashboard(request):
    selected_date_str = request.GET.get("date", timezone.localdate().strftime("%Y-%m-%d"))
    selected_date = datetime.strptime(selected_date_str, "%Y-%m-%d").date()
    rows = _dp26_get_day_rows(selected_date)

    urgent_rows = [row for row in rows if row["is_urgent"]]
    operational_rows = [row for row in rows if row["is_operational"]]
    working_rows = [row for row in rows if row["is_working"] or row["is_on_break"]]
    needs_attention_rows = urgent_rows + operational_rows

    # Live screen should stay clean during service: active staff + urgent live blockers.
    live_rows = []
    seen = set()
    for row in working_rows + urgent_rows:
        key = row["employee_number"]
        if key not in seen:
            live_rows.append(row)
            seen.add(key)

    review_rows = [row for row in rows if row["rostered"] or row["has_activity"]]

    late_count = sum(1 for row in operational_rows if "late" in row.get("issue", "").lower())
    not_arrived_count = sum(
        1 for row in operational_rows
        if "absent" in row.get("issue", "").lower() or "not arrived" in row.get("issue", "").lower()
    )

    week_start = selected_date - timedelta(days=selected_date.weekday())
    payroll_ready_bool, payroll_problem_rows = _dp26_payroll_is_ready(week_start)
    payroll_issues_count = len(payroll_problem_rows)
    payroll_ready = 100 if payroll_ready_bool else 0

    return render(request, "manager_today.html", {
        "selected_date": selected_date,
        "week_start": week_start,
        "rows": rows,
        "live_rows": live_rows,
        "review_rows": review_rows,
        "urgent_rows": urgent_rows,
        "operational_rows": operational_rows,
        "working_rows": working_rows,
        "needs_attention_rows": needs_attention_rows,
        "late_count": late_count,
        "not_arrived_count": not_arrived_count,
        "late_absent_count": late_count + not_arrived_count,
        "payroll_issues_count": payroll_issues_count,
        "payroll_ready": payroll_ready,
        "rostered_count": sum(1 for row in rows if row["rostered"]),
        "currently_working": sum(1 for row in rows if row["is_working"]),
        "on_break": sum(1 for row in rows if row["is_on_break"]),
        "clocked_out": sum(1 for row in rows if row["is_clocked_out"]),
        "urgent_count": len(urgent_rows),
        "operational_count": len(operational_rows),
    })


@_dp26_login_required
def payroll_problems(request):
    week_start = _dp26_week_start_from_request(request)
    week_end = week_start + timedelta(days=6)
    rows = _dp26_get_payroll_problem_rows(week_start)
    return render(request, "payroll_problems.html", {
        "week_start": week_start,
        "week_end": week_end,
        "rows": rows,
        "problem_count": len(rows),
    })


@_dp26_login_required
def manager_weekly_summary(request):
    week_start = _dp26_week_start_from_request(request)
    week_end = week_start + timedelta(days=6)
    standard_hours = float(request.GET.get("standard_hours", "39"))
    summary_rows = _dp26_get_week_rows(week_start, standard_hours)
    payroll_ready_bool, payroll_problem_rows = _dp26_payroll_is_ready(week_start)

    return render(request, "weekly_summary.html", {
        "week_start": week_start,
        "week_end": week_end,
        "summary_rows": summary_rows,
        "standard_hours": standard_hours,
        "payroll_ready": payroll_ready_bool,
        "unresolved_problem_count": len(payroll_problem_rows),
    })


@_dp26_login_required
def export_sage_payroll_csv(request):
    week_start = _dp26_week_start_from_request(request)
    period_number = request.GET.get("period", "1")
    standard_hours = float(request.GET.get("standard_hours", "39"))
    include_header = request.GET.get("include_header") == "1"

    payroll_ready_bool, payroll_problem_rows = _dp26_payroll_is_ready(week_start)
    if not payroll_ready_bool:
        response = HttpResponse(content_type="text/plain", status=409)
        response.write("Payroll export blocked. Fix payroll problems first:\n\n")
        for problem in payroll_problem_rows:
            response.write(f"{problem['date']} - {problem['employee']}: {problem['problem']}\n")
        return response

    rows = _dp26_get_week_rows(week_start, standard_hours)
    response = HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = 'attachment; filename="sage_payroll_export.csv"'
    writer = csv.writer(response)

    # Sage Payroll IE single-timesheet import order:
    # period number, employee number, 0000, payment element 1, payment element 2, payment element 3.
    # Header is OFF by default because Sage imports often expect raw rows only.
    if include_header:
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

# -------------------------------------------------------------------
# Delivery patch 27: make break status visible on home/today dashboards
# -------------------------------------------------------------------
from django.contrib.auth.decorators import login_required as _dp27_login_required
from core.compliance import (
    get_day_rows as _dp27_get_day_rows,
    payroll_is_ready as _dp27_payroll_is_ready,
)


def _dp27_week_start(day):
    return day - timedelta(days=day.weekday())


def _dp27_live_rows(rows):
    live = []
    seen = set()
    for row in rows:
        if row.get("is_working") or row.get("is_on_break") or row.get("is_urgent"):
            key = row.get("employee_number")
            if key not in seen:
                live.append(row)
                seen.add(key)
    return live


def _dp27_break_attention_rows(rows):
    return [
        row for row in rows
        if row.get("is_working") or row.get("is_on_break")
        if row.get("break_css") in ["break-warn", "break-urgent", "break-on"]
    ]


def _dp27_roster_rows(rows):
    return [row for row in rows if row.get("rostered") or row.get("has_activity")]


def _dp27_not_arrived_now(rows):
    return [
        row for row in rows
        if row.get("rostered")
        and not row.get("has_activity")
        and row.get("is_operational")
    ]


def home_page(request):
    today = timezone.localdate()
    week_start = _dp27_week_start(today)
    rows = _dp27_get_day_rows(today)
    live_rows = _dp27_live_rows(rows)
    break_attention_rows = _dp27_break_attention_rows(rows)
    roster_rows = _dp27_roster_rows(rows)
    not_arrived_rows = _dp27_not_arrived_now(rows)
    payroll_ready_bool, payroll_problem_rows = _dp27_payroll_is_ready(week_start)

    return render(request, "home.html", {
        "today": today,
        "now_time": timezone.localtime(timezone.now()),
        "week_start": week_start,
        "rows": rows,
        "live_rows": live_rows,
        "break_attention_rows": break_attention_rows,
        "roster_rows": roster_rows,
        "not_arrived_now_count": len(not_arrived_rows),
        "currently_working": sum(1 for row in rows if row.get("is_working")),
        "on_break": sum(1 for row in rows if row.get("is_on_break")),
        "rostered_count": sum(1 for row in rows if row.get("rostered")),
        "break_attention_count": len(break_attention_rows),
        "payroll_problem_count": len(payroll_problem_rows),
        "payroll_ready": payroll_ready_bool,
    })


@_dp27_login_required
def manager_today_dashboard(request):
    selected_date_str = request.GET.get("date", timezone.localdate().strftime("%Y-%m-%d"))
    selected_date = datetime.strptime(selected_date_str, "%Y-%m-%d").date()
    week_start = _dp27_week_start(selected_date)
    rows = _dp27_get_day_rows(selected_date)
    live_rows = _dp27_live_rows(rows)
    break_attention_rows = _dp27_break_attention_rows(rows)
    review_rows = _dp27_roster_rows(rows)

    urgent_rows = [row for row in rows if row.get("is_urgent")]
    operational_rows = [row for row in rows if row.get("is_operational")]
    late_count = sum(1 for row in operational_rows if "late" in row.get("issue", "").lower())
    not_arrived_count = len(_dp27_not_arrived_now(rows))
    payroll_ready_bool, payroll_problem_rows = _dp27_payroll_is_ready(week_start)

    return render(request, "manager_today.html", {
        "selected_date": selected_date,
        "week_start": week_start,
        "rows": rows,
        "live_rows": live_rows,
        "break_attention_rows": break_attention_rows,
        "review_rows": review_rows,
        "urgent_rows": urgent_rows,
        "operational_rows": operational_rows,
        "late_count": late_count,
        "not_arrived_count": not_arrived_count,
        "late_absent_count": late_count + not_arrived_count,
        "currently_working": sum(1 for row in rows if row.get("is_working")),
        "on_break": sum(1 for row in rows if row.get("is_on_break")),
        "rostered_count": sum(1 for row in rows if row.get("rostered")),
        "break_attention_count": len(break_attention_rows),
        "payroll_issues_count": len(payroll_problem_rows),
        "payroll_ready": 100 if payroll_ready_bool else 0,
    })

# -------------------------------------------------------------------
# Delivery patch 28: overnight operational day fix
# -------------------------------------------------------------------
# Real restaurant behaviour: at 00:06, a 16:00-23:00 or 23:00-00:00 shift
# has not magically become yesterday's payroll error. The live dashboard must
# keep showing open staff until the operational day rolls over at 05:00.
from core.compliance import current_operational_date as _dp28_current_operational_date


def home_page(request):
    today = _dp28_current_operational_date()
    week_start = _dp27_week_start(today)
    rows = _dp27_get_day_rows(today)
    live_rows = _dp27_live_rows(rows)
    break_attention_rows = _dp27_break_attention_rows(rows)
    roster_rows = _dp27_roster_rows(rows)
    not_arrived_rows = _dp27_not_arrived_now(rows)
    payroll_ready_bool, payroll_problem_rows = _dp27_payroll_is_ready(week_start)

    return render(request, "home.html", {
        "today": today,
        "operational_day_start_hour": 5,
        "now_time": timezone.localtime(timezone.now()),
        "week_start": week_start,
        "rows": rows,
        "live_rows": live_rows,
        "break_attention_rows": break_attention_rows,
        "roster_rows": roster_rows,
        "not_arrived_now_count": len(not_arrived_rows),
        "currently_working": sum(1 for row in rows if row.get("is_working")),
        "on_break": sum(1 for row in rows if row.get("is_on_break")),
        "rostered_count": sum(1 for row in rows if row.get("rostered")),
        "break_attention_count": len(break_attention_rows),
        "payroll_problem_count": len(payroll_problem_rows),
        "payroll_ready": payroll_ready_bool,
    })


@_dp27_login_required
def manager_today_dashboard(request):
    default_date = _dp28_current_operational_date()
    selected_date_str = request.GET.get("date", default_date.strftime("%Y-%m-%d"))
    selected_date = datetime.strptime(selected_date_str, "%Y-%m-%d").date()
    week_start = _dp27_week_start(selected_date)
    rows = _dp27_get_day_rows(selected_date)
    live_rows = _dp27_live_rows(rows)
    break_attention_rows = _dp27_break_attention_rows(rows)
    review_rows = _dp27_roster_rows(rows)

    urgent_rows = [row for row in rows if row.get("is_urgent")]
    operational_rows = [row for row in rows if row.get("is_operational")]
    late_count = sum(1 for row in operational_rows if "late" in row.get("issue", "").lower())
    not_arrived_count = len(_dp27_not_arrived_now(rows))
    payroll_ready_bool, payroll_problem_rows = _dp27_payroll_is_ready(week_start)

    return render(request, "manager_today.html", {
        "selected_date": selected_date,
        "operational_day_start_hour": 5,
        "week_start": week_start,
        "rows": rows,
        "live_rows": live_rows,
        "break_attention_rows": break_attention_rows,
        "review_rows": review_rows,
        "urgent_rows": urgent_rows,
        "operational_rows": operational_rows,
        "late_count": late_count,
        "not_arrived_count": not_arrived_count,
        "late_absent_count": late_count + not_arrived_count,
        "currently_working": sum(1 for row in rows if row.get("is_working")),
        "on_break": sum(1 for row in rows if row.get("is_on_break")),
        "rostered_count": sum(1 for row in rows if row.get("rostered")),
        "break_attention_count": len(break_attention_rows),
        "payroll_issues_count": len(payroll_problem_rows),
        "payroll_ready": 100 if payroll_ready_bool else 0,
    })

# -------------------------------------------------------------------
# Delivery patch 30: manager-first current staff and synced payroll issues
# -------------------------------------------------------------------
from core.compliance import (
    current_operational_date as _dp30_current_operational_date,
    get_day_rows as _dp30_get_day_rows,
    payroll_is_ready as _dp30_payroll_is_ready,
)


def _dp30_week_start(day):
    return day - timedelta(days=day.weekday())


def _dp30_live_rows(rows):
    # Current Staff means people still clocked in now. Do not include old/finished issues here.
    return [row for row in rows if row.get("is_working") or row.get("is_on_break")]


def _dp30_break_attention_rows(rows):
    return [
        row for row in rows
        if (row.get("is_working") or row.get("is_on_break"))
        and row.get("break_css") in ["break-warn", "break-urgent"]
    ]


def _dp30_roster_rows(rows):
    return [row for row in rows if row.get("rostered") or row.get("has_activity")]


def home_page(request):
    today = _dp30_current_operational_date()
    week_start = _dp30_week_start(today)
    rows = _dp30_get_day_rows(today)
    live_rows = _dp30_live_rows(rows)
    break_attention_rows = _dp30_break_attention_rows(rows)
    roster_rows = _dp30_roster_rows(rows)
    payroll_ready_bool, payroll_problem_rows = _dp30_payroll_is_ready(week_start)

    return render(request, "home.html", {
        "today": today,
        "now_time": timezone.localtime(timezone.now()),
        "week_start": week_start,
        "rows": rows,
        "live_rows": live_rows,
        "break_attention_rows": break_attention_rows,
        "roster_rows": roster_rows,
        "currently_working": sum(1 for row in rows if row.get("is_working")),
        "on_break": sum(1 for row in rows if row.get("is_on_break")),
        "rostered_count": sum(1 for row in rows if row.get("rostered")),
        "break_attention_count": len(break_attention_rows),
        "payroll_problem_count": len(payroll_problem_rows),
        "payroll_ready": payroll_ready_bool,
    })


@_dp27_login_required
def manager_today_dashboard(request):
    default_date = _dp30_current_operational_date()
    selected_date_str = request.GET.get("date", default_date.strftime("%Y-%m-%d"))
    selected_date = datetime.strptime(selected_date_str, "%Y-%m-%d").date()
    week_start = _dp30_week_start(selected_date)
    rows = _dp30_get_day_rows(selected_date)
    live_rows = _dp30_live_rows(rows)
    break_attention_rows = _dp30_break_attention_rows(rows)
    review_rows = _dp30_roster_rows(rows)
    payroll_ready_bool, payroll_problem_rows = _dp30_payroll_is_ready(week_start)

    return render(request, "manager_today.html", {
        "selected_date": selected_date,
        "week_start": week_start,
        "rows": rows,
        "live_rows": live_rows,
        "break_attention_rows": break_attention_rows,
        "review_rows": review_rows,
        "currently_working": sum(1 for row in rows if row.get("is_working")),
        "on_break": sum(1 for row in rows if row.get("is_on_break")),
        "rostered_count": sum(1 for row in rows if row.get("rostered")),
        "break_attention_count": len(break_attention_rows),
        "payroll_issues_count": len(payroll_problem_rows),
        "payroll_ready": 100 if payroll_ready_bool else 0,
    })

# -------------------------------------------------------------------
# Delivery patch 31: dashboard cleanup and Sage decimal export safety
# -------------------------------------------------------------------
from decimal import Decimal, ROUND_HALF_UP
from django.contrib.auth.decorators import login_required as _dp31_login_required


def _dp31_week_start(day):
    return day - timedelta(days=day.weekday())


def _dp31_minutes_to_decimal_string(minutes):
    """Return Sage-ready decimal hours, fixed to 2 dp: 7h13m -> 7.22."""
    minutes = int(minutes or 0)
    value = (Decimal(minutes) / Decimal(60)).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    return format(value, ".2f")


def _dp31_add_export_strings(rows):
    export_rows = []
    for row in rows:
        row["normal_export"] = _dp31_minutes_to_decimal_string(row.get("normal_minutes", 0))
        row["sunday_export"] = _dp31_minutes_to_decimal_string(row.get("sunday_minutes", 0))
        row["overtime_export"] = _dp31_minutes_to_decimal_string(row.get("overtime_minutes", 0))
        if int(row.get("paid_minutes", 0) or 0) > 0:
            export_rows.append(row)
    return rows, export_rows


# Override patch 30 helpers: current staff keeps break status, but no duplicate break section below.
def _dp30_break_attention_rows(rows):
    return [
        row for row in rows
        if (row.get("is_working") or row.get("is_on_break"))
        and row.get("break_css") in ["break-warn", "break-urgent"]
    ]


@_dp31_login_required
def manager_weekly_summary(request):
    week_start = _patch_parse_week_start(request)
    week_end = week_start + timedelta(days=6)
    standard_hours = float(request.GET.get("standard_hours", "39"))
    period_number = request.GET.get("period", "1")
    summary_rows = _patch_get_week_rows(week_start, standard_hours)
    summary_rows, export_rows = _dp31_add_export_strings(summary_rows)
    payroll_ready_bool, payroll_problem_rows = _dp30_payroll_is_ready(week_start)

    return render(request, "weekly_summary.html", {
        "week_start": week_start,
        "week_end": week_end,
        "summary_rows": summary_rows,
        "export_rows": export_rows,
        "standard_hours": standard_hours,
        "period_number": period_number,
        "payroll_problem_count": len(payroll_problem_rows),
        "payroll_ready": payroll_ready_bool,
    })


@_dp31_login_required
def export_sage_payroll_csv(request):
    week_start = _patch_parse_week_start(request)
    period_number = request.GET.get("period", "1")
    standard_hours = float(request.GET.get("standard_hours", "39"))

    payroll_ready_bool, payroll_problem_rows = _dp30_payroll_is_ready(week_start)
    if not payroll_ready_bool:
        response = HttpResponse(content_type="text/plain", status=400)
        response.write("Payroll is not ready. Fix payroll issues before exporting the Sage CSV.\n")
        for row in payroll_problem_rows:
            response.write(f"{row.get('date')} - {row.get('employee')}: {row.get('problem')}\n")
        return response

    rows = _patch_get_week_rows(week_start, standard_hours)

    response = HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = 'attachment; filename="sage_payroll_export.csv"'
    writer = csv.writer(response)

    # Sage Payroll IE single-timesheet import order:
    # period number, employee number, 0000, payment element 1, payment element 2, payment element 3.
    # Values are decimal hours, not HH.MM. Example: 7h13m = 7.22.
    for row in rows:
        if int(row.get("paid_minutes", 0) or 0) == 0:
            continue
        writer.writerow([
            period_number,
            row["employee_number"],
            "0000",
            _dp31_minutes_to_decimal_string(row.get("normal_minutes", 0)),
            _dp31_minutes_to_decimal_string(row.get("sunday_minutes", 0)),
            _dp31_minutes_to_decimal_string(row.get("overtime_minutes", 0)),
        ])

    return response

# -------------------------------------------------------------------
# Delivery patch 33: payroll quick fixes + manager-friendly weekly review status
# -------------------------------------------------------------------
from datetime import datetime as _dp33_datetime, timedelta as _dp33_timedelta
from django.contrib import messages as _dp33_messages
from django.shortcuts import redirect as _dp33_redirect
from core.models import RosterShift as _dp33_RosterShift, ClockEvent as _dp33_ClockEvent, Employee as _dp33_Employee
from core.compliance import calculate_employee_day as _dp33_calculate_employee_day
from core.compliance import current_operational_date as _dp33_current_operational_date


def _dp33_hours(minutes):
    return round((int(minutes or 0)) / 60, 2)


def _dp33_minutes_to_hours_label(minutes):
    minutes = int(minutes or 0)
    hours = minutes // 60
    mins = minutes % 60
    if hours and mins:
        return f"{hours}h {mins}m"
    if hours:
        return f"{hours}h"
    return f"{mins}m"


def _dp33_make_aware(day, clock_time):
    return timezone.make_aware(_dp33_datetime.combine(day, clock_time))


def _dp33_shift_datetimes(employee, day):
    shifts = list(_dp33_RosterShift.objects.filter(employee=employee, shift_date=day).order_by("start_time"))
    if not shifts:
        return None
    first = shifts[0]
    last = shifts[-1]
    start_dt = _dp33_make_aware(day, first.start_time)
    end_dt = _dp33_make_aware(day, last.end_time)
    if end_dt <= start_dt:
        end_dt += _dp33_timedelta(days=1)
    return {
        "start": start_dt,
        "end": end_dt,
        "start_label": start_dt.strftime("%H:%M"),
        "end_label": end_dt.strftime("%H:%M"),
        "roster_label": f"{first.start_time.strftime('%H:%M')} - {last.end_time.strftime('%H:%M')}",
    }


def _dp33_has_clock(employee, day, clock_type):
    start, end = operational_window(day)
    return _dp33_ClockEvent.objects.filter(employee=employee, timestamp__gte=start, timestamp__lt=end, clock_type=clock_type).exists()


def _dp33_create_manager_event(employee, clock_type, timestamp, note):
    return _dp33_ClockEvent.objects.create(
        employee=employee,
        clock_type=clock_type,
        timestamp=timestamp,
        method="MANAGER",
        notes=f"Manager quick fix: {note}",
    )


def _dp33_apply_quick_fix(request):
    mode = request.POST.get("mode")
    employee_number = request.POST.get("employee_number")
    day_raw = request.POST.get("event_date")
    week_start = request.POST.get("week_start") or ""
    employee = _patch_get_object_or_404(_dp33_Employee, employee_number=employee_number)
    day = _dp33_datetime.strptime(day_raw, "%Y-%m-%d").date()
    shift = _dp33_shift_datetimes(employee, day)

    try:
        if mode == "use_roster_start":
            if not shift:
                _dp33_messages.error(request, "No roster start time found for this shift.")
            elif _dp33_has_clock(employee, day, "IN"):
                _dp33_messages.info(request, f"{employee.name} already has a clock-in for this day.")
            else:
                _dp33_create_manager_event(employee, "IN", shift["start"], f"used roster start {shift['start_label']}")
                _dp33_messages.success(request, f"Added clock-in for {employee.name} at roster start {shift['start_label']}.")

        elif mode == "use_roster_finish":
            if not shift:
                _dp33_messages.error(request, "No roster finish time found for this shift.")
            elif _dp33_has_clock(employee, day, "OUT"):
                _dp33_messages.info(request, f"{employee.name} already has a clock-out for this day.")
            else:
                _dp33_create_manager_event(employee, "OUT", shift["end"], f"used roster finish {shift['end_label']}")
                _dp33_messages.success(request, f"Added clock-out for {employee.name} at roster finish {shift['end_label']}.")

        elif mode == "use_roster_shift":
            if not shift:
                _dp33_messages.error(request, "No roster shift found for this employee on this day.")
            else:
                added = []
                if not _dp33_has_clock(employee, day, "IN"):
                    _dp33_create_manager_event(employee, "IN", shift["start"], f"used roster shift start {shift['start_label']}")
                    added.append(f"in {shift['start_label']}")
                if not _dp33_has_clock(employee, day, "OUT"):
                    _dp33_create_manager_event(employee, "OUT", shift["end"], f"used roster shift finish {shift['end_label']}")
                    added.append(f"out {shift['end_label']}")
                if added:
                    _dp33_messages.success(request, f"Added {employee.name}: " + ", ".join(added) + ".")
                else:
                    _dp33_messages.info(request, f"{employee.name} already has clock-in and clock-out records for this day.")

        elif mode == "enter_actual_time":
            clock_type = request.POST.get("clock_type")
            actual_time = request.POST.get("actual_time")
            if clock_type not in ["IN", "OUT"]:
                _dp33_messages.error(request, "Choose clock-in or clock-out.")
            elif not actual_time:
                _dp33_messages.error(request, "Enter the actual time.")
            else:
                target_dt = _dp33_make_aware(day, _dp33_datetime.strptime(actual_time, "%H:%M").time())
                if shift and clock_type == "OUT" and target_dt <= shift["start"]:
                    target_dt += _dp33_timedelta(days=1)
                _dp33_create_manager_event(employee, clock_type, target_dt, f"entered actual {clock_type.lower()} time {actual_time}")
                label = "clock-in" if clock_type == "IN" else "clock-out"
                _dp33_messages.success(request, f"Added {label} for {employee.name} at {actual_time}.")

        else:
            _dp33_messages.error(request, "Unknown quick fix.")

    except Exception as exc:
        _dp33_messages.error(request, f"Could not apply quick fix: {exc}")

    return _dp33_redirect(f"/manager/payroll-problems/?week_start={week_start}")


def _dp33_payroll_problem_rows(week_start):
    rows = []
    today = _dp33_current_operational_date()
    for employee in _dp33_Employee.objects.filter(active=True).order_by("name"):
        for i in range(7):
            day = week_start + _dp33_timedelta(days=i)
            if day > today:
                continue
            d = _dp33_calculate_employee_day(employee, day, include_live=True)
            shift = _dp33_shift_datetimes(employee, day)
            problems = []
            quick = []

            if d.get("rostered") and not d.get("has_activity") and day < today:
                problems.append("No clock records")
                if shift:
                    quick.append({"mode": "use_roster_shift", "label": f"Use roster {shift['roster_label']}"})
                    quick.append({"mode": "enter_actual_time", "label": "Enter actual times", "clock_type": "IN"})

            if d.get("missing_clock_out"):
                problems.append("Missing clock-out")
                if shift:
                    quick.append({"mode": "use_roster_finish", "label": f"Use finish {shift['end_label']}"})
                quick.append({"mode": "enter_actual_time", "label": "Enter actual finish", "clock_type": "OUT"})

            if d.get("invalid_sequence"):
                problems.append("Check clock events")

            if d.get("is_urgent"):
                for part in str(d.get("issue") or "").split(";"):
                    part = part.strip()
                    if part:
                        problems.append(part)

            if d.get("worked_minutes", 0) > 12 * 60:
                problems.append("Long shift")

            if d.get("has_activity") and not d.get("rostered"):
                problems.append("Unrostered shift")

            # Remove duplicates while keeping order.
            problems = list(dict.fromkeys([p for p in problems if p and p != "OK"]))
            if not problems:
                continue

            if not quick:
                quick.append({"mode": "advanced", "label": "Advanced edit"})

            rows.append({
                "date": day,
                "employee_number": employee.employee_number,
                "employee": employee.name,
                "roster": d.get("roster"),
                "status": d.get("status"),
                "worked_hours": d.get("worked_hours"),
                "break_minutes": d.get("break_minutes"),
                "break_status": d.get("break_status"),
                "problem": "; ".join(problems),
                "quick_actions": quick,
            })
    return rows


@_dp31_login_required
def payroll_problems(request):
    if request.method == "POST":
        return _dp33_apply_quick_fix(request)

    week_start = _patch_parse_week_start(request)
    week_end = week_start + _dp33_timedelta(days=6)
    rows = _dp33_payroll_problem_rows(week_start)
    return render(request, "payroll_problems.html", {
        "week_start": week_start,
        "week_end": week_end,
        "rows": rows,
        "problem_count": len(rows),
    })


def _dp33_weekly_rows(week_start, standard_hours):
    raw_rows = _patch_get_week_rows(week_start, standard_hours)
    current_day = _dp33_current_operational_date()
    week_end = week_start + _dp33_timedelta(days=6)
    problem_rows = _dp33_payroll_problem_rows(week_start)
    problem_map = {}
    for problem in problem_rows:
        problem_map.setdefault(problem["employee_number"], []).append(f"{problem['date'].strftime('%a')}: {problem['problem']}")

    for row in raw_rows:
        rostered_minutes = int(float(row.get("rostered_hours", 0) or 0) * 60)
        paid_minutes = int(row.get("paid_minutes", 0) or 0)
        difference_minutes = paid_minutes - rostered_minutes
        problems = problem_map.get(row.get("employee_number"), [])
        future_rostered = week_end >= current_day and rostered_minutes > paid_minutes and current_day <= week_end

        if problems:
            row["review_status"] = "Review"
            row["review_reason"] = "; ".join(problems[:3])
            row["status_css"] = "warn"
        elif week_start <= current_day <= week_end and future_rostered:
            row["review_status"] = "In progress"
            row["review_reason"] = "Week not finished"
            row["status_css"] = "progress"
        elif rostered_minutes > 0 and paid_minutes == 0:
            row["review_status"] = "Review"
            row["review_reason"] = "Rostered but no paid hours"
            row["status_css"] = "warn"
        elif abs(difference_minutes) > 4 * 60:
            row["review_status"] = "Review"
            row["review_reason"] = f"Variance {_dp33_minutes_to_hours_label(abs(difference_minutes))}"
            row["status_css"] = "warn"
        elif abs(difference_minutes) > 60:
            row["review_status"] = "Check"
            row["review_reason"] = f"Variance {_dp33_minutes_to_hours_label(abs(difference_minutes))}"
            row["status_css"] = "check"
        else:
            row["review_status"] = "OK"
            row["review_reason"] = ""
            row["status_css"] = "ok"

    return raw_rows


@_dp31_login_required
def manager_weekly_summary(request):
    week_start = _patch_parse_week_start(request)
    week_end = week_start + _dp33_timedelta(days=6)
    standard_hours = float(request.GET.get("standard_hours", "39"))
    period_number = request.GET.get("period", "1")
    summary_rows = _dp33_weekly_rows(week_start, standard_hours)
    summary_rows, export_rows = _dp31_add_export_strings(summary_rows)
    payroll_issue_rows = _dp33_payroll_problem_rows(week_start)
    payroll_ready_bool = len(payroll_issue_rows) == 0

    totals = {
        "rostered": round(sum(float(r.get("rostered_hours", 0) or 0) for r in summary_rows), 2),
        "paid": round(sum(float(r.get("paid_hours", 0) or 0) for r in summary_rows), 2),
        "normal": round(sum(float(r.get("normal_hours", 0) or 0) for r in summary_rows), 2),
        "sunday": round(sum(float(r.get("sunday_hours", 0) or 0) for r in summary_rows), 2),
        "overtime": round(sum(float(r.get("overtime_hours", 0) or 0) for r in summary_rows), 2),
    }

    return render(request, "weekly_summary.html", {
        "week_start": week_start,
        "week_end": week_end,
        "summary_rows": summary_rows,
        "export_rows": export_rows,
        "standard_hours": standard_hours,
        "period_number": period_number,
        "payroll_problem_count": len(payroll_issue_rows),
        "payroll_ready": payroll_ready_bool,
        "totals": totals,
    })

# -------------------------------------------------------------------
# Patch 34: Demo Week Simulator
# -------------------------------------------------------------------
# Purpose: create a realistic demo week from the uploaded roster so the
# product can be shown end-to-end: roster -> clocking -> payroll issues
# -> quick fixes -> Sage export.

from django.contrib.auth.decorators import login_required as _demo_login_required


def _demo_week_monday(d=None):
    from django.utils import timezone as _tz
    if d is None:
        d = _tz.localdate()
    return d - timedelta(days=d.weekday())


def _demo_shift_datetimes(shift):
    """Return aware start/end datetimes for a roster shift, handling overnight shifts."""
    from datetime import datetime as _dt, timedelta as _td
    from django.utils import timezone as _tz

    start = _dt.combine(shift.shift_date, shift.start_time)
    end = _dt.combine(shift.shift_date, shift.end_time)
    if end <= start:
        end = end + _td(days=1)
    return _tz.make_aware(start), _tz.make_aware(end)


def _demo_add_event(employee, clock_type, when, note):
    ClockEvent.objects.create(
        employee=employee,
        clock_type=clock_type,
        timestamp=when,
        method="DEMO",
        notes=note,
    )


def _demo_make_normal_shift(shift, late_mins=0, finish_delta_mins=0, add_break=True, note="Demo shift"):
    from datetime import timedelta as _td
    start, end = _demo_shift_datetimes(shift)
    employee = shift.employee
    in_time = start + _td(minutes=late_mins)
    out_time = end + _td(minutes=finish_delta_mins)

    _demo_add_event(employee, "IN", in_time, note)

    shift_minutes = max(0, int((out_time - in_time).total_seconds() // 60))
    if add_break and shift_minutes > 270:
        # Normal restaurant-style break around the middle of the shift.
        break_start = in_time + _td(minutes=min(270, max(180, shift_minutes // 2)))
        break_length = 30 if shift_minutes > 360 else 15
        break_end = break_start + _td(minutes=break_length)
        if break_end < out_time:
            _demo_add_event(employee, "BREAK_START", break_start, note)
            _demo_add_event(employee, "BREAK_END", break_end, note)

    _demo_add_event(employee, "OUT", out_time, note)


def _demo_clear_week_events(week_start):
    from datetime import datetime as _dt, time as _time, timedelta as _td
    from django.utils import timezone as _tz
    start_dt = _tz.make_aware(_dt.combine(week_start, _time.min))
    end_dt = start_dt + _td(days=8)  # includes overnight Sunday shifts
    return ClockEvent.objects.filter(
        timestamp__gte=start_dt,
        timestamp__lt=end_dt,
        method="DEMO",
    ).delete()[0]


def _demo_create_week(week_start, scenario):
    from datetime import datetime as _dt, time as _time, timedelta as _td
    from django.utils import timezone as _tz

    week_end = week_start + _td(days=6)
    shifts = list(
        RosterShift.objects.select_related("employee")
        .filter(shift_date__gte=week_start, shift_date__lte=week_end, employee__active=True)
        .order_by("shift_date", "start_time", "employee__name")
    )

    if not shifts:
        return {"created": 0, "message": "No roster shifts found for this week."}

    _demo_clear_week_events(week_start)
    created_before = ClockEvent.objects.filter(method="DEMO").count()

    # Pick a small number of realistic issues. The demo should show value without
    # making the app look chaotic.
    issue_counts = {
        "clean": {"missing_out": 0, "no_records": 0, "missed_break": 0, "worked_late": 0, "late": 0, "cover": 0},
        "normal": {"missing_out": 1, "no_records": 1, "missed_break": 1, "worked_late": 1, "late": 2, "cover": 1},
        "messy": {"missing_out": 2, "no_records": 2, "missed_break": 2, "worked_late": 2, "late": 4, "cover": 1},
    }.get(scenario, {"missing_out": 1, "no_records": 1, "missed_break": 1, "worked_late": 1, "late": 2, "cover": 1})

    assigned = set()
    notes = []

    def take_shift(label):
        for s in shifts:
            if s.id not in assigned:
                assigned.add(s.id)
                notes.append(label)
                return s
        return None

    # Missing clock-out: very common. Staff clock in, but no OUT event.
    for _ in range(issue_counts["missing_out"]):
        s = take_shift("Missing clock-out")
        if s:
            start, end = _demo_shift_datetimes(s)
            _demo_add_event(s.employee, "IN", start + _td(minutes=3), "Demo: forgot to clock out")
            if int((end - start).total_seconds() // 60) > 270:
                b = start + _td(hours=4)
                _demo_add_event(s.employee, "BREAK_START", b, "Demo: forgot to clock out")
                _demo_add_event(s.employee, "BREAK_END", b + _td(minutes=30), "Demo: forgot to clock out")

    # No records for a rostered shift: common enough when someone forgets to clock in.
    for _ in range(issue_counts["no_records"]):
        s = take_shift("No clock records")
        if s:
            # Intentionally create no events. Payroll quick fix should offer Use roster shift.
            pass

    # Missed break: staff worked the shift but did not record a break.
    for _ in range(issue_counts["missed_break"]):
        s = take_shift("Missed break")
        if s:
            _demo_make_normal_shift(s, late_mins=0, finish_delta_mins=0, add_break=False, note="Demo: no break recorded")

    # Worked late: actual time should usually be accepted by manager.
    for _ in range(issue_counts["worked_late"]):
        s = take_shift("Worked late")
        if s:
            _demo_make_normal_shift(s, late_mins=0, finish_delta_mins=35, add_break=True, note="Demo: worked late")

    # Late arrival: common, but not always a payroll blocker.
    for i in range(issue_counts["late"]):
        s = take_shift("Late arrival")
        if s:
            _demo_make_normal_shift(s, late_mins=8 + (i * 7), finish_delta_mins=0, add_break=True, note="Demo: arrived late")

    # Everything else is clean.
    for s in shifts:
        if s.id not in assigned:
            _demo_make_normal_shift(s, late_mins=0, finish_delta_mins=0, add_break=True, note="Demo: clean shift")

    # One unrostered cover shift if there is a suitable employee.
    if issue_counts["cover"]:
        employee = Employee.objects.filter(active=True).order_by("name").first()
        if employee:
            cover_day = week_start + _td(days=2)
            cover_start = _tz.make_aware(_dt.combine(cover_day, _time(18, 0)))
            cover_end = cover_start + _td(hours=3)
            _demo_add_event(employee, "IN", cover_start, "Demo: unrostered cover shift")
            _demo_add_event(employee, "OUT", cover_end, "Demo: unrostered cover shift")
            notes.append("Unrostered cover shift")

    created_after = ClockEvent.objects.filter(method="DEMO").count()
    return {
        "created": max(0, created_after - created_before),
        "message": f"Demo week created from {len(shifts)} roster shifts.",
        "notes": notes,
    }


@_demo_login_required
def manager_demo_week_simulator(request):
    from datetime import datetime as _dt, timedelta as _td
    from django.contrib import messages as _messages
    from django.shortcuts import redirect as _redirect
    from django.urls import reverse as _reverse
    from django.utils import timezone as _tz

    default_week = _demo_week_monday(_tz.localdate())
    week_start_raw = request.POST.get("week_start") or request.GET.get("week_start") or default_week.isoformat()
    try:
        week_start = _dt.strptime(week_start_raw, "%Y-%m-%d").date()
    except ValueError:
        week_start = default_week
    week_end = week_start + _td(days=6)

    if request.method == "POST":
        action = request.POST.get("action")
        if action == "clear":
            deleted = _demo_clear_week_events(week_start)
            _messages.success(request, f"Demo clock events cleared for this week ({deleted} event(s) removed).")
            return _redirect(f"{_reverse('manager_demo_week_simulator')}?week_start={week_start.isoformat()}")
        if action == "simulate":
            scenario = request.POST.get("scenario", "normal")
            result = _demo_create_week(week_start, scenario)
            if result["created"]:
                _messages.success(request, f"{result['message']} {result['created']} demo clock event(s) created.")
            else:
                _messages.warning(request, result["message"])
            return _redirect(f"{_reverse('manager_demo_week_simulator')}?week_start={week_start.isoformat()}")

    roster_count = RosterShift.objects.filter(shift_date__gte=week_start, shift_date__lte=week_end).count()
    demo_event_count = ClockEvent.objects.filter(
        method="DEMO",
        timestamp__date__gte=week_start,
        timestamp__date__lte=week_end + _td(days=1),
    ).count()
    sample_shifts = list(
        RosterShift.objects.select_related("employee")
        .filter(shift_date__gte=week_start, shift_date__lte=week_end)
        .order_by("shift_date", "start_time", "employee__name")[:12]
    )

    return render(request, "manager_demo_week.html", {
        "week_start": week_start,
        "week_end": week_end,
        "roster_count": roster_count,
        "demo_event_count": demo_event_count,
        "sample_shifts": sample_shifts,
    })

# -------------------------------------------------------------------
# Delivery patch 36: manager-first payroll quick fixes
# -------------------------------------------------------------------
from datetime import datetime as _dp36_datetime, timedelta as _dp36_timedelta, time as _dp36_time
from django.contrib import messages as _dp36_messages
from django.shortcuts import redirect as _dp36_redirect
from django.utils import timezone as _dp36_timezone
from core.models import Employee as _dp36_Employee, ClockEvent as _dp36_ClockEvent, RosterShift as _dp36_RosterShift
from core.compliance import calculate_employee_day as _dp36_calculate_employee_day


def _dp36_parse_day(day_raw):
    return _dp36_datetime.strptime(day_raw, "%Y-%m-%d").date()


def _dp36_make_aware(day, clock_time):
    return _dp36_timezone.make_aware(_dp36_datetime.combine(day, clock_time))


def _dp36_service_window(day):
    """Restaurant service day: 05:00 to 05:00 next day."""
    start = _dp36_timezone.make_aware(_dp36_datetime.combine(day, _dp36_time(5, 0)))
    end = start + _dp36_timedelta(days=1)
    return start, end


def _dp36_events(employee, day):
    start, end = _dp36_service_window(day)
    return list(_dp36_ClockEvent.objects.filter(employee=employee, timestamp__gte=start, timestamp__lt=end).order_by("timestamp"))


def _dp36_has_event(employee, day, clock_type):
    start, end = _dp36_service_window(day)
    return _dp36_ClockEvent.objects.filter(employee=employee, timestamp__gte=start, timestamp__lt=end, clock_type=clock_type).exists()


def _dp36_roster_shift(employee, day):
    shifts = list(_dp36_RosterShift.objects.filter(employee=employee, shift_date=day).order_by("start_time"))
    if not shifts:
        return None
    first = shifts[0]
    last = shifts[-1]
    start_dt = _dp36_make_aware(day, first.start_time)
    end_dt = _dp36_make_aware(day, last.end_time)
    if end_dt <= start_dt:
        end_dt += _dp36_timedelta(days=1)
    minutes = int((end_dt - start_dt).total_seconds() // 60)
    return {
        "start": start_dt,
        "end": end_dt,
        "start_label": first.start_time.strftime("%H:%M"),
        "end_label": last.end_time.strftime("%H:%M"),
        "label": f"{first.start_time.strftime('%H:%M')} - {last.end_time.strftime('%H:%M')}",
        "hours_label": f"{round(minutes / 60, 2)}h",
        "break_minutes": getattr(first, "break_minutes", 0) or 0,
    }


def _dp36_create_event(employee, clock_type, timestamp, note):
    return _dp36_ClockEvent.objects.create(
        employee=employee,
        clock_type=clock_type,
        timestamp=timestamp,
        method="MANAGER",
        notes=f"Manager quick fix: {note}",
    )


def _dp36_first_in_last_out(employee, day):
    events = _dp36_events(employee, day)
    ins = [e for e in events if e.clock_type == "IN"]
    outs = [e for e in events if e.clock_type == "OUT"]
    return (ins[0] if ins else None), (outs[-1] if outs else None)


def _dp36_apply_quick_fix(request):
    mode = request.POST.get("mode")
    employee_number = request.POST.get("employee_number")
    day_raw = request.POST.get("event_date")
    week_start = request.POST.get("week_start") or ""

    employee = _patch_get_object_or_404(_dp36_Employee, employee_number=employee_number)
    day = _dp36_parse_day(day_raw)
    shift = _dp36_roster_shift(employee, day)

    try:
        if mode == "pay_roster_shift":
            if not shift:
                _dp36_messages.error(request, "No roster shift found for this employee.")
            else:
                added = []
                if not _dp36_has_event(employee, day, "IN"):
                    _dp36_create_event(employee, "IN", shift["start"], f"paid roster shift start {shift['start_label']}")
                    added.append(f"clock-in {shift['start_label']}")
                if not _dp36_has_event(employee, day, "OUT"):
                    _dp36_create_event(employee, "OUT", shift["end"], f"paid roster shift finish {shift['end_label']}")
                    added.append(f"clock-out {shift['end_label']}")
                if added:
                    _dp36_messages.success(request, f"{employee.name}: roster shift used for payroll ({shift['label']}).")
                else:
                    _dp36_messages.info(request, f"{employee.name}: roster shift already has clock records.")

        elif mode == "clock_out_roster_finish":
            if not shift:
                _dp36_messages.error(request, "No roster finish time found for this shift.")
            elif _dp36_has_event(employee, day, "OUT"):
                _dp36_messages.info(request, f"{employee.name} already has a clock-out for this day.")
            else:
                _dp36_create_event(employee, "OUT", shift["end"], f"clocked out at roster finish {shift['end_label']}")
                _dp36_messages.success(request, f"{employee.name}: clock-out added at {shift['end_label']}.")

        elif mode == "enter_actual_finish":
            actual_time = request.POST.get("actual_time")
            if not actual_time:
                _dp36_messages.error(request, "Enter the finish time.")
            else:
                target_dt = _dp36_make_aware(day, _dp36_datetime.strptime(actual_time, "%H:%M").time())
                if shift and target_dt <= shift["start"]:
                    target_dt += _dp36_timedelta(days=1)
                _dp36_create_event(employee, "OUT", target_dt, f"entered actual finish {actual_time}")
                _dp36_messages.success(request, f"{employee.name}: clock-out added at {actual_time}.")

        elif mode == "enter_actual_shift":
            start_time = request.POST.get("start_time")
            finish_time = request.POST.get("finish_time")
            if not start_time or not finish_time:
                _dp36_messages.error(request, "Enter both start and finish times.")
            else:
                start_dt = _dp36_make_aware(day, _dp36_datetime.strptime(start_time, "%H:%M").time())
                finish_dt = _dp36_make_aware(day, _dp36_datetime.strptime(finish_time, "%H:%M").time())
                if finish_dt <= start_dt:
                    finish_dt += _dp36_timedelta(days=1)
                if not _dp36_has_event(employee, day, "IN"):
                    _dp36_create_event(employee, "IN", start_dt, f"entered actual start {start_time}")
                if not _dp36_has_event(employee, day, "OUT"):
                    _dp36_create_event(employee, "OUT", finish_dt, f"entered actual finish {finish_time}")
                _dp36_messages.success(request, f"{employee.name}: actual shift added ({start_time} - {finish_time}).")

        elif mode == "approve_unrostered_shift":
            first_in, last_out = _dp36_first_in_last_out(employee, day)
            if not first_in or not last_out:
                _dp36_messages.error(request, "This shift needs a start and finish time before it can be approved.")
            elif _dp36_RosterShift.objects.filter(employee=employee, shift_date=day).exists():
                _dp36_messages.info(request, f"{employee.name} already has a roster shift for this day.")
            else:
                start_time = _dp36_timezone.localtime(first_in.timestamp).time().replace(second=0, microsecond=0)
                finish_time = _dp36_timezone.localtime(last_out.timestamp).time().replace(second=0, microsecond=0)
                _dp36_RosterShift.objects.create(
                    employee=employee,
                    shift_date=day,
                    start_time=start_time,
                    end_time=finish_time,
                    break_minutes=0,
                )
                _dp36_messages.success(request, f"{employee.name}: unrostered shift approved for payroll.")

        else:
            _dp36_messages.error(request, "Unknown quick fix.")

    except Exception as exc:
        _dp36_messages.error(request, f"Could not apply quick fix: {exc}")

    return _dp36_redirect(f"/manager/payroll-problems/?week_start={week_start}")


def _dp36_payroll_problem_rows(week_start):
    rows = []
    today = _dp33_current_operational_date() if "_dp33_current_operational_date" in globals() else _dp36_timezone.localdate()

    for employee in _dp36_Employee.objects.filter(active=True).order_by("name"):
        for i in range(7):
            day = week_start + _dp36_timedelta(days=i)
            if day > today:
                continue

            d = _dp36_calculate_employee_day(employee, day, include_live=True)
            shift = _dp36_roster_shift(employee, day)
            problems = []
            quick = []

            # True payroll blockers only. Break warnings are not payroll blockers.
            if d.get("rostered") and not d.get("has_activity") and day < today:
                problems.append("No clock records")
                if shift:
                    quick.append({"mode": "pay_roster_shift", "label": f"Pay roster shift ({shift['label']})"})
                    quick.append({"mode": "enter_actual_shift", "label": "Enter actual times"})

            if d.get("missing_clock_out"):
                problems.append("Missing clock-out")
                if shift:
                    quick.append({"mode": "clock_out_roster_finish", "label": f"Clock out at {shift['end_label']}"})
                quick.append({"mode": "enter_actual_finish", "label": "Enter finish"})

            if d.get("invalid_sequence"):
                problems.append("Check clock events")

            if d.get("worked_minutes", 0) > 12 * 60:
                problems.append("Long shift")

            if d.get("has_activity") and not d.get("rostered"):
                problems.append("Unrostered shift")
                first_in, last_out = _dp36_first_in_last_out(employee, day)
                if first_in and last_out and not d.get("invalid_sequence"):
                    quick.append({"mode": "approve_unrostered_shift", "label": "Approve shift"})

            # Remove duplicates and ignore break/compliance warnings on the payroll blocker page.
            cleaned = []
            for p in problems:
                if not p or p == "OK":
                    continue
                if "break" in p.lower():
                    continue
                if p not in cleaned:
                    cleaned.append(p)
            problems = cleaned

            if not problems:
                continue

            if not quick:
                quick.append({"mode": "advanced", "label": "Review"})

            rows.append({
                "date": day,
                "employee_number": employee.employee_number,
                "employee": employee.name,
                "roster": d.get("roster"),
                "status": d.get("status"),
                "worked_hours": d.get("worked_hours"),
                "problem": "; ".join(problems),
                "quick_actions": quick,
            })
    return rows


@_dp31_login_required
def payroll_problems(request):
    if request.method == "POST":
        return _dp36_apply_quick_fix(request)

    week_start = _patch_parse_week_start(request)
    week_end = week_start + _dp36_timedelta(days=6)
    rows = _dp36_payroll_problem_rows(week_start)
    return render(request, "payroll_problems.html", {
        "week_start": week_start,
        "week_end": week_end,
        "rows": rows,
        "problem_count": len(rows),
    })


def _dp36_weekly_rows(week_start, standard_hours):
    raw_rows = _patch_get_week_rows(week_start, standard_hours)
    current_day = _dp33_current_operational_date() if "_dp33_current_operational_date" in globals() else _dp36_timezone.localdate()
    week_end = week_start + _dp36_timedelta(days=6)
    problem_rows = _dp36_payroll_problem_rows(week_start)
    problem_map = {}
    for problem in problem_rows:
        problem_map.setdefault(problem["employee_number"], []).append(f"{problem['date'].strftime('%a')}: {problem['problem']}")

    for row in raw_rows:
        rostered_minutes = int(float(row.get("rostered_hours", 0) or 0) * 60)
        paid_minutes = int(row.get("paid_minutes", 0) or 0)
        difference_minutes = paid_minutes - rostered_minutes
        problems = problem_map.get(row.get("employee_number"), [])
        future_rostered = week_end >= current_day and rostered_minutes > paid_minutes and current_day <= week_end

        if problems:
            row["review_status"] = "Review"
            row["review_reason"] = "; ".join(problems[:3])
            row["status_css"] = "warn"
        elif week_start <= current_day <= week_end and future_rostered:
            row["review_status"] = "In progress"
            row["review_reason"] = "Week not finished"
            row["status_css"] = "progress"
        elif rostered_minutes > 0 and paid_minutes == 0 and week_end < current_day:
            row["review_status"] = "Review"
            row["review_reason"] = "Rostered but no paid hours"
            row["status_css"] = "warn"
        elif abs(difference_minutes) > 4 * 60 and week_end < current_day:
            row["review_status"] = "Review"
            row["review_reason"] = f"Variance {_dp33_minutes_to_hours_label(abs(difference_minutes)) if '_dp33_minutes_to_hours_label' in globals() else round(abs(difference_minutes)/60,2)}"
            row["status_css"] = "warn"
        elif abs(difference_minutes) > 60 and week_end < current_day:
            row["review_status"] = "Check"
            row["review_reason"] = f"Variance {_dp33_minutes_to_hours_label(abs(difference_minutes)) if '_dp33_minutes_to_hours_label' in globals() else round(abs(difference_minutes)/60,2)}"
            row["status_css"] = "check"
        else:
            row["review_status"] = "OK"
            row["review_reason"] = ""
            row["status_css"] = "ok"
    return raw_rows


@_dp31_login_required
def manager_weekly_summary(request):
    week_start = _patch_parse_week_start(request)
    week_end = week_start + _dp36_timedelta(days=6)
    standard_hours = float(request.GET.get("standard_hours", "39"))
    period_number = request.GET.get("period", "1")
    summary_rows = _dp36_weekly_rows(week_start, standard_hours)
    summary_rows, export_rows = _dp31_add_export_strings(summary_rows)
    payroll_issue_rows = _dp36_payroll_problem_rows(week_start)
    payroll_ready_bool = len(payroll_issue_rows) == 0
    totals = {
        "rostered": round(sum(float(r.get("rostered_hours", 0) or 0) for r in summary_rows), 2),
        "paid": round(sum(float(r.get("paid_hours", 0) or 0) for r in summary_rows), 2),
        "normal": round(sum(float(r.get("normal_hours", 0) or 0) for r in summary_rows), 2),
        "sunday": round(sum(float(r.get("sunday_hours", 0) or 0) for r in summary_rows), 2),
        "overtime": round(sum(float(r.get("overtime_hours", 0) or 0) for r in summary_rows), 2),
    }
    return render(request, "weekly_summary.html", {
        "week_start": week_start,
        "week_end": week_end,
        "summary_rows": summary_rows,
        "export_rows": export_rows,
        "standard_hours": standard_hours,
        "period_number": period_number,
        "payroll_problem_count": len(payroll_issue_rows),
        "payroll_ready": payroll_ready_bool,
        "totals": totals,
    })

# -------------------------------------------------------------------
# Delivery patch 38: one payroll issue engine + manager-first fixes
# -------------------------------------------------------------------
from datetime import datetime as _dp38_datetime, timedelta as _dp38_timedelta
from django.contrib import messages as _dp38_messages
from django.http import HttpResponse as _dp38_HttpResponse
from django.shortcuts import redirect as _dp38_redirect, render as _dp38_render
from django.utils import timezone as _dp38_timezone
import csv as _dp38_csv


def _dp38_event_minute(ev):
    return _dp38_timezone.localtime(ev.timestamp).replace(second=0, microsecond=0)


def _dp38_events_unique(employee, day):
    """Return events with exact duplicate clock records collapsed for issue detection."""
    unique = []
    seen = set()
    for ev in _dp36_events(employee, day):
        key = (ev.clock_type, _dp38_event_minute(ev))
        if key in seen:
            continue
        seen.add(key)
        unique.append(ev)
    return unique


def _dp38_first_and_last_any(employee, day):
    events = _dp38_events_unique(employee, day)
    if not events:
        return None, None
    return events[0], events[-1]


def _dp38_first_in_last_out_unique(employee, day):
    events = _dp38_events_unique(employee, day)
    ins = [e for e in events if e.clock_type == "IN"]
    outs = [e for e in events if e.clock_type == "OUT"]
    return (ins[0] if ins else None), (outs[-1] if outs else None)


def _dp38_sequence_problem(employee, day):
    """Only flags genuinely odd payroll-blocking event sequences."""
    events = _dp38_events_unique(employee, day)
    if not events:
        return False

    # Valid simple payroll sequence after ignoring break events: IN ... OUT
    work_events = [e.clock_type for e in events if e.clock_type in ("IN", "OUT")]
    if not work_events:
        return True
    if work_events.count("IN") != 1 or work_events.count("OUT") != 1:
        return True
    if work_events[0] != "IN" or work_events[-1] != "OUT":
        return True

    # Breaks should not block payroll, but impossible ordering should be reviewed.
    break_balance = 0
    for ev in events:
        if ev.clock_type == "BREAK_START":
            break_balance += 1
        elif ev.clock_type == "BREAK_END":
            if break_balance <= 0:
                return True
            break_balance -= 1
    return False


def _dp38_delete_day_events(employee, day):
    start, end = _dp36_service_window(day)
    _dp36_ClockEvent.objects.filter(employee=employee, timestamp__gte=start, timestamp__lt=end).delete()


def _dp38_create_clean_shift(employee, start_dt, end_dt, note):
    if end_dt <= start_dt:
        end_dt += _dp38_timedelta(days=1)
    _dp36_create_event(employee, "IN", start_dt, f"{note} start")
    _dp36_create_event(employee, "OUT", end_dt, f"{note} finish")


def _dp38_apply_quick_fix(request):
    mode = request.POST.get("mode")
    employee_number = request.POST.get("employee_number")
    day_raw = request.POST.get("event_date")
    week_start = request.POST.get("week_start") or ""

    employee = _patch_get_object_or_404(_dp36_Employee, employee_number=employee_number)
    day = _dp36_parse_day(day_raw)
    shift = _dp36_roster_shift(employee, day)

    try:
        if mode == "pay_roster_shift":
            if not shift:
                _dp38_messages.error(request, "No roster shift found for this employee.")
            else:
                _dp38_delete_day_events(employee, day)
                _dp38_create_clean_shift(employee, shift["start"], shift["end"], f"paid roster hours {shift['label']}")
                _dp38_messages.success(request, f"{employee.name}: paid roster hours ({shift['label']}).")

        elif mode == "clock_out_roster_finish":
            if not shift:
                _dp38_messages.error(request, "No roster finish time found.")
            else:
                first_in, _last_out = _dp38_first_in_last_out_unique(employee, day)
                # Keep the real clock-in where possible, but rebuild a clean payroll sequence.
                start_dt = first_in.timestamp if first_in else shift["start"]
                _dp38_delete_day_events(employee, day)
                _dp38_create_clean_shift(employee, start_dt, shift["end"], f"clocked out at roster finish {shift['end_label']}")
                _dp38_messages.success(request, f"{employee.name}: clocked out at {shift['end_label']}.")

        elif mode == "enter_actual_finish":
            actual = request.POST.get("actual_time")
            if not actual:
                _dp38_messages.error(request, "Enter the finish time.")
            else:
                finish_dt = _dp36_make_aware(day, _dp38_datetime.strptime(actual, "%H:%M").time())
                first_in, _last_out = _dp38_first_in_last_out_unique(employee, day)
                start_dt = first_in.timestamp if first_in else (shift["start"] if shift else None)
                if not start_dt:
                    _dp38_messages.error(request, "No start time found. Use Enter actual times instead.")
                else:
                    if finish_dt <= start_dt:
                        finish_dt += _dp38_timedelta(days=1)
                    _dp38_delete_day_events(employee, day)
                    _dp38_create_clean_shift(employee, start_dt, finish_dt, f"actual finish entered by manager {actual}")
                    _dp38_messages.success(request, f"{employee.name}: finish set to {actual}.")

        elif mode == "enter_actual_shift":
            start_raw = request.POST.get("start_time")
            finish_raw = request.POST.get("finish_time")
            if not start_raw or not finish_raw:
                _dp38_messages.error(request, "Enter start and finish times.")
            else:
                start_dt = _dp36_make_aware(day, _dp38_datetime.strptime(start_raw, "%H:%M").time())
                finish_dt = _dp36_make_aware(day, _dp38_datetime.strptime(finish_raw, "%H:%M").time())
                _dp38_delete_day_events(employee, day)
                _dp38_create_clean_shift(employee, start_dt, finish_dt, f"actual shift entered by manager {start_raw}-{finish_raw}")
                _dp38_messages.success(request, f"{employee.name}: paid actual times {start_raw} - {finish_raw}.")

        elif mode == "approve_unrostered_shift":
            first_in, last_out = _dp38_first_in_last_out_unique(employee, day)
            if not first_in or not last_out:
                _dp38_messages.error(request, "This shift needs a clock-in and clock-out before it can be approved.")
            else:
                if not _dp36_roster_shift(employee, day):
                    start_time = _dp38_timezone.localtime(first_in.timestamp).time().replace(second=0, microsecond=0)
                    finish_time = _dp38_timezone.localtime(last_out.timestamp).time().replace(second=0, microsecond=0)
                    _dp36_RosterShift.objects.create(
                        employee=employee,
                        shift_date=day,
                        start_time=start_time,
                        end_time=finish_time,
                        break_minutes=0,
                    )
                _dp38_messages.success(request, f"{employee.name}: cover shift approved for payroll.")

        elif mode == "pay_actual_time":
            first, last = _dp38_first_and_last_any(employee, day)
            if not first or not last or first.timestamp == last.timestamp:
                _dp38_messages.error(request, "Not enough clock information. Enter actual times instead.")
            else:
                start_dt = first.timestamp
                end_dt = last.timestamp
                _dp38_delete_day_events(employee, day)
                _dp38_create_clean_shift(employee, start_dt, end_dt, "paid actual clock span")
                _dp38_messages.success(
                    request,
                    f"{employee.name}: paid actual time {_dp38_timezone.localtime(start_dt).strftime('%H:%M')} - {_dp38_timezone.localtime(end_dt).strftime('%H:%M')}.",
                )

        else:
            _dp38_messages.error(request, "Unknown quick fix.")

    except Exception as exc:
        _dp38_messages.error(request, f"Could not apply quick fix: {exc}")

    return _dp38_redirect(f"/manager/payroll-problems/?week_start={week_start}")


def _dp38_payroll_problem_rows(week_start):
    """Single issue list used by Payroll Issues, Weekly Review and Sage export."""
    rows = []
    today = _dp33_current_operational_date() if "_dp33_current_operational_date" in globals() else _dp36_timezone.localdate()

    for employee in _dp36_Employee.objects.filter(active=True).order_by("name"):
        for i in range(7):
            day = week_start + _dp36_timedelta(days=i)
            if day > today:
                continue

            d = _dp36_calculate_employee_day(employee, day, include_live=True)
            shift = _dp36_roster_shift(employee, day)
            events = _dp38_events_unique(employee, day)
            first_in, last_out = _dp38_first_in_last_out_unique(employee, day)
            problems = []
            quick = []

            # Common restaurant cases first. These are the things a manager can fix quickly.
            if shift and not events and day < today:
                problems.append("No clock records")
                quick.append({"mode": "pay_roster_shift", "label": f"Pay roster hours ({shift['label']})"})
                quick.append({"mode": "enter_actual_shift", "label": "Enter actual times"})

            elif shift and first_in and not last_out:
                problems.append("Missing clock-out")
                quick.append({"mode": "clock_out_roster_finish", "label": f"Clock out at {shift['end_label']}"})
                quick.append({"mode": "enter_actual_finish", "label": "Enter finish"})

            elif events and not shift:
                if first_in and last_out and not _dp38_sequence_problem(employee, day):
                    problems.append("Unrostered shift")
                    quick.append({"mode": "approve_unrostered_shift", "label": "Approve shift"})
                else:
                    problems.append("Check clock events")
                    quick.append({"mode": "pay_actual_time", "label": "Pay actual time"})
                    quick.append({"mode": "enter_actual_shift", "label": "Enter correct times"})

            elif events and _dp38_sequence_problem(employee, day):
                problems.append("Check clock events")
                quick.append({"mode": "pay_actual_time", "label": "Pay actual time"})
                quick.append({"mode": "enter_actual_shift", "label": "Enter correct times"})

            # Long paid shifts are worth reviewing, but breaks alone do not block payroll.
            if d.get("worked_minutes", 0) > 12 * 60:
                problems.append("Long shift")

            cleaned = []
            for problem in problems:
                if not problem:
                    continue
                if "break" in problem.lower():
                    continue
                if problem not in cleaned:
                    cleaned.append(problem)
            problems = cleaned

            if not problems:
                continue

            if not quick:
                quick.append({"mode": "advanced", "label": "Review"})

            rows.append({
                "date": day,
                "employee_number": employee.employee_number,
                "employee": employee.name,
                "roster": d.get("roster"),
                "status": d.get("status"),
                "worked_hours": d.get("worked_hours"),
                "problem": "; ".join(problems),
                "quick_actions": quick,
            })
    return rows


def _dp30_payroll_is_ready(week_start):
    rows = _dp38_payroll_problem_rows(week_start)
    return (len(rows) == 0), rows


@_dp31_login_required
def payroll_problems(request):
    if request.method == "POST":
        return _dp38_apply_quick_fix(request)

    week_start = _patch_parse_week_start(request)
    week_end = week_start + _dp36_timedelta(days=6)
    rows = _dp38_payroll_problem_rows(week_start)
    return _dp38_render(request, "payroll_problems.html", {
        "week_start": week_start,
        "week_end": week_end,
        "rows": rows,
        "problem_count": len(rows),
    })


def _dp38_weekly_rows(week_start, standard_hours):
    raw_rows = _patch_get_week_rows(week_start, standard_hours)
    current_day = _dp33_current_operational_date() if "_dp33_current_operational_date" in globals() else _dp36_timezone.localdate()
    week_end = week_start + _dp36_timedelta(days=6)
    problem_rows = _dp38_payroll_problem_rows(week_start)
    problem_map = {}
    for problem in problem_rows:
        problem_map.setdefault(problem["employee_number"], []).append(f"{problem['date'].strftime('%a')}: {problem['problem']}")

    for row in raw_rows:
        rostered_minutes = int(float(row.get("rostered_hours", 0) or 0) * 60)
        paid_minutes = int(row.get("paid_minutes", 0) or 0)
        difference_minutes = paid_minutes - rostered_minutes
        problems = problem_map.get(row.get("employee_number"), [])
        future_rostered = week_start <= current_day <= week_end and rostered_minutes > paid_minutes

        if problems:
            row["review_status"] = "Review"
            row["review_reason"] = "; ".join(problems[:3])
            row["status_css"] = "warn"
        elif future_rostered:
            row["review_status"] = "In progress"
            row["review_reason"] = "Week not finished"
            row["status_css"] = "progress"
        elif rostered_minutes > 0 and paid_minutes == 0 and week_end < current_day:
            row["review_status"] = "Review"
            row["review_reason"] = "Rostered but no paid hours"
            row["status_css"] = "warn"
        elif abs(difference_minutes) > 4 * 60:
            row["review_status"] = "Review"
            row["review_reason"] = f"Variance {_dp33_minutes_to_hours_label(abs(difference_minutes))}" if "_dp33_minutes_to_hours_label" in globals() else "Large variance"
            row["status_css"] = "warn"
        elif abs(difference_minutes) > 60:
            row["review_status"] = "Check"
            row["review_reason"] = f"Variance {_dp33_minutes_to_hours_label(abs(difference_minutes))}" if "_dp33_minutes_to_hours_label" in globals() else "Variance"
            row["status_css"] = "check"
        else:
            row["review_status"] = "OK"
            row["review_reason"] = ""
            row["status_css"] = "ok"
    return raw_rows


def _dp33_weekly_rows(week_start, standard_hours):
    return _dp38_weekly_rows(week_start, standard_hours)


def export_sage_payroll_csv(request):
    week_start = _patch_parse_week_start(request)
    period_number = request.GET.get("period", "1")
    standard_hours = float(request.GET.get("standard_hours", "39"))

    payroll_ready_bool, payroll_problem_rows = _dp30_payroll_is_ready(week_start)
    if not payroll_ready_bool:
        response = _dp38_HttpResponse(content_type="text/plain", status=400)
        response.write("Payroll is not ready. Fix the payroll issues shown on the Payroll Issues page.\n")
        for row in payroll_problem_rows:
            response.write(f"{row.get('date')} - {row.get('employee')}: {row.get('problem')}\n")
        return response

    rows = _patch_get_week_rows(week_start, standard_hours)
    response = _dp38_HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = 'attachment; filename="sage_payroll_export.csv"'
    writer = _dp38_csv.writer(response)
    for row in rows:
        employee_number = row.get("employee_number")
        normal = _dp31_minutes_to_decimal_string(row.get("normal_minutes", 0)) if "_dp31_minutes_to_decimal_string" in globals() else str(row.get("normal_hours", 0))
        sunday = _dp31_minutes_to_decimal_string(row.get("sunday_minutes", 0)) if "_dp31_minutes_to_decimal_string" in globals() else str(row.get("sunday_hours", 0))
        overtime = _dp31_minutes_to_decimal_string(row.get("overtime_minutes", 0)) if "_dp31_minutes_to_decimal_string" in globals() else str(row.get("overtime_hours", 0))
        if normal == "0.00" and sunday == "0.00" and overtime == "0.00":
            continue
        writer.writerow([period_number, employee_number, "0000", normal, sunday, overtime])
    return response
