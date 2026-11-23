"""LAN service advertisement (mDNS / DNS-SD).

Phones on the same Wi-Fi discover the backend with zero configuration:
no typed IP addresses, no per-device builds. The Flutter app browses
``_fyona-erp._tcp.local`` and connects to the advertised address+port.

Best-effort by design: any failure (no multicast route, sandbox, missing
dependency) is swallowed — the API itself is unaffected.
"""

import socket

SERVICE_TYPE = "_fyona-erp._tcp.local."
SERVICE_NAME = "FYONA-ERP"

_holder: dict = {}


def _lan_ip() -> str | None:
    """Outbound-interface IPv4 without sending any traffic."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
        finally:
            s.close()
        if ip and not ip.startswith("127."):
            return ip
    except Exception:
        pass
    try:
        ip = socket.gethostbyname(socket.gethostname())
        if ip and not ip.startswith("127."):
            return ip
    except Exception:
        pass
    return None


async def start_advertisement(port: int):
    """Register the mDNS service. Returns a handle (or None on failure)."""
    try:
        from zeroconf import ServiceInfo
        from zeroconf.asyncio import AsyncZeroconf
    except Exception:
        return None
    try:
        ip = _lan_ip()
        if not ip:
            return None
        zc = AsyncZeroconf()
        info = ServiceInfo(
            SERVICE_TYPE,
            f"{SERVICE_NAME}.{SERVICE_TYPE}",
            addresses=[socket.inet_aton(ip)],
            port=int(port),
            properties={"path": "/api/v1", "v": "1"},
            server=f"{socket.gethostname()}.local.",
        )
        await zc.async_register_service(info)
        _holder["zc"] = zc
        _holder["info"] = info
        return zc
    except Exception:
        try:
            await _safe_close()
        except Exception:
            pass
        return None


async def _safe_close() -> None:
    zc = _holder.pop("zc", None)
    info = _holder.pop("info", None)
    if zc is None:
        return
    try:
        if info is not None:
            await zc.async_unregister_service(info)
    except Exception:
        pass
    try:
        await zc.async_close()
    except Exception:
        pass


async def stop_advertisement() -> None:
    """Idempotent shutdown hook."""
    try:
        await _safe_close()
    except Exception:
        pass
