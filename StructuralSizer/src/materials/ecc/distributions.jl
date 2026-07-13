# =============================================================================
# Empirical ECC Distributions (NRMCA / RMC ready-mix EPDs, 2021–2025)
# =============================================================================
#
# Loads `data/rmc_epd_2021_2025.csv` (1078 rows of individual plant-mix EPDs)
# and exposes the empirical A1–A3 GWP distribution per (strength,
# density-class) bucket via two complementary surfaces:
#
#   1. `ecc_distribution(strength_psi; density_class)` — percentile / mean
#      summary, used for quick characterization.
#   2. `ecc_samples(strength_psi; density_class)` and
#      `sample_ecc_per_kg(strength_psi, ρ; density_class, n, rng)` — raw
#      values and a Monte Carlo sampler for the procurement-uncertainty
#      sweep in `flat_plate_methods` Section 2.
#
# This file deliberately avoids `DataFrames` and `Statistics` to keep
# StructuralSizer's dependency surface flat — `CSV.File` is already used
# by the AISC section catalogs (see `members/sections/steel/catalogs/`).
#
# =============================================================================

using Random: AbstractRNG, default_rng

const _ECC_CSV_PATH = joinpath(@__DIR__, "data", "rmc_epd_2021_2025.csv")

"""
    ECC_PROVENANCE_NOTE :: String

Canonical one-paragraph provenance string for the concrete ECC values shipped
with StructuralSizer. Every site that quotes or summarizes the dataset (the
`Concrete` preset module header, the `ECCDistribution` docstring, the
embodied-carbon docs page, etc.) should reference this constant so that the
text stays in sync when the dataset is refreshed.

Detailed inclusion criteria, per-bucket counts, and composition tagging live
in `StructuralSizer/src/materials/ecc/data/README.md`.
"""
const ECC_PROVENANCE_NOTE = """
NRMCA / RMC ready-mix EPD dataset (n = 1078 individual plant-mix EPDs,
2021–2025, A1–A3 cradle-to-gate, US plants only). Boundary system is
A1–A3 only: A4 transport, A5 install, B-stage use, and C-stage end-of-life
are out of scope, and all distributional results must be quoted with this
caveat. Regenerate the parsed CSV with
`python3 scripts/runners/ingest_rmc_ecc.py --apply`.
"""

"""
    ECCDistribution{Q<:Unitful.Quantity}

Percentile summary of a (strength, density-class, composition) bucket of
EPD records. Parameterized on the GWP unit `Q` so both surfaces — per
unit volume of concrete (`ECCDistribution{CarbonPerVolQuantity}`,
returned by [`ecc_distribution`](@ref)) and per unit mass of concrete
(`ECCDistribution{CarbonPerMassQuantity}`, returned by
[`ecc_distribution_per_kg`](@ref)) — share one type.

All distributional fields (`mean`, `std`, `p10`, `p25`, `p50`, `p75`,
`p90`) carry the same `Q` units so callers can multiply/divide by
density without ad-hoc bookkeeping. `ustrip` only at the API boundary.

Boundary system is A1–A3 cradle-to-gate per the EPD dataset.

# Provenance
$(ECC_PROVENANCE_NOTE)
"""
struct ECCDistribution{Q<:Unitful.Quantity}
    n   ::Int
    mean::Q
    std ::Q
    p10 ::Q
    p25 ::Q
    p50 ::Q
    p75 ::Q
    p90 ::Q
end

"""Bucket key: `(strength_psi, density_class, composition)`. The
composition `:all` marks the pooled-across-compositions distribution."""
const _BucketKey = Tuple{Int, Symbol, Symbol}

"""Raw-bucket key: `(strength_psi, density_class)`. Used by the Monte
Carlo sampler, which always pools across compositions."""
const _RawKey = Tuple{Int, Symbol}

# Lazily populated on first access — see `_load_distributions!`.
# Per-vol typed throughout; callers convert to per-mass via
# `ecc_distribution_per_kg` (scalar division by density) so the cache
# stays single-unit and bootstrap sampling avoids per-call reallocation.
const _ECC_DISTRIBUTIONS = Dict{_BucketKey, ECCDistribution{CarbonPerVolQuantity}}()
const _ECC_RAW_VALUES    = Dict{_RawKey, Vector{CarbonPerVolQuantity}}()
const _ECC_LOADED        = Ref(false)

# -----------------------------------------------------------------------------
# Internal helpers
# -----------------------------------------------------------------------------

"""Return the empirical p-percentile of a sorted vector using the same
nearest-rank rule the Python ingest script applies (`vals[floor(p·n)]`),
so that Julia and Python summaries match exactly. Operates on either
`Vector{Float64}` or `Vector{<:Unitful.Quantity}` — the rank logic is
unit-agnostic."""
function _percentile_sorted(vals::AbstractVector{T}, p::Float64) where {T}
    n = length(vals)
    n == 0 && return T <: Unitful.Quantity ? T(NaN) : NaN
    n == 1 && return vals[1]
    idx = clamp(floor(Int, p * n), 0, n - 1) + 1
    return vals[idx]
end

"""Median (50th percentile) with linear interpolation on even-length
vectors. Used in preference to `_percentile_sorted(_, 0.5)` for the
canonical median field. Unit-preserving."""
function _median_sorted(vals::AbstractVector{T}) where {T}
    n = length(vals)
    n == 0 && return T <: Unitful.Quantity ? T(NaN) : NaN
    n == 1 && return vals[1]
    mid = n ÷ 2
    return iseven(n) ? 0.5 * (vals[mid] + vals[mid + 1]) : vals[mid + 1]
end

"""Build a percentile summary from a vector of typed per-volume GWP
quantities. Caller is responsible for the canonical per-vol unit so the
returned `ECCDistribution{CarbonPerVolQuantity}` stays single-unit
across the registry."""
function _summarize(vals::Vector{CarbonPerVolQuantity})
    nan_q = NaN * u"kgCO2e/m^3"
    n = length(vals)
    n == 0 && return ECCDistribution(0, nan_q, nan_q, nan_q, nan_q, nan_q, nan_q, nan_q)
    sort!(vals)
    μ = sum(vals) / n
    # `(Q)^2` produces `Quantity{Float64, (𝐗/𝐋³)^2, _}`; `sqrt` restores
    # the original per-vol units so `σ` shares `Q` with `μ`.
    σ = n > 1 ? sqrt(sum((v - μ)^2 for v in vals) / (n - 1)) : 0.0 * u"kgCO2e/m^3"
    return ECCDistribution(
        n, μ, σ,
        _percentile_sorted(vals, 0.10),
        _percentile_sorted(vals, 0.25),
        _median_sorted(vals),
        _percentile_sorted(vals, 0.75),
        _percentile_sorted(vals, 0.90),
    )
end

"""Load the CSV and populate the per-bucket distribution table. Idempotent."""
function _load_distributions!()
    _ECC_LOADED[] && return nothing
    isfile(_ECC_CSV_PATH) || error(
        "ECC distribution CSV missing: $(_ECC_CSV_PATH). " *
        "Run `python3 scripts/runners/ingest_rmc_ecc.py --apply` to regenerate.")

    expected = (:strength_psi, :density_class, :gwp_a1a3_kg_m3, :composition_class)
    file = CSV.File(_ECC_CSV_PATH)
    for col in expected
        col in propertynames(file) || error(
            "ECC CSV missing required column `$col`. " *
            "Found: $(propertynames(file)). Re-ingest with the latest script.")
    end

    # CSV records are in kg CO₂e per m³ — tag with `u"kgCO2e/m^3"` at
    # this single ingestion boundary so the rest of the module operates
    # on typed `CarbonPerVolQuantity` values.
    bucket_vals = Dict{_BucketKey, Vector{CarbonPerVolQuantity}}()
    raw_vals    = Dict{_RawKey,    Vector{CarbonPerVolQuantity}}()
    for row in file
        psi  = Int(row.strength_psi)
        dens = Symbol(row.density_class)
        comp = Symbol(row.composition_class)
        gwp  = Float64(row.gwp_a1a3_kg_m3) * u"kgCO2e/m^3"
        push!(get!(bucket_vals, (psi, dens, comp), CarbonPerVolQuantity[]), gwp)
        push!(get!(bucket_vals, (psi, dens, :all), CarbonPerVolQuantity[]), gwp)
        push!(get!(raw_vals,    (psi, dens),       CarbonPerVolQuantity[]), gwp)
    end

    empty!(_ECC_DISTRIBUTIONS)
    for (key, vals) in bucket_vals
        _ECC_DISTRIBUTIONS[key] = _summarize(vals)
    end
    empty!(_ECC_RAW_VALUES)
    for (key, vals) in raw_vals
        # Stored unsorted — sampling with replacement does not require
        # sorted input, and we want the ordered list to remain available
        # for callers who may want to re-summarize the bucket.
        _ECC_RAW_VALUES[key] = vals
    end
    _ECC_LOADED[] = true
    return nothing
end

# -----------------------------------------------------------------------------
# Public API
# -----------------------------------------------------------------------------

"""
    ecc_distribution(strength_psi; density_class=:NWC, composition=:all)
        -> ECCDistribution{CarbonPerVolQuantity}

Return the per-m³ A1–A3 GWP percentile summary for the given bucket.
All percentile fields carry `u"kgCO2e/m^3"`.

`composition` ∈ `(:all, :plain, :fa, :slag, :slag_fa, :sf, :ggp)`.
The default `:all` pools across compositions and yields the
within-strength-class distribution used in the Section 2 main figure.

Throws if the bucket is missing — small buckets (e.g. NWC 6 ksi
`slag_fa`, n = 9) are present but should be quoted with caution.
"""
function ecc_distribution(strength_psi::Integer;
                          density_class::Symbol = :NWC,
                          composition::Symbol   = :all)
    _load_distributions!()
    key = (Int(strength_psi), density_class, composition)
    haskey(_ECC_DISTRIBUTIONS, key) || error(
        "No EPD records for bucket $key. Available buckets: " *
        "$(sort(collect(keys(_ECC_DISTRIBUTIONS)))).")
    return _ECC_DISTRIBUTIONS[key]
end

"""
    ecc_distribution_per_kg(strength_psi, ρ; density_class=:NWC, composition=:all)
        -> ECCDistribution{CarbonPerMassQuantity}

Return the same percentile summary as [`ecc_distribution`](@ref) but
divided by `ρ` so the fields carry `u"kgCO2e/kg"` — the units consumed
by `Concrete.ecc`.

`ρ` may be a `Real` (interpreted as kg/m³) or a `Density` quantity
(e.g. `2380u"kg/m^3"`). Use the `Concrete` preset's nominal density
to match the rest of the embodied-carbon accounting; Unitful keeps the
dimensions honest regardless of which form is passed.
"""
function ecc_distribution_per_kg(strength_psi::Integer, ρ;
                                 density_class::Symbol = :NWC,
                                 composition::Symbol   = :all)
    dist = ecc_distribution(strength_psi;
                            density_class = density_class,
                            composition   = composition)
    ρ_q = ρ isa Unitful.Quantity ? ρ : Float64(ρ) * u"kg/m^3"
    ustrip(u"kg/m^3", ρ_q) > 0 || error("density must be positive, got $ρ")
    # `CarbonPerVolQuantity / Density = CarbonPerMassQuantity` via Unitful;
    # `uconvert` pins the result to the canonical `u"kgCO2e/kg"` unit so
    # the parametric struct keeps a single concrete type parameter.
    _per_kg(x) = uconvert(u"kgCO2e/kg", x / ρ_q)
    return ECCDistribution(
        dist.n,
        _per_kg(dist.mean),
        _per_kg(dist.std),
        _per_kg(dist.p10),
        _per_kg(dist.p25),
        _per_kg(dist.p50),
        _per_kg(dist.p75),
        _per_kg(dist.p90),
    )
end

"""
    ecc_samples(strength_psi; density_class=:NWC) -> Vector{CarbonPerVolQuantity}

Return the raw vector of A1–A3 GWP values for every EPD in the
`(strength_psi, density_class)` bucket, pooled across mix compositions,
typed as `u"kgCO2e/m^3"`. This is the empirical population that
[`sample_ecc_per_kg`](@ref) bootstraps from.

Returns the live registry vector — do not mutate. Use
`copy(ecc_samples(...))` if you need to modify a working copy; strip
to bare floats with `ustrip.(u"kgCO2e/m^3", v)` for downstream plotting
/ CSV pipelines that prefer numeric DataFrames.
"""
function ecc_samples(strength_psi::Integer; density_class::Symbol = :NWC)
    _load_distributions!()
    key = (Int(strength_psi), density_class)
    haskey(_ECC_RAW_VALUES, key) || error(
        "No EPD records for $(density_class) $(strength_psi) psi. " *
        "Available: $(sort(collect(keys(_ECC_RAW_VALUES)))).")
    return _ECC_RAW_VALUES[key]
end

"""
    sample_ecc_per_kg(strength_psi, ρ; density_class=:NWC, n=1000, rng=default_rng())
        -> Vector{CarbonPerMassQuantity}

Draw `n` Monte Carlo samples (typed `u"kgCO2e/kg"`) from the empirical
EPD distribution for `(strength_psi, density_class)`, dividing by `ρ`
to convert per-m³ into per-kg via Unitful.

Sampling is non-parametric bootstrap with replacement — no Gaussian /
log-normal fit is assumed, and tail mass is preserved. `ρ` may be a
`Real` (kg/m³) or a `Density` quantity. Pass an explicit `rng` for
reproducibility (`Random.MersenneTwister(seed)` is the conventional
choice).

For deterministic percentile summaries instead of MC samples, see
[`ecc_distribution`](@ref) / [`ecc_distribution_per_kg`](@ref).
"""
function sample_ecc_per_kg(strength_psi::Integer, ρ;
                           density_class::Symbol = :NWC,
                           n::Integer = 1000,
                           rng::AbstractRNG = default_rng())
    n > 0 || error("sample_ecc_per_kg: n must be positive, got $n")
    raw = ecc_samples(strength_psi; density_class = density_class)
    ρ_q = ρ isa Unitful.Quantity ? ρ : Float64(ρ) * u"kg/m^3"
    ustrip(u"kg/m^3", ρ_q) > 0 || error("density must be positive, got $ρ")
    # `Quantity{Float64,...}` arithmetic on each bootstrap draw; `uconvert`
    # pins the result to the canonical `u"kgCO2e/kg"` so the output vector
    # has a single concrete element type.
    out = Vector{CarbonPerMassQuantity}(undef, n)
    @inbounds for i in 1:n
        out[i] = uconvert(u"kgCO2e/kg", raw[rand(rng, 1:length(raw))] / ρ_q)
    end
    return out
end

"""List `(strength_psi, density_class)` pairs present in the registry."""
function list_strength_classes()
    _load_distributions!()
    pairs = Set{Tuple{Int, Symbol}}()
    for (psi, dens) in keys(_ECC_RAW_VALUES)
        push!(pairs, (psi, dens))
    end
    return sort!(collect(pairs))
end

"""List composition symbols present for a given `(strength_psi, density_class)`."""
function list_compositions(strength_psi::Integer, density_class::Symbol = :NWC)
    _load_distributions!()
    comps = Symbol[]
    for (psi, dens, comp) in keys(_ECC_DISTRIBUTIONS)
        if psi == Int(strength_psi) && dens == density_class && comp !== :all
            push!(comps, comp)
        end
    end
    return sort!(comps)
end
