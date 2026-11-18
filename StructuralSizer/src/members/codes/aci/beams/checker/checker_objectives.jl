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

