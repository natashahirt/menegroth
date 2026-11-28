---
id: note-ffce6f82
type: note
project: menegroth
parent_id: plan-0b622f2c
title: 'API-surface contract added to optimization plan: every toggle reachable from
  /design + /schema'
node_label: 'API-surface contract added to optimization plan: e'
tags: api,toggles,DesignParameters,schema,optimize_for,pareto,fidelity,relaxation
status: active
open_threads: 0
success: 'null'
files: docs/sizing-map/optimization-architecture.md@1b2c8da
session_id: sess-61ea56aa
created_at: '2026-11-24T15:09:21.429627+00:00'
updated_at: '2026-11-24T15:09:21.429627+00:00'
has_child_rationale: 'User: all toggles must be accessible from the current API layer'
---
Added §10 'API surface' to optimization-architecture.md. Every pillar toggle must be a DesignParameters field (design/parameters.jl) threading the SAME chain as optimize_for: APIParams DTO (api/schema/input_types.jl) -> json_to_params (api/deserialize/floors.jl) -> fail-loud enum in api/validation.jl (pattern API_OPTIMIZE_FOR + _push_enum!) -> publish in /schema (api/schema/input_schema.jl + params_schema.jl) -> agent/chat (api/ontology.jl, design_state.jl, agent_tools/orientation.jl, chat/param_patches.jl). Default-preserving rule: every toggle defaults to today's behavior (relaxation off, full fidelity, single optimize_for) -> flag-off byte-identical, test-enforced. Toggle registry: objective_terms (vector objective), relaxation_seed, candidate_band, report_optimality_gap, allow_shrink, fidelity (fast|full), compute_budget. FLAGGED: pareto_sweep is NOT a drop-in field — it changes the /design RESPONSE shape (returns a `front` of N gap-certified designs), scoped as its own WP (API.2 / part of P.3). WPs API.1 (scalar toggles, byte-identical flag-off) + API.2 (response-shape extension).
