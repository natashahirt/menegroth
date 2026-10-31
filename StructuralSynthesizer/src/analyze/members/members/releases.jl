# =============================================================================
# End-release resolution (Phase 2)
# =============================================================================
#
# Segments own per-end fixity symbols (:default | :fixed | :pinned); the resolver
# collapses a beam's chain of segments plus its whole-member torsion flag to one
# of Asap's five element-release enums. `:default` symbols defer to the Phase 3
# `(role, material, lateral_role)` dispatch — `StructuralSizer.default_release`
# and `StructuralSizer.default_torsion_released` (declared in
# `StructuralSizer/src/members/defaults.jl`, per-material specializations in the
# material modules), imported here via `@reexport using StructuralSizer` in
# `StructuralSynthesizer.jl`.

# Allowed per-end segment release symbols.
const _RELEASE_SEGMENT_SYMS = (:default, :fixed, :pinned)

"""
    _release_enum(start_sym, end_sym, torsion_released) -> Symbol

Collapse a pair of resolved per-end fixity symbols (each `:fixed` or `:pinned`)
plus a whole-member torsion flag to one of Asap's five element-release enums
(`external/Asap/src/Elements/elements.jl`): `:fixedfixed`, `:freefixed`,
`:fixedfree`, `:freefree`, `:joist`. `torsion_released` only selects between
`:joist` and `:freefree` for the pinned–pinned case; it is irrelevant otherwise.

!!! note "`torsion_released` naming — reconciled in Phase 3 via docstring"
    Asap's `k_joist` kernel (`external/Asap/src/Elements/K.jl` line 293) is built
    from `E, A, L, G, J` — it **retains** axial and torsion and releases only
    bending, whereas `k_freefree` retains axial alone. Physically Asap's `:joist`
    therefore keeps torsion **fixed**, so the field name `torsion_released` reads
    as the inverse of the DOF state it selects. Phase 3 keeps the field name
    (Option A) and documents the intended meaning on `Beam.torsion_released`:
    `torsion_released == true` selects Asap's OWSJ-style `:joist` element (pinned
    bending ends, retained torsional `GJ`), it does **not** mean literal torsion
    release. The `(:pinned, :pinned) + torsion_released == true => :joist` mapping
    encodes that intent (steel OWSJ => Asap `:joist`).
"""
function _release_enum(start_sym::Symbol, end_sym::Symbol, torsion_released::Bool)
    start_sym === :fixed  && end_sym === :fixed  && return :fixedfixed
    start_sym === :pinned && end_sym === :fixed  && return :freefixed
    start_sym === :fixed  && end_sym === :pinned && return :fixedfree
    start_sym === :pinned && end_sym === :pinned && return torsion_released ? :joist : :freefree
    error("resolve_release: resolved end symbols must each be :fixed or :pinned, " *
          "got (start = $(start_sym), end = $(end_sym))")
end

"""
    _resolve_beam_end_symbols(beam, chain, material) -> (start_sym, end_sym, torsion_released)

Resolve a beam's outer end fixity symbols (`:fixed`/`:pinned`) and its
whole-member torsion flag, enforcing the chain-interior constraint.

`chain` is the ordered `Vector{Segment}` spanned by `beam` (same order as
`segment_indices(beam)`; the first segment's `release_start` is the member start
node, the last segment's `release_end` is the member end node).

Resolution rules:
- `:default` outer symbols defer to `default_release(role, material, lateral_role)`.
- Interior fixity symbols — every symbol other than the first segment's
  `release_start` and the last segment's `release_end` — must be `:fixed` (or
  `:default`, treated as `:fixed` for moment continuity across a shatter node).
  An explicit interior `:pinned` is an accidental mid-member hinge and errors,
  naming the offending segment.
- `torsion_released === nothing` defers to `default_torsion_released(role, material)`.
"""
function _resolve_beam_end_symbols(beam::Beam, chain::AbstractVector{<:Segment}, material)
    n = length(chain)
    n == 0 && error("resolve_release: beam has an empty segment chain")
    role = getfield(beam, :role)
    lateral_role = getfield(beam, :lateral_role)

    # Validate raw per-end symbols before interpreting them.
    for (i, seg) in enumerate(chain)
        seg.release_start in _RELEASE_SEGMENT_SYMS || error(
            "resolve_release: segment $i (edge $(seg.edge_idx)) has invalid " *
            "release_start = $(seg.release_start); expected one of $(_RELEASE_SEGMENT_SYMS)")
        seg.release_end in _RELEASE_SEGMENT_SYMS || error(
            "resolve_release: segment $i (edge $(seg.edge_idx)) has invalid " *
            "release_end = $(seg.release_end); expected one of $(_RELEASE_SEGMENT_SYMS)")
    end

    # Interior ends must be moment-continuous (:fixed or :default).
    _interior_ok(sym) = sym === :fixed || sym === :default
    _check_interior(sym, seg, which) =
        _interior_ok(sym) || error(
            "resolve_release: interior end (`$(which)`) of segment (edge " *
            "$(seg.edge_idx)) is `$(sym)`; chain-interior segments must be `:fixed` " *
            "(an interior `:pinned` would be an accidental mid-member hinge)")

    if n > 1
        _check_interior(chain[1].release_end, chain[1], :release_end)
        _check_interior(chain[n].release_start, chain[n], :release_start)
        for i in 2:(n - 1)
            _check_interior(chain[i].release_start, chain[i], :release_start)
            _check_interior(chain[i].release_end, chain[i], :release_end)
        end
    end

    raw_start = chain[1].release_start
    raw_end = chain[n].release_end

    # Resolve :default outer ends via the (role, material, lateral_role) dispatch.
    def_start, def_end = default_release(role, material, lateral_role)
    start_sym = raw_start === :default ? def_start : raw_start
    end_sym = raw_end === :default ? def_end : raw_end

    (start_sym in (:fixed, :pinned)) || error(
        "resolve_release: resolved start symbol `$(start_sym)` is not :fixed/:pinned")
    (end_sym in (:fixed, :pinned)) || error(
        "resolve_release: resolved end symbol `$(end_sym)` is not :fixed/:pinned")

    tors_raw = getfield(beam, :torsion_released)
    torsion_released = tors_raw === nothing ? default_torsion_released(role, material) : tors_raw

    return (start_sym, end_sym, torsion_released)
end

"""
    resolve_release(beam, chain, material) -> Symbol

Collapse a beam's per-segment `release_start`/`release_end` symbols and its
`torsion_released` flag to a single Asap element-release enum
(`:fixedfixed`, `:freefixed`, `:fixedfree`, `:freefree`, or `:joist`).

`chain` is the ordered `Vector{Segment}` spanned by `beam` (same order as
`segment_indices(beam)`; first segment's `release_start` is the member start, last
segment's `release_end` is the member end). Interior segments must be
moment-continuous, so an explicit interior `:pinned` errors. `:default` symbols
defer to the `(role, material, lateral_role)` dispatch
(`StructuralSizer.default_release` / `default_torsion_released`). A `nothing`
`material` (no beam material specified) resolves to fully-fixed ends, preserving
the prior all-`:fixedfixed` behavior.

For a shattered (multi-segment) chain this single symbol is the member-level
idealization; the per-element assignment used at Asap model construction is
[`resolve_edge_releases`](@ref).
"""
function resolve_release(beam::Beam, chain::AbstractVector{<:Segment}, material)
    start_sym, end_sym, torsion_released = _resolve_beam_end_symbols(beam, chain, material)
    return _release_enum(start_sym, end_sym, torsion_released)
end

"""
    resolve_edge_releases(beam, chain, material) -> Vector{Symbol}

Per-element release symbols for a beam's chain, in `chain` order (one symbol per
skeleton edge / Asap element). A single-segment chain yields
`[resolve_release(...)]`. For a shattered (multi-segment) chain the member's
resolved start fixity is applied to the first element, the resolved end fixity to
the last element, and every interior element is `:fixedfixed` — so a released
member end never turns an interior shatter node into an accidental mid-member
hinge.

Note: a member-level torsion release (`:joist`) cannot be represented on a
shattered chain (torsion continuity spans shatter nodes); such a member collapses
to `:freefixed`/`:fixedfree` outer elements. No producer currently emits
multi-segment released members (Phase 3/5 concern).
"""
function resolve_edge_releases(beam::Beam, chain::AbstractVector{<:Segment}, material)
    start_sym, end_sym, torsion_released = _resolve_beam_end_symbols(beam, chain, material)
    n = length(chain)
    n == 1 && return [_release_enum(start_sym, end_sym, torsion_released)]
    releases = fill(:fixedfixed, n)
    releases[1] = _release_enum(start_sym, :fixed, torsion_released)
    releases[n] = _release_enum(:fixed, end_sym, torsion_released)
    return releases
end

"""
    update_bracing!(struc; braced_by_slabs=true)

Update Lb for segments based on bracing conditions.

If `braced_by_slabs=true`, sets Lb=0 for any segment whose edge supports a slab
(top flange continuously braced by deck).
"""
function update_bracing!(struc::BuildingStructure{T}; braced_by_slabs::Bool=true) where T
    braced_by_slabs || return struc
    
    # Collect all edges that support slabs
    slab_edge_set = Set{Int}()
    for slab in struc.slabs
        for edge_idx in slab_face_edge_ids(struc, slab)
            push!(slab_edge_set, edge_idx)
        end
    end
    
    n_braced = 0
    for seg in struc.segments
        if seg.edge_idx in slab_edge_set
            seg.Lb = zero(seg.L)  # Fully braced by slab
            n_braced += 1
        end
    end
    
    @debug "Updated bracing: $(n_braced)/$(length(struc.segments)) segments braced by slabs (Lb=0)"
    return struc
end

