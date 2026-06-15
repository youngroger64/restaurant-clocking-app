#!/bin/bash
set -e

echo "Backing up current files..."
cp core/views.py core/views.py.payroll_sms_bak
cp core/urls.py core/urls.py.payroll_sms_bak
cp templates/weekly_summary.html templates/weekly_summary.html.payroll_sms_bak 2>/dev/null || true

echo "Installing Twilio Python package..."
source venv/bin/activate
pip install twilio
pip freeze > requirements.txt

echo "Creating management command folders..."
mkdir -p core/management/commands
touch core/management/__init__.py
touch core/management/commands/__init__.py

echo "Adding SMS break-alert command..."
cat > core/management/commands/check_break_alerts.py <<'PY'
import json
import os
from datetime import datetime
from pathlib import Path

from django.core.management.base import BaseCommand
from django.utils import timezone

from core.models import Employee, ClockEvent


STATE_FILE = Path("/home/ec2-user/restaurant_clocking/break_alert_state.json")


def load_state():
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception:
            return {}
    return {}


def save_state(state):
    STATE_FILE.write_text(json.dumps(state, indent=2))


def send_sms(message):
    sid = os.environ.get("TWILIO_ACCOUNT_SID")
    token = os.environ.get("TWILIO_AUTH_TOKEN")
    from_number = os.environ.get("TWILIO_FROM_NUMBER")
    to_number = os.environ.get("MANAGER_PHONE_NUMBER")

    if not all([sid, token, from_number, to_number]):
        print("SMS not sent. Missing Twilio environment variables.")
        print(message)
        return False

    from twilio.rest import Client

    client = Client(sid, token)
    client.messages.create(
        body=message,
        from_=from_number,
        to=to_number,
    )
    print("SMS sent:", message)
    return True


class Command(BaseCommand):
    help = "Checks currently clocked-in staff and sends SMS alerts when breaks are overdue."

    def handle(self, *args, **options):
        today = timezone.localdate()
        now = timezone.now()
        state = load_state()
        sent_count = 0

        employees = Employee.objects.filter(active=True).order_by("name")

        for employee in employees:
            events = ClockEvent.objects.filter(
                employee=employee,
                timestamp__date=today,
            ).order_by("timestamp")

            if not events.exists():
                continue

            latest_event = events.last()

            # Only alert while employee is actively working.
            # If they are on break, clocked out, or have no active IN, no alert is sent.
            if latest_event.clock_type != "IN":
                continue

            last_in = None
            break_minutes = 0
            break_start = None

            for event in events:
                if event.clock_type == "IN":
                    last_in = event.timestamp
                elif event.clock_type == "BREAK_START":
                    break_start = event.timestamp
                elif event.clock_type == "BREAK_END" and break_start:
                    break_minutes += int((event.timestamp - break_start).total_seconds() / 60)
                    break_start = None

            if not last_in:
                continue

            current_work_minutes = int((now - last_in).total_seconds() / 60)

            alert_level = None
            required_break = 0

            if current_work_minutes >= 360 and break_minutes < 30:
                alert_level = "6h_30m"
                required_break = 30
            elif current_work_minutes >= 270 and break_minutes < 15:
                alert_level = "4h30_15m"
                required_break = 15

            if not alert_level:
                continue

            state_key = f"{today}:{employee.employee_number}:{alert_level}"

            if state.get(state_key):
                continue

            hours = round(current_work_minutes / 60, 2)

            message = (
                f"Break alert: {employee.name} has worked approx {hours} hours today "
                f"and has recorded {break_minutes} mins break. Required break: {required_break} mins."
            )

            if send_sms(message):
                state[state_key] = datetime.utcnow().isoformat()
                sent_count += 1

        save_state(state)
        self.stdout.write(self.style.SUCCESS(f"Break alert check complete. SMS sent: {sent_count}"))
PY

echo "Appending improved payroll weekly summary and Sage export views..."
cat >> core/views.py <<'PY'


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
PY

echo "Updating core/urls.py..."
python - <<'PY'
from pathlib import Path

path = Path("core/urls.py")
text = path.read_text()

if "export_sage_payroll_csv" not in text.split("urlpatterns")[0]:
    text = text.replace(
        "manager_daily_monitor,",
        "manager_daily_monitor,\n    export_sage_payroll_csv,"
    )

if "export-sage-payroll" not in text:
    text = text.replace(
        "path('manager/daily-monitor/', manager_daily_monitor, name='manager_daily_monitor'),",
        "path('manager/daily-monitor/', manager_daily_monitor, name='manager_daily_monitor'),\n    path('manager/export-sage-payroll/', export_sage_payroll_csv, name='export_sage_payroll_csv'),"
    )

path.write_text(text)
PY

echo "Replacing weekly summary template..."
cat > templates/weekly_summary.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Weekly Payroll Summary</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #222; }
        .container { max-width: 1250px; margin: auto; background: white; padding: 24px; border-radius: 14px; border: 1px solid #e5e7eb; }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 10px; text-align: left; }
        th { background: #f9fafb; }
        .ok { color: #1a7f37; font-weight: bold; }
        .warn { color: #b42318; font-weight: bold; }
        .button { display: inline-block; padding: 10px 13px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 8px; }
        .secondary { background: #4b5563; }
        input, button { padding: 8px; }
    </style>
</head>
<body>

<div class="container">

<h1>Weekly Payroll Summary</h1>

<p>
This page prepares payroll-style hours from clock records. Breaks are unpaid. Sunday hours are separated for Sunday premium handling. Overtime is calculated above the standard weekly hours entered below.
</p>

<form method="get">
    Week Start:
    <input type="date" name="week_start" value="{{ week_start|date:'Y-m-d' }}">
    Standard Weekly Hours:
    <input type="number" step="0.5" name="standard_hours" value="{{ standard_hours }}">
    <button type="submit">View Week</button>
</form>

<h2>{{ week_start }} to {{ week_end }}</h2>

<p>
    <a class="button" href="/manager/export-sage-payroll/?week_start={{ week_start|date:'Y-m-d' }}&period=1&standard_hours={{ standard_hours }}">
        Download Sage Payroll CSV
    </a>
</p>

<table>
    <tr>
        <th>Employee No</th>
        <th>Employee</th>
        <th>Rostered</th>
        <th>Worked</th>
        <th>Unpaid Breaks</th>
        <th>Paid Hours</th>
        <th>Normal</th>
        <th>Sunday</th>
        <th>Overtime</th>
        <th>Difference</th>
        <th>Status</th>
    </tr>

    {% for row in summary_rows %}
    <tr>
        <td>{{ row.employee_number }}</td>
        <td>{{ row.employee }}</td>
        <td>{{ row.rostered_hours }}</td>
        <td>{{ row.worked_hours }}</td>
        <td>{{ row.break_hours }}</td>
        <td>{{ row.paid_hours }}</td>
        <td>{{ row.normal_hours }}</td>
        <td>{{ row.sunday_hours }}</td>
        <td>{{ row.overtime_hours }}</td>
        <td>{{ row.difference }}</td>
        <td class="{% if row.warning == 'OK' %}ok{% else %}warn{% endif %}">
            {{ row.warning }}
        </td>
    </tr>
    {% endfor %}
</table>

<p>
    <a class="button secondary" href="/manager/today/">Today's Dashboard</a>
    <a class="button secondary" href="/manager/upload-roster/">Upload Roster</a>
    <a class="button secondary" href="/">Home</a>
</p>

</div>

</body>
</html>
HTML

echo "Creating systemd timer/service templates for break alerts..."
cat > break-alert.service <<'UNIT'
[Unit]
Description=Restaurant Clocking Break Alert Check

[Service]
User=ec2-user
Group=ec2-user
WorkingDirectory=/home/ec2-user/restaurant_clocking
Environment="PATH=/home/ec2-user/restaurant_clocking/venv/bin"
# Add these four Environment lines after you create Twilio:
# Environment="TWILIO_ACCOUNT_SID=your_sid"
# Environment="TWILIO_AUTH_TOKEN=your_token"
# Environment="TWILIO_FROM_NUMBER=+353..."
# Environment="MANAGER_PHONE_NUMBER=+353..."
ExecStart=/home/ec2-user/restaurant_clocking/venv/bin/python manage.py check_break_alerts
UNIT

cat > break-alert.timer <<'UNIT'
[Unit]
Description=Run restaurant break-alert check every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Unit=break-alert.service

[Install]
WantedBy=timers.target
UNIT

echo "Upgrade complete."
echo "Next steps:"
echo "1) sudo systemctl restart restaurant_clocking"
echo "2) Open /manager/weekly-summary/?week_start=2026-06-15"
echo "3) Copy break-alert.service and break-alert.timer to /etc/systemd/system when Twilio credentials are ready."
