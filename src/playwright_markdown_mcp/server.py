"""Playwright Markdown MCP server.

Fetches URLs through a real Chromium browser (bypassing most Cloudflare
bot challenges and JS-required pages) and returns the main content as
clean Markdown.
"""
from __future__ import annotations

import logging
from typing import Literal

import trafilatura
from fastmcp import FastMCP
from playwright.async_api import (
    TimeoutError as PlaywrightTimeoutError,
    async_playwright,
)

logger = logging.getLogger(__name__)

mcp = FastMCP("playwright-markdown")

WaitUntil = Literal["load", "domcontentloaded", "networkidle", "commit"]


@mcp.tool()
async def fetch_url_as_markdown(
    url: str,
    wait_until: WaitUntil = "load",
    timeout_ms: int = 30000,
) -> str:
    """Fetch a URL through Chromium and return the main content as Markdown.

    Uses Playwright with a real browser, which bypasses most Cloudflare bot
    challenges and renders JavaScript-required pages. The fetched HTML is
    then passed through trafilatura, which strips navigation, ads, sidebars,
    and footers and converts the article body to Markdown.

    Args:
        url: The URL to fetch.
        wait_until: When to consider navigation complete. "load" (default)
            waits for the load event. "domcontentloaded" is faster but may
            miss late-rendered content. "networkidle" waits for network to
            quiet — best for SPAs but slower. "commit" returns as soon as
            the response starts.
        timeout_ms: Navigation timeout in milliseconds. Default 30000.

    Returns:
        The page's main content as Markdown, or a string starting with
        "ERROR:" if the fetch or extraction fails in an expected way
        (timeout, no extractable content, etc.).
    """
    try:
        async with async_playwright() as p:
            browser = await p.chromium.launch(headless=True)
            try:
                context = await browser.new_context()
                page = await context.new_page()
                await page.goto(url, wait_until=wait_until, timeout=timeout_ms)
                html = await page.content()
            finally:
                await browser.close()
    except PlaywrightTimeoutError:
        return f"ERROR: navigation to {url} timed out after {timeout_ms}ms"
    except Exception as exc:
        return f"ERROR: failed to fetch {url}: {exc}"

    md = trafilatura.extract(
        html,
        output_format="markdown",
        include_links=True,
        include_tables=True,
        url=url,
    )
    if not md:
        return f"ERROR: no extractable content found at {url}"
    return md


def main() -> None:
    """Entry point for the playwright-markdown-mcp script."""
    mcp.run()


if __name__ == "__main__":
    main()
