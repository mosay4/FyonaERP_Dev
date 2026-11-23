import json
from typing import Callable, Any
from .redis import get_redis
from .logging import get_logger

logger = get_logger("event_bus")


class EventBus:
    def __init__(self):
        self._handlers: dict[str, list[Callable]] = {}

    def subscribe(self, event_type: str):
        def decorator(handler: Callable):
            if event_type not in self._handlers:
                self._handlers[event_type] = []
            self._handlers[event_type].append(handler)
            return handler

        return decorator

    async def publish(self, event_type: str, data: dict[str, Any]) -> None:
        logger.info("event_published", event_type=event_type)
        # Local handlers
        for handler in self._handlers.get(event_type, []):
            try:
                await handler(data)
            except Exception as e:
                logger.error(
                    "event_handler_failed", event_type=event_type, error=str(e)
                )
        # Redis Pub/Sub for cross-service
        try:
            redis = await get_redis()
            await redis.publish(event_type, json.dumps(data))
        except Exception as e:
            logger.warning("redis_publish_failed", event_type=event_type, error=str(e))


event_bus = EventBus()
