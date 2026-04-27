# Changelog

## v0.6.0 (2026-04-28)

### Added
- Three-tier fetch strategy: native markdown fast-path → plain HTTP + trafilatura → headless browser. Most pages with static HTML content no longer require a browser at all.
- Persistent headless browser instance: Chromium launches lazily on the first browser-tier fetch and stays alive for the session. Subsequent browser-tier fetches pay only navigation time, not the ~2–5 s cold-start cost.
- JS shell detection heuristics: pages returning a "JavaScript required" stub are detected and routed to the browser tier rather than returning the stub as content. Two signals are used — sparse extraction relative to large raw HTML, and the presence of "javascript" in a short extraction.

### Changed
- Headed (`headless=False`) fetches remain one-off: a temporary browser is launched and closed per fetch. Headed mode is an infrequent escape hatch, not the common case, so it is not kept persistent.

## v0.5.1 (2026-04-27)

### Changed
- Added MCP registry verification string to README (required for registry submission).

## v0.5.0 (2026-04-27)

### Changed
- Renamed from `playwright-markdown-mcp` to `web-to-markdown-mcp`. Tool name (`fetch_url_as_markdown`) unchanged.
- Added GitHub Actions workflow for automated PyPI publishing via Trusted Publishers.
- Published to PyPI (`uvx web-to-markdown-mcp` now works for outside users).
- Registered on the [MCP registry](https://registry.modelcontextprotocol.io).

### Added
- `Accept: text/markdown` fast-path: if the server responds with `Content-Type: text/markdown` (e.g. Cloudflare Markdown for Agents), the body is returned immediately with no browser overhead.
- Unit test suite covering fast-path, content-stabilization polling, and the fetch tool.

## v0.4.0

### Added
- Content-stabilization polling: after navigation, polls the DOM and runs trafilatura, returning as soon as two consecutive polls produce the same extraction. Faster return for typical pages; more robust on slow SPAs and bot-challenge pages.

### Changed
- Default `wait_until` changed from `"load"` to `"domcontentloaded"` — polling handles the rest.
- Default `timeout_ms` raised from 30000 to 60000.

## v0.3.0

### Added
- `headless` parameter (default `true`): pass `false` to use a visible browser window for sites that block headless mode.

## v0.2.0

### Changed
- Switched from vanilla Playwright to [patchright](https://github.com/Kaliiiiiiiiii-Vinyzu/patchright) for anti-detection patches. Headless mode now passes Cloudflare bot detection on many sites that blocked vanilla headless Chromium.

## v0.1.0

Initial release. FastMCP server with a single `fetch_url_as_markdown` tool. Playwright + trafilatura, MIT licensed.
