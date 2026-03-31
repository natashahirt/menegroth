# =============================================================================
# API Validation — Input checking before design
# =============================================================================

"""
    ValidationError

Structured validation error with field path, invalid value, constraint type,
allowed values (for enum constraints), and a human-readable message.
"""
struct ValidationError
    field::String
    value::Any
    constraint::String
    allowed::Union{Vector{String}, Nothing}
    message::String
end

"""
    ValidationResult

Holds validation outcome: `ok` is true if all checks pass, `errors` collects
structured errors for every failing check.
"""
struct ValidationResult
    ok::Bool
    errors::Vector{ValidationError}
end

"""Create a passing `ValidationResult` with no errors."""
ValidationResult() = ValidationResult(true, ValidationError[])

"""Push an enum constraint error."""
function _push_enum!(errors, field, value, allowed_tuple)
    allowed = collect(String, string.(allowed_tuple))
    push!(errors, ValidationError(
        field, string(value), "enum", allowed,
        "Invalid $field \"$value\". Must be one of: $(join(allowed, ", "))."
    ))
end

"""Push a range/bound constraint error."""
function _push_range!(errors, field, value, constraint_desc)
    push!(errors, ValidationError(
        field, string(value), "range", nothing,
        "Invalid $field $value. $constraint_desc"
    ))
end

"""Push a required-field error."""
function _push_required!(errors, field, message)
    push!(errors, ValidationError(field, "", "required", nothing, message))
end

"""Push a general constraint error."""
function _push_general!(errors, field, value, message)
    push!(errors, ValidationError(field, string(value), "general", nothing, message))
end

"""Push a compatibility constraint error."""
function _push_compat!(errors, field, value, message)
    push!(errors, ValidationError(field, string(value), "compatibility", nothing, message))
end

"""Push a lookup (material/soil) constraint error."""
function _push_lookup!(errors, field, value, options_keys)
    allowed = collect(String, string.(options_keys))
    push!(errors, ValidationError(
        field, string(value), "enum", allowed,
        "Unknown $field \"$value\". Options: $(join(allowed, ", "))."
    ))
end

"""
    validate_input(input::APIInput) -> ValidationResult

Run all input validation checks. Returns immediately usable result; the caller
decides whether to abort (HTTP 400) or proceed.
"""
function validate_input(input::APIInput)
    errors = ValidationError[]

    # ─── Units required ───────────────────────────────────────────────────
    if isempty(strip(input.units))
        _push_required!(errors, "units",
            "Missing required field \"units\". Accepted: feet/ft, inches/in, meters/m, millimeters/mm, centimeters/cm.")
    else
        try
            parse_unit(input.units)
        catch e
            _push_general!(errors, "units", input.units, string(e))
        end
    end

    # ─── Vertices ─────────────────────────────────────────────────────────
    n_verts = length(input.vertices)
    if n_verts < 4
        _push_range!(errors, "vertices", n_verts, "Need at least 4 vertices (got $n_verts).")
    end
    for (i, v) in enumerate(input.vertices)
        if length(v) != 3
            _push_general!(errors, "vertices[$i]", length(v),
                "Vertex $i has $(length(v)) coordinates (expected 3).")
        end
    end

    # ─── Edges ────────────────────────────────────────────────────────────
    all_edges = vcat(input.edges.beams, input.edges.columns, input.edges.braces)
    if isempty(all_edges)
        _push_required!(errors, "edges",
            "No edges provided (need at least beams, columns, or braces).")
    end
    for (i, edge) in enumerate(all_edges)
        if length(edge) != 2
            _push_general!(errors, "edges[$i]", length(edge),
                "Edge $i has $(length(edge)) vertex indices (expected 2).")
            continue
        end
        v1, v2 = edge
        if v1 < 1 || v1 > n_verts
            _push_range!(errors, "edges[$i].v1", v1,
                "Vertex index $v1 out of range [1, $n_verts].")
        end
        if v2 < 1 || v2 > n_verts
            _push_range!(errors, "edges[$i].v2", v2,
                "Vertex index $v2 out of range [1, $n_verts].")
        end
        if v1 == v2
            _push_general!(errors, "edges[$i]", "$v1,$v2",
                "Edge $i: degenerate edge (both indices = $v1).")
        end
    end

    # ─── Supports ─────────────────────────────────────────────────────────
    if isempty(input.supports)
        _push_required!(errors, "supports", "No support vertices specified.")
    end
    for (i, si) in enumerate(input.supports)
        if si < 1 || si > n_verts
            _push_range!(errors, "supports[$i]", si,
                "Support $i: vertex index $si out of range [1, $n_verts].")
        end
    end

    # ─── Stories Z (optional — inferred from vertex Z if omitted) ────────
    if !isempty(input.stories_z)
        if length(input.stories_z) < 2
            _push_range!(errors, "stories_z", length(input.stories_z),
                "If provided, need at least 2 story elevations (got $(length(input.stories_z))).")
        end
    end

    # ─── Faces (if provided) ─────────────────────────────────────────────
    for (category, polylines) in input.faces
        for (j, poly) in enumerate(polylines)
            if length(poly) < 3
                _push_range!(errors, "faces.$category[$j]", length(poly),
                    "Face \"$category\"[$j] has $(length(poly)) vertices (need >= 3).")
            end
            for (k, coord) in enumerate(poly)
                if length(coord) != 3
                    _push_general!(errors, "faces.$category[$j].vertex[$k]", length(coord),
                        "Face \"$category\"[$j] vertex $k has $(length(coord)) coords (expected 3).")
                end
            end
        end
    end

    # ─── Params ──────────────────────────────────────────────────────────
    p = input.params

    if !(p.floor_type in API_FLOOR_TYPES)
        _push_enum!(errors, "floor_type", p.floor_type, API_FLOOR_TYPES)
    end

    # ─── Floor + column/beam type compatibility ─────────────────────────────
    beamless_floor = p.floor_type in ("flat_plate", "flat_slab")
    steel_column = p.column_type in ("steel_w", "steel_hss", "steel_pipe")
    pixelframe_column = p.column_type == "pixelframe"
    steel_beam = p.beam_type in ("steel_w", "steel_hss")
    if beamless_floor && (steel_column || pixelframe_column)
        _push_compat!(errors, "column_type", p.column_type,
            "floor_type \"$(p.floor_type)\" requires reinforced concrete columns. " *
            "column_type \"$(p.column_type)\" is not supported for beamless slab systems.")
    end
    if p.floor_type == "vault"
        if steel_column
            _push_compat!(errors, "column_type", p.column_type,
                "floor_type \"vault\" requires reinforced concrete columns. " *
                "column_type \"$(p.column_type)\" is not supported.")
        end
        if steel_beam
            _push_compat!(errors, "beam_type", p.beam_type,
                "floor_type \"vault\" requires reinforced concrete beams. " *
                "beam_type \"$(p.beam_type)\" is not supported.")
        end
    end

    # ─── Floor options (method, deflection_limit, punching_strategy) ─────
    method_key = uppercase(strip(p.floor_options.method))
    if !(method_key in API_FLOOR_ANALYSIS_METHODS)
        _push_enum!(errors, "floor_options.method", p.floor_options.method, API_FLOOR_ANALYSIS_METHODS)
    end
    defl_key = uppercase(strip(p.floor_options.deflection_limit))
    if !(defl_key in API_DEFLECTION_LIMITS)
        _push_enum!(errors, "floor_options.deflection_limit", p.floor_options.deflection_limit, API_DEFLECTION_LIMITS)
    end
    punch_key = lowercase(strip(p.floor_options.punching_strategy))
    if !(punch_key in API_PUNCHING_STRATEGIES)
        _push_enum!(errors, "floor_options.punching_strategy", p.floor_options.punching_strategy, API_PUNCHING_STRATEGIES)
    end
    if !isnothing(p.floor_options.vault_lambda) && p.floor_options.vault_lambda <= 0
        _push_range!(errors, "floor_options.vault_lambda", p.floor_options.vault_lambda, "Must be > 0.")
    end
    if !isnothing(p.floor_options.target_edge_m) && p.floor_options.target_edge_m <= 0
        _push_range!(errors, "floor_options.target_edge_m", p.floor_options.target_edge_m, "Must be > 0.")
    end
    if !isnothing(p.visualization_target_edge_m) && p.visualization_target_edge_m <= 0
        _push_range!(errors, "visualization_target_edge_m", p.visualization_target_edge_m, "Must be > 0.")
    end
    if !isnothing(p.max_iterations) && p.max_iterations < 1
        _push_range!(errors, "max_iterations", p.max_iterations, "Must be >= 1.")
    end

    for (i, ov) in enumerate(p.scoped_overrides)
        if !(ov.floor_type in API_FLOOR_TYPES)
            _push_enum!(errors, "scoped_overrides[$i].floor_type", ov.floor_type, API_FLOOR_TYPES)
        end
        method_key = uppercase(strip(ov.floor_options.method))
        if !(method_key in API_FLOOR_ANALYSIS_METHODS)
            _push_enum!(errors, "scoped_overrides[$i].floor_options.method", ov.floor_options.method, API_FLOOR_ANALYSIS_METHODS)
        end
        defl_key = uppercase(strip(ov.floor_options.deflection_limit))
        if !(defl_key in API_DEFLECTION_LIMITS)
            _push_enum!(errors, "scoped_overrides[$i].floor_options.deflection_limit", ov.floor_options.deflection_limit, API_DEFLECTION_LIMITS)
        end
        punch_key = lowercase(strip(ov.floor_options.punching_strategy))
        if !(punch_key in API_PUNCHING_STRATEGIES)
            _push_enum!(errors, "scoped_overrides[$i].floor_options.punching_strategy", ov.floor_options.punching_strategy, API_PUNCHING_STRATEGIES)
        end
        if !isnothing(ov.floor_options.vault_lambda) && ov.floor_options.vault_lambda <= 0
            _push_range!(errors, "scoped_overrides[$i].floor_options.vault_lambda", ov.floor_options.vault_lambda, "Must be > 0.")
        end
        if !isnothing(ov.floor_options.target_edge_m) && ov.floor_options.target_edge_m <= 0
            _push_range!(errors, "scoped_overrides[$i].floor_options.target_edge_m", ov.floor_options.target_edge_m, "Must be > 0.")
        end
        if !isnothing(ov.floor_options.concrete) && !haskey(CONCRETE_MAP, ov.floor_options.concrete)
            _push_lookup!(errors, "scoped_overrides[$i].floor_options.concrete", ov.floor_options.concrete, keys(CONCRETE_MAP))
        end
        if isempty(ov.faces)
            _push_required!(errors, "scoped_overrides[$i].faces",
                "scoped_overrides[$i] must include at least one face polygon.")
        end
        for (j, poly) in enumerate(ov.faces)
            if length(poly) < 3
                _push_range!(errors, "scoped_overrides[$i].faces[$j]", length(poly),
                    "scoped_overrides[$i].faces[$j] has $(length(poly)) vertices (need >= 3).")
            end
            for (k, coord) in enumerate(poly)
                if length(coord) != 3
                    _push_general!(errors, "scoped_overrides[$i].faces[$j].vertex[$k]", length(coord),
                        "scoped_overrides[$i].faces[$j] vertex $k has $(length(coord)) coords (expected 3).")
                end
            end
        end
    end

    if !(p.column_type in API_COLUMN_TYPES)
        _push_enum!(errors, "column_type", p.column_type, API_COLUMN_TYPES)
    end
    if p.column_type in ("steel_w", "steel_hss", "steel_pipe") && p.column_catalog !== nothing &&
       !(p.column_catalog in API_STEEL_COLUMN_CATALOGS)
        _push_enum!(errors, "column_catalog", p.column_catalog, API_STEEL_COLUMN_CATALOGS)
    end
    if p.column_type == "rc_rect" && p.column_catalog !== nothing && !(p.column_catalog in API_RC_RECT_COLUMN_CATALOGS)
        _push_enum!(errors, "column_catalog", p.column_catalog, API_RC_RECT_COLUMN_CATALOGS)
    end
    if p.column_type == "rc_circular" && p.column_catalog !== nothing && !(p.column_catalog in API_RC_CIRCULAR_COLUMN_CATALOGS)
        _push_enum!(errors, "column_catalog", p.column_catalog, API_RC_CIRCULAR_COLUMN_CATALOGS)
    end

    # ─── Uniform column sizing ─────────────────────────────────────────────
    ucs = lowercase(strip(p.uniform_column_sizing))
    if !(ucs in API_UNIFORM_COLUMN_SIZING)
        _push_enum!(errors, "uniform_column_sizing", p.uniform_column_sizing, API_UNIFORM_COLUMN_SIZING)
    end
    if ucs != "off" && p.column_type == "pixelframe"
        _push_compat!(errors, "uniform_column_sizing", p.uniform_column_sizing,
            "uniform_column_sizing \"$(p.uniform_column_sizing)\" is not supported with pixelframe columns.")
    end

    if !(p.beam_type in API_BEAM_TYPES)
        _push_enum!(errors, "beam_type", p.beam_type, API_BEAM_TYPES)
    end

    if !(p.beam_catalog in API_BEAM_CATALOGS)
        _push_enum!(errors, "beam_catalog", p.beam_catalog, API_BEAM_CATALOGS)
    end
    if p.column_type == "pixelframe" || p.beam_type == "pixelframe"
        pf = p.pixelframe_options
        if pf !== nothing
            preset = lowercase(strip(pf.fc_preset))
            if !(preset in API_PIXELFRAME_FC_PRESETS)
                _push_enum!(errors, "pixelframe_options.fc_preset", pf.fc_preset, API_PIXELFRAME_FC_PRESETS)
            elseif preset == "custom"
                if pf.fc_min_ksi === nothing || pf.fc_max_ksi === nothing || pf.fc_resolution_ksi === nothing
                    _push_required!(errors, "pixelframe_options",
                        "pixelframe_options: fc_min_ksi, fc_max_ksi, and fc_resolution_ksi are required when fc_preset is \"custom\".")
                elseif pf.fc_min_ksi >= pf.fc_max_ksi
                    _push_range!(errors, "pixelframe_options.fc_min_ksi", pf.fc_min_ksi,
                        "Must be < fc_max_ksi.")
                elseif pf.fc_resolution_ksi <= 0
                    _push_range!(errors, "pixelframe_options.fc_resolution_ksi", pf.fc_resolution_ksi,
                        "Must be > 0.")
                end
            end
        end
    end

    if p.beam_catalog == "custom"
        if p.beam_catalog_bounds === nothing
            _push_required!(errors, "beam_catalog_bounds",
                "beam_catalog_bounds is required when beam_catalog is \"custom\".")
        else
            b = p.beam_catalog_bounds
            if b.min_width_in >= b.max_width_in
                _push_range!(errors, "beam_catalog_bounds.min_width_in", b.min_width_in,
                    "Must be < max_width_in.")
            end
            if b.min_depth_in >= b.max_depth_in
                _push_range!(errors, "beam_catalog_bounds.min_depth_in", b.min_depth_in,
                    "Must be < max_depth_in.")
            end
            if b.resolution_in <= 0
                _push_range!(errors, "beam_catalog_bounds.resolution_in", b.resolution_in,
                    "Must be > 0.")
            end
        end
    end

    if !(lowercase(strip(p.column_sizing_strategy)) in API_SIZING_STRATEGIES)
        _push_enum!(errors, "column_sizing_strategy", p.column_sizing_strategy, API_SIZING_STRATEGIES)
    end
    if !(lowercase(strip(p.beam_sizing_strategy)) in API_SIZING_STRATEGIES)
        _push_enum!(errors, "beam_sizing_strategy", p.beam_sizing_strategy, API_SIZING_STRATEGIES)
    end

    if p.fire_rating ∉ (0.0, 1.0, 1.5, 2.0, 3.0, 4.0)
        _push_enum!(errors, "fire_rating", p.fire_rating, (0.0, 1.0, 1.5, 2.0, 3.0, 4.0))
    end
    if !(p.optimize_for in API_OPTIMIZE_FOR)
        _push_enum!(errors, "optimize_for", p.optimize_for, API_OPTIMIZE_FOR)
    end
    if !haskey(CONCRETE_MAP, p.materials.concrete)
        _push_lookup!(errors, "materials.concrete", p.materials.concrete, keys(CONCRETE_MAP))
    end
    if !haskey(CONCRETE_MAP, p.materials.column_concrete)
        _push_lookup!(errors, "materials.column_concrete", p.materials.column_concrete, keys(CONCRETE_MAP))
    end
    if !haskey(REBAR_MAP, p.materials.rebar)
        _push_lookup!(errors, "materials.rebar", p.materials.rebar, keys(REBAR_MAP))
    end
    if !haskey(STEEL_MAP, p.materials.steel)
        _push_lookup!(errors, "materials.steel", p.materials.steel, keys(STEEL_MAP))
    end

    # ─── Foundation (when size_foundations is true) ────────────────────
    if p.size_foundations
        if !haskey(SOIL_MAP, p.foundation_soil)
            _push_lookup!(errors, "foundation_soil", p.foundation_soil, keys(SOIL_MAP))
        end
        if !haskey(CONCRETE_MAP, p.foundation_concrete)
            _push_lookup!(errors, "foundation_concrete", p.foundation_concrete, keys(CONCRETE_MAP))
        end
        if p.foundation_options !== nothing
            fo = p.foundation_options
            strategy_ok = lowercase(strip(fo.strategy)) in API_FOUNDATION_STRATEGIES
            if !strategy_ok
                _push_enum!(errors, "foundation_options.strategy", fo.strategy, API_FOUNDATION_STRATEGIES)
            end
            if !(0.0 <= fo.mat_coverage_threshold <= 1.0)
                _push_range!(errors, "foundation_options.mat_coverage_threshold", fo.mat_coverage_threshold,
                    "Must be between 0 and 1.")
            end
            if fo.mat_params !== nothing && fo.mat_params.analysis_method !== nothing
                am = lowercase(strip(fo.mat_params.analysis_method))
                if !(am in API_MAT_ANALYSIS_METHODS)
                    _push_enum!(errors, "foundation_options.mat_params.analysis_method",
                        fo.mat_params.analysis_method, API_MAT_ANALYSIS_METHODS)
                end
            end
        end
    end

    # ─── Unit system ──────────────────────────────────────────────────
    if !(lowercase(strip(p.unit_system)) in API_UNIT_SYSTEMS)
        _push_enum!(errors, "unit_system", p.unit_system, API_UNIT_SYSTEMS)
    end

    return ValidationResult(isempty(errors), errors)
end
