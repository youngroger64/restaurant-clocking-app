#!/usr/bin/env bash
set -euo pipefail

PATCH_NAME="patch_45_payroll_engine_consolidation"
echo "== ${PATCH_NAME} =="
PROJECT_ROOT="$(pwd)"
echo "Project root: ${PROJECT_ROOT}"

if [ ! -f manage.py ] || [ ! -d core ]; then
  echo "ERROR: run this from the Django project root, e.g. cd ~/restaurant_clocking" >&2
  exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="backups_patch_45_${STAMP}"
mkdir -p "${BACKUP_DIR}/core" "${BACKUP_DIR}/templates"
cp core/views.py "${BACKUP_DIR}/core/views.py"
[ -f core/compliance.py ] && cp core/compliance.py "${BACKUP_DIR}/core/compliance.py"
[ -f templates/weekly_summary.html ] && cp templates/weekly_summary.html "${BACKUP_DIR}/templates/weekly_summary.html"
[ -f templates/payroll_problems.html ] && cp templates/payroll_problems.html "${BACKUP_DIR}/templates/payroll_problems.html"

echo "Creating single payroll service..."
mkdir -p core/services
[ -f core/services/__init__.py ] || touch core/services/__init__.py
cat > core/services/payroll.py <<'PY'
"""
Single payroll issue and weekly payroll summary engine.

This module is intentionally boring: manager weekly summary, payroll problems,
and Sage export should all call the functions here so the manager never sees
"2 issues" on one page and "no issues" on another.
"""
from __future__ import annotations

import csv
from datetime import datetime, timedelta
from typing import Dict, Iterable, List, Tuple

from django.http import HttpResponse
from django.utils import timezone

from core.models import ClockEvent, Employee, RosterShift
from core.compliance import calculate_employee_day, get_week_rows

CLOCK_TYPES = {"IN", "BREAK_START", "BREAK_END", "OUT"}
WORK_TYPES = {"IN", "OUT"}


def parse_week_start(request):
    raw = request.GET.get("week_start") or request.POST.get("week_start")
    if raw:
        return datetime.strptime(raw, "%Y-%m-%d").date()
    today = timezone.localdate()
    return today - timedelta(days=today.weekday())


def _day_range(week_start):
    return [week_start + timedelta(days=i) for i in range(7)]


def _event_minute(event):
    return timezone.localtime(event.timestamp).replace(second=0, microsecond=0)


def _events_for_day(employee, day):
    """Return clock events for a calendar/service day with exact duplicates collapsed."""
    events = (
        ClockEvent.objects
        .filter(employee=employee, timestamp__date=day)
        .order_by("timestamp", "id")
    )
    unique = []
    seen = set()
    for event in events:
        if event.clock_type not in CLOCK_TYPES:
            continue
        key = (event.clock_type, _event_minute(event))
        if key in seen:
            continue
        seen.add(key)
        unique.append(event)
    return unique


def _employees_for_week(week_start):
    """Include active employees plus anyone with roster/events in the week."""
    week_end = week_start + timedelta(days=6)
    ids = set(Employee.objects.filter(active=True).values_list("id", flat=True))
    ids.update(
        RosterShift.objects
        .filter(shift_date__gte=week_start, shift_date__lte=week_end)
        .values_list("employee_id", flat=True)
    )
    ids.update(
        ClockEvent.objects
        .filter(timestamp__date__gte=week_start, timestamp__date__lte=week_end)
        .values_list("employee_id", flat=True)
    )
    return Employee.objects.filter(id__in=ids).order_by("name", "employee_number")


def _clock_sequence_issue(events):
    """
    Return a payroll-blocking issue for broken clock records, or None.

    Deliberately does not block payroll for soft operational warnings such as
    late arrival, short break or unrostered work. Those belong on the manager
    dashboard/review screens, not as stale blockers once a manager has reviewed
    the day.
    """
    if not events:
        return None

    work = [event.clock_type for event in events if event.clock_type in WORK_TYPES]
    if work:
        if "IN" not in work:
            return "Missing clock-in"
        if "OUT" not in work:
            return "Missing clock-out"
        if work[0] != "IN" or work[-1] != "OUT":
            return "Check clock event order"
        if work.count("IN") != work.count("OUT"):
            return "Check clock event sequence"
        if work.count("IN") > 1 or work.count("OUT") > 1:
            return "Multiple clock-ins/outs on same day"

    break_balance = 0
    for event in events:
        if event.clock_type == "BREAK_START":
            break_balance += 1
        elif event.clock_type == "BREAK_END":
            if break_balance <= 0:
                return "Break ended without a break start"
            break_balance -= 1
    if break_balance:
        return "Break was not ended"

    return None


def get_payroll_issue_rows(week_start):
    rows = []
    for employee in _employees_for_week(week_start):
        for day in _day_range(week_start):
            events = _events_for_day(employee, day)
            if not events:
                continue

            issue = _clock_sequence_issue(events)
            day_row = calculate_employee_day(employee, day, include_live=False)

            if not issue and int(day_row.get("worked_minutes") or 0) > 14 * 60:
                issue = "Unusually long shift"

            if not issue:
                continue

            rows.append({
                "date": day,
                "employee_number": employee.employee_number,
                "employee": employee.name,
                "roster": day_row.get("roster") or "Not rostered",
                "status": day_row.get("status") or "Check",
                "worked_hours": day_row.get("worked_hours") or 0,
                "break_minutes": day_row.get("break_minutes") or 0,
                "problem": issue,
                "source": "payroll_engine",
            })
    return rows


def payroll_is_ready(week_start):
    rows = get_payroll_issue_rows(week_start)
    return len(rows) == 0, rows


def _hours(value):
    return round(float(value or 0), 2)


def _minutes_to_decimal_string(minutes):
    return f"{round((int(minutes or 0)) / 60, 2):.2f}"


def get_weekly_summary_rows(week_start, standard_hours=39):
    rows = get_week_rows(week_start, standard_hours)
    for row in rows:
        row["rostered_hours"] = _hours(row.get("rostered_hours"))
        row["worked_hours"] = _hours(row.get("worked_hours"))
        row["break_hours"] = _hours(row.get("break_hours"))
        row["paid_hours"] = _hours(row.get("paid_hours"))
        row["normal_hours"] = _hours(row.get("normal_hours"))
        row["sunday_hours"] = _hours(row.get("sunday_hours"))
        row["overtime_hours"] = _hours(row.get("overtime_hours"))
        row["difference"] = _hours(row.get("difference"))
        row["normal_export"] = _minutes_to_decimal_string(row.get("normal_minutes", row["normal_hours"] * 60))
        row["sunday_export"] = _minutes_to_decimal_string(row.get("sunday_minutes", row["sunday_hours"] * 60))
        row["overtime_export"] = _minutes_to_decimal_string(row.get("overtime_minutes", row["overtime_hours"] * 60))
        if not row.get("warning"):
            row["warning"] = "OK"
    return rows


def get_export_rows(week_start, standard_hours=39):
    return [
        row for row in get_weekly_summary_rows(week_start, standard_hours)
        if int(row.get("paid_minutes") or 0) > 0
    ]


def get_weekly_totals(summary_rows):
    return {
        "rostered": round(sum(float(r.get("rostered_hours") or 0) for r in summary_rows), 2),
        "paid": round(sum(float(r.get("paid_hours") or 0) for r in summary_rows), 2),
        "normal": round(sum(float(r.get("normal_hours") or 0) for r in summary_rows), 2),
        "sunday": round(sum(float(r.get("sunday_hours") or 0) for r in summary_rows), 2),
        "overtime": round(sum(float(r.get("overtime_hours") or 0) for r in summary_rows), 2),
    }


def build_sage_csv_response(week_start, standard_hours=39, period_number="1"):
    response = HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = 'attachment; filename="sage_payroll_export.csv"'
    writer = csv.writer(response)
    for row in get_export_rows(week_start, standard_hours):
        writer.writerow([
            period_number,
            row["employee_number"],
            "0000",
            row["normal_export"],
            row["sunday_export"],
            row["overtime_export"],
        ])
    return response
PY

echo "Appending final payroll view overrides..."
cat >> core/views.py <<'PY'

# -------------------------------------------------------------------
# Patch 45: final payroll source-of-truth overrides
# -------------------------------------------------------------------
# All payroll-facing screens below intentionally use core.services.payroll.
# This prevents stale patch generations from showing different issue counts.
from django.contrib.auth.decorators import login_required as _p45_login_required
from django.shortcuts import render as _p45_render
from django.http import HttpResponse as _p45_HttpResponse
from core.services.payroll import (
    parse_week_start as _p45_parse_week_start,
    get_payroll_issue_rows as _p45_get_payroll_issue_rows,
    payroll_is_ready as _p45_payroll_is_ready,
    get_weekly_summary_rows as _p45_get_weekly_summary_rows,
    get_export_rows as _p45_get_export_rows,
    get_weekly_totals as _p45_get_weekly_totals,
    build_sage_csv_response as _p45_build_sage_csv_response,
)


@_p45_login_required
def payroll_problems(request):
    week_start = _p45_parse_week_start(request)
    week_end = week_start + timedelta(days=6)
    rows = _p45_get_payroll_issue_rows(week_start)
    return _p45_render(request, "payroll_problems.html", {
        "week_start": week_start,
        "week_end": week_end,
        "rows": rows,
        "problem_count": len(rows),
        "payroll_problem_count": len(rows),
        "unresolved_problem_count": len(rows),
    })


@_p45_login_required
def manager_weekly_summary(request):
    week_start = _p45_parse_week_start(request)
    week_end = week_start + timedelta(days=6)
    standard_hours = float(request.GET.get("standard_hours", "39") or 39)
    period_number = request.GET.get("period", "1") or "1"
    summary_rows = _p45_get_weekly_summary_rows(week_start, standard_hours)
    export_rows = _p45_get_export_rows(week_start, standard_hours)
    payroll_ready_bool, payroll_issue_rows = _p45_payroll_is_ready(week_start)
    totals = _p45_get_weekly_totals(summary_rows)

    return _p45_render(request, "weekly_summary.html", {
        "week_start": week_start,
        "week_end": week_end,
        "summary_rows": summary_rows,
        "rows": summary_rows,
        "export_rows": export_rows,
        "standard_hours": standard_hours,
        "period_number": period_number,
        "payroll_ready": payroll_ready_bool,
        "payroll_problem_count": len(payroll_issue_rows),
        "unresolved_problem_count": len(payroll_issue_rows),
        "totals": totals,
    })


@_p45_login_required
def export_sage_payroll_csv(request):
    week_start = _p45_parse_week_start(request)
    week_end = week_start + timedelta(days=6)
    period_number = request.GET.get("period", "1") or "1"
    standard_hours = float(request.GET.get("standard_hours", "39") or 39)
    allow_unresolved = request.GET.get("allow_unresolved") == "1"
    payroll_ready_bool, payroll_issue_rows = _p45_payroll_is_ready(week_start)

    if payroll_issue_rows and not allow_unresolved:
        return _p45_render(request, "payroll_export_blocked.html", {
            "week_start": week_start,
            "week_end": week_end,
            "problem_count": len(payroll_issue_rows),
            "payroll_problem_count": len(payroll_issue_rows),
            "unresolved_problem_count": len(payroll_issue_rows),
            "problems": payroll_issue_rows,
            "standard_hours": standard_hours,
            "period_number": period_number,
        })

    return _p45_build_sage_csv_response(week_start, standard_hours, period_number)
PY

# Make the weekly template accept both old and new context names if this older template is present.
if [ -f templates/weekly_summary.html ]; then
python3 - <<'PY'
from pathlib import Path
p = Path("templates/weekly_summary.html")
s = p.read_text()
# Keep existing look, but ensure both variable names can be shown consistently.
s = s.replace(
    "{% if unresolved_problem_count and unresolved_problem_count > 0 %}",
    "{% if payroll_problem_count and payroll_problem_count > 0 %}"
)
s = s.replace("{{ unresolved_problem_count }} payroll warning(s) found.", "{{ payroll_problem_count }} payroll issue(s) found.")
s = s.replace("Review Payroll Problems before exporting to Sage.", "Fix Payroll Issues before exporting to Sage.")
s = s.replace("Open Payroll Problems", "Fix Payroll Issues")
p.write_text(s)
PY
fi

python3 manage.py check
python3 manage.py shell -c "from datetime import date; from core.services.payroll import get_payroll_issue_rows; ws=date(2026,6,15); print('Patch 45 payroll issue rows for 2026-06-15:', len(get_payroll_issue_rows(ws)))" || true

echo
echo "Patch 45 complete."
echo "Next recommended commands:"
echo "  git status"
echo "  git add core/services/payroll.py core/services/__init__.py core/views.py templates/weekly_summary.html"
echo "  git commit -m 'Patch 45 consolidate payroll issue engine'"
echo "  git push"
echo "  sudo systemctl restart restaurant_clocking"
echo
echo "After restart, check:"
echo "  /manager/weekly-summary/?week_start=2026-06-15"
echo "  /manager/payroll-problems/?week_start=2026-06-15"
