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
# Boundary system: A1–A3 only (raw materials → cement plant → ready-mix
# gate). A4 transport, A5 install, B-stage use, and C-stage end-of-life
# are out of scope. Always quote distributional results with this caveat.
#
# Provenance: see `data/README.md`. Regenerate the CSV with:
#
#     python3 scripts/runners/ingest_rmc_ecc.py --apply
#
# This file deliberately avoids `DataFrames` and `Statistics` to keep
# StructuralSizer's dependency surface flat — `CSV.File` is already used
# by the AISC section catalogs (see `members/sections/steel/catalogs/`).
#
# =============================================================================

using Random: AbstractRNG, default_rng

const _ECC_CSV_PATH = joinpath(@__DIR__, "data", "rmc_epd_2021_2025.csv")

"""
    ECCDistribution

Percentile summary of a (strength, density-class, composition) bucket of
EPD records. All GWP fields are in **kg CO₂e per m³ of concrete**
(A1–A3 cradle-to-gate).

Fields: `n`, `mean`, `std`, `p10`, `p25`, `p50`, `p75`, `p90`.
"""
struct ECCDistribution
    n   ::Int
    mean::Float64
    std ::Float64
    p10 ::Float64
    p25 ::Float64
    p50 ::Float64
    p75 ::Float64
    p90 ::Float64
end

"""Bucket key: `(strength_psi, density_class, composition)`. The
composition `:all` marks the pooled-across-compositions distribution."""
const _BucketKey = Tuple{Int, Symbol, Symbol}

"""Raw-bucket key: `(strength_psi, density_class)`. Used by the Monte
Carlo sampler, which always pools across compositions."""
const _RawKey = Tuple{Int, Symbol}

# Lazily populated on first access — see `_load_distributions!`.
const _ECC_DISTRIBUTIONS = Dict{_BucketKey, ECCDistribution}()
const _ECC_RAW_VALUES    = Dict{_RawKey, Vector{Float64}}()
const _ECC_LOADED        = Ref(false)

# -----------------------------------------------------------------------------
# Internal helpers
# -----------------------------------------------------------------------------

"""Return the empirical p-percentile of a sorted vector using the same
nearest-rank rule the Python ingest script applies (`vals[floor(p·n)]`),
so that Julia and Python summaries match exactly."""
function _percentile_sorted(vals::Vector{Float64}, p::Float64)
    n = length(vals)
    n == 0 && return NaN
    n == 1 && return vals[1]
    idx = clamp(floor(Int, p * n), 0, n - 1) + 1
    return vals[idx]
end

"""Median (50th percentile) with linear interpolation on even-length
vectors. Used in preference to `_percentile_sorted(_, 0.5)` for the
canonical median field."""
function _median_sorted(vals::Vector{Float64})
    n = length(vals)
    n == 0 && return NaN
    n == 1 && return vals[1]
    mid = n ÷ 2
    return iseven(n) ? 0.5 * (vals[mid] + vals[mid + 1]) : vals[mid + 1]
end

function _summarize(vals::Vector{Float64})
    n = length(vals)
    n == 0 && return ECCDistribution(0, NaN, NaN, NaN, NaN, NaN, NaN, NaN)
    sort!(vals)
    μ = sum(vals) / n
    σ = if n > 1
        sqrt(sum((v - μ)^2 for v in vals) / (n - 1))
    else
        0.0
    end
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

    bucket_vals = Dict{_BucketKey, Vector{Float64}}()
    raw_vals    = Dict{_RawKey,    Vector{Float64}}()
    for row in file
        psi  = Int(row.strength_psi)
        dens = Symbol(row.density_class)
        comp = Symbol(row.composition_class)
        gwp  = Float64(row.gwp_a1a3_kg_m3)
        push!(get!(bucket_vals, (psi, dens, comp), Float64[]), gwp)
        push!(get!(bucket_vals, (psi, dens, :all), Float64[]), gwp)
        push!(get!(raw_vals,    (psi, dens),       Float64[]), gwp)
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
    ecc_distribution(strength_psi; density_class=:NWC, composition=:all) -> ECCDistribution

Return the per-m³ A1–A3 GWP percentile summary for the given bucket.

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
    ecc_distribution_per_kg(strength_psi, ρ; density_class=:NWC, composition=:all) -> ECCDistribution

Return the same percentile summary as [`ecc_distribution`](@ref) but
scaled by `1/ρ` so that the fields are **kg CO₂e per kg of concrete**
— the units consumed by `Concrete.ecc`.

`ρ` may be a `Real` (interpreted as kg/m³) or a `Density` quantity
(e.g. `2380u"kg/m^3"`). Use the `Concrete` preset's nominal density
to match the rest of the embodied-carbon accounting.
"""
function ecc_distribution_per_kg(strength_psi::Integer, ρ;
                                 density_class::Symbol = :NWC,
                                 composition::Symbol   = :all)
    dist = ecc_distribution(strength_psi;
                            density_class=density_class,
                            composition=composition)
    ρ_kg_m3 = if ρ isa Real
        Float64(ρ)
    else
        ustrip(u"kg/m^3", ρ)
    end
    ρ_kg_m3 > 0 || error("density must be positive, got $ρ")
    inv_ρ = 1.0 / ρ_kg_m3
    return ECCDistribution(
        dist.n,
        dist.mean * inv_ρ,
        dist.std  * inv_ρ,
        dist.p10  * inv_ρ,
        dist.p25  * inv_ρ,
        dist.p50  * inv_ρ,
        dist.p75  * inv_ρ,
        dist.p90  * inv_ρ,
    )
end

"""
    ecc_samples(strength_psi; density_class=:NWC) -> Vector{Float64}

Return the raw vector of A1–A3 GWP values (kg CO₂e / m³) for every EPD
in the `(strength_psi, density_class)` bucket, pooled across mix
compositions. This is the empirical population that `sample_ecc_per_kg`
bootstraps from.

Returns the live registry vector — do not mutate. Use
`copy(ecc_samples(...))` if you need to modify a working copy.
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
    sample_ecc_per_kg(strength_psi, ρ; density_class=:NWC, n=1000, rng=default_rng()) -> Vector{Float64}

Draw `n` Monte Carlo samples (kg CO₂e per **kg** of concrete) from the
empirical EPD distribution for `(strength_psi, density_class)`, scaled
by `1/ρ` to convert per-m³ into per-kg.

Sampling is non-parametric bootstrap with replacement — no Gaussian /
log-normal fit is assumed, and tail-mass is preserved. `ρ` may be a
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
    ρ_kg_m3 = ρ isa Real ? Float64(ρ) : ustrip(u"kg/m^3", ρ)
    ρ_kg_m3 > 0 || error("density must be positive, got $ρ")
    inv_ρ = 1.0 / ρ_kg_m3
    out = Vector{Float64}(undef, n)
    @inbounds for i in 1:n
        out[i] = raw[rand(rng, 1:length(raw))] * inv_ρ
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
