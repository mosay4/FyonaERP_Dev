from celery import Celery
from celery.schedules import crontab
from app.core.config import settings

celery = Celery(
    "fyona",
    broker=settings.CELERY_BROKER_URL,
    backend=settings.CELERY_RESULT_BACKEND,
)

celery.conf.update(
    task_serializer="json",
    accept_content=["json"],
    result_serializer="json",
    timezone="Asia/Riyadh",
    enable_utc=True,
    task_track_started=True,
    task_time_limit=300,
    task_soft_time_limit=240,
    worker_max_tasks_per_child=1000,
    worker_prefetch_multiplier=1,
    task_acks_late=True,
    task_reject_on_worker_lost=True,
)

# ── Beat schedule: notifications, reminders, periodic reports ──
celery.conf.beat_schedule = {
    "process_due_reminders-every-minute": {
        "task": "process_due_reminders",
        "schedule": 60.0,
    },
    "check_low_balance-every-30-min": {
        "task": "check_low_balance",
        "schedule": 1800.0,
    },
    "check_budget_alerts-every-6-hours": {
        "task": "check_budget_alerts",
        "schedule": 21600.0,
    },
    "generate_daily_report-at-0600": {
        "task": "generate_daily_report",
        "schedule": crontab(hour=6, minute=0),
    },
    "generate_weekly_report-sunday-0600": {
        "task": "generate_weekly_report",
        "schedule": crontab(hour=6, minute=0, day_of_week=0),
    },
    "generate_monthly_report-1st-0600": {
        "task": "generate_monthly_report",
        "schedule": crontab(hour=6, minute=0, day_of_month=1),
    },
    "cleanup-expired-sessions-daily": {
        "task": "cleanup_expired_sessions",
        "schedule": crontab(hour=3, minute=30),
    },
    "purge-personal-relay-hourly": {
        "task": "purge_personal_relay",
        "schedule": 3600.0,
    },
    "retry-renewal-charges-daily": {
        "task": "retry_renewal_charges",
        "schedule": crontab(hour=4, minute=0),
    },
}


@celery.task(bind=True, name="ping")
def ping(self) -> str:
    """Test task to verify Celery worker is operational."""
    return "pong"
