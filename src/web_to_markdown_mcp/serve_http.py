"""HTTP entrypoint for web-to-markdown-mcp.

Serves the existing FastMCP app over streamable HTTP so the Claude mobile
app can reach it as a remote connector, wrapped in a query-string API-key
gate and a per-IP rate limiter. The stdio entrypoint (server.main) is left
untouched and still used for local Claude Desktop on the Mac.

Why a query-string key and not a header: the mobile MCP client cannot send
custom headers (the same reason Cloudflare Access Passkey won't work here),
so `?key=` in the URL is the only gate it can carry. Same pattern already
proven with Open Brain.

Design notes worth remembering:
  * The wrapper is PURE ASGI, not Starlette BaseHTTPMiddleware. BaseHTTP-
    Middleware buffers responses and breaks the streamable-HTTP event
    stream; a pure-ASGI callable that only inspects the request and either
    short-circuits or passes the scope through does not.
  * It forwards non-http scopes (lifespan, websocket) untouched. That is
    load-bearing: FastMCP's streamable-HTTP session manager raises
    "task group not initialized" on every request if its lifespan does not
    run, and the lifespan only runs if these scopes reach the inner app.
  * Fail closed: if the key file is missing or empty, every request is 401.

Config via environment (all optional except you must create the key file):
  WTM_HTTP_HOST      bind address           default 127.0.0.1 (localhost only)
  WTM_HTTP_PORT      bind port              default 8787
  WTM_MCP_PATH       endpoint path          default /mcp
  WTM_KEYFILE        path to key file       default /etc/web-to-markdown/keys
  WTM_ALLOWED_HOSTS  comma list for host/   default 127.0.0.1,localhost
                     origin protection      (ADD the tunnel hostname on deploy)
  WTM_RATE_CAPACITY  token-bucket burst     default 20
  WTM_RATE_REFILL    tokens refilled/sec    default 0.5  (~30/min steady)

Key file format: one key per line, blank lines and #-comments ignored.
Multiple lines let you rotate with overlap (add new, switch client, remove
old) without a restart -- the file is re-read whenever its mtime changes.
"""
from __future__ import annotations

import hmac
import inspect
import json
import logging
import os
import re
import time
from pathlib import Path
from urllib.parse import parse_qs

import uvicorn

from web_to_markdown_mcp.server import mcp

logger = logging.getLogger("web_to_markdown_mcp.http")

# --- configuration ---------------------------------------------------------
HOST = os.environ.get("WTM_HTTP_HOST", "127.0.0.1")
PORT = int(os.environ.get("WTM_HTTP_PORT", "8787"))
MCP_PATH = os.environ.get("WTM_MCP_PATH", "/mcp")
KEYFILE = Path(os.environ.get("WTM_KEYFILE", "/etc/web-to-markdown/keys"))
ALLOWED_HOSTS = [h.strip() for h in os.environ.get(
    "WTM_ALLOWED_HOSTS", "127.0.0.1,localhost").split(",") if h.strip()]
RATE_CAPACITY = float(os.environ.get("WTM_RATE_CAPACITY", "20"))
RATE_REFILL = float(os.environ.get("WTM_RATE_REFILL", "0.5"))

# --- key loading (rotatable without restart, cached by mtime) --------------
_keys_cache: tuple[float, frozenset[str]] = (-1.0, frozenset())


def _load_keys() -> frozenset[str]:
    global _keys_cache
    try:
        mtime = KEYFILE.stat().st_mtime
    except OSError:
        return frozenset()  # missing file -> fail closed
    if mtime == _keys_cache[0]:
        return _keys_cache[1]
    keys = frozenset(
        ln.strip() for ln in KEYFILE.read_text().splitlines()
        if ln.strip() and not ln.lstrip().startswith("#")
    )
    _keys_cache = (mtime, keys)
    return keys


def _key_ok(presented: str) -> bool:
    if not presented:
        return False
    # constant-time compare against every valid key (avoid timing leaks)
    return any(hmac.compare_digest(presented, k) for k in _load_keys())


# --- rate limiting (per-IP token bucket, in-process) -----------------------
_buckets: dict[str, tuple[float, float]] = {}  # identity -> (tokens, last_ts)


def _rate_ok(identity: str) -> bool:
    now = time.monotonic()
    tokens, last = _buckets.get(identity, (RATE_CAPACITY, now))
    tokens = min(RATE_CAPACITY, tokens + (now - last) * RATE_REFILL)
    if tokens < 1.0:
        _buckets[identity] = (tokens, now)
        return False
    _buckets[identity] = (tokens - 1.0, now)
    if len(_buckets) > 4096:  # crude bound against unbounded growth
        cutoff = now - 3600
        for k in [k for k, (_, t) in _buckets.items() if t < cutoff]:
            _buckets.pop(k, None)
    return True


def _client_ip(scope) -> str:
    hdr = {k.decode().lower(): v.decode() for k, v in scope.get("headers", [])}
    return (hdr.get("cf-connecting-ip")
            or hdr.get("x-forwarded-for", "").split(",")[0].strip()
            or (scope.get("client") or ["unknown"])[0])


# --- log scrubbing: never let ?key=... survive into a log line -------------
_KEY_RE = re.compile(r"([?&]key=)[^&\s]+")


class _ScrubKeyFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        if isinstance(record.msg, str) and "key=" in record.msg:
            record.msg = _KEY_RE.sub(r"\1REDACTED", record.msg)
        if record.args:
            record.args = tuple(
                _KEY_RE.sub(r"\1REDACTED", a) if isinstance(a, str) else a
                for a in record.args
            )
        return True


# --- the gate (pure ASGI) --------------------------------------------------
async def _send_json(send, status: int, body: dict) -> None:
    data = json.dumps(body).encode()
    await send({"type": "http.response.start", "status": status,
                "headers": [(b"content-type", b"application/json"),
                            (b"content-length", str(len(data)).encode())]})
    await send({"type": "http.response.body", "body": data})


class Gate:
    """Rate-limit by IP, then require a valid ?key=. Everything else passes."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            # lifespan / websocket: forward untouched (see module docstring)
            return await self.app(scope, receive, send)
        if not _rate_ok(_client_ip(scope)):
            return await _send_json(send, 429, {"error": "rate limited"})
        key = parse_qs(scope.get("query_string", b"").decode("latin-1")).get("key", [""])[0]
        if not _key_ok(key):
            logger.warning("rejected %s (bad/missing key)", scope.get("path", "?"))
            return await _send_json(send, 401, {"error": "unauthorized"})
        return await self.app(scope, receive, send)


# --- app construction (version-robust kwarg filtering) ---------------------
def _build_app():
    want = dict(path=MCP_PATH, stateless_http=True,
                allowed_hosts=ALLOWED_HOSTS, transport="http")
    params = inspect.signature(mcp.http_app).parameters
    kwargs = {k: v for k, v in want.items() if k in params}
    dropped = [k for k in want if k not in params]
    if dropped:
        logger.warning("fastmcp.http_app does not support %s on this version; "
                       "upgrade fastmcp if host/origin protection is needed", dropped)
    return Gate(mcp.http_app(**kwargs))


def main() -> None:
    for name in ("", "uvicorn", "uvicorn.access", "uvicorn.error",
                 "web_to_markdown_mcp.http"):
        logging.getLogger(name).addFilter(_ScrubKeyFilter())
    if not _load_keys():
        logger.warning("no keys loaded from %s -- every request will 401 until "
                       "you create it (one key per line)", KEYFILE)
    logger.info("serving MCP on http://%s:%s%s (allowed_hosts=%s)",
                HOST, PORT, MCP_PATH, ALLOWED_HOSTS)
    uvicorn.run(_build_app(), host=HOST, port=PORT,
                log_level="info", access_log=False)


if __name__ == "__main__":
    main()
