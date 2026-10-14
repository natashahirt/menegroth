---
id: note-bc1ca7de
type: note
project: menegroth
parent_id: plan-f0bf18b9
title: 'Candidate CS contributions: evolving function networks, agent-proposes/model-adjudicates
  hybrid, versioned structural benchmark'
node_label: Candidate contributions
tags: research-contribution,function-network,agentic,benchmark,novelty-check
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-af5f41f4
created_at: '2026-10-14T19:35:18.638386+00:00'
updated_at: '2026-10-14T19:35:18.638386+00:00'
---
Assessment: 'LLM agent + function-network BO on a structural simulator' alone is an integration/systems paper (fine for engineering-design venues, thin for CS). Sharper candidate contributions:

1. Evolving function networks (most novel-looking): BO/active learning over a function network whose node functions get versioned and whose structure grows, with edge-level retention/invalidation of knowledge. Related: time-varying BO, but that assumes smooth global drift, not discrete code-driven edge-level change. Novelty is an impression from a quick search, NOT verified.
2. Agent proposes, model adjudicates: LLM agent supplies semantic hypotheses/proposals (AgentDSE evidence that semantics improves sample efficiency); function-network posterior supplies value-of-information and adjudicates claims. Clean ablation: vs agent-only and vs FN-BO-only.
3. Benchmark: a real deterministic, regime-switching engineering simulator with exposed intermediates and real version history.

Git-history replay of menegroth makes (1) evaluable on real code evolution.

Before claiming novelty: targeted check of time-varying BO, versioned/evolving simulators, LLM+BO hybrids. Venue split: ML venue (AutoML/BO workshop first) wants method + proofs/ablations; engineering venue (J. Mech. Design, Automation in Construction) wants system + case study.

Status: offered to add a focused novelty check to the plan; not yet started.
