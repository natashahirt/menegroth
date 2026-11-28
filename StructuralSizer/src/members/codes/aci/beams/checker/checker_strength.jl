
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
    _rect_as_required_in2(Mu_kipft, b, d, fc_psi, fy_psi) -> Float64

Tension steel (in²) required by analysis for a rectangular section, or `0`
when `Mu` does not call for it. `Inf` when the section cannot develop `Mu`.
"""
function _rect_as_required_in2(Mu_kipft::Real, b::Length, d::Length, fc_psi::Real, fy_psi::Real)
    Mu_kipft <= 0 && return 0.0
    As = required_reinforcement(float(Mu_kipft) * Asap.kip * u"ft", b, d,
                                float(fc_psi) * u"psi", float(fy_psi) * u"psi";
                                require_tension_controlled = false)
    return float(ustrip(u"inch^2", As))
end

"""
    _min_steel_check(As_in, As_min, As_req) -> NamedTuple

ACI 318-11 §10.5.1 (corpus: aci-318-11, page 144) where analysis requires
tension steel, and §10.5.3 (page 145): that minimum need not be met when the
steel provided is at least one-third greater than the steel required by
analysis. `As_req` is that area in in². A non-positive `As_req` means analysis
requires no tension steel, so §10.5.1 does not apply.
"""
function _min_steel_check(As_in::Float64, As_min::Float64, As_req::Float64)
    if As_req <= 0
        return (passed = true, ratio = 0.0, clause = "ACI 318-11 10.5.1")
    end
    if As_in + 1e-9 >= As_min
        return (passed = true, ratio = As_min / max(As_in, 1e-10),
                clause = "ACI 318-11 10.5.1")
    end
    # "at least one-third greater" is (4/3) of the analysis area.
    floor = (4 / 3) * As_req
    if isfinite(floor) && As_in + 1e-9 >= floor
        return (passed = true, ratio = floor / max(As_in, 1e-10),
                clause = "ACI 318-11 10.5.3")
    end
    return (passed = false, ratio = As_min / max(As_in, 1e-10),
            clause = "ACI 318-11 10.5.1")
end

"""
    _sizing_requires_as_min(checker, As_in, As_min, As_req) -> Bool

`true` when discrete sizing must reject this steel.

ACI 318-11 §10.5.1 Eq. (10-3) (corpus: aci-318-11, page 144) is `As,min`.
§10.5.3 (page 145) waives it when the provided steel is at least one-third
greater than the steel required by analysis. [`_min_steel_check`](@ref) keeps
that waiver for the published check.

ENGINEERING JUDGMENT: `checker.size_to_as_min` declines the waiver while a
section is being chosen. The moment of this pass is not the final moment, and
a later pass can raise it until §10.5.3 no longer applies. Analysis that
requires no tension steel (`As_req ≤ 0`) does not call for `As,min`.
"""
function _sizing_requires_as_min(checker::ACIBeamChecker, As_in::Float64, As_min::Float64,
                                 As_req::Float64)
    checker.size_to_as_min || return false
    As_req > 0 || return false
    return As_in + 1e-9 < As_min
end

"""The published minimum-steel result, tightened when sizing requires `As,min`."""
function _sizing_min_steel(checker::ACIBeamChecker, As_in::Float64, As_min::Float64,
                           As_req::Float64)
    steel = _min_steel_check(As_in, As_min, As_req)
    _sizing_requires_as_min(checker, As_in, As_min, As_req) || return steel
    return (passed = false, ratio = As_min / max(As_in, 1e-10),
            clause = "sizing requires As,min")
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
function _compute_φVn_max(section::RCBeamSection, fc_psi::Float64, λ::Float64;
                          vc_factor::Float64 = 1.0, vs_factor::Float64 = 1.0)
    b_in = ustrip(u"inch", section.b)
    d_in = ustrip(u"inch", section.d)

    sqrt_fc = sqrt(fc_psi)
    Vc_lb     = vc_factor * 2 * λ * sqrt_fc * b_in * d_in
    # vs_factor is 0 when stirrups are not credited. §11.4.7.9 still defines Vs,max.
    Vs_max_lb = vs_factor * 8 * sqrt_fc * b_in * d_in

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
    objective::AbstractObjective;
    rebar=nothing,
    transverse=nothing,
)
    n = length(catalog)

    fc_ksi_val = fc_ksi(material)   # from aci_material_utils
    cache.fc_ksi = fc_ksi_val
    cache.fy_ksi = checker.fy_ksi
    cache.Es_ksi = checker.Es_ksi

    fc_psi = fc_ksi_val * 1000.0
    fy_psi = checker.fy_ksi * 1000.0

    # Determine target unit for objective
    ref_obj = objective_value(objective, catalog[1], material, 1.0u"m";
                              rebar=rebar, transverse=transverse)
    ref_unit = unit(ref_obj)

    # Thread-safe: each iteration writes to distinct cache indices
    Threads.@threads for j in 1:n
        section = catalog[j]

        # Flexural capacity (sagging catalog steel + hogging section adequacy)
        cache.φMn[j] = _compute_φMn(section, fc_psi, fy_psi)
        cache.φMn_neg[j] = _compute_φMn_neg(section, fc_psi, fy_psi)

        # Maximum shear capacity
        cache.φVn_max[j] = _compute_φVn_max(section, fc_psi, checker.λ;
                                            vc_factor = _checker_vc_factor(checker, section),
                                            vs_factor = _checker_vs_factor(checker))

        # Net tensile strain (ACI 318-11 §10.3.5)
        cache.εt[j] = _compute_εt(section, fc_psi, fy_psi)

        # Section depth in meters
        cache.depths[j] = ustrip(u"m", section.h)

        # Objective coefficient (value per meter of beam)
        val = objective_value(objective, section, material, 1.0u"m";
                              rebar=rebar, transverse=transverse)
        cache.obj_coeffs[j] = ref_unit != Unitful.NoUnits ? ustrip(ref_unit, val) : Float64(val)
    end
end

"""Longitudinal steel is weighed, costed, and counted in carbon. Flexural fy stays on the checker."""
function precompute_capacities!(
    checker::ACIBeamChecker,
    cache::ACIBeamCapacityCache,
    catalog::AbstractVector{<:AbstractSection},
    material::ReinforcedConcreteMaterial,
    objective::AbstractObjective,
)
    precompute_capacities!(checker, cache, catalog, material.concrete, objective;
                           rebar=material.rebar, transverse=material.transverse)
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
4. Shear adequacy: Vu ≤ φ(Vc + Vs,max), with signed-Nu modifier, and torsion
   section adequacy (ACI 318-11 §11.5.3.1) when Tu > 0, on each concurrent row
5. Net tensile strain: εt ≥ 0.004 (ACI 318-11 §10.3.5)
6. Minimum reinforcement: As ≥ As,min (ACI 318-11 §10.5.1)
7. Service deflection (ACI 318-11 §9.5.2) when `w_dead_kplf > 0`, and the
   story-shell spans when given
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

    # 1. Depth check
    cache.depths[j] ≤ checker.max_depth || return false

    # 2. Sagging flexural check  — φMn ≥ Mu
    cache.φMn[j] ≥ Mu || return false

    # 3. Hogging section adequacy — φMn_neg ≥ Mu_neg
    cache.φMn_neg[j] ≥ Mu_neg || return false

    # 4. Shear and torsion section adequacy, one row per concurrent case. The
    #    demand envelope is that row when the checker was given no case list.
    #    Tension uses Eq. (11-8); compression uses Eq. (11-4) only with the Vu
    #    of the same case. Torsion (§11.5.3.1) is checked on each row above
    #    the threshold.
    _rectangular_shear_failure(checker, cache, j, section, demand) === nothing ||
        return false

    # 4. Net tensile strain (ACI 318-11 §10.3.5) — εt ≥ 0.004 for beams
    cache.εt[j] ≥ 0.004 || return false

    # 5. Minimum reinforcement (ACI 318-11 §10.5.1, §10.5.3)
    fc_psi = cache.fc_ksi * 1000.0
    fy_psi = cache.fy_ksi * 1000.0
    b_in   = ustrip(u"inch", section.b)
    d_in   = ustrip(u"inch", section.d)
    As_in  = ustrip(u"inch^2", section.As)
    As_min = _as_min_aci_1051(b_in, d_in, fc_psi, fy_psi)
    As_req = _rect_as_required_in2(to_kipft(demand.Mu), section.b, section.d, fc_psi, fy_psi)
    _sizing_min_steel(checker, As_in, As_min, As_req).passed || return false

    # 6. Service deflection (ACI 318-11 §9.5.2). w_dead_kplf = 0 skips it.
    if checker.w_dead_kplf > 0
        defl = design_beam_deflection(
            section.b, section.h, section.d, section.As,
            fc_psi * u"psi", fy_psi * u"psi", checker.Es_ksi * ksi,
            geometry.L,
            checker.w_dead_kplf * kip / u"ft",
            checker.w_live_kplf * kip / u"ft";
            support = checker.defl_support,
            ξ = checker.defl_ξ,
            sustained_live_fraction = checker.defl_sustained_live,
        )
        defl.ok || return false
    end

    # 7. Story-shell deflection (ACI 318-11 §9.5.2) — when the shell gave spans
    _shell_deflection_ratio(checker, demand.member_idx, section) <= 1 || return false

    return true
end

"""Strength checks use the concrete. The rebar on a reinforced-concrete material is for the objective."""
function is_feasible(
    checker::ACIBeamChecker,
    cache::ACIBeamCapacityCache,
    j::Int,
    section::RCBeamSection,
    material::ReinforcedConcreteMaterial,
    demand::RCBeamDemand,
    geometry::ConcreteMemberGeometry,
)
    is_feasible(checker, cache, j, section, material.concrete, demand, geometry)
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
                         fc_psi::Float64, λ::Float64, Nu_kip::Float64;
                         vc_factor::Float64 = 1.0, vs_factor::Float64 = 1.0)
    sqrt_fc = sqrt(fc_psi)
    # vs_factor scales §11.4.7.9. 0 withholds stirrup shear (caller judgment).
    Vs_max_lb = vs_factor * 8 * sqrt_fc * bw_in * d_in
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
    # ACI 318-11 §8.13.8: joist Vc is permitted 10 percent above Chapter 11.
    return 0.75 * (vc_factor * Vc_lb + Vs_max_lb) / 1000.0
end

"""φVn (kip) of one rectangular section at one signed axial force."""
function _section_φVn(checker::ACIBeamChecker, cache::ACIBeamCapacityCache,
                      j::Int, section::RCBeamSection, Nu_kip::Float64)
    Nu_kip == 0 && return cache.φVn_max[j]
    fc_psi = cache.fc_ksi * 1000.0
    b_in = ustrip(u"inch", section.b)
    d_in = ustrip(u"inch", section.d)
    Ag = b_in * ustrip(u"inch", section.h)
    return _φVn_with_axial(b_in, d_in, Ag, Ag, fc_psi, checker.λ, Nu_kip;
                           vc_factor = _checker_vc_factor(checker, section),
                           vs_factor = _checker_vs_factor(checker))
end

"""`nothing` when every concurrent shear row passes. Otherwise the failing row and `kind` (`:shear` or `:torsion`)."""
function _rectangular_shear_failure(checker::ACIBeamChecker, cache::ACIBeamCapacityCache,
                                   j::Int, section::RCBeamSection, demand::RCBeamDemand)
    b_in = ustrip(u"inch", section.b)
    d_in = ustrip(u"inch", section.d)
    fc_psi = cache.fc_ksi * 1000.0
    props = nothing
    for row in _demand_shear_rows(checker, demand)
        φVn = _section_φVn(checker, cache, j, section, row.Nu_kip)
        if φVn < row.Vu_kip
            return (; row, kind=:shear)
        end
        row.Tu_kipin > 0 || continue
        if props === nothing
            d_stir = ustrip(u"inch", rebar(section.stirrup_size).diameter)
            cov_in = ustrip(u"inch", section.cover)
            props = torsion_section_properties(section.b, section.h,
                                               (cov_in + d_stir / 2) * u"inch")
        end
        # ACI 318-11 §11.5.3.1
        Tth = threshold_torsion(props.Acp, props.pcp, fc_psi; λ=checker.λ)
        if row.Tu_kipin > Tth && !torsion_section_adequate(
                row.Vu_kip, row.Tu_kipin, b_in, d_in, props.Aoh, props.ph, fc_psi;
                λ=checker.λ)
            return (; row, kind=:torsion)
        end
    end
    return nothing
end

