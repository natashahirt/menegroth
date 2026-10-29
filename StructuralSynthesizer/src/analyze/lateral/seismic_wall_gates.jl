# ==============================================================================
# Gate before elastic wall forces are used as seismic design demands
# ==============================================================================
#
# The story analysis reports QE, Ax, and θ. It does not crack the shells,
# multiply Eh by ρ, amplify Mta by Ax, combine orthogonal directions, or
# fold P-delta into member forces. This function refuses that use unless
# the caller has already done the step, or the cited clause permits it.
# It does not apply a factor.

"""
    require_seismic_wall_demand_provisions(; sdc, ...)

Refuse seismic design use of elastic wall forces when a cited provision
is neither satisfied by the model nor permitted for this Seismic Design
Category.

Every argument is required. Nothing here is filled in:

- Cracked-section stiffness is the caller's statement that the shell
  model already follows ACI 318-19 Table 6.6.3.1.1(a). This function
  does not apply 0.70Ig or 0.35Ig, and it does not scale E.
- For Seismic Design Category B or C, §12.3.4.1 permits ρ = 1.0, so Eh
  may remain QE. For D, E, or F, ρ is not chosen here.
- Orthogonal combination is required only where §12.5.3 or §12.5.4 says
  the independent procedure is not permitted. For D, E, or F the caller
  must either apply §12.5.1.2 or state that 12.5.4(a)–(g) are absent.
  A stated Type 1 or Type 5 irregularity overrides that statement.
- Ax is required only for Category C, D, E, or F with a Type 1
  horizontal irregularity (§12.8.4.3). The factor is not computed here.
- P-delta on member forces is required only when θ > 0.10 (§12.8.7).
  θmax is not evaluated, because it depends on β and Cd.

# Citations
ASCE 7-22 §12.7.3 item 1 (corpus: asce-7-22, PDF page 184);
§12.3.4.1 and §12.3.4.2 (PDF page 182); Eq. 12.4-3 (PDF page 183);
§12.5.2–§12.5.4 (PDF pages 183–184); §12.8.4.3 Eq. 12.8-15 (PDF page 187);
§12.8.7 (PDF page 188).
ACI 318-19 §6.6.3.1.1 and Table 6.6.3.1.1(a) (corpus: aci-318-19, PDF page 78).
"""
function require_seismic_wall_demand_provisions(;
        sdc::Symbol,
        model_uses_cracked_section_stiffness::Bool,
        sustained_lateral_loads::Bool,
        sustained_lateral_divisor_applied::Bool,
        type1_horizontal_irregularity::Bool,
        type5_horizontal_irregularity::Bool,
        orthogonal_combination_applied::Bool,
        orthogonal_12_5_4_conditions_absent::Bool,
        ax_applied_to_accidental_torsion::Bool,
        theta::Real,
        pdelta_included_in_member_forces::Bool,
        rho_applied_to_eh::Bool)
    _require_cracked_wall_stiffness(;
        model_uses_cracked_section_stiffness,
        sustained_lateral_loads,
        sustained_lateral_divisor_applied)
    sdc in (:B, :C, :D, :E, :F) || throw(ArgumentError(
        "Seismic Design Category $(sdc) is not B, C, D, E, or F. " *
        "ASCE 7-22 §12.3.4 and §12.5 are not applied to an unnamed category."))
    _require_redundancy_on_eh(; sdc, rho_applied_to_eh)
    _require_orthogonal_directions(;
        sdc, type1_horizontal_irregularity, type5_horizontal_irregularity,
        orthogonal_combination_applied, orthogonal_12_5_4_conditions_absent)
    _require_torsional_amplification(;
        sdc, type1_horizontal_irregularity, ax_applied_to_accidental_torsion)
    _require_pdelta_on_strength(; theta, pdelta_included_in_member_forces)
    return nothing
end

function _require_cracked_wall_stiffness(;
        model_uses_cracked_section_stiffness::Bool,
        sustained_lateral_loads::Bool,
        sustained_lateral_divisor_applied::Bool)
    if !model_uses_cracked_section_stiffness
        throw(ArgumentError(
            "Seismic wall forces from a gross-section shell model are refused. " *
            "ASCE 7-22 §12.7.3 item 1 (corpus: asce-7-22, PDF page 184) requires " *
            "concrete stiffness to consider cracked sections. ACI 318-19 " *
            "Table 6.6.3.1.1(a) (corpus: aci-318-19, PDF page 78) permits " *
            "0.70Ig for an uncracked wall and 0.35Ig for a cracked wall, with " *
            "axial area 1.0Ag. Neither factor is applied here."))
    end
    if sustained_lateral_loads && !sustained_lateral_divisor_applied
        throw(ArgumentError(
            "Sustained lateral load is present and the wall inertia has not " *
            "been divided by (1 + βds). ACI 318-19 §6.6.3.1.1 (corpus: " *
            "aci-318-19, PDF page 78) requires that divisor for columns and " *
            "walls. It is not applied here."))
    end
    return nothing
end

function _require_redundancy_on_eh(; sdc::Symbol, rho_applied_to_eh::Bool)
    sdc in (:D, :E, :F) || return nothing
    rho_applied_to_eh && return nothing
    throw(ArgumentError(
        "Eh is still QE. ASCE 7-22 Eq. 12.4-3 (corpus: asce-7-22, PDF page 183) " *
        "is Eh = ρ QE. For Seismic Design Category $sdc, §12.3.4.2 (PDF page 182) " *
        "sets ρ = 1.3 unless its conditions are met. Those conditions are not " *
        "evaluated here, and ρ is not applied."))
end

function _require_orthogonal_directions(;
        sdc::Symbol,
        type1_horizontal_irregularity::Bool,
        type5_horizontal_irregularity::Bool,
        orthogonal_combination_applied::Bool,
        orthogonal_12_5_4_conditions_absent::Bool)
    # §12.5.2 permits the independent procedure for Category B.
    sdc == :B && return nothing
    orthogonal_combination_applied && return nothing
    if sdc == :C
        type5_horizontal_irregularity || return nothing
        throw(ArgumentError(
            "Seismic Design Category C with a Type 5 horizontal irregularity " *
            "requires the orthogonal combination of ASCE 7-22 §12.5.1.2. " *
            "§12.5.3 (corpus: asce-7-22, PDF page 184) does not permit the " *
            "independent procedure. One seismic direction was used."))
    end
    if type1_horizontal_irregularity || type5_horizontal_irregularity
        which = type1_horizontal_irregularity ? "Type 1" : "Type 5"
        throw(ArgumentError(
            "Seismic Design Category $sdc with a $which horizontal irregularity " *
            "requires the orthogonal combination of ASCE 7-22 §12.5.1.2. " *
            "§12.5.4(a)–(b) (corpus: asce-7-22, PDF page 184) does not permit " *
            "the independent procedure. One seismic direction was used."))
    end
    orthogonal_12_5_4_conditions_absent && return nothing
    throw(ArgumentError(
        "Seismic Design Category $sdc was analyzed in one direction. " *
        "ASCE 7-22 §12.5.4 (corpus: asce-7-22, PDF page 184) permits that " *
        "only when 12.5.4(a)–(g) are absent. Those conditions were not " *
        "stated absent, and §12.5.1.2 was not applied."))
end

function _require_torsional_amplification(;
        sdc::Symbol,
        type1_horizontal_irregularity::Bool,
        ax_applied_to_accidental_torsion::Bool)
    sdc == :B && return nothing
    type1_horizontal_irregularity || return nothing
    ax_applied_to_accidental_torsion && return nothing
    throw(ArgumentError(
        "Accidental torsion is unamplified. ASCE 7-22 §12.8.4.3 (corpus: " *
        "asce-7-22, PDF page 187) requires Ax on Mta for Seismic Design " *
        "Category $sdc when a Type 1 horizontal irregularity exists. " *
        "Eq. 12.8-15 is not applied here."))
end

function _require_pdelta_on_strength(;
        theta::Real, pdelta_included_in_member_forces::Bool)
    θ = Float64(theta)
    isfinite(θ) && θ >= 0 || throw(ArgumentError(
        "Stability coefficient θ must be a finite number ≥ 0. Got $theta."))
    θ <= 0.10 && return nothing
    pdelta_included_in_member_forces && return nothing
    throw(ArgumentError(
        "θ = $θ is greater than 0.10 and member forces omit P-delta. " *
        "ASCE 7-22 §12.8.7 (corpus: asce-7-22, PDF page 188) requires those " *
        "effects on story shears, moments, and member forces. The " *
        "1/(1 − θ) alternative is not applied here."))
end
