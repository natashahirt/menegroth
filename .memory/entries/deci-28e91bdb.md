---
id: deci-28e91bdb
type: decision
project: menegroth
parent_id: plan-b0000001
title: 'Cut agent dev cost: requestable rules, lean hooks, critic-only coordinator,
  quiet test runner, no nightly doc audit'
node_label: 'Cut agent dev cost: requestable rules, lean hooks,'
tags: cost,agent-config,rules,hooks,coordinator,testing
status: active
open_threads: 0
success: 'null'
files: .cursor/agents.yaml@76c7208, .cursor/hooks.json@76c7208, .cursor/rules/angelo.mdc@76c7208,
  .cursor/rules/coordinator.mdc@76c7208, .cursor/rules/corpus.mdc@76c7208, .cursor/rules/memory.mdc@76c7208,
  .cursor/rules/core.mdc@76c7208, .cursor/rules/coordinator-local.mdc@76c7208, AGENTS.md@76c7208,
  docs/agent-setup.md@76c7208, scripts/check_agent_config.sh@76c7208, scripts/runners/test_quiet.jl@76c7208
session_id: sess-c85ddd04
created_at: '2026-10-22T18:16:38.513146+00:00'
updated_at: '2026-10-22T18:16:38.513146+00:00'
---
Budget-driven reduction of per-request and per-run agent token spend (2026-10-22).

- Rules: memory/coordinator/corpus/angelo .mdc switched to agent-requestable (~67 KB, ~17k tokens removed from every request). New always-on `core.mdc` (~1 KB) keeps the critical triggers: memory record before commits, corpus-first + citation for code-derived work, coordinator only when asked.
- Coordinator: new `coordinator-local.mdc` (overrides coordinator.mdc). Single agent by default; pipeline only for code-derived engineering math, core-abstraction refactors, or explicit request. Default rigor low (`rigor: low` in agents.yaml). Critic is the baseline checker; reviewer opt-in (moved Opus -> Sonnet). Fix cycles only on critic P0; stop at soft cap; one coordinator-written checkpoint per run, no per-subagent memory entries; proposals must state spawn count + models.
- Hooks: stop hook only acts when files/commits/memory changed; sessionStart = pickup only (no full-tree recall); auto-visualize removed; subagentStop = submit_result only. Added angelo update/init -> guard check.
- AGENTS.md slimmed 15.7 KB -> ~2 KB; setup docs moved to docs/agent-setup.md.
- scripts/runners/test_quiet.jl: tests in child process, full log to logs/, prints only summary + per-failure excerpts (verified pass + fail paths).
- Removed .github/workflows/doc-audit.yml (nightly Cursor Cloud Agent); prompt kept.
- Enforcement: scripts/check_agent_config.sh run by local .git/hooks/pre-commit blocks commits that revert these settings; user added a zsh `angelo` wrapper forcing `update --keep-edits` (angelo's interactive migrate/overwrite would restore stock always-on rules).

Supersedes the reviewer part of anno-99c4d84a (Opus checkers).
