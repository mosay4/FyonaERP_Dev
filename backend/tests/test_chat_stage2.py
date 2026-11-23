"""Isolated Stage 2 acceptance tests: SQLite memory + fake TTL cache, no services."""
import unittest
import json
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch
from uuid import uuid4

from sqlalchemy import insert, update
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker

from app.domain.entities.chat_entities import ChatMessage, ChatPresence
from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.merchant_entities import MerchantLink
from app.domain.entities.invoice_entities import Invoice, InvoiceItem, Payment
from app.domain.entities.business_entities import Customer
from app.domain.services import chat_service as svc
from app.api.v1 import chat
from app.api.v1 import reconciliation as _registered_entities  # noqa: F401


class ChatStage2(unittest.IsolatedAsyncioTestCase):
    async def test_three_texts_invoice_retry_echo_and_history(self):
        async with self.engine.begin() as conn:
            for entity in (Customer, Invoice, InvoiceItem, Payment):
                await conn.run_sync(entity.__table__.create)
        with patch.object(svc, '_shop', AsyncMock(return_value={'name': 'Shop'})):
            async with self.sessions() as db:
                link = await db.get(MerchantLink, self.link)
                invoice = Invoice(organization_id=self.org, customer_id=link.party_id,
                    invoice_number='INV-FOUR', invoice_type='sale',
                    invoice_date=datetime.now().date(), status='confirmed',
                    total=100, paid_amount=0, balance=100, currency='SAR')
                db.add(invoice)
                await db.flush()
                ids = []
                for i, kind in enumerate(['text', 'text', 'text', 'invoice']):
                    request = dict(side='merchant', kind=kind, text=f'text {i}',
                        invoice_id=invoice.id if kind == 'invoice' else None)
                    wire = chat.SendMessage(**request, client_message_id=f'four-{i}')
                    first = await svc.send_message(db, self.sender, self.link,
                        **request, client_message_id=wire.client_message_id)
                    retry = await svc.send_message(db, self.sender, self.link,
                        **request, idempotency_key=f'four-{i}')
                    self.assertTrue(retry['duplicate'])
                    self.assertEqual(first['message']['id'], retry['message']['id'])
                    for result in (first, retry):
                        self.assertEqual(result['message']['client_message_id'], f'four-{i}')
                        self.assertEqual(result['message']['client_id'], f'four-{i}')
                        self.assertEqual(result['message']['idempotency_key'], f'four-{i}')
                        if kind == 'invoice':
                            self.assertEqual(result['message']['invoice_number'], 'INV-FOUR')
                    ids.append(first['message']['id'])
                await db.commit()
                for _ in range(2):
                    history = await svc.list_messages(db, self.sender, self.link, side='merchant')
                    self.assertEqual(len(history['messages']), 4)
                    self.assertEqual({m['id'] for m in history['messages']}, set(ids))
                    self.assertEqual({m['client_message_id'] for m in history['messages']},
                                     {f'four-{i}' for i in range(4)})
                    self.assertEqual({m['idempotency_key'] for m in history['messages']},
                                     {f'four-{i}' for i in range(4)})
                with self.assertRaisesRegex(ValueError, 'Conflicting'):
                    await svc.send_message(db, self.sender, self.link, side='merchant',
                        kind='text', text='bad', client_id='a', client_message_id='b')
                with self.assertRaisesRegex(ValueError, 'Conflicting'):
                    await svc.send_message(db, self.sender, self.link, side='merchant',
                        kind='text', text='bad', client_message_id='a', idempotency_key='b')
                wire = chat.SendMessage(side='merchant', text='fallback',
                                        idempotency_key='fallback-only')
                with patch.object(svc, 'notify_new_message', AsyncMock(return_value=None)):
                    result = await chat.send(self.link, wire, self.sender, db)
                self.assertEqual(json.loads(result.body)['data']['message']['client_message_id'],
                                 'fallback-only')

    async def asyncSetUp(self):
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with self.engine.begin() as conn:
            for table in (Organization.__table__, User.__table__, ChatMessage.__table__, ChatPresence.__table__, MerchantLink.__table__):
                await conn.run_sync(table.create)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)
        self.sender, self.recipient, self.org, self.link = (uuid4() for _ in range(4))
        async with self.sessions() as db:
            await db.execute(insert(MerchantLink).values(
                id=self.link, merchant_org_id=self.org, party_kind="customer",
                party_id=uuid4(), invited_by=self.sender,
                external_user_id=self.recipient, status="accepted"))
            await db.commit()

    async def asyncTearDown(self):
        await self.engine.dispose()

    async def test_notification_active_leave_stale_other_user_org(self):
        clock = [0]
        cache = {}

        async def get(key):
            value, expires = cache.get(key, (None, -1))
            return value if clock[0] < expires else None

        async def put(key, value, expire):
            cache[key] = (value, clock[0] + expire)

        async def clear(_script, _count, key, value):
            active = json.loads(await get(key) or 'null')
            if isinstance(active, dict) and active.get('conversation_id') == value:
                cache.pop(key, None)

        emit, push = AsyncMock(), AsyncMock()
        with patch.object(svc, "cache_get", get), patch.object(svc, "cache_set", put), \
             patch.object(svc, "get_redis", AsyncMock(return_value=SimpleNamespace(eval=clear))), \
             patch.object(svc, "_shop", AsyncMock(return_value={"name": "Shop"})), \
             patch("app.domain.services.debt_notification_service.emit", emit), \
             patch("app.domain.services.debt_notification_service.push_event", push):
            async with self.sessions() as db:
                await svc.set_active_conversation(db, self.recipient, self.link)
                async def send(key):
                    return await chat.send(self.link, chat.SendMessage(
                        side="merchant", text="hello", client_id=key), self.sender, db)
                await send("active")
                self.assertEqual(push.await_count, 0)
                self.assertEqual(emit.await_count, 0)
                await svc.set_active_conversation(db, self.recipient, self.link, active=False)
                await send("left")
                self.assertEqual(push.await_count, 1)
                await send("left")  # idempotent retries do not notify twice
                self.assertEqual(push.await_count, 1)
                await svc.set_active_conversation(db, self.recipient, self.link)
                clock[0] += 31
                await send("stale")
                self.assertEqual(push.await_count, 2)
                await put(svc._active_key(uuid4(), self.recipient), str(self.link), 30)
                await put(svc._active_key(self.org, uuid4()), str(self.link), 30)
                await send("isolated")
                self.assertEqual(push.await_count, 3)
                await put(svc._active_key(self.org, self.recipient), str(uuid4()), 30)
                await send("other-chat")
                self.assertEqual(push.await_count, 4)
                with self.assertRaises(ValueError):
                    await svc.set_active_conversation(db, uuid4(), self.link)

    async def test_stage4_every_role_direction_and_exact_freshness(self):
        cache = {}
        async def put(key, value, expire):
            self.assertEqual(expire, 30)
            cache[key] = value
        async def get(key):
            return cache.get(key)
        async def clear(_script, _count, key, value):
            if json.loads(cache.get(key, 'null') or 'null').get('conversation_id') == value:
                cache.pop(key, None)
        emit, push = AsyncMock(), AsyncMock()
        now = datetime(2026, 10, 26, tzinfo=timezone.utc)
        with patch.object(svc, 'cache_get', get), patch.object(svc, 'cache_set', put), \
             patch.object(svc, 'get_redis', AsyncMock(return_value=SimpleNamespace(eval=clear))), \
             patch.object(svc, '_now', return_value=now), \
             patch.object(svc, '_shop', AsyncMock(return_value={'name': 'Shop'})), \
             patch.object(svc, '_party_name', AsyncMock(return_value='Party')), \
             patch('app.domain.services.debt_notification_service.emit', emit), \
             patch('app.domain.services.debt_notification_service.push_event', push):
            async with self.sessions() as db:
                external_org = uuid4()
                db.add_all([Organization(id=self.org, name='Shop', slug=uuid4().hex),
                            Organization(id=external_org, name='Party', slug=uuid4().hex)])
                await db.flush()
                db.add_all([User(id=self.sender, organization_id=self.org, role='owner',
                                 email=f'{uuid4()}@test.invalid', full_name='Merchant'),
                            User(id=self.recipient, organization_id=external_org, role='customer',
                                 email=f'{uuid4()}@test.invalid', full_name='Party')])
                await db.flush()
                for role in ('owner', 'employee'):
                    await db.execute(update(User).where(User.id == self.sender).values(role=role))
                    for kind in ('customer', 'supplier'):
                        await db.execute(update(User).where(User.id == self.recipient).values(role=kind))
                        await db.execute(update(MerchantLink).where(MerchantLink.id == self.link).values(party_kind=kind))
                        for side, sender, recipient in (
                            ('merchant', self.sender, self.recipient),
                            ('personal', self.recipient, self.sender),
                        ):
                            with self.subTest(role=role, kind=kind, side=side):
                                async def send(suffix):
                                    return await chat.send(self.link, chat.SendMessage(
                                        side=side, text='hello', client_id=f'{role}-{kind}-{side}-{suffix}'), sender, db)
                                emit.reset_mock(); push.reset_mock()
                                await svc.set_active_conversation(db, recipient, self.link)
                                await send('active')
                                self.assertEqual((emit.await_count, push.await_count), (0, 0))
                                key = svc._active_key(self.org, recipient)
                                # Even if cache TTL is broken, 30 seconds is NOT fresh.
                                cache[key] = json.dumps({'conversation_id': str(self.link),
                                    'seen_at': now.timestamp() - 30})
                                await send('stale')
                                self.assertEqual((emit.await_count, push.await_count), (1, 1))
                                await svc.set_active_conversation(db, recipient, self.link)
                                await svc.set_active_conversation(db, recipient, self.link, active=False)
                                await send('left')
                                self.assertEqual((emit.await_count, push.await_count), (2, 2))
                                await send('left')
                                self.assertEqual((emit.await_count, push.await_count), (2, 2))

    async def test_5000_bounded_latest_before_forward_and_cursor_isolation(self):
        start = datetime(2026, 1, 1, tzinfo=timezone.utc)
        ids = [uuid4() for _ in range(5000)]
        async with self.sessions() as db:
            await db.execute(insert(ChatMessage), [dict(
                id=mid, link_id=self.link, merchant_org_id=self.org,
                sender_user_id=self.sender, recipient_user_id=self.recipient,
                sender_side="merchant", kind="text", text=str(i),
                # Equal timestamps exercise deterministic (created_at, id) cursors.
                created_at=start + timedelta(seconds=i // 2),
            ) for i, mid in enumerate(ids)])
            await db.commit()
            expected = sorted(zip(ids, range(5000)), key=lambda pair: (pair[1] // 2, pair[0]))
            page = await svc.list_messages(db, self.recipient, self.link, side="personal")
            self.assertEqual(len(page["messages"]), 40)
            self.assertTrue(page["has_more"])
            self.assertEqual([m["id"] for m in page["messages"]], [str(x[0]) for x in expected[-40:]])
            older = await svc.list_messages(db, self.recipient, self.link, side="personal",
                before_id=expected[-40][0])
            self.assertEqual([m["id"] for m in older["messages"]], [str(x[0]) for x in expected[-80:-40]])
            forward = await svc.list_messages(db, self.recipient, self.link, side="personal",
                after_id=expected[-80][0], limit=100000)
            self.assertEqual(len(forward["messages"]), 79)
            focused = await svc.list_messages(db, self.recipient, self.link, side="personal",
                around_id=expected[200][0])
            self.assertEqual(len(focused["messages"]), 40)
            self.assertEqual(focused["messages"][-1]["id"], str(expected[200][0]))
            foreign = ChatMessage(id=uuid4(), link_id=uuid4(), merchant_org_id=uuid4(),
                sender_user_id=self.sender, recipient_user_id=self.recipient, kind="text")
            db.add(foreign)
            await db.flush()
            with self.assertRaises(ValueError):
                await svc.list_messages(db, self.recipient, self.link, side="personal", before_id=foreign.id)
            with self.assertRaises(ValueError):
                await svc.list_messages(db, uuid4(), self.link, side="personal")

    async def test_client_id_cannot_reveal_other_conversation(self):
        async with self.sessions() as db:
            db.add(ChatMessage(link_id=uuid4(), merchant_org_id=uuid4(),
                sender_user_id=self.sender, recipient_user_id=uuid4(),
                sender_side="merchant", kind="text", text="private", client_id="same"))
            await db.flush()
            with self.assertRaises(ValueError):
                await svc.send_message(db, self.sender, self.link,
                    side="merchant", kind="text", text="new", client_id="same")


if __name__ == "__main__":
    unittest.main()
