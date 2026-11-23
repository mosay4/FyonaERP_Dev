from datetime import datetime
from typing import Optional, List
from uuid import UUID
from pydantic import BaseModel, ConfigDict, field_validator


# ── Notifications ──

class NotificationResponse(BaseModel):
    image_url: Optional[str] = None
    id: UUID
    organization_id: UUID
    user_id: Optional[UUID]
    type: str
    title: str
    message: Optional[str]
    action: Optional[str]
    action_payload: Optional[str]
    route: Optional[str] = None
    domain: Optional[str] = None
    is_read: bool
    source_notif_id: Optional[UUID] = None
    is_system: bool = True
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class NotificationMarkReadRequest(BaseModel):
    all: bool = False


# ── Notification Preferences ──

class NotificationPreferencesResponse(BaseModel):
    email_alerts: bool = True
    invoice_alerts: bool = True
    payment_alerts: bool = True
    system_updates: bool = True
    budget_alerts: bool = True
    low_balance_alerts: bool = True
    daily_report: bool = False
    weekly_report: bool = False
    monthly_report: bool = False

    model_config = ConfigDict(from_attributes=True)


class NotificationPreferencesUpdate(BaseModel):
    email_alerts: Optional[bool] = None
    invoice_alerts: Optional[bool] = None
    payment_alerts: Optional[bool] = None
    system_updates: Optional[bool] = None
    budget_alerts: Optional[bool] = None
    low_balance_alerts: Optional[bool] = None
    daily_report: Optional[bool] = None
    weekly_report: Optional[bool] = None
    monthly_report: Optional[bool] = None


# ── Reminders ──

class ReminderCreate(BaseModel):
    title: str
    message: Optional[str] = None
    remind_at: datetime
    repeat: str = "none"  # none, daily, weekly, monthly

    @field_validator("title")
    @classmethod
    def validate_title(cls, v: str) -> str:
        if len(v.strip()) < 2:
            raise ValueError("عنوان التذكير يجب أن يكون حرفين على الأقل")
        return v.strip()

    @field_validator("repeat")
    @classmethod
    def validate_repeat(cls, v: str) -> str:
        if v not in ("none", "daily", "weekly", "monthly"):
            raise ValueError("قيمة التكرار غير صالحة")
        return v


class ReminderUpdate(BaseModel):
    title: Optional[str] = None
    message: Optional[str] = None
    remind_at: Optional[datetime] = None
    repeat: Optional[str] = None
    is_active: Optional[bool] = None

    @field_validator("repeat")
    @classmethod
    def validate_repeat(cls, v: Optional[str]) -> Optional[str]:
        if v is not None and v not in ("none", "daily", "weekly", "monthly"):
            raise ValueError("قيمة التكرار غير صالحة")
        return v


class ReminderResponse(BaseModel):
    id: UUID
    organization_id: UUID
    user_id: Optional[UUID]
    title: str
    message: Optional[str]
    remind_at: datetime
    repeat: str
    is_active: bool
    last_triggered_at: Optional[datetime]
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)
