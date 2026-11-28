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

"""
    cache_matches(checker::ACIBeamChecker, cache::ACIBeamCapacityCache, catalog, material) -> Bool

True when `cache` holds one entry per catalog section and was precomputed for
this material's `f'c` and this checker's rebar grade (`fy`, `Es`). Those are the
only material / checker inputs [`precompute_capacities!`](@ref) reads, so a cache
that matches them is valid for any demand or span — the span- and load-dependent
checks run per demand in `is_feasible`, never from the cache.

Backstops a caller-supplied cache (e.g. `size_tbeams`' `capacity_store`) through
`_require_cache_match`, so a mis-keyed cache throws instead of sizing against
capacities that belong to a different catalog or grade.
"""
function cache_matches(checker::ACIBeamChecker, cache::ACIBeamCapacityCache, catalog, material)
    length(cache.depths) == length(catalog) || return false
    fy, Es = material isa ReinforcedConcreteMaterial ?
        (fy_ksi(material), Es_ksi(material)) : (checker.fy_ksi, checker.Es_ksi)
    same(a, b) = isapprox(a, b; rtol = 1e-9)
    return same(cache.fc_ksi, fc_ksi(material)) && same(cache.fy_ksi, fy) &&
           same(cache.Es_ksi, Es)
end

