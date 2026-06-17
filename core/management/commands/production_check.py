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
