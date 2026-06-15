#!/bin/bash
set -e

echo "Backing up files..."
cp core/views.py core/views.py.single_calc_bak
cp core/urls.py core/urls.py.single_calc_bak
cp templates/weekly_summary.html templates/weekly_summary.html.single_calc_bak 2>/dev/null || true
cp templates/manager_today.html templates/manager_today.html.single_calc_bak 2>/dev/null || true

echo "Creating core/compliance.py..."
cat > core/compliance.py <<'PY'
from datetime import datetime, timedelta

from django.utils import timezone

from .models import Employee, ClockEvent, RosterShift


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
            parts.append(
                f"{shift.start_time.strftime('%H:%M')} - {shift.end_time.strftime('%H:%M')}"
            )

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
        "roster_text": roster_text,
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

    currently_open_work = work_start is not None
    currently_open_break = break_start is not None

    if include_live and selected_date == timezone.localdate():
        if currently_open_work:
            worked_minutes += int((now - work_start).total_seconds() / 60)
        elif currently_open_break:
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

    required_break = required_break_minutes(worked_minutes)

    urgent_issues = []
    operational_issues = []

    if invalid_sequence:
        urgent_issues.append("Check clock sequence")

    if latest_event and not roster["rostered"]:
        urgent_issues.append("Working but not rostered")

    if roster["rostered"] and not latest_event and selected_date == timezone.localdate() and roster["planned_start"]:
        planned_dt = timezone.make_aware(datetime.combine(selected_date, roster["planned_start"]))
        if now > planned_dt + timedelta(minutes=30):
            urgent_issues.append("Rostered but absent")
        elif now > planned_dt + timedelta(minutes=10):
            operational_issues.append("Late / not arrived")

    if latest_event and latest_event.clock_type in ["IN", "BREAK_END"]:
        if required_break > 0 and break_minutes < required_break:
            urgent_issues.append(
                f"Worked {format_minutes(worked_minutes)} with only {break_minutes} mins break"
            )

    if latest_event and latest_event.clock_type == "OUT":
        if required_break > 0 and break_minutes < required_break:
            urgent_issues.append("Break missing or too short")

    if selected_date < timezone.localdate() and latest_event and latest_event.clock_type in ["IN", "BREAK_START", "BREAK_END"]:
        urgent_issues.append("Missing clock-out")

    if first_in and roster["planned_start"]:
        planned_dt = timezone.make_aware(datetime.combine(selected_date, roster["planned_start"]))
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

    paid_minutes = worked_minutes

    return {
        "employee_number": employee.employee_number,
        "employee": employee.name,
        "employee_obj": employee,
        "date": selected_date,
        "roster": roster["roster_text"],
        "rostered": roster["rostered"],
        "rostered_minutes": roster["rostered_minutes"],
        "first_in": first_in.strftime("%H:%M") if first_in else "-",
        "last_out": last_out.strftime("%H:%M") if last_out else "-",
        "status": status,
        "worked_minutes": worked_minutes,
        "break_minutes": break_minutes,
        "paid_minutes": paid_minutes,
        "worked_hours": round(worked_minutes / 60, 2),
        "break_hours": round(break_minutes / 60, 2),
        "paid_hours": round(paid_minutes / 60, 2),
        "required_break": required_break,
        "issue_type": issue_type,
        "issue": issue_text,
        "is_urgent": issue_type == "Urgent",
        "is_operational": issue_type == "Operational",
        "is_working": status in ["Working now", "Back from break"],
        "is_on_break": status == "On break",
        "is_clocked_out": status == "Clocked out",
        "has_activity": latest_event is not None,
        "missing_clock_out": selected_date < timezone.localdate()
        and latest_event is not None
        and latest_event.clock_type in ["IN", "BREAK_START", "BREAK_END"],
        "invalid_sequence": invalid_sequence,
    }


def get_day_rows(selected_date):
    employees = Employee.objects.filter(active=True).order_by("name")
    return [
        calculate_employee_day(employee, selected_date, include_live=True)
        for employee in employees
    ]


def calculate_employee_week(employee, week_start, standard_hours=39):
    week_end = week_start + timedelta(days=6)
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
    employees = Employee.objects.filter(active=True).order_by("name")
    return [
        calculate_employee_week(employee, week_start, standard_hours)
        for employee in employees
    ]
PY

echo "Appending new unified views to core/views.py..."
cat >> core/views.py <<'PY'


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
PY

echo "Replacing email alert command to use same calculation engine..."
mkdir -p core/management/commands
touch core/management/__init__.py
touch core/management/commands/__init__.py

cat > core/management/commands/send_manager_alerts.py <<'PY'
import json
from pathlib import Path

from django.conf import settings
from django.core.mail import send_mail
from django.core.management.base import BaseCommand
from django.utils import timezone

from core.compliance import get_day_rows


STATE_FILE = Path("/home/ec2-user/restaurant_clocking/email_alert_state.json")


def load_state():
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception:
            return {}
    return {}


def save_state(state):
    STATE_FILE.write_text(json.dumps(state, indent=2))


class Command(BaseCommand):
    help = "Send manager email summary for urgent attendance/break issues."

    def handle(self, *args, **options):
        today = timezone.localdate()
        rows = get_day_rows(today)
        urgent_rows = [row for row in rows if row["is_urgent"]]

        if not urgent_rows:
            self.stdout.write("No urgent issues. No email sent.")
            return

        state = load_state()
        issue_key = "|".join(sorted([
            f"{row['employee_number']}:{row['issue']}" for row in urgent_rows
        ]))

        if state.get(str(today)) == issue_key:
            self.stdout.write("Same urgent issues already emailed today. No duplicate sent.")
            return

        lines = [
            "Restaurant Manager Alert",
            "",
            "URGENT ISSUES",
            "",
        ]

        for row in urgent_rows:
            lines.append(
                f"- {row['employee']}: {row['issue']} "
                f"(Status: {row['status']}, Worked: {row['worked_hours']}h, Break: {row['break_minutes']} mins)"
            )

        lines.extend([
            "",
            f"Generated: {timezone.localtime().strftime('%d-%b-%Y %H:%M')}",
            "",
            "This is an automated alert from the restaurant staff management system.",
        ])

        subject = f"Restaurant Alert: {len(urgent_rows)} urgent issue(s)"
        message = "\n".join(lines)
        recipient = getattr(settings, "MANAGER_ALERT_EMAIL", "youngroger64@gmail.com")

        send_mail(
            subject,
            message,
            settings.DEFAULT_FROM_EMAIL,
            [recipient],
            fail_silently=False,
        )

        state[str(today)] = issue_key
        save_state(state)

        self.stdout.write(self.style.SUCCESS(f"Email sent to {recipient}: {subject}"))
PY

echo "Running Django check..."
python manage.py check

echo "Restarting app..."
sudo systemctl restart restaurant_clocking

echo "Upgrade complete."
echo "Open:"
echo "  /manager/today/"
echo "  /manager/weekly-summary/?week_start=2026-06-15"
echo ""
echo "Then commit:"
echo "  git add ."
echo "  git commit -m 'Unify dashboard payroll and alert calculations'"
echo "  git push"
