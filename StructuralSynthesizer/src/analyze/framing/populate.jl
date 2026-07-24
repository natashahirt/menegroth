# =============================================================================
# Framing auto-generation: populate_levels! / derive_framing_level /
# materialize_level!  — Phase 5 (plan `joists-roles-materials`)
# =============================================================================
#
# One mechanism powers both the single-level case (steel + OWSJ deck, RC waffle,
# mass-timber joists) and — through opts-driven per-level schemas — the
# multi-level case (girders + secondary beams + joists). The flow is:
#
#   populate_levels!(struc; opts)
#     └─ for each slab, for level_idx = 1, 2, …:
#          derive_framing_level(slab, level_idx, opts)  → FramingLevel | nothing
#          attach_framing_level!(struc, slab, level)    (Phase 4, if newly derived)
#          materialize_level!(struc, slab, level)        → Vector{Beam{T}}
#
# Mechanics contract (`.cursor/rules/code-accuracy.mdc`): this file invents NO
# structural formulas. Every mechanics decision reduces to an already-existing,
# already-tested utility:
#   - joist geometry (pattern → lines) comes from the slab's own sizing data via
#     the Phase-4 `joist_geometry(slab, level_idx)` trait (rib grid / joist
#     spacing / span axis) — never fabricated here;
#   - joist landings (host subdivision) reuse the skeleton `edge_chains`
#     mechanism (`api/deserialize.jl`), the same topological surgery used at
#     deserialization;
#   - joist end releases are left as `level.end_fixity` (default `:default`),
#     which the Phase-2 runtime resolver (`resolve_release`) maps through the
#     Phase-3 `(role, material, lateral_role)` dispatch (`default_release`);
#   - seat eccentricity / torsion are likewise deferred to Phase 3.
#
# The only non-code decisions this file makes are flagged `ENGINEERING JUDGMENT`
# (default joist spacing for the opts-schema path; `lateral_role = :gravity` for
# auto-generated joists). Neither is code-mandated and the corpus carries no
# SJI / NDS joist-spacing table to cite, so they are judgment defaults.

# -----------------------------------------------------------------------------
# ENGINEERING JUDGMENT defaults
# -----------------------------------------------------------------------------

# ENGINEERING JUDGMENT: default center-to-center joist spacing for the
# opts-schema path (`:one_way` / `:two_way` / `:composite_deck` /
# `:non_composite_deck`) when the caller supplies neither `opts.spacing` nor a
# resolved spacing on the pattern. ~4 ft for steel framing, ~2 ft for wood
# framing are common layout starting points; neither is code-mandated (no SJI /
# NDS spacing table exists in the corpus), so these are judgment defaults a
# caller is expected to override with `opts.spacing`.
const _JUDGMENT_STEEL_JOIST_SPACING_M = 1.2192   # 4.0 ft
const _JUDGMENT_WOOD_JOIST_SPACING_M  = 0.6096   # 2.0 ft

# -----------------------------------------------------------------------------
# populate_levels!
# -----------------------------------------------------------------------------

"""
    populate_levels!(struc::BuildingStructure; opts::NamedTuple = NamedTuple()) -> Nothing

Auto-generate the framing hierarchy above every slab in `struc` (plan
`joists-roles-materials`, Phase 5). Mutates `struc` in place and returns
`nothing`.

For each slab, iterates `level_idx = 1, 2, …`, calling
[`derive_framing_level`](@ref)`(slab, level_idx, opts)` until it returns
`nothing`. Each non-`nothing` [`FramingLevel`](@ref) is attached (via
[`attach_framing_level!`](@ref), unless it is already one of the slab's levels)
and then materialized into real `Beam{T}`s via [`materialize_level!`](@ref).

# Iteration / subdivision contract
- Level 1 is derived from the slab type + `opts` (see `derive_framing_level`).
- A level `N ≥ 2` is generated **only if the caller requested it** by supplying
  an `opts` key `Symbol("level_\$N")` whose value is a `NamedTuple` schema (this
  is how "the previous level requested subdivision" is encoded — the request
  lives in `opts`, keyed by the level it describes). Absent that key,
  `derive_framing_level` returns `nothing` and iteration stops.

# Idempotence (guardrail)
`populate_levels!` is idempotent within a `prepare!` call and across repeated
calls: `materialize_level!` stamps `level.group_id`, and `derive_framing_level`
returns `nothing` for any `level_idx` a slab already carries a **materialized**
level at, so a second call adds no new members. A manually attached level (via
`attach_framing_level!`) that has not yet been materialized IS respected — it is
materialized on the next call, not skipped.

# opts (all optional)
- `opts.materials`: `NamedTuple` of member materials by key
  (`:steel`, `:timber`, `:concrete`, `:beam`) used to fill `FramingLevel.material`
  for slab types that do not carry their own member material.
- `opts.spacing`: center-to-center joist spacing (structure length unit) for the
  opts-schema slab types.
- `opts.axis` / `opts.count`: level-1 joist run-direction / explicit joist count
  for the opts-schema slab types (ignored by the joist-sizing slab types, whose
  level-1 geometry comes from the sized result).
- `opts.end_fixity` / `opts.catalog_override`: level-1 per-end release override
  and per-level section catalog override.
- `opts.level_N`: `NamedTuple` schema for framing level `N ≥ 2` (keys
  `:material`, `:spacing`, `:role`, `:axis`, `:count`, `:end_fixity`,
  `:catalog_override`).

Passing an empty `opts` (the pipeline default from `prepare!`) generates nothing
for the standard flat-plate / flat-slab / beam-supported flows, so existing
behavior is unchanged unless a caller opts in.
"""
function populate_levels!(struc::BuildingStructure; opts::NamedTuple = NamedTuple())
    # P2(d) fix (p5_eng_v2): count levels that actually produced ≥ 1 `Beam`, not
    # merely levels that were derived. A derived-but-empty level (pattern lays out
    # no joists on the slab) must NOT trigger the tributary cascade — the docstring
    # contract is "only IF members were generated", and the empty-opts pipeline
    # path must stay a strict no-op.
    n_beams_generated = 0
    for slab in struc.slabs
        level_idx = 1
        while true
            level = derive_framing_level(slab, level_idx, opts)
            level === nothing && break
            # Newly derived levels are attached; an existing (manual or prior)
            # level returned by derive is already on the slab — do not re-attach.
            if !any(fl -> fl === level, slab.framing_levels)
                attach_framing_level!(struc, slab, level)
            end
            beams = materialize_level!(struc, slab, level)
            if !isempty(beams)
                n_beams_generated += 1
            end
            @debug "populate_levels!: materialized framing level" slab_idx=level.slab_idx level=level.level role=level.role n_beams=length(beams) n_supports=length(level.supports)
            level_idx += 1
        end
    end

    # Layer-2+ tributary cascade (Phase 0 machinery): only refresh member
    # tributary profiles when we actually generated members, so the empty-opts
    # pipeline path is a strict no-op and leaves existing tributaries untouched.
    if n_beams_generated > 0
        # (1) Level-0 skeleton beams get their slab-face tributaries from the
        #     cell-edge merge; (2) the level-cascade then gives the generated
        #     joists their strip tributaries and flows each level's load down onto
        #     its `level.supports` hosts (P1(b) fix).
        compute_member_tributaries!(struc; strategy = :cell_merge)
        # The baseline was just rebuilt above; skip the redundant rebuild inside
        # the cascade (P2(e) idempotence fix, p5_eng_v3). The cascade still clears
        # the generated (`level ≥ 1`) members' stale deposits internally.
        cascade_framing_tributaries!(struc; reset_baseline = false)
    end
    return nothing
end

# -----------------------------------------------------------------------------
# cascade_framing_tributaries!  (Phase 5 — level-to-level tributary redistribution)
# -----------------------------------------------------------------------------

"""
    cascade_framing_tributaries!(struc::BuildingStructure) -> struc

Redistribute slab tributary load DOWN the auto-generated framing hierarchy, top
level first (plan `joists-roles-materials`, Phase 5, defect P1(b)). Complements
[`compute_member_tributaries!`](@ref): that pass fills only the Level-0 (skeleton)
beams' `tributary_profile`s from the cell-edge tributaries; this pass gives the
auto-generated joists (`level ≥ 1`) their strip tributaries and flows each level's
load onto the `level.supports` hosts one level below.

# Mechanics (entirely within Phase 0's `TributaryProfile` width machinery)
For every materialized [`FramingLevel`](@ref), processed top-down
(`level = maxlevel … 1`):

1. **Strip tributary.** Each `:joist` in the level directly supports the slab and
   carries a tributary strip whose width is the joist center-to-center spacing
   (`LinearAxisPattern.spacing`; see [`_level_strip_width_m`](@ref) for the other
   pattern types). The strip width is *added* uniformly to the joist's
   `tributary_profile` (created when `nothing`).
2. **Reaction hand-off.** Each level-`N` member that carries a tributary profile
   hands its load to the level-`N-1` hosts it lands on. The transferred quantity
   is the member's tributary AREA `(∫₀¹ w(s) ds)·L` — which already includes any
   load a higher level deposited onto it, so the cascade composes. It is split
   EQUALLY among the member's chain-vertex supports (an AREA-PRESERVING bookkeeping
   proxy — see the note below) and added to each host's profile as an equivalent
   tributary width `ΔA / L_host`.

The transfer is area-conservative and dimensionally consistent: a member's
tributary AREA (m²) becomes a host tributary WIDTH (m) via division by the host
length. The slab unit pressure never enters, so no load factor is invented — the
pressure would multiply both the joist reaction and the host demand identically
and cancels out of the width bookkeeping. Because profiles are always *added to*,
a Level-0 host ends with its own slab tributary (from `compute_member_tributaries!`)
plus the accumulated Level-1, Level-2, … contributions — the "Level-N loads flow
to Level-N-1 supports" contract. This is the seam Phase 10 generalizes (level
`k+1 → k`): the same top-down add works for any depth.

!!! note "Reaction split — EQUAL share (ENGINEERING JUDGMENT, not a code citation)"
    A member's total tributary area is split EQUALLY among its chain-vertex
    supports (endpoints and interior landings): each of the `n_sup` supports
    receives `area / n_sup`. This is an exactly AREA-PRESERVING bookkeeping proxy
    used ONLY for the T-beam flange (effective-width `sw`) and carbon accounting —
    it is deliberately NOT a code-based continuous-beam reaction distribution, and
    is NOT claimed to be conservative: the equal split OVER-CREDITS exterior-support
    flange width relative to a true continuous-beam reaction (whose exterior
    reactions are smaller). Reaction fidelity for defects #1/#2 is delivered by the
    elastic FEM solve (the joist-aware `to_asap!` routing), not by this width
    cascade. For a single-segment joist (level 1, 2 endpoint hosts) the equal
    split is the classic 50/50 "half-reactions to the two ends" rule
    (byte-identical to Phase 5); for a Phase-10 multi-segment joist every support
    receives an equal `A/n_sup` share.

    An ACI 318-19 §6.5.4 approximate-reaction split was intentionally NOT used
    here: §6.5.1(c) (L ≤ 3D) is unverifiable in this pressure-free area-only pass,
    and re-normalizing its coefficients to sum to the member area is not
    meaningfully better for a pure bookkeeping proxy — so the equal split is used
    for its exact area preservation and consistency with the Phase-10 A_L1
    contract, with real reaction fidelity left to the FEM solve.

    The host contribution is smeared UNIFORMLY along the host, not placed as a
    discrete point load at the landing station: `TributaryProfile` stores a
    piecewise-linear WIDTH profile only, so a zero-width reaction spike is not
    representable and the deposit is kept area-equivalent (a caller needing
    station-resolved point loads rebuilds the FEM load model, which is exactly
    what the joist-aware `to_asap!` routing does for member sizing).

Idempotence (`reset_baseline::Bool = true`, defect P2(e), p5_eng_v3): the pass
first restores every beam to its **pre-cascade slab-face-only** state, so a re-run
(including a *direct* call that bypasses `populate_levels!`) recomputes from
scratch instead of double-counting. When `reset_baseline` is `true` this is done
in two steps:

1. **Drop all prior tributary state.** Every beam's `tributary_profile` is set to
   `nothing`. This is stronger than merely re-running `compute_member_tributaries!`
   because `:cell_merge` only OVERWRITES beams that carry a slab cell tributary — a
   Level-0 host that receives cascade deposits but has no cell tributary of its own
   would otherwise keep its stale deposit and double-count on re-run.
2. **Rebuild the Level-0 slab-face baseline** via
   `compute_member_tributaries!(; strategy = :cell_merge)`, which re-derives each
   host's slab-face profile from the cell tributaries — the exact same baseline
   `populate_levels!` establishes immediately before calling this pass.

`populate_levels!` runs `compute_member_tributaries!` itself in the line above the
cascade call, so it passes `reset_baseline = false` to skip the redundant rebuild;
in that path only the generated members (`level ≥ 1`) need clearing (the caller
already supplied a fresh Level-0 baseline). `populate_levels!` only invokes this
pass when new members were generated. Generated members carry no slab cell
tributary, so `:cell_merge` never rebuilds them — they are always cleared
explicitly below regardless of `reset_baseline`.
"""
function cascade_framing_tributaries!(struc::BuildingStructure{T};
                                      reset_baseline::Bool = true) where {T}
    # Reset every beam to its pre-cascade slab-face-only baseline so the additive
    # pass never double-counts across repeated invocations. `populate_levels!`
    # runs `compute_member_tributaries!` immediately before this pass, so it passes
    # `reset_baseline = false` to avoid rebuilding the baseline twice.
    if reset_baseline
        # Clear ALL beams first: `:cell_merge` only overwrites beams that carry a
        # slab cell tributary, so a host that received cascade deposits but has no
        # cell tributary of its own would otherwise keep its stale deposit.
        for b in struc.beams
            b.tributary_profile = nothing
        end
        compute_member_tributaries!(struc; strategy = :cell_merge)
    end
    # Generated members (`level ≥ 1`) never carry a slab cell tributary, so
    # `:cell_merge` leaves them untouched; clear them explicitly. This is also the
    # only reset needed on the `reset_baseline = false` (populate_levels!) path.
    for b in struc.beams
        level_of(b) >= 1 && (b.tributary_profile = nothing)
    end

    # Collect materialized framing levels across all slabs.
    levels = FramingLevel{T}[]
    for slab in struc.slabs, fl in slab.framing_levels
        fl.group_id === nothing && continue
        push!(levels, fl)
    end
    isempty(levels) && return struc
    max_level = maximum(fl.level for fl in levels)

    # Top-down: highest level first, Level 1 last, so each level deposits onto a
    # host that will itself be processed (as a joist) at the next lower level.
    for N in max_level:-1:1
        for fl in levels
            fl.level == N || continue
            _cascade_one_level!(struc, fl, T)
        end
    end
    return struc
end

"""
Process one materialized [`FramingLevel`](@ref): assign the level's `:joist`
members their strip tributaries, then hand each member's tributary area down onto
the level's `supports` hosts (see [`cascade_framing_tributaries!`](@ref)).
"""
function _cascade_one_level!(struc::BuildingStructure, fl::FramingLevel, ::Type{T}) where {T}
    gid = fl.group_id
    (gid === nothing || !haskey(struc.member_groups, gid)) && return
    member_idxs = struc.member_groups[gid].member_indices
    isempty(member_idxs) && return

    # 1. Strip tributary for this level's joists (they directly support the slab).
    if fl.role === :joist
        strip_m = _level_strip_width_m(struc, fl)
        if strip_m !== nothing && strip_m > 0
            for mi in member_idxs
                _add_uniform_trib_width!(struc.beams[mi], strip_m, T)
            end
        end
    end

    # 2. Hand each member's tributary area down to its hosts (Phase 10).
    #    Distribute the beam's total tributary AREA EQUALLY among its chain-vertex
    #    supports (endpoints AND interior landings). This is an AREA-PRESERVING
    #    bookkeeping proxy for the flange/carbon accounting — NOT a code-based
    #    reaction distribution and NOT claimed conservative (see the ENGINEERING
    #    JUDGMENT note below). For a single-segment level-1 joist with 2 endpoint
    #    hosts this is the classic 50/50 rule (Phase 5 semantics preserved
    #    byte-identically); for a level-N joist chain each support gets an equal
    #    1/n_sup share.
    #
    #    Interior chain vertices that are NOT in `supports` (e.g. a level-(N-1)
    #    joist landing on a level-N beam that was subdivided by an even higher
    #    level, but the higher level came after this cascade recorded the
    #    supports) are ignored — they don't receive tributary. This is
    #    correct: those higher-level landings own their own supports list.
    supports = fl.supports
    isempty(supports) && return
    host_vertex_sets = _host_vertex_sets(struc, supports)
    host_accum_m2 = Dict{Int, Float64}()
    skel = struc.skeleton
    for mi in member_idxs
        beam = struc.beams[mi]
        area_m2 = _member_tributary_area_m2(struc, beam)
        area_m2 <= 0 && continue

        edges = [struc.segments[si].edge_idx for si in segment_indices(beam)]
        verts = _ordered_chain_vertices(skel, edges)

        # Chain vertices that resolve to a host in this level's `supports`, in
        # chain order. `_host_for_vertex` returns the same host for interior
        # landings on a multi-segment host, so we track (vertex → host) pairs.
        supports_on_chain = Tuple{Int, Int}[]     # (vertex_idx, host_beam_idx)
        for v in verts
            h = _host_for_vertex(v, supports, host_vertex_sets)
            h === nothing && continue
            push!(supports_on_chain, (v, h))
        end
        if isempty(supports_on_chain)
            # AREA PRESERVATION: this chain resolved to ZERO level-(N-1) supports,
            # so its tributary area cannot be handed down. Dropping it here (the old
            # behavior) silently vanished the area from the flange/carbon
            # bookkeeping — not area-preserving. Instead we RETAIN the area on the
            # chain itself: the member keeps its own `tributary_profile` (populated
            # in step 1 / by higher levels), so no area is lost from the total; it
            # simply is not additionally credited to a host below. Reaction fidelity
            # is unaffected (delivered by the FEM solve, not this width cascade).
            @warn "Framing cascade: joist chain has no resolved host support on the \
                   level below; retaining its tributary area on the chain (not \
                   handed down) to preserve total area." level = fl.level member_index = mi area_m2 = area_m2 maxlog = 8
            continue
        end

        # ENGINEERING JUDGMENT (NOT a code citation, NOT a proven safety bound):
        # split the member's tributary AREA EQUALLY among its chain-vertex supports
        # (endpoints and interior landings). This is an AREA-PRESERVING bookkeeping
        # proxy used ONLY for the T-beam flange (effective-width sw) and carbon
        # accounting; it deliberately does NOT model the true continuous-beam
        # reaction split and is NOT conservative — equal split OVER-CREDITS
        # exterior-support flange width versus a real continuous-beam reaction.
        # Reaction fidelity for defects #1/#2 is delivered by the elastic FEM solve
        # (the joist-aware `to_asap!` routing), not by this width cascade. Equal
        # split keeps the pass EXACTLY area-preserving — a single-span joist reduces
        # to the classic 50/50 rule — and matches the Phase-10 A_L1 equal-split
        # contract.
        n_sup = length(supports_on_chain)
        share_m2 = area_m2 / n_sup
        for (_, h) in supports_on_chain
            host_accum_m2[h] = get(host_accum_m2, h, 0.0) + share_m2
        end
    end

    # 3. Deposit each host's accumulated tributary area as an equivalent uniform
    #    width (area-conservative: ΔA / L_host).
    for (h, dA_m2) in host_accum_m2
        L_h_m = _member_length_m(struc.beams[h])
        L_h_m <= 0 && continue
        _add_uniform_trib_width!(struc.beams[h], dA_m2 / L_h_m, T)
    end
    return
end

# -- cascade helpers ----------------------------------------------------------

"""Length of a member in meters (Float64), stripping units when `T` is unitful."""
_member_length_m(beam) =
    (L = member_length(beam); L isa Unitful.Quantity ? ustrip(u"m", L) : Float64(L))

"""
Tributary AREA of a member in m²: `(∫₀¹ w(s) ds) · L`. Returns `0.0` when the
member has no tributary profile.
"""
function _member_tributary_area_m2(struc::BuildingStructure, beam)
    prof = beam.tributary_profile
    prof === nothing && return 0.0
    mean_w = tributary_average(prof)        # ∫₀¹ w(s) ds, in the width unit T
    mean_w_m = mean_w isa Unitful.Quantity ? ustrip(u"m", mean_w) : Float64(mean_w)
    return mean_w_m * _member_length_m(beam)
end

"""Add a constant tributary width `dw_m` (meters) uniformly to a beam's profile,
creating the profile when the beam has none."""
function _add_uniform_trib_width!(beam, dw_m::Float64, ::Type{T}) where {T}
    dw_m <= 0 && return
    dw_T = _len_T(T, dw_m)                   # meters → width unit T
    prof = beam.tributary_profile
    if prof === nothing
        beam.tributary_profile = TributaryProfile{T}([0.0, 1.0], T[dw_T, dw_T], nothing)
    else
        beam.tributary_profile = TributaryProfile{T}(copy(prof.positions),
                                                     T[w + dw_T for w in prof.widths],
                                                     prof.axis)
    end
    return
end

"""Ordered `(start_vertex, end_vertex)` of a member's segment chain."""
function _member_end_vertices(struc::BuildingStructure, beam)
    skel = struc.skeleton
    edges = [struc.segments[si].edge_idx for si in segment_indices(beam)]
    verts = _ordered_chain_vertices(skel, edges)
    return (verts[1], verts[end])
end

"""Map each host member index in `supports` to the set of skeleton vertices on
its segment chain (for landing → host resolution)."""
function _host_vertex_sets(struc::BuildingStructure, supports::Vector{Int})
    skel = struc.skeleton
    sets = Dict{Int, Set{Int}}()
    for h in supports
        (h < 1 || h > length(struc.beams)) && continue
        vs = Set{Int}()
        for si in segment_indices(struc.beams[h])
            si <= length(struc.segments) || continue
            v1, v2 = skel.edge_indices[struc.segments[si].edge_idx]
            push!(vs, v1); push!(vs, v2)
        end
        sets[h] = vs
    end
    return sets
end

"""First host in `supports` whose chain contains vertex `v`, or `nothing`."""
function _host_for_vertex(v::Int, supports::Vector{Int}, sets::Dict{Int, Set{Int}})
    for h in supports
        s = get(sets, h, nothing)
        s !== nothing && v in s && return h
    end
    return nothing
end

"""
    _level_strip_width_m(struc, fl) -> Union{Float64, Nothing}

Joist tributary strip width (meters) for a materialized level, dispatched on the
level's pattern. `LinearAxisPattern` → center-to-center `spacing` (the exercised
Phase-5 path). The other pattern types are best-effort (waffle currently yields no
rib grid, so `IsoparametricPattern`/`RadialPattern` are not exercised by the
Phase-5 slab types); `CustomPattern` has no well-defined width and returns
`nothing` with a warning.
"""
_level_strip_width_m(struc::BuildingStructure, fl::FramingLevel) =
    _pattern_strip_width_m(struc, fl, fl.pattern)

function _pattern_strip_width_m(struc::BuildingStructure, fl::FramingLevel,
                                pattern::LinearAxisPattern)
    if pattern.spacing !== nothing
        s = pattern.spacing isa Unitful.Quantity ?
            ustrip(u"m", pattern.spacing) : Float64(pattern.spacing)
        s > 0 && return s
    end
    # Fallback for a count-only pattern: infer the average center-to-center
    # spacing from the generated joists' perpendicular positions.
    return _infer_joist_spacing_m(struc, fl, pattern.axis)
end

function _pattern_strip_width_m(struc::BuildingStructure, fl::FramingLevel,
                                pattern::IsoparametricPattern)
    ext = _level_member_extent_m(struc, fl)
    ext === nothing && return nothing
    xext, yext = ext
    nx = max(pattern.n_xi, 1); ny = max(pattern.n_eta, 1)
    w = ((xext / (nx + 1)) + (yext / (ny + 1))) / 2   # representative rib spacing
    return w > 0 ? w : nothing
end

function _pattern_strip_width_m(struc::BuildingStructure, fl::FramingLevel,
                                pattern::RadialPattern)
    ext = _level_member_extent_m(struc, fl)
    ext === nothing && return nothing
    asp = pattern.angular_spacing isa Unitful.Quantity ?
        ustrip(u"rad", pattern.angular_spacing) : Float64(pattern.angular_spacing)
    w = asp * (maximum(ext) / 2)                      # angular pitch × representative radius
    return w > 0 ? w : nothing
end

function _pattern_strip_width_m(::BuildingStructure, fl::FramingLevel,
                                ::CustomPattern)
    @warn "cascade_framing_tributaries!: CustomPattern has no well-defined joist tributary width; leaving tributary_profile = nothing for framing level $(fl.level). Specify widths via the load model." maxlog=1
    return nothing
end

"""Average center-to-center spacing (meters) of a level's joists, inferred from
their midpoint projections onto the pattern axis' perpendicular. Fallback for a
count-only `LinearAxisPattern`."""
function _infer_joist_spacing_m(struc::BuildingStructure, fl::FramingLevel, axis)
    skel = struc.skeleton
    gid = fl.group_id
    (gid === nothing || !haskey(struc.member_groups, gid)) && return nothing
    a = _unit2((Float64(axis[1]), Float64(axis[2])))
    a == (0.0, 0.0) && return nothing
    perp = (-a[2], a[1])
    projs = Float64[]
    for mi in struc.member_groups[gid].member_indices
        v1, v2 = _member_end_vertices(struc, struc.beams[mi])
        mid = ((_vertex_xy_m(skel, v1)[1] + _vertex_xy_m(skel, v2)[1]) / 2,
               (_vertex_xy_m(skel, v1)[2] + _vertex_xy_m(skel, v2)[2]) / 2)
        push!(projs, _dot2(mid, perp))
    end
    length(projs) < 2 && return nothing
    sort!(projs)
    gaps = filter(>(1e-9), [projs[i + 1] - projs[i] for i in 1:(length(projs) - 1)])
    isempty(gaps) && return nothing
    return sum(gaps) / length(gaps)
end

"""Bounding-box `(x_extent, y_extent)` in meters of a level's member vertices."""
function _level_member_extent_m(struc::BuildingStructure, fl::FramingLevel)
    skel = struc.skeleton
    gid = fl.group_id
    (gid === nothing || !haskey(struc.member_groups, gid)) && return nothing
    xs = Float64[]; ys = Float64[]
    for mi in struc.member_groups[gid].member_indices
        for v in _member_end_vertices(struc, struc.beams[mi])
            xy = _vertex_xy_m(skel, v)
            push!(xs, xy[1]); push!(ys, xy[2])
        end
    end
    (isempty(xs) || isempty(ys)) && return nothing
    return (maximum(xs) - minimum(xs), maximum(ys) - minimum(ys))
end

# -----------------------------------------------------------------------------
# derive_framing_level
# -----------------------------------------------------------------------------

"""
    derive_framing_level(slab::Slab{T}, level_idx::Int, opts::NamedTuple) -> Union{Nothing, FramingLevel{T}}

Decide the [`FramingLevel`](@ref) a slab should carry at framing `level_idx`, or
`nothing` if none. Keyed on `slab.floor_type::Symbol` (the current slab-type
discriminator — see `StructuralSynthesizer/src/building_types/cells.jl`). Never
throws for an unrecognized slab type: unknown types return `nothing` gracefully.

# Idempotence / manual respect (checked first, all slab types)
- If the slab already carries a level at `level_idx` that has been
  **materialized** (`group_id !== nothing`) → `nothing` (don't re-stack).
- If it carries an attached but **not-yet-materialized** level at `level_idx`
  (e.g. a manual `attach_framing_level!`) → that level is returned so
  `populate_levels!` materializes it.

# Level-1 behavior by slab type

| `floor_type`                              | level-1 result |
|-------------------------------------------|----------------|
| `:waffle`                                 | `IsoparametricPattern` from the slab's `WaffleRibGrid` (via `joist_geometry`); monolithic RC, `role=:joist`, material from `opts.materials.beam`/`.concrete`. `nothing` today (waffle sizing returns a `CIPSlabResult` with no rib grid). |
| `:mass_timber_joist`                      | `LinearAxisPattern` from `joist_geometry(slab,1)` (result `joist_spacing` + `spans.axis`); `role=:joist`, material `opts.materials.timber`. |
| `:joist_roof_deck`                        | same as mass-timber, OWSJ; material `opts.materials.steel`. |
| `:one_way`/`:two_way`/`:composite_deck`/`:non_composite_deck` | opts-schema `LinearAxisPattern`: axis ⟂ `spans.axis`, spacing `opts.spacing` (or ENGINEERING-JUDGMENT default). `nothing` when no material resolvable from `opts`. |
| `:flat_plate`/`:flat_slab`/`:hollow_core`/`:vault`/`:grade`/`:clt`/`:dlt`/`:nlt` and any other | `nothing`. |

For `level_idx ≥ 2`, only an `opts.level_N` `NamedTuple` schema produces a level
(see [`populate_levels!`](@ref)).

!!! note "Non-nullable material"
    `FramingLevel.material::AbstractMaterial` (Phase 4) is not nullable, so a
    level can only be derived when a member material is resolvable. When the
    relevant `opts.materials.*` key is unset, this returns `nothing` rather than
    a partially specified level — the graceful "unset ⇒ no level" path.
"""
function derive_framing_level(slab::Slab{T}, level_idx::Int, opts::NamedTuple) where {T}
    # --- idempotence / manual respect (all slab types) ---
    existing = _existing_level(slab, level_idx)
    if existing !== nothing
        return existing.group_id === nothing ? existing : nothing
    end

    level_idx >= 2 && return _derive_level_schema(slab, level_idx, opts)

    ft = slab.floor_type
    if ft === :waffle || ft === :mass_timber_joist || ft === :joist_roof_deck
        pattern = StructuralSizer.joist_geometry(slab, level_idx)
        pattern === nothing && return nothing
        mat = ft === :waffle          ? _resolve_level_material(opts, :beam, :concrete) :
              ft === :mass_timber_joist ? _resolve_level_material(opts, :timber, :beam) :
                                          _resolve_level_material(opts, :steel, :beam)  # OWSJ
        mat === nothing && return nothing
        # `axis`/`count` are fixed by the sized joist geometry for these slab
        # types; only the release/catalog controls are honored from `opts`.
        return FramingLevel{T}(slab_idx = 0, level = level_idx, pattern = pattern,
                               role = :joist, material = mat,
                               end_fixity = get(opts, :end_fixity, (:default, :default)),
                               catalog_override = get(opts, :catalog_override, nothing))
    elseif ft === :one_way || ft === :two_way ||
           ft === :composite_deck || ft === :non_composite_deck
        return _derive_schema_level(slab, level_idx, opts)
    else
        # :flat_plate, :flat_slab, :hollow_core, :vault, :grade, :clt, :dlt,
        # :nlt, and any unrecognized floor type → no auto-generated framing.
        return nothing
    end
end

"""First level on `slab` whose `level == level_idx`, or `nothing`."""
function _existing_level(slab::Slab, level_idx::Int)
    idx = findfirst(fl -> fl.level == level_idx, slab.framing_levels)
    return idx === nothing ? nothing : slab.framing_levels[idx]
end

"""
First resolvable material among `keys` in `opts.materials`, or `nothing`. Used
to fill the (non-nullable) `FramingLevel.material` for slab types that do not
carry their own member material.
"""
function _resolve_level_material(opts::NamedTuple, keys::Symbol...)
    mats = get(opts, :materials, NamedTuple())
    mats isa NamedTuple || return nothing
    for k in keys
        m = get(mats, k, nothing)
        m isa AbstractMaterial && return m
    end
    return nothing
end

"""
opts-schema level for `:one_way` / `:two_way` / `:composite_deck` /
`:non_composite_deck` (level 1). Joists run ⟂ to `slab.spans.axis` at
`opts.spacing` (or an ENGINEERING-JUDGMENT default). Returns `nothing` when no
member material is resolvable from `opts.materials`.

Optional top-level `opts` keys are honored for this level-1 joist field:
`:axis` (joist run direction; defaults to ⟂ `slab.spans.axis`), `:count`
(explicit joist count), `:end_fixity`, and `:catalog_override`. These let a
caller override the schema-convention layout for the opts-schema slab types
(the joist-sizing slab types — mass-timber / OWSJ / waffle — take their level-1
geometry from the sized result instead; see [`derive_framing_level`](@ref)).
"""
function _derive_schema_level(slab::Slab{T}, level_idx::Int, opts::NamedTuple) where {T}
    mat = _resolve_level_material(opts, :steel, :beam, :timber)
    mat === nothing && return nothing
    axis = slab.spans.axis
    perp = (-axis[2], axis[1])              # joists ⟂ span axis (schema convention)
    joist_axis = get(opts, :axis, perp)
    spacing = _resolve_schema_spacing(T, opts, mat)
    pattern = LinearAxisPattern{T}(joist_axis, spacing, get(opts, :count, nothing))
    return FramingLevel{T}(slab_idx = 0, level = level_idx, pattern = pattern,
                           role = :joist, material = mat,
                           end_fixity = get(opts, :end_fixity, (:default, :default)),
                           catalog_override = get(opts, :catalog_override, nothing))
end

"""
Schema joist spacing (structure length unit `T`): `opts.spacing` if present,
else the ENGINEERING-JUDGMENT per-material default.
"""
function _resolve_schema_spacing(::Type{T}, opts::NamedTuple, mat::AbstractMaterial) where {T}
    sp = get(opts, :spacing, nothing)
    if sp !== nothing
        return _len_T(T, sp)
    end
    default_m = mat isa StructuralSizer.Timber ?
        _JUDGMENT_WOOD_JOIST_SPACING_M : _JUDGMENT_STEEL_JOIST_SPACING_M
    return _len_T(T, default_m)
end

"""
Level `N ≥ 2` from an explicit `opts.level_N` `NamedTuple` schema. The schema
carries at least `:material`; optional `:axis`, `:spacing`, `:role`
(`:joist`|`:beam`), `:count`, `:end_fixity`, `:catalog_override`.
Returns `nothing` when the key is absent or carries no material.

# Default axis (perpendicular alternation)
When the schema does not pin `:axis`, the level's joist run-direction alternates
so consecutive levels are mutually perpendicular (the standard girder →
secondary-beam → joist framing convention). Level 1's opts-schema joists run ⟂
to `slab.spans.axis` (see [`_derive_schema_level`](@ref)); so an even level
(2, 4, …) defaults to `slab.spans.axis` (⟂ to level 1) and an odd level ≥ 3
(3, 5, …) defaults to the perpendicular of `slab.spans.axis` (⟂ to level 2).
A prior bug hardcoded every level ≥ 2 to `slab.spans.axis`, which left Level 3
parallel to (instead of perpendicular to) Level 2.
"""
function _derive_level_schema(slab::Slab{T}, level_idx::Int, opts::NamedTuple) where {T}
    schema = get(opts, Symbol("level_$(level_idx)"), nothing)
    schema isa NamedTuple || return nothing
    mat = get(schema, :material, nothing)
    mat isa AbstractMaterial || return nothing
    # Default axis (perpendicular alternation): Level 1 (joists) defaults to
    # ⟂ slab.spans.axis. Even levels (2, 4, …) alternate to the preceding
    # level's axis — so Level 2 defaults to ⟂ Level 1 (parallel to slab axis).
    # A prior bug hardcoded alternation against the slab axis, not the
    # preceding level, which left Level 3 parallel to (instead of ⟂) Level 2.
    base_axis = slab.spans.axis
    perp_axis = (-base_axis[2], base_axis[1])
    
    default_axis = if level_idx == 1
        perp_axis
    else
        prev = _existing_level(slab, level_idx - 1)
        if prev !== nothing && prev.pattern isa LinearAxisPattern
            pax = prev.pattern.axis
            (-pax[2], pax[1])
        else
            # fallback for non-linear or missing level
            iseven(level_idx) ? base_axis : perp_axis
        end
    end
    axis = get(schema, :axis, default_axis)
    role = get(schema, :role, :beam)
    spacing = _resolve_schema_spacing(T, (; spacing = get(schema, :spacing, nothing)), mat)
    pattern = LinearAxisPattern{T}(axis, spacing, get(schema, :count, nothing))
    return FramingLevel{T}(slab_idx = 0, level = level_idx, pattern = pattern,
                           role = role, material = mat,
                           end_fixity = get(schema, :end_fixity, (:default, :default)),
                           catalog_override = get(schema, :catalog_override, nothing))
end

# -----------------------------------------------------------------------------
# materialize_level!
# -----------------------------------------------------------------------------

"""
    materialize_level!(struc::BuildingStructure, slab::Slab{T}, level::FramingLevel{T}) -> Vector{Beam{T}}

Turn one [`FramingLevel`](@ref) into real `Beam{T}` members (plan
`joists-roles-materials`, Phase 5). Material-agnostic — the material lives on
`level` and is applied at sizing time via the member group. Returns the created
joist beams (empty if the pattern lays out no joists on this slab).

# Steps
1. **Pattern → polylines.** [`_pattern_joist_lines`](@ref) resolves
   `level.pattern` to joist center-lines in the slab's local 2D frame, using the
   slab's real geometry for extent/count (`count === nothing` ⇒ derived from the
   slab extent and spacing so joists span the bay).
2. **Landings + host subdivision.** Each joist line's two ends are intersected
   with the slab's outer boundary edges; a skeleton vertex is inserted at each
   landing and the host edge is split into a multi-segment `edge_chains` chain
   (same surgery as `api/deserialize.jl`). Host member indices are recorded in
   `level.supports`.
3. **Joist Segments.** One `Segment` per joist, with `release_start`/`release_end`
   taken from `level.end_fixity` (`:default` ⇒ resolved later by Phase 2's
   `resolve_release` through the Phase-3 `default_release` dispatch — no release
   mechanics are decided here).
4. **Joist Beams.** `Beam{T}` with `role = level.role`, `level = level.level`,
   `lateral_role = :gravity`, `torsion_released = level.torsion_released`. The
   member material is recorded as a zero-volume `MaterialVolumes(level.material
   => 0 m³)` entry (sizing overwrites it), so the beam's material is discoverable
   before sizing.
5. **MemberGroup.** One group per level, `hash`ed from
   `(slab_idx, level, role, material)` and stamped on `level.group_id`. Its
   `catalog_override` is set from `level.catalog_override` (the Phase-6 seam
   `size_member_group!` routes to the material selector).

The layer-2+ tributary cascade (`compute_member_tributaries!`) is driven once by
[`populate_levels!`](@ref) after all levels are materialized, not per level.

!!! note "ENGINEERING JUDGMENT — lateral_role = :gravity"
    Auto-generated joists are created with `lateral_role = :gravity` (Phase 1
    convention: joists provide gravity load paths, not lateral-system
    participation, in the default model). This is a judgment default, not a code
    requirement; a caller wanting joists in the lateral system re-tags them
    afterward.

!!! note "Phase 7 seam (`:bridge` / `sync_asap!`)"
    Landings are recorded as real skeleton geometry (`edge_chains`), so a later
    `to_asap!` / `sync_asap!` sees the subdivided hosts and the joist edges
    directly — no `ParametricFrameElement` bridge is created here. Phase 7 wires
    seat eccentricity (`Element.eccentricity`) and shell-pressure routing on top
    of this geometry.
"""
function materialize_level!(struc::BuildingStructure, slab::Slab{T},
                            level::FramingLevel{T}) where {T}
    skel = struc.skeleton
    created = Beam{T}[]

    # (Phase 10) Extent (for laying out joist positions) always uses the slab
    # boundary — a level-N joist spans the same slab bay. Host set (for landing
    # intersections) generalizes: level 1 lands on boundary; level N ≥ 2 lands
    # on level-(N-1) beam edges PLUS the boundary (so a secondary beam can end
    # at the perimeter girder or run interior over multiple lower-level joists).
    extent_edges = _slab_boundary_sub_edges(struc, slab)
    host_edges = _level_host_edges(struc, slab, level.level)
    if isempty(host_edges) || isempty(extent_edges)
        level.group_id = _framing_group_id(level)   # mark materialized (idempotent)
        return created
    end

    # Floor elevation (all boundary edges of a slab are co-planar in Z).
    z_m = _vertex_z_m(skel, skel.edge_indices[first(extent_edges)][1])

    # edge → host beam index (for subdivision bookkeeping). Includes both
    # boundary sub-edges and level-(N-1) beam edges.
    edge_to_beam = _edge_to_beam_map(struc)

    # 1. Pattern → joist center-lines (p0, direction) in slab-local 2D meters,
    #    laid out over the SLAB extent (independent of the level's host set).
    lines = _pattern_joist_lines(struc, slab, extent_edges, level.pattern)

    # Concave-safe clipping guard (#5). `_pattern_joist_lines` lays joists across
    # the perpendicular bounding-extent of the slab and `_boundary_intersections`
    # casts an INFINITE line, so on a re-entrant (non-convex) slab a joist chain
    # built from ALL crossings would span a re-entrant notch (through the
    # exterior) or land outside the plate. When the slab's TRUE outer boundary is
    # non-convex we clip each joist line to its interior sub-span(s) (see
    # `_interior_subchains`). On a convex/rectangular boundary the whole span
    # between the two crossings is interior, so the clip is a strict no-op and the
    # layout is byte-identical to the pre-clip behavior — this guard skips the
    # clip path entirely for convex slabs. Pure geometry (no code provision).
    interior_poly = _slab_interior_polygon_m(struc, slab)
    clip_interior = interior_poly !== nothing && !Asap.is_convex_polygon(interior_poly)

    # 2. Resolve landings for each joist line.
    #    joist_chains :: Vector{Vector{Int}}  — ordered chain vertices per joist.
    #    edge_mids    :: Dict{host_edge => Vector{(param_u, vertex_idx)}}
    joist_chains = Vector{Int}[]
    edge_mids = Dict{Int, Vector{Tuple{Float64, Int}}}()
    landed_hosts = Set{Int}()

    for (p0, dir) in lines
        hits = _boundary_intersections(struc, host_edges, p0, dir)
        length(hits) < 2 && continue

        # (Phase 10) Collect ALL landings along the joist line, in order — not
        # just the two extremes. Each host edge crossing becomes an interior
        # support on the joist chain; consecutive-duplicate vertices (from
        # sharing an edge endpoint between adjacent hits) are dropped so the
        # chain is topologically clean. `chain_xy`/`chain_hosts` run parallel to
        # `chain_vs` for the concave clip (midpoint interiority) and host
        # bookkeeping.
        chain_vs = Int[]
        chain_xy = NTuple{2, Float64}[]
        chain_hosts = Int[]                       # host beam idx per vertex (0 ⇒ none)
        for (e, u, xy) in hits
            v = _landing_vertex!(skel, e, u, xy, z_m, edge_mids)
            (!isempty(chain_vs) && last(chain_vs) == v) && continue
            push!(chain_vs, v)
            push!(chain_xy, xy)
            push!(chain_hosts, get(edge_to_beam, e, 0))
        end
        length(chain_vs) < 2 && continue

        # Convex slab (or unresolved boundary): keep the full chain — the entire
        # span between the two boundary crossings is interior (no-op clip,
        # byte-identical to prior behavior). Non-convex slab: split into
        # interior-only sub-chains so no segment crosses a re-entrant notch.
        subchains = clip_interior ?
            _interior_subchains(chain_xy, interior_poly) :
            Vector{Int}[collect(1:length(chain_vs))]

        for idxs in subchains
            length(idxs) < 2 && continue
            push!(joist_chains, chain_vs[idxs])
            for i in idxs
                chain_hosts[i] != 0 && push!(landed_hosts, chain_hosts[i])
            end
        end
    end

    # 2b. Split each host edge once with all its (sorted) landing vertices.
    for (host_edge, mids) in edge_mids
        isempty(mids) && continue
        haskey(edge_to_beam, host_edge) || continue
        sort!(mids; by = first)                       # order along v1 → v2
        mid_vertices = [v for (_, v) in mids]
        _split_host_edge!(struc, edge_to_beam[host_edge], host_edge, mid_vertices, T)
    end

    # 3–4. Create a Segment + Beam per joist chain. A joist chain with `k`
    #      vertices produces `k-1` sub-segments threaded into a single Beam;
    #      interior joints (`k > 2`) stay continuous (`:fixed`) so the joist
    #      is a continuous beam over its intermediate hosts, and only the two
    #      chain endpoints honor `level.end_fixity`.
    joist_group = level.level == 1 ? :joists : :secondary
    beam_indices = Int[]
    for chain_vs in joist_chains
        n_seg = length(chain_vs) - 1
        seg_indices = Int[]
        for k in 1:n_seg
            v_a = chain_vs[k]
            v_b = chain_vs[k + 1]
            e_joist = add_element!(skel, v_a, v_b; group = joist_group)
            L_T = _len_T(T, Meshes.measure(skel.edges[e_joist]))
            rs = k == 1     ? level.end_fixity[1] : :fixed
            re = k == n_seg ? level.end_fixity[2] : :fixed
            seg = Segment(e_joist, L_T; Lb = L_T, Cb = 1.0,
                          release_start = rs, release_end = re)
            push!(struc.segments, seg)
            push!(seg_indices, length(struc.segments))
        end
        L_beam_T = sum(struc.segments[si].L for si in seg_indices)
        Lb_beam_T = maximum(struc.segments[si].Lb for si in seg_indices)
        beam = Beam(seg_indices, L_beam_T; Lb = Lb_beam_T,
                    role = level.role, level = level.level,
                    lateral_role = :gravity, torsion_released = level.torsion_released)
        # Record the member material (zero volume until sizing fills it in).
        # `_volume_key` unwraps ReinforcedConcreteMaterial → Concrete so downstream
        # `element_ec` can read `mat.ρ` (RC has no ρ field).
        set_volumes!(beam, MaterialVolumes(_volume_key(level.material) => zero(VolumeType)))
        push!(struc.beams, beam)
        push!(beam_indices, length(struc.beams))
        push!(created, beam)
    end

    # 5. One MemberGroup per level; propagate the catalog override (Phase 6 seam).
    gid = _framing_group_id(level)
    level.group_id = gid
    for bi in beam_indices
        set_group_id!(struc.beams[bi], gid)
    end
    if !isempty(beam_indices)
        struc.member_groups[gid] = MemberGroup(gid, beam_indices, nothing,
                                               level.catalog_override)
    end

    # Record the hosts this level landed on (member indices at level `level-1`
    # below — a mixture of level-0 girders and level-(N-1) joists for N ≥ 2).
    level.supports = sort!(collect(landed_hosts))

    # Refresh derived geometry (edge lengths for the new edges, etc.).
    rebuild_geometry_cache!(skel)

    return created
end

# -----------------------------------------------------------------------------
# Geometry helpers
# -----------------------------------------------------------------------------

"""Length in the structure's unit `T` from a raw Meshes measure (meters)."""
_len_T(::Type{T}, L) where {T} = T <: Unitful.Quantity ? convert(T, L) : ustrip(u"m", L)
_len_T(::Type{T}, x::Real) where {T} = T <: Unitful.Quantity ? convert(T, x * u"m") : convert(T, x)

"""Stable UInt64 group id for a level: `(slab_idx, level, role, material)`."""
_framing_group_id(level::FramingLevel) =
    hash((:framing_level, level.slab_idx, level.level, level.role, level.material))

"""
    _slab_boundary_edges(struc, slab) -> Vector{Int}

Edges on the outer boundary of `slab`, in the topological sense — an edge is
a slab boundary iff it belongs to exactly ONE of the slab's own faces.

A multi-cell slab's shared interior edges (between two of its own cells) are
excluded, and girders shared with an ADJACENT slab are included (they are on
this slab's perimeter, even though the adjacent slab also contains them).

This is deliberately *not* `edge_face_count(skel, e) == 1`, which is a
building-perimeter test — that would strip every interior girder shared
between adjacent slabs and leave corner/edge bays with only 1-2 boundary
edges, causing `materialize_level!` to fail to intersect joist lines on
per-bay slabs (Phase 11 follow-up: sparse-joist bug).
"""
function _slab_boundary_edges(struc::BuildingStructure, slab::Slab)
    skel = struc.skeleton

    slab_faces = Set{Int}()
    for cell_idx in slab.cell_indices
        push!(slab_faces, struc.cells[cell_idx].face_idx)
    end
    isempty(slab_faces) && return Int[]

    counts = Dict{Int, Int}()
    for f in slab_faces
        for e in skel.face_edge_indices[f]
            counts[e] = get(counts, e, 0) + 1
        end
    end

    out = [e for (e, c) in counts if c == 1]
    sort!(out)                                    # deterministic order
    return out
end

"""
    _slab_boundary_sub_edges(struc, slab) -> Vector{Int}

All boundary sub-edges of a slab, following any `_split_host_edge!` chains
recorded in `skel.edge_chains`. A prior level's joist landings on the boundary
subdivide the boundary edges, but `skel.face_edge_ids` still names the ORIGINAL
edge index (now truncated to its first sub-segment). Phase 10 needs the full
sub-edge list so a higher-level joist can intersect any part of the boundary,
not just the first sub-segment. Order along each original boundary edge is
preserved (`edge_chains` stores sub-edges in v1→v2 order — see
`_split_host_edge!`).
"""
function _slab_boundary_sub_edges(struc::BuildingStructure, slab::Slab)
    skel = struc.skeleton
    out = Int[]
    for E in _slab_boundary_edges(struc, slab)
        key = hash((:framing_host_chain, E))
        if haskey(skel.edge_chains, key)
            append!(out, skel.edge_chains[key])
        else
            push!(out, E)
        end
    end
    return out
end

"""
    _level_host_edges(struc, slab, level_idx) -> Vector{Int}

Host-edge candidates for a level's joist landings (Phase 10).

- **Level 1** → all slab boundary sub-edges (perimeter girders + any prior joist
  landings on the boundary).
- **Level `N ≥ 2`** → boundary sub-edges ∪ every edge of every level-`N-1` beam.
  A level-`N` joist crossing a level-`N-1` beam therefore lands on it as an
  interior support (the joist becomes a continuous chain over its host lattice).

The boundary is always included so a level-`N ≥ 2` joist can span from perimeter
to perimeter over interior level-`N-1` supports (the standard secondary-beam
convention). Returned indices are unique and sorted for determinism.
"""
function _level_host_edges(struc::BuildingStructure, slab::Slab, level_idx::Int)
    boundary = _slab_boundary_sub_edges(struc, slab)
    level_idx == 1 && return unique!(sort!(boundary))

    prev = level_idx - 1
    prev_edges = Int[]
    for b in struc.beams
        level_of(b) == prev || continue
        for si in segment_indices(b)
            si <= length(struc.segments) || continue
            push!(prev_edges, struc.segments[si].edge_idx)
        end
    end
    return unique!(sort!(vcat(boundary, prev_edges)))
end

"""Map each host beam's edges to its beam index (for subdivision bookkeeping)."""
function _edge_to_beam_map(struc::BuildingStructure)
    m = Dict{Int, Int}()
    for (bi, beam) in enumerate(struc.beams)
        for si in segment_indices(beam)
            si <= length(struc.segments) || continue
            m[struc.segments[si].edge_idx] = bi
        end
    end
    return m
end

"""XY of a skeleton vertex in meters (Float64)."""
function _vertex_xy_m(skel, v::Int)
    c = Meshes.coords(skel.vertices[v])
    return (ustrip(u"m", c.x), ustrip(u"m", c.y))
end

"""Z of a skeleton vertex in meters (Float64)."""
_vertex_z_m(skel, v::Int) = ustrip(u"m", Meshes.coords(skel.vertices[v]).z)

"""2D dot product."""
_dot2(a::NTuple{2, Float64}, b::NTuple{2, Float64}) = a[1] * b[1] + a[2] * b[2]

"""Unit-normalize a 2D direction; returns `(0,0)` for a zero vector."""
function _unit2(a::NTuple{2, Float64})
    n = hypot(a[1], a[2])
    n < 1e-12 && return (0.0, 0.0)
    return (a[1] / n, a[2] / n)
end

"""
    _pattern_joist_lines(struc, slab, host_edges, pattern) -> Vector{Tuple{NTuple{2,Float64}, NTuple{2,Float64}}}

Resolve `pattern` to joist center-lines in slab-local 2D meters, each a
`(point, unit-direction)` pair. Lines are extended infinitely; the boundary
crossings become the joist ends in `materialize_level!`, which additionally clips
each line to the slab interior on non-convex boundaries (see the concave-safe
guard there) so no joist crosses a re-entrant notch.
"""
function _pattern_joist_lines(struc::BuildingStructure, slab::Slab,
                              host_edges::Vector{Int},
                              pattern::LinearAxisPattern)
    skel = struc.skeleton
    a = _unit2(pattern.axis)
    a == (0.0, 0.0) && return Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[]
    perp = (-a[2], a[1])                         # joists laid out ⟂ to axis

    # Perpendicular extent of the slab boundary vertices.
    verts = Set{Int}()
    for e in host_edges
        v1, v2 = skel.edge_indices[e]
        push!(verts, v1); push!(verts, v2)
    end
    isempty(verts) && return Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[]
    projs = [_dot2(_vertex_xy_m(skel, v), perp) for v in verts]
    pmin, pmax = extrema(projs)
    W = pmax - pmin
    W <= 1e-9 && return Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[]

    positions = _joist_offsets(pattern, pmin, pmax, W)
    return [((q * perp[1], q * perp[2]), a) for q in positions]
end

# Non-linear patterns (isoparametric ribs, radial fans, custom generators) are
# resolved to straight center-lines spanning the slab. Only `LinearAxisPattern`
# is exercised by the Phase-5 slab types (waffle currently yields no rib grid),
# so these are best-effort straight-line resolutions built for completeness.
function _pattern_joist_lines(struc::BuildingStructure, slab::Slab,
                              host_edges::Vector{Int},
                              pattern::IsoparametricPattern)
    skel = struc.skeleton
    verts = Set{Int}()
    for e in host_edges
        v1, v2 = skel.edge_indices[e]
        push!(verts, v1); push!(verts, v2)
    end
    isempty(verts) && return Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[]
    xs = [_vertex_xy_m(skel, v)[1] for v in verts]
    ys = [_vertex_xy_m(skel, v)[2] for v in verts]
    xmin, xmax = extrema(xs); ymin, ymax = extrema(ys)
    lines = Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[]
    # ξ-family ribs (run along +y, laid out along x).
    for k in 1:pattern.n_xi
        x = xmin + k * (xmax - xmin) / (pattern.n_xi + 1)
        push!(lines, ((x, 0.0), (0.0, 1.0)))
    end
    # η-family ribs (run along +x, laid out along y).
    for k in 1:pattern.n_eta
        y = ymin + k * (ymax - ymin) / (pattern.n_eta + 1)
        push!(lines, ((0.0, y), (1.0, 0.0)))
    end
    return lines
end

function _pattern_joist_lines(struc::BuildingStructure, slab::Slab,
                              host_edges::Vector{Int},
                              pattern::RadialPattern)
    c = (Float64(pattern.center[1]), Float64(pattern.center[2]))
    return [(c, (cos(k * pattern.angular_spacing), sin(k * pattern.angular_spacing)))
            for k in 0:(pattern.n - 1)]
end

function _pattern_joist_lines(struc::BuildingStructure, slab::Slab,
                              host_edges::Vector{Int},
                              pattern::CustomPattern)
    polylines = pattern.generator(slab)
    lines = Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[]
    for pl in polylines
        length(pl) < 2 && continue
        p1 = (Float64(pl[1][1]), Float64(pl[1][2]))
        p2 = (Float64(pl[end][1]), Float64(pl[end][2]))
        d = _unit2((p2[1] - p1[1], p2[2] - p1[2]))
        d == (0.0, 0.0) && continue
        push!(lines, (p1, d))
    end
    return lines
end

"""
Interior joist perpendicular-offsets in `(pmin, pmax)`. With an explicit
`pattern.count`, `count` evenly spaced interior lines; otherwise laid out from
`pmin` at `pattern.spacing` intervals (spanning the bay). Returns `Float64[]`
when neither spacing nor count is resolved.
"""
function _joist_offsets(pattern::LinearAxisPattern, pmin::Float64, pmax::Float64, W::Float64)
    if pattern.count !== nothing
        n = pattern.count
        n <= 0 && return Float64[]
        return [pmin + k * W / (n + 1) for k in 1:n]
    end
    pattern.spacing === nothing && return Float64[]
    sp = pattern.spacing isa Unitful.Quantity ?
        ustrip(u"m", pattern.spacing) : Float64(pattern.spacing)
    sp <= 1e-9 && return Float64[]
    out = Float64[]
    q = pmin + sp
    while q < pmax - 1e-6
        push!(out, q)
        q += sp
    end
    return out
end

"""
Intersections of the infinite line `p0 + t*dir` with the slab boundary edges,
sorted by `t`. Each hit is `(edge_idx, param_u ∈ [0,1] on the edge, xy_on_edge)`.
The `xy` is taken from the host edge (`A + u*(B-A)`) so the landing lies exactly
on the edge.
"""
function _boundary_intersections(struc::BuildingStructure, host_edges::Vector{Int},
                                 p0::NTuple{2, Float64}, dir::NTuple{2, Float64})
    skel = struc.skeleton
    hits = Tuple{Float64, Int, Float64, NTuple{2, Float64}}[]   # (t, edge, u, xy)
    for e in host_edges
        v1, v2 = skel.edge_indices[e]
        A = _vertex_xy_m(skel, v1)
        B = _vertex_xy_m(skel, v2)
        res = _line_seg_intersect(p0, dir, A, B)
        res === nothing && continue
        t, u = res
        xy = (A[1] + u * (B[1] - A[1]), A[2] + u * (B[2] - A[2]))
        push!(hits, (t, e, u, xy))
    end
    sort!(hits; by = first)
    return [(e, u, xy) for (_, e, u, xy) in hits]
end

"""
    _slab_interior_polygon_m(struc, slab) -> Union{Nothing, Vector{NTuple{2, Float64}}}

The slab's TRUE outer boundary as an ordered XY polygon in meters (Float64),
reusing the concave-safe [`_get_slab_boundary_vertices`](@ref) loop (CCW, and
explicitly NOT a convex hull — it handles L/T/U re-entrant shapes). Returns
`nothing` when the boundary cannot be resolved or has fewer than three vertices,
so callers fall back to the un-clipped (convex) joist path. Used only to clip
joist center-lines to the slab interior (#5) — a geometry helper, not a
structural-mechanics decision, so no code clause applies.
"""
function _slab_interior_polygon_m(struc::BuildingStructure, slab::Slab)
    boundary_vis =
        try
            first(_get_slab_boundary_vertices(struc, slab))
        catch
            return nothing
        end
    length(boundary_vis) < 3 && return nothing
    return NTuple{2, Float64}[_vertex_xy_m(struc.skeleton, v) for v in boundary_vis]
end

"""
    _point_on_polygon_boundary(px, py, poly; tol) -> Bool

`true` when `(px, py)` lies within `tol` of any edge of the simple polygon `poly`
(i.e. ON the boundary). Used to make span interiority deterministic: an on-edge
sample point makes the even–odd ray cast [`_point_in_polygon_xy`](@ref) undefined
(a joist line collinear with a boundary edge), so such samples are rejected rather
than classified. Pure geometry — no mechanics.
"""
function _point_on_polygon_boundary(px::Float64, py::Float64,
                                    poly::Vector{NTuple{2, Float64}}; tol::Float64 = 1e-9)
    n = length(poly)
    tol2 = tol * tol
    for i in 1:n
        ax, ay = poly[i]
        bx, by = poly[mod1(i + 1, n)]
        ex = bx - ax; ey = by - ay
        L2 = ex * ex + ey * ey
        if L2 <= tol2                       # degenerate (zero-length) edge
            (px - ax)^2 + (py - ay)^2 <= tol2 && return true
            continue
        end
        # Closest point on segment AB to P, via the clamped projection parameter.
        t = clamp(((px - ax) * ex + (py - ay) * ey) / L2, 0.0, 1.0)
        cx = ax + t * ex; cy = ay + t * ey
        (px - cx)^2 + (py - cy)^2 <= tol2 && return true
    end
    return false
end

"""
    _interior_subchains(chain_xy, poly) -> Vector{Vector{Int}}

Split an ordered joist-line landing chain into maximal runs of consecutive
landings whose connecting span lies INSIDE the concave-safe slab polygon `poly`.
Interiority is decided per span by sampling SEVERAL interior points (not just the
midpoint) and requiring every sample to be strictly inside `poly` — via the
even–odd ray cast [`_point_in_polygon_xy`](@ref) — AND off the boundary (via
[`_point_on_polygon_boundary`](@ref)). Multi-point sampling plus the explicit
on-boundary rejection make the classification deterministic when a joist line is
collinear with a boundary edge (a single midpoint could land exactly on-edge,
where the ray cast is undefined) and robust for angled / non-rectilinear spans. A
span with any exterior or on-boundary sample (a re-entrant notch, or beyond the
plate) breaks the chain and that segment is dropped. Returns index runs into
`chain_xy`; single-vertex runs are discarded by the caller. Pure geometry — no
mechanics. (Only invoked for non-convex bays; convex/rectilinear layouts skip the
clip entirely in the caller, so their behavior is unchanged.)
"""
function _interior_subchains(chain_xy::Vector{NTuple{2, Float64}},
                             poly::Vector{NTuple{2, Float64}})
    n = length(chain_xy)
    runs = Vector{Int}[]
    n < 2 && return runs
    # On-boundary tolerance, RELATIVE to the slab extent. An absolute 1e-9 m is
    # wrong at scale: on a large plate coordinates carry more floating-point noise,
    # while on a tiny plate 1e-9 m could swallow a real feature. Scale the base
    # 1e-9 by a characteristic length (the polygon's bounding-box diagonal) so the
    # test is dimensionally sensible for any slab size. Pure geometry — no clause.
    xs = (p[1] for p in poly); ys = (p[2] for p in poly)
    char_len = hypot(maximum(xs) - minimum(xs), maximum(ys) - minimum(ys))
    bnd_tol = 1e-9 * max(char_len, 1.0)
    # Interior sample parameters along each span — deliberately NOT including the
    # endpoints (which sit on host edges) nor forcing a single midpoint.
    sample_ts = (0.15, 0.35, 0.5, 0.65, 0.85)
    current = Int[]
    for i in 1:(n - 1)
        ax, ay = chain_xy[i]
        bx, by = chain_xy[i + 1]
        span_interior = true
        # A span COLLINEAR with a boundary edge is dropped INTENTIONALLY: its
        # interior samples land on the boundary (rejected by `_point_on_polygon_
        # boundary`), so the whole span breaks the chain and no joist is laid there.
        # This is correct — that perimeter line is already carried by a level-0
        # girder, so a joist duplicating it would double the support and (via the
        # cascade) the tributary. Interior spans that merely graze a re-entrant
        # notch corner are likewise excluded, deferring that area to the per-cell
        # path. No mechanics — geometric span selection only.
        for t in sample_ts
            sx = ax + t * (bx - ax)
            sy = ay + t * (by - ay)
            if _point_on_polygon_boundary(sx, sy, poly; tol = bnd_tol) ||
               !_point_in_polygon_xy(sx, sy, poly)
                span_interior = false
                break
            end
        end
        if span_interior
            isempty(current) && push!(current, i)
            push!(current, i + 1)
        else
            length(current) >= 2 && push!(runs, current)
            current = Int[]
        end
    end
    length(current) >= 2 && push!(runs, current)
    return runs
end

"""
Intersect infinite line `p0 + t*dir` with segment `A→B`. Returns `(t, u)` with
`u ∈ [0, 1]` (clamped), or `nothing` for a parallel/degenerate case.
"""
function _line_seg_intersect(p0::NTuple{2, Float64}, dir::NTuple{2, Float64},
                             A::NTuple{2, Float64}, B::NTuple{2, Float64}; tol::Float64 = 1e-9)
    ex = B[1] - A[1]
    ey = B[2] - A[2]
    det = ex * dir[2] - ey * dir[1]        # (B-A) × dir
    abs(det) < tol && return nothing
    rx = A[1] - p0[1]
    ry = A[2] - p0[2]
    # Solve p0 + t dir = A + u (B-A):
    t = (rx * (-ey) + ex * ry) / det
    u = (dir[1] * ry - dir[2] * rx) / det
    (u < -tol || u > 1.0 + tol) && return nothing
    return (t, clamp(u, 0.0, 1.0))
end

"""
Add (or dedup) a landing vertex on host `edge` at parameter `u`; record it in
`edge_mids[edge]` when it is strictly interior to the edge (so the host is later
split there). Landings that coincide with an existing edge endpoint (`u ≈ 0/1`)
reuse that vertex and are NOT recorded as split points. Returns the vertex index.
"""
function _landing_vertex!(skel, edge::Int, u::Float64, xy::NTuple{2, Float64},
                          z_m::Float64, edge_mids::Dict{Int, Vector{Tuple{Float64, Int}}};
                          tol::Float64 = 1e-6)
    # P1(a) fix (p5_eng_v2): reuse the host edge endpoint when the landing
    # coincides with it (u ≈ 0 / 1) BEFORE creating any vertex. The prior body
    # always called `add_vertex!` first, so an endpoint landing produced a
    # coincident DUPLICATE vertex instead of joining the existing host vertex,
    # breaking topology / support continuity at the endpoint.
    v1, v2 = skel.edge_indices[edge]
    u <= tol && return v1
    u >= 1.0 - tol && return v2
    v = add_vertex!(skel, [xy[1], xy[2], z_m]; group = :framing_landings)
    push!(get!(Vector{Tuple{Float64, Int}}, edge_mids, edge), (u, v))
    return v
end

"""
Split host edge `E` (the member `host_beam_idx`) at the ordered interior vertices
`mids` (v1-side → v2-side), reusing `edge_chains`. Index-stable: the first
sub-edge reuses `E`; the rest are appended. New sub-segments are threaded onto
the host beam's `segment_indices`, interior joints made `:fixed` (continuous
girder), and the outer releases preserved.
"""
function _split_host_edge!(struc::BuildingStructure, host_beam_idx::Int, E::Int,
                           mids::Vector{Int}, ::Type{T}) where {T}
    skel = struc.skeleton
    v1, v2 = skel.edge_indices[E]
    chain_vs = vcat(v1, mids, v2)
    n_sub = length(chain_vs) - 1
    n_sub < 2 && return                       # nothing to split
    host_group = _edge_group(skel, E)

    seg_E_idx = findfirst(s -> s.edge_idx == E, struc.segments)
    seg_E_idx === nothing && return
    orig_seg = struc.segments[seg_E_idx]
    orig_rs, orig_re, orig_Cb = orig_seg.release_start, orig_seg.release_end, orig_seg.Cb

    sub_edges = Int[E]
    _rewire_edge!(skel, E, chain_vs[1], chain_vs[2])
    for k in 2:n_sub
        e_new = add_element!(skel, chain_vs[k], chain_vs[k + 1]; group = host_group)
        push!(sub_edges, e_new)
    end

    chain_seg_indices = Int[]
    for (k, e_sub) in enumerate(sub_edges)
        L_T = _len_T(T, Meshes.measure(skel.edges[e_sub]))
        rs = k == 1     ? orig_rs : :fixed     # interior joints stay continuous
        re = k == n_sub ? orig_re : :fixed
        if k == 1
            orig_seg.L = L_T
            orig_seg.Lb = L_T
            orig_seg.release_start = rs
            orig_seg.release_end = re
            push!(chain_seg_indices, seg_E_idx)
        else
            push!(struc.segments,
                  Segment(e_sub, L_T; Lb = L_T, Cb = orig_Cb,
                          release_start = rs, release_end = re))
            push!(chain_seg_indices, length(struc.segments))
        end
    end

    hb = struc.beams[host_beam_idx]
    hb.base.segment_indices = chain_seg_indices
    hb.base.L = sum(struc.segments[si].L for si in chain_seg_indices)
    hb.base.Lb = maximum(struc.segments[si].Lb for si in chain_seg_indices)

    # 2c. Update face-vertex and face-edge indices for all faces containing E
    #     to preserve topological consistency and CCW winding (defect P11).
    for f in 1:length(skel.face_edge_indices)
        f_edges = skel.face_edge_indices[f]
        E_idx = findfirst(==(E), f_edges)
        E_idx === nothing && continue

        f_verts = skel.face_vertex_indices[f]
        old_v_indices = copy(f_verts)

        # Orientation: is the face traversing E as v1->v2 or v2->v1?
        # f_edges[E_idx] connects f_verts[E_idx] and f_verts[next].
        if f_verts[E_idx] == v1
            # v1 -> v2: insert mids and sub_edges[2:end] after E
            splice!(f_verts, E_idx+1:E_idx, mids)
            splice!(f_edges, E_idx+1:E_idx, sub_edges[2:end])
        else
            # v2 -> v1: replace E with reverse(sub_edges) and insert reverse(mids)
            splice!(f_verts, E_idx+1:E_idx, reverse(mids))
            splice!(f_edges, E_idx:E_idx, reverse(sub_edges))
        end

        # Update lookup if enabled
        if skel.lookup !== nothing
            delete!(skel.lookup.face_index, sort(old_v_indices))
            skel.lookup.face_index[sort(f_verts)] = f
        end

        # Update Meshes.Polygon object for area/normal consistency
        skel.faces[f] = Meshes.Ngon(skel.vertices[f_verts]...)
    end

    skel.edge_chains[hash((:framing_host_chain, E))] = copy(sub_edges)
    return
end

"""Rewire existing edge index `E` to connect vertices `a → b` (graph + lookup)."""
function _rewire_edge!(skel, E::Int, a::Int, b::Int)
    old = skel.edge_indices[E]
    skel.edges[E] = Meshes.Segment(skel.vertices[a], skel.vertices[b])
    skel.edge_indices[E] = (a, b)
    Graphs.rem_edge!(skel.graph, old[1], old[2])
    Graphs.add_edge!(skel.graph, a, b)
    if skel.lookup !== nothing
        delete!(skel.lookup.edge_index, (old[1], old[2]))
        delete!(skel.lookup.edge_index, (old[2], old[1]))
        skel.lookup.edge_index[(a, b)] = E
        skel.lookup.edge_index[(b, a)] = E
    end
    return
end

"""Group symbol an edge index belongs to (first match), or `:beams`."""
function _edge_group(skel, E::Int)
    for (g, edges) in skel.groups_edges
        E in edges && return g
    end
    return :beams
end
