---
id: anno-c0420e6a
type: annotation
project: menegroth
parent_id: menegroth
title: 'Coordinator model policy: prefer Anthropic (Sonnet) + xAI (Grok), avoid top
  tier'
node_label: 'Coordinator model policy: prefer Anthropic (Sonnet'
tags: ''
status: active
open_threads: 0
success: 'null'
files: .cursor/agents.yaml@dbd9423
session_id: sess-60a70b0a
created_at: '2026-10-21T02:06:45.616652+00:00'
updated_at: '2026-10-21T02:06:45.616652+00:00'
---
User set a standing preference for coordinator agent models in .cursor/agents.yaml: prefer Anthropic Claude and xAI Grok, and do NOT default to the most expensive tier (no Opus as a blanket default). Applied as model-only partial overrides on the built-in roster: engineer + tester -> grok-4.7-high-fast; reviewer + critic + explore + memory -> claude-sonnet-5-thinking-high; zettelkasten-extractor -> claude-sonnet-5-thinking-high. bugbot/security-review left unset (host-native in Cursor, ignore the model field). Caveat: the coordinator MCP server caches agents.yaml at startup, so restart the server (or Cursor) for overrides to take effect.
