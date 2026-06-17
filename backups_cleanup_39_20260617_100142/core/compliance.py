from datetime import datetime, time, timedelta

from django.utils import timezone

from .models import Employee, ClockEvent, RosterShift


OPERATIONAL_DAY_START_HOUR = 5


def current_operational_date():
    local_now = timezone.localtime(timezone.now())
    if local_now.time() < time(OPERATIONAL_DAY_START_HOUR, 0):
        return local_now.date() - timedelta(days=1)
    return local_now.date()


def format_minutes(minutes):
    minutes = int(minutes or 0)
    if minutes < 60:
        return f"{minutes} mins"
    hours = minutes // 60
    mins = minutes % 60
    if mins == 0:
        return f"{hours}h"
    return f"{hours}h {mins}m"


def required_break_minutes(worked_minutes):
    if worked_minutes > 360:
        return 30
    if worked_minutes > 270:
        return 15
    return 0


def operational_window(selected_date):
    start = timezone.make_aware(datetime.combine(selected_date, time(OPERATIONAL_DAY_START_HOUR, 0)))
    return start, start + timedelta(days=1)


def _local_hhmm(dt):
    if not dt:
        return "-"
    return timezone.localtime(dt).strftime("%H:%M")


def _planned_start_dt(selected_date, planned_start):
    return timezone.make_aware(datetime.combine(selected_date, planned_start))


def _planned_end_dt(selected_date, planned_start, planned_end):
    if not planned_end:
        return None
    start_dt = _planned_start_dt(selected_date, planned_start)
    end_dt = timezone.make_aware(datetime.combine(selected_date, planned_end))
    if end_dt <= start_dt:
        end_dt += timedelta(days=1)
    return end_dt


def get_roster_info(employee, selected_date):
    shifts = RosterShift.objects.filter(employee=employee, shift_date=selected_date).order_by("start_time")
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
            rostered_minutes -= int(shift.break_minutes or 0)
        roster_text = ", ".join(parts)

    return {
        "rostered": rostered,
        "roster_text": roster_text,
        "planned_start": planned_start,
        "planned_end": planned_end,
        "rostered_minutes": max(0, rostered_minutes),
    }


def _events_for_operational_day(employee, selected_date):
    start, end = operational_window(selected_date)
    return ClockEvent.objects.filter(employee=employee, timestamp__gte=start, timestamp__lt=end).order_by("timestamp")


def build_break_status(worked_minutes, break_minutes, is_working, is_on_break, invalid_sequence=False):
    if invalid_sequence:
        return {
            "break_status": "Check clock events",
            "break_css": "break-urgent",
            "break_action": "Fix the clock times before payroll.",
            "required_break": required_break_minutes(worked_minutes),
        }

    required_break = required_break_minutes(worked_minutes)
    remaining_to_15 = max(0, 271 - worked_minutes)
    remaining_to_30 = max(0, 361 - worked_minutes)

    if is_on_break:
        return {
            "break_status": "On break now",
            "break_css": "break-on",
            "break_action": "No action unless break runs too long.",
            "required_break": required_break,
        }

    if required_break and break_minutes >= required_break:
        return {
            "break_status": "OK",
            "break_css": "break-ok",
            "break_action": "No action.",
            "required_break": required_break,
        }

    if worked_minutes > 360 and break_minutes < 30:
        return {
            "break_status": "30 min break overdue",
            "break_css": "break-urgent",
            "break_action": "Give or record the break.",
            "required_break": 30,
        }

    if worked_minutes > 270 and break_minutes < 15:
        return {
            "break_status": "15 min break overdue",
            "break_css": "break-urgent",
            "break_action": "Give or record the break.",
            "required_break": 15,
        }

    if is_working and worked_minutes >= 345 and break_minutes < 30:
        return {
            "break_status": f"30 min break due in {format_minutes(remaining_to_30)}",
            "break_css": "break-warn",
            "break_action": "Plan break soon.",
            "required_break": 30,
        }

    if is_working and worked_minutes >= 255 and break_minutes < 15:
        return {
            "break_status": f"15 min break due in {format_minutes(remaining_to_15)}",
            "break_css": "break-warn",
            "break_action": "Plan break soon.",
            "required_break": 15,
        }

    if is_working and worked_minutes >= 240 and break_minutes < 15:
        return {
            "break_status": f"Break in {format_minutes(remaining_to_15)}",
            "break_css": "break-warn",
            "break_action": "Plan break soon.",
            "required_break": 15,
        }

    return {
        "break_status": "OK for now",
        "break_css": "break-ok",
        "break_action": "No action.",
        "required_break": required_break,
    }


def calculate_employee_day(employee, selected_date, include_live=True):
    events = _events_for_operational_day(employee, selected_date)
    roster = get_roster_info(employee, selected_date)

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
            if work_start is not None or break_start is not None:
                invalid_sequence = True
            work_start = event.timestamp

        elif event.clock_type == "BREAK_START":
            if work_start is not None:
                worked_minutes += max(0, int((event.timestamp - work_start).total_seconds() / 60))
                work_start = None
            else:
                invalid_sequence = True
            if break_start is not None:
                invalid_sequence = True
            break_start = event.timestamp

        elif event.clock_type == "BREAK_END":
            if break_start is not None:
                break_minutes += max(0, int((event.timestamp - break_start).total_seconds() / 60))
                break_start = None
            else:
                invalid_sequence = True
            work_start = event.timestamp

        elif event.clock_type == "OUT":
            last_out = event.timestamp
            if work_start is not None:
                worked_minutes += max(0, int((event.timestamp - work_start).total_seconds() / 60))
                work_start = None
            elif break_start is not None:
                # A clock-out straight from break is usually a manager correction case.
                break_minutes += max(0, int((event.timestamp - break_start).total_seconds() / 60))
                break_start = None
                invalid_sequence = True
            else:
                invalid_sequence = True

    now = timezone.now()
    today = current_operational_date()
    currently_open_work = work_start is not None
    currently_open_break = break_start is not None

    if include_live and selected_date == today:
        if currently_open_work:
            worked_minutes += max(0, int((now - work_start).total_seconds() / 60))
        elif currently_open_break:
            break_minutes += max(0, int((now - break_start).total_seconds() / 60))

    if break_minutes > worked_minutes and worked_minutes < 60:
        invalid_sequence = True

    status = "No activity"
    if latest_event:
        status = {
            "IN": "Working now",
            "BREAK_START": "On break",
            "BREAK_END": "Working now",
            "OUT": "Finished",
        }.get(latest_event.clock_type, "No activity")

    is_working = bool(latest_event and latest_event.clock_type in ["IN", "BREAK_END"])
    is_on_break = bool(latest_event and latest_event.clock_type == "BREAK_START")
    is_clocked_out = bool(latest_event and latest_event.clock_type == "OUT")

    break_info = build_break_status(worked_minutes, break_minutes, is_working, is_on_break, invalid_sequence)
    required_break = break_info["required_break"]

    urgent_issues = []
    operational_issues = []

    if invalid_sequence:
        urgent_issues.append("Check clock events")

    if latest_event and not roster["rostered"]:
        urgent_issues.append("Unrostered shift")

    # Absent/late is a review item only. It is not shown as a top-card count.
    if roster["rostered"] and not latest_event and selected_date == today and roster["planned_start"]:
        planned_dt = _planned_start_dt(selected_date, roster["planned_start"])
        if now > planned_dt + timedelta(minutes=30):
            operational_issues.append("Absent")
        elif now > planned_dt + timedelta(minutes=10):
            operational_issues.append("Late")

    if is_working:
        if worked_minutes > 360 and break_minutes < 30:
            urgent_issues.append("30 min break overdue")
        elif worked_minutes > 270 and break_minutes < 15:
            urgent_issues.append("15 min break overdue")
        elif break_info["break_css"] == "break-warn":
            operational_issues.append(break_info["break_status"])

    if is_clocked_out and required_break > 0 and break_minutes < required_break:
        urgent_issues.append("Break missing or too short")

    if latest_event and latest_event.clock_type in ["IN", "BREAK_START", "BREAK_END"]:
        if selected_date < today:
            urgent_issues.append("Missing clock-out")
        elif worked_minutes > 14 * 60:
            urgent_issues.append("Very long open shift")

    if first_in and roster["planned_start"]:
        planned_start_dt = _planned_start_dt(selected_date, roster["planned_start"])
        planned_end_dt = _planned_end_dt(selected_date, roster["planned_start"], roster["planned_end"])
        late_minutes = int((first_in - planned_start_dt).total_seconds() / 60)
        if planned_end_dt and first_in > planned_end_dt:
            operational_issues.append("Clocked in after shift ended")
        elif late_minutes > 10:
            operational_issues.append(f"Late by {late_minutes} mins")
        elif late_minutes < -15:
            operational_issues.append(f"Clocked in {abs(late_minutes)} mins early")

    if worked_minutes > 12 * 60:
        operational_issues.append("Long shift")

    issue_type = "OK"
    issue_text = "OK"
    if urgent_issues:
        issue_type = "Urgent"
        issue_text = "; ".join(dict.fromkeys([x for x in urgent_issues if x]))
    elif operational_issues:
        issue_type = "Operational"
        issue_text = "; ".join(dict.fromkeys([x for x in operational_issues if x]))

    paid_minutes = max(0, worked_minutes)

    return {
        "employee_number": employee.employee_number,
        "employee": employee.name,
        "employee_obj": employee,
        "date": selected_date,
        "roster": roster["roster_text"],
        "rostered": roster["rostered"],
        "rostered_minutes": roster["rostered_minutes"],
        "first_in": _local_hhmm(first_in),
        "last_out": _local_hhmm(last_out),
        "status": status,
        "worked_minutes": worked_minutes,
        "break_minutes": break_minutes,
        "paid_minutes": paid_minutes,
        "worked_hours": round(worked_minutes / 60, 2),
        "break_hours": round(break_minutes / 60, 2),
        "paid_hours": round(paid_minutes / 60, 2),
        "required_break": required_break,
        "break_status": break_info["break_status"],
        "break_css": break_info["break_css"],
        "break_action": break_info["break_action"],
        "issue_type": issue_type,
        "issue": issue_text,
        "is_urgent": issue_type == "Urgent",
        "is_operational": issue_type == "Operational",
        "is_working": is_working,
        "is_on_break": is_on_break,
        "is_clocked_out": is_clocked_out,
        "has_activity": latest_event is not None,
        "missing_clock_out": bool(latest_event and latest_event.clock_type in ["IN", "BREAK_START", "BREAK_END"] and selected_date < today),
        "invalid_sequence": invalid_sequence,
    }


def get_day_rows(selected_date):
    return [calculate_employee_day(employee, selected_date, include_live=True) for employee in Employee.objects.filter(active=True).order_by("name")]


def get_payroll_problem_rows(week_start):
    rows = []
    for employee in Employee.objects.filter(active=True).order_by("name"):
        for i in range(7):
            day = week_start + timedelta(days=i)
            d = calculate_employee_day(employee, day, include_live=True)
            problems = []
            if d.get("missing_clock_out"):
                problems.append("Missing clock-out")
            if d.get("invalid_sequence"):
                problems.append("Check clock events")
            if d.get("is_urgent"):
                problems.append(d.get("issue"))
            if d.get("worked_minutes", 0) > 12 * 60:
                problems.append("Long shift")
            if d.get("paid_minutes", 0) > 0 and not d.get("employee_number"):
                problems.append("Missing Sage employee number")
            if problems:
                rows.append({
                    "date": day,
                    "employee_number": employee.employee_number,
                    "employee": employee.name,
                    "roster": d.get("roster"),
                    "status": d.get("status"),
                    "worked_hours": d.get("worked_hours"),
                    "break_minutes": d.get("break_minutes"),
                    "break_status": d.get("break_status"),
                    "problem": "; ".join(dict.fromkeys([p for p in problems if p])),
                })
    return rows


def payroll_is_ready(week_start):
    problems = get_payroll_problem_rows(week_start)
    return len(problems) == 0, problems


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
        day_row = calculate_employee_day(employee, day, include_live=True)
        rostered_minutes += day_row["rostered_minutes"]
        worked_minutes += day_row["worked_minutes"]
        break_minutes += day_row["break_minutes"]
        paid_minutes += day_row["paid_minutes"]
        if day.weekday() == 6:
            sunday_minutes += day_row["paid_minutes"]
        if day_row["is_urgent"]:
            warnings.append(f"{day}: {day_row['issue']}")

    overtime_minutes = max(0, paid_minutes - standard_minutes)
    normal_minutes = max(0, paid_minutes - overtime_minutes - sunday_minutes)
    difference_minutes = paid_minutes - rostered_minutes

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
        "difference": round(difference_minutes / 60, 2),
        "warning": "; ".join(warnings) if warnings else "OK",
        "paid_minutes": paid_minutes,
        "normal_minutes": normal_minutes,
        "sunday_minutes": sunday_minutes,
        "overtime_minutes": overtime_minutes,
    }


def get_week_rows(week_start, standard_hours=39):
    return [calculate_employee_week(employee, week_start, standard_hours) for employee in Employee.objects.filter(active=True).order_by("name")]
