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

    # ─── Floor + column/beam type compatibility ─────────────────────────────
    # Flat plate/slab accept RC (rectangular, circular) only. Steel and PixelFrame not supported.
    beamless_floor = p.floor_type in ("flat_plate", "flat_slab")
    steel_column = p.column_type in ("steel_w", "steel_hss", "steel_pipe")
    pixelframe_column = p.column_type == "pixelframe"
    steel_beam = p.beam_type in ("steel_w", "steel_hss")
    if beamless_floor && (steel_column || pixelframe_column)
        push!(errors, "floor_type \"$(p.floor_type)\" requires reinforced concrete columns. " *
              "column_type \"$(p.column_type)\" is not supported for beamless slab systems.")
    end
    # Vault requires RC beams and RC columns (thrust resistance)
    if p.floor_type == "vault"
        if steel_column
            push!(errors, "floor_type \"vault\" requires reinforced concrete columns. " *
                  "column_type \"$(p.column_type)\" is not supported.")
        end
        if steel_beam
            push!(errors, "floor_type \"vault\" requires reinforced concrete beams. " *
                  "beam_type \"$(p.beam_type)\" is not supported.")
        end
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
    if !isnothing(p.floor_options.vault_lambda) && p.floor_options.vault_lambda <= 0
        push!(errors, "Invalid floor_options.vault_lambda $(p.floor_options.vault_lambda). Must be > 0.")
    end
    if !isnothing(p.floor_options.target_edge_m) && p.floor_options.target_edge_m <= 0
        push!(errors, "Invalid floor_options.target_edge_m $(p.floor_options.target_edge_m). Must be > 0.")
    end
    if !isnothing(p.visualization_target_edge_m) && p.visualization_target_edge_m <= 0
        push!(errors, "Invalid visualization_target_edge_m $(p.visualization_target_edge_m). Must be > 0.")
    end

    for (i, ov) in enumerate(p.scoped_overrides)
        if !(ov.floor_type in valid_floor_types)
            push!(errors, "Invalid scoped_overrides[$i].floor_type \"$(ov.floor_type)\". Must be one of: $(join(valid_floor_types, ", ")).")
        end
        if !isnothing(ov.floor_options.vault_lambda) && ov.floor_options.vault_lambda <= 0
            push!(errors, "Invalid scoped_overrides[$i].floor_options.vault_lambda $(ov.floor_options.vault_lambda). Must be > 0.")
        end
        if isempty(ov.faces)
            push!(errors, "scoped_overrides[$i] must include at least one face polygon.")
        end
        for (j, poly) in enumerate(ov.faces)
            if length(poly) < 3
                push!(errors, "scoped_overrides[$i].faces[$j] has $(length(poly)) vertices (need ≥ 3).")
            end
            for (k, coord) in enumerate(poly)
                if length(coord) != 3
                    push!(errors, "scoped_overrides[$i].faces[$j] vertex $k has $(length(coord)) coords (expected 3).")
                end
            end
        end
    end

    valid_column_types = ("rc_rect", "rc_circular", "steel_w", "steel_hss", "steel_pipe", "pixelframe")
    if !(p.column_type in valid_column_types)
        push!(errors, "Invalid column_type \"$(p.column_type)\". Must be one of: $(join(valid_column_types, ", ")).")
    end
    valid_steel_column_catalogs = ("compact_only", "preferred", "all")
    if p.column_type in ("steel_w", "steel_hss", "steel_pipe") && p.column_catalog !== nothing &&
       !(p.column_catalog in valid_steel_column_catalogs)
        push!(errors, "Invalid column_catalog for steel \"$(p.column_catalog)\". Must be one of: $(join(valid_steel_column_catalogs, ", ")).")
    end
    valid_rc_rect_catalogs = ("standard", "square", "rectangular", "low_capacity", "high_capacity", "all")
    if p.column_type == "rc_rect" && p.column_catalog !== nothing && !(p.column_catalog in valid_rc_rect_catalogs)
        push!(errors, "Invalid column_catalog for RC rectangular \"$(p.column_catalog)\". Must be one of: $(join(valid_rc_rect_catalogs, ", ")).")
    end
    valid_rc_circular_catalogs = ("standard", "low_capacity", "high_capacity", "all")
    if p.column_type == "rc_circular" && p.column_catalog !== nothing && !(p.column_catalog in valid_rc_circular_catalogs)
        push!(errors, "Invalid column_catalog for RC circular \"$(p.column_catalog)\". Must be one of: $(join(valid_rc_circular_catalogs, ", ")).")
    end

    valid_beam_types = ("steel_w", "steel_hss", "rc_rect", "rc_tbeam", "pixelframe")
    if !(p.beam_type in valid_beam_types)
        push!(errors, "Invalid beam_type \"$(p.beam_type)\". Must be one of: $(join(valid_beam_types, ", ")).")
    end

    valid_beam_catalogs = ("standard", "small", "large", "xlarge", "all", "custom")
    if !(p.beam_catalog in valid_beam_catalogs)
        push!(errors, "Invalid beam_catalog \"$(p.beam_catalog)\". Must be one of: $(join(valid_beam_catalogs, ", ")).")
    end
    valid_pixelframe_fc_presets = ("standard", "low", "high", "extended", "custom")
    if p.column_type == "pixelframe" || p.beam_type == "pixelframe"
        pf = p.pixelframe_options
        if pf !== nothing
            preset = lowercase(strip(pf.fc_preset))
            if !(preset in valid_pixelframe_fc_presets)
                push!(errors, "Invalid pixelframe_options.fc_preset \"$(pf.fc_preset)\". Must be one of: $(join(valid_pixelframe_fc_presets, ", ")).")
            elseif preset == "custom"
                if pf.fc_min_ksi === nothing || pf.fc_max_ksi === nothing || pf.fc_resolution_ksi === nothing
                    push!(errors, "pixelframe_options: fc_min_ksi, fc_max_ksi, and fc_resolution_ksi are required when fc_preset is \"custom\".")
                elseif pf.fc_min_ksi >= pf.fc_max_ksi
                    push!(errors, "pixelframe_options: fc_min_ksi must be < fc_max_ksi.")
                elseif pf.fc_resolution_ksi <= 0
                    push!(errors, "pixelframe_options: fc_resolution_ksi must be > 0.")
                end
            end
        end
    end

    if p.beam_catalog == "custom"
        if p.beam_catalog_bounds === nothing
            push!(errors, "beam_catalog_bounds is required when beam_catalog is \"custom\".")
        else
            b = p.beam_catalog_bounds
            if b.min_width_in >= b.max_width_in
                push!(errors, "beam_catalog_bounds: min_width_in must be < max_width_in.")
            end
            if b.min_depth_in >= b.max_depth_in
                push!(errors, "beam_catalog_bounds: min_depth_in must be < max_depth_in.")
            end
            if b.resolution_in <= 0
                push!(errors, "beam_catalog_bounds: resolution_in must be > 0.")
            end
        end
    end

    if !(lowercase(strip(p.column_sizing_strategy)) in ("discrete", "nlp"))
        push!(errors, "Invalid column_sizing_strategy \"$(p.column_sizing_strategy)\". Must be discrete or nlp.")
    end
    if !(lowercase(strip(p.beam_sizing_strategy)) in ("discrete", "nlp"))
        push!(errors, "Invalid beam_sizing_strategy \"$(p.beam_sizing_strategy)\". Must be discrete or nlp.")
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
    if !haskey(CONCRETE_MAP, p.materials.column_concrete)
        push!(errors, "Unknown column_concrete \"$(p.materials.column_concrete)\". Options: $(join(keys(CONCRETE_MAP), ", ")).")
    end
    if !haskey(REBAR_MAP, p.materials.rebar)
        push!(errors, "Unknown rebar \"$(p.materials.rebar)\". Options: $(join(keys(REBAR_MAP), ", ")).")
    end
    if !haskey(STEEL_MAP, p.materials.steel)
        push!(errors, "Unknown steel \"$(p.materials.steel)\". Options: $(join(keys(STEEL_MAP), ", ")).")
    end

    # ─── Foundation (when size_foundations is true) ────────────────────
    if p.size_foundations
        if !haskey(SOIL_MAP, p.foundation_soil)
            push!(errors, "Unknown foundation_soil \"$(p.foundation_soil)\". " *
                  "Options: $(join(keys(SOIL_MAP), ", ")).")
        end
        if !haskey(CONCRETE_MAP, p.foundation_concrete)
            push!(errors, "Unknown foundation_concrete \"$(p.foundation_concrete)\". Options: $(join(keys(CONCRETE_MAP), ", ")).")
        end
        if p.foundation_options !== nothing
            fo = p.foundation_options
            strategy_ok = lowercase(strip(fo.strategy)) in ("auto", "auto_strip_spread", "all_spread", "all_strip", "mat")
            if !strategy_ok
                push!(errors, "foundation_options.strategy must be one of: auto, auto_strip_spread, all_spread, all_strip, mat (got \"$(fo.strategy)\").")
            end
            if !(0.0 <= fo.mat_coverage_threshold <= 1.0)
                push!(errors, "foundation_options.mat_coverage_threshold must be between 0 and 1 (got $(fo.mat_coverage_threshold)).")
            end
            if fo.mat_params !== nothing && fo.mat_params.analysis_method !== nothing
                am = lowercase(strip(fo.mat_params.analysis_method))
                if !(am in ("rigid", "shukla", "winkler"))
                    push!(errors, "foundation_options.mat_params.analysis_method must be rigid, shukla, or winkler (got \"$(fo.mat_params.analysis_method)\").")
                end
            end
        end
    end

    # ─── Unit system ──────────────────────────────────────────────────
    if !(lowercase(strip(p.unit_system)) in ("imperial", "metric"))
        push!(errors, "Invalid unit_system \"$(p.unit_system)\". Must be \"imperial\" or \"metric\".")
    end

    return ValidationResult(isempty(errors), errors)
end
