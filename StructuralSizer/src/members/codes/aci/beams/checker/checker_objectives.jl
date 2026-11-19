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
    length::Length;
    rebar=nothing,
    transverse=nothing,
)
    Ag = section.b * section.h
    uconvert(u"m^3", Ag * length)
end

"""Self-weight of the RC beam, in kilograms. With `rebar`, longitudinal bars and stirrups are at the rebar density."""
function objective_value(
    ::MinWeight,
    section::RCBeamSection,
    material::Concrete,
    length::Length;
    rebar=nothing,
    transverse=nothing,
)
    Ag = section.b * section.h
    rebar === nothing && return uconvert(u"kg", Ag * length * material.ρ)
    trans = transverse === nothing ? rebar : transverse
    return _rc_objective(MinWeight(), Ag, section.As + section.As_prime, material, rebar, trans, length, section)
end

"""Cost of the RC beam: gross volume (m³)."""
function objective_value(
    ::MinCost,
    section::RCBeamSection,
    material::Concrete,
    length::Length;
    rebar=nothing,
    transverse=nothing,
)
    return uconvert(u"m^3", section.b * section.h * length)
end

"""Embodied carbon of the RC beam, a typed `kgCO₂e` quantity (Asap `𝐗` dimension)."""
function objective_value(
    ::MinCarbon,
    section::RCBeamSection,
    material::Concrete,
    length::Length;
    rebar=nothing,
    transverse=nothing,
)
    Ag = section.b * section.h
    rebar === nothing && return uconvert(u"kgCO2e",
        uconvert(u"m^3", Ag * length) * material.ρ * material.ecc)
    trans = transverse === nothing ? rebar : transverse
    return _rc_objective(MinCarbon(), Ag, section.As + section.As_prime, material, rebar, trans, length, section)
end
