"""Sara's provider is independent of Falcon and OpenCode configuration."""
from openai import AsyncOpenAI
from app.core.config import settings
from app.domain.services.ai_router import classify_difficulty


def client():
    return AsyncOpenAI(api_key=settings.SARA_API_KEY or settings.DEEPSEEK_API_KEY,
                       base_url=settings.SARA_BASE_URL, timeout=90, max_retries=1)


def options(query):
    # DeepSeek documents medium as mapping to its standard high budget;
    # never request max. Simple questions disable thinking.
    hard = classify_difficulty(query) != 'low'
    return {'model': settings.SARA_MODEL, 'max_tokens': 4096 if hard else 2048,
            'reasoning_effort': 'medium' if hard else 'low',
            'extra_body': {'thinking': {'type': 'enabled' if hard else 'disabled'}}}
