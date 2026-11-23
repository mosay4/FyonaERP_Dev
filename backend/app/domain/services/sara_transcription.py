"""Bounded local speech recognition, separate from the chat model."""
import asyncio
import os
import tempfile
from app.core.config import settings

_gate = asyncio.Semaphore(1)
_model = None


def _transcribe(content, language):
    global _model
    from faster_whisper import WhisperModel, BatchedInferencePipeline
    if _model is None:
        _model = WhisperModel(settings.SARA_STT_MODEL, device='cpu',
                             compute_type='int8', cpu_threads=2, num_workers=1)
    name = None
    try:
        with tempfile.NamedTemporaryFile(suffix='.audio', delete=False) as file:
            file.write(content)
            name = file.name
        # Batch short speech windows instead of decoding the entire recording
        # serially with five competing beams on a two-core server.
        segments, info = BatchedInferencePipeline(model=_model).transcribe(
            name, language=language, batch_size=4,
            vad_filter=True, beam_size=1, condition_on_previous_text=False)
        if info.duration > 660:
            raise ValueError('التسجيل أطول من عشر دقائق. أرسل تسجيلًا أقصر.')
        # Consume every segment, never a truncated first chunk.
        text = ' '.join(segment.text.strip() for segment in segments).strip()
        if not text and info.duration <= 30:
            # A short quiet phone recording can be removed entirely by VAD.
            # Retry real non-silent samples without VAD, never invent silence.
            from faster_whisper.audio import decode_audio
            import numpy as np
            samples = decode_audio(name)
            rms = float(np.sqrt(np.mean(samples * samples))) if len(samples) else 0
            if rms > 0.001:
                retry, _ = _model.transcribe(samples, language=language, beam_size=1,
                    vad_filter=False, condition_on_previous_text=False)
                text = ' '.join(segment.text.strip() for segment in retry).strip()
        return text
    finally:
        if name:
            os.unlink(name)


async def transcribe(file, language='ar'):
    content = await file.read(30 * 1024 * 1024 + 1)
    if len(content) > 30 * 1024 * 1024:
        raise ValueError('حجم التسجيل كبير. الحد 30 ميجابايت.')
    async with _gate:
        return await asyncio.to_thread(_transcribe, content,
                                      'en' if language == 'en' else 'ar')
