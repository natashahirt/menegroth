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
- `flange_width`: Effective flange width (bf) — Length unit, or a function
  `bw -> bf` evaluated per candidate web (ACI 318-11 §8.12.2)
- `flange_thickness`: Slab thickness (hf) — Length unit
- `joist_spacing`: Center-to-center rib spacing when the members are ribs of
  ACI 318-11 §8.13 joist construction (default `nothing`). The default catalog
  becomes [`joist_rc_tbeams`](@ref) and the checker applies §8.13.8. When no rib
  meets §8.13.3 at this spacing, §8.13.4 applies: the ribs are sized as beams
  from the `catalog_size` family; §8.13.8 still applies to any of those sections that
  meet §8.13.2 and §8.13.3.
- `joist_direction`: `:one_way` or `:two_orthogonal` (§8.13.1)
- `Nu`: Vector of factored axial compressions (default: zeros). When > 0,
  the shear checker increases Vc per ACI §22.5.6.1.
- `catalog`: Optional per-call catalog override (default `nothing`); takes
  precedence over `opts.custom_catalog` and the `catalog_size`-selected family.
  A per-call catalog.
- `catalog_size`: `:standard`, `:small`, `:large` (default `:standard`)
- `mip_gap`: MIP optimality gap (default 1e-4)
- `output_flag`: Solver verbosity (default 0)
- `capacity_store`: Optional `AbstractDict` for reusing precomputed section
  capacities across calls (default `nothing`). When given, the φMn/φVn/εt
  precompute for the catalog is cached by content fingerprint and reused by any
  later call whose rib geometry, material, and rebar grade are bit-identical —
  the span- and load-dependent checks still run per demand, so results are
  bit-identical to recomputing. See [`_tbeam_capacity_cache`](@ref).

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
    flange_width::Union{Length, Function},
    flange_thickness::Length,
    joist_spacing::Union{Nothing, Length} = nothing,
    joist_direction::Symbol = :one_way,
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
    sustained_live_fraction::Real = opts.sustained_live_fraction,
    shell_spans::Union{Nothing, AbstractVector} = nothing,
    stirrup_shear::Bool = true,
    shear_cases = nothing,
    capacity_store::Union{Nothing, AbstractDict} = nothing,
)
    n = length(Mu)
    n == length(Vu)          || throw(ArgumentError("Mu and Vu must have same length"))
    n == length(geometries)  || throw(ArgumentError("demands and geometries must have same length"))
    shell_spans === nothing || length(shell_spans) == n ||
        throw(ArgumentError("shell_spans must have one entry per demand"))
    _require_sizing_strategy(
        opts, (:discrete,); api="reinforced-concrete T-beam sizing")

    # Convert geometries
    conc_geoms = [to_concrete_geometry(g) for g in geometries]

    # Build T-beam catalog — Phase 6 precedence: explicit `catalog` kwarg
    # (per-group override) > `opts.custom_catalog` > joist ribs > the
    # `catalog_size`-selected standard T-beam family.
    joist_cat = isnothing(joist_spacing) ? RCTBeamSection[] :
        joist_rc_tbeams(flange_width=flange_width, flange_thickness=flange_thickness,
                        center_spacing=joist_spacing)
    if !isnothing(joist_spacing) && isempty(joist_cat) &&
            isnothing(catalog) && isnothing(opts.custom_catalog)
        @warn "No joist rib width (4–8 in) meets ACI 318-11 §8.13.3 (clear spacing " *
              "≤ 30 in) at $(uconvert(u"inch", joist_spacing)) centers; sizing the ribs " *
              "from the beam catalog. The §8.13.8 shear increase applies only to " *
              "sections that meet §8.13.2 and §8.13.3." maxlog=4
    end
    cat = if !isnothing(catalog)
        catalog
    elseif !isnothing(opts.custom_catalog)
        opts.custom_catalog
    elseif !isempty(joist_cat)
        joist_cat
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

    checker, demands = _tbeam_checker_and_demands(
        Mu, Vu, opts; Mu_neg, Nu, Tu, w_dead, w_live, defl_support, defl_ξ,
        sustained_live_fraction, shell_spans, joist_spacing, joist_direction,
        stirrup_shear, shear_cases)

    # Longitudinal and transverse rebar enter the discrete objective.
    material = _sizing_material(opts.material, opts.rebar_material, get_transverse_rebar(opts))

    # Reuse the catalog's capacity precompute across calls with identical rib
    # geometry (the dominant cost of discrete T-beam sizing). `nothing` store ⇒
    # `optimize_discrete` precomputes internally, exactly as before.
    cache = _tbeam_capacity_cache(capacity_store, cat, material, checker,
                                  opts.objective, opts.n_max_sections)

    return optimize_discrete(
        checker, demands, conc_geoms, cat, material;
        objective      = opts.objective,
        n_max_sections = opts.n_max_sections,
        optimizer      = opts.solver,
        mip_gap        = mip_gap,
        output_flag    = output_flag,
        time_limit_sec = opts.time_limit_sec,
        cache          = cache,
    )
end

"""
    _tbeam_capacity_key(cat, material, checker, objective, n_max_sections) -> UInt

Content fingerprint for a T-beam capacity cache. Two calls share a cache only
when their catalogs are *bit-identical* and the capacity-relevant checker and
material inputs match, so a reused cache yields bit-identical sizing. Hashing
raw (unrounded) field values is deliberate: a geometry that recomputes the same
`Float64` bits reuses the cache, and any difference forces a rebuild.

Only inputs that [`precompute_capacities!`](@ref) reads enter the key. The
checker's deflection / service-load fields (`w_dead_kplf`, `w_live_kplf`,
`shell_spans`, `defl_*`) are applied per demand in [`is_feasible`](@ref), not
baked into the cache, so they are deliberately excluded — that is exactly what
lets one cache serve every member iteration whose spans and loads differ.
"""
function _tbeam_capacity_key(cat, material, checker::ACIBeamChecker, objective,
                             n_max_sections)
    h = hash(:tbeam_capacity_cache_v1)
    h = hash(objective, h)
    h = hash(n_max_sections, h)
    # Capacity-relevant checker fields only (see docstring).
    h = hash((checker.fy_ksi, checker.fyt_ksi, checker.Es_ksi, Float64(checker.λ)), h)
    h = hash(fc_ksi(material), h)
    if material isa ReinforcedConcreteMaterial
        h = hash((fy_ksi(material), Es_ksi(material)), h)
    end
    for s in cat
        h = hash((ustrip(u"inch", s.bw), ustrip(u"inch", s.h), ustrip(u"inch", s.d),
                  ustrip(u"inch", s.bf), ustrip(u"inch", s.hf), ustrip(u"inch", s.cover),
                  ustrip(u"inch^2", s.As), s.n_bars, s.bar_size,
                  ustrip(u"inch^2", s.As_prime), s.n_bars_prime, s.bar_size_prime,
                  ustrip(u"inch", s.d_prime), s.stirrup_size), h)
    end
    return h
end

"""
    _tbeam_capacity_cache(store, cat, material, checker, objective, n_max_sections)

Build or reuse the capacity cache for `cat` under this checker/material, keyed by
[`_tbeam_capacity_key`](@ref) in the caller-supplied `store`. Returns `nothing`
when `store === nothing`, so `optimize_discrete` precomputes as before.

The precompute (φMn / φMn_neg / φVn / εt for the whole catalog) is the dominant
cost of discrete T-beam sizing; reusing it across member iterations with
identical rib geometry is the point of the store. `optimize_discrete` revalidates
the returned cache against the catalog and material via `_require_cache_match`
([`cache_matches`](@ref)), so a mis-keyed cache is caught, not silently used.
"""
function _tbeam_capacity_cache(store, cat, material, checker::ACIBeamChecker,
                               objective, n_max_sections)
    store === nothing && return nothing
    key = _tbeam_capacity_key(cat, material, checker, objective, n_max_sections)
    cached = get(store, key, nothing)
    cached === nothing || return cached
    cache = create_cache(checker, length(cat))
    precompute_capacities!(checker, cache, cat, material, objective)
    store[key] = cache
    return cache
end

"""
The `ACIBeamChecker` and `RCBeamDemand`s that [`size_tbeams`](@ref) checks
candidates with. [`check_tbeam_section`](@ref) uses the same pair, so a
section it passes is one the sizer would accept.
"""
function _tbeam_checker_and_demands(
    Mu::Vector, Vu::Vector, opts::ConcreteBeamOptions;
    Mu_neg::Vector, Nu::Vector, Tu::Vector,
    w_dead, w_live, defl_support::Symbol, defl_ξ::Real,
    sustained_live_fraction::Real, shell_spans,
    joist_spacing, joist_direction::Symbol,
    stirrup_shear::Bool = true,
    shear_cases = nothing,
)
    n = length(Mu)
    Mu_kipft = [to_kipft(m) for m in Mu]
    Mu_neg_kipft = [to_kipft(m) for m in Mu_neg]
    Vu_kip   = [to_kip(v)   for v in Vu]
    Nu_kip   = [to_kip(n)   for n in Nu]

    # Torsion as kip·in (raw number)
    Tu_kipin = if isempty(Tu)
        zeros(n)
    else
        [t isa Unitful.Quantity ? abs(ustrip(kip*u"inch", t)) : abs(Float64(t)) for t in Tu]
    end

    # Nu, Tu, and Mu_neg reach the checker through the RCBeamDemand fields.
    demands = [RCBeamDemand(i; Mu=Mu_kipft[i], Mu_neg=Mu_neg_kipft[i],
                            Vu=Vu_kip[i], Nu=Nu_kip[i], Tu=Tu_kipin[i]) for i in 1:n]

    # Service loads for the deflection check, when given
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
        shell_spans = shell_spans === nothing ? Vector{RCShellSpan}[] : shell_spans,
        joist_spacing = joist_spacing,
        joist_direction = joist_direction,
        stirrup_shear = stirrup_shear,
        shear_cases = _checker_shear_cases(shear_cases, n),
    )
    return checker, demands
end

"""
    check_tbeam_section(section, Mu, Vu, geometry, opts::ConcreteBeamOptions;
                        Mu_neg=Mu, Nu=0, joist_spacing=nothing, shell_span=nothing,
                        ...) -> FeasibilityExplanation

Check one `RCTBeamSection` against one demand with the checker
[`size_tbeams`](@ref) uses. The explanation passes only when the checker's
`is_feasible` accepts the section and every reported check passes.

`shell_span` is that member's list of [`RCShellSpan`](@ref)s, or `nothing`.
"""
function check_tbeam_section(
    section::RCTBeamSection, Mu, Vu, geometry, opts::ConcreteBeamOptions;
    Mu_neg = Mu,
    Nu = zero(Vu),
    joist_spacing::Union{Nothing, Length} = nothing,
    joist_direction::Symbol = :one_way,
    w_dead = nothing,
    w_live = nothing,
    defl_support::Symbol = :simply_supported,
    defl_ξ::Real = 2.0,
    sustained_live_fraction::Real = opts.sustained_live_fraction,
    shell_span = nothing,
    stirrup_shear::Bool = true,
)::FeasibilityExplanation
    checker, demands = _tbeam_checker_and_demands(
        [Mu], [Vu], opts; Mu_neg = [Mu_neg], Nu = [Nu], Tu = Float64[],
        w_dead, w_live, defl_support, defl_ξ, sustained_live_fraction,
        shell_spans = shell_span === nothing ? nothing : [shell_span],
        joist_spacing, joist_direction, stirrup_shear)
    geom = to_concrete_geometry(geometry)
    cache = create_cache(checker, 1)
    precompute_capacities!(checker, cache, [section], opts.material, opts.objective)
    expl = explain_feasibility(checker, cache, 1, section, opts.material, demands[1], geom)
    feasible = is_feasible(checker, cache, 1, section, opts.material, demands[1], geom)
    feasible && expl.passed && return expl
    return FeasibilityExplanation(false, expl.checks,
                                  feasible ? expl.governing_check : "is_feasible",
                                  expl.governing_ratio)
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
    x0::Union{Nothing,Vector{Float64}} = nothing,
    w_dead = nothing,
    w_live = nothing,
    L_span = nothing,
    defl_support::Symbol = :simply_supported,
    defl_ξ::Float64 = 2.0,
    sustained_live_fraction::Real = 0.0,
    joist_spacing::Union{Nothing, Length} = nothing,
    joist_direction::Symbol = :one_way,
)
    problem = RCTBeamNLPProblem(Mu, Vu, bf, hf, opts;
                                w_dead=w_dead, w_live=w_live, L_span=L_span,
                                support=defl_support, ξ=defl_ξ,
                                sustained_live_fraction=sustained_live_fraction,
                                Tu=Tu, Nu=Nu, shear_cases=shear_cases,
                                flexure_cases=flexure_cases,
                                joist_spacing=joist_spacing,
                                joist_direction=joist_direction)

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
    # Same repair as the rectangular beam: fewer bars, then a deeper web,
    # until ACIBeamChecker passes. Public default Mu_neg = Mu is unchanged.
    Mu_neg_kipft = to_kipft(isnothing(Mu_neg) ? Mu : Mu_neg)
    return _rc_tbeam_nlp_verify(result, problem, opts, Mu_neg_kipft)
end

"""
`true` when `section` meets ACI 318-11 §8.13.2 and §8.13.3 at this problem's
rib spacing. A problem that is not joist construction always passes.
"""
function _snapped_joist_ok(section::RCTBeamSection, problem::RCTBeamNLPProblem)
    problem.joist_spacing_in > 0 || return true
    try
        joist = JoistConstruction(section, problem.joist_spacing_in * u"inch",
                                  problem.joist_direction)
        return check_joist_construction(joist).vc_increase_permitted
    catch e
        e isa ArgumentError || rethrow()
        return false
    end
end

"""Accept the snapped T-beam, or the repaired section, or `:infeasible`."""
function _rc_tbeam_nlp_verify(
    result::RCTBeamNLPResult,
    problem::RCTBeamNLPProblem,
    opts::NLPBeamOptions,
    Mu_neg_kipft::Float64,
)
    _rc_column_nlp_acceptable(result.status) || return result
    # Every NLP sagging and shear row reaches the gate: the largest sagging
    # case, and one checker shear row per case with its own Nu and Tu.
    demand = (
        Mu_kipft = maximum(problem.flexure_cases), Mu_neg_kipft = Mu_neg_kipft,
        Vu_kip = problem.Vu_kip, Nu_kip = problem.Nu_kip, Tu_kipin = problem.Tu_kipin,
        shear_cases = [RCBeamShearCase(c.Vu_kip, c.Nu_kip, c.Tu_kipin)
                       for c in problem.shear_cases],
    )
    spacing = problem.joist_spacing_in > 0 ? problem.joist_spacing_in * u"inch" : nothing
    # The snapped rib has to meet §8.13.2 and §8.13.3. The checker then
    # applies §8.13.8 only to a section that still meets them.
    passes = sec -> _snapped_joist_ok(sec, problem) &&
        _beam_nlp_passes_checker(sec, opts; demand...,
                                 joist_spacing = spacing,
                                 joist_direction = problem.joist_direction)
    passes(result.section) && return result
    found = _beam_nlp_repair(
        (bw, h, n) -> _rc_tbeam_with_bars(bw, h, n, result.bf, result.hf, opts),
        opts, result.bw_final, result.h_final, problem.bw_max, problem.h_max,
        result.ρ_opt, result.section.n_bars, passes;
        widen_first = spacing !== nothing,
    )
    isnothing(found) && return RCTBeamNLPResult(
        result.section, result.bw_opt, result.h_opt, result.ρ_opt,
        result.bw_final, result.h_final, result.bf, result.hf,
        result.area_web, :infeasible, result.iterations)
    section, bw, h = found
    return RCTBeamNLPResult(
        section, result.bw_opt, result.h_opt, result.ρ_opt,
        bw, h, result.bf, result.hf, bw * h, result.status, result.iterations)
end

"""
    joist_nlp_spacing(spacing, opts, hf) -> Union{Length, Nothing}

Spacing to pass into the rib NLP, or `nothing` when no width inside the
bounds can meet ACI 318-11 §8.13.2 and §8.13.3. §8.13.4 then sizes that rib
as a beam, and §8.13.8 does not apply.
"""
function joist_nlp_spacing(spacing, opts::NLPBeamOptions, hf)
    spacing === nothing && return nothing
    s_in = ustrip(u"inch", spacing)
    s_in > 0 || return nothing
    hf_in = ustrip(u"inch", hf)
    bw_min = max(ustrip(u"inch", opts.min_width), 4.0, s_in - 30.0)
    bw_max = min(ustrip(u"inch", opts.max_width), s_in - 1e-3)
    bw_min <= bw_max || return nothing
    h_min = max(ustrip(u"inch", opts.min_depth), hf_in + 2.0)
    h_min <= hf_in + 3.5 * bw_max || return nothing
    return spacing
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
    w_dead = nothing,
    w_live = nothing,
    L_span = nothing,
    defl_support::Symbol = :simply_supported,
    defl_ξ::Float64 = 2.0,
    sustained_live_fraction::Real = 0.0,
    joist_spacing = nothing,
    joist_direction::Symbol = :one_way,
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
    spacing_vec = if joist_spacing === nothing
        fill(nothing, n)
    elseif joist_spacing isa AbstractVector
        length(joist_spacing) == n || throw(ArgumentError(
            "joist_spacing vector length must match Mu"))
        joist_spacing
    else
        fill(joist_spacing, n)
    end

    # Allow scalar or vector service loads / span
    wd_vec = isnothing(w_dead) ? fill(nothing, n) : (w_dead isa AbstractVector ? w_dead : fill(w_dead, n))
    wl_vec = isnothing(w_live) ? fill(nothing, n) : (w_live isa AbstractVector ? w_live : fill(w_live, n))
    Ls_vec = isnothing(L_span) ? fill(nothing, n) : (L_span isa AbstractVector ? L_span : fill(L_span, n))

    results = Vector{RCTBeamNLPResult}(undef, n)
    for i in 1:n
        sc = shear_cases === nothing ? nothing : shear_cases[i]
        fc = flexure_cases === nothing ? nothing : flexure_cases[i]
        results[i] = size_rc_tbeam_nlp(Mu[i], Vu[i], bf_vec[i], hf_vec[i], opts;
                                        Mu_neg=Mu_neg[i], Nu=Nu[i], shear_cases=sc,
                                        flexure_cases=fc,
                                        w_dead=wd_vec[i], w_live=wl_vec[i],
                                        L_span=Ls_vec[i],
                                        defl_support=defl_support, defl_ξ=defl_ξ,
                                        sustained_live_fraction=sustained_live_fraction,
                                        joist_spacing=spacing_vec[i],
                                        joist_direction=joist_direction)
    end
    return results
end