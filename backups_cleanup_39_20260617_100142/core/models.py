from django.db import models
from django.utils import timezone


class Employee(models.Model):
    employee_number = models.CharField(max_length=20, unique=True)
    name = models.CharField(max_length=100)
    pin = models.CharField(max_length=10)
    active = models.BooleanField(default=True)

    def __str__(self):
        return self.name


class ClockEvent(models.Model):

    CLOCK_TYPES = [
        ('IN', 'Clock In'),
        ('BREAK_START', 'Break Start'),
        ('BREAK_END', 'Break End'),
        ('OUT', 'Clock Out'),
    ]

    employee = models.ForeignKey(Employee, on_delete=models.CASCADE)
    clock_type = models.CharField(max_length=20, choices=CLOCK_TYPES)
    timestamp = models.DateTimeField(default=timezone.now)
    method = models.CharField(max_length=20, default='QR')
    notes = models.TextField(blank=True, default="")

    def __str__(self):
        return f"{self.employee.name} - {self.clock_type}"
class RosterShift(models.Model):
    employee = models.ForeignKey(Employee, on_delete=models.CASCADE)
    shift_date = models.DateField()
    start_time = models.TimeField()
    end_time = models.TimeField()
    break_minutes = models.IntegerField(default=30)

    def __str__(self):
        return f"{self.employee.name} - {self.shift_date}"
