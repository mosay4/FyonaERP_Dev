"""Email template wording tests: words must never glue together.

Pure template tests — no database, no SMTP.
"""
import os

os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-at-least-sixteen")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379")

from app.core import email_templates


def test_otp_signup_label_is_separated():
    html = email_templates.otp_email("123456", 10, "للتسجيل")
    assert "رمز التحقق للتسجيل." in html
    assert "التحققللتسجيل" not in html


def test_otp_reset_label_is_separated():
    html = email_templates.otp_email("123456", 10, "لإعادة تعيين كلمة المرور")
    assert "رمز التحقق لإعادة تعيين كلمة المرور." in html
    assert "التحققلإعادة" not in html


def test_otp_email_change_label_is_separated():
    html = email_templates.otp_email("123456", 10, "لتغيير البريد الإلكتروني")
    assert "رمز التحقق لتغيير البريد الإلكتروني." in html
    assert "التحققلتغيير" not in html


def test_otp_without_label_unchanged():
    html = email_templates.otp_email("123456", 10)
    assert "لقد طلبت رمز التحقق. استخدم الرمز التالي لإكمال العملية:" in html


def test_login_alert_text_lines_are_standalone():
    text = email_templates.login_alert_text("Galaxy S22", "1.2.3.4", "2026-09-20 20:17")
    lines = text.splitlines()
    assert "Fyona ERP — نظام إدارة الأعمال" in lines
    assert "الوقت: 2026-09-20 20:17" in lines
    assert "الجهاز: Galaxy S22" in lines
    assert "عنوان IP: 1.2.3.4" in lines
    # The reported gluing must be gone in every projection.
    assert "الأعمالالوقت" not in text


def test_login_alert_html_layout_untouched():
    html = email_templates.login_alert_email("Galaxy S22", "1.2.3.4", "2026-09-20 20:17")
    # Brand header, detail rows and footer all exactly as before.
    assert "نظام إدارة الأعمال</div>" in html
    assert "الجهاز: <b>Galaxy S22</b><br>" in html
    assert "الوقت: <b>2026-09-20 20:17</b>" in html
    assert "fyona.erp@gmail.com" in html
