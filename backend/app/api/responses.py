from typing import Any
from uuid import UUID
from decimal import Decimal
from datetime import datetime
from fastapi import status
from fastapi.responses import JSONResponse, Response


def ok(data: Any = None, message: str = "OK") -> JSONResponse:
    return JSONResponse(
        content={"success": True, "message": message, "data": _serialize(data)},
        status_code=status.HTTP_200_OK,
    )


def created(data: Any = None, message: str = "Created") -> JSONResponse:
    return JSONResponse(
        content={"success": True, "message": message, "data": _serialize(data)},
        status_code=status.HTTP_201_CREATED,
    )


def no_content(message: str = "Deleted") -> Response:
    # RFC 9110: a 204 response MUST NOT carry a body. Sending JSON here made
    # uvicorn raise "Response content longer than Content-Length" and kill the
    # connection mid-response.
    return Response(status_code=status.HTTP_204_NO_CONTENT)


def _paginated(items: list, total: int, page: int, per_page: int):
    return {
        "items": _serialize(items),
        "total": total,
        "page": page,
        "per_page": per_page,
        "total_pages": max(1, (total + per_page - 1) // per_page),
    }


def ok_paginated(
    items: list, total: int, page: int, per_page: int, message: str = "OK"
) -> JSONResponse:
    return ok(_paginated(items, total, page, per_page), message)


def _serialize(obj: Any) -> Any:
    if obj is None:
        return None
    if isinstance(obj, list):
        return [_serialize_item(o) for o in obj]
    return _serialize_item(obj)


def _serialize_item(obj: Any) -> Any:
    if isinstance(obj, (UUID, Decimal)):
        return str(obj)
    if isinstance(obj, datetime):
        return obj.isoformat()
    if isinstance(obj, (str, int, float, bool)):
        return obj
    if obj is None:
        return None
    if hasattr(obj, "model_dump"):
        return _make_json_safe(obj.model_dump())
    if hasattr(obj, "dict"):
        return _make_json_safe(obj.dict())
    if isinstance(obj, dict):
        return _make_json_safe(obj)
    return str(obj)


def _make_json_safe(d: dict) -> dict:
    """Recursively convert all non-JSON-safe types to JSON-safe equivalents."""
    result = {}
    for k, v in d.items():
        if isinstance(v, (UUID, Decimal)):
            result[k] = str(v)
        elif isinstance(v, datetime):
            result[k] = v.isoformat()
        elif isinstance(v, dict):
            result[k] = _make_json_safe(v)
        elif isinstance(v, list):
            result[k] = [_serialize_item(item) for item in v]
        elif hasattr(v, "model_dump"):
            result[k] = _make_json_safe(v.model_dump())
        elif hasattr(v, "dict"):
            result[k] = _make_json_safe(v.dict())
        elif isinstance(v, (str, int, float, bool)):
            result[k] = v
        elif v is None:
            result[k] = None
        else:
            result[k] = str(v)
    return result
