#!/usr/bin/env bash
set -euo pipefail

PATCH_NAME="patch_40_production_settings_hardening"
STAMP="$(date +%Y%m%d_%H%M%S)"
ROOT="$(pwd)"

if [ ! -f "manage.py" ] || [ ! -d "config" ] || [ ! -d "core" ]; then
  echo "ERROR: Run this from the Django project root, e.g. cd ~/restaurant_clocking"
  exit 1
fi

echo "== $PATCH_NAME =="
echo "Project root: $ROOT"

mkdir -p "backups_${PATCH_NAME}_${STAMP}"
cp -a config/settings.py .env .env.example .gitignore "backups_${PATCH_NAME}_${STAMP}/" 2>/dev/null || true

python3 - <<'PY'
from pathlib import Path
import re

settings = Path("config/settings.py")
text = settings.read_text()

# Replace settings.py with a clearer production-ready version. This keeps the
# same SQLite/database/app behaviour, but makes deployment safety explicit.
new_settings = r'''"""
Django settings for the restaurant clocking project.

Production notes:
- Secrets and deployment-specific values are read from .env / environment variables.
- Do not commit .env to GitHub.
- Production should run with DJANGO_DEBUG=False.
"""

import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent


def _load_local_env() -> None:
    """Tiny .env loader so production does not need an extra dependency."""
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


def env_int(name: str, default: int) -> int:
    value = os.environ.get(name)
    if value is None or value.strip() == "":
        return default
    return int(value)


def env_list(name: str, default: str = "localhost,127.0.0.1") -> list[str]:
    value = os.environ.get(name, default)
    return [item.strip() for item in value.split(",") if item.strip()]


SECRET_KEY = os.environ.get("DJANGO_SECRET_KEY", "unsafe-dev-secret-key-change-me")
DEBUG = env_bool("DJANGO_DEBUG", False)
ALLOWED_HOSTS = env_list("DJANGO_ALLOWED_HOSTS")
CSRF_TRUSTED_ORIGINS = env_list("DJANGO_CSRF_TRUSTED_ORIGINS", "")

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
EMAIL_PORT = env_int("EMAIL_PORT", 587)
EMAIL_USE_TLS = env_bool("EMAIL_USE_TLS", True)
EMAIL_HOST_USER = os.environ.get("EMAIL_HOST_USER", "")
EMAIL_HOST_PASSWORD = os.environ.get("EMAIL_HOST_PASSWORD", "")
DEFAULT_FROM_EMAIL = os.environ.get("DEFAULT_FROM_EMAIL", EMAIL_HOST_USER)
MANAGER_ALERT_EMAIL = os.environ.get("MANAGER_ALERT_EMAIL", "")

# Browser/security defaults. Cookie HTTPS flags are controlled by env so the
# app can still run behind HTTP during emergency maintenance.
X_FRAME_OPTIONS = "DENY"
SECURE_CONTENT_TYPE_NOSNIFF = True
CSRF_COOKIE_SAMESITE = "Lax"
SESSION_COOKIE_SAMESITE = "Lax"
CSRF_COOKIE_SECURE = env_bool("DJANGO_CSRF_COOKIE_SECURE", not DEBUG)
SESSION_COOKIE_SECURE = env_bool("DJANGO_SESSION_COOKIE_SECURE", not DEBUG)
SECURE_SSL_REDIRECT = env_bool("DJANGO_SECURE_SSL_REDIRECT", False)

# Required when HTTPS is terminated by a reverse proxy / load balancer.
if env_bool("DJANGO_USE_X_FORWARDED_PROTO", True):
    SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")

# Basic console logging for systemd/journalctl.
LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "handlers": {
        "console": {"class": "logging.StreamHandler"},
    },
    "root": {
        "handlers": ["console"],
        "level": os.environ.get("DJANGO_LOG_LEVEL", "INFO"),
    },
}
'''
settings.write_text(new_settings)
PY

# Ensure .env exists and move production toward DEBUG=False without changing hosts/secrets.
if [ ! -f .env ]; then
  cat > .env <<'ENV'
DJANGO_SECRET_KEY=change-me-before-production
DJANGO_DEBUG=False
DJANGO_ALLOWED_HOSTS=localhost,127.0.0.1
DJANGO_CSRF_TRUSTED_ORIGINS=
EMAIL_HOST_USER=
EMAIL_HOST_PASSWORD=
DEFAULT_FROM_EMAIL=
MANAGER_ALERT_EMAIL=
DJANGO_SECURE_SSL_REDIRECT=False
DJANGO_USE_X_FORWARDED_PROTO=True
DJANGO_CSRF_COOKIE_SECURE=True
DJANGO_SESSION_COOKIE_SECURE=True
DJANGO_LOG_LEVEL=INFO
ENV
  chmod 600 .env 2>/dev/null || true
else
  # Set DEBUG false for production. Preserve everything else.
  if grep -q '^DJANGO_DEBUG=' .env; then
    sed -i 's/^DJANGO_DEBUG=.*/DJANGO_DEBUG=False/' .env
  else
    printf '\nDJANGO_DEBUG=False\n' >> .env
  fi
  for line in \
    'DJANGO_CSRF_TRUSTED_ORIGINS=' \
    'DJANGO_SECURE_SSL_REDIRECT=False' \
    'DJANGO_USE_X_FORWARDED_PROTO=True' \
    'DJANGO_CSRF_COOKIE_SECURE=True' \
    'DJANGO_SESSION_COOKIE_SECURE=True' \
    'DJANGO_LOG_LEVEL=INFO'; do
    key="${line%%=*}"
    grep -q "^${key}=" .env || echo "$line" >> .env
  done
  chmod 600 .env 2>/dev/null || true
fi

cat > .env.example <<'ENV'
DJANGO_SECRET_KEY=change-me
DJANGO_DEBUG=False
DJANGO_ALLOWED_HOSTS=your-domain.example.com,127.0.0.1,localhost
DJANGO_CSRF_TRUSTED_ORIGINS=https://your-domain.example.com
EMAIL_HOST=smtp.gmail.com
EMAIL_PORT=587
EMAIL_USE_TLS=True
EMAIL_HOST_USER=your-alert-email@gmail.com
EMAIL_HOST_PASSWORD=your-gmail-app-password
DEFAULT_FROM_EMAIL=your-alert-email@gmail.com
MANAGER_ALERT_EMAIL=manager@example.com
DJANGO_SECURE_SSL_REDIRECT=False
DJANGO_USE_X_FORWARDED_PROTO=True
DJANGO_CSRF_COOKIE_SECURE=True
DJANGO_SESSION_COOKIE_SECURE=True
DJANGO_LOG_LEVEL=INFO
ENV

# Add a simple production checklist command that catches the common mistakes.
mkdir -p core/management/commands
cat > core/management/commands/production_check.py <<'PY'
from django.conf import settings
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Run restaurant_clocking production readiness checks."

    def handle(self, *args, **options):
        problems = []
        warnings = []

        if settings.DEBUG:
            problems.append("DJANGO_DEBUG is True. Production should use DJANGO_DEBUG=False.")
        if not settings.SECRET_KEY or "unsafe" in settings.SECRET_KEY or settings.SECRET_KEY == "change-me":
            problems.append("DJANGO_SECRET_KEY is missing or still uses a placeholder.")
        if not settings.ALLOWED_HOSTS:
            problems.append("DJANGO_ALLOWED_HOSTS is empty.")
        if "*" in settings.ALLOWED_HOSTS:
            warnings.append("DJANGO_ALLOWED_HOSTS contains '*'. Use specific hostnames/IPs for production.")
        if getattr(settings, "EMAIL_HOST_PASSWORD", "") in {"", "your-gmail-app-password"}:
            warnings.append("EMAIL_HOST_PASSWORD is empty or a placeholder. Email alerts may not send.")
        if not getattr(settings, "MANAGER_ALERT_EMAIL", ""):
            warnings.append("MANAGER_ALERT_EMAIL is empty. Manager email alerts may not send.")
        if not getattr(settings, "CSRF_COOKIE_SECURE", False):
            warnings.append("CSRF_COOKIE_SECURE is False. Use True when serving over HTTPS.")
        if not getattr(settings, "SESSION_COOKIE_SECURE", False):
            warnings.append("SESSION_COOKIE_SECURE is False. Use True when serving over HTTPS.")

        if problems:
            self.stdout.write(self.style.ERROR("Production check failed:"))
            for item in problems:
                self.stdout.write(self.style.ERROR(f"  - {item}"))
        else:
            self.stdout.write(self.style.SUCCESS("Production check passed: no blocking issues found."))

        if warnings:
            self.stdout.write(self.style.WARNING("Warnings:"))
            for item in warnings:
                self.stdout.write(self.style.WARNING(f"  - {item}"))

        if problems:
            raise SystemExit(1)
PY

cat >> PRODUCTION_CLEANUP_NOTES.md <<'TXT'

## Patch 40 notes

Patch 40 hardens deployment settings without changing the clocking, roster, payroll, or CSV logic.

New/confirmed `.env` settings:

- `DJANGO_DEBUG=False`
- `DJANGO_ALLOWED_HOSTS=...`
- `DJANGO_CSRF_TRUSTED_ORIGINS=...`
- `DJANGO_CSRF_COOKIE_SECURE=True`
- `DJANGO_SESSION_COOKIE_SECURE=True`
- `DJANGO_USE_X_FORWARDED_PROTO=True`
- `DJANGO_LOG_LEVEL=INFO`

Useful checks:

```bash
python3 manage.py check --deploy
python3 manage.py production_check
```

If the site is HTTPS-only, consider setting:

```bash
DJANGO_SECURE_SSL_REDIRECT=True
```
TXT

python3 manage.py check
python3 manage.py production_check || true

echo ""
echo "Patch 40 complete."
echo "Next recommended commands:"
echo "  git status"
echo "  git add ."
echo "  git commit -m 'Patch 40 production settings hardening'"
echo "  git push"
echo "  sudo systemctl restart restaurant_clocking"
echo ""
echo "After restart, test the public site, manager login, roster upload, and one clock-in flow."
