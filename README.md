# playwright-markdown-mcp

An [MCP](https://modelcontextprotocol.io) server that fetches a URL through a real Chromium browser and returns the main content as clean Markdown.

## Why

Most MCP web-fetch tools either:

- use plain HTTP, which fails on JS-required pages and gets blocked by Cloudflare bot detection on many sites; or
- use a real browser but return raw HTML or accessibility-tree snapshots, which are noisy and token-heavy when you just want to read the article.

This server uses Playwright (real Chromium) to load the page — bypassing most Cloudflare WAF challenges and rendering JS-heavy pages — and then [trafilatura](https://trafilatura.readthedocs.io) to strip navigation, sidebars, ads, and footers down to the article body, returning clean Markdown.

For a typical article, expect roughly 80% fewer tokens than the raw HTML and roughly 90% fewer than a full accessibility-tree snapshot.

## Installation

Requires Python 3.10+ and a one-time Chromium download (~300 MB).

```bash
# Run directly with uv (no install step)
uvx playwright-markdown-mcp

# Or install with pip
pip install playwright-markdown-mcp

# One-time browser download
playwright install chromium
```

## MCP client configuration

### Claude Desktop

Edit your config file:

- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`

```json
{
  "mcpServers": {
    "playwright-markdown": {
      "command": "uvx",
      "args": ["playwright-markdown-mcp"]
    }
  }
}
```

Restart Claude Desktop.

### LM Studio

Edit `~/.lmstudio/mcp.json` (Developer tab → Edit mcp.json) — same JSON block as above. Then enable **Allow calling servers from mcp.json** in the Developer tab's Server Settings. The server appears in the Integrations tab of any new chat.

### Cursor / Windsurf / VS Code

Same JSON block, in each client's MCP config location.

### Claude Code

```bash
claude mcp add playwright-markdown -- uvx playwright-markdown-mcp
```

## Usage

The server exposes a single tool:

### `fetch_url_as_markdown`

| Parameter    | Type   | Default  | Description                                                                 |
|--------------|--------|----------|-----------------------------------------------------------------------------|
| `url`        | string | required | The URL to fetch                                                            |
| `wait_until` | string | `"load"` | `"load"`, `"domcontentloaded"`, `"networkidle"`, or `"commit"`              |
| `timeout_ms` | int    | `30000`  | Navigation timeout in milliseconds                                          |

**Returns** Markdown as a string, or a string beginning with `"ERROR:"` on expected failures (timeout, no extractable content, navigation error).

**Example call** (from any MCP client's tool-use UI):

```
fetch_url_as_markdown(url="https://example.com/long-article")
```

`wait_until` choice:

- `"load"` (default) — waits for the load event, suitable for most pages
- `"domcontentloaded"` — faster, but may miss late-rendered content
- `"networkidle"` — waits for network to quiet, best for SPAs, slower
- `"commit"` — returns as soon as the response starts, rarely what you want

## Limitations

- **Cold start.** Each call launches a fresh Chromium (~1–2 s overhead). A persistent browser instance is on the v2 roadmap.
- **Datacenter IPs.** Cloudflare's harder challenges still block requests from datacenter IPs (Oracle Cloud, AWS, etc.) even with a real browser. Best results come from running this on a residential connection.
- **Heavy SPAs.** Pages that render content well after `load` may need `wait_until="networkidle"`.
- **Auth-walled content.** This server uses a clean browser context with no cookies or stored auth. Logged-in pages won't work.

## Comparison with related tools

- **[`@playwright/mcp`](https://github.com/microsoft/playwright-mcp)** (Microsoft) — general-purpose interactive browser automation: navigate, click, fill forms, run JS, take accessibility snapshots. Use it when you need to *interact* with a page. Use this server when you need to *read* a page.
- **`mcp-server-fetch`** and similar HTTP-based servers — faster and lighter, but get blocked by Cloudflare and don't render JS. Try those first for compliant sites; reach for this one when they fail.
- **LM Studio Hub plugins** like `vadimfedenko/visit-website-reworked` and `npacker/web-tools` — same idea inside LM Studio's plugin system. This server runs in any MCP client.

## Roadmap

- [ ] Persistent browser instance to amortize cold start
- [ ] `Accept: text/markdown` fast path for [Cloudflare's Markdown for Agents](https://blog.cloudflare.com/introducing-markdown-for-agents/)
- [ ] Optional `selector` parameter to scope extraction
- [ ] Optional viewport, user-agent, and locale overrides
- [ ] Optional persistent browser context for sticky cookies / WAF trust

## Contributing

Issues and PRs welcome. For substantive changes, please open an issue first to discuss the approach.

## License

MIT — see [LICENSE](LICENSE).
