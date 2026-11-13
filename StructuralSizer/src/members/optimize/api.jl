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
  prior behaviour exactly. This is the hook `MemberGroup.catalog_override`
  (Phase 6) routes through so a single member group can be restricted to a
  specific catalog without forking the sizing functions. Ignored on the NLP
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
    n == length(geometries) || throw(ArgumentError("demands and geometries must have same length"))
    n == length(Pu_t) || throw(ArgumentError("Pu and Pu_t must have same length"))
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
    if opts.sizing_strategy == :nlp && opts.section_type in (:w, :hss) &&
            !_has_composite_context(opts, composite, n) &&
            all(iszero, Pu_t)
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

    # Catalog precedence (Phase 6): explicit `catalog` kwarg (per-group override
    # routed from `MemberGroup.catalog_override`) > `opts.custom_catalog` >
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
                            total_deflection_limit = _total_deflection_limit(opts))
    
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
    end
    emit!(tc, :sizing, "size_columns", "", :exit; status=string(result.status))
    return result
end

# ==============================================================================
# Concrete Implementation
# ==============================================================================

"""
    size_columns(Pu, Mux, geometries, opts::ConcreteColumnOptions; Muy=...) -> NamedTuple

Positional adapter retained for back-compat. Synthesises `RCColumnDemand`s from
the envelope vectors (using `M1=0`, `transverse_load=false` as conservative
stand-ins) and forwards to the demand-driven overload below. Callers that
already have signed end moments (e.g. extracted from FEA in
`StructuralSynthesizer`) should pass demands directly via the second overload
to avoid this lossy step.
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
                   Mux = Mux_kipft[i],
                   Muy = Muy_kipft[i],
                   βdns = opts.βdns) for i in 1:n]

    return size_columns(demands, geometries, opts;
                        catalog=catalog,
                        mip_gap=mip_gap, output_flag=output_flag,
                        cache=cache, tc=tc)
end

"""
    size_columns(demands::Vector{<:RCColumnDemand}, geometries, opts::ConcreteColumnOptions; ...) -> NamedTuple

Demand-driven concrete column sizing. Preserves end moments
(`M1x/M2x/M1y/M2y`) and the `transverse_load` flag from the demand so the
slenderness path computes `Cm` per ACI 318-19 §6.6.4.5.3 instead of the
conservative `M1 = 0` stand-in.

Routes to the NLP path when `opts.sizing_strategy == :nlp`; otherwise runs the
discrete MIP catalog optimisation.
"""
function size_columns(
    demands::Vector{<:Union{RCColumnDemand,RCColumnDemandSet}},
    geometries::Vector,
    opts::ConcreteColumnOptions;
    catalog::Union{Nothing, AbstractVector} = nothing,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
    cache::Union{Nothing, AbstractCapacityCache} = nothing,
    tc::Union{Nothing, TraceCollector} = nothing,
    feasible::Union{Nothing, Vector{Vector{Int}}} = nothing,
)
    n = length(demands)
    n == length(geometries) || throw(ArgumentError("demands and geometries must have same length"))

    # ─── NLP path ───
    if opts.sizing_strategy == :nlp
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

    if !isnothing(opts.materials)
        result = optimize_discrete(
            checker, demands, conc_geoms, cat,
            [_sizing_material(m, opts.rebar_material, get_transverse_rebar(opts)) for m in opts.materials];
            objective = opts.objective,
            n_max_sections = opts.n_max_sections,
            optimizer = opts.solver,
            mip_gap = mip_gap,
            output_flag = output_flag,
            time_limit_sec = opts.time_limit_sec,
            tc = tc,
            feasible = feasible,
        )
    else
        result = optimize_discrete(
            checker, demands, conc_geoms, cat, _sizing_material(opts.material, opts.rebar_material, get_transverse_rebar(opts));
            objective = opts.objective,
            n_max_sections = opts.n_max_sections,
            optimizer = opts.solver,
            mip_gap = mip_gap,
            output_flag = output_flag,
            time_limit_sec = opts.time_limit_sec,
            cache = cache,
            tc = tc,
            feasible = feasible,
        )
    end
    emit!(tc, :sizing, "size_columns", "", :exit; status=string(result.status))
    return result
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
    demands::Vector{<:Union{RCColumnDemand,RCColumnDemandSet}},
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
        objective_value = obj_val,
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

    sections = [r.section for r in nlp_results]
    L_ft = [uconvert(u"ft", g.L) for g in geometries]
    obj_val = ustrip(sum(r.weight_per_ft * u"lb/ft" * L_ft[i] for (i, r) in enumerate(nlp_results)))

    return (;
        section_indices = collect(1:length(sections)),
        sections        = sections,
        status          = :nlp_complete,
        objective_value = obj_val,
    )
end

# ==============================================================================
# Geometry Converters
# ==============================================================================

"""
    to_steel_geometry(geom) -> SteelMemberGeometry

Convert any geometry to steel geometry. Concrete geometry now carries per-axis
`kx`/`ky`, which map directly onto `SteelMemberGeometry`'s `Kx`/`Ky`.
"""
function to_steel_geometry(geom::ConcreteMemberGeometry)
    SteelMemberGeometry(geom.L; Lb=geom.Lu, Kx=geom.kx, Ky=geom.ky)
end
to_steel_geometry(geom::SteelMemberGeometry) = geom

"""
    to_concrete_geometry(geom) -> ConcreteMemberGeometry

Convert any geometry to concrete geometry, preserving per-axis effective length
factors (`Kx → kx`, `Ky → ky`). The previous version collapsed both axes onto
`Ky`, which silently discarded strong-axis bracing information.
"""
function to_concrete_geometry(geom::SteelMemberGeometry)
    ConcreteMemberGeometry(geom.L; Lu=geom.Lb, kx=geom.Kx, ky=geom.Ky)
end
to_concrete_geometry(geom::ConcreteMemberGeometry) = geom

"""
    convert_geometries(geometries, target::Symbol)

Convert geometries to target type (`:steel` or `:concrete`).
"""
function convert_geometries(geometries::Vector, target::Symbol)
    if target === :steel
        return [to_steel_geometry(g) for g in geometries]
    elseif target === :concrete
        return [to_concrete_geometry(g) for g in geometries]
    else
        throw(ArgumentError("Unknown target=$target. Use :steel or :concrete"))
    end
end

# ==============================================================================
# Demand Converters
# ==============================================================================

"""
    to_steel_demands(demands) -> Vector{MemberDemand}

Convert RC demands to steel demands. Preserves end moments (M1x, M2x, M1y, M2y)
and the `transverse_load` flag so the AISC B1 amplification path sees the
same Cm context as the ACI slenderness path.
"""
function to_steel_demands(demands::Vector{<:RCColumnDemand})
    [MemberDemand(d.member_idx;
                  Pu_c=d.Pu, Mux=d.Mux, Muy=d.Muy,
                  M1x=d.M1x, M2x=d.M2x, M1y=d.M1y, M2y=d.M2y,
                  transverse_load=d.transverse_load)
     for d in demands]
end
to_steel_demands(demands::Vector{<:MemberDemand}) = demands

"""
    to_rc_demands(demands; βdns=0.6) -> Vector{RCColumnDemand}

Convert steel/general member demands to RC column demands. Forwards end
moments (`M1x/M2x/M1y/M2y`) and the `transverse_load` flag so the ACI
slenderness path can compute `Cm = 0.6 − 0.4·(M1/M2)` per ACI 318-19
§6.6.4.5.3 instead of falling back on the conservative `M1=0` stand-in.
"""
function to_rc_demands(demands::Vector{<:MemberDemand}; βdns=0.6)
    [RCColumnDemand(d.member_idx;
                    Pu=d.Pu_c, Mux=d.Mux, Muy=d.Muy,
                    M1x=d.M1x, M2x=d.M2x, M1y=d.M1y, M2y=d.M2y,
                    βdns=βdns,
                    transverse_load=d.transverse_load)
     for d in demands]
end
to_rc_demands(demands::Vector{<:RCColumnDemand}; βdns=nothing) = demands

# ==============================================================================
# RC Beam Sizing (Discrete Catalog Optimization)
# ==============================================================================

"""
    size_beams(Mu, Vu, geometries, opts::ConcreteBeamOptions; Nu=..., Tu=..., ...)

Size reinforced concrete beams using discrete catalog optimization.
Selects the lightest (or minimum-objective) RCBeamSection that satisfies
ACI 318-11 flexure and shear requirements.

# Arguments
- `Mu`: Vector of factored moments — any moment unit (N·m, kN·m, kip·ft, etc.)
- `Vu`: Vector of factored shears — any force unit (N, kN, kip, etc.)
- `geometries`: Member geometries (span length via `ConcreteMemberGeometry`)
- `opts`: `ConcreteBeamOptions`

# Keyword Arguments
- `Nu`: Vector of factored axial compressions (default: zeros). When > 0,
  the shear checker increases Vc per ACI §22.5.6.1.
- `Tu`: Vector of factored torsional moments (default: zeros, kip·in or Unitful).
  When > threshold torsion, the MIP checker checks cross-section adequacy
  per ACI 318-11 §11.5.3.1.
- `catalog`: Optional per-call catalog override (default `nothing`); takes
  precedence over `opts.custom_catalog` and the standard `rc_beam_catalog`.
  This is the hook `MemberGroup.catalog_override` (Phase 6) routes through.
- `mip_gap`: MIP optimality gap (default 1e-4)
- `output_flag`: Solver verbosity (default 0)

# Returns
Named tuple with:
- `sections`: Optimal `RCBeamSection` per member
- `section_indices`: Indices into catalog
- `status`: Solver status
- `objective_value`: Final objective value

# Example
```julia
Mu = [100.0, 200.0] .* kip .* u"ft"
Vu = [30.0, 50.0] .* kip
geoms = [ConcreteMemberGeometry(6.0u"m") for _ in 1:2]
result = size_beams(Mu, Vu, geoms, ConcreteBeamOptions())

# With axial compression on member 2:
Nu = [0.0, 50.0] .* kip
result = size_beams(Mu, Vu, geoms, ConcreteBeamOptions(); Nu=Nu)

# With torsion on member 1:
Tu = [80.0, 0.0]   # kip·in (or Unitful: [80.0u"kip*inch", 0.0u"kip*inch"])
result = size_beams(Mu, Vu, geoms, ConcreteBeamOptions(); Tu=Tu)
```
"""
function size_beams end

"""One span list per demand, or none. `nothing` and an empty list both skip the check."""
function _beam_shell_spans(shell_spans, n::Int)
    shell_spans === nothing && return Vector{RCShellSpan}[]
    length(shell_spans) == n ||
        throw(ArgumentError("shell_spans must have one list per demand"))
    return shell_spans
end

"""Shear rows in kip. `nothing` keeps each demand's envelope Vu, Nu, and Tu."""
function _checker_shear_cases(shear_cases, n::Int)
    shear_cases === nothing && return Vector{RCBeamShearCase}[]
    length(shear_cases) == n ||
        throw(ArgumentError("shear_cases must have one list per demand"))
    out = Vector{Vector{RCBeamShearCase}}(undef, n)
    for i in 1:n
        rows = shear_cases[i]
        if rows === nothing
            out[i] = RCBeamShearCase[]
            continue
        end
        built = RCBeamShearCase[]
        for c in rows
            if c isa RCBeamShearCase
                push!(built, c)
            elseif c isa RCBeamNLPShearCase
                push!(built, RCBeamShearCase(c.Vu_kip, c.Nu_kip, c.Tu_kipin))
            else
                Vu, Nu, Tu = c
                push!(built, RCBeamShearCase(
                    Vu isa Unitful.Quantity ? to_kip(Vu) : Float64(Vu),
                    Nu isa Unitful.Quantity ? to_kip(Nu) : Float64(Nu),
                    Tu isa Unitful.Quantity ? abs(ustrip(kip * u"inch", Tu)) : abs(Float64(Tu)),
                ))
            end
        end
        out[i] = built
    end
    return out
end

function size_beams(
    Mu::Vector,
    Vu::Vector,
    geometries::Vector,
    opts::ConcreteBeamOptions;
    Mu_neg::Vector = Mu,
    Nu::Vector = zeros_like(Vu),
    Tu::Vector = Float64[],
    catalog::Union{Nothing, AbstractVector} = nothing,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
    tc::Union{Nothing, TraceCollector} = nothing,
    feasible::Union{Nothing, Vector{Vector{Int}}} = nothing,
    shell_spans = nothing,
    shear_cases = nothing,
)
    n = length(Mu)
    n == length(Vu)          || throw(ArgumentError("Mu and Vu must have same length"))
    n == length(geometries)  || throw(ArgumentError("demands and geometries must have same length"))

    emit!(tc, :sizing, "size_beams", "", :enter;
          material="concrete",
          n_members=n,
          options_type=string(typeof(opts)),
          sizing_strategy="discrete_mip")

    # Convert geometries
    conc_geoms = [to_concrete_geometry(g) for g in geometries]

    # Build catalog — Phase 6 precedence: explicit `catalog` kwarg (per-group
    # override) > `opts.custom_catalog` > material-default `rc_beam_catalog`.
    cat = !isnothing(catalog) ? catalog :
        (isnothing(opts.custom_catalog) ?
            rc_beam_catalog(opts.catalog) :
            opts.custom_catalog)

    # Convert forces / moments to kip / kip·ft
    Mu_kipft = [to_kipft(m) for m in Mu]
    Mu_neg_kipft = [to_kipft(m) for m in Mu_neg]
    Vu_kip   = [to_kip(v)   for v in Vu]
    Nu_kip   = [to_kip(n)   for n in Nu]

    # Convert torsion to kip·in (raw number)
    Tu_kipin = if isempty(Tu)
        zeros(n)
    else
        [t isa Unitful.Quantity ? abs(ustrip(kip*u"inch", t)) : abs(Float64(t)) for t in Tu]
    end

    # Build demands (Nu, Tu, Mu_neg flow to checker via RCBeamDemand fields)
    demands = [RCBeamDemand(i; Mu=Mu_kipft[i], Mu_neg=Mu_neg_kipft[i],
                            Vu=Vu_kip[i], Nu=Nu_kip[i], Tu=Tu_kipin[i]) for i in 1:n]

    spans = _beam_shell_spans(shell_spans, n)
    # Create checker
    checker = ACIBeamChecker(;
        fy_ksi  = ustrip(ksi, opts.rebar_material.Fy),
        fyt_ksi = ustrip(ksi, get_transverse_rebar(opts).Fy),
        Es_ksi  = ustrip(ksi, opts.rebar_material.E),
        λ       = opts.material.λ,       # Lightweight factor from Concrete type
        max_depth = opts.max_depth,
        shell_spans = spans,
        shear_cases = _checker_shear_cases(shear_cases, n),
    )

    # Optimize — multi-material if grades vector is provided
    if !isnothing(opts.materials)
        result = optimize_discrete(
            checker, demands, conc_geoms, cat,
            [_sizing_material(m, opts.rebar_material, get_transverse_rebar(opts)) for m in opts.materials];
            objective      = opts.objective,
            n_max_sections = opts.n_max_sections,
            optimizer      = opts.solver,
            mip_gap        = mip_gap,
            output_flag    = output_flag,
            time_limit_sec = opts.time_limit_sec,
            tc             = tc,
            feasible       = feasible,
        )
    else
        result = optimize_discrete(
            checker, demands, conc_geoms, cat, _sizing_material(opts.material, opts.rebar_material, get_transverse_rebar(opts));
            objective      = opts.objective,
            n_max_sections = opts.n_max_sections,
            optimizer      = opts.solver,
            mip_gap        = mip_gap,
            output_flag    = output_flag,
            time_limit_sec = opts.time_limit_sec,
            tc             = tc,
            feasible       = feasible,
        )
    end
    emit!(tc, :sizing, "size_beams", "", :exit; status=string(result.status))
    return result
end

# ==============================================================================
# Steel Beam Sizing (via AISC Checker; axial optional)
# ==============================================================================

"""
    size_beams(Mu, Vu, geometries, opts::SteelBeamOptions; Pu, δ_max_vec, ...)

Size steel beams using discrete catalog optimization.

Uses the AISC 360 checker. Default `Pu = 0` (pure flexure). When axial
compression is present — including composite beams with nonzero `Pu_c` —
pass `Pu` explicitly; do **not** zero it. Required flexural strengths then
include App. 8 B1 amplification into §H1 (AISC 360-16 Appendix 8 Eqs. A-8-1 /
A-8-3 — corpus: aisc-360-16, pages 305–306; §H1.1 — page 133).
`CompositeContext` + `Pu` reach 8-arg `is_feasible` via `size_columns`.

# Deflection constraints

When `opts.deflection_limit` is set (e.g. `1/360`), the optimizer enforces
`δ_scaled / L ≤ deflection_limit` where `δ_scaled = δ_max_LL × I_ref / Ix`.
Similarly for `opts.total_deflection_limit` (e.g. `1/240`) using `δ_max_total`.

Pass `δ_max_vec` (LL) and/or `δ_max_total_vec` (DL+LL), plus `I_ref_vec`,
from an Asap FEM analysis (or equivalent). The checker scales deflection
linearly with `1/Ix` for each candidate section.

Without the deflection vectors, the checks are skipped (consistent with
the checker requiring δ_max_LL > 0 / δ_max_total > 0).

# Arguments
- `Mu`: Vector of factored moments — any moment unit (N·m, kN·m, kip·ft, etc.)
- `Vu`: Vector of factored shears — any force unit
- `geometries`: Member geometries (span via `SteelMemberGeometry`)
- `opts`: `SteelBeamOptions`

# Keyword Arguments
- `Pu`: Factored axial compressions (default: zeros). Forwarded to `size_columns`
  as `Pu_c` for §H1 / App. 8 B1. Do not zero for composite beam-columns.
- `Pu_t`: Factored axial tension magnitudes (default: zeros). Forwarded onto
  `MemberDemand.Pu_t` for AISC 360-16 §H1.2 (Eqs. H1-1a/H1-1b with Pc = φt·Pn;
  corpus: aisc-360-16, page 134). Compression stays on `Pu` (§H1.1, page 133).
- `δ_max_vec`: Max LL deflection from analysis for each beam (length unit, e.g. m or inch).
- `δ_max_total_vec`: Max DL+LL service deflection for each beam (length unit).
- `I_ref_vec`: Reference Ix used in the analysis for each beam (length⁴ unit).
- `catalog`: Optional per-call catalog override (default `nothing`), forwarded to
  `size_columns`; the hook `MemberGroup.catalog_override` (Phase 6) routes through.
- `feasible`: Optional per-group vector of ALLOWED catalog indices, forwarded to
  `optimize_discrete` and INTERSECTED with the internal capacity screening. Used
  by the batched StructuralSynthesizer `member_group_overrides` path to narrow a
  single beam group's candidates; `nothing` (default) is byte-identical.
- `mip_start`: Optional per-group vector of prior catalog indices forwarded to
  `optimize_discrete` as a MIP warm start (solver hint only; does not change the
  optimum). `nothing` (default) is byte-identical.
- `composite`: Optional `CompositeContext` (or per-member vector) forwarded onto
  each `MemberDemand`. A vector entry of `nothing` does not override
  `opts.composite == true`. Hogging Chapter F (`Cb=1.0`, `Lb=L`) is applied
  by 6-arg `is_feasible` whenever `Mux_neg` is set (default `Mux_neg=Mu`).
- `mip_gap`: MIP optimality gap (default 1e-4)
- `output_flag`: Solver verbosity (default 0)

# Returns
Named tuple with:
- `sections`: Optimal sections (one per member)
- `section_indices`: Indices into catalog
- `status`: Solver status
- `objective_value`: Final objective value

# Example
```julia
Mu = [150.0, 200.0] .* u"kN*m"
Vu = [100.0, 120.0] .* u"kN"
geoms = [SteelMemberGeometry(8.0; Kx=1.0, Ky=1.0) for _ in 1:2]

# Strength only
result = size_beams(Mu, Vu, geoms, SteelBeamOptions(section_type=:w))

# With L/360 deflection constraint (δ_max_LL and I_ref from Asap analysis)
opts = SteelBeamOptions(section_type=:w, deflection_limit=1/360)
result = size_beams(Mu, Vu, geoms, opts;
                    δ_max_vec=[0.025, 0.030],   # meters
                    I_ref_vec=[1.5e-4, 2.0e-4])  # m⁴
```
"""
function size_beams(
    Mu::Vector,
    Vu::Vector,
    geometries::Vector,
    opts::SteelBeamOptions;
    Pu::Vector = zeros_like(Vu),
    Pu_t::Vector = zeros_like(Vu),
    Mux_pos::Vector = Mu,
    Mux_neg::Vector = Mu,
    δ_max_vec::Union{Nothing, Vector} = nothing,
    δ_max_total_vec::Union{Nothing, Vector} = nothing,
    I_ref_vec::Union{Nothing, Vector} = nothing,
    catalog::Union{Nothing, AbstractVector} = nothing,
    feasible::Union{Nothing, Vector{Vector{Int}}} = nothing,
    mip_start::Union{Nothing, Vector{Int}} = nothing,
    composite::Union{Nothing, Bool, CompositeContext, PerStationComposite, AbstractVector} = nothing,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
    tc::Union{Nothing, TraceCollector} = nothing,
    M1x::Union{Nothing, Vector} = nothing,
    M2x::Union{Nothing, Vector} = nothing,
    M1y::Union{Nothing, Vector} = nothing,
    M2y::Union{Nothing, Vector} = nothing,
    transverse_load::Union{Nothing, Bool, AbstractVector} = nothing,
    shell_spans = nothing,
)
    length(Pu) == length(Mu) || throw(ArgumentError("Pu and Mu must have same length"))
    # The story shell passes one span list per group. This checker has no
    # shell-span slot, so a live-load limit cannot be applied to those spans.
    if shell_spans !== nothing && opts.deflection_limit !== nothing &&
            any(!isempty, shell_spans)
        throw(ArgumentError(
            "steel beam sizing cannot apply story-shell live-load spans"))
    end
    length(Pu_t) == length(Mu) || throw(ArgumentError("Pu_t and Mu must have same length"))
    # AISC 360-16 §H1.1 (compression, page 133) and §H1.2 (tension, page 134)
    # — corpus: aisc-360-16. `Pu` is Pu_c; `Pu_t` is the tension magnitude.
    # App. 8 §8.2.1 (PDF page 306): end moments for Eq. A-8-4, or
    # `transverse_load` for Cm = 1.0 on a member loaded between supports.
    return size_columns(Pu, Mu, geometries, opts;
                        Pu_t=Pu_t,
                        Mux_pos=Mux_pos, Mux_neg=Mux_neg,
                        Vu_strong=Vu,
                        δ_max_vec=δ_max_vec,
                        δ_max_total_vec=δ_max_total_vec,
                        I_ref_vec=I_ref_vec,
                        catalog=catalog,
                        feasible=feasible,
                        mip_start=mip_start,
                        composite=composite,
                        mip_gap=mip_gap, output_flag=output_flag,
                        tc=tc,
                        M1x=M1x, M2x=M2x, M1y=M1y, M2y=M2y,
                        transverse_load=transverse_load)
end

# ==============================================================================
# PixelFrame Beam Sizing (MIP Discrete Catalog)
# ==============================================================================

"""
    size_beams(Mu, Vu, geometries, opts::PixelFrameBeamOptions; ...)

Size PixelFrame beams using discrete catalog optimization.

Generates a catalog of `PixelFrameSection`s (or uses `opts.custom_catalog`),
then selects the minimum-objective section satisfying ACI 318-19 flexure/axial
and fib MC2010 FRC shear requirements via MIP.

Validates that each beam span is an exact multiple of `opts.pixel_length`.
Raises `ArgumentError` if any span is not divisible.

# Arguments
- `Mu`: Vector of factored moments — any moment unit (N·m, kN·m, kip·ft, etc.)
- `Vu`: Vector of factored shears — any force unit (N, kN, kip, etc.)
- `geometries`: Member geometries (span via `ConcreteMemberGeometry`)
- `opts`: `PixelFrameBeamOptions`

# Keyword Arguments
- `Pu`: Vector of factored axial compressions (default: zeros)
- `catalog`: Optional per-call catalog override (default `nothing`); takes
  precedence over `opts.custom_catalog` and the generated PixelFrame catalog.
  This is the hook `MemberGroup.catalog_override` (Phase 6) routes through.
- `mip_gap`: MIP optimality gap (default 1e-4)
- `output_flag`: Solver verbosity (default 0)

# Returns
Named tuple with:
- `sections`: Optimal `PixelFrameSection` per member (governing section)
- `section_indices`: Indices into catalog
- `n_pixels`: Vector{Int} — number of pixels per member
- `status`: Solver status
- `objective_value`: Final objective value

# Example
```julia
Mu = [5.0, 10.0] .* u"kN*m"
Vu = [15.0, 25.0] .* u"kN"
geoms = [ConcreteMemberGeometry(6.0u"m") for _ in 1:2]
result = size_beams(Mu, Vu, geoms, PixelFrameBeamOptions())
```
"""
function size_beams(
    Mu::Vector,
    Vu::Vector,
    geometries::Vector,
    opts::PixelFrameBeamOptions;
    Pu::Vector = zeros_like(Vu),
    catalog::Union{Nothing, AbstractVector} = nothing,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
    tc::Union{Nothing, TraceCollector} = nothing,
)
    n = length(Mu)
    n == length(Vu)         || throw(ArgumentError("Mu and Vu must have same length"))
    n == length(geometries) || throw(ArgumentError("demands and geometries must have same length"))

    emit!(tc, :sizing, "size_beams", "", :enter;
          material="pixelframe",
          n_members=n,
          options_type=string(typeof(opts)),
          sizing_strategy="discrete_mip")

    # Convert geometries
    conc_geoms = [to_concrete_geometry(g) for g in geometries]

    # Strip pixel length to mm at the boundary
    px_mm = _pf_pixel_mm(opts)

    # Validate pixel divisibility for each member span
    n_pixels_vec = Vector{Int}(undef, n)
    for i in 1:n
        L_mm = ustrip(u"mm", conc_geoms[i].L)
        n_pixels_vec[i] = validate_pixel_divisibility(L_mm, px_mm; label="Beam $i")
    end

    # Build catalog — Phase 6 precedence: explicit `catalog` kwarg (per-group
    # override) > `opts.custom_catalog` > generated PixelFrame catalog.
    cat = if !isnothing(catalog)
        catalog
    elseif !isnothing(opts.custom_catalog)
        opts.custom_catalog
    else
        generate_pixelframe_catalog(; _pf_catalog_kwargs(opts)...)
    end

    # Convert forces / moments to SI (N, N·m) for PixelFrame checker
    Pu_N   = [to_newtons(p) for p in Pu]
    Mu_Nm  = [to_newton_meters(m) for m in Mu]
    Vu_N   = [to_newtons(v) for v in Vu]

    # Build demands (SI units — PixelFrame checker uses N / N·m)
    demands = [MemberDemand(i; Pu_c=Pu_N[i], Mux=Mu_Nm[i], Vu_strong=Vu_N[i]) for i in 1:n]

    # Create checker — strip Unitful at the boundary via _pf_checker_kwargs
    checker = PixelFrameChecker(; _pf_checker_kwargs(opts)...)

    # Material placeholder — PixelFrame material is embedded in sections
    # Use the first section's material for the interface requirement
    mat = isempty(cat) ? FiberReinforcedConcrete(NWC_4000, 20.0, 1.0, 1.0) : cat[1].material

    mip_result = optimize_discrete(
        checker, demands, conc_geoms, cat, mat;
        objective      = opts.objective,
        n_max_sections = opts.n_max_sections,
        optimizer      = opts.solver,
        mip_gap        = mip_gap,
        output_flag    = output_flag,
        time_limit_sec = opts.time_limit_sec,
        tc             = tc,
    )

    emit!(tc, :sizing, "size_beams", "", :exit; status=string(mip_result.status))
    return (; mip_result..., n_pixels=n_pixels_vec)
end

# ==============================================================================
# PixelFrame Column Sizing (MIP Discrete Catalog)
# ==============================================================================

"""
    size_columns(Pu, Mux, geometries, opts::PixelFrameColumnOptions; Muy=...)

Size PixelFrame columns using discrete catalog optimization.

Generates a catalog of `PixelFrameSection`s (or uses `opts.custom_catalog`),
then selects the minimum-objective section satisfying ACI 318-19 axial/flexural
and fib MC2010 FRC shear requirements via MIP.

Validates that each column height is an exact multiple of `opts.pixel_length`.
Raises `ArgumentError` if any height is not divisible.

# Arguments
- `Pu`: Vector of factored axial loads — any force unit (N, kN, kip, etc.)
- `Mux`: Vector of factored moments about x-axis — any moment unit
- `geometries`: Member geometries (via `ConcreteMemberGeometry`)
- `opts`: `PixelFrameColumnOptions`

# Keyword Arguments
- `Muy`: Vector of factored moments about y-axis (default: zeros)
- `catalog`: Optional per-call catalog override (default `nothing`); takes
  precedence over `opts.custom_catalog` and the generated PixelFrame catalog.
  This is the hook `MemberGroup.catalog_override` (Phase 6) routes through.
- `mip_gap`: MIP optimality gap (default 1e-4)
- `output_flag`: Solver verbosity (default 0)

# Returns
Named tuple with:
- `sections`: Optimal `PixelFrameSection` per member (governing section)
- `section_indices`: Indices into catalog
- `n_pixels`: Vector{Int} — number of pixels per member
- `status`: Solver status
- `objective_value`: Final objective value

# Example
```julia
Pu  = [50.0, 100.0] .* u"kN"
Mux = [5.0, 10.0] .* u"kN*m"
geoms = [ConcreteMemberGeometry(4.0u"m") for _ in 1:2]
result = size_columns(Pu, Mux, geoms, PixelFrameColumnOptions())
```
"""
function size_columns(
    Pu::Vector,
    Mux::Vector,
    geometries::Vector,
    opts::PixelFrameColumnOptions;
    Muy::Vector = zeros_like(Mux),
    catalog::Union{Nothing, AbstractVector} = nothing,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
    tc::Union{Nothing, TraceCollector} = nothing,
)
    n = length(Pu)
    n == length(Mux)        || throw(ArgumentError("Pu and Mux must have same length"))
    n == length(geometries) || throw(ArgumentError("demands and geometries must have same length"))

    emit!(tc, :sizing, "size_columns", "", :enter;
          material="pixelframe",
          n_members=n,
          options_type=string(typeof(opts)),
          sizing_strategy="discrete_mip")

    # Convert geometries
    conc_geoms = [to_concrete_geometry(g) for g in geometries]

    # Strip pixel length to mm at the boundary
    px_mm = _pf_pixel_mm(opts)

    # Validate pixel divisibility for each column height
    n_pixels_vec = Vector{Int}(undef, n)
    for i in 1:n
        L_mm = ustrip(u"mm", conc_geoms[i].L)
        n_pixels_vec[i] = validate_pixel_divisibility(L_mm, px_mm; label="Column $i")
    end

    # Build catalog — Phase 6 precedence: explicit `catalog` kwarg (per-group
    # override) > `opts.custom_catalog` > generated PixelFrame catalog.
    cat = if !isnothing(catalog)
        catalog
    elseif !isnothing(opts.custom_catalog)
        opts.custom_catalog
    else
        generate_pixelframe_catalog(; _pf_catalog_kwargs(opts)...)
    end

    # Convert forces / moments to SI (N, N·m) for PixelFrame checker
    Pu_N   = [to_newtons(p) for p in Pu]
    Mux_Nm = [to_newton_meters(m) for m in Mux]
    Vu_N   = zeros(n)  # Columns: shear from moment demand (conservative: 0)

    # Build demands (SI units — PixelFrame checker uses N / N·m)
    demands = [MemberDemand(i; Pu_c=Pu_N[i], Mux=Mux_Nm[i], Vu_strong=Vu_N[i]) for i in 1:n]

    # Create checker — strip Unitful at the boundary via _pf_checker_kwargs
    checker = PixelFrameChecker(; _pf_checker_kwargs(opts)...)

    # Material placeholder — PixelFrame material is embedded in sections
    mat = isempty(cat) ? FiberReinforcedConcrete(NWC_4000, 20.0, 1.0, 1.0) : cat[1].material

    mip_result = optimize_discrete(
        checker, demands, conc_geoms, cat, mat;
        objective      = opts.objective,
        n_max_sections = opts.n_max_sections,
        optimizer      = opts.solver,
        mip_gap        = mip_gap,
        output_flag    = output_flag,
        time_limit_sec = opts.time_limit_sec,
        tc             = tc,
    )

    emit!(tc, :sizing, "size_columns", "", :exit; status=string(mip_result.status))
    return (; mip_result..., n_pixels=n_pixels_vec)
end

# ==============================================================================
# Unified Entry Point: size_members
# ==============================================================================

"""
    size_members(arg1, arg2, geometries, opts; ...)

Unified member sizing dispatcher. Routes to `size_columns` or `size_beams`
based on the options type:

| Options type               | Interpretation       | Delegates to     |
|:-------------------------- |:-------------------- |:---------------- |
| `ConcreteColumnOptions`    | arg1=Pu, arg2=Mux    | `size_columns`   |
| `ConcreteBeamOptions`      | arg1=Mu, arg2=Vu     | `size_beams`     |
| `PixelFrameColumnOptions`  | arg1=Pu, arg2=Mux    | `size_columns`   |
| `PixelFrameBeamOptions`    | arg1=Mu, arg2=Vu     | `size_beams`     |

For steel options (`SteelColumnOptions` / `SteelBeamOptions`),
call `size_columns` or `size_beams` directly since the type system cannot
distinguish the two cases.

# Example
```julia
# Concrete columns
result = size_members(Pu, Mux, geoms, ConcreteColumnOptions())

# Concrete beams
result = size_members(Mu, Vu, geoms, ConcreteBeamOptions())

# PixelFrame beams
result = size_members(Mu, Vu, geoms, PixelFrameBeamOptions())

# PixelFrame columns
result = size_members(Pu, Mux, geoms, PixelFrameColumnOptions())

# Steel — use size_beams / size_columns directly
result = size_beams(Mu, Vu, geoms, SteelBeamOptions())
result = size_columns(Pu, Mux, geoms, SteelColumnOptions())
```
"""
function size_members end

function size_members(
    Pu::Vector, Mux::Vector, geometries::Vector,
    opts::ConcreteColumnOptions; kwargs...
)
    tc = get(kwargs, :tc, nothing)
    emit!(tc, :sizing, "size_members", "", :enter;
          dispatch="concrete_columns",
          n_members=length(Pu),
          options_type=string(typeof(opts)))
    result = size_columns(Pu, Mux, geometries, opts; kwargs...)
    emit!(tc, :sizing, "size_members", "", :exit; status=string(result.status))
    return result
end

function size_members(
    Mu::Vector, Vu::Vector, geometries::Vector,
    opts::ConcreteBeamOptions; kwargs...
)
    tc = get(kwargs, :tc, nothing)
    emit!(tc, :sizing, "size_members", "", :enter;
          dispatch="concrete_beams",
          n_members=length(Mu),
          options_type=string(typeof(opts)))
    result = size_beams(Mu, Vu, geometries, opts; kwargs...)
    emit!(tc, :sizing, "size_members", "", :exit; status=string(result.status))
    return result
end

function size_members(
    Mu::Vector, Vu::Vector, geometries::Vector,
    opts::PixelFrameBeamOptions; kwargs...
)
    tc = get(kwargs, :tc, nothing)
    emit!(tc, :sizing, "size_members", "", :enter;
          dispatch="pixelframe_beams",
          n_members=length(Mu),
          options_type=string(typeof(opts)))
    result = size_beams(Mu, Vu, geometries, opts; kwargs...)
    emit!(tc, :sizing, "size_members", "", :exit; status=string(result.status))
    return result
end

function size_members(
    Pu::Vector, Mux::Vector, geometries::Vector,
    opts::PixelFrameColumnOptions; kwargs...
)
    tc = get(kwargs, :tc, nothing)
    emit!(tc, :sizing, "size_members", "", :enter;
          dispatch="pixelframe_columns",
          n_members=length(Pu),
          options_type=string(typeof(opts)))
    result = size_columns(Pu, Mux, geometries, opts; kwargs...)
    emit!(tc, :sizing, "size_members", "", :exit; status=string(result.status))
    return result
end

# ==============================================================================
# NLP Column Sizing (Continuous Optimization)
# ==============================================================================

"""Demand stored on the NLP problem and passed to the as-built checker.

A caller [`RCColumnDemand`](@ref) is kept as the same object, so `M1`/`M2`
and `transverse_load` are not replaced by the `M1 = 0` stand-in. `nothing`
builds that stand-in from the envelope `Pu`/`Mux`/`Muy`.
"""
function _rc_column_nlp_use_demand(
    Pu, Mux, Muy,
    opts::NLPColumnOptions,
    demand::Union{Nothing,RCColumnDemand},
)
    isnothing(demand) || return demand
    return RCColumnDemand(1;
        Pu = to_kip(Pu),
        Mux = to_kipft(Mux),
        Muy = to_kipft(Muy),
        βdns = opts.βdns,
    )
end

"""
    size_rc_column_nlp(Pu, Mux, geometry, opts::NLPColumnOptions; Muy=0) -> RCColumnNLPResult

Size a single RC column using continuous (NLP) optimization.

Unlike `size_columns` which selects from a discrete catalog, this function
optimizes column dimensions (b, h) and reinforcement ratio (ρg) continuously
to find the minimum-volume section that satisfies ACI 318 requirements.

Uses the interior point solver (Ipopt) by default via `optimize_continuous`.

# Arguments
- `Pu`: Factored axial load (compression positive) — any force unit
- `Mux`: Factored moment about x-axis — any moment unit
- `geometry`: `ConcreteMemberGeometry` with Lu, k, braced
- `opts`: `NLPColumnOptions` with material, bounds, solver settings

# Keyword Arguments
- `Muy`: Factored moment about y-axis (default: 0). Ignored when `demand` is set.
- `x0`: Optional start `[b, h, ρg]` in inches and ratio. Solved together
  with the axial-only start, unless it already matches that start.
  `nothing` (default) uses the moment-informed [`initial_guess`](@ref).
- `demand`: Caller [`RCColumnDemand`](@ref). When set, this object — including
  `M1`/`M2` and `transverse_load` — is the demand on the NLP problem and on
  the as-built `ACIColumnChecker` gate. `nothing` (default) builds an envelope
  stand-in with `M1 = 0` and `transverse_load = false`.

# Returns
`RCColumnNLPResult` with:
- `section`: Optimized `RCColumnSection` (rounded to practical dimensions)
- `b_opt`, `h_opt`, `ρ_opt`: Continuous optimal values
- `b_final`, `h_final`: Final dimensions after rounding
- `area`: Final cross-sectional area (sq in)
- `status`: `:optimal`, `:feasible`, `:converged`, `:infeasible`, `:failed`

# Example
```julia
using Unitful
using StructuralSizer: kip

# Define demand and geometry
Pu = 500.0kip
Mux = 200.0kip * u"ft"
geom = ConcreteMemberGeometry(4.0; k=1.0, braced=true)

# Size with defaults
result = size_rc_column_nlp(Pu, Mux, geom, NLPColumnOptions())
println("Optimal: \$(result.b_final)\" × \$(result.h_final)\"")

# Custom options
opts = NLPColumnOptions(
    material = NWC_5000,
    min_dim = 14.0u"inch",
    max_dim = 30.0u"inch",
    prefer_square = 0.1,
    verbose = true
)
result = size_rc_column_nlp(Pu, Mux, geom, opts)
```

# Algorithm
1. Formulates the problem as `RCColumnNLPProblem <: AbstractNLPProblem`
2. For Ipopt, solves from the axial-only start and from the moment-informed
   start (or an explicit `x0`). Random `n_multistart` samples do not replace
   that axial start.
3. Rounds each start's solution to a practical `RCColumnSection` and checks
   that built section with the real `ACIColumnChecker`, whatever the solver
   status. A failing section is repaired (more bars, then larger b and h
   within the bounds); if nothing passes, that start is `:infeasible`.
4. Keeps the acceptable as-built section with the better objective.
   `:infeasible` and `:failed` do not replace `:optimal`, `:feasible`, or
   `:converged`.

See also: [`size_columns`](@ref), [`NLPColumnOptions`](@ref), [`RCColumnNLPProblem`](@ref)
"""
function size_rc_column_nlp(
    Pu,
    Mux,
    geometry::ConcreteMemberGeometry,
    opts::NLPColumnOptions;
    Muy = 0.0,
    x0::Union{Nothing,Vector{Float64}} = nothing,
    demand::Union{Nothing,RCColumnDemand,RCColumnDemandSet} = nothing,
)
    problem = if demand isa RCColumnDemandSet
        RCColumnNLPProblem(demand, geometry, opts)
    else
        RCColumnNLPProblem(
            _rc_column_nlp_use_demand(Pu, Mux, Muy, opts, demand), geometry, opts)
    end

    # Grid / NLopt / NonConvex do not consume x0. One solve matches the
    # previous path. Ipopt is local, so try the axial-only basin too.
    if opts.solver !== :ipopt
        opt_result = optimize_continuous(
            problem;
            objective = opts.objective,
            solver = opts.solver,
            maxiter = opts.maxiter,
            tol = opts.tol,
            verbose = opts.verbose,
            x0 = x0,
            n_multistart = opts.n_multistart,
        )
        return _rc_column_nlp_verify_as_built(
            problem, build_rc_column_nlp_result(problem, opt_result))
    end

    x_axial = axial_only_initial_guess(problem)
    x_other = isnothing(x0) ? initial_guess(problem) : copy(x0)
    built = _solve_rc_column_nlp_from(problem, opts, x_axial)
    if !_rc_column_starts_match(problem, x_other, x_axial)
        other = _solve_rc_column_nlp_from(problem, opts, x_other)
        if _rc_column_nlp_candidate_wins(problem, built, other)
            built = other
        end
    end
    return built
end

"""Statuses that may win the two-start comparison.

`:optimal` and `:feasible` meet the KKT tolerance (or the relaxed one).
`:converged` is an iteration-limit or slow-progress stop. In
`size_rc_column_nlp` every status reaches the comparison only after
[`_rc_column_nlp_verify_as_built`](@ref), which turns a section that fails
the real ACI checker into `:infeasible`.
`:infeasible` and `:failed` are not candidates while another start is acceptable.
"""
function _rc_column_nlp_acceptable(status::Symbol)
    return status === :optimal || status === :feasible || status === :converged
end

"""True when two column starts are the same point inside the bounds."""
function _rc_column_starts_match(
    problem::RCColumnNLPProblem,
    a::Vector{Float64},
    b::Vector{Float64},
)
    length(a) == length(b) == n_variables(problem) || return false
    lb, ub = variable_bounds(problem)
    for i in eachindex(a)
        ai = clamp(a[i], lb[i], ub[i])
        bi = clamp(b[i], lb[i], ub[i])
        isapprox(ai, bi; atol=1e-8, rtol=1e-8) || return false
    end
    return true
end

"""Objective of the section `size_rc_column_nlp` would return. Lower is better.

`MinVolume` with no square penalty ranks by final gross area. Every other
objective, including `prefer_square`, uses `objective_fn` at the built
section (`b_final`, `h_final`, and the section's as-built `ρg`) so a squarer
section can win when that penalty asks for it.
"""
function _rc_column_returned_cost(problem::RCColumnNLPProblem, built::RCColumnNLPResult)
    if problem.opts.objective isa MinVolume && problem.opts.prefer_square <= 0
        return built.area
    end
    return objective_fn(problem, [built.b_final, built.h_final, built.section.ρg])
end

"""
    _rc_column_nlp_candidate_wins(problem, incumbent, candidate) -> Bool

`candidate` replaces the axial-only `incumbent` only when it is acceptable
and better. An `:infeasible` or `:failed` solve never replaces an acceptable
one. A start whose built section fails the real ACI checker (and cannot be
repaired) is already `:infeasible` before this comparison. When `prefer_square` is off,
a larger final area does not count as better.
"""
function _rc_column_nlp_candidate_wins(
    problem::RCColumnNLPProblem,
    incumbent::RCColumnNLPResult,
    candidate::RCColumnNLPResult,
)
    cand_ok = _rc_column_nlp_acceptable(candidate.status)
    inc_ok = _rc_column_nlp_acceptable(incumbent.status)
    cand_ok || return false
    inc_ok || return true

    area_smaller = candidate.area < incumbent.area - 1e-6
    area_larger = candidate.area > incumbent.area + 1e-6
    if problem.opts.prefer_square <= 0 && area_larger
        return false
    end

    c_cand = _rc_column_returned_cost(problem, candidate)
    c_inc = _rc_column_returned_cost(problem, incumbent)
    isfinite(c_cand) || return false
    isfinite(c_inc) || return true
    if c_cand < c_inc - 1e-8
        return true
    end
    # Equal objective: keep the smaller snapped section.
    return problem.opts.prefer_square <= 0 && area_smaller && c_cand <= c_inc + 1e-8
end

"""
    _rc_column_nlp_checker(opts) -> ACIColumnChecker

The real ACI column checker set up to enforce what `RCColumnNLPProblem` does:

- `include_slenderness = opts.include_slenderness` (the NLP magnifies Mux
  only when this is on).
- `include_biaxial = true` with `α_biaxial = 1.5`, the NLP's Bresler
  exponent. Both the checker and the NLP skip the biaxial check unless
  Muy > 0.
- `fy_ksi`, `Es_ksi` from `opts.rebar_material`, the same values the NLP
  material tuple uses.
- `max_depth = opts.max_dim`. The checker limits `h` only; `b` is checked
  against the bounds in [`_rc_column_as_built_ok`](@ref).
"""
function _rc_column_nlp_checker(opts::NLPColumnOptions)
    return ACIColumnChecker(;
        include_slenderness = opts.include_slenderness,
        include_biaxial = true,
        α_biaxial = 1.5,
        fy_ksi = fy_ksi(opts.rebar_material),
        Es_ksi = Es_ksi(opts.rebar_material),
        max_depth = opts.max_dim,
    )
end

"""Dimension slack (in) for the `min_dim`/`max_dim` bounds on a built section."""
const _RC_NLP_DIM_TOL_IN = 1e-6

"""
    _rc_column_rho_within_cap(ρg, ρ_max) -> Bool

True when `ρg` does not exceed `ρ_max`.

A section whose ratio is the cap can land one binary ulp above it. That single
ulp is accepted. A larger overshoot, including the `1e-8` band previously
allowed here, is not. This is not a relaxation of ACI 318-19 §10.6.1.1.
"""
function _rc_column_rho_within_cap(ρg::Real, ρ_max::Real)
    ρ = Float64(ρg)
    cap = Float64(ρ_max)
    ρ <= cap && return true
    return ρ <= nextfloat(cap)
end

"""
    _rc_column_as_built_ok(problem, checker, section) -> Bool

True when the built `section` can be returned:

1. `min_dim ≤ b, h ≤ max_dim` (the NLP variable bounds).
2. At most `RC_COLUMN_NLP_MAX_BARS` bars.
3. `0.01 ≤ ρg ≤ 0.08` — ACI 318-19 §10.6.1.1 (aci-318-19, p. 158) — and
   `ρg ≤ opts.ρ_max`. The practical cap does not replace the ACI limits.
   The checker does not test either ratio; this gate does.
4. `is_feasible` of the real `ACIColumnChecker` with every case on the
   problem (the caller demand when one was supplied, including `M1`/`M2`
   and `transverse_load`) and `problem.geometry`, on a one-section capacity cache.
"""
function _rc_column_as_built_ok(
    problem::RCColumnNLPProblem,
    checker::ACIColumnChecker,
    section::RCColumnSection,
)
    opts = problem.opts
    b = ustrip(u"inch", section.b)
    h = ustrip(u"inch", section.h)
    lo = problem.b_min - _RC_NLP_DIM_TOL_IN
    hi = problem.b_max + _RC_NLP_DIM_TOL_IN
    (lo <= b <= hi && lo <= h <= hi) || return false
    length(section.bars) <= RC_COLUMN_NLP_MAX_BARS || return false
    # ACI 318-19 §10.6.1.1 (aci-318-19, p. 158). opts.ρ_max is a tighter
    # practical cap and does not raise the ACI minimum or maximum.
    0.01 <= section.ρg <= 0.08 || return false
    _rc_column_rho_within_cap(section.ρg, opts.ρ_max) || return false

    cache = create_cache(checker, 1)
    # Objective coefficients are not used here; MinVolume needs no material data.
    precompute_capacities!(checker, cache, [section], opts.material, MinVolume())
    return is_feasible(checker, cache, 1, section, opts.material,
                       _rc_nlp_checked_demand(problem), problem.geometry)
end

"""One demand, or a set when the problem carries more than one case."""
function _rc_nlp_checked_demand(problem::RCColumnNLPProblem)
    length(problem.cases) == 1 && return problem.demand
    return RCColumnDemandSet(problem.demand.member_idx, problem.cases)
end

"""Copy of `built` with a different status."""
function _rc_column_nlp_with_status(built::RCColumnNLPResult, status::Symbol)
    return RCColumnNLPResult(
        built.section, built.b_opt, built.h_opt, built.ρ_opt,
        built.b_final, built.h_final, built.area, status, built.iterations)
end

"""
    _rc_column_nlp_repair(problem, checker, built) -> Union{RCColumnNLPResult, Nothing}

Smallest-first search for a section that passes [`_rc_column_as_built_ok`](@ref),
starting from the failed `built` section.

At each `b × h` (start: `b_final × h_final`, held to `max_dim`), try the bar
count `_build_nlp_trial_section` would use for `ρ_opt`, then add 2 bars at a
time while the count stays ≤ `RC_COLUMN_NLP_MAX_BARS` and the added steel
keeps `ρg ≤ opts.ρ_max`. A starting count that already exceeds `opts.ρ_max`
is not tried. If none passes, grow both `b` and `h` by `dim_increment`, each
held to `max_dim`, and retry.

Terminates when the proposed step does not increase `b` or `h` (including a
`dim_increment` so small that `b + incr == b` in Float64), once both sit at
`max_dim`, or when `dim_increment ≤ 0` or `max_dim` is not finite. Each inner
pass tries at most `RC_COLUMN_NLP_MAX_BARS / 2` counts. Returns `nothing`
when no section in that range passes. ACI 318-19 §10.6.1.1 (0.01 and 0.08)
still applies inside [`_rc_column_as_built_ok`](@ref); this search does not
raise `ρ_max` to make the minimum bar count legal.
"""
function _rc_column_nlp_repair(
    problem::RCColumnNLPProblem,
    checker::ACIColumnChecker,
    built::RCColumnNLPResult,
)
    opts = problem.opts
    A_bar = ustrip(u"inch^2", rebar(opts.bar_size).A)
    incr = ustrip(u"inch", opts.dim_increment)
    b_cap = problem.b_max
    b = min(built.b_final, b_cap)
    h = min(built.h_final, b_cap)
    n_failed = length(built.section.bars)
    b_failed = ustrip(u"inch", built.section.b)
    h_failed = ustrip(u"inch", built.section.h)

    while true
        n = _nlp_trial_bar_count(b, h, built.ρ_opt, opts)
        n_top = min(RC_COLUMN_NLP_MAX_BARS, floor(Int, opts.ρ_max * b * h / A_bar))
        # A starting count already over opts.ρ_max is not a candidate.
        # Adding bars would only raise ρg. Do not raise ρ_max to admit it.
        ρ_start = (b > 0 && h > 0) ? n * A_bar / (b * h) : Inf
        if n <= n_top && _rc_column_rho_within_cap(ρ_start, opts.ρ_max)
            while true
                # `built.section` already failed; do not check it twice.
                same_as_failed = n == n_failed && b == b_failed && h == h_failed
                if !same_as_failed
                    section = _build_nlp_column_section(b, h, n, opts)
                    if !isnothing(section) && _rc_column_as_built_ok(problem, checker, section)
                        return RCColumnNLPResult(
                            section, built.b_opt, built.h_opt, section.ρg,
                            b, h, b * h, built.status, built.iterations)
                    end
                end
                n + 2 <= n_top || break
                n += 2
            end
        end

        (incr > 0 && isfinite(b_cap)) || return nothing
        (b < b_cap || h < b_cap) || return nothing
        b_next = min(b + incr, b_cap)
        h_next = min(h + incr, b_cap)
        # Float64: an increment below spacing leaves b and h unchanged and
        # would otherwise spin while `b < b_cap` stays true.
        (b_next > b || h_next > h) || return nothing
        b = b_next
        h = h_next
    end
end

"""
    _rc_column_nlp_verify_as_built(problem, built) -> RCColumnNLPResult

Check the section `size_rc_column_nlp` would return with the real ACI
checker ([`_rc_column_as_built_ok`](@ref)), whatever the solver status.

- Acceptable status (`:optimal`, `:feasible`, `:converged`) and the built
  section passes: `built` is returned unchanged.
- It fails: [`_rc_column_nlp_repair`](@ref) adds bars, then grows the
  section. A repaired result keeps the solver status and reports the
  repaired section's `b_final`, `h_final`, `area`, and `ρ_opt = ρg`.
- No section passes: status becomes `:infeasible`, so the start cannot win
  the two-start comparison and callers do not treat it as usable.

`:infeasible` and `:failed` solves are returned unchanged.
"""
function _rc_column_nlp_verify_as_built(
    problem::RCColumnNLPProblem,
    built::RCColumnNLPResult,
)
    _rc_column_nlp_acceptable(built.status) || return built
    checker = _rc_column_nlp_checker(problem.opts)
    _rc_column_as_built_ok(problem, checker, built.section) && return built
    repaired = _rc_column_nlp_repair(problem, checker, built)
    return isnothing(repaired) ? _rc_column_nlp_with_status(built, :infeasible) : repaired
end

"""One Ipopt solve from `x_start`, returned as a snapped column result.

The returned section is verified (and repaired if needed) with the real ACI
checker before the caller compares the two starts.
"""
function _solve_rc_column_nlp_from(
    problem::RCColumnNLPProblem,
    opts::NLPColumnOptions,
    x_start::Vector{Float64},
)
    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose,
        x0 = x_start,
        n_multistart = opts.n_multistart,
    )
    return _rc_column_nlp_verify_as_built(
        problem, build_rc_column_nlp_result(problem, opt_result))
end

"""
    size_rc_columns_nlp(Pu, Mux, geometries, opts::NLPColumnOptions; Muy=...) -> Vector{RCColumnNLPResult}

Size multiple RC columns using continuous (NLP) optimization.

Applies `size_rc_column_nlp` to each column independently.

# Arguments
- `Pu`: Vector of factored axial loads
- `Mux`: Vector of factored moments about x-axis
- `geometries`: Vector of `ConcreteMemberGeometry`
- `opts`: `NLPColumnOptions` (shared for all columns)

# Keyword Arguments
- `Muy`: Vector of factored moments about y-axis (default: zeros)

# Returns
Vector of `RCColumnNLPResult`, one per column.

# Example
```julia
Pu = [400.0, 600.0, 800.0] .* kip
Mux = [150.0, 200.0, 250.0] .* kip .* u"ft"
geoms = [ConcreteMemberGeometry(4.0; k=1.0) for _ in 1:3]

results = size_rc_columns_nlp(Pu, Mux, geoms, NLPColumnOptions())
for (i, r) in enumerate(results)
    println("Column \$i: \$(r.b_final)\" × \$(r.h_final)\"")
end
```
"""
function size_rc_columns_nlp(
    Pu::Vector,
    Mux::Vector,
    geometries::Vector{<:ConcreteMemberGeometry},
    opts::NLPColumnOptions;
    Muy::Vector = zeros(length(Pu))
)
    n = length(Pu)
    n == length(Mux) || throw(ArgumentError("Pu and Mux must have same length"))
    n == length(geometries) || throw(ArgumentError("Pu and geometries must have same length"))
    
    results = Vector{RCColumnNLPResult}(undef, n)
    
    for i in 1:n
        Muy_i = i <= length(Muy) ? Muy[i] : 0.0
        results[i] = size_rc_column_nlp(Pu[i], Mux[i], geometries[i], opts; Muy=Muy_i)
    end
    
    return results
end

"""
    size_rc_columns_nlp(demands, geometries, opts) -> Vector{RCColumnNLPResult}

Size each column from its [`RCColumnDemand`](@ref), keeping `M1`/`M2` and
`transverse_load` on the NLP problem and the as-built check.
"""
function size_rc_columns_nlp(
    demands::Vector{<:Union{RCColumnDemand,RCColumnDemandSet}},
    geometries::Vector{<:ConcreteMemberGeometry},
    opts::NLPColumnOptions,
)
    n = length(demands)
    n == length(geometries) || throw(ArgumentError("demands and geometries must have same length"))
    results = Vector{RCColumnNLPResult}(undef, n)
    for i in 1:n
        d = demands[i]
        anchor = d isa RCColumnDemandSet ?
            d.cases[argmax([Float64(to_kip(c.Pu)) for c in d.cases])] : d
        results[i] = size_rc_column_nlp(
            anchor.Pu, anchor.Mux, geometries[i], opts; Muy=anchor.Muy, demand=d)
    end
    return results
end

# ==============================================================================
# RC Circular Column NLP Sizing (Continuous Optimization)
# ==============================================================================

"""
    size_rc_column_nlp(::Type{RCCircularSection}, Pu, Mux, geometry, opts) -> RCCircularNLPResult

Size a single circular RC column using continuous (NLP) optimization.

Optimizes column diameter (D) and reinforcement ratio (ρg) continuously
to find the minimum-area section that satisfies ACI 318 requirements.

# Arguments
- `Pu`: Factored axial load (compression positive) — any force unit
- `Mux`: Factored moment about x-axis — any moment unit
- `geometry`: `ConcreteMemberGeometry` with Lu, k, braced
- `opts`: `NLPColumnOptions` with material, bounds, solver settings.
  Use `tie_type=:spiral` for spiral confinement (typical for circular).

# Returns
`RCCircularNLPResult` with:
- `section`: Optimized `RCCircularSection` (rounded to practical diameter)
- `D_opt`, `ρ_opt`: Continuous optimal values
- `D_final`: Final diameter after rounding
- `area`: Final cross-sectional area (sq in)
- `status`: `:optimal`, `:feasible`, `:infeasible`, `:failed`

# Example
```julia
using Unitful
using StructuralSizer: kip

Pu = 500.0kip
Mux = 200.0kip * u"ft"
geom = ConcreteMemberGeometry(4.0; k=1.0, braced=true)

opts = NLPColumnOptions(tie_type=:spiral, min_dim=10.0u"inch", max_dim=36.0u"inch")
result = size_rc_column_nlp(RCCircularSection, Pu, Mux, geom, opts)
println("Optimal diameter: \$(result.D_final)\"")
```

See also: [`size_rc_column_nlp`](@ref), [`NLPColumnOptions`](@ref), [`RCCircularNLPProblem`](@ref)
"""
function size_rc_column_nlp(::Type{RCCircularSection},
    Pu,
    Mux,
    geometry::ConcreteMemberGeometry,
    opts::NLPColumnOptions;
    x0::Union{Nothing,Vector{Float64}} = nothing
)
    Pu_kip = to_kip(Pu)
    Mux_kipft = to_kipft(Mux)

    demand = RCColumnDemand(1;
        Pu = Pu_kip,
        Mux = Mux_kipft,
        Muy = 0.0,
        βdns = opts.βdns
    )

    problem = RCCircularNLPProblem(demand, geometry, opts)

    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose,
        x0 = x0,
        n_multistart = opts.n_multistart,
    )

    return build_rc_circular_nlp_result(problem, opt_result)
end

"""
    size_rc_columns_nlp(::Type{RCCircularSection}, Pu, Mux, geometries, opts) -> Vector{RCCircularNLPResult}

Size multiple circular RC columns using continuous (NLP) optimization.
Applies `size_rc_column_nlp(RCCircularSection, ...)` to each column independently.
"""
function size_rc_columns_nlp(::Type{RCCircularSection},
    Pu::Vector,
    Mux::Vector,
    geometries::Vector{<:ConcreteMemberGeometry},
    opts::NLPColumnOptions
)
    n = length(Pu)
    n == length(Mux) || throw(ArgumentError("Pu and Mux must have same length"))
    n == length(geometries) || throw(ArgumentError("Pu and geometries must have same length"))

    results = Vector{RCCircularNLPResult}(undef, n)
    for i in 1:n
        results[i] = size_rc_column_nlp(RCCircularSection, Pu[i], Mux[i], geometries[i], opts)
    end
    return results
end

# ==============================================================================
# RC Beam NLP Sizing (Continuous Optimization)
# ==============================================================================

"""
    size_rc_beam_nlp(Mu, Vu, opts::NLPBeamOptions) -> RCBeamNLPResult

Size a single RC beam using continuous (NLP) optimization.

Optimizes beam width (b), depth (h), and reinforcement ratio (ρ) to find
the minimum-area section satisfying ACI 318 flexure and shear requirements.

# Arguments
- `Mu`: Factored moment — any moment unit (kip·ft, kN·m, etc.)
- `Vu`: Factored shear — any force unit (kip, kN, etc.)
- `opts`: `NLPBeamOptions` with material, bounds, solver settings

# Returns
`RCBeamNLPResult` with:
- `section`: Constructed `RCBeamSection`
- `b_opt`, `h_opt`, `ρ_opt`: Continuous optimal values
- `b_final`, `h_final`: Final dimensions after optional snapping
- `area`: Final cross-sectional area (in²)
- `status`: Solver termination status

# Example
```julia
using Unitful
using StructuralSizer: kip

Mu = 200.0kip * u"ft"
Vu = 40.0kip
opts = NLPBeamOptions(min_depth=14.0u"inch", max_depth=30.0u"inch")
result = size_rc_beam_nlp(Mu, Vu, opts)
println("Section: \$(result.section.name), Area: \$(result.area) in²")
```
"""
function size_rc_beam_nlp(Mu, Vu, opts::NLPBeamOptions;
                          Tu = 0.0,
                          Nu = 0.0,
                          Mu_neg = nothing,
                          shear_cases = nothing,
                          flexure_cases = nothing,
                          w_dead = nothing,
                          w_live = nothing,
                          L_span = nothing,
                          defl_support::Symbol = :simply_supported,
                          defl_ξ::Float64 = 2.0,
                          sustained_live_fraction::Real = 0.0,
                          x0::Union{Nothing,Vector{Float64}} = nothing)
    problem = RCBeamNLPProblem(Mu, Vu, opts; Tu=Tu, Nu=Nu, shear_cases=shear_cases,
                               flexure_cases=flexure_cases,
                               w_dead=w_dead, w_live=w_live, L_span=L_span,
                               support=defl_support, ξ=defl_ξ,
                               sustained_live_fraction=sustained_live_fraction)

    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose,
        x0 = x0,
    )

    result = build_rc_beam_nlp_result(problem, opt_result)
    # Post-NLP hogging adequacy (top steel is not an NLP design variable).
    # The NLP therefore cannot deepen for Mu_neg; it may return :infeasible.
    # Public default Mu_neg = Mu (unsigned envelope) is unchanged.
    Mu_neg_kipft = to_kipft(isnothing(Mu_neg) ? Mu : Mu_neg)
    if !_neg_moment_adequate(result.section, Mu_neg_kipft, problem.fc_psi, problem.fy_psi)
        return RCBeamNLPResult(result.section, result.b_opt, result.h_opt, result.ρ_opt,
                               result.b_final, result.h_final, result.area,
                               :infeasible, result.iterations)
    end
    # The installed section, after bar rounding, still has to pass the same
    # deflection check the discrete beam uses (ACI 318-11 §9.5.2).
    if problem.w_dead_kiplf > 0
        sec = result.section
        defl = design_beam_deflection(
            sec.b, sec.h, sec.d, sec.As,
            problem.fc_psi * u"psi", problem.fy_psi * u"psi", problem.Es_ksi * ksi,
            problem.L_in * u"inch",
            problem.w_dead_kiplf * kip / u"ft",
            problem.w_live_kiplf * kip / u"ft";
            support = problem.defl_support,
            ξ = problem.defl_ξ,
            sustained_live_fraction = problem.defl_sustained_live,
        )
        defl.ok || return RCBeamNLPResult(result.section, result.b_opt, result.h_opt, result.ρ_opt,
                                          result.b_final, result.h_final, result.area,
                                          :infeasible, result.iterations)
    end
    return result
end

"""
    size_rc_beams_nlp(Mu, Vu, opts::NLPBeamOptions) -> Vector{RCBeamNLPResult}

Size multiple RC beams using continuous (NLP) optimization.
"""
function size_rc_beams_nlp(Mu::Vector, Vu::Vector, opts::NLPBeamOptions;
                           Mu_neg::Vector = Mu,
                           Nu::Vector = zeros_like(Vu),
                           shear_cases = nothing,
                           flexure_cases = nothing,
                           w_dead = nothing,
                           w_live = nothing,
                           L_span = nothing,
                           defl_support::Symbol = :simply_supported,
                           defl_ξ::Float64 = 2.0,
                           sustained_live_fraction::Real = 0.0)
    n = length(Mu)
    n == length(Vu) || throw(ArgumentError("Mu and Vu must have same length"))
    n == length(Mu_neg) || throw(ArgumentError("Mu_neg must have same length as Mu"))
    n == length(Nu) || throw(ArgumentError("Nu must have same length as Vu"))
    if shear_cases !== nothing
        length(shear_cases) == n ||
            throw(ArgumentError("shear_cases must have same length as Mu"))
    end
    if flexure_cases !== nothing
        length(flexure_cases) == n ||
            throw(ArgumentError("flexure_cases must have same length as Mu"))
    end

    results = Vector{RCBeamNLPResult}(undef, n)
    for i in 1:n
        sc = shear_cases === nothing ? nothing : shear_cases[i]
        fc = flexure_cases === nothing ? nothing : flexure_cases[i]
        wd = w_dead isa AbstractVector ? w_dead[i] : w_dead
        wl = w_live isa AbstractVector ? w_live[i] : w_live
        Ls = L_span isa AbstractVector ? L_span[i] : L_span
        results[i] = size_rc_beam_nlp(Mu[i], Vu[i], opts; Mu_neg=Mu_neg[i], Nu=Nu[i],
                                      shear_cases=sc, flexure_cases=fc,
                                      w_dead=wd, w_live=wl, L_span=Ls,
                                      defl_support=defl_support, defl_ξ=defl_ξ,
                                      sustained_live_fraction=sustained_live_fraction)
    end
    return results
end

# ==============================================================================
# HSS NLP Column Sizing (Continuous Optimization)
# ==============================================================================

"""
    size_hss_nlp(Pu, Mux, geometry, opts::NLPHSSOptions; Muy=0) -> HSSColumnNLPResult

Size a single rectangular HSS column using continuous (NLP) optimization.

Optimizes HSS dimensions (B, H, t) continuously to find the minimum-weight
section that satisfies AISC 360 requirements. Uses smooth approximations
of AISC functions for compatibility with automatic differentiation.

# Arguments
- `Pu`: Factored axial load (compression positive) — any force unit
- `Mux`: Factored moment about x-axis — any moment unit
- `geometry`: `SteelMemberGeometry` with L, Kx, Ky
- `opts`: `NLPHSSOptions` with material, bounds, solver settings

# Keyword Arguments
- `Muy`: Factored moment about y-axis (default: 0)

# Returns
`HSSColumnNLPResult` with:
- `section`: Optimized `HSSRectSection` (rounded to standard sizes)
- `B_opt`, `H_opt`, `t_opt`: Continuous optimal values
- `B_final`, `H_final`, `t_final`: Final dimensions after rounding
- `area`: Final cross-sectional area (sq in)
- `weight_per_ft`: Weight per linear foot (lb/ft)
- `status`: `:optimal`, `:feasible`, `:infeasible`, `:failed`

# Example
```julia
using Unitful

# Define demand and geometry
Pu = 500.0u"kN"
Mux = 50.0u"kN*m"
geom = SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0)

# Size with defaults
result = size_hss_nlp(Pu, Mux, geom, NLPHSSOptions())
println("Optimal: HSS \$(result.B_final)×\$(result.H_final)×\$(result.t_final)")

# Custom options
opts = NLPHSSOptions(
    material = A992_Steel,
    min_outer = 6.0u"inch",
    max_outer = 16.0u"inch",
    prefer_square = 0.1,
    verbose = true
)
result = size_hss_nlp(Pu, Mux, geom, opts)
```

# Algorithm
1. Formulates the problem as `HSSColumnNLPProblem <: AbstractNLPProblem`
2. Uses smooth AISC functions for differentiability
3. Calls `optimize_continuous(problem; solver=opts.solver)`
4. Rounds continuous solution to practical HSS sizes
5. Returns `HSSColumnNLPResult` with final section

See also: [`size_columns`](@ref), [`NLPHSSOptions`](@ref), [`HSSColumnNLPProblem`](@ref)
"""
function size_hss_nlp(
    Pu,
    Mux,
    geometry::SteelMemberGeometry,
    opts::NLPHSSOptions;
    Muy = 0.0,
    x0::Union{Nothing,Vector{Float64}} = nothing,
)
    demand = MemberDemand(1; 
        Pu_c = to_newtons(Pu) * u"N",
        Mux = to_newton_meters(Mux) * u"N*m",
        Muy = to_newton_meters(Muy) * u"N*m"
    )
    
    problem = HSSColumnNLPProblem(demand, geometry, opts)
    
    # Solve using the generic continuous optimizer
    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose,
        x0 = x0,
    )
    
    # Convert to user-friendly result
    return build_hss_nlp_result(problem, opt_result)
end

"""
    size_hss_columns_nlp(Pu, Mux, geometries, opts::NLPHSSOptions; Muy=...) -> Vector{HSSColumnNLPResult}

Size multiple HSS columns using continuous (NLP) optimization.

Applies `size_hss_nlp` to each column independently.

# Arguments
- `Pu`: Vector of factored axial loads
- `Mux`: Vector of factored moments about x-axis
- `geometries`: Vector of `SteelMemberGeometry`
- `opts`: `NLPHSSOptions` (shared for all columns)

# Keyword Arguments
- `Muy`: Vector of factored moments about y-axis (default: zeros)

# Returns
Vector of `HSSColumnNLPResult`, one per column.

# Example
```julia
Pu = [300.0, 500.0, 700.0] .* u"kN"
Mux = [30.0, 50.0, 70.0] .* u"kN*m"
geoms = [SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0) for _ in 1:3]

results = size_hss_columns_nlp(Pu, Mux, geoms, NLPHSSOptions())
for (i, r) in enumerate(results)
    println("Column \$i: HSS \$(r.B_final)×\$(r.H_final)×\$(r.t_final)")
end
```
"""
function size_hss_columns_nlp(
    Pu::Vector,
    Mux::Vector,
    geometries::Vector{<:SteelMemberGeometry},
    opts::NLPHSSOptions;
    Muy::Vector = zeros(length(Pu))
)
    n = length(Pu)
    n == length(Mux) || throw(ArgumentError("Pu and Mux must have same length"))
    n == length(geometries) || throw(ArgumentError("Pu and geometries must have same length"))
    
    results = Vector{HSSColumnNLPResult}(undef, n)
    
    for i in 1:n
        Muy_i = i <= length(Muy) ? Muy[i] : 0.0
        results[i] = size_hss_nlp(Pu[i], Mux[i], geometries[i], opts; Muy=Muy_i)
    end
    
    return results
end

# ==============================================================================
# W Section NLP Column Sizing (Continuous Optimization)
# ==============================================================================

"""
    size_w_nlp(Pu, Mux, geometry, opts::NLPWOptions; Muy=0, Mux_neg=Mux, composite=nothing) -> WColumnNLPResult

Size a W section column using continuous (NLP) optimization.

Optimizes W section dimensions (d, bf, tf, tw) continuously to find the 
minimum-weight section that satisfies AISC 360 requirements. Treats the
section as a parameterized I-shape (similar to a built-up section).

**Note**: The optimal dimensions are a custom continuous section and may not
match standard rolled W shapes. Use the MIP solver for catalog selection.

# Arguments
- `Pu`: Factored axial load (compression positive) — any force unit
- `Mux`: Factored moment about x-axis — any moment unit
- `geometry`: `SteelMemberGeometry` with L, Kx, Ky
- `opts`: `NLPWOptions` with material, bounds, solver settings

# Keyword Arguments
- `Muy`: Factored moment about y-axis (default: 0)
- `Mux_neg`: Hogging strong-axis moment (default: `Mux`). When `Mux_neg > 0`,
  sizes against `max(Mux, Mux_neg)` with hogging Chapter F (`Lb = L`,
  `Cb = 1.0`) if deck-braced sagging `Lb`/`Cb` would otherwise inflate φMn.
  AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103.
  # ENGINEERING JUDGMENT: hogging `Cb = 1.0` (no bottom-flange `Cb` field).
- `composite`: Optional `CompositeContext` / `true` / `nothing` stored on
  `MemberDemand`. Chapter I plastic capacity is evaluated by 8-arg
  `is_feasible` on the discrete MIP path (`size_columns` diverts NLP→MIP
  when a `CompositeContext` is present).

# Returns
`WColumnNLPResult` with:
- `d_opt`, `bf_opt`, `tf_opt`, `tw_opt`: Continuous optimal values
- `d_final`, `bf_final`, `tf_final`, `tw_final`: Final dimensions
- `area`: Cross-sectional area (sq in)
- `weight_per_ft`: Weight per linear foot (lb/ft)
- `Ix`, `Iy`, `rx`, `ry`: Section properties
- `status`: `:optimal`, `:feasible`, `:infeasible`, `:failed`

# Example
```julia
using Unitful

# Define demand and geometry
Pu = 1000.0u"kN"
Mux = 150.0u"kN*m"
geom = SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0)

# Size with defaults
result = size_w_nlp(Pu, Mux, geom, NLPWOptions())
println("Optimal: d=\$(result.d_final)\", bf=\$(result.bf_final)\"")
println("Weight: \$(round(result.weight_per_ft, digits=1)) lb/ft")
```

See also: [`size_columns`](@ref), [`NLPWOptions`](@ref), [`WColumnNLPProblem`](@ref)
"""
function size_w_nlp(
    Pu,
    Mux,
    geometry::SteelMemberGeometry,
    opts::NLPWOptions;
    Muy = 0.0,
    Mux_neg = Mux,
    composite = nothing,
    x0::Union{Nothing,Vector{Float64}} = nothing,
)
    demand = MemberDemand(1; 
        Pu_c = to_newtons(Pu) * u"N",
        Mux = to_newton_meters(Mux) * u"N*m",
        Mux_neg = to_newton_meters(Mux_neg) * u"N*m",
        Muy = to_newton_meters(Muy) * u"N*m",
        composite = composite,
    )
    
    problem = WColumnNLPProblem(demand, geometry, opts)
    
    # Solve using the generic continuous optimizer
    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose,
        x0 = x0,
    )
    
    # Convert to user-friendly result
    return build_w_nlp_result(problem, opt_result)
end

"""
    size_w_columns_nlp(Pu, Mux, geometries, opts::NLPWOptions; Muy, Mux_neg, composite) -> Vector{WColumnNLPResult}

Size multiple W section columns using continuous (NLP) optimization.

Applies `size_w_nlp` to each column independently.

# Arguments
- `Pu`: Vector of factored axial loads
- `Mux`: Vector of factored moments about x-axis
- `geometries`: Vector of `SteelMemberGeometry`
- `opts`: `NLPWOptions` (shared for all columns)

# Keyword Arguments
- `Muy`: Vector of factored moments about y-axis (default: zeros)
- `Mux_neg`: Vector of hogging strong-axis moments (default: `Mux`). Threaded
  into `size_w_nlp` so hogging Chapter F (`Lb=L`, `Cb=1.0`) can govern.
  AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103.
- `composite`: Per-member or scalar composite payload forwarded onto each
  `MemberDemand` (see `size_w_nlp`).

# Returns
Vector of `WColumnNLPResult`, one per column.

# Example
```julia
Pu = [500.0, 1000.0, 1500.0] .* u"kN"
Mux = [50.0, 100.0, 150.0] .* u"kN*m"
geoms = [SteelMemberGeometry(4.0; Kx=1.0, Ky=1.0) for _ in 1:3]

opts = NLPWOptions()
results = size_w_columns_nlp(Pu, Mux, geoms, opts)
for (i, r) in enumerate(results)
    println("Column \$i: d=\$(round(r.d_final, digits=1))\", \$(round(r.weight_per_ft))lb/ft")
end
```
"""
function size_w_columns_nlp(
    Pu::Vector,
    Mux::Vector,
    geometries::Vector{<:SteelMemberGeometry},
    opts::NLPWOptions;
    Muy::Vector = zeros(length(Pu)),
    Mux_neg::Vector = Mux,
    composite::Union{Nothing, Bool, CompositeContext, PerStationComposite, AbstractVector} = nothing,
)
    n = length(Pu)
    n == length(Mux) || throw(ArgumentError("Pu and Mux must have same length"))
    n == length(geometries) || throw(ArgumentError("Pu and geometries must have same length"))
    n == length(Mux_neg) || throw(ArgumentError("Pu and Mux_neg must have same length"))
    
    results = Vector{WColumnNLPResult}(undef, n)
    
    for i in 1:n
        Muy_i = i <= length(Muy) ? Muy[i] : 0.0
        comp_i = if composite isa AbstractVector
            i <= length(composite) || throw(ArgumentError(
                "composite vector must have one entry per member"))
            composite[i]
        else
            composite
        end
        results[i] = size_w_nlp(Pu[i], Mux[i], geometries[i], opts;
                                Muy=Muy_i, Mux_neg=Mux_neg[i], composite=comp_i)
    end
    
    return results
end

# ==============================================================================
# Steel W Beam NLP Sizing (Dedicated Beam Formulation)
# ==============================================================================

"""
    size_steel_w_beam_nlp(Mu, Vu, geometry, opts::NLPWOptions; Mux_neg, Ix_min, x0) -> WColumnNLPResult

Size a W-shape beam using continuous (NLP) optimization with dedicated
AISC F2 flexure (including smooth LTB) and G2 shear constraints.

Unlike `size_w_nlp` (which uses H1-1 interaction with Pu=0), this
formulation directly optimizes for flexure and shear, producing beams
with wider flanges to resist lateral-torsional buckling.

When `Mux_neg > 0` (default `Mux_neg = Mu`), sizes against
`max(Mu, Mux_neg)` with hogging Chapter F (`Lb = L`, `Cb = 1.0`) if
deck-braced sagging `Lb`/`Cb` would otherwise inflate φMn.

AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103.
# ENGINEERING JUDGMENT
Hogging uses `Cb = 1.0` (`SteelMemberGeometry` has only sagging `Cb`).

# Arguments
- `Mu`: Factored moment — any moment unit
- `Vu`: Factored shear — any force unit
- `geometry`: `SteelMemberGeometry` with L, Lb (unbraced length), Cb
- `opts`: `NLPWOptions` with material, dimension bounds, solver settings

# Keyword Arguments
- `Mux_neg`: Hogging (top-flange compression) moment. Default: `Mu`
  (unsigned envelope includes hogging).
- `Ix_min`: Minimum required Ix for deflection (Length⁴ or bare in⁴). Use
  `required_Ix_for_deflection` to compute from service loads. Default: `nothing`.
- `x0`: Initial guess vector (default: automatic)

# Returns
`WColumnNLPResult` with `.section::ISymmSection` for analytical checks.

# Example
```julia
# Strength only
result = size_steel_w_beam_nlp(150.0u"kN*m", 100.0u"kN",
    SteelMemberGeometry(8.0; Kx=1.0, Ky=1.0),
    NLPWOptions(min_depth=8.0u"inch", max_depth=24.0u"inch"))

# With deflection constraint
Ix_req = required_Ix_for_deflection(0.8kip/u"ft", 25.0u"ft", 29000.0ksi)
result = size_steel_w_beam_nlp(Mu, Vu, geom, opts; Ix_min=Ix_req)
```
"""
function size_steel_w_beam_nlp(
    Mu,
    Vu,
    geometry::SteelMemberGeometry,
    opts::NLPWOptions;
    Mux_neg = Mu,
    Ix_min = nothing,
    Ix_min_total = nothing,
    Tu = 0.0,
    L_span = nothing,
    x0::Union{Nothing,Vector{Float64}} = nothing,
)
    problem = SteelWBeamNLPProblem(Mu, Vu, geometry, opts; Mux_neg=Mux_neg, Ix_min=Ix_min, Ix_min_total=Ix_min_total, Tu=Tu, L_span=L_span)
    
    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose,
        x0 = x0,
    )
    
    return build_w_beam_nlp_result(problem, opt_result)
end

"""
    size_steel_w_beams_nlp(Mu, Vu, geometries, opts; Ix_min) -> Vector{WColumnNLPResult}

Size multiple W-shape beams using continuous (NLP) optimization.

`Ix_min` can be a scalar (applied to all) or a vector (per beam).
"""
function size_steel_w_beams_nlp(
    Mu::Vector,
    Vu::Vector,
    geometries::Vector{<:SteelMemberGeometry},
    opts::NLPWOptions;
    Mux_neg = Mu,
    Ix_min = nothing,
)
    n = length(Mu)
    n == length(Vu) || throw(ArgumentError("Mu and Vu must have same length"))
    n == length(geometries) || throw(ArgumentError("Mu and geometries must have same length"))
    
    results = Vector{WColumnNLPResult}(undef, n)
    for i in 1:n
        Ix_i = isnothing(Ix_min) ? nothing :
               (Ix_min isa AbstractVector ? Ix_min[i] : Ix_min)
        Mux_neg_i = Mux_neg isa AbstractVector ? Mux_neg[i] : Mux_neg
        results[i] = size_steel_w_beam_nlp(Mu[i], Vu[i], geometries[i], opts;
                                          Mux_neg=Mux_neg_i, Ix_min=Ix_i)
    end
    return results
end

# ==============================================================================
# Steel HSS Beam NLP Sizing (Dedicated Beam Formulation)
# ==============================================================================

"""
    size_steel_hss_beam_nlp(Mu, Vu, opts::NLPHSSOptions; Ix_min, x0) -> HSSColumnNLPResult

Size a rectangular HSS beam using continuous (NLP) optimization with
dedicated AISC F7 flexure and G4 shear constraints.

Unlike `size_hss_nlp` (which uses H1-1 interaction with Pu=0), this
formulation directly optimizes for flexure and shear without compression
capacity calculations, producing more efficient beam sections.

# Arguments
- `Mu`: Factored moment — any moment unit
- `Vu`: Factored shear — any force unit
- `opts`: `NLPHSSOptions` with material, dimension bounds, solver settings

# Keyword Arguments
- `Ix_min`: Minimum required Ix for deflection (Length⁴ or bare in⁴). Default: `nothing`.
- `x0`: Initial guess vector (default: automatic)

# Returns
`HSSColumnNLPResult` with `.section::HSSRectSection` for analytical checks.

# Example
```julia
result = size_steel_hss_beam_nlp(60.0u"kN*m", 80.0u"kN",
    NLPHSSOptions(min_outer=4.0u"inch", max_outer=12.0u"inch"))
```
"""
function size_steel_hss_beam_nlp(
    Mu,
    Vu,
    opts::NLPHSSOptions;
    Ix_min = nothing,
    Ix_min_total = nothing,
    Tu = 0.0,
    x0::Union{Nothing,Vector{Float64}} = nothing,
)
    problem = SteelHSSBeamNLPProblem(Mu, Vu, opts; Ix_min=Ix_min, Ix_min_total=Ix_min_total, Tu=Tu)
    
    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose,
        x0 = x0,
    )
    
    return build_hss_beam_nlp_result(problem, opt_result)
end

"""
    size_steel_hss_beams_nlp(Mu, Vu, opts; Ix_min) -> Vector{HSSColumnNLPResult}

Size multiple HSS beams using continuous (NLP) optimization.

`Ix_min` can be a scalar (applied to all) or a vector (per beam).
"""
function size_steel_hss_beams_nlp(
    Mu::Vector,
    Vu::Vector,
    opts::NLPHSSOptions;
    Ix_min = nothing,
)
    n = length(Mu)
    n == length(Vu) || throw(ArgumentError("Mu and Vu must have same length"))
    
    results = Vector{HSSColumnNLPResult}(undef, n)
    for i in 1:n
        Ix_i = isnothing(Ix_min) ? nothing :
               (Ix_min isa AbstractVector ? Ix_min[i] : Ix_min)
        results[i] = size_steel_hss_beam_nlp(Mu[i], Vu[i], opts; Ix_min=Ix_i)
    end
    return results
end

# ==============================================================================
# RC T-Beam Sizing: Discrete (MIP)
# ==============================================================================

"""
    size_tbeams(Mu, Vu, geometries, opts::ConcreteBeamOptions;
                flange_width, flange_thickness, Nu=..., catalog_size=:standard, ...)

Size reinforced concrete T-beams using discrete catalog optimization.

Generates a catalog of `RCTBeamSection`s with fixed flange dimensions
(from slab sizing and tributary geometry) and selects the minimum-objective
section satisfying ACI 318-11 requirements.

# Arguments
- `Mu`: Vector of factored moments — any moment unit
- `Vu`: Vector of factored shears — any force unit
- `geometries`: Member geometries
- `opts`: `ConcreteBeamOptions`

# Keyword Arguments
- `flange_width`: Effective flange width (bf). A length, or a function
  of web width that returns a length.
- `flange_thickness`: Slab thickness (hf) — Length unit
- `Nu`: Vector of factored axial compressions (default: zeros). When > 0,
  the shear checker increases Vc per ACI §22.5.6.1.
- `catalog`: Optional per-call catalog override (default `nothing`); takes
  precedence over `opts.custom_catalog` and the `catalog_size`-selected family.
  This is the hook `MemberGroup.catalog_override` (Phase 6) routes through.
- `catalog_size`: `:standard`, `:small`, `:large` (default `:standard`)
- `mip_gap`: MIP optimality gap (default 1e-4)
- `output_flag`: Solver verbosity (default 0)

# Returns
Named tuple: `(; section_indices, sections, status, objective_value)`

# Example
```julia
Mu = [200.0, 300.0] .* kip .* u"ft"
Vu = [40.0, 60.0] .* kip
geoms = [ConcreteMemberGeometry(8.0u"m") for _ in 1:2]
result = size_tbeams(Mu, Vu, geoms, ConcreteBeamOptions();
                     flange_width=48u"inch", flange_thickness=5u"inch")
```
"""
function size_tbeams(
    Mu::Vector,
    Vu::Vector,
    geometries::Vector,
    opts::ConcreteBeamOptions;
    flange_width,
    flange_thickness::Length,
    Mu_neg::Vector = Mu,
    Nu::Vector = zeros_like(Vu),
    Tu::Vector = Float64[],
    catalog::Union{Nothing, AbstractVector} = nothing,
    catalog_size::Symbol = :standard,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
    w_dead = nothing,
    w_live = nothing,
    defl_support::Symbol = :simply_supported,
    defl_ξ::Real = 2.0,
    sustained_live_fraction::Real = 0.0,
    shell_spans = nothing,
    joist_spacing = nothing,
    shear_cases = nothing,
)
    n = length(Mu)
    n == length(Vu)          || throw(ArgumentError("Mu and Vu must have same length"))
    n == length(geometries)  || throw(ArgumentError("demands and geometries must have same length"))

    # Convert geometries
    conc_geoms = [to_concrete_geometry(g) for g in geometries]

    # Build T-beam catalog — Phase 6 precedence: explicit `catalog` kwarg
    # (per-group override) > `opts.custom_catalog` > `catalog_size`-selected
    # standard T-beam family.
    cat = if !isnothing(catalog)
        catalog
    elseif !isnothing(opts.custom_catalog)
        opts.custom_catalog
    elseif catalog_size === :standard
        standard_rc_tbeams(flange_width=flange_width, flange_thickness=flange_thickness)
    elseif catalog_size === :small
        small_rc_tbeams(flange_width=flange_width, flange_thickness=flange_thickness)
    elseif catalog_size === :large
        large_rc_tbeams(flange_width=flange_width, flange_thickness=flange_thickness)
    else
        throw(ArgumentError("Unknown catalog_size=:$catalog_size. Use :standard, :small, or :large"))
    end

    isempty(cat) && throw(ArgumentError("T-beam catalog is empty — check flange_width/flange_thickness"))

    # Convert forces / moments
    Mu_kipft = [to_kipft(m) for m in Mu]
    Mu_neg_kipft = [to_kipft(m) for m in Mu_neg]
    Vu_kip   = [to_kip(v)   for v in Vu]
    Nu_kip   = [to_kip(n)   for n in Nu]

    # Convert torsion to kip·in (raw number)
    Tu_kipin = if isempty(Tu)
        zeros(n)
    else
        [t isa Unitful.Quantity ? abs(ustrip(kip*u"inch", t)) : abs(Float64(t)) for t in Tu]
    end

    # Build demands (Nu, Tu, Mu_neg flow to checker via RCBeamDemand fields)
    demands = [RCBeamDemand(i; Mu=Mu_kipft[i], Mu_neg=Mu_neg_kipft[i],
                            Vu=Vu_kip[i], Nu=Nu_kip[i], Tu=Tu_kipin[i]) for i in 1:n]

    # Convert service loads for deflection check (if provided)
    wd_kplf = if isnothing(w_dead)
        0.0
    elseif w_dead isa Unitful.Quantity
        ustrip(kip/u"ft", w_dead)
    else
        Float64(w_dead)
    end
    wl_kplf = if isnothing(w_live)
        0.0
    elseif w_live isa Unitful.Quantity
        ustrip(kip/u"ft", w_live)
    else
        Float64(w_live)
    end

    # Center-to-center spacing. §8.13.8's 10 percent is applied per rib, and
    # only when that rib also meets §8.13.2 and §8.13.3.
    joist_in = joist_spacing === nothing ? 0.0 : ustrip(u"inch", joist_spacing)
    spans = _beam_shell_spans(shell_spans, n)
    # Create checker (with optional deflection)
    checker = ACIBeamChecker(;
        fy_ksi  = ustrip(ksi, opts.rebar_material.Fy),
        fyt_ksi = ustrip(ksi, get_transverse_rebar(opts).Fy),
        Es_ksi  = ustrip(ksi, opts.rebar_material.E),
        λ       = opts.material.λ,
        max_depth = opts.max_depth,
        w_dead_kplf = wd_kplf,
        w_live_kplf = wl_kplf,
        defl_support = defl_support,
        defl_ξ = Float64(defl_ξ),
        defl_sustained_live = sustained_live_fraction,
        shell_spans = spans,
        joist_spacing_in = joist_in,
        shear_cases = _checker_shear_cases(shear_cases, n),
    )

    return optimize_discrete(
        checker, demands, conc_geoms, cat, _sizing_material(opts.material, opts.rebar_material, get_transverse_rebar(opts));
        objective      = opts.objective,
        n_max_sections = opts.n_max_sections,
        optimizer      = opts.solver,
        mip_gap        = mip_gap,
        output_flag    = output_flag,
        time_limit_sec = opts.time_limit_sec,
    )
end

# ==============================================================================
# RC T-Beam NLP Sizing (Continuous Optimization)
# ==============================================================================

"""
    size_rc_tbeam_nlp(Mu, Vu, bf, hf, opts::NLPBeamOptions) -> RCTBeamNLPResult

Size a single RC T-beam using continuous (NLP) optimization.

Optimizes web width (bw), total depth (h), and reinforcement ratio (ρ) with
fixed flange dimensions. The flange width and thickness are determined by slab
sizing and tributary geometry, and are not design variables.

# Arguments
- `Mu`: Factored moment — any moment unit
- `Vu`: Factored shear — any force unit
- `bf`: Effective flange width — any length unit
- `hf`: Flange (slab) thickness — any length unit
- `opts`: `NLPBeamOptions` with material, bounds, solver settings

# Returns
`RCTBeamNLPResult` with:
- `section`: Constructed `RCTBeamSection`
- `bw_opt`, `h_opt`, `ρ_opt`: Continuous optimal values
- `bw_final`, `h_final`: Dimensions after optional snapping
- `bf`, `hf`: Fixed flange dimensions (inches)
- `area_web`: Web area bw×h (in²)
- `status`: Solver termination status

# Example
```julia
Mu = 250.0kip * u"ft"
Vu = 50.0kip
bf = 48.0u"inch"
hf = 5.0u"inch"
opts = NLPBeamOptions(min_depth=16.0u"inch", max_depth=30.0u"inch")
result = size_rc_tbeam_nlp(Mu, Vu, bf, hf, opts)
println("Section: \$(result.section.name), Web area: \$(result.area_web) in²")
```
"""
function size_rc_tbeam_nlp(
    Mu, Vu,
    bf::Length, hf::Length,
    opts::NLPBeamOptions;
    Tu = 0.0,
    Nu = 0.0,
    Mu_neg = nothing,
    shear_cases = nothing,
    flexure_cases = nothing,
    joist_spacing = nothing,
    x0::Union{Nothing,Vector{Float64}} = nothing,
    w_dead = nothing,
    w_live = nothing,
    L_span = nothing,
    defl_support::Symbol = :simply_supported,
    defl_ξ::Float64 = 2.0,
    sustained_live_fraction::Real = 0.0,
)
    problem = RCTBeamNLPProblem(Mu, Vu, bf, hf, opts;
                                w_dead=w_dead, w_live=w_live, L_span=L_span,
                                support=defl_support, ξ=defl_ξ,
                                sustained_live_fraction=sustained_live_fraction,
                                Tu=Tu, Nu=Nu, shear_cases=shear_cases,
                                flexure_cases=flexure_cases,
                                joist_spacing=joist_spacing)

    opt_result = optimize_continuous(
        problem;
        objective = opts.objective,
        solver = opts.solver,
        maxiter = opts.maxiter,
        tol = opts.tol,
        verbose = opts.verbose,
        x0 = x0,
    )

    result = build_rc_tbeam_nlp_result(problem, opt_result)
    # Ceil-to-bar can drop the built section below the NLP's εt ≥ 0.005 target.
    # ACI 318-11 §10.3.5 (corpus: aci-318-11, PDF p. 142) requires εt ≥ 0.004.
    εt_built = _compute_εt(result.section, problem.fc_psi, problem.fy_psi)
    if εt_built < 0.004
        return RCTBeamNLPResult(result.section, result.bw_opt, result.h_opt, result.ρ_opt,
                                result.bw_final, result.h_final, result.bf, result.hf,
                                result.area_web, :infeasible, result.iterations)
    end
    # Post-NLP hogging adequacy (top steel is not an NLP design variable).
    # The NLP therefore cannot deepen for Mu_neg; it may return :infeasible.
    # Public default Mu_neg = Mu is unchanged.
    Mu_neg_kipft = to_kipft(isnothing(Mu_neg) ? Mu : Mu_neg)
    if !_neg_moment_adequate(result.section, Mu_neg_kipft, problem.fc_psi, problem.fy_psi)
        return RCTBeamNLPResult(result.section, result.bw_opt, result.h_opt, result.ρ_opt,
                                result.bw_final, result.h_final, result.bf, result.hf,
                                result.area_web, :infeasible, result.iterations)
    end
    return result
end

"""
    size_rc_tbeams_nlp(Mu, Vu, bf, hf, opts::NLPBeamOptions) -> Vector{RCTBeamNLPResult}

Size multiple RC T-beams using continuous (NLP) optimization.

`bf` and `hf` can be scalars (shared) or vectors (per beam).

# Example
```julia
Mu = [200.0, 300.0] .* kip .* u"ft"
Vu = [40.0, 60.0] .* kip
bf = 48.0u"inch"   # shared flange width
hf = 5.0u"inch"    # shared slab thickness
results = size_rc_tbeams_nlp(Mu, Vu, bf, hf, NLPBeamOptions())
```
"""
function size_rc_tbeams_nlp(
    Mu::Vector, Vu::Vector,
    bf, hf,
    opts::NLPBeamOptions;
    Mu_neg::Vector = Mu,
    Nu::Vector = zeros_like(Vu),
    shear_cases = nothing,
    flexure_cases = nothing,
    joist_spacing = nothing,
    w_dead = nothing,
    w_live = nothing,
    L_span = nothing,
    defl_support::Symbol = :simply_supported,
    defl_ξ::Float64 = 2.0,
    sustained_live_fraction::Real = 0.0,
)
    n = length(Mu)
    n == length(Vu) || throw(ArgumentError("Mu and Vu must have same length"))
    n == length(Mu_neg) || throw(ArgumentError("Mu_neg must have same length as Mu"))
    n == length(Nu) || throw(ArgumentError("Nu must have same length as Vu"))
    if shear_cases !== nothing
        length(shear_cases) == n ||
            throw(ArgumentError("shear_cases must have same length as Mu"))
    end
    if flexure_cases !== nothing
        length(flexure_cases) == n ||
            throw(ArgumentError("flexure_cases must have same length as Mu"))
    end

    # Allow scalar or vector bf/hf
    bf_vec = bf isa AbstractVector ? bf : fill(bf, n)
    hf_vec = hf isa AbstractVector ? hf : fill(hf, n)
    length(bf_vec) == n || throw(ArgumentError("bf vector length must match Mu"))
    length(hf_vec) == n || throw(ArgumentError("hf vector length must match Mu"))

    # Allow scalar or vector service loads / span
    wd_vec = isnothing(w_dead) ? fill(nothing, n) : (w_dead isa AbstractVector ? w_dead : fill(w_dead, n))
    wl_vec = isnothing(w_live) ? fill(nothing, n) : (w_live isa AbstractVector ? w_live : fill(w_live, n))
    Ls_vec = isnothing(L_span) ? fill(nothing, n) : (L_span isa AbstractVector ? L_span : fill(L_span, n))

    results = Vector{RCTBeamNLPResult}(undef, n)
    for i in 1:n
        sc = shear_cases === nothing ? nothing : shear_cases[i]
        fc = flexure_cases === nothing ? nothing : flexure_cases[i]
        js = joist_spacing isa AbstractVector ? joist_spacing[i] : joist_spacing
        results[i] = size_rc_tbeam_nlp(Mu[i], Vu[i], bf_vec[i], hf_vec[i], opts;
                                        Mu_neg=Mu_neg[i], Nu=Nu[i], shear_cases=sc,
                                        flexure_cases=fc, joist_spacing=js,
                                        w_dead=wd_vec[i], w_live=wl_vec[i],
                                        L_span=Ls_vec[i],
                                        defl_support=defl_support, defl_ξ=defl_ξ,
                                        sustained_live_fraction=sustained_live_fraction)
    end
    return results
end