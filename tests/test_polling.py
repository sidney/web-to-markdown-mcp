"""Tests for content-stabilization polling (_poll_until_stable)."""
import time as real_time
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from web_to_markdown_mcp.server import _poll_until_stable


def _time_mock(*monotonic_values):
    """Patch web_to_markdown_mcp.server.time without touching the real time module.

    Patching time.monotonic directly reaches the actual module object and breaks
    asyncio's event loop (which also calls time.monotonic internally). Instead,
    we shadow the 'time' name in the server module's namespace.
    """
    m = MagicMock(wraps=real_time)
    m.monotonic.side_effect = list(monotonic_values)
    return m


async def test_returns_on_first_stable_pair():
    """Two consecutive identical extractions trigger immediate return."""
    page = AsyncMock()
    page.content.return_value = "<html><body><p>content</p></body></html>"

    with patch("trafilatura.extract", side_effect=["Hello", "Hello"]):
        result = await _poll_until_stable(page, "https://example.com/", budget_ms=5000, interval_ms=1)

    assert result == "Hello"
    assert page.content.call_count == 2


async def test_keeps_polling_while_content_changes():
    """Content changes across polls; returns only when stable."""
    page = AsyncMock()
    page.content.return_value = "<html></html>"

    with patch("trafilatura.extract", side_effect=["Hello", "Hello World", "Hello World"]):
        result = await _poll_until_stable(page, "https://example.com/", budget_ms=5000, interval_ms=1)

    assert result == "Hello World"
    assert page.content.call_count == 3


async def test_returns_none_when_budget_exhausted_no_content():
    """Budget expires with every poll returning None."""
    page = AsyncMock()
    page.content.return_value = "<html></html>"

    # monotonic calls: [set deadline, check after first poll]
    with patch("web_to_markdown_mcp.server.time", _time_mock(0.0, 1.0)):
        with patch("trafilatura.extract", return_value=None):
            result = await _poll_until_stable(page, "https://example.com/", budget_ms=5, interval_ms=1)

    assert result is None


async def test_returns_last_content_when_budget_exhausted():
    """Budget expires while content is still changing; returns last extraction."""
    page = AsyncMock()
    page.content.return_value = "<html></html>"

    # monotonic calls: [set deadline, check after poll 1 (not expired), check after poll 2 (expired)]
    with patch("web_to_markdown_mcp.server.time", _time_mock(0.0, 0.0, 1.0)):
        with patch("trafilatura.extract", side_effect=["Hello", "Hello World"]):
            result = await _poll_until_stable(page, "https://example.com/", budget_ms=5, interval_ms=1)

    assert result == "Hello World"


async def test_resolves_after_challenge_clears():
    """None polls (bot challenge in progress) followed by stable content returns that content."""
    page = AsyncMock()
    page.content.return_value = "<html></html>"

    with patch("trafilatura.extract", side_effect=[None, "Real content", "Real content"]):
        result = await _poll_until_stable(page, "https://example.com/", budget_ms=5000, interval_ms=1)

    assert result == "Real content"
    assert page.content.call_count == 3
