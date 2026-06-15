from django.urls import path


from .views import (
    home_page,
    clock_page,
    export_clock_events_csv,
    upload_roster,
    manager_dashboard,
    manager_weekly_summary,
    generate_test_clock_events,
    manager_daily_monitor,
)

urlpatterns = [
    path('', home_page, name='home'),
    path('clock/', clock_page, name='clock'),
    path('export/clock-events/', export_clock_events_csv, name='export_clock_events_csv'),
    path('manager/upload-roster/', upload_roster, name='upload_roster'),
    path('manager/dashboard/', manager_dashboard, name='manager_dashboard'),
    path('manager/weekly-summary/', manager_weekly_summary, name='manager_weekly_summary'),
    path('manager/generate-test-events/', generate_test_clock_events, name='generate_test_clock_events'),
    path('manager/daily-monitor/', manager_daily_monitor, name='manager_daily_monitor'),
]
