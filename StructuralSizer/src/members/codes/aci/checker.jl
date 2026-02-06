# ==============================================================================
# ACI 318-19 Capacity Checker for RC Columns
# ==============================================================================
# Implements AbstractCapacityChecker for ACI 318 concrete column design.
# Matches the interface used by AISCChecker for MIP optimization.
#
# Uses unified material utilities from aci_material_utils.jl

using Asap: kip, ksi, to_ksi

"""
    ACIColumnChecker <: AbstractCapacityChecker

ACI 318-19 capacity checker for reinforced concrete columns.
Implements the same interface as AISCChecker for use with `optimize_discrete`.

# Options
- `include_slenderness`: Whether to consider slenderness effects (default true)
- `include_biaxial`: Whether to consider biaxial bending (default true)
- `α_biaxial`: Load contour exponent for biaxial check (default 1.5)
- `fy_ksi`: Rebar yield strength in ksi (default 60.0 for Grade 60)
- `max_depth`: Maximum section depth constraint (meters, Inf = no limit)

# Strength Reduction Factors (computed per ACI Table 21.2.2)
- Tension-controlled (εt ≥ 0.005): φ = 0.90
- Compression-controlled (εt ≤ εy): φ = 0.65 (tied), 0.75 (spiral)
- Transition zone: linear interpolation

# Usage
```julia
checker = ACIColumnChecker(; include_slenderness=true, α_biaxial=1.5)
catalog = standard_rc_columns()
demands = [RCColumnDemand(1; Pu=500.0, Mux=100.0, Muy=50.0)]
geometries = [ConcreteMemberGeometry(12.0/3.28; k=1.0, braced=true)]
result = optimize_discrete(checker, demands, geometries, catalog, NWC_4000)
```
"""
struct ACIColumnChecker <: AbstractCapacityChecker
    include_slenderness::Bool
    include_biaxial::Bool
    α_biaxial::Float64
    fy_ksi::Float64         # Rebar yield strength (ksi)
    max_depth::Float64      # meters
end

function ACIColumnChecker(;
    include_slenderness = true,
    include_biaxial = true,
    α_biaxial = 1.5,
    fy_ksi = 60.0,          # Grade 60 rebar
    max_depth = Inf
)
    max_d = max_depth isa Unitful.Quantity ? ustrip(uconvert(u"m", max_depth)) : Float64(max_depth)
    ACIColumnChecker(include_slenderness, include_biaxial, Float64(α_biaxial), Float64(fy_ksi), max_d)
end

# ==============================================================================
# Capacity Cache
# ==============================================================================

"""Union type for P-M diagrams (rectangular or circular)."""
# Use broader type to handle parametric material types
const PMDiagram = PMInteractionDiagram{<:AbstractSection}

"""
    ACIColumnCapacityCache <: AbstractCapacityCache

Caches P-M diagrams and objective coefficients for RC columns.
Supports both rectangular and circular sections.

For rectangular sections, also caches y-axis (minor axis) diagrams
to support proper biaxial bending checks when b ≠ h.
"""
mutable struct ACIColumnCapacityCache <: AbstractCapacityCache
    diagrams::Vector{PMDiagram}             # P-M diagrams per section (x-axis / strong axis)
    diagrams_y::Vector{Union{PMDiagram, Nothing}}  # Y-axis diagrams for rectangular sections
    obj_coeffs::Vector{Float64}             # Objective coefficients per section
    depths::Vector{Float64}                 # Section depths in meters (h for rect, D for circular)
    is_square::Vector{Bool}                 # True if section is approximately square (b ≈ h)
    fc_ksi::Float64                         # Concrete strength (ksi)
    fy_ksi::Float64                         # Steel yield strength (ksi)
    Es_ksi::Float64                         # Steel modulus (ksi)
end

function ACIColumnCapacityCache(n_sections::Int)
    ACIColumnCapacityCache(
        Vector{PMDiagram}(undef, n_sections),
        Vector{Union{PMDiagram, Nothing}}(nothing, n_sections),  # Y-axis diagrams
        zeros(n_sections),
        zeros(n_sections),
        fill(true, n_sections),  # Default to square
        0.0,
        0.0,
        29000.0
    )
end

"""Create a checker-specific cache."""
create_cache(::ACIColumnChecker, n_sections::Int) = ACIColumnCapacityCache(n_sections)

# ==============================================================================
# Interface Implementation
# ==============================================================================

"""
    precompute_capacities!(checker, cache, catalogue, material, objective)

Precompute P-M diagrams and objective coefficients for all sections.
Works with both rectangular (RCColumnSection) and circular (RCCircularSection) types.

# Material Support
- `Concrete`: Uses checker.fy_ksi for rebar strength
- `ReinforcedConcreteMaterial`: Uses embedded rebar properties
"""
function precompute_capacities!(
    checker::ACIColumnChecker,
    cache::ACIColumnCapacityCache,
    catalogue::AbstractVector{<:AbstractSection},
    material::Concrete,
    objective::AbstractObjective
)
    n = length(catalogue)
    
    # Extract material properties in ksi (ACI uses US units internally)
    cache.fc_ksi = fc_ksi(material)
    cache.fy_ksi = checker.fy_ksi  # From checker (rebar strength)
    cache.Es_ksi = 29000.0         # Standard Es for rebar
    
    # Build material tuple for P-M functions
    mat = to_material_tuple(material, cache.fy_ksi, cache.Es_ksi)
    
    _precompute_diagrams!(checker, cache, catalogue, material, mat, objective, n)
end

# Overload for ReinforcedConcreteMaterial - uses embedded rebar properties
function precompute_capacities!(
    checker::ACIColumnChecker,
    cache::ACIColumnCapacityCache,
    catalogue::AbstractVector{<:AbstractSection},
    material::ReinforcedConcreteMaterial,
    objective::AbstractObjective
)
    n = length(catalogue)
    
    # Extract material properties from the RC material
    cache.fc_ksi = fc_ksi(material)
    cache.fy_ksi = fy_ksi(material)
    cache.Es_ksi = Es_ksi(material)
    
    # Build material tuple from RC material
    mat = to_material_tuple(material)
    
    _precompute_diagrams!(checker, cache, catalogue, material.concrete, mat, objective, n)
end

# Internal helper to avoid code duplication
function _precompute_diagrams!(
    checker::ACIColumnChecker,
    cache::ACIColumnCapacityCache,
    catalogue::AbstractVector{<:AbstractSection},
    concrete::Concrete,  # For objective_value (needs Concrete, not tuple)
    mat::NamedTuple,     # For P-M calculations
    objective::AbstractObjective,
    n::Int
)
    # Determine target unit for objective
    ref_obj = objective_value(objective, catalogue[1], concrete, 1.0u"m")
    ref_unit = ref_obj isa Unitful.Quantity ? unit(ref_obj) : Unitful.NoUnits
    
    for j in 1:n
        section = catalogue[j]
        
        # Generate P-M diagram (dispatches on section type)
        cache.diagrams[j] = generate_PM_diagram(section, mat; n_intermediate=15)
        
        # Section depth (h for rectangular, D for circular)
        cache.depths[j] = _section_depth_m(section)
        
        # Check if section is approximately square and generate y-axis diagram if needed
        cache.is_square[j], cache.diagrams_y[j] = _check_square_and_generate_y_diagram(
            section, mat, checker.include_biaxial
        )
        
        # Objective coefficient (value per meter)
        val = objective_value(objective, section, concrete, 1.0u"m")
        if ref_unit != Unitful.NoUnits
            cache.obj_coeffs[j] = ustrip(uconvert(ref_unit, val))
        else
            cache.obj_coeffs[j] = val
        end
    end
end

# Helper to check if section is square and generate y-axis diagram if needed
function _check_square_and_generate_y_diagram(section::RCColumnSection, mat, include_biaxial::Bool)
    b = ustrip(u"inch", section.b)
    h = ustrip(u"inch", section.h)
    
    # Consider square if dimensions within 5% of each other
    is_square = abs(b - h) / max(b, h) < 0.05
    
    # Generate y-axis diagram for rectangular sections if biaxial is enabled
    diagram_y = if !is_square && include_biaxial
        generate_PM_diagram_yaxis(section, mat; n_intermediate=15)
    else
        nothing
    end
    
    return is_square, diagram_y
end

# Circular sections are always "square" (axisymmetric)
function _check_square_and_generate_y_diagram(section::RCCircularSection, mat, include_biaxial::Bool)
    return true, nothing
end

# Helper to extract section depth in meters (works for both section types)
_section_depth_m(section::RCColumnSection) = ustrip(uconvert(u"m", section.h))
_section_depth_m(section::RCCircularSection) = ustrip(uconvert(u"m", section.D))

"""
    is_feasible(checker, cache, j, section, material, demand, geometry) -> Bool

Check if an RC column section satisfies ACI 318 requirements for the given demand.
Checks:
1. Depth constraint
2. Uniaxial P-M interaction (with slenderness magnification if enabled)
3. Biaxial interaction (if enabled and Muy > 0)
"""
function is_feasible(
    checker::ACIColumnChecker,
    cache::ACIColumnCapacityCache,
    j::Int,
    section::RCColumnSection,
    material::Concrete,
    demand::RCColumnDemand,
    geometry::ConcreteMemberGeometry
)::Bool
    _is_feasible_rc_column(checker, cache, j, section, material, demand, geometry)
end

function is_feasible(
    checker::ACIColumnChecker,
    cache::ACIColumnCapacityCache,
    j::Int,
    section::RCCircularSection,
    material::Concrete,
    demand::RCColumnDemand,
    geometry::ConcreteMemberGeometry
)::Bool
    _is_feasible_rc_column(checker, cache, j, section, material, demand, geometry)
end

# Generic implementation for both section types
function _is_feasible_rc_column(
    checker::ACIColumnChecker,
    cache::ACIColumnCapacityCache,
    j::Int,
    section::Union{RCColumnSection, RCCircularSection},
    material::Concrete,
    demand::RCColumnDemand,
    geometry::ConcreteMemberGeometry
)::Bool
    # Extract demand values in kip and kip-ft
    Pu = demand.Pu isa Unitful.Quantity ? ustrip(kip, demand.Pu) : Float64(demand.Pu)
    Mux = demand.Mux isa Unitful.Quantity ? ustrip(kip*u"ft", demand.Mux) : Float64(demand.Mux)
    Muy = demand.Muy isa Unitful.Quantity ? ustrip(kip*u"ft", demand.Muy) : Float64(demand.Muy)
    βdns = Float64(demand.βdns)
    
    # --- Depth Check ---
    cache.depths[j] <= checker.max_depth || return false
    
    # --- Slenderness Effects ---
    if checker.include_slenderness
        # Create material tuple for slenderness functions
        mat = (fc = cache.fc_ksi, fy = cache.fy_ksi, Es = cache.Es_ksi, εcu = 0.003)
        
        # Extract end moments (M1 = smaller, M2 = larger) for proper Cm calculation
        M1x = demand.M1x isa Unitful.Quantity ? ustrip(kip*u"ft", demand.M1x) : Float64(demand.M1x)
        M2x = demand.M2x isa Unitful.Quantity ? ustrip(kip*u"ft", demand.M2x) : Float64(demand.M2x)
        M1y = demand.M1y isa Unitful.Quantity ? ustrip(kip*u"ft", demand.M1y) : Float64(demand.M1y)
        M2y = demand.M2y isa Unitful.Quantity ? ustrip(kip*u"ft", demand.M2y) : Float64(demand.M2y)
        
        # Magnify moment if slender (using actual end moments for Cm)
        result = magnify_moment_nonsway(
            section, mat, geometry,
            Pu, M1x, M2x;
            βdns = βdns
        )
        Mux = result.Mc
        
        # Also magnify Muy if biaxial
        if Muy > 0 && checker.include_biaxial
            result_y = magnify_moment_nonsway(
                section, mat, geometry,
                Pu, M1y, M2y;
                βdns = βdns
            )
            Muy = result_y.Mc
        end
    end
    
    # --- Get P-M diagram ---
    diagram = cache.diagrams[j]
    
    # --- Uniaxial P-M Check (x-axis) ---
    check_x = check_PM_capacity(diagram, Pu, Mux)
    check_x.adequate || return false
    
    # --- Biaxial Check (if applicable) ---
    if checker.include_biaxial && Muy > 0
        # Bresler Load Contour: (Mux/φMnx)^α + (Muy/φMny)^α ≤ 1.0
        φMnx = check_x.φMn_at_Pu
        
        # For rectangular sections (b ≠ h), use y-axis diagram for φMny
        # For square/circular sections, use same capacity for both axes
        φMny = if cache.is_square[j] || isnothing(cache.diagrams_y[j])
            φMnx  # Same for square/circular section
        else
            # Use y-axis diagram for rectangular sections
            check_y = check_PM_capacity(cache.diagrams_y[j], Pu, Muy)
            check_y.adequate || return false  # Must also pass y-axis check
            check_y.φMn_at_Pu
        end
        
        util_biaxial = bresler_load_contour(Mux, Muy, φMnx, φMny; α=checker.α_biaxial)
        util_biaxial <= 1.0 || return false
    end
    
    return true
end

"""Get the objective coefficient for section j."""
function get_objective_coeff(checker::ACIColumnChecker, cache::ACIColumnCapacityCache, j::Int)::Float64
    cache.obj_coeffs[j]
end

"""Generate error message for infeasible groups."""
function get_feasibility_error_msg(
    checker::ACIColumnChecker,
    demand::RCColumnDemand,
    geometry::ConcreteMemberGeometry
)
    Pu = demand.Pu isa Unitful.Quantity ? ustrip(kip, demand.Pu) : demand.Pu
    Mux = demand.Mux isa Unitful.Quantity ? ustrip(kip*u"ft", demand.Mux) : demand.Mux
    Muy = demand.Muy isa Unitful.Quantity ? ustrip(kip*u"ft", demand.Muy) : demand.Muy
    
    "No feasible RC sections: Pu=$(Pu) kip, Mux=$(Mux) kip-ft, Muy=$(Muy) kip-ft, " *
    "Lu=$(geometry.Lu) m, k=$(geometry.k)"
end

# ==============================================================================
# Objective Value for RC Columns (using existing Concrete type)
# ==============================================================================

"""
    objective_value(objective, section, material, length) -> value

Calculate objective function value for an RC column section.
"""
function objective_value(
    ::MinVolume,
    section::RCColumnSection,
    material::Concrete,
    length::Unitful.Length
)
    # Cross-sectional area
    Ag = section.b * section.h
    # Volume = area × length
    return uconvert(u"m^3", Ag * length)
end

function objective_value(
    ::MinWeight,
    section::RCColumnSection,
    material::Concrete,
    length::Unitful.Length
)
    # Cross-sectional area
    Ag = section.b * section.h
    # Weight = volume × density × gravity
    return uconvert(u"kN", Ag * length * material.ρ * 1u"gn")
end

function objective_value(
    ::MinCost,
    section::RCColumnSection,
    material::Concrete,
    length::Unitful.Length
)
    # Simplified cost: use volume as proxy
    # (more concrete & rebar = more cost)
    Ag = section.b * section.h
    return uconvert(u"m^3", Ag * length)
end

# Circular section objective values
function objective_value(
    ::MinVolume,
    section::RCCircularSection,
    material::Concrete,
    length::Unitful.Length
)
    # Volume = area × length
    return uconvert(u"m^3", section.Ag * length)
end

function objective_value(
    ::MinWeight,
    section::RCCircularSection,
    material::Concrete,
    length::Unitful.Length
)
    # Weight = volume × density × gravity
    return uconvert(u"kN", section.Ag * length * material.ρ * 1u"gn")
end

function objective_value(
    ::MinCost,
    section::RCCircularSection,
    material::Concrete,
    length::Unitful.Length
)
    # Simplified cost: use volume as proxy
    return uconvert(u"m^3", section.Ag * length)
end

# MinCarbon: Embodied carbon = mass × ECC (kgCO₂e/kg)
function objective_value(
    ::MinCarbon,
    section::RCColumnSection,
    material::Concrete,
    length::Unitful.Length
)
    Ag = section.b * section.h
    # Mass = volume × density, embodied carbon = mass × ecc
    volume = uconvert(u"m^3", Ag * length)
    mass_kg = ustrip(volume) * ustrip(u"kg/m^3", material.ρ)
    return mass_kg * material.ecc  # kgCO₂e
end

function objective_value(
    ::MinCarbon,
    section::RCCircularSection,
    material::Concrete,
    length::Unitful.Length
)
    volume = uconvert(u"m^3", section.Ag * length)
    mass_kg = ustrip(volume) * ustrip(u"kg/m^3", material.ρ)
    return mass_kg * material.ecc  # kgCO₂e
end

# ==============================================================================
# Legacy ACIChecker (for beams - stub)
# ==============================================================================

"""
    ACIChecker <: AbstractCapacityChecker

Legacy ACI checker stub for beams. Use ACIColumnChecker for columns.
"""
struct ACIChecker <: AbstractCapacityChecker
    exposure::Symbol
    sdc::Symbol
    deflection_limit::Union{Nothing, Float64}
    lightweight::Bool
    λ::Float64
end

function ACIChecker(;
    exposure = :moderate,
    sdc = :B,
    deflection_limit = nothing,
    lightweight = false
)
    λ = lightweight ? 0.75 : 1.0
    ACIChecker(exposure, sdc, deflection_limit, lightweight, λ)
end
