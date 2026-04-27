"""web-to-markdown-mcp server.

Fetches URLs and returns the main content as clean Markdown. Tries an
HTTP content-negotiation fast-path first (Accept: text/markdown); falls
back to real Chromium via patchright for JS-heavy and bot-protected pages.
"""
from __future__ import annotations

import asyncio
import logging
import time
from contextlib import asynccontextmanager
from typing import Literal

import httpx
import trafilatura
from fastmcp import FastMCP
from patchright.async_api import (
    Browser,
    Page,
    TimeoutError as PlaywrightTimeoutError,
    async_playwright,
)

logger = logging.getLogger(__name__)

WaitUntil = Literal["load", "domcontentloaded", "networkidle", "commit"]

_ACCEPT_HEADER = "text/markdown, text/html;q=0.9, */*;q=0.8"
_FAST_PATH_TIMEOUT = 10.0

_playwright_instance = None
_headless_browser: Browser | None = None
_browser_lock = asyncio.Lock()


async def _get_headless_browser() -> Browser:
    """Return the shared headless browser, launching it if needed or if it has crashed."""
    global _playwright_instance, _headless_browser
    async with _browser_lock:
        if _headless_browser is None or not _headless_browser.is_connected():
            if _playwright_instance is not None:
                try:
                    await _playwright_instance.stop()
                except Exception:
                    pass
            _playwright_instance = await async_playwright().start()
            _headless_browser = await _playwright_instance.chromium.launch(headless=True)
    return _headless_browser


@asynccontextmanager
async def _lifespan(server: FastMCP):
    yield
    global _playwright_instance, _headless_browser
    if _headless_browser is not None:
        try:
            await _headless_browser.close()
        except Exception:
            pass
    if _playwright_instance is not None:
        try:
            await _playwright_instance.stop()
        except Exception:
            pass


mcp = FastMCP("web-to-markdown", lifespan=_lifespan)


@mcp.tool()
async def fetch_url_as_markdown(
    url: str,
    wait_until: WaitUntil = "domcontentloaded",
    timeout_ms: int = 60000,
    headless: bool = True,
    poll_budget_ms: int = 5000,
    poll_interval_ms: int = 250,
) -> str:
    """Fetch a URL and return the main content as Markdown.

    First tries a plain HTTP request with an Accept: text/markdown header.
    If the server responds with Content-Type: text/markdown (e.g. Cloudflare
    Markdown for Agents sites), the body is returned immediately without
    launching a browser.

    Otherwise, uses patchright (a Playwright fork with anti-detection
    patches) to drive real Chromium, which clears most Cloudflare bot
    challenges and renders JavaScript-required pages. A single headless
    Chromium instance is kept alive across calls so subsequent fetches
    avoid the browser cold-start cost (~2-5s). After navigation, polls
    the page DOM and runs trafilatura, returning as soon as the extracted
    Markdown stabilizes across two consecutive polls — typically within a
    few hundred milliseconds of the DOM being built, regardless of whether
    trackers, ads, and analytics are still loading in the background.

    Args:
        url: The URL to fetch.
        wait_until: When the navigation step is considered complete.
            "domcontentloaded" (default) returns when the HTML is parsed
            and the DOM is built. "load" waits for all subresources
            (images, scripts, stylesheets) — slower and rarely needed
            since content-stabilization polling runs after this.
            "networkidle" waits for network to quiet — best for SPAs but
            sometimes hangs on pages with persistent connections.
            "commit" returns as soon as the response starts.
        timeout_ms: Navigation timeout in milliseconds. Default 60000.
            This is the budget for the navigation step only; content
            extraction has its own separate budget (poll_budget_ms).
        headless: Whether to run Chromium headless. Default True. Set to
            False to use a visible browser window — slower and pops a
            Chromium window on screen, but clears bot-detection challenges
            (Cloudflare, etc.) that block headless mode. If a fetch returns
            "ERROR: navigation timed out" or "ERROR: no extractable content"
            on a site that likely has bot protection, retry with
            headless=False. Requires a display, so headless=False fails on
            servers without a graphical environment unless a virtual
            display like Xvfb is configured.
        poll_budget_ms: Maximum time after navigation to wait for content
            extraction to stabilize. Default 5000. Increase for slow SPAs
            that progressively render content over many seconds, or when
            using headless=False on bot-protected sites where the
            challenge takes time to resolve — 10000-15000 is reasonable
            for the latter.
        poll_interval_ms: How often to re-attempt extraction during
            polling. Default 250.

    Returns:
        The page's main content as Markdown, or a string starting with
        "ERROR:" if the fetch or extraction fails in an expected way
        (timeout, no extractable content, etc.).
    """
    md = await _try_native_markdown(url)
    if md is not None:
        return md

    try:
        md = await _browser_fetch(
            url, wait_until, timeout_ms, headless, poll_budget_ms, poll_interval_ms
        )
    except PlaywrightTimeoutError:
        return f"ERROR: navigation to {url} timed out after {timeout_ms}ms"
    except Exception as exc:
        return f"ERROR: failed to fetch {url}: {exc}"

    if not md:
        return f"ERROR: no extractable content found at {url}"
    return md


async def _browser_fetch(
    url: str,
    wait_until: WaitUntil,
    timeout_ms: int,
    headless: bool,
    poll_budget_ms: int,
    poll_interval_ms: int,
) -> str | None:
    if headless:
        browser = await _get_headless_browser()
        context = await browser.new_context()
        try:
            page = await context.new_page()
            await page.goto(url, wait_until=wait_until, timeout=timeout_ms)
            return await _poll_until_stable(page, url, poll_budget_ms, poll_interval_ms)
        finally:
            await context.close()
    else:
        async with async_playwright() as p:
            browser = await p.chromium.launch(headless=False)
            try:
                context = await browser.new_context()
                page = await context.new_page()
                await page.goto(url, wait_until=wait_until, timeout=timeout_ms)
                return await _poll_until_stable(page, url, poll_budget_ms, poll_interval_ms)
            finally:
                await browser.close()


async def _try_native_markdown(url: str) -> str | None:
    """Return the body if the server responds with Content-Type: text/markdown, else None.

    Sends an Accept header advertising markdown preference. Servers that
    don't support content negotiation ignore it and respond normally, so
    this is fully backwards-compatible. Any error silently falls through to
    the browser pipeline.
    """
    try:
        async with httpx.AsyncClient(follow_redirects=True) as client:
            r = await client.get(
                url,
                headers={"Accept": _ACCEPT_HEADER},
                timeout=_FAST_PATH_TIMEOUT,
            )
        if (
            r.is_success
            and r.headers.get("content-type", "").split(";", 1)[0].strip().lower()
            == "text/markdown"
        ):
            logger.debug("fast-path: native markdown from %s", url)
            return r.text
    except Exception:
        pass
    return None


async def _poll_until_stable(
    page: Page,
    url: str,
    budget_ms: int,
    interval_ms: int,
) -> str | None:
    """Poll the page DOM and run trafilatura, returning as soon as the
    extraction stabilizes across two consecutive polls. Returns None if
    the budget exhausts without producing stable non-empty content.

    The "two consecutive identical extractions" rule handles three cases
    naturally:

    - Bot challenges return some extractable text but it's the challenge
      page; we keep polling until the challenge resolves and the real
      article DOM appears.
    - Progressively rendered SPAs return growing content across polls;
      we keep polling until content stops growing.
    - Truly empty pages (404, paywall, image-only) return None on every
      poll; we time out and surface "no extractable content".

    Future enhancement (Option B): if extraction returns None for the
    first few polls, that's likely a bot challenge in progress, and the
    budget could be auto-extended on the first non-None extraction. Not
    implemented now because explicit poll_budget_ms keeps the behavior
    predictable; if user experience reveals that callers consistently
    need to bump poll_budget_ms for bot-protected sites, this is the
    cleanest place to add adaptive behavior.
    """
    deadline = time.monotonic() + budget_ms / 1000.0
    interval = interval_ms / 1000.0
    last_md: str | None = None

    while True:
        html = await page.content()
        md = trafilatura.extract(
            html,
            output_format="markdown",
            include_links=True,
            include_tables=True,
            url=url,
        )

        # Content has stabilized when this poll produces non-empty content
        # that matches the previous poll exactly.
        if md and md == last_md:
            return md

        if time.monotonic() >= deadline:
            # Budget exhausted; return whatever we have (may be None).
            return md

        last_md = md
        await asyncio.sleep(interval)


def main() -> None:
    """Entry point for the web-to-markdown-mcp script."""
    mcp.run()


if __name__ == "__main__":
    main()
