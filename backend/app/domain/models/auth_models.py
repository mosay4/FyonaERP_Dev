from pydantic import BaseModel, field_validator, ConfigDict, computed_field
from typing import Optional
from datetime import datetime
import re

# ── Organization ──


class OrganizationCreate(BaseModel):
    name: str
    slug: Optional[str] = None
    business_type: Optional[str] = None

    @field_validator("name")
    @classmethod
    def validate_name(cls, v: str) -> str:
        if len(v.strip()) < 2:
            raise ValueError("اسم المؤسسة يجب أن يكون على الأقل حرفين")
        return v.strip()

    @field_validator("slug")
    @classmethod
    def generate_slug(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return None
        slug = v.lower().replace(" ", "-").replace("_", "-")
        slug = re.sub(r"[^a-z0-9-]", "", slug)
        return slug


class OrganizationResponse(BaseModel):
    id: str
    name: str
    slug: str
    business_type: Optional[str]
    subscription_plan: str
    subscription_status: str
    is_active: bool
    onboarding_completed: bool
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


# ── Auth ──


class FirebaseAuthRequest(BaseModel):
    id_token: str
    google_id_token: Optional[str] = None


class RefreshRequest(BaseModel):
    refresh_token: str


class AuthResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    user: "UserResponse"

    @computed_field
    @property
    def token(self) -> str:
        return self.access_token


class UserResponse(BaseModel):
    id: str
    organization_id: str
    full_name: str
    email: str
    phone: Optional[str]
    phone_masked: Optional[str] = None
    phone_complete: bool = False
    role: str
    avatar: Optional[str]
    username: Optional[str] = None
    is_active: bool = True
    is_platform_admin: bool = False
    admin_permissions: list[str] = []
    preferred_language: str = "ar"
    preferred_currency: str = "SAR"
    preferred_usage_mode: Optional[str]
    email_verified: bool = False
    mfa_enabled: bool = False
    last_login_at: Optional[datetime]
    created_at: datetime
    subscription_plan: Optional[str] = None
    subscription_status: Optional[str] = None
    status: Optional[str] = None
    subscription_start_date: Optional[datetime] = None
    subscription_end_date: Optional[datetime] = None
    trial_start_date: Optional[datetime] = None
    trial_end_date: Optional[datetime] = None
    personal_trial_activated: bool = False
    business_trial_activated: bool = False
    organization_name: Optional[str] = None
    organization_avatar: Optional[str] = None

    model_config = ConfigDict(from_attributes=True)


class UserUpdateRequest(BaseModel):
    full_name: Optional[str] = None
    email: Optional[str] = None
    phone: Optional[str] = None
    preferred_language: Optional[str] = None
    preferred_currency: Optional[str] = None
    preferred_usage_mode: Optional[str] = None
    organization_name: Optional[str] = None

    @field_validator("full_name")
    @classmethod
    def validate_full_name(cls, v: Optional[str]) -> Optional[str]:
        if v is not None and len(v.strip()) < 2:
            raise ValueError("الاسم الكامل يجب أن يكون على الأقل حرفين")
        return v.strip() if v else v


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"

    @computed_field
    @property
    def token(self) -> str:
        return self.access_token


class PhoneUpdateRequest(BaseModel):
    phone: str
    country: Optional[str] = None  # ISO 3166-1 alpha-2, e.g. "YE"

    @field_validator("phone")
    @classmethod
    def validate_phone(cls, v: str) -> str:
        if not v or not v.strip():
            raise ValueError("رقم الهاتف مطلوب")
        return v.strip()

    @field_validator("country")
    @classmethod
    def validate_country(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return None
        v = v.strip().upper()
        if not v or len(v) != 2:
            raise ValueError("الدولة المحددة غير صالحة")
        return v


# ── Email / Password Auth ──


def _validate_email(v: str) -> str:
    email = v.strip().lower()
    if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", email):
        raise ValueError("بريد إلكتروني غير صالح")
    return email


def _validate_password(v: str) -> str:
    if len(v) < 8:
        raise ValueError("كلمة المرور يجب أن تكون 8 أحرف على الأقل")
    return v


class RegisterRequest(BaseModel):
    full_name: str
    email: str
    phone: Optional[str] = None
    password: str
    organization_name: Optional[str] = None
    preferred_usage_mode: Optional[str] = None
    organization_name: Optional[str] = None

    @field_validator("full_name")
    @classmethod
    def validate_full_name(cls, v: str) -> str:
        if len(v.strip()) < 2:
            raise ValueError("الاسم الكامل يجب أن يكون على الأقل حرفين")
        return v.strip()

    @field_validator("email")
    @classmethod
    def validate_email(cls, v: str) -> str:
        return _validate_email(v)

    @field_validator("password")
    @classmethod
    def validate_password(cls, v: str) -> str:
        return _validate_password(v)

    @field_validator("phone")
    @classmethod
    def validate_phone(cls, v: Optional[str]) -> Optional[str]:
        if v is not None and len(v.strip()) < 6:
            raise ValueError("رقم الهاتف غير صالح")
        return v.strip() if v else v


class VerifyRegistrationRequest(BaseModel):
    email: str
    otp: str

    @field_validator("email")
    @classmethod
    def validate_email(cls, v: str) -> str:
        return _validate_email(v)

    @field_validator("otp")
    @classmethod
    def validate_otp(cls, v: str) -> str:
        code = v.strip()
        if len(code) < 4 or len(code) > 8:
            raise ValueError("رمز التحقق غير صالح")
        return code


class LoginRequest(BaseModel):
    email: str
    password: str

    @field_validator("email")
    @classmethod
    def validate_email(cls, v: str) -> str:
        return _validate_email(v)


class ForgotPasswordRequest(BaseModel):
    email: str
    # `reset` = account password (email accounts only).
    # `pin`   = the device/app PIN — verification ONLY, never touches the
    #           account password, so external logins (Google) can use it too.
    purpose: str = "reset"

    @field_validator("email")
    @classmethod
    def validate_email(cls, v: str) -> str:
        return _validate_email(v)

    @field_validator("purpose")
    @classmethod
    def validate_purpose(cls, v: str) -> str:
        if v not in ("reset", "pin"):
            raise ValueError("غرض غير صالح")
        return v


class VerifyOtpRequest(BaseModel):
    email: str
    otp: str
    purpose: str = "reset"

    @field_validator("email")
    @classmethod
    def validate_email(cls, v: str) -> str:
        return _validate_email(v)

    @field_validator("otp")
    @classmethod
    def validate_otp(cls, v: str) -> str:
        code = v.strip()
        if len(code) < 4 or len(code) > 8:
            raise ValueError("رمز التحقق غير صالح")
        return code

    @field_validator("purpose")
    @classmethod
    def validate_purpose(cls, v: str) -> str:
        if v not in ("reset", "login", "pin"):
            raise ValueError("غرض غير صالح")
        return v


class ResetPasswordRequest(BaseModel):
    reset_token: str
    new_password: str

    @field_validator("new_password")
    @classmethod
    def validate_password(cls, v: str) -> str:
        return _validate_password(v)


class ChangePasswordRequest(BaseModel):
    current_password: str
    new_password: str

    @field_validator("current_password")
    @classmethod
    def validate_current(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("كلمة المرور الحالية مطلوبة")
        return v

    @field_validator("new_password")
    @classmethod
    def validate_password(cls, v: str) -> str:
        return _validate_password(v)


class EmailChangeVerifyRequest(BaseModel):
    new_email: str
    otp: str

    @field_validator("new_email")
    @classmethod
    def validate_new_email(cls, v: str) -> str:
        return _validate_email(v)

    @field_validator("otp")
    @classmethod
    def validate_otp(cls, v: str) -> str:
        code = v.strip()
        if len(code) < 4 or len(code) > 8:
            raise ValueError("رمز التحقق غير صالح")
        return code


class OtpSentResponse(BaseModel):
    success: bool = True
    message: str = "تم إرسال رمز التحقق بنجاح"
    expires_in_seconds: int
    cooldown_seconds: int = 0


class ResetTokenResponse(BaseModel):
    success: bool = True
    message: str = "تم التحقق من الرمز"
    reset_token: str
    expires_in_seconds: int


class ErrorResponse(BaseModel):
    detail: str
    code: Optional[str] = None


class PaginatedResponse(BaseModel):
    items: list
    total: int
    page: int
    per_page: int
    total_pages: int
