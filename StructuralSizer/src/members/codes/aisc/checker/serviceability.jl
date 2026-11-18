# ==============================================================================
# Composite Beam Feasibility (AISC 360-22 Chapter I, with 360-16 Chapter F/H)
# ==============================================================================

"""Inertia the composite deflection check needs. `nothing` when that check is off.
Unshored total deflection uses bare `Ix` and is not part of this inertia."""
function _I_required_for_composite(checker, shored::Bool, L_m, I_ref, δ_LL, δ_total)
    need = 0.0
    if !isnothing(checker.deflection_limit) && I_ref > 0 && δ_LL > 0 && checker.deflection_limit > 0
        need = max(need, δ_LL * I_ref / (checker.deflection_limit * L_m))
    end
    if shored && !isnothing(checker.total_deflection_limit) && I_ref > 0 && δ_total > 0 &&
            checker.total_deflection_limit > 0
        need = max(need, δ_total * I_ref / (checker.total_deflection_limit * L_m))
    end
    return need > 0 ? need * u"m^4" : nothing
end
