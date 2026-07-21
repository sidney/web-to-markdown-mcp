"""Tests for the SSRF guard (_ssrf.py).

These exercise the classifier and the resolve-and-check path without real
outbound DNS where it matters: literal-IP and scheme cases need no DNS, and
hostname cases patch the running loop's getaddrinfo so the tests are
deterministic and offline. The one real-DNS case ("localhost") resolves
locally to loopback and so is safe and stable.

Tests are plain sync functions that drive the async guard with asyncio.run,
so they don't depend on the project's pytest-asyncio configuration.
"""
from __future__ import annotations

import asyncio
import ipaddress
from unittest.mock import patch

import pytest

from web_to_markdown_mcp import _ssrf
from web_to_markdown_mcp._ssrf import (
    SSRFError,
    _reason_disallowed,
    assert_url_allowed,
)


def setup_function(_fn):
    # Isolate the decision cache between tests.
    _ssrf._cache.clear()


def _run(coro):
    return asyncio.run(coro)


async def _check_with_resolver(url: str, ips: list[str]) -> None:
    """Run assert_url_allowed with getaddrinfo mocked to return `ips`."""
    loop = asyncio.get_running_loop()

    async def fake_getaddrinfo(host, port, **kwargs):
        return [(2, 1, 6, "", (ip, port)) for ip in ips]

    with patch.object(loop, "getaddrinfo", fake_getaddrinfo):
        await assert_url_allowed(url)


# --- classifier unit tests (no async, no DNS) ------------------------------
@pytest.mark.parametrize("ip,expected", [
    ("127.0.0.1", "loopback"),
    ("10.0.0.1", "private"),
    ("192.168.1.1", "private"),
    ("172.16.9.9", "private"),
    ("169.254.169.254", "link-local"),   # cloud metadata
    ("0.0.0.0", "private"),
    ("::1", "loopback"),
    ("fe80::1", "link-local"),
    ("fc00::1", "private"),               # unique-local
    ("::ffff:127.0.0.1", "loopback"),     # v4-mapped loopback
    ("::ffff:10.0.0.1", "private"),       # v4-mapped private
    ("8.8.8.8", None),                    # public
    ("::ffff:8.8.8.8", None),             # v4-mapped public
    ("2606:4700:4700::1111", None),       # public v6
])
def test_reason_classification(ip, expected):
    assert _reason_disallowed(ipaddress.ip_address(ip)) == expected


# --- literal-IP URLs are blocked without any DNS ---------------------------
@pytest.mark.parametrize("url", [
    "http://127.0.0.1/",
    "http://10.0.0.5/",
    "http://192.168.1.1/",
    "http://172.16.9.9/",
    "http://169.254.169.254/latest/meta-data/",
    "http://0.0.0.0/",
    "http://[::1]/",
    "http://[::ffff:127.0.0.1]/",
    "http://[fe80::1]/",
    "http://[fc00::1]/",
    "http://2130706433/",     # integer form of 127.0.0.1
    "http://0x7f000001/",     # hex form of 127.0.0.1
    "http://user@127.0.0.1/",  # userinfo cannot mask the real host
])
def test_blocks_disallowed_literals(url):
    with pytest.raises(SSRFError):
        _run(assert_url_allowed(url))


@pytest.mark.parametrize("url", [
    "http://8.8.8.8/",
    "http://[::ffff:8.8.8.8]/",
    "http://[2606:4700:4700::1111]/",
])
def test_allows_public_literals(url):
    _run(assert_url_allowed(url))  # must not raise


# --- schemes and malformed hosts -------------------------------------------
@pytest.mark.parametrize("url", [
    "ftp://8.8.8.8/",
    "file:///etc/passwd",
    "gopher://8.8.8.8/",
    "http:///path-only",  # no host
])
def test_blocks_bad_schemes_and_missing_host(url):
    with pytest.raises(SSRFError):
        _run(assert_url_allowed(url))


# --- hostname resolution (mocked resolver) ---------------------------------
def test_allows_public_resolving_host():
    _run(_check_with_resolver("http://public.example/", ["8.8.8.8"]))


def test_blocks_internal_resolving_host():
    with pytest.raises(SSRFError):
        _run(_check_with_resolver("http://sneaky.example/", ["10.1.2.3"]))


def test_blocks_when_any_resolved_address_is_internal():
    # A public + internal A-record set must be rejected: the connection could
    # pick the internal one.
    with pytest.raises(SSRFError):
        _run(_check_with_resolver("http://mixed.example/", ["8.8.8.8", "127.0.0.1"]))


def test_localhost_hostname_blocked_real_dns():
    # Resolves locally to loopback; no external DNS needed.
    with pytest.raises(SSRFError):
        _run(assert_url_allowed("http://localhost/"))


# --- decision cache --------------------------------------------------------
def test_decision_is_cached_within_ttl():
    calls = {"n": 0}

    async def go():
        loop = asyncio.get_running_loop()

        async def counting(host, port, **kwargs):
            calls["n"] += 1
            return [(2, 1, 6, "", ("8.8.8.8", port))]

        with patch.object(loop, "getaddrinfo", counting):
            await assert_url_allowed("http://cached.example/")
            await assert_url_allowed("http://cached.example/")

    _run(go())
    assert calls["n"] == 1  # second call served from cache
