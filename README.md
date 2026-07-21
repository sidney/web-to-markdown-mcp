# web-to-markdown-mcp
<!-- mcp-name: io.github.sidney/web-to-markdown-mcp -->

An [MCP](https://modelcontextprotocol.io) server that fetches a URL and returns the main content as clean Markdown. Uses plain HTTP when possible and real Chromium when needed.

## Why

Most MCP web-fetch tools either:

- use plain HTTP, which fails on JS-required pages and gets blocked by Cloudflare bot detection on many sites; or
- use a real browser but return raw HTML or accessibility-tree snapshots, which are noisy and token-heavy when you just want to read the article.

This server uses a three-tier strategy, using the fastest approach that works for each URL:

1. **Native markdown fast-path.** Every request first tries a plain HTTP GET with an `Accept: text/markdown` header. Servers that support content negotiation — such as Cloudflare-hosted sites with [Markdown for Agents](https://developers.cloudflare.com/fundamentals/reference/markdown-for-agents/) enabled — respond with `Content-Type: text/markdown`, and the body is returned immediately with no browser overhead.

2. **Plain HTTP + extraction.** If the server returns HTML, [trafilatura](https://trafilatura.readthedocs.io) extracts the article body as clean Markdown directly from the static response. Heuristics detect JS shells — pages that return only a "JavaScript required" stub in the static HTML — and fall through to tier 3 for those.

3. **Headless browser.** When tiers 1 and 2 yield nothing usable, [patchright](https://github.com/Kaliiiiiiiiii-Vinyzu/patchright) (a Playwright fork with anti-detection patches) drives real Chromium and trafilatura extracts the rendered content. A single headless browser instance is kept alive across calls — it launches lazily on the first browser-tier fetch and stays running for the session, so subsequent fetches pay only navigation time rather than Chromium startup cost (~2–5 s).

For sites that block even headless patchright (aggressive bot detection), pass `headless=False`. This uses a visible Chromium window — slower and visually intrusive, but clears most remaining challenges. A headed browser is launched and closed for each fetch that needs it; it is not kept persistent since headed fetches are an infrequent escape hatch rather than the common case.

After browser navigation, the server polls the DOM and runs trafilatura, returning as soon as two consecutive polls produce the same extraction. This means it returns within a few hundred milliseconds for typical pages — rather than waiting for analytics, ads, and other late-loading resources to finish — and gives slow SPAs and bot-challenge clearance time to settle without timing out prematurely.

For a typical article, expect roughly 80% fewer tokens than the raw HTML and roughly 90% fewer than a full accessibility-tree snapshot.

## Installation

Requires Python 3.10+ and a one-time Chromium download (~300 MB).

```bash
# Run directly with uv (no install step)
uvx web-to-markdown-mcp

# Or install with pip
pip install web-to-markdown-mcp

# One-time browser download
patchright install chromium
```

## MCP client configuration

### Claude Desktop

Edit your config file:

- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`

```json
{
  "mcpServers": {
    "web-to-markdown": {
      "command": "uvx",
      "args": ["web-to-markdown-mcp"]
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
claude mcp add web-to-markdown -- uvx web-to-markdown-mcp
```

## Usage

The server exposes a single tool:

### `fetch_url_as_markdown`

| Parameter            | Type   | Default              | Description                                                                              |
|----------------------|--------|----------------------|------------------------------------------------------------------------------------------|
| `url`                | string | required             | The URL to fetch                                                                         |
| `wait_until`         | string | `"domcontentloaded"` | When navigation completes: `"load"`, `"domcontentloaded"`, `"networkidle"`, `"commit"`   |
| `timeout_ms`         | int    | `60000`              | Navigation-step timeout in milliseconds                                                  |
| `headless`           | bool   | `true`               | `false` uses a visible browser window — slower but clears more bot detection             |
| `poll_budget_ms`     | int    | `5000`               | Max time after navigation to wait for content stabilization                              |
| `poll_interval_ms`   | int    | `250`                | How often to re-attempt extraction during polling                                        |

**Returns** Markdown as a string, or a string beginning with `"ERROR:"` on expected failures (timeout, no extractable content, navigation error).

**Example call** (from any MCP client's tool-use UI):

```
fetch_url_as_markdown(url="https://example.com/long-article")
```

`wait_until` choice:

- `"domcontentloaded"` (default) — returns when the DOM is built; content-stabilization polling handles the rest
- `"load"` — waits for all subresources (images, scripts, stylesheets); rarely needed since polling runs after this
- `"networkidle"` — waits for network to quiet; sometimes hangs on pages with persistent background connections
- `"commit"` — returns as soon as the response starts; rarely useful

**When to bump `poll_budget_ms`:** the 5-second default is fine for typical pages but may return a partial extraction on slow SPAs that render content over many seconds, and may time out before a bot-detection challenge clears in headed mode. For headed-mode fetches of bot-protected sites, 10000-30000 is a reasonable budget.

## Limitations

- **First browser-tier fetch per session.** The headless browser launches lazily on the first fetch that needs it (~2–5 s). Subsequent browser-tier fetches in the same session reuse the running instance and pay only navigation time.
- **Bot detection on hard sites.** patchright headless clears default Cloudflare configurations on many sites, but pages running aggressive Bot Fight Mode, Turnstile interactive challenges, or commercial bot-management products (PerimeterX, DataDome, Kasada) — and Cloudflare's own marketing site — still detect headless Chromium. Pass `headless=False` to use a visible browser window, which clears most of these. The cost is a Chromium window flashing on screen for a couple of seconds per fetch.
- **Headed-mode bot challenges need a generous polling budget.** When using `headless=False` on bot-protected sites, the challenge can take 5-15 seconds to clear. Set `poll_budget_ms` to 10000-15000 for these cases — the 5000 default may return prematurely while the challenge is still resolving.
- **Headed mode requires a display.** `headless=False` fails on servers without a graphical environment (cloud VMs, containers, CI). Use a virtual display like Xvfb if you need headed mode in those environments.
- **Datacenter IPs.** Cloudflare's harder challenges still block requests from datacenter IPs (Oracle Cloud, AWS, etc.) regardless of browser fingerprint or headed/headless mode. Best results come from running this on a residential connection.
- **Slow SPA rendering.** For pages that progressively render content over many seconds, bump `poll_budget_ms`. The default returns the most-recent extraction at budget expiry, which on a still-rendering SPA may be partial.
- **Auth-walled content.** This server uses a clean browser context with no cookies or stored auth. Logged-in pages won't work.

## Comparison with related tools

- **[`@playwright/mcp`](https://github.com/microsoft/playwright-mcp)** (Microsoft) — general-purpose interactive browser automation: navigate, click, fill forms, run JS, take accessibility snapshots. Use it when you need to *interact* with a page. Use this server when you need to *read* a page.
- **`mcp-server-fetch`** and similar HTTP-based servers — also try plain HTTP first, so for static sites the behaviour is similar. The difference is JS-rendered pages and bot-protected sites: those tools don't have a browser fallback, so they fail where this server succeeds.
- **LM Studio Hub plugins** like `vadimfedenko/visit-website-reworked` and `npacker/web-tools` — same idea inside LM Studio's plugin system. This server runs in any MCP client.

## Roadmap

- [x] Persistent headless browser instance to amortize cold start
- [x] `Accept: text/markdown` fast path for [Cloudflare's Markdown for Agents](https://blog.cloudflare.com/introducing-markdown-for-agents/)
- [ ] Optional `selector` parameter to scope extraction
- [ ] Optional viewport, user-agent, and locale overrides
- [ ] Optional persistent browser context for sticky cookies / WAF trust
- [ ] `channel="chrome"` option to use installed Google Chrome instead of bundled Chromium (further stealth for the hardest sites)

## Contributing

Issues and PRs welcome. For substantive changes, please open an issue first to discuss the approach.

## License

MIT — see [LICENSE](LICENSE).
