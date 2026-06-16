from datetime import datetime, timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone

from core.models import ClockEvent, Employee, RosterShift


class Command(BaseCommand):
    help = "Loads realistic demo clock events for a selected roster date. For demo/testing only."

    def add_arguments(self, parser):
        parser.add_argument(
            "--date",
            type=str,
            default="2026-06-15",
            help="Roster date to generate demo events for, format YYYY-MM-DD",
        )
        parser.add_argument(
            "--clear",
            action="store_true",
            help="Clear existing DEMO/QR/QR_AUTO/MANAGER events for this date before loading demo data.",
        )

    def handle(self, *args, **options):
        demo_date = datetime.strptime(options["date"], "%Y-%m-%d").date()

        if options["clear"]:
            ClockEvent.objects.filter(
                timestamp__date=demo_date,
                method__in=["DEMO", "QR", "QR_AUTO", "MANAGER"]
            ).delete()
            self.stdout.write(self.style.WARNING(f"Cleared existing demo/QR events for {demo_date}"))

        shifts = RosterShift.objects.filter(
            shift_date=demo_date
        ).select_related("employee").order_by("start_time")

        if not shifts.exists():
            self.stdout.write(self.style.ERROR(f"No roster shifts found for {demo_date}"))
            return

        created = 0

        for shift in shifts:
            emp_no = shift.employee.employee_number
            employee = shift.employee

            start_dt = timezone.make_aware(datetime.combine(demo_date, shift.start_time))
            end_dt = timezone.make_aware(datetime.combine(demo_date, shift.end_time))

            if end_dt <= start_dt:
                end_dt += timedelta(days=1)

            # Demo scenarios by employee number.
            # 101 Aoife: absent, no events.
            if emp_no == "101":
                continue

            # 102 Liam: good shift, proper 30 min break.
            if emp_no == "102":
                events = [
                    ("IN", start_dt + timedelta(minutes=2)),
                    ("BREAK_START", start_dt + timedelta(hours=4, minutes=5)),
                    ("BREAK_END", start_dt + timedelta(hours=4, minutes=35)),
                    ("OUT", end_dt + timedelta(minutes=4)),
                ]

            # 104 Jack: forgot to clock out.
            elif emp_no == "104":
                events = [
                    ("IN", start_dt - timedelta(minutes=3)),
                    ("BREAK_START", start_dt + timedelta(hours=4, minutes=20)),
                    ("BREAK_END", start_dt + timedelta(hours=4, minutes=50)),
                    # no OUT
                ]

            # 105 Emma: late but otherwise fine.
            elif emp_no == "105":
                events = [
                    ("IN", start_dt + timedelta(minutes=22)),
                    ("BREAK_START", start_dt + timedelta(hours=4, minutes=45)),
                    ("BREAK_END", start_dt + timedelta(hours=5, minutes=15)),
                    ("OUT", end_dt),
                ]

            # 108 Ben: no break on long shift.
            elif emp_no == "108":
                events = [
                    ("IN", start_dt + timedelta(minutes=1)),
                    ("OUT", end_dt + timedelta(minutes=10)),
                ]

            # Other staff: mostly normal.
            else:
                events = [
                    ("IN", start_dt + timedelta(minutes=3)),
                    ("BREAK_START", start_dt + timedelta(hours=4, minutes=10)),
                    ("BREAK_END", start_dt + timedelta(hours=4, minutes=40)),
                    ("OUT", end_dt + timedelta(minutes=2)),
                ]

            for clock_type, ts in events:
                ClockEvent.objects.create(
                    employee=employee,
                    clock_type=clock_type,
                    timestamp=ts,
                    method="DEMO"
                 
                )
                created += 1

        self.stdout.write(self.style.SUCCESS(f"Created {created} demo clock events for {demo_date}"))
        self.stdout.write("Demo scenarios:")
        self.stdout.write("- Aoife: absent")
        self.stdout.write("- Liam: normal compliant shift")
        self.stdout.write("- Jack: forgot clock-out")
        self.stdout.write("- Emma: late arrival")
        self.stdout.write("- Ben: long shift with no break")
