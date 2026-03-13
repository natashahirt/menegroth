# =============================================================================
# API Validation — Input checking before design
# =============================================================================

"""
    ValidationResult

Holds validation outcome: `ok` is true if all checks pass, `errors` collects
human-readable messages for every failing check.
"""
struct ValidationResult
    ok::Bool
    errors::Vector{String}
end

"""Create a passing `ValidationResult` with no errors."""
ValidationResult() = ValidationResult(true, String[])

"""
    validate_input(input::APIInput) -> ValidationResult

Run all input validation checks. Returns immediately usable result; the caller
decides whether to abort (HTTP 400) or proceed.
"""
function validate_input(input::APIInput)
    errors = String[]

    # ─── Units required ───────────────────────────────────────────────────
    if isempty(strip(input.units))
        push!(errors, "Missing required field \"units\". " *
              "Accepted: feet/ft, inches/in, meters/m, millimeters/mm, centimeters/cm.")
    else
        try
            parse_unit(input.units)
        catch e
            push!(errors, string(e))
        end
    end

    # ─── Vertices ─────────────────────────────────────────────────────────
    n_verts = length(input.vertices)
    if n_verts < 4
        push!(errors, "Need at least 4 vertices (got $n_verts).")
    end
    for (i, v) in enumerate(input.vertices)
        if length(v) != 3
            push!(errors, "Vertex $i has $(length(v)) coordinates (expected 3).")
        end
    end

    # ─── Edges ────────────────────────────────────────────────────────────
    all_edges = vcat(input.edges.beams, input.edges.columns, input.edges.braces)
    if isempty(all_edges)
        push!(errors, "No edges provided (need at least beams, columns, or braces).")
    end
    for (i, edge) in enumerate(all_edges)
        if length(edge) != 2
            push!(errors, "Edge $i has $(length(edge)) vertex indices (expected 2).")
            continue
        end
        v1, v2 = edge
        if v1 < 1 || v1 > n_verts
            push!(errors, "Edge $i: vertex index $v1 out of range [1, $n_verts].")
        end
        if v2 < 1 || v2 > n_verts
            push!(errors, "Edge $i: vertex index $v2 out of range [1, $n_verts].")
        end
        if v1 == v2
            push!(errors, "Edge $i: degenerate edge (both indices = $v1).")
        end
    end

    # ─── Supports ─────────────────────────────────────────────────────────
    if isempty(input.supports)
        push!(errors, "No support vertices specified.")
    end
    for (i, si) in enumerate(input.supports)
        if si < 1 || si > n_verts
            push!(errors, "Support $i: vertex index $si out of range [1, $n_verts].")
        end
    end

    # ─── Stories Z (optional — inferred from vertex Z if omitted) ────────
    # Only validate if explicitly provided (empty array is fine — will be inferred)
    if !isempty(input.stories_z)
        if length(input.stories_z) < 2
            push!(errors, "If provided, need at least 2 story elevations (got $(length(input.stories_z))).")
        end
    end

    # ─── Faces (if provided) ─────────────────────────────────────────────
    for (category, polylines) in input.faces
        for (j, poly) in enumerate(polylines)
            if length(poly) < 3
                push!(errors, "Face \"$category\"[$j] has $(length(poly)) vertices (need ≥ 3).")
            end
            for (k, coord) in enumerate(poly)
                if length(coord) != 3
                    push!(errors, "Face \"$category\"[$j] vertex $k has $(length(coord)) coords (expected 3).")
                end
            end
        end
    end

    # ─── Params ──────────────────────────────────────────────────────────
    p = input.params

    valid_floor_types = ("flat_plate", "flat_slab", "one_way", "vault")
    if !(p.floor_type in valid_floor_types)
        push!(errors, "Invalid floor_type \"$(p.floor_type)\". Must be one of: $(join(valid_floor_types, ", ")).")
    end

    # ─── Floor options (method, deflection_limit, punching_strategy) ─────
    valid_analysis_methods = ("DDM", "DDM_SIMPLIFIED", "EFM", "EFM_HARDY_CROSS", "FEA")
    method_key = uppercase(strip(p.floor_options.method))
    if !(method_key in valid_analysis_methods)
        push!(errors, "Invalid floor_options.method \"$(p.floor_options.method)\". " *
              "Must be one of: $(join(valid_analysis_methods, ", ")).")
    end
    valid_deflection_limits = ("L_240", "L_360", "L_480")
    defl_key = uppercase(strip(p.floor_options.deflection_limit))
    if !(defl_key in valid_deflection_limits)
        push!(errors, "Invalid floor_options.deflection_limit \"$(p.floor_options.deflection_limit)\". " *
              "Must be one of: $(join(valid_deflection_limits, ", ")).")
    end
    valid_punching_strategies = ("grow_columns", "reinforce_last", "reinforce_first")
    punch_key = lowercase(strip(p.floor_options.punching_strategy))
    if !(punch_key in valid_punching_strategies)
        push!(errors, "Invalid floor_options.punching_strategy \"$(p.floor_options.punching_strategy)\". " *
              "Must be one of: $(join(valid_punching_strategies, ", ")).")
    end

    valid_column_types = ("rc_rect", "rc_circular", "steel_w", "steel_hss", "steel_pipe")
    if !(p.column_type in valid_column_types)
        push!(errors, "Invalid column_type \"$(p.column_type)\". Must be one of: $(join(valid_column_types, ", ")).")
    end

    valid_beam_types = ("steel_w", "steel_hss", "rc_rect", "rc_tbeam")
    if !(p.beam_type in valid_beam_types)
        push!(errors, "Invalid beam_type \"$(p.beam_type)\". Must be one of: $(join(valid_beam_types, ", ")).")
    end

    if p.fire_rating ∉ (0.0, 1.0, 1.5, 2.0, 3.0, 4.0)
        push!(errors, "Invalid fire_rating $(p.fire_rating). Must be one of: 0, 1, 1.5, 2, 3, 4.")
    end
    if !(p.optimize_for in ("weight", "carbon", "cost"))
        push!(errors, "Invalid optimize_for \"$(p.optimize_for)\". Must be: weight, carbon, or cost.")
    end
    if !haskey(CONCRETE_MAP, p.materials.concrete)
        push!(errors, "Unknown concrete \"$(p.materials.concrete)\". Options: $(join(keys(CONCRETE_MAP), ", ")).")
    end
    if !haskey(REBAR_MAP, p.materials.rebar)
        push!(errors, "Unknown rebar \"$(p.materials.rebar)\". Options: $(join(keys(REBAR_MAP), ", ")).")
    end
    if !haskey(STEEL_MAP, p.materials.steel)
        push!(errors, "Unknown steel \"$(p.materials.steel)\". Options: $(join(keys(STEEL_MAP), ", ")).")
    end

    # ─── Foundation soil (required when size_foundations is true) ──────
    if p.size_foundations && !haskey(SOIL_MAP, p.foundation_soil)
        push!(errors, "Unknown foundation_soil \"$(p.foundation_soil)\". " *
              "Options: $(join(keys(SOIL_MAP), ", ")).")
    end

    # ─── Unit system ──────────────────────────────────────────────────
    if !(lowercase(strip(p.unit_system)) in ("imperial", "metric"))
        push!(errors, "Invalid unit_system \"$(p.unit_system)\". Must be \"imperial\" or \"metric\".")
    end

    return ValidationResult(isempty(errors), errors)
end
