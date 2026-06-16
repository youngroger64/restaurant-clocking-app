#!/usr/bin/env bash
set -euo pipefail

echo "=== Restaurant Clocking Patch 16: Roster Upload Replace Week + Fix Roster Manager Display ==="
echo "Fixes:"
echo "  - After CSV upload, roster table displays immediately"
echo "  - Employee dropdown is populated"
echo "  - Uploading a roster replaces the roster for that week to avoid duplicates"
echo "  - Clock events are NOT deleted, so real clocking/payroll problems remain visible"
echo

if [ ! -f "manage.py" ]; then
  echo "ERROR: Run from Django project root: cd ~/restaurant_clocking"
  exit 1
fi

stamp=$(date +%Y%m%d_%H%M%S)
mkdir -p "patch_backups_16_$stamp"
cp -f core/views.py "patch_backups_16_$stamp/views.py.before_patch16"
cp -f templates/upload_roster.html "patch_backups_16_$stamp/upload_roster.html.before_patch16" 2>/dev/null || true

cat >> core/views.py <<'PY'

# -------------------------------------------------------------------
# Patch 16: safer roster manager upload
# Replaces roster shifts for the selected/imported week and redirects
# back to the roster manager so the uploaded roster is visible.
# -------------------------------------------------------------------

from django.contrib.auth.decorators import login_required as _patch16_login_required
from django.shortcuts import redirect as _patch16_redirect


def _patch16_parse_date(value):
    value = (value or "").strip()
    for fmt in ("%Y-%m-%d", "%d/%m/%Y", "%d-%m-%Y"):
        try:
            return datetime.strptime(value, fmt).date()
        except ValueError:
            pass
    raise ValueError(f"Invalid date format: {value}. Use YYYY-MM-DD.")


def _patch16_parse_time(value):
    value = (value or "").strip()
    for fmt in ("%H:%M", "%H:%M:%S"):
        try:
            return datetime.strptime(value, fmt).time()
        except ValueError:
            pass
    raise ValueError(f"Invalid time format: {value}. Use HH:MM.")


def _patch16_week_start_for_date(day):
    return day - timedelta(days=day.weekday())


@_patch16_login_required
def roster_manager(request):
    message = ""
    error = ""

    raw_week_start = request.GET.get("week_start") or request.POST.get("week_start")
    if raw_week_start:
        week_start = datetime.strptime(raw_week_start, "%Y-%m-%d").date()
    else:
        week_start = timezone.localdate() - timedelta(days=timezone.localdate().weekday())

    # CSV upload: replace the roster for the detected/selected week.
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
            for row in reader:
                shift_date = _patch16_parse_date(row.get("Date"))
                parsed_rows.append({
                    "employee_number": (row.get("EmployeeNumber") or "").strip(),
                    "employee_name": (row.get("EmployeeName") or "").strip(),
                    "shift_date": shift_date,
                    "start_time": _patch16_parse_time(row.get("StartTime")),
                    "end_time": _patch16_parse_time(row.get("EndTime")),
                    "break_minutes": int((row.get("BreakMinutes") or "0").strip() or "0"),
                })

            if not parsed_rows:
                raise ValueError("CSV contained no roster rows.")

            # Use the week of the first imported shift unless a week_start was explicitly supplied.
            if not raw_week_start:
                week_start = _patch16_week_start_for_date(parsed_rows[0]["shift_date"])

            week_end = week_start + timedelta(days=6)

            # Replace roster shifts for this week only. Do not delete clock events.
            RosterShift.objects.filter(
                shift_date__gte=week_start,
                shift_date__lte=week_end,
            ).delete()

            count = 0
            for row in parsed_rows:
                employee, _created = Employee.objects.get_or_create(
                    employee_number=row["employee_number"],
                    defaults={
                        "name": row["employee_name"] or row["employee_number"],
                        "pin": row["employee_number"],
                        "active": True,
                    }
                )

                # Keep employee name fresh if CSV has a better name.
                if row["employee_name"] and employee.name != row["employee_name"]:
                    employee.name = row["employee_name"]
                    employee.save()

                RosterShift.objects.create(
                    employee=employee,
                    shift_date=row["shift_date"],
                    start_time=row["start_time"],
                    end_time=row["end_time"],
                    break_minutes=row["break_minutes"],
                )
                count += 1

            return _patch16_redirect(f"/manager/upload-roster/?week_start={week_start.isoformat()}&uploaded={count}")

        except Exception as exc:
            error = f"Roster upload failed: {exc}"

    uploaded = request.GET.get("uploaded")
    if uploaded:
        message = f"Uploaded {uploaded} roster shift(s). Existing roster shifts for this week were replaced."

    week_end = week_start + timedelta(days=6)
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
PY

# Make upload page show success/error clearly and explain replacement behaviour.
python3 <<'PY'
from pathlib import Path
p = Path("templates/upload_roster.html")
if p.exists():
    s = p.read_text()

    if "{% if message %}" not in s:
        s = s.replace(
            "<h1>Roster Manager</h1>",
            """<h1>Roster Manager</h1>
        {% if message %}<p class="ok">{{ message }}</p>{% endif %}
        {% if error %}<p class="warn">{{ error }}</p>{% endif %}""",
            1
        )

    s = s.replace(
        "Upload is still useful for the weekly rota. After upload, check the table below and make any edits.",
        "Upload the weekly rota CSV. Uploading replaces the roster for that week, then shows the imported shifts below for review/editing."
    )

    s = s.replace(
        "If someone calls in sick, reassign the shift to the cover person or delete/cancel the shift.",
        "If someone calls in sick, reassign the shift to the cover person or delete the shift if it is cancelled."
    )

    p.write_text(s)
PY

echo "Checking Python syntax..."
python -m py_compile core/views.py

echo "Running Django checks..."
python manage.py check

echo
echo "Patch 16 complete."
echo "Restart:"
echo "  sudo systemctl restart restaurant_clocking"
