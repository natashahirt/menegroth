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

