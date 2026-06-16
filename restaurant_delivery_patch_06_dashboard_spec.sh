#!/usr/bin/env bash
set -euo pipefail

echo "=== Restaurant Clocking Patch 06: Dashboard Reorganisation ==="

if [ ! -f "manage.py" ]; then
  echo "Run from project root"
  exit 1
fi

mkdir -p patch_backups_06
cp -f core/views.py patch_backups_06/views.py.bak 2>/dev/null || true

cat <<'EOF'

MANUAL IMPLEMENTATION GUIDE
===========================

This patch is intentionally a planning patch because the dashboard code
structure varies significantly between versions.

Apply the following changes:

1. TOP CARDS
------------

Replace:

- Health Score
- Rostered Today
- Working Now
- On Break
- Urgent Issues
- Payroll Problems

With:

- 👥 Working Now
- ☕ On Break
- ⏰ Late
- 🚫 Not Arrived
- ⚠ Payroll Issues
- ✅ Payroll Ready

Formula:

Payroll Ready % =
100 - ((payroll_issues / max(rostered_today,1)) * 100)

Cap between 0 and 100.

2. FIRST DASHBOARD SECTION
--------------------------

Title:

Staff Currently Working

Columns:

Employee | Status | Since | Worked

Status values:

Working
On Break

This becomes the first large table on the page.

3. SECOND SECTION
-----------------

Title:

Today's Roster Status

Summary row:

Rostered Today
Arrived
Late
Not Arrived

Then:

Employee | Shift | Status

Status:

Arrived
Late
Not Yet Due

4. THIRD SECTION
----------------

Title:

Needs Attention

Merge all issue sources into one list:

- Late
- Missing clock out
- Open break
- Long break
- Long shift
- Working but not rostered

Display:

Issue | Employee | Action

Action:

[Fix]

5. REMOVE THESE STANDALONE SECTIONS
-----------------------------------

REMOVE:

Working But Not Rostered

REMOVE:

Large Payroll Problems section

Those become issue types inside Needs Attention.

6. PAYROLL PANEL
----------------

Bottom section:

Payroll Ready: XX%

Issues Remaining: X

Button:

Review Payroll Problems

7. UX RULE
----------

Manager should answer:

- Who is here?
- Who is on break?
- Who is late?
- Who hasn't arrived?
- Do I need to fix payroll?

Within 5 seconds.

EOF

echo
echo "Patch 06 planning complete."
echo "This is a dashboard redesign and should be implemented against the current dashboard template."
