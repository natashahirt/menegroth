"""End-to-end MCP client smoke test.

Spawns ``scripts/corpus/mcp_server.py`` over stdio using the official
``mcp`` SDK client, then exercises a handshake + ``tools/list`` +
representative ``tools/call`` invocations.

Run::

    python3 scripts/corpus/tests/test_mcp_client.py

This test requires the ``mcp`` SDK (``pip install mcp``) and an ingested
corpus (Tier 1 sources copied into ``corpus/text/...``). It is not part
of the unit test suite because it spawns a subprocess and depends on the
real corpus contents.
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
SERVER = REPO_ROOT / "scripts" / "corpus" / "mcp_server.py"


async def main() -> int:
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client

    params = StdioServerParameters(
        command=sys.executable,
        args=[str(SERVER)],
        cwd=str(REPO_ROOT),
    )

    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            tools = await session.list_tools()
            names = sorted(t.name for t in tools.tools)
            print(f"server advertises {len(names)} tools:")
            for n in names:
                print(f"  - {n}")
            assert len(names) == 8, f"expected 8 tools, got {len(names)}"

            print("\ncalling list_sources(family='aci') ...")
            result = await session.call_tool("list_sources", {"family": "aci"})
            payload = _payload(result)
            assert payload["status"] == "ok", payload
            ids = [s["id"] for s in payload["results"]]
            print(f"  -> {len(ids)} aci source(s): {ids[:5]}{'...' if len(ids) > 5 else ''}")
            assert len(ids) >= 1

            print("\ncalling get_clause(family='aisc', edition='AISC 360-16', clause_id='F2') ...")
            result = await session.call_tool(
                "get_clause",
                {"family": "aisc", "edition": "AISC 360-16", "clause_id": "F2"},
            )
            payload = _payload(result)
            assert payload["status"] == "ok", payload
            confidence = payload["results"][0]["confidence"]
            print(f"  -> confidence: {confidence}")
            assert confidence in {"extracted", "text-match", "not-found"}

            print("\ncalling search_extractions(extraction_class='phi_factor') ...")
            result = await session.call_tool(
                "search_extractions", {"extraction_class": "phi_factor"},
            )
            payload = _payload(result)
            print(f"  -> status: {payload['status']}")
            assert payload["status"] in {"ok", "no_extractions_available"}

    print("\nOK: server speaks MCP, tools register, calls work end-to-end.")
    return 0


def _payload(result):
    """Extract the JSON dict from an MCP tool call result.

    FastMCP wraps tool returns into ``CallToolResult`` with ``content`` blocks
    and a parsed ``structuredContent`` field; prefer the structured field.
    """
    if getattr(result, "structuredContent", None):
        return result.structuredContent
    # Fall back to first text content block.
    import json
    for c in getattr(result, "content", []):
        text = getattr(c, "text", None)
        if text:
            return json.loads(text)
    raise AssertionError(f"no payload in result: {result!r}")


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
