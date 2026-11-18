function _size_slab_groups(groups, slab_specs, struc, material, floor_opts::StructuralSizer.AbstractFloorOptions;
                           col_I_factor::Real = 0.70, topping_span = nothing,
                           rib_bays = nothing)  # ACI 318-11 §10.10.4.1
    gids = collect(keys(groups))
    n = length(gids)
    
    results_vec  = Vector{AbstractFloorResult}(undef, n)
    sw_vec       = Vector{typeof(0.0u"kPa")}(undef, n)
    spans_vec    = Vector{SpanInfo}(undef, n)
    mats_vec     = Vector{Concrete}(undef, n)
    topping_vec  = Vector{Union{Nothing, NamedTuple}}(undef, n)
    opts_vec     = Vector{StructuralSizer.AbstractFloorOptions}(undef, n)
    
    @inbounds Threads.@threads for k in 1:n
        gid = gids[k]
        spec_idxs = groups[gid]
        specs = slab_specs[spec_idxs]
        result, sw_service, spans_gov, mat_eff, topping, opts_eff = _process_single_slab_group(
            gid, specs, struc, material, floor_opts;
            col_I_factor=col_I_factor, topping_span=topping_span, rib_bays=rib_bays)
        
        results_vec[k] = result
        sw_vec[k]      = sw_service
        spans_vec[k]   = spans_gov
        mats_vec[k]    = mat_eff
        topping_vec[k] = topping
        opts_vec[k]    = opts_eff
    end
    
    group_results = Dict{UInt64, AbstractFloorResult}(gids[k] => results_vec[k] for k in 1:n)
    group_sw      = Dict{UInt64, typeof(0.0u"kPa")}(gids[k] => sw_vec[k] for k in 1:n)
    group_spans   = Dict{UInt64, SpanInfo}(gids[k] => spans_vec[k] for k in 1:n)
    group_mats    = Dict{UInt64, Concrete}(gids[k] => mats_vec[k] for k in 1:n)
    group_toppings = Dict{UInt64, Union{Nothing, NamedTuple}}(gids[k] => topping_vec[k] for k in 1:n)
    group_opts    = Dict{UInt64, StructuralSizer.AbstractFloorOptions}(gids[k] => opts_vec[k] for k in 1:n)

    return group_results, group_sw, group_spans, group_mats, group_toppings, group_opts
end

"""Span-to-rise ratio of a vault whose options give neither `rise` nor `lambda` (project default, not a code value)."""
const DEFAULT_VAULT_LAMBDA = 10.0

"""
    _default_floor_options(floor_type::Symbol) -> AbstractFloorOptions

Default options for a slab whose floor type the request's options do not
describe. Systems without a sizer have no entry; their kernels throw
`UnsupportedFloorSystemError`.
"""
function _default_floor_options(floor_type::Symbol)
    floor_type === :vault          && return StructuralSizer.VaultOptions(lambda = DEFAULT_VAULT_LAMBDA)
    floor_type === :one_way        && return StructuralSizer.OneWayOptions()
    floor_type === :two_way        && return StructuralSizer.TwoWayOptions()
    floor_type === :flat_slab      && return StructuralSizer.FlatSlabOptions()
    floor_type === :composite_deck && return StructuralSizer.CompositeDeckOptions()
    return StructuralSizer.FlatPlateOptions()
end

"""`opts` when it describes `floor_type`, otherwise that type's defaults."""
_options_for_floor_type(opts::StructuralSizer.AbstractFloorOptions, floor_type::Symbol) =
    StructuralSizer.floor_symbol(opts) === floor_type ? opts : _default_floor_options(floor_type)

"""Size a single slab group: resolve governing demands, call the backend, return `(result, self_weight, spans)`."""
function _process_single_slab_group(gid, specs, struc, material, floor_opts::StructuralSizer.AbstractFloorOptions;
                                    col_I_factor::Real = 0.70, topping_span = nothing,
                                    rib_bays = nothing)  # ACI 318-11 §10.10.4.1
    ft_syms = unique(getfield.(specs, :floor_type))
    length(ft_syms) == 1 || throw(ArgumentError("Slab group $gid has mixed floor types: $(ft_syms)."))

    ft_sym = only(ft_syms)
    ft = StructuralSizer.floor_type(ft_sym)

    if ft isa Vault
        for s in specs
            length(s.cell_indices) == 1 || throw(ArgumentError("Vault slabs must be a single rectangular face; got a slab with $(length(s.cell_indices)) cells in group $gid."))
            cell = struc.cells[only(s.cell_indices)]
            _assert_rectangular_slab_face(struc, cell.face_idx)
        end
    end

    all_spans = [s.spans_gov for s in specs]
    spans_gov = StructuralSizer.governing_spans(all_spans)
    
    sdl_gov = maximum(getfield.(specs, :sdl_gov))
    live_gov = maximum(getfield.(specs, :live_gov))

    bay = (rib_bays === nothing || !(ft isa OneWay || ft isa TwoWay)) ? nothing :
        _governing_rib_bay(struc, specs, rib_bays[1], rib_bays[2])
    # An explicit spacing wins. Otherwise the rib bay is the topping span.
    # The center-to-center bay is longer than the clear distance, so this
    # thickness is not thinner than a clear-span topping.
    # One-way joists are not laid out yet, so their span count and panel
    # extents stay `nothing`; detailing reads them from the placed joists.
    topping = if !(ft isa OneWay || ft isa TwoWay)
        nothing
    elseif topping_span !== nothing && bay === nothing
        (span = topping_span, l2 = topping_span, n_spans = nothing, n_l2 = nothing,
         side = nothing, side_l2 = nothing)
    elseif topping_span !== nothing
        (span = topping_span, l2 = topping_span, n_spans = bay.n_spans, n_l2 = bay.n_l2,
         side = bay.side, side_l2 = bay.side_l2)
    elseif bay !== nothing
        (span = bay.span, l2 = bay.l2, n_spans = bay.n_spans, n_l2 = bay.n_l2,
         side = bay.side, side_l2 = bay.side_l2)
    else
        nothing
    end
    span_for_sizing = if ft isa StructuralSizer.CompositeDeck
        _governing_deck_span(struc, specs, floor_opts)
    elseif topping === nothing
        _sizing_span(ft, spans_gov)
    else
        topping.span
    end

    scoped_opts = unique([s.floor_opts_override for s in specs if hasproperty(s, :floor_opts_override) && !isnothing(s.floor_opts_override)])
    length(scoped_opts) <= 1 || throw(ArgumentError("Slab group $gid has conflicting floor options overrides."))
    effective_floor_opts = isempty(scoped_opts) ? floor_opts : only(scoped_opts)
    effective_floor_opts = _options_for_floor_type(effective_floor_opts, ft_sym)

    scoped_mats = unique([s.material_override for s in specs if hasproperty(s, :material_override) && !isnothing(s.material_override)])
    length(scoped_mats) <= 1 || throw(ArgumentError("Slab group $gid has conflicting material overrides."))
    effective_material = isempty(scoped_mats) ? material : only(scoped_mats)

    effective_floor_opts = _with_concrete_material(effective_floor_opts, effective_material)
    # ACI 318-11 §10.10.4.1 — scoped-override cells inherit the global column cracking factor
    effective_floor_opts = _apply_col_I_factor(effective_floor_opts, col_I_factor)

    extra_kwargs = if ft isa TwoWay
        # The short reinforcement-axis chord sets β (ACI 318-11 §9.5.3.3).
        # A ribbed floor's topping uses the rib spacing for both chords.
        spec0 = first(specs)
        l2 = topping === nothing ? min(spans_gov.primary, spans_gov.secondary) : topping.l2
        (l2 = l2,
         wall_supported = hasproperty(spec0, :wall_supported) && spec0.wall_supported,
         missing_edge_beam = hasproperty(spec0, :missing_edge_beam) && spec0.missing_edge_beam)
    elseif ft isa FlatPlate
        (thickness_only = true,)
    elseif ft isa Vault
        _preliminary_vault_geometry(effective_floor_opts, span_for_sizing)
    else
        NamedTuple()
    end
    cells = Int[]
    for s in specs
        append!(cells, s.cell_indices)
    end
    Lc = (ft isa OneWay || ft isa CompositeDeck) ? opening_cantilever_length(struc, cells) : nothing
    if Lc !== nothing && ft isa CompositeDeck
        @warn "composite deck group $gid has an unframed opening $(round(u"m", Lc; digits=2)) from a support; that strip is a cantilever"
        extra_kwargs = merge(extra_kwargs, (cantilever = Lc,))
    end
    if topping !== nothing
        extra_kwargs = merge(extra_kwargs, (joist_topping = true,))
    end
    result = StructuralSizer._size_span_floor(ft, span_for_sizing, sdl_gov, live_gov;
                                               material=effective_material, options=effective_floor_opts, extra_kwargs...)
    # Table 9.5(a): the strip from the support to the opening is a cantilever
    # of its own length. Keep it when it is thicker than the bay.
    if Lc !== nothing && ft isa OneWay && effective_floor_opts isa StructuralSizer.OneWayOptions
        cant_opts = StructuralSizer.OneWayOptions(effective_floor_opts.material,
            effective_floor_opts.cover, effective_floor_opts.bar_size, StructuralSizer.CANTILEVER)
        cant = StructuralSizer._size_span_floor(ft, Lc, sdl_gov, live_gov;
            material = effective_material, options = cant_opts)
        if StructuralSizer.total_depth(cant) > StructuralSizer.total_depth(result)
            @warn "one-way group $gid has an unframed opening $(round(u"m", Lc; digits=2)) from a support; its thickness is the cantilever"
            result = cant
        end
    end
    sw_service = StructuralSizer.self_weight(result)

    return result, sw_service, spans_gov, effective_material, topping, effective_floor_opts
end

"""
Longest distance the deck spans between beams.

A cell with fill beams spans the joist spacing. A cell with no fill beam
spans from one edge beam to the other (`spans.primary`). Slab sizing runs
before those beams are placed, so a bay longer than the profile's published
one-span unshored length is sized at the steel-joist spacing the fill beams
will use. The group is sized for the longer of those.
"""
function _governing_deck_span(struc, specs, floor_opts)
    limit = floor_opts isa StructuralSizer.CompositeDeckOptions ?
        StructuralSizer.max_unshored_simple_span(floor_opts.deck_profile) : nothing
    planned = _JUDGMENT_STEEL_JOIST_SPACING_M * u"m"
    worst = nothing
    for spec in specs, ci in spec.cell_indices
        s = _cell_deck_span(struc, ci)
        if limit !== nothing && s > limit && _slab_joist_spacing(struc, ci) === nothing
            s = min(s, uconvert(unit(s), planned))
        end
        worst = worst === nothing ? s : max(worst, s)
    end
    worst === nothing && throw(ArgumentError("a composite deck group has no cells"))
    return worst
end

"""Joist spacing on the slab that owns `cell_idx`, or `nothing`."""
function _slab_joist_spacing(struc, cell_idx)
    for slab in struc.slabs
        cell_idx in slab.cell_indices || continue
        for fl in slab.framing_levels
            fl.pattern isa LinearAxisPattern || continue
            sp = fl.pattern.spacing
            sp === nothing && continue
            return sp
        end
    end
    return nothing
end

"""`true` when a joist crosses this cell, including one that lands on its edge.

A joist may be one segment across several cells. The midpoint of that
segment sits in only one of them, so the test samples the segment and
also accepts a proper crossing of a cell edge.
"""
function _cell_crossed_by_joist(struc, cell_idx)
    skel = struc.skeleton
    face = struc.cells[cell_idx].face_idx
    poly = NTuple{2, Float64}[_vertex_xy_m(skel, v) for v in skel.face_vertex_indices[face]]
    for e in get(skel.groups_edges, :joists, Int[])
        v1, v2 = skel.edge_indices[e]
        a = _vertex_xy_m(skel, v1)
        b = _vertex_xy_m(skel, v2)
        _segment_meets_polygon(a, b, poly) && return true
    end
    return false
end

"""`true` when segment `a`–`b` enters `poly` or lands on its boundary."""
function _segment_meets_polygon(a, b, poly; tol::Float64 = 1e-3)
    for t in (0.0, 0.25, 0.5, 0.75, 1.0)
        p = (a[1] + t * (b[1] - a[1]), a[2] + t * (b[2] - a[2]))
        _point_in_polygon_xy(p[1], p[2], poly) && return true
        _point_on_polygon_boundary(p[1], p[2], poly; tol = tol) && return true
    end
    n = length(poly)
    for i in 1:n
        c = poly[i]
        d = poly[mod1(i + 1, n)]
        _segments_cross(a, b, c, d) && return true
    end
    return false
end

"""Proper crossing of segments `a`–`b` and `c`–`d`. Shared endpoints do not count."""
function _segments_cross(a, b, c, d)
    cross(p, q, r) = (q[1] - p[1]) * (r[2] - p[2]) - (q[2] - p[2]) * (r[1] - p[1])
    return cross(c, d, a) * cross(c, d, b) < 0 && cross(a, b, c) * cross(a, b, d) < 0
end

"""
Write the joist spacing onto each composite-deck slab the joists cross.

The beam bay stays on `spans`. The sheet's span is `topping_span`, which
the deck sizer reads. A slab with a cell the joists do not cross keeps the
bay, so the sheet is not sized for a span it does not have.
"""
function _record_deck_spans!(struc)
    for slab in struc.slabs
        slab.floor_type === :composite_deck || continue
        spans = []
        covered = true
        for ci in slab.cell_indices
            if !_cell_crossed_by_joist(struc, ci) ||
                    _slab_joist_spacing(struc, ci) === nothing
                covered = false
                break
            end
            push!(spans, _cell_deck_span(struc, ci))
        end
        (covered && !isempty(spans)) || continue
        extra = (topping_span = maximum(spans),)
        details = slab.design_details
        slab.design_details = details isa NamedTuple ? merge(details, extra) : extra
    end
    return struc
end

"""
Deck span of one cell.

A joist that crosses the cell carries the deck, so the span is the joist
spacing. Slab sizing runs before those joists are edges. A framing level
that already names the spacing is the spacing the edges will have, and the
deck spans that distance instead of the bay. A cell the joists do not cross,
once the edges exist, keeps the bay.
"""
function _cell_deck_span(struc, cell_idx)
    bay = struc.cells[cell_idx].spans.primary
    spacing = _slab_joist_spacing(struc, cell_idx)
    spacing === nothing && return bay
    edges = get(struc.skeleton.groups_edges, :joists, Int[])
    if isempty(edges) || _cell_crossed_by_joist(struc, cell_idx)
        return min(bay, uconvert(unit(bay), spacing))
    end
    return bay
end

"""
Rise for the initial vault estimate when the options give only bounds. The
analytical kernel needs a fixed rise; the design pass optimizes within the bounds.
"""
function _preliminary_vault_geometry(opts::StructuralSizer.VaultOptions, span)
    (opts.rise !== nothing || opts.lambda !== nothing) && return NamedTuple()
    if opts.rise_bounds !== nothing
        lo, hi = opts.rise_bounds
        return (rise = clamp(span / DEFAULT_VAULT_LAMBDA, lo, hi),)
    end
    lb = opts.lambda_bounds
    return (lambda = lb === nothing ? DEFAULT_VAULT_LAMBDA : clamp(DEFAULT_VAULT_LAMBDA, lb...),)
end

"""
Corners of one face, in the same order the rib pattern uses.

A single-cell slab boundary is this ring, made counter-clockwise.
"""
function _face_corners_m(struc, face_idx)
    boundary = Int[Int(v) for v in struc.skeleton.face_vertex_indices[face_idx]]
    StructuralSizer._ensure_ccw_vis!(boundary, struc.skeleton)
    poly = [_vertex_xy_m(struc.skeleton, v) for v in boundary]
    return _panel_corners(poly)
end

"""
Bay lengths of the panel with the longest span-direction bay.

Returns the rib-to-rib bays and the full side lengths. `span` is the bay
along the slab's span axis. `l2` is the bay the other way. `side` and
`side_l2` are the full panel edges those bays add up to.
"""
function _governing_rib_bay(struc, specs, nξ::Int, nη::Int)
    (nξ >= 1 && nη >= 1) || throw(ArgumentError(
        "a rib grid needs at least one bay each way, got $nξ by $nη"))
    best = nothing
    for spec in specs
        axis = spec.spans_gov.axis
        for ci in spec.cell_indices
            face = struc.cells[ci].face_idx
            corners = _face_corners_m(struc, face)
            length(corners) == 4 || throw(ArgumentError(
                "a grillage topping needs a quadrilateral panel, " *
                "and face $face has $(length(corners)) corners"))
            span_m, n_span, other_m, n_other, side_m, other_side_m =
                _bay_along_axis(corners, nξ, nη, axis)
            if best === nothing || span_m > best.span_m
                best = (span_m = span_m, n_spans = n_span, other_m = other_m,
                        n_other = n_other, side_m = side_m, other_side_m = other_side_m)
            end
        end
    end
    best === nothing && throw(ArgumentError("a grillage topping has no panel"))
    return (span = best.span_m * u"m", l2 = best.other_m * u"m",
            n_spans = best.n_spans, n_l2 = best.n_other,
            side = best.side_m * u"m", side_l2 = best.other_side_m * u"m")
end

"""`(span_m, n_spans, other_m, n_other, side_m, other_side_m)` along `axis`."""
function _bay_along_axis(corners, nξ::Int, nη::Int, axis)
    eξ = (corners[2][1] - corners[1][1], corners[2][2] - corners[1][2])
    eη = (corners[4][1] - corners[1][1], corners[4][2] - corners[1][2])
    Lξ = hypot(eξ[1], eξ[2])
    Lη = hypot(eη[1], eη[2])
    (Lξ > 1e-9 && Lη > 1e-9) || throw(ArgumentError("a rib panel has a zero side"))
    bξ, bη = Lξ / nξ, Lη / nη
    ax = (Float64(axis[1]), Float64(axis[2]))
    nax = hypot(ax[1], ax[2])
    if nax < 1e-9
        return bξ >= bη ? (bξ, nξ, bη, nη, Lξ, Lη) : (bη, nη, bξ, nξ, Lη, Lξ)
    end
    uξ = (eξ[1] / Lξ, eξ[2] / Lξ)
    uη = (eη[1] / Lη, eη[2] / Lη)
    uax = (ax[1] / nax, ax[2] / nax)
    along_ξ = abs(uξ[1] * uax[1] + uξ[2] * uax[2]) >= abs(uη[1] * uax[1] + uη[2] * uax[2])
    return along_ξ ? (bξ, nξ, bη, nη, Lξ, Lη) : (bη, nη, bξ, nξ, Lη, Lξ)
end

"""Copy of `opts` with field `name` set to `value`; every other field is kept."""
_replace_field(opts::T, name::Symbol, value) where {T} =
    T((f === name ? value : getfield(opts, f) for f in fieldnames(T))...)

"""Concrete swapped into a reinforced-concrete material; rebar and transverse steel kept."""
_with_concrete(rc::ReinforcedConcreteMaterial, concrete::Concrete) =
    ReinforcedConcreteMaterial(concrete, rc.rebar, rc.transverse)

"""Replace concrete grade in floor options while preserving rebar/detail settings."""
_with_concrete_material(opts::Union{StructuralSizer.FlatPlateOptions,
                                    StructuralSizer.TwoWayOptions,
                                    StructuralSizer.OneWayOptions}, concrete::Concrete) =
    _replace_field(opts, :material, _with_concrete(opts.material, concrete))

_with_concrete_material(opts::StructuralSizer.FlatSlabOptions, concrete::Concrete) =
    _replace_field(opts, :base, _with_concrete_material(opts.base, concrete))

_with_concrete_material(opts::StructuralSizer.VaultOptions, concrete::Concrete) =
    _replace_field(opts, :material, concrete)

_with_concrete_material(opts::StructuralSizer.AbstractFloorOptions, ::Concrete) = opts
