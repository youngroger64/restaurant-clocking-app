#!/bin/bash
set -e

echo "Backing up compliance engine..."
cp core/compliance.py core/compliance.py.outside_roster_bak

echo "Patching outside-roster-hours logic..."
python - <<'PY'
from pathlib import Path

path = Path("core/compliance.py")
text = path.read_text()

old = '''    if first_in and roster["planned_start"]:
        planned_dt = timezone.make_aware(datetime.combine(selected_date, roster["planned_start"]))
        late_minutes = int((first_in - planned_dt).total_seconds() / 60)
        if late_minutes > 10:
            operational_issues.append(f"Late by {late_minutes} mins")
'''

new = '''    if first_in and roster["planned_start"]:
        planned_start_dt = timezone.make_aware(datetime.combine(selected_date, roster["planned_start"]))

        planned_end_dt = None
        if roster["planned_end"]:
            planned_end_dt = timezone.make_aware(datetime.combine(selected_date, roster["planned_end"]))
            if planned_end_dt <= planned_start_dt:
                planned_end_dt += timedelta(days=1)

        late_minutes = int((first_in - planned_start_dt).total_seconds() / 60)

        if planned_end_dt and first_in > planned_end_dt:
            operational_issues.append("Clocked in after rostered shift ended")
        elif late_minutes > 10:
            operational_issues.append(f"Late by {late_minutes} mins")
        elif late_minutes < -15:
            operational_issues.append(f"Clocked in {abs(late_minutes)} mins early")
'''

if old not in text:
    print("Expected block not found. No changes made.")
else:
    text = text.replace(old, new)
    path.write_text(text)
    print("Updated late/outside-roster logic.")
PY

echo "Running Django check..."
python manage.py check

echo "Restarting app..."
sudo systemctl restart restaurant_clocking

echo "Done. Refresh /manager/today/"
