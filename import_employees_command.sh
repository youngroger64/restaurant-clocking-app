#!/bin/bash
set -e

echo "Creating employee import command..."

mkdir -p core/management/commands
touch core/management/__init__.py
touch core/management/commands/__init__.py

cat > core/management/commands/import_employees_csv.py <<'PY'
import csv
from pathlib import Path

from django.core.management.base import BaseCommand

from core.models import Employee


class Command(BaseCommand):
    help = "Import or update employees from a CSV file."

    def add_arguments(self, parser):
        parser.add_argument("csv_path", type=str)

    def handle(self, *args, **options):
        csv_path = Path(options["csv_path"])

        if not csv_path.exists():
            self.stdout.write(self.style.ERROR(f"File not found: {csv_path}"))
            return

        created = 0
        updated = 0

        with csv_path.open(newline="", encoding="utf-8-sig") as f:
            reader = csv.DictReader(f)

            for row in reader:
                employee_number = (row.get("EmployeeNumber") or "").strip()
                name = (row.get("EmployeeName") or "").strip()
                pin = (row.get("PIN") or employee_number).strip()
                active_text = (row.get("Active") or "TRUE").strip().upper()
                active = active_text in ["TRUE", "YES", "1", "Y"]

                if not employee_number or not name:
                    self.stdout.write(self.style.WARNING(f"Skipped invalid row: {row}"))
                    continue

                employee, was_created = Employee.objects.update_or_create(
                    employee_number=employee_number,
                    defaults={
                        "name": name,
                        "pin": pin,
                        "active": active,
                    }
                )

                if was_created:
                    created += 1
                else:
                    updated += 1

        self.stdout.write(self.style.SUCCESS(
            f"Employee import complete. Created: {created}, Updated: {updated}"
        ))
PY

echo "Running Django check..."
python manage.py check

echo "Employee import command installed."
echo ""
echo "Next:"
echo "python manage.py import_employees_csv restaurant_employees_201_215.csv"
