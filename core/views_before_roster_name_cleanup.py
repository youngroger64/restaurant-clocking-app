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
    """Manager roster upload and review.

    Production rule:
    - uploading a CSV replaces roster shifts for the uploaded week
    - clock records are never deleted by roster upload
    - rows are validated before anything is deleted
    """
    message = ""
    error = ""

    def _parse_date(value):
        value = (value or "").strip()
        for fmt in ("%Y-%m-%d", "%d/%m/%Y", "%d-%m-%Y"):
            try:
                return datetime.strptime(value, fmt).date()
            except ValueError:
                pass
        raise ValueError(f"Invalid date '{value}'. Use YYYY-MM-DD or DD/MM/YYYY.")

    def _parse_time(value):
        value = (value or "").strip()
        for fmt in ("%H:%M", "%H:%M:%S"):
            try:
                return datetime.strptime(value, fmt).time()
            except ValueError:
                pass
        raise ValueError(f"Invalid time '{value}'. Use HH:MM.")

    def _week_start_for(day):
        return day - timedelta(days=day.weekday())

    raw_week_start = request.GET.get("week_start") or request.POST.get("week_start")
    if raw_week_start:
        try:
            week_start = _parse_date(raw_week_start)
            week_start = _week_start_for(week_start)
        except Exception:
            week_start = timezone.localdate() - timedelta(days=timezone.localdate().weekday())
    else:
        week_start = timezone.localdate() - timedelta(days=timezone.localdate().weekday())
    week_end = week_start + timedelta(days=6)

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
            row_errors = []
            for line_no, row in enumerate(reader, start=2):
                try:
                    emp_no = (row.get("EmployeeNumber") or "").strip()
                    emp_name = (row.get("EmployeeName") or "").strip()
                    if not emp_no:
                        raise ValueError("EmployeeNumber is blank")
                    if not emp_name:
                        raise ValueError("EmployeeName is blank")

                    shift_date = _parse_date(row.get("Date"))
                    start_time = _parse_time(row.get("StartTime"))
                    end_time = _parse_time(row.get("EndTime"))
                    if start_time == end_time:
                        raise ValueError("Start and end time are the same")

                    raw_break = (row.get("BreakMinutes") or "0").strip()
                    break_minutes = int(raw_break or 0)
                    if break_minutes < 0:
                        raise ValueError("BreakMinutes cannot be negative")

                    parsed_rows.append({
                        "employee_number": emp_no,
                        "employee_name": emp_name,
                        "shift_date": shift_date,
                        "start_time": start_time,
                        "end_time": end_time,
                        "break_minutes": break_minutes,
                    })
                except Exception as exc:
                    row_errors.append(f"Row {line_no}: {exc}")

            if row_errors:
                raise ValueError("Roster upload has errors:\n" + "\n".join(row_errors[:20]))
            if not parsed_rows:
                raise ValueError("The CSV did not contain any roster rows.")

            weeks = {_week_start_for(r["shift_date"]) for r in parsed_rows}
            if len(weeks) != 1:
                raise ValueError("Upload one roster week at a time. The CSV contains multiple weeks.")

            week_start = weeks.pop()
            week_end = week_start + timedelta(days=6)

            # Validate duplicates inside the file before deleting existing roster rows.
            seen = set()
            duplicates = []
            for r in parsed_rows:
                key = (r["employee_number"], r["shift_date"], r["start_time"], r["end_time"])
                if key in seen:
                    duplicates.append(f"{r['employee_number']} {r['shift_date']} {r['start_time']}-{r['end_time']}")
                seen.add(key)
            if duplicates:
                raise ValueError("Duplicate shifts in CSV: " + "; ".join(duplicates[:10]))

            # Production behaviour: replace the roster for this week only.
            # Clock events are deliberately left untouched.
            deleted_count, _ = RosterShift.objects.filter(
                shift_date__gte=week_start,
                shift_date__lte=week_end,
            ).delete()

            created_count = 0
            employees_created = 0
            employees_updated = 0
            for r in parsed_rows:
                employee, created = Employee.objects.get_or_create(
                    employee_number=r["employee_number"],
                    defaults={
                        "name": r["employee_name"],
                        "pin": r["employee_number"],
                        "active": True,
                    },
                )
                if created:
                    employees_created += 1
                else:
                    changed = False
                    if employee.name != r["employee_name"]:
                        employee.name = r["employee_name"]
                        changed = True
                    if not employee.active:
                        employee.active = True
                        changed = True
                    if changed:
                        employee.save()
                        employees_updated += 1

                RosterShift.objects.create(
                    employee=employee,
                    shift_date=r["shift_date"],
                    start_time=r["start_time"],
                    end_time=r["end_time"],
                    break_minutes=r["break_minutes"],
                )
                created_count += 1

            message = (
                f"Roster imported for {week_start.strftime('%d/%m/%Y')} - {week_end.strftime('%d/%m/%Y')}. "
                f"Replaced {deleted_count} old shift(s). Added {created_count} shift(s). "
                f"Created {employees_created} employee(s). Updated {employees_updated} employee(s). "
                "Clock records were not changed."
            )
        except Exception as exc:
            error = str(exc)

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


def _patch_payroll_problem_rows(week_start):
    """
    Single source of truth for payroll problems.

    The weekly payroll page, payroll problems page, and Sage export safety
    must all use this function. Otherwise the manager can see "2 issues" on
    Weekly Payroll, click through, and see "No payroll problems found".
    """
    rows = []

    for employee in Employee.objects.filter(active=True).order_by("name"):
        for i in range(7):
            day = week_start + timedelta(days=i)
            d = _patch_calculate_employee_day(employee, day, include_live=True)
            problems = []

            if d.get("missing_clock_out"):
                problems.append("Missing clock-out")
            if d.get("invalid_sequence"):
                problems.append("Check clock events")
            if d.get("is_urgent"):
                issue = d.get("issue")
                if issue and issue != "OK":
                    problems.append(issue)
            if d.get("worked_hours", 0) > 12:
                problems.append("Unusually long shift")

            # Do not show duplicate wording in the manager-facing problem list.
            clean = []
            for item in problems:
                if item and item not in clean:
                    clean.append(item)

            if clean:
                rows.append({
                    "date": day,
                    "employee_number": employee.employee_number,
                    "employee": employee.name,
                    "roster": d.get("roster"),
                    "status": d.get("status"),
                    "worked_hours": d.get("worked_hours"),
                    "break_minutes": d.get("break_minutes"),
                    "problem": "; ".join(clean),
                })

    return rows










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




# -------------------------------------------------------------------
# Patch 25: weekly payroll uses shared live roster calculations
# -------------------------------------------------------------------




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





# -------------------------------------------------------------------
# Delivery patch 28: overnight operational day fix
# -------------------------------------------------------------------
# Real restaurant behaviour: at 00:06, a 16:00-23:00 or 23:00-00:00 shift
# has not magically become yesterday's payroll error. The live dashboard must
# keep showing open staff until the operational day rolls over at 05:00.
from core.compliance import current_operational_date as _dp28_current_operational_date





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





# -------------------------------------------------------------------
# Delivery patch 33: payroll quick fixes + manager-friendly weekly review status
# -------------------------------------------------------------------

# Old patch-era payroll code removed. Active payroll lives in core/services/payroll.py

from django.contrib.auth.decorators import login_required as _p48_login_required
from django.shortcuts import render as _p48_render
from core.services.payroll import (
    parse_week_start as _p48_parse_week_start,
    get_payroll_blocker_rows as _p48_get_payroll_blocker_rows,
    get_manager_review_rows as _p48_get_manager_review_rows,
    payroll_is_ready as _p48_payroll_is_ready,
    get_weekly_summary_rows as _p48_get_weekly_summary_rows,
    get_export_rows as _p48_get_export_rows,
    get_weekly_totals as _p48_get_weekly_totals,
    build_sage_csv_response as _p48_build_sage_csv_response,
    apply_quick_fix as _p48_apply_quick_fix,
)

# Keep older dashboard/home functions synced without rewriting them here.
_dp30_payroll_is_ready = _p48_payroll_is_ready


@_p48_login_required
def payroll_problems(request):
    if request.method == "POST":
        return _p48_apply_quick_fix(request)

    week_start = _p48_parse_week_start(request)
    week_end = week_start + timedelta(days=6)
    rows = _p48_get_payroll_blocker_rows(week_start)
    review_rows = _p48_get_manager_review_rows(week_start)
    return _p48_render(request, "payroll_problems.html", {
        "week_start": week_start,
        "week_end": week_end,
        "rows": rows,
        "review_rows": review_rows,
        "problem_count": len(rows),
        "payroll_problem_count": len(rows),
        "unresolved_problem_count": len(rows),
        "manager_review_count": len(review_rows),
    })


@_p48_login_required
def manager_weekly_summary(request):
    week_start = _p48_parse_week_start(request)
    week_end = week_start + timedelta(days=6)
    standard_hours = float(request.GET.get("standard_hours", "39") or 39)
    period_number = request.GET.get("period", "1") or "1"
    summary_rows = _p48_get_weekly_summary_rows(week_start, standard_hours)
    export_rows = _p48_get_export_rows(week_start, standard_hours)
    payroll_ready_bool, payroll_issue_rows = _p48_payroll_is_ready(week_start)
    review_rows = _p48_get_manager_review_rows(week_start)
    totals = _p48_get_weekly_totals(summary_rows)

    return _p48_render(request, "weekly_summary.html", {
        "week_start": week_start,
        "week_end": week_end,
        "summary_rows": summary_rows,
        "rows": summary_rows,
        "export_rows": export_rows,
        "standard_hours": standard_hours,
        "period_number": period_number,
        "payroll_ready": payroll_ready_bool,
        "payroll_problem_count": len(payroll_issue_rows),
        "unresolved_problem_count": len(payroll_issue_rows),
        "manager_review_count": len(review_rows),
        "totals": totals,
    })


@_p48_login_required
def export_sage_payroll_csv(request):
    week_start = _p48_parse_week_start(request)
    week_end = week_start + timedelta(days=6)
    period_number = request.GET.get("period", "1") or "1"
    standard_hours = float(request.GET.get("standard_hours", "39") or 39)
    allow_unresolved = request.GET.get("allow_unresolved") == "1"
    payroll_ready_bool, payroll_issue_rows = _p48_payroll_is_ready(week_start)

    if payroll_issue_rows and not allow_unresolved:
        return _p48_render(request, "payroll_export_blocked.html", {
            "week_start": week_start,
            "week_end": week_end,
            "problem_count": len(payroll_issue_rows),
            "payroll_problem_count": len(payroll_issue_rows),
            "unresolved_problem_count": len(payroll_issue_rows),
            "problems": payroll_issue_rows,
            "standard_hours": standard_hours,
            "period_number": period_number,
        })

    return _p48_build_sage_csv_response(week_start, standard_hours, period_number)

