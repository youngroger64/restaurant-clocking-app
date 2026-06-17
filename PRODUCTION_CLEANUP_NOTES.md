# Production cleanup notes

Patch 39 is a foundation cleanup. It is designed to keep current behaviour while preparing the project for production.

## What changed

- `config/settings.py` now reads secrets and deployment values from `.env` / environment variables.
- `.env.example` was created as a safe template.
- `.gitignore` was expanded to keep secrets, database files, logs, static output, and archives out of GitHub.
- Old delivery patch scripts and backup files were moved under `archive/`.

## Important production action

Rotate the Gmail app password that was previously committed in `settings.py`. The script copied the old value into local `.env` only to avoid breaking the running server, but a committed credential should be considered exposed.

## Recommended next production patches

1. Add regression tests for payroll-critical flows.
2. Split `core/views.py` into manager, clocking, roster, and payroll modules.
3. Move Sage CSV logic into `core/services/payroll_export.py`.
4. Block or strongly warn before export when unresolved payroll problems exist.
