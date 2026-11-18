# ==============================================================================
# Bar placement for a designed building
# ==============================================================================
#
# Reads the sized sections and the building geometry and calls the StructuralSizer
# detailers. Supports, continuity, and the slab above a column come from the
# skeleton; materials come from the same options the sizers used.
# ==============================================================================

"""
    BuildingDetail

Placed bars of a designed building, keyed by the design index of each member.
`errors` holds members whose detailing threw, keyed `"kind:index"`.
"""
struct BuildingDetail
    columns::Dict{Int, StructuralSizer.MemberDetail}
    beams::Dict{Int, StructuralSizer.MemberDetail}
    slabs::Dict{Int, StructuralSizer.MemberDetail}
    footings::Dict{Int, StructuralSizer.MemberDetail}
    walls::Dict{Int, StructuralSizer.MemberDetail}
    errors::Dict{String, String}
end

BuildingDetail() = BuildingDetail(Dict{Int, StructuralSizer.MemberDetail}(),
                                  Dict{Int, StructuralSizer.MemberDetail}(),
                                  Dict{Int, StructuralSizer.MemberDetail}(),
                                  Dict{Int, StructuralSizer.MemberDetail}(),
                                  Dict{Int, StructuralSizer.MemberDetail}(),
                                  Dict{String, String}())

"""Total placed bar mass of the building, kg."""
function building_detail_mass(bd::BuildingDetail)
    total = 0.0u"kg"
    for dict in (bd.columns, bd.beams, bd.slabs, bd.footings, bd.walls), md in values(dict)
        total += StructuralSizer.detail_mass(md)
    end
    return total
end

const _RC_COLUMN = Union{StructuralSizer.RCColumnSection, StructuralSizer.RCCircularSection}
const _RC_BEAM = Union{StructuralSizer.RCBeamSection, StructuralSizer.RCTBeamSection}

# ── Materials ──────────────────────────────────────────────────────────────

"True in Seismic Design Category D, E, or F, once the lateral stage has stored it."
_high_sdc(design) = something(design.structure.site.sdc, :B) in (:D, :E, :F)

"A concrete-and-rebar bundle the column shear diagram can read, or nothing."
function _rc_bundle(conc, rebar, transverse)
    base = conc isa StructuralSizer.ReinforcedConcreteMaterial ? conc.concrete :
           conc isa StructuralSizer.Concrete ? conc : nothing
    steel = rebar isa StructuralSizer.RebarSteel ? rebar : nothing
    if base === nothing || steel === nothing
        return nothing
    end
    ties = transverse isa StructuralSizer.RebarSteel ? transverse : steel
    return StructuralSizer.ReinforcedConcreteMaterial(base, steel, ties)
end

"""Concrete, longitudinal rebar, and transverse rebar of the column sizer."""
function _column_materials(params::DesignParameters, col)
    opts = params.columns
    if opts isa StructuralSizer.ConcreteColumnOptions
        conc = something(col.concrete, opts.material)
        return conc, opts.rebar_material, something(opts.transverse_rebar_material, opts.rebar_material)
    end
    m = params.materials
    rebar = resolve_column_rebar(m)
    return something(col.concrete, resolve_column_concrete(m)), rebar, rebar
end

"""Concrete, longitudinal rebar, and transverse rebar of the beam sizer."""
function _beam_materials(params::DesignParameters)
    opts = params.beams
    if opts isa StructuralSizer.ConcreteBeamOptions
        return opts.material, opts.rebar_material,
               something(opts.transverse_rebar_material, opts.rebar_material)
    end
    m = params.materials
    rebar = something(m.rebar, StructuralSizer.Rebar_60)
    return something(m.concrete, StructuralSizer.NWC_4000), rebar, rebar
end

"""Spread footing parameters the foundation sizer used."""
function _spread_params(params::DesignParameters)
    fo = params.foundation_options
    return isnothing(fo) ? StructuralSizer.FoundationOptions().spread_params : fo.options.spread_params
end

"""Slab RC material and clear cover the flat plate sizer used."""
function _slab_materials(params::DesignParameters)
    floor = params.floor
    floor isa StructuralSizer.FlatSlabOptions && (floor = floor.base)
    if floor isa StructuralSizer.FlatPlateOptions ||
       floor isa StructuralSizer.OneWayOptions ||
       floor isa StructuralSizer.TwoWayOptions
        return floor.material, floor.cover
    end
    return resolve_slab_rc(params.materials), StructuralSizer.FlatPlateOptions().cover
end

# ── Geometry ───────────────────────────────────────────────────────────────

"""`(bottom_vertex, top_vertex)` of a column's segment chain."""
function _column_end_vertices(struc::BuildingStructure, col)
    a, b = _member_end_vertices(struc, col)
    skel = struc.skeleton
    return _vertex_z_m(skel, a) <= _vertex_z_m(skel, b) ? (a, b) : (b, a)
end

"""
Vertex maps of a structure, built once per [`detail_building`](@ref) call.

- `col_top`, `col_bottom`: column index by the vertex at its top or bottom.
- `beam_ends`: `(start, end)` vertices of each beam.
- `beam_through`: beams whose chain passes through a vertex without ending there.
"""
function _detail_geometry(struc::BuildingStructure)
    col_top, col_bottom = Dict{Int, Int}(), Dict{Int, Int}()
    for (i, col) in enumerate(struc.columns)
        isempty(segment_indices(col)) && continue
        bot, top = _column_end_vertices(struc, col)
        col_top[top] = i
        col_bottom[bot] = i
    end
    beam_ends = Vector{NTuple{2, Int}}(undef, length(struc.beams))
    beam_through = Dict{Int, Vector{Int}}()
    for (bi, beam) in enumerate(struc.beams)
        edges = [struc.segments[s].edge_idx for s in segment_indices(beam)]
        verts = _ordered_chain_vertices(struc.skeleton, edges)
        beam_ends[bi] = (verts[1], verts[end])
        for v in verts[2:(end - 1)]
            push!(get!(beam_through, v, Int[]), bi)
        end
    end
    model = struc.asap_model
    has_joists = any(b -> is_joist(b), struc.beams)
    elemental_loads = (has_joists && model !== nothing && !isempty(model.frame_elements)) ?
        Asap.get_elemental_loads(model) : nothing
    return (; col_top, col_bottom, beam_ends, beam_through, elemental_loads)
end

"""Width of a column along the unit plan direction `dir`, meters."""
function _column_width_along(cr::ColumnDesignResult, col, dir::NTuple{2, Float64})
    c1, c2 = ustrip(u"m", cr.c1), ustrip(u"m", cr.c2)
    cr.shape === :circular && return c1
    θ = col.θ
    along1 = abs(cos(θ) * dir[1] + sin(θ) * dir[2])
    along2 = abs(-sin(θ) * dir[1] + cos(θ) * dir[2])
    return along1 * c1 + along2 * c2
end

"""Unit plan direction from vertex `a` to vertex `b`."""
function _plan_dir(skel, a::Int, b::Int)
    pa, pb = _vertex_xy_m(skel, a), _vertex_xy_m(skel, b)
    d = (pb[1] - pa[1], pb[2] - pa[2])
    n = hypot(d...)
    return n > 1e-9 ? (d[1] / n, d[2] / n) : (1.0, 0.0)
end

"""
Support width at beam end vertex `v` along `dir`, meters: the column below,
else the column above, else the web of a beam passing through the vertex.
`nothing` when no support is found.
"""
function _beam_support_width(design::BuildingDesign, geo, v::Int, dir)
    struc = design.structure
    for ci in (get(geo.col_top, v, 0), get(geo.col_bottom, v, 0))
        cr = get(design.columns, ci, nothing)
        cr === nothing && continue
        return _column_width_along(cr, struc.columns[ci], dir)
    end
    for bi in get(geo.beam_through, v, Int[])
        br = get(design.beams, bi, nothing)
        br === nothing && continue
        sec = br.section_obj
        sec isa StructuralSizer.RCBeamSection && return ustrip(u"m", sec.b)
        sec isa StructuralSizer.RCTBeamSection && return ustrip(u"m", sec.bw)
    end
    return nothing
end

"""
True when §12.12.4 forces were calculated for this member and they do not
exceed the design strength, so §18.14.3.2 applies.
"""
function _induced_within_strength(design, kind, idx)
    result = design.structure.ordinary_wall_result
    result === nothing && return false
    for check in result.induced
        if check.kind === kind && check.index === idx
            return check.calculated && !check.exceeds
        end
    end
    return false
end

"""
Factored gravity axial stored with the δDE check, or `nothing`.

That axial is `1.2D + 1.6L + 0.2·SDS·D`. It includes the vertical ground
motion of ACI 318-19 §18.14.2.1 and it does not include Eh. §18.14.3.2(c)
uses it as the factored gravity axial.
"""
function _induced_gravity_pu(design, kind, idx)
    result = design.structure.ordinary_wall_result
    result === nothing && return nothing
    for check in result.induced
        if check.kind === kind && check.index === idx && check.calculated
            return check.Pu_N * u"N"
        end
    end
    return nothing
end

"""True when another beam leaves vertex `v` in the direction `dir` (continuity)."""
function _beam_continues(struc::BuildingStructure, geo, v::Int, dir, self_idx::Int)
    skel = struc.skeleton
    for (bi, (a, b)) in enumerate(geo.beam_ends)
        bi == self_idx && continue
        other = a == v ? b : b == v ? a : 0
        other == 0 && continue
        d = _plan_dir(skel, v, other)
        d[1] * dir[1] + d[2] * dir[2] > 0.98 && return true
    end
    return false
end

"""Slab or beam depth at the top of a column, and the slab cover, meters."""
function _column_top_depth(design::BuildingDesign, geo, col, top::Int)
    struc = design.structure
    cells = col.tributary_cell_indices
    best = 0.0
    for (si, sr) in design.slabs
        si <= length(struc.slabs) || continue
        any(c -> c in cells, struc.slabs[si].cell_indices) || continue
        best = max(best, ustrip(u"m", sr.thickness))
    end
    for (bi, br) in design.beams
        bi <= length(struc.beams) || continue
        sec = br.section_obj
        sec isa _RC_BEAM || continue
        (top in geo.beam_ends[bi] || bi in get(geo.beam_through, top, Int[])) || continue
        best = max(best, ustrip(u"m", sec.h))
    end
    return best
end

# ── Members ────────────────────────────────────────────────────────────────

function _detail_column(design::BuildingDesign, geo, idx::Int)
    struc = design.structure
    cr = design.columns[idx]
    sec = cr.section_obj
    sec isa _RC_COLUMN || return nothing
    col = struc.columns[idx]
    conc, rebar, transverse = _column_materials(design.params, col)
    _, top = _column_end_vertices(struc, col)
    depth = _column_top_depth(design, geo, col, top)
    _, slab_cover = _slab_materials(design.params)
    seismic = _high_sdc(design)
    within = _induced_within_strength(design, :column, idx)
    md = StructuralSizer.detail_column(sec; height = cr.height, slab_above = depth * u"m",
        slab_cover = depth > 0 ? slab_cover : 0.0u"m",
        continues = !isnothing(col.column_above),
        fc = conc.fc′, fy = rebar.Fy, fyt = transverse.Fy, λ = conc.λ,
        coating = rebar.coating,
        tie_spacing = cr.tie_spacing > 0u"m" ? cr.tie_spacing : nothing,
        gravity_seismic = seismic && !within,
        induced_within_strength = within,
        material = seismic ? _rc_bundle(conc, rebar, transverse) : nothing,
        axials = (cr.Pu,), Vu_x = cr.Vu_x, Vu_y = cr.Vu_y, Pu = cr.Pu,
        Pu_gravity = _induced_gravity_pu(design, :column, idx))
    depth > 0 || push!(md.notes, "No slab or beam found at the column top; ties run to the top.")
    return md
end

function _detail_beam(design::BuildingDesign, geo, idx::Int)
    idx in geo.solid_beams && return _detail_solid_head_piece(design, geo, idx)
    struc = design.structure
    br = design.beams[idx]
    sec = br.section_obj
    sec isa _RC_BEAM || return nothing
    a, b = geo.beam_ends[idx]
    skel = struc.skeleton
    dir = _plan_dir(skel, a, b)
    back = (-dir[1], -dir[2])
    # A rib that meets a solid head is supported at the head face: the clear
    # span ends there and the bars run into the head as at a continuous support.
    ca = _continues_in(struc, geo, a, back, idx, geo.solid_beams) ? 0.0 :
         _beam_support_width(design, geo, a, dir)
    cb = _continues_in(struc, geo, b, dir, idx, geo.solid_beams) ? 0.0 :
         _beam_support_width(design, geo, b, dir)
    if ca === nothing || cb === nothing
        md = StructuralSizer.MemberDetail(:beam)
        push!(md.warnings, "beam supports were not found at both ends; bars are not placed")
        return md
    end
    conc, rebar, transverse = _beam_materials(design.params)
    exterior = (!_beam_continues(struc, geo, a, back, idx), !_beam_continues(struc, geo, b, dir, idx))
    beam = struc.beams[idx]
    top_bars, hog = nothing, nothing
    from_envelope = beam.Mu_neg_envelope !== nothing
    if is_joist(beam)
        hog = from_envelope ? beam.Mu_neg_envelope * u"N*m" :
            _joist_end_hogging(struc, beam, geo.elemental_loads)
        if hog !== nothing && hog > 1.0u"N*m"
            top_bars = StructuralSizer.hogging_bars(sec, hog, conc.fc′, rebar.Fy)
        end
    end
    md = StructuralSizer.detail_beam(sec; span = br.member_length,
        supports = (ca * u"m", cb * u"m"), exterior = exterior,
        fc = conc.fc′, fy = rebar.Fy, fyt = transverse.Fy, λ = conc.λ,
        coating = rebar.coating, Vu = br.Vu, top_bars = top_bars,
        gravity_seismic = _high_sdc(design) && !_induced_within_strength(design, :beam, idx),
        induced_within_strength = _induced_within_strength(design, :beam, idx))
    if is_joist(beam) && !from_envelope && hog !== nothing
        push!(md.warnings,
            "no factored hogging envelope was stored for this rib; top bars use the " *
            "last solved frame case, which may not govern")
    end
    if top_bars !== nothing
        push!(md.notes, from_envelope ?
            "Top bars carry the factored hogging envelope the rib was sized for (all cases and patterns), full length." :
            "Top bars are the solved frame's negative moment at the rib ends, full length.")
    elseif hog !== nothing && hog > 1.0u"N*m"
        push!(md.warnings, "the rib end moment does not fit top bars in the web; hanger bars are shown")
    elseif !all(exterior)
        push!(md.warnings,
            "hogging steel over the continuous support is not part of the sizing result; " *
            "the top bars shown are hangers or compression bars only")
    end
    return md
end

"""True when a beam in `pool` leaves vertex `v` in the direction `dir`."""
function _continues_in(struc::BuildingStructure, geo, v::Int, dir, self_idx::Int, pool)
    skel = struc.skeleton
    for bi in pool
        bi == self_idx && continue
        a, b = geo.beam_ends[bi]
        other = a == v ? b : b == v ? a : 0
        other == 0 && continue
        d = _plan_dir(skel, v, other)
        d[1] * dir[1] + d[2] * dir[2] > 0.98 && return true
    end
    return false
end

"""
Solid-head data for detailing: the head beams, their rectangles, the framing
level of each, and the solved cases (full load, then patterns) that the
per-piece hogging envelope reads. Empty when the design has no solid head.
"""
function _solid_head_detail_geometry(design::BuildingDesign)
    struc = design.structure
    solid = Set{Int}()
    level_of = Dict{Int, FramingLevel}()
    for slab in struc.slabs, level in slab.framing_levels
        gid = level.solid_group_id
        gid === nothing && continue
        for bi in level_member_indices(struc, level)
            group_id(struc.beams[bi]) == gid || continue
            push!(solid, bi)
            level_of[bi] = level
        end
    end
    isempty(solid) && return (solid_beams = solid, head_rects = Dict{Int, NTuple{2, Float64}}(),
                              head_level = level_of, head_cases = nothing)
    model = struc.asap_model
    cases = nothing
    if model !== nothing && !isempty(model.frame_elements) && model.processed
        cases = Tuple{Vector{Float64}, Any}[(model.u, Asap.get_elemental_loads(model))]
        patterns = _pattern_demand_cases(struc, design.params)
        patterns === nothing || append!(cases, patterns)
    end
    return (solid_beams = solid, head_rects = solid_head_rectangles_m(struc),
            head_level = level_of, head_cases = cases)
end

"""Largest factored hogging moment (N·m) on `beam` over `cases`, or `nothing`."""
function _beam_hogging_over_cases(struc, cases, beam)
    cases === nothing && return nothing
    model = struc.asap_model
    hog = 0.0
    found = false
    for si in segment_indices(beam)
        e = struc.segments[si].edge_idx
        e < 1 && continue
        for k in _frame_element_indices(struc, e)
            el = model.frame_elements[k]
            for (u, load_map) in cases
                f = _element_forces_from_u(el, u, _case_loads(load_map, el); resolution = 50)
                _, h = _asap_signed_My_envelopes(el, f.My)
                hog = max(hog, h)
                found = true
            end
        end
    end
    return found ? hog * u"N*m" : nothing
end

"""
Top bars of one solid-head piece from its own hogging envelope.

The rectangle is the piece's share of the head at the sized rib depth, and
the effective depth is the sized rib's, the depth the head punching check
uses. Each end is a head face where a rib leaves, a continuation into the
next head piece, or an exterior end.
"""
function _detail_solid_head_piece(design::BuildingDesign, geo, idx::Int)
    struc = design.structure
    beam = struc.beams[idx]
    level = geo.head_level[idx]
    rect = get(geo.head_rects, idx, nothing)
    if rect === nothing
        md = StructuralSizer.MemberDetail(:beam)
        push!(md.warnings, "the solid head's ribs are not sized; head bars are not placed")
        return md
    end
    rib = nothing
    for bi in level_member_indices(struc, level)
        bi in geo.solid_beams && continue
        sec = section(struc.beams[bi])
        sec isa _RC_BEAM && (rib = sec; break)
    end
    rib === nothing && throw(ArgumentError(
        "solid-head piece $idx has no sized concrete rib to take its depth and cover from"))
    concrete = _solid_head_concrete(level)
    concrete === nothing && throw(ArgumentError(
        "solid-head piece $idx is on a framing level with no concrete"))
    _, rebar, _ = _beam_materials(design.params)
    a, b = geo.beam_ends[idx]
    dir = _plan_dir(struc.skeleton, a, b)
    back = (-dir[1], -dir[2])
    others = setdiff(Set(eachindex(struc.beams)), geo.solid_beams)
    end_kind(v, d) = _continues_in(struc, geo, v, d, idx, others) ? :face :
                     _continues_in(struc, geo, v, d, idx, geo.solid_beams) ? :continuous :
                     :exterior
    hog = _beam_hogging_over_cases(struc, geo.head_cases, beam)
    md = StructuralSizer.detail_solid_head_piece(;
        length = _as_metres(beam.base.L), width = rect[1] * u"m", depth = rect[2] * u"m",
        d = rib.d, cover = rib.cover, Mu_neg = hog,
        ends = (end_kind(a, back), end_kind(b, dir)),
        fc = concrete.fc′, fy = rebar.Fy, λ = concrete.λ, coating = rebar.coating)
    hog === nothing && push!(md.warnings,
        "the frame is not solved, so the head piece's hogging moment is unknown; head bars are not placed")
    return md
end

"""
Hogging moment at the ends of one joist, from the solved frame. Newtons-metres.

`loads_map` is `Asap.get_elemental_loads` of the model, built once per
detailing pass.
"""
function _joist_end_hogging(struc, beam, loads_map)
    model = struc.asap_model
    (model === nothing || loads_map === nothing || isempty(model.frame_elements)) && return nothing
    hog = 0.0
    found = false
    for seg_idx in segment_indices(beam)
        eidx = struc.segments[seg_idx].edge_idx
        (eidx < 1 || eidx > length(model.frame_elements)) && continue
        el = model.frame_elements[eidx]
        eid = el.elementID
        loads = (eid >= 1 && eid <= length(loads_map)) ? loads_map[eid] : Asap.AbstractLoad[]
        ends = Float64[]
        if !isempty(loads)
            diagram = Asap.ElementForceAndDisplacement(el, loads; resolution = 4)
            My = diagram.forces.My
            isempty(My) && continue
            push!(ends, My[1], My[end])
        elseif length(el.forces) >= 12
            # Internal moment from end forces, Asap's sign: My(0) = −F[6], My(L) = F[12].
            push!(ends, -el.forces[6], el.forces[12])
        else
            continue
        end
        _, h = _asap_signed_My_envelopes(el, ends)
        hog = max(hog, h)
        found = true
    end
    return found ? hog * u"N*m" : nothing
end

function _detail_slab(design::BuildingDesign, geo, idx::Int)
    slab = design.structure.slabs[idx]
    if slab.result isa StructuralSizer.FlatPlatePanelResult
        rc, cover = _slab_materials(design.params)
        conc = rc.concrete
        return StructuralSizer.detail_flat_plate_slab(design.structure, slab;
            cover = cover, fc = conc.fc′, fy = rc.rebar.Fy, λ = conc.λ, coating = rc.rebar.coating)
    end
    rib = _detail_rib_topping(design, idx)
    rib === nothing || return rib
    return _detail_code_slab(design, idx)
end

"""
Rib-to-rib layout of a one-way joist level on `slab`, or `nothing`.

The topping spans across the joists, between the joist lines and the panel
edges. `span` is the longest of those center-to-center gaps, `n_spans` their
count, `run` the panel width across the joists, and `length` the panel
length along them, all from the placed joists and the slab's cell boundaries.
"""
function _linear_joist_topping(struc, slab)
    skel = struc.skeleton
    corners = [_vertex_xy_m(skel, Int(v)) for ci in slab.cell_indices
               for v in skel.face_vertex_indices[struc.cells[ci].face_idx]]
    isempty(corners) && return nothing
    for level in slab.framing_levels
        (level.role === :joist && level.pattern isa LinearAxisPattern) || continue
        a = _unit2((Float64(level.pattern.axis[1]), Float64(level.pattern.axis[2])))
        a == (0.0, 0.0) && continue
        perp = (-a[2], a[1])
        lines = Float64[]
        for bi in level_member_indices(struc, level)
            is_joist(struc.beams[bi]) || continue
            v1, v2 = _member_end_vertices(struc, struc.beams[bi])
            p1, p2 = _vertex_xy_m(skel, v1), _vertex_xy_m(skel, v2)
            q = (_dot2(p1, perp) + _dot2(p2, perp)) / 2
            any(x -> abs(x - q) < 1e-3, lines) || push!(lines, q)
        end
        isempty(lines) && continue
        t = [_dot2(p, perp) for p in corners]
        s = [_dot2(p, a) for p in corners]
        stations = sort!(vcat(minimum(t), lines, maximum(t)))
        gaps = diff(stations)
        return (span = maximum(gaps) * u"m", n_spans = length(gaps),
                run = (maximum(t) - minimum(t)) * u"m",
                length = (maximum(s) - minimum(s)) * u"m")
    end
    return nothing
end

"""
Place the rib-to-rib topping mat of this one-way or two-way slab.

A grillage topping uses the bars stored at sizing, on the center-to-center
rib bay. A one-way joist topping is designed here from the placed joists:
flexure across them, and the §7.12 mat parallel to them
([`StructuralSizer.shrinkage_topping_bars`](@ref)).
"""
function _detail_rib_topping(design::BuildingDesign, idx::Int)
    struc = design.structure
    slab = struc.slabs[idx]
    slab.floor_type in (:one_way, :two_way) || return nothing
    det = slab.design_details
    (det isa NamedTuple && hasproperty(det, :topping_span)) || return nothing
    rc, params_cover = _slab_materials(design.params)
    cover = hasproperty(det, :topping_cover) ? det.topping_cover : params_cover
    h = StructuralSizer.total_depth(slab.result)
    if hasproperty(det, :topping_bars) && det.topping_bars !== nothing
        solid = any(level -> level.pattern isa IsoparametricPattern && level.pattern.solid_head > 0,
                    slab.framing_levels)
        return StructuralSizer.detail_rib_topping(;
            side = det.topping_side, across = det.topping_side_l2, h = h, cover = cover,
            along = det.topping_bars, across_bars = det.topping_bars_l2,
            solid_head = solid)
    end
    layout = _linear_joist_topping(struc, slab)
    if layout === nothing
        md = StructuralSizer.MemberDetail(:slab)
        push!(md.warnings, "no joist level was found under this topping; bars are not placed")
        return md
    end
    floor = design.params.floor
    bar_size = hasproperty(floor, :bar_size) ? floor.bar_size : 5
    dead = maximum(struc.cells[ci].sdl + struc.cells[ci].self_weight for ci in slab.cell_indices)
    live = maximum(struc.cells[ci].live_load for ci in slab.cell_indices)
    along = StructuralSizer.one_way_topping_bars(h, layout.span, dead, live,
        rc.concrete, rc.rebar; n_spans = layout.n_spans, cover = cover, bar_size = bar_size)
    return StructuralSizer.detail_rib_topping(;
        side = layout.run, across = layout.length, h = h, cover = cover,
        along = along, across_bars = StructuralSizer.shrinkage_topping_bars(h, rc.rebar))
end

"""
Place the bars a beam-supported slab or a composite deck did not get from
the joist-topping path.

A composite deck's positive reinforcement is the sheet. The concrete above
it gets the temperature mat of SDI C-2017 §2.4.B.15.a.1.

A one-way or two-way slab uses the story shell's required area when that
field is stored, placed uniform at the panel maximum. The shell already
sized each triangle by the Whitney block (ACI 318-11 §10.2.7). One-way
spacing in the span direction is §7.6.5; the other direction is §7.12.2.2.
Two-way spacing in both directions is §13.3.2.

A one-way slab with no shell field uses §8.3.3 when the span line permits
it, and the elastic strip otherwise, through [`one_way_topping_bars`](@ref).
A two-way slab with no shell field is not given a direct-design mat.
"""
function _detail_code_slab(design::BuildingDesign, idx::Int)
    slab = design.structure.slabs[idx]
    slab.result === nothing && return nothing
    if slab.floor_type === :composite_deck
        return _detail_deck_temperature(design, idx)
    end
    slab.floor_type in (:one_way, :two_way) || return nothing
    side, across = _panel_extents(design.structure, slab)
    (side === nothing || across === nothing) && return nothing
    h = StructuralSizer.total_depth(slab.result)
    (h === nothing || h <= zero(h)) && return nothing
    _, cover = _slab_materials(design.params)
    areas = _shell_face_areas(slab)
    if areas !== nothing && maximum(areas) > 0
        return _detail_shell_mat(design, slab, areas, side, across, h, cover)
    end
    slab.floor_type === :one_way && return _detail_one_way_solid(design, idx, side, across, h, cover)
    md = StructuralSizer.MemberDetail(:slab)
    push!(md.warnings, "two-way bars are not placed: the shell stored no reinforcement, " *
                       "and ACI 318-11 Chapter 13 direct design is not used here")
    return md
end

"Largest shell area in each face, m²/m, or `nothing` when the field is absent."
function _shell_face_areas(slab)
    det = slab.design_details
    (det isa NamedTuple && hasproperty(det, :shell_reinforcement)) || return nothing
    fields = det.shell_reinforcement
    fields === nothing && return nothing
    idxs = hasproperty(det, :shell_panels) ? det.shell_panels : eachindex(fields)
    xb = xt = yb = yt = 0.0
    n = 0
    for i in idxs
        1 <= i <= length(fields) || continue
        field = fields[i]
        field === nothing && continue
        for el in field.elements
            n += 1
            xb = max(xb, float(el.As_x_bot))
            xt = max(xt, float(el.As_x_top))
            yb = max(yb, float(el.As_y_bot))
            yt = max(yt, float(el.As_y_top))
        end
    end
    return n == 0 ? nothing : (xb, xt, yb, yt)
end

"""Panel length along the span axis, and the width across it."""
function _panel_extents(struc, slab)
    skel = struc.skeleton
    corners = NTuple{2, Float64}[]
    for ci in slab.cell_indices
        for v in skel.face_vertex_indices[struc.cells[ci].face_idx]
            push!(corners, _vertex_xy_m(skel, Int(v)))
        end
    end
    isempty(corners) && return (nothing, nothing)
    axis = (1.0, 0.0)
    if slab.spans !== nothing
        ax = slab.spans.axis
        a = _unit2((Float64(ax[1]), Float64(ax[2])))
        a != (0.0, 0.0) && (axis = a)
    end
    perp = (-axis[2], axis[1])
    s = [_dot2(p, axis) for p in corners]
    t = [_dot2(p, perp) for p in corners]
    return ((maximum(s) - minimum(s)) * u"m", (maximum(t) - minimum(t)) * u"m")
end

"Uniform mat at the shell envelope. One-way and two-way use different spacing."
function _detail_shell_mat(design, slab, areas, side, across, h, cover)
    xb, xt, yb, yt = areas
    if slab.floor_type === :two_way
        sx = sy = StructuralSizer.max_bar_spacing(h)
        clause = "ACI 318-11 §13.3.2: spacing at most 2h, and 18 in"
    else
        sx = StructuralSizer.solid_slab_spacing(h)
        sy = min(5 * h, 18.0u"inch")
        # The span direction is primary flexure. The other direction is
        # the §7.12 mat, and not less than the shell's own area.
        rc, _ = _slab_materials(design.params)
        ratio = StructuralSizer.shrinkage_temperature_ratio(rc.rebar.Fy)
        floor_as = ustrip(u"m", ratio * h)
        yb = max(yb, floor_as)
        clause = "ACI 318-11 §7.6.5 in the span direction; §7.12.2.2 in the other"
    end
    along = StructuralSizer.area_direction_bars(xb, xt; max_spacing = sx,
        reason = "shell envelope, span direction. $clause")
    across_bars = StructuralSizer.area_direction_bars(yb, yt; max_spacing = sy,
        reason = "shell envelope, the other direction. $clause")
    return StructuralSizer.detail_rib_topping(;
        side = side, across = across, h = h, cover = cover,
        along = along, across_bars = across_bars,
        placement_note = "Bars are uniform at the largest required area in the panel. " * clause,
        area_source = "story-shell envelope")
end

"""
§8.3.3 or the elastic strip for a solid one-way slab, plus the §7.12 mat.

The stored span is the clear distance inside the slab. An interior bay uses
the two-span interior coefficients, which are the largest negative moment
§8.3.3 writes, because the slab record does not carry the full line of spans.
A cantilever is not given the simple-span formula.
"""
function _detail_one_way_solid(design, idx, side, across, h, cover)
    struc = design.structure
    slab = struc.slabs[idx]
    support = StructuralSizer._slab_span_support(struc, slab)
    if support == StructuralSizer.CANTILEVER
        md = StructuralSizer.MemberDetail(:slab)
        push!(md.warnings, "cantilever one-way bars are not placed")
        return md
    end
    rc, _ = _slab_materials(design.params)
    floor = design.params.floor
    bar_size = hasproperty(floor, :bar_size) ? floor.bar_size : 5
    ln = slab.spans === nothing ? side : slab.spans.primary
    ln = ln isa Unitful.Quantity ? ln : ln * u"m"
    dead = maximum(struc.cells[ci].sdl + struc.cells[ci].self_weight for ci in slab.cell_indices)
    live = maximum(struc.cells[ci].live_load for ci in slab.cell_indices)
    kw = if support == StructuralSizer.ONE_END_CONT
        (n_spans = 2, span = :end, discontinuous = :spandrel, support_face = :first_interior)
    elseif support == StructuralSizer.BOTH_ENDS_CONT
        (n_spans = 2, span = :interior, discontinuous = :spandrel, support_face = :first_interior)
    else
        (n_spans = 1, span = :end, discontinuous = :spandrel, support_face = :first_interior)
    end
    along = StructuralSizer.one_way_topping_bars(h, ln, dead, live, rc.concrete, rc.rebar;
        n_spans = kw.n_spans, cover = cover, bar_size = bar_size,
        max_spacing = StructuralSizer.solid_slab_spacing(h),
        span = kw.span, discontinuous = kw.discontinuous, support_face = kw.support_face)
    # A face with no moment does not get a temperature mat of its own.
    # §7.12 steel is the other direction, placed below.
    none = StructuralSizer.StripReinforcement(:neg, 0.0u"N*m", 0.0u"m^2", 0.0u"m^2",
        0.0u"m^2", 4, 0.0u"m", 0, true)
    face(strip) = strip.Mu > 1.0u"N*m" ? strip : none
    along = (
        bars = (pos = face(along.bars.pos), ext_neg = face(along.bars.ext_neg),
                int_neg = face(along.bars.int_neg)),
        reasons = along.reasons,
        analysis = along.analysis,
    )
    return StructuralSizer.detail_rib_topping(;
        side = side, across = across, h = h, cover = cover,
        along = along, across_bars = StructuralSizer.shrinkage_topping_bars(h, rc.rebar),
        placement_note = "Solid one-way slab. Primary spacing is ACI 318-11 §7.6.5 " *
                         "(3h and 18 in). The other direction is §7.12.",
        area_source = "one-way slab")
end

"""Temperature mat in the concrete above the deck. The sheet is the flexural steel."""
function _detail_deck_temperature(design, idx)
    slab = design.structure.slabs[idx]
    r = slab.result
    r isa StructuralSizer.CompositeDeckResult || return nothing
    hasproperty(r.checks, :As_temperature_shrinkage) || return nothing
    side, across = _panel_extents(design.structure, slab)
    (side === nothing || across === nothing) && return nothing
    along = StructuralSizer.deck_temperature_bars(
        r.checks.As_temperature_shrinkage, r.total_depth)
    # The bars sit in the concrete above the deck, not in the flute.
    # ACI 318-11 §7.7.1(c), page 97: 3/4 in for No. 11 and smaller.
    return StructuralSizer.detail_temperature_mat(;
        side = side, across = across, h = r.fill_depth,
        cover = 0.75u"inch", along = along)
end

function _detail_wall(design::BuildingDesign, _geo, idx::Int)
    struc = design.structure
    wall = struc.walls[idx]
    conc = something(wall.concrete, resolve_column_concrete(design.params.materials))
    rebar = resolve_column_rebar(design.params.materials)
    records = get(design.walls, idx, WallCheckRecord[])
    Vu = nothing
    for rec in records
        rec.check == "in-plane shear" || continue
        demand = rec.demand * u"N"
        Vu = Vu === nothing ? demand : max(Vu, demand)
    end
    hw = 0.0u"m"
    for other in struc.walls
        _same_wall_line(wall, other) && (hw += other.base.L)
    end
    hw > 0u"m" || (hw = wall.base.L)
    above = wall.wall_above === nothing ? :roof : :wall
    below = any(other -> other.story < wall.story && _same_wall_line(wall, other), struc.walls) ?
        :wall : :foundation
    slab = 0.0u"m"
    for sr in values(design.slabs)
        slab = max(slab, sr.thickness)
    end
    _, slab_cover = _slab_materials(design.params)
    openings = [(o.s0 * u"m", o.z0 * u"m", o.width * u"m", o.height * u"m") for o in wall.openings]
    zones, reach = _boundary_zones(struc, idx, wall_length(wall) * u"m", records)
    md = StructuralSizer.detail_wall(;
        length = wall_length(wall) * u"m", height = wall.base.L, thickness = wall.thickness,
        ρl = wall.ρl, ρt = wall.ρt, openings = openings,
        Vu = Vu, ends = _wall_detail_ends(struc, idx), below = below, above = above,
        slab_above = slab, slab_cover = slab > 0u"m" ? slab_cover : 0.0u"m",
        fc = conc.fc′, fy = rebar.Fy, λ = conc.λ, coating = rebar.coating,
        hw = hw, special = _wall_on_special_row(struc, idx),
        boundary_zones = zones, critical_reach = reach)
    note = _jamb_tie_note(records)
    note === nothing || push!(md.notes, note)
    _record_horizontal_termination!(md, wall_length(wall) * u"m", struc, idx)
    _record_support_extension!(md, wall, struc, idx, conc, rebar)
    _record_boundary_hoops!(md, wall, struc, idx)
    _record_end_bars!(md, struc, idx)
    return md
end

"""
The added end bars, when this pier has them.

§18.10.2.4(b) is the extension past the critical section. (c) stops at most
half of those bars at one section. That cutoff is not laid out here.
"""
function _record_end_bars!(md, struc, idx)
    result = struc.ordinary_wall_result
    result === nothing && return md
    bars = get(result.end_bars, idx, nothing)
    bars === nothing && return md
    n = bars.layers * bars.per_layer
    zone = round(bars.zone_m; digits = 3)
    note = "each end adds $n No. $(bars.bar) bars in $(bars.layers) layers " *
           "over $(zone) m."
    if bars.from_ratio && bars.extension_m !== nothing
        reach = round(bars.extension_m; digits = 2)
        note *= " ACI 318-19 §18.10.2.4(a) sets the minimum, and (b) carries the " *
                "bars $(reach) m past the critical section. No more than half of " *
                "them stop at one section (§18.10.2.4(c))."
    end
    push!(md.notes, note)
    return md
end

"True when this pier was designed on Table 12.2-1 row A.1 or B.4."
function _wall_on_special_row(struc, idx)
    result = struc.ordinary_wall_result
    result === nothing && return false
    return haskey(result.boundary, idx) || haskey(result.opening_edges, idx)
end

"""
Record §18.10.6.4(k) for a required boundary element.

The placed horizontal bars have to end within 6 in. of the wall end.
Whether they may stop straight, or need a hook, depends on the boundary
transverse reinforcement, which is not placed.
"""
function _record_horizontal_termination!(md, length, struc, idx)
    result = struc.ordinary_wall_result
    result === nothing && return md
    required = false
    decision = get(result.boundary, idx, nothing)
    if decision !== nothing && decision.required === true
        required = true
    end
    edges = get(result.opening_edges, idx, SpecialBoundaryDecision[])
    required = required || any(e -> e.required === true, edges)
    required || return md
    gap = StructuralSizer.wall_horizontal_end_gap(md, length)
    if gap === nothing
        push!(md.warnings,
            "§18.10.6.4(k): no horizontal web reinforcement was placed")
        return md
    end
    inches = ustrip(u"inch", gap)
    # ACI 318-19 §18.10.6.4(k) (corpus: aci-318-19, page 329): within 6 in.
    if StructuralSizer.web_end_within_six_inches(gap)
        push!(md.notes,
            "horizontal web bars end $(round(inches; digits = 2)) in from the wall end, " *
            "within the 6 in. of ACI 318-19 §18.10.6.4(k). The hook is not chosen: " *
            "the boundary transverse reinforcement is not placed.")
    else
        push!(md.warnings,
            "§18.10.6.4(k): horizontal web bars end $(round(inches; digits = 2)) in " *
            "from the wall end, past the 6 in. limit")
    end
    return md
end

"""
Record §18.10.6.4(j) at the base of a continuous wall line.

The critical section is that base. §18.10.2.3(b) takes the development
length of the placed vertical bars as 1.25 times §25.4.2.1. The clause's
bar is the largest one in the special boundary element, and those bars
are not placed, so the recorded length is not the extension. A footing,
mat, or pile cap is not stated, so the 12 in. extension is not applied.
"""
function _record_support_extension!(md, wall, struc, idx, conc, rebar)
    result = struc.ordinary_wall_result
    result === nothing && return md
    decision = get(result.boundary, idx, nothing)
    (decision !== nothing && decision.required === true &&
        decision.continuous && wall.story == 0) || return md
    best = nothing
    best_d = 0.0
    for g in md.groups
        g.role === :vertical || continue
        d = ustrip(u"m", StructuralSizer.bar_diameter(g.bar_size))
        if best === nothing || d > best_d
            best = g.bar_size
            best_d = d
        end
    end
    if best === nothing
        push!(md.warnings,
            "§18.10.6.4(j): no longitudinal bar was placed, so ℓd is not calculated")
        return md
    end
    # §18.10.2.3(b) (corpus: aci-318-19, page 320) at the base of a continuous line.
    ld = StructuralSizer.boundary_bar_development(
        best, conc.fc′, rebar.Fy, conc.λ; coating = rebar.coating, yielding_likely = true)
    inches = ustrip(u"inch", ld)
    push!(md.notes,
        "placed No. $(best) vertical bars develop in $(round(inches; digits = 2)) in., " *
        "1.25 times §25.4.2.1, because yielding is likely at this base " *
        "(ACI 318-19 §18.10.2.3(b)). §18.10.6.4(j) extends the boundary transverse " *
        "reinforcement by the development length of the largest bar in the special " *
        "boundary element. Those bars are not placed, so this length is not that " *
        "extension. The support is not stated as a footing, mat, or pile cap, so the " *
        "12 in. extension is not applied.")
    return md
end

"""
§18.10.6.4 lengths already decided for this pier, and the Table 18.10.6.5(b)
reach: the greater of ℓw and Mu/(4Vu) from the in-plane records.
"""
function _boundary_zones(struc, idx, lw, records)
    result = struc.ordinary_wall_result
    zones = NamedTuple[]
    result === nothing && return zones, lw
    decisions = SpecialBoundaryDecision[]
    base = get(result.boundary, idx, nothing)
    base === nothing || push!(decisions, base)
    append!(decisions, get(result.opening_edges, idx, SpecialBoundaryDecision[]))
    bars = get(result.end_bars, idx, nothing)
    for decision in decisions
        (decision.required === true && decision.zone_length_m !== nothing) || continue
        bar = bars === nothing ? 0 : bars.bar
        spacing = bars === nothing ? 0.0u"m" : bars.spacing_m * u"m"
        push!(zones, (zone = decision.zone_length_m * u"m", bar = bar,
                      spacing = spacing))
    end
    return zones, _boundary_critical_reach(records, lw)
end

function _boundary_critical_reach(records, lw)
    Mu = 0.0
    Vu = 0.0
    for rec in records
        if rec.check == "in-plane axial-flexure (P-M)"
            Mu = max(Mu, abs(rec.demand))
        elseif rec.check == "in-plane shear"
            Vu = max(Vu, abs(rec.demand))
        end
    end
    # Table 18.10.6.5(b) (corpus: aci-318-19, page 332): greater of ℓw and Mu/4Vu.
    from_shear = Vu > 1.0 ? (Mu / (4 * Vu)) * u"m" : 0.0u"m"
    return max(lw, from_shear)
end

function _record_boundary_hoops!(md, wall, struc, idx)
    result = struc.ordinary_wall_result
    result === nothing && return md
    decisions = SpecialBoundaryDecision[]
    base = get(result.boundary, idx, nothing)
    base === nothing || push!(decisions, base)
    append!(decisions, get(result.opening_edges, idx, SpecialBoundaryDecision[]))
    for decision in decisions
        (decision.required === true && decision.zone_length_m !== nothing) || continue
        arranged = StructuralSizer.boundary_hoop_arrangement(
            wall.thickness, decision.zone_length_m * u"m")
        hx = round(ustrip(u"inch", arranged.hx); digits = 2)
        hoops = arranged.overlapping_hoops ? "overlapping hoops" : "one hoop"
        flange = decision.flanged ?
            " This covers the web length; the flange in the element is not arranged." : ""
        placed = decision === base ? get(result.end_bars, idx, nothing) : nothing
        tie = placed === nothing ?
            "The hoops enclose the web vertical bars (§25.7.2.2). " *
            "Added boundary longitudinal bars are not placed." :
            "The tie and crosstie are No. $(placed.tie) (§25.7.2.2 for the No. $(placed.bar) end bars)."
        push!(md.notes,
            "boundary transverse reinforcement is $hoops. Longitudinal bars in the " *
            "element are spaced at most $(hx) in., which is hx of ACI 318-19 " *
            "§18.10.6.4(f). A crosstie crosses the thickness at every bar that is " *
            "not at a hoop corner. §25.7.2.3(b) would allow 6 in. clear; that " *
            "allowance is not used. " * tie * flange)
    end
    return md
end

"""
Quote the tightest column-tie spacing the jamb checks asked for.

Those segments are columns (§2.3). Their ties are not the distributed wall
bars, and they are not drawn on the wall elevation.
"""
function _jamb_tie_note(records)
    best_in = Inf
    bar = 0
    for rec in records
        found = match(r"No\. (\d+) ties at ([0-9.]+) in", rec.clause)
        found === nothing && continue
        spacing = parse(Float64, found.captures[2])
        if spacing < best_in
            best_in = spacing
            bar = parse(Int, found.captures[1])
        end
    end
    isfinite(best_in) || return nothing
    return "Segments beside openings are designed as columns (ACI 318-19 §2.3). " *
           "They need No. $(bar) ties at $(round(best_in; digits = 2)) in. for shear " *
           "(§22.5). The distributed wall bars are not those ties."
end

"""True when two piers are the same plan line, including a reversed tracing."""
function _same_wall_line(a, b)
    same = hypot(a.x1 - b.x1, a.y1 - b.y1) < 1e-4 && hypot(a.x2 - b.x2, a.y2 - b.y2) < 1e-4
    flipped = hypot(a.x1 - b.x2, a.y1 - b.y2) < 1e-4 && hypot(a.x2 - b.x1, a.y2 - b.y1) < 1e-4
    return same || flipped
end

"""(:free or :joined, :free or :joined) from the walls that meet this pier's ends."""
function _wall_detail_ends(struc, idx)
    walls = struc.walls
    ends = [:free, :free]
    asm = nothing
    for a in wall_assemblies(walls)
        idx in a.wall_indices && (asm = a)
    end
    asm === nothing && return (:free, :free)
    asm.joined || return (:free, :free)
    wall = walls[idx]
    for corner in assembly_corners(walls, asm)
        idx in corner.wall_indices || continue
        if hypot(corner.x - wall.x1, corner.y - wall.y1) <= 1e-3
            ends[1] = :joined
        elseif hypot(corner.x - wall.x2, corner.y - wall.y2) <= 1e-3
            ends[2] = :joined
        end
    end
    return (ends[1], ends[2])
end

function _detail_footing(design::BuildingDesign, geo, idx::Int)
    struc = design.structure
    fdn = struc.foundations[idx]
    r = fdn.result
    r isa StructuralSizer.MatFootingResult && return _detail_mat(design, r)
    r isa StructuralSizer.SpreadFootingResult || return nothing
    length(fdn.support_indices) == 1 || return nothing
    sp = _spread_params(design.params)
    rc = sp.material
    conc = rc.concrete
    sup = struc.supports[only(fdn.support_indices)]
    db = r.rebar_dia
    bar_size = StructuralSizer.infer_bar_size(π * db^2 / 4)
    B, L = r.B, r.L_ftg
    c1, c2 = sup.c1, sup.c2
    if L < B
        B, L = L, B
        c1, c2 = c2, c1
    end
    column_bars = column_Ag = column_lap = nothing
    ci = get(geo.col_bottom, sup.vertex_idx, nothing)
    if ci !== nothing
        cr = get(design.columns, ci, nothing)
        sec = cr === nothing ? nothing : cr.section_obj
        if sec isa _RC_COLUMN && !isempty(sec.bars)
            ccon, crebar, _ = _column_materials(design.params, struc.columns[ci])
            bs = StructuralSizer._column_bar_size(sec)
            column_bars = (bs, length(sec.bars))
            column_Ag = cr.Ag
            column_lap = bs <= 11 ? StructuralSizer.column_lap_length(sec, ccon.fc′, crebar.Fy;
                λ = ccon.λ, coating = crebar.coating) : nothing
        end
    end
    return StructuralSizer.detail_spread_footing(; B = B, L = L, D = r.D, bar_size = bar_size,
        n_bars = r.rebar_count, column = (c1, c2), column_bars = column_bars,
        column_Ag = column_Ag, column_lap = column_lap, cover = sp.cover,
        fc = conc.fc′, fy = rc.rebar.Fy, λ = conc.λ, coating = rc.rebar.coating)
end

"""Bars of a mat, using the bar size and cover the foundation options designed with."""
function _detail_mat(design::BuildingDesign, r)
    fp = design.params.foundation_options
    opts = fp === nothing ? StructuralSizer.MatParams() : fp.options.mat_params
    return StructuralSizer.detail_mat(;
        B = r.B, L = r.L_ftg, D = r.D, cover = opts.cover,
        bar_size_x = opts.bar_size_x, bar_size_y = opts.bar_size_y,
        As_x_bot = r.As_x_bot, As_x_top = r.As_x_top,
        As_y_bot = r.As_y_bot, As_y_top = r.As_y_top)
end

"""
    detail_building(design) -> BuildingDetail

Bar placement for every reinforced concrete column, beam, flat plate, flat
slab, ribbed topping, wall, mat, and single-column spread footing of a design.
Members of other materials or systems are skipped. A member whose detailing
throws is recorded in `errors` and the rest are still detailed.
"""
function detail_building(design::BuildingDesign)
    bd = BuildingDetail()
    struc = design.structure
    geo = merge(_detail_geometry(struc), _solid_head_detail_geometry(design))
    for (kind, dict, results, n, f) in (
            ("column", bd.columns, design.columns, length(struc.columns), _detail_column),
            ("beam", bd.beams, design.beams, length(struc.beams), _detail_beam),
            ("slab", bd.slabs, design.slabs, length(struc.slabs), _detail_slab),
            ("footing", bd.footings, design.foundations, length(struc.foundations), _detail_footing))
        for idx in sort!(collect(keys(results)))
            idx <= n || continue
            try
                md = f(design, geo, idx)
                md === nothing || (dict[idx] = md)
            catch err
                err isa InterruptException && rethrow()
                bd.errors["$(kind):$(idx)"] = sprint(showerror, err)
            end
        end
    end
    for idx in eachindex(struc.walls)
        try
            md = _detail_wall(design, geo, idx)
            md === nothing || (bd.walls[idx] = md)
        catch err
            err isa InterruptException && rethrow()
            bd.errors["wall:$(idx)"] = sprint(showerror, err)
        end
    end
    return bd
end
