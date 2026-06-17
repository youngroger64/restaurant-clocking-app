from django.contrib import admin
from .models import Employee, ClockEvent, RosterShift

@admin.register(Employee)
class EmployeeAdmin(admin.ModelAdmin):
    list_display = ("employee_number", "name", "active")


@admin.register(ClockEvent)
class ClockEventAdmin(admin.ModelAdmin):
    list_display = ("employee", "clock_type", "timestamp", "method")
    list_filter = ("clock_type", "method", "timestamp")
    search_fields = ("employee__name", "employee__employee_number")
    ordering = ("-timestamp",)

@admin.register(RosterShift)
class RosterShiftAdmin(admin.ModelAdmin):
    list_display = (
        "employee",
        "shift_date",
        "start_time",
        "end_time",
        "break_minutes",
    )
