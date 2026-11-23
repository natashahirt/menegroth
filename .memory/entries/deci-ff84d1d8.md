---
id: deci-ff84d1d8
type: decision
project: menegroth
parent_id: plan-cecee16b
title: 'Axial-member architecture: general shared Strut sizer, Truss owner-group,
  :braces→:struts, braced-frame-is-a-vertical-truss'
node_label: 'Axial-member architecture: general shared Strut si'
tags: architecture,strut,truss,braced-frame,axial-member,lfrs,phase-h,phase-c,primitives,sizer
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/building_types/members.jl@507697a, StructuralSynthesizer/src/building_types/skeleton.jl@507697a,
  StructuralSynthesizer/src/analyze/members/members/initialize.jl@507697a
session_id: sess-725b3df8
created_at: '2026-11-23T17:42:29.772660+00:00'
updated_at: '2026-11-23T17:42:54.430715+00:00'
has_child_rationale: Durable cross-cutting element-taxonomy + sizer decisions agreed
  while scoping the LFRS designer; hold regardless of build order
related_to: plan-3dbc321c
---
Durable architecture decisions agreed with the user (2026-11-23) while scoping the steel LFRS designer. These hold regardless of build-order sequencing (which is deliberately left open below). Couples Phase H (braced frames) and Phase C (trusses/joists).

**Core insight:** strut = brace = truss chord/web = joist chord = ONE axial-member design problem (AISC Ch. E compression + Ch. D tension, already in the steel checker). Build the axial sizer once; it serves all.

**1. Minimize primitives.** Member primitives stay: `Beam`/`Column` (flexural / beam-column; gravity AND moment-frame via `lateral_role`), `Strut` (axial), `Wall` (planar). A **`Truss` is an OWNER/GROUP** over struts, NOT a new primitive (parallel to a moment frame = tagged Beam/Column, or a wall-line). Do NOT merge Column and Strut (beam-column vs pin-ended axial = different governing checks); share only the compression branch in the sizer.

**2. `Strut` = the general axial-member primitive.** Generalize it beyond lateral bracing. Add a `role`/function on the strut ∈ {`:brace`, `:truss_web`, `:truss_chord`, `:joist_chord`} (mirrors `beam.lateral_role`); the role (not the element) drives demand source, connection type, seismic detailing. Keep the name `Strut` (already carries `brace_type ∈ {:tension_only,:compression_only,:both}`; renaming the type is churn for no gain).

**3. Rename skeleton group `:braces` → `:struts`.** Name what the edge IS (axial member), not one thing it does (brace). Touch points: `skeleton.jl` (group), `initialize_members!` (`brace_edges`), API deserializer/schema, any `:braces` string refs. Add a deprecation alias if the API is already public. 'Brace' becomes the strut `role`.

**4. Shared general axial-member sizer (general by design).** One interface: IN = per-case axial demand set (Pu tension/compression per load case), L, K, unbraced length, `brace_type`, material, objective. CHECKS = AISC Ch. E compression (KL/r, flexural/torsional buckling) + Ch. D tension (yield/rupture) + HSS slenderness — all already in the steel checker; material-general (steel W/HSS, timber ties, RC tension members). OUT = lightest section + utilization + governing check (same shape every owner uses). SOLVER PATHS = catalog MIP · continuous NLP · table lookup, selected by options (exactly today's size_columns catalog-vs-NLP dispatch). `Strut`, the `Truss` owner, and the braced-frame designer all call this one sizer.

**5. Catalog vs explicit = TWO orthogonal strategy axes on shared infra (not forked code).** (a) MEMBER SOLVER: catalog MIP / continuous NLP / table-lookup (SJI safe-load). (b) ASSEMBLY REPRESENTATION: black-box (one equivalent member / designation, internals not in the FE model) vs explicit (every member a pinned element in the solve). They compose: SJI joist = black-box + table-lookup; engineered steel truss / braced frame = explicit + catalog-or-NLP. Same `Truss` owner, strategy fields — like `ColumnOptions`.

**6. Explicit truss: general sizing handles ALL topologies at once.** Warren/Pratt/Vierendeel/braced-frame/transfer/outrigger differ only in geometry (input) and demand source (gravity vs lateral); member force recovery + axial sizing is identical. The per-type work that is pluggable (NOT a blocker): joint/panel-point design (gusset vs AISC Ch. K HSS [already in corpus] vs bolted) and seismic detailing (AISC 341 SCBF/EBF). Vierendeel = fixed member releases → beam-column truss, reuses Beam/Column.

**7. Truss chords default to axial `Strut`** (pin-jointed idealization, loads at panel points). A chord carrying load BETWEEN panel points is an opt-in `Beam`-column chord. Keeps the common case clean.

**8. Braced-frame-is-a-vertical-truss** (columns=chords, braces=web, pinned joints). So the explicit-truss assembly layer (topology on `:struts` edges + per-member axial sizing + joint design + pinned/released-frame-element solve) is SHARED infrastructure for Phase C4 (roof trusses) + Phase H1 (braced frames) + high-rise transfer/outrigger trusses. Build once, unlock three.

**9. Asap tension/compression-ONLY behavior is the only genuinely-new analysis piece, and is DEFERRABLE.** A pinned (moment-released) frame element in the existing frame+shell `Model` already behaves as a LINEAR axial/truss member (Asap also has a standalone `TrussModel`). Tension/comp-only (nonlinear, compression brace buckles and sheds to the tension brace) is needed only for slender CBF tension-only braces, and per architecture-contracts.mdc must live in Asap. Gravity trusses take both, so this does not block them.

**LEFT OPEN (sequencing, not decided):** (i) MF-first (reuses Beam/Column, fastest first LFRS building as a dual system w/ RC core) vs axial/truss-layer-first (highest-leverage shared foundation). (ii) Near-term truss target: SJI joists (black-box catalog, highest real-world volume) vs engineered explicit trusses/braced frames. The shared sizer + `Truss` owner are built the same way either way.
