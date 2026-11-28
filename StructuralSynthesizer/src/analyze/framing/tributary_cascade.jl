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
    # The skeleton is already on the beams. A strip, and a hand-off of the
    # joist area onto the boundary, would count the panel a second time.
    if rib_analysis(fl) == :grillage
        _restore_grillage_joist_profiles!(struc, fl)
        return
    end
    member_idxs = level_member_indices(struc, fl)
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
    member_idxs = level_member_indices(struc, fl)
    isempty(member_idxs) && return nothing
    a = _unit2((Float64(axis[1]), Float64(axis[2])))
    a == (0.0, 0.0) && return nothing
    perp = (-a[2], a[1])
    projs = Float64[]
    for mi in member_idxs
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
    member_idxs = level_member_indices(struc, fl)
    isempty(member_idxs) && return nothing
    xs = Float64[]; ys = Float64[]
    for mi in member_idxs
        for v in _member_end_vertices(struc, struc.beams[mi])
            xy = _vertex_xy_m(skel, v)
            push!(xs, xy[1]); push!(ys, xy[2])
        end
    end
    (isempty(xs) || isempty(ys)) && return nothing
    return (maximum(xs) - minimum(xs), maximum(ys) - minimum(ys))
end

