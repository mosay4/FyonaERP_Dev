from fastapi import APIRouter, Depends, File, Form, UploadFile, HTTPException, Request
from pydantic import BaseModel
from typing import Optional
from uuid import UUID
import json

from ...core.config import settings
from ...core.database import get_db
from ...core.logging import get_logger
from ...api.deps import get_current_org_id, get_current_user_id, require_permission
from ...api.responses import ok
from ...domain.models.m5_models import AIQuery
from ...domain.models.agent_models import AgentContext
from ...domain.services.m5_service import HRService
from ...domain.services.sara_agent_service import SaraAgentService
from ...domain.services.sara_subscriptions import load_context
from ...domain.services import sara_personal_device as personal_device
from ...infrastructure.repositories.sql_alchemy_m5_repository import (
    SQLDepartmentRepo,
    SQLPositionRepo,
    SQLEmployeeRepo,
    SQLAttendanceRepo,
    SQLLeaveRepo,
    SQLPayrollRepo,
)

router = APIRouter(tags=["AI"])
logger = get_logger("ai_api")


def _svc(db):
    return HRService(
        SQLDepartmentRepo(db),
        SQLPositionRepo(db),
        SQLEmployeeRepo(db),
        SQLAttendanceRepo(db),
        SQLLeaveRepo(db),
        SQLPayrollRepo(db),
    )


@router.get("/ai/insights", summary="Get AI insights and recommendations")
async def insights(
    org=Depends(get_current_org_id),
    db=Depends(get_db),
    _=Depends(require_permission("ai", "read")),
):
    return ok(await _svc(db).insights(UUID(org)))


@router.get("/ai/forecast/{metric}", summary="Forecast sales/inventory")
async def forecast(
    metric: str,
    periods: int = 3,
    org=Depends(get_current_org_id),
    db=Depends(get_db),
    _=Depends(require_permission("ai", "read")),
):
    return ok(await _svc(db).forecast(UUID(org), metric, periods))


@router.get("/ai/metrics", summary="Sara agent analytics & health monitoring metrics")
async def sara_metrics(
    org=Depends(get_current_org_id),
    db=Depends(get_db),
    _=Depends(require_permission("ai", "read")),
):
    from ...domain.services.agent_analytics import AgentAnalytics, evaluate_health
    metrics = await AgentAnalytics.metrics(db, org_id=UUID(org))
    metrics["health"] = evaluate_health(metrics)
    return ok(metrics)


@router.post("/ai/query", summary="Natural language query with AI Agent")
async def query_ai(
    data: AIQuery,
    request: Request,
    org=Depends(get_current_org_id),
    uid=Depends(get_current_user_id),
    db=Depends(get_db),
    _=Depends(require_permission("ai", "read")),
):
    org_id = UUID(org)
    user_id = UUID(uid)
    if data.account_type not in (None, 'personal'):
        raise HTTPException(403, detail='افتح سارة من قسم الأعمال لبيانات الأعمال.')

    # Build agent context
    ctx = AgentContext(
        user_id=uid,
        user_name=data.user_name or "",
        account_type="personal",
        company_name=data.company_name,
        current_screen=data.current_screen or "",
        subscription_context=await load_context(db, uid),
        network_status=data.network_status or "online",
        current_tab=data.current_tab or "",
        last_screen=data.last_screen or "",
        last_operation=data.last_operation or "",
        pending_operations=data.pending_operations or [],
        language=data.language or "ar",
        screen_catalog=data.screen_catalog or [],
    )

    # Build conversation history from request
    history = []
    if data.history:
        for h in data.history:
            role = h.get("role", "user")
            content = h.get("content", "")
            if role in ("user", "assistant", "system"):
                history.append({"role": role, "content": content})

    # Process with agent — return the final user query (with transcript/analysis if any)
    # so the frontend can persist the true textual content for memory.
    agent = SaraAgentService(db, org_id, user_id)
    response = await agent.process(
        query=data.query,
        ctx=ctx,
        conversation_history=history,
        # New app builds: the Personal ledger is on the phone; Sara's reads
        # come back as device_calls (POST /ai/continue).
        device=personal_device.is_device_request(request),
    )
    result = response.model_dump()
    result["user_query"] = data.query
    return ok(result)


@router.post("/ai/query-attachment", summary="Voice/Image/File query with AI Agent (multipart)")
@router.post("/ai/query-audio", summary="Voice/Image/File query with AI Agent (multipart)")
async def query_attachment(
    query: str = Form(""),
    user_name: str = Form(""),
    account_type: str = Form("personal"),
    company_name: Optional[str] = Form(None),
    current_screen: str = Form(""),
    language: str = Form("ar"),
    history: Optional[str] = Form(None),
    screen_catalog: Optional[str] = Form(None),
    audio_file: Optional[UploadFile] = File(None),
    image_file: Optional[UploadFile] = File(None),
    attachment_file: Optional[UploadFile] = File(None),
    request: Request = None,
    org=Depends(get_current_org_id),
    uid=Depends(get_current_user_id),
    db=Depends(get_db),
    _=Depends(require_permission("ai", "read")),
):
    org_id = UUID(org)
    user_id = UUID(uid)
    is_en = (language or "ar").lower() in ("en", "english")
    if account_type != 'personal':
        raise HTTPException(403, detail='افتح سارة من قسم الأعمال لبيانات الأعمال.')
    has_attachment = any(f is not None and f.filename for f in (audio_file, image_file, attachment_file))
    if not (settings.SARA_API_KEY or settings.DEEPSEEK_API_KEY) and (has_attachment or query.strip()):
        return ok({
            "answer": ("The OpenAI API key is not set. Please add OPENAI_API_KEY to the .env file." if is_en else "لم يتم تعيين مفتاح OpenAI. يرجى إضافة OPENAI_API_KEY إلى ملف .env."),
            "confidence": 0.0,
            "actions": [],
            "suggestions": [],
        })

    from openai import AsyncOpenAI

    # 1) Transcribe audio (if provided) using OpenAI Whisper
    audio_transcribed = False
    if audio_file is not None and audio_file.filename:
        try:
            from ...domain.services.sara_transcription import transcribe
            spoken = await transcribe(audio_file, 'en' if is_en else 'ar')
            if spoken:
                query = f"{query} {spoken}".strip() if query.strip() else spoken
                audio_transcribed = True
            else:
                logger.warning("Whisper: transcription returned empty text")
                return ok({
                    "answer": ("I could not hear what you said clearly. Please try again and speak more clearly." if is_en else "عذراً، لم أتمكن من سماع ما قلت بوضوح. حاول مرة أخرى وأتحدث بشكل أوضح."),
                    "confidence": 0.0,
                    "actions": [],
                    "suggestions": [],
                })
        except Exception as e:
            logger.error("Whisper transcription failed: %s", e)
            return ok({
                "answer": ("Sorry, there was a problem processing your voice. Check your internet connection and try again." if is_en else "عذراً، حدثت مشكلة في معالجة الصوت. تأكد من اتصالك بالإنترنت وحاول مرة أخرى."),
                "confidence": 0.0,
                "actions": [],
                "suggestions": [],
            })

    # 2) Analyze image (if provided) using gpt-4o vision
    if image_file is not None and image_file.filename:
        import base64
        img_content = await image_file.read()
        img_b64 = base64.b64encode(img_content).decode()
        img_type = image_file.content_type or "image/png"
        from ...domain.services.sara_model import client as sara_client
        client = sara_client()
        if is_en:
            vision_prompt = (
                "You are the image analyst for Sara, the smart assistant in the FYONA app. Analyse the attached image in detail:\n"
                f"User's question: {query or 'Analyse this image'}\n"
                "Describe the content of the image clearly and accurately.\n"
                "If the image is financial — accounts, invoices, receipts, statements, or contains numbers, amounts and dates — extract every number, amount, date and item precisely.\n"
                "If the image is NOT financial: describe it briefly and state that it is a general image and not a financial document.\n"
                "Never say that you cannot see or analyse the image.\n"
                "Reply in clear, concise English."
            )
        else:
            vision_prompt = (
                "أنت محلل صور لسارة، المساعد الذكي في تطبيق FYONA. حللي الصورة المرفقة بالتفصيل:\n"
                f"سؤال المستخدم: {query or 'حلل هذه الصورة'}\n"
                "أوصفي محتوى الصورة بوضوح ودقة.\n"
                "إذا كانت الصورة مالية أو حسابات أو فواتير أو إيصالات أو كشوفاً أو تحتوي على أرقام ومبالغ وتواريخ: استخرجي كل الأرقام والمبالغ والتواريخ والعناصر بدقة.\n"
                "إذا كانت الصورة غير مالية: أوصفيها باختصار واذكري أنها صورة عامة وليست مستنداً مالياً.\n"
                "لا تقولي أبداً أنك لا تستطيعين رؤية الصورة أو تحليلها.\n"
                "أجب بالعربية بشكل واضح ومختصر."
            )
        try:
            vision = await client.chat.completions.create(
                model=settings.SARA_MODEL,
                messages=[{
                    "role": "user",
                    "content": [
                        {"type": "text", "text": vision_prompt},
                        {"type": "image_url", "image_url": {"url": f"data:{img_type};base64,{img_b64}"}},
                    ],
                }],
                max_tokens=1024,
            )
            analysis = (vision.choices[0].message.content or "").strip()
        except Exception as e:
            logger.warning("vision_analysis_failed: %s", e)
            analysis = ""
        if analysis:
            if is_en:
                query = (
                    f"The user attached an image and asked for your help analysing it.\n"
                    f"Image analysis:\n{analysis}\n\n"
                    f"User's question: {query or 'Analyse the image and describe it to me'}"
                ).strip()
            else:
                query = (
                    f"المستخدم أرفق صورة وطلب مساعدتك في تحليلها.\n"
                    f"تحليل الصورة:\n{analysis}\n\n"
                    f"سؤال المستخدم: {query or 'حللي الصورة ووصفيها لي'}"
                ).strip()

    # 3) Read plain-text attachment (if provided)
    if attachment_file is not None and attachment_file.filename:
        text_content = await attachment_file.read()
        try:
            text = text_content.decode("utf-8", errors="replace").strip()
        except Exception:
            text = ""
        if text:
            if is_en:
                query = f"{query}\n\nFile content ({attachment_file.filename}):\n{text[:4000]}".strip()
            else:
                query = f"{query}\n\nمحتوى الملف ({attachment_file.filename}):\n{text[:4000]}".strip()

    catalog_list = []
    if screen_catalog:
        try:
            parsed_catalog = json.loads(screen_catalog)
            if isinstance(parsed_catalog, list):
                catalog_list = parsed_catalog
        except (json.JSONDecodeError, TypeError):
            catalog_list = []

    ctx = AgentContext(
        user_id=uid,
        user_name=user_name or "",
        account_type=account_type or "personal",
        company_name=company_name,
        current_screen=current_screen or "",
        language=language or "ar",
        screen_catalog=catalog_list,
        subscription_context=await load_context(db, uid),
    )

    history_list = []
    if history:
        try:
            parsed_history = json.loads(history)
        except (json.JSONDecodeError, TypeError):
            parsed_history = []
        for h in parsed_history:
            role = h.get("role", "user")
            content = h.get("content", "")
            if role in ("user", "assistant", "system"):
                history_list.append({"role": role, "content": content})

    agent = SaraAgentService(db, org_id, user_id)
    response = await agent.process(
        query=query,
        ctx=ctx,
        conversation_history=history_list,
        device=personal_device.is_device_request(request),
    )
    result = response.model_dump()
    result["user_query"] = query
    return ok(result)


class PersonalContinue(BaseModel):
    state: dict
    results: list = []
    language: str = "ar"
    screen_catalog: list = []
    current_screen: str = ""
    user_name: str = ""


@router.post("/ai/continue", summary="Personal Sara: resume with the phone's answers")
async def continue_personal(
    data: PersonalContinue,
    request: Request,
    org=Depends(get_current_org_id),
    uid=Depends(get_current_user_id),
    db=Depends(get_db),
    _=Depends(require_permission("ai", "read")),
):
    """The phone answered Sara's Personal reads from its own ledger. The
    paused conversation comes back signed; nothing was kept on the server."""
    if not personal_device.is_device_request(request):
        raise HTTPException(409, detail="Personal Sara device mode header is missing.")
    if len(json.dumps(data.state, default=str)) > personal_device.STATE_LIMIT or \
            len(json.dumps(data.results, default=str)) > personal_device.STATE_LIMIT:
        raise HTTPException(413, detail="المحادثة طويلة جدًا؛ ابدأ طلبًا جديدًا.")
    try:
        state = personal_device.unseal(data.state, str(UUID(uid)))
    except ValueError:
        raise HTTPException(409, detail="انتهت صلاحية هذه المحادثة؛ أعد إرسال سؤالك.")
    ctx = AgentContext(
        user_id=uid,
        user_name=data.user_name or "",
        account_type="personal",
        current_screen=data.current_screen or "",
        subscription_context=await load_context(db, uid),
        language=data.language or "ar",
        screen_catalog=data.screen_catalog or [],
    )
    agent = SaraAgentService(db, UUID(org), UUID(uid))
    response = await agent.process(query="", ctx=ctx, device=True,
                                   resume={"state": state, "results": data.results})
    result = response.model_dump()
    if state.get("phase") == "context":
        result["user_query"] = state.get("query")
    return ok(result)


@router.post("/ai/speak", summary="Text to Speech — convert Sara's reply to audio")
async def speak(
    text: str = Form(..., description="النص المراد تحويله لصوت"),
    voice: str = Form("alloy", description="صوت سارة: alloy | echo | fable | onyx | nova | shimmer"),
    speed: float = Form(1.0, description="سرعة الصوت (0.25 - 4.0)"),
    _org=Depends(get_current_org_id),
    _uid=Depends(get_current_user_id),
    _=Depends(require_permission("ai", "read")),
):
    from fastapi import Response
    from openai import AsyncOpenAI

    # Sara answers in text only (owner's decision): she understands voice
    # messages but never speaks. Kept as an empty answer for old app builds.
    return Response(content=b"", media_type="audio/mpeg")

    speed = min(max(speed, 0.25), 4.0)
    voices = {"alloy", "echo", "fable", "onyx", "nova", "shimmer"}
    if voice not in voices:
        voice = "alloy"

    try:
        client = AsyncOpenAI(api_key=settings.OPENAI_API_KEY)
        resp = await client.audio.speech.create(
            model="tts-1",
            voice=voice,
            input=text[:4000],
            speed=speed,
        )
        return Response(content=resp.content, media_type="audio/mpeg")
    except Exception as e:
        logger.error("TTS failed: %s", e)
        return Response(content=b"", media_type="audio/mpeg")


@router.get("/ai/test-key", summary="Test the AI provider key (DeepSeek, else OpenAI)")
async def test_openai_key(
    _org=Depends(get_current_org_id),
    _uid=Depends(get_current_user_id),
    _=Depends(require_permission("ai", "read")),
):
    from app.domain.services.ai_router import build_client, route

    r = route("ping")
    if not r.api_key:
        return ok({"valid": False, "error": "No AI provider key is configured"})
    try:
        await build_client(r).models.list()
        # Never echo any part of the key.
        return ok({"valid": True, "provider": r.provider, "model": r.model})
    except Exception as e:
        return ok({"valid": False, "provider": r.provider, "error": type(e).__name__})
