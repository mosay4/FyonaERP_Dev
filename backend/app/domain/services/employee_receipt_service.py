"""Identical receipt projections for the merchant and the linked employee."""
import json


def identity_snapshot(employee, organization) -> str:
    return json.dumps({'employee_name': employee.full_name,
        'organization_name': organization.name,
        'organization_photo': organization.avatar}, ensure_ascii=False)


def _identity(row, employee, organization):
    fallback = {'employee_name': employee.full_name, 'organization_name': organization.name,
                'organization_photo': organization.avatar}
    try:
        value = json.loads(row.receipt_snapshot or '{}')
        if isinstance(value, dict):
            fallback.update({k: value[k] for k in fallback if k in value})
    except (TypeError, ValueError):
        pass
    return fallback


def _fx(row):
    try:
        data = json.loads(row.receipt_snapshot or '{}')
        keys = ('base_currency', 'payment_currency', 'payment_amount',
                'exchange_rate', 'fx_rate', 'converted_amount', 'base_amount',
                'original_currency', 'remaining_amount', 'original_debt_id',
                'original_debt_invoice', 'original_debt_amount', 'outstanding_before', 'cash_effect', 'cash_amount')
        return {key: data[key] for key in keys if key in data}
    except (TypeError, ValueError):
        return {}


def salary_receipt(row, employee, organization):
    return {**_identity(row, employee, organization), **_fx(row), 'id': str(row.id),
        'operation_no': row.operation_no, 'invoice_no': row.invoice_no or row.operation_no,
        'amount': float(row.amount), 'currency': row.currency,
        'paid_at': row.paid_at.isoformat() if row.paid_at else None,
        'notes': row.notes, 'bank_name': row.bank_name, 'branch_name': row.branch_name,
        'base_salary': float(row.base_salary or 0),
        'remaining_salary': float(row.remaining_salary or 0)}


def debt_receipt(row, employee, organization):
    return {**_identity(row, employee, organization), **_fx(row), 'id': str(row.id),
        'invoice_no': row.invoice_no or str(row.id), 'direction': row.direction,
        'kind': row.kind, 'amount': float(row.amount), 'currency': row.currency,
        'notes': row.notes, 'bank_name': row.bank_name, 'branch_name': row.branch_name,
        'created_at': row.created_at.isoformat() if row.created_at else None}
