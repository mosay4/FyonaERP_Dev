"""HTTP-level branch membership / all-mode / transfer integration (SQLite)."""

from decimal import Decimal
from uuid import uuid4

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import create_engine
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker

from app.main import app
from app.core.config import settings
from app.core.database import Base, get_db
from app.core.security import create_access_token
from app.domain.entities import auth_entities  # noqa: F401
from app.domain.entities import finance_entities  # noqa: F401
from app.domain.entities import business_entities  # noqa: F401
from app.domain.entities import invoice_entities  # noqa: F401
from app.domain.entities import sale_entities  # noqa: F401
from app.domain.entities import branch_entities  # noqa: F401
from app.domain.entities.auth_entities import (
    Organization, User, UserSession,
)
from datetime import datetime, timedelta, timezone
from app.domain.entities.finance_entities import BankAccount
from app.domain.entities.sale_entities import Branch
from app.domain.entities.branch_entities import BranchMember

pytestmark = pytest.mark.asyncio


async def test_phone_lookup_accepts_national_international_and_arabic_formats(client, _session_factory):
    s = await _employee_access_scenario(_session_factory, full=True)
    async with _session_factory() as db:
        user = await db.get(User, s['worker'].id)
        user.phone = '+967 777 123 456'; user.phone_country = 'YE'; user.public_code = '600101'
        await db.commit()
        assert user.phone_lookup_digits == '967777123456'
        assert user.phone_national_digits == '777123456'
    h = _h(s['owner_token'])
    for query in ['600101', '٦٠٠١٠١', '777123456', '0777123456', '+967777123456', '967777123456', '00967777123456', '٠٠٩٦٧٧٧٧١٢٣٤٥٦']:
        response = await client.get(f'{API}/employees/lookup', headers=h, params={'code': query})
        assert response.status_code == 200, (query, response.text)
        value = response.json()['data']['user']
        assert value['id'] == str(s['worker'].id)
        if query in ['600101', '٦٠٠١٠١']:
            assert value['phone'] is None and value['public_code'] == '600101'
        else:
            assert value['phone'] == '+967 777 123 456' and value['public_code'] is None
    async with _session_factory() as db:
        db.add(User(organization_id=s['own'].id, full_name='Another country', role='owner',
            email=f'{uuid4().hex}@test.local', phone='+966777123456', phone_country='SA'))
        await db.commit()
    response = await client.get(f'{API}/employees/lookup', headers=h, params={'code': '777123456'})
    assert response.status_code == 409, response.text
    response = await client.get(f'{API}/employees/lookup', headers=h, params={'code': '+967777123456'})
    assert response.status_code == 200 and response.json()['data']['user']['id'] == str(s['worker'].id)
    response = await client.get(f'{API}/employees/lookup', headers=h, params={'code': '9999999999'})
    assert response.status_code == 404 and 'الرقم المميز' in response.text and 'الهاتف' in response.text


async def test_employee_debt_overview_get_with_json_header_has_no_empty_body_error(client, _session_factory):
    from app.domain.entities.business_entities import Customer
    s = await _employee_access_scenario(_session_factory, full=True)
    async with _session_factory() as db:
        customer = Customer(organization_id=s['org'].id, branch_id=s['branches'][0].id, name='Assigned customer')
        forbidden = Customer(organization_id=s['org'].id, branch_id=s['branches'][1].id, name='Other branch customer')
        db.add_all([customer, forbidden]); await db.commit()
    selected = await client.post(f'{API}/branches/select', headers=_h(s['worker_token']), json={
        'organization_id': str(s['org'].id), 'branch_id': str(s['branches'][0].id)})
    assert selected.status_code == 200, selected.text
    h = {**_h(s['worker_token'], selected.json()['data']['token']), 'Content-Type': 'application/json'}
    for endpoint in ['overview', 'status']:
        response = await client.get(f'{API}/merchant-links/{endpoint}', headers=h,
            params={'party_kind': 'customer', 'party_id': str(customer.id)})
        assert response.status_code == 200, (endpoint, response.text)
    response = await client.get(f'{API}/merchant-links/overview', headers=h,
        params={'party_kind': 'customer', 'party_id': str(forbidden.id)})
    assert response.status_code == 404, response.text
    response = await client.post(f'{API}/merchant-links/debt-groups', headers=h, content=b'{')
    assert response.status_code == 422, response.text


async def test_falcon_all_allowed_branch_stocks_sales_and_named_chat(client, _session_factory, monkeypatch):
    import json
    from sqlalchemy import select
    from app.domain.entities.business_entities import Product
    from app.domain.entities.sale_entities import BranchStock
    from app.domain.entities.invoice_entities import Invoice, InvoiceItem
    from app.domain.services import falcon_service
    from app.core.config import settings
    monkeypatch.setattr(settings, 'OPENAI_API_KEY', '')
    async def no_ai(*args, **kwargs): return None
    monkeypatch.setattr(falcon_service, '_call_ai', no_ai)
    s = await _employee_access_scenario(_session_factory, full=True)
    async with _session_factory() as db:
        third = Branch(organization_id=s['org'].id, name='Forbidden Third')
        db.add(third); await db.flush()
        branches = [*s['branches'], third]
        member = (await db.execute(select(BranchMember).where(
            BranchMember.organization_id == s['org'].id, BranchMember.user_id == s['worker'].id))).scalar_one()
        member.branch_ids = json.dumps([str(b.id) for b in branches[:2]])
        product = Product(organization_id=s['org'].id, branch_id=branches[0].id,
            name='Shared Product', stock=999, price=10, cost_price=2, cost_currency='USD', min_stock=6)
        secret = Product(organization_id=s['org'].id, branch_id=third.id,
            name='Forbidden Product', stock=1000, price=100, cost_price=10, cost_currency='USD')
        db.add_all([product, secret]); await db.flush()
        for n, (branch, stock, amount) in enumerate(zip(branches, [5, 12, 1000], [100, 200, 900])):
            db.add(BranchStock(organization_id=s['org'].id, branch_id=branch.id,
                product_id=product.id, quantity=stock, avg_cost=2))
            invoice = Invoice(organization_id=s['org'].id, branch_id=branch.id,
                invoice_type='sale', invoice_number=f'FAL-{n}', status='confirmed', currency='USD', total=amount)
            db.add(invoice); await db.flush()
            db.add(InvoiceItem(invoice_id=invoice.id, product_id=product.id, description='Shared Product',
                quantity=n+1, base_quantity=n+1, unit_price=amount/(n+1), total=amount, cost_total=amount/2, profit=amount/2))
        await db.commit()
    selected = await client.post(f'{API}/branches/select', headers=_h(s['worker_token']), json={
        'organization_id': str(s['org'].id), 'all': True})
    assert selected.status_code == 200, selected.text
    h = _h(s['worker_token'], selected.json()['data']['token'])
    payload = {'scope': 'inventory', 'report_currency': 'USD', 'lang': 'ar'}
    result = await client.post(f'{API}/inventory/falcon/analyze', headers=h, json=payload)
    assert result.status_code == 200, result.text
    data = result.json()['data']['stats']
    assert set(data['branch_ids']) == {str(b.id) for b in branches[:2]}
    assert data['total_sales'] == 300 and data['inventory_value'] == 34 and data['products_count'] == 1
    assert {row['branch_name']: row['stock'] for row in data['branch_summaries']} == {branches[0].name: 5, branches[1].name: 12}
    assert {row['branch_name']: row['total_sales'] for row in data['branch_summaries']} == {branches[0].name: 100, branches[1].name: 200}
    assert sum(row['inventory_value'] for row in data['branch_summaries']) == data['inventory_value']
    chat = await client.post(f'{API}/inventory/falcon/chat', headers=h,
        json={**payload, 'question': 'أي فرع يحتاج توريد؟', 'history': []})
    assert chat.status_code == 200, chat.text
    assert branches[0].name in chat.text and branches[1].name in chat.text and 'Forbidden Third' not in chat.text
    result = await client.post(f'{API}/inventory/falcon/analyze', headers=h,
        json={**payload, 'scope': 'product', 'ref_id': str(secret.id)})
    assert result.status_code == 404, result.text
    selected = await client.post(f'{API}/branches/select', headers=_h(s['worker_token']), json={
        'organization_id': str(s['org'].id), 'branch_id': str(branches[1].id)})
    h = _h(s['worker_token'], selected.json()['data']['token'])
    result = await client.post(f'{API}/inventory/falcon/analyze', headers=h, json=payload)
    assert result.status_code == 200, result.text
    data = result.json()['data']['stats']
    assert data['total_sales'] == 200 and data['inventory_value'] == 24
    assert [row['branch_name'] for row in data['branch_summaries']] == [branches[1].name]
    details = await client.get(f'{API}/employees', headers=_h(s['owner_token']))
    assert details.status_code == 200
    branches_card = details.json()['data']['employees'][0]['managed_branches']
    assert {row['name'] for row in branches_card} == {branches[0].name, branches[1].name}
    assert set(details.json()['data']['employees'][0]['branch_ids']) == {str(b.id) for b in branches[:2]}
    async with _session_factory() as db:
        member = (await db.execute(select(BranchMember).where(
            BranchMember.organization_id == s['org'].id, BranchMember.user_id == s['worker'].id))).scalar_one()
        member.branch_ids = json.dumps([str(branches[1].id)])
        await db.commit()
    details = await client.get(f'{API}/employees', headers=_h(s['owner_token']))
    assert details.json()['data']['employees'] == []
    second_scope = await client.post(f'{API}/branches/select', headers=_h(s['owner_token']), json={
        'organization_id': str(s['org'].id), 'branch_id': str(branches[1].id)})
    details = await client.get(f'{API}/employees', headers=_h(s['owner_token'], second_scope.json()['data']['token']))
    entry = details.json()['data']['employees'][0]
    assert entry['branch_ids'] == [str(branches[1].id)]
    assert [row['name'] for row in entry['managed_branches']] == [branches[1].name]


async def _employee_access_scenario(factory, *, full=False, branch_count=2, own_branches=0):
    import json
    from app.api.v1.employees import default_permissions
    from app.domain.entities.hr_entities import Employee
    from app.domain.entities.employee_workspace_entities import EmployeeWorkspace, EmployeeInvitation
    tag = uuid4().hex[:8]
    async with factory() as db:
        org = Organization(name='Merchant', slug=f'policy-{tag}', subscription_plan='business',
            subscription_status='active', subscription_start_date=datetime.now(timezone.utc)-timedelta(days=1),
            subscription_end_date=datetime.now(timezone.utc)+timedelta(days=30))
        own = Organization(name='Worker own', slug=f'worker-{tag}', subscription_plan='business' if own_branches else 'personal',
            subscription_status='active', subscription_end_date=datetime.now(timezone.utc)+timedelta(days=30))
        db.add_all([org, own]); await db.flush()
        merchant = User(organization_id=org.id, full_name='Merchant', role='owner', email=f'm-{tag}@test.local')
        worker = User(organization_id=own.id, full_name='Worker', role='owner', email=f'w-{tag}@test.local')
        db.add_all([merchant, worker]); await db.flush()
        for user in [merchant, worker]:
            db.add(UserSession(user_id=user.id, refresh_token=uuid4().hex, is_active=True,
                expires_at=datetime.now(timezone.utc)+timedelta(days=1)))
        branches = [Branch(organization_id=org.id, name='Main' if n == 0 else f'Secret {n}', is_default=n == 0)
                    for n in range(branch_count)]
        db.add_all([Branch(organization_id=own.id, name=f'Own {n}', is_default=n == 0)
                    for n in range(own_branches)])
        db.add_all(branches); await db.flush()
        banks = [BankAccount(organization_id=org.id, branch_id=b.id, bank_name=b.name,
            account_number=f'{tag}-{n}', account_name=b.name, currency='USD', balance=100+n*9000)
            for n, b in enumerate(branches)]
        db.add_all(banks)
        emp = Employee(organization_id=org.id, employee_code=tag, full_name='HR worker', salary=500)
        db.add(emp); await db.flush()
        permissions = default_permissions() if full else {key: False for key in default_permissions()}
        if not full:
            permissions.update({'dashboard': True, 'transactions': True, 'income': True,
                'sales': True, 'sales.create': True, 'sales.view': False})
        db.add(EmployeeWorkspace(employee_id=emp.id, organization_id=org.id, linked_user_id=worker.id,
            permissions=json.dumps(permissions)))
        member = BranchMember(organization_id=org.id, user_id=worker.id, status='active',
            branch_ids=json.dumps([str(branches[0].id)]), all_branches=False,
            permissions=json.dumps(permissions))
        db.add(member)
        db.add(EmployeeInvitation(organization_id=org.id, employee_id=emp.id,
            invited_user_id=worker.id, invited_by=merchant.id, status='accepted', permissions=json.dumps(permissions)))
        await db.commit()
        return {'org': org, 'own': own, 'worker': worker, 'merchant': merchant, 'emp': emp,
            'branches': branches, 'banks': banks, 'permissions': permissions,
            'owner_token': create_access_token(str(merchant.id), str(org.id), 'owner'),
            'worker_token': create_access_token(str(worker.id), str(own.id), 'owner')}


async def test_debt_settlement_targets_one_invoice_and_preserves_fx(client, _session_factory, monkeypatch):
    from decimal import Decimal
    from sqlalchemy import select
    from app.domain.entities.employee_workspace_entities import EmployeeDebt
    import app.domain.services.employee_finance_service as finance
    async def no_push(*args, **kwargs): pass
    monkeypatch.setattr(finance, 'notify_user', no_push)
    s = await _employee_access_scenario(_session_factory, full=True)
    async with _session_factory() as db:
        sar = BankAccount(organization_id=s['org'].id, branch_id=s['branches'][0].id,
            bank_name='SAR bank', account_number=uuid4().hex, account_name='SAR', currency='SAR', balance=0)
        db.add(sar); await db.commit()
    h = _h(s['owner_token'])
    charge = {'direction': 'employer_owes', 'kind': 'charge', 'amount': '500.00',
        'currency': 'SAR', 'payment_currency': 'SAR', 'branch_id': str(s['branches'][0].id),
        'bank_account_id': str(sar.id)}
    first = await client.post(f'{API}/employees/{s["emp"].id}/debts', headers=h, json=charge)
    assert first.status_code == 201, first.text
    source = first.json()['data']
    second = await client.post(f'{API}/employees/{s["emp"].id}/debts', headers=h, json={**charge, 'amount': '700.00'})
    assert second.status_code == 201, second.text
    body = {'direction': 'employer_owes', 'kind': 'settlement', 'debt_id': source['id'],
        'amount': '50.00', 'currency': 'SAR', 'payment_currency': 'USD', 'exchange_rate': '3.75',
        'bank_account_id': str(s['banks'][0].id), 'branch_id': str(s['branches'][0].id),
        'idempotency_key': 'selected-debt-payment-123'}
    result = await client.post(f'{API}/employees/{s["emp"].id}/debts', headers=h, json=body)
    assert result.status_code == 201, result.text
    paid = result.json()['data']
    assert paid['original_debt_id'] == source['id'] and paid['original_debt_invoice'] == source['invoice_no']
    assert paid['currency'] == 'SAR' and paid['payment_currency'] == 'USD'
    assert Decimal(paid['converted_amount']) == Decimal('187.50')
    assert Decimal(paid['remaining_amount']) == Decimal('312.50')
    retry = await client.post(f'{API}/employees/{s["emp"].id}/debts', headers=h, json=body)
    assert retry.status_code == 201 and retry.json()['data']['id'] == paid['id']
    over = await client.post(f'{API}/employees/{s["emp"].id}/debts', headers=h,
        json={**body, 'amount': '100', 'idempotency_key': 'over-payment-attempt-123'})
    assert over.status_code == 422, over.text
    wrong = await client.post(f'{API}/employees/{s["emp"].id}/debts', headers=h,
        json={**body, 'debt_id': str(uuid4()), 'idempotency_key': 'unknown-invoice-payment-123'})
    assert wrong.status_code == 404, wrong.text
    ledger = (await client.get(f'{API}/employees/{s["emp"].id}/debts', headers=h)).json()['data']['debts']
    remaining = {r['id']: r['outstanding_amount'] for r in ledger if r['kind'] == 'charge'}
    assert Decimal(remaining[source['id']]) == Decimal('312.50')
    assert Decimal(remaining[second.json()['data']['id']]) == Decimal('700.00')
    async with _session_factory() as db:
        assert (await db.get(BankAccount, s['banks'][0].id)).balance == Decimal('50.00')
        assert len((await db.execute(select(EmployeeDebt).where(EmployeeDebt.kind == 'settlement'))).scalars().all()) == 1


async def test_payment_options_selected_branch_and_business_invitation_logo(client, _session_factory, monkeypatch):
    from sqlalchemy import select
    from app.domain.entities.notification_entities import AppNotification
    from app.api.v1 import employees as api
    s = await _employee_access_scenario(_session_factory, full=True)
    async with _session_factory() as db:
        main = await db.get(Branch, s['branches'][0].id)
        main.name = 'اسم المتجر التجاري'; main.image = '/uploads/business-logo.png'
        owner = await db.get(User, s['merchant'].id)
        owner.full_name = 'اسم شخصي لا يظهر'; owner.photo_url = '/personal-private.png'
        employee = await db.get(__import__('app.domain.entities.hr_entities', fromlist=['Employee']).Employee, s['emp'].id)
        worker = await db.get(User, s['worker'].id)
        inv = await api._create_invitation(db, s['org'].id, employee, worker, owner.id, '{}')
        await db.commit()
        calls = []
        async def push(db, **kwargs): calls.append(kwargs)
        monkeypatch.setattr(api, 'notify_user', push)
        await api._push_invitation(db, inv, base_url='https://fyona.example/')
        notice = (await db.execute(select(AppNotification).where(AppNotification.event_id == f'employee_invite:{inv.id}'))).scalar_one()
        assert notice.image_url == '/uploads/business-logo.png'
        assert 'اسم المتجر التجاري' in notice.title and 'اسم شخصي' not in notice.title
        assert calls[0]['image_url'] == 'https://fyona.example/uploads/business-logo.png'
        inv_id = str(inv.id)
    detail = await client.get(f'{API}/employees/invitations/{inv_id}', headers=_h(s['worker_token']))
    assert detail.status_code == 200, detail.text
    assert detail.json()['data']['merchant']['name'] == 'اسم المتجر التجاري'
    assert detail.json()['data']['merchant']['photo_url'] == '/uploads/business-logo.png'
    selected = await client.post(f'{API}/branches/select', headers=_h(s['owner_token']), json={
        'branch_id': str(s['branches'][0].id), 'organization_id': str(s['org'].id)})
    h = _h(s['owner_token'], selected.json()['data']['token'])
    options = await client.get(f'{API}/business/payment-options', headers=h, params={'branch_id': str(s['branches'][1].id)})
    assert options.status_code == 200, options.text
    assert str(s['banks'][1].id) in {row['id'] for row in options.json()}
    assert any(row['bank_name'] == 'كاش' for row in options.json())
    assert all(row['branch_id'] == str(s['branches'][1].id) for row in options.json())


@pytest.mark.parametrize('inactive', ['expired', 'cancelled'])
async def test_owner_subscription_controls_workspace_and_renewal_notifies_once(
        client, _session_factory, monkeypatch, inactive):
    from sqlalchemy import select
    from unittest.mock import AsyncMock
    from app.domain.entities.notification_entities import AppNotification
    from app.domain.services import merchant_subscription_service as subscriptions
    from app.domain.services.subscription_welcome import send_subscription_welcome
    from app.domain.services.section_entitlements import activate
    s = await _employee_access_scenario(_session_factory, full=True)
    async with _session_factory() as db:
        own = await db.get(Organization, s['own'].id)
        own.subscription_status = 'expired'
        own.subscription_end_date = datetime.now(timezone.utc) - timedelta(days=1)
        await db.commit()
    selection = {'organization_id': str(s['org'].id), 'branch_id': str(s['branches'][0].id)}
    r = await client.post(f'{API}/branches/select', headers=_h(s['worker_token']), json=selection)
    assert r.status_code == 200, r.text
    assert r.json()['data']['owner_expired'] is False
    h = _h(s['worker_token'], r.json()['data']['token'])
    assert (await client.get(f'{API}/business/project-settings', headers=h)).status_code == 200
    async with _session_factory() as db:
        org = await db.get(Organization, s['org'].id)
        org.subscription_status = inactive
        if inactive == 'expired':
            org.subscription_end_date = datetime.now(timezone.utc) - timedelta(days=1)
        await db.commit()
    for headers in [h, _h(s['owner_token'])]:
        r = await client.get(f'{API}/business/project-settings', headers=headers)
        assert r.status_code == 403, r.text
        assert r.json()['message']['code'] == 'merchant_subscription_expired'
    r = await client.get(f'{API}/branches/access', headers=_h(s['worker_token']))
    company = next(c for c in r.json()['data']['companies'] if c['organization_id'] == str(s['org'].id))
    assert company['owner_expired'] and company['owner_subscription_status'] == inactive
    assert company['owner_subscription_plan'] == 'business' and company['owner_subscription_end_date']
    r = await client.post(f'{API}/branches/select', headers=_h(s['worker_token']), json=selection)
    assert r.status_code == 200 and r.json()['data']['owner_expired'], r.text
    push = AsyncMock()
    monkeypatch.setattr(subscriptions, 'notify_user', push)
    monkeypatch.setattr('app.domain.services.push_service.notify_user', AsyncMock())
    async with _session_factory() as db:
        org = await db.get(Organization, s['org'].id)
        activate(org, 'business', days=30)
        await db.commit()
        for _ in range(2):
            await send_subscription_welcome(db, user_id=s['merchant'].id,
                org_id=org.id, event='manual:renewal-test')
        notices = (await db.execute(select(AppNotification).where(
            AppNotification.user_id == s['worker'].id))).scalars().all()
        assert len(notices) == 1 and notices[0].route.startswith('/job-requests?invite=')
        assert notices[0].domain == 'main' and notices[0].is_system
        assert push.await_count == 1 and push.await_args.kwargs['action_payload'] == notices[0].route
        invitation_id = notices[0].route.split('invite=')[1]
    reopened = await client.get(f'{API}/employees/invitations/{invitation_id}', headers=_h(s['worker_token']))
    assert reopened.status_code == 200 and reopened.json()['data']['employee']['id'] == str(s['emp'].id)
    for headers in [h, _h(s['owner_token'])]:
        r = await client.get(f'{API}/business/project-settings', headers=headers)
        assert r.status_code == 200, r.text


async def test_payment_options_requested_authorized_branch_only(client, _session_factory):
    s = await _employee_access_scenario(_session_factory, full=True, branch_count=3)
    for token, all_mode in [(s['owner_token'], False), (s['owner_token'], True), (s['worker_token'], False)]:
        r = await client.post(f'{API}/branches/select', headers=_h(token), json={
            'organization_id': str(s['org'].id), 'all': all_mode})
        assert r.status_code == 200, r.text
        h = _h(token, r.json()['data']['token'])
        allowed = 1 if token == s['worker_token'] else 3
        for n in range(3):
            r = await client.get(f'{API}/business/payment-options?branch_id={s["branches"][n].id}', headers=h)
            if n >= allowed:
                assert r.status_code == 403, r.text
            else:
                assert r.status_code == 200, r.text
                assert [a['id'] for a in r.json() if a['account_type'] != 'cash'] == [str(s['banks'][n].id)]
                cash = [a for a in r.json() if a['account_type'] == 'cash']
                assert len(cash) == 1
                repeated = await client.get(f'{API}/business/payment-options?branch_id={s["branches"][n].id}', headers=h)
                assert repeated.status_code == 200, repeated.text
                assert [a['id'] for a in repeated.json() if a['account_type'] == 'cash'] == [cash[0]['id']]
                assert {a['branch_id'] for a in r.json()} == {str(s['branches'][n].id)}


async def test_shared_negative_setting_changes_withdrawals_immediately(client, _session_factory):
    s = await _employee_access_scenario(_session_factory, full=True)
    r = await client.post(f'{API}/branches/select', headers=_h(s['worker_token']), json={
        'organization_id': str(s['org'].id), 'branch_id': str(s['branches'][0].id)})
    assert r.status_code == 200, r.text
    employee = _h(s['worker_token'], r.json()['data']['token'])
    owner = _h(s['owner_token'])
    path = f'{API}/banking/accounts/{s["banks"][0].id}/withdraw'
    r = await client.post(path, headers=owner, json={'amount': 101})
    assert r.status_code == 400, r.text
    r = await client.put(f'{API}/business/project-settings', headers=employee, json={'allow_negative': True})
    assert r.status_code == 200, r.text
    r = await client.get(f'{API}/business/project-settings', headers=owner)
    assert r.json()['data']['settings']['allow_negative'] is True
    r = await client.post(path, headers=owner, json={'amount': 101})
    assert r.status_code == 200, r.text
    r = await client.put(f'{API}/business/project-settings', headers=owner, json={'allow_negative': False})
    assert r.status_code == 200, r.text
    r = await client.post(path, headers=employee, json={'amount': 1})
    assert r.status_code == 400, r.text


async def test_debt_fx_partial_full_overpay_and_salary_base_currency(client, _session_factory, monkeypatch):
    from sqlalchemy import select
    from unittest.mock import AsyncMock
    from app.domain.entities.finance_entities import BankTransaction
    monkeypatch.setattr('app.domain.services.employee_finance_service.notify_user', AsyncMock())
    s = await _employee_access_scenario(_session_factory, full=True)
    async with _session_factory() as db:
        sar = BankAccount(organization_id=s['org'].id, branch_id=s['branches'][0].id,
            bank_name='SAR', account_name='SAR', account_number=uuid4().hex, currency='SAR', balance=1000)
        db.add(sar); await db.commit()
    h = _h(s['owner_token'])
    path = f'{API}/employees/{s["emp"].id}/debts'
    common = {'direction': 'employee_owes', 'currency': 'SAR', 'branch_id': str(s['branches'][0].id)}
    r = await client.post(path, headers=h, json={**common, 'amount': 500, 'bank_account_id': str(sar.id)})
    assert r.status_code == 201, r.text
    settlement = {**common, 'kind': 'settlement', 'amount': 50, 'payment_currency': 'USD',
        'fx_rate': '3.75', 'bank_account_id': str(s['banks'][0].id), 'idempotency_key': 'settlement-retry'}
    r = await client.post(path, headers=h, json=settlement)
    assert r.status_code == 201, r.text
    receipt = r.json()['data']
    assert receipt['converted_amount'] == receipt['base_amount'] == '187.50'
    assert receipt['fx_rate'] == '3.75' and receipt['original_currency'] == 'SAR'
    assert receipt['remaining_amount'] == '312.50'
    retry = await client.post(path, headers=h, json=settlement)
    assert retry.status_code == 201 and retry.json()['data']['id'] == receipt['id'], retry.text
    overpay = {**settlement, 'amount': 100, 'idempotency_key': 'overpay-rejected'}
    r = await client.post(path, headers=h, json=overpay)
    assert r.status_code == 422, r.text
    r = await client.get(path, headers=h)
    assert r.json()['data']['balances'] == {'SAR': 312.5}
    for values in [{'branch_id': str(s['branches'][1].id)}, {'payment_currency': 'SAR'}]:
        r = await client.post(path, headers=h, json={**settlement, **values, 'idempotency_key': None})
        assert r.status_code == 422, r.text
    r = await client.post(path, headers=h, json={**settlement, 'amount': 125,
        'fx_rate': '2.5', 'idempotency_key': 'full-settlement'})
    assert r.status_code == 201 and r.json()['data']['remaining_amount'] == '0.00', r.text
    r = await client.get(path, headers=h)
    assert r.json()['data']['balances'] == {'SAR': 0}
    r = await client.post(f'{API}/employees/{s["emp"].id}/salary', headers=h, json={
        'amount': 100, 'currency': 'USD', 'fx_rate': '3.75',
        'branch_id': common['branch_id'], 'bank_account_id': settlement['bank_account_id']})
    assert r.status_code == 201, r.text
    assert r.json()['data']['base_currency'] == 'SAR' and r.json()['data']['remaining_salary'] == 125
    async with _session_factory() as db:
        assert (await db.get(BankAccount, s['banks'][0].id)).balance == Decimal('175')
        assert (await db.get(BankAccount, sar.id)).balance == Decimal('500')
        txs = (await db.execute(select(BankTransaction).where(BankTransaction.organization_id == s['org'].id))).scalars().all()
        assert len(txs) == 4


async def test_expired_workspace_never_falls_back_to_own_company_settings(client, _session_factory):
    from jose import jwt
    from app.domain.services.branch_service import decode_scope_token
    from app.domain.entities.business_settings_entities import BusinessProjectSettings
    scenario = await _employee_access_scenario(_session_factory, full=True, own_branches=1)
    selected = await client.post(f'{API}/branches/select', headers=_h(scenario['worker_token']),
        json={'organization_id': str(scenario['org'].id), 'all': False,
              'branch_id': str(scenario['branches'][0].id)})
    assert selected.status_code == 200, selected.text
    payload = decode_scope_token(selected.json()['data']['token'])
    payload['exp'] = 1
    expired = jwt.encode(payload, settings.JWT_SECRET_KEY, algorithm=settings.JWT_ALGORITHM)
    response = await client.put(f'{API}/business/project-settings',
        headers=_h(scenario['worker_token'], expired), json={'enabled_currencies': ['EUR']})
    assert response.status_code == 401, response.text
    assert response.json()['message']['code'] == 'branch_scope_expired'
    async with _session_factory() as db:
        assert await db.get(BusinessProjectSettings, scenario['own'].id) is None
        assert await db.get(BusinessProjectSettings, scenario['org'].id) is None


async def test_employee_explicit_denials_payment_metadata_and_transactions(client, _session_factory):
    from sqlalchemy import select
    import json
    scenario = await _employee_access_scenario(_session_factory)
    s = scenario
    r = await client.post(f'{API}/branches/select', headers=_h(s['worker_token']), json={
        'organization_id': str(s['org'].id), 'branch_id': str(s['branches'][0].id)})
    assert r.status_code == 200, r.text
    h = _h(s['worker_token'], r.json()['data']['token'])
    for denied_path in ['/notifications', '/invoices/designs/a4']:
        denied = await client.get(f'{API}{denied_path}', headers=h)
        assert denied.status_code == 403, (denied_path, denied.text)
    for path in ['/banking/accounts', '/customers', '/products', '/employees', '/sales/invoices']:
        r = await client.get(f'{API}{path}', headers=h)
        assert r.status_code in (403, 404), (path, r.text)
    r = await client.get(f'{API}/business/payment-options', headers=h)
    assert r.status_code == 200, r.text
    assert [a['id'] for a in r.json() if a['account_type'] != 'cash'] == [str(s['banks'][0].id)]
    assert any(a['account_type'] == 'cash' for a in r.json())
    assert all('balance' not in a and a['balance_visible'] is False for a in r.json())
    r = await client.post(f'{API}/banking/accounts/{s["banks"][0].id}/deposit', headers=h, json={'amount': 11})
    assert r.status_code == 200 and 'balance' not in r.json()['data'], r.text
    r = await client.post(f'{API}/banking/accounts/{s["banks"][0].id}/withdraw', headers=h, json={'amount': 1})
    assert r.status_code == 403, r.text
    r = await client.get(f'{API}/business/transactions', headers=h)
    assert r.status_code == 200, r.text
    assert 'income' in r.text
    r = await client.put(f'{API}/business/project-settings', headers=h, json={'allow_negative': True})
    assert r.status_code == 403, r.text
    r = await client.post(f'{API}/business/project-settings/backups', headers=h)
    assert r.status_code == 403, r.text
    # Merchant updates take effect on the very next request, not a new login.
    async with _session_factory() as db:
        member = (await db.execute(select(BranchMember).where(BranchMember.user_id == s['worker'].id))).scalar_one()
        permissions = dict(s['permissions']); permissions['income'] = False
        member.permissions = json.dumps(permissions); await db.commit()
    r = await client.post(f'{API}/banking/accounts/{s["banks"][0].id}/deposit', headers=h, json={'amount': 1})
    assert r.status_code == 403, r.text


async def test_full_employee_shared_settings_backup_and_no_employee_management(client, _session_factory):
    s = await _employee_access_scenario(_session_factory, full=True)
    r = await client.post(f'{API}/branches/select', headers=_h(s['worker_token']), json={
        'organization_id': str(s['org'].id), 'branch_id': str(s['branches'][0].id)})
    assert r.status_code == 200, r.text
    h = _h(s['worker_token'], r.json()['data']['token'])
    for path in ['/employees', f'/employees/{s["emp"].id}/salary']:
        r = await client.get(f'{API}{path}', headers=h)
        assert r.status_code == 403, r.text
    settings = {'enabled_currencies': ['EUR', 'USD'], 'allow_negative': True,
        'invoice_design': {'paper': {'companyName': 'Shared merchant'}}}
    r = await client.put(f'{API}/business/project-settings', headers=h, json=settings)
    assert r.status_code == 200, r.text
    r = await client.get(f'{API}/business/project-settings', headers=_h(s['owner_token']))
    assert r.status_code == 200 and r.json()['data']['settings'] == settings
    r = await client.get(f'{API}/business/project-settings', headers=_h(s['worker_token']))
    assert r.status_code == 403  # Own Personal plan cannot read the merchant's settings.
    r = await client.post(f'{API}/business/project-settings/backups', headers=h)
    assert r.status_code == 200, r.text
    backup_id = r.json()['data']['id']
    r = await client.get(f'{API}/business/project-settings/backups/{backup_id}', headers=h)
    assert r.status_code == 200, r.text
    snapshot = r.json()['data']['snapshot']
    assert 'users' not in snapshot['tables'] and 'employees' not in snapshot['tables']
    assert {a['id'] for a in snapshot['tables']['bank_accounts']} == {str(s['banks'][0].id)}
    r = await client.post(f'{API}/business/project-settings/backups/{backup_id}/restore', headers=h)
    assert r.status_code == 200, r.text
    r = await client.get(f'{API}/business/project-settings/backups/{backup_id}', headers=_h(s['worker_token']))
    assert r.status_code == 403, r.text


@pytest.mark.parametrize('linked', [True, False])
async def test_permanent_employee_delete_removes_data_and_link(client, _session_factory, monkeypatch, linked):
    from app.domain.entities.hr_entities import Employee
    from app.domain.entities.employee_workspace_entities import EmployeeWorkspace, EmployeeSalaryPayment, EmployeeDebt
    from app.domain.entities.notification_entities import AppNotification
    from sqlalchemy import select
    import app.api.v1.employees as employee_api
    sent = []
    async def push(db, **kwargs): sent.append(kwargs)
    monkeypatch.setattr(employee_api, 'notify_user', push)
    s = await _employee_access_scenario(_session_factory, full=True)
    r = await client.post(f'{API}/branches/select', headers=_h(s['worker_token']), json={
        'organization_id': str(s['org'].id), 'branch_id': str(s['branches'][0].id)})
    token = r.json()['data']['token']
    async with _session_factory() as db:
        if not linked:
            ws = await db.get(EmployeeWorkspace, s['emp'].id); ws.linked_user_id = None
        db.add(EmployeeSalaryPayment(employee_id=s['emp'].id, organization_id=s['org'].id,
            amount=100, currency='USD', operation_no=f'SAL-{uuid4()}'))
        db.add(EmployeeDebt(employee_id=s['emp'].id, organization_id=s['org'].id,
            amount=10, currency='USD', direction='employee_owes', kind='charge'))
        await db.commit()
    r = await client.delete(f'{API}/employees/{s["emp"].id}', headers=_h(s['owner_token']))
    assert r.status_code == 204, r.text
    async with _session_factory() as db:
        assert await db.get(Employee, s['emp'].id) is None
        assert await db.get(EmployeeWorkspace, s['emp'].id) is None
        assert await db.get(User, s['worker'].id) is not None
        member = (await db.execute(select(BranchMember).where(
            BranchMember.user_id == s['worker'].id))).scalar_one()
        assert member.status == 'revoked' and member.scope_valid_after is not None
        assert (await db.execute(select(EmployeeSalaryPayment).where(EmployeeSalaryPayment.employee_id == s['emp'].id))).scalars().all() == []
        assert (await db.execute(select(EmployeeDebt).where(EmployeeDebt.employee_id == s['emp'].id))).scalars().all() == []
        if linked:
            notification = (await db.execute(select(AppNotification).where(AppNotification.user_id == s['worker'].id))).scalars().first()
            assert notification and notification.is_system and 'حذف' in notification.title
    assert len(sent) == 1
    r = await client.get(f'{API}/banking/accounts', headers=_h(s['worker_token'], token))
    assert r.status_code == 403, r.text
    r = await client.get(f'{API}/employees/invitations/me', headers=_h(s['worker_token']))
    assert r.json()['data']['invitations'] == []
API = settings.API_PREFIX


async def test_child_balance_denial_wins_and_invoice_settings_remain_shared(client, _session_factory):
    import json
    from sqlalchemy import select
    s = await _employee_access_scenario(_session_factory, full=True)
    async with _session_factory() as db:
        member = (await db.execute(select(BranchMember).where(
            BranchMember.user_id == s['worker'].id))).scalar_one()
        permissions = dict(s['permissions'], **{'banks.balances': False})
        member.permissions = json.dumps(permissions)
        await db.commit()
    r = await client.post(f'{API}/branches/select', headers=_h(s['worker_token']), json={
        'organization_id': str(s['org'].id), 'branch_id': str(s['branches'][0].id)})
    h = _h(s['worker_token'], r.json()['data']['token'])
    for path in ['/banking/accounts', '/business/payment-options']:
        r = await client.get(f'{API}{path}', headers=h)
        assert r.status_code == 200, r.text
        assert '"balance":' not in r.text and '"opening_balance":' not in r.text
        assert '9100' not in r.text
    for method, path, payload in [('post', '/business/project-settings/backups', None),
            ('put', '/business/project-settings', {'allow_negative': True})]:
        r = await getattr(client, method)(f'{API}{path}', headers=h, json=payload)
        assert r.status_code == 403, r.text
    patch = {'invoice_design': {'paper': {'companyName': 'Shared design'}}}
    r = await client.put(f'{API}/business/project-settings', headers=h, json=patch)
    assert r.status_code == 200, r.text
    r = await client.get(f'{API}/business/project-settings', headers=_h(s['owner_token']))
    assert r.json()['data']['settings'] == patch
    r = await client.get(f'{API}/business/project-settings', headers=h)
    assert r.status_code == 200 and r.json()['data']['settings'] == patch


async def test_backup_checksum_and_branch_binding(client, _session_factory):
    from app.domain.entities.business_settings_entities import BusinessProjectBackup
    s = await _employee_access_scenario(_session_factory, full=True)
    headers = []
    for branch in s['branches']:
        r = await client.post(f'{API}/branches/select', headers=_h(s['owner_token']),
            json={'branch_id': str(branch.id)})
        headers.append(_h(s['owner_token'], r.json()['data']['token']))
    r = await client.post(f'{API}/business/project-settings/backups', headers=headers[0])
    assert r.status_code == 200, r.text
    backup_id = r.json()['data']['id']
    for suffix in ['', '/restore']:
        r = await (client.post if suffix else client.get)(
            f'{API}/business/project-settings/backups/{backup_id}{suffix}', headers=headers[1])
        assert r.status_code == 404, r.text
    async with _session_factory() as db:
        from uuid import UUID
        row = await db.get(BusinessProjectBackup, UUID(backup_id))
        row.payload += ' '
        await db.commit()
    r = await client.post(f'{API}/business/project-settings/backups/{backup_id}/restore', headers=headers[0])
    assert r.status_code == 400, r.text


async def test_unlink_relink_never_revalidates_old_scope(client, _session_factory, monkeypatch):
    import json
    from sqlalchemy import select
    import app.api.v1.employees as employee_api
    async def push(*args, **kwargs): pass
    monkeypatch.setattr(employee_api, 'notify_user', push)
    s = await _employee_access_scenario(_session_factory, full=True)
    r = await client.post(f'{API}/branches/select', headers=_h(s['worker_token']), json={
        'organization_id': str(s['org'].id), 'branch_id': str(s['branches'][0].id)})
    old_token = r.json()['data']['token']
    r = await client.post(f'{API}/employees/{s["emp"].id}/unlink', headers=_h(s['worker_token']))
    assert r.status_code == 200, r.text
    # Simulate an accepted new link while retaining the revocation tombstone.
    async with _session_factory() as db:
        member = (await db.execute(select(BranchMember).where(
            BranchMember.user_id == s['worker'].id))).scalar_one()
        member.status = 'active'
        member.branch_ids = json.dumps([str(s['branches'][0].id)])
        member.permissions = json.dumps(s['permissions'])
        await db.commit()
    r = await client.get(f'{API}/banking/accounts', headers=_h(s['worker_token'], old_token))
    assert r.status_code == 403, r.text
    r = await client.post(f'{API}/branches/select', headers=_h(s['worker_token'], old_token), json={
        'organization_id': str(s['org'].id), 'branch_id': str(s['branches'][0].id)})
    assert r.status_code == 200, r.text
    r = await client.get(f'{API}/banking/accounts', headers=_h(s['worker_token'], r.json()['data']['token']))
    assert r.status_code == 200, r.text


@pytest.mark.parametrize('conflict', ['new_movement', 'moved_branch'])
async def test_backup_restore_rejects_unsafe_merge(client, _session_factory, conflict):
    s = await _employee_access_scenario(_session_factory, full=True)
    r = await client.post(f'{API}/branches/select', headers=_h(s['owner_token']),
        json={'branch_id': str(s['branches'][0].id)})
    h = _h(s['owner_token'], r.json()['data']['token'])
    r = await client.post(f'{API}/business/project-settings/backups', headers=h)
    assert r.status_code == 200, r.text
    backup_id = r.json()['data']['id']
    if conflict == 'new_movement':
        r = await client.post(f'{API}/banking/accounts/{s["banks"][0].id}/deposit',
            headers=h, json={'amount': 11})
        assert r.status_code == 200, r.text
    else:
        async with _session_factory() as db:
            account = await db.get(BankAccount, s['banks'][0].id)
            account.branch_id = s['branches'][1].id
            await db.commit()
    r = await client.post(f'{API}/business/project-settings/backups/{backup_id}/restore', headers=h)
    assert r.status_code == (409 if conflict == 'new_movement' else 403), r.text
    async with _session_factory() as db:
        account = await db.get(BankAccount, s['banks'][0].id)
        assert account.balance == (111 if conflict == 'new_movement' else 100)
        assert account.branch_id == s['branches'][0 if conflict == 'new_movement' else 1].id


async def test_limited_employee_invoice_and_income_paths_use_operational_permissions(client, _session_factory):
    import json
    from sqlalchemy import select
    from app.domain.entities.invoice_entities import Invoice
    from uuid import UUID
    s = await _employee_access_scenario(_session_factory)
    async with _session_factory() as db:
        member = (await db.execute(select(BranchMember).where(
            BranchMember.user_id == s['worker'].id))).scalar_one()
        member.permissions = json.dumps(dict(s['permissions'], transactions=False))
        await db.commit()
    r = await client.post(f'{API}/branches/select', headers=_h(s['worker_token']), json={
        'organization_id': str(s['org'].id), 'branch_id': str(s['branches'][0].id)})
    h = _h(s['worker_token'], r.json()['data']['token'])
    r = await client.get(f'{API}/business/transactions?kind=inout', headers=h)
    assert r.status_code == 200, r.text
    r = await client.get(f'{API}/business/transactions', headers=h)
    assert r.status_code == 403, r.text
    data = {'invoice_type': 'sale', 'items': [{'description': 'Service', 'unit_price': 5}]}
    r = await client.post(f'{API}/invoices', headers=h, json=data)
    assert r.status_code == 201, r.text
    invoice_id = UUID(r.json()['data']['id'])
    async with _session_factory() as db:
        invoice = await db.get(Invoice, invoice_id)
        assert invoice.organization_id == s['org'].id
        assert invoice.branch_id == s['branches'][0].id
    r = await client.post(f'{API}/invoices', headers=h, json={**data, 'invoice_type': 'purchase'})
    assert r.status_code == 403, r.text
    r = await client.get(f'{API}/invoices', headers=h)
    assert r.status_code == 403, r.text  # sales.view explicitly false


@pytest.mark.parametrize('all_mode', [False, True])
@pytest.mark.parametrize('denied', ['reports.view', 'reports.export', 'banks.balances'])
async def test_employee_reports_and_exports_respect_child_denials(client, _session_factory, all_mode, denied):
    import json
    from sqlalchemy import select
    s = await _employee_access_scenario(_session_factory, full=True, branch_count=3)
    async with _session_factory() as db:
        member = (await db.execute(select(BranchMember).where(BranchMember.user_id == s['worker'].id))).scalar_one()
        member.all_branches = True
        member.permissions = json.dumps(dict(s['permissions'], **{denied: False}))
        await db.commit()
    r = await client.post(f'{API}/branches/select', headers=_h(s['worker_token']), json={
        'organization_id': str(s['org'].id),
        **({'all': True} if all_mode else {'branch_id': str(s['branches'][0].id)})})
    assert r.status_code == 200, r.text
    h = _h(s['worker_token'], r.json()['data']['token'])
    # A view grant alone must never grant a statement/export action.
    r = await client.get(f'{API}/banking/accounts/{s["banks"][0].id}/statement', headers=h)
    assert r.status_code == 403, r.text
    for path in ['/business-reports/money', '/business-reports/home', '/business-reports/overview']:
        r = await client.get(f'{API}{path}?currency=USD', headers=h)
        assert r.status_code == (200 if denied == 'reports.export' else 403), (path, r.text)
        if r.status_code == 403:
            assert '9100' not in r.text and '18100' not in r.text
    if all_mode:
        r = await client.post(f'{API}/banking/accounts/{s["banks"][0].id}/deposit', headers=h, json={'amount': 1})
        assert r.status_code == 409, r.text  # all branches is strictly read-only


@pytest.mark.parametrize('branch_count,own_count,full', [(1, 0, False), (1, 2, True), (3, 0, True), (3, 2, False)])
async def test_employee_workspace_matrix_preserves_own_and_shared_settings(client, _session_factory, branch_count, own_count, full):
    s = await _employee_access_scenario(_session_factory, full=full, branch_count=branch_count, own_branches=own_count)
    r = await client.post(f'{API}/branches/select', headers=_h(s['worker_token']), json={
        'organization_id': str(s['org'].id), 'branch_id': str(s['branches'][0].id)})
    assert r.status_code == 200, r.text
    h = _h(s['worker_token'], r.json()['data']['token'])
    for path in ['/business/transactions', '/business/payment-options', '/business/project-settings']:
        r = await client.get(f'{API}{path}', headers=h)
        assert r.status_code == 200, (path, r.text)
    patch = {'enabled_currencies': ['EUR', 'USD'], 'allow_negative': True}
    r = await client.put(f'{API}/business/project-settings', headers=_h(s['owner_token']), json=patch)
    assert r.status_code == 200, r.text
    r = await client.get(f'{API}/business/project-settings', headers=h)
    assert r.json()['data']['settings'] == patch
    r = await client.put(f'{API}/business/project-settings', headers=h, json={'allow_negative': False})
    assert r.status_code == (200 if full else 403), r.text
    if own_count:
        r = await client.get(f'{API}/business/project-settings', headers=_h(s['worker_token']))
        assert r.status_code == 200 and r.json()['data']['settings'] == {}, r.text
        r = await client.put(f'{API}/business/project-settings', headers=_h(s['worker_token']), json={'enabled_currencies': ['JPY']})
        assert r.status_code == 200, r.text
        r = await client.get(f'{API}/business/project-settings', headers=h)
        assert r.json()['data']['settings']['enabled_currencies'] == ['EUR', 'USD']
    r = await client.get(f'{API}/employees', headers=h)
    assert r.status_code == 403, r.text


async def test_employee_debt_actions_and_branch_transfer_options_are_scoped(client, _session_factory):
    import json
    from sqlalchemy import select
    s = await _employee_access_scenario(_session_factory, full=True, branch_count=3)
    r = await client.post(f'{API}/branches/select', headers=_h(s['worker_token']), json={
        'organization_id': str(s['org'].id), 'branch_id': str(s['branches'][0].id)})
    h = _h(s['worker_token'], r.json()['data']['token'])
    r = await client.post(f'{API}/customers', headers=h, json={'name': 'Allowed customer'})
    assert r.status_code == 201, r.text
    customer_id = r.json()['data']['id']
    r = await client.get(f'{API}/merchant-links/overview', headers=h,
        params={'party_kind': 'customer', 'party_id': customer_id})
    assert r.status_code == 200, r.text
    async with _session_factory() as db:
        member = (await db.execute(select(BranchMember).where(BranchMember.user_id == s['worker'].id))).scalar_one()
        member.permissions = json.dumps(dict(s['permissions'], **{'debts.add': False, 'banks.balances': False}))
        await db.commit()
    r = await client.post(f'{API}/merchant-links/party/opening-debt', headers=h,
        json={'party_kind': 'customer', 'party_id': customer_id, 'amount': 50, 'currency': 'USD'})
    assert r.status_code == 403, r.text
    r = await client.get(f'{API}/branches/transfers/options', headers=h, params={'branch_id': str(s['branches'][0].id)})
    assert r.status_code == 200 and '"balance":' not in r.text, r.text
    r = await client.get(f'{API}/branches/transfers/options', headers=h, params={'branch_id': str(s['branches'][1].id)})
    assert r.status_code == 403, r.text


async def test_delete_never_linked_employee_is_permanent_without_touching_auth(client, _session_factory):
    from uuid import UUID
    from app.domain.entities.hr_entities import Employee
    from app.domain.entities.employee_workspace_entities import EmployeeWorkspace
    s = await _employee_access_scenario(_session_factory)
    r = await client.post(f'{API}/employees', headers=_h(s['owner_token']),
        json={'full_name': 'Never linked', 'salary': 300, 'salary_currency': 'USD'})
    assert r.status_code == 201, r.text
    employee_id = UUID(r.json()['data']['employee']['id'])
    r = await client.delete(f'{API}/employees/{employee_id}', headers=_h(s['owner_token']))
    assert r.status_code == 204, r.text
    async with _session_factory() as db:
        assert await db.get(Employee, employee_id) is None
        assert await db.get(EmployeeWorkspace, employee_id) is None
        assert await db.get(User, s['worker'].id) is not None


@pytest.fixture()
def _sync_engine(tmp_path):
    eng = create_engine(f"sqlite:///{tmp_path}/branchapi.db",
                        connect_args={"check_same_thread": False})
    Base.metadata.create_all(eng)
    return eng


@pytest.fixture()
def _async_engine(_sync_engine):
    from sqlalchemy import event
    engine = create_async_engine(f"sqlite+aiosqlite:///{_sync_engine.url.database}")
    # Reports use PostgreSQL day bucketing. Keep this SQLite integration harness
    # faithful without altering production SQL or skipping report execution.
    @event.listens_for(engine.sync_engine, 'connect')
    def report_functions(connection, _):
        connection.create_function('date_trunc', 2,
            lambda unit, value: str(value)[:10] + ' 00:00:00' if value is not None else None)
    return engine


@pytest.fixture()
def _session_factory(_async_engine):
    return async_sessionmaker(_async_engine, expire_on_commit=False)


@pytest.fixture()
async def client(_session_factory):
    async with _session_factory() as req:
        async def _override():
            try:
                yield req
                await req.commit()
            except Exception:
                await req.rollback()
                raise
        app.dependency_overrides[get_db] = _override
        address = uuid4().bytes
        async with AsyncClient(transport=ASGITransport(app=app,
                               client=(f'127.{address[0]}.{address[1]}.{address[2]}', 12345)),
                               base_url="http://localhost") as ac:
            yield ac
        app.dependency_overrides.clear()


def _h(token, branch=None):
    h = {"Authorization": f"Bearer {token}"}
    if branch:
        h["X-Branch-Token"] = branch
    return h


@pytest.mark.parametrize('kind', ['branch', 'customer', 'supplier'])
@pytest.mark.parametrize('accept', [True, False])
async def test_stage1_invitation_response_once(client, _session_factory, monkeypatch, kind, accept):
    from unittest.mock import AsyncMock
    from sqlalchemy import select
    from app.domain.entities.branch_entities import BranchInvitation
    from app.domain.entities.business_entities import Customer, Supplier
    from app.domain.entities.merchant_entities import MerchantLink
    from app.domain.entities.notification_entities import AppNotification
    from app.domain.services import push_service
    push = AsyncMock(return_value={'sent': 1, 'failed': 0})
    monkeypatch.setattr(push_service, 'push_to_users_now', push)
    s = await _employee_access_scenario(_session_factory, full=True)
    async with _session_factory() as db:
        if kind == 'branch':
            invitation = BranchInvitation(organization_id=s['org'].id,
                branch_id=s['branches'][0].id, invited_user_id=s['worker'].id,
                invited_by=s['merchant'].id, status='pending',
                expires_at=datetime.now(timezone.utc) + timedelta(days=1))
        else:
            party = (Customer if kind == 'customer' else Supplier)(
                organization_id=s['org'].id, name='الطرف')
            db.add(party); await db.flush()
            invitation = MerchantLink(merchant_org_id=s['org'].id, party_kind=kind,
                party_id=party.id, external_user_id=s['worker'].id,
                invited_by=s['merchant'].id, status='pending')
        db.add(invitation); await db.commit()
        iid = invitation.id
    path = (f'{API}/branches/invitations/{iid}/respond' if kind == 'branch' else
            f"{API}/me/merchant-invites/{iid}/{'accept' if accept else 'reject'}")
    # Another authenticated user cannot respond or trigger either channel.
    bad = await client.post(path, headers=_h(s['owner_token']), json={'accept': accept})
    assert bad.status_code in (400, 404), bad.text
    assert push.await_count == 0
    response = await client.post(path, headers=_h(s['worker_token']), json={'accept': accept})
    assert response.status_code == 200, response.text
    await client.post(path, headers=_h(s['worker_token']), json={'accept': accept})
    assert push.await_count == 1
    assert push.await_args.args[1] == [s['merchant'].id]
    async with _session_factory() as db:
        notices = (await db.execute(select(AppNotification).where(
            AppNotification.event_id.contains(str(iid))))).scalars().all()
        assert len(notices) == 1
        notice = notices[0]
        assert notice.user_id == s['merchant'].id and notice.organization_id == s['org'].id
        assert notice.is_system and notice.domain == 'main'
        assert notice.message == push.await_args.kwargs['body']
        assert notice.route == push.await_args.kwargs['action_payload']


async def test_stage1_expired_branch_no_notification(client, _session_factory, monkeypatch):
    from unittest.mock import AsyncMock
    from sqlalchemy import select
    from app.domain.entities.branch_entities import BranchInvitation
    from app.domain.entities.notification_entities import AppNotification
    from app.domain.services import push_service
    push = AsyncMock(); monkeypatch.setattr(push_service, 'notify_user', push)
    s = await _employee_access_scenario(_session_factory, full=True)
    async with _session_factory() as db:
        inv = BranchInvitation(organization_id=s['org'].id,
            branch_id=s['branches'][0].id, invited_user_id=s['worker'].id,
            invited_by=s['merchant'].id, status='pending',
            expires_at=datetime.now(timezone.utc) - timedelta(days=1))
        db.add(inv); await db.commit(); iid = inv.id
    r = await client.post(f'{API}/branches/invitations/{iid}/respond',
        headers=_h(s['worker_token']), json={'accept': True})
    assert r.status_code == 400
    assert push.await_count == 0
    async with _session_factory() as db:
        assert not (await db.execute(select(AppNotification).where(
            AppNotification.event_id.like(f'%:{iid}')))).scalars().all()


async def test_stage1_payment_cash_empty_and_branch_scoped(client, _session_factory):
    from sqlalchemy import delete
    s = await _employee_access_scenario(_session_factory, full=True)
    async with _session_factory() as db:
        await db.execute(delete(BankAccount).where(BankAccount.organization_id == s['org'].id))
        await db.commit()
    for branch in s['branches']:
        selection = await client.post(f'{API}/branches/select', headers=_h(s['owner_token']),
            json={'branch_id': str(branch.id), 'organization_id': str(s['org'].id)})
        h = _h(s['owner_token'], selection.json()['data']['token'])
        for _ in range(2):
            r = await client.get(f'{API}/business/payment-options', headers=h)
            assert r.status_code == 200, r.text
            assert len(r.json()) == 1 and r.json()[0]['bank_name'] == 'كاش'
            assert r.json()[0]['branch_id'] == str(branch.id)
        async with _session_factory() as db:
            bank = BankAccount(organization_id=s['org'].id, branch_id=branch.id,
                bank_name='New bank', account_name='Current', account_number='NEW', currency='SAR')
            db.add(bank); await db.commit()
        r = await client.get(f'{API}/business/payment-options', headers=h)
        assert len(r.json()) == 2
        assert len({a['id'] for a in r.json()}) == 2
        assert all(a['branch_id'] == str(branch.id) for a in r.json())


async def test_employee_workspace_identity_presence_and_company_all_isolation(client, _session_factory):
    import json
    from sqlalchemy import select
    from app.domain.entities.employee_workspace_entities import EmployeeWorkspace
    from app.domain.entities.hr_entities import Employee

    tag = uuid4().hex[:8]
    async with _session_factory() as db:
        orgs = [Organization(name=f'S4 Store {n}', slug=f's4-{tag}-{n}',
            subscription_plan='business', subscription_status='active',
            subscription_start_date=datetime.now(timezone.utc) - timedelta(days=1),
            subscription_end_date=datetime.now(timezone.utc) + timedelta(days=30)) for n in range(3)]
        db.add_all(orgs); await db.flush()
        staff = User(organization_id=orgs[2].id, full_name='Account Name', role='employee',
            email=f's4-{tag}@test.local')
        db.add(staff); await db.flush()
        db.add(UserSession(user_id=staff.id, refresh_token=uuid4().hex, is_active=True,
            expires_at=datetime.now(timezone.utc) + timedelta(days=1)))
        branches = [[Branch(organization_id=o.id, name=f'Store {n} Branch {b}',
            is_default=b == 0) for b in range(2)] for n, o in enumerate(orgs)]
        db.add_all([b for rows in branches for b in rows]); await db.flush()
        employees = [Employee(organization_id=o.id, employee_code=f's4-{tag}-{n}',
            full_name=f'HR Name {n}', salary=500) for n, o in enumerate(orgs[:2])]
        db.add_all(employees); await db.flush()
        for n, employee in enumerate(employees):
            db.add(EmployeeWorkspace(employee_id=employee.id, organization_id=orgs[n].id,
                linked_user_id=staff.id, permissions='{}'))
            db.add(BranchMember(organization_id=orgs[n].id, user_id=staff.id, status='active',
                all_branches=n == 0, branch_ids=json.dumps([str(branches[n][0].id)]),
                permissions='{"products": {"read": true}}'))
        await db.commit()
        staff_id = staff.id
        org_ids = [str(o.id) for o in orgs]
        employee_ids = [e.id for e in employees]
        branch_ids = [[str(b.id) for b in rows] for rows in branches]
        token = create_access_token(str(staff.id), org_ids[2], 'employee')

    scopes = []
    for n in range(2):
        r = await client.get(f'{API}/employees/me/profile', headers=_h(token),
            params={'organization_id': org_ids[n]})
        assert r.status_code == 200, r.text
        assert r.json()['data']['employee']['id'] == str(employee_ids[n])
        assert r.json()['data']['employee']['full_name'] == f'HR Name {n}'
        assert r.json()['data']['organization']['id'] == org_ids[n]
        r = await client.post(f'{API}/branches/select', headers=_h(token), json={
            'organization_id': org_ids[n], 'branch_id': branch_ids[n][0]})
        assert r.status_code == 200, r.text
        scopes.append(r.json()['data']['token'])

    r = await client.get(f'{API}/employees/me/profile', headers=_h(token),
        params={'organization_id': org_ids[2]})
    assert r.status_code == 404, r.text
    for n in range(2):
        async with _session_factory() as db:
            before = [(await db.get(EmployeeWorkspace, eid)).last_seen_at for eid in employee_ids]
        r = await client.post(f'{API}/employees/me/heartbeat', headers=_h(token, scopes[n]))
        assert r.status_code == 200 and r.json()['data']['online'] is True, r.text
        async with _session_factory() as db:
            after = [(await db.get(EmployeeWorkspace, eid)).last_seen_at for eid in employee_ids]
        assert after[n] is not None and after[n] != before[n]
        assert after[1 - n] is None  # Presence is exclusive to the active merchant.

    r = await client.post(f'{API}/branches/select', headers=_h(token), json={
        'organization_id': org_ids[0], 'all': True})
    assert r.status_code == 200, r.text
    all_scope = r.json()['data']['token']
    r = await client.get(f'{API}/branches', headers=_h(token, all_scope))
    assert r.status_code == 200, r.text
    assert {b['id'] for b in r.json()['data']} == set(branch_ids[0])
    r = await client.post(f'{API}/branches/select', headers=_h(token), json={
        'organization_id': org_ids[1], 'all': True})
    assert r.status_code == 403, r.text
    r = await client.get(f'{API}/branches/access', headers=_h(token, scopes[1]))
    assert r.status_code == 200, r.text
    company = next(c for c in r.json()['data']['companies'] if c['organization_id'] == org_ids[1])
    assert {b['id'] for b in company['branches']} == {branch_ids[1][0]}
    async with _session_factory() as db:
        member = (await db.execute(select(BranchMember).where(
            BranchMember.organization_id == orgs[0].id, BranchMember.user_id == staff_id))).scalar_one()
        member.status = 'revoked'
        await db.commit()
    r = await client.get(f'{API}/employees/me/profile', headers=_h(token),
        params={'organization_id': org_ids[0]})
    assert r.status_code == 404, r.text
    r = await client.post(f'{API}/employees/me/heartbeat', headers=_h(token, all_scope))
    assert r.status_code == 403, r.text
    r = await client.get(f'{API}/employees/me/profile', headers=_h(token),
        params={'organization_id': org_ids[1]})
    assert r.status_code == 200 and r.json()['data']['employee']['id'] == str(employee_ids[1])


async def test_employment_section_three_identity_privacy_finance_and_routes(
        client, _session_factory, monkeypatch):
    from sqlalchemy import select, func
    from app.domain.entities.employee_workspace_entities import EmployeeWorkspace, EmployeeInvitation
    from app.domain.entities.hr_entities import Employee
    from app.domain.entities.notification_entities import AppNotification
    import app.api.v1.employees as employee_api
    pushes = []

    async def push_spy(db, **kwargs):
        pushes.append(kwargs)
    monkeypatch.setattr(employee_api, 'notify_user', push_spy)
    tag = uuid4().hex[:8]
    async with _session_factory() as db:
        orgs = [Organization(name=f'Store {n}', slug=f'section3-{tag}-{n}',
            avatar=f'/store-{n}.png', subscription_plan='business', subscription_status='active',
            subscription_start_date=datetime.now(timezone.utc) - timedelta(days=1),
            subscription_end_date=datetime.now(timezone.utc) + timedelta(days=30)) for n in range(3)]
        db.add_all(orgs); await db.flush()
        owners = [User(organization_id=o.id, full_name=f'Merchant {n}', role='owner',
            email=f's3-{tag}-{n}@test.local', phone=f'055000000{n}', photo_url=f'/merchant-{n}.png')
            for n, o in enumerate(orgs)]
        staff = User(organization_id=orgs[2].id, full_name='Account Name', role='employee',
            email=f's3-staff-{tag}@test.local')
        db.add_all([*owners, staff]); await db.flush()
        for user in [*owners, staff]:
            db.add(UserSession(user_id=user.id, refresh_token=uuid4().hex, is_active=True,
                expires_at=datetime.now(timezone.utc) + timedelta(days=1)))
        employees = [Employee(organization_id=o.id, employee_code=f's3-{tag}-{n}',
            full_name=f'HR Name {n}', salary=500, notes='Private HR notes')
            for n, o in enumerate(orgs[:2])]
        db.add_all(employees); await db.flush()
        for n, employee in enumerate(employees):
            db.add(EmployeeWorkspace(employee_id=employee.id, organization_id=orgs[n].id,
                salary_currency='SAR', permissions='{}'))
            db.add(Branch(organization_id=orgs[n].id, name=f'Branch {n}', is_default=True))
        await db.commit()
        staff_id, outsider_id = staff.id, owners[2].id
        org_ids, emp_ids = [o.id for o in orgs], [e.id for e in employees]
        owner_ids = [o.id for o in owners]
        # Repeated delivery updates the same main/system event, not a new domain.
        invites = []
        for n in range(2):
            inv = await employee_api._create_invitation(db, orgs[n].id, employees[n], staff,
                owners[n].id, '{}')
            await employee_api._create_invitation(db, orgs[n].id, employees[n], staff,
                owners[n].id, '{}')
            invites.append(inv.id)
            await employee_api._push_invitation(db, inv)
        await db.commit()
        assert await db.scalar(select(func.count()).select_from(AppNotification).where(
            AppNotification.user_id == staff_id)) == 2
        event = await db.scalar(select(AppNotification).where(
            AppNotification.event_id == f'employee_invite:{invites[0]}'))
        assert event.domain == 'main' and event.is_system
        assert event.route == event.action_payload == f'/job-requests?invite={invites[0]}'
        assert pushes[0]['action_payload'] == event.route

    def token(uid, oid, role='owner'):
        return create_access_token(str(uid), str(oid), role)
    sh = _h(token(staff_id, org_ids[2], 'employee'))
    oh = _h(token(outsider_id, org_ids[2]))
    # Self-scoped system notifications require no notification RBAC rows.
    unread = await client.get(f'{API}/notifications/unread-count', headers=sh)
    assert unread.status_code == 200, unread.text
    assert unread.json()['data']['count'] >= 1
    notifications = await client.get(f'{API}/notifications', headers=sh)
    assert notifications.status_code == 200, notifications.text
    assert any(n['id'] == str(event.id)
               and n['domain'] == 'main' and n['is_system'] is True
               and n['route'] == f'/job-requests?invite={invites[0]}'
               for n in notifications.json()['data']['items'])
    marked = await client.post(f'{API}/notifications/read-all', headers=sh)
    assert marked.status_code == 200, marked.text
    unread = await client.get(f'{API}/notifications/unread-count', headers=sh)
    assert unread.status_code == 200, unread.text
    assert unread.json()['data']['count'] == 0
    path = f'{API}/employees/invitations/{invites[0]}'
    assert (await client.get(path, headers=oh)).status_code == 404
    detail = (await client.get(path, headers=sh)).json()['data']
    assert detail['merchant']['name'] == 'Branch 0'
    assert detail['merchant']['phone'] == '0550000000'
    assert detail['organization']['photo_url'] == '/store-0.png'
    assert 'notes' not in detail['employee']  # Pending never exposes private HR.
    for n in range(2):
        accepted = await client.post(f'{API}/employees/invitations/{invites[n]}/respond',
            headers=sh, json={'accept': True})
        assert accepted.status_code == 200, accepted.text
        assert accepted.json()['data']['merchant']['name'] == f'Branch {n}'
        assert pushes[-1]['action_payload'] == f'/employees/detail?id={emp_ids[n]}'
        mh = _h(token(owner_ids[n], org_ids[n]))
        async with _session_factory() as db:
            branch = await db.scalar(select(Branch).where(Branch.organization_id == org_ids[n], Branch.is_default.is_(True)))
            account = BankAccount(organization_id=org_ids[n], branch_id=branch.id,
                bank_name='Salary Bank', account_name='Salary', account_number=uuid4().hex,
                currency='SAR', balance=1000)
            db.add(account); await db.commit()
            payment_scope = {'branch_id': str(branch.id), 'bank_account_id': str(account.id)}
        payment = await client.post(f'{API}/employees/{emp_ids[n]}/salary', headers=mh,
            json={'amount': 100 + n, 'currency': 'SAR', 'notes': f'Salary {n}', **payment_scope})
        assert payment.status_code == 201, payment.text
        debt = await client.post(f'{API}/employees/{emp_ids[n]}/debts', headers=mh,
            json={'amount': 20 + n, 'currency': 'SAR', 'direction': 'employer_owes',
                  'notes': f'Debt {n}', **payment_scope})
        assert debt.status_code == 201, debt.text

    assert (await client.get(f'{API}/employees/me/finance', headers=sh)).status_code == 409
    async with _session_factory() as db:
        org = await db.get(Organization, org_ids[0]); org.name = 'Renamed Store'
        emp = await db.get(Employee, emp_ids[0]); emp.full_name = 'Renamed HR'
        await db.commit()
    for n in range(2):
        finance = await client.get(f'{API}/employees/me/finance?employee_id={emp_ids[n]}', headers=sh)
        assert finance.status_code == 200, finance.text
        data = finance.json()['data']
        assert data['employee_id'] == str(emp_ids[n])
        assert len(data['salary']) == len(data['debts']) == 1
        assert data['salary'][0]['amount'] == 100 + n
        assert data['debts'][0]['amount'] == 20 + n
        for receipt in [data['salary'][0], data['debts'][0]]:
            assert receipt['organization_name'] == f'Store {n}'
            assert receipt['employee_name'] == f'HR Name {n}'
        assert (await client.get(f'{API}/employees/me/finance?employee_id={emp_ids[n]}', headers=oh)).status_code == 404
    merchant_ledger = await client.get(f'{API}/employees/{emp_ids[0]}/salary',
        headers=_h(token(owner_ids[0], org_ids[0])))
    assert merchant_ledger.json()['data']['payments'][0]['organization_name'] == 'Store 0'
    async with _session_factory() as db:
        member = await db.scalar(select(BranchMember).where(
            BranchMember.organization_id == org_ids[0], BranchMember.user_id == staff_id))
        member.status = 'revoked'
        await db.commit()
    assert (await client.get(path, headers=sh)).status_code == 404
    remaining = (await client.get(f'{API}/employees/invitations/me', headers=sh)).json()['data']['invitations']
    assert [x['id'] for x in remaining] == [str(invites[1])]
    assert (await client.get(f'{API}/employees/me/finance?employee_id={emp_ids[0]}', headers=sh)).status_code == 404
    async with _session_factory() as db:
        invitation = await db.get(EmployeeInvitation, invites[1])
        invitation.invited_by = None
        organization = await db.get(Organization, org_ids[1])
        organization.avatar = None
        branch = await db.scalar(select(Branch).where(Branch.organization_id == org_ids[1]))
        branch.image = '/default-store.png'
        await db.commit()
    fallback = (await client.get(f'{API}/employees/invitations/{invites[1]}', headers=sh)).json()['data']
    assert fallback['merchant']['name'] == 'Branch 1'
    assert fallback['organization']['photo_url'] == '/default-store.png'


@pytest.mark.parametrize('initiator', ['merchant', 'employee'])
@pytest.mark.parametrize('scope_kind', ['full_cross_company', 'limited_cross_company', 'same_company'])
async def test_employee_unlink_revokes_old_scopes_and_notifies_other_party(
        client, _session_factory, monkeypatch, initiator, scope_kind):
    from sqlalchemy import select, func
    from app.domain.entities.employee_workspace_entities import (
        EmployeeWorkspace, EmployeeInvitation, EmployeeSalaryPayment, EmployeeDebt)
    from app.domain.entities.hr_entities import Employee
    from app.domain.entities.notification_entities import AppNotification
    from app.domain.entities.branch_entities import BranchInvitation
    import app.api.v1.employees as employee_api
    tag = uuid4().hex[:8]
    pushes = []

    async def push_spy(db, **kwargs):
        pushes.append(kwargs)
    monkeypatch.setattr(employee_api, 'notify_user', push_spy)
    async with _session_factory() as db:
        def company(name):
            return Organization(name=name, slug=f'{name}-{tag}', subscription_plan='business',
                subscription_status='active',
                subscription_start_date=datetime.now(timezone.utc) - timedelta(days=1),
                subscription_end_date=datetime.now(timezone.utc) + timedelta(days=30))
        merchant_org, own_org, other_org = company('merchant'), company('own'), company('other')
        db.add_all([merchant_org, own_org, other_org]); await db.flush()
        owner = User(organization_id=merchant_org.id, full_name='Merchant', role='owner', email=f'unlink-owner-{tag}@test.local')
        staff = User(organization_id=(merchant_org.id if scope_kind == 'same_company' else own_org.id),
            full_name='Staff account', role='employee' if scope_kind == 'same_company' else 'owner', email=f'unlink-staff-{tag}@test.local')
        outsider = User(organization_id=other_org.id, full_name='Other merchant', role='owner', email=f'unlink-other-{tag}@test.local')
        db.add_all([owner, staff, outsider]); await db.flush()
        for user in [owner, staff, outsider]:
            db.add(UserSession(user_id=user.id, refresh_token=uuid4().hex, is_active=True,
                expires_at=datetime.now(timezone.utc) + timedelta(days=1)))
        main = Branch(organization_id=merchant_org.id, name='Main', is_default=True)
        second = Branch(organization_id=merchant_org.id, name='Second')
        own = Branch(organization_id=own_org.id, name='Own', is_default=True)
        other = Branch(organization_id=other_org.id, name='Other', is_default=True)
        db.add_all([main, second, own, other]); await db.flush()
        employee = Employee(organization_id=merchant_org.id, employee_code=tag, full_name='Staff HR', salary=500)
        db.add(employee); await db.flush()
        db.add(EmployeeWorkspace(employee_id=employee.id, organization_id=merchant_org.id,
            linked_user_id=staff.id, permissions='{"banks": true, "sales": false}',
            last_seen_at=datetime.now(timezone.utc), active_organization_id=merchant_org.id))
        db.add(BranchMember(organization_id=merchant_org.id, user_id=staff.id, status='active',
            all_branches=scope_kind == 'full_cross_company',
            branch_ids=__import__('json').dumps([str(main.id)]),
            permissions='{"banks": true}', can_transfer=True))
        db.add(BranchMember(organization_id=other_org.id, user_id=staff.id, status='active',
            all_branches=True, branch_ids='[]', permissions='{"banks": true}'))
        accepted = EmployeeInvitation(organization_id=merchant_org.id, employee_id=employee.id,
            invited_user_id=staff.id, invited_by=owner.id, status='accepted', permissions='{}')
        pending = EmployeeInvitation(organization_id=merchant_org.id, employee_id=employee.id,
            invited_user_id=staff.id, invited_by=owner.id, status='pending', permissions='{}')
        branch_invite = BranchInvitation(organization_id=merchant_org.id, branch_id=main.id,
            invited_user_id=staff.id, invited_by=owner.id, status='pending')
        bank = BankAccount(organization_id=merchant_org.id, branch_id=main.id,
            bank_name='Test Bank', account_name='Main', account_number=tag, currency='SAR', balance=1000)
        db.add_all([accepted, pending, branch_invite, bank])
        db.add(EmployeeSalaryPayment(organization_id=merchant_org.id, employee_id=employee.id,
            operation_no=f'SAL-{tag}', amount=100, currency='SAR'))
        db.add(EmployeeDebt(organization_id=merchant_org.id, employee_id=employee.id,
            direction='employee_owes', kind='charge', amount=20, currency='SAR'))
        await db.commit()
        owner_token = create_access_token(str(owner.id), str(merchant_org.id), 'owner')
        staff_token = create_access_token(str(staff.id), str(staff.organization_id), staff.role)
        outsider_token = create_access_token(str(outsider.id), str(other_org.id), 'owner')

    r = await client.post(f'{API}/branches/select', headers=_h(staff_token), json={
        'organization_id': str(merchant_org.id), 'branch_id': str(main.id)})
    assert r.status_code == 200, r.text
    old_scope = r.json()['data']['token']
    old_all_scope = None
    if scope_kind == 'full_cross_company':
        r = await client.post(f'{API}/branches/select', headers=_h(staff_token), json={
            'organization_id': str(merchant_org.id), 'all': True})
        assert r.status_code == 200, r.text
        old_all_scope = r.json()['data']['token']
    r = await client.get(f'{API}/banking/accounts', headers=_h(staff_token, old_scope))
    assert r.status_code == 200, r.text
    r = await client.post(f'{API}/employees/{employee.id}/unlink', headers=_h(outsider_token))
    assert r.status_code == 404, r.text
    r = await client.post(f'{API}/employees/{employee.id}/unlink',
        headers=_h(owner_token) if initiator == 'merchant' else _h(staff_token, old_scope))
    assert r.status_code == 200, r.text
    assert r.json()['data']['already_unlinked'] is False
    recipient = staff if initiator == 'merchant' else owner
    assert len(pushes) == 1 and pushes[0]['user_id'] == recipient.id

    for scope in [old_scope] + ([old_all_scope] if old_all_scope else []):
        r = await client.get(f'{API}/banking/accounts', headers=_h(staff_token, scope))
        assert r.status_code == 403, r.text
        assert 'employee_workspace_revoked' in r.text
        r = await client.post(f'{API}/employees/me/heartbeat', headers=_h(staff_token, scope))
        assert r.status_code == 403, r.text
    r = await client.post(f'{API}/banking/accounts/{bank.id}/withdraw',
        headers=_h(staff_token, old_scope), json={'amount': 50})
    assert r.status_code == 403, r.text
    r = await client.post(f'{API}/branches/select', headers=_h(staff_token), json={
        'organization_id': str(merchant_org.id), 'branch_id': str(main.id)})
    assert r.status_code == 403, r.text
    r = await client.get(f'{API}/banking/accounts', headers=_h(staff_token))
    assert r.status_code == (403 if scope_kind == 'same_company' else 200), r.text
    r = await client.get(f'{API}/branches/access', headers=_h(staff_token))
    assert r.status_code == 200, r.text
    accessible = {x['organization_id'] for x in r.json()['data']['companies']}
    assert str(merchant_org.id) not in accessible and str(other_org.id) in accessible
    r = await client.post(f'{API}/branches/select', headers=_h(staff_token), json={
        'organization_id': str(other_org.id), 'branch_id': str(other.id)})
    assert r.status_code == 200, r.text
    r = await client.get(f'{API}/banking/accounts', headers=_h(staff_token, r.json()['data']['token']))
    assert r.status_code == 200, r.text
    recipient_token = staff_token if initiator == 'merchant' else owner_token
    r = await client.get(f'{API}/notifications', headers=_h(recipient_token))
    assert r.status_code == 200, r.text
    assert any(n['title'] == pushes[0]['title'] and n['is_system'] is True
               for n in r.json()['data']['items'])
    r = await client.get(f'{API}/banking/accounts', headers=_h(owner_token))
    assert r.status_code == 200, r.text
    r = await client.get(f'{API}/employees/invitations/me', headers=_h(staff_token))
    assert r.status_code == 200 and r.json()['data']['invitations'] == []
    r = await client.post(f'{API}/employees/invitations/{accepted.id}/respond',
        headers=_h(staff_token), json={'accept': True})
    assert r.status_code == 404, r.text
    r = await client.post(f'{API}/employees/{employee.id}/unlink', headers=_h(owner_token))
    assert r.status_code == 200 and r.json()['data']['already_unlinked'] is True
    assert len(pushes) == 1
    async with _session_factory() as db:
        member = (await db.execute(select(BranchMember).where(
            BranchMember.organization_id == merchant_org.id, BranchMember.user_id == staff.id))).scalar_one()
        assert member.status == 'revoked' and member.permissions == '{}'
        assert member.branch_ids == '[]' and not member.all_branches and not member.can_transfer
        workspace = await db.get(EmployeeWorkspace, employee.id)
        assert workspace.linked_user_id is None and workspace.last_seen_at is None
        assert (await db.get(Employee, employee.id)).is_deleted is False
        assert (await db.get(BankAccount, bank.id)).balance == 1000
        assert await db.scalar(select(func.count()).select_from(EmployeeSalaryPayment)) == 1
        assert await db.scalar(select(func.count()).select_from(EmployeeDebt)) == 1
        assert (await db.get(BranchInvitation, branch_invite.id)).status == 'revoked'
        notification = (await db.execute(select(AppNotification).where(
            AppNotification.event_id.like('employee_unlink:%')))).scalar_one()
        assert notification.user_id == recipient.id
        assert notification.is_system and notification.domain == 'main'
        assert notification.organization_id == recipient.organization_id
        assert await db.scalar(select(func.count()).select_from(UserSession).where(
            UserSession.user_id == staff.id, UserSession.is_active.is_(True))) == 1


async def test_received_stock_is_visible_in_list_detail_and_stock_filters(
        client, _session_factory):
    """Regression: transfers wrote BranchStock=5 but /products serialized the
    cloned Product.stock=0 for every non-main receiver warehouse."""
    from app.domain.entities.business_entities import Product
    from app.domain.services import branch_stock_service as stock
    tag = uuid4().hex[:8]
    async with _session_factory() as db:
        org = Organization(
            name=f"Inventory {tag}", slug=f"stock-{tag}",
            subscription_plan="business", subscription_status="active",
            subscription_start_date=datetime.now(timezone.utc) - timedelta(days=1),
            subscription_end_date=datetime.now(timezone.utc) + timedelta(days=30))
        db.add(org)
        await db.flush()
        owner = User(organization_id=org.id, full_name="Owner", role="owner",
                     email=f"stock-{tag}@test.local")
        db.add(owner)
        await db.flush()
        db.add(UserSession(user_id=owner.id, refresh_token=f"stock-{tag}",
                           is_active=True, expires_at=datetime.now(timezone.utc) + timedelta(days=1)))
        sender = Branch(organization_id=org.id, name="Sender", is_default=True)
        receiver = Branch(organization_id=org.id, name="Receiver")
        db.add_all([sender, receiver])
        await db.flush()
        products = [Product(organization_id=org.id, branch_id=sender.id,
                            name=name, unit="قطعة", price=7, cost_price=3,
                            cost_currency="SAR", stock=20, min_stock=8)
                    for name in ("تونه", "زيت")]
        db.add_all(products)
        await db.flush()
        for product in products:
            await stock.adjust_stock(db, org.id, sender.id, product.id,
                                     Decimal("20"), Decimal("3"))
        await db.commit()
        oid, uid, sid, rid = org.id, owner.id, sender.id, receiver.id
        pids = [p.id for p in products]
    auth = create_access_token(str(uid), str(oid), "owner")
    async def scoped(branch_id):
        response = await client.post(f"{API}/branches/select", headers=_h(auth),
                                     json={"branch_id": str(branch_id)})
        assert response.status_code == 200, response.text
        return _h(auth, response.json()["data"]["token"])
    sender_headers, receiver_headers = await scoped(sid), await scoped(rid)
    response = await client.post(f"{API}/branches/transfers/inventory",
        headers=sender_headers, json={"from_branch_id": str(sid),
        "to_branch_id": str(rid), "idempotency_key": f"stock-{tag}",
        "items": [{"from_product_id": str(pid), "quantity": 5} for pid in pids]})
    assert response.status_code in (200, 201), response.text
    transfer = response.json()["data"]
    target_ids = {line["to_product_id"] for line in transfer["items"]}
    response = await client.get(f"{API}/products", headers=receiver_headers)
    assert response.status_code == 200, response.text
    received = response.json()["data"]["items"]
    assert {p["id"] for p in received} == target_ids
    assert {Decimal(str(p["stock"])) for p in received} == {Decimal("5")}
    for pid in target_ids:
        response = await client.get(f"{API}/products/{pid}", headers=receiver_headers)
        assert response.status_code == 200, response.text
        assert Decimal(str(response.json()["data"]["stock"])) == Decimal("5")
    response = await client.get(f"{API}/products?stock_status=out", headers=receiver_headers)
    assert response.json()["data"]["items"] == []
    response = await client.get(f"{API}/products?stock_status=low", headers=receiver_headers)
    assert {p["id"] for p in response.json()["data"]["items"]} == target_ids
    response = await client.get(f"{API}/products", headers=sender_headers)
    assert {Decimal(str(p["stock"])) for p in response.json()["data"]["items"]} == {Decimal("15")}
    # Cancel uses the ledger too; refresh must display zero afterwards.
    response = await client.post(f"{API}/branches/transfers/{transfer['id']}/reverse",
                                  headers=sender_headers, json={})
    assert response.status_code == 200, response.text
    response = await client.get(f"{API}/products?stock_status=out", headers=receiver_headers)
    assert {p["id"] for p in response.json()["data"]["items"]} == target_ids
    assert {Decimal(str(p["stock"])) for p in response.json()["data"]["items"]} == {Decimal("0")}


async def test_branch_access_all_mode_and_transfer(client, _session_factory):
    tag = str(uuid4().int % 1000000).zfill(6)
    async with _session_factory() as db:
        owner_org = Organization(
            name=f"Owner {tag}", slug=f"o-{tag}",
            subscription_plan="business", subscription_status="active",
            subscription_start_date=datetime.now(timezone.utc) - timedelta(days=1),
            subscription_end_date=datetime.now(timezone.utc) + timedelta(days=30))
        guest_org = Organization(name=f"Guest {tag}", slug=f"g-{tag}",
                                 subscription_plan="personal")
        db.add_all([owner_org, guest_org])
        await db.flush()
        owner = User(organization_id=owner_org.id, full_name="Owner",
                     email=f"o{tag}@t.local", phone=f"+96770{tag}", role="owner")
        guest = User(organization_id=guest_org.id, full_name="Guest",
                     email=f"g{tag}@t.local", phone=f"+96771{tag}",
                     role="personal", public_code=f"8{tag[:5]}")
        db.add_all([owner, guest])
        await db.flush()
        for u in (owner, guest):
            db.add(UserSession(user_id=u.id, refresh_token=f"r-{u.id}",
                               is_active=True,
                               expires_at=datetime.now(timezone.utc) + timedelta(days=1)))
        b1 = Branch(organization_id=owner_org.id, name="Main", is_default=True)
        b2 = Branch(organization_id=owner_org.id, name="Second")
        db.add_all([b1, b2])
        await db.flush()
        a1 = BankAccount(organization_id=owner_org.id, branch_id=b1.id,
                         bank_name="Bank A", account_name="A", account_number="1",
                         balance=Decimal("1000"), currency="USD")
        a2 = BankAccount(organization_id=owner_org.id, branch_id=b2.id,
                         bank_name="Bank B", account_name="B", account_number="2",
                         balance=Decimal("0"), currency="SAR")
        db.add_all([a1, a2])
        await db.commit()
        oid, gid = owner_org.id, guest_org.id
        b1id, b2id, a1id, a2id = b1.id, b2.id, a1.id, a2.id
        owner_id, guest_id = owner.id, guest.id
    owner_tok = create_access_token(str(owner_id), str(oid), "owner")
    guest_tok = create_access_token(str(guest_id), str(gid), "personal")

    # invitation
    r = await client.post(f"{API}/branches/invitations",
                          headers=_h(owner_tok),
                          json={"branch_id": str(b2id), "phone": f"+96771{tag}",
                                "can_transfer": True})
    assert r.status_code in (200, 201), r.text
    invite_id = r.json()["data"]["id"]
    # system notification reaches the guest under their OWN org
    r = await client.get(f"{API}/notifications", headers=_h(guest_tok))
    assert r.status_code == 200, r.text
    titles = [i["title"] for i in r.json()["data"]["items"]]
    assert "دعوة فرع جديد" in titles
    # accept
    r = await client.post(f"{API}/branches/invitations/{invite_id}/respond",
                          headers=_h(guest_tok), json={"accept": True})
    assert r.status_code == 200, r.text
    # access summary includes the invited company
    r = await client.get(f"{API}/branches/access", headers=_h(guest_tok))
    assert r.status_code == 200, r.text
    companies = r.json()["data"]["companies"]
    assert any(c["organization_id"] == str(oid) for c in companies)
    # select the invited branch -> signed token targeting the other company
    r = await client.post(f"{API}/branches/select", headers=_h(guest_tok),
                          json={"organization_id": str(oid),
                                "branch_id": str(b2id)})
    assert r.status_code == 200, r.text
    guest_branch_tok = r.json()["data"]["token"]
    # member read allowed; write denied by membership permissions
    r = await client.get(f"{API}/customers",
                         headers=_h(guest_tok, guest_branch_tok))
    assert r.status_code == 200, r.text
    r = await client.post(f"{API}/customers",
                          headers=_h(guest_tok, guest_branch_tok),
                          json={"name": "Nope"})
    assert r.status_code == 403, r.text
    # All scopes remain read-only even with an explicit permitted branch.
    r = await client.post(f"{API}/branches/select", headers=_h(owner_tok),
                          json={"all": True})
    assert r.status_code == 200, r.text
    all_tok = r.json()["data"]["token"]
    r = await client.get(f"{API}/customers",
                         headers=_h(owner_tok, all_tok))
    assert r.status_code == 200, r.text
    r = await client.post(f"{API}/customers",
                          headers=_h(owner_tok, all_tok),
                          json={"name": "Blocked"})
    assert r.status_code == 409, r.text
    r = await client.post(f'{API}/customers', headers=_h(owner_tok, all_tok),
        json={'name': 'Explicit branch customer', 'branch_id': str(b2id)})
    assert r.status_code == 409, r.text
    # financial transfer via HTTP
    r = await client.post(f"{API}/branches/transfers/financial",
                          headers=_h(owner_tok),
                          json={"from_branch_id": str(b1id),
                                "to_branch_id": str(b2id),
                                "from_account_id": str(a1id),
                                "to_account_id": str(a2id),
                                "amount": 10, "exchange_rate": 250})
    assert r.status_code in (200, 201), r.text
    body = r.json()["data"]
    assert body["received_amount"] == 2500.0
    # insufficient sender balance must be a clear 400, never a 500
    r = await client.post(f"{API}/branches/transfers/financial",
                          headers=_h(owner_tok),
                          json={"from_branch_id": str(b1id),
                                "to_branch_id": str(b2id),
                                "from_account_id": str(a1id),
                                "to_account_id": str(a2id),
                                "amount": 999999, "exchange_rate": 250})
    assert r.status_code == 400, r.text
    assert "رصيد" in r.text, r.text

    # reverse
    r = await client.post(
        f"{API}/branches/transfers/{body['id']}/reverse",
        headers=_h(owner_tok), json={})
    assert r.status_code == 200, r.text
    # branch-scoped invoice design: extra branch inherits main until edited
    r = await client.post(f"{API}/branches/select", headers=_h(owner_tok),
                          json={"branch_id": str(b1id)})
    main_branch_tok = r.json()["data"]["token"]
    r = await client.post(f"{API}/branches/select", headers=_h(owner_tok),
                          json={"branch_id": str(b2id)})
    second_branch_tok = r.json()["data"]["token"]
    r = await client.put(f"{API}/invoices/designs/paper",
                         headers=_h(owner_tok, main_branch_tok),
                         json={"payload": {"companyName": "Main Design"}})
    assert r.status_code == 200, r.text
    r = await client.get(f"{API}/invoices/designs/paper",
                         headers=_h(owner_tok, second_branch_tok))
    assert r.json()["data"]["payload"]["companyName"] == "Main Design", r.text
    r = await client.put(f"{API}/invoices/designs/paper",
                         headers=_h(owner_tok, second_branch_tok),
                         json={"payload": {"companyName": "Second Design"}})
    assert r.status_code == 200, r.text
    r = await client.get(f"{API}/invoices/designs/paper",
                         headers=_h(owner_tok, second_branch_tok))
    assert r.json()["data"]["payload"]["companyName"] == "Second Design"
    r = await client.get(f"{API}/invoices/designs/paper",
                         headers=_h(owner_tok, main_branch_tok))
    assert r.json()["data"]["payload"]["companyName"] == "Main Design"

    # reversal legs must be a positive IN operation (not a bank withdrawal)
    r = await client.get(f"{API}/business/transactions?per_page=100",
                         headers=_h(owner_tok))
    assert r.status_code == 200, r.text
    rows = r.json()["data"]["items"]
    reversals = [x for x in rows if x.get("kind") == "transfer_reversal"]
    assert reversals, rows
    assert any(x.get("direction") == "in"
               and float(x.get("amount") or 0) > 0 for x in reversals), reversals
    assert all(x.get("kind") != "bank_withdrawal" for x in reversals), reversals

    # revoked membership -> token access denied immediately
    async with _session_factory() as db:
        from app.domain.entities.branch_entities import BranchMember
        from sqlalchemy import select
        m = (await db.execute(select(BranchMember).where(
            BranchMember.user_id == guest_id))).scalar_one()
        mid = m.id
    r = await client.patch(f"{API}/branches/members/{mid}",
                           headers=_h(owner_tok), json={"status": "revoked"})
    assert r.status_code == 200, r.text
    r = await client.get(f"{API}/customers",
                         headers=_h(guest_tok, guest_branch_tok))
    assert r.status_code == 403, r.text
    # branch-scoped durable currency customization (survives reinstall)
    r = await client.put(f"{API}/branches/currencies",
                         headers=_h(owner_tok, second_branch_tok),
                         json={"currencies": ["SAR", "USD", "YER_NEW"]})
    assert r.status_code == 200, r.text
    r = await client.get(f"{API}/branches/currencies",
                         headers=_h(owner_tok, second_branch_tok))
    assert r.status_code == 200, r.text
    assert r.json()["data"]["currencies"] == ["SAR", "USD", "YER_NEW"]

    # branch image upload (real PNG through PIL + storage)
    import base64 as _b64
    png = _b64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGP8z8DAwMDAxMDAwMDAAAANHQEDasKb6QAAAABJRU5ErkJggg==")
    r = await client.post(
        f"{API}/branches/{b2id}/image",
        headers=_h(owner_tok),
        files={"file": ("branch.png", png, "image/png")})
    assert r.status_code == 200, r.text
    assert r.json()["data"]["image"].startswith("uploads/")
    r = await client.get(f"{API}/branches/manage", headers=_h(owner_tok))
    b2row = next(b for b in r.json()["data"]["branches"]
                 if b["id"] == str(b2id))
    assert b2row["image"].startswith("uploads/")

    # the SAME barcode may exist in different branches, but not twice in one
    bc = f"BC-{uuid4().hex[:8]}"
    bc_ids = {}
    for tok in (main_branch_tok, second_branch_tok):
        r = await client.post(f"{API}/products",
                              headers=_h(owner_tok, tok),
                              json={"name": f"Barcode {bc}", "unit": "قطعة",
                                    "price": 10, "barcode": bc})
        assert r.status_code in (200, 201), r.text
        bc_ids[tok] = r.json()["data"]["id"]
    r = await client.get(f"{API}/products/resolve-barcode",
                         headers=_h(owner_tok, second_branch_tok),
                         params={"code": bc})
    assert r.status_code == 200, r.text
    assert r.json()["data"]["product"]["id"] == bc_ids[second_branch_tok]
    r = await client.post(f"{API}/products",
                          headers=_h(owner_tok, main_branch_tok),
                          json={"name": f"Barcode dup {bc}", "unit": "قطعة",
                                "price": 11, "barcode": bc})
    assert r.status_code == 409, r.text
    detail = r.json()["message"]
    assert detail["code"] == "product_code_conflict"
    assert detail["field"] == "barcode"
    assert detail["product_name"].startswith("Barcode ")

    # reset then permanently delete the extra branch (HTTP + FK cascade)
    r = await client.post(f"{API}/branches/{b2id}/reset",
                          headers=_h(owner_tok))
    assert r.status_code == 200, r.text
    r = await client.delete(f"{API}/branches/{b2id}",
                            headers=_h(owner_tok))
    assert r.status_code == 200, r.text
    r = await client.get(f"{API}/branches/manage",
                         headers=_h(owner_tok))
    ids = [b["id"] for b in r.json()["data"]["branches"]]
    assert str(b2id) not in ids
    # factory reset of the whole Business account
    r = await client.post(f"{API}/branches/reset-all",
                          headers=_h(owner_tok))
    assert r.status_code == 200, r.text
    r = await client.get(f"{API}/branches/manage", headers=_h(owner_tok))
    branches = r.json()["data"]["branches"]
    assert len(branches) == 1 and branches[0]["is_default"] is True


@pytest.mark.parametrize('scope_kind', ['legacy', 'single', 'multiple'])
async def test_employee_workspace_link_permissions_salary_and_debt(
        client, _session_factory, scope_kind):
    tag = uuid4().hex[:8]
    async with _session_factory() as db:
        org = Organization(name=f"Staff {tag}", slug=f"staff-{tag}",
            subscription_plan="business", subscription_status="active",
            subscription_start_date=datetime.now(timezone.utc) - timedelta(days=1),
            subscription_end_date=datetime.now(timezone.utc) + timedelta(days=30))
        db.add(org)
        await db.flush()
        owner = User(organization_id=org.id, full_name="Owner", role="owner",
            email=f"owner-{tag}@test.local")
        employee_user = User(organization_id=org.id, full_name="Employee User",
            role="employee", email=f"emp-{tag}@test.local",
            phone="0501234567",
            public_code=f"{int(tag[:5], 16) % 900000 + 100000}")
        db.add_all([owner, employee_user])
        await db.flush()
        db.add_all([
            UserSession(user_id=owner.id, refresh_token=f"o-{tag}",
                is_active=True, expires_at=datetime.now(timezone.utc) + timedelta(days=1)),
            UserSession(user_id=employee_user.id, refresh_token=f"e-{tag}",
                is_active=True, expires_at=datetime.now(timezone.utc) + timedelta(days=1)),
        ])
        main = Branch(organization_id=org.id, name="Main", is_default=True)
        second = Branch(organization_id=org.id, name="Second")
        third = Branch(organization_id=org.id, name="Third")
        db.add_all([main, second, third])
        await db.flush()
        salary_bank = BankAccount(organization_id=org.id, branch_id=main.id,
            bank_name='Salary Bank', account_name='Salary', account_number=uuid4().hex,
            currency='SAR', balance=1000)
        db.add(salary_bank); await db.flush()
        owner_tok = create_access_token(str(owner.id), str(org.id), "owner")
        await db.commit()
        emp_tok = create_access_token(str(employee_user.id), str(org.id), "employee")
        emp_code = employee_user.public_code
        chosen = None if scope_kind == 'legacy' else [str(main.id)]
        if scope_kind == 'multiple':
            chosen.append(str(second.id))
        expected_branches = chosen if chosen is not None else [str(main.id)]

    r = await client.post(f"{API}/employees", headers=_h(owner_tok), json={
        "full_name": "Ali Staff", "employee_code": "E-1", "salary": 500,
        "salary_currency": "SAR", "link_code": emp_code, "phone": "0501234567",
        "permissions": {"banks": True, "sales": scope_kind == 'multiple', "reports": True},
        **({'branch_ids': chosen} if chosen is not None else {}),
    })
    assert r.status_code == 201, r.text
    employee_id = r.json()["data"]["employee"]["id"]
    r = await client.get(f"{API}/employees/lookup", headers=_h(owner_tok),
        params={"code": "0501234567"})
    assert r.status_code == 200, r.text
    assert r.json()["data"]["user"]["name"] == "Employee User"
    assert r.json()["data"]["user"]["public_code"] is None
    assert r.json()["data"]["user"]["phone"] == '0501234567'
    r = await client.get(f"{API}/employees/lookup", headers=_h(owner_tok),
        params={"code": emp_code})
    assert r.status_code == 200
    assert r.json()['data']['user']['phone'] is None
    assert r.json()['data']['user']['public_code'] == emp_code
    r = await client.get(f"{API}/employees/invitations/me", headers=_h(emp_tok))
    assert r.status_code == 200, r.text
    invitation = r.json()["data"]["invitations"][0]
    assert invitation["salary"] == 500
    assert set(invitation['branch_ids']) == set(expected_branches)
    async with _session_factory() as db:
        pending_member = (await db.execute(__import__('sqlalchemy').select(BranchMember).where(
            BranchMember.organization_id == org.id,
            BranchMember.user_id == employee_user.id))).scalar_one_or_none()
        assert pending_member is None
    r = await client.post(f"{API}/employees/invitations/{invitation['id']}/respond",
        headers=_h(emp_tok), json={"accept": True})
    assert r.status_code == 200, r.text
    async with _session_factory() as db:
        member = (await db.execute(__import__('sqlalchemy').select(BranchMember).where(
            BranchMember.organization_id == org.id,
            BranchMember.user_id == employee_user.id))).scalar_one()
        assert member.status == "active"
        assert member.all_branches is False  # Omitted scope defaults to the current branch.
        assert set(__import__('json').loads(member.branch_ids)) == set(expected_branches)
        perms = __import__('json').loads(member.permissions)
        assert perms["banks"] is True and perms["sales"] is (scope_kind == 'multiple')
    if chosen is not None:
        for bid in chosen:
            r = await client.post(f'{API}/branches/select', headers=_h(emp_tok),
                json={'branch_id': bid, 'organization_id': str(org.id)})
            assert r.status_code == 200, r.text
        r = await client.post(f'{API}/branches/select', headers=_h(emp_tok),
            json={'branch_id': str(third.id), 'organization_id': str(org.id)})
        assert r.status_code == 403, r.text
        r = await client.post(f'{API}/employees/{employee_id}/invite', headers=_h(owner_tok),
            json={'code': emp_code, 'branch_ids': [str(uuid4())]})
        assert r.status_code == 400, r.text
        r = await client.post(f'{API}/employees/{employee_id}/invite', headers=_h(owner_tok),
            json={'code': emp_code, 'branch_ids': []})
        assert r.status_code == 400, r.text
    r = await client.post(f"{API}/employees/{employee_id}/salary", headers=_h(owner_tok),
        json={"amount": 500, "currency": "SAR", "notes": "October",
              'branch_id': str(main.id), 'bank_account_id': str(salary_bank.id)})
    assert r.status_code == 201, r.text
    paid = r.json()["data"]
    assert paid["base_salary"] == 500 and paid["remaining_salary"] == 0
    assert paid["invoice_no"].startswith("SAL-")
    r = await client.post(f"{API}/employees/{employee_id}/debts", headers=_h(owner_tok),
        json={"direction": "employer_owes", "kind": "charge", "amount": 50, "currency": "SAR",
              'branch_id': str(main.id), 'bank_account_id': str(salary_bank.id)})
    assert r.status_code == 201, r.text
    assert r.json()["data"]["invoice_no"].startswith("DBT-")
    r = await client.post(f"{API}/employees/me/heartbeat", headers=_h(emp_tok))
    assert r.status_code == 200 and r.json()['data']['online'] is False, r.text
    r = await client.post(f'{API}/branches/select', headers=_h(emp_tok),
        json={'organization_id': str(org.id), 'branch_id': str(main.id)})
    assert r.status_code == 200, r.text
    r = await client.post(f'{API}/employees/me/heartbeat', headers=_h(emp_tok, r.json()['data']['token']))
    assert r.status_code == 200 and r.json()['data']['online'] is True, r.text
    r = await client.get(f"{API}/employees", headers=_h(owner_tok))
    assert r.status_code == 200 and r.json()["data"]["employees"][0]["online"] is True
    r = await client.get(f"{API}/employees/me/finance", headers=_h(emp_tok))
    assert r.status_code == 200
    data = r.json()["data"]
    assert len(data["salary"]) == 1 and data["salary"][0]["amount"] == 500
    assert data["balances"]["SAR"] == -50
    r = await client.get(f"{API}/employees", headers=_h(emp_tok))
    assert r.status_code == 403
    if chosen is not None:
        r = await client.put(f'{API}/employees/{employee_id}', headers=_h(owner_tok),
            json={'branch_ids': [str(second.id)], 'permissions': {'banks': False}})
        assert r.status_code == 200, r.text
        async with _session_factory() as db:
            member = (await db.execute(__import__('sqlalchemy').select(BranchMember).where(
                BranchMember.organization_id == org.id,
                BranchMember.user_id == employee_user.id))).scalar_one()
            assert __import__('json').loads(member.branch_ids) == [str(second.id)]
            assert __import__('json').loads(member.permissions)['banks'] is False
        r = await client.post(f'{API}/branches/select', headers=_h(emp_tok),
            json={'branch_id': str(main.id), 'organization_id': str(org.id)})
        assert r.status_code == 403, r.text
