# =============================================================================
# Design Results
# =============================================================================

"""
Strip reinforcement design at a moment location.
All values stored in coherent SI (m, m², kN·m).
"""
struct StripReinforcementDesign
    Mu::typeof(1.0u"kN*m")           # Factored moment
    As_required::typeof(1.0u"m^2")   # Required steel area
    As_minimum::typeof(1.0u"m^2")    # Minimum steel area
    As_provided::typeof(1.0u"m^2")   # Provided steel area
    bar_size::String                  # e.g., "#5", "16M"
    spacing::typeof(1.0u"m")          # Bar spacing
    n_bars::Int                       # Number of bars
end

"""
Design result for a slab panel.
All values stored in coherent SI (m, kPa, kN·m).
"""
Base.@kwdef mutable struct SlabDesignResult
    # ── Convergence & iteration tracking ──────────────────────────────
    converged::Bool = true
    failure_reason::String = ""               # e.g. "non_convergence"
    failing_check::String = ""                # last check that failed
    iterations::Int = 0                       # design iterations used
    pattern_loading::Bool = false             # ACI 13.7.6 pattern loading applied
    
    # Sizing
    thickness::typeof(1.0u"m")
    self_weight::typeof(1.0u"kPa")
    
    # Analysis
    M0::Union{typeof(1.0u"kN*m"), Nothing} = nothing  # Total static moment
    qu::Union{typeof(1.0u"kPa"), Nothing} = nothing    # Factored uniform load
    
    # Reinforcement (by location)
    column_strip::Dict{Symbol, StripReinforcementDesign} = Dict()  # :ext_neg, :pos, :int_neg
    middle_strip::Dict{Symbol, StripReinforcementDesign} = Dict()
    
    # Checks
    deflection_ok::Bool = true
    deflection_ratio::Float64 = 0.0           # actual / limit
    deflection_in::Float64 = 0.0              # actual deflection (inches)
    deflection_limit_in::Float64 = 0.0        # allowable deflection (inches)
    
    # Punching shear summary
    punching_max_ratio::Float64 = 0.0
    punching_ok::Bool = true
    punching_vu_max_psi::Float64 = 0.0        # max demand (psi)
    
    # Shear stud details
    has_studs::Bool = false
    n_stud_cols::Int = 0
    stud_rails_max::Int = 0
    stud_per_rail_max::Int = 0
    
    # Integrity & transfer (ACI 8.7.4.2 / 8.4.2.3)
    integrity_ok::Bool = true
    n_transfer_bars_additional::Int = 0
    
    # Column P-M reinforcement ratio (max ρg from slab-design column check)
    col_rho_max::Float64 = 0.0
    
    # Compression rebar ratio for long-term deflection
    ρ_prime::Float64 = 0.0
    
    # Drop panel geometry (flat slab only)
    h_drop_in::Float64 = 0.0
    a_drop1_ft::Float64 = 0.0
    a_drop2_ft::Float64 = 0.0

    # Captured from slab.drop_panel before restore! (survives snapshot round-trip)
    drop_panel::Union{Nothing, StructuralSizer.DropPanelGeometry} = nothing

    # Floor result type flags (survive restore! — slab.result gets reverted to initial estimate)
    is_vault::Bool = false
    vault_rise::Union{Nothing, typeof(1.0u"m")} = nothing

    # Full StructuralSizer result captured before restore! wipes slab.result.
    # Used by engineering_report and any downstream that needs the rich sizing detail.
    sizer_result::Union{Nothing, StructuralSizer.AbstractFloorResult} = nothing

    # USER DECISION: when the requested DDM or EFM is not permitted, the
    # design falls back to FEA and the caller must be able to see that.
    # Copied from the `size_flat_plate!` NamedTuple (`slab.design_details`)
    # by `_populate_slab_results!`.  `restore!` writes that NamedTuple back
    # onto the slab, so the same three fields survive a snapshot round-trip.
    # `method_fallback_reasons` is empty when the requested method was used.
    method_requested::Union{Nothing, StructuralSizer.FlatPlateAnalysisMethod} = nothing
    method_used::Union{Nothing, StructuralSizer.FlatPlateAnalysisMethod} = nothing
    method_fallback_reasons::Vector{String} = String[]

    # "not_analyzed" when only a minimum thickness was set and no moment
    # analysis ran. Empty when the floor type does not report it.
    analysis_status::String = ""

    # Wood-Armer bars of this slab's panels from the story shell, one field
    # per panel. Empty when the story shell did not design the slab.
    shell_reinforcement::Vector{StructuralSizer.ElementRebarField} =
        StructuralSizer.ElementRebarField[]
end

"""
    slab_diagnostic_governing_check(sr::SlabDesignResult) -> String

Canonical limit-state key for `/diagnose` and design summaries. When the slab passes API-style
`ok` (`converged && deflection_ok && punching_ok`), returns whichever of deflection vs slab
punching has the higher ratio. When it fails, prefers the sizer's `failing_check` and
`failure_reason` (e.g. Whitney / rebar inadequacy reports `section_inadequate` and
`reinforcement_design`) so diagnostics are not mislabeled as deflection or punching alone.
"""
function slab_diagnostic_governing_check(sr::SlabDesignResult)::String
    if sr.converged && sr.deflection_ok && sr.punching_ok
        return sr.deflection_ratio >= sr.punching_max_ratio ? "deflection" : "punching_shear_slab"
    end
    fc = strip(sr.failing_check)
    if !isempty(fc)
        fc == "reinforcement_design" && return "reinforcement_design"
        fc == "reinforcement_design_secondary" && return "reinforcement_design_secondary"
        fc == "transfer_reinforcement" && return "transfer_reinforcement"
        occursin("punching", fc) && return "punching_shear_slab"
        occursin("deflection", fc) && return "deflection"
    end
    fr = strip(sr.failure_reason)
    if fr == "section_inadequate"
        return "reinforcement_design"
    end
    if !sr.converged
        return "non_convergence"
    end
    if !sr.punching_ok
        return "punching_shear_slab"
    end
    if !sr.deflection_ok
        return "deflection"
    end
    return sr.deflection_ratio >= sr.punching_max_ratio ? "deflection" : "punching_shear_slab"
end
