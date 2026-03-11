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
        "Accepted: feet/ft, inches/in, meters/m, millimeters/mm, centimeters/cm"))
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
"""
function json_to_skeleton(input::APIInput)
    coord_unit = parse_unit(input.units)

    # Convert to meters (BuildingStructure expects m-based skeleton so that
    # face_area returns m² matching the hardcoded A type parameter)
    _to_m(val) = uconvert(u"m", val * coord_unit)

    T = typeof(1.0u"m")
    skel = BuildingSkeleton{T}()
    enable_lookup!(skel)

    # ─── Stories Z (optional — rebuild_stories! infers from vertices) ─────
    if !isempty(input.stories_z)
        skel.stories_z = [_to_m(z) for z in input.stories_z]
    end

    # ─── Vertices ─────────────────────────────────────────────────────────
    for coords in input.vertices
        pt = Meshes.Point(
            _to_m(coords[1]),
            _to_m(coords[2]),
            _to_m(coords[3]),
        )
        add_vertex!(skel, pt)
    end

    # ─── Edges: beams (with auto-shatter) ─────────────────────────────────
    _shatter_edges!(skel, input.edges.beams, :beams)

    # ─── Edges: columns (with auto-shatter) ──────────────────────────────
    _shatter_edges!(skel, input.edges.columns, :columns)

    # ─── Edges: braces / struts (with auto-shatter) ──────────────────────
    _shatter_edges!(skel, input.edges.braces, :braces)

    # ─── Supports ─────────────────────────────────────────────────────────
    for vi in input.supports
        add_vertex!(skel, skel.vertices[vi]; group=:support)
    end

    # ─── Rebuild stories from vertex Z coordinates ────────────────────────
    if isempty(skel.vertices)
        error("Cannot rebuild stories: no vertices found in skeleton")
    end
    rebuild_stories!(skel)
    
    # Ensure stories_z was populated
    if isempty(skel.stories_z)
        error("rebuild_stories! failed to populate stories_z from $(length(skel.vertices)) vertices")
    end

    # ─── Faces ────────────────────────────────────────────────────────────
    has_explicit_faces = !isempty(input.faces) &&
        any(!isempty(polys) for polys in values(input.faces))

    if has_explicit_faces
        _add_explicit_faces!(skel, input.faces, coord_unit, _to_m)
    else
        find_faces!(skel)
        _auto_categorize_faces!(skel)
    end

    n_chains = length(skel.edge_chains)
    n_shattered = sum(length(v) for v in values(skel.edge_chains); init=0)
    @debug "Built skeleton" vertices=length(skel.vertices) edges=length(skel.edges) chains=n_chains shattered_edges=n_shattered

    return skel
end

"""Add explicit face polylines from the JSON `faces` dict (coordinates converted to meters)."""
function _add_explicit_faces!(skel::BuildingSkeleton{T}, face_groups::APIFaceGroups,
                               coord_unit, _to_m) where T
    for (category, polylines) in face_groups
        group = Symbol(category)
        for poly_coords in polylines
            pts = [Meshes.Point(_to_m(c[1]), _to_m(c[2]), _to_m(c[3]))
                   for c in poly_coords]
            polygon = Meshes.Ngon(pts...)

            # Determine level_idx from the Z coordinate of the first vertex
            z_val = Meshes.coords(pts[1]).z
            level_idx = _find_level_idx(skel, z_val)

            add_face!(skel, polygon; group=group, level_idx=level_idx)
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

"""Find the story level index for a given Z elevation."""
function _find_level_idx(skel::BuildingSkeleton{T}, z_val) where T
    z_stripped = ustrip(z_val)
    for (i, sz) in enumerate(skel.stories_z)
        if abs(ustrip(sz) - z_stripped) < 1e-4
            return i - 1  # 0-indexed
        end
    end
    return -1
end

# ─── Design Parameters ────────────────────────────────────────────────────────

"""
    json_to_params(api_params::APIParams) -> DesignParameters

Convert API parameter block to a `DesignParameters` instance.
"""
function json_to_params(api_params::APIParams)
    loads = GravityLoads(
        floor_LL  = api_params.loads.floor_LL_psf * psf,
        roof_LL   = api_params.loads.roof_LL_psf * psf,
        grade_LL  = api_params.loads.grade_LL_psf * psf,
        floor_SDL = api_params.loads.floor_SDL_psf * psf,
        roof_SDL  = api_params.loads.roof_SDL_psf * psf,
        wall_SDL  = api_params.loads.wall_SDL_psf * psf,
    )

    materials = MaterialOptions(
        concrete = _resolve_concrete_name(api_params.materials.concrete),
        rebar    = _resolve_rebar_name(api_params.materials.rebar),
        steel    = _resolve_steel_name(api_params.materials.steel),
    )

    floor = _resolve_floor_options(api_params)

    columns = _resolve_column_options(api_params)
    beams = _resolve_beam_options(api_params)

    foundation_options = if api_params.size_foundations
        soil = _resolve_soil_name(api_params.foundation_soil)
        FoundationParameters(soil=soil)
    else
        nothing
    end

    display_units_sys = lowercase(api_params.unit_system) == "metric" ? :metric : :imperial

    return DesignParameters(
        loads = loads,
        materials = materials,
        floor = floor,
        columns = columns,
        beams = beams,
        fire_rating = validate_fire_rating(api_params.fire_rating),
        optimize_for = Symbol(api_params.optimize_for),
        foundation_options = foundation_options,
        display_units = DisplayUnits(display_units_sys),
    )
end

# ─── Name → object resolution helpers ────────────────────────────────────────

const CONCRETE_MAP = Dict{String, StructuralSizer.Concrete}(
    "NWC_3000" => StructuralSizer.NWC_3000,
    "NWC_4000" => StructuralSizer.NWC_4000,
    "NWC_5000" => StructuralSizer.NWC_5000,
    "NWC_6000" => StructuralSizer.NWC_6000,
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
    "medium_sand" => StructuralSizer.medium_sand,
)

"""Look up a concrete grade by name string, or error with available options."""
function _resolve_concrete_name(name::String)
    haskey(CONCRETE_MAP, name) && return CONCRETE_MAP[name]
    error("Unknown concrete grade: \"$name\". Options: $(join(keys(CONCRETE_MAP), ", "))")
end

"""Look up a rebar grade by name string, or error with available options."""
function _resolve_rebar_name(name::String)
    haskey(REBAR_MAP, name) && return REBAR_MAP[name]
    error("Unknown rebar grade: \"$name\". Options: $(join(keys(REBAR_MAP), ", "))")
end

"""Look up a structural steel type by name string, or error with available options."""
function _resolve_steel_name(name::String)
    haskey(STEEL_MAP, name) && return STEEL_MAP[name]
    error("Unknown steel type: \"$name\". Options: $(join(keys(STEEL_MAP), ", "))")
end

"""Look up a soil type by name string, or error with available options."""
function _resolve_soil_name(name::String)
    haskey(SOIL_MAP, name) && return SOIL_MAP[name]
    error("Unknown soil type: \"$name\". Options: $(join(keys(SOIL_MAP), ", "))")
end

"""Resolve floor options from API params."""
function _resolve_floor_options(api_params::APIParams)
    ft = Symbol(api_params.floor_type)
    method = _resolve_analysis_method(api_params.floor_options.method)
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
        return StructuralSizer.VaultOptions()
    else
        return StructuralSizer.FlatPlateOptions(
            method=method, deflection_limit=defl, punching_strategy=punch)
    end
end

"""Resolve analysis method string to Julia type."""
function _resolve_analysis_method(method_str::String)
    s = uppercase(strip(method_str))
    s == "DDM"               && return StructuralSizer.DDM()
    s == "DDM_SIMPLIFIED"    && return StructuralSizer.DDM(:simplified)
    s == "EFM"               && return StructuralSizer.EFM()
    s == "EFM_HARDY_CROSS"   && return StructuralSizer.EFM(solver=:hardy_cross)
    s == "FEA"               && return StructuralSizer.FEA()
    return StructuralSizer.DDM()  # default
end

"""Resolve deflection limit string to Symbol."""
function _resolve_deflection_limit(s::String)
    s = uppercase(strip(s))
    s == "L_240" && return :L_240
    s == "L_360" && return :L_360
    s == "L_480" && return :L_480
    return :L_360  # default
end

"""Resolve punching strategy string to Symbol."""
function _resolve_punching_strategy(s::String)
    s = lowercase(strip(s))
    s == "grow_columns"    && return :grow_columns
    s == "reinforce_last"  && return :reinforce_last
    s == "reinforce_first" && return :reinforce_first
    return :grow_columns  # default
end

"""Resolve column type string to ColumnOptions."""
function _resolve_column_options(api_params::APIParams)
    ct = lowercase(strip(api_params.column_type))
    concrete = _resolve_concrete_name(api_params.materials.concrete)
    rebar = _resolve_rebar_name(api_params.materials.rebar)
    steel = _resolve_steel_name(api_params.materials.steel)

    if startswith(ct, "rc_")
        shape = ct == "rc_circular" ? :circular : :rect
        return StructuralSizer.ConcreteColumnOptions(
            grade = concrete,
            rebar_grade = rebar,
            section_shape = shape
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
        return StructuralSizer.SteelColumnOptions(
            material = steel,
            section_type = section_type
        )
    else
        # Default to RC rectangular
        return StructuralSizer.ConcreteColumnOptions(
            grade = concrete,
            rebar_grade = rebar,
            section_shape = :rect
        )
    end
end

"""Resolve beam type string to BeamOptions."""
function _resolve_beam_options(api_params::APIParams)
    bt = lowercase(strip(api_params.beam_type))
    concrete = _resolve_concrete_name(api_params.materials.concrete)
    rebar = _resolve_rebar_name(api_params.materials.rebar)
    steel = _resolve_steel_name(api_params.materials.steel)

    if startswith(bt, "steel_")
        section_type = if bt == "steel_w"
            :w
        elseif bt == "steel_hss"
            :hss
        else
            :w  # default
        end
        return StructuralSizer.SteelBeamOptions(
            material = steel,
            section_type = section_type
        )
    elseif bt == "rc_rect"
        return StructuralSizer.ConcreteBeamOptions(
            grade = concrete,
            rebar_grade = rebar,
            include_flange = false
        )
    elseif bt == "rc_tbeam"
        return StructuralSizer.ConcreteBeamOptions(
            grade = concrete,
            rebar_grade = rebar,
            include_flange = true
        )
    else
        # Default to steel W-shape
        return StructuralSizer.SteelBeamOptions(
            material = steel,
            section_type = :w
        )
    end
end
