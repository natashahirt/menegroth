# Component dossiers for the scene header and the solve trace.
# Spec: docs/src/reference/scene_format.md
#
# Every number is taken from a design result or a trace event. Missing values
# are JSON null. Clauses are the same strings the diagnose path already emits
# for that section type; an unknown section gets an empty clause.

const _JSON_DEPTH = 8
const _JSON_VEC = 80

_finite(x::Real) = (isnan(x) || isinf(x)) ? nothing : Float64(x)
_finite(::Nothing) = nothing

function _si(::Nothing, ::Unitful.Units)
    return nothing
end
function _si(q, u::Unitful.Units)
    return _finite(ustrip(u, q))
end

_text(x) = x === nothing ? nothing : string(x)

"""JSON-safe copy of a trace payload. Long vectors keep their length and a head."""
function _jsonify(v, depth::Int = 0)
    depth > _JSON_DEPTH && return string(typeof(v))
    v === nothing && return nothing
    v isa Bool && return v
    v isa AbstractString && return String(v)
    v isa Symbol && return string(v)
    if v isa Unitful.Quantity
        return Dict{String, Any}(
            "value" => _finite(ustrip(v)),
            "unit" => string(Unitful.unit(v)),
        )
    end
    v isa Real && return _finite(v)
    if v isa AbstractDict
        return Dict{String, Any}(string(k) => _jsonify(val, depth + 1) for (k, val) in pairs(v))
    end
    v isa NamedTuple && return _jsonify(Dict(pairs(v)), depth)
    if v isa AbstractVector
        n = length(v)
        if n > _JSON_VEC
            head_n = min(8, n)
            return Dict{String, Any}(
                "length" => n,
                "truncated" => true,
                "head" => [_jsonify(v[i], depth + 1) for i in 1:head_n],
            )
        end
        return Any[_jsonify(x, depth + 1) for x in v]
    end
    return string(v)
end

function _event_record(ev::StructuralSizer.TraceEvent)
    return Dict{String, Any}(
        "t_s" => ev.timestamp,
        "layer" => string(ev.layer),
        "stage" => ev.stage,
        "element_id" => ev.element_id,
        "event" => string(ev.event_type),
        "data" => _jsonify(ev.data),
    )
end

function _lookup_hits(data::Dict{String, Any}, kind::String, idx::Int)
    lookup = get(data, "lookup", nothing)
    lookup isa AbstractDict || return false
    member = get(lookup, "member_idx", get(lookup, "member_index", nothing))
    member_type = get(lookup, "member_type", get(lookup, "kind", nothing))
    return member == idx && string(member_type) == kind
end

"""Trace events whose element id or lookup names this component."""
function _path_for(events::Vector{StructuralSizer.TraceEvent}, kind::String, idx::Int)
    id = string(idx)
    aliases = Set([
        "$(kind)_$(id)",
        "$(kind)-$(id)",
        kind == "column" ? "column_group_$(id)" : "",
    ])
    out = Dict{String, Any}[]
    for ev in events
        hit = ev.element_id in aliases || occursin("$(kind)_$(id)", ev.element_id)
        if !hit
            mi = get(ev.data, "member_idx", nothing)
            mk = get(ev.data, "member_type", nothing)
            hit = mi == idx && string(mk) == kind
        end
        hit = hit || _lookup_hits(ev.data, kind, idx)
        hit || continue
        push!(out, _event_record(ev))
    end
    return out
end

function _check(; name, clause, ratio, governing, demand = nothing, demand_unit = "",
        capacity = nothing, capacity_unit = "", extra = Dict{String, Any}())
    known = ratio !== nothing
    row = Dict{String, Any}(
        "name" => name,
        "clause" => clause,
        "ratio" => ratio,
        "ok" => known ? ratio <= 1.0 : nothing,
        "governing" => governing,
        "demand" => demand,
        "demand_unit" => demand_unit,
        "capacity" => capacity,
        "capacity_unit" => capacity_unit,
    )
    for (k, v) in extra
        row[k] = v
    end
    return row
end

function _section_outline(sec)
    isnothing(sec) && return nothing
    poly = StructuralSizer.section_polygon(sec)
    isempty(poly) && return nothing
    return [[Float64(y), Float64(z)] for (y, z) in poly]
end

"""
Bars in the centroid frame of `section_polygon`.

Each entry is `[y, z, diameter]` in meters. A beam's bars are the single
tension layer at `d` and the compression layer at `d_prime`. `nothing` when
the section stores no bars.
"""
function _rebar_drawing(sec)
    isnothing(sec) && return nothing
    StructuralSizer.has_rebar(sec) || return nothing
    bars = StructuralSizer.section_rebar_bars(sec)
    isempty(bars) && return nothing
    return [[Float64(y), Float64(z), Float64(diameter)] for (y, z, diameter) in bars]
end

"""Stirrup, tie, or spiral centerline. Spacing is not part of the section, so it is omitted."""
function _transverse_drawing(sec)
    isnothing(sec) && return nothing
    tr = StructuralSizer.section_transverse(sec)
    isnothing(tr) && return nothing
    loop = tr.loop
    return Dict{String, Any}(
        "kind" => string(tr.kind),
        "diameter_m" => tr.diameter,
        "cover_m" => tr.cover,
        "bar_size" => tr.bar_size,
        "loop_m" => isnothing(loop) ? nothing : [[Float64(y), Float64(z)] for (y, z) in loop],
        "radius_m" => tr.radius,
    )
end

"""
Placed bars of one member for the viewer. Paths are bar centerlines in the
member's elevation plane, `[x, z]` in meters; transverse groups carry the
station of each bar along the member instead. `nothing` when the member was
not detailed. A detailing error is returned as `{"error": message}`.
"""
function _detail_record(md)
    md === nothing && return nothing
    md isa AbstractString && return Dict{String, Any}("error" => md)
    groups = map(md.groups) do g
        Dict{String, Any}(
            "mark" => g.mark,
            "role" => string(g.role),
            "direction" => string(g.direction),
            "bar_size" => g.bar_size,
            "diameter_m" => _si(StructuralSizer.bar_diameter(g.bar_size), u"m"),
            "count" => g.count,
            "length_m" => _si(g.length, u"m"),
            "shape" => string(g.shape),
            "path_m" => [[x, z] for (x, z) in g.path],
            "centerlines_m" => [[[x, y, z] for (x, y, z) in wire] for wire in g.centerlines],
            "x_positions_m" => g.x_positions,
            "z_positions_m" => g.z_positions,
            "laps" => g.laps,
            "note" => g.note,
            "mass_kg" => _si(StructuralSizer.bar_set_mass(StructuralSizer.bar_set(g)), u"kg"),
        )
    end
    return Dict{String, Any}(
        "kind" => string(md.kind),
        "mass_kg" => _si(StructuralSizer.detail_mass(md), u"kg"),
        "groups" => groups,
        "outline_m" => [collect(r) for r in md.outline],
        "voids_m" => [collect(r) for r in md.voids],
        "section_dots_m" => [collect(p) for p in md.section_dots],
        "solid_m" => md.solid === nothing ? nothing : collect(md.solid),
        "warnings" => md.warnings,
        "notes" => md.notes,
        "areas_in2" => Dict{String, Any}(md.areas),
    )
end

"""Detail of `kind` at `idx` from a building detail: the member, its error message, or `nothing`."""
function _member_detail(bd::BuildingDetail, kind::String, dict, idx::Int)
    haskey(dict, idx) && return dict[idx]
    return get(bd.errors, "$(kind):$(idx)", nothing)
end

function _governing_block(check::String, ratio, ok, clause::String)
    return Dict{String, Any}(
        "check" => check,
        "ratio" => ratio,
        "ok" => ok,
        "clause" => clause,
    )
end

function _strip_records(strips::Dict)
    out = Dict{String, Any}()
    for (loc, rd) in strips
        out[string(loc)] = Dict{String, Any}(
            "Mu_kNm" => _si(rd.Mu, u"kN*m"),
            "As_required_m2" => _si(rd.As_required, u"m^2"),
            "As_minimum_m2" => _si(rd.As_minimum, u"m^2"),
            "As_provided_m2" => _si(rd.As_provided, u"m^2"),
            "bar_size" => rd.bar_size,
            "spacing_m" => _si(rd.spacing, u"m"),
            "n_bars" => rd.n_bars,
        )
    end
    return out
end

function _frame_elements_by_edge(design::BuildingDesign, model::Asap.Model)
    by = Dict{Int, Vector{Int}}()
    edges = design.asap_model_frame_edge_indices
    length(edges) == length(model.frame_elements) || return by
    for (e, edge_idx) in enumerate(edges)
        push!(get!(by, edge_idx, Int[]), e - 1)
    end
    return by
end

function _member_elements(struc::BuildingStructure, member, by_edge::Dict{Int, Vector{Int}})
    out = Int[]
    for seg_idx in segment_indices(member)
        seg_idx > length(struc.segments) && continue
        append!(out, get(by_edge, struc.segments[seg_idx].edge_idx, Int[]))
    end
    return sort!(unique(out))
end

"""Plan ring of each cell of `slab`, in meters. Used to give a shell triangle to one slab."""
function _slab_plan_m(struc::BuildingStructure, slab)
    skel = struc.skeleton
    rings = Vector{Vector{Vector{Float64}}}()
    for ci in slab.cell_indices
        1 <= ci <= length(struc.cells) || continue
        face = struc.cells[ci].face_idx
        1 <= face <= length(skel.face_vertex_indices) || continue
        ring = Vector{Float64}[]
        for v in skel.face_vertex_indices[face]
            xy = _vertex_xy_m(skel, Int(v))
            push!(ring, [xy[1], xy[2]])
        end
        length(ring) >= 3 && push!(rings, ring)
    end
    return rings
end

"""Slab elevation in meters, structural Z, from the story that owns its cells."""
function _slab_elevation_m(struc::BuildingStructure, slab)
    faces = Set{Int}()
    for ci in slab.cell_indices
        1 <= ci <= length(struc.cells) || continue
        push!(faces, struc.cells[ci].face_idx)
    end
    isempty(faces) && return nothing
    # `stories` is a Dict keyed by the 0-based story index. Iteration yields
    # pairs; the story value holds the faces and the elevation.
    for story in values(struc.skeleton.stories)
        any(f -> f in faces, story.faces) || continue
        return _si(story.elevation, u"m")
    end
    return nothing
end

function _story_range_m(struc::BuildingStructure, story::Int, height)
    stories = struc.skeleton.stories
    # Same index as the pier: bottom is this story, top is the next story
    # that has faces (`_wall_pier_height`).
    z0 = haskey(stories, story) ? _si(stories[story].elevation, u"m") : nothing
    above = nothing
    for k in sort!(collect(keys(stories)))
        k <= story && continue
        isempty(stories[k].faces) && continue
        above = k
        break
    end
    z1 = above === nothing ? nothing : _si(stories[above].elevation, u"m")
    if z1 === nothing && z0 !== nothing && height !== nothing
        z1 = z0 + height
    end
    return z0, z1
end

function _column_ratio(cr::ColumnDesignResult, check::String)
    if !isempty(cr.governing_check) && check == cr.governing_check
        return _finite(cr.governing_ratio)
    end
    check == "axial_compression" && return _finite(cr.axial_ratio)
    check == "pm_interaction" && return _finite(cr.interaction_ratio)
    check == "column_shear" && return _finite(cr.shear_ratio)
    if check == "punching_shear_col" && !isnothing(cr.punching)
        return _finite(cr.punching.ratio)
    end
    check == "seismic_frame" && return _finite(_seismic_frame_ratio(cr.seismic_frame))
    return nothing
end

function _column_record(idx::Int, cr::ColumnDesignResult, col, frame_elements::Vector{Int},
                        events::Vector{StructuralSizer.TraceEvent})
    governing = column_diagnostic_governing_check(cr)
    axial_clause, pm_clause = _column_code_clauses(cr)
    punch_clause = isnothing(cr.punching) ? "" : "ACI 318-19 §22.6"
    clause = if !isempty(cr.governing_clause) && governing == cr.governing_check
        cr.governing_clause
    elseif governing == "axial_compression"
        axial_clause
    elseif governing == "pm_interaction"
        pm_clause
    elseif governing == "column_shear"
        cr.shear_clause
    elseif governing == "punching_shear_col"
        punch_clause
    elseif governing == "seismic_frame"
        "ASCE 7-22 §12.2.5.8"
    else
        ""
    end
    checks = Dict{String, Any}[
        _check(; name = "axial_compression", clause = axial_clause,
            ratio = _finite(cr.axial_ratio), governing = governing == "axial_compression",
            demand = _si(cr.Pu, u"kN"), demand_unit = "kN"),
        _check(; name = "pm_interaction", clause = pm_clause,
            ratio = _finite(cr.interaction_ratio), governing = governing == "pm_interaction",
            demand = _si(cr.Mu_x, u"kN*m"), demand_unit = "kN·m",
            extra = Dict{String, Any}("Mu_y_kNm" => _si(cr.Mu_y, u"kN*m"))),
    ]
    if !isempty(cr.shear_clause)
        push!(checks, _check(; name = "column_shear", clause = cr.shear_clause,
            ratio = _finite(cr.shear_ratio), governing = governing == "column_shear",
            demand = _si(max(cr.Vu_x, cr.Vu_y), u"kN"), demand_unit = "kN",
            capacity = _si(max(cr.ϕVn_x, cr.ϕVn_y), u"kN"), capacity_unit = "kN",
            extra = Dict{String, Any}(
                "Vu_x_kN" => _si(cr.Vu_x, u"kN"),
                "Vu_y_kN" => _si(cr.Vu_y, u"kN"),
                "phiVn_x_kN" => _si(cr.ϕVn_x, u"kN"),
                "phiVn_y_kN" => _si(cr.ϕVn_y, u"kN"),
                "tie_bar" => cr.tie_bar_size,
                "tie_spacing_m" => _si(cr.tie_spacing, u"m"),
            )))
    end
    punching = nothing
    if !isnothing(cr.punching)
        p = cr.punching
        punching = Dict{String, Any}(
            "Vu_kN" => _si(p.Vu, u"kN"),
            "phiVc_kN" => _si(p.φVc, u"kN"),
            "ratio" => _finite(p.ratio),
            "ok" => p.ok,
            "perimeter_m" => _si(p.critical_perimeter, u"m"),
            "tributary_m2" => _si(p.tributary_area, u"m^2"),
            "Mub_kNm" => _si(p.Mub, u"kN*m"),
            "clause" => punch_clause,
        )
        push!(checks, _check(; name = "punching_shear_col", clause = punch_clause,
            ratio = _finite(p.ratio), governing = governing == "punching_shear_col",
            demand = _si(p.Vu, u"kN"), demand_unit = "kN",
            capacity = _si(p.φVc, u"kN"), capacity_unit = "kN",
            extra = Dict{String, Any}(
                "perimeter_m" => punching["perimeter_m"],
                "Mub_kNm" => punching["Mub_kNm"],
            )))
    end
    if !isnothing(cr.seismic_frame)
        sf = cr.seismic_frame
        push!(checks, _check(; name = "seismic_frame", clause = "ASCE 7-22 §12.2.5.8",
            ratio = _finite(sf.ratio), governing = governing == "seismic_frame",
            extra = Dict{String, Any}(
                "governing_check" => sf.governing_check,
                "case" => sf.case_label,
                "detail" => sf.detail,
                "passed" => sf.passed,
            )))
    end
    known = ("axial_compression", "pm_interaction", "column_shear",
             "punching_shear_col", "seismic_frame", "axial_compression_unverified")
    if !(governing in known)
        push!(checks, _check(; name = governing, clause = clause,
            ratio = _column_ratio(cr, governing), governing = true))
    end
    return Dict{String, Any}(
        "id" => "column:$(idx)",
        "kind" => "column",
        "title" => "Column $(idx)",
        "design_index" => idx,
        "story" => col.story,
        "governing" => _governing_block(governing, _column_ratio(cr, governing), cr.ok, clause),
        "bind" => Dict{String, Any}("frame_elements" => frame_elements),
        "drawing" => Dict{String, Any}(
            "section" => cr.section_size,
            "shape" => string(cr.shape),
            "c1_m" => _si(cr.c1, u"m"),
            "c2_m" => _si(cr.c2, u"m"),
            "height_m" => _si(cr.height, u"m"),
            "Ag_m2" => _si(cr.Ag, u"m^2"),
            "As_m2" => _si(cr.As_total, u"m^2"),
            "rho_g" => _finite(cr.rho_g),
            "outline_m" => _section_outline(cr.section_obj),
            "rebar_m" => _rebar_drawing(cr.section_obj),
            "transverse" => _transverse_drawing(cr.section_obj),
            "punching" => punching,
        ),
        "checks" => checks,
        "path" => _path_for(events, "column", idx),
    )
end

"""
Clause and ratio for the beam card's governing tag.

A sizer check keeps its own clause and ratio. Falling through to shear is
what put a G2 ratio under a deflection name.
"""
function _beam_governing_presentation(br::BeamDesignResult, governing::String,
                                     flexure_clause::String, shear_clause::String)
    if governing == "seismic_frame"
        return "ASCE 7-22 §12.2.5.8", _finite(_seismic_frame_ratio(br.seismic_frame))
    end
    if !isempty(br.governing_check)
        clause = if !isempty(br.governing_clause)
            br.governing_clause
        elseif _is_flexure_check(governing)
            flexure_clause
        elseif _is_shear_check(governing)
            shear_clause
        else
            ""
        end
        return clause, _finite(br.governing_ratio)
    end
    governing == "flexure" && return flexure_clause, _finite(br.flexure_ratio)
    return shear_clause, _finite(br.shear_ratio)
end

"""δ/L and its limit for a deflection check. Other checks have no single pair of units."""
function _governing_pair(br::BeamDesignResult, governing::String)
    startswith(governing, "deflection") || return nothing, "", nothing, ""
    (isfinite(br.governing_demand) && isfinite(br.governing_capacity)) ||
        return nothing, "", nothing, ""
    return br.governing_demand, "δ/L", br.governing_capacity, "δ/L"
end

function _beam_record(idx::Int, br::BeamDesignResult, frame_elements::Vector{Int},
                      events::Vector{StructuralSizer.TraceEvent}; studs = nothing,
                      outline = nothing)
    governing = beam_diagnostic_governing_check(br)
    flexure_clause, shear_clause = _beam_code_clauses(br)
    clause, ratio = _beam_governing_presentation(br, governing, flexure_clause, shear_clause)
    checks = Dict{String, Any}[
        _check(; name = "flexure", clause = flexure_clause,
            ratio = _finite(br.flexure_ratio), governing = governing == "flexure",
            demand = _si(br.Mu, u"kN*m"), demand_unit = "kN·m"),
        _check(; name = "shear", clause = shear_clause,
            ratio = _finite(br.shear_ratio), governing = governing == "shear",
            demand = _si(br.Vu, u"kN"), demand_unit = "kN"),
    ]
    if governing != "flexure" && governing != "shear" && governing != "seismic_frame"
        demand, demand_unit, capacity, capacity_unit = _governing_pair(br, governing)
        push!(checks, _check(; name = governing, clause = clause, ratio = ratio,
            governing = true, demand = demand, demand_unit = demand_unit,
            capacity = capacity, capacity_unit = capacity_unit))
    end
    if !isnothing(br.seismic_frame)
        sf = br.seismic_frame
        push!(checks, _check(; name = "seismic_frame", clause = "ASCE 7-22 §12.2.5.8",
            ratio = _finite(sf.ratio), governing = governing == "seismic_frame",
            extra = Dict{String, Any}(
                "governing_check" => sf.governing_check,
                "case" => sf.case_label,
                "detail" => sf.detail,
                "passed" => sf.passed,
            )))
    end
    return Dict{String, Any}(
        "id" => "beam:$(idx)",
        "kind" => "beam",
        "title" => "Beam $(idx)",
        "design_index" => idx,
        "governing" => _governing_block(governing, ratio, br.ok, clause),
        "bind" => Dict{String, Any}("frame_elements" => frame_elements),
        "drawing" => Dict{String, Any}(
            "section" => br.section_size,
            "length_m" => _si(br.member_length, u"m"),
            "weight_kg" => _si(br.weight, u"kg"),
            "outline_m" => outline === nothing ? _section_outline(br.section_obj) : outline,
            "rebar_m" => _rebar_drawing(br.section_obj),
            "transverse" => _transverse_drawing(br.section_obj),
            "studs" => studs,
        ),
        "checks" => checks,
        "path" => _path_for(events, "beam", idx),
    )
end

"""
Studs stored with the composite stiffness of `beam`, or `nothing`.

`s_m` is the station from the beam start. `y_m` is the offset from the
centerline. `z_m` is the top of steel in the section frame, and the shank
runs `length_m` from there toward the slab.
"""
function _stud_drawing(struc, beam)
    layout = composite_stud_placement(struc, beam)
    layout === nothing && return nothing
    # A stored layout with no stations is a composite beam whose steel alone
    # met the shear. The picture says so. It does not invent stud positions.
    if isempty(layout.s)
        return Dict{String, Any}(
            "count" => 0,
            "note" => "Steel alone meets the shear. No studs are required.",
        )
    end
    return Dict{String, Any}(
        "s_m" => layout.s,
        "y_m" => layout.y,
        "z_m" => layout.z_flange,
        "diameter_m" => ustrip(u"m", layout.d_sa),
        "length_m" => ustrip(u"m", layout.l_sa),
        "count" => length(layout.s),
    )
end

"""
Catalog flute of a composite deck, or `nothing` for any other floor result.

`direction` is the slab span axis in plan, the line the ribs run along.
A zero axis is left null. Widths and the gage come from the deck catalog.
"""
function _deck_drawing(result, axis)
    result isa StructuralSizer.CompositeDeckResult || return nothing
    prof = StructuralSizer.composite_deck_profile(result.deck_profile)
    haskey(prof.gages, result.deck_gauge) || error(
        "deck profile $(prof.name) has no gage $(result.deck_gauge)")
    ax, ay = axis
    direction = hypot(ax, ay) > 1e-8 ? [ax, ay] : nothing
    return Dict{String, Any}(
        "profile" => prof.name,
        "hr_m" => _si(result.deck_depth, u"m"),
        "rib_top_m" => _si(prof.rib_top, u"m"),
        "rib_bottom_m" => _si(prof.rib_bottom, u"m"),
        "pitch_m" => _si(prof.pitch, u"m"),
        "fill_m" => _si(result.fill_depth, u"m"),
        "total_depth_m" => _si(result.total_depth, u"m"),
        "gage" => result.deck_gauge,
        "sheet_m" => _si(prof.gages[result.deck_gauge].t, u"m"),
        "direction" => direction,
    )
end

"""Center-to-center spacing of parallel plan lines, or `nothing` when they are not one spacing."""
function _rib_spacing(lines::Vector{NTuple{4, Float64}})
    length(lines) < 2 && return nothing
    dirs = NTuple{2, Float64}[]
    for (ax, ay, bx, by) in lines
        push!(dirs, _unit2((bx - ax, by - ay)))
    end
    d0 = dirs[1]
    all(d -> abs(_dot2(d, d0)) > 0.999, dirs) || return nothing
    normal = (-d0[2], d0[1])
    offsets = sort!([_dot2((ax, ay), normal) for (ax, ay, _, _) in lines])
    clustered = Float64[offsets[1]]
    for value in offsets
        abs(value - clustered[end]) <= 0.01 && continue
        push!(clustered, value)
    end
    length(clustered) < 2 && return nothing
    step = clustered[2] - clustered[1]
    all(i -> abs((clustered[i + 1] - clustered[i]) - step) <= 0.01, 1:(length(clustered) - 1)) || return nothing
    return step
end

"""
Stem shared by the T-beam ribs under `slab`, or `nothing` when the slab has none.

`uniform` is false when those stems are not one section. Spacing is the
center-to-center distance of parallel ribs, and stays null otherwise.
"""
function _rib_drawing(design::BuildingDesign, struc::BuildingStructure, slab)
    lines = NTuple{4, Float64}[]
    stems = StructuralSizer.RCTBeamSection[]
    for (bi, beam) in enumerate(struc.beams)
        any(s -> s === slab, _slabs_on_beam(struc, beam)) || continue
        br = get(design.beams, bi, nothing)
        isnothing(br) && continue
        sec = br.section_obj
        sec isa StructuralSizer.RCTBeamSection || continue
        push!(stems, sec)
        edges = [struc.segments[si].edge_idx for si in segment_indices(beam)]
        isempty(edges) && continue
        verts = _ordered_chain_vertices(struc.skeleton, edges)
        a = _vertex_xy_m(struc.skeleton, first(verts))
        b = _vertex_xy_m(struc.skeleton, last(verts))
        push!(lines, (a[1], a[2], b[1], b[2]))
    end
    isempty(stems) && return nothing
    first_stem = first(stems)
    same(sec) = abs(ustrip(u"m", sec.bw - first_stem.bw)) <= 0.001 &&
                abs(ustrip(u"m", sec.h - first_stem.h)) <= 0.001 &&
                abs(ustrip(u"m", sec.hf - first_stem.hf)) <= 0.001
    all(same, stems) || return Dict{String, Any}("uniform" => false)
    return Dict{String, Any}(
        "uniform" => true,
        "bw_m" => _si(first_stem.bw, u"m"),
        "stem_m" => _si(first_stem.h - first_stem.hf, u"m"),
        "flange_m" => _si(first_stem.hf, u"m"),
        "spacing_m" => _rib_spacing(lines),
    )
end

function _slab_record(idx::Int, sr::SlabDesignResult, slab, elevation, events,
                      design::BuildingDesign, struc::BuildingStructure)
    governing = slab_diagnostic_governing_check(sr)
    defl_measured = slab_deflection_measured(sr)
    defl_clause = "ACI 318-19 §24.2"
    # A solid head is the two sections of ACI 318-11 §11.11.1.2. A flat plate
    # keeps the §22.6 label the slab result was checked under.
    punch_clause = any(fl -> fl.pattern isa IsoparametricPattern && fl.pattern.solid_head > 0,
                       slab.framing_levels) ? "ACI 318-11 §11.11.1.2" : "ACI 318-19 §22.6"
    clause = governing == "deflection" ? defl_clause :
             governing == "punching_shear_slab" ? punch_clause : ""
    ratio = governing == "deflection" ? _finite(sr.deflection_ratio) :
            governing == "punching_shear_slab" ? _finite(sr.punching_max_ratio) : nothing
    ok = _slab_design_ok(sr)
    return Dict{String, Any}(
        "id" => "slab:$(idx)",
        "kind" => "slab",
        "title" => "Slab $(idx)",
        "design_index" => idx,
        "governing" => _governing_block(governing, ratio, ok, clause),
        "bind" => Dict{String, Any}(
            "shell_kinds" => [0, 2],
            "elevation_m" => elevation,
            "cell_indices" => [i - 1 for i in slab.cell_indices],
            "plan_m" => _slab_plan_m(struc, slab),
        ),
        "drawing" => Dict{String, Any}(
            "floor_type" => string(slab.floor_type),
            "position" => string(slab.position),
            "thickness_m" => _si(sr.thickness, u"m"),
            "self_weight_kPa" => _si(sr.self_weight, u"kPa"),
            "span_primary_m" => _si(slab.spans.primary, u"m"),
            "span_secondary_m" => _si(slab.spans.secondary, u"m"),
            "column_strip" => _strip_records(sr.column_strip),
            "middle_strip" => _strip_records(sr.middle_strip),
            "h_drop_m" => sr.h_drop_in == 0 ? nothing : _finite(ustrip(u"m", sr.h_drop_in * u"inch")),
            "a_drop1_m" => sr.a_drop1_ft == 0 ? nothing : _finite(ustrip(u"m", sr.a_drop1_ft * u"ft")),
            "a_drop2_m" => sr.a_drop2_ft == 0 ? nothing : _finite(ustrip(u"m", sr.a_drop2_ft * u"ft")),
            "deck" => _deck_drawing(slab.result, slab.spans.axis),
            "ribs" => _rib_drawing(design, struc, slab),
        ),
        "checks" => Dict{String, Any}[
            _check(; name = "deflection", clause = defl_clause,
                ratio = defl_measured ? _finite(sr.deflection_ratio) : nothing,
                governing = governing == "deflection",
                demand = defl_measured ? _finite(ustrip(u"m", sr.deflection_in * u"inch")) : nothing,
                demand_unit = "m",
                capacity = defl_measured ? _finite(ustrip(u"m", sr.deflection_limit_in * u"inch")) : nothing,
                capacity_unit = "m"),
            _check(; name = "punching_shear_slab", clause = punch_clause,
                ratio = _finite(sr.punching_max_ratio), governing = governing == "punching_shear_slab",
                demand = _finite(ustrip(u"kPa", sr.punching_vu_max_psi * u"psi")), demand_unit = "kPa",
                extra = Dict{String, Any}(
                    "has_studs" => sr.has_studs,
                    "n_stud_cols" => sr.n_stud_cols,
                    "stud_rails_max" => sr.stud_rails_max,
                    "stud_per_rail_max" => sr.stud_per_rail_max,
                )),
        ],
        "method" => Dict{String, Any}(
            "requested" => _text(sr.method_requested),
            "used" => _text(sr.method_used),
            "fallback" => String[string(r) for r in sr.method_fallback_reasons],
            "iterations" => sr.iterations,
            "converged" => sr.converged,
            "failure_reason" => sr.failure_reason,
            "failing_check" => sr.failing_check,
            "pattern_loading" => sr.pattern_loading,
            "analysis_status" => sr.analysis_status,
            "M0_kNm" => _si(sr.M0, u"kN*m"),
            "qu_kPa" => _si(sr.qu, u"kPa"),
            "integrity_ok" => sr.integrity_ok,
            "n_transfer_bars_additional" => sr.n_transfer_bars_additional,
            "col_rho_max" => _finite(sr.col_rho_max),
            "rho_prime" => _finite(sr.ρ_prime),
        ),
        "path" => _path_for(events, "slab", idx),
    )
end

function _wall_record(idx::Int, wall, records::Vector{WallCheckRecord},
                      struc::BuildingStructure, events)
    rec = _wall_record_body(idx, wall, records, events)
    height_m = rec["drawing"]["height_m"]
    z0, z1 = _story_range_m(struc, wall.story, height_m)
    rec["bind"]["z0_m"] = z0
    rec["bind"]["z1_m"] = z1
    origin = rec["bind"]["plane"]["origin"]
    origin[3] = something(z0, 0.0)
    return rec
end

function _wall_record_body(idx::Int, wall, records::Vector{WallCheckRecord}, events)
    length_m = hypot(wall.x2 - wall.x1, wall.y2 - wall.y1)
    dx = wall.x2 - wall.x1
    dy = wall.y2 - wall.y1
    nlen = hypot(dx, dy)
    normal = nlen > 1e-9 ? [-dy / nlen, dx / nlen, 0.0] : [0.0, 1.0, 0.0]
    checks = Dict{String, Any}[]
    governing = ""
    governing_ratio = nothing
    all_passed = true
    for rec in records
        all_passed &= rec.passed
        ratio = _finite(rec.ratio)
        if ratio !== nothing && (governing_ratio === nothing || ratio > governing_ratio)
            governing = rec.check
            governing_ratio = ratio
        end
        push!(checks, _check(;
            name = rec.check, clause = rec.clause, ratio = ratio, governing = false,
            demand = _finite(rec.demand), capacity = _finite(rec.capacity),
            extra = Dict{String, Any}(
                "passed" => rec.passed,
                "story" => rec.story,
                "direction" => string(rec.direction),
                "case" => string(rec.case),
                "combination" => string(rec.combination),
                "alternative" => string(rec.alternative),
            ),
        ))
    end
    gov_clause = ""
    for row in checks
        row["governing"] = row["name"] == governing && governing != ""
        if row["governing"] == true
            gov_clause = String(row["clause"])
        end
    end
    return Dict{String, Any}(
        "id" => "wall:$(idx)",
        "kind" => "wall",
        "title" => "Wall $(idx)",
        "design_index" => idx,
        "story" => wall.story,
        "governing" => _governing_block(governing, governing_ratio, all_passed, gov_clause),
        "bind" => Dict{String, Any}(
            "shell_kinds" => [1],
            "plane" => Dict{String, Any}(
                "origin" => [wall.x1, wall.y1, 0.0],
                "normal" => normal,
            ),
            "z0_m" => nothing,
            "z1_m" => nothing,
        ),
        "drawing" => Dict{String, Any}(
            "x1_m" => wall.x1, "y1_m" => wall.y1, "x2_m" => wall.x2, "y2_m" => wall.y2,
            "length_m" => length_m,
            "height_m" => _si(wall.base.L, u"m"),
            "thickness_m" => _si(wall.thickness, u"m"),
            "rho_l" => _finite(wall.ρl),
            "rho_t" => _finite(wall.ρt),
            "note" => "A failed ordinary-wall check is reported. The section is not changed.",
        ),
        "checks" => checks,
        "path" => _path_for(events, "wall", idx),
    )
end

"""Title for a footing dossier. The kind byte is `footing_kind`."""
function _footing_title(ftype::Symbol, idx::Int)
    ftype === :mat && return "Mat $idx"
    ftype === :wall_strip && return "Wall strip $idx"
    ftype === :strip && return "Strip footing $idx"
    ftype === :combined && return "Combined footing $idx"
    return "Spread footing $idx"
end

"""Steel areas from a sizer result. A per-width area stays in metres, not square metres."""
function _footing_reinforcement(result)
    names = (:As, :As_bot, :As_top, :As_long_bot, :As_long_top, :As_trans, :As_tensile,
             :As_x_bot, :As_x_top, :As_y_bot, :As_y_top)
    out = Dict{String, Any}()
    for name in names
        hasproperty(result, name) || continue
        q = getproperty(result, name)
        q isa Unitful.Quantity || continue
        dim = dimension(q)
        if dim == dimension(1.0u"m^2")
            out[string(name) * "_m2"] = _si(q, u"m^2")
        elseif dim == dimension(1.0u"m")
            out[string(name) * "_m"] = _si(q, u"m")
        end
    end
    return out
end

"""One opening on a wall the footing carries. A door does not split the mat."""
function _footing_opening(op)
    return Dict{String, Any}(
        "s0_m" => op.s0,
        "z0_m" => op.z0,
        "width_m" => op.width,
        "height_m" => op.height,
        "kind" => string(op.kind),
    )
end

"""Grade walls on a footing, with the openings cut in each centerline."""
function _footing_wall_records(walls, indices)
    out = Dict{String, Any}[]
    for i in indices
        1 <= i <= length(walls) || continue
        w = walls[i]
        push!(out, Dict{String, Any}(
            "index" => i,
            "x1_m" => w.x1,
            "y1_m" => w.y1,
            "x2_m" => w.x2,
            "y2_m" => w.y2,
            "thickness_m" => _si(w.thickness, u"m"),
            "openings" => [_footing_opening(op) for op in w.openings],
        ))
    end
    return out
end

function _footing_record(idx::Int, fr::FoundationDesignResult, scene_index::Int,
                         support_nodes::Vector{Int}, events, fdn, walls)
    ftype = fdn.foundation_type
    result = fdn.result
    analysis = hasproperty(result, :analysis) ? string(result.analysis) : nothing
    n_columns = hasproperty(result, :n_columns) ? Int(result.n_columns) : nothing
    utilization = hasproperty(result, :utilization) ? _finite(result.utilization) : nothing
    wall_records = _footing_wall_records(walls, fdn.wall_indices)
    segs = [(w["x1_m"], w["y1_m"], w["x2_m"], w["y2_m"]) for w in wall_records]
    note = ftype === :wall_strip && !_legs_colinear(segs) ?
        "The box is the extent of the legs. The footing is those legs, not the filled rectangle." :
        nothing
    # A wall or mat result without a per-check breakdown reports only its
    # governing utilization.
    has_breakdown = hasproperty(result, :checks) &&
        any(!isnan, (result.checks.bearing, result.checks.punching, result.checks.one_way_shear))
    wall_governed = ftype in (:mat, :wall_strip) && utilization !== nothing && !has_breakdown
    governing = wall_governed ? "utilization" : foundation_diagnostic_governing_check(fr)
    ratios = Dict(foundation_check_ratios(fr))
    ratio = governing == "utilization" ? utilization : _finite(get(ratios, governing, NaN))
    checks = Dict{String, Any}[
        _check(; name = "bearing", clause = "", ratio = _finite(fr.bearing_ratio),
            governing = governing == "bearing",
            demand = _si(fr.reaction, u"kN"), demand_unit = "kN"),
        _check(; name = "punching_shear_fdn", clause = "",
            ratio = _finite(fr.punching_ratio), governing = governing == "punching_shear_fdn"),
        _check(; name = "one_way_shear_fdn", clause = "",
            ratio = _finite(fr.one_way_shear_ratio), governing = governing == "one_way_shear_fdn"),
        _check(; name = "flexure_fdn", clause = "",
            ratio = _finite(fr.flexure_ratio), governing = governing == "flexure_fdn"),
    ]
    utilization !== nothing && push!(checks, _check(;
        name = "utilization", clause = "", ratio = utilization,
        governing = governing == "utilization"))
    return Dict{String, Any}(
        "id" => "footing:$(idx)",
        "kind" => "footing",
        "title" => _footing_title(ftype, idx),
        "design_index" => idx,
        "governing" => _governing_block(governing, ratio, fr.ok, ""),
        "bind" => Dict{String, Any}(
            "footing" => scene_index,
            "support_nodes" => support_nodes,
        ),
        "drawing" => Dict{String, Any}(
            "foundation_type" => string(ftype),
            "analysis" => analysis,
            "utilization" => utilization,
            "n_columns" => n_columns,
            "length_m" => _si(fr.length, u"m"),
            "width_m" => _si(fr.width, u"m"),
            "depth_m" => _si(fr.depth, u"m"),
            "group_id" => fr.group_id,
            "concrete_m3" => _si(fr.concrete_volume, u"m^3"),
            "steel_m3" => _si(fr.steel_volume, u"m^3"),
            "reinforcement" => _footing_reinforcement(result),
            "wall_indices" => Int[i for i in fdn.wall_indices],
            "walls" => wall_records,
            "note" => note,
        ),
        "checks" => checks,
        "path" => vcat(_path_for(events, "foundation", idx), _path_for(events, "footing", idx)),
    )
end

"""
Design-earthquake route on each gravity member, and the boundary route on
each special pier. Both are already on `ordinary_wall_result`. A design
without that result is unchanged.

The clause is the section that applies. There is no utilization ratio:
§18.14.3 is a choice between two detailing sections, and §18.10.6 is whether
a boundary element is required. The demand is the induced moment, or the
boundary-zone length when one was computed.
"""
function _attach_outcome_checks!(components, design)
    result = design.structure.ordinary_wall_result
    result === nothing && return components
    by_id = Dict(rec["id"] => rec for rec in components)
    if hasproperty(result, :induced)
        for check in result.induced
            kind = check.kind === :column ? "column" :
                   check.kind === :beam ? "beam" : ""
            isempty(kind) && continue
            rec = get(by_id, "$(kind):$(check.index)", nothing)
            rec === nothing && continue
            within = check.calculated && !check.exceeds
            push!(rec["checks"], _check(;
                name = "design_earthquake_displacement",
                clause = within ? "ACI 318-19 §18.14.3.2" : "ACI 318-19 §18.14.3.3",
                ratio = nothing,
                governing = false,
                demand = check.Mu_Nm / 1000,
                demand_unit = "kN·m",
                extra = Dict{String, Any}(
                    "Vu_kN" => check.Vu_N / 1000,
                    "calculated" => check.calculated,
                    "exceeds" => check.exceeds,
                    "section" => within ? "18.14.3.2" : "18.14.3.3",
                    "asce" => "ASCE 7-22 §12.12.4",
                )))
        end
    end
    hasproperty(result, :boundary) || return components
    for (idx, decision) in result.boundary
        rec = get(by_id, "wall:$(idx)", nothing)
        rec === nothing && continue
        route = decision.route === :displacement ?
            "ACI 318-19 §18.10.6.2" : "ACI 318-19 §18.10.6.3"
        state = decision.required === true ? "required" :
                decision.required === false ? "not required" : "not evaluated"
        push!(rec["checks"], _check(;
            name = "boundary_element",
            clause = route * " · " * state,
            ratio = nothing,
            governing = false,
            demand = decision.zone_length_m,
            demand_unit = decision.zone_length_m === nothing ? "" : "m",
            extra = Dict{String, Any}(
                "required" => decision.required,
                "c_m" => decision.c_m,
                "route" => string(decision.route),
                "required_by" => string(decision.required_by),
            )))
    end
    return components
end

function _summary_record(design::BuildingDesign, bd::Union{Nothing, BuildingDetail} = nothing)
    s = design.summary
    induced = design.structure.ordinary_wall_result
    checks = induced === nothing || !hasproperty(induced, :induced) ?
             GravityInducedCheck[] : induced.induced
    return Dict{String, Any}(
        "all_checks_pass" => s.all_checks_pass,
        "critical_element" => s.critical_element,
        "critical_ratio" => _finite(s.critical_ratio),
        "concrete_m3" => _si(s.concrete_volume, u"m^3"),
        "steel_kg" => _si(s.steel_weight, u"kg"),
        "rebar_kg" => _si(s.rebar_weight, u"kg"),
        "rebar_detailed_kg" => bd === nothing ? nothing : _si(building_detail_mass(bd), u"kg"),
        "embodied_carbon_kgco2e" => _si(s.embodied_carbon, u"kgCO2e"),
        "induced_within" => count(c -> c.calculated && !c.exceeds, checks),
        "induced_over" => count(c -> c.calculated && c.exceeds, checks),
        "induced_unchecked" => count(c -> !c.calculated, checks),
    )
end

"""Analysis elevation of `member`, in metres, from its first segment. `nothing` when the member has no edge."""
function _member_elevation_m(struc::BuildingStructure, member)
    segs = segment_indices(member)
    isempty(segs) && return nothing
    si = first(segs)
    1 <= si <= length(struc.segments) || return nothing
    edge = struc.segments[si].edge_idx
    1 <= edge <= length(struc.skeleton.edge_indices) || return nothing
    v1, _ = struc.skeleton.edge_indices[edge]
    return _vertex_z_m(struc.skeleton, v1)
end

"""
Open a solid-head piece as a slab of the full rib depth.

The beam record still carries the catalog section. A head piece replaces that
with the gross rectangle and a slab sheet: no stirrups, no T-flange.
`elevation` is the analysis line of the piece, the same storey elevation the
slab shell uses. The head does not receive `shell_kinds`, so it does not
become the owner of those triangles.
"""
function _present_solid_head!(rec, rect, idx::Int, elevation = nothing)
    drawing = get(rec, "drawing", nothing)
    drawing isa AbstractDict || return rec
    detail = get(drawing, "detail", nothing)
    detail isa AbstractDict || return rec
    get(detail, "kind", "") == "slab" || return rec
    rec["kind"] = "slab"
    rec["title"] = "Solid head $idx"
    drawing["transverse"] = nothing
    drawing["outline_m"] = nothing
    drawing["rebar_m"] = nothing
    drawing["solid_head"] = true
    if rect !== nothing
        drawing["thickness_m"] = rect[2]
        drawing["span_primary_m"] = get(drawing, "length_m", nothing)
        drawing["width_m"] = rect[1]
    end
    bind = get(rec, "bind", nothing)
    if bind isa AbstractDict && elevation isa Number
        bind["elevation_m"] = Float64(elevation)
    end
    return rec
end

"""
    scene_component_records(design, model) -> (components, design_trace)

The viewer dossier and the solve trace, both JSON-safe. `design_trace.events`
is every recorded solver event. `components[].path` is the subset that names
that component.
"""
function scene_component_records(design::BuildingDesign, model::Asap.Model;
                                 origin::NTuple{3, Float64} = (0.0, 0.0, 0.0))
    struc = design.structure
    events = design.solver_trace
    by_edge = _frame_elements_by_edge(design, model)
    slab_polys = _story_slab_polygons(struc)
    bd = detail_building(design)
    with_detail!(rec, kind, dict, idx) =
        (rec["drawing"]["detail"] = _detail_record(_member_detail(bd, kind, dict, idx)); rec)
    components = Dict{String, Any}[]
    for idx in sort(collect(keys(design.columns)))
        idx > length(struc.columns) && continue
        push!(components, with_detail!(_column_record(
            idx, design.columns[idx], struc.columns[idx],
            _member_elements(struc, struc.columns[idx], by_edge), events),
            "column", bd.columns, idx))
    end
    head_rect = solid_head_rectangles_m(struc)
    for idx in sort(collect(keys(design.beams)))
        idx > length(struc.beams) && continue
        beam_elems = _member_elements(struc, struc.beams[idx], by_edge)
        sec = design.beams[idx].section_obj
        side = _member_flange_side(model, beam_elems, sec, slab_polys, origin)
        rec = with_detail!(_beam_record(
            idx, design.beams[idx], beam_elems, events;
            studs = _stud_drawing(struc, struc.beams[idx]),
            outline = _edge_flange_outline(sec, side)),
            "beam", bd.beams, idx)
        push!(components, _present_solid_head!(
            rec, get(head_rect, idx, nothing), idx,
            _member_elevation_m(struc, struc.beams[idx])))
    end
    for idx in sort(collect(keys(design.slabs)))
        idx > length(struc.slabs) && continue
        slab = struc.slabs[idx]
        push!(components, with_detail!(_slab_record(
            idx, design.slabs[idx], slab, _slab_elevation_m(struc, slab), events, design, struc),
            "slab", bd.slabs, idx))
    end
    for idx in sort(collect(keys(design.walls)))
        idx > length(struc.walls) && continue
        push!(components, with_detail!(
            _wall_record(idx, struc.walls[idx], design.walls[idx], struc, events),
            "wall", bd.walls, idx))
    end
    _attach_outcome_checks!(components, design)
    scene_i = 0
    for (idx, fdn) in enumerate(struc.foundations)
        res = get(design.foundations, idx, nothing)
        isnothing(res) && continue
        support_nodes = _footing_support_nodes(model, struc, fdn.support_indices, design.structural_offsets)
        isempty(support_nodes) && continue
        push!(components, with_detail!(
            _footing_record(idx, res, scene_i, Int.(support_nodes), events, fdn, struc.walls),
            "footing", bd.footings, idx))
        scene_i += 1
    end
    trace = Dict{String, Any}(
        "event_count" => length(events),
        "converged" => design.converged,
        "diagnostics" => design.diagnostics,
        "scope_notes" => design.scope_notes,
        "phase_timings_s" => Dict{String, Any}(k => v for (k, v) in design.phase_timings),
        "summary" => _summary_record(design, bd),
        "events" => [_event_record(ev) for ev in events],
    )
    return components, trace
end

function _with_component_records(packet::ScenePacket, design::BuildingDesign, model::Asap.Model)
    components, trace = scene_component_records(design, model; origin = packet.origin)
    meta = copy(packet.meta)
    meta["components"] = components
    meta["design_trace"] = trace
    counts = copy(meta["counts"])
    counts["components"] = length(components)
    meta["counts"] = counts
    return ScenePacket(packet.stages, packet.origin, meta, packet.buffers)
end
