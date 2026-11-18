# ==============================================================================
# Column Sizing API
# ==============================================================================
# Clean, type-dispatched interface for column sizing.
# One function, material-specific options types.
# All inputs can be Unitful quantities - conversions handled internally.

# Register trace contracts for member sizing entrypoints.
# NOTE: Docstrings conflict with `@traced` (Julia doc macro ordering), so we register manually.
TRACE_REGISTRY[(:size_columns, :sizing)] =
    TracedFunctionMeta(:size_columns, :sizing,
                       [:enter, :exit, :decision, :failure], nothing,
                       @__FILE__, @__LINE__)
TRACE_REGISTRY[(:size_beams, :sizing)] =
    TracedFunctionMeta(:size_beams, :sizing,
                       [:enter, :exit, :decision, :failure], nothing,
                       @__FILE__, @__LINE__)
TRACE_REGISTRY[(:size_members, :sizing)] =
    TracedFunctionMeta(:size_members, :sizing,
                       [:enter, :exit, :decision, :failure], nothing,
                       @__FILE__, @__LINE__)

"""Concrete plus longitudinal and transverse rebar, so discrete objectives count both."""
function _sizing_material(concrete, rebar, transverse = rebar)
    concrete isa ReinforcedConcreteMaterial && return concrete
    return ReinforcedConcreteMaterial(concrete, rebar, transverse)
end

"""Create zero vector matching the units of the input vector."""
function zeros_like(v::Vector)
    if !isempty(v) && v[1] isa Unitful.Quantity
        return zeros(length(v)) .* unit(v[1])
    else
        return zeros(length(v))
    end
end

"""
    _require_sizing_strategy(opts, supported; api) -> Symbol

Validate a public member-sizing strategy before any solver work. Strategy
selection is an API contract: an unknown or unsupported symbol must not silently
fall through to the discrete path.
"""
function _require_sizing_strategy(opts, supported::Tuple; api::AbstractString)
    strategy = opts.sizing_strategy
    strategy in supported || throw(ArgumentError(
        "$api does not support sizing_strategy=:$strategy; expected one of $(collect(supported))"))
    return strategy
end

"""Resolve the `MemberDemand.composite` payload for steel beam sizing.

A `CompositeContext` or `true` on `composite_kw` (scalar or per-member
vector) wins. A vector entry of `nothing` does **not** override
`SteelBeamOptions.composite == true` — that would drop Chapter I / the
sentinel when the caller meant to enable composite.

Hogging Chapter F (`Cb=1.0`, `Lb=L`) is applied by 6-arg `is_feasible`
whenever `Mux_neg` is set (including the `Mux_neg=Mux` default); it is
not gated on this payload.
"""
function _resolve_demand_composite(opts, composite_kw, i::Int)
    opts_composite = opts isa SteelBeamOptions && opts.composite
    if composite_kw isa AbstractVector
        i <= length(composite_kw) || throw(ArgumentError(
            "composite vector must have one entry per member (got " *
            "$(length(composite_kw)) for index $i)"))
        entry = composite_kw[i]
        if entry isa CompositeContext || entry isa PerStationComposite || entry === true
            return entry
        elseif isnothing(entry) && opts_composite
            return true
        else
            return entry
        end
    elseif composite_kw isa CompositeContext || composite_kw isa PerStationComposite ||
            composite_kw === true
        return composite_kw
    elseif opts_composite
        return true
    else
        return nothing
    end
end

"""True if any member resolves to a real `CompositeContext` (Chapter I path)."""
function _has_composite_context(opts, composite_kw, n::Int)
    for i in 1:n
        c = _resolve_demand_composite(opts, composite_kw, i)
        (c isa CompositeContext || c isa PerStationComposite) && return true
    end
    return false
end

# ==============================================================================
# Main API: size_columns
# ==============================================================================

"""
    size_columns(Pu, Mux, geometries, opts::SteelColumnOptions; Muy=...)
    size_columns(Pu, Mux, geometries, opts::ConcreteColumnOptions; Muy=...)

Size columns using the specified options. Accepts any consistent Unitful quantities.

# Arguments
- `Pu`: Factored axial loads (positive = compression) — any force unit (N, kN, kip, etc.)
- `Mux`: Factored moments about x-axis — any moment unit (N·m, kN·m, kip·ft, etc.)
- `geometries`: Member geometries (auto-converted as needed)
- `opts`: `SteelColumnOptions` or `ConcreteColumnOptions`

# Keyword Arguments
- `Muy`: Factored moments about y-axis (default: zeros with same unit as Mux)
- `catalog`: Optional per-call section catalog override (default `nothing`).
  When supplied, it takes precedence over `opts.custom_catalog` and the
  material's standard catalog for this call only; omitting it reproduces the
  prior behaviour exactly. A caller passes it to restrict one group to a
  catalog without forking the sizing functions. Ignored on the NLP
  (`sizing_strategy = :nlp`) path, which has no discrete catalog.

# Returns
Named tuple with:
- `sections`: Optimal sections (one per member)
- `section_indices`: Indices into catalog
- `status`: Solver status
- `objective_value`: Final objective value

# Example
```julia
using Unitful
using StructuralSizer: kip, ksi  # Asap custom units
# Unitful built-ins like kN, ft, m are available via u"..."

# Steel columns with SI units
Pu = [500.0, 800.0] .* u"kN"
Mux = [100.0, 150.0] .* u"kN*m"
geoms = [SteelMemberGeometry(4.0u"m"), SteelMemberGeometry(4.0u"m")]
result = size_columns(Pu, Mux, geoms, SteelColumnOptions())

# Concrete columns with US units  
Pu = [200.0, 350.0] .* kip
Mux = [150.0, 200.0] .* kip * u"ft"
geoms = [ConcreteMemberGeometry(12.0u"ft"), ConcreteMemberGeometry(12.0u"ft")]
result = size_columns(Pu, Mux, geoms, ConcreteColumnOptions())

# Mixed units work too - conversions are automatic
Pu_mixed = [500.0u"kN", 112.4kip]  # Will be converted internally
```
"""
function size_columns end

# ==============================================================================
# Steel Implementation
# ==============================================================================

"""Throw unless an optional end-moment vector matches the member count."""
function _check_moment_vector(name::Symbol, vec, n::Int)
    vec === nothing && return
    length(vec) == n || throw(ArgumentError("$name must have one entry per member"))
    return
end

_moment_vector_nm(::Nothing) = nothing
_moment_vector_nm(vec) = [to_newton_meters(m) for m in vec]

"""True when the caller supplied curvature or a span load for Appendix 8."""
function _steel_b1_requested(M1x, M2x, M1y, M2y, transverse_load)
    (M1x !== nothing || M2x !== nothing || M1y !== nothing || M2y !== nothing) &&
        return true
    transverse_load isa Bool && return transverse_load
    transverse_load isa AbstractVector && return any(transverse_load)
    return false
end

"""One steel `MemberDemand` from the array API, in newtons and newton-metres."""
function _steel_array_demand(i, Pu_N, Pu_t_N, Mux_Nm, Mux_pos_Nm, Mux_neg_Nm,
                             Muy_Nm, Vus_N, δ_m, δ_tot, Ir_m4,
                             M1x_Nm, M2x_Nm, M1y_Nm, M2y_Nm, transverse_load, composite)
    tl = transverse_load === nothing ? false :
         transverse_load isa Bool ? transverse_load : Bool(transverse_load[i])
    return MemberDemand(i; Pu_c=Pu_N[i], Pu_t=Pu_t_N[i], Mux=Mux_Nm[i],
                        Mux_pos=Mux_pos_Nm[i], Mux_neg=Mux_neg_Nm[i],
                        Muy=Muy_Nm[i],
                        M1x=M1x_Nm === nothing ? nothing : M1x_Nm[i],
                        M2x=M2x_Nm === nothing ? nothing : M2x_Nm[i],
                        M1y=M1y_Nm === nothing ? nothing : M1y_Nm[i],
                        M2y=M2y_Nm === nothing ? nothing : M2y_Nm[i],
                        Vu_strong=Vus_N[i],
                        δ_max_LL=δ_m[i], δ_max_total=δ_tot[i],
                        I_ref=Ir_m4[i],
                        transverse_load=tl,
                        composite=composite)
end



function size_columns(
    Pu::Vector,
    Mux::Vector,
    geometries::Vector,
    opts::SteelMemberOptions;
    Muy::Vector = zeros_like(Mux),
    Mux_pos::Vector = Mux,
    Mux_neg::Vector = Mux,
    Vu_strong::Vector = zeros_like(Pu),
    # AISC 360-16 §H1.2 — flexure + tension uses Eqs. H1-1a/H1-1b with
    # Pc = φt·Pn (Section D2). corpus: aisc-360-16, page 134.
    # Default zeros keeps compression-only callers byte-identical.
    Pu_t::Vector = zeros_like(Pu),
    δ_max_vec::Union{Nothing, Vector} = nothing,
    δ_max_total_vec::Union{Nothing, Vector} = nothing,
    I_ref_vec::Union{Nothing, Vector} = nothing,
    catalog::Union{Nothing, AbstractVector} = nothing,
    feasible::Union{Nothing, Vector{Vector{Int}}} = nothing,
    mip_start::Union{Nothing, Vector{Int}} = nothing,
    composite::Union{Nothing, Bool, CompositeContext, PerStationComposite, AbstractVector} = nothing,
    shell_spans::Union{Nothing, AbstractVector} = nothing,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
    tc::Union{Nothing, TraceCollector} = nothing,
    # AISC 360-16 App. 8 §8.2.1 (corpus: aisc-360-16, PDF page 306).
    # Omitted end moments keep M1 = 0. `transverse_load` selects Cm = 1.0
    # for a member with load between its supports (§8.2.1(b)).
    M1x::Union{Nothing, Vector} = nothing,
    M2x::Union{Nothing, Vector} = nothing,
    M1y::Union{Nothing, Vector} = nothing,
    M2y::Union{Nothing, Vector} = nothing,
    transverse_load::Union{Nothing, Bool, AbstractVector} = nothing,
)
    n = length(Pu)
    n == length(Mux) || throw(ArgumentError("Pu and Mux must have same length"))
    shell_spans === nothing || length(shell_spans) == n ||
        throw(ArgumentError("shell_spans must have one entry per demand"))
    n == length(geometries) || throw(ArgumentError("demands and geometries must have same length"))
    n == length(Pu_t) || throw(ArgumentError("Pu and Pu_t must have same length"))
    strategy = _require_sizing_strategy(
        opts, (:discrete, :nlp); api="steel column/beam sizing")
    _check_moment_vector(:M1x, M1x, n)
    _check_moment_vector(:M2x, M2x, n)
    _check_moment_vector(:M1y, M1y, n)
    _check_moment_vector(:M2y, M2y, n)
    if transverse_load isa AbstractVector
        length(transverse_load) == n || throw(ArgumentError(
            "transverse_load must have one entry per member"))
    end

    emit!(tc, :sizing, "size_columns", "", :enter;
          material="steel",
          n_members=n,
          options_type=string(typeof(opts)),
          sizing_strategy=string(opts.sizing_strategy),
          section_type=string(opts.section_type))

    steel_geoms = [to_steel_geometry(g) for g in geometries]

    # ─── Steel NLP path (W and HSS only) ───
    # CompositeContext needs 8-arg is_feasible (Chapter I + H1 with Pu).
    # Continuous NLP has no Chapter I plastic capacity — use discrete MIP.
    # Nonzero Pu_t also stays on discrete MIP: the NLP H1 constraint is
    # compression-only, and §H1.2 tension is the checker that already exists.
    # AISC 360-16 §H1.2 — corpus: aisc-360-16, page 134.
    if strategy === :nlp
        opts.section_type in (:w, :hss) || throw(ArgumentError(
            "steel NLP sizing supports section_type :w or :hss; got :$(opts.section_type)"))
        !_has_composite_context(opts, composite, n) || throw(ArgumentError(
            "steel NLP sizing does not support CompositeContext; use sizing_strategy=:discrete"))
        all(iszero, Pu_t) || throw(ArgumentError(
            "steel NLP sizing does not support tensile axial demand Pu_t; use sizing_strategy=:discrete"))
        (shell_spans === nothing || all(isempty, shell_spans)) || throw(ArgumentError(
            "steel NLP sizing does not check story-shell spans; use sizing_strategy=:discrete"))
        # The continuous H1 constraint uses the first-order moment. Appendix 8
        # B1 depends on the section stiffness, which that constraint does not
        # carry. A compressed member with end moments or span load stays on
        # the discrete checker, where B1 is applied.
        if _steel_b1_requested(M1x, M2x, M1y, M2y, transverse_load) &&
                any(!iszero, Pu)
            throw(ArgumentError(
                "steel NLP does not apply Appendix 8 B1. Use sizing_strategy=:discrete " *
                "when a compressed member has end moments or transverse load. " *
                "AISC 360-16 App. 8 §8.2.1 (corpus: aisc-360-16, PDF page 306)."))
        end
        emit!(tc, :sizing, "size_columns", "", :decision; path="nlp")
        return _size_steel_columns_nlp(Pu, Mux, steel_geoms, opts;
                                       Muy=Muy, Mux_neg=Mux_neg, composite=composite)
    end
    emit!(tc, :sizing, "size_columns", "", :decision; path="discrete_mip")

    # Catalog precedence: explicit `catalog` kwarg > `opts.custom_catalog` >
    # material-default `steel_column_catalog`. Passing `catalog` silently
    # reproduces prior behaviour when omitted (`nothing`).
    cat = !isnothing(catalog) ? catalog :
        (isnothing(opts.custom_catalog) ?
            steel_column_catalog(opts.section_type, opts.catalog) :
            opts.custom_catalog)
    
    Pu_N = [to_newtons(p) for p in Pu]
    Mux_Nm = [to_newton_meters(m) for m in Mux]
    Mux_pos_Nm = [to_newton_meters(m) for m in Mux_pos]
    Mux_neg_Nm = [to_newton_meters(m) for m in Mux_neg]
    Muy_Nm = [to_newton_meters(m) for m in Muy]
    Vus_N  = [to_newtons(v) for v in Vu_strong]

    δ_m    = isnothing(δ_max_vec)       ? zeros(n) : [to_meters(d) for d in δ_max_vec]
    δ_tot  = isnothing(δ_max_total_vec) ? zeros(n) : [to_meters(d) for d in δ_max_total_vec]
    Ir_m4  = isnothing(I_ref_vec)       ? ones(n)  : [to_meters_fourth(r) for r in I_ref_vec]
    
    # Envelope pairing: each group's max |P| with its max |M|.
    # CONSERVATIVE under gravity-only (same-sign D+L cannot unload a
    # coincident peak). Pu_t is the tension magnitude (always ≥ 0).
    # AISC 360-16 §H1.1 Eqs. H1-1a/H1-1b — compression + flexure
    # (corpus: aisc-360-16, page 133). §H1.2 — the same equations for
    # flexure + tension, with Pc = φt·Pn per Section D2 (page 134),
    # on the sagging face and on the hogging face. Tension Mr is first-order.
    Pu_t_N = [to_newtons(p) for p in Pu_t]
    M1x_Nm = _moment_vector_nm(M1x)
    M2x_Nm = _moment_vector_nm(M2x)
    M1y_Nm = _moment_vector_nm(M1y)
    M2y_Nm = _moment_vector_nm(M2y)
    demands = [_steel_array_demand(i, Pu_N, Pu_t_N, Mux_Nm, Mux_pos_Nm, Mux_neg_Nm,
                                   Muy_Nm, Vus_N, δ_m, δ_tot, Ir_m4,
                                   M1x_Nm, M2x_Nm, M1y_Nm, M2y_Nm, transverse_load,
                                   _resolve_demand_composite(opts, composite, i))
               for i in 1:n]
    
    checker = AISCChecker(; max_depth = opts.max_depth,
                            deflection_limit = _deflection_limit(opts),
                            total_deflection_limit = _total_deflection_limit(opts),
                            shell_spans = shell_spans === nothing ?
                                Vector{SteelShellSpan}[] : shell_spans)
    
    # Optimize — multi-material if materials vector is provided.
    # `feasible` (per-group candidate restriction) is forwarded unchanged; it is
    # `nothing` for every existing caller (byte-identical) and only set by the
    # batched StructuralSynthesizer member_group_overrides path.
    if !isnothing(opts.materials)
        result = optimize_discrete(
            checker, demands, steel_geoms, cat, opts.materials;
            objective = opts.objective,
            n_max_sections = opts.n_max_sections,
            optimizer = opts.solver,
            mip_gap = mip_gap,
            output_flag = output_flag,
            time_limit_sec = opts.time_limit_sec,
            feasible = feasible,
            mip_start = mip_start,
            tc = tc,
        )
    else
        result = optimize_discrete(
            checker, demands, steel_geoms, cat, opts.material;
            objective = opts.objective,
            n_max_sections = opts.n_max_sections,
            optimizer = opts.solver,
            mip_gap = mip_gap,
            output_flag = output_flag,
            time_limit_sec = opts.time_limit_sec,
            feasible = feasible,
            mip_start = mip_start,
            tc = tc,
        )
        # Diagnosis only. SS_TRACE_SHELL_PASSES=1 prints, per group, the
        # governing check of the chosen shape and why the next lighter one failed.
        get(ENV, "SS_TRACE_SHELL_PASSES", "") == "1" &&
            _trace_steel_choice(checker, demands, steel_geoms, cat, opts.material, result)
    end
    emit!(tc, :sizing, "size_columns", "", :exit; status=string(result.status))
    return result
end

function _trace_steel_choice(checker, demands, geoms, cat, material, result)
    cache = create_cache(checker, length(cat))
    precompute_capacities!(checker, cache, cat, material, MinVolume())
    order = sortperm([ustrip(u"m^2", s.A) for s in cat])
    rank = invperm(order)
    fmt(c) = "$(c.name) $(round(c.ratio; digits = 2))"
    ft(x) = round(to_meters(x) / 0.3048; digits = 1)
    for (i, j) in enumerate(result.section_indices)
        j > 0 || continue
        d = demands[i]
        ex = explain_feasibility(checker, cache, j, cat[j], material, d, geoms[i])
        line = "  steel group $i  $(cat[j].name)  governs: $(ex.governing_check) " *
               "$(round(ex.governing_ratio; digits = 2))" *
               "  [Pu_c=$(round(d.Pu_c / 4448.22; digits = 1)) Pu_t=$(round(d.Pu_t / 4448.22; digits = 1)) kip," *
               " Mu+=$(round(d.Mux_pos / 1355.82; digits = 1)) Mu-=$(round(d.Mux_neg / 1355.82; digits = 1))" *
               " Muy=$(round(d.Muy / 1355.82; digits = 1)) kip·ft, L=$(ft(geoms[i].L))" *
               " Lb=$(ft(geoms[i].Lb)) ft, composite=$(nameof(typeof(d.composite)))]"
        if rank[j] > 1
            k = order[rank[j] - 1]
            lighter = explain_feasibility(checker, cache, k, cat[k], material, d, geoms[i])
            fails = [fmt(c) for c in lighter.checks if !c.passed]
            line *= "\n      lighter $(cat[k].name) fails: $(isempty(fails) ? "nothing (not chosen for another reason)" : join(fails, ", "))"
        end
        println(line)
    end
end

# ==============================================================================
# Concrete Implementation
# ==============================================================================

"""
    size_columns(Pu, Mux, geometries, opts::ConcreteColumnOptions; Muy=...) -> NamedTuple

Positional adapter retained for back-compat. Synthesises `RCColumnDemand`s from
the envelope vectors and forwards to the demand-driven overload below. The
end-moment signs are unknown, so single curvature is assumed (`M1 = −M2`,
ACI 318-19 sign convention): `Cm = 1.0` (Eq. 6.6.4.5.3a) and the braced
slenderness limit 34 + 12(M1/M2) = 22 (Eq. 6.2.5.1b), the worst case of both.
Callers that have signed end moments (e.g. from FEA in `StructuralSynthesizer`)
should pass demands directly via the second overload.
"""
function size_columns(
    Pu::Vector,
    Mux::Vector,
    geometries::Vector,
    opts::ConcreteColumnOptions;
    Muy::Vector = zeros_like(Mux),
    catalog::Union{Nothing, AbstractVector} = nothing,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
    cache::Union{Nothing, AbstractCapacityCache} = nothing,
    tc::Union{Nothing, TraceCollector} = nothing,
)
    n = length(Pu)
    n == length(Mux) || throw(ArgumentError("Pu and Mux must have same length"))
    n == length(geometries) || throw(ArgumentError("demands and geometries must have same length"))

    Pu_kip    = [to_kip(p)    for p in Pu]
    Mux_kipft = [to_kipft(m)  for m in Mux]
    Muy_kipft = [to_kipft(m)  for m in Muy]

    demands = [RCColumnDemand(i;
                   Pu  = Pu_kip[i],
                   Mux = abs(Mux_kipft[i]), M1x = -abs(Mux_kipft[i]), M2x = abs(Mux_kipft[i]),
                   Muy = abs(Muy_kipft[i]), M1y = -abs(Muy_kipft[i]), M2y = abs(Muy_kipft[i]),
                   βdns = opts.βdns) for i in 1:n]

    return size_columns(demands, geometries, opts;
                        catalog=catalog,
                        mip_gap=mip_gap, output_flag=output_flag,
                        cache=cache, tc=tc)
end

"""
    size_columns(demands::Vector{<:RCColumnDemand}, geometries, opts::ConcreteColumnOptions; ...) -> NamedTuple
    size_columns(demands::Vector{<:RCColumnDemandSet}, geometries, opts::ConcreteColumnOptions; ...) -> NamedTuple

Demand-driven concrete column sizing. Preserves end moments
(`M1x/M2x/M1y/M2y`) and the `transverse_load` flag from the demand so the
slenderness path computes `Cm` per ACI 318-19 §6.6.4.5.3 instead of the
conservative `M1 = 0` stand-in. With [`RCColumnDemandSet`](@ref)s each group's
section must pass every one of its load cases.

Routes to the NLP path when `opts.sizing_strategy == :nlp`; otherwise runs the
discrete MIP catalog optimisation. A demand set is one constraint row per
case on the NLP path, and one checker case per load on the discrete path.

`feasible` is an optional per-group list of allowed catalog indices. It only
removes candidates; every remaining one still goes through the checker. It
needs the discrete strategy and a single-material catalog.
"""
function size_columns(
    demands::Vector{<:Union{RCColumnDemand, RCColumnDemandSet}},
    geometries::Vector,
    opts::ConcreteColumnOptions;
    catalog::Union{Nothing, AbstractVector} = nothing,
    feasible::Union{Nothing, Vector{Vector{Int}}} = nothing,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
    cache::Union{Nothing, AbstractCapacityCache} = nothing,
    tc::Union{Nothing, TraceCollector} = nothing,
)
    n = length(demands)
    n == length(geometries) || throw(ArgumentError("demands and geometries must have same length"))
    strategy = _require_sizing_strategy(
        opts, (:discrete, :nlp); api="concrete column sizing")

    # ─── NLP path ───
    if strategy === :nlp
        feasible === nothing || throw(ArgumentError(
            "concrete column NLP sizing has no catalog, so a feasible mask needs the :discrete strategy"))
        emit!(tc, :sizing, "size_columns", "", :enter;
              material="concrete",
              n_members=n,
              options_type=string(typeof(opts)),
              sizing_strategy=string(opts.sizing_strategy),
              path="nlp")
        # Pass the caller demands through. Rebuilding from Pu/Mux/Muy alone
        # drops M1/M2 and transverse_load, so the as-built check would use
        # Cm from M1 = 0 instead of the demand the caller supplied.
        return _size_columns_nlp(demands, geometries, opts)
    end

    # ─── MIP catalog path ───
    emit!(tc, :sizing, "size_columns", "", :enter;
          material="concrete",
          n_members=n,
          options_type=string(typeof(opts)),
          sizing_strategy=string(opts.sizing_strategy),
          path="discrete_mip",
          include_slenderness=opts.include_slenderness,
          include_biaxial=opts.include_biaxial,
          section_shape=string(opts.section_shape))

    conc_geoms = [to_concrete_geometry(g) for g in geometries]

    # Catalog precedence (Phase 6): explicit `catalog` kwarg (per-group
    # override) > `opts.custom_catalog` > material-default `rc_column_catalog`.
    cat = !isnothing(catalog) ? catalog :
        (isnothing(opts.custom_catalog) ?
            rc_column_catalog(opts.section_shape, opts.catalog) :
            opts.custom_catalog)

    checker = ACIColumnChecker(;
        include_slenderness = opts.include_slenderness,
        include_biaxial = opts.include_biaxial,
        fy_ksi = ustrip(ksi, opts.rebar_material.Fy),
        Es_ksi = ustrip(ksi, opts.rebar_material.E),
        max_depth = opts.max_depth,
    )

    opts.catalog_constraint in (:hard, :soft) || throw(ArgumentError(
        "catalog_constraint must be :hard or :soft (got :$(opts.catalog_constraint))"))
    if !isnothing(opts.materials)
        feasible === nothing || throw(ArgumentError(
            "a feasible mask indexes one catalog; it is not supported with several materials"))
    end
    # A named catalog grows one tier at a time when a group has no section
    # and `catalog_constraint` is `:soft`. `:hard`, an explicit or custom
    # catalog, or a feasibility mask is used as given.
    tier = (opts.catalog_constraint === :soft && isnothing(catalog) &&
            isnothing(opts.custom_catalog) && feasible === nothing) ? opts.catalog : nothing
    # Longitudinal and transverse rebar enter the discrete objective.
    transverse = get_transverse_rebar(opts)
    run(sections) = isnothing(opts.materials) ?
        optimize_discrete(
            checker, demands, conc_geoms, sections,
            _sizing_material(opts.material, opts.rebar_material, transverse);
            objective = opts.objective,
            n_max_sections = opts.n_max_sections,
            optimizer = opts.solver,
            mip_gap = mip_gap,
            output_flag = output_flag,
            time_limit_sec = opts.time_limit_sec,
            cache = cache,
            feasible = feasible,
            tc = tc,
        ) :
        optimize_discrete(
            checker, demands, conc_geoms, sections,
            [_sizing_material(m, opts.rebar_material, transverse) for m in opts.materials];
            objective = opts.objective,
            n_max_sections = opts.n_max_sections,
            optimizer = opts.solver,
            mip_gap = mip_gap,
            output_flag = output_flag,
            time_limit_sec = opts.time_limit_sec,
            tc = tc,
            feasible = feasible,
        )
    result = nothing
    while true
        try
            result = run(cat)
            break
        catch e
            grown = tier isa Symbol ?
                grow_rc_column_catalog(cat, opts.section_shape, tier) : nothing
            (grown !== nothing && e isa ArgumentError &&
                startswith(e.msg, "No feasible sections for group")) || rethrow()
            cat, nxt = grown
            depth_in = round(Int, maximum(_column_size_in, cat))
            @warn "RC column sizing: no section in the :$tier catalog passes; " *
                  "retrying with :$nxt added (sizes to $(depth_in) in)." reason = e.msg
            emit!(tc, :sizing, "size_columns", "", :decision;
                  phase = "catalog_growth", from = string(tier), to = string(nxt))
            tier = nxt
        end
    end
    emit!(tc, :sizing, "size_columns", "", :exit; status=string(result.status))
    return result
end

"Next named RC column catalog. `:all` is the top and is absent."
const _RC_COLUMN_CATALOG_GROWTH = Dict{Tuple{Symbol, Symbol}, Symbol}(
    (:rect, :low_capacity) => :standard,
    (:rect, :square) => :high_capacity,
    (:rect, :standard) => :high_capacity,
    (:rect, :rectangular) => :high_capacity,
    (:rect, :high_capacity) => :all,
    (:circular, :low_capacity) => :standard,
    (:circular, :standard) => :high_capacity,
    (:circular, :high_capacity) => :all,
)

"Larger plan dimension of a column section, in inches."
_column_size_in(s::RCColumnSection) = ustrip(u"inch", max(s.b, s.h))
_column_size_in(s::RCCircularSection) = ustrip(u"inch", s.D)

"Identity of a catalog section, so a merged catalog does not repeat a layout."
function _rc_column_key(s::RCColumnSection)
    bars = Tuple((ustrip(u"inch", b.x), ustrip(u"inch", b.y), ustrip(u"inch^2", b.As))
                 for b in s.bars)
    return (:rect, ustrip(u"inch", s.b), ustrip(u"inch", s.h),
            ustrip(u"inch", s.cover), s.tie_type, bars)
end
function _rc_column_key(s::RCCircularSection)
    bars = Tuple((ustrip(u"inch", b.x), ustrip(u"inch", b.y), ustrip(u"inch^2", b.As))
                 for b in s.bars)
    return (:circular, ustrip(u"inch", s.D), ustrip(u"inch", s.cover), s.tie_type, bars)
end

_merge_rc_column_catalogs(a, b) = unique(_rc_column_key, vcat(a, b))

"""
    grow_rc_column_catalog(cat, section_shape, tier) -> Union{Nothing, Tuple{Vector, Symbol}}

One step up from the named catalog `tier` that just failed, merged into `cat`.
`nothing` when `tier` is already the top or is not a named catalog.

`:standard` and `:square` are square sections. The sections added from the
next catalog on that step are the squares, so the first bump does not open
a rectangular plan.
"""
function grow_rc_column_catalog(cat, section_shape::Symbol, tier::Symbol)
    shape = section_shape === :circular ? :circular : :rect
    next = get(_RC_COLUMN_CATALOG_GROWTH, (shape, tier), nothing)
    next === nothing && return nothing
    added = rc_column_catalog(shape, next)
    if shape === :rect && tier in (:standard, :square)
        added = filter(s -> ustrip(u"inch", s.b) ≈ ustrip(u"inch", s.h), added)
    end
    return (_merge_rc_column_catalogs(cat, added), next)
end

"""
    _size_columns_nlp(demands, geometries, opts) -> NamedTuple

NLP column sizing adapter. Constructs `NLPColumnOptions` from the shared
`ConcreteColumnOptions` fields, calls `size_rc_columns_nlp` with the caller
[`RCColumnDemand`](@ref)s (so `M1`/`M2` and `transverse_load` reach the
as-built check), and wraps the results into the same
`(; section_indices, sections, status, objective_value)` NamedTuple that the
MIP catalog path returns.

`status` is `:nlp_complete` only when every column is `:optimal`, `:feasible`,
or `:converged` after the as-built check. Otherwise `status` is `:infeasible`
and every entry of `sections` is `nothing`, so a rejected section cannot be
installed as a completed design. [`_rc_nlp_result_installable`](@ref) is the
predicate installers use.
"""
function _size_columns_nlp(
    demands::Vector{<:Union{RCColumnDemand, RCColumnDemandSet}},
    geometries::Vector,
    opts::ConcreteColumnOptions,
)
    max_dim = isfinite(opts.max_depth) ? opts.max_depth : 48.0u"inch"

    nlp_opts = NLPColumnOptions(
        material            = opts.material,
        rebar_material      = opts.rebar_material,
        cover               = opts.cover,
        tie_type            = :tied,
        min_dim             = 8.0u"inch",
        max_dim             = max_dim,
        dim_increment       = opts.nlp_dim_increment,
        aspect_limit        = opts.nlp_aspect_limit,
        prefer_square       = opts.nlp_prefer_square,
        include_slenderness = opts.include_slenderness,
        βdns                = opts.βdns,
        bar_size            = 8,
        ρ_max               = opts.nlp_ρ_max,
        solver              = opts.nlp_solver,
        objective           = opts.objective,
        maxiter             = opts.nlp_maxiter,
        tol                 = opts.nlp_tol,
        n_multistart        = opts.nlp_n_multistart,
    )

    conc_geoms = [to_concrete_geometry(g) for g in geometries]
    nlp_results = size_rc_columns_nlp(demands, conc_geoms, nlp_opts)
    return _rc_nlp_export_result(nlp_results, opts, conc_geoms)
end

"""
    _rc_nlp_result_installable(result) -> Bool

True when `result` may be written onto a building as a completed column design.

The RC NLP adapter uses the Symbol `:nlp_complete` only when every column
passed the as-built check, and then only if `sections` contains no `nothing`.
Any other Symbol status (`:infeasible`, `:failed`, ...) is not installable.
A non-Symbol status is a discrete-MIP `MathOptInterface` termination code and
is left to that path.
"""
function _rc_nlp_result_installable(result)
    hasproperty(result, :status) || return true
    st = result.status
    st isa Symbol || return true
    st === :nlp_complete || return false
    hasproperty(result, :sections) || return false
    return all(s -> !isnothing(s), result.sections)
end

"""
    _rc_nlp_export_result(nlp_results, opts, conc_geoms) -> NamedTuple

MIP-shaped export of rectangular NLP column results.

`:nlp_complete` requires every per-column status to be acceptable
([`_rc_column_nlp_acceptable`](@ref)). If any column is not, the aggregate
status is `:infeasible` and `sections` is all `nothing`.
"""
function _rc_nlp_export_result(
    nlp_results::Vector{RCColumnNLPResult},
    opts::ConcreteColumnOptions,
    conc_geoms::Vector,
)
    n = length(nlp_results)
    ok = all(_rc_column_nlp_acceptable(r.status) for r in nlp_results)
    sections = if ok
        RCColumnSection[r.section for r in nlp_results]
    else
        Union{RCColumnSection,Nothing}[nothing for _ in 1:n]
    end
    obj_val = if ok && n > 0
        concrete = opts.material isa ReinforcedConcreteMaterial ? opts.material.concrete : opts.material
        rebar = opts.material isa ReinforcedConcreteMaterial ? opts.material.rebar : opts.rebar_material
        transverse = opts.material isa ReinforcedConcreteMaterial ? opts.material.transverse :
                     get_transverse_rebar(opts)
        ustrip(sum(
            objective_value(opts.objective, r.section, concrete, conc_geoms[i].L;
                            rebar=rebar, transverse=transverse)
            for (i, r) in enumerate(nlp_results)
        ))
    else
        0.0
    end
    return (;
        section_indices = collect(1:n),
        sections        = sections,
        status          = ok ? :nlp_complete : :infeasible,
        normalized_status = ok ? :optimal : :infeasible,
        objective_value = obj_val,
        objective       = opts.objective,
        backend         = :nlp,
        diagnostics     = String[],
    )
end

"""NLP Mux / geometry that also covers hogging Chapter F (`Lb=L`, `Cb=1.0`)."""
function _nlp_hogging_demands(Mux::Vector, Mux_neg::Vector, geometries::Vector{<:SteelMemberGeometry})
    n = length(Mux)
    n == length(Mux_neg) || throw(ArgumentError("Mux and Mux_neg must have same length"))
    n == length(geometries) || throw(ArgumentError("Mux and geometries must have same length"))
    Mux_use = Vector{typeof(0.0u"N*m")}(undef, n)
    geoms_use = Vector{SteelMemberGeometry}(undef, n)
    for i in 1:n
        mx = to_newton_meters(Mux[i])
        mn = to_newton_meters(Mux_neg[i])
        Mux_use[i] = max(mx, mn) * u"N*m"
        g = geometries[i]
        # Deck-braced Lb < L or sagging Cb > 1 makes hogging LTB stricter.
        # AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103.
        hog_stricter = _hogging_is_stricter(g)
        geoms_use[i] = hog_stricter ? _hogging_chapter_f_geometry(g) : g
    end
    return Mux_use, geoms_use
end

"""
    _size_steel_columns_nlp(Pu, Mux, geometries, opts; Muy, Mux_neg, composite) -> NamedTuple

Steel column NLP adapter. Maps SteelColumnOptions to NLPWOptions or NLPHSSOptions,
calls size_w_columns_nlp or size_hss_columns_nlp, and returns MIP-compatible result shape.

`Mux_neg` is threaded so hogging Chapter F (`Lb=L`, `Cb=1.0`) governs the
continuous W/HSS solve when deck-braced sagging `Lb`/`Cb` would otherwise
drop the signed face (AISC 360-16 §F2.2, page 103).

`composite` is forwarded onto each `MemberDemand` (Chapter I `CompositeContext`
callers are routed to MIP by `size_columns` before this adapter runs).
"""
function _size_steel_columns_nlp(
    Pu::Vector, Mux::Vector, geometries::Vector{<:SteelMemberGeometry},
    opts::SteelMemberOptions;
    Muy::Vector = zeros_like(Mux),
    Mux_neg::Vector = Mux,
    composite::Union{Nothing, Bool, CompositeContext, PerStationComposite, AbstractVector} = nothing,
)
    max_d = isfinite(ustrip(u"mm", opts.max_depth)) ? opts.max_depth : 36.0u"inch"
    Muy_vec = length(Muy) >= length(Pu) ? Muy : [i <= length(Muy) ? Muy[i] : 0.0 for i in 1:length(Pu)]
    Mux_use, geoms_use = _nlp_hogging_demands(Mux, Mux_neg, geometries)
    n = length(Pu)
    composite_vec = [_resolve_demand_composite(opts, composite, i) for i in 1:n]

    if opts.section_type === :w
        nlp_opts = NLPWOptions(material=opts.material, max_depth=max_d, objective=opts.objective)
        # WColumnNLPProblem reapplies hogging geometry when Mux_neg > 0.
        # Pass the original member then, so the rule runs once. When
        # Mux_neg is not positive that constructor leaves Lb/Cb unchanged,
        # and the geometry from _nlp_hogging_demands is the only application.
        geoms_w = [
            to_kipft(Mux_neg[i]) > 0 ? geometries[i] : geoms_use[i]
            for i in 1:n
        ]
        nlp_results = size_w_columns_nlp(Pu, Mux_use, geoms_w, nlp_opts;
                                         Muy=Muy_vec, Mux_neg=Mux_neg,
                                         composite=composite_vec)
    elseif opts.section_type === :hss
        nlp_opts = NLPHSSOptions(material=opts.material, max_outer=max_d, objective=opts.objective)
        nlp_results = size_hss_columns_nlp(Pu, Mux_use, geoms_use, nlp_opts; Muy=Muy_vec)
    else
        throw(ArgumentError("Steel NLP only supports section_type :w or :hss (got :$(opts.section_type))"))
    end

    return _steel_nlp_export_result(nlp_results, opts, geometries)
end

"""True when a steel NLP child result is safe to install."""
_steel_nlp_child_installable(status::Symbol) = status in (:optimal, :feasible)

"""
    _steel_nlp_export_result(nlp_results, opts, geometries) -> NamedTuple

Adapt per-member steel NLP results to the public member-sizing shape. Aggregate
success requires every child to be installable; failed children are never
returned as completed sections.
"""
function _steel_nlp_export_result(nlp_results, opts::SteelMemberOptions, geometries)
    n = length(nlp_results)
    n == length(geometries) || throw(ArgumentError(
        "NLP results and geometries must have the same length"))
    ok = all(r -> _steel_nlp_child_installable(r.status), nlp_results)
    sections = ok ? [r.section for r in nlp_results] : fill(nothing, n)
    status = if ok
        :nlp_complete
    elseif any(r -> r.status === :infeasible, nlp_results)
        :infeasible
    else
        :failed
    end
    obj_val = if ok && n > 0
        ustrip(sum(
            objective_value(opts.objective, r.section, opts.material, geometries[i].L)
            for (i, r) in enumerate(nlp_results)
        ))
    else
        0.0
    end
    return (;
        section_indices = collect(1:n),
        sections        = sections,
        status          = status,
        normalized_status = ok ? :optimal : status,
        objective_value = obj_val,
        objective       = opts.objective,
        backend         = :nlp,
        diagnostics     = String[],
    )
end

"""True when an aggregate steel NLP result may be installed."""
function _steel_nlp_result_installable(result)
    hasproperty(result, :status) || return false
    result.status === :nlp_complete || return false
    hasproperty(result, :sections) || return false
    return all(s -> !isnothing(s), result.sections)
end

