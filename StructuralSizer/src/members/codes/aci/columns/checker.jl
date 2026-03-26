# ==============================================================================
# ACI 318-11 Capacity Checker for RC Columns
# ==============================================================================
# Implements AbstractCapacityChecker for ACI 318 concrete column design.
# Matches the interface used by AISCChecker for MIP optimization.
#
# Uses unified material utilities from aci_material_utils.jl

using Asap: kip, ksi, to_ksi

"""
    ACIColumnChecker <: AbstractCapacityChecker

ACI 318-11 capacity checker for reinforced concrete columns.
Implements the same interface as AISCChecker for use with `optimize_discrete`.

# Options
- `include_slenderness`: Whether to consider slenderness effects (default true)
- `include_biaxial`: Whether to consider biaxial bending (default true)
- `α_biaxial`: Load contour exponent for biaxial check (default 1.5)
- `fy_ksi`: Rebar yield strength in ksi — from user's rebar material
- `Es_ksi`: Rebar elastic modulus in ksi — from user's rebar material
- `max_depth`: Maximum section depth constraint (meters, Inf = no limit)

# Strength Reduction Factors (computed per ACI §9.3.2)
- Tension-controlled (εt ≥ 0.005): φ = 0.90
- Compression-controlled (εt ≤ εy): φ = 0.65 (tied), 0.75 (spiral)
- Transition zone: linear interpolation

# Usage
```julia
checker = ACIColumnChecker(;
    fy_ksi = ustrip(ksi, rebar.Fy),
    Es_ksi = ustrip(ksi, rebar.E),
)
```
"""
struct ACIColumnChecker <: AbstractCapacityChecker
    include_slenderness::Bool
    include_biaxial::Bool
    α_biaxial::Float64
    fy_ksi::Float64         # Rebar yield strength (ksi)
    Es_ksi::Float64         # Rebar elastic modulus (ksi)
    max_depth::Float64      # meters
end

function ACIColumnChecker(;
    include_slenderness = true,
    include_biaxial = true,
    α_biaxial = 1.5,
    fy_ksi::Real,
    Es_ksi::Real,
    max_depth = Inf
)
    max_d = to_meters(max_depth)
    ACIColumnChecker(include_slenderness, include_biaxial, Float64(α_biaxial), Float64(fy_ksi), Float64(Es_ksi), max_d)
end

# ==============================================================================
# Capacity Cache
# ==============================================================================

"""Union type covering all `PMInteractionDiagram` parametrisations (rectangular or circular)."""
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
    εcu::Float64                            # Concrete ultimate strain
end

"""
    ACIColumnCapacityCache(n_sections::Int)

Construct a cache pre-sized for `n_sections` column section candidates.
"""
function ACIColumnCapacityCache(n_sections::Int)
    ACIColumnCapacityCache(
        Vector{PMDiagram}(undef, n_sections),
        Vector{Union{PMDiagram, Nothing}}(nothing, n_sections),  # Y-axis diagrams
        zeros(n_sections),
        zeros(n_sections),
        fill(true, n_sections),  # Default to square
        0.0,
        0.0,
        to_ksi(Rebar_60.E),  # Standard rebar Es from material type
        NWC_4000.εcu          # Default concrete ultimate strain
    )
end

"""
    create_cache(::ACIColumnChecker, n_sections::Int) -> ACIColumnCapacityCache

Allocate a fresh capacity cache for the ACI column checker with room for `n_sections` entries.
"""
create_cache(::ACIColumnChecker, n_sections::Int) = ACIColumnCapacityCache(n_sections)

# ==============================================================================
# Interface Implementation
# ==============================================================================

"""
    precompute_capacities!(checker, cache, catalog, material, objective)

Precompute P-M diagrams and objective coefficients for all sections.
Works with both rectangular (RCColumnSection) and circular (RCCircularSection) types.

# Material Support
- `Concrete`: Uses checker.fy_ksi for rebar strength
- `ReinforcedConcreteMaterial`: Uses embedded rebar properties
"""
function precompute_capacities!(
    checker::ACIColumnChecker,
    cache::ACIColumnCapacityCache,
    catalog::AbstractVector{<:AbstractSection},
    material::Concrete,
    objective::AbstractObjective
)
    n = length(catalog)
    
    # Extract material properties in ksi (ACI uses US units internally)
    cache.fc_ksi = fc_ksi(material)
    cache.fy_ksi = checker.fy_ksi   # From checker (user's rebar grade)
    cache.Es_ksi = checker.Es_ksi   # From checker (user's rebar grade)
    cache.εcu = material.εcu
    
    # Build material tuple for P-M functions
    mat = to_material_tuple(material, cache.fy_ksi, cache.Es_ksi)
    
    _precompute_diagrams!(checker, cache, catalog, material, mat, objective, n)
end

"""
    precompute_capacities!(checker, cache, catalog, material::ReinforcedConcreteMaterial, objective)

Overload that extracts rebar properties from the embedded `ReinforcedConcreteMaterial`.
"""
function precompute_capacities!(
    checker::ACIColumnChecker,
    cache::ACIColumnCapacityCache,
    catalog::AbstractVector{<:AbstractSection},
    material::ReinforcedConcreteMaterial,
    objective::AbstractObjective
)
    n = length(catalog)
    
    # Extract material properties from the RC material
    cache.fc_ksi = fc_ksi(material)
    cache.fy_ksi = fy_ksi(material)
    cache.Es_ksi = Es_ksi(material)
    cache.εcu = εcu(material)
    
    # Build material tuple from RC material
    mat = to_material_tuple(material)
    
    _precompute_diagrams!(checker, cache, catalog, material.concrete, mat, objective, n)
end

"""
    _precompute_diagrams!(checker, cache, catalog, concrete, mat, objective, n)

Internal helper shared by both `Concrete` and `ReinforcedConcreteMaterial` overloads.
Generates P-M diagrams, y-axis diagrams (when biaxial is enabled), and objective
coefficients for all `n` sections in `catalog`. Thread-parallelised.
"""
function _precompute_diagrams!(
    checker::ACIColumnChecker,
    cache::ACIColumnCapacityCache,
    catalog::AbstractVector{<:AbstractSection},
    concrete::Concrete,  # For objective_value (needs Concrete, not tuple)
    mat::NamedTuple,     # For P-M calculations
    objective::AbstractObjective,
    n::Int
)
    # Determine target unit for objective
    ref_obj = objective_value(objective, catalog[1], concrete, 1.0u"m")
    ref_unit = unit(ref_obj)
    
    # Thread-safe: each iteration writes to distinct cache indices (no cross-deps)
    Threads.@threads for j in 1:n
        section = catalog[j]
        
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
            cache.obj_coeffs[j] = ustrip(ref_unit, val)
        else
            cache.obj_coeffs[j] = val
        end
    end
end

"""
    _check_square_and_generate_y_diagram(section::RCColumnSection, mat, include_biaxial) -> Tuple{Bool, Union{PMDiagram, Nothing}}

Return `(is_square, diagram_y)`. For non-square rectangular sections with biaxial
enabled, a weak-axis P-M diagram is generated; otherwise `nothing`.
"""
function _check_square_and_generate_y_diagram(section::RCColumnSection, mat, include_biaxial::Bool)
    b = ustrip(u"inch", section.b)
    h = ustrip(u"inch", section.h)
    
    (b > 0 && h > 0) || throw(ArgumentError("Column dimensions b=$b and h=$h must both be positive"))
    is_square = abs(b - h) / max(b, h) < 0.05
    
    # Generate y-axis diagram for rectangular sections if biaxial is enabled
    diagram_y = if !is_square && include_biaxial
        generate_PM_diagram(section, mat, WeakAxis(); n_intermediate=15)
    else
        nothing
    end
    
    return is_square, diagram_y
end

"""Circular sections are axisymmetric; always returns `(true, nothing)`."""
function _check_square_and_generate_y_diagram(section::RCCircularSection, mat, include_biaxial::Bool)
    return true, nothing
end

"""Return section depth in metres (h for rectangular)."""
_section_depth_m(section::RCColumnSection) = ustrip(u"m", section.h)

"""Return section depth in metres (D for circular)."""
_section_depth_m(section::RCCircularSection) = ustrip(u"m", section.D)

"""
    is_feasible(checker::ACIColumnChecker, cache, j, section::RCColumnSection, material, demand, geometry) -> Bool

Check if a rectangular RC column section satisfies ACI 318 requirements.

Checks:
1. Depth constraint
2. Uniaxial P-M interaction (with slenderness magnification if enabled)
3. Biaxial interaction (if enabled and Muy > 0)

Delegates to [`_is_feasible_rc_column`](@ref).
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

"""
    is_feasible(checker::ACIColumnChecker, cache, j, section::RCCircularSection, material, demand, geometry) -> Bool

Dispatch for circular sections — delegates to [`_is_feasible_rc_column`](@ref).
"""
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

"""
    _is_feasible_rc_column(checker, cache, j, section, material, demand, geometry) -> Bool

Shared implementation for rectangular and circular columns. Checks:
1. Depth constraint against `checker.max_depth`.
2. Slenderness-magnified uniaxial P-M interaction (x-axis).
3. Bresler load-contour biaxial interaction (if enabled and Muy > 0).
"""
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
    Pu = to_kip(demand.Pu)
    Mux = to_kipft(demand.Mux)
    Muy = to_kipft(demand.Muy)
    βdns = Float64(demand.βdns)
    
    # --- Depth Check ---
    cache.depths[j] <= checker.max_depth || return false
    
    # --- Slenderness Effects ---
    if checker.include_slenderness
        # Create material tuple for slenderness functions
        mat = (fc = cache.fc_ksi, fy = cache.fy_ksi, Es = cache.Es_ksi, εcu = cache.εcu)
        
        # Extract end moments (M1 = smaller, M2 = larger) for proper Cm calculation
        M1x = to_kipft(demand.M1x)
        M2x = to_kipft(demand.M2x)
        M1y = to_kipft(demand.M1y)
        M2y = to_kipft(demand.M2y)
        
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

"""
    get_objective_coeff(checker::ACIColumnChecker, cache::ACIColumnCapacityCache, j::Int) -> Float64

Return the precomputed per-metre objective coefficient for section index `j`.
"""
function get_objective_coeff(checker::ACIColumnChecker, cache::ACIColumnCapacityCache, j::Int)::Float64
    cache.obj_coeffs[j]
end

"""
    get_feasibility_error_msg(checker::ACIColumnChecker, demand, geometry) -> String

Generate a human-readable message describing why no section in the catalog satisfied the demand.
"""
function get_feasibility_error_msg(
    checker::ACIColumnChecker,
    demand::RCColumnDemand,
    geometry::ConcreteMemberGeometry
)
    Pu = to_kip(demand.Pu)
    Mux = to_kipft(demand.Mux)
    Muy = to_kipft(demand.Muy)
    
    "No feasible RC sections: Pu=$(Pu) kip, Mux=$(Mux) kip·ft, Muy=$(Muy) kip·ft, " *
    "Lu=$(geometry.Lu), k=$(geometry.k)"
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
    length::Length
)
    # Cross-sectional area
    Ag = section.b * section.h
    # Volume = area × length
    return uconvert(u"m^3", Ag * length)
end

"""Minimum-weight objective for a rectangular RC column (kg)."""
function objective_value(
    ::MinWeight,
    section::RCColumnSection,
    material::Concrete,
    length::Length
)
    Ag = section.b * section.h
    return uconvert(u"kg", Ag * length * material.ρ)
end

"""Minimum-cost objective for a rectangular RC column (m³ volume proxy)."""
function objective_value(
    ::MinCost,
    section::RCColumnSection,
    material::Concrete,
    length::Length
)
    Ag = section.b * section.h
    return uconvert(u"m^3", Ag * length)
end

"""Minimum-volume objective for a circular RC column (m³)."""
function objective_value(
    ::MinVolume,
    section::RCCircularSection,
    material::Concrete,
    length::Length
)
    return uconvert(u"m^3", section.Ag * length)
end

"""Minimum-weight objective for a circular RC column (kg)."""
function objective_value(
    ::MinWeight,
    section::RCCircularSection,
    material::Concrete,
    length::Length
)
    return uconvert(u"kg", section.Ag * length * material.ρ)
end

"""Minimum-cost objective for a circular RC column (m³ volume proxy)."""
function objective_value(
    ::MinCost,
    section::RCCircularSection,
    material::Concrete,
    length::Length
)
    return uconvert(u"m^3", section.Ag * length)
end

"""Minimum-carbon objective for a rectangular RC column (kgCO₂e)."""
function objective_value(
    ::MinCarbon,
    section::RCColumnSection,
    material::Concrete,
    length::Length
)
    Ag = section.b * section.h
    volume = uconvert(u"m^3", Ag * length)
    mass_kg = ustrip(volume) * ustrip(u"kg/m^3", material.ρ)
    return mass_kg * material.ecc  # kgCO₂e
end

"""Minimum-carbon objective for a circular RC column (kgCO₂e)."""
function objective_value(
    ::MinCarbon,
    section::RCCircularSection,
    material::Concrete,
    length::Length
)
    volume = uconvert(u"m^3", section.Ag * length)
    mass_kg = ustrip(volume) * ustrip(u"kg/m^3", material.ρ)
    return mass_kg * material.ecc  # kgCO₂e
end

# ==============================================================================
# Feasibility Explanation (Solver Trace)
# ==============================================================================

"""
    explain_feasibility(checker::ACIColumnChecker, cache, j, section, material, demand, geometry)

Evaluate ALL ACI 318 column checks without short-circuiting and return per-check
demand/capacity ratios. Mirrors `_is_feasible_rc_column` exactly but collects
every intermediate result.
"""
function explain_feasibility(
    checker::ACIColumnChecker,
    cache::ACIColumnCapacityCache,
    j::Int,
    section::Union{RCColumnSection, RCCircularSection},
    material::Concrete,
    demand::RCColumnDemand,
    geometry::ConcreteMemberGeometry
)::FeasibilityExplanation
    checks = CheckResult[]

    Pu = to_kip(demand.Pu)
    Mux = to_kipft(demand.Mux)
    Muy = to_kipft(demand.Muy)
    βdns = Float64(demand.βdns)

    # --- Depth Check ---
    d_section = cache.depths[j]
    d_limit = checker.max_depth
    d_ratio = d_limit > 0 ? d_section / d_limit : 0.0
    push!(checks, CheckResult("depth", d_section <= d_limit,
          d_ratio, d_section, d_limit, ""))

    # --- Slenderness Effects — ACI 318-19 §6.6.4 ---
    if checker.include_slenderness
        mat = (fc = cache.fc_ksi, fy = cache.fy_ksi, Es = cache.Es_ksi, εcu = cache.εcu)
        M1x = to_kipft(demand.M1x)
        M2x = to_kipft(demand.M2x)
        M1y = to_kipft(demand.M1y)
        M2y = to_kipft(demand.M2y)

        result_x = magnify_moment_nonsway(section, mat, geometry, Pu, M1x, M2x; βdns=βdns)
        Mux = result_x.Mc

        if Muy > 0 && checker.include_biaxial
            result_y = magnify_moment_nonsway(section, mat, geometry, Pu, M1y, M2y; βdns=βdns)
            Muy = result_y.Mc
        end

        # Report slenderness amplification ratio (Mc/M2)
        slend_ratio = M2x > 0 ? Mux / M2x : 1.0
        push!(checks, CheckResult("slenderness_magnification", true,
              slend_ratio, Mux, M2x > 0 ? M2x : Mux, "ACI 318-19 6.6.4"))
    end

    # --- Uniaxial P-M Check (x-axis) — ACI 318-19 §22.4 ---
    diagram = cache.diagrams[j]
    check_x = check_PM_capacity(diagram, Pu, Mux)
    pm_ratio_x = check_x.adequate ? (check_x.φMn_at_Pu > 0 ? Mux / check_x.φMn_at_Pu : 0.0) : Inf
    push!(checks, CheckResult("pm_interaction_x", check_x.adequate,
          pm_ratio_x, Mux, check_x.φMn_at_Pu, "ACI 318-19 22.4"))

    # --- Biaxial Check — ACI 318-19 via Bresler Load Contour ---
    if checker.include_biaxial && Muy > 0
        φMnx = check_x.φMn_at_Pu

        φMny = if cache.is_square[j] || isnothing(cache.diagrams_y[j])
            φMnx
        else
            check_y = check_PM_capacity(cache.diagrams_y[j], Pu, Muy)
            if !check_y.adequate
                push!(checks, CheckResult("pm_interaction_y", false,
                      Inf, Muy, 0.0, "ACI 318-19 22.4"))
            end
            check_y.φMn_at_Pu
        end

        if φMnx > 0 && φMny > 0
            util_biaxial = bresler_load_contour(Mux, Muy, φMnx, φMny; α=checker.α_biaxial)
            push!(checks, CheckResult("biaxial_bresler", util_biaxial <= 1.0,
                  util_biaxial, max(Mux, Muy), 1.0, "ACI 318-19 R22.4 / Bresler"))
        else
            push!(checks, CheckResult("biaxial_bresler", false,
                  Inf, max(Mux, Muy), 0.0, "ACI 318-19 R22.4 / Bresler"))
        end
    end

    # --- Aggregate ---
    all_pass = all(c -> c.passed, checks)
    gov_idx = argmax([c.ratio for c in checks])
    gov = checks[gov_idx]

    FeasibilityExplanation(all_pass, checks, gov.name, gov.ratio)
end

