---
id: anno-49cde79d
type: annotation
project: menegroth
parent_id: plan-9fee23b6
title: 'BLOCKER: zettelkasten MCP server not connected — ZK note commits blocked (needs
  reload)'
node_label: ZK MCP down — commit blocked
tags: blocker,mcp,zettelkasten,extraction,overnight
status: active
open_threads: 0
success: 'null'
files: docs/260714_report_corpus_batch_extraction.md@10f4a3f
session_id: sess-c6d7f850
created_at: '2026-07-14T01:57:17.975197+00:00'
updated_at: '2026-07-14T01:57:17.975197+00:00'
---
During the overnight ACI beam/slab extraction run (run-d3306fbe), the **zettelkasten MCP server (`project-0-menegroth-zettelkasten`) is not connected** in this Cursor session. `GetMcpTools` shows only `project-0-menegroth-coordinator`, `project-0-menegroth-memory`, `project-0-menegroth-memory-artifacts`, `user-menegroth-corpus` — no `note`/`attach` tool exists. So NO zettelkasten note can be committed (neither by scribe subagents nor directly by the parent).

Why prep still worked: `create_extraction_graph` seeded per-source hubs (`20260713-2137-*`) because the COORDINATOR server reaches the ZK store internally; the ZK's own MCP tool surface is what's missing for writes.

**State preserved:** all 4 first-wave extractors (doubly-reinforced, moment-redistribution, cantilever, simply-supported beams) completed with clean, safety-compliant grounded candidate sets (OCR-garbled equations flagged as `question`, NOT fabricated; all numeric test oracles captured). Full candidate lists live in the run-d3306fbe agent transcripts. The `aci-318-canon` spine + hubs are materialized.

**Remediation (needs user):** Cursor → Reload MCP Servers (or restart Cursor) so the `zettelkasten` entry in `.cursor/mcp.json` (`/Users/tashahirt/.venvs/angelo/bin/angelo-zettelkasten`, binary present) registers. Then either resume run-d3306fbe (re-run extractors so scribes get full candidates) or re-run the scribe wave with the captured candidates.

**Did NOT do:** hand-author note `.md` files directly — that bypasses grounding validation + spine-edge resolution on safety-critical structural content. Deliberately declined per code-accuracy rule.

Note: the deterministic 28-doc ingest (manifest + corpus/text) is unaffected and complete — all queryable via corpus MCP tools.
