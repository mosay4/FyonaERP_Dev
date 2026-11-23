"""HTML email templates for Fyona (RTL Arabic, brand-compatible)."""

BRAND_COLOR = "#A01530"
BRAND_NAME = "Fyona ERP"


def _layout(title: str, body_html: str) -> str:
    return f"""\
<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>{title}</title>
</head>
<body style="margin:0;padding:0;background:#F4F4F7;font-family:'Segoe UI',Tahoma,Arial,sans-serif">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F4F4F7;padding:24px 12px">
    <tr><td align="center">
      <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#FFFFFF;border-radius:16px;overflow:hidden;box-shadow:0 4px 24px rgba(0,0,0,.06)">
        <tr>
          <td style="background:{BRAND_COLOR};padding:28px 32px;text-align:center">
            <div style="color:#FFFFFF;font-size:24px;font-weight:800;letter-spacing:.5px">{BRAND_NAME}</div>
            <div style="color:rgba(255,255,255,.8);font-size:13px;margin-top:4px">نظام إدارة الأعمال</div>
          </td>
        </tr>
        <tr>
          <td style="padding:32px 32px 16px;color:#1A1A2E;font-size:15px;line-height:1.8">
            {body_html}
          </td>
        </tr>
        <tr>
          <td style="padding:20px 32px 28px;border-top:1px solid #F0F0F4;text-align:center">
            <div style="color:#888;font-size:12px;line-height:1.7">
              رسالة تلقائية من نظام <b>{BRAND_NAME}</b> — لا ترد على هذا البريد.<br>
              في حال واجهت أي مشكلة تواصل معنا عبر البريد:
              <a href="mailto:fyona.erp@gmail.com" style="color:{BRAND_COLOR}">fyona.erp@gmail.com</a>
            </div>
          </td>
        </tr>
      </table>
    </td></tr>
  </table>
</body>
</html>"""


def otp_email(code: str, ttl_minutes: int, purpose_label: str = "") -> str:
    title = "رمز التحقق — Fyona ERP"
    intro = (
        f"لقد طلبت رمز التحقق {purpose_label}. استخدم الرمز التالي لإكمال العملية:"
        if purpose_label
        else "لقد طلبت رمز التحقق. استخدم الرمز التالي لإكمال العملية:"
    )
    body = f"""\
<h2 style="margin:0 0 8px;color:#1A1A2E;font-size:20px">مرحباً</h2>
<p style="margin:0 0 16px">{intro}</p>
<table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 auto 18px">
  <tr>
    <td style="background:{BRAND_COLOR};color:#FFFFFF;font-size:34px;font-weight:800;letter-spacing:10px;border-radius:12px;padding:16px 28px;text-align:center">{code}</td>
  </tr>
</table>
<p style="margin:0 0 6px;color:#555">الرمز صالح لمدة <b style="color:{BRAND_COLOR}">{ttl_minutes} دقائق</b>.</p>
<p style="margin:0;color:#999;font-size:13px">إذا لم تكن أنت من طلب الرمز، تجاهل هذه الرسالة.</p>
"""
    return _layout(title, body)


def welcome_email(full_name: str = "") -> str:
    title = "أهلاً بك في Fyona ERP"
    greeting = f"أهلاً بك{f' {full_name}' if full_name else ''} 🎉"
    body = f"""\
<h2 style="margin:0 0 8px;color:#1A1A2E;font-size:20px">{greeting}</h2>
<p style="margin:0 0 12px">تم تأكيد بريدك الإلكتروني وإنشاء حسابك في <b>{BRAND_NAME}</b> بنجاح.</p>
<p style="margin:0 0 12px">نحن متحمسون لانضمامك! يمكنك الآن البدء بإدارة أعمالك بكل سهولة.</p>
"""
    return _layout(title, body)


def password_changed_email(device_name: str = "") -> str:
    title = "تم تغيير كلمة المرور — Fyona ERP"
    device = f" من الجهاز <b>{device_name}</b>" if device_name else ""
    body = f"""\
<h2 style="margin:0 0 8px;color:#1A1A2E;font-size:20px">تغيير كلمة المرور 🔒</h2>
<p style="margin:0 0 12px">تم تغيير كلمة المرور لحسابك{device} بنجاح.</p>
<p style="margin:0 0 12px;color:#555">إذا لم تكن أنت من قام بهذا التغيير، يرجى التواصل مع الدعم فوراً وتأمين حسابك.</p>
"""
    return _layout(title, body)


def login_alert_text(device_name: str, ip: str, time_str: str) -> str:
    """Plain-text twin of [login_alert_email]: one fact per line so mail
    clients that render text (snippets, plain-text views) never glue words
    together. The HTML layout itself is untouched."""
    return (
        "Fyona ERP — نظام إدارة الأعمال\n"
        "تسجيل دخول جديد\n"
        "تم تسجيل الدخول إلى حسابك من جهاز جديد:\n"
        f"الجهاز: {device_name}\n"
        f"عنوان IP: {ip}\n"
        f"الوقت: {time_str}\n"
        "إذا لم تكن أنت، قم بتغيير كلمة المرور فوراً."
    )


def login_alert_email(device_name: str, ip: str, time_str: str) -> str:
    title = "تسجيل دخول من جهاز جديد — Fyona ERP"
    body = f"""\
<h2 style="margin:0 0 8px;color:#1A1A2E;font-size:20px">تسجيل دخول جديد 🛡️</h2>
<p style="margin:0 0 12px">تم تسجيل الدخول إلى حسابك من جهاز جديد:</p>
<table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 0 12px">
  <tr><td style="background:#F7F7FA;border-radius:8px;padding:12px 18px;color:#333;font-size:13px;line-height:1.9">
    الجهاز: <b>{device_name}</b><br>
    عنوان IP: <b>{ip}</b><br>
    الوقت: <b>{time_str}</b>
  </td></tr>
</table>
<p style="margin:0;color:#999;font-size:13px">إذا لم تكن أنت، قم بتغيير كلمة المرور فوراً.</p>
"""
    return _layout(title, body)


def notification_email(title: str, message: str) -> str:
    body = f"""\
<h2 style="margin:0 0 8px;color:#1A1A2E;font-size:20px">{title}</h2>
<p style="margin:0 0 12px;color:#333">{message}</p>
"""
    return _layout(title, body)


def subscription_request_email(
    *,
    request_ref: str,
    user_name: str,
    user_phone: str = "",
    user_email: str = "",
    org_name: str = "",
    plan_name: str = "",
    period: str = "",
    amount: str = "",
    currency: str = "",
    payment_method: str = "",
    created_at: str = "",
) -> str:
    """Rich invoice-style email for a new subscription request.

    Branded in the FYONA look (white card + liver-red accents) and lays out the
    request details in a clean table so admins can act at a glance.
    """
    title = "طلب اشتراك جديد — FYONA"
    phone_cell = user_phone or "—"
    email_cell = user_email or "—"
    repo = f"""\
<div style="font-size:16px;font-weight:800;color:#1A1A2E;margin:0 0 4px">📬 طلب اشتراك جديد</div>
<p style="margin:0 0 16px;color:#666;font-size:13px">وصل طلب اشتراك جديد إلى إدارة النظام، يرجى مراجعته من لوحة التحكم.</p>

<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;margin:0 0 18px;background:#FFF7F8;border:1px solid #F3D7DB;border-radius:12px;overflow:hidden">
  <tr>
    <td style="background:{BRAND_COLOR};color:#FFFFFF;padding:10px 16px;font-size:15px;font-weight:800;text-align:right">رقم الطلب</td>
    <td style="background:#FFFFFF;color:#1A1A2E;padding:10px 16px;font-size:15px;font-weight:800;text-align:left" dir="ltr">{request_ref}</td>
  </tr>
  <tr style="background:#FFF7F8">
    <td style="color:#8A0F26;padding:9px 16px;font-size:13px;font-weight:700;border-top:1px solid #F3D7DB">اسم المستخدم</td>
    <td style="color:#1A1A2E;padding:9px 16px;font-size:14px;font-weight:700;border-top:1px solid #F3D7DB">{user_name}</td>
  </tr>
  <tr>
    <td style="color:#8A0F26;padding:9px 16px;font-size:13px;font-weight:700;border-top:1px solid #F3D7DB">رقم الهاتف</td>
    <td style="color:#1A1A2E;padding:9px 16px;font-size:14px;border-top:1px solid #F3D7DB" dir="ltr">{phone_cell}</td>
  </tr>
  <tr style="background:#FFF7F8">
    <td style="color:#8A0F26;padding:9px 16px;font-size:13px;font-weight:700;border-top:1px solid #F3D7DB">البريد الإلكتروني</td>
    <td style="color:#1A1A2E;padding:9px 16px;font-size:14px;border-top:1px solid #F3D7DB" dir="ltr">{email_cell}</td>
  </tr>
  <tr>
    <td style="color:#8A0F26;padding:9px 16px;font-size:13px;font-weight:700;border-top:1px solid #F3D7DB">المنظمة</td>
    <td style="color:#1A1A2E;padding:9px 16px;font-size:14px;border-top:1px solid #F3D7DB">{org_name or "—"}</td>
  </tr>
  <tr style="background:#FFF7F8">
    <td style="color:#8A0F26;padding:9px 16px;font-size:13px;font-weight:700;border-top:1px solid #F3D7DB">الباقة</td>
    <td style="color:#1A1A2E;padding:9px 16px;font-size:14px;font-weight:700;border-top:1px solid #F3D7DB">{plan_name}{f' — {period}' if period else ''}</td>
  </tr>
  <tr>
    <td style="color:#8A0F26;padding:9px 16px;font-size:13px;font-weight:700;border-top:1px solid #F3D7DB">قيمة الاشتراك</td>
    <td style="color:#1A1A2E;padding:9px 16px;font-size:16px;font-weight:900;border-top:1px solid #F3D7DB">{amount} <span style="color:{BRAND_COLOR}">{currency}</span></td>
  </tr>
  <tr style="background:#FFF7F8">
    <td style="color:#8A0F26;padding:9px 16px;font-size:13px;font-weight:700;border-top:1px solid #F3D7DB">طريقة الدفع</td>
    <td style="color:#1A1A2E;padding:9px 16px;font-size:14px;font-weight:700;border-top:1px solid #F3D7DB">{payment_method}</td>
  </tr>
  <tr>
    <td style="color:#8A0F26;padding:9px 16px;font-size:13px;font-weight:700;border-top:1px solid #F3D7DB">تاريخ الطلب</td>
    <td style="color:#1A1A2E;padding:9px 16px;font-size:14px;border-top:1px solid #F3D7DB" dir="ltr">{created_at}</td>
  </tr>
</table>

<p style="margin:0 0 18px;color:#555;font-size:13px;line-height:1.8">
  لاعتماد هذا الاشتراك أو رفضه، افتح قسم <b style="color:{BRAND_COLOR}">طلبات الاشتراك</b> في لوحة تحكم FYONA ثم اختر "تفاصيل" واتخذ القرار.
</p>
"""
    return _layout(title, repo)
