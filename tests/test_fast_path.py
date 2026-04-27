"""Tests for the Accept: text/markdown fast-path (_try_native_markdown)."""
import httpx
import pytest
import respx

from web_to_markdown_mcp.server import _ACCEPT_HEADER, _try_native_markdown


async def test_returns_body_on_text_markdown():
    with respx.mock:
        respx.get("https://example.com/").mock(
            return_value=httpx.Response(200, text="# Hello", headers={"content-type": "text/markdown"})
        )
        result = await _try_native_markdown("https://example.com/")
    assert result == "# Hello"


async def test_returns_body_on_text_markdown_with_charset():
    with respx.mock:
        respx.get("https://example.com/").mock(
            return_value=httpx.Response(
                200, text="# Hello", headers={"content-type": "text/markdown; charset=utf-8"}
            )
        )
        result = await _try_native_markdown("https://example.com/")
    assert result == "# Hello"


async def test_returns_none_on_html_response():
    with respx.mock:
        respx.get("https://example.com/").mock(
            return_value=httpx.Response(200, text="<html></html>", headers={"content-type": "text/html"})
        )
        result = await _try_native_markdown("https://example.com/")
    assert result is None


async def test_returns_none_on_404():
    with respx.mock:
        respx.get("https://example.com/").mock(return_value=httpx.Response(404))
        result = await _try_native_markdown("https://example.com/")
    assert result is None


async def test_returns_none_on_500():
    with respx.mock:
        respx.get("https://example.com/").mock(return_value=httpx.Response(500))
        result = await _try_native_markdown("https://example.com/")
    assert result is None


async def test_returns_none_on_connection_error():
    with respx.mock:
        respx.get("https://example.com/").mock(side_effect=httpx.ConnectError("refused"))
        result = await _try_native_markdown("https://example.com/")
    assert result is None


async def test_returns_none_on_timeout():
    with respx.mock:
        respx.get("https://example.com/").mock(side_effect=httpx.TimeoutException("timed out"))
        result = await _try_native_markdown("https://example.com/")
    assert result is None


async def test_sends_correct_accept_header():
    with respx.mock:
        route = respx.get("https://example.com/").mock(
            return_value=httpx.Response(200, text="# Hello", headers={"content-type": "text/markdown"})
        )
        await _try_native_markdown("https://example.com/")
    assert route.calls[0].request.headers["accept"] == _ACCEPT_HEADER
