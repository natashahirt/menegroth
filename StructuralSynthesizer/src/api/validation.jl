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
              "Specify coordinate units: \"feet\", \"inches\", \"meters\", or \"mm\".")
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

    return ValidationResult(isempty(errors), errors)
end
