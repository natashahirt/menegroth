# =============================================================================
# API Deserialize — JSON input → BuildingSkeleton + DesignParameters
# =============================================================================

"""
    parse_unit(unit_str::String) -> Unitful.FreeUnits

Convert a JSON unit string to a Unitful unit. Throws `ArgumentError` for
unrecognised strings.
"""
function parse_unit(unit_str::String)
    s = lowercase(strip(unit_str))
    s in ("feet", "ft")          && return u"ft"
    s in ("inches", "in")        && return u"inch"
    s in ("meters", "m")         && return u"m"
    s in ("millimeters", "mm")   && return u"mm"
    s in ("centimeters", "cm")   && return u"cm"
    throw(ArgumentError(
        "Unknown unit \"$unit_str\". " *
        "Accepted: $(_accepted_doc(API_UNIT_ALIASES))"))
end

# =============================================================================
# Shatter Logic — split long edges at intermediate vertices
# =============================================================================

"""
    _shatter_edges(skel, edge_pairs, group; tol=1e-6) -> nothing

For each edge pair `[v1, v2]`, detect any existing skeleton vertices that lie
on the line segment between `v1` and `v2`. If intermediates are found, the edge
is split into ordered sub-segments and all sub-segments are added to the
skeleton. The original user-line is recorded in `skel.edge_chains` so that
`initialize_members!` can later merge the sub-segments into one member.

If no intermediates exist, the edge is added as-is (no chain entry needed —
1:1 mapping is the default).
"""
function _shatter_edges!(skel::BuildingSkeleton{T}, edge_pairs::Vector{Vector{Int}},
                          group::Symbol; tol::Float64=1e-6) where T
    all_vertex_indices = Set(1:length(skel.vertices))

    for pair in edge_pairs
        v1, v2 = pair
        p1 = skel.vertices[v1]
        p2 = skel.vertices[v2]

        # Find intermediate vertices on this line segment
        intermediates = _find_intermediates(skel, v1, v2, all_vertex_indices, tol)

        if isempty(intermediates)
            # No shattering needed — add as single edge
            seg = Meshes.Segment(p1, p2)
            add_element!(skel, seg; group=group)
        else
            # Sort intermediates by parameter along the line and shatter
            chain_id = UInt64(hash((:edge_chain, group, v1, v2)))
            chain_edges = Int[]

            # Build ordered vertex sequence: v1 → intermediates → v2
            ordered = vcat(v1, [vi for (vi, _) in intermediates], v2)

            for k in 1:(length(ordered) - 1)
                va, vb = ordered[k], ordered[k + 1]
                seg = Meshes.Segment(skel.vertices[va], skel.vertices[vb])
                add_element!(skel, seg; group=group)
                push!(chain_edges, length(skel.edges))
            end

            skel.edge_chains[chain_id] = chain_edges
        end
    end
end

"""
Find skeleton vertex indices that lie strictly between `v1` and `v2` on the
line segment, returned sorted by parameter `t ∈ (0, 1)`.
"""
function _find_intermediates(skel::BuildingSkeleton{T}, v1::Int, v2::Int,
                              candidates::Set{Int}, tol::Float64) where T
    p1 = skel.vertices[v1]
    p2 = skel.vertices[v2]

    c1 = Meshes.coords(p1)
    c2 = Meshes.coords(p2)
    dx = ustrip(c2.x - c1.x)
    dy = ustrip(c2.y - c1.y)
    dz = ustrip(c2.z - c1.z)
    seg_len_sq = dx^2 + dy^2 + dz^2
    seg_len_sq < tol^2 && return Tuple{Int, Float64}[]

    result = Tuple{Int, Float64}[]

    for vi in candidates
        vi == v1 && continue
        vi == v2 && continue

        pv = skel.vertices[vi]
        cv = Meshes.coords(pv)
        ex = ustrip(cv.x - c1.x)
        ey = ustrip(cv.y - c1.y)
        ez = ustrip(cv.z - c1.z)

        # Parameter along the line
        t = (ex * dx + ey * dy + ez * dz) / seg_len_sq
        (t < tol || t > 1.0 - tol) && continue

        # Distance from point to line
        # Cross product magnitude / segment length
        cx = ey * dz - ez * dy
        cy = ez * dx - ex * dz
        cz = ex * dy - ey * dx
        dist_sq = (cx^2 + cy^2 + cz^2) / seg_len_sq
        dist_sq > tol^2 && continue

        push!(result, (vi, t))
    end

    sort!(result; by=last)
    return result
end

# =============================================================================
# JSON → BuildingSkeleton
# =============================================================================

"""Throw ArgumentError if any edge vertex index is out of [1, n_verts]."""
function _validate_edge_bounds(edge_pairs::Vector{Vector{Int}}, n_verts::Int, label::String)
    for (i, pair) in enumerate(edge_pairs)
        length(pair) >= 2 || throw(ArgumentError("$label edge $i has $(length(pair)) indices (expected 2)."))
        v1, v2 = pair[1], pair[2]
        (v1 >= 1 && v1 <= n_verts) || throw(ArgumentError("$label edge $i: vertex index $v1 out of range [1, $n_verts]."))
        (v2 >= 1 && v2 <= n_verts) || throw(ArgumentError("$label edge $i: vertex index $v2 out of range [1, $n_verts]."))
    end
end

"""Add vertices from input.vertices to the skeleton (coordinates converted via _to_m)."""
function _add_vertices!(skel::BuildingSkeleton, input::APIInput, _to_m)
    for coords in input.vertices
        pt = Meshes.Point(_to_m(coords[1]), _to_m(coords[2]), _to_m(coords[3]))
        add_vertex!(skel, pt)
    end
end

"""
Add beam, column, brace, and wall edges with bounds checks and shatter.

`input.edges.walls` is shattered into the `:walls` group. An empty wall list
is a no-op: `_shatter_edges!` iterates nothing and adds no edges.
"""
function _add_edges!(skel::BuildingSkeleton, input::APIInput)
    n_verts = length(skel.vertices)
    _validate_edge_bounds(input.edges.beams, n_verts, "Beam")
    _validate_edge_bounds(input.edges.columns, n_verts, "Column")
    _validate_edge_bounds(input.edges.braces, n_verts, "Brace")
    _validate_edge_bounds(input.edges.walls, n_verts, "Wall")
    _shatter_edges!(skel, input.edges.beams, :beams)
    _shatter_edges!(skel, input.edges.columns, :columns)
    _shatter_edges!(skel, input.edges.braces, :braces)
    _shatter_edges!(skel, input.edges.walls, :walls)
end

"""Add support vertices; throws if any support index is out of [1, n_vertices]."""
function _add_supports!(skel::BuildingSkeleton, input::APIInput)
    n_verts = length(skel.vertices)
    for vi in input.supports
        (vi >= 1 && vi <= n_verts) || throw(ArgumentError("Support vertex index $vi out of range [1, $n_verts]."))
        add_vertex!(skel, skel.vertices[vi]; group=:support)
    end
end

"""Rebuild stories then add explicit faces or find/auto-categorize faces."""
function _add_faces!(skel::BuildingSkeleton, input::APIInput, coord_unit, _to_m)
    if isempty(skel.vertices)
        error("Cannot rebuild stories: no vertices found in skeleton")
    end
    rebuild_stories!(skel)
    if isempty(skel.stories_z)
        error("rebuild_stories! failed to populate stories_z from $(length(skel.vertices)) vertices")
    end
    has_explicit = !isempty(input.faces) && any(!isempty(polys) for polys in values(input.faces))
    find_faces!(skel)
    _auto_categorize_faces!(skel)
    rebuild_geometry_cache!(skel)
    if has_explicit
        _apply_explicit_face_groups!(skel, input.faces, _to_m)
    end
end

"""
    json_to_skeleton(input::APIInput) -> BuildingSkeleton

Build a `BuildingSkeleton` from the parsed JSON input.

All coordinates are converted to **meters** internally, matching the convention
used by `gen_medium_office` and required by `BuildingStructure` (which hardcodes
`A = typeof(1.0u"m^2")` for area and `P = typeof(1.0u"kN/m^2")` for pressure).

## Shatter behaviour
Long edges that pass through intermediate vertices are automatically split into
sub-segments. The original user-line is recorded in `skel.edge_chains` so that
`initialize_members!` can merge sub-segments into one continuous member.

## Stories Z
If `input.stories_z` is empty, story elevations are inferred from the unique Z
coordinates of all vertices via `rebuild_stories!`.

## Bounds checks
Vertex indices in edges and supports are validated; out-of-range indices throw
`ArgumentError` even when `validate_input` has not been called.
"""
function json_to_skeleton(input::APIInput)
    coord_unit = parse_unit(input.units)
    _to_m(val) = uconvert(u"m", val * coord_unit)

    T = typeof(1.0u"m")
    skel = BuildingSkeleton{T}()
    enable_lookup!(skel)

    if !isempty(input.stories_z)
        skel.stories_z = [_to_m(z) for z in input.stories_z]
    end

    _add_vertices!(skel, input, _to_m)
    _add_edges!(skel, input)
    _add_supports!(skel, input)
    _add_faces!(skel, input, coord_unit, _to_m)

    n_chains = length(skel.edge_chains)
    n_shattered = sum(length(v) for v in values(skel.edge_chains); init=0)
    @debug "Built skeleton" vertices=length(skel.vertices) edges=length(skel.edges) chains=n_chains shattered_edges=n_shattered

    return skel
end

"""Map explicit face polygons onto detected skeleton faces and assign requested groups."""
function _apply_explicit_face_groups!(skel::BuildingSkeleton{T}, face_groups::APIFaceGroups, _to_m) where T
    for (category, _) in face_groups
        skel.groups_faces[Symbol(category)] = Int[]
    end

    vc = skel.geometry.vertex_coords
    face_to_story = Dict{Int, Int}()
    for (story_idx, story) in skel.stories
        for face_idx in story.faces
            face_to_story[face_idx] = story_idx
        end
    end

    for (category, polylines) in face_groups
        group = Symbol(category)
        for (poly_idx, poly_coords) in enumerate(polylines)
            length(poly_coords) >= 3 || continue

            poly_xy = [(_to_m(c[1]) |> ustrip, _to_m(c[2]) |> ustrip) for c in poly_coords]
            z_val = _to_m(poly_coords[1][3])
            level_idx = _find_level_idx(skel, z_val)

            matched = Int[]
            for (face_idx, vis) in enumerate(skel.face_vertex_indices)
                get(face_to_story, face_idx, typemin(Int)) == level_idx || continue
                cx = sum(vc[vi, 1] for vi in vis) / length(vis)
                cy = sum(vc[vi, 2] for vi in vis) / length(vis)
                _point_in_polygon_2d(cx, cy, poly_xy) && push!(matched, face_idx)
            end

            if isempty(matched)
                throw(ArgumentError(
                    "Explicit face \"$category\"[$poly_idx] did not match any detected skeleton faces. " *
                    "Ensure selector geometry overlaps slab cells on the target story."))
            end
            append!(skel.groups_faces[group], matched)
        end
    end
end

"""Auto-categorise faces by story level (bottom → :grade, top → :roof, middle → :floor)."""
function _auto_categorize_faces!(skel::BuildingSkeleton{T}) where T
    isempty(skel.stories) && return

    sorted_levels = sort(collect(keys(skel.stories)))
    min_level = first(sorted_levels)
    max_level = last(sorted_levels)

    for (level_idx, story) in skel.stories
        target_grp = if level_idx == min_level
            :grade
        elseif level_idx == max_level
            :roof
        else
            :floor
        end
        if !haskey(skel.groups_faces, target_grp)
            skel.groups_faces[target_grp] = Int[]
        end
        append!(skel.groups_faces[target_grp], story.faces)
    end
end

"""Find the story level index for a given Z elevation. Returns a 0-indexed level,
or the nearest story if no exact match is found (with a warning)."""
function _find_level_idx(skel::BuildingSkeleton{T}, z_val) where T
    z_stripped = ustrip(z_val)
    best_idx = 0
    best_dist = Inf
    for (i, sz) in enumerate(skel.stories_z)
        dist = abs(ustrip(sz) - z_stripped)
        if dist < 1e-4
            return i - 1  # 0-indexed, exact match
        end
        if dist < best_dist
            best_dist = dist
            best_idx = i - 1
        end
    end
    @warn "Face at z=$z_val does not match any story elevation exactly; " *
          "snapping to nearest story (level $best_idx, distance=$(round(best_dist; digits=4)))"
    return best_idx
end

"""2D point-in-polygon test with boundary-inclusive tolerance."""
function _point_in_polygon_2d(x::Float64, y::Float64, poly::Vector{Tuple{Float64, Float64}})
    n = length(poly)
    n < 3 && return false

    inside = false
    j = n
    for i in 1:n
        xi, yi = poly[i]
        xj, yj = poly[j]
        if _point_on_segment_2d(x, y, xi, yi, xj, yj)
            return true
        end
        intersects = ((yi > y) != (yj > y)) &&
                     (x < (xj - xi) * (y - yi) / (yj - yi + 1e-16) + xi)
        inside = intersects ? !inside : inside
        j = i
    end
    return inside
end

"""Boundary check helper for 2D point-in-polygon."""
function _point_on_segment_2d(px, py, x1, y1, x2, y2; tol=1e-8)
    dx = x2 - x1
    dy = y2 - y1
    seg_len_sq = dx^2 + dy^2
    seg_len_sq <= tol^2 && return hypot(px - x1, py - y1) <= tol
    t = ((px - x1) * dx + (py - y1) * dy) / seg_len_sq
    (t < -tol || t > 1 + tol) && return false
    qx = x1 + clamp(t, 0.0, 1.0) * dx
    qy = y1 + clamp(t, 0.0, 1.0) * dy
    return hypot(px - qx, py - qy) <= tol
end

# ─── Design Parameters ────────────────────────────────────────────────────────

"""
    json_to_params(api_params::APIParams) -> DesignParameters

Convert API parameter block to a `DesignParameters` instance.
"""
function json_to_params(api_params::APIParams, coord_unit_str::String="meters")
    floor_ll_psf = api_params.loads.floor_LL_psf
    roof_ll_psf = something(api_params.loads.roof_LL_psf, floor_ll_psf)
    grade_ll_psf = something(api_params.loads.grade_LL_psf, floor_ll_psf)

    loads = GravityLoads(
        floor_LL  = floor_ll_psf * psf,
        roof_LL   = roof_ll_psf * psf,
        grade_LL  = grade_ll_psf * psf,
        floor_SDL = api_params.loads.floor_SDL_psf * psf,
        roof_SDL  = api_params.loads.roof_SDL_psf * psf,
        wall_SDL  = api_params.loads.wall_SDL_psf * psf,
    )

    conc, reb, stl = _resolve_materials(api_params)
    column_conc = _resolve_concrete_name(api_params.materials.column_concrete)
    # Set column override so resolve_column_concrete(materials) returns column_conc (default 6 ksi)
    column_rc = StructuralSizer.ReinforcedConcreteMaterial(column_conc, reb)
    materials = MaterialOptions(concrete=conc, rebar=reb, steel=stl, column=column_rc)

    floor = _resolve_floor_options(api_params)

    columns = _resolve_column_options(api_params)
    beams = _resolve_beam_options(api_params)
    # Log when beam_type is ignored (slab-only systems do not size beams)
    ft = Symbol(api_params.floor_type)
    if ft in (:flat_plate, :flat_slab) && api_params.beam_type != "steel_w"
        @info "beam_type=\"$(api_params.beam_type)\" is ignored for floor_type=$(ft) (slab-only system)."
    end

    foundation_options = if api_params.size_foundations
        soil = _resolve_soil_name(api_params.foundation_soil)
        fdn_conc = _resolve_concrete_name(api_params.foundation_concrete)
        reb = _resolve_rebar_name(api_params.materials.rebar)
        opts = _resolve_foundation_options(api_params, fdn_conc, reb)
        FoundationParameters(soil = soil, options = opts, concrete = fdn_conc)
    else
        nothing
    end

    display_units_sys = lowercase(api_params.unit_system) == "metric" ? :metric : :imperial
    scoped_overrides = _resolve_scoped_floor_overrides(api_params, coord_unit_str)

    ucs = Symbol(lowercase(strip(api_params.uniform_column_sizing)))

    framing_opts = _resolve_framing_opts(api_params)

    return DesignParameters(
        loads = loads,
        materials = materials,
        floor = floor,
        framing_opts = framing_opts,
        columns = columns,
        beams = beams,
        fire_rating = validate_fire_rating(api_params.fire_rating),
        optimize_for = Symbol(api_params.optimize_for),
        max_iterations = something(api_params.max_iterations, 20),
        foundation_options = foundation_options,
        scoped_floor_overrides = scoped_overrides,
        uniform_column_sizing = ucs,
        geometry_is_centerline = api_params.geometry_is_centerline,
        display_units = DisplayUnits(display_units_sys),
        visualization_target_edge_m = api_params.visualization_target_edge_m,
        skip_visualization = api_params.skip_visualization,
        visualization_detail = api_params.visualization_detail,
    )
end

"""Resolve face-scoped floor overrides from API params (coordinates converted to meters)."""
function _resolve_scoped_floor_overrides(api_params::APIParams, coord_unit_str::String)
    isempty(api_params.scoped_overrides) && return ScopedFloorOverride[]

    coord_unit = parse_unit(coord_unit_str)
    _to_m(x) = ustrip(uconvert(u"m", x * coord_unit))
    out = ScopedFloorOverride[]

    for ov in api_params.scoped_overrides
        ft = Symbol(ov.floor_type)
        method = ov.floor_options.method
        defl = ov.floor_options.deflection_limit
        punch = ov.floor_options.punching_strategy
        target_edge_m = ov.floor_options.target_edge_m
        concrete = isnothing(ov.floor_options.concrete) ? nothing : _resolve_concrete_name(ov.floor_options.concrete)
        λ = ov.floor_options.vault_lambda

        faces_m = Vector{NTuple{3, Float64}}[]
        for poly in ov.faces
            pts = NTuple{3, Float64}[]
            for c in poly
                length(c) < 3 && continue
                push!(pts, (_to_m(c[1]), _to_m(c[2]), _to_m(c[3])))
            end
            length(pts) >= 3 && push!(faces_m, pts)
        end

        push!(out, ScopedFloorOverride(
            floor_type = ft,
            method = method,
            deflection_limit = defl,
            punching_strategy = punch,
            target_edge_m = target_edge_m,
            concrete = concrete,
            vault_lambda = λ,
            faces = faces_m,
        ))
    end

    return out
end

# ─── Name → object resolution helpers ────────────────────────────────────────

const CONCRETE_MAP = Dict{String, StructuralSizer.Concrete}(
    "NWC_3000" => StructuralSizer.NWC_3000,
    "NWC_4000" => StructuralSizer.NWC_4000,
    "NWC_5000" => StructuralSizer.NWC_5000,
    "NWC_6000" => StructuralSizer.NWC_6000,
    "Earthen_500" => StructuralSizer.Earthen_500,
    "Earthen_1000" => StructuralSizer.Earthen_1000,
    "Earthen_2000" => StructuralSizer.Earthen_2000,
    "Earthen_4000" => StructuralSizer.Earthen_4000,
    "Earthen_8000" => StructuralSizer.Earthen_8000,
)

const REBAR_MAP = Dict{String, StructuralSizer.RebarSteel}(
    "Rebar_40" => StructuralSizer.Rebar_40,
    "Rebar_60" => StructuralSizer.Rebar_60,
    "Rebar_75" => StructuralSizer.Rebar_75,
    "Rebar_80" => StructuralSizer.Rebar_80,
)

const STEEL_MAP = Dict{String, StructuralSizer.StructuralSteel}(
    "A992" => StructuralSizer.A992_Steel,
)

const SOIL_MAP = Dict{String, StructuralSizer.Soil}(
    "loose_sand"  => StructuralSizer.loose_sand,
    "medium_sand" => StructuralSizer.medium_sand,
    "dense_sand"  => StructuralSizer.dense_sand,
    "soft_clay"   => StructuralSizer.soft_clay,
    "stiff_clay"  => StructuralSizer.stiff_clay,
    "hard_clay"   => StructuralSizer.hard_clay,
)

"""Generic named-value resolver: look up `name` in `map`, or error listing options."""
function _resolve_from_map(name::String, map::Dict, label::String)
    haskey(map, name) && return map[name]
    error("Unknown $label: \"$name\". Options: $(join(keys(map), ", "))")
end

_resolve_concrete_name(name::String) = _resolve_from_map(name, CONCRETE_MAP, "concrete grade")
_resolve_rebar_name(name::String)    = _resolve_from_map(name, REBAR_MAP,    "rebar grade")
_resolve_steel_name(name::String)    = _resolve_from_map(name, STEEL_MAP,    "steel type")
_resolve_soil_name(name::String)     = _resolve_from_map(name, SOIL_MAP,     "soil type")

"""Resolve floor options from API params."""
function _resolve_floor_options(api_params::APIParams)
    ft = Symbol(api_params.floor_type)
    method = _resolve_analysis_method(api_params.floor_options)
    defl   = _resolve_deflection_limit(api_params.floor_options.deflection_limit)
    punch  = _resolve_punching_strategy(api_params.floor_options.punching_strategy)

    if ft == :flat_plate
        return StructuralSizer.FlatPlateOptions(
            method=method, deflection_limit=defl, punching_strategy=punch)
    elseif ft == :flat_slab
        return StructuralSizer.FlatSlabOptions(
            base=StructuralSizer.FlatPlateOptions(
                method=method, deflection_limit=defl, punching_strategy=punch))
    elseif ft == :one_way
        return StructuralSizer.OneWayOptions()
    elseif ft == :vault
        # Vault sizing requires either rise or lambda. Use client-provided
        # lambda when available, otherwise default to lambda=10.
        λ = api_params.floor_options.vault_lambda
        return isnothing(λ) ? StructuralSizer.VaultOptions(lambda=10.0) :
                              StructuralSizer.VaultOptions(lambda=λ)
    else
        return StructuralSizer.FlatPlateOptions(
            method=method, deflection_limit=defl, punching_strategy=punch)
    end
end

const _ANALYSIS_METHOD_MAP = Dict{String, Function}(
    "DDM"             => () -> StructuralSizer.DDM(),
    "DDM_SIMPLIFIED"  => () -> StructuralSizer.DDM(:simplified),
    "EFM"             => () -> StructuralSizer.EFM(),
    "EFM_HARDY_CROSS" => () -> StructuralSizer.EFM(solver=:hardy_cross),
)

"""Resolve analysis method from floor options. FEA uses target_edge_m when provided (FEA default: adaptive)."""
function _resolve_analysis_method(floor_opts::APIFloorOptions)
    s = uppercase(strip(floor_opts.method))
    if s == "FEA"
        te = isnothing(floor_opts.target_edge_m) ? nothing : floor_opts.target_edge_m * u"m"
        return StructuralSizer.FEA(target_edge=te)
    end
    haskey(_ANALYSIS_METHOD_MAP, s) && return _ANALYSIS_METHOD_MAP[s]()
    @warn "Unknown analysis_method '$(floor_opts.method)' — defaulting to DDM"
    return StructuralSizer.DDM()
end

const _DEFLECTION_LIMIT_MAP = Dict{String, Symbol}(
    "L_240" => :L_240, "L_360" => :L_360, "L_480" => :L_480,
)

"""Resolve deflection limit string to Symbol."""
function _resolve_deflection_limit(s::String)
    key = uppercase(strip(s))
    haskey(_DEFLECTION_LIMIT_MAP, key) && return _DEFLECTION_LIMIT_MAP[key]
    @warn "Unknown deflection_limit '$s' — defaulting to L_360"
    return :L_360
end

const _PUNCHING_STRATEGY_MAP = Dict{String, Symbol}(
    "grow_columns" => :grow_columns,
    "reinforce_last" => :reinforce_last,
    "reinforce_first" => :reinforce_first,
)

"""Resolve punching strategy string to Symbol."""
function _resolve_punching_strategy(s::String)
    key = lowercase(strip(s))
    haskey(_PUNCHING_STRATEGY_MAP, key) && return _PUNCHING_STRATEGY_MAP[key]
    @warn "Unknown punching_strategy '$s' — defaulting to grow_columns"
    return :grow_columns
end

"""Resolve sizing strategy string to Symbol."""
function _resolve_sizing_strategy(s::String)
    key = lowercase(strip(s))
    key == "nlp" && return :nlp
    key == "discrete" && return :discrete
    key == "mip" && return :discrete  # legacy GH wire value; same as discrete (catalog MIP)
    @warn "Unknown sizing_strategy '$s' — defaulting to discrete"
    return :discrete
end

"""Resolve all three material names from API params. Returns `(concrete, rebar, steel)`."""
function _resolve_materials(api_params::APIParams)
    return (
        _resolve_concrete_name(api_params.materials.concrete),
        _resolve_rebar_name(api_params.materials.rebar),
        _resolve_steel_name(api_params.materials.steel),
    )
end

# ─── Framing auto-generation (Phase 5, plan `joists-roles-materials`) ─────────

# Named timber presets available to the framing-material resolver. INTENTIONALLY
# EMPTY: no verified NDS Supplement (Table 4A/4B/…) reference design values for a
# timber species/grade are grounded in the corpus (the NDS is not a corpus
# source — see `.cursor/rules/corpus.mdc`). Structural material properties are
# safety-critical and MUST NOT be fabricated, so a JSON caller cannot select a
# timber preset until a grounded one is registered here. The direct
# `framing_opts.materials.timber = <Timber>` Julia path (a caller-supplied
# `StructuralSizer.Timber`) is unaffected and remains the supported way to drive
# mass-timber framing today.
const TIMBER_MAP = Dict{String, StructuralSizer.Timber}()

"""
Resolve a framing-level member material family name to a StructuralSizer
`AbstractMaterial`, drawing on the top-level `materials` block. `"steel"` →
structural steel (`materials.steel`); `"concrete"` → reinforced concrete
(`materials.concrete` + `materials.rebar`); `"timber"` → the named preset in
`materials.timber` (resolved via [`TIMBER_MAP`](@ref)). Errors on any other
value.

Timber is a recognized family (mass-timber joists are supported by the member
sizer via the NDS glulam path), but no NDS-grounded timber preset ships in the
material library yet, so a `"timber"` request errors unless `materials.timber`
names a registered preset. Structural material values are safety-critical and
are never fabricated here (`.cursor/rules/code-accuracy.mdc`).
"""
function _resolve_framing_material(name::AbstractString, api_params::APIParams)
    key = lowercase(strip(name))
    if key == "steel"
        return _resolve_steel_name(api_params.materials.steel)
    elseif key == "concrete"
        conc = _resolve_concrete_name(api_params.materials.concrete)
        reb  = _resolve_rebar_name(api_params.materials.rebar)
        return StructuralSizer.ReinforcedConcreteMaterial(conc, reb)
    elseif key == "timber"
        preset = api_params.materials.timber
        preset === nothing && error(
            "framing_levels material \"timber\" requires a registered timber " *
            "preset named in materials.timber, but none was provided and no " *
            "NDS-grounded timber preset ships yet. Supply a Timber material via " *
            "the framing_opts Julia API, or register a verified preset in TIMBER_MAP.")
        return _resolve_from_map(preset, TIMBER_MAP, "timber preset")
    end
    error("Unknown framing_levels material \"$name\". Options: steel, concrete, timber.")
end

"""
Build the level-1 `opts.materials` NamedTuple for `populate_levels!`. `:beam` is
the universal fallback key resolved by every slab-type path in
`derive_framing_level`; the family key (`:steel`/`:concrete`) is added so a
slab type that prefers a specific family (e.g. OWSJ → `:steel`) picks it up.
"""
function _framing_materials_nt(name::AbstractString, mat)
    fam = Symbol(lowercase(strip(name)))
    return fam in (:steel, :concrete, :timber) ?
        NamedTuple{(fam, :beam)}((mat, mat)) : (; beam = mat)
end

"""
    _resolve_framing_opts(api_params::APIParams) -> NamedTuple

Translate `api_params.framing_levels` into the `opts` NamedTuple consumed by
`populate_levels!`. Returns an empty NamedTuple (a strict no-op) when no framing
levels are requested. Level 1 (framing directly on the slab — joists) sets
`:materials` plus optional `:spacing`/`:axis`/`:count`/`:end_fixity`/
`:catalog_override` (its role is fixed by the slab type; `:axis`/`:count` apply
only to the opts-schema slab types). Levels 2+ each contribute a `:level_N`
schema NamedTuple (`:material`, and optional
`:spacing`/`:role`/`:count`/`:axis`/`:end_fixity`/`:catalog_override`). Spacing is
given in inches on the wire and passed as a `u"inch"` quantity; `populate_levels!`
converts it to the structure's length unit. `end_fixity` is a 2-element release
vector parsed to an `NTuple{2, Symbol}`; `catalog_override` is a steel-catalog
name resolved to the concrete section collection.
"""
function _resolve_framing_opts(api_params::APIParams)
    levels = api_params.framing_levels
    isempty(levels) && return NamedTuple()

    # Level 1 (framing directly on the slab — joists). Geometry/role are fixed by
    # the slab type; the opts-schema slab types additionally honor axis/count.
    lvl1 = levels[1]
    mat1 = _resolve_framing_material(lvl1.material, api_params)
    opts = (; materials = _framing_materials_nt(lvl1.material, mat1))
    if lvl1.spacing_in !== nothing
        opts = merge(opts, (; spacing = lvl1.spacing_in * u"inch"))
    end
    if lvl1.axis !== nothing && length(lvl1.axis) >= 2
        opts = merge(opts, (; axis = (Float64(lvl1.axis[1]), Float64(lvl1.axis[2]))))
    end
    lvl1.count !== nothing && (opts = merge(opts, (; count = lvl1.count)))
    let ef = _resolve_framing_end_fixity(lvl1.end_fixity)
        ef !== nothing && (opts = merge(opts, (; end_fixity = ef)))
    end
    let co = _resolve_framing_catalog_override(lvl1.catalog_override)
        co !== nothing && (opts = merge(opts, (; catalog_override = co)))
    end

    for k in 2:length(levels)
        lvl = levels[k]
        schema = (; material = _resolve_framing_material(lvl.material, api_params))
        lvl.spacing_in !== nothing &&
            (schema = merge(schema, (; spacing = lvl.spacing_in * u"inch")))
        lvl.role !== nothing &&
            (schema = merge(schema, (; role = Symbol(lowercase(strip(lvl.role))))))
        lvl.count !== nothing &&
            (schema = merge(schema, (; count = lvl.count)))
        if lvl.axis !== nothing && length(lvl.axis) >= 2
            schema = merge(schema, (; axis = (Float64(lvl.axis[1]), Float64(lvl.axis[2]))))
        end
        let ef = _resolve_framing_end_fixity(lvl.end_fixity)
            ef !== nothing && (schema = merge(schema, (; end_fixity = ef)))
        end
        let co = _resolve_framing_catalog_override(lvl.catalog_override)
            co !== nothing && (schema = merge(schema, (; catalog_override = co)))
        end
        opts = merge(opts, NamedTuple{(Symbol("level_$k"),)}((schema,)))
    end
    return opts
end

# Accepted per-end release symbols for a framing level's `end_fixity`. `:default`
# defers to the (role, material, lateral_role) release dispatch; the others are
# the explicit member-end releases the runtime `resolve_release` accepts.
const _FRAMING_END_FIXITY_VALUES = (:default, :pinned, :fixed, :free)

"""
Parse an API `end_fixity` (a 2-element `[start, end]` release-name vector) into an
`NTuple{2, Symbol}` for `FramingLevel.end_fixity`. Returns `nothing` when unset.
Errors on a wrong length or an unrecognized release name.
"""
function _resolve_framing_end_fixity(ef::Union{Vector{String}, Nothing})
    ef === nothing && return nothing
    length(ef) == 2 || error(
        "framing_levels end_fixity must have exactly 2 entries [start, end]; got $(length(ef)).")
    syms = ntuple(i -> Symbol(lowercase(strip(ef[i]))), 2)
    for s in syms
        s in _FRAMING_END_FIXITY_VALUES || error(
            "Unknown framing_levels end_fixity release \"$s\". " *
            "Options: $(join(_FRAMING_END_FIXITY_VALUES, ", ")).")
    end
    return syms
end

# Named steel section catalogs selectable per framing level via
# `catalog_override`. Resolves to the concrete section collection consumed by
# `size_member_group!` (whose default is `StructuralSizer.all_W()`). ENGINEERING
# KNOB, not a published-code factor — restricts which sections the sizer may pick.
const _FRAMING_CATALOG_MAP = Dict{String, Function}(
    "all_w"        => StructuralSizer.all_W,
    "preferred_w"  => StructuralSizer.preferred_W,
    "all_hss"      => StructuralSizer.all_HSS,
    "all_hssround" => StructuralSizer.all_HSSRound,
)

"""
Resolve an API `catalog_override` steel-catalog name to the concrete section
catalog collection consumed by `size_member_group!`. Returns `nothing` when
unset. Errors on an unrecognized name.
"""
function _resolve_framing_catalog_override(name::Union{String, Nothing})
    name === nothing && return nothing
    key = lowercase(strip(name))
    haskey(_FRAMING_CATALOG_MAP, key) || error(
        "Unknown framing_levels catalog_override \"$name\". " *
        "Options: all_W, preferred_W, all_HSS, all_HSSRound.")
    return _FRAMING_CATALOG_MAP[key]()
end

"""Build fc_values [MPa] from PixelFrame options. 1 ksi ≈ 6.895 MPa."""
function _resolve_pixelframe_fc_values(api_params::APIParams)
    ksi_to_MPa = 6.894757  # 1 ksi = 6.894757 MPa
    opts = api_params.pixelframe_options
    preset = opts !== nothing ? lowercase(strip(opts.fc_preset)) : "standard"

    if preset == "custom" && opts !== nothing &&
       opts.fc_min_ksi !== nothing && opts.fc_max_ksi !== nothing && opts.fc_resolution_ksi !== nothing
        min_ksi = opts.fc_min_ksi
        max_ksi = opts.fc_max_ksi
        res_ksi = max(opts.fc_resolution_ksi, 0.5)
        vals_ksi = collect(min_ksi:res_ksi:max_ksi)
        return Float64.(vals_ksi .* ksi_to_MPa)
    end

    # Presets: fc values in MPa (catalog uses MPa)
    if preset == "low"
        return [21.0, 28.0, 35.0]  # ≈ 3–5 ksi
    elseif preset == "high"
        return [42.0, 50.0, 57.0, 69.0]  # ≈ 6–10 ksi
    elseif preset == "extended"
        return collect(Float64, 28:7:97)  # 4–14 ksi, step 1 ksi
    else
        # standard: 4–8 ksi
        return [28.0, 35.0, 42.0, 50.0, 57.0]
    end
end

"""Resolve column type string to ColumnOptions. Uses column_concrete (default 6 ksi)."""
function _resolve_column_options(api_params::APIParams)
    ct = lowercase(strip(api_params.column_type))
    _, rebar, steel = _resolve_materials(api_params)
    column_conc = _resolve_concrete_name(api_params.materials.column_concrete)

    # column_catalog is optional; resolve a safe default by column_type.
    # This prevents defaults from failing validation (e.g. rc_rect + "preferred").
    function _effective_column_catalog_str()
        if api_params.column_catalog !== nothing
            return lowercase(strip(api_params.column_catalog))
        end
        if ct == "rc_rect" || ct == "rc_circular"
            return "standard"
        elseif startswith(ct, "steel_")
            return "preferred"
        else
            return "standard"
        end
    end

    if ct == "pixelframe"
        fc_vals = _resolve_pixelframe_fc_values(api_params)
        return StructuralSizer.PixelFrameColumnOptions(
            fc_values = fc_vals .* u"MPa",
        )
    elseif startswith(ct, "rc_")
        shape = ct == "rc_circular" ? :circular : :rect
        catalog_sym = Symbol(_effective_column_catalog_str())
        strat = _resolve_sizing_strategy(api_params.column_sizing_strategy)
        return StructuralSizer.ConcreteColumnOptions(
            material = column_conc,
            rebar_material = rebar,
            section_shape = shape,
            catalog = catalog_sym,
            sizing_strategy = strat,
            time_limit_sec = something(api_params.mip_time_limit_sec, 30.0),
        )
    elseif startswith(ct, "steel_")
        section_type = if ct == "steel_w"
            :w
        elseif ct == "steel_hss"
            :hss
        elseif ct == "steel_pipe"
            :pipe
        else
            :w  # default
        end
        catalog_sym = Symbol(_effective_column_catalog_str())
        strat = _resolve_sizing_strategy(api_params.column_sizing_strategy)
        return StructuralSizer.SteelColumnOptions(
            material = steel,
            section_type = section_type,
            catalog = catalog_sym,
            sizing_strategy = strat,
            time_limit_sec = something(api_params.mip_time_limit_sec, 30.0),
        )
    else
        # Default to RC rectangular
        return StructuralSizer.ConcreteColumnOptions(
            material = column_conc,
            rebar_material = rebar,
            section_shape = :rect
        )
    end
end

# =============================================================================
# Foundation options (optional API overrides → StructuralSizer types)
# =============================================================================

"""Merge optional API spread params into StructuralSizer.SpreadParams. Lengths in API are inches."""
function _api_to_spread_params(api_sp::APISpreadParams, rc::StructuralSizer.ReinforcedConcreteMaterial)
    def = StructuralSizer.SpreadParams(material = rc)
    inch = u"inch"
    StructuralSizer.SpreadParams(
        material = rc,
        cover = api_sp.cover_in !== nothing ? api_sp.cover_in * inch : def.cover,
        min_depth = api_sp.min_depth_in !== nothing ? api_sp.min_depth_in * inch : def.min_depth,
        bar_size = something(api_sp.bar_size, def.bar_size),
        depth_increment = api_sp.depth_increment_in !== nothing ? api_sp.depth_increment_in * inch : def.depth_increment,
        size_increment = api_sp.size_increment_in !== nothing ? api_sp.size_increment_in * inch : def.size_increment,
        pier_shape = def.pier_shape,
        pier_c1 = def.pier_c1,
        pier_c2 = def.pier_c2,
        footing_shape = def.footing_shape,
        ϕ_flexure = def.ϕ_flexure,
        ϕ_shear = def.ϕ_shear,
        ϕ_bearing = def.ϕ_bearing,
        λ = def.λ,
        fc_col = def.fc_col,
        check_bearing = def.check_bearing,
        check_dowels = def.check_dowels,
        check_development = def.check_development,
        objective = def.objective,
    )
end

"""Merge optional API strip params into StructuralSizer.StripParams. Lengths in API are inches."""
function _api_to_strip_params(api_st::APIStripParams, rc::StructuralSizer.ReinforcedConcreteMaterial)
    def = StructuralSizer.StripParams(material = rc)
    inch = u"inch"
    StructuralSizer.StripParams(
        material = rc,
        cover = api_st.cover_in !== nothing ? api_st.cover_in * inch : def.cover,
        min_depth = api_st.min_depth_in !== nothing ? api_st.min_depth_in * inch : def.min_depth,
        bar_size_long = something(api_st.bar_size_long, def.bar_size_long),
        bar_size_trans = something(api_st.bar_size_trans, def.bar_size_trans),
        depth_increment = def.depth_increment,
        width_increment = api_st.width_increment_in !== nothing ? api_st.width_increment_in * inch : def.width_increment,
        max_depth_ratio = something(api_st.max_depth_ratio, def.max_depth_ratio),
        analysis = def.analysis,
        ϕ_flexure = def.ϕ_flexure,
        ϕ_shear = def.ϕ_shear,
        ϕ_bearing = def.ϕ_bearing,
        λ = def.λ,
        fc_col = def.fc_col,
        check_development = def.check_development,
        check_bearing = def.check_bearing,
        check_dowels = def.check_dowels,
        merge_gap_factor = something(api_st.merge_gap_factor, def.merge_gap_factor),
        eccentricity_limit = something(api_st.eccentricity_limit, def.eccentricity_limit),
        objective = def.objective,
    )
end

"""Resolve mat analysis_method string to AbstractMatMethod."""
function _resolve_mat_analysis_method(s::String)
    am = lowercase(strip(s))
    am == "rigid"   && return StructuralSizer.RigidMat()
    am == "shukla"  && return StructuralSizer.ShuklaAFM()
    am == "winkler" && return StructuralSizer.WinklerFEA()
    @warn "Unknown mat analysis_method \"$s\" — defaulting to rigid"
    return StructuralSizer.RigidMat()
end

"""Merge optional API mat params into StructuralSizer.MatParams. Lengths in API are inches."""
function _api_to_mat_params(api_mat::APIMatParams, rc::StructuralSizer.ReinforcedConcreteMaterial)
    def = StructuralSizer.MatParams(material = rc)
    inch = u"inch"
    method = api_mat.analysis_method !== nothing ?
        _resolve_mat_analysis_method(api_mat.analysis_method) : def.analysis_method
    edge_oh = api_mat.edge_overhang_in !== nothing ? api_mat.edge_overhang_in * inch : def.edge_overhang
    StructuralSizer.MatParams(
        material = rc,
        cover = api_mat.cover_in !== nothing ? api_mat.cover_in * inch : def.cover,
        min_depth = api_mat.min_depth_in !== nothing ? api_mat.min_depth_in * inch : def.min_depth,
        bar_size_x = something(api_mat.bar_size_x, def.bar_size_x),
        bar_size_y = something(api_mat.bar_size_y, def.bar_size_y),
        depth_increment = api_mat.depth_increment_in !== nothing ? api_mat.depth_increment_in * inch : def.depth_increment,
        edge_overhang = edge_oh,
        analysis_method = method,
        ϕ_flexure = def.ϕ_flexure,
        ϕ_shear = def.ϕ_shear,
        λ = def.λ,
        objective = def.objective,
    )
end

"""Build FoundationOptions from API params. Uses foundation_concrete + materials.rebar for RC material."""
function _resolve_foundation_options(api_params::APIParams, fdn_conc::StructuralSizer.Concrete, reb::StructuralSizer.RebarSteel)
    rc = StructuralSizer.ReinforcedConcreteMaterial(fdn_conc, reb)
    def_opts = StructuralSizer.FoundationOptions()
    strategy = def_opts.strategy
    mat_coverage_threshold = def_opts.mat_coverage_threshold
    spread_params = def_opts.spread_params
    strip_params = def_opts.strip_params
    mat_params = def_opts.mat_params

    if api_params.foundation_options !== nothing
        fo = api_params.foundation_options
        raw = strip(fo.strategy)
        strategy = isempty(raw) ? def_opts.strategy : Symbol(lowercase(raw))
        # Explicit mat override — must not fall through to coverage-based logic
        strategy === :mat && @info "Foundation strategy: mat (explicit override)"
        mat_coverage_threshold = fo.mat_coverage_threshold
        if fo.spread_params !== nothing
            spread_params = _api_to_spread_params(fo.spread_params, rc)
        end
        if fo.strip_params !== nothing
            strip_params = _api_to_strip_params(fo.strip_params, rc)
        end
        if fo.mat_params !== nothing
            mat_params = _api_to_mat_params(fo.mat_params, rc)
        end
    else
        # Apply top-level foundation_concrete + rebar to default option blocks
        spread_params = StructuralSizer.SpreadParams(material = rc)
        strip_params = StructuralSizer.StripParams(material = rc)
        mat_params = StructuralSizer.MatParams(material = rc)
    end

    return StructuralSizer.FoundationOptions(
        spread_params = spread_params,
        strip_params = strip_params,
        mat_params = mat_params,
        strategy = strategy,
        mat_coverage_threshold = mat_coverage_threshold,
    )
end

"""Resolve beam type string to BeamOptions."""
function _resolve_beam_options(api_params::APIParams)
    bt = lowercase(strip(api_params.beam_type))
    concrete, rebar, steel = _resolve_materials(api_params)

    catalog = Symbol(api_params.beam_catalog)

    # Build custom catalog from bounds when beam_catalog is "custom".
    custom_cat = nothing
    if catalog === :custom && api_params.beam_catalog_bounds !== nothing
        b = api_params.beam_catalog_bounds
        custom_cat = StructuralSizer.rc_beam_catalog_from_bounds(;
            min_width_in = b.min_width_in,
            max_width_in = b.max_width_in,
            min_depth_in = b.min_depth_in,
            max_depth_in = b.max_depth_in,
            resolution_in = b.resolution_in,
        )
    end

    tlim = something(api_params.mip_time_limit_sec, 30.0)
    if startswith(bt, "steel_")
        section_type = if bt == "steel_w"
            :w
        elseif bt == "steel_hss"
            :hss
        else
            :w  # default
        end
        strat = _resolve_sizing_strategy(api_params.beam_sizing_strategy)
        return StructuralSizer.SteelBeamOptions(
            material = steel,
            section_type = section_type,
            sizing_strategy = strat,
            time_limit_sec = tlim,
        )
    elseif bt == "rc_rect"
        strat = _resolve_sizing_strategy(api_params.beam_sizing_strategy)
        return StructuralSizer.ConcreteBeamOptions(
            material = concrete,
            rebar_material = rebar,
            include_flange = false,
            catalog = catalog === :custom ? :standard : catalog,
            custom_catalog = custom_cat,
            sizing_strategy = strat,
            time_limit_sec = tlim,
        )
    elseif bt == "rc_tbeam"
        strat = _resolve_sizing_strategy(api_params.beam_sizing_strategy)
        return StructuralSizer.ConcreteBeamOptions(
            material = concrete,
            rebar_material = rebar,
            include_flange = true,
            catalog = catalog === :custom ? :standard : catalog,
            custom_catalog = custom_cat,
            sizing_strategy = strat,
            time_limit_sec = tlim,
        )
    elseif bt == "pixelframe"
        fc_vals = _resolve_pixelframe_fc_values(api_params)
        return StructuralSizer.PixelFrameBeamOptions(
            fc_values = fc_vals .* u"MPa",
        )
    else
        # Default to steel W-shape
        return StructuralSizer.SteelBeamOptions(
            material = steel,
            section_type = :w
        )
    end
end
