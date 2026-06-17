#!/usr/bin/env bash
set -euo pipefail

echo "== patch_49_safe_roster_upload_replace_week =="
echo "Purpose: make Upload Roster production-safe by replacing the selected/uploaded week, not appending duplicate shifts."
echo "This patch replaces the existing upload_roster function body. It does NOT append another duplicate def."

if [ ! -f manage.py ] || [ ! -f core/views.py ]; then
  echo "ERROR: Run this from the Django project root, e.g. cd ~/restaurant_clocking"
  exit 1
fi

stamp=$(date +%Y%m%d_%H%M%S)
mkdir -p "patch_backups_49_${stamp}"
cp -f core/views.py "patch_backups_49_${stamp}/views.py.before_patch49"
cp -f templates/upload_roster.html "patch_backups_49_${stamp}/upload_roster.html.before_patch49" 2>/dev/null || true

python3 <<'PY'
from pathlib import Path
import re

path = Path("core/views.py")
s = path.read_text()

replacement = r'''def upload_roster(request):
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


'''

pattern = r"def upload_roster\(request\):\n.*?\n(?=def manager_dashboard\(request\):)"
new_s, count = re.subn(pattern, replacement, s, count=1, flags=re.S)
if count != 1:
    raise SystemExit("ERROR: Could not replace exactly one upload_roster function.")

path.write_text(new_s)
PY

# Ensure the roster upload page has manager-facing warning text and displays errors.
python3 <<'PY'
from pathlib import Path
p = Path("templates/upload_roster.html")
if not p.exists():
    raise SystemExit("templates/upload_roster.html not found")
s = p.read_text()

# Add a simple production warning near the upload form if not already present.
warning = "This replaces the roster for the uploaded week. Clock records will not be deleted."
if warning not in s:
    # Insert after first h1/h2 title if possible, otherwise near body start.
    inserted = False
    for marker in ["</h1>", "</h2>"]:
        if marker in s:
            s = s.replace(marker, marker + f"\n<p style=\"background:#fffbeb;border-left:4px solid #f59e0b;padding:10px;\"><strong>Roster upload:</strong> {warning}</p>", 1)
            inserted = True
            break
    if not inserted:
        s = s.replace("<body>", f"<body>\n<p style=\"background:#fffbeb;border-left:4px solid #f59e0b;padding:10px;\"><strong>Roster upload:</strong> {warning}</p>", 1)

# Display error if template doesn't already do so.
if "{{ error }}" not in s:
    block = """\n{% if error %}\n<div style=\"background:#fee2e2;border-left:4px solid #dc2626;padding:10px;margin:10px 0;color:#7f1d1d;white-space:pre-wrap;\"><strong>Upload error:</strong> {{ error }}</div>\n{% endif %}\n"""
    if "{{ message }}" in s:
        s = s.replace("{{ message }}", "{{ message }}" + block, 1)
    else:
        s = s.replace("<body>", "<body>" + block, 1)

p.write_text(s)
PY

echo "Checking Python syntax..."
python -m py_compile core/views.py

echo "Running Django check..."
python manage.py check

echo
echo "Patch 49 complete."
echo "What changed:"
echo "  - Replaced the old upload_roster implementation instead of appending another one."
echo "  - CSV upload now validates all rows before making changes."
echo "  - CSV upload replaces the roster for the uploaded week only."
echo "  - Clock records are not deleted."
echo "  - Upload page warns managers that the week roster will be replaced."
echo
echo "Next commands:"
echo "  git status"
echo "  git add core/views.py templates/upload_roster.html"
echo "  git commit -m 'Patch 49 make roster upload replace week safely'"
echo "  git push"
echo "  sudo systemctl restart restaurant_clocking"
