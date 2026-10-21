---
id: anno-99c4d84a
type: annotation
project: menegroth
parent_id: menegroth
title: 'Revised coordinator model policy: Opus checkers + Grok implementers'
node_label: 'Revised coordinator model policy: Opus checkers + '
tags: ''
status: active
open_threads: 0
success: 'null'
files: .cursor/agents.yaml@b232486
session_id: sess-60a70b0a
created_at: '2026-10-21T02:08:21.154057+00:00'
updated_at: '2026-10-21T02:08:21.154057+00:00'
---
User refined the coordinator agent model overrides in .cursor/agents.yaml. Final mapping: engineer + tester -> grok-4.7-high (xAI, dropped the -fast variant); reviewer -> claude-opus-4-8-thinking-high; critic -> claude-opus-5-5-thinking-high (strongest adversarial reasoning); explore + memory + zettelkasten-extractor -> claude-sonnet-5-thinking-high. bugbot/security-review left unset (host-native in Cursor, ignore the model field). Supersedes the earlier 'avoid top tier' annotation: reasoning-heavy checkers now run on Opus intentionally. Caveat 1: claude-opus-5-5-thinking-high slug is convention-derived, not yet verified against a known-good run. Caveat 2: coordinator MCP caches agents.yaml at startup, so restart the server/Cursor for overrides to take effect.
