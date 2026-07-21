"""SSRF guard for web-to-markdown-mcp.

The fetcher is general-purpose (no domain allowlist), so this IP denylist is
the load-bearing control that stops it being used to reach internal services
or cloud-metadata endpoints. It must run on the top-level URL AND on every
redirect hop AND on every browser subresource request -- see how server.py
wires it into both the httpx tier (manual redirect loop) and the Chromium
tier (page.route interceptor).

Covers: non-http(s) schemes; literal and DNS-resolved private / loopback /
link-local / reserved / multicast / unspecified addresses; IPv4-mapped,
6to4, and Teredo IPv6 that embed a disallowed IPv4; and integer / hex IP
literals (http://2130706433/) that slip past dotted-quad checks.

Known residuals (documented, deliberately not closed here):
  * DNS-rebinding TOCTOU: we resolve and vet, but httpx and Chromium
    re-resolve when they actually connect, so a hostile resolver can hand us
    a public IP and them an internal one. Closing it fully means pinning the
    connection to the vetted IP. The box's fail-closed VPN egress blackholes
    most of that window; loopback and link-local are the part routing can't
    catch, and those are caught here as long as the resolver is honest at
    vet time. The decision cache below widens this window by at most
    CACHE_TTL seconds.
  * Exotic IP-literal obfuscation (dotted-octal and mixed forms) beyond the
    plain-integer and hex-integer cases handled below.
"""
from __future__ import annotations

import asyncio
import ipaddress
import os
import socket
import time
from urllib.parse import urlsplit

CACHE_TTL = float(os.environ.get("WTM_SSRF_CACHE_TTL", "60"))
_ALLOWED_SCHEMES = {"http", "https"}

# (host, port) -> (expiry_monotonic, reason_or_None)
_cache: dict[tuple[str, int], tuple[float, str | None]] = {}


class SSRFError(ValueError):
    """Raised when a URL or host is not allowed to be fetched."""


def _reason_disallowed(ip: ipaddress.IPv4Address | ipaddress.IPv6Address) -> str | None:
    """Return a short reason if this address is in a blocked class, else None."""
    if isinstance(ip, ipaddress.IPv6Address):
        embedded = ip.ipv4_mapped or ip.sixtofour
        if embedded is None and ip.teredo is not None:
            embedded = ip.teredo[1]  # teredo client IPv4
        if embedded is not None:
            # The embedded IPv4 is the real target; classify that.
            return _reason_disallowed(embedded)
    if ip.is_loopback:
        return "loopback"
    if ip.is_link_local:        # 169.254.0.0/16 (cloud metadata), fe80::/10
        return "link-local"
    if ip.is_private:           # RFC1918, ULA, and related special ranges
        return "private"
    if ip.is_reserved:
        return "reserved"
    if ip.is_multicast:
        return "multicast"
    if ip.is_unspecified:       # 0.0.0.0, ::
        return "unspecified"
    return None


def _as_literal_ip(host: str) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    """Parse a host that is actually an IP literal, including the integer and
    hex forms browsers accept (http://2130706433/ == http://127.0.0.1/)."""
    try:
        return ipaddress.ip_address(host)
    except ValueError:
        pass
    try:
        if host.lower().startswith("0x"):
            return ipaddress.ip_address(int(host, 16))
        if host.isdigit():
            return ipaddress.ip_address(int(host))
    except ValueError:
        pass
    return None


async def _resolve_reason(host: str, scheme: str, port: int) -> str | None:
    """Return a blocked-class reason for host, or None if all resolved
    addresses are allowed. Cached for CACHE_TTL seconds."""
    key = (host, port)
    now = time.monotonic()
    cached = _cache.get(key)
    if cached is not None and cached[0] > now:
        return cached[1]

    literal = _as_literal_ip(host)
    if literal is not None:
        reason = _reason_disallowed(literal)
        _cache[key] = (now + CACHE_TTL, reason)
        return reason

    loop = asyncio.get_running_loop()
    try:
        infos = await loop.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror as exc:
        # Don't cache resolution failures; they're often transient.
        raise SSRFError(f"cannot resolve {host}: {exc}") from exc

    reason: str | None = None
    if not infos:
        reason = "unresolvable"
    for info in infos:
        r = _reason_disallowed(ipaddress.ip_address(info[4][0]))
        if r:
            reason = r  # reject if ANY resolved address is blocked
            break
    _cache[key] = (now + CACHE_TTL, reason)
    return reason


async def assert_url_allowed(url: str) -> None:
    """Raise SSRFError unless url is an http(s) URL whose host resolves
    entirely to public addresses. Safe to call on every hop / subresource."""
    parts = urlsplit(url)
    scheme = parts.scheme.lower()
    if scheme not in _ALLOWED_SCHEMES:
        raise SSRFError(f"scheme {parts.scheme!r} not allowed (http/https only)")
    host = parts.hostname
    if not host:
        raise SSRFError("no host in URL")
    port = parts.port or (443 if scheme == "https" else 80)
    reason = await _resolve_reason(host, scheme, port)
    if reason:
        raise SSRFError(f"{host} maps to a {reason} address")
