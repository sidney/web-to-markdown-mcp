"""Localhost smoke test for web-to-markdown-mcp over streamable HTTP.

Runs the MCP handshake (initialize -> notifications/initialized) then calls
fetch_url_as_markdown, printing the first chunk of returned markdown. Uses the
official mcp client so we don't hand-roll session-id threading.

Usage:
    python smoke_fetch.py "https://some-js-heavy-page.example"
Env:
    WTM_HTTP_PORT (default 8787), WTM_KEYFILE (default ./secrets/keys)
"""
import asyncio, os, sys
from pathlib import Path

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

PORT = os.environ.get("WTM_HTTP_PORT", "8787")
KEY = Path(os.environ.get("WTM_KEYFILE", "./secrets/keys")).read_text().split()[0]
URL = f"http://127.0.0.1:{PORT}/mcp?key={KEY}"
TARGET = sys.argv[1] if len(sys.argv) > 1 else "https://example.com"

async def main():
    async with streamablehttp_client(URL) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            print("tools:", [t.name for t in tools.tools])
            result = await session.call_tool(
                "fetch_url_as_markdown", {"url": TARGET}
            )
            text = result.content[0].text if result.content else "(empty)"
            print(f"\n--- {TARGET} ({len(text)} chars) ---")
            print(text[:600])

asyncio.run(main())
