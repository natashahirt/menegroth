"""
    MaterialTakeoff

Concrete volume, rebar mass, and structural-steel mass for one group of
elements, with the embodied carbon of each. Built from the volumes stored on
those elements, which is the same source as the carbon split.
"""
struct MaterialTakeoff
    concrete_volume::typeof(1.0u"m^3")
    rebar_mass::typeof(1.0u"kg")
    structural_steel_mass::typeof(1.0u"kg")
    concrete_ec::CarbonMassQuantity
    rebar_ec::CarbonMassQuantity
    structural_steel_ec::CarbonMassQuantity
end

MaterialTakeoff() = MaterialTakeoff(
    0.0u"m^3", 0.0u"kg", 0.0u"kg",
    0.0u"kgCO2e", 0.0u"kgCO2e", 0.0u"kgCO2e",
)

function Base.:+(a::MaterialTakeoff, b::MaterialTakeoff)
    MaterialTakeoff(
        a.concrete_volume + b.concrete_volume,
        a.rebar_mass + b.rebar_mass,
        a.structural_steel_mass + b.structural_steel_mass,
        a.concrete_ec + b.concrete_ec,
        a.rebar_ec + b.rebar_ec,
        a.structural_steel_ec + b.structural_steel_ec,
    )
end

"""
Design summary with aggregate metrics.
"""
Base.@kwdef mutable struct DesignSummary
    # Volumes/weights
    concrete_volume::typeof(1.0u"m^3") = 0.0u"m^3"
    steel_weight::typeof(1.0u"kg") = 0.0u"kg"
    rebar_weight::typeof(1.0u"kg") = 0.0u"kg"
    timber_volume::typeof(1.0u"m^3") = 0.0u"m^3"

    # Derived metrics. All `embodied_carbon_*` fields carry typed
    # `kgCO₂e` quantities (Asap `𝐗` dimension); serialize / report /
    # narrate / agent-tool paths strip via `ustrip(u"kgCO2e", …)` at the
    # JSON / Printf boundary. Populated by `_compute_design_summary!` from
    # the single `compute_building_ec` call so the per-element parts sum
    # exactly to `embodied_carbon`.
    embodied_carbon::CarbonMassQuantity              = 0.0u"kgCO2e"
    embodied_carbon_slabs::CarbonMassQuantity        = 0.0u"kgCO2e"
    embodied_carbon_columns::CarbonMassQuantity      = 0.0u"kgCO2e"
    embodied_carbon_beams::CarbonMassQuantity        = 0.0u"kgCO2e"
    embodied_carbon_struts::CarbonMassQuantity       = 0.0u"kgCO2e"
    embodied_carbon_foundations::CarbonMassQuantity  = 0.0u"kgCO2e"
    embodied_carbon_fireproofing::CarbonMassQuantity = 0.0u"kgCO2e"
    # Material partition of the same total. Concrete, rebar, structural steel,
    # timber, and other come from element volumes; fireproofing is a coating
    # and is not in those five. The five plus fireproofing equal `embodied_carbon`.
    embodied_carbon_concrete::CarbonMassQuantity          = 0.0u"kgCO2e"
    embodied_carbon_rebar::CarbonMassQuantity             = 0.0u"kgCO2e"
    embodied_carbon_structural_steel::CarbonMassQuantity  = 0.0u"kgCO2e"
    embodied_carbon_timber::CarbonMassQuantity            = 0.0u"kgCO2e"
    embodied_carbon_other::CarbonMassQuantity             = 0.0u"kgCO2e"
    # Element × material. Summing a field across these five equals the
    # matching building-level material total above. Drop panels, shear caps,
    # and punching studs added only to `concrete_volume` / `rebar_weight` are
    # not here. Composite headed studs are in the beam steel mass.
    takeoff_slabs::MaterialTakeoff        = MaterialTakeoff()
    takeoff_columns::MaterialTakeoff      = MaterialTakeoff()
    takeoff_beams::MaterialTakeoff        = MaterialTakeoff()
    takeoff_struts::MaterialTakeoff       = MaterialTakeoff()
    takeoff_foundations::MaterialTakeoff  = MaterialTakeoff()
    cost_estimate::Float64 = 0.0      # $

    # Status
    all_checks_pass::Bool = true
    # When any element fails API-style `ok`, this names the worst failing element and its governing ratio.
    # When all pass, this is the highest utilization anywhere (demand/limit style ratios).
    critical_element::String = ""
    critical_ratio::Float64 = 0.0
end

