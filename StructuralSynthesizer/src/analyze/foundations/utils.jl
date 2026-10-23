# Foundation initialization and sizing utilities

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

"""
    initialize_supports!(struc::BuildingStructure)

Create Support objects for each support vertex in the skeleton.
Must be called after `to_asap!(struc)` and `solve!(struc.asap_model)`.

Extracts reaction forces from the ASAP model nodes.
"""
function initialize_supports!(struc::BuildingStructure{T}) where T
    skel = struc.skeleton
    model = struc.asap_model
    
    isempty(model.nodes) && throw(ArgumentError("ASAP model has no nodes. Call to_asap!() first."))
    model.processed || throw(ArgumentError("ASAP model not solved. Call solve!(struc.asap_model) first."))
    
    support_vertex_indices = get(skel.groups_vertices, :support, Int[])
    isempty(support_vertex_indices) && (@warn "No support vertices found in skeleton"; return struc)
    
    empty!(struc.supports)
    
    # Build vertex → Column lookup for column dimension extraction
    col_by_vertex = Dict{Int, Column}()
    for col in struc.columns
        col.vertex_idx > 0 && (col_by_vertex[col.vertex_idx] = col)
    end
    
    for v_idx in support_vertex_indices
        node = model.nodes[v_idx]  # Vertex index maps to node index (from to_asap!)
        
        # Extract reactions with units
        rxn = node.reaction
        forces = (
            uconvert(u"kN", rxn[1]),
            uconvert(u"kN", rxn[2]),
            uconvert(u"kN", rxn[3])
        )
        moments = (
            uconvert(u"kN*m", rxn[4]),
            uconvert(u"kN*m", rxn[5]),
            uconvert(u"kN*m", rxn[6])
        )
        
        # Column dimensions: pull from Column member at this vertex (if sized)
        col_c1 = 18.0u"inch"   # sensible default
        col_c2 = 18.0u"inch"
        col_shape = :rectangular
        if haskey(col_by_vertex, v_idx)
            col = col_by_vertex[v_idx]
            col_shape = col.shape               # :rectangular or :circular
            if col.c1 !== nothing
                col_c1 = uconvert(u"inch", col.c1)
                col_c2 = col.c2 !== nothing ? uconvert(u"inch", col.c2) : col_c1
            elseif section(col) !== nothing
                sec = section(col)
                col_c1 = uconvert(u"inch", StructuralSizer.section_width(sec))
                col_c2 = uconvert(u"inch", StructuralSizer.section_depth(sec))
            end
        end
        
        support = Support(v_idx, v_idx; forces=forces, moments=moments,
                          foundation_type=:spread,
                          c1=col_c1, c2=col_c2, shape=col_shape)
        push!(struc.supports, support)
    end
    
    @debug "Initialized $(length(struc.supports)) supports from skeleton"
    return struc
end

"""
    _pf_from_loads(model, loads) → Vector{Float64}

Fixed-end force vector `Pf` for `loads` without writing `model.Pf` or `model.u`.
"""
function _pf_from_loads(model, loads)
    Pf = zeros(Float64, model.nDOFs)
    for load in loads
        load isa Asap.ElementLoad || continue
        Asap.populate_load!(Pf, load)
    end
    return Pf
end

"""
    _unfactored_DL_loads(struc) → Vector{<:Asap.AbstractLoad}

Unfactored D+L tributary loads for a service solve. Does not mutate `model.loads`.

ASCE 7-16 §2.4.1 combo 2 is D+L (corpus: asce-7-16, pages 63–64). Strength
combos in §2.3.1 (1.4D, 1.2D+1.6L; page 62) must not be back-solved as Ps=Pu/1.4.
"""
function _unfactored_DL_loads(struc::BuildingStructure)
    loads = Asap.AbstractLoad[]
    model = struc.asap_model
    (isnothing(model) || isempty(model.frame_elements)) && return loads
    els = model.frame_elements
    for (cell_idx, cell) in enumerate(struc.cells)
        cell.floor_type == :grade && continue
        _create_cell_tributary_loads!(
            loads, els, struc.skeleton, struc, cell, cell_idx;
            split_dead_live=true, combo=StructuralSizer.service)
    end
    # Unfactored member self-weight (ρ A g) is not in the cell tributary
    # dicts. Include it so service D+L matches ASCE 7-16 §2.4.1 combo 2
    # (dead includes self-weight). GravityLoad.q reads the current section.
    for ld in model.loads
        ld isa Asap.GravityLoad && push!(loads, ld)
    end
    return loads
end

"""
    _service_reactions(struc) → Vector{Float64}

Global reaction vector (N, N·m) for unfactored D+L, reusing the cached
stiffness factorization via `Asap.solve`. Does not write `model.u`.
"""
function _service_reactions(struc::BuildingStructure)
    model = struc.asap_model
    R = zeros(Float64, model.nDOFs)
    loads = _unfactored_DL_loads(struc)
    isempty(loads) && return R
    u_s = Asap.solve(model, loads)
    Pf_s = _pf_from_loads(model, loads)
    R[model.fixedDOFs] = model.S[model.fixedDOFs, :] * u_s + Pf_s[model.fixedDOFs]
    return R
end

"""
    _foundation_demand_from_signed(i, Fz, Fz_s, Fx, Fy, Mx, My; c1, c2, shape)

Map signed ASAP reactions onto a `FoundationDemand`.

ASAP reaction is force FROM support TO structure: gravity Fz>0 is compression,
Fz<0 is uplift. Keep signed `Pu`/`Ps` (negative = tension) so grouped
footings retain the tension-compression couple. Isolated all-uplift still
skips a compression footing (ACI 318-11 §15.8.1.2, corpus: aci-318-11,
page 275). `Ps` is unfactored D+L (ASCE 7-16 §2.4.1 combo 2), not `Pu/1.4`.
"""
function _foundation_demand_from_signed(i::Int, Fz, Fz_s, Fx, Fy, Mx, My;
                                       c1, c2, shape)
    uplift = Fz < zero(Fz)
    return StructuralSizer.FoundationDemand(i;
        Pu=Fz, Mux=Mx, Muy=My, Vux=Fx, Vuy=Fy, Ps=Fz_s,
        c1=c1, c2=c2, shape=shape, uplift=uplift)
end

"""True when every support in `idxs` has factored uplift."""
_all_uplift(demands, idxs) = all(demands[i].uplift for i in idxs)

"""True when `idxs` contains both compressive and tensile factored `Pu`."""
function _mixed_sign_Pu(demands, idxs)
    isempty(idxs) && return false
    z = zero(demands[first(idxs)].Pu)
    has_pos = false
    has_neg = false
    for i in idxs
        P = demands[i].Pu
        P > z && (has_pos = true)
        P < z && (has_neg = true)
        has_pos && has_neg && return true
    end
    return false
end

"""True when any foundation already spans more than one support."""
_explicit_support_groupings(struc) =
    any(f -> length(f.support_indices) > 1, struc.foundations)

"""`:strip` if supports are colinear; `:mat` if both plan axes have span.

ACI 318-11 §15.10.1 — footings supporting more than one column are combined
footings or mats (corpus: aci-318-11, page 277).
"""
function _combined_foundation_type(struc, supp_indices)
    length(supp_indices) < 2 && return :spread
    positions = _support_positions_xy(struc, supp_indices)
    xs = [p[1] for p in positions]
    ys = [p[2] for p in positions]
    Δx = maximum(xs) - minimum(xs)
    Δy = maximum(ys) - minimum(ys)
    # A true line has ~0 span on the perpendicular axis.
    if Δx > 1.0u"ft" && Δy > 1.0u"ft"
        return :mat
    end
    return :strip
end

"""Merge isolated mixed-sign foundations in one reaction group into a strip/mat.

ACI 318-11 §15.10.1 / §15.8.1.2 — do not net a tension-compression couple
into one isolated spread (corpus: aci-318-11, pages 277 / 275).
"""
function _promote_mixed_sign_isolated_groups!(struc, demands)
    isempty(struc.foundation_groups) && return struc
    to_merge = Vector{Vector{Int}}()
    for (_, fg) in struc.foundation_groups
        f_indices = fg.foundation_indices
        length(f_indices) < 2 && continue
        all(i -> length(struc.foundations[i].support_indices) == 1, f_indices) || continue
        supports = [struc.foundations[i].support_indices[1] for i in f_indices]
        _mixed_sign_Pu(demands, supports) || continue
        push!(to_merge, copy(f_indices))
    end
    isempty(to_merge) && return struc

    merged = Set{Int}()
    for f_indices in to_merge
        union!(merged, f_indices)
    end
    placeholder = _placeholder_foundation_result(typeof(struc).parameters[1])
    new_foundations = Foundation[]
    for (fi, fnd) in enumerate(struc.foundations)
        fi in merged && continue
        push!(new_foundations, fnd)
    end
    for f_indices in to_merge
        supports = [struc.foundations[i].support_indices[1] for i in f_indices]
        ftype = _combined_foundation_type(struc, supports)
        push!(new_foundations, Foundation(supports, placeholder; foundation_type=ftype))
    end
    empty!(struc.foundations)
    append!(struc.foundations, new_foundations)
    build_foundation_groups!(struc)
    return struc
end

"""
    support_demands(struc::BuildingStructure; load_factor=1.0)

Convert support reactions to FoundationDemand objects.

Factored `Pu` is the signed vertical reaction (compression positive). Service
`Ps` is read from an extra unfactored D+L solve that reuses the stiffness
factorization. `load_factor` scales both (use 1.0 when reactions are already
factored).
"""
function support_demands(struc::BuildingStructure; load_factor::Real=1.0)
    isempty(struc.supports) && throw(ArgumentError("No supports. Call initialize_supports!() first."))

    model = struc.asap_model
    R_s = _service_reactions(struc)
    demands = StructuralSizer.FoundationDemand[]

    for (i, supp) in enumerate(struc.supports)
        Fx = supp.forces[1] * load_factor
        Fy = supp.forces[2] * load_factor
        Fz = supp.forces[3] * load_factor
        Mx = supp.moments[1] * load_factor
        My = supp.moments[2] * load_factor

        node = model.nodes[supp.node_idx]
        gid = node.globalID
        Fz_s = uconvert(unit(Fz), (R_s[gid[3]] * u"N") * load_factor)

        push!(demands, _foundation_demand_from_signed(i, Fz, Fz_s, Fx, Fy, Mx, My;
            c1=supp.c1, c2=supp.c2, shape=supp.shape))
    end

    return demands
end

"""
    initialize_foundations!(struc::BuildingStructure; groupings=nothing)

Create Foundation objects for supports.

# Arguments
- `groupings`: Optional vector of support index vectors for combined foundations.
  If `nothing`, creates 1:1 mapping (one spread footing per support).

# Example
```julia
# One footing per column (default)
initialize_foundations!(struc)

# Combined footing for supports 1 & 2
initialize_foundations!(struc; groupings=[[1, 2], [3], [4]])
```
"""
function initialize_foundations!(struc::BuildingStructure{T}; 
                                  groupings::Union{Nothing, Vector{Vector{Int}}}=nothing) where T
    isempty(struc.supports) && throw(ArgumentError("No supports. Call initialize_supports!() first."))
    
    empty!(struc.foundations)
    
    if isnothing(groupings)
        # Default: one foundation per support
        for (i, _) in enumerate(struc.supports)
            # Placeholder result - will be filled by size_foundations!
            placeholder = _placeholder_foundation_result(T)
            fnd = Foundation([i], placeholder; foundation_type=:spread)
            push!(struc.foundations, fnd)
        end
    else
        # Explicit groupings
        for supp_indices in groupings
            ftype = length(supp_indices) > 1 ? :combined : :spread
            placeholder = _placeholder_foundation_result(T)
            fnd = Foundation(supp_indices, placeholder; foundation_type=ftype)
            push!(struc.foundations, fnd)
        end
    end
    
    @debug "Initialized $(length(struc.foundations)) foundations"
    return struc
end

"""Create a zero-valued `SpreadFootingResult` placeholder for undesigned foundations."""
function _placeholder_foundation_result(::Type{T}) where T
    L = typeof(1.0u"m")
    V = typeof(1.0u"m^3")
    F = typeof(1.0u"kN")
    StructuralSizer.SpreadFootingResult{L, V, F}(
        0.0u"m", 0.0u"m", 0.0u"m", 0.0u"m",
        0.0u"m", 0, 0.0u"m",
        0.0u"m^3", 0.0u"m^3", 0.0
    )
end

"""Size each foundation in `struc.foundations` as-is (no strategy / grouping logic)."""
function _size_foundation!(
    struc::BuildingStructure;
    soil::StructuralSizer.Soil,
    opts::StructuralSizer.FoundationOptions = StructuralSizer.FoundationOptions(),
    demands::Union{Nothing, Vector{StructuralSizer.FoundationDemand}} = nothing,
    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
    concrete::StructuralSizer.Concrete = StructuralSizer.NWC_4000,
    rebar::StructuralSizer.Metal = StructuralSizer.Rebar_60,
    pier_width = 0.3u"m",
    kwargs...
)
    isempty(struc.foundations) && throw(ArgumentError(
        "No foundations. Call initialize_foundations!() first."))

    demands = isnothing(demands) ? support_demands(struc) : demands
    n_fnd = length(struc.foundations)

    StructuralSizer.emit!(tc, :workflow, "_size_foundation!", "", :enter;
                          n_foundations=n_fnd,
                          code=string(opts.code))

    # ── Per-foundation sizing closure ────────────────────────────────────
    _size_one_fnd!(f_idx) = begin
        fnd = struc.foundations[f_idx]
        n_supp = length(fnd.support_indices)

        if opts.code == :aci
            _size_fnd_aci!(struc, f_idx, fnd, n_supp, demands, soil, opts; tc=tc)
        else
            _size_fnd_is!(struc, f_idx, fnd, n_supp, demands, soil,
                          concrete, rebar, pier_width; tc=tc, kwargs...)
        end
    end

    # ── Dispatch (threaded or serial) ────────────────────────────────────
    if Threads.nthreads() > 1
        Threads.@threads for f_idx in 1:n_fnd
            _size_one_fnd!(f_idx)
        end
    else
        for f_idx in 1:n_fnd
            _size_one_fnd!(f_idx)
        end
    end

    total_concrete = sum(StructuralSizer.concrete_volume(f.result) for f in struc.foundations)
    total_steel    = sum(StructuralSizer.steel_volume(f.result)    for f in struc.foundations)
    @info "Sized $(length(struc.foundations)) foundations ($(opts.code))" total_concrete total_steel

    StructuralSizer.emit!(tc, :workflow, "_size_foundation!", "", :exit;
                          total_concrete_m3=Float64(ustrip(u"m^3", total_concrete)),
                          total_steel_m3=Float64(ustrip(u"m^3", total_steel)))

    return struc
end

# ─────────────────────────────────────────────────────────────────────────────
# ACI 318-11 dispatch
# ─────────────────────────────────────────────────────────────────────────────

"""Dispatch a single foundation through the ACI 318 sizing path (spread, strip, or mat)."""
function _size_fnd_aci!(struc, f_idx, fnd, n_supp, demands, soil, opts;
                        tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing)
    mat = opts.spread_params.material   # ReinforcedConcreteMaterial (concrete + rebar)

    # Keep this lightweight: this function is called once per foundation.
    # Use :decision (not :enter/:exit) to avoid bloating tier=:failures traces.
    StructuralSizer.emit!(tc, :workflow, "_size_fnd_aci!", "foundation_$f_idx", :decision;
                          foundation_type=string(fnd.foundation_type),
                          n_supports=n_supp)

    # ACI 318-11 §15.8.1.2 — tensile force across the interface is not a
    # compression footing demand (corpus: aci-318-11, page 275).
    if _all_uplift(demands, fnd.support_indices)
        StructuralSizer.emit!(tc, :workflow, "_size_fnd_aci!", "foundation_$f_idx", :decision;
                              skipped_uplift=true)
        @warn "Foundation $f_idx in factored uplift — skipping compression footing (ACI 318-11 §15.8.1.2)"
        return
    end

    if fnd.foundation_type == :mat
        _mixed_sign_Pu(demands, fnd.support_indices) && error(
            "Foundation $f_idx mixed-sign Pu on a mat cannot design tensile " *
            "interface steel; form a strip or refuse (ACI 318-11 §15.8.1.2(b), " *
            "corpus: aci-318-11, page 275).")
        # Mat foundation — all supports in one slab
        mat_demands = [demands[i] for i in fnd.support_indices]
        positions = _support_positions_xy(struc, fnd.support_indices)
        result = StructuralSizer.design_footing(StructuralSizer.MatFoundation(), 
            mat_demands, positions, soil; opts=opts.mat_params, tc=tc)
        _assign_foundation!(struc, f_idx, fnd, result, :mat, mat)

    elseif fnd.foundation_type == :spread && n_supp == 1
        demand = demands[fnd.support_indices[1]]
        result = StructuralSizer.design_footing(StructuralSizer.SpreadFooting(), demand, soil; opts=opts.spread_params, tc=tc)
        _assign_foundation!(struc, f_idx, fnd, result, :spread, mat)

    elseif fnd.foundation_type in (:combined, :strip) || n_supp > 1
        # ACI 318-11 §15.8.1.2(b) (corpus: aci-318-11, page 275): a mixed-sign
        # couple must be a strip so tensile interface steel is designed, not
        # omitted by an isolated spread.
        strip_demands = [demands[i] for i in fnd.support_indices]
        axes = _support_strip_axes(struc, fnd.support_indices)
        results = map(axes) do axis
            positions = _support_positions_along_axis(struc, fnd.support_indices, axis)
            StructuralSizer.design_footing(StructuralSizer.StripFooting(),
                strip_demands, positions, soil; opts=opts.strip_params, tc=tc,
                strip_axis=axis)
        end
        result = _governing_strip_result(results)
        if _mixed_sign_Pu(demands, fnd.support_indices)
            (result isa StructuralSizer.StripFootingResult &&
             ustrip(u"m^2", result.As_tensile) > 0) || error(
                "Foundation $f_idx mixed-sign strip omitted As_tensile " *
                "(ACI 318-11 §15.8.1.2(b), corpus: aci-318-11, page 275).")
        end
        _assign_foundation!(struc, f_idx, fnd, result, :strip, mat)
    else
        @warn "Foundation type $(fnd.foundation_type) not wired for ACI, skipping"
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# IS 456 legacy dispatch
# ─────────────────────────────────────────────────────────────────────────────

"""Dispatch a single foundation through the IS 456 legacy sizing path."""
function _size_fnd_is!(struc, f_idx, fnd, n_supp, demands, soil,
                       concrete, rebar, pier_width; tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing, kwargs...)
    if _all_uplift(demands, fnd.support_indices)
        @warn "Foundation $f_idx in factored uplift — skipping compression footing (ACI 318-11 §15.8.1.2)"
        return
    end

    if fnd.foundation_type == :spread && n_supp == 1
        demand = demands[fnd.support_indices[1]]
        result = StructuralSizer.design_footing(StructuralSizer.SpreadFooting(), 
            demand, soil, concrete, rebar; pier_width=pier_width, kwargs...)
        volumes = _compute_foundation_volumes(result, concrete, rebar)
        struc.foundations[f_idx] = Foundation(
            fnd.support_indices, result;
            foundation_type=:spread, group_id=fnd.group_id, volumes=volumes)

    elseif fnd.foundation_type == :combined || n_supp > 1
        total_Pu = sum(demands[i].Pu for i in fnd.support_indices)
        total_Ps = sum(demands[i].Ps for i in fnd.support_indices)
        # Propagate envelope Mux/Muy — dropping them understated eccentric
        # bearing (ACI 336.2R §3.2.1 / §4.1).
        gov_Mux = maximum(abs(demands[i].Mux) for i in fnd.support_indices)
        gov_Muy = maximum(abs(demands[i].Muy) for i in fnd.support_indices)
        combined_demand = StructuralSizer.FoundationDemand(f_idx;
            Pu=total_Pu, Ps=total_Ps, Mux=gov_Mux, Muy=gov_Muy)
        result = StructuralSizer.design_footing(StructuralSizer.SpreadFooting(), 
            combined_demand, soil, concrete, rebar; pier_width=pier_width, kwargs...)
        volumes = _compute_foundation_volumes(result, concrete, rebar)
        struc.foundations[f_idx] = Foundation(
            fnd.support_indices, result;
            foundation_type=:combined, group_id=fnd.group_id, volumes=volumes)
        @warn "Combined footing designed as equivalent spread footing (IS simplified)"
    else
        @warn "Foundation type $(fnd.foundation_type) not implemented (IS), skipping"
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

"""Assign a sized foundation result back into struc, computing material volumes."""
function _assign_foundation!(struc, f_idx, fnd, result, ftype::Symbol, mat)
    concrete_mat = mat.concrete
    rebar_mat    = mat.rebar
    volumes = _compute_foundation_volumes(result, concrete_mat, rebar_mat)
    struc.foundations[f_idx] = Foundation(
        fnd.support_indices, result;
        foundation_type=ftype, group_id=fnd.group_id, volumes=volumes)
end

"""Return `:x` or `:y` for a unique longer plan span.

When Δx and Δy are equal within SI ulp (`1e-12` m, not a construction
tolerance) this throws — callers must size both axes via
`_support_strip_axes`. Named `c1` is ∥ global X (deci-311bd2d0).
"""
function _support_strip_axis(struc, supp_indices::Vector{Int})
    axes = _support_strip_axes(struc, supp_indices)
    length(axes) == 1 && return axes[1]
    throw(ArgumentError(
        "support Δx=Δy within SI ulp; size both axes via _support_strip_axes " *
        "(do not default to :x)"))
end

"""Plan spans Δx, Δy in metres from support vertices."""
function _support_span_xy_m(struc, supp_indices::Vector{Int})
    skel = struc.skeleton
    pts = [skel.vertices[struc.supports[i].vertex_idx] for i in supp_indices]
    length(pts) <= 1 && return (0.0, 0.0)
    xs = [ustrip(u"m", Meshes.coords(p).x) for p in pts]
    ys = [ustrip(u"m", Meshes.coords(p).y) for p in pts]
    return (maximum(xs) - minimum(xs), maximum(ys) - minimum(ys))
end

"""True when Δx and Δy match within a tight SI/ulp length, not construction.

`1e-12` m is on the order of Float64 metre round-trip residue, not a
1-inch / 1-ft layout tolerance.
"""
_strip_spans_tied(Δx::Float64, Δy::Float64) =
    abs(Δx - Δy) <= max(1e-12, 4 * max(eps(Δx), eps(Δy), eps(1.0)))

"""Axes to size for a strip: `[:x]`, `[:y]`, or `[:x, :y]` when Δx=Δy.

Named `c1` remains ∥ global X; `:y` remaps across/along (deci-311bd2d0).
Coincident supports (both spans ~0) stay `[:x]`.
"""
function _support_strip_axes(struc, supp_indices::Vector{Int})
    Δx, Δy = _support_span_xy_m(struc, supp_indices)
    if _strip_spans_tied(Δx, Δy)
        abs(Δx) <= 1e-12 && abs(Δy) <= 1e-12 && return Symbol[:x]
        return Symbol[:x, :y]
    end
    return Δx > Δy ? Symbol[:x] : Symbol[:y]
end

"""Keep the worse of two (or more) strip designs: higher utilization, then D, then volume."""
function _governing_strip_result(results)
    length(results) == 1 && return results[1]
    foldl(results) do a, b
        ua = StructuralSizer.utilization(a)
        ub = StructuralSizer.utilization(b)
        ua > ub + 1e-12 && return a
        ub > ua + 1e-12 && return b
        da = ustrip(u"m", StructuralSizer.footing_depth(a))
        db = ustrip(u"m", StructuralSizer.footing_depth(b))
        da > db + 1e-12 && return a
        db > da + 1e-12 && return b
        va = ustrip(u"m^3", StructuralSizer.concrete_volume(a))
        vb = ustrip(u"m^3", StructuralSizer.concrete_volume(b))
        return va ≥ vb ? a : b
    end
end

"""Extract support positions along `axis` (`:x` or `:y`) for strip layout."""
function _support_positions_along_axis(struc, supp_indices::Vector{Int}, axis::Symbol)
    skel = struc.skeleton
    pts = [skel.vertices[struc.supports[i].vertex_idx] for i in supp_indices]
    if length(pts) <= 1
        return [0.0u"m"]
    end
    xs = [ustrip(u"m", Meshes.coords(p).x) for p in pts]
    ys = [ustrip(u"m", Meshes.coords(p).y) for p in pts]
    axis === :x || axis === :y ||
        throw(ArgumentError("strip axis must be :x or :y; got :$axis"))
    coords = axis === :x ? xs : ys
    origin = minimum(coords)
    return [(c - origin) * u"m" for c in coords]
end

"""Extract support positions along the unique longer axis (errors if Δx=Δy)."""
function _support_positions_along_axis(struc, supp_indices::Vector{Int})
    axes = _support_strip_axes(struc, supp_indices)
    length(axes) == 1 || throw(ArgumentError(
        "support Δx=Δy within SI ulp; pass strip_axis explicitly (do not default to :x)"))
    return _support_positions_along_axis(struc, supp_indices, axes[1])
end

"""Extract support positions as (x, y) tuples (for mat footing layout)."""
function _support_positions_xy(struc, supp_indices::Vector{Int})
    skel = struc.skeleton
    return [let v = skel.vertices[struc.supports[i].vertex_idx]
        c = Meshes.coords(v)
        (c.x, c.y)  # Length quantities for design_footing(MatFoundation, ...)
    end for i in supp_indices]
end

"""Compute material volumes for a foundation from its result."""
function _compute_foundation_volumes(result::R, concrete, rebar) where R<:AbstractFoundationResult
    MaterialVolumes(
        concrete => StructuralSizer.concrete_volume(result),
        rebar => StructuralSizer.steel_volume(result)
    )
end

"""Print rebar schedule line for a spread footing (count × bar size each way)."""
function _print_rebar_line(r::StructuralSizer.SpreadFootingResult, du)
    println("  Rebar: $(r.rebar_count) × $(fmt(du, :rebar_dia, r.rebar_dia, digits=0)) each way")
end
"""Print rebar schedule line for a strip footing (longitudinal + transverse areas)."""
function _print_rebar_line(r::StructuralSizer.StripFootingResult, du)
    println("  Rebar: As_long=$(fmt(du, :rebar_area, r.As_long_bot)), As_trans=$(fmt(du, :rebar_area, r.As_trans))")
    if ustrip(u"m^2", r.As_tensile) > 0
        println("  As_tensile=$(fmt(du, :rebar_area, r.As_tensile)) (ACI 318-11 §15.8.1.2(b))")
    end
end
"""Print rebar schedule line for a mat footing (x- and y-direction areas)."""
function _print_rebar_line(r::StructuralSizer.MatFootingResult, du)
    println("  Rebar: As_x=$(fmt(du, :rebar_area, r.As_x_bot)), As_y=$(fmt(du, :rebar_area, r.As_y_bot))")
end
"""Fallback rebar line for unrecognised foundation result types."""
_print_rebar_line(r, du) = println("  Rebar: (see result object)")

"""
    foundation_summary(design::BuildingDesign)
    foundation_summary(struc::BuildingStructure; du=imperial)

Print a summary of all foundations in the structure.
Display units controlled by `du` (default: `imperial`).
"""
function foundation_summary(design::BuildingDesign)
    foundation_summary(design.structure; du=design.params.display_units)
end

function foundation_summary(struc::BuildingStructure; du::DisplayUnits=imperial)
    isempty(struc.foundations) && return println("No foundations designed.")
    
    println("\n=== Foundation Summary ===")
    println("─" ^ 60)
    
    total_concrete = 0.0u"m^3"
    total_steel = 0.0u"m^3"
    total_area = 0.0u"m^2"
    
    for (i, fnd) in enumerate(struc.foundations)
        r = fnd.result
        supp_str = join(fnd.support_indices, ", ")
        
        println("Foundation $i ($(fnd.foundation_type), supports: [$supp_str])")
        println("  Size: $(fmt(du, :length, r.B)) × $(fmt(du, :length, r.L_ftg)) × $(fmt(du, :length, r.D))")
        _print_rebar_line(r, du)
        println("  Concrete: $(fmt(du, :volume, r.concrete_volume, digits=3))")
        println("  Steel: $(fmt(du, :volume, r.steel_volume, digits=5))")
        println("  Utilization: $(round(r.utilization * 100, digits=1))%")
        println()
        
        total_concrete += r.concrete_volume
        total_steel += r.steel_volume
        total_area += StructuralSizer.footprint_area(r)
    end
    
    println("─" ^ 60)
    println("TOTALS:")
    println("  Foundations: $(length(struc.foundations))")
    println("  Footprint area: $(fmt(du, :area, total_area))")
    println("  Concrete volume: $(fmt(du, :volume, total_concrete))")
    println("  Steel volume: $(fmt(du, :volume, total_steel, digits=4))")
    println("  Steel weight: $(fmt(du, :mass, total_steel * 7850u"kg/m^3", digits=1))")
end

"""
    build_foundation_groups!(struc::BuildingStructure)

Populate `struc.foundation_groups` from `struc.foundations` using `Foundation.group_id`.
"""
function build_foundation_groups!(struc::BuildingStructure)
    empty!(struc.foundation_groups)
    
    for (f_idx, f) in enumerate(struc.foundations)
        gid = f.group_id === nothing ? UInt64(hash((:singleton_foundation_group, f_idx))) : f.group_id
        f.group_id = gid
        
        fg = get!(struc.foundation_groups, gid) do
            FoundationGroup(gid)
        end
        push!(fg.foundation_indices, f_idx)
    end
    
    return struc.foundation_groups
end

# =============================================================================
# Automatic Grouping by Reaction Similarity
# =============================================================================

"""
    group_foundations_by_reaction!(struc::BuildingStructure; 
                                    tolerance=0.15, 
                                    n_support_bins=true,
                                    demands=nothing)

Automatically assign `group_id` to foundations with similar reaction magnitudes.

# Arguments
- `tolerance`: Relative tolerance for grouping (0.15 = 15% difference allowed)
- `n_support_bins`: If true, also separate by number of supports (single vs combined)
- `demands`: Optional precomputed `support_demands(struc)` to avoid recomputation

# Returns
Number of unique groups created.

# Example
```julia
initialize_supports!(struc)
initialize_foundations!(struc)
demands = support_demands(struc)  # Compute once
n_groups = group_foundations_by_reaction!(struc; tolerance=0.0, demands=demands)
size_foundations_grouped!(struc; soil=medium_sand, demands=demands)
```
"""
function group_foundations_by_reaction!(struc::BuildingStructure; 
                                         tolerance::Real=0.0,
                                         n_support_bins::Bool=true,
                                         demands::Union{Nothing, Vector{StructuralSizer.FoundationDemand}}=nothing)
    isempty(struc.foundations) && throw(ArgumentError("No foundations. Call initialize_foundations!() first."))
    
    demands = isnothing(demands) ? support_demands(struc) : demands
    
    # Compute governing Pu for each foundation
    foundation_loads = Float64[]
    for fnd in struc.foundations
        if length(fnd.support_indices) == 1
            Pu = ustrip(u"kN", demands[fnd.support_indices[1]].Pu)
        else
            # Combined: sum of loads
            Pu = sum(ustrip(u"kN", demands[i].Pu) for i in fnd.support_indices)
        end
        push!(foundation_loads, Pu)
    end
    
    # Cluster into groups by similarity
    # Simple greedy clustering: assign to existing group if within tolerance, else create new
    groups = Dict{UInt64, Vector{Int}}()
    group_loads = Dict{UInt64, Float64}()  # Representative load for each group
    
    for (f_idx, load) in enumerate(foundation_loads)
        fnd = struc.foundations[f_idx]
        n_supports = length(fnd.support_indices)
        
        # Find compatible group
        assigned = false
        for (gid, rep_load) in group_loads
            # Check tolerance
            if rep_load > 0 && abs(load - rep_load) / rep_load <= tolerance
                # Check n_supports constraint
                if !n_support_bins || _group_n_supports(struc, groups[gid]) == n_supports
                    push!(groups[gid], f_idx)
                    # Update representative to max (conservative)
                    group_loads[gid] = max(rep_load, load)
                    assigned = true
                    break
                end
            end
        end
        
        if !assigned
            # Create new group
            gid = UInt64(hash((:foundation_reaction_group, length(groups) + 1, n_supports)))
            groups[gid] = [f_idx]
            group_loads[gid] = load
        end
    end
    
    # Assign group_ids to foundations
    for (gid, f_indices) in groups
        for f_idx in f_indices
            struc.foundations[f_idx].group_id = gid
        end
    end
    
    # Build the groups dict
    build_foundation_groups!(struc)
    
    n_groups = length(groups)
    @info "Grouped $(length(struc.foundations)) foundations into $n_groups groups (tolerance=$(tolerance*100)%)"
    
    return n_groups
end

"""Number of supports for the first foundation in a group (for grouping compatibility)."""
function _group_n_supports(struc, f_indices)
    isempty(f_indices) && return 0
    return length(struc.foundations[f_indices[1]].support_indices)
end

"""
    size_foundations_grouped!(struc; soil, opts, demands=nothing, ...)

Size foundations at the group level: design for governing load, apply to all in group.

This is more efficient than individual sizing and ensures constructability
(same footing size for similar columns).

Dispatches on `opts.code` (`:aci` default, `:is` legacy).
"""
function size_foundations_grouped!(
    struc::BuildingStructure;
    soil::StructuralSizer.Soil,
    opts::StructuralSizer.FoundationOptions = StructuralSizer.FoundationOptions(),
    demands::Union{Nothing, Vector{StructuralSizer.FoundationDemand}} = nothing,
    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
    # Legacy IS kwargs
    concrete::StructuralSizer.Concrete = StructuralSizer.NWC_4000,
    rebar::StructuralSizer.Metal = StructuralSizer.Rebar_60,
    pier_width = 0.3u"m",
    kwargs...
)
    isempty(struc.foundations) && throw(ArgumentError(
        "No foundations. Call initialize_foundations!() first."))

    isempty(struc.foundation_groups) && build_foundation_groups!(struc)
    demands = isnothing(demands) ? support_demands(struc) : demands
    _promote_mixed_sign_isolated_groups!(struc, demands)

    gids = collect(keys(struc.foundation_groups))
    n_fnd_groups = length(gids)
    group_results_vec = Vector{Any}(nothing, n_fnd_groups)

    StructuralSizer.emit!(tc, :workflow, "size_foundations_grouped!", "", :enter;
                          n_groups=n_fnd_groups,
                          n_foundations=length(struc.foundations),
                          code=string(opts.code))

    _size_one_group!(k) = begin
        gid = gids[k]
        fg = struc.foundation_groups[gid]
        f_indices = fg.foundation_indices
        isempty(f_indices) && return

        gov_Pu  = 0.0u"kN"
        gov_Ps  = 0.0u"kN"
        gov_Mux = 0.0u"kN*m"
        gov_Muy = 0.0u"kN*m"
        gov_Vux = 0.0u"kN"
        gov_Vuy = 0.0u"kN"

        try
            group_supports = Int[]
            for f_idx in f_indices
                append!(group_supports, struc.foundations[f_idx].support_indices)
            end
            unique!(group_supports)

            if _all_uplift(demands, group_supports)
                @warn "Foundation group $gid in factored uplift — skipping compression footing (ACI 318-11 §15.8.1.2)"
                return
            end

            # ACI 318-11 §15.10.1 — combined footings/mats resist the factored
            # loads (corpus: aci-318-11, page 277). Mixed-sign or multi-support
            # groups keep per-support signed Pu/Ps so x_bar uses the couple
            # (§15.8.1.2, page 275). Do not net into one SpreadFooting.
            needs_signed_combined = _mixed_sign_Pu(demands, group_supports) ||
                any(i -> length(struc.foundations[i].support_indices) > 1 ||
                         struc.foundations[i].foundation_type in (:combined, :strip, :mat),
                    f_indices)

            if needs_signed_combined
                for f_idx in f_indices
                    fnd = struc.foundations[f_idx]
                    n_supp = length(fnd.support_indices)
                    if opts.code == :aci
                        _size_fnd_aci!(struc, f_idx, fnd, n_supp, demands, soil, opts; tc=tc)
                    else
                        _size_fnd_is!(struc, f_idx, fnd, n_supp, demands, soil,
                                      concrete, rebar, pier_width; tc=tc, kwargs...)
                    end
                end
                if _mixed_sign_Pu(demands, group_supports)
                    has_tensile = any(f_indices) do fi
                        r = struc.foundations[fi].result
                        r isa StructuralSizer.StripFootingResult &&
                            ustrip(u"m^2", r.As_tensile) > 0
                    end
                    has_tensile || error(
                        "Foundation group $gid mixed-sign couple did not form a strip " *
                        "with designed As_tensile (ACI 318-11 §15.8.1.2(b), " *
                        "corpus: aci-318-11, page 275); refuse rather than omit the steel.")
                end
                r = struc.foundations[f_indices[1]].result
                StructuralSizer.emit!(tc, :workflow, "size_foundations_grouped!", "foundation_group_$(gid)", :decision;
                                      n_foundations=length(f_indices),
                                      n_supports=length(group_supports),
                                      mixed_sign=_mixed_sign_Pu(demands, group_supports),
                                      routed="signed_combined",
                                      B_m=Float64(ustrip(u"m", StructuralSizer.footing_width(r))),
                                      L_m=Float64(ustrip(u"m", StructuralSizer.footing_length(r))),
                                      D_m=Float64(ustrip(u"m", StructuralSizer.footing_depth(r))),
                                      utilization=Float64(StructuralSizer.utilization(r)))
                return
            end

            any_compression = false
            for f_idx in f_indices
                fnd = struc.foundations[f_idx]
                _all_uplift(demands, fnd.support_indices) && continue
                any_compression = true
                d = demands[fnd.support_indices[1]]
                gov_Pu  = max(gov_Pu,  d.Pu)
                gov_Ps  = max(gov_Ps,  d.Ps)
                gov_Mux = max(gov_Mux, abs(d.Mux))
                gov_Muy = max(gov_Muy, abs(d.Muy))
                gov_Vux = max(gov_Vux, abs(d.Vux))
                gov_Vuy = max(gov_Vuy, abs(d.Vuy))
            end

            if !any_compression
                @warn "Foundation group $gid in factored uplift — skipping compression footing (ACI 318-11 §15.8.1.2)"
                return
            end
            # Use the largest column dimensions in the group (conservative for punching)
            gov_c1 = 18.0u"inch"
            gov_c2 = 18.0u"inch"
            gov_shape = :rectangular
            for f_idx in f_indices
                fnd = struc.foundations[f_idx]
                for si in fnd.support_indices
                    d = demands[si]
                    gov_c1 = max(gov_c1, d.c1)
                    gov_c2 = max(gov_c2, d.c2)
                    d.shape == :circular && (gov_shape = :circular)
                end
            end
            gov_demand = StructuralSizer.FoundationDemand(1;
                Pu=gov_Pu, Mux=gov_Mux, Muy=gov_Muy,
                Vux=gov_Vux, Vuy=gov_Vuy, Ps=gov_Ps,
                c1=gov_c1, c2=gov_c2, shape=gov_shape)

            if opts.code == :aci
                group_results_vec[k] = StructuralSizer.design_footing(StructuralSizer.SpreadFooting(), 
                    gov_demand, soil; opts=opts.spread_params, tc=tc)
            else
                group_results_vec[k] = StructuralSizer.design_footing(StructuralSizer.SpreadFooting(), 
                    gov_demand, soil, concrete, rebar;
                    pier_width=pier_width, kwargs...)
            end

            r = group_results_vec[k]
            StructuralSizer.emit!(tc, :workflow, "size_foundations_grouped!", "foundation_group_$(gid)", :decision;
                                  n_foundations=length(f_indices),
                                  gov_Pu_kN=Float64(ustrip(u"kN", gov_Pu)),
                                  gov_c1_in=Float64(ustrip(u"inch", gov_c1)),
                                  gov_c2_in=Float64(ustrip(u"inch", gov_c2)),
                                  shape=string(gov_shape),
                                  B_m=Float64(ustrip(u"m", StructuralSizer.footing_width(r))),
                                  L_m=Float64(ustrip(u"m", StructuralSizer.footing_length(r))),
                                  D_m=Float64(ustrip(u"m", StructuralSizer.footing_depth(r))),
                                  utilization=Float64(StructuralSizer.utilization(r)))
        catch e
            StructuralSizer.emit!(tc, :workflow, "size_foundations_grouped!", "foundation_group_$(gid)", :failure;
                                  error=string(typeof(e)),
                                  message=sprint(showerror, e))
            rethrow()
        end
    end

    if Threads.nthreads() > 1
        tasks = map(1:n_fnd_groups) do k
            Threads.@spawn _size_one_group!(k)
        end
        fetch.(tasks)
    else
        for k in 1:n_fnd_groups
            _size_one_group!(k)
        end
    end

    # Reconstruct Dict from parallel results
    group_results = Dict{UInt64, StructuralSizer.AbstractFoundationResult}()
    for k in 1:n_fnd_groups
        group_results_vec[k] === nothing && continue
        group_results[gids[k]] = group_results_vec[k]
    end

    # Determine material source for volume computation
    if opts.code == :aci
        mat = opts.spread_params.material
        c_mat, r_mat = mat.concrete, mat.rebar
    else
        c_mat, r_mat = concrete, rebar
    end

    # Apply group result to all foundations in each group
    for (f_idx, fnd) in enumerate(struc.foundations)
        gid = fnd.group_id
        gid === nothing && continue
        haskey(group_results, gid) || continue
        result = group_results[gid]
        volumes = _compute_foundation_volumes(result, c_mat, r_mat)
        struc.foundations[f_idx] = Foundation(
            fnd.support_indices, result;
            foundation_type=fnd.foundation_type, group_id=gid, volumes=volumes)
    end

    n_groups = length(struc.foundation_groups)
    total_concrete = sum(StructuralSizer.concrete_volume(f.result) for f in struc.foundations)
    total_steel    = sum(StructuralSizer.steel_volume(f.result)    for f in struc.foundations)
    @info "Sized $n_groups foundation groups ($(opts.code))" total_concrete total_steel

    StructuralSizer.emit!(tc, :workflow, "size_foundations_grouped!", "", :exit;
                          n_groups=n_groups,
                          total_concrete_m3=Float64(ustrip(u"m^3", total_concrete)),
                          total_steel_m3=Float64(ustrip(u"m^3", total_steel)))

    return struc
end

"""
    foundation_group_summary(design::BuildingDesign; demands=nothing)
    foundation_group_summary(struc::BuildingStructure; du=imperial, demands=nothing)

Print a summary organized by foundation groups.
Display units controlled by `du` (default: `imperial`).

# Arguments
- `demands`: Optional precomputed `support_demands(struc)` to avoid recomputation
"""
function foundation_group_summary(design::BuildingDesign;
                                   demands::Union{Nothing, Vector{StructuralSizer.FoundationDemand}}=nothing)
    foundation_group_summary(design.structure; du=design.params.display_units, demands=demands)
end

function foundation_group_summary(struc::BuildingStructure; 
                                   du::DisplayUnits=imperial,
                                   demands::Union{Nothing, Vector{StructuralSizer.FoundationDemand}}=nothing)
    isempty(struc.foundation_groups) && return println("No foundation groups. Call build_foundation_groups!() first.")
    
    demands = isnothing(demands) ? support_demands(struc) : demands
    
    println("\n=== Foundation Group Summary ===")
    println("─" ^ 70)
    
    total_concrete = 0.0u"m^3"
    total_steel = 0.0u"m^3"
    
    for (g_idx, (gid, fg)) in enumerate(struc.foundation_groups)
        f_indices = fg.foundation_indices
        n_ftg = length(f_indices)
        
        # Get representative foundation
        fnd = struc.foundations[f_indices[1]]
        r = fnd.result
        
        # Load range in group
        loads = Float64[]
        for f_idx in f_indices
            f = struc.foundations[f_idx]
            if length(f.support_indices) == 1
                push!(loads, ustrip(u"kN", demands[f.support_indices[1]].Pu))
            else
                push!(loads, sum(ustrip(u"kN", demands[i].Pu) for i in f.support_indices))
            end
        end
        
        load_min = minimum(loads)
        load_max = maximum(loads)
        
        println("Group $g_idx: $n_ftg foundations")
        println("  Load range: $(round(load_min, digits=1)) - $(round(load_max, digits=1)) kN")
        println("  Size: $(fmt(du, :length, r.B)) × $(fmt(du, :length, r.L_ftg)) × $(fmt(du, :length, r.D))")
        _print_rebar_line(r, du)
        println("  Concrete/footing: $(fmt(du, :volume, r.concrete_volume, digits=3))")
        println("  Group total concrete: $(fmt(du, :volume, r.concrete_volume * n_ftg))")
        println()
        
        total_concrete += r.concrete_volume * n_ftg
        total_steel += r.steel_volume * n_ftg
    end
    
    println("─" ^ 70)
    println("TOTALS:")
    println("  Groups: $(length(struc.foundation_groups))")
    println("  Foundations: $(length(struc.foundations))")
    println("  Concrete volume: $(fmt(du, :volume, total_concrete))")
    println("  Steel volume: $(fmt(du, :volume, total_steel, digits=4))")
    println("  Steel weight: $(fmt(du, :mass, total_steel * 7850u"kg/m^3", digits=1))")
end

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
            size_foundations_grouped!(struc; soil=soil, opts=opts, demands=demands,
                                      tc=tc,
                                      concrete=concrete, rebar=rebar, pier_width=pier_width, kwargs...)
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
            # Single mat foundation covering all supports
            all_supp = collect(1:length(struc.supports))
            placeholder = _placeholder_foundation_result(typeof(struc).parameters[1])
            empty!(struc.foundations)
            push!(struc.foundations, Foundation(all_supp, placeholder; foundation_type=:mat))
            _size_foundation!(struc; soil=soil, opts=opts, demands=demands,
                              tc=tc,
                              concrete=concrete, rebar=rebar, pier_width=pier_width, kwargs...)

        elseif strategy == :strip
            initialize_foundations!(struc)
            strip_groups = _strip_groupings_from_orthogonal_grid(struc)
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
                _auto_merge_to_strips!(struc, demands, soil, opts; tc=tc)
            end
            _size_foundation!(struc; soil=soil, opts=opts, demands=demands,
                              tc=tc,
                              concrete=concrete, rebar=rebar, pier_width=pier_width, kwargs...)

        else  # :spread
            # Pure spread → group by reaction for efficiency
            initialize_foundations!(struc)
            group_foundations_by_reaction!(struc; tolerance=group_tolerance, demands=demands)
            StructuralSizer.emit!(tc, :workflow, "size_foundations!", "", :decision;
                                  spread_grouping="reaction_similarity",
                                  n_groups=length(struc.foundation_groups),
                                  tolerance=group_tolerance)
            size_foundations_grouped!(struc; soil=soil, opts=opts, demands=demands,
                                      tc=tc,
                                      concrete=concrete, rebar=rebar, pier_width=pier_width, kwargs...)
        end

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
