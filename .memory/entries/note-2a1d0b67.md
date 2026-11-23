---
id: note-2a1d0b67
type: note
project: menegroth
parent_id: deci-5e3b7151
title: Steel (AISC) capacity cache is Lb/Cb-dependent (lazy per-(j,Lb,Cb) memo) —
  NOT a clean mirror of the demand-independent ACI beam cache; rectangular RC beams
  ARE
node_label: Steel (AISC) capacity cache is Lb/Cb-dependent (la
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/codes/aisc/checker/steel_feasibility.jl@80f0ed4,
  StructuralSizer/src/members/optimize/api/beams.jl@507697a
session_id: sess-af2ebfb0
created_at: '2026-11-23T17:42:36.403968+00:00'
updated_at: '2026-11-23T17:42:36.403968+00:00'
---
Scoping the capacity-cache extension (todo cache-rcbeams-steel) surfaced a key asymmetry:

- RECTANGULAR RC BEAMS (size_beams(::ConcreteBeamOptions), beams.jl:98): same ACIBeamChecker + ACIBeamCapacityCache as T-beams, whose precompute (φMn/φMn_neg/φVn/εt) I already proved demand- and span-independent. So this is a CLEAN extension of the content-keyed capacity_store pattern. The only real work is generalizing the capacity-key: _tbeam_capacity_key hashes RCTBeamSection fields (bw/bf/hf); RCBeamSection has different fields (b/h/d/As/n_bars/bar_size/cover). Need a section-type-dispatched _section_capacity_fingerprint so one key fn covers both.

- STEEL (AISC): size_beams(::SteelBeamOptions) delegates to the AISC array size_columns (beams.jl:369). AISC strong-axis φMnx is a function of Lb (unbraced length) and Cb, both per-member geometry, computed LAZILY via _get_φMnx_cached!(cache, j, Lb_m, Cb, ...) keyed by (j, Lb, Cb) (steel_feasibility.jl:78, explanations.jl:72). This is a DIFFERENT cache architecture than ACI's one-shot demand-independent precompute. Cross-call reuse is only safe for the Lb-INDEPENDENT parts (depths, weak-axis φMn, φPn pieces, Lp/Lr) plus sharing the lazy φMnx memo across groups with EQUAL Lb. Reusing a φMnx computed at one Lb for a member with a different Lb would be unconservative/unsafe. So the steel extension must NOT blindly copy the T-beam approach; it needs its own design (verify AISC cache_matches, decide what to share) and its own A/B.

Recommendation: do rectangular RC beams first (clean, bit-exact by construction), treat steel as a separate scoped investigation.
