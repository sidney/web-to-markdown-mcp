"""Tests for the HTTP fast-path tiers (_try_http)."""
import httpx
import pytest
import respx

from web_to_markdown_mcp.server import _ACCEPT_HEADER, _try_http


# --- Tier 1: native text/markdown ---

async def test_returns_body_on_text_markdown():
    with respx.mock:
        respx.get("https://example.com/").mock(
            return_value=httpx.Response(200, text="# Hello", headers={"content-type": "text/markdown"})
        )
        result = await _try_http("https://example.com/")
    assert result == "# Hello"


async def test_returns_body_on_text_markdown_with_charset():
    with respx.mock:
        respx.get("https://example.com/").mock(
            return_value=httpx.Response(
                200, text="# Hello", headers={"content-type": "text/markdown; charset=utf-8"}
            )
        )
        result = await _try_http("https://example.com/")
    assert result == "# Hello"


# --- Tier 2: trafilatura extraction from plain HTML ---

async def test_returns_extracted_markdown_from_html():
    html = "<html><body><article><p>Hello world, this is real content.</p></article></body></html>"
    with respx.mock:
        respx.get("https://example.com/").mock(
            return_value=httpx.Response(200, text=html, headers={"content-type": "text/html"})
        )
        result = await _try_http("https://example.com/")
    assert result is not None
    assert "Hello world" in result


async def test_returns_none_when_trafilatura_finds_nothing():
    html = "<html><body><script>app.render()</script></body></html>"
    with respx.mock:
        respx.get("https://example.com/").mock(
            return_value=httpx.Response(200, text=html, headers={"content-type": "text/html"})
        )
        result = await _try_http("https://example.com/")
    assert result is None


async def test_returns_none_for_js_shell_with_sparse_extraction():
    """Large HTML with tiny extracted content (JS SPA stub) falls through to browser."""
    stub_text = "You need to enable JavaScript to run this app."
    script_tags = "<script src='chunk.js'></script>" * 200
    large_html = f"<html><head>{script_tags}</head><body><div id='root'><p>{stub_text}</p></div></body></html>"
    with respx.mock:
        respx.get("https://example.com/").mock(
            return_value=httpx.Response(200, text=large_html, headers={"content-type": "text/html"})
        )
        result = await _try_http("https://example.com/")
    assert result is None


async def test_returns_short_extraction_from_small_html():
    """Short extracted content from small HTML (e.g. example.com) is kept, not discarded."""
    short_html = "<html><body><p>" + "Real content. " * 5 + "</p></body></html>"
    with respx.mock:
        respx.get("https://example.com/").mock(
            return_value=httpx.Response(200, text=short_html, headers={"content-type": "text/html"})
        )
        result = await _try_http("https://example.com/")
    # Small raw HTML means the short extraction is credible, not a JS stub
    assert result is not None


# --- Error cases ---

async def test_returns_none_on_404():
    with respx.mock:
        respx.get("https://example.com/").mock(return_value=httpx.Response(404))
        result = await _try_http("https://example.com/")
    assert result is None


async def test_returns_none_on_500():
    with respx.mock:
        respx.get("https://example.com/").mock(return_value=httpx.Response(500))
        result = await _try_http("https://example.com/")
    assert result is None


async def test_returns_none_on_connection_error():
    with respx.mock:
        respx.get("https://example.com/").mock(side_effect=httpx.ConnectError("refused"))
        result = await _try_http("https://example.com/")
    assert result is None


async def test_returns_none_on_timeout():
    with respx.mock:
        respx.get("https://example.com/").mock(side_effect=httpx.TimeoutException("timed out"))
        result = await _try_http("https://example.com/")
    assert result is None


async def test_sends_correct_accept_header():
    with respx.mock:
        route = respx.get("https://example.com/").mock(
            return_value=httpx.Response(200, text="# Hello", headers={"content-type": "text/markdown"})
        )
        await _try_http("https://example.com/")
    assert route.calls[0].request.headers["accept"] == _ACCEPT_HEADER
