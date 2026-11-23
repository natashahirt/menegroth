---
id: find-48ce26cc
type: finding
project: menegroth
parent_id: find-542bde3f
title: 'e0c0 audit: collinear bar-sharing enforces the C2 pairing; root is asymmetric
  demands to the per-girder MIP'
node_label: 'e0c0 audit: collinear bar-sharing enforces the C2 '
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-39c762b3
created_at: '2026-11-23T22:27:47.922710+00:00'
updated_at: '2026-11-23T22:27:47.922710+00:00'
has_child_rationale: Static audit of the sizing path localizes the C2-pairing mechanism
  and isolates the root to asymmetric demands
---
Static audit of the T-beam sizing path (size_beams.jl T-beam branch + collinear_ribs.jl).

FINDINGS:
1. With uniform_geometry=false, each beam group is a SINGLETON batch sized by _size_tbeams_escalating(Mu[i], Vu[i], Mu_neg[i], ...) with its own bf_of(bw). So identical demand+flange inputs MUST give identical sections (deterministic MIP). => mirror girders can only differ if their DEMANDS differ.
2. _share_collinear_rib_bars! (collinear_ribs.jl:262) ALSO applies to one-sided EDGE girders (spec.joist_spacing===nothing && !_spec_has_edge(spec) is the only skip; one-sided edges participate). The four hub girders lie on TWO collinear lines through hub (12,10): Line1 (6,5)-(12,10)-(18,15) = {B55,B11}; Line2 (6,15)-(12,10)-(18,5) = {B27,B44}. Each line is raised to its own max(bw,h,bar) via `maximum` over the line. Each line is C2-invariant, so this ENFORCES B11==B55 and B27==B44 (explains the observed 180deg pairing) but keeps the two MIRROR lines independent. The sharing uses `maximum` (symmetric) and _collinear_rib_groups pairs correctly, so sharing preserves symmetry IF its inputs are symmetric.
3. Therefore sharing is NOT the root; the root is that the per-girder MIP sized Line1 (T18x36-bf42) and Line2 (T20x30-bf20) members to DIFFERENT demands pre-sharing.

PARADOX: frame geometry + solved frame are reflection-symmetric (find-542bde3f), pattern_loading=:none (so loads should be symmetric), flange geometry symmetric => demands SHOULD be symmetric, yet sections differ. The only remaining source is PATH-DEPENDENT iterative state: asymmetric installed sections in a round feed an asymmetric solve -> asymmetric demands -> asymmetric sizing (self-consistent mirror-broken fixed point). The _size_with_story_shell! loop has an UPWARD-ONLY ratchet (_section_floors) for some beam kinds (T-beams reportedly not floored), another path-dependence vector. The reflection-odd SEED/tie-break that selects the mirror-broken branch is not statically identifiable.

DECISIVE NEXT TEST (separates loads-asymmetry vs sizing-path-asymmetry): install ONE uniform section on ALL beams, rebuild stiffness, single solve, then compare beam_signed_moment_field / member_group_demands for the four hub girders. If demands are mirror-equal under uniform sections => loads/analysis are symmetric and the carrier is purely the sizing-path tie-break/ratchet (fix: canonical reflection-covariant tie-break + symmetric ratchet seeding). If demands differ under uniform sections => a reflection-odd load/analysis input remains to find.
