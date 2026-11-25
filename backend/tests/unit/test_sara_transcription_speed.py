"""Sara voice fallback (server speech-to-text) loads fast and only once.

Measured on the QA box: loading faster-whisper "small" took 8.0 s with the
model-hub round trip and 1.6 s from the local cache; preloading at startup
takes even that off the first voice message.
"""
import sys
import types

import pytest

from app.domain.services import sara_transcription as stt


def test_model_loads_from_local_cache_first_and_once(monkeypatch):
    calls = []

    class FakeModel:
        def __init__(self, name, **kw):
            calls.append(kw.get('local_files_only', False))

    monkeypatch.setitem(sys.modules, 'faster_whisper', types.SimpleNamespace(WhisperModel=FakeModel))
    monkeypatch.setattr(stt, '_model', None)
    first = stt._load()
    assert stt._load() is first
    assert calls == [True]


def test_falls_back_to_download_when_not_cached(monkeypatch):
    calls = []

    class FakeModel:
        def __init__(self, name, **kw):
            calls.append(kw.get('local_files_only', False))
            if kw.get('local_files_only'):
                raise RuntimeError('not cached')

    monkeypatch.setitem(sys.modules, 'faster_whisper', types.SimpleNamespace(WhisperModel=FakeModel))
    monkeypatch.setattr(stt, '_model', None)
    stt._load()
    assert calls == [True, False]


@pytest.mark.asyncio
async def test_preload_is_skipped_in_tests(monkeypatch):
    monkeypatch.setattr(stt, '_load', lambda: (_ for _ in ()).throw(AssertionError('loaded')))
    await stt.preload()
