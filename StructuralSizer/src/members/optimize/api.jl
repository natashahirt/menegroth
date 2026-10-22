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
        if entry isa CompositeContext || entry === true
            return entry
        elseif isnothing(entry) && opts_composite
            return true
        else
            return entry
        end
    elseif composite_kw isa CompositeContext || composite_kw === true
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
        _resolve_demand_composite(opts, composite_kw, i) isa CompositeContext && return true
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

function size_columns(
    Pu::Vector,
    Mux::Vector,
    geometries::Vector,
    opts::SteelMemberOptions;
    Muy::Vector = zeros_like(Mux),
    Mux_pos::Vector = Mux,
    Mux_neg::Vector = Mux,
    Vu_strong::Vector = zeros_like(Pu),
    δ_max_vec::Union{Nothing, Vector} = nothing,
    δ_max_total_vec::Union{Nothing, Vector} = nothing,
    I_ref_vec::Union{Nothing, Vector} = nothing,
    catalog::Union{Nothing, AbstractVector} = nothing,
    feasible::Union{Nothing, Vector{Vector{Int}}} = nothing,
    mip_start::Union{Nothing, Vector{Int}} = nothing,
    composite::Union{Nothing, Bool, CompositeContext, AbstractVector} = nothing,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
    tc::Union{Nothing, TraceCollector} = nothing,
)
    n = length(Pu)
    n == length(Mux) || throw(ArgumentError("Pu and Mux must have same length"))
    n == length(geometries) || throw(ArgumentError("demands and geometries must have same length"))
    
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
    if opts.sizing_strategy == :nlp && opts.section_type in (:w, :hss) &&
            !_has_composite_context(opts, composite, n)
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
    # coincident peak).  `Pu_t` is not forwarded here — SCOPE until
    # lateral/uplift (AISC 360-16 §H1.2 tension+flexure).
    demands = [MemberDemand(i; Pu_c=Pu_N[i], Mux=Mux_Nm[i],
                               Mux_pos=Mux_pos_Nm[i], Mux_neg=Mux_neg_Nm[i],
                               Muy=Muy_Nm[i],
                               Vu_strong=Vus_N[i],
                               δ_max_LL=δ_m[i], δ_max_total=δ_tot[i],
                               I_ref=Ir_m4[i],
                               composite=_resolve_demand_composite(opts, composite, i))
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
    demands::Vector{<:RCColumnDemand},
    geometries::Vector,
    opts::ConcreteColumnOptions;
    catalog::Union{Nothing, AbstractVector} = nothing,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
    cache::Union{Nothing, AbstractCapacityCache} = nothing,
    tc::Union{Nothing, TraceCollector} = nothing,
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
        Pu_v  = [d.Pu  for d in demands]
        Mux_v = [d.Mux for d in demands]
        Muy_v = [d.Muy for d in demands]
        return _size_columns_nlp(Pu_v, Mux_v, geometries, opts; Muy=Muy_v)
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
            checker, demands, conc_geoms, cat, opts.materials;
            objective = opts.objective,
            n_max_sections = opts.n_max_sections,
            optimizer = opts.solver,
            mip_gap = mip_gap,
            output_flag = output_flag,
            time_limit_sec = opts.time_limit_sec,
            tc = tc,
        )
    else
        result = optimize_discrete(
            checker, demands, conc_geoms, cat, opts.material;
            objective = opts.objective,
            n_max_sections = opts.n_max_sections,
            optimizer = opts.solver,
            mip_gap = mip_gap,
            output_flag = output_flag,
            time_limit_sec = opts.time_limit_sec,
            cache = cache,
            tc = tc,
        )
    end
    emit!(tc, :sizing, "size_columns", "", :exit; status=string(result.status))
    return result
end

"""
    _size_columns_nlp(Pu, Mux, geometries, opts; Muy) -> NamedTuple

NLP column sizing adapter.  Constructs `NLPColumnOptions` from the shared
`ConcreteColumnOptions` fields, calls `size_rc_columns_nlp`, and wraps
the results into the same `(; section_indices, sections, status, objective_value)`
NamedTuple that the MIP catalog path returns.

This allows the slab-column iteration loop in `size_flat_plate!` to use
NLP column sizing without any changes to the pipeline code.
"""
function _size_columns_nlp(
    Pu::Vector, Mux::Vector, geometries::Vector,
    opts::ConcreteColumnOptions;
    Muy::Vector = zeros_like(Mux),
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
    nlp_results = size_rc_columns_nlp(Pu, Mux, conc_geoms, nlp_opts; Muy=Muy)

    # Wrap into MIP-compatible result shape so the slab pipeline can read
    # column_result.sections[i] without knowing which strategy was used.
    sections = [r.section for r in nlp_results]
    # Match MIP path: objective_value = total volume (m³) or weight (kg) per opts.objective
    concrete = opts.material isa ReinforcedConcreteMaterial ? opts.material.concrete : opts.material
    obj_val  = ustrip(sum(
        objective_value(opts.objective, r.section, concrete, conc_geoms[i].L)
        for (i, r) in enumerate(nlp_results)
    ))

    return (;
        section_indices = collect(1:length(sections)),
        sections        = sections,
        status          = :nlp_complete,
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
    composite::Union{Nothing, Bool, CompositeContext, AbstractVector} = nothing,
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

    # Create checker
    checker = ACIBeamChecker(;
        fy_ksi  = ustrip(ksi, opts.rebar_material.Fy),
        fyt_ksi = ustrip(ksi, get_transverse_rebar(opts).Fy),
        Es_ksi  = ustrip(ksi, opts.rebar_material.E),
        λ       = opts.material.λ,       # Lightweight factor from Concrete type
        max_depth = opts.max_depth,
    )

    # Optimize — multi-material if grades vector is provided
    if !isnothing(opts.materials)
        result = optimize_discrete(
            checker, demands, conc_geoms, cat, opts.materials;
            objective      = opts.objective,
            n_max_sections = opts.n_max_sections,
            optimizer      = opts.solver,
            mip_gap        = mip_gap,
            output_flag    = output_flag,
            time_limit_sec = opts.time_limit_sec,
            tc             = tc,
        )
    else
        result = optimize_discrete(
            checker, demands, conc_geoms, cat, opts.material;
            objective      = opts.objective,
            n_max_sections = opts.n_max_sections,
            optimizer      = opts.solver,
            mip_gap        = mip_gap,
            output_flag    = output_flag,
            time_limit_sec = opts.time_limit_sec,
            tc             = tc,
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
    Mux_pos::Vector = Mu,
    Mux_neg::Vector = Mu,
    δ_max_vec::Union{Nothing, Vector} = nothing,
    δ_max_total_vec::Union{Nothing, Vector} = nothing,
    I_ref_vec::Union{Nothing, Vector} = nothing,
    catalog::Union{Nothing, AbstractVector} = nothing,
    feasible::Union{Nothing, Vector{Vector{Int}}} = nothing,
    mip_start::Union{Nothing, Vector{Int}} = nothing,
    composite::Union{Nothing, Bool, CompositeContext, AbstractVector} = nothing,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
    tc::Union{Nothing, TraceCollector} = nothing,
)
    length(Pu) == length(Mu) || throw(ArgumentError("Pu and Mu must have same length"))
    return size_columns(Pu, Mu, geometries, opts;
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
                        tc=tc)
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
- `Muy`: Factored moment about y-axis (default: 0)

# Returns
`RCColumnNLPResult` with:
- `section`: Optimized `RCColumnSection` (rounded to practical dimensions)
- `b_opt`, `h_opt`, `ρ_opt`: Continuous optimal values
- `b_final`, `h_final`: Final dimensions after rounding
- `area`: Final cross-sectional area (sq in)
- `status`: `:optimal`, `:feasible`, `:infeasible`, `:failed`

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
2. Calls `optimize_continuous(problem; solver=opts.solver)`
3. Rounds continuous solution to practical dimensions
4. Returns `RCColumnNLPResult` with final section

See also: [`size_columns`](@ref), [`NLPColumnOptions`](@ref), [`RCColumnNLPProblem`](@ref)
"""
function size_rc_column_nlp(
    Pu,
    Mux,
    geometry::ConcreteMemberGeometry,
    opts::NLPColumnOptions;
    Muy = 0.0,
    x0::Union{Nothing,Vector{Float64}} = nothing
)
    # Convert demands to RCColumnDemand format
    Pu_kip = to_kip(Pu)
    Mux_kipft = to_kipft(Mux)
    Muy_kipft = to_kipft(Muy)
    
    demand = RCColumnDemand(1; 
        Pu = Pu_kip, 
        Mux = Mux_kipft, 
        Muy = Muy_kipft, 
        βdns = opts.βdns
    )
    
    # Create NLP problem
    problem = RCColumnNLPProblem(demand, geometry, opts)
    
    # Solve using the generic continuous optimizer
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
    
    # Convert to user-friendly result
    return build_rc_column_nlp_result(problem, opt_result)
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
                          x0::Union{Nothing,Vector{Float64}} = nothing)
    problem = RCBeamNLPProblem(Mu, Vu, opts; Tu=Tu, Nu=Nu)

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
    return result
end

"""
    size_rc_beams_nlp(Mu, Vu, opts::NLPBeamOptions) -> Vector{RCBeamNLPResult}

Size multiple RC beams using continuous (NLP) optimization.
"""
function size_rc_beams_nlp(Mu::Vector, Vu::Vector, opts::NLPBeamOptions;
                           Mu_neg::Vector = Mu,
                           Nu::Vector = zeros_like(Vu))
    n = length(Mu)
    n == length(Vu) || throw(ArgumentError("Mu and Vu must have same length"))
    n == length(Mu_neg) || throw(ArgumentError("Mu_neg must have same length as Mu"))
    n == length(Nu) || throw(ArgumentError("Nu must have same length as Vu"))

    results = Vector{RCBeamNLPResult}(undef, n)
    for i in 1:n
        results[i] = size_rc_beam_nlp(Mu[i], Vu[i], opts; Mu_neg=Mu_neg[i], Nu=Nu[i])
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
    composite::Union{Nothing, Bool, CompositeContext, AbstractVector} = nothing,
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
- `flange_width`: Effective flange width (bf) — Length unit
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
    flange_width::Length,
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
    )

    return optimize_discrete(
        checker, demands, conc_geoms, cat, opts.material;
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
    x0::Union{Nothing,Vector{Float64}} = nothing,
    w_dead = nothing,
    w_live = nothing,
    L_span = nothing,
    defl_support::Symbol = :simply_supported,
    defl_ξ::Float64 = 2.0,
)
    problem = RCTBeamNLPProblem(Mu, Vu, bf, hf, opts;
                                w_dead=w_dead, w_live=w_live, L_span=L_span,
                                support=defl_support, ξ=defl_ξ, Tu=Tu, Nu=Nu)

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
    w_dead = nothing,
    w_live = nothing,
    L_span = nothing,
    defl_support::Symbol = :simply_supported,
    defl_ξ::Float64 = 2.0,
)
    n = length(Mu)
    n == length(Vu) || throw(ArgumentError("Mu and Vu must have same length"))
    n == length(Mu_neg) || throw(ArgumentError("Mu_neg must have same length as Mu"))
    n == length(Nu) || throw(ArgumentError("Nu must have same length as Vu"))

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
        results[i] = size_rc_tbeam_nlp(Mu[i], Vu[i], bf_vec[i], hf_vec[i], opts;
                                        Mu_neg=Mu_neg[i], Nu=Nu[i],
                                        w_dead=wd_vec[i], w_live=wl_vec[i],
                                        L_span=Ls_vec[i],
                                        defl_support=defl_support, defl_ξ=defl_ξ)
    end
    return results
end