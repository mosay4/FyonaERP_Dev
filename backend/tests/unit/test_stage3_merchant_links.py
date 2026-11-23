import json
from unittest.mock import AsyncMock
from uuid import uuid4

import pytest
from sqlalchemy import select

from tests.unit.test_notifications_visibility import pg_url, db  # noqa: F401
from app.api.v1 import merchant_links as api
from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.business_entities import Customer, Supplier
from app.domain.entities.notification_entities import AppNotification
from app.domain.entities.push_entities import DeviceToken
from app.domain.services import merchant_link_service as svc, push_service


async def seed(db, kind='customer'):
    merchant = Organization(id=uuid4(), name='Merchant', slug=uuid4().hex)
    personal = Organization(id=uuid4(), name='Personal', slug=uuid4().hex)
    db.add_all([merchant, personal])
    await db.flush()
    owner = User(id=uuid4(), organization_id=merchant.id, role='owner',
                 email=f'{uuid4()}@test.invalid', full_name='Owner')
    target = User(id=uuid4(), organization_id=personal.id, role='owner',
                  email=f'{uuid4()}@test.invalid', full_name='Invitee',
                  phone='+9665' + str(uuid4().int)[-8:],
                  public_code=str(uuid4().int)[-6:])
    party = (Customer if kind == 'customer' else Supplier)(
        id=uuid4(), organization_id=merchant.id, name='Party')
    db.add_all([owner, target, party])
    await db.flush()
    return merchant, owner, target, party


@pytest.mark.asyncio
async def test_indexed_phone_normalization_and_identifier_privacy(db, monkeypatch):
    merchant, owner, target, _ = await seed(db)
    national = target.phone[4:]
    arabic = str.maketrans('0123456789', '٠١٢٣٤٥٦٧٨٩')
    for value in [target.phone, '00' + target.phone[1:],
                  '0' + national, ('0' + national).translate(arabic)]:
        assert (await svc.lookup_user(db, value, None)).id == target.id
    assert (await svc.lookup_user(db, None, target.public_code.translate(arabic))).id == target.id
    permissions = AsyncMock(return_value=True)
    monkeypatch.setattr(api.SQLAlchemyRoleRepository, 'user_has_permission', permissions)
    for via, value in [('phone', '0' + national), ('code', target.public_code)]:
        result = await api.lookup(api.LookupRequest(**{via: value}), str(merchant.id), owner.id, db)
        body = json.loads(result.body)['data']
        assert body['matched_by'] == via and body[via] == value
        assert body['contact'] == {'via': via, 'value': value}
        assert ('code' if via == 'phone' else 'phone') not in body
    with pytest.raises(ValueError):
        await svc.lookup_user(db, target.phone, target.public_code)
    assert await svc.lookup_user(db, '***1234', None) is None


@pytest.mark.asyncio
async def test_ambiguous_phone_never_guesses_or_crosses_country(db):
    _, _, target, _ = await seed(db)
    other = User(id=uuid4(), organization_id=target.organization_id, role='owner',
                 email=f'{uuid4()}@test.invalid', full_name='Other', phone=target.phone)
    db.add(other)
    await db.flush()
    with pytest.raises(ValueError, match='أكثر من حساب'):
        await svc.lookup_user(db, target.phone, None)
    other.phone = '+971' + target.phone[4:]
    await db.flush()
    with pytest.raises(ValueError, match='أكثر من حساب'):
        await svc.lookup_user(db, '0' + target.phone[4:], None)
    assert await svc.lookup_user(db, '+968' + target.phone[4:], None) is None


@pytest.mark.asyncio
@pytest.mark.parametrize('kind', ['customer', 'supplier'])
@pytest.mark.parametrize('accept', [True, False])
async def test_invitation_device_push_and_response_exactly_once(db, monkeypatch, kind, accept):
    merchant, owner, target, party = await seed(db, kind)
    db.add(DeviceToken(user_id=target.id, token=uuid4().hex, platform='android', is_active=True))
    await db.flush()
    monkeypatch.setattr(api, '_need_party_perm', AsyncMock())
    send = AsyncMock(return_value={'sent': 1, 'failed': 0, 'invalid_tokens': []})
    monkeypatch.setattr(push_service, '_send_push_bounded', send)
    reply = AsyncMock(return_value={'sent': 1, 'failed': 0})
    monkeypatch.setattr(push_service, 'push_to_users_now', reply)
    body = api.InviteRequest(party_kind=kind, party_id=party.id, code=target.public_code)
    result = await api.invite(body, str(merchant.id), owner.id, db)
    link_id = json.loads(result.body)['data']['id']
    from uuid import UUID
    link_id = UUID(link_id)
    send.assert_awaited_once()
    invite_row = (await db.execute(select(AppNotification).where(
        AppNotification.user_id == target.id))).scalar_one()
    assert invite_row.organization_id == merchant.id
    assert invite_row.event_id.startswith(f'merchant_invite:{link_id}:')
    assert send.await_args.kwargs['data']['action_payload'] == invite_row.route
    with pytest.raises(api.HTTPException, match=''):
        await api.invite(body, str(merchant.id), owner.id, db)
    assert send.await_count == 1
    operation = api.accept_invite if accept else api.reject_invite
    await operation(link_id, target.id, db)
    await operation(link_id, target.id, db)
    reply.assert_awaited_once()
    assert reply.await_args.args[1] == [owner.id]
    notices = (await db.execute(select(AppNotification).where(
        AppNotification.user_id == owner.id))).scalars().all()
    assert len(notices) == 1 and notices[0].organization_id == merchant.id
    # A rejected relationship may be invited again: a NEW event must push too.
    if not accept:
        await api.invite(body, str(merchant.id), owner.id, db)
        assert send.await_count == 2
        await operation(link_id, target.id, db)
        assert reply.await_count == 2
        assert len((await db.execute(select(AppNotification).where(
            AppNotification.user_id == owner.id,
            AppNotification.event_id.like('link_rejected:%')))).scalars().all()) == 2
