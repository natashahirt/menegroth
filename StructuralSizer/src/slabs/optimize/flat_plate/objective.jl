# ==============================================================================
# Internal: Composite Objective (Concrete + Steel)
# ==============================================================================

"""
    _flat_plate_objective(p, h, c, rebar) -> Float64

Compute the composite objective for a flat-plate grid point.
Accounts for both slab concrete, column concrete, and rebar steel.
"""
function _flat_plate_objective(p::FlatPlateNLPProblem, h, c, rebar)
    # Slab concrete volume (per panel)
    V_slab = ustrip(u"m", h) * ustrip(u"m", p.l1) * ustrip(u"m", p.l2)

    # Column concrete volume (c² × Σ column heights)
    c_m = ustrip(u"m", c)
    V_col = c_m^2 * p.column_height_sum_m

    V_conc = V_slab + V_col   # m³

    # Steel volume ≈ total As × span length (approximate)
    V_steel = ustrip(u"m^2", rebar.total_As) * ustrip(u"m", p.l1)  # m³

    obj = p.objective
    ρ_c = ustrip(u"kg/m^3", p.material.concrete.ρ)
    ρ_s = ustrip(u"kg/m^3", p.material.rebar.ρ)

    if obj isa MinVolume
        return V_conc + V_steel
    elseif obj isa MinWeight
        return V_conc * ρ_c + V_steel * ρ_s
    elseif obj isa MinCarbon
        # Strip typed `ecc` once at the NLP boundary — JuMP needs bare Float64.
        ecc_c = ustrip(u"kgCO2e/kg", p.material.concrete.ecc)
        ecc_s = ustrip(u"kgCO2e/kg", p.material.rebar.ecc)
        return V_conc * ρ_c * ecc_c + V_steel * ρ_s * ecc_s
    elseif obj isa MinCost
        cc = p.material.concrete.cost
        cs = p.material.rebar.cost
        (isnan(cc) || isnan(cs)) &&
            error("MinCost requires both concrete.cost and rebar.cost to be set")
        return V_conc * ρ_c * cc + V_steel * ρ_s * cs
    else
        error("Unsupported objective: $(typeof(obj))")
    end
end

