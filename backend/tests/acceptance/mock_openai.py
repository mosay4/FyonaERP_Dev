"""Scripted mock of the OpenAI async client for deterministic agent acceptance tests.

Only the remote OpenAI transport is replaced; the real agent loop, prompt builder,
tool executor, memory store and SQLAlchemy queries are all exercised as in production.
"""

import json
from types import SimpleNamespace


class FakeToolCall:
    def __init__(self, name, arguments, call_id):
        self.id = call_id
        self.function = SimpleNamespace(
            name=name,
            arguments=(
                json.dumps(arguments, ensure_ascii=False)
                if isinstance(arguments, (dict, list))
                else str(arguments)
            ),
        )

    def model_dump(self):
        return {
            "id": self.id,
            "type": "function",
            "function": {
                "name": self.function.name,
                "arguments": self.function.arguments,
            },
        }


class FakeMessage:
    def __init__(self, content=None, tool_calls=None):
        self.content = content
        self.tool_calls = tool_calls


class FakeChoice:
    def __init__(self, message):
        self.message = message


class FakeResponse:
    def __init__(self, content=None, tool_calls=None):
        self.choices = [FakeChoice(FakeMessage(content=content, tool_calls=tool_calls))]


class ScriptedCompletions:
    """chat.completions.create replays a scripted list of model turns.

    Each step is either:
      - {"content": "...", "tool_calls": [{"name":..., "arguments": {...}}, ...]}
      - a callable receiving the current messages list. A callable lets a test
        emulate the model OBSERVING the real tool results that the ToolExecutor
        produced and REFLECTING before deciding its next action.
      - an Exception instance: `create` will raise it (simulates API failures).
    """

    def __init__(self, script=None):
        self.script = list(script or [])
        self.calls = []          # messages snapshot per create() call
        self.call_kwargs = []    # full kwargs per create() call

    async def create(self, **kwargs):
        self.calls.append(kwargs.get("messages", []))
        self.call_kwargs.append(kwargs)
        if self.script:
            step = self.script.pop(0)
        else:
            step = {"content": "نهاية المحادثة."}
        if callable(step):
            out = step(kwargs.get("messages", []))
            if isinstance(out, Exception):
                raise out
            step = out
        return self._build_response(step)

    @staticmethod
    def _build_response(step):
        if isinstance(step, Exception):
            raise step
        content = step.get("content")
        raw = step.get("tool_calls") or []
        tool_calls = [
            FakeToolCall(t["name"], t.get("arguments", {}), f"call_{i}")
            for i, t in enumerate(raw)
        ]
        return FakeResponse(content=content, tool_calls=tool_calls or None)


class ScriptedSpeech:
    def __init__(self, audio_bytes=b"MP3-FAKE-DATA"):
        self.audio = audio_bytes
        self.calls = []

    async def create(self, **kwargs):
        self.calls.append(kwargs)
        return SimpleNamespace(content=self.audio)


class ScriptedTranscriptions:
    def __init__(self, text="ملخص مصاريفي لهذا الشهر"):
        self.text = text
        self.calls = []

    async def create(self, **kwargs):
        self.calls.append(kwargs)
        return SimpleNamespace(text=self.text)


class MockAsyncOpenAI:
    def __init__(self, script=None, audio_bytes=b"MP3-FAKE-DATA", transcript_text=""):
        self.chat = SimpleNamespace(completions=ScriptedCompletions(script))
        self.audio = SimpleNamespace(
            speech=ScriptedSpeech(audio_bytes),
            transcriptions=ScriptedTranscriptions(transcript_text),
        )


def final_content(text="تم تنفيذ طلبك بنجاح."):
    """Build a final (no tool calls) model step."""
    return {"content": text}


def tool_call(name, arguments=None):
    """Build a model step that issues one tool call."""
    return {
        "content": None,
        "tool_calls": [{"name": name, "arguments": arguments or {}}],
    }


def parallel_tool_calls(*calls):
    """Build a model step that issues several tool calls in ONE round."""
    return {"content": None, "tool_calls": [c for c in calls]}
