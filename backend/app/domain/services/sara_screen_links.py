"""Personal Sara: a reply that promises a screen button always carries it.

The model sometimes answers «الزر تحت جاهز — اضغط عليه» without calling
open_app_screen: the history it sees is text only, so on a repeated request
it imitates its earlier reply (whose button it cannot see) and emits no
action. After the agent loop, when the user asked to open/send a screen or
the reply talks about a button/opening a screen, and no navigation action
was produced, the screen is derived deterministically from the user's words
(then Sara's) and the open_screen action is attached.

The Flutter chat applies the same rule as a second safety net
(lib/features/ai/domain/agent/sara_link_fallback.dart).
"""
import re
from typing import Optional

# Phrase/word → (Arabic screen name, English screen name, route). Earlier
# entries win on the same word (اشتراكات → المتكررة, not الاشتراك).
_KEYWORDS = [
    ("كشف حساب", ("كشف الحساب", "Bank Statement", "/personal/bank-statement")),
    ("bank statement", ("كشف الحساب", "Bank Statement", "/personal/bank-statement")),
    ("الشجره الماليه", ("الشجرة المالية", "Financial Tree", "/personal/financial-tree")),
    ("شجره", ("الشجرة المالية", "Financial Tree", "/personal/financial-tree")),
    ("financial tree", ("الشجرة المالية", "Financial Tree", "/personal/financial-tree")),
    ("حسابات التجار", ("حسابات التجار", "Merchant Accounts", "/personal/merchant-accounts")),
    ("تجار", ("حسابات التجار", "Merchant Accounts", "/personal/merchant-accounts")),
    ("merchant", ("حسابات التجار", "Merchant Accounts", "/personal/merchant-accounts")),
    ("نسخ احتياطي", ("النسخ الاحتياطي", "Backup", "/personal/backup")),
    ("نسخه احتياطيه", ("النسخ الاحتياطي", "Backup", "/personal/backup")),
    ("backup", ("النسخ الاحتياطي", "Backup", "/personal/backup")),
    ("تقرير", ("التقارير", "Reports", "/personal/reports")),
    ("تقارير", ("التقارير", "Reports", "/personal/reports")),
    ("report", ("التقارير", "Reports", "/personal/reports")),
    ("متكرر", ("المتكررة", "Recurring", "/personal/recurring")),
    ("اشتراكات", ("المتكررة", "Recurring", "/personal/recurring")),
    ("recurring", ("المتكررة", "Recurring", "/personal/recurring")),
    ("ميزاني", ("الميزانية", "Budget", "/personal/budget")),
    ("budget", ("الميزانية", "Budget", "/personal/budget")),
    ("اهداف", ("الأهداف", "Goals", "/personal/savings")),
    ("هدف", ("الأهداف", "Goals", "/personal/savings")),
    ("هدفي", ("الأهداف", "Goals", "/personal/savings")),
    ("ادخار", ("الأهداف", "Goals", "/personal/savings")),
    ("goal", ("الأهداف", "Goals", "/personal/savings")),
    ("saving", ("الأهداف", "Goals", "/personal/savings")),
    ("ديون", ("الديون", "Debts", "/personal/debts")),
    ("دين", ("الديون", "Debts", "/personal/debts")),
    ("debt", ("الديون", "Debts", "/personal/debts")),
    ("تصنيف", ("التصنيفات", "Categories", "/personal/categories")),
    ("categor", ("التصنيفات", "Categories", "/personal/categories")),
    ("تحويل", ("التحويل", "Transfer", "/personal/transfer")),
    ("transfer", ("التحويل", "Transfer", "/personal/transfer")),
    ("بنوك", ("البنوك", "Banks", "/personal/banks")),
    ("بنك", ("البنوك", "Banks", "/personal/banks")),
    ("بنكي", ("البنوك", "Banks", "/personal/banks")),
    ("bank", ("البنوك", "Banks", "/personal/banks")),
    ("محفظه", ("المحفظة", "Wallet", "/personal/transactions")),
    ("معاملات", ("المحفظة", "Wallet", "/personal/transactions")),
    ("عمليات", ("المحفظة", "Wallet", "/personal/transactions")),
    ("wallet", ("المحفظة", "Wallet", "/personal/transactions")),
    ("transaction", ("المحفظة", "Wallet", "/personal/transactions")),
]

_ASK_CUES = (
    "افتح", "فتح", "وديني", "ودني", "خذني", "انتقل", "صفحه", "شاشه", "زر", "زرار",
    "رابط", "لينك", "ارسل لي", "رسل لي", "رسلي", "ارسلي", "ابعث", "ابعتلي", "دزلي",
    "open", "button", "link", "take me", "go to", "navigate", "send me",
)
_REPLY_CUES = (
    "الزر", "زر ", "اضغط", "يوديك", "يفتح لك", "فتحت لك", "افتح لك", "الرابط",
    "button", "tap", "press", "link below",
)
_PREFIXES = ("وال", "بال", "فال", "كال", "لل", "ال", "و", "ب", "ل", "ف")
_SPLIT = re.compile(r"[\s,،.؟?!:؛\-_/«»\"'()\[\]]+")


def _norm(text: str) -> str:
    t = (text or "").lower()
    t = re.sub("[ً-ٟـ]", "", t)
    t = re.sub("[أإآ]", "ا", t)
    return t.replace("ة", "ه").replace("ى", "ي")


def _forms(word: str):
    yield word
    for p in _PREFIXES:
        if word.startswith(p) and len(word) - len(p) >= 3:
            yield word[len(p):]


def asks_for_screen(text: str) -> bool:
    t = _norm(text)
    return any(c in t for c in _ASK_CUES)


def reply_promises_button(text: str) -> bool:
    t = _norm(text)
    return any(c in t for c in _REPLY_CUES)


def screen_from_text(text: str) -> Optional[tuple]:
    """(name_ar, name_en, route) of the first Personal screen [text] names."""
    t = _norm(text)
    if not t.strip():
        return None
    words = [w for w in _SPLIT.split(t) if w]
    best_at, best = None, None
    for kw, target in _KEYWORDS:
        kw = _norm(kw)
        at = -1
        if " " in kw:
            i = t.find(kw)
            if i >= 0:
                at = len([w for w in t[:i].split() if w])
        else:
            for i, w in enumerate(words):
                if any(f == kw or (len(kw) >= 4 and f.startswith(kw)) for f in _forms(w)):
                    at = i
                    break
        if at >= 0 and (best_at is None or at < best_at):
            best_at, best = at, target
    return best


def missing_open_action(query: str, answer: str, actions: list) -> Optional[dict]:
    """The open_screen params to attach, or None when nothing is missing.

    [actions] are AgentAction objects or dicts with an ``action`` key.
    """
    def kind(a):
        return a.get("action") if isinstance(a, dict) else getattr(a, "action", None)

    if any(kind(a) in ("open_screen", "open_entity", "export_pdf") for a in actions or []):
        return None
    if not (asks_for_screen(query) or reply_promises_button(answer)):
        return None
    target = screen_from_text(query) or screen_from_text(answer)
    if not target:
        return None
    name_ar, name_en, route = target
    return {"screen": name_ar, "screen_en": name_en, "route": route}
