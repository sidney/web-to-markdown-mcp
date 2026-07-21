# Security & design notes

This documents the security-relevant design of web-to-markdown-mcp: what the
threats are, how the code defends against them, what is deliberately left
open, and the operational knobs that affect the tradeoffs. Read this before
changing the fetch path (`server.py`), the SSRF guard (`_ssrf.py`), or the
HTTP entrypoint (`serve_http.py`).

## Threat model

The server fetches arbitrary URLs and returns their rendered content. Two
properties make that dangerous:

1. **It is general-purpose** — there is no domain allowlist. Any URL the
   caller supplies (or any URL a fetched page redirects to) gets fetched.
2. **It is exposed as a network service** — `serve_http.py` runs it behind a
   Cloudflare tunnel so the mobile client can reach it. Anyone who reaches
   the endpoint can ask it to fetch things *from where the server sits*.

Together these create a Server-Side Request Forgery (SSRF) risk: without a
control, the server could be used to reach internal services, other hosts on
the box's network, or the cloud metadata endpoint (`169.254.169.254`), and
return their contents. On the deploy box the server also has egress through a
VPN, so it is additionally a potential open proxy.

Two controls address these:

- The **`?key=` gate** (`serve_http.py`) is the sole authentication. The
  mobile MCP client cannot send custom headers, so the key rides in the query
  string. This is what stops the endpoint being an open proxy.
- The **SSRF IP denylist** (`_ssrf.py`) is what stops the fetcher reaching
  internal/link-local/loopback targets regardless of who is authenticated.
  It is load-bearing precisely *because* there is no domain allowlist.

## The SSRF guard runs at three depths

One check at the entrypoint is not enough, because redirects and the browser
introduce hops the entrypoint never sees. The guard therefore runs in three
places (all in `server.py`, guard logic in `_ssrf.py`):

1. **Tool input** — `fetch_url_as_markdown` calls `assert_url_allowed(url)`
   before any network activity. Rejects non-http(s) schemes and hosts that
   resolve to a disallowed address.
2. **httpx tier, every redirect hop** — the fast-path client runs with
   `follow_redirects=False`; `_guarded_get` follows redirects manually and
   re-checks each hop, so a 302 into an internal IP raises instead of being
   followed.
3. **Browser tier, every request** — `_guard_route` is installed via
   `page.route("**/*", ...)` and vets the navigation, browser-driven
   redirects, and subresources. These are the hops httpx can't see once
   Chromium is driving.

What the guard classifies as disallowed (`_ssrf._reason_disallowed`):
loopback, link-local (includes the `169.254.169.254` metadata IP), private
(RFC1918 + ULA), reserved, multicast, and unspecified. It unwraps IPv4-mapped,
6to4, and Teredo IPv6 to classify the embedded IPv4, and parses integer/hex IP
literals (`http://2130706433/`) that would otherwise bypass dotted-quad checks.
If a host resolves to multiple addresses and *any* one is disallowed, the URL
is rejected.

## HTTP auth model (`serve_http.py`)

- **Key gate**: `?key=` compared in constant time against a key file (one key
  per line). The file is re-read when its mtime changes, so keys **rotate
  without a restart** — add a new line, switch the connector URL, remove the
  old line.
- **Fail closed**: a missing or empty key file means every request is 401.
- **Rate limit**: per-IP token bucket (real client IP taken from
  `cf-connecting-ip` behind the tunnel).
- **Log scrubbing**: uvicorn access logging is off and a logging filter
  rewrites `key=…` to `key=REDACTED`. Note this only controls *our* process —
  **cloudflared can log the query string itself**, so check its logging config
  on the box; the key gate's secrecy depends on it too.
- **Host/origin protection**: FastMCP's HTTP transport rejects requests whose
  `Host` isn't allow-listed. `WTM_ALLOWED_HOSTS` must include the tunnel
  hostname on deploy or every request 400s — the classic "works on localhost,
  breaks behind the tunnel" trap.
- **Streaming safety**: the gate is pure ASGI, not Starlette
  `BaseHTTPMiddleware`, which would buffer and break the streamable-HTTP event
  stream. It forwards `lifespan`/`websocket` scopes untouched — load-bearing,
  because FastMCP's session manager raises "task group not initialized" on
  every request if its lifespan doesn't run.

## Operational notes (tunables)

| Env var | Default | Effect |
| --- | --- | --- |
| `WTM_BROWSER_CONCURRENCY` | `1` | Size of `_fetch_semaphore`. One headless page at a time bounds RAM/CPU on the 2-vCPU box. Tiers 1–2 (httpx) stay concurrent. |
| `WTM_SSRF_CACHE_TTL` | `60` | Seconds the guard caches a host's allow/deny decision. Higher = fewer DNS lookups but a wider DNS-rebinding window (see residuals). Set `0` to check every request. |
| `WTM_ALLOWED_HOSTS` | `127.0.0.1,localhost` | Host/origin allowlist. Add the tunnel hostname on deploy. |
| `WTM_RATE_CAPACITY` / `WTM_RATE_REFILL` | `20` / `0.5` | Token-bucket burst / refill-per-second. |

**`page.route("**/*")` overhead**: routing every subresource through Python
adds latency on heavy tier-3 pages. If it bites, narrow the route pattern to
document/navigation requests. The tradeoff: subresource requests to internal
IPs would then go unguarded — acceptable for content extraction, since
subresource response bytes are never returned to the caller (only the main
document is extracted), but it does reopen blind-SSRF probing via subresources.

## Known residuals (deliberately open)

- **DNS rebinding (TOCTOU)**: the guard resolves and vets a host, but httpx and
  Chromium re-resolve when they actually connect. A hostile resolver can
  return a public IP to the guard and an internal IP to the connection. The
  decision cache widens this window by up to `WTM_SSRF_CACHE_TTL` seconds.
  *Backstop*: on the deploy box, fetcher egress is forced through the VPN with
  a fail-closed blackhole, which blackholes most rebinding targets. The gap is
  loopback and link-local, which don't traverse that routing — and those are
  caught by this guard *as long as the resolver is honest at vet time*.
  *To close fully*: pin the connection to the vetted IP — a custom httpx
  transport, plus Chromium `--host-resolver-rules`. Treat as a separate
  hardening pass; not done because the VPN backstop covers the routable part.
- **Exotic IP-literal obfuscation**: integer and hex forms are handled;
  dotted-octal and other mixed forms are not.

## Packaging & entrypoints

- `_ssrf.py` is imported relatively (`from ._ssrf import ...`) and **must sit
  in the package next to `server.py`**. Running `server.py` as a loose script
  rather than via the installed package breaks that import; go through the
  package entrypoints.
- Two entrypoints share one `FastMCP` instance:
  - `server.main` → `mcp.run()` (stdio) — local Claude Desktop on the Mac.
  - `serve_http.main` → uvicorn over streamable HTTP — the deploy box.
- `uvicorn` is only needed by the HTTP entrypoint. Keeping it as an optional
  extra (`pip install '.[http]'`) lets the stdio/Mac install stay lean.
