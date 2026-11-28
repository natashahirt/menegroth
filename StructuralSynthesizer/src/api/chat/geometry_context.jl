"""Max characters of structured geometry JSON in the chat system prompt (limits context size)."""
const _MAX_CHAT_BUILDING_GEOMETRY_JSON_CHARS = 120_000

"""
    _parse_chat_building_geometry(raw) -> Union{Nothing, Dict{String, Any}}

Normalize `building_geometry` or `geometry` from POST /chat into a string-keyed dict. Expected
shape matches the geometry section of POST /design (Grasshopper `BuildingGeometry.ToJson()`):
`units`, `vertices`, `edges`::{beams,columns,braces}, `supports`, `faces`::{category -> polygons}, optional `stories_z`.
"""
function _parse_chat_building_geometry(raw)::Union{Nothing, Dict{String, Any}}
    isnothing(raw) && return nothing
    if raw isa Dict{String, Any}
        return raw
    end
    if raw isa AbstractDict
        return Dict{String, Any}(string(k) => v for (k, v) in pairs(raw))
    end
    try
        d = JSON3.read(JSON3.write(raw))
        d isa AbstractDict || return nothing
        return Dict{String, Any}(string(k) => v for (k, v) in pairs(d))
    catch
        return nothing
    end
end

# ─── Chat-side structure cache ────────────────────────────────────────────────
#
# When POST /chat receives `building_geometry`, we build a lightweight
# BuildingSkeleton → BuildingStructure → initialize! to get real structural
# data (cells, slabs, members, tributaries) without running the solver.
# The result is cached by geometry hash to avoid re-initializing every turn.

mutable struct _ChatStructureCache
    geometry_hash::String
    structure::Union{BuildingStructure, Nothing}
    digest::Union{Dict{String, Any}, Nothing}
    lock::ReentrantLock
end
_ChatStructureCache() = _ChatStructureCache("", nothing, nothing, ReentrantLock())

const _CHAT_STRUCTURE_CACHE = _ChatStructureCache()

"""
    _chat_geometry_sse_emit!(stream, phase; kwargs...)

Emit one SSE `data:` line with `type` = `geometry_init` for client loading traces.
`stream` may be `nothing` (no-op).
"""
function _chat_geometry_sse_emit!(
    stream::Union{Nothing, HTTP.Stream},
    phase::String;
    message::Union{Nothing, String} = nothing,
    geometry_hash_prefix::Union{Nothing, String} = nothing,
    elapsed_ms::Union{Nothing, Int} = nothing,
    cached::Union{Nothing, Bool} = nothing,
    extra::Union{Nothing, Dict{String, Any}} = nothing,
)
    isnothing(stream) && return
    d = Dict{String, Any}("type" => "geometry_init", "phase" => phase)
    !isnothing(message) && (d["message"] = message)
    !isnothing(geometry_hash_prefix) && (d["geometry_hash_prefix"] = geometry_hash_prefix)
    !isnothing(elapsed_ms) && (d["elapsed_ms"] = elapsed_ms)
    !isnothing(cached) && (d["cached"] = cached)
    if !isnothing(extra)
        for (k, v) in extra
            d[string(k)] = v
        end
    end
    write(stream, "data: $(JSON3.write(d))\n\n")
    return nothing
end

"""
    _chat_get_or_build_structure(geo_dict; sse_stream=nothing) -> Union{BuildingStructure, Nothing}

Thread-safe access to the chat structure cache. Returns a fully initialized
`BuildingStructure` with cells, members, and tributaries computed.
Returns `nothing` if initialization fails (logs warning).

When `sse_stream` is set, emits phased `geometry_init` SSE events for the UI.
"""
function _chat_get_or_build_structure(
    geo_dict::Dict{String, Any};
    sse_stream::Union{Nothing, HTTP.Stream} = nothing,
)::Union{BuildingStructure, Nothing}
    geo_hash = try
        compute_geometry_hash(_api_input_geometry_only_from_chat_dict(geo_dict))
    catch
        _chat_geometry_sse_emit!(
            sse_stream, "error";
            message = "Could not compute geometry hash for structure build.",
        )
        return nothing
    end
    hp = length(geo_hash) >= 8 ? geo_hash[1:8] : geo_hash

    lock(_CHAT_STRUCTURE_CACHE.lock) do
        if _CHAT_STRUCTURE_CACHE.geometry_hash == geo_hash && !isnothing(_CHAT_STRUCTURE_CACHE.structure)
            _chat_geometry_sse_emit!(
                sse_stream, "cache_hit_structure";
                message = "Reusing initialized BuildingStructure from server cache (same geometry).",
                geometry_hash_prefix = hp,
                cached = true,
            )
            return _CHAT_STRUCTURE_CACHE.structure
        end
    end

    prev_chat_hash = lock(_CHAT_STRUCTURE_CACHE.lock) do
        _CHAT_STRUCTURE_CACHE.geometry_hash
    end
    if !isempty(prev_chat_hash) && prev_chat_hash != geo_hash
        reset_session_state!(DESIGN_CACHE; reason="geometry hash changed (POST /chat)")
        _chat_geometry_sse_emit!(
            sse_stream, "session_reset";
            message = "New geometry detected — design history and insights cleared (chat preserved).",
            geometry_hash_prefix = hp,
        )
    end

    _chat_geometry_sse_emit!(
        sse_stream, "start";
        message = "Building analytical model from geometry (no structural solver).",
        geometry_hash_prefix = hp,
    )
    _chat_geometry_sse_emit!(
        sse_stream, "skeleton";
        message = "Parsing vertices, edges, faces, supports → BuildingSkeleton…",
        geometry_hash_prefix = hp,
    )
    t_skel = time()
    struc = try
        api_input = _api_input_geometry_only_from_chat_dict(geo_dict)
        skel = json_to_skeleton(api_input)
        _chat_geometry_sse_emit!(
            sse_stream, "skeleton_done";
            message = "Skeleton built.",
            geometry_hash_prefix = hp,
            elapsed_ms = round(Int, (time() - t_skel) * 1000),
            extra = Dict{String, Any}(
                "n_vertices" => length(skel.vertices),
                "n_edges" => length(skel.edges),
            ),
        )
        _chat_geometry_sse_emit!(
            sse_stream, "initialize";
            message = "initialize! — cells, slabs, framing, column tributaries…",
            geometry_hash_prefix = hp,
        )
        t_ini = time()
        struc = BuildingStructure(skel)
        initialize!(struc)
        _chat_geometry_sse_emit!(
            sse_stream, "initialize_done";
            message = "Structure initialized.",
            geometry_hash_prefix = hp,
            elapsed_ms = round(Int, (time() - t_ini) * 1000),
            extra = Dict{String, Any}(
                "n_cells" => length(struc.cells),
                "n_slabs" => length(struc.slabs),
                "n_beams" => length(struc.beams),
                "n_columns" => length(struc.columns),
            ),
        )
        struc
    catch e
        _chat_geometry_sse_emit!(
            sse_stream, "error";
            message = "Structure build failed: $(sprint(showerror, e))",
            geometry_hash_prefix = hp,
        )
        @warn "Chat structure initialization failed — falling back to raw JSON analysis" exception=(e, catch_backtrace())
        return nothing
    end

    lock(_CHAT_STRUCTURE_CACHE.lock) do
        _CHAT_STRUCTURE_CACHE.geometry_hash = geo_hash
        _CHAT_STRUCTURE_CACHE.structure = struc
        _CHAT_STRUCTURE_CACHE.digest = nothing  # invalidate cached digest
    end
    return struc
end

"""
    _structure_geometry_digest(struc::BuildingStructure) -> Dict{String, Any}

Extract a rich geometry digest from an initialized `BuildingStructure`.
Includes real structural data: cell spans, slab panels, member lengths,
column tributary areas with variation metrics, beam spans, story info,
grid topology, and span variance flags.

This replaces the raw-JSON `_chat_structured_geometry_stats` approach with
data computed by the same pipeline the solver uses.
"""
function _structure_geometry_digest(struc::BuildingStructure)::Dict{String, Any}
    skel = struc.skeleton
    result = Dict{String, Any}()
    flags = String[]
    to_ft(x) = ustrip(u"ft", x)

    # ── Counts ────────────────────────────────────────────────────────────
    result["n_cells"] = length(struc.cells)
    result["n_slabs"] = length(struc.slabs)
    result["n_beams"] = length(struc.beams)
    result["n_columns"] = length(struc.columns)
    result["n_stories"] = length(skel.stories)
    result["n_vertices"] = length(skel.vertices)
    result["n_supports"] = length(struc.supports)

    # ── Story heights ─────────────────────────────────────────────────────
    if length(skel.stories_z) >= 2
        sorted_z = sort(skel.stories_z)
        heights_ft = [to_ft(sorted_z[i+1] - sorted_z[i]) for i in 1:length(sorted_z)-1]
        result["stories"] = Dict{String, Any}(
            "n_stories" => length(sorted_z),
            "story_heights_ft" => round.(heights_ft; digits=2),
            "min_ft" => round(minimum(heights_ft); digits=2),
            "max_ft" => round(maximum(heights_ft); digits=2),
            "source" => "stories_z",
        )
        if maximum(heights_ft) > 18.0
            push!(flags, "tall_story_>18ft")
        end
    end

    # ── Cell spans ────────────────────────────────────────────────────────
    if !isempty(struc.cells)
        cell_data = Dict{String, Any}[]
        areas_ft2 = Float64[]
        primary_spans_ft = Float64[]
        secondary_spans_ft = Float64[]
        for (i, cell) in enumerate(struc.cells)
            a_ft2 = ustrip(u"ft^2", cell.area)
            p_ft = to_ft(cell.spans.primary)
            s_ft = to_ft(cell.spans.secondary)
            push!(areas_ft2, a_ft2)
            push!(primary_spans_ft, p_ft)
            push!(secondary_spans_ft, s_ft)
            push!(cell_data, Dict{String, Any}(
                "idx" => i,
                "area_ft2" => round(a_ft2; digits=1),
                "primary_span_ft" => round(p_ft; digits=2),
                "secondary_span_ft" => round(s_ft; digits=2),
                "position" => string(cell.position),
                "floor_type" => string(cell.floor_type),
            ))
        end
        result["cells"] = Dict{String, Any}(
            "count" => length(cell_data),
            "area_ft2" => Dict{String, Any}(
                "min" => round(minimum(areas_ft2); digits=1),
                "max" => round(maximum(areas_ft2); digits=1),
                "mean" => round(sum(areas_ft2) / length(areas_ft2); digits=1),
            ),
            "primary_span_ft" => Dict{String, Any}(
                "min" => round(minimum(primary_spans_ft); digits=2),
                "max" => round(maximum(primary_spans_ft); digits=2),
                "mean" => round(sum(primary_spans_ft) / length(primary_spans_ft); digits=2),
            ),
            "secondary_span_ft" => Dict{String, Any}(
                "min" => round(minimum(secondary_spans_ft); digits=2),
                "max" => round(maximum(secondary_spans_ft); digits=2),
                "mean" => round(sum(secondary_spans_ft) / length(secondary_spans_ft); digits=2),
            ),
            "positions" => Dict{String, Int}(
                string(k) => count(c -> c.position == k, struc.cells)
                for k in unique(c.position for c in struc.cells)
            ),
        )
        # Truncate per-cell detail if too many
        if length(cell_data) <= 30
            result["cells"]["detail"] = cell_data
        else
            result["cells"]["detail_note"] = "$(length(cell_data)) cells (detail truncated). Use stats above."
        end
    end

    # ── Slab panels ───────────────────────────────────────────────────────
    if !isempty(struc.slabs)
        slab_data = Dict{String, Any}[]
        for (i, slab) in enumerate(struc.slabs)
            p_ft = to_ft(slab.spans.primary)
            s_ft = to_ft(slab.spans.secondary)
            ratio = s_ft > 0.01 ? round(p_ft / s_ft; digits=2) : 0.0
            push!(slab_data, Dict{String, Any}(
                "idx" => i,
                "n_cells" => length(slab.cell_indices),
                "primary_span_ft" => round(p_ft; digits=2),
                "secondary_span_ft" => round(s_ft; digits=2),
                "aspect_ratio" => ratio,
                "position" => string(slab.position),
                "floor_type" => string(slab.floor_type),
            ))
        end
        result["slabs"] = Dict{String, Any}(
            "count" => length(slab_data),
            "detail" => slab_data,
        )
    end

    # ── Beam spans ────────────────────────────────────────────────────────
    if !isempty(struc.beams)
        beam_spans_ft = Float64[]
        x_spans = Float64[]
        y_spans = Float64[]
        for beam in struc.beams
            L_ft = to_ft(beam.base.L)
            push!(beam_spans_ft, L_ft)
            seg_indices = beam.base.segment_indices
            if !isempty(seg_indices)
                seg = struc.segments[first(seg_indices)]
                vi1, vi2 = skel.edge_indices[seg.edge_idx]
                v1 = skel.vertices[vi1]
                v2 = skel.vertices[vi2]
                dx = abs(ustrip(u"m", Meshes.coords(v2).x - Meshes.coords(v1).x))
                dy = abs(ustrip(u"m", Meshes.coords(v2).y - Meshes.coords(v1).y))
                if dx >= dy
                    push!(x_spans, L_ft)
                else
                    push!(y_spans, L_ft)
                end
            end
        end
        beam_stats = Dict{String, Any}(
            "count" => length(beam_spans_ft),
            "all" => _stats_dict(beam_spans_ft, "ft"),
        )
        !isempty(x_spans) && (beam_stats["x_direction"] = _stats_dict(x_spans, "ft"))
        !isempty(y_spans) && (beam_stats["y_direction"] = _stats_dict(y_spans, "ft"))
        result["beam_spans"] = beam_stats

        max_span_ft = maximum(beam_spans_ft)
        if max_span_ft > 30.0
            push!(flags, "long_beam_span_>30ft ($(round(max_span_ft; digits=1)) ft)")
        end
    end

    # ── Column heights ────────────────────────────────────────────────────
    if !isempty(struc.columns)
        col_heights_ft = [to_ft(col.base.L) for col in struc.columns]
        result["column_heights"] = _stats_dict(col_heights_ft, "ft")
    end

    # ── Column tributary areas ────────────────────────────────────────────
    if !isempty(struc.columns)
        trib_areas_ft2 = Float64[]
        per_column = Dict{String, Any}[]
        by_position = Dict{Symbol, Vector{Float64}}()
        for (i, col) in enumerate(struc.columns)
            At = column_tributary_area(struc, col)
            if !isnothing(At)
                a_ft2 = ustrip(u"ft^2", At)
                push!(trib_areas_ft2, a_ft2)
                pos = col.position
                haskey(by_position, pos) || (by_position[pos] = Float64[])
                push!(by_position[pos], a_ft2)
                push!(per_column, Dict{String, Any}(
                    "idx" => i,
                    "story" => col.story,
                    "position" => string(pos),
                    "tributary_ft2" => round(a_ft2; digits=1),
                    "height_ft" => round(to_ft(col.base.L); digits=2),
                ))
            end
        end
        if !isempty(trib_areas_ft2)
            mean_a = sum(trib_areas_ft2) / length(trib_areas_ft2)
            std_a = length(trib_areas_ft2) > 1 ? sqrt(sum((x - mean_a)^2 for x in trib_areas_ft2) / (length(trib_areas_ft2) - 1)) : 0.0
            cv_overall = mean_a > 0 ? std_a / mean_a : 0.0
            sorted = sort(trib_areas_ft2)
            p10 = sorted[max(1, round(Int, 0.1 * length(sorted)))]
            p90 = sorted[min(length(sorted), round(Int, 0.9 * length(sorted)))]

            within_cvs = Float64[]
            position_stats = Dict{String, Any}()
            for (pos, areas) in by_position
                n = length(areas)
                m = sum(areas) / n
                s = n > 1 ? sqrt(sum((x - m)^2 for x in areas) / (n - 1)) : 0.0
                wcv = m > 0 ? s / m : 0.0
                push!(within_cvs, wcv)
                position_stats[string(pos)] = Dict{String, Any}(
                    "count" => n,
                    "mean_ft2" => round(m; digits=1),
                    "cv" => round(wcv; digits=3),
                )
            end
            max_within_cv = isempty(within_cvs) ? 0.0 : maximum(within_cvs)

            # Check cell topology: if all cells are quads (4-vertex faces),
            # the grid is rectangular regardless of tributary area variation.
            # Variable bay sizes on a rectangular grid produce different
            # tributary areas for same-position columns — that is normal
            # geometry, not irregularity (ACI 318 DDM/EFM both handle it).
            all_cells_quad = all(
                length(skel.face_vertex_indices[cell.face_idx]) == 4
                for cell in struc.cells
                if cell.face_idx >= 1 && cell.face_idx <= length(skel.face_vertex_indices)
            )

            trib_stats = Dict{String, Any}(
                "count" => length(trib_areas_ft2),
                "min_ft2" => round(minimum(trib_areas_ft2); digits=1),
                "max_ft2" => round(maximum(trib_areas_ft2); digits=1),
                "mean_ft2" => round(mean_a; digits=1),
                "cv_overall" => round(cv_overall; digits=3),
                "cv_within_position" => round(max_within_cv; digits=3),
                "p10_ft2" => round(p10; digits=1),
                "p90_ft2" => round(p90; digits=1),
                "by_position" => position_stats,
                "all_cells_quad" => all_cells_quad,
            )

            span_variance = if max_within_cv < 0.15
                "uniform"
            elseif max_within_cv < 0.30
                "moderate"
            else
                "high"
            end
            trib_stats["grid_topology"] = all_cells_quad ? "rectangular" : "non_rectangular"
            trib_stats["span_variance"] = span_variance
            trib_stats["interpretation"] = if all_cells_quad && span_variance == "uniform"
                "Rectangular grid with uniform bay sizes. " *
                "Tributary areas are consistent within each position class. DDM/EFM assumptions apply."
            elseif all_cells_quad
                "Rectangular grid with variable bay sizes (within-position CV=$(round(max_within_cv; digits=2))). " *
                "Different bay sizes produce different tributary loads per column — this is normal geometry, " *
                "not a grid irregularity. DDM/EFM assumptions apply. " *
                "Punching shear is checked per-column with each column's actual tributary load."
            elseif span_variance == "uniform"
                "Non-rectangular grid but tributary areas are consistent within each position class. " *
                "Consider FEA for non-orthogonal panel geometry."
            elseif span_variance == "moderate"
                "Non-rectangular grid with moderate tributary spread (within-position CV=$(round(max_within_cv; digits=2))). " *
                "Some same-position columns carry different loads — check punching shear. Consider FEA."
            else
                "Non-rectangular grid with high tributary spread (within-position CV=$(round(max_within_cv; digits=2))). " *
                "DDM assumptions may not hold for non-orthogonal panels. FEA recommended. " *
                "Punching shear is checked per-column with each column's actual tributary load."
            end
            result["column_tributaries"] = trib_stats

            if !all_cells_quad && span_variance != "uniform"
                push!(flags, "non_rectangular_grid_high_span_variance ($(span_variance), within-position CV=$(round(max_within_cv; digits=2)))")
            end

            if length(per_column) <= 40
                trib_stats["per_column"] = per_column
            else
                trib_stats["per_column_note"] = "$(length(per_column)) columns (detail truncated)."
            end
        end
    end

    # ── Envelope ──────────────────────────────────────────────────────────
    if !isempty(skel.vertices)
        xs = [ustrip(u"ft", Meshes.coords(v).x) for v in skel.vertices]
        ys = [ustrip(u"ft", Meshes.coords(v).y) for v in skel.vertices]
        zs = [ustrip(u"ft", Meshes.coords(v).z) for v in skel.vertices]
        result["envelope"] = Dict{String, Any}(
            "footprint_x_ft" => round(maximum(xs) - minimum(xs); digits=2),
            "footprint_y_ft" => round(maximum(ys) - minimum(ys); digits=2),
            "total_height_ft" => round(maximum(zs) - minimum(zs); digits=2),
            "unit" => "ft",
        )
    end

    # ── Structural flags ──────────────────────────────────────────────────
    !isempty(flags) && (result["structural_flags"] = flags)
    result["source"] = "BuildingStructure_initialized"
    result["unit_system"] = "imperial"
    return result
end

"""Helper: compute min/max/mean/CV stats dict from a numeric vector."""
function _stats_dict(vals::Vector{Float64}, unit::String)::Dict{String, Any}
    n = length(vals)
    n == 0 && return Dict{String, Any}("count" => 0)
    mn = minimum(vals)
    mx = maximum(vals)
    mean_v = sum(vals) / n
    std_v = n > 1 ? sqrt(sum((x - mean_v)^2 for x in vals) / (n - 1)) : 0.0
    cv = mean_v > 0 ? std_v / mean_v : 0.0
    return Dict{String, Any}(
        "count" => n,
        "min" => round(mn; digits=2),
        "max" => round(mx; digits=2),
        "mean" => round(mean_v; digits=2),
        "cv" => round(cv; digits=3),
        "unit" => unit,
    )
end

"""
    _structure_digest_plaintext(d::Dict{String, Any}) -> String

Render the structure-based geometry digest as a compact LLM-readable block.
"""
function _structure_digest_plaintext(d::Dict{String, Any})::String
    lines = String["── STRUCTURE-BASED GEOMETRY DIGEST (authoritative — MUST USE) ──"]
    push!(lines, "MANDATORY: Quote the numbers below directly. Do NOT say spans are unknown or need further analysis.")
    push!(lines, "Source: BuildingStructure (skeleton → initialize! — same pipeline as solver)")

    # Counts
    push!(lines, "Elements: $(get(d, "n_cells", 0)) cells, $(get(d, "n_slabs", 0)) slabs, " *
                  "$(get(d, "n_beams", 0)) beams, $(get(d, "n_columns", 0)) columns")

    # Stories
    st = get(d, "stories", nothing)
    if !isnothing(st)
        n = get(st, "n_stories", "?")
        push!(lines, "Stories: $n levels")
        sh = get(st, "story_heights_ft", nothing)
        if !isnothing(sh) && !isempty(sh)
            push!(lines, "  Heights: $(join(sh, ", ")) ft")
        end
    end

    # Envelope
    env = get(d, "envelope", nothing)
    if !isnothing(env)
        push!(lines, "Footprint: $(env["footprint_x_ft"]) × $(env["footprint_y_ft"]) ft")
        push!(lines, "Total height: $(env["total_height_ft"]) ft")
    end

    # Cell spans
    cells = get(d, "cells", nothing)
    if !isnothing(cells)
        ps = get(cells, "primary_span_ft", nothing)
        ss = get(cells, "secondary_span_ft", nothing)
        if !isnothing(ps)
            push!(lines, "Cell primary spans: $(ps["min"])–$(ps["max"]) ft (mean $(ps["mean"]) ft)")
        end
        if !isnothing(ss)
            push!(lines, "Cell secondary spans: $(ss["min"])–$(ss["max"]) ft (mean $(ss["mean"]) ft)")
        end
        pos = get(cells, "positions", nothing)
        if !isnothing(pos)
            push!(lines, "  Positions: " * join(["$k=$v" for (k, v) in pos], ", "))
        end
    end

    # Beam spans
    bs = get(d, "beam_spans", nothing)
    if !isnothing(bs)
        all_s = get(bs, "all", nothing)
        if !isnothing(all_s)
            push!(lines, "Beam spans: $(all_s["min"])–$(all_s["max"]) ft (mean $(all_s["mean"]) ft, $(all_s["count"]) beams)")
        end
        xd = get(bs, "x_direction", nothing)
        yd = get(bs, "y_direction", nothing)
        if !isnothing(xd)
            push!(lines, "  X-direction: $(xd["min"])–$(xd["max"]) ft ($(xd["count"]) beams)")
        end
        if !isnothing(yd)
            push!(lines, "  Y-direction: $(yd["min"])–$(yd["max"]) ft ($(yd["count"]) beams)")
        end
    end

    # Column heights
    ch = get(d, "column_heights", nothing)
    if !isnothing(ch)
        push!(lines, "Column heights: $(ch["min"])–$(ch["max"]) ft (mean $(ch["mean"]) ft)")
    end

    # Column tributaries
    ct = get(d, "column_tributaries", nothing)
    if !isnothing(ct)
        push!(lines, "Column tributary areas: $(ct["min_ft2"])–$(ct["max_ft2"]) ft² (mean $(ct["mean_ft2"]) ft²)")
        cv_overall = get(ct, "cv_overall", get(ct, "cv", "?"))
        cv_within = get(ct, "cv_within_position", "?")
        push!(lines, "  Overall CV=$(cv_overall), within-position CV=$(cv_within), p10=$(ct["p10_ft2"]) ft², p90=$(ct["p90_ft2"]) ft²")
        bp = get(ct, "by_position", nothing)
        if !isnothing(bp)
            for (pos, ps) in bp
                push!(lines, "  $(pos): n=$(ps["count"]), mean=$(ps["mean_ft2"]) ft², CV=$(ps["cv"])")
            end
        end
        topo = get(ct, "grid_topology", nothing)
        sv = get(ct, "span_variance", nothing)
        !isnothing(topo) && push!(lines, "  Grid topology: $(topo), span variance: $(sv)")
        interp = get(ct, "interpretation", nothing)
        !isnothing(interp) && push!(lines, "  → $interp")
    end

    # Slab panels (compact)
    slabs = get(d, "slabs", nothing)
    if !isnothing(slabs) && !isempty(get(slabs, "detail", []))
        details = slabs["detail"]
        types_count = Dict{String, Int}()
        for s in details
            ft = get(s, "floor_type", "unknown")
            types_count[ft] = get(types_count, ft, 0) + 1
        end
        push!(lines, "Slab panels: $(slabs["count"]) (" * join(["$v×$k" for (k, v) in types_count], ", ") * ")")
    end

    # Flags
    fl = get(d, "structural_flags", nothing)
    if !isnothing(fl) && !isempty(fl)
        push!(lines, "⚡ Structural flags: " * join(fl, ", "))
    end

    push!(lines, "── END DIGEST ──")
    return join(lines, "\n") * "\n"
end

"""
    _chat_get_structure_digest(geo_dict; sse_stream=nothing) -> Union{Dict{String, Any}, Nothing}

Get (or compute + cache) a structure-based geometry digest.
Returns `nothing` if structure initialization fails.

When `sse_stream` is set, emits `geometry_init` phases (`cache_hit_digest`, `digest`,
`digest_done`, `complete`, `fallback`) for client loading traces.
"""
function _chat_get_structure_digest(
    geo_dict::Dict{String, Any};
    sse_stream::Union{Nothing, HTTP.Stream} = nothing,
)::Union{Dict{String, Any}, Nothing}
    t0 = time()
    geo_hash = try
        compute_geometry_hash(_api_input_geometry_only_from_chat_dict(geo_dict))
    catch
        _chat_geometry_sse_emit!(
            sse_stream, "error";
            message = "Could not compute geometry hash for digest.",
        )
        return nothing
    end
    hp = length(geo_hash) >= 8 ? geo_hash[1:8] : geo_hash

    lock(_CHAT_STRUCTURE_CACHE.lock) do
        if _CHAT_STRUCTURE_CACHE.geometry_hash == geo_hash && !isnothing(_CHAT_STRUCTURE_CACHE.digest)
            d = _CHAT_STRUCTURE_CACHE.digest
            _chat_geometry_sse_emit!(
                sse_stream, "cache_hit_digest";
                message = "Geometry digest already cached for this model.",
                geometry_hash_prefix = hp,
                cached = true,
            )
            _chat_geometry_sse_emit!(
                sse_stream, "complete";
                message = "Geometry ready for assistant.",
                geometry_hash_prefix = hp,
                elapsed_ms = round(Int, (time() - t0) * 1000),
                cached = true,
                extra = Dict{String, Any}(
                    "structure_digest_ok" => true,
                    "n_cells" => get(d, "n_cells", 0),
                    "n_slabs" => get(d, "n_slabs", 0),
                    "n_beams" => get(d, "n_beams", 0),
                    "n_columns" => get(d, "n_columns", 0),
                ),
            )
            return d
        end
    end

    struc = _chat_get_or_build_structure(geo_dict; sse_stream=sse_stream)
    if isnothing(struc)
        _chat_geometry_sse_emit!(
            sse_stream, "fallback";
            message = "Using lightweight raw-JSON geometry stats (structure init unavailable).",
            geometry_hash_prefix = hp,
            extra = Dict{String, Any}("structure_digest_ok" => false),
        )
        _chat_geometry_sse_emit!(
            sse_stream, "complete";
            message = "Geometry preprocessing finished (fallback mode).",
            geometry_hash_prefix = hp,
            elapsed_ms = round(Int, (time() - t0) * 1000),
            extra = Dict{String, Any}("structure_digest_ok" => false),
        )
        return nothing
    end

    lock(_CHAT_STRUCTURE_CACHE.lock) do
        if _CHAT_STRUCTURE_CACHE.geometry_hash == geo_hash && !isnothing(_CHAT_STRUCTURE_CACHE.digest)
            d = _CHAT_STRUCTURE_CACHE.digest
            _chat_geometry_sse_emit!(
                sse_stream, "complete";
                message = "Geometry ready for assistant.",
                geometry_hash_prefix = hp,
                elapsed_ms = round(Int, (time() - t0) * 1000),
                cached = true,
                extra = Dict{String, Any}(
                    "structure_digest_ok" => true,
                    "n_cells" => get(d, "n_cells", 0),
                    "n_slabs" => get(d, "n_slabs", 0),
                    "n_beams" => get(d, "n_beams", 0),
                    "n_columns" => get(d, "n_columns", 0),
                ),
            )
            return d
        end
    end

    _chat_geometry_sse_emit!(
        sse_stream, "digest";
        message = "Computing assistant geometry digest (spans, tributaries, flags)…",
        geometry_hash_prefix = hp,
    )
    t_d = time()
    digest = try
        _structure_geometry_digest(struc)
    catch e
        _chat_geometry_sse_emit!(
            sse_stream, "error";
            message = "Digest failed: $(sprint(showerror, e))",
            geometry_hash_prefix = hp,
        )
        @warn "Structure geometry digest failed" exception=(e, catch_backtrace())
        _chat_geometry_sse_emit!(
            sse_stream, "fallback";
            message = "Digest computation failed; assistant will use raw JSON stats if available.",
            geometry_hash_prefix = hp,
            extra = Dict{String, Any}("structure_digest_ok" => false),
        )
        _chat_geometry_sse_emit!(
            sse_stream, "complete";
            message = "Geometry preprocessing finished (digest error).",
            geometry_hash_prefix = hp,
            elapsed_ms = round(Int, (time() - t0) * 1000),
            extra = Dict{String, Any}("structure_digest_ok" => false),
        )
        return nothing
    end

    lock(_CHAT_STRUCTURE_CACHE.lock) do
        _CHAT_STRUCTURE_CACHE.digest = digest
    end
    _chat_geometry_sse_emit!(
        sse_stream, "digest_done";
        message = "Digest computed.",
        geometry_hash_prefix = hp,
        elapsed_ms = round(Int, (time() - t_d) * 1000),
    )
    _chat_geometry_sse_emit!(
        sse_stream, "complete";
        message = "Geometry ready for assistant.",
        geometry_hash_prefix = hp,
        elapsed_ms = round(Int, (time() - t0) * 1000),
        extra = Dict{String, Any}(
            "structure_digest_ok" => true,
            "n_cells" => get(digest, "n_cells", 0),
            "n_slabs" => get(digest, "n_slabs", 0),
            "n_beams" => get(digest, "n_beams", 0),
            "n_columns" => get(digest, "n_columns", 0),
        ),
    )
    return digest
end

# ─── Pre-design geometry analysis (raw JSON → enriched stats for LLM) ────────
#
# These helpers operate on the raw building_geometry dict from POST /chat,
# requiring no BuildingSkeleton or Unitful — pure arithmetic on JSON arrays.
# The goal is to give the LLM concrete numbers (spans, heights, panel shapes)
# at opening-analysis time, before any POST /design.

"""Unit string → scale factor to meters.  Falls back to 1.0 (assume meters)."""
function _chat_geo_unit_to_m(units::String)::Float64
    s = lowercase(strip(units))
    s in ("feet", "ft")        && return Asap.FT_TO_M
    s in ("inches", "in")      && return Asap.IN_TO_M
    s in ("meters", "m", "")   && return 1.0
    s in ("millimeters", "mm") && return 0.001
    s in ("centimeters", "cm") && return 0.01
    return 1.0
end

"""Display-unit label from the geometry's unit string (\"ft\", \"m\", etc.)."""
function _chat_geo_unit_label(units::String)::String
    s = lowercase(strip(units))
    s in ("feet", "ft")        && return "ft"
    s in ("inches", "in")      && return "in"
    s in ("meters", "m", "")   && return "m"
    s in ("millimeters", "mm") && return "mm"
    s in ("centimeters", "cm") && return "cm"
    return s
end

"""Extract `[x,y,z]` from a raw JSON vertex entry. Returns `nothing` on bad data."""
function _chat_geo_vertex(v)::Union{Nothing, NTuple{3,Float64}}
    (v isa AbstractVector && length(v) >= 3) || return nothing
    try
        return (Float64(v[1]), Float64(v[2]), Float64(v[3]))
    catch
        return nothing
    end
end

"""Euclidean distance between two 3D vertices (in raw coordinate units)."""
function _chat_geo_dist(a::NTuple{3,Float64}, b::NTuple{3,Float64})::Float64
    return sqrt((b[1]-a[1])^2 + (b[2]-a[2])^2 + (b[3]-a[3])^2)
end

"""
Compute edge lengths (in raw units) for a set of `[i,j]` 1-based index pairs.
Returns a vector of lengths, skipping any edge with bad vertex references.
"""
function _chat_geo_edge_lengths(verts::AbstractVector, edges::AbstractVector)::Vector{Float64}
    lengths = Float64[]
    for e in edges
        (e isa AbstractVector && length(e) >= 2) || continue
        i, j = try (Int(e[1]), Int(e[2])) catch; continue end
        (1 <= i <= length(verts) && 1 <= j <= length(verts)) || continue
        a = _chat_geo_vertex(verts[i])
        b = _chat_geo_vertex(verts[j])
        (isnothing(a) || isnothing(b)) && continue
        d = _chat_geo_dist(a, b)
        d > 0.0 && push!(lengths, d)
    end
    return lengths
end

"""
Classify a horizontal beam edge as primarily X- or Y-oriented based on which
plan-projection delta dominates.  Returns `:x`, `:y`, or `:diagonal`.
"""
function _chat_geo_beam_direction(a::NTuple{3,Float64}, b::NTuple{3,Float64})::Symbol
    dx = abs(b[1] - a[1])
    dy = abs(b[2] - a[2])
    total = dx + dy
    total < 1e-9 && return :diagonal
    dx / total > 0.7 && return :x
    dy / total > 0.7 && return :y
    return :diagonal
end

"""
Compute beam span stats with directional breakdown.
Returns `(all_stats, x_stats, y_stats)` where each is a Dict or `nothing`.
"""
function _chat_geo_beam_span_stats(
    verts::AbstractVector, beam_edges::AbstractVector, unit_label::String,
)::Tuple{Union{Nothing,Dict{String,Any}}, Union{Nothing,Dict{String,Any}}, Union{Nothing,Dict{String,Any}}}
    all_lengths = Float64[]
    x_lengths   = Float64[]
    y_lengths   = Float64[]
    for e in beam_edges
        (e isa AbstractVector && length(e) >= 2) || continue
        i, j = try (Int(e[1]), Int(e[2])) catch; continue end
        (1 <= i <= length(verts) && 1 <= j <= length(verts)) || continue
        a = _chat_geo_vertex(verts[i])
        b = _chat_geo_vertex(verts[j])
        (isnothing(a) || isnothing(b)) && continue
        d = _chat_geo_dist(a, b)
        d < 1e-6 && continue
        push!(all_lengths, d)
        dir = _chat_geo_beam_direction(a, b)
        dir == :x && push!(x_lengths, d)
        dir == :y && push!(y_lengths, d)
    end

    _make_stats = (ls::Vector{Float64}, label::String) -> begin
        isempty(ls) && return nothing
        mn = minimum(ls)
        mx = maximum(ls)
        μ  = sum(ls) / length(ls)
        cv = length(ls) > 1 ? sqrt(sum((l - μ)^2 for l in ls) / (length(ls) - 1)) / μ : 0.0
        Dict{String, Any}(
            "min"  => round(mn; digits=2),
            "max"  => round(mx; digits=2),
            "mean" => round(μ;  digits=2),
            "cv"   => round(cv; digits=3),
            "n"    => length(ls),
            "unit" => unit_label,
            "basis" => label,
        )
    end

    all_s = _make_stats(all_lengths, "all_beam_edges")
    x_s   = _make_stats(x_lengths,   "x_direction_beams")
    y_s   = _make_stats(y_lengths,   "y_direction_beams")
    return (all_s, x_s, y_s)
end

"""
Compute story heights from `stories_z` array.
Returns `(heights_in_units, stats_dict)` or `([], nothing)`.
"""
function _chat_geo_story_analysis(stories_z::AbstractVector, unit_label::String)
    zs = Float64[]
    for z in stories_z
        try push!(zs, Float64(z)) catch; end
    end
    sort!(zs)
    length(zs) < 2 && return (Float64[], nothing)

    heights = Float64[zs[i] - zs[i-1] for i in 2:length(zs)]
    filter!(h -> h > 0, heights)
    isempty(heights) && return (Float64[], nothing)

    stats = Dict{String, Any}(
        "n_stories"  => length(heights),
        "heights"    => round.(heights; digits=2),
        "min"        => round(minimum(heights); digits=2),
        "max"        => round(maximum(heights); digits=2),
        "total"      => round(sum(heights); digits=2),
        "unit"       => unit_label,
    )
    if maximum(heights) - minimum(heights) > 0.01 * maximum(heights)
        stats["regularity"] = "variable"
    else
        stats["regularity"] = "uniform"
    end
    return (heights, stats)
end

"""
Analyse slab panels from the `faces` dict in raw geometry JSON.
Computes panel topology (tri/quad/other), aspect ratios, and corner orthogonality.
"""
function _chat_geo_panel_analysis(faces_dict, unit_label::String)::Union{Nothing, Dict{String, Any}}
    (faces_dict isa AbstractDict) || return nothing

    slab_polys = Any[]
    for cat in ("floor", "roof")
        polys = get(faces_dict, cat, nothing)
        if isnothing(polys)
            polys = get(faces_dict, Symbol(cat), nothing)
        end
        polys isa AbstractVector && append!(slab_polys, polys)
    end
    isempty(slab_polys) && return nothing

    n_tri, n_quad, n_other = 0, 0, 0
    panel_aspects = Float64[]
    quad_corner_devs = Float64[]
    quad_max_devs = Float64[]
    panel_max_spans = Float64[]
    n_quad_orthogonal = 0

    for poly in slab_polys
        poly isa AbstractVector || continue
        pts_xy = NTuple{2,Float64}[]
        for pt in poly
            (pt isa AbstractVector && length(pt) >= 2) || continue
            try
                push!(pts_xy, (Float64(pt[1]), Float64(pt[2])))
            catch; end
        end
        nv = length(pts_xy)
        nv < 3 && continue

        if nv == 3
            n_tri += 1
        elseif nv == 4
            n_quad += 1
        else
            n_other += 1
        end

        # Edge lengths of this panel
        edge_ls = Float64[]
        for i in 1:nv
            j = i == nv ? 1 : i + 1
            push!(edge_ls, hypot(pts_xy[j][1] - pts_xy[i][1], pts_xy[j][2] - pts_xy[i][2]))
        end
        filter!(l -> l > 1e-6, edge_ls)
        if !isempty(edge_ls)
            push!(panel_max_spans, maximum(edge_ls))
            mn_e = minimum(edge_ls)
            mn_e > 1e-4 && push!(panel_aspects, maximum(edge_ls) / mn_e)
        end

        # Quad corner orthogonality
        if nv == 4
            angs = Float64[]
            for i in 1:4
                im = i == 1 ? 4 : i - 1
                ip = i == 4 ? 1 : i + 1
                p_im, p_i, p_ip = pts_xy[im], pts_xy[i], pts_xy[ip]
                v1x, v1y = p_im[1] - p_i[1], p_im[2] - p_i[2]
                v2x, v2y = p_ip[1] - p_i[1], p_ip[2] - p_i[2]
                nv1 = hypot(v1x, v1y)
                nv2 = hypot(v2x, v2y)
                (nv1 < 1e-9 || nv2 < 1e-9) && continue
                d = clamp((v1x * v2x + v1y * v2y) / (nv1 * nv2), -1.0, 1.0)
                push!(angs, rad2deg(acos(d)))
            end
            if length(angs) == 4
                devs = [abs(a - 90.0) for a in angs]
                append!(quad_corner_devs, devs)
                push!(quad_max_devs, maximum(devs))
                if sum(devs) / 4 < 6.0
                    n_quad_orthogonal += 1
                end
            end
        end
    end

    n_panels = n_tri + n_quad + n_other
    n_panels == 0 && return nothing

    aspect_stats = if !isempty(panel_aspects)
        μ = sum(panel_aspects) / length(panel_aspects)
        Dict{String, Any}(
            "min"  => round(minimum(panel_aspects); digits=2),
            "max"  => round(maximum(panel_aspects); digits=2),
            "mean" => round(μ; digits=2),
            "n"    => length(panel_aspects),
        )
    else
        nothing
    end

    q_mean_dev = isempty(quad_corner_devs) ? nothing : sum(quad_corner_devs) / length(quad_corner_devs)
    q_max_dev  = isempty(quad_max_devs) ? nothing : maximum(quad_max_devs)

    classification = if n_other > 0 || (n_quad == 0 && n_tri > 0) || n_tri / n_panels > 0.35
        "triangular_mixed_or_complex_panels"
    elseif n_quad > 0 && !isnothing(q_mean_dev) && !isnothing(q_max_dev) &&
           (q_mean_dev > 8.0 || q_max_dev > 15.0)
        "non_orthogonal_or_skewed_quads"
    elseif n_quad > 0 && !isnothing(aspect_stats) && !isnothing(q_mean_dev) &&
           aspect_stats["mean"] > 1.0 &&
           (let cv_a = length(panel_aspects) > 1 ? sqrt(sum((a - sum(panel_aspects)/length(panel_aspects))^2 for a in panel_aspects) / (length(panel_aspects)-1)) / (sum(panel_aspects)/length(panel_aspects)) : 0.0; cv_a > 0.28 end) &&
           q_mean_dev <= 8.0
        "orthogonal_cells_variable_bay_aspect"
    elseif n_quad > 0 && !isnothing(q_mean_dev) && q_mean_dev <= 8.0
        "orthogonal_rectangular_cells"
    else
        "undetermined"
    end

    result = Dict{String, Any}(
        "n_panels"  => n_panels,
        "topology"  => Dict{String, Any}(
            "triangular" => n_tri, "quadrilateral" => n_quad, "other" => n_other,
        ),
        "plan_shape_classification" => classification,
        "panel_edge_aspect_ratio" => aspect_stats,
    )

    if !isempty(panel_max_spans)
        result["panel_max_edge"] = Dict{String,Any}(
            "min" => round(minimum(panel_max_spans); digits=2),
            "max" => round(maximum(panel_max_spans); digits=2),
            "unit" => unit_label,
        )
    end

    if !isnothing(q_mean_dev) || !isnothing(q_max_dev)
        result["quad_corner_deviation_from_90_deg"] = Dict{String, Any}(
            "mean" => round(something(q_mean_dev, 0.0); digits=2),
            "max"  => round(something(q_max_dev, 0.0); digits=2),
        )
    end

    ortho_frac = n_quad > 0 ? n_quad_orthogonal / n_quad : nothing
    if !isnothing(ortho_frac)
        result["fraction_quads_orthogonal"] = round(ortho_frac; digits=3)
    end

    return result
end

"""
Compute column grid analysis: unique XY positions, nearest-neighbour spacing,
edge vs interior classification via convex hull membership.
"""
function _chat_geo_column_grid_analysis(
    verts::AbstractVector, column_edges::AbstractVector, unit_label::String,
)::Union{Nothing, Dict{String, Any}}
    # Collect unique column base XY positions (use the lower-z endpoint of each column edge)
    col_xy = NTuple{2,Float64}[]
    for e in column_edges
        (e isa AbstractVector && length(e) >= 2) || continue
        i, j = try (Int(e[1]), Int(e[2])) catch; continue end
        (1 <= i <= length(verts) && 1 <= j <= length(verts)) || continue
        a = _chat_geo_vertex(verts[i])
        b = _chat_geo_vertex(verts[j])
        (isnothing(a) || isnothing(b)) && continue
        base = a[3] <= b[3] ? a : b
        xy = (round(base[1]; digits=6), round(base[2]; digits=6))
        xy in col_xy || push!(col_xy, xy)
    end
    length(col_xy) < 2 && return nothing

    # Nearest-neighbour distances
    nn_dists = Float64[]
    for (idx, p) in enumerate(col_xy)
        dmin = Inf
        for (jdx, q) in enumerate(col_xy)
            idx == jdx && continue
            d = hypot(q[1] - p[1], q[2] - p[2])
            d < dmin && (dmin = d)
        end
        dmin < Inf && push!(nn_dists, dmin)
    end

    nn_stats = if !isempty(nn_dists)
        Dict{String, Any}(
            "min"  => round(minimum(nn_dists); digits=2),
            "max"  => round(maximum(nn_dists); digits=2),
            "mean" => round(sum(nn_dists) / length(nn_dists); digits=2),
            "unit" => unit_label,
        )
    else
        nothing
    end

    # Grid topology: cluster X and Y coordinates independently
    xs = sort(unique(round(p[1]; digits=3) for p in col_xy))
    ys = sort(unique(round(p[2]; digits=3) for p in col_xy))

    grid_info = Dict{String, Any}(
        "n_unique_positions" => length(col_xy),
        "n_gridlines_x"     => length(xs),
        "n_gridlines_y"     => length(ys),
    )

    if length(xs) >= 2
        x_spacings = Float64[xs[i] - xs[i-1] for i in 2:length(xs)]
        grid_info["gridline_spacings_x"] = round.(x_spacings; digits=2)
        grid_info["gridline_spacings_x_unit"] = unit_label
    end
    if length(ys) >= 2
        y_spacings = Float64[ys[i] - ys[i-1] for i in 2:length(ys)]
        grid_info["gridline_spacings_y"] = round.(y_spacings; digits=2)
        grid_info["gridline_spacings_y_unit"] = unit_label
    end

    # Simple convex hull edge/interior split using 2D cross-product test
    n_edge = 0
    n_interior = 0
    if length(col_xy) >= 3
        hull = _chat_geo_convex_hull_2d(col_xy)
        hull_set = Set(hull)
        for p in col_xy
            if p in hull_set
                n_edge += 1
            else
                n_interior += 1
            end
        end
        grid_info["n_edge_columns"] = n_edge
        grid_info["n_interior_columns"] = n_interior
    end

    result = Dict{String, Any}("grid" => grid_info)
    !isnothing(nn_stats) && (result["nearest_neighbour_spacing"] = nn_stats)
    return result
end

"""Simple 2D convex hull (Andrew's monotone chain). Returns hull points in order."""
function _chat_geo_convex_hull_2d(points::Vector{NTuple{2,Float64}})::Vector{NTuple{2,Float64}}
    pts = sort(points; by=p->(p[1], p[2]))
    n = length(pts)
    n <= 2 && return pts

    _cross(o, a, b) = (a[1]-o[1])*(b[2]-o[2]) - (a[2]-o[2])*(b[1]-o[1])

    lower = NTuple{2,Float64}[]
    for p in pts
        while length(lower) >= 2 && _cross(lower[end-1], lower[end], p) <= 0
            pop!(lower)
        end
        push!(lower, p)
    end
    upper = NTuple{2,Float64}[]
    for p in reverse(pts)
        while length(upper) >= 2 && _cross(upper[end-1], upper[end], p) <= 0
            pop!(upper)
        end
        push!(upper, p)
    end
    pop!(lower)
    pop!(upper)
    return vcat(lower, upper)
end

"""
Compute building envelope: bounding box, footprint dimensions, total height.
"""
function _chat_geo_envelope(verts::AbstractVector, unit_label::String)::Union{Nothing, Dict{String, Any}}
    xs, ys, zs = Float64[], Float64[], Float64[]
    for v in verts
        pt = _chat_geo_vertex(v)
        isnothing(pt) && continue
        push!(xs, pt[1]); push!(ys, pt[2]); push!(zs, pt[3])
    end
    (isempty(xs) || isempty(ys) || isempty(zs)) && return nothing

    lx = maximum(xs) - minimum(xs)
    ly = maximum(ys) - minimum(ys)
    lz = maximum(zs) - minimum(zs)
    ar = ly > 1e-6 ? lx / ly : nothing

    result = Dict{String, Any}(
        "footprint_x" => round(lx; digits=2),
        "footprint_y" => round(ly; digits=2),
        "total_height" => round(lz; digits=2),
        "unit" => unit_label,
    )
    !isnothing(ar) && (result["footprint_aspect_ratio"] = round(ar; digits=2))
    return result
end

"""
Generate structural semantic flags and advisory warnings from pre-design geometry.
Flags are terse tokens for programmatic use; warnings are human-readable sentences
the LLM should surface. Warnings are advisory — the user may dismiss them.
"""
function _chat_geo_flags_and_warnings(
    beam_stats_all, beam_stats_x, beam_stats_y,
    story_heights::Vector{Float64}, story_stats,
    panel_analysis,
    column_analysis,
    envelope,
    to_m::Float64, unit_label::String,
)::Tuple{Vector{String}, Vector{String}}
    flags    = String[]
    warnings = String[]

    # ── Beam span flags ──────────────────────────────────────────────────
    if !isnothing(beam_stats_all)
        max_span_m = beam_stats_all["max"] * to_m
        max_span_u = beam_stats_all["max"]

        if max_span_m > 12.2   # ~40 ft
            push!(flags, "very_long_spans")
            push!(warnings,
                "Max beam span $(round(max_span_u; digits=1)) $unit_label " *
                "($(round(max_span_m * 3.28084; digits=1)) ft) is very long for a flat plate/slab system. " *
                "Typical economical flat plate spans are 20–30 ft. Consider reducing column spacing in Grasshopper, " *
                "or switching to a one-way beam-and-slab or steel framing system.")
        elseif max_span_m > 9.1  # ~30 ft
            push!(flags, "long_spans_over_30ft")
            push!(warnings,
                "Max beam span $(round(max_span_u; digits=1)) $unit_label " *
                "($(round(max_span_m * 3.28084; digits=1)) ft) exceeds 30 ft. " *
                "This is at the upper range for flat plate/slab construction — expect thick slabs, " *
                "high self-weight, and potential deflection governance. Review carefully.")
        end

        min_span_m = beam_stats_all["min"] * to_m
        if min_span_m < 1.5  # ~5 ft — suspiciously short
            push!(flags, "very_short_span")
            push!(warnings,
                "Min beam span $(round(beam_stats_all["min"]; digits=1)) $unit_label " *
                "($(round(min_span_m * 3.28084; digits=1)) ft) is unusually short. " *
                "Verify this is intentional and not a modeling artifact in Grasshopper.")
        end

        if beam_stats_all["cv"] > 0.25
            push!(flags, "diverse_beam_edge_lengths")
        end
    end

    # Directional span note (different X vs Y bay sizes are normal, not irregular)
    if !isnothing(beam_stats_x) && !isnothing(beam_stats_y)
        ratio = max(beam_stats_x["mean"], beam_stats_y["mean"]) /
                max(min(beam_stats_x["mean"], beam_stats_y["mean"]), 1e-6)
        if ratio > 2.0
            push!(flags, "large_x_y_span_ratio")
            push!(warnings,
                "Mean X-direction span ($(beam_stats_x["mean"]) $unit_label) and " *
                "Y-direction span ($(beam_stats_y["mean"]) $unit_label) differ by a factor of " *
                "$(round(ratio; digits=1)). This is not necessarily irregular, but two-way slab " *
                "methods assume roughly comparable spans in both directions. For very elongated " *
                "panels, a one-way slab system may be more appropriate.")
        end
    end

    # ── Story height flags ───────────────────────────────────────────────
    if !isempty(story_heights)
        max_h_m = maximum(story_heights) * to_m
        min_h_m = minimum(story_heights) * to_m

        if max_h_m > 6.0  # ~20 ft
            push!(flags, "tall_story_over_6m")
            push!(warnings,
                "Tallest story height $(round(maximum(story_heights); digits=1)) $unit_label " *
                "($(round(max_h_m * 3.28084; digits=1)) ft) is over 20 ft. " *
                "Long unsupported column lengths increase slenderness effects and may require " *
                "larger column sections. Verify this is intended (e.g. lobby, double-height space).")
        end

        if min_h_m < 2.5  # ~8 ft
            push!(flags, "short_story_under_2_5m")
            push!(warnings,
                "Shortest story height $(round(minimum(story_heights); digits=1)) $unit_label " *
                "($(round(min_h_m * 3.28084; digits=1)) ft) is under 8 ft. " *
                "This may not accommodate slab depth plus MEP clearance. " *
                "Verify in Grasshopper — could be a modeling artifact.")
        end

        if length(story_heights) > 1 &&
           maximum(story_heights) - minimum(story_heights) > 0.15 * maximum(story_heights)
            push!(flags, "variable_story_heights")
        end
    end

    # ── Slab panel flags ─────────────────────────────────────────────────
    if !isnothing(panel_analysis)
        cls = get(panel_analysis, "plan_shape_classification", "")
        if cls == "non_orthogonal_or_skewed_quads"
            push!(flags, "non_orthogonal_slab_panel_corners")
            push!(warnings,
                "Slab panels have non-orthogonal corners (mean deviation from 90° > 8°). " *
                "DDM and EFM assume orthogonal grids — consider using FEA method, " *
                "or adjusting geometry to a rectangular grid in Grasshopper.")
        elseif cls == "triangular_mixed_or_complex_panels"
            push!(flags, "mixed_or_triangulated_slab_panels")
            push!(warnings,
                "Slab panels include triangular or complex polygon shapes. " *
                "This requires FEA analysis — DDM and EFM are not applicable. " *
                "Consider simplifying to rectangular panels if using DDM/EFM.")
        elseif cls == "orthogonal_cells_variable_bay_aspect"
            push!(flags, "orthogonal_grid_different_bay_sizes_in_plan")
        end

        ar = get(panel_analysis, "panel_edge_aspect_ratio", nothing)
        if !isnothing(ar)
            max_ar = get(ar, "max", 1.0)
            if max_ar > 2.0
                push!(flags, "high_panel_aspect_ratio")
                if max_ar > 3.0
                    push!(warnings,
                        "Panel aspect ratio up to $(round(max_ar; digits=1)):1. " *
                        "ACI 318-11 §13.6.1.2 limits DDM to panels with long/short ≤ 2 " *
                        "(EFM is less restrictive but still assumes roughly rectangular bays). " *
                        "Consider using FEA, or adjusting column spacing to reduce aspect ratio.")
                end
            end
        end
    end

    # ── Column grid flags ────────────────────────────────────────────────
    if !isnothing(column_analysis)
        nn = get(column_analysis, "nearest_neighbour_spacing", nothing)
        if !isnothing(nn)
            max_nn_m = nn["max"] * to_m
            min_nn_m = nn["min"] * to_m
            if max_nn_m > 15.0  # ~49 ft
                push!(flags, "wide_column_spacing")
                push!(warnings,
                    "Max nearest-neighbour column spacing is $(nn["max"]) $unit_label " *
                    "($(round(max_nn_m * 3.28084; digits=1)) ft). Some columns are very widely spaced — " *
                    "verify the column grid is complete in Grasshopper.")
            end
            if min_nn_m < 1.5  # ~5 ft — columns suspiciously close
                push!(flags, "very_close_columns")
                push!(warnings,
                    "Min nearest-neighbour column spacing is $(nn["min"]) $unit_label " *
                    "($(round(min_nn_m * 3.28084; digits=1)) ft). Columns may be duplicated or " *
                    "placed too close together — verify in Grasshopper.")
            end
        end
    end

    # ── Envelope sanity ──────────────────────────────────────────────────
    if !isnothing(envelope)
        h_m = get(envelope, "total_height", 0.0) * to_m
        if h_m > 60.0
            push!(flags, "tall_building")
            push!(warnings,
                "Building total height $(envelope["total_height"]) $unit_label " *
                "($(round(h_m * 3.28084; digits=0)) ft) is significant. " *
                "This solver handles gravity only — lateral/seismic analysis is outside scope. " *
                "Ensure lateral system is designed separately.")
        end
    end

    # ── Geometry sanity checks ───────────────────────────────────────────
    # Zero-length edges already filtered by length calcs; duplicate vertices
    # are detectable but expensive for large models — skip for now.

    return (flags, warnings)
end

"""
Enriched geometry statistics computed from raw `building_geometry` JSON.
Provides the LLM with concrete span, height, panel, and column grid data
at chat-opening time — before any POST /design.
"""
function _chat_structured_geometry_stats(g::Dict{String, Any})::Dict{String, Any}
    units_str  = string(get(g, "units", ""))
    to_m       = _chat_geo_unit_to_m(units_str)
    unit_label = _chat_geo_unit_label(units_str)
    verts      = get(g, "vertices", [])
    nv         = verts isa AbstractVector ? length(verts) : 0
    eg         = get(g, "edges", nothing)

    beam_edges   = Any[]
    column_edges = Any[]
    brace_edges  = Any[]
    if eg isa AbstractDict
        b = get(eg, "beams", []);   b isa AbstractVector && (beam_edges = b)
        c = get(eg, "columns", []); c isa AbstractVector && (column_edges = c)
        z = get(eg, "braces", []);  z isa AbstractVector && (brace_edges = z)
    end

    sup = get(g, "supports", [])
    ns  = sup isa AbstractVector ? length(sup) : 0
    sz  = get(g, "stories_z", [])
    nzs = sz isa AbstractVector ? length(sz) : 0

    nfaces = 0
    faces_dict = get(g, "faces", nothing)
    try
        if faces_dict isa AbstractDict
            for (_, polys) in pairs(faces_dict)
                polys isa AbstractVector && (nfaces += length(polys))
            end
        end
    catch; end

    # ── Counts (always present) ──────────────────────────────────────────
    result = Dict{String, Any}(
        "units"                => units_str,
        "n_vertices"           => nv,
        "n_beam_edges"         => length(beam_edges),
        "n_column_edges"       => length(column_edges),
        "n_brace_edges"        => length(brace_edges),
        "n_supports"           => ns,
        "n_stories_z_entries"  => nzs,
        "n_face_polygon_loops" => nfaces,
    )

    # ── Beam span statistics with directional breakdown ──────────────────
    beam_all, beam_x, beam_y = _chat_geo_beam_span_stats(verts, beam_edges, unit_label)
    if !isnothing(beam_all)
        result["beam_spans"] = Dict{String, Any}("all" => beam_all)
        !isnothing(beam_x) && (result["beam_spans"]["x_direction"] = beam_x)
        !isnothing(beam_y) && (result["beam_spans"]["y_direction"] = beam_y)
        result["beam_spans"]["note"] =
            "all mixes X- and Y-oriented members. Different orthogonal bay sizes inflate CV — " *
            "that is normal geometry, not plan irregularity. Use x_direction/y_direction for per-axis spans."
    end

    # ── Column height statistics ─────────────────────────────────────────
    col_lengths = _chat_geo_edge_lengths(verts, column_edges)
    if !isempty(col_lengths)
        result["column_heights"] = Dict{String, Any}(
            "min"  => round(minimum(col_lengths); digits=2),
            "max"  => round(maximum(col_lengths); digits=2),
            "mean" => round(sum(col_lengths) / length(col_lengths); digits=2),
            "n"    => length(col_lengths),
            "unit" => unit_label,
        )
    end

    # ── Story analysis ───────────────────────────────────────────────────
    story_heights_raw, story_stats = _chat_geo_story_analysis(
        sz isa AbstractVector ? sz : [], unit_label,
    )
    if !isnothing(story_stats)
        story_stats["source"] = "stories_z"
        result["stories"] = story_stats
    else
        # Fallback: infer story elevations from unique vertex Z levels when
        # stories_z is omitted by the client payload.
        vz = Float64[]
        for v in verts
            pt = _chat_geo_vertex(v)
            isnothing(pt) && continue
            push!(vz, pt[3])
        end
        if !isempty(vz)
            uniqz = sort(unique(round.(vz; digits=6)))
            result["n_unique_vertex_z"] = length(uniqz)
            inf_heights, inf_stats = _chat_geo_story_analysis(uniqz, unit_label)
            if !isnothing(inf_stats)
                inf_stats["source"] = "inferred_from_vertex_z"
                result["stories"] = inf_stats
                story_heights_raw = inf_heights
            end
        end
    end

    # ── Slab panel analysis ──────────────────────────────────────────────
    panel_analysis = _chat_geo_panel_analysis(faces_dict, unit_label)
    !isnothing(panel_analysis) && (result["slab_panels"] = panel_analysis)

    # ── Column grid analysis ─────────────────────────────────────────────
    col_grid = _chat_geo_column_grid_analysis(verts, column_edges, unit_label)
    !isnothing(col_grid) && (result["column_grid"] = col_grid)

    # ── Building envelope ────────────────────────────────────────────────
    envelope = _chat_geo_envelope(verts, unit_label)
    !isnothing(envelope) && (result["envelope"] = envelope)

    # ── Flags and warnings ───────────────────────────────────────────────
    flags, geo_warnings = _chat_geo_flags_and_warnings(
        beam_all, beam_x, beam_y,
        story_heights_raw, story_stats,
        panel_analysis, col_grid, envelope,
        to_m, unit_label,
    )
    !isempty(flags)       && (result["structural_flags"] = flags)
    !isempty(geo_warnings) && (result["warnings"] = geo_warnings)

    # ── Geometry data coverage (helps LLM avoid vague "missing detail" text) ─
    missing = String[]
    !haskey(result, "beam_spans") && push!(missing, "beam_spans_from_edges.beams")
    !haskey(result, "stories") && push!(missing, "story_heights_from_stories_z_or_vertex_z")
    !haskey(result, "column_heights") && push!(missing, "column_heights_from_edges.columns")
    !haskey(result, "slab_panels") && push!(missing, "slab_panel_shapes_from_faces.floor_or_roof")
    result["data_coverage"] = Dict{String, Any}(
        "missing_items" => missing,
        "has_all_primary_metrics" => isempty(missing),
    )
    result["unit_to_m"] = to_m

    return result
end

"""
Convert geometry stats dict into a concise plaintext digest that the LLM reads before the JSON.
Every critical number appears as a direct sentence — no nesting, no parsing required.
"""
function _geometry_digest_plaintext(stats::Dict{String, Any})::String
    lines = String["── GEOMETRY DIGEST (MANDATORY — quote these numbers directly, NEVER say they are missing) ──"]

    unit = get(stats, "units", "")
    nc = get(stats, "n_column_edges", 0)
    nb = get(stats, "n_beam_edges", 0)
    ns = get(stats, "n_supports", 0)
    nf = get(stats, "n_face_polygon_loops", 0)
    push!(lines, "Elements: $nb beams, $nc columns, $ns supports, $nf slab faces")

    # Beam spans
    bs = get(stats, "beam_spans", nothing)
    if !isnothing(bs)
        all_s = get(bs, "all", nothing)
        if !isnothing(all_s)
            u = get(all_s, "unit", unit)
            push!(lines, "Beam spans (all): min=$(all_s["min"]) $u, max=$(all_s["max"]) $u, mean=$(all_s["mean"]) $u, n=$(all_s["n"])")
        end
        xd = get(bs, "x_direction", nothing)
        if !isnothing(xd)
            u = get(xd, "unit", unit)
            push!(lines, "  X-direction: min=$(xd["min"]) $u, max=$(xd["max"]) $u, mean=$(xd["mean"]) $u")
        end
        yd = get(bs, "y_direction", nothing)
        if !isnothing(yd)
            u = get(yd, "unit", unit)
            push!(lines, "  Y-direction: min=$(yd["min"]) $u, max=$(yd["max"]) $u, mean=$(yd["mean"]) $u")
        end
    else
        push!(lines, "Beam spans: unavailable (no valid edges.beams payload).")
    end

    # Column heights
    ch = get(stats, "column_heights", nothing)
    if !isnothing(ch)
        u = get(ch, "unit", unit)
        push!(lines, "Column heights: min=$(ch["min"]) $u, max=$(ch["max"]) $u, mean=$(ch["mean"]) $u, n=$(ch["n"])")
    end

    # Stories
    st = get(stats, "stories", nothing)
    if !isnothing(st)
        n = get(st, "n_stories", nothing)
        !isnothing(n) && push!(lines, "Stories: $n")
        sh = get(st, "heights", nothing)
        if !isnothing(sh) && sh isa AbstractVector && !isempty(sh)
            u = get(st, "unit", unit)
            push!(lines, "Story heights: $(join(sh, ", ")) $u")
        end
        src = get(st, "source", "")
        !isempty(src) && push!(lines, "Story-height source: $src")
    else
        push!(lines, "Stories: unavailable (neither stories_z nor inferable vertex Z levels).")
    end

    # Column grid
    cg = get(stats, "column_grid", nothing)
    if !isnothing(cg)
        n_unique = get(cg, "n_unique_positions", nothing)
        !isnothing(n_unique) && push!(lines, "Column grid: $n_unique unique positions")
        nn = get(cg, "nearest_neighbour_spacing", nothing)
        if !isnothing(nn)
            u = get(nn, "unit", unit)
            push!(lines, "  Nearest-neighbour spacing: min=$(nn["min"]) $u, max=$(nn["max"]) $u")
        end
        grid = get(cg, "grid", nothing)
        if !isnothing(grid)
            n_edge = get(grid, "n_edge_columns", nothing)
            n_int  = get(grid, "n_interior_columns", nothing)
            if !isnothing(n_edge) && !isnothing(n_int)
                push!(lines, "  Edge columns: $n_edge, Interior columns: $n_int")
            end
        end
    end

    # Slab panels
    sp = get(stats, "slab_panels", nothing)
    if !isnothing(sp)
        cls = get(sp, "plan_shape_classification", "")
        n_panels = get(sp, "n_panels", 0)
        push!(lines, "Slab panels: $n_panels panels, classification: $cls")
        ar = get(sp, "panel_edge_aspect_ratio", nothing)
        if !isnothing(ar)
            push!(lines, "  Aspect ratio: min=$(get(ar, "min", "?"))  max=$(get(ar, "max", "?"))  mean=$(get(ar, "mean", "?"))")
        end
    else
        push!(lines, "Slab panels: unavailable (faces.floor/roof not provided or empty).")
    end

    # Envelope
    env = get(stats, "envelope", nothing)
    if !isnothing(env)
        u = get(env, "unit", unit)
        fp_x = get(env, "footprint_x", nothing)
        fp_y = get(env, "footprint_y", nothing)
        h = get(env, "total_height", nothing)
        if !isnothing(fp_x) && !isnothing(fp_y)
            push!(lines, "Footprint: $fp_x × $fp_y $u")
        end
        !isnothing(h) && push!(lines, "Total height: $h $u")
    end

    # Economical ranges from GEOMETRIC_SENSITIVITY_MAP
    span_ranges = get(get(GEOMETRIC_SENSITIVITY_MAP, "span_length", Dict()), "typical_economical_ranges", nothing)
    story_ranges = get(get(GEOMETRIC_SENSITIVITY_MAP, "story_height", Dict()), "typical_economical_ranges", nothing)
    if !isnothing(span_ranges)
        bs_all = get(get(stats, "beam_spans", Dict()), "all", nothing)
        if !isnothing(bs_all)
            max_span_m = get(bs_all, "max", 0.0)
            # Convert to meters if needed for comparison
            to_m = get(stats, "unit_to_m", 1.0)
            max_m = max_span_m * to_m
            if max_m > 9.1
                push!(lines, "⚡ Economical span ranges: " * join(["$k: $v" for (k, v) in span_ranges], "; "))
            end
        end
    end
    if !isnothing(story_ranges)
        story_data = get(stats, "stories", nothing)
        if !isnothing(story_data)
            sh = get(story_data, "heights", nothing)
            if !isnothing(sh) && sh isa AbstractVector && !isempty(sh)
                to_m = get(stats, "unit_to_m", 1.0)
                max_h = maximum(sh) * to_m
                if max_h > 4.5
                    push!(lines, "⚡ Economical story height ranges: " * join(["$k: $v" for (k, v) in story_ranges], "; "))
                end
            end
        end
    end

    # Flags
    flags = get(stats, "structural_flags", nothing)
    if !isnothing(flags) && !isempty(flags)
        push!(lines, "Structural flags: $(join(flags, ", "))")
    end

    cov = get(stats, "data_coverage", nothing)
    if cov isa AbstractDict
        missing = get(cov, "missing_items", String[])
        if missing isa AbstractVector && !isempty(missing)
            push!(lines, "Data gaps: $(join(string.(missing), ", ")).")
        else
            push!(lines, "Data coverage: complete for primary geometry metrics.")
        end
    end

    push!(lines, "── END DIGEST ──")
    return join(lines, "\n") * "\n"
end

"""
Append structured design geometry JSON and/or the optional human Summary line to the system prompt.

Prefers a **structure-based digest** (from `BuildingStructure` → `initialize!`) which provides
real cell spans, slab panels, member lengths, column tributary areas, grid topology, and span variance analysis.
Falls back to the raw-JSON `_chat_structured_geometry_stats` approach if initialization fails.
"""
function _append_chat_building_geometry_sections!(
    parts::Vector,
    geometry_summary::String,
    structured::Union{Nothing, Dict{String, Any}},
)
    if !isnothing(structured)
        # Try the structure-based path first (real structural data)
        struc_digest = _chat_get_structure_digest(structured)

        if !isnothing(struc_digest)
            @info "Chat geometry: structure-based digest OK" n_cells=get(struc_digest, "n_cells", 0) n_beams=get(struc_digest, "n_beams", 0)
            push!(parts, "\n\nBUILDING GEOMETRY (structure-initialized — cells, members, tributaries computed):\n")
            push!(parts, _structure_digest_plaintext(struc_digest))

            warnings = get(struc_digest, "warnings", nothing)
            if !isnothing(warnings) && !isempty(warnings)
                push!(parts, "\n⚠ GEOMETRY WARNINGS:\n")
                for w in warnings
                    push!(parts, "  • ", w, "\n")
                end
            end

            push!(parts, "\nFull structure analysis JSON: ", JSON3.write(struc_digest), "\n")
        else
            @warn "Chat geometry: structure-based digest FAILED — using raw JSON fallback"
            stats = _chat_structured_geometry_stats(structured)
            json_txt = JSON3.write(structured)
            push!(parts, "\n\nBUILDING GEOMETRY (raw JSON analysis — structure init failed, using geometric approximation):\n")
            push!(parts, _geometry_digest_plaintext(stats))

            if haskey(stats, "warnings") && !isempty(stats["warnings"])
                push!(parts, "\n⚠ GEOMETRY WARNINGS (address these in your opening analysis — they are advisory, not blocking):\n")
                for w in stats["warnings"]
                    push!(parts, "  • ", w, "\n")
                end
            end

            push!(parts, "\nFull geometry analysis JSON (detail behind the digest above): ", JSON3.write(stats), "\n")
            if length(json_txt) > _MAX_CHAT_BUILDING_GEOMETRY_JSON_CHARS
                push!(parts, "Full geometry JSON omitted (length ", string(length(json_txt)), " chars > limit ", string(_MAX_CHAT_BUILDING_GEOMETRY_JSON_CHARS), "). Use the counts above, the narrative summary if present, or run Design so the server caches the structure.\n")
            else
                push!(parts, "Full geometry JSON:\n", json_txt, "\n")
            end
        end
    end
    if !isempty(strip(geometry_summary))
        label = isnothing(structured) ? "BUILDING GEOMETRY" : "BUILDING GEOMETRY (narrative summary — same model as structured block above when both are present)"
        push!(parts, "\n\n", label, ":\n", geometry_summary)
    end
    return nothing
end

"""
    _api_input_geometry_only_from_chat_dict(g) -> APIInput

Build an `APIInput` from chat `building_geometry` dict using default `params`, for hashing only.
Matches the geometry slice of POST /design / Grasshopper `BuildingGeometry.ToJson()`.
"""
function _api_input_geometry_only_from_chat_dict(g::Dict{String, Any})::APIInput
    edges_in = get(g, "edges", nothing)
    edges_blob = if edges_in isa AbstractDict
        Dict{String, Any}(
            "beams"   => collect(Any, get(edges_in, "beams", [])),
            "columns" => collect(Any, get(edges_in, "columns", [])),
            "braces"  => collect(Any, get(edges_in, "braces", [])),
        )
    else
        Dict{String, Any}("beams" => Any[], "columns" => Any[], "braces" => Any[])
    end
    faces_in = get(g, "faces", nothing)
    faces_blob = if faces_in isa AbstractDict
        Dict{String, Any}(string(k) => v for (k, v) in pairs(faces_in))
    else
        Dict{String, Any}()
    end
    blob = Dict{String, Any}(
        "units"      => string(get(g, "units", "feet")),
        "vertices"   => get(g, "vertices", Any[]),
        "edges"      => edges_blob,
        "supports"   => get(g, "supports", Any[]),
        "stories_z"  => get(g, "stories_z", Any[]),
        "faces"      => faces_blob,
        "params"     => Dict{String, Any}(),
    )
    return JSON3.read(JSON3.write(blob), APIInput)
end

"""SHA-256 geometry hash for chat `building_geometry`, or `nothing` if parsing fails."""
function _try_geometry_hash_from_chat_dict(g::Dict{String, Any})::Union{Nothing, String}
    try
        return compute_geometry_hash(_api_input_geometry_only_from_chat_dict(g))
    catch
        return nothing
    end
end

"""
Resolve which geometry fingerprint to compare to the server: prefer hash derived from structured
`building_geometry` when available; otherwise `client_geometry_hash`.
Returns `(resolved_hash_or_nothing, source, derived_or_nothing)` where `derived_or_nothing` is
the hash from structured JSON when that was attempted (even if resolution fell back to client).
"""
function _chat_geometry_resolution(
    structured::Union{Nothing, Dict{String, Any}},
    client_geometry_hash::String,
)::Tuple{Union{Nothing, String}, String, Union{Nothing, String}}
    derived::Union{Nothing, String} = nothing
    if !isnothing(structured)
        derived = _try_geometry_hash_from_chat_dict(structured)
        if !isnothing(derived) && !isempty(derived)
            return (derived, "building_geometry", derived)
        end
    end
    ch = strip(client_geometry_hash)
    !isempty(ch) && return (ch, "client_geometry_hash", derived)
    return (nothing, "none", derived)
end

"""Read the server-cached geometry hash under lock."""
function _server_geometry_hash()::String
    with_cache_read(c -> c.geometry_hash, DESIGN_CACHE)
end

"""True when chat-resolved geometry (body or client hash) disagrees with the server's last POST /design hash."""
function _geometry_prompt_stale(
    resolved::Union{Nothing, String},
    client_geometry_hash::String,
)::Bool
    srv = strip(_server_geometry_hash())
    isempty(srv) && return false
    if !isnothing(resolved) && !isempty(resolved)
        return resolved != srv
    end
    return _geometry_stale_for_client(client_geometry_hash)
end

"""True when client hash is present and differs from the server's cached POST /design geometry."""
function _geometry_stale_for_client(client_geometry_hash::String)::Bool
    cli = strip(client_geometry_hash)
    srv = strip(_server_geometry_hash())
    !isempty(cli) && !isempty(srv) && cli != srv
end

"""Merge geometry alignment fields into tool JSON for the LLM. Uses resolved hash when available."""
function _attach_geometry_alignment!(result::Dict{String, Any}, args::Dict{String, Any})
    cli = strip(string(get(args, "client_geometry_hash", "")))
    resolved = lock(_CHAT_STRUCTURE_CACHE.lock) do
        h = _CHAT_STRUCTURE_CACHE.geometry_hash
        isempty(h) ? "" : h
    end
    effective = !isempty(resolved) ? resolved : cli
    isempty(effective) && return result
    srv = strip(_server_geometry_hash())
    result["client_geometry_hash"] = cli
    result["resolved_geometry_hash"] = effective
    result["server_cached_geometry_hash"] = srv
    if isempty(srv)
        result["geometry_alignment"] = "unknown"
    elseif effective == srv
        result["geometry_alignment"] = "aligned"
    else
        history = get_design_history_entries()
        client_is_old = any(strip(e.geometry_hash) == effective for e in history)
        result["geometry_alignment"] = client_is_old ? "client_behind_server" : "server_behind_client"
    end
    result["geometry_stale"] = result["geometry_alignment"] == "server_behind_client"
    return result
end

