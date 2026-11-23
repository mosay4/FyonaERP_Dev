"""Atomic employee payments: original currency, explicit branch, locked account."""
import json
import hashlib
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP, localcontext
from uuid import uuid4

from fastapi import HTTPException
from sqlalchemy import select

from ...core.qa_business_ledger import contains_registered_branch
from ..entities.auth_entities import Organization
from ..entities.business_settings_entities import BusinessProjectSettings
from ..entities.employee_workspace_entities import EmployeeWorkspace, EmployeeSalaryPayment, EmployeeDebt
from ..entities.finance_entities import BankAccount, BankTransaction
from ..entities.sale_entities import Branch
from .currency_service import CurrencyService
from .employee_receipt_service import identity_snapshot
from .employment_notification_service import save_employment_event
from .push_service import notify_user

CENT = Decimal('0.01')


def money(value):
    with localcontext() as context:
        context.prec = 60
        return Decimal(str(value)).quantize(CENT, rounding=ROUND_HALF_UP)


def snapshot(row):
    try:
        value = json.loads(row.receipt_snapshot or '{}')
        return value if isinstance(value, dict) else {}
    except (TypeError, ValueError):
        return {}


def decimal_rate(source, target, rates):
    """Return target units per source unit, using approved observations only."""
    source = 'YER_NEW' if source == 'YER' else source
    target = 'YER_NEW' if target == 'YER' else target
    if source == target:
        return Decimal(1)
    global_rates = rates.get('global', {})
    cities = rates.get('yemen', {})
    def valid(value):
        try:
            result = Decimal(str(value))
            return result if result.is_finite() and result > 0 else None
        except Exception:
            return None
    def city(code):
        return cities.get('sanaa' if code == 'YER_OLD' else 'aden', {})
    if target.startswith('YER') and source in ('SAR', 'USD'):
        direct = valid(city(target).get(source, {}).get('average'))
        if direct is not None:
            return direct
    if source.startswith('YER') and target in ('SAR', 'USD'):
        direct = valid(city(source).get(target, {}).get('average'))
        if direct is not None:
            return Decimal(1) / direct
    def per_usd(code):
        if code == 'USD':
            return Decimal(1)
        return valid(city(code).get('USD', {}).get('average') if code.startswith('YER') else global_rates.get(code))
    a, b = per_usd(source), per_usd(target)
    return b / a if a is not None and b is not None else None


async def conversion(amount, payment_currency, base_currency, manual_rate=None):
    if payment_currency == base_currency:
        rate = Decimal(1)
    elif manual_rate is not None:
        rate = Decimal(str(manual_rate))
    else:
        # Ordinary get_all_rates reads memory/durable cache, never providers.
        try:
            rates = await CurrencyService.get_instance().get_all_rates()
            rate = decimal_rate(payment_currency, base_currency, rates)
        except Exception:
            rate = None
    if rate is None or not rate.is_finite() or rate <= 0:
        raise HTTPException(422, detail='سعر الصرف غير متاح؛ أدخل سعر صرف صحيحاً')
    with localcontext() as context:
        context.prec = 60
        equivalent = money(amount * rate)
    if equivalent > Decimal('9999999999999999.99'):
        raise HTTPException(422, detail='المبلغ المحول يتجاوز الحد المسموح')
    return rate, equivalent


def debt_value(row):
    return Decimal(str(row.amount or 0))


def paid_salary_base(rows, base_currency):
    paid = Decimal(0)
    for row in rows:
        saved = snapshot(row)
        if saved.get('base_currency') == base_currency and saved.get('converted_amount') is not None:
            paid += Decimal(str(saved['converted_amount']))
        elif row.currency == base_currency:
            paid += Decimal(str(row.amount))
        else:
            return None
    return paid


def outstanding_debts(rows):
    """Allocate legacy unlinked settlements FIFO; new ones name one charge."""
    charges = sorted((row for row in rows if row.kind == 'charge'),
                     key=lambda row: (str(row.created_at or ''), str(row.id)))
    remaining = {str(row.id): debt_value(row) for row in charges}
    for row in rows:
        if row.kind != 'settlement': continue
        left = debt_value(row)
        target = snapshot(row).get('original_debt_id')
        candidates = [c for c in charges if c.direction == row.direction and c.currency == row.currency
                      and (not target or str(c.id) == target)]
        for charge in candidates:
            key = str(charge.id)
            use = min(remaining[key], left)
            remaining[key] -= use
            left -= use
            if left <= 0: break
    return remaining


def cash_effect(*, salary, direction=None, kind=None):
    if salary: return 'debit'
    if kind == 'charge':
        return 'debit' if direction == 'employee_owes' else 'none'
    return 'credit' if direction == 'employee_owes' else 'debit'


async def record_finance(db, employee, org_id, user_id, data, allowed_ids, *, salary):
    if data.branch_id is None or data.bank_account_id is None:
        raise HTTPException(422, detail='اختر الفرع ثم حساب الدفع')
    if data.branch_id not in allowed_ids:
        raise HTTPException(403, detail='الفرع خارج نطاق وصولك')
    if await contains_registered_branch(db, [data.branch_id]):
        # No second writer: this remains blocked until the device has an
        # authorized payroll/debt ledger, even for debt with no bank effect.
        raise HTTPException(409, detail={
            'code': 'employee_finance_device_scope',
            'message': 'الراتب ودين الموظف لهذا الفرع غير متاحين في المسار المتصل.',
        })
    request_data = data.model_dump(mode='json', exclude={'idempotency_key'})
    request_data['amount'] = str(money(data.amount))
    request_hash = hashlib.sha256(json.dumps(request_data, sort_keys=True).encode()).hexdigest()
    if data.idempotency_key:
        model = EmployeeSalaryPayment if salary else EmployeeDebt
        previous = (await db.execute(select(model).where(
            model.employee_id == employee.id, model.organization_id == org_id))).scalars().all()
        for existing in previous:
            saved = snapshot(existing)
            if saved.get('idempotency_key') != data.idempotency_key:
                continue
            if saved.get('request_hash') != request_hash:
                raise HTTPException(409, detail='مفتاح العملية مستخدم لبيانات مختلفة')
            return existing, await db.get(Organization, org_id)
    branch = (await db.execute(select(Branch).where(
        Branch.id == data.branch_id, Branch.organization_id == org_id,
        Branch.is_active.is_(True), Branch.is_archived.is_(False)))).scalar_one_or_none()
    if branch is None:
        raise HTTPException(404, detail='الفرع غير متاح')
    bank = (await db.execute(select(BankAccount).where(
        BankAccount.id == data.bank_account_id, BankAccount.organization_id == org_id,
        BankAccount.branch_id == branch.id, BankAccount.is_deleted.is_(False),
        BankAccount.is_active.is_(True)).with_for_update())).scalar_one_or_none()
    if bank is None:
        raise HTTPException(422, detail='حساب الدفع لا يتبع الفرع المحدد')
    payment_currency = (data.payment_currency or data.currency).strip().upper()
    if bank.currency.upper() != payment_currency:
        raise HTTPException(422, detail='عملة الدفع لا تطابق عملة الحساب')
    ws = (await db.execute(select(EmployeeWorkspace).where(
        EmployeeWorkspace.employee_id == employee.id))).scalar_one_or_none()
    source_debt = None
    debt_rows = []
    if not salary and data.kind == 'settlement':
        debt_rows = (await db.execute(select(EmployeeDebt).where(
            EmployeeDebt.employee_id == employee.id, EmployeeDebt.organization_id == org_id))).scalars().all()
        debt_id = getattr(data, 'debt_id', None)
        if debt_id:
            source_debt = next((r for r in debt_rows if r.id == debt_id and r.kind == 'charge'
                                and r.direction == data.direction), None)
            if source_debt is None:
                raise HTTPException(404, detail='فاتورة الدين غير موجودة لهذا الموظف والاتجاه')
            if data.currency.upper() != source_debt.currency.upper():
                raise HTTPException(422, detail='عملة الدين الأصلية لا تطابق الفاتورة المختارة')
    base_currency = (ws.salary_currency if salary and ws else data.currency).upper()
    if salary and not ws:
        base_currency = 'SAR'
    rate, equivalent = await conversion(data.amount, payment_currency, base_currency, data.exchange_rate)
    if equivalent <= 0:
        raise HTTPException(422, detail='المبلغ المحول أقل من أصغر وحدة للعملة')
    remaining = equivalent if not salary and data.kind == 'charge' else None
    if salary:
        rows = (await db.execute(select(EmployeeSalaryPayment).where(
            EmployeeSalaryPayment.employee_id == employee.id,
            EmployeeSalaryPayment.organization_id == org_id))).scalars().all()
        paid = paid_salary_base(rows, base_currency)
        if paid is None:
            raise HTTPException(409, detail='دفعة تاريخية بعملة مختلفة تحتاج سعر الصرف الأصلي قبل متابعة الراتب')
        remaining = money(Decimal(str(employee.salary or 0)) - paid - equivalent)
    elif data.kind == 'settlement':
        if source_debt is not None:
            outstanding = outstanding_debts(debt_rows).get(str(source_debt.id), Decimal(0))
        else:
            outstanding = sum((debt_value(row) * (-1 if row.kind == 'settlement' else 1)
                               for row in debt_rows if row.direction == data.direction and row.currency == base_currency), Decimal(0))
        if equivalent > outstanding:
            raise HTTPException(422, detail='مبلغ السداد أكبر من الدين المتبقي بهذه العملة')
        remaining = money(outstanding - equivalent)
    effect = cash_effect(salary=salary, direction=None if salary else data.direction,
                         kind=None if salary else data.kind)
    outgoing = effect == 'debit'
    balance = money(bank.balance or 0)
    if outgoing and balance < data.amount:
        settings = await db.get(BusinessProjectSettings, org_id)
        shared = json.loads(settings.settings or '{}') if settings else {}
        if shared.get('allow_negative') is not True:
            raise HTTPException(422, detail='رصيد الحساب غير كافٍ والدفع بالسالب غير مسموح')
    next_balance = money(balance + (-data.amount if outgoing else data.amount if effect == 'credit' else Decimal(0)))
    if abs(next_balance) > Decimal('9999999999.99'):
        raise HTTPException(422, detail='رصيد الحساب الناتج يتجاوز الحد المسموح')
    if effect != 'none': bank.balance = next_balance
    op = f"{'SAL' if salary else 'DBT'}-{datetime.now(timezone.utc):%Y%m%d}-{uuid4().hex[:12].upper()}"
    organization = await db.get(Organization, org_id)
    details = json.loads(identity_snapshot(employee, organization))
    details.update(base_currency=base_currency, payment_currency=payment_currency,
        payment_amount=str(data.amount), exchange_rate=str(rate), converted_amount=str(equivalent),
        fx_rate=str(rate), base_amount=str(equivalent), original_currency=base_currency,
        remaining_amount=str(remaining) if remaining is not None else None)
    details.update(idempotency_key=data.idempotency_key, request_hash=request_hash)
    details.update(cash_effect=effect, cash_amount=str(data.amount if effect != 'none' else Decimal(0)))
    if source_debt is not None:
        details.update(original_debt_id=str(source_debt.id), original_debt_invoice=source_debt.invoice_no,
                       original_debt_amount=str(source_debt.amount), outstanding_before=str(outstanding))
    common = dict(id=uuid4(), organization_id=org_id, employee_id=employee.id,
        notes=data.notes, created_by=user_id, bank_account_id=bank.id,
        branch_id=branch.id, bank_name=bank.bank_name, branch_name=branch.name,
        invoice_no=op, receipt_snapshot=json.dumps(details, ensure_ascii=False))
    if salary:
        row = EmployeeSalaryPayment(**common, operation_no=op, amount=data.amount,
            currency=payment_currency, base_salary=employee.salary or 0, remaining_salary=remaining)
    else:
        row = EmployeeDebt(**common, direction=data.direction, kind=data.kind,
            amount=equivalent, currency=base_currency)
    db.add(row)
    if effect != 'none':
        db.add(BankTransaction(organization_id=org_id, bank_account_id=bank.id,
            tx_type='withdrawal' if outgoing else 'deposit', amount=data.amount,
            currency=payment_currency, running_balance=bank.balance, reference=op,
            description=f'{employee.full_name} — {op}'))
    route = f'/employee-profile/receipt?employee_id={employee.id}&record_id={row.id}&kind={"salary" if salary else "debt"}'
    title = 'تم صرف راتبك' if salary else ('تم تسجيل سداد دين' if data.kind == 'settlement' else 'تم تسجيل دين')
    body = f'{data.amount} {payment_currency} — {branch.name}'
    if ws and ws.linked_user_id:
        await save_employment_event(db, recipient_id=ws.linked_user_id,
            event_id=f'employee-finance:{row.id}', title=title, body=body, route=route,
            image_url=branch.image or organization.avatar)
    await db.commit()
    if ws and ws.linked_user_id:
        await notify_user(db, user_id=ws.linked_user_id, title=title, body=body, action_payload=route,
                          image_url=branch.image or organization.avatar)
    return row, organization
