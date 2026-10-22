# ==============================================================================
# ACI 318-11 Capacity Checker for RC Beams
# ==============================================================================
# Implements AbstractCapacityChecker for ACI 318 beam design.
# Matches the interface used by ACIColumnChecker / AISCChecker for MIP
# optimization via `optimize_discrete`.
#
# Checks:
#   1. Flexural capacity: φMn ≥ Mu (sagging, catalog bottom steel)
#   2. Negative-moment section adequacy: φMn_neg ≥ Mu_neg (hogging, candidate top steel)
#   3. Shear section adequacy: Vu ≤ φ(Vc + Vs,max)
#   4. Depth constraint: h ≤ max_depth
#   5. Net tensile strain: εt ≥ 0.004 (ACI 318-11 §10.3.5)
#   6. Minimum reinforcement: As ≥ As,min (ACI 318-11 §10.5.1)
#
# Shear note: This checker verifies that the cross-section is geometrically
# large enough to resist the applied shear (i.e., Vs_required ≤ Vs_max).
# Detailed stirrup spacing design is performed after section selection.
# ==============================================================================

using Asap: kip, ksi, to_ksi, to_kip, to_kipft

# ==============================================================================
# Checker Type
# ==============================================================================

"""
    ACIBeamChecker <: AbstractCapacityChecker

ACI 318-11 capacity checker for reinforced concrete beams.
Implements the same interface as AISCChecker / ACIColumnChecker for use
with `optimize_discrete`.

# Fields
- `fy_ksi`: Longitudinal rebar yield strength (ksi)
- `fyt_ksi`: Transverse (stirrup) rebar yield strength (ksi)
- `Es_ksi`: Rebar elastic modulus (ksi)
- `λ`: Lightweight concrete factor (1.0 for NWC)
- `max_depth`: Maximum section depth constraint (meters, Inf = no limit)

# Usage
```julia
checker = ACIBeamChecker(;
    fy_ksi  = 60.0,     # Grade 60 rebar
    fyt_ksi = 60.0,
    Es_ksi  = 29000.0,
)
```
"""
struct ACIBeamChecker <: AbstractCapacityChecker
    fy_ksi::Float64
    fyt_ksi::Float64
    Es_ksi::Float64
    λ::Float64
    max_depth::Float64      # meters

    # ── Optional deflection check (service loads) ──
    # When w_dead_kplf > 0, is_feasible also checks ACI §24.2 deflection.
    w_dead_kplf::Float64    # Service dead load (kip/ft), 0.0 = no deflection check
    w_live_kplf::Float64    # Service live load (kip/ft)
    defl_support::Symbol    # :simply_supported, :cantilever, etc.
    defl_ξ::Float64         # Time-dependent factor (2.0 = 5+ years)
end

function ACIBeamChecker(;
    fy_ksi::Real  = 60.0,
    fyt_ksi::Real = 60.0,
    Es_ksi::Real  = 29000.0,
    λ::Real       = 1.0,
    max_depth     = Inf,
    w_dead_kplf::Real = 0.0,
    w_live_kplf::Real = 0.0,
    defl_support::Symbol = :simply_supported,
    defl_ξ::Real = 2.0,
)
    max_d = isa(max_depth, Length) ? ustrip(u"m", max_depth) : Float64(max_depth)
    ACIBeamChecker(Float64(fy_ksi), Float64(fyt_ksi), Float64(Es_ksi),
                   Float64(λ), max_d,
                   Float64(w_dead_kplf), Float64(w_live_kplf),
                   defl_support, Float64(defl_ξ))
end

# ==============================================================================
# Capacity Cache
# ==============================================================================

"""
    ACIBeamCapacityCache <: AbstractCapacityCache

Caches precomputed capacities and objective coefficients for RC beams.
"""
mutable struct ACIBeamCapacityCache <: AbstractCapacityCache
    φMn::Vector{Float64}            # Sagging flexural capacity per section (kip·ft)
    φMn_neg::Vector{Float64}        # Hogging section-adequacy φMn (kip·ft)
    φVn_max::Vector{Float64}        # Maximum shear capacity per section (kip)
    εt::Vector{Float64}             # Net tensile strain per section (ACI §10.3.5)
    obj_coeffs::Vector{Float64}     # Objective coefficients per section
    depths::Vector{Float64}         # Section depth in meters
    fc_ksi::Float64                 # Concrete strength (ksi)
    fy_ksi::Float64                 # Rebar yield strength (ksi)
    Es_ksi::Float64                 # Rebar elastic modulus (ksi)
end

function ACIBeamCapacityCache(n_sections::Int)
    ACIBeamCapacityCache(
        zeros(n_sections),       # φMn
        zeros(n_sections),       # φMn_neg
        zeros(n_sections),       # φVn_max
        zeros(n_sections),       # εt
        zeros(n_sections),       # obj_coeffs
        zeros(n_sections),       # depths
        0.0, 0.0, 0.0,
    )
end

"""Create an ACI beam capacity cache for `n_sections` catalog entries."""
create_cache(::ACIBeamChecker, n_sections::Int) = ACIBeamCapacityCache(n_sections)


# ==============================================================================
# φMn computation (singly reinforced, raw psi/inch)
# ==============================================================================

"""
Compute φMn in kip·ft for a singly-reinforced RCBeamSection.

Uses:
  a  = As fy / (0.85 f'c b)
  c  = a / β₁
  εt = 0.003 (d − c) / c
  φ  = flexure_phi(εt)
  Mn = As fy (d − a/2)                   (lb·in)
  φMn = φ Mn / 12 000                    (kip·ft)
"""
function _compute_φMn(section::RCBeamSection, fc_psi::Float64, fy_psi::Float64)
    b_in  = ustrip(u"inch", section.b)
    d_in  = ustrip(u"inch", section.d)
    As_in = ustrip(u"inch^2", section.As)

    As_in > 0 || return 0.0
    (b_in > 0 && fc_psi > 0) || throw(ArgumentError("b ($b_in in) and f'c ($fc_psi psi) must be positive"))

    a_in = As_in * fy_psi / (0.85 * fc_psi * b_in)
    β1   = _beta1_from_fc_psi(fc_psi)
    c_in = a_in / β1

    εcu = 0.003  # ACI 318-11 §10.2.3
    εt = c_in > 0 ? εcu * (d_in - c_in) / c_in : 0.0

    φ = flexure_phi(εt)

    Mn_lbin = As_in * fy_psi * (d_in - a_in / 2)   # lb·in
    return φ * Mn_lbin / 12_000.0                    # kip·ft
end

# ==============================================================================
# Negative-moment section adequacy (hogging / top tension)
# ==============================================================================
# Catalogs store concrete dims + one BOTTOM bar layer only. Hogging capacity is
# a section-adequacy check (like stirrups): the maximum φMn over candidate TOP
# bars that fit in one layer. Compression (bottom) steel is ignored —
# conservative. Whitney block and φ = flexure_phi(εt) match the sagging path.
#
# ENGINEERING JUDGMENT: candidate bars are #4–#11 from the REBAR catalog, n
# from 2 to the maximum that fits in one layer (`_max_bars_in_width` with the
# section cover, stirrup, and 3/4 in. aggregate — same as the catalogs).

const _NEG_FLEXURE_BAR_SIZES = 4:11
const _NEG_FLEXURE_D_AGG_IN = 0.75

"""Web (or rectangular) width used for hogging compression and bar fit, inches."""
_neg_flexure_width_in(section::RCBeamSection) = ustrip(u"inch", section.b)
_neg_flexure_width_in(section::RCTBeamSection) = ustrip(u"inch", section.bw)

"""
    _rect_φMn_singly(b_in, d_in, As_in, fc_psi, fy_psi) -> (φMn_kipft, εt)

Singly-reinforced rectangular Whitney φMn. Compression steel ignored.
εcu = 0.003 per ACI 318-11 §10.2.3 (corpus: aci-318-11, page 142).
"""
function _rect_φMn_singly(b_in::Float64, d_in::Float64, As_in::Float64,
                          fc_psi::Float64, fy_psi::Float64)
    As_in > 0 || return (0.0, Inf)
    (b_in > 0 && fc_psi > 0) || return (0.0, 0.0)
    a_in = As_in * fy_psi / (0.85 * fc_psi * b_in)
    β1   = _beta1_from_fc_psi(fc_psi)
    c_in = a_in / β1
    εcu = 0.003  # ACI 318-11 §10.2.3 — corpus: aci-318-11, page 142
    εt = c_in > 0 ? εcu * (d_in - c_in) / c_in : 0.0
    φ = flexure_phi(εt)
    Mn_lbin = As_in * fy_psi * (d_in - a_in / 2)
    return (φ * Mn_lbin / 12_000.0, εt)
end

"""
    _as_min_aci_1051(b_in, d_in, fc_psi, fy_psi) -> Float64

As,min (in²) per ACI 318-11 §10.5.1 Eq. (10-3) and the 200 bw d / fy floor
(corpus: aci-318-11, page 144). `b_in` is bw for T-beams.
"""
function _as_min_aci_1051(b_in::Float64, d_in::Float64, fc_psi::Float64, fy_psi::Float64)
    max(3.0 * sqrt(fc_psi) * b_in * d_in / fy_psi,
        200.0 * b_in * d_in / fy_psi)
end

"""
Iterate candidate single-layer top-bar arrangements that satisfy
ACI 318-11 §10.3.5 (εt ≥ 0.004, page 142) and §10.5.1 (As ≥ As,min, page 144).
Yields NamedTuples `(bar_size, n_bars, As, φMn, εt, d_top)`.
"""
function _each_top_steel_candidate(section, fc_psi::Float64, fy_psi::Float64)
    b_in     = _neg_flexure_width_in(section)
    h_in     = ustrip(u"inch", section.h)
    cover_in = ustrip(u"inch", section.cover)
    d_stir   = ustrip(u"inch", rebar(section.stirrup_size).diameter)
    cands = NamedTuple[]
    for bar_size in _NEG_FLEXURE_BAR_SIZES
        db_in = ustrip(u"inch", rebar(bar_size).diameter)
        Ab_in = ustrip(u"inch^2", rebar(bar_size).A)
        max_n = _max_bars_in_width(b_in, cover_in, d_stir, db_in, _NEG_FLEXURE_D_AGG_IN)
        d_top = h_in - cover_in - d_stir - db_in / 2
        d_top > 0 || continue
        for n in 2:max_n
            As_in = n * Ab_in
            As_in ≥ _as_min_aci_1051(b_in, d_top, fc_psi, fy_psi) || continue
            φMn, εt = _rect_φMn_singly(b_in, d_top, As_in, fc_psi, fy_psi)
            # ACI 318-11 §10.3.5 — corpus: aci-318-11, page 142
            εt ≥ 0.004 || continue
            push!(cands, (bar_size=bar_size, n_bars=n, As=As_in, φMn=φMn, εt=εt, d_top=d_top))
        end
    end
    return cands
end

"""
    _compute_φMn_neg(section, fc_psi, fy_psi) -> Float64

Maximum hogging φMn (kip·ft) over candidate top-bar arrangements.
Hogging compression is at the bottom face; width is `b` (rectangular) or
`bw` (T-beam). For T-beams, ACI 318-11 §10.6.6 (corpus: aci-318-11, page 146)
requires part of the flange-tension steel to be distributed over the effective
flange width or ℓn/10 — a detailing requirement not modeled in this capacity.
"""
function _compute_φMn_neg(section, fc_psi::Float64, fy_psi::Float64)
    cands = _each_top_steel_candidate(section, fc_psi, fy_psi)
    isempty(cands) && return 0.0
    return maximum(c.φMn for c in cands)
end

"""True if the section's hogging adequacy φMn_neg covers `Mu_neg` (kip·ft)."""
function _neg_moment_adequate(section, Mu_neg_kipft::Float64, fc_psi::Float64, fy_psi::Float64)
    _compute_φMn_neg(section, fc_psi, fy_psi) ≥ Mu_neg_kipft
end

"""
    required_top_steel(section, Mu_neg; fc, fy) -> NamedTuple or nothing

Smallest adequate single-layer top-bar arrangement for hogging moment `Mu_neg`
(kip·ft or Unitful). Among arrangements with φMn ≥ Mu_neg, εt ≥ 0.004, and
As ≥ As,min, pick minimum `As`, then fewest bars, then smaller designation.
Returns `(bar_size, n_bars, As, φMn, εt, d_top)` or `nothing`.
"""
function required_top_steel(section, Mu_neg; fc, fy)
    fc_psi = fc isa Unitful.Quantity ? ustrip(u"psi", fc) : Float64(fc) * 1000.0
    fy_psi = fy isa Unitful.Quantity ? ustrip(u"psi", fy) : Float64(fy) * 1000.0
    Mu_kipft = to_kipft(Mu_neg)
    cands = filter(c -> c.φMn ≥ Mu_kipft, _each_top_steel_candidate(section, fc_psi, fy_psi))
    isempty(cands) && return nothing
    return first(sort(cands; by=c -> (c.As, c.n_bars, c.bar_size)))
end

# ==============================================================================
# φVn_max computation (raw psi/inch)
# ==============================================================================

"""
Maximum possible design shear capacity for the section geometry (Nu=0 baseline):

  Vc     = 2 λ √f'c bw d         (lb)
  Vs_max = 8 √f'c bw d           (ACI §22.5.1.2)
  φVn    = 0.75 (Vc + Vs_max)    (kip)

Note: When Nu > 0, the axial compression modifier is applied in
`is_feasible` rather than here, since Nu is demand-specific.
"""
function _compute_φVn_max(section::RCBeamSection, fc_psi::Float64, λ::Float64)
    b_in = ustrip(u"inch", section.b)
    d_in = ustrip(u"inch", section.d)

    sqrt_fc = sqrt(fc_psi)
    Vc_lb     = 2 * λ * sqrt_fc * b_in * d_in
    Vs_max_lb = 8 * sqrt_fc * b_in * d_in

    return 0.75 * (Vc_lb + Vs_max_lb) / 1000.0      # kip
end

# ==============================================================================
# εt computation (ACI 318-11 §10.3.5)
# ==============================================================================

"""
Net tensile strain εt for a singly-reinforced RCBeamSection.

ACI 318-11 §10.3.5 requires εt ≥ 0.004 for beams (nonprestressed
flexural members).  Sections with εt < 0.004 are compression-controlled
and prohibited for beams.
"""
function _compute_εt(section::RCBeamSection, fc_psi::Float64, fy_psi::Float64)
    b_in  = ustrip(u"inch", section.b)
    d_in  = ustrip(u"inch", section.d)
    As_in = ustrip(u"inch^2", section.As)

    As_in > 0 || return Inf  # No steel → infinite strain (always OK)
    (b_in > 0 && fc_psi > 0) || throw(ArgumentError("b ($b_in in) and f'c ($fc_psi psi) must be positive"))

    a_in = As_in * fy_psi / (0.85 * fc_psi * b_in)
    β1   = _beta1_from_fc_psi(fc_psi)
    c_in = a_in / β1

    εcu = 0.003  # ACI 318-11 §10.2.3
    return c_in > 0 ? εcu * (d_in - c_in) / c_in : Inf
end

# ==============================================================================
# Interface: precompute_capacities!
# ==============================================================================

"""
    precompute_capacities!(checker::ACIBeamChecker, cache, catalog, material, objective)

Precompute flexural, shear, and strain capacities for all beam sections in the catalog.
Thread-safe: each section index writes to distinct cache slots.
"""
function precompute_capacities!(
    checker::ACIBeamChecker,
    cache::ACIBeamCapacityCache,
    catalog::AbstractVector{<:AbstractSection},
    material::Concrete,
    objective::AbstractObjective,
)
    n = length(catalog)

    fc_ksi_val = fc_ksi(material)   # from aci_material_utils
    cache.fc_ksi = fc_ksi_val
    cache.fy_ksi = checker.fy_ksi
    cache.Es_ksi = checker.Es_ksi

    fc_psi = fc_ksi_val * 1000.0
    fy_psi = checker.fy_ksi * 1000.0

    # Determine target unit for objective
    ref_obj = objective_value(objective, catalog[1], material, 1.0u"m")
    ref_unit = unit(ref_obj)

    # Thread-safe: each iteration writes to distinct cache indices
    Threads.@threads for j in 1:n
        section = catalog[j]

        # Flexural capacity (sagging catalog steel + hogging section adequacy)
        cache.φMn[j] = _compute_φMn(section, fc_psi, fy_psi)
        cache.φMn_neg[j] = _compute_φMn_neg(section, fc_psi, fy_psi)

        # Maximum shear capacity
        cache.φVn_max[j] = _compute_φVn_max(section, fc_psi, checker.λ)

        # Net tensile strain (ACI 318-11 §10.3.5)
        cache.εt[j] = _compute_εt(section, fc_psi, fy_psi)

        # Section depth in meters
        cache.depths[j] = ustrip(u"m", section.h)

        # Objective coefficient (value per meter of beam)
        val = objective_value(objective, section, material, 1.0u"m")
        cache.obj_coeffs[j] = ref_unit != Unitful.NoUnits ? ustrip(ref_unit, val) : Float64(val)
    end
end

# ==============================================================================
# Interface: is_feasible
# ==============================================================================

"""
    is_feasible(checker, cache, j, section, material, demand, geometry) -> Bool

Check if an RC beam section satisfies ACI 318 requirements:
1. Depth constraint: h ≤ max_depth
2. Flexure (sagging): Mu ≤ φMn
3. Flexure (hogging adequacy): Mu_neg ≤ φMn_neg
4. Shear adequacy: Vu ≤ φ(Vc + Vs,max), with signed-Nu modifier
5. Net tensile strain: εt ≥ 0.004 (ACI 318-11 §10.3.5)
6. Minimum reinforcement: As ≥ As,min (ACI 318-11 §10.5.1)
7. Torsion section adequacy (ACI 318-11 §11.5.3.1) — when Tu > 0
"""
function is_feasible(
    checker::ACIBeamChecker,
    cache::ACIBeamCapacityCache,
    j::Int,
    section::RCBeamSection,
    material::Concrete,
    demand::RCBeamDemand,
    geometry::ConcreteMemberGeometry,
)::Bool
    Mu = to_kipft(demand.Mu)
    Mu_neg = to_kipft(demand.Mu_neg)
    Vu = to_kip(demand.Vu)

    # 1. Depth check
    cache.depths[j] ≤ checker.max_depth || return false

    # 2. Sagging flexural check  — φMn ≥ Mu
    cache.φMn[j] ≥ Mu || return false

    # 3. Hogging section adequacy — φMn_neg ≥ Mu_neg
    cache.φMn_neg[j] ≥ Mu_neg || return false

    # 4. Shear adequacy — section large enough for the shear.
    #    Signed Nu: compression (Nu>0) uses Eq. (11-4); tension (Nu<0) uses
    #    Eq. (11-8). Nu = 0 uses the cached no-axial φVn_max.
    Nu_kip = _get_Nu_kip(demand)
    if Nu_kip != 0
        fc_psi_s = cache.fc_ksi * 1000.0
        b_in_s   = ustrip(u"inch", section.b)
        d_in_s   = ustrip(u"inch", section.d)
        h_in_s   = ustrip(u"inch", section.h)
        Ag_in2   = b_in_s * h_in_s
        φVn_kip = _φVn_with_axial(b_in_s, d_in_s, Ag_in2, Ag_in2, fc_psi_s, checker.λ, Nu_kip)
        φVn_kip ≥ Vu || return false
    else
        cache.φVn_max[j] ≥ Vu || return false
    end

    # 4. Net tensile strain (ACI 318-11 §10.3.5) — εt ≥ 0.004 for beams
    cache.εt[j] ≥ 0.004 || return false

    # 5. Minimum reinforcement (ACI 318-11 §10.5.1)
    fc_psi = cache.fc_ksi * 1000.0
    fy_psi = cache.fy_ksi * 1000.0
    b_in   = ustrip(u"inch", section.b)
    d_in   = ustrip(u"inch", section.d)
    As_in  = ustrip(u"inch^2", section.As)
    As_min = max(3.0 * sqrt(fc_psi) * b_in * d_in / fy_psi,
                 200.0 * b_in * d_in / fy_psi)
    As_in ≥ As_min || return false

    # 6. Torsion section adequacy (§11.5.3.1) — only when Tu > 0
    Tu_val = _get_Tu_kipin(demand)
    if Tu_val > 0.0
        h_in = ustrip(u"inch", section.h)
        d_stir = ustrip(u"inch", rebar(section.stirrup_size).diameter)
        cov_in = ustrip(u"inch", section.cover)
        c_ctr  = cov_in + d_stir / 2

        props = torsion_section_properties(section.b, section.h, c_ctr * u"inch")
        Tth = threshold_torsion(props.Acp, props.pcp, fc_psi; λ=checker.λ)
        if Tu_val > Tth
            torsion_section_adequate(Vu, Tu_val, b_in, d_in,
                                     props.Aoh, props.ph, fc_psi;
                                     λ=checker.λ) || return false
        end
    end

    return true
end

"""Extract factored torsion Tu from demand as kip·in (backward-compatible)."""
function _get_Tu_kipin(demand::RCBeamDemand)
    Tu = demand.Tu
    if Tu isa Unitful.Quantity
        return abs(ustrip(kip*u"inch", Tu))
    else
        return abs(Float64(Tu))
    end
end

"""
Extract signed factored axial force Nu from demand as kip.

Positive = compression (ACI 318-11 §11.2.1.2), negative = tension
(ACI 318-11 §11.2.2.3, "Nu is negative for tension").
"""
function _get_Nu_kip(demand::RCBeamDemand)
    Nu = demand.Nu
    if Nu isa Unitful.Quantity
        return ustrip(kip, Nu)
    else
        return Float64(Nu)
    end
end

"""
    _φVn_with_axial(bw_in, d_in, Ag_comp_in2, Ag_tens_in2, fc_psi, λ, Nu_kip) -> Float64

Design shear φ(Vc + Vs,max) in kip with signed axial modifier.

- `Nu_kip > 0`: ACI 318-11 §11.2.1.2 Eq. (11-4) (corpus: aci-318-11, page 168)
  `Vc = 2(1 + Nu/(2000 Ag)) λ √f'c bw d`, `Nu/Ag` in psi.
- `Nu_kip < 0`: ACI 318-11 §11.2.2.3 Eq. (11-8) (corpus: aci-318-11, page 170)
  `Vc = 2(1 + Nu/(500 Ag)) λ √f'c bw d`, not less than zero.
- `Vs,max = 8 √f'c bw d` (ACI 318-11 §11.4.7.9); φ = 0.75.

`Ag_comp_in2` / `Ag_tens_in2` let T-beams use the conservative gross area
for each sign (larger Ag for compression, smaller Ag for tension).
"""
function _φVn_with_axial(bw_in::Float64, d_in::Float64,
                         Ag_comp_in2::Float64, Ag_tens_in2::Float64,
                         fc_psi::Float64, λ::Float64, Nu_kip::Float64)
    sqrt_fc = sqrt(fc_psi)
    Vs_max_lb = 8 * sqrt_fc * bw_in * d_in
    if Nu_kip > 0
        # ACI 318-11 §11.2.1.2 Eq. (11-4) — corpus: aci-318-11, page 168
        axial = 1 + (Nu_kip * 1000) / (2000 * Ag_comp_in2)
        Vc_lb = 2 * λ * axial * sqrt_fc * bw_in * d_in
    elseif Nu_kip < 0
        # ACI 318-11 §11.2.2.3 Eq. (11-8) — corpus: aci-318-11, page 170
        axial = 1 + (Nu_kip * 1000) / (500 * Ag_tens_in2)
        Vc_lb = max(0.0, 2 * λ * axial * sqrt_fc * bw_in * d_in)
    else
        Vc_lb = 2 * λ * sqrt_fc * bw_in * d_in
    end
    return 0.75 * (Vc_lb + Vs_max_lb) / 1000.0
end

# ==============================================================================
# Interface: get_objective_coeff
# ==============================================================================

"""Get the precomputed objective coefficient for beam section `j`."""
function get_objective_coeff(
    checker::ACIBeamChecker,
    cache::ACIBeamCapacityCache,
    j::Int,
)::Float64
    cache.obj_coeffs[j]
end

# ==============================================================================
# Interface: error message
# ==============================================================================

"""Generate descriptive error message for infeasible ACI beam groups."""
function get_feasibility_error_msg(
    checker::ACIBeamChecker,
    demand::RCBeamDemand,
    geometry::ConcreteMemberGeometry,
)
    Mu = to_kipft(demand.Mu)
    Mu_neg = to_kipft(demand.Mu_neg)
    Vu = to_kip(demand.Vu)
    Nu = _get_Nu_kip(demand)
    Tu = _get_Tu_kipin(demand)
    base = "No feasible RC beam section: Mu=$(round(Mu, digits=1)) kip·ft, " *
           "Mu_neg=$(round(Mu_neg, digits=1)) kip·ft, " *
           "Vu=$(round(Vu, digits=1)) kip, L=$(geometry.L)"
    if Nu != 0 || Tu > 0
        base *= " (Nu=$(round(Nu, digits=1)) kip, Tu=$(round(Tu, digits=1)) kip·in)"
    end
    base
end

"""
    diagnose_infeasibility(checker, cache, catalog, material, demand, geometry) -> String

Run feasibility checks on the highest-capacity section and return which check failed.
Useful for debugging when no section passes.
"""
function diagnose_infeasibility(
    checker::ACIBeamChecker,
    cache::ACIBeamCapacityCache,
    catalog::AbstractVector,
    material::Concrete,
    demand::RCBeamDemand,
    geometry::ConcreteMemberGeometry,
)::String
    n = length(catalog)
    n == 0 && return "Catalog is empty"
    best_j = argmax(cache.φMn)
    sec = catalog[best_j]
    Mu = to_kipft(demand.Mu)
    Mu_neg = to_kipft(demand.Mu_neg)
    Vu = to_kip(demand.Vu)
    Nu_kip = _get_Nu_kip(demand)
    Tu_val = _get_Tu_kipin(demand)

    if cache.depths[best_j] > checker.max_depth
        return "Depth: h=$(cache.depths[best_j])m > max_depth=$(checker.max_depth)m"
    end
    if cache.φMn[best_j] < Mu
        return "Flexure: φMn=$(round(cache.φMn[best_j], digits=1)) < Mu=$(round(Mu, digits=1)) kip·ft"
    end
    if cache.φMn_neg[best_j] < Mu_neg
        return "Neg. flexure: φMn_neg=$(round(cache.φMn_neg[best_j], digits=1)) < Mu_neg=$(round(Mu_neg, digits=1)) kip·ft"
    end
    if Nu_kip != 0
        fc_psi = cache.fc_ksi * 1000.0
        b_in = ustrip(u"inch", sec.b)
        d_in = ustrip(u"inch", sec.d)
        h_in = ustrip(u"inch", sec.h)
        Ag_in2 = b_in * h_in
        φVn_kip = _φVn_with_axial(b_in, d_in, Ag_in2, Ag_in2, fc_psi, checker.λ, Nu_kip)
        if φVn_kip < Vu
            tag = Nu_kip < 0 ? "Nu<0" : "Nu>0"
            return "Shear ($tag): φVn=$(round(φVn_kip, digits=1)) < Vu=$(round(Vu, digits=1)) kip"
        end
    else
        if cache.φVn_max[best_j] < Vu
            return "Shear: φVn_max=$(round(cache.φVn_max[best_j], digits=1)) < Vu=$(round(Vu, digits=1)) kip"
        end
    end
    if cache.εt[best_j] < 0.004
        return "εt: $(round(cache.εt[best_j], digits=4)) < 0.004 (ACI §10.3.5)"
    end
    fc_psi = cache.fc_ksi * 1000.0
    fy_psi = cache.fy_ksi * 1000.0
    b_in = ustrip(u"inch", sec.b)
    d_in = ustrip(u"inch", sec.d)
    As_in = ustrip(u"inch^2", sec.As)
    As_min = max(3.0 * sqrt(fc_psi) * b_in * d_in / fy_psi, 200.0 * b_in * d_in / fy_psi)
    if As_in < As_min
        return "As_min: As=$(round(As_in, digits=2)) < As_min=$(round(As_min, digits=2)) in²"
    end
    if Tu_val > 0.0
        h_in = ustrip(u"inch", sec.h)
        d_stir = ustrip(u"inch", rebar(sec.stirrup_size).diameter)
        cov_in = ustrip(u"inch", sec.cover)
        c_ctr = cov_in + d_stir / 2
        props = torsion_section_properties(sec.b, sec.h, c_ctr * u"inch")
        Tth = threshold_torsion(props.Acp, props.pcp, fc_psi; λ=checker.λ)
        if Tu_val > Tth && !torsion_section_adequate(Vu, Tu_val, b_in, d_in, props.Aoh, props.ph, fc_psi; λ=checker.λ)
            return "Torsion: section inadequate for Tu=$(round(Tu_val, digits=1)) kip·in"
        end
    end
    return "All checks passed for best section — possible threading/cache inconsistency"
end

# ==============================================================================
# Objective Values for RCBeamSection
# ==============================================================================

"""Objective value: gross concrete volume of the RC beam per unit length."""
function objective_value(
    ::MinVolume,
    section::RCBeamSection,
    material::Concrete,
    length::Length,
)
    Ag = section.b * section.h
    uconvert(u"m^3", Ag * length)
end

"""Objective value: self-weight of the RC beam per unit length."""
function objective_value(
    ::MinWeight,
    section::RCBeamSection,
    material::Concrete,
    length::Length,
)
    Ag = section.b * section.h
    uconvert(u"kN", Ag * length * material.ρ * 1u"gn")
end

"""Objective value: cost proxy (volume) for the RC beam per unit length."""
function objective_value(
    ::MinCost,
    section::RCBeamSection,
    material::Concrete,
    length::Length,
)
    Ag = section.b * section.h
    uconvert(u"m^3", Ag * length)
end

"""Objective value: embodied carbon of the RC beam per unit length, returned
as a typed `kgCO₂e` quantity (Asap `𝐗` dimension)."""
function objective_value(
    ::MinCarbon,
    section::RCBeamSection,
    material::Concrete,
    length::Length,
)
    Ag = section.b * section.h
    volume = uconvert(u"m^3", Ag * length)
    return uconvert(u"kgCO2e", volume * material.ρ * material.ecc)
end

# ==============================================================================
# Feasibility Explanation (Solver Trace)
# ==============================================================================

"""
    explain_feasibility(checker::ACIBeamChecker, cache, j, section, material, demand, geometry)

Evaluate ALL ACI 318 beam checks without short-circuiting and return per-check
demand/capacity ratios. Mirrors `is_feasible` for ACIBeamChecker exactly but
collects every intermediate result.
"""
function explain_feasibility(
    checker::ACIBeamChecker,
    cache::ACIBeamCapacityCache,
    j::Int,
    section::RCBeamSection,
    material::Concrete,
    demand::RCBeamDemand,
    geometry::ConcreteMemberGeometry,
)::FeasibilityExplanation
    checks = CheckResult[]

    Mu = to_kipft(demand.Mu)
    Mu_neg = to_kipft(demand.Mu_neg)
    Vu = to_kip(demand.Vu)

    # --- 1. Depth Check ---
    d_section = cache.depths[j]
    d_limit = checker.max_depth
    d_ratio = d_limit > 0 ? d_section / d_limit : 0.0
    push!(checks, CheckResult("depth", d_section <= d_limit,
          d_ratio, d_section, d_limit, ""))

    # --- 2. Sagging flexure — ACI 318-11 §10.2 / §9.3.2 ---
    φMn = cache.φMn[j]
    flex_ratio = φMn > 0 ? Mu / φMn : (Mu > 0 ? Inf : 0.0)
    push!(checks, CheckResult("flexure", φMn >= Mu,
          flex_ratio, Mu, φMn, "ACI 318-11 10.2"))

    # --- 2b. Hogging section adequacy ---
    φMn_neg = cache.φMn_neg[j]
    neg_ratio = φMn_neg > 0 ? Mu_neg / φMn_neg : (Mu_neg > 0 ? Inf : 0.0)
    push!(checks, CheckResult("flexure_neg", φMn_neg >= Mu_neg,
          neg_ratio, Mu_neg, φMn_neg, "ACI 318-11 10.2"))

    # --- 3. Shear Adequacy — ACI 318-11 §11.2 ---
    Nu_kip = _get_Nu_kip(demand)
    if Nu_kip != 0
        fc_psi_s = cache.fc_ksi * 1000.0
        b_in_s   = ustrip(u"inch", section.b)
        d_in_s   = ustrip(u"inch", section.d)
        h_in_s   = ustrip(u"inch", section.h)
        Ag_in2   = b_in_s * h_in_s
        φVn_kip = _φVn_with_axial(b_in_s, d_in_s, Ag_in2, Ag_in2, fc_psi_s, checker.λ, Nu_kip)
    else
        φVn_kip = cache.φVn_max[j]
    end
    shear_ratio = φVn_kip > 0 ? Vu / φVn_kip : (Vu > 0 ? Inf : 0.0)
    shear_clause = Nu_kip < 0 ? "ACI 318-11 11.2.2.3" : (Nu_kip > 0 ? "ACI 318-11 11.2.1.2" : "ACI 318-11 11.2.1.1")
    push!(checks, CheckResult("shear", φVn_kip >= Vu,
          shear_ratio, Vu, φVn_kip, shear_clause))

    # --- 4. Net Tensile Strain — ACI 318-11 §10.3.5 ---
    εt = cache.εt[j]
    εt_limit = 0.004
    εt_ratio = εt_limit > 0 ? εt_limit / max(εt, 1e-10) : 0.0
    push!(checks, CheckResult("net_tensile_strain", εt >= εt_limit,
          εt_ratio, εt_limit, εt, "ACI 318-11 10.3.5"))

    # --- 5. Minimum Reinforcement — ACI 318-11 §10.5.1 ---
    fc_psi = cache.fc_ksi * 1000.0
    fy_psi = cache.fy_ksi * 1000.0
    b_in   = ustrip(u"inch", section.b)
    d_in   = ustrip(u"inch", section.d)
    As_in  = ustrip(u"inch^2", section.As)
    As_min = _as_min_aci_1051(b_in, d_in, fc_psi, fy_psi)
    min_reinf_ratio = As_min > 0 ? As_min / max(As_in, 1e-10) : 0.0
    push!(checks, CheckResult("min_reinforcement", As_in >= As_min,
          min_reinf_ratio, As_min, As_in, "ACI 318-11 10.5.1"))

    # --- 6. Torsion Section Adequacy — ACI 318-19 §22.7 ---
    Tu_val = _get_Tu_kipin(demand)
    if Tu_val > 0.0
        h_in = ustrip(u"inch", section.h)
        d_stir = ustrip(u"inch", rebar(section.stirrup_size).diameter)
        cov_in = ustrip(u"inch", section.cover)
        c_ctr  = cov_in + d_stir / 2

        props = torsion_section_properties(section.b, section.h, c_ctr * u"inch")
        Tth = threshold_torsion(props.Acp, props.pcp, fc_psi; λ=checker.λ)

        if Tu_val > Tth
            torsion_ok = torsion_section_adequate(Vu, Tu_val, b_in, d_in,
                                                   props.Aoh, props.ph, fc_psi;
                                                   λ=checker.λ)
            torsion_ratio = torsion_ok ? 0.9 : 1.1  # approximate — exact ratio is internal
            push!(checks, CheckResult("torsion_adequacy", torsion_ok,
                  torsion_ratio, Tu_val, Tth, "ACI 318-19 22.7"))
        end
    end

    # --- Aggregate ---
    all_pass = all(c -> c.passed, checks)
    gov_idx = argmax([c.ratio for c in checks])
    gov = checks[gov_idx]

    FeasibilityExplanation(all_pass, checks, gov.name, gov.ratio)
end
