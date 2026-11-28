# =============================================================================
# Solver Trace Contracts (manual registry; functions are documented)
# =============================================================================
#
# Note: StructuralSynthesizer re-exports StructuralSizer, so we register into
# StructuralSizer.TRACE_REGISTRY here for audit tooling.

StructuralSizer.TRACE_REGISTRY[(:size_foundations!, :workflow)] =
    StructuralSizer.TracedFunctionMeta(:size_foundations!, :workflow,
                                       [:enter, :exit, :decision, :failure], nothing,
                                       @__FILE__, @__LINE__)

StructuralSizer.TRACE_REGISTRY[(:size_foundations_grouped!, :workflow)] =
    StructuralSizer.TracedFunctionMeta(:size_foundations_grouped!, :workflow,
                                       [:enter, :exit, :decision, :failure], nothing,
                                       @__FILE__, @__LINE__)

StructuralSizer.TRACE_REGISTRY[(:_resolve_strategy, :workflow)] =
    StructuralSizer.TracedFunctionMeta(:_resolve_strategy, :workflow,
                                       [:decision, :failure], nothing,
                                       @__FILE__, @__LINE__)

StructuralSizer.TRACE_REGISTRY[(:_auto_merge_to_strips!, :workflow)] =
    StructuralSizer.TracedFunctionMeta(:_auto_merge_to_strips!, :workflow,
                                       [:decision, :failure], nothing,
                                       @__FILE__, @__LINE__)

StructuralSizer.TRACE_REGISTRY[(:_size_foundation!, :workflow)] =
    StructuralSizer.TracedFunctionMeta(:_size_foundation!, :workflow,
                                       [:enter, :exit, :failure], nothing,
                                       @__FILE__, @__LINE__)

# =============================================================================
# Strategy-Aware Foundation Pipeline
# =============================================================================

"""
    _resolve_strategy(struc, demands, soil, opts) → Symbol

Determine foundation strategy: `:spread`, `:strip`, or `:mat`.

# Strategy values
- `:auto` — Coverage-based: spread (<30%), strip (30–50%), mat (>threshold).
- `:auto_strip_spread` — Same as auto but never picks mat; high coverage → strip.
- `:all_spread`, `:all_strip`, `:mat` — Explicit override.
"""
function _resolve_strategy(struc, demands, soil, opts;
                           tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing)
    strat = opts.strategy
    strat == :all_spread && return :spread
    strat == :all_strip  && return :strip
    strat == :mat        && return :mat
    strat != :auto && strat != :auto_strip_spread && return strat

    try
        # Auto: estimate required spread footing area per support
        qa = soil.qa
        total_req = 0.0u"m^2"
        for d in demands
            # Signed Ps: skip tension when estimating compression-footing coverage.
            d.Ps <= zero(d.Ps) && continue
            A_req = d.Ps / qa
            total_req += A_req
        end

        # Building footprint from skeleton bounding box
        skel = struc.skeleton
        verts = skel.vertices
        isempty(verts) && return :spread
        xs = [ustrip(u"m", Meshes.coords(v).x) for v in verts]
        ys = [ustrip(u"m", Meshes.coords(v).y) for v in verts]
        footprint_m2 = (maximum(xs) - minimum(xs)) * (maximum(ys) - minimum(ys))
        footprint_m2 < 1.0 && return :spread

        coverage = ustrip(u"m^2", total_req) / footprint_m2

        result = if coverage > opts.mat_coverage_threshold
            :mat
        elseif coverage > 0.30
            :strip
        else
            :spread
        end

        emitted = result
        # auto_strip_spread: never pick mat; high coverage → strip
        if strat == :auto_strip_spread && result == :mat
            emitted = :strip
        end

        StructuralSizer.emit!(tc, :workflow, "_resolve_strategy", "", :decision;
                              opts_strategy=string(strat),
                              chosen_strategy=string(emitted),
                              coverage=Float64(coverage),
                              mat_threshold=Float64(opts.mat_coverage_threshold),
                              strip_threshold=0.30,
                              n_supports=length(demands),
                              qa_kPa=Float64(ustrip(u"kPa", qa)))

        return emitted
    catch e
        StructuralSizer.emit!(tc, :workflow, "_resolve_strategy", "", :failure;
                              error=string(typeof(e)),
                              message=sprint(showerror, e))
        rethrow()
    end
end

"""
    _strip_groupings_from_orthogonal_grid(struc) → Vector{Vector{Int}}

Use DDM-style column-line detection to group supports into strips.
Uses governing spans from cells (primary/secondary axis) and clusters supports
by projection onto the perpendicular axis within 10% of primary span (ACI 318-11 §13.6.1.4).
Returns empty if no cells or geometry, or if the structure is not orthogonal.

Strips run along the primary (short) span direction — each column line = one strip.
"""
function _strip_groupings_from_orthogonal_grid(struc::BuildingStructure)
    isempty(struc.supports) && return Vector{Int}[]
    isempty(struc.cells) && return Vector{Int}[]
    isnothing(struc.skeleton.geometry) && return Vector{Int}[]

    skel = struc.skeleton
    vc = skel.geometry.vertex_coords

    # Governing spans from cells (same source as DDM)
    cell_spans = [c.spans for c in struc.cells]
    spans_gov = StructuralSizer.governing_spans(cell_spans)
    span_axis = spans_gov.axis
    l1 = spans_gov.primary

    ax_len = hypot(span_axis...)
    ax_len < 1e-9 && return Vector{Int}[]
    span_axis = (span_axis[1] / ax_len, span_axis[2] / ax_len)
    perp_axis = (-span_axis[2], span_axis[1])  # 90° CCW

    l1_m = ustrip(u"m", l1)
    cluster_tol = 0.10 * l1_m  # ACI 318-11 §13.6.1.4: columns within 10% of span = same column line

    # Project each support onto the perpendicular axis (DDM column-line logic)
    perp_projs = [let vi = struc.supports[i].vertex_idx
        vc[vi, 1] * perp_axis[1] + vc[vi, 2] * perp_axis[2]
    end for i in 1:length(struc.supports)]

    # Span-axis projections (for ordering within each strip)
    span_projs = [let vi = struc.supports[i].vertex_idx
        vc[vi, 1] * span_axis[1] + vc[vi, 2] * span_axis[2]
    end for i in 1:length(struc.supports)]

    # Cluster supports by perpendicular projection (same column line)
    assigned = falses(length(struc.supports))
    groups = Vector{Int}[]
    sorted_order = sortperm(perp_projs)

    for idx in sorted_order
        assigned[idx] && continue
        group = [idx]
        assigned[idx] = true
        for jdx in sorted_order
            assigned[jdx] && continue
            if abs(perp_projs[jdx] - perp_projs[idx]) <= cluster_tol
                push!(group, jdx)
                assigned[jdx] = true
            end
        end
        sort!(group; by=i -> span_projs[i])  # Order along strip for design
        push!(groups, group)
    end

    @debug "Strip groupings" span_axis perp_axis cluster_tol n_groups=length(groups) groups
    for (gi, g) in enumerate(groups)
        perps = [perp_projs[i] for i in g]
        spans = [span_projs[i] for i in g]
        @debug "  Strip group $gi" support_indices=g perp_projs=perps span_projs=spans
    end

    return groups
end

"""
    _auto_merge_to_strips!(struc, demands, soil, opts) → struc

Inspect spread footings for adjacency and merge overlapping pairs into
strip footings. After this call, `struc.foundations` may contain a mix of
`:spread` (single support) and `:strip` (multiple supports).

Merge criterion: gap between footing edges < `merge_gap_factor × D_max`.
"""
function _auto_merge_to_strips!(struc, demands, soil, opts;
                                tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing)
    N = length(struc.foundations)
    N < 2 && return struc

    qa = soil.qa
    skel = struc.skeleton

    # Tentative spread footing widths (B ≈ √(Ps/qa)) and a default D
    spreads = Vector{NamedTuple{(:idx, :x, :y, :B, :D), Tuple{Int, Float64, Float64, Float64, Float64}}}()
    for (fi, fnd) in enumerate(struc.foundations)
        length(fnd.support_indices) != 1 && continue
        si = fnd.support_indices[1]
        d = demands[si]
        # Include tension supports so a mixed-sign neighbor can merge into a
        # strip (ACI 318-11 §15.10.1 / §15.8.1.2, corpus: aci-318-11,
        # pages 277 / 275). Tentative B uses compression Ps; tension columns
        # get a minimum width so they still participate in adjacency.
        Ps_compr = max(d.Ps, zero(d.Ps))
        A_m2 = ustrip(u"m^2", Ps_compr / qa)
        B = max(sqrt(max(A_m2, 0.0)), 0.3)
        D = max(B * 0.15, 0.3)   # rough depth ≈ 15% of B, min 0.3 m
        v = skel.vertices[struc.supports[si].vertex_idx]
        c = Meshes.coords(v)
        push!(spreads, (idx=fi, x=ustrip(u"m", c.x), y=ustrip(u"m", c.y), B=B, D=D))
    end

    merge_factor = opts.strip_params.merge_gap_factor
    merged = Set{Int}()   # foundation indices already merged
    new_groups = Vector{Vector{Int}}()   # groups of support indices to merge

    # Greedy pairwise merge (column-line detection)
    for i in eachindex(spreads)
        spreads[i].idx in merged && continue
        group_support = [struc.foundations[spreads[i].idx].support_indices[1]]
        group_fnd_idx = [spreads[i].idx]

        for j in (i+1):length(spreads)
            spreads[j].idx in merged && continue

            dx = abs(spreads[i].x - spreads[j].x)
            dy = abs(spreads[i].y - spreads[j].y)
            dist = sqrt(dx^2 + dy^2)
            half_Bi = spreads[i].B / 2
            half_Bj = spreads[j].B / 2
            gap = dist - half_Bi - half_Bj
            D_max = max(spreads[i].D, spreads[j].D)

            # Merge if footings would nearly touch / overlap
            if gap < merge_factor * D_max
                push!(group_support, struc.foundations[spreads[j].idx].support_indices[1])
                push!(group_fnd_idx, spreads[j].idx)
                push!(merged, spreads[j].idx)
            end
        end

        if length(group_support) > 1
            push!(merged, spreads[i].idx)
            push!(new_groups, group_support)
        end
    end

    isempty(new_groups) && return struc

    # Rebuild foundations: keep non-merged as :spread, add merged as :strip
    placeholder = _placeholder_foundation_result(typeof(struc).parameters[1])
    new_foundations = Foundation[]

    for (fi, fnd) in enumerate(struc.foundations)
        fi in merged && continue
        push!(new_foundations, fnd)
    end
    for supp_group in new_groups
        push!(new_foundations,
            Foundation(supp_group, placeholder; foundation_type=:strip))
    end

    empty!(struc.foundations)
    append!(struc.foundations, new_foundations)

    n_strips = length(new_groups)
    n_spreads = count(f -> f.foundation_type == :spread, struc.foundations)
    @info "Auto-merge: $n_strips strips + $n_spreads spreads (from $(N) original)"

    StructuralSizer.emit!(tc, :workflow, "_auto_merge_to_strips!", "", :decision;
                          n_original=N,
                          n_strips=n_strips,
                          n_spreads=n_spreads,
                          merge_gap_factor=Float64(opts.strip_params.merge_gap_factor))

    return struc
end

"""
    size_foundations!(struc; soil, opts, demands=nothing, group_tolerance=0.15, verbose=true)

Strategy-aware foundation sizing pipeline:

1. Compute demands from support reactions
2. Determine strategy (`:spread`, `:strip`, `:mat`) from coverage or user override
3. For `:mat` → one mat foundation covering all supports
4. For `:strip`:
   - Infer orthogonal grid from support positions (primary/secondary axes, spacing)
   - If orthogonal: strips along axis with shorter spacing (one strip per row/column)
   - If not orthogonal: fall back to spread footings + merge foundations too close
5. For `:spread` → group by reaction similarity, size one per group
6. Size all foundations via ACI or IS dispatch
"""
function size_foundations!(
    struc::BuildingStructure;
    soil::StructuralSizer.Soil,
    opts::StructuralSizer.FoundationOptions = StructuralSizer.FoundationOptions(),
    demands::Union{Nothing, Vector{StructuralSizer.FoundationDemand}} = nothing,
    group_tolerance::Float64 = 0.15,
    verbose::Bool = true,
    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
    # Legacy IS kwargs
    concrete::StructuralSizer.Concrete = StructuralSizer.NWC_4000,
    rebar::StructuralSizer.Metal = StructuralSizer.Rebar_60,
    pier_width = 0.3u"m",
    kwargs...
)
    try
        demands = isnothing(demands) ? support_demands(struc) : demands
        wall_fnds, wall_skip = design_grade_wall_foundations(struc, demands, soil, opts)
        StructuralSizer.emit!(tc, :workflow, "size_foundations!", "", :enter;
                              n_supports=length(struc.supports),
                              n_foundations=length(struc.foundations),
                              opts_strategy=string(opts.strategy),
                              code=string(opts.code))

        # Keep user groupings (e.g. [[1, 2]]) — initialize_foundations!() would
        # wipe them. ACI 318-11 §15.10.1 (corpus: aci-318-11, page 277).
        if _explicit_support_groupings(struc)
            StructuralSizer.emit!(tc, :workflow, "size_foundations!", "", :decision;
                                  preserved_groupings=true,
                                  n_foundations=length(struc.foundations))
            verbose && @info "Preserving explicit foundation groupings" n_foundations=length(struc.foundations)
            isempty(struc.foundation_groups) && build_foundation_groups!(struc)
            _drop_wall_supports!(struc, wall_skip)
            isempty(struc.foundations) || size_foundations_grouped!(struc; soil=soil, opts=opts, demands=demands,
                                      tc=tc,
                                      concrete=concrete, rebar=rebar, pier_width=pier_width, kwargs...)
            append!(struc.foundations, wall_fnds)
            StructuralSizer.emit!(tc, :workflow, "size_foundations!", "", :exit;
                                  n_foundations=length(struc.foundations),
                                  n_groups=length(struc.foundation_groups))
            return struc
        end

        strategy = _resolve_strategy(struc, demands, soil, opts; tc=tc)
        verbose && @info "Foundation strategy: $strategy" opts_strategy=opts.strategy

        StructuralSizer.emit!(tc, :workflow, "size_foundations!", "", :decision;
                              chosen_strategy=string(strategy),
                              group_tolerance=group_tolerance)

        if strategy == :mat
            # Single mat foundation covering the supports a grade wall did not take.
            all_supp = [i for i in eachindex(struc.supports) if i ∉ wall_skip]
            empty!(struc.foundations)
            if !isempty(all_supp)
                placeholder = _placeholder_foundation_result(typeof(struc).parameters[1])
                push!(struc.foundations, Foundation(all_supp, placeholder; foundation_type=:mat))
                _size_foundation!(struc; soil=soil, opts=opts, demands=demands,
                                  tc=tc,
                                  concrete=concrete, rebar=rebar, pier_width=pier_width, kwargs...)
            end

        elseif strategy == :strip
            initialize_foundations!(struc; skip=wall_skip)
            strip_groups = [_filter_skip(g, wall_skip) for g in _strip_groupings_from_orthogonal_grid(struc)]
            if !isempty(strip_groups)
                # Orthogonal grid detected: create strip foundations along shorter-spacing axis
                placeholder = _placeholder_foundation_result(typeof(struc).parameters[1])
                in_strip = Set{Int}()
                new_foundations = Foundation[]
                for g in strip_groups
                    length(g) > 1 || continue
                    union!(in_strip, g)
                    push!(new_foundations, Foundation(g, placeholder; foundation_type=:strip))
                end
                for fnd in struc.foundations
                    length(fnd.support_indices) == 1 || continue
                    fnd.support_indices[1] in in_strip && continue
                    push!(new_foundations, fnd)
                end
                empty!(struc.foundations)
                append!(struc.foundations, new_foundations)
                n_strips = count(g -> length(g) > 1, strip_groups)
                verbose && @info "Strip groupings from orthogonal grid: $n_strips strips"
                StructuralSizer.emit!(tc, :workflow, "size_foundations!", "", :decision;
                                      strip_grouping="orthogonal_grid",
                                      n_strips=n_strips,
                                      n_foundations=length(struc.foundations))
            else
                # Non-orthogonal or irregular: merge foundations that are too close
                StructuralSizer.emit!(tc, :workflow, "size_foundations!", "", :decision;
                                      strip_grouping="auto_merge_fallback")
                isempty(struc.foundations) || _auto_merge_to_strips!(struc, demands, soil, opts; tc=tc)
            end
            isempty(struc.foundations) || _size_foundation!(struc; soil=soil, opts=opts, demands=demands,
                              tc=tc,
                              concrete=concrete, rebar=rebar, pier_width=pier_width, kwargs...)

        else  # :spread
            # Pure spread → group by reaction for efficiency
            initialize_foundations!(struc; skip=wall_skip)
            if !isempty(struc.foundations)
                group_foundations_by_reaction!(struc; tolerance=group_tolerance, demands=demands)
                StructuralSizer.emit!(tc, :workflow, "size_foundations!", "", :decision;
                                      spread_grouping="reaction_similarity",
                                      n_groups=length(struc.foundation_groups),
                                      tolerance=group_tolerance)
                size_foundations_grouped!(struc; soil=soil, opts=opts, demands=demands,
                                          tc=tc,
                                          concrete=concrete, rebar=rebar, pier_width=pier_width, kwargs...)
            end
        end

        append!(struc.foundations, wall_fnds)
        StructuralSizer.emit!(tc, :workflow, "size_foundations!", "", :exit;
                              n_foundations=length(struc.foundations),
                              n_groups=length(struc.foundation_groups))

        return struc
    catch e
        StructuralSizer.emit!(tc, :workflow, "size_foundations!", "", :failure;
                              error=string(typeof(e)),
                              message=sprint(showerror, e))
        rethrow()
    end
end

function _filter_skip(indices, skip::Set{Int})
    isempty(skip) && return indices
    return filter(i -> i ∉ skip, indices)
end

"""Drop supports a grade-wall footing already carries, and drop an emptied group."""
function _drop_wall_supports!(struc, skip::Set{Int})
    isempty(skip) && return struc
    kept = empty(struc.foundations)
    for fnd in struc.foundations
        idxs = filter(i -> i ∉ skip, fnd.support_indices)
        isempty(idxs) && continue
        fnd.support_indices = idxs
        push!(kept, fnd)
    end
    empty!(struc.foundations)
    append!(struc.foundations, kept)
    return struc
end
