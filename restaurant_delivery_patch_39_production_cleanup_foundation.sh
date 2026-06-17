#!/usr/bin/env bash
set -euo pipefail

PATCH_NAME="patch_39_production_cleanup_foundation"
STAMP="$(date +%Y%m%d_%H%M%S)"
ROOT="$(pwd)"

if [ ! -f "manage.py" ] || [ ! -d "config" ] || [ ! -d "core" ]; then
  echo "ERROR: Run this from the Django project root, e.g. cd ~/restaurant_clocking"
  exit 1
fi

echo "== $PATCH_NAME =="
echo "Project root: $ROOT"

mkdir -p "backups_${PATCH_NAME}_${STAMP}"
cp -a config/settings.py .gitignore "backups_${PATCH_NAME}_${STAMP}/" 2>/dev/null || true

python3 - <<'PY'
from pathlib import Path
import re

settings = Path("config/settings.py")
text = settings.read_text()

def find_string(name, default=""):
    m = re.search(rf"^{name}\s*=\s*(['\"])(.*?)\1", text, re.M)
    return m.group(2) if m else default

secret = find_string("SECRET_KEY", "change-me-before-production")
email_user = find_string("EMAIL_HOST_USER", "")
email_password = find_string("EMAIL_HOST_PASSWORD", "")
default_from = find_string("DEFAULT_FROM_EMAIL", email_user)
manager_alert = find_string("MANAGER_ALERT_EMAIL", "")

debug_match = re.search(r"^DEBUG\s*=\s*(True|False)", text, re.M)
debug = debug_match.group(1) if debug_match else "True"

hosts_match = re.search(r"^ALLOWED_HOSTS\s*=\s*\[(.*?)\]", text, re.M | re.S)
if hosts_match:
    hosts = re.findall(r"['\"]([^'\"]+)['\"]", hosts_match.group(1))
else:
    hosts = ["localhost", "127.0.0.1"]

# Keep the live server working by creating .env once from current settings.
# The .env file is ignored by git and should be edited/rotated on production.
env = Path(".env")
if not env.exists():
    env.write_text("\n".join([
        "# Local production settings for restaurant_clocking",
        "# Created by patch 39 from the previous Django settings.py values.",
        "# IMPORTANT: rotate any exposed credentials, especially Gmail app passwords.",
        f"DJANGO_SECRET_KEY={secret}",
        f"DJANGO_DEBUG={debug}",
        f"DJANGO_ALLOWED_HOSTS={','.join(hosts)}",
        f"EMAIL_HOST_USER={email_user}",
        f"EMAIL_HOST_PASSWORD={email_password}",
        f"DEFAULT_FROM_EMAIL={default_from}",
        f"MANAGER_ALERT_EMAIL={manager_alert}",
        "",
    ]))
    try:
        env.chmod(0o600)
    except Exception:
        pass

# Safe public template without secrets.
Path(".env.example").write_text("\n".join([
    "DJANGO_SECRET_KEY=change-me",
    "DJANGO_DEBUG=False",
    "DJANGO_ALLOWED_HOSTS=your-domain.example.com,127.0.0.1,localhost",
    "EMAIL_HOST_USER=your-alert-email@gmail.com",
    "EMAIL_HOST_PASSWORD=your-gmail-app-password",
    "DEFAULT_FROM_EMAIL=your-alert-email@gmail.com",
    "MANAGER_ALERT_EMAIL=manager@example.com",
    "",
]))

new_settings = r'''"""
Django settings for the restaurant clocking project.

Production notes:
- Secrets are read from environment variables or a local .env file.
- Do not commit .env to GitHub.
- Keep DEBUG=False in production.
"""

import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent


def _load_local_env() -> None:
    """Small .env loader to avoid adding another dependency."""
    env_path = BASE_DIR / ".env"
    if not env_path.exists():
        return
    for raw_line in env_path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


_load_local_env()


def env_bool(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def env_list(name: str, default: str = "localhost,127.0.0.1") -> list[str]:
    value = os.environ.get(name, default)
    return [item.strip() for item in value.split(",") if item.strip()]


SECRET_KEY = os.environ.get("DJANGO_SECRET_KEY", "unsafe-dev-secret-key-change-me")
DEBUG = env_bool("DJANGO_DEBUG", False)
ALLOWED_HOSTS = env_list("DJANGO_ALLOWED_HOSTS")

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "core",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "config.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [BASE_DIR / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.debug",
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

WSGI_APPLICATION = "config.wsgi.application"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": BASE_DIR / "db.sqlite3",
    }
}

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

LANGUAGE_CODE = "en-us"
TIME_ZONE = "Europe/Dublin"
USE_I18N = True
USE_TZ = True

STATIC_URL = "static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

EMAIL_BACKEND = "django.core.mail.backends.smtp.EmailBackend"
EMAIL_HOST = os.environ.get("EMAIL_HOST", "smtp.gmail.com")
EMAIL_PORT = int(os.environ.get("EMAIL_PORT", "587"))
EMAIL_USE_TLS = env_bool("EMAIL_USE_TLS", True)
EMAIL_HOST_USER = os.environ.get("EMAIL_HOST_USER", "")
EMAIL_HOST_PASSWORD = os.environ.get("EMAIL_HOST_PASSWORD", "")
DEFAULT_FROM_EMAIL = os.environ.get("DEFAULT_FROM_EMAIL", EMAIL_HOST_USER)
MANAGER_ALERT_EMAIL = os.environ.get("MANAGER_ALERT_EMAIL", "")

# Safer browser defaults. These do not change app behaviour, but help production posture.
X_FRAME_OPTIONS = "DENY"
CSRF_COOKIE_SAMESITE = "Lax"
SESSION_COOKIE_SAMESITE = "Lax"
'''
settings.write_text(new_settings)
PY

# Harden gitignore without removing existing entries.
touch .gitignore
for pattern in \
  ".env" \
  "*.env" \
  "db.sqlite3" \
  "*.sqlite3" \
  "*.log" \
  "staticfiles/" \
  "media/" \
  "__pycache__/" \
  "*.pyc" \
  "backups_patch_*/" \
  "archive/"; do
  grep -qxF "$pattern" .gitignore || echo "$pattern" >> .gitignore
done

# Move old patch clutter out of the project root. This is intentionally conservative.
mkdir -p archive/patches archive/backups archive/old_backups
shopt -s nullglob
for f in restaurant_delivery_patch_*.sh manager_homepage_dashboard.sh payroll_problems_smart_clocking.sh demo_simulation_tool.sh restaurant_dashboard_patch.diff; do
  [ "$f" = "restaurant_delivery_patch_39_production_cleanup_foundation.sh" ] && continue
  mv "$f" archive/patches/ 2>/dev/null || true
done
for d in backups_patch_*; do
  mv "$d" archive/backups/ 2>/dev/null || true
done
for f in core/*.bak core/*.working_not_rostered_bak templates/*.bak templates/*.working_not_rostered_bak templates/*.manager_home_bak core/urls.py.working_not_rostered_bak core/views.py.working_not_rostered_bak; do
  mv "$f" archive/old_backups/ 2>/dev/null || true
done
shopt -u nullglob

cat > PRODUCTION_CLEANUP_NOTES.md <<'TXT'
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
TXT

python3 manage.py check

echo ""
echo "Patch 39 complete."
echo "Next recommended commands:"
echo "  git status"
echo "  git add ."
echo "  git commit -m 'Patch 39 production cleanup foundation'"
echo "  sudo systemctl restart restaurant_clocking"
echo ""
echo "IMPORTANT: rotate the Gmail app password stored in .env."
