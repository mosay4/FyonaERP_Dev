"""Cancellation acceptance on Original HTTP; no new accounting policy."""
import time
import pytest

from test_business_linked_http_acceptance import linked_http, checked  # noqa: F401


@pytest.mark.parametrize('kind', ['customer', 'supplier'])
def test_cancelled_linked_invoice_has_no_open_debt_and_one_cancel_notice(linked_http, kind):
    client, d = linked_http
    supplier = kind == 'supplier'
    personal = {'Authorization': 'Bearer ' + d['supplier_bearer' if supplier else 'partner_bearer']}
    merchant = {'Authorization': 'Bearer ' + d['owner_bearer'],
                'X-Branch-Token': d['owner_branch_token']}
    link = d['supplier_link_id' if supplier else 'partner_link_id']
    if not supplier:
        checked(client.post(f'/me/merchant-invites/{link}/accept', headers=personal))
    body = {('supplier_id' if supplier else 'customer_id'): d['supplier_id' if supplier else 'customer_id'],
            'currency': 'SAR', 'idempotency_key': 'cancel-linked-original', 'payments': [],
            'items': [{'product_id': d['product_id'], 'quantity': '1', 'unit_price': '10'}]}
    invoice = checked(client.post('/invoices/issue-' + ('purchase' if supplier else 'sale'),
                                  headers=merchant, json=body), 201)['data']
    result = checked(client.post(f"/invoices/{invoice['id']}/status", headers=merchant,
                                 json={'action': 'cancel'}))['data']
    assert result['status'] == 'cancelled' and float(result['balance']) == 0
    # FastAPI yield-dependency teardown commits after the response is sent. Poll
    # the real read path for at most one second, not an invented fixture commit.
    for _ in range(20):
        invoices = checked(client.get(f'/me/merchant-links/{link}/invoices', headers=personal))['data']
        if invoices[0]['status'] == 'cancelled':
            break
        time.sleep(.05)
    assert invoices[0]['status'] == 'cancelled' and invoices[0]['remaining'] == 0
    debts = checked(client.get(f'/me/merchant-links/{link}/debts', headers=personal))['data']['debts']
    assert sum(float(row['debt']) for row in debts) == 0, 'Original cancel leaves linked receivable/payable debt open'
    notices = checked(client.get('/debt-notifications', headers=personal,
                                  params={'side': 'personal', 'link_id': link}))['data']['items']
    assert len(notices) == 2, 'Missing transactional cancellation notification'
    # Preserve Original API semantics: a repeated cancellation is rejected, but
    # must never insert a second notification or restore the cancelled debt.
    checked(client.post(f"/invoices/{invoice['id']}/status", headers=merchant,
                        json={'action': 'cancel'}), 400)
    replayed = checked(client.get('/debt-notifications', headers=personal,
                                  params={'side': 'personal', 'link_id': link}))['data']['items']
    assert {row['id'] for row in replayed} == {row['id'] for row in notices}


def test_financial_payment_delete_is_not_an_invoice_collection_reversal(linked_http):
    client, d = linked_http
    personal = {'Authorization': 'Bearer ' + d['partner_bearer']}
    merchant = {'Authorization': 'Bearer ' + d['owner_bearer'],
                'X-Branch-Token': d['owner_branch_token']}
    link = d['partner_link_id']
    checked(client.post(f'/me/merchant-invites/{link}/accept', headers=personal))
    invoice = checked(client.post('/invoices/issue-sale', headers=merchant, json={
        'customer_id': d['customer_id'], 'currency': 'SAR', 'payments': [],
        'idempotency_key': 'no-invented-reversal', 'items': [{
            'product_id': d['product_id'], 'quantity': '1', 'unit_price': '10'}]}), 201)['data']
    checked(client.post(f"/business/customers/{d['customer_id']}/payments", headers=merchant,
        json={'invoice_id': invoice['id'], 'bank_account_id': d['account_id'],
              'amount': '3', 'currency': 'SAR', 'payment_method': 'bank'}), 201)
    detail = checked(client.get(f"/me/merchant-links/{link}/operations/{invoice['id']}",
                                headers=personal))['data']
    assert detail['remaining'] == 7
    ident = detail['payments'][0]['id']
    # Existing /payments DELETE addresses financial_payments, NOT invoice
    # payments. Do not invent a reversal endpoint or new cash/debt policy.
    checked(client.delete(f'/payments/{ident}', headers=merchant), 404)
    after = checked(client.get(f'/me/merchant-links/{link}/debts', headers=personal))['data']['debts']
    assert sum(float(row['debt']) for row in after) == 7
    notices = checked(client.get('/debt-notifications', headers=personal,
                                  params={'side': 'personal', 'link_id': link}))['data']['items']
    assert len(notices) == 2  # no approved reversal or reversal notification


@pytest.mark.parametrize('kind', ['customer', 'supplier'])
def test_paid_invoice_cancellation_remains_forbidden_without_reversing_cash(linked_http, kind):
    client, d = linked_http
    supplier = kind == 'supplier'
    personal = {'Authorization': 'Bearer ' + d['supplier_bearer' if supplier else 'partner_bearer']}
    merchant = {'Authorization': 'Bearer ' + d['owner_bearer'],
                'X-Branch-Token': d['owner_branch_token']}
    link = d['supplier_link_id' if supplier else 'partner_link_id']
    if not supplier:
        checked(client.post(f'/me/merchant-invites/{link}/accept', headers=personal))
    invoice = checked(client.post('/invoices/issue-' + ('purchase' if supplier else 'sale'),
        headers=merchant, json={
            ('supplier_id' if supplier else 'customer_id'): d['supplier_id' if supplier else 'customer_id'],
            'currency': 'SAR', 'idempotency_key': 'paid-cancel-policy',
            'payments': [{'bank_account_id': d['account_id'], 'amount': '10', 'currency': 'SAR'}],
            'items': [{'product_id': d['product_id'], 'quantity': '1', 'unit_price': '10'}]}), 201)['data']
    assert invoice['status'] == 'paid'
    banks_before = checked(client.get('/banking/accounts', headers=merchant))
    checked(client.post(f"/invoices/{invoice['id']}/status", headers=merchant,
                        json={'action': 'cancel'}), 400)
    banks_after = checked(client.get('/banking/accounts', headers=merchant))
    assert banks_after == banks_before
    rows = checked(client.get(f'/me/merchant-links/{link}/invoices', headers=personal))['data']
    assert rows[0]['status'] == 'paid' and rows[0]['remaining'] == 0
    notices = checked(client.get('/debt-notifications', headers=personal,
                                  params={'side': 'personal', 'link_id': link}))['data']['items']
    assert notices == []  # no cancelled-debt claim for a rejected cancellation
