"""Central AI router — DeepSeek V4.1 Flash with adaptive thinking effort.

The Falcon and Sarah systems keep their EXACT logic/behavior; only the
model layer is routed here. DeepSeek's API is OpenAI-compatible (same
AsyncOpenAI SDK, different base_url), so switching is transparent.

Effort tiers — chosen per question difficulty, NATIVE to deepseek-flash:
  low  → quick direct answers (light/no thinking)        tokens ×1
  high → thinking enabled, moderate budget               tokens ×4
  max  → thinking enabled, large budget (deep analysis)  tokens ×9

When DEEPSEEK_API_KEY is absent, everything falls back to the legacy
OpenAI path unchanged — no system can break.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Optional

from app.core.config import settings


@dataclass
class AIRoute:
    provider: str            # 'deepseek' | 'openai'
    base_url: Optional[str]  # None → SDK default (legacy OpenAI)
    api_key: str
    model: str
    max_tokens: int
    effort: str              # low | high | max


# Bilingual difficulty signals (ar/en).
_HIGH_HINTS = re.compile(
    r"(قارن|تحليل|حلل|لماذا|أرشدني|اشرح لي|توقعات|اتجاهات|"
    r"compare|why|analy[sz]e|forecast|trend|insight|explain)",
    re.IGNORECASE,
)
_MAX_HINTS = re.compile(
    r"(خطة|خطط لي|استراتيجية|تقرير شامل|دراسة|مقارنة شاملة|سيناريو|"
    r"أثر|تأثير|خلاصة شاملة|"
    r"plan|strategy|comprehensive|report|scenario|roadmap|forecast)",
    re.IGNORECASE,
)


def classify_difficulty(question: str) -> str:
    """Cheap deterministic triage: low | high | max."""
    q = (question or "").strip()
    if not q:
        return "low"
    long_q = len(q) > 240
    multi_part = q.count("؟") + q.count("?") >= 2
    if _MAX_HINTS.search(q) or (long_q and multi_part):
        return "max"
    if _HIGH_HINTS.search(q) or len(q) > 90 or multi_part:
        return "high"
    return "low"


def route(
    question: str,
    *,
    tools: bool = False,
    base_tokens: int = 1024,
) -> AIRoute:
    """Pick provider/model/effort/budget for a call. Never raises.

    [tools] is accepted for interface compatibility — deepseek-flash
    supports function calling at every effort level, so agentic loops
    (Sarah) get the same adaptive thinking as the Falcon.
    """
    effort = classify_difficulty(question)
    if settings.DEEPSEEK_API_KEY:
        mult = {"low": 1, "high": 4, "max": 9}[effort]
        return AIRoute(
            provider="deepseek",
            base_url=settings.DEEPSEEK_BASE_URL,
            api_key=settings.DEEPSEEK_API_KEY,
            model=settings.DEEPSEEK_MODEL,
            max_tokens=min(base_tokens * mult, 8192),
            effort=effort,
        )
    # Legacy fallback — identical behavior to before the router existed.
    return AIRoute(
        provider="openai",
        base_url=None,
        api_key=settings.OPENAI_API_KEY or "",
        model=settings.OPENAI_MODEL,
        max_tokens=base_tokens,
        effort=effort,
    )


def build_client(r: AIRoute):
    """AsyncOpenAI-compatible client for the route."""
    from openai import AsyncOpenAI

    return AsyncOpenAI(api_key=r.api_key, base_url=r.base_url)
