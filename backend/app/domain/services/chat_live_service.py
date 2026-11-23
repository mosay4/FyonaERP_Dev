"""Bounded long-poll signals. One Redis subscription per worker, not per user.

Only a conversation UUID is published. Messages remain in the authorized DB
query; Redis is a wake-up hint and is never a source of message contents.
"""
import asyncio
from collections import defaultdict
from contextlib import suppress
from . import chat_service
from ...core.redis import get_redis


class ChatLiveHub:
    prefix = 'fyona:chat:changed:'
    def __init__(self, max_waiters=2048, max_per_user=2):
        self.waiters = defaultdict(set)
        self.users = defaultdict(int)
        self.max_waiters, self.max_per_user = max_waiters, max_per_user
        self.task = None
        self.ready = asyncio.Event()

    def register(self, link_id, user_id):
        if sum(self.users.values()) >= self.max_waiters or self.users[user_id] >= self.max_per_user:
            return None
        event = asyncio.Event()
        self.waiters[str(link_id)].add(event); self.users[user_id] += 1
        return event

    def unregister(self, link_id, user_id, event):
        key = str(link_id)
        self.waiters[key].discard(event)
        if not self.waiters[key]: self.waiters.pop(key, None)
        self.users[user_id] -= 1
        if self.users[user_id] <= 0: self.users.pop(user_id, None)

    def notify(self, link_id):
        for event in tuple(self.waiters.get(str(link_id), ())): event.set()

    def start(self):
        if self.task is None or self.task.done(): self.task = asyncio.create_task(self._listen())

    async def _listen(self):
        while True:
            try:
                redis = await get_redis()
                async with redis.pubsub() as channel:
                    await channel.psubscribe(self.prefix + '*')
                    self.ready.set()
                    while True:
                        message = await channel.get_message(ignore_subscribe_messages=True, timeout=15)
                        if message and message.get('type') == 'pmessage': self.notify(message['data'])
            except asyncio.CancelledError:
                raise
            except Exception:
                self.ready.clear()
                # Wake requests to use bounded HTTP fallback instead of hanging.
                for key in tuple(self.waiters): self.notify(key)
                await asyncio.sleep(2)

    async def publish(self, link_id):
        self.notify(link_id)
        try:
            redis = await get_redis()
            await asyncio.wait_for(redis.publish(self.prefix + str(link_id), str(link_id)), timeout=.3)
        except Exception:
            pass  # DB cursor catch-up makes a lost hint harmless.

    async def stop(self):
        if self.task:
            self.task.cancel()
            with suppress(asyncio.CancelledError): await self.task
            self.task = None
        self.ready.clear()


chat_live_hub = ChatLiveHub()


async def wait_messages(db, user_id, link_id, *, side, after_id=None, limit=40, timeout=15):
    from fastapi import HTTPException
    await chat_service._link_for_participant(db, user_id, link_id)
    event = chat_live_hub.register(link_id, user_id)
    if event is None:
        raise HTTPException(429, detail='يوجد طلب استقبال نشط بالفعل؛ أعد المحاولة بعد قليل', headers={'Retry-After': '1'})
    try:
        chat_live_hub.start()
        page = await chat_service.list_messages(db, user_id, link_id, side=side, after_id=after_id, limit=limit)
        await db.commit()  # Release the DB connection BEFORE waiting for Redis.
        if page['messages']: return page
        try: await asyncio.wait_for(chat_live_hub.ready.wait(), timeout=.5)
        except asyncio.TimeoutError: return {**page, 'realtime': False}
        try: await asyncio.wait_for(event.wait(), timeout=timeout)
        except asyncio.TimeoutError: pass
        db.expire_all()
        return {**await chat_service.list_messages(db, user_id, link_id, side=side, after_id=after_id, limit=limit),
                'realtime': chat_live_hub.ready.is_set()}
    finally:
        chat_live_hub.unregister(link_id, user_id, event)
