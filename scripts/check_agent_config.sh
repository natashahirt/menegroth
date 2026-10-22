#!/usr/bin/env bash
# Guard the cost-reduction edits to angelo-managed agent config.
#
# `angelo update` / `angelo init --force` can revert these files to the stock
# (always-applied, high-token) versions if someone picks [m]igrate or
# [o]verwrite at its prompt. Run by .git/hooks/pre-commit; also runnable by hand.
# Restore a reverted file with `git checkout -- <file>` (or `git log -p <file>`).

set -u
cd "$(git rev-parse --show-toplevel)" || exit 1

fail=0
err() { echo "agent-config guard: $*" >&2; fail=1; }

for rule in memory coordinator corpus angelo; do
  f=".cursor/rules/$rule.mdc"
  grep -q '^alwaysApply: false' "$f" 2>/dev/null || err "$f must be 'alwaysApply: false' (agent-requestable)"
done

for f in .cursor/rules/core.mdc .cursor/rules/coordinator-local.mdc docs/agent-setup.md; do
  [ -f "$f" ] || err "$f is missing"
done

if grep -q 'visualize()' .cursor/hooks.json 2>/dev/null; then
  err ".cursor/hooks.json re-added the auto-visualize hook"
fi
if grep -q 'load the full research tree' .cursor/hooks.json 2>/dev/null; then
  err ".cursor/hooks.json re-added the full-tree recall on session start"
fi

grep -q '^rigor: low' .cursor/agents.yaml 2>/dev/null || err ".cursor/agents.yaml lost 'rigor: low'"

size=$(wc -c < AGENTS.md 2>/dev/null || echo 0)
[ "$size" -lt 4000 ] || err "AGENTS.md is ${size} bytes; setup docs belong in docs/agent-setup.md"

new_files=$(ls .cursor/rules/*.new .cursor/*.new 2>/dev/null)
[ -n "$new_files" ] && echo "agent-config guard: note: upstream angelo versions waiting to reconcile: $new_files" >&2

if [ "$fail" -ne 0 ]; then
  echo "agent-config guard: commit blocked. Restore with 'git checkout -- <file>' or bypass with --no-verify." >&2
  exit 1
fi
exit 0
