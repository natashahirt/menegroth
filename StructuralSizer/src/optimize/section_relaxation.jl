# ==============================================================================
# Continuous-section relaxation: scaling laws + catalog projection (Workstream R.1)
# ==============================================================================
#
# The relaxation-guided sizing pipeline (docs/sizing-map/optimization-architecture.md,
# Pillar A) solves a cheap *continuous* section relaxation first, then projects the
# continuous optimum onto the discrete catalog and warm-starts the discrete owner
# inside a small candidate band. This file provides the continuous abstraction:
#
#   1. A per-family *scaling law* — a smooth monotone price for stiffness. Real
#      section families (steel W/HSS/Pipe, RC rect/T) follow near-power-law
#      relations between their strong-axis second moment of area `I` and their
#      area `A` and plastic modulus `Z`, so a log–log least-squares fit gives a
#      differentiable `A(I)` with which to price a continuous stiffness target and
#      to supply the marginal weight-per-stiffness `w_e = dA/dI` that the drift
#      optimality-criteria resizer ([`drift_optimality_resize`](@ref)) consumes.
#
#   2. A *projection* of a continuous stiffness target onto the catalog (the
#      lightest discrete section that meets it) and a bounded *candidate band*
#      around that projection with which to warm-start the discrete MIP.
#
# These relations are EMPIRICAL CURVE FITS to catalog geometry, not code-derived
# provisions — no safety factor, capacity equation, or code clause lives here. The
# strength/stability checks that certify a projected section remain the discrete
# owners' responsibility; this file only narrows *which* catalog entries they try.
#
# Like `drift_optimality.jl`, this routine is PURE: plain `Float64` vectors in
# consistent SI units (`I` in m⁴, `A` in m², `Z` in m³) in, results out. Unit
# stripping from `AbstractSection`s happens in the caller, where the section
# definitions are in scope (this file loads before `members/sections/`).

"""
    SectionScalingLaw

A fitted continuous model of one discrete section family, used to price a
stiffness target and to project it onto the catalog.

The catalog property table is stored ascending in strong-axis second moment of
area `I` (SI, m⁴), with the aligned area `A` (m²) and plastic section modulus
`Z` (m³, or an empty vector when not supplied). Power-law fits

    A ≈ exp(a_A) · I^b_A        Z ≈ exp(a_Z) · I^b_Z

are stored as `(intercept, slope)` pairs in natural-log space (`logA_fit`,
`logZ_fit`), giving a smooth, strictly monotone (for `b > 0`) continuous price
for any `I` between — or modestly beyond — the catalog endpoints.

Fields:
- `I`, `A`, `Z` — the sorted catalog table (`Z` empty when unavailable).
- `logA_fit`, `logZ_fit` — `(intercept, slope)` of the log–log fits (`logZ_fit`
  is `(NaN, NaN)` when `Z` was not supplied).
"""
struct SectionScalingLaw
    I::Vector{Float64}
    A::Vector{Float64}
    Z::Vector{Float64}
    logA_fit::NTuple{2,Float64}
    logZ_fit::NTuple{2,Float64}
end

"""
    _loglog_fit(x, y) -> (intercept, slope)

Ordinary least-squares fit of `ln(y) = intercept + slope · ln(x)` over strictly
positive `x`, `y`. Returns `(NaN, NaN)` when fewer than two distinct `x` values
are present (a single point cannot define a slope).
"""
function _loglog_fit(x::AbstractVector{<:Real}, y::AbstractVector{<:Real})
    lx = log.(float.(x))
    ly = log.(float.(y))
    n = length(lx)
    x̄ = sum(lx) / n
    ȳ = sum(ly) / n
    Sxx = 0.0
    Sxy = 0.0
    @inbounds for i in 1:n
        dx = lx[i] - x̄
        Sxx += dx * dx
        Sxy += dx * (ly[i] - ȳ)
    end
    Sxx ≤ 0 && return (NaN, NaN)          # all x equal: slope undefined
    slope = Sxy / Sxx
    intercept = ȳ - slope * x̄
    return (intercept, slope)
end

"""
    fit_section_scaling_law(I, A; Z=nothing) -> SectionScalingLaw

Fit a [`SectionScalingLaw`](@ref) to a catalog's strong-axis second moment of
area `I` (m⁴) and area `A` (m²), optionally with the plastic modulus `Z` (m³).
All inputs must be strictly positive and equal length; the table is returned
sorted ascending in `I`. At least two entries with distinct `I` are required.
"""
function fit_section_scaling_law(I::AbstractVector{<:Real}, A::AbstractVector{<:Real};
                                 Z::Union{Nothing,AbstractVector{<:Real}} = nothing)
    n = length(I)
    length(A) == n || throw(ArgumentError(
        "fit_section_scaling_law: I and A must have equal length; got $n and $(length(A))."))
    n ≥ 2 || throw(ArgumentError("fit_section_scaling_law: need ≥ 2 catalog entries; got $n."))
    all(>(0), I) || throw(ArgumentError("fit_section_scaling_law: all I must be > 0."))
    all(>(0), A) || throw(ArgumentError("fit_section_scaling_law: all A must be > 0."))
    have_Z = Z !== nothing
    if have_Z
        length(Z) == n || throw(ArgumentError(
            "fit_section_scaling_law: Z must match length(I) = $n; got $(length(Z))."))
        all(>(0), Z) || throw(ArgumentError("fit_section_scaling_law: all Z must be > 0."))
    end

    perm = sortperm(float.(I))
    Is = Float64.(collect(I))[perm]
    As = Float64.(collect(A))[perm]
    Zs = have_Z ? Float64.(collect(Z))[perm] : Float64[]

    logA_fit = _loglog_fit(Is, As)
    any(isnan, logA_fit) && throw(ArgumentError(
        "fit_section_scaling_law: I values are not distinct enough to fit a slope."))
    logZ_fit = have_Z ? _loglog_fit(Is, Zs) : (NaN, NaN)
    return SectionScalingLaw(Is, As, Zs, logA_fit, logZ_fit)
end

"""
    continuous_area(law, I_target) -> Float64

Continuous (relaxed) area in m² for a strong-axis stiffness target `I_target`
(m⁴), from the power-law fit `A ≈ exp(a_A)·I^b_A`. This is the price the
continuous relaxation pays for stiffness; it lower-bounds the discrete catalog
area whenever the family's `A(I)` is convex in log space (the usual case).
"""
function continuous_area(law::SectionScalingLaw, I_target::Real)
    I_target > 0 || throw(ArgumentError("continuous_area: I_target must be > 0; got $I_target."))
    a, b = law.logA_fit
    return exp(a + b * log(float(I_target)))
end

"""
    marginal_area(law, I_target) -> Float64

Marginal area per unit strong-axis stiffness, `dA/dI` (m²/m⁴ = m⁻²), at
`I_target`. For the power law `A = exp(a)·I^b`, `dA/dI = b·A/I`. This is the
weight-per-stiffness coefficient `w_e` consumed by
[`drift_optimality_resize`](@ref): allocating stiffness where `γ_e/w_e` is
largest is the near-minimum-weight distribution for a drift constraint.
"""
function marginal_area(law::SectionScalingLaw, I_target::Real)
    I_target > 0 || throw(ArgumentError("marginal_area: I_target must be > 0; got $I_target."))
    _, b = law.logA_fit
    return b * continuous_area(law, I_target) / float(I_target)
end

"""
    continuous_modulus(law, I_target) -> Float64

Continuous plastic section modulus `Z` (m³) for a stiffness target `I_target`
(m⁴), from the fit `Z ≈ exp(a_Z)·I^b_Z`. Throws if the law was fit without `Z`.
"""
function continuous_modulus(law::SectionScalingLaw, I_target::Real)
    any(isnan, law.logZ_fit) && throw(ArgumentError(
        "continuous_modulus: this scaling law was fit without Z data."))
    I_target > 0 || throw(ArgumentError("continuous_modulus: I_target must be > 0; got $I_target."))
    a, b = law.logZ_fit
    return exp(a + b * log(float(I_target)))
end

"""
    project_to_catalog(law, I_target) -> Union{Int, Nothing}

Index into `law.I`/`law.A` of the lightest catalog section whose strong-axis
stiffness meets the target: `argmin A` over all entries with `I ≥ I_target`.
Returns `nothing` when no catalog entry reaches `I_target` (the catalog must be
grown). Selecting on minimum area — rather than simply the first entry with
`I ≥ I_target` — is robust to the rare non-monotonicity of `A` in `I` across a
mixed-shape catalog.
"""
function project_to_catalog(law::SectionScalingLaw, I_target::Real)
    best = nothing
    best_A = Inf
    @inbounds for i in eachindex(law.I)
        if law.I[i] ≥ I_target && law.A[i] < best_A
            best = i
            best_A = law.A[i]
        end
    end
    return best
end

"""
    candidate_band(law, idx, k) -> UnitRange{Int}

The `±k`-step window of catalog indices around `idx`, clamped to the catalog
bounds `1:length(law.I)`. This is the bounded set of discrete candidates the
warm-started MIP evaluates around the continuous projection, in place of the
full catalog.
"""
function candidate_band(law::SectionScalingLaw, idx::Integer, k::Integer)
    k ≥ 0 || throw(ArgumentError("candidate_band: band half-width k must be ≥ 0; got $k."))
    n = length(law.I)
    (1 ≤ idx ≤ n) || throw(ArgumentError("candidate_band: idx=$idx out of range 1:$n."))
    return max(1, idx - k):min(n, idx + k)
end

"""
    projection_gap(law, I_target, idx) -> Float64

Relative area gap between the discrete pick `law.A[idx]` and the continuous
price `continuous_area(law, I_target)`:

    (A_catalog − A_continuous) / A_continuous ≥ 0 (typically).

A small gap certifies the projection landed close to the continuous optimum; it
is the per-member optimality-gap contribution that bounds the discrete design.
"""
function projection_gap(law::SectionScalingLaw, I_target::Real, idx::Integer)
    (1 ≤ idx ≤ length(law.A)) || throw(ArgumentError(
        "projection_gap: idx=$idx out of range 1:$(length(law.A))."))
    Ac = continuous_area(law, I_target)
    return (law.A[idx] - Ac) / Ac
end

# ==============================================================================
# Discrete warm start: continuous targets → catalog-order MIP seeds + bands
# ==============================================================================
#
# `optimize_discrete` already exposes the two hooks a relaxation-guided warm start
# needs, both byte-identical when left at `nothing`:
#   • `mip_start` — a per-group prior catalog index, seeded onto the branch-and-
#     bound incumbent. A pure HINT: it cannot change the feasible region or the
#     optimum, only shorten the solve.
#   • `feasible`  — a per-group vector of ALLOWED catalog indices, INTERSECTED with
#     the internal capacity screening (never a substitute for it). It can only
#     REMOVE candidates, so capacity is always still certified by the checker; it
#     narrows the search to the band around the continuous projection.
#
# This routine turns R.1's continuous projection into those two parameters. It is
# pure index arithmetic over number tables (catalog-order `I`/`A`), so it stays in
# this pre-`sections` layer. The crucial bookkeeping: [`project_to_catalog`] and
# [`candidate_band`] index the law's *I-sorted* table, while the MIP expects
# *catalog-order* indices — the sort permutation maps between them here.

"""
    RelaxationWarmStart

Per-group discrete warm start produced by [`relaxation_warm_start`](@ref), with
all indices in the caller's **catalog order** (directly usable as
`optimize_discrete`'s `mip_start` and `feasible` arguments):

- `mip_start` — projected lightest-feasible catalog index per group (a MIP hint).
- `band`      — sorted `±k` candidate catalog indices per group (a hard, capacity-
                intersected restriction; the search space for the warm solve).
- `gap`       — per-group projection area gap (`projection_gap`); a certificate of
                how close the discrete pick sits to the continuous price.
- `grown`     — `true` where the continuous target exceeded the catalog's stiffest
                section, so the projection was clamped to the top (the catalog
                should be grown for that group).
"""
struct RelaxationWarmStart
    mip_start::Vector{Int}
    band::Vector{Vector{Int}}
    gap::Vector{Float64}
    grown::Vector{Bool}
end

"""
    relaxation_warm_start(I_catalog, A_catalog, I_targets; Z_catalog=nothing, k=1)
        -> RelaxationWarmStart

Map per-group continuous strong-axis stiffness targets `I_targets` (m⁴) onto a
discrete warm start over a catalog given in catalog order by its second moment of
area `I_catalog` (m⁴) and area `A_catalog` (m²). A [`SectionScalingLaw`](@ref) is
fit on the (internally sorted) catalog; each target is projected to the lightest
catalog section meeting it, with a clamped `±k` candidate band around it. All
returned indices are in the original catalog order.

A target above the catalog maximum is clamped to the stiffest section and flagged
in `grown`. `k` is the band half-width (`k=0` ⇒ the single projected section).
"""
function relaxation_warm_start(I_catalog::AbstractVector{<:Real}, A_catalog::AbstractVector{<:Real},
                               I_targets::AbstractVector{<:Real};
                               Z_catalog::Union{Nothing,AbstractVector{<:Real}} = nothing,
                               k::Integer = 1)
    n = length(I_catalog)
    length(A_catalog) == n || throw(ArgumentError(
        "relaxation_warm_start: I_catalog and A_catalog must have equal length; got $n and $(length(A_catalog))."))
    k ≥ 0 || throw(ArgumentError("relaxation_warm_start: band half-width k must be ≥ 0; got $k."))
    all(>(0), I_targets) || throw(ArgumentError("relaxation_warm_start: all I_targets must be > 0."))

    # Sort the catalog by I; `perm[li]` is the catalog-order index of sorted row `li`.
    perm = sortperm(float.(collect(I_catalog)))
    Is = Float64.(collect(I_catalog))[perm]
    As = Float64.(collect(A_catalog))[perm]
    Zs = Z_catalog === nothing ? nothing : Float64.(collect(Z_catalog))[perm]
    law = fit_section_scaling_law(Is, As; Z = Zs)

    m = length(I_targets)
    mip_start = Vector{Int}(undef, m)
    band = Vector{Vector{Int}}(undef, m)
    gap = Vector{Float64}(undef, m)
    grown = falses(m)
    for g in 1:m
        t = float(I_targets[g])
        li = project_to_catalog(law, t)
        if li === nothing            # target beyond the catalog: clamp to the stiffest
            li = length(law.I)
            grown[g] = true
        end
        mip_start[g] = perm[li]
        band[g] = sort(perm[collect(candidate_band(law, li, k))])
        gap[g] = projection_gap(law, t, li)
    end
    return RelaxationWarmStart(mip_start, band, gap, grown)
end
