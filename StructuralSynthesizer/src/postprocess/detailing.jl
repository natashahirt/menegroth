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
    if floor isa StructuralSizer.FlatPlateOptions
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
    return (; col_top, col_bottom, beam_ends, beam_through)
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
    md = StructuralSizer.detail_column(sec; height = cr.height, slab_above = depth * u"m",
        slab_cover = depth > 0 ? slab_cover : 0.0u"m",
        continues = !isnothing(col.column_above),
        fc = conc.fc′, fy = rebar.Fy, fyt = transverse.Fy, λ = conc.λ,
        coating = rebar.coating)
    depth > 0 || push!(md.notes, "No slab or beam found at the column top; ties run to the top.")
    return md
end

function _detail_beam(design::BuildingDesign, geo, idx::Int)
    struc = design.structure
    br = design.beams[idx]
    sec = br.section_obj
    sec isa _RC_BEAM || return nothing
    a, b = geo.beam_ends[idx]
    skel = struc.skeleton
    dir = _plan_dir(skel, a, b)
    back = (-dir[1], -dir[2])
    ca = _beam_support_width(design, geo, a, dir)
    cb = _beam_support_width(design, geo, b, dir)
    if ca === nothing || cb === nothing
        md = StructuralSizer.MemberDetail(:beam)
        push!(md.warnings, "beam supports were not found at both ends; bars are not placed")
        return md
    end
    conc, rebar, transverse = _beam_materials(design.params)
    exterior = (!_beam_continues(struc, geo, a, back, idx), !_beam_continues(struc, geo, b, dir, idx))
    md = StructuralSizer.detail_beam(sec; span = br.member_length,
        supports = (ca * u"m", cb * u"m"), exterior = exterior,
        fc = conc.fc′, fy = rebar.Fy, fyt = transverse.Fy, λ = conc.λ,
        coating = rebar.coating, Vu = br.Vu)
    all(exterior) || push!(md.warnings,
        "hogging steel over the continuous support is not part of the sizing result; " *
        "the top bars shown are hangers or compression bars only")
    return md
end

function _detail_slab(design::BuildingDesign, geo, idx::Int)
    slab = design.structure.slabs[idx]
    slab.result isa StructuralSizer.FlatPlatePanelResult || return nothing
    rc, cover = _slab_materials(design.params)
    conc = rc.concrete
    return StructuralSizer.detail_flat_plate_slab(design.structure, slab;
        cover = cover, fc = conc.fc′, fy = rc.rebar.Fy, λ = conc.λ, coating = rc.rebar.coating)
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
    return StructuralSizer.detail_wall(;
        length = wall_length(wall) * u"m", height = wall.base.L, thickness = wall.thickness,
        ρl = wall.ρl, ρt = wall.ρt, openings = openings,
        Vu = Vu, ends = _wall_detail_ends(struc, idx), below = below, above = above,
        slab_above = slab, slab_cover = slab > 0u"m" ? slab_cover : 0.0u"m",
        fc = conc.fc′, fy = rebar.Fy, λ = conc.λ, coating = rebar.coating,
        hw = hw)
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

"""
    detail_building(design) -> BuildingDetail

Bar placement for every reinforced concrete column, beam, flat plate or flat
slab, wall, and single-column spread footing of a design. Members of other
materials or systems are skipped. A member whose detailing throws is recorded
in `errors` and the rest are still detailed.
"""
function detail_building(design::BuildingDesign)
    bd = BuildingDetail()
    struc = design.structure
    geo = _detail_geometry(struc)
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
