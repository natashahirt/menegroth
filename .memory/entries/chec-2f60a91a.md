---
id: chec-2f60a91a
type: checkpoint
project: menegroth
parent_id: plan-b0000001
title: 'kglite crash resolved: dedicated Python 3.11 venv for angelo'
node_label: 'kglite crash resolved: dedicated Python 3.11 venv '
tags: kglite,venv,mcp,resolved,setup
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-6dad54fe
created_at: '2026-07-12T21:58:38.677339+00:00'
updated_at: '2026-07-12T21:58:38.677339+00:00'
---
# kglite SIGFPE resolved via a dedicated Python 3.11 venv

**What changed.** Created a dedicated venv at `~/.venvs/angelo` on Python 3.11.1 and installed `angelo[zettelkasten]` 1.7.8 into it (from the local clone /tmp/angelo_src; the scientific wheels are cp311 builds, cryptography 49 compiled from source via the system Rust 1.84). Repointed all four servers in `.cursor/mcp.json` (memory, coordinator, zettelkasten, memory-artifacts) from /opt/miniconda3/bin to `~/.venvs/angelo/bin`.

**Result.** `import memory.server` and `KnowledgeGraph()` no longer SIGFPE under 3.11 - the crash was specific to the conda Python 3.13 native-extension stack. The memory server rebuilds the kglite cache from the 25 committed .memory/ files cleanly, and an MCP initialize + tools/list handshake returns tools fast: memory 16, coordinator 15, zettelkasten 21.

**Embeddings.** The servers eagerly load the model2vec embedding model (minishlab/potion-retrieval-32M) at startup. On this throttled network the HF xet chunked download stalls, which blocked the servers from finishing init and advertising tools (symptom: "server loaded but no tools/prompts/resources"). Fixed by setting `MEMORY_SKIP_EMBEDDINGS=1` in each server env in mcp.json; search degrades to keyword matching (fine for the 25-entry tree). A background `snapshot_download` with HF xet disabled is caching the model; once cached, remove the skip flags to restore semantic search.
