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
