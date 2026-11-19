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
  A per-call catalog, also what a framing level passes via its beam options.
- `feasible`: Optional per-group list of allowed catalog indices. It only
  removes candidates; every remaining one still goes through the checker.
  Single-material catalogs only.
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
    feasible::Union{Nothing, Vector{Vector{Int}}} = nothing,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
    tc::Union{Nothing, TraceCollector} = nothing,
    shell_spans::Union{Nothing, AbstractVector} = nothing,
    shear_cases = nothing,
)
    n = length(Mu)
    n == length(Vu)          || throw(ArgumentError("Mu and Vu must have same length"))
    n == length(geometries)  || throw(ArgumentError("demands and geometries must have same length"))
    shell_spans === nothing || length(shell_spans) == n ||
        throw(ArgumentError("shell_spans must have one entry per demand"))
    _require_sizing_strategy(
        opts, (:discrete,); api="reinforced-concrete beam sizing")

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
    !isnothing(opts.materials) && feasible !== nothing && throw(ArgumentError(
        "a feasible mask indexes one catalog; it is not supported with several materials"))
    # Longitudinal and transverse rebar enter the discrete objective.
    transverse = get_transverse_rebar(opts)
    run(cat) = isnothing(opts.materials) ?
        optimize_discrete(
            checker, demands, conc_geoms, cat,
            _sizing_material(opts.material, opts.rebar_material, transverse);
            objective      = opts.objective,
            n_max_sections = opts.n_max_sections,
            optimizer      = opts.solver,
            mip_gap        = mip_gap,
            output_flag    = output_flag,
            time_limit_sec = opts.time_limit_sec,
            feasible       = feasible,
            tc             = tc,
        ) :
        optimize_discrete(
            checker, demands, conc_geoms, cat,
            [_sizing_material(m, opts.rebar_material, transverse) for m in opts.materials];
            objective      = opts.objective,
            n_max_sections = opts.n_max_sections,
            optimizer      = opts.solver,
            mip_gap        = mip_gap,
            output_flag    = output_flag,
            time_limit_sec = opts.time_limit_sec,
            tc             = tc,
            feasible       = feasible,
        )
    # A named catalog grows one tier at a time when a group has no section
    # and `catalog_constraint` is `:soft`. `:hard`, an explicit or custom
    # catalog, or a feasibility mask is used as given.
    opts.catalog_constraint in (:hard, :soft) || throw(ArgumentError(
        "catalog_constraint must be :hard or :soft (got :$(opts.catalog_constraint))"))
    tier = (opts.catalog_constraint === :soft && isnothing(catalog) &&
            isnothing(opts.custom_catalog) && feasible === nothing) ?
        opts.catalog : nothing
    result = nothing
    while true
        try
            result = run(cat)
            break
        catch e
            next = tier === nothing ? nothing : get(_RC_BEAM_CATALOG_GROWTH, tier, nothing)
            (next !== nothing && _no_feasible_section(e)) || rethrow()
            cat = _merge_rc_beam_catalogs(cat, rc_beam_catalog(next))
            @warn "RC beam sizing: no section in the :$tier catalog passes; " *
                  "retrying with :$next added (depths to " *
                  "$(round(Int, ustrip(u"inch", maximum(s -> s.h, cat)))) in)." reason = e.msg
            emit!(tc, :sizing, "size_beams", "", :decision;
                  phase = "catalog_growth", from = string(tier), to = string(next))
            tier = next
        end
    end
    emit!(tc, :sizing, "size_beams", "", :exit; status=string(result.status))
    return _caller_materials(result, opts)
end

"Next larger named RC beam catalog. `:xlarge` is the top."
const _RC_BEAM_CATALOG_GROWTH = Dict(
    :small => :standard, :standard => :large, :large => :xlarge, :all => :xlarge)

"""
    grow_rc_beam_catalog(cat, tier) -> Union{Nothing, Tuple{Vector, Symbol}}

One step up from the named catalog `tier` that just failed, merged into `cat`.
`nothing` when `tier` is already the top or is not a named catalog.
"""
function grow_rc_beam_catalog(cat, tier::Symbol)
    next = get(_RC_BEAM_CATALOG_GROWTH, tier, nothing)
    next === nothing && return nothing
    return (_merge_rc_beam_catalogs(cat, rc_beam_catalog(next)), next)
end

"True for the discrete optimizer's error when a group has no feasible section."
_no_feasible_section(e) =
    e isa ArgumentError && startswith(e.msg, "No feasible sections for group")

"The sections of `a` and `b`, without repeats."
_merge_rc_beam_catalogs(a, b) =
    unique(s -> (s.b, s.h, s.n_bars, s.bar_size, s.n_bars_prime, s.bar_size_prime,
                 s.cover, s.stirrup_size), vcat(a, b))

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
  `size_columns`. A per-call catalog.
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
- `shell_spans`: Optional vector, one entry per beam, of [`SteelShellSpan`](@ref)s
  from the story shell. A separate live-load check per span; it never changes
  `δ_max_vec`.
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
    shell_spans::Union{Nothing, AbstractVector} = nothing,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
    tc::Union{Nothing, TraceCollector} = nothing,
    M1x::Union{Nothing, Vector} = nothing,
    M2x::Union{Nothing, Vector} = nothing,
    M1y::Union{Nothing, Vector} = nothing,
    M2y::Union{Nothing, Vector} = nothing,
    transverse_load::Union{Nothing, Bool, AbstractVector} = nothing,
)
    length(Pu) == length(Mu) || throw(ArgumentError("Pu and Mu must have same length"))
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
                        shell_spans=shell_spans,
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
  A per-call catalog, also what a framing level passes via its beam options.
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
  A per-call catalog, also what a framing level passes via its beam options.
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

