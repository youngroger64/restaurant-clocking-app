#!/bin/bash
set -e

echo "Backing up files..."
cp core/views.py core/views.py.alerts_bak
cp core/urls.py core/urls.py.alerts_bak
cp templates/manager_today.html templates/manager_today.html.alerts_bak 2>/dev/null || true

echo "Adding improved alert logic to core/views.py..."
cat >> core/views.py <<'PY'


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
PY

echo "Replacing manager_today.html..."
cat > templates/manager_today.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Today's Dashboard</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f4f6f8; margin: 0; padding: 25px; color: #222; }
        .container { max-width: 1250px; margin: auto; }
        .header, .section { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 20px; margin: 18px 0; }
        h1 { margin: 0 0 8px 0; }
        .muted { color: #666; }
        .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 14px; margin: 18px 0; }
        .card { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 18px; }
        .number { font-size: 34px; font-weight: bold; margin-top: 8px; }
        table { width: 100%; border-collapse: collapse; margin-top: 12px; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 11px; text-align: left; }
        th { background: #f9fafb; }
        .urgent { color: #b42318; font-weight: bold; }
        .operational { color: #b7791f; font-weight: bold; }
        .ok { color: #1a7f37; font-weight: bold; }
        .button { display: inline-block; padding: 10px 13px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; margin-right: 8px; }
        .secondary { background: #4b5563; }
        input, button { padding: 8px; }
    </style>
</head>
<body>
<div class="container">
    <div class="header">
        <h1>Today's Dashboard</h1>
        <p class="muted">Start here. Urgent issues are compliance/payroll risks. Operational issues are useful manager notes such as late arrivals.</p>
        <form method="get">Date: <input type="date" name="date" value="{{ selected_date|date:'Y-m-d' }}"> <button type="submit">View Date</button></form>
    </div>

    <div class="cards">
        <div class="card"><div>Rostered Today</div><div class="number">{{ rostered_count }}</div></div>
        <div class="card"><div>Working Now</div><div class="number">{{ currently_working }}</div></div>
        <div class="card"><div>On Break</div><div class="number">{{ on_break }}</div></div>
        <div class="card"><div>Clocked Out</div><div class="number">{{ clocked_out }}</div></div>
        <div class="card"><div>Urgent Issues</div><div class="number">{{ urgent_count }}</div></div>
        <div class="card"><div>Operational Notes</div><div class="number">{{ operational_count }}</div></div>
    </div>

    <div class="section">
        <h2>Urgent Issues</h2>
        <p class="muted">These need attention first: missed breaks, missing clock-outs, absent staff, or working but not rostered.</p>
        <table>
            <tr><th>Employee</th><th>Roster</th><th>Status</th><th>Issue</th><th>Worked</th><th>Break</th><th>Paid</th></tr>
            {% for row in urgent_rows %}
            <tr><td>{{ row.employee }}</td><td>{{ row.roster }}</td><td>{{ row.status }}</td><td class="urgent">{{ row.issue }}</td><td>{{ row.worked_hours }}</td><td>{{ row.break_minutes }} mins</td><td>{{ row.paid_hours }}</td></tr>
            {% empty %}
            <tr><td colspan="7" class="ok">No urgent issues.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Operational Notes</h2>
        <p class="muted">Useful notes such as late arrivals. These do not trigger email alerts.</p>
        <table>
            <tr><th>Employee</th><th>Roster</th><th>Status</th><th>Note</th><th>Worked</th><th>Break</th></tr>
            {% for row in operational_rows %}
            <tr><td>{{ row.employee }}</td><td>{{ row.roster }}</td><td>{{ row.status }}</td><td class="operational">{{ row.issue }}</td><td>{{ row.worked_hours }}</td><td>{{ row.break_minutes }} mins</td></tr>
            {% empty %}
            <tr><td colspan="6" class="ok">No operational notes.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>Currently Working</h2>
        <table>
            <tr><th>Employee</th><th>Roster</th><th>First In</th><th>Status</th><th>Worked</th><th>Break</th></tr>
            {% for row in working_rows %}
            <tr><td>{{ row.employee }}</td><td>{{ row.roster }}</td><td>{{ row.first_in }}</td><td>{{ row.status }}</td><td>{{ row.worked_hours }}</td><td>{{ row.break_minutes }} mins</td></tr>
            {% empty %}
            <tr><td colspan="6">No staff currently clocked in.</td></tr>
            {% endfor %}
        </table>
    </div>

    <div class="section">
        <h2>All Staff Today</h2>
        <table>
            <tr><th>No</th><th>Employee</th><th>Roster</th><th>First In</th><th>Last Out</th><th>Status</th><th>Worked</th><th>Break</th><th>Paid</th><th>Issue</th></tr>
            {% for row in rows %}
            <tr>
                <td>{{ row.employee_number }}</td><td>{{ row.employee }}</td><td>{{ row.roster }}</td><td>{{ row.first_in }}</td><td>{{ row.last_out }}</td><td>{{ row.status }}</td><td>{{ row.worked_hours }}</td><td>{{ row.break_minutes }} mins</td><td>{{ row.paid_hours }}</td>
                <td class="{% if row.is_urgent %}urgent{% elif row.is_operational %}operational{% else %}ok{% endif %}">{{ row.issue }}</td>
            </tr>
            {% endfor %}
        </table>
    </div>

    <p>
        <a class="button" href="/clock/">Staff Clocking</a>
        <a class="button" href="/manager/upload-roster/">Upload Roster</a>
        <a class="button" href="/manager/weekly-summary/?week_start=2026-06-15">Weekly Summary</a>
        <a class="button secondary" href="/">Home</a>
    </p>
</div>
</body>
</html>
HTML

echo "Creating email alert command..."
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

from core.views import _manager_issue_rows


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
        rows = _manager_issue_rows(today)
        urgent_rows = [row for row in rows if row["is_urgent"]]

        if not urgent_rows:
            self.stdout.write("No urgent issues. No email sent.")
            return

        state = load_state()
        issue_key = "|".join(sorted([f"{row['employee_number']}:{row['issue']}" for row in urgent_rows]))

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

echo "Creating email alert systemd timer/service files..."
cat > email-alert.service <<'UNIT'
[Unit]
Description=Restaurant Manager Email Alert Check

[Service]
User=ec2-user
Group=ec2-user
WorkingDirectory=/home/ec2-user/restaurant_clocking
Environment="PATH=/home/ec2-user/restaurant_clocking/venv/bin"
ExecStart=/home/ec2-user/restaurant_clocking/venv/bin/python manage.py send_manager_alerts
UNIT

cat > email-alert.timer <<'UNIT'
[Unit]
Description=Run restaurant manager email alerts every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Unit=email-alert.service

[Install]
WantedBy=timers.target
UNIT

echo "Upgrade complete."
echo "Next:"
echo "1) Add MANAGER_ALERT_EMAIL = 'youngroger64@gmail.com' to config/settings.py if not already present."
echo "2) sudo systemctl restart restaurant_clocking"
echo "3) python manage.py send_manager_alerts"
echo "4) sudo cp email-alert.service email-alert.timer /etc/systemd/system/"
echo "5) sudo systemctl daemon-reload && sudo systemctl enable --now email-alert.timer"
