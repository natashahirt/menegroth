# =============================================================================
# Equivalent Lateral Force Seismic Demand (ASCE 7-22 §12.8)
# =============================================================================
#
# Pure demand equations. Seismic weight W, period T, Sa, R, Cd, Ie, and ρ are
# caller inputs. Nothing here is applied to a building model.
#
# Units
#   Forces are in the caller's force unit. Lengths are in one consistent
#   length unit. Cs, Cvx, Ax, k, the live-load factor, and the stability
#   coefficient θ are dimensionless. θ = (Px / hsx) / (Vx / Δxe), so Px/hsx
#   and Vx/Δxe must share units of force per length.
#
# Not implemented, and not to be inferred here:
#   §12.7.2 seismic weight, §12.8.1.3 (the permission to use SDS = 1.0),
#   §12.8.2 approximate period, the redundancy factor ρ itself, Table 12.2-1
#   values of R or Cd, diaphragm classification, and wind.
# =============================================================================

"""
    seismic_response_coefficient(; method, SDS, S1, R, Ie, Sa, SD1, T, TL)

Seismic response coefficient `Cs` (dimensionless).

`method` is required and is either `:sa` (Eq. 12.8-2) or `:sds` (Eq. 12.8-3).
There is no default. `Sa` is required only for `:sa` and is the value the
caller has already chosen at period `T`. Where `T` is less than the period at
which `Sa` is maximum, ASCE 7-22 says the maximum `Sa` shall be used; that
selection is the caller's job. `SD1`, `T`, and `TL` are required only for
`:sds`, because Eqs. 12.8-4 and 12.8-5 cap only Eq. 12.8-3. Eqs. 12.8-6 and
12.8-7 are lower bounds for both methods, so `SDS` and `S1` are required
for both.

Spectral parameters `SDS`, `SD1`, `S1`, and `Sa` are dimensionless. `T` and
`TL` are in seconds. `R` and `Ie` are dimensionless.

# Citation
ASCE 7-22 §12.8.1.1, Eqs. 12.8-2 through 12.8-7 (corpus: asce-7-22, PDF page 185).
"""
function seismic_response_coefficient(;
    method=nothing,
    SDS=nothing,
    SD1=nothing,
    S1=nothing,
    T=nothing,
    TL=nothing,
    R=nothing,
    Ie=nothing,
    Sa=nothing,
)
    method = _seismic_method(method)
    # SDS and S1 feed the lower bounds, Eqs. 12.8-6 and 12.8-7, which apply
    # to both methods. SD1, T, and TL feed only the Eq. 12.8-3 caps.
    SDS = _required_finite("SDS", SDS)
    S1 = _required_finite("S1", S1)
    R = _required_finite("R", R)
    Ie = _required_finite("Ie", Ie)
    R > 0 || throw(ArgumentError("R must be > 0; got $R"))
    Ie > 0 || throw(ArgumentError("Ie must be > 0; got $Ie"))
    SDS >= 0 || throw(ArgumentError("SDS must be >= 0; got $SDS"))
    S1 >= 0 || throw(ArgumentError("S1 must be >= 0; got $S1"))

    # R/Ie is the common divisor in Eqs. 12.8-2, 12.8-3, 12.8-7, and, for
    # method :sds, Eqs. 12.8-4 and 12.8-5.
    R_over_Ie = R / Ie
    if method === :sa
        Sa = _required_finite("Sa", Sa)
        Sa >= 0 || throw(ArgumentError("Sa must be >= 0; got $Sa"))
        # ASCE 7-22 §12.8.1.1, Eq. 12.8-2 (corpus: asce-7-22, PDF page 185):
        # Cs = Sa / (R/Ie). Eqs. 12.8-4 and 12.8-5 cap the value computed
        # from Eq. 12.8-3 only. They do not cap Eq. 12.8-2.
        cs = Sa / R_over_Ie
    else
        # SD1, T, and TL are the inputs of Eqs. 12.8-4 and 12.8-5, which cap
        # Eq. 12.8-3 only (ASCE 7-22 §12.8.1.1, PDF page 185).
        SD1 = _required_finite("SD1", SD1)
        T = _required_finite("T", T)
        TL = _required_finite("TL", TL)
        T > 0 || throw(ArgumentError("T must be > 0; got $T"))
        TL > 0 || throw(ArgumentError("TL must be > 0; got $TL"))
        SD1 >= 0 || throw(ArgumentError("SD1 must be >= 0; got $SD1"))
        # ASCE 7-22 §12.8.1.1, Eq. 12.8-3 (corpus: asce-7-22, PDF page 185).
        basic = SDS / R_over_Ie
        # ASCE 7-22 §12.8.1.1 (corpus: asce-7-22, PDF page 185): the value of
        # Cs computed in accordance with Eq. 12.8-3 need not exceed Eq. 12.8-4
        # for T ≤ TL and Eq. 12.8-5 for T > TL. At T == TL, Eq. 12.8-4 is used.
        if T <= TL
            cap = SD1 / (T * R_over_Ie)
        else
            cap = SD1 * TL / (T^2 * R_over_Ie)
        end
        cs = min(basic, cap)
    end

    # ASCE 7-22 §12.8.1.1, Eq. 12.8-6 (corpus: asce-7-22, PDF page 185):
    # Cs shall not be less than 0.044*SDS*Ie, and that value shall not be
    # less than 0.01. Item 3 of §12.8.1.1 applies this lower bound to both
    # Method 1 and Method 2.
    cs = max(cs, max(0.044 * SDS * Ie, 0.01))

    # ASCE 7-22 §12.8.1.1, Eq. 12.8-7 (corpus: asce-7-22, PDF page 185),
    # only where S1 is equal to or greater than 0.6. The lower bound applies
    # to both methods.
    if S1 >= 0.6
        cs = max(cs, 0.5 * S1 / R_over_Ie)
    end
    return cs
end

"""
    seismic_base_shear(Cs, W) -> Float64

Seismic base shear `V = Cs * W`.

`Cs` is dimensionless. `W` and `V` share the caller's force unit. `W = 0` is
allowed. `W < 0` throws.

# Citation
ASCE 7-22 §12.8.1, Eq. 12.8-1 (corpus: asce-7-22, PDF page 185).
"""
function seismic_base_shear(Cs, W)
    Cs = _as_finite("Cs", Cs)
    W = _as_finite("W", W)
    W >= 0 || throw(ArgumentError("W must be >= 0; got $W"))
    # ASCE 7-22 §12.8.1, Eq. 12.8-1 (corpus: asce-7-22, PDF page 185).
    return Cs * W
end

"""
    vertical_distribution_exponent(T; between) -> Float64

Exponent `k` for the vertical distribution of seismic forces.

`k = 1` when `T <= 0.5` s and `k = 2` when `T >= 2.5` s. For `0.5 < T < 2.5`,
`between` is required and must be `:two` (`k = 2`) or `:interpolate`
(`k = 1 + (T - 0.5) / (2.5 - 0.5)`). There is no default. At `T == 0.5` and
`T == 2.5` the code is unambiguous and `between` is not required.

`T` is in seconds. `k` is dimensionless.

# Citation
ASCE 7-22 §12.8.3 (corpus: asce-7-22, PDF page 186).
"""
function vertical_distribution_exponent(T; between=nothing)
    T = _as_finite("T", T)
    T > 0 || throw(ArgumentError("T must be > 0; got $T"))
    # ASCE 7-22 §12.8.3 (corpus: asce-7-22, PDF page 186).
    if T <= 0.5
        return 1.0
    elseif T >= 2.5
        return 2.0
    end
    if between === :two
        return 2.0
    elseif between === :interpolate
        return 1.0 + (T - 0.5) / (2.5 - 0.5)
    end
    throw(ArgumentError(
        "between must be :two or :interpolate when 0.5 < T < 2.5; got $(repr(between))"))
end

"""
    vertical_distribution(weights, heights, V, k) -> NamedTuple

Story forces `Fx = Cvx * V` and distribution factors `Cvx`.

`Cvx = (wx * hx^k) / sum_i (wi * hi^k)`, with the sum over every level in the
order given. Heights are measured from the base, in one length unit. Weights
and `V` share the caller's force unit. `Cvx` is dimensionless. The returned
named tuple has fields `Fx` and `Cvx`.

# Citation
ASCE 7-22 §12.8.3, Eqs. 12.8-12 and 12.8-13 (corpus: asce-7-22, PDF page 186).
"""
function vertical_distribution(weights, heights, V, k)
    weights isa AbstractVector || throw(ArgumentError("weights must be a vector"))
    heights isa AbstractVector || throw(ArgumentError("heights must be a vector"))
    length(weights) == length(heights) || throw(ArgumentError(
        "weights and heights must have the same length; got $(length(weights)) and $(length(heights))"))
    n = length(weights)
    n > 0 || throw(ArgumentError("weights and heights must be non-empty"))
    V = _as_finite("V", V)
    k = _as_finite("k", k)

    whk = Vector{Float64}(undef, n)
    for i in 1:n
        wi = _as_finite("weights[$i]", weights[i])
        hi = _as_finite("heights[$i]", heights[i])
        wi >= 0 || throw(ArgumentError("story weight must be >= 0; weights[$i] = $wi"))
        hi > 0 || throw(ArgumentError(
            "height from the base must be > 0; heights[$i] = $hi"))
        whk[i] = wi * hi^k
    end

    # ENGINEERING JUDGMENT: ASCE 7-22 Eq. 12.8-13 (PDF page 186) prints i=1
    # above the summation sign and n below it. Figure C12.8-3 and ASCE 7-16
    # Eq. 12.8-12 (PDF page 157) print n above and i=1 below. Per user decision
    # 2026-10-23 the sum is over every level, i = 1 to n. A finite sum over the
    # same levels has the same value either way. Do not present the usual order
    # as what the 7-22 page prints.
    den = sum(whk)
    if !isfinite(den) || den == 0
        throw(ArgumentError(
            "vertical distribution denominator must be finite and nonzero; got $den"))
    end
    # ASCE 7-22 §12.8.3, Eqs. 12.8-13 and 12.8-12 (corpus: asce-7-22, PDF page 186).
    Cvx = whk ./ den
    Fx = Cvx .* V
    return (Fx=Fx, Cvx=Cvx)
end

"""
    accidental_eccentricity(plan_dimension) -> Float64

Accidental eccentricity, `0.05 * plan_dimension`.

The result is a length in the same unit as `plan_dimension`. It is the
magnitude of the 5% offset. The accidental torsion moment is the story force
times this eccentricity. The caller applies that moment each way.

Applicable where diaphragms are not flexible. Accidental torsion is included
in the analysis for Seismic Design Category B with Type 1 horizontal
structural irregularity and TIR > 1.4, and for Seismic Design Category C, D,
E, or F with Type 1 horizontal structural irregularity. This function does
not classify the diaphragm or the Seismic Design Category.

# Citation
ASCE 7-22 §12.8.4.2.1 and §12.8.4.2.2 (corpus: asce-7-22, PDF page 187).
"""
function accidental_eccentricity(plan_dimension)
    plan_dimension = _as_finite("plan_dimension", plan_dimension)
    plan_dimension >= 0 || throw(ArgumentError(
        "plan_dimension must be >= 0; got $plan_dimension"))
    # ASCE 7-22 §12.8.4.2.2: 5% of the dimension perpendicular to the applied
    # forces (corpus: asce-7-22, PDF page 187).
    return 0.05 * plan_dimension
end

"""
    torsional_amplification(δmax, δavg) -> Float64

Torsional amplification factor `Ax = (δmax / (1.2 * δavg))^2`, clamped to
`[1, 3]`.

`δmax` and `δavg` share one length unit. `Ax` is dimensionless. `Ax` shall
not be less than 1 and is not required to exceed 3.0; this function applies
both limits.

Applies to Seismic Design Category C, D, E, or F with Type 1 horizontal
structural irregularity. `δmax` and `δavg` may be computed with `Ax = 1`.
This function does not check the Seismic Design Category.

# Citation
ASCE 7-22 §12.8.4.3, Eq. 12.8-15 (corpus: asce-7-22, PDF page 187).
"""
function torsional_amplification(δmax, δavg)
    δmax = _as_finite("δmax", δmax)
    δavg = _as_finite("δavg", δavg)
    δavg > 0 || throw(ArgumentError("δavg must be > 0; got $δavg"))
    δmax >= 0 || throw(ArgumentError("δmax must be >= 0; got $δmax"))
    # ASCE 7-22 §12.8.4.3, Eq. 12.8-15 (corpus: asce-7-22, PDF page 187).
    Ax = (δmax / (1.2 * δavg))^2
    return clamp(Ax, 1.0, 3.0)
end

"""
    design_earthquake_displacement(Cd, δe, Ie, δdi) -> Float64

Design Earthquake Displacement `δDE = Cd * δe / Ie + δdi`.

`Cd` and `Ie` are dimensionless. `δe`, `δdi`, and `δDE` share one length unit.

# Citation
ASCE 7-22 §12.8.6.3, Eq. 12.8-16 (corpus: asce-7-22, PDF page 187).
"""
function design_earthquake_displacement(Cd, δe, Ie, δdi)
    Cd = _as_finite("Cd", Cd)
    δe = _as_finite("δe", δe)
    Ie = _as_finite("Ie", Ie)
    δdi = _as_finite("δdi", δdi)
    Ie > 0 || throw(ArgumentError("Ie must be > 0; got $Ie"))
    # ASCE 7-22 §12.8.6.3, Eq. 12.8-16 (corpus: asce-7-22, PDF page 187).
    return Cd * δe / Ie + δdi
end

"""
    maximum_considered_displacement(R, δe, Ie, δdi) -> Float64

Maximum Considered Earthquake Displacement `δMCE = 1.5 * R * δe / Ie + δdi`.

`R` and `Ie` are dimensionless. `δe`, `δdi`, and `δMCE` share one length unit.

# Citation
ASCE 7-22 §12.8.6.4, Eq. 12.8-17 (corpus: asce-7-22, PDF page 188).
"""
function maximum_considered_displacement(R, δe, Ie, δdi)
    R = _as_finite("R", R)
    δe = _as_finite("δe", δe)
    Ie = _as_finite("Ie", Ie)
    δdi = _as_finite("δdi", δdi)
    Ie > 0 || throw(ArgumentError("Ie must be > 0; got $Ie"))
    # ASCE 7-22 §12.8.6.4, Eq. 12.8-17 (corpus: asce-7-22, PDF page 188).
    # The leading 1.5 is the factor printed in Eq. 12.8-17.
    return 1.5 * R * δe / Ie + δdi
end

"""
    design_story_drift(δ_top, δ_bottom) -> Float64

Design story drift `Δ = δ_top - δ_bottom`.

This is the difference of Design Earthquake Displacements at the centers of
mass of the story. Diaphragm deformation may be neglected. Both displacements
and `Δ` share one length unit.

For Seismic Design Category C, D, E, or F with Type 1 horizontal structural
irregularity, `Δ` is instead the largest difference of vertically aligned
displacements along any edge. That value is `edge_design_story_drift`. This
function does not check the Seismic Design Category.

# Citation
ASCE 7-22 §12.8.6.5 (corpus: asce-7-22, PDF page 188).
"""
function design_story_drift(δ_top, δ_bottom)
    δ_top = _as_finite("δ_top", δ_top)
    δ_bottom = _as_finite("δ_bottom", δ_bottom)
    # ASCE 7-22 §12.8.6.5 (corpus: asce-7-22, PDF page 188).
    return δ_top - δ_bottom
end

"""
    edge_design_story_drift(δ_top, δ_bottom) -> Float64

Largest design story drift along an edge, `maximum(δ_top .- δ_bottom)`.

For Seismic Design Category C, D, E, or F with Type 1 horizontal structural
irregularity, `Δ` is the largest difference of the Design Earthquake
Displacements of vertically aligned points at the top and bottom of the story
along any edge of the structure. The two vectors are those aligned pairs, in
the same order. This function does not check the Seismic Design Category and
does not search several edges; the caller passes one edge's pairs.

Displacements share one length unit.

# Citation
ASCE 7-22 §12.8.6.5 (corpus: asce-7-22, PDF page 188).
"""
function edge_design_story_drift(δ_top, δ_bottom)
    δ_top isa AbstractVector || throw(ArgumentError("δ_top must be a vector"))
    δ_bottom isa AbstractVector || throw(ArgumentError("δ_bottom must be a vector"))
    length(δ_top) == length(δ_bottom) || throw(ArgumentError(
        "edge displacement vectors must have the same length; got $(length(δ_top)) and $(length(δ_bottom))"))
    n = length(δ_top)
    n > 0 || throw(ArgumentError("edge displacement vectors must be non-empty"))
    # ASCE 7-22 §12.8.6.5 (corpus: asce-7-22, PDF page 188): the largest
    # difference of vertically aligned displacements along the edge.
    Δ = -Inf
    for i in 1:n
        top = _as_finite("δ_top[$i]", δ_top[i])
        bot = _as_finite("δ_bottom[$i]", δ_bottom[i])
        Δ = max(Δ, top - bot)
    end
    return Δ
end

"""
    allowable_story_drift(hsx, risk_category, system; rho=nothing) -> Float64

Allowable story drift `Δa` from Table 12.12-1, in the same length unit as `hsx`.

`risk_category` is `:I`, `:II`, `:III`, or `:IV`. There is no default.

`system` is one of:
- `:lowrise_interior_walls`: four stories or less, not masonry shear walls,
  with interior walls, partitions, and ceilings designed to accommodate the
  Design Earthquake Displacements. `Δa/hsx` is 0.025, 0.020, 0.015 for risk
  category I or II, III, IV.
- `:masonry_cantilever`: `Δa = 0.010 * hsx` for every risk category.
- `:masonry_other`: `Δa = 0.007 * hsx` for every risk category.
- `:other`: `Δa/hsx` is 0.020, 0.015, 0.010 for risk category I or II, III, IV.

For a seismic force-resisting system consisting solely of moment frames in
Seismic Design Category D, E, or F, `Δ` shall not exceed `Δa/ρ`
(§12.12.1.1). Pass `rho` to return `Δa/rho`. When `rho` is omitted, the
result is `Δa`. `rho` is not inferred, and this function does not check the
seismic force-resisting system or the Seismic Design Category.

# Citation
ASCE 7-22 §12.12.1, Table 12.12-1 (corpus: asce-7-22, PDF page 195);
§12.12.1.1 (corpus: asce-7-22, PDF page 194).
"""
function allowable_story_drift(hsx, risk_category, system; rho=nothing)
    hsx = _as_finite("hsx", hsx)
    hsx > 0 || throw(ArgumentError("hsx must be > 0; got $hsx"))
    _require_risk_category(risk_category)
    ratio = _allowable_drift_ratio(risk_category, system)
    # ASCE 7-22 Table 12.12-1 (corpus: asce-7-22, PDF page 195): Δa = ratio * hsx.
    Δa = ratio * hsx
    rho === nothing && return Δa
    ρ = _as_finite("rho", rho)
    ρ > 0 || throw(ArgumentError("rho must be > 0; got $ρ"))
    # ASCE 7-22 §12.12.1.1 (corpus: asce-7-22, PDF page 194): Δ shall not
    # exceed Δa/ρ. Applied only when the caller passes rho.
    return Δa / ρ
end

"""
    drift_live_load_factor(unreduced_live_load_psf) -> Float64

Factor on the unreduced design live load `L0` used with drift displacements.

Returns `0.8` where the unreduced design live load exceeds 100 lb/ft², and
`0.4` otherwise. Exactly 100 lb/ft² returns `0.4`. The argument is `L0` in
lb/ft². The factor is dimensionless; the caller multiplies it by `L0`.

# Citation
ASCE 7-22 §12.8.6.1 (corpus: asce-7-22, PDF page 187).
"""
function drift_live_load_factor(unreduced_live_load_psf)
    L0 = _as_finite("unreduced_live_load_psf", unreduced_live_load_psf)
    L0 >= 0 || throw(ArgumentError(
        "unreduced_live_load_psf must be >= 0; got $L0"))
    # ASCE 7-22 §12.8.6.1 (corpus: asce-7-22, PDF page 187): 0.8*L0 where the
    # unreduced design live load exceeds 100 lb/ft², and 0.4*L0 otherwise.
    return L0 > 100.0 ? 0.8 : 0.4
end

"""
    stability_coefficient(Px, hsx, Vx, Δxe) -> Float64

Stability coefficient `θ = (Px / hsx) / (Vx / Δxe)`.

`θ` is dimensionless, so `Px/hsx` and `Vx/Δxe` must share units of force per
length. `Δxe == 0` returns `θ = 0`.

# Citation
ASCE 7-22 §12.8.7, Eq. 12.8-18 (corpus: asce-7-22, PDF page 188).
"""
function stability_coefficient(Px, hsx, Vx, Δxe)
    Px = _as_finite("Px", Px)
    hsx = _as_finite("hsx", hsx)
    Vx = _as_finite("Vx", Vx)
    Δxe = _as_finite("Δxe", Δxe)
    hsx > 0 || throw(ArgumentError("hsx must be > 0; got $hsx"))
    Vx > 0 || throw(ArgumentError("Vx must be > 0; got $Vx"))
    Δxe >= 0 || throw(ArgumentError("Δxe must be >= 0; got $Δxe"))
    # A zero elastic story drift is infinite story stiffness, so θ = 0.
    Δxe == 0 && return 0.0
    # ASCE 7-22 §12.8.7, Eq. 12.8-18 (corpus: asce-7-22, PDF page 188).
    return (Px / hsx) / (Vx / Δxe)
end

"""
    stability_coefficient_limit(β, Cd; Ω0=nothing) -> Float64

Maximum stability coefficient `θmax = min(0.5 / (β * Cd), 0.25)`.

`β`, `Cd`, and `θmax` are dimensionless. `β` is required. It may be taken as
1.0 and shall not be taken less than `1.25/Ω0`. This function does not
default `β` to 1.0. When `Ω0` is passed, `β < 1.25/Ω0` throws.

The code says `θmax` need not be taken less than 0.1. That is a permission,
not a requirement. A result smaller than 0.1 is returned as computed.

# Citation
ASCE 7-22 §12.8.7, Eq. 12.8-19 (corpus: asce-7-22, PDF page 188).
"""
function stability_coefficient_limit(β, Cd; Ω0=nothing)
    β = _as_finite("β", β)
    Cd = _as_finite("Cd", Cd)
    β > 0 || throw(ArgumentError("β must be > 0; got $β"))
    Cd > 0 || throw(ArgumentError("Cd must be > 0; got $Cd"))
    if Ω0 !== nothing
        Ω0 = _as_finite("Ω0", Ω0)
        Ω0 > 0 || throw(ArgumentError("Ω0 must be > 0; got $Ω0"))
        # ASCE 7-22 §12.8.7 (corpus: asce-7-22, PDF page 188): β shall not
        # be taken less than 1.25/Ω0. Equal to that limit is permitted.
        β < 1.25 / Ω0 && throw(ArgumentError(
            "β = $β is less than 1.25/Ω0 = $(1.25 / Ω0); β shall not be taken less than 1.25/Ω0"))
    end
    # ASCE 7-22 §12.8.7, Eq. 12.8-19 (corpus: asce-7-22, PDF page 188):
    # θmax = 0.5/(β*Cd) and shall not exceed 0.25.
    # The code says θmax need not be taken less than 0.1. That is a
    # permission, not a requirement. Do not raise a smaller result to 0.1.
    return min(0.5 / (β * Cd), 0.25)
end

"""
    pdelta_displacement_multiplier(θ, θmax) -> Float64

Multiplier on displacements and member forces for P-delta.

P-delta is not required where `θ <= 0.10`; the multiplier is `1.0`. Where
`0.10 < θ <= θmax`, the multiplier is `1 / (1 - θ)`. Where `θ > θmax`, the
structure shall be redesigned and this function throws. That redesign limit
is applied even when `θ <= 0.10`. `θ >= 1` throws because `1 / (1 - θ)` is
undefined. `θ` and `θmax` are dimensionless.

# Citation
ASCE 7-22 §12.8.7 (corpus: asce-7-22, PDF page 188).
"""
function pdelta_displacement_multiplier(θ, θmax)
    θ = _as_finite("θ", θ)
    θmax = _as_finite("θmax", θmax)
    # ASCE 7-22 §12.8.7 (corpus: asce-7-22, PDF page 188): θ shall not exceed θmax.
    if θ > θmax
        throw(ArgumentError(
            "stability coefficient θ = $θ exceeds θmax = $θmax; the structure shall be redesigned"))
    end
    if θ >= 1
        throw(ArgumentError(
            "stability coefficient θ = $θ must be < 1; the P-delta multiplier 1/(1-θ) is undefined"))
    end
    # ASCE 7-22 §12.8.7 (corpus: asce-7-22, PDF page 188): P-delta is not
    # required where θ <= 0.10. Where 0.10 < θ <= θmax, displacements and
    # member forces may be multiplied by 1/(1-θ).
    θ <= 0.10 && return 1.0
    return 1.0 / (1.0 - θ)
end

# -----------------------------------------------------------------------------
# Input checks. Not code factors.
# -----------------------------------------------------------------------------

function _as_finite(name::AbstractString, x)::Float64
    if !(x isa Real) || x isa Bool || !isfinite(x)
        throw(ArgumentError("$name must be a finite number; got $(repr(x))"))
    end
    return Float64(x)
end

function _required_finite(name::AbstractString, x)::Float64
    x === nothing && throw(ArgumentError("$name is required"))
    return _as_finite(name, x)
end

function _seismic_method(method)
    method === nothing && throw(ArgumentError("method is required and must be :sa or :sds"))
    method === :sa || method === :sds || throw(ArgumentError(
        "method must be :sa or :sds; got $(repr(method))"))
    return method
end

function _require_risk_category(risk_category)
    risk_category === :I || risk_category === :II ||
        risk_category === :III || risk_category === :IV ||
        throw(ArgumentError(
            "risk_category must be :I, :II, :III, or :IV; got $(repr(risk_category))"))
    return risk_category
end

"""Table 12.12-1 ratio Δa/hsx. Risk category has already been checked."""
function _allowable_drift_ratio(risk_category, system)::Float64
    if system === :masonry_cantilever
        # ASCE 7-22 Table 12.12-1, masonry cantilever shear wall structures
        # (corpus: asce-7-22, PDF page 195): 0.010 hsx for every risk category.
        return 0.010
    elseif system === :masonry_other
        # ASCE 7-22 Table 12.12-1, other masonry shear wall structures
        # (corpus: asce-7-22, PDF page 195): 0.007 hsx for every risk category.
        return 0.007
    elseif system === :lowrise_interior_walls
        # ASCE 7-22 Table 12.12-1 (corpus: asce-7-22, PDF page 195): structures
        # other than masonry shear wall structures, four stories or less, with
        # interior walls, partitions, and ceilings designed to accommodate the
        # Design Earthquake Displacements.
        if risk_category === :I || risk_category === :II
            return 0.025
        elseif risk_category === :III
            return 0.020
        elseif risk_category === :IV
            return 0.015
        end
    elseif system === :other
        # ASCE 7-22 Table 12.12-1, all other structures
        # (corpus: asce-7-22, PDF page 195).
        if risk_category === :I || risk_category === :II
            return 0.020
        elseif risk_category === :III
            return 0.015
        elseif risk_category === :IV
            return 0.010
        end
    end
    throw(ArgumentError(
        "system must be :lowrise_interior_walls, :masonry_cantilever, :masonry_other, or :other; got $(repr(system))"))
end
