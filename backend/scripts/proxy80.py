#!/usr/bin/env python3
"""Minimal TCP forwarder: public :80 -> backend :8001.

Phone networks (and some carriers/hotels) block non-standard outbound ports
like 8001. Port 80 is never filtered. This keeps a single uvicorn instance
authoritative while making the API reachable on both ports.
"""
import asyncio
import logging
import signal
import sys

LISTEN = ("0.0.0.0", 80)
TARGET = ("127.0.0.1", 8001)

logging.basicConfig(level=logging.INFO, format="%(asctime)s proxy %(message)s")
log = logging.getLogger("proxy")

conn_id = 0


async def pipe(reader, writer, tag):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, asyncio.CancelledError):
        pass
    except Exception as exc:  # noqa: BLE001
        log.warning("pipe %s ended: %r", tag, exc)
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def handle(client_reader, client_writer):
    global conn_id
    conn_id += 1
    cid = conn_id
    try:
        server_reader, server_writer = await asyncio.open_connection(*TARGET)
    except Exception as exc:  # noqa: BLE001
        log.warning("connect #%d to backend failed: %r", cid, exc)
        client_writer.close()
        return
    log.info("conn #%d open (%s -> %s:%d)", cid, client_writer.get_extra_info("peername"), *TARGET)
    await asyncio.gather(
        pipe(client_reader, server_writer, f"c{cid}"),
        pipe(server_reader, client_writer, f"s{cid}"),
        return_exceptions=True,
    )
    log.info("conn #%d closed", cid)


async def main():
    server = await asyncio.start_server(
        lambda r, w: handle(r, w), *LISTEN, backlog=128, reuse_address=True
    )
    log.info("listening on %s:%d -> %s:%d", *LISTEN, *TARGET)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    async with server:
        await stop.wait()
    log.info("shutting down")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)