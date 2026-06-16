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
