#!/usr/bin/env python3
"""End-to-end smoke test for the menegroth-corpus MCP server.

Spawns ``scripts/corpus/mcp_server.py`` over stdio (the same transport
Cursor uses), performs the MCP handshake, lists the registered tools,
and invokes a couple of tools to confirm they return well-formed
envelopes. Useful when changing the tool surface or upgrading the
``mcp`` SDK.

Usage::

    python3 scripts/runners/corpus_mcp_smoke.py
"""
from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SERVER_SCRIPT = REPO_ROOT / "scripts" / "corpus" / "mcp_server.py"


async def main() -> int:
    try:
        from mcp import ClientSession, StdioServerParameters
        from mcp.client.stdio import stdio_client
    except ImportError as exc:
        print(f"ERROR: mcp SDK not importable: {exc}", file=sys.stderr)
        print("Install with: pip install mcp", file=sys.stderr)
        return 2

    params = StdioServerParameters(
        command=sys.executable,
        args=[str(SERVER_SCRIPT)],
        cwd=str(REPO_ROOT),
    )

    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            init = await session.initialize()
            print(f"server: {init.serverInfo.name} (proto {init.protocolVersion})")

            tools = await session.list_tools()
            names = sorted(t.name for t in tools.tools)
            print(f"tools ({len(names)}):")
            for name in names:
                print(f"  - {name}")

            def _unwrap(result) -> dict:
                """Pull the envelope dict from a FastMCP CallToolResult.

                FastMCP may surface the dict either as ``structuredContent`` or
                as a JSON-encoded ``TextContent``; handle both transparently.
                """
                if result.structuredContent:
                    payload = result.structuredContent
                    if "status" not in payload and "result" in payload:
                        payload = payload["result"]
                    return payload
                for item in result.content or []:
                    text = getattr(item, "text", None)
                    if text:
                        try:
                            return json.loads(text)
                        except json.JSONDecodeError:
                            continue
                return {}

            print("\ncalling list_sources(limit=3)...")
            result = await session.call_tool("list_sources", {"limit": 3})
            payload = _unwrap(result)
            sources = payload.get("results", [])
            print(f"  status={payload.get('status')} count={len(sources)}")
            for src in sources:
                print(f"    {src.get('id')}  ({src.get('family')}/{src.get('role')})  {src.get('edition')}")

            print("\ncalling search_text(query='strength reduction', max_results=2)...")
            result = await session.call_tool(
                "search_text",
                {"query": "strength reduction", "max_results": 2},
            )
            payload = _unwrap(result)
            hits = payload.get("results", [])
            print(f"  status={payload.get('status')} hits={len(hits)}")
            for hit in hits:
                src = (hit.get("source") or {}).get("id")
                pages = hit.get("page_range")
                line = hit.get("line_number")
                print(f"    {src}  page_range={pages}  line={line}")

    print("\nOK: MCP server responded over stdio.")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
