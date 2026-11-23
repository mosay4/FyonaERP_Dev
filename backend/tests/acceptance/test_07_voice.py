"""Acceptance Test 7 — Voice Agent (TTS + STT).

Backend endpoints /ai/speak (TTS) and /ai/query-audio (STT + agent) are exercised
against the real FastAPI endpoint functions with the OpenAI transport mocked:
- MP3 bytes are returned with the right content-type.
- Sara's voice selection and speed are honoured (and clamped to valid ranges).
- Whisper transcripts are appended to the user query before the agent runs.
- Failure paths degrade to an empty audio response, never a crash.
"""

from io import BytesIO
from types import SimpleNamespace

import pytest
import openai
from fastapi import UploadFile

from app.api.v1.ai import query_ai, query_attachment, speak
from app.domain.models.m5_models import AIQuery

from tests.acceptance.mock_openai import final_content, MockAsyncOpenAI


async def test_speak_returns_mp3_bytes(seed, openai_client):
    client = openai_client()
    resp = await speak(
        text="مرحباً بك في فاونا", voice="nova", speed=1.5,
        _org=str(seed["org_a"]), _uid=str(seed["org_a"]), _=None,
    )
    assert resp.media_type == "audio/mpeg"
    assert resp.body == b"MP3-FAKE-DATA"

    call = client.audio.speech.calls[0]
    assert call["model"] == "tts-1"
    assert call["voice"] == "nova"
    assert call["speed"] == 1.5
    assert call["input"] == "مرحباً بك في فاونا"


async def test_speak_defaults_to_alloy_speed_1(seed, openai_client):
    client = openai_client()
    await speak(
        text="اختبار", voice="alloy", speed=1.0,
        _org=str(seed["org_a"]), _uid=str(seed["org_a"]), _=None,
    )
    call = client.audio.speech.calls[0]
    assert call["voice"] == "alloy"
    assert call["speed"] == 1.0


async def test_speak_clamps_invalid_voice_and_speed(seed, openai_client):
    client = openai_client()
    await speak(
        text="أ", voice="سارة-غير-موجودة", speed=99.0,
        _org=str(seed["org_a"]), _uid=str(seed["org_a"]), _=None,
    )
    call = client.audio.speech.calls[0]
    assert call["voice"] == "alloy"          # invalid voice -> default
    assert call["speed"] == 4.0              # clamped to max

    client2 = openai_client()
    await speak(
        text="أ", voice="shimmer", speed=-5.0,
        _org=str(seed["org_a"]), _uid=str(seed["org_a"]), _=None,
    )
    assert client2.audio.speech.calls[0]["speed"] == 0.25  # clamped to min


async def test_speak_without_key_returns_empty_audio(seed, no_api_key):
    resp = await speak(
        text="مرحباً", _org=str(seed["org_a"]), _uid=str(seed["org_a"]), _=None,
    )
    assert resp.media_type == "audio/mpeg"
    assert resp.body == b""


async def test_speak_tts_failure_returns_empty_audio(seed, monkeypatch):
    class BoomSpeech:
        async def create(self, **kwargs):
            raise RuntimeError("tts provider down")

    mock = SimpleNamespace(
        chat=SimpleNamespace(completions=SimpleNamespace()),
        audio=SimpleNamespace(speech=BoomSpeech()),
    )
    monkeypatch.setattr(openai, "AsyncOpenAI", lambda api_key: mock)
    resp = await speak(
        text="مرحباً", voice="alloy", speed=1.0,
        _org=str(seed["org_a"]), _uid=str(seed["org_a"]), _=None,
    )
    assert resp.media_type == "audio/mpeg"
    assert resp.body == b""


async def test_voice_transcript_reaches_the_agent(make_agent, seed, openai_client, db):
    """STT: whisper transcript is appended to the query the agent processes."""
    client = openai_client(
        script=[final_content("تم تحليل صوتك: مصاريفك هذا الشهر 800 ريال.")],
        transcript_text="ملخص مصاريفي لهذا الشهر",
    )
    audio = UploadFile(filename="record.m4a", file=BytesIO(b"\x00\x01\x02"))

    await query_attachment(
        query="", user_name="مريم", account_type="personal",
        company_name=None, current_screen="الرئيسية", history=None,
        audio_file=audio, image_file=None, attachment_file=None,
        org=str(seed["org_a"]), uid=str(seed["org_a"]), db=db, _=None,
    )

    # 1) Whisper was invoked with the audio file.
    assert client.audio.transcriptions.calls
    whisper = client.audio.transcriptions.calls[0]
    assert whisper["model"] == "whisper-1"
    assert whisper["file"][0] == "record.m4a"

    # 2) The agent received the spoken text as part of its user query.
    user_msgs = [
        m.get("content") for msgs in client.chat.completions.calls for m in msgs
        if m.get("role") == "user"
    ]
    assert any("ملخص مصاريفي لهذا الشهر" in (c or "") for c in user_msgs)


async def test_query_endpoint_integration(make_agent, seed, openai_client, db):
    """The full /ai/query API layer + agent + real DB, end to end."""
    openai_client(script=[
        {"content": None, "tool_calls": [
            {"name": "get_banking_data", "arguments": {}},
        ]},
        final_content("رصيدك في الراجحي 1000 ريال."),
    ])

    data = AIQuery(
        query="كم رصيدي؟", user_name="مريم", account_type="personal",
        subscription_plan="Pro", subscription_status="active",
        network_status="online", current_screen="البنوك",
    )
    resp = await query_ai(
        data, org=str(seed["org_a"]), uid=str(seed["org_a"]), db=db, _=None,
    )

    import json as _json
    body = _json.loads(resp.body)["data"]
    assert body["text"] == "رصيدك في الراجحي 1000 ريال."
    assert body["confidence"] == 0.9
    assert "needs_clarification" in body
    assert isinstance(body["actions"], list)


async def test_voice_endpoints_require_auth(seed):
    """Unauthenticated calls to the voice endpoints are rejected."""
    try:
        from app.main import app  # may pull optional deps (sentry) not installed here
    except ModuleNotFoundError:
        pytest.skip("app.main unavailable in this environment (optional deps missing)")

    from httpx import AsyncClient, ASGITransport
    from unittest.mock import AsyncMock
    from app.core.database import get_db

    mock_db = AsyncMock()
    app.dependency_overrides[get_db] = lambda: mock_db
    try:
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://localhost") as ac:
            r1 = await ac.post("/api/v1/ai/speak", data={"text": "مرحباً"})
            r2 = await ac.post("/api/v1/ai/query-audio", files={"audio_file": ("a.m4a", b"\x00")})
            r3 = await ac.post("/api/v1/ai/query", json={"query": "كم رصيدي؟"})
        assert r1.status_code in (401, 403)
        assert r2.status_code in (401, 403)
        assert r3.status_code in (401, 403)
    finally:
        app.dependency_overrides.clear()
