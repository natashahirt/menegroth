---
id: plan-f0bf18b9
type: plan
project: menegroth
parent_id: plan-66282b2f
title: 'Phase: Institutional knowledge — from heuristic ontology to evidence-backed,
  code-versioned knowledge (research framing + lit review)'
node_label: Institutional knowledge
tags: institutional-knowledge,ontology,function-network,bayesian,scenario-discovery,trust-tiers,lit-review,harness
status: active
open_threads: 4
success: 'null'
files: ''
session_id: sess-af5f41f4
created_at: '2026-10-14T19:34:44.944291+00:00'
updated_at: '2026-10-14T19:35:23.940971+00:00'
has_child_rationale: 'Design Harness memory layer: what the agent learns from its
  own experiments'
---
Goal: replace the hand-written heuristic ontology (StructuralSynthesizer/src/api/ontology.jl) with institutional knowledge the agent can traverse: parameter->outcome causal understanding, learned from menegroth's own simulator experiments, fed by existing knowledge graphs (corpus canon, memory tree, code graph), and kept valid as the code evolves.

Framing reached in discussion (2026-09-28 / 2026-10-14):
- A flat list of claims doesn't scale (params x outcomes x contexts). Knowledge should live on a network whose structure comes from the code: nodes = parameters, context, trace-recorded intermediates, outcomes; edges = functions (code-pinned, clause-cited where applicable). This is a Bayesian-network / function-network view.
- Edges split into white-box (closed-form cited equations: call, don't learn), grey-box (branching rules), black-box (sizers, catalog selection, MIP, iteration loops: learn from experiments).
- Probabilities = epistemic uncertainty about a deterministic code's output (unrun regions) plus spread from unparameterized context (e.g. geometry). Behavior is discontinuous -> needs regime-aware modeling; slab-column iteration is a cycle -> model converged state.
- Mapping the space is itself open-ended (new runs reveal new branches) and generalization across buildings/systems is a core requirement.

Next step (user-approved direction): literature review before committing to an architecture. Plan: requirements memo -> search 6 questions (mapping/illumination, exploiting structure, generalization, agents, structural DSE, KG-informed learning) -> user prunes -> zettelkasten ingest -> approaches x requirements spine -> synthesis recommending architecture + first experiment. A quick overview pass is done (see child note); user will decide whether to turn it into a full review.

Open next action offered: a focused novelty check on the candidate contributions (see child note) before the broad review.
