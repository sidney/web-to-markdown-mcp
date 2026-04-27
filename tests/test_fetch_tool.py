"""Tests for the fetch_url_as_markdown MCP tool."""
from unittest.mock import AsyncMock, patch

import pytest
from patchright.async_api import TimeoutError as PlaywrightTimeoutError

from web_to_markdown_mcp.server import fetch_url_as_markdown


def _browser_mock(page_mock=None):
    """Build a mock browser with a connected context/page chain."""
    if page_mock is None:
        page_mock = AsyncMock()
    context = AsyncMock()
    context.new_page.return_value = page_mock
    browser = AsyncMock()
    browser.new_context.return_value = context
    browser.is_connected.return_value = True
    return browser, page_mock


async def test_fast_path_skips_browser():
    """When native markdown is available, the browser is never called."""
    with patch("web_to_markdown_mcp.server._try_native_markdown", return_value="# Native"):
        with patch("web_to_markdown_mcp.server._get_headless_browser") as mock_browser:
            result = await fetch_url_as_markdown("https://example.com/")

    assert result == "# Native"
    mock_browser.assert_not_called()


async def test_falls_back_to_browser_and_returns_polled_content():
    """Fast-path miss triggers browser fetch; poll result is returned."""
    browser, _ = _browser_mock()

    with patch("web_to_markdown_mcp.server._try_native_markdown", return_value=None):
        with patch("web_to_markdown_mcp.server._get_headless_browser", new=AsyncMock(return_value=browser)):
            with patch("web_to_markdown_mcp.server._poll_until_stable", return_value="# Browser"):
                result = await fetch_url_as_markdown("https://example.com/")

    assert result == "# Browser"


async def test_returns_error_on_navigation_timeout():
    """PlaywrightTimeoutError from page.goto is caught and returned as ERROR string."""
    page = AsyncMock()
    page.goto.side_effect = PlaywrightTimeoutError("navigation timed out")
    browser, _ = _browser_mock(page_mock=page)

    with patch("web_to_markdown_mcp.server._try_native_markdown", return_value=None):
        with patch("web_to_markdown_mcp.server._get_headless_browser", new=AsyncMock(return_value=browser)):
            result = await fetch_url_as_markdown("https://example.com/", timeout_ms=30000)

    assert result.startswith("ERROR:")
    assert "timed out" in result
    assert "30000" in result


async def test_returns_error_on_unexpected_exception():
    """Generic exceptions from the browser pipeline are caught and returned as ERROR strings."""
    page = AsyncMock()
    page.goto.side_effect = RuntimeError("something broke")
    browser, _ = _browser_mock(page_mock=page)

    with patch("web_to_markdown_mcp.server._try_native_markdown", return_value=None):
        with patch("web_to_markdown_mcp.server._get_headless_browser", new=AsyncMock(return_value=browser)):
            result = await fetch_url_as_markdown("https://example.com/")

    assert result.startswith("ERROR:")
    assert "something broke" in result


async def test_returns_error_when_no_extractable_content():
    """When polling yields nothing, returns an ERROR string mentioning the URL."""
    browser, _ = _browser_mock()

    with patch("web_to_markdown_mcp.server._try_native_markdown", return_value=None):
        with patch("web_to_markdown_mcp.server._get_headless_browser", new=AsyncMock(return_value=browser)):
            with patch("web_to_markdown_mcp.server._poll_until_stable", return_value=None):
                result = await fetch_url_as_markdown("https://example.com/")

    assert result.startswith("ERROR:")
    assert "no extractable content" in result
