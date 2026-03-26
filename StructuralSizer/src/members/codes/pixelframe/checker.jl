# ==============================================================================
# PixelFrame Capacity Checker
# ==============================================================================
# Implements AbstractCapacityChecker for PixelFrame sections.
# Uses ACI 318-19 for axial and flexural capacity, fib MC2010 for FRC shear.
#
# Unlike ACI/AISC checkers, the material is embedded in the section itself
# (each PixelFrameSection carries its own FRC). The `material` argument in
# the interface is accepted but not used for capacity calculations.
#
# Minimum bounding box constraint:
#   When `min_depth_mm` or `min_width_mm` > 0, sections whose bounding box
#   (from CompoundSection ymax−ymin / xmax−xmin) is smaller are rejected.
#   This supports punching-shear-driven column sizing: the flat plate
#   pipeline computes the required column dimension from punching, then
#   re-calls size_columns with the minimum set to (failed_size + increment).
#
# Cache units: N, N·m (consistent with AISC checker convention).
# Demands: converted via to_newtons / to_newton_meters at the boundary.
# ==============================================================================

using Unitful

# ==============================================================================
# Checker Type
# ==============================================================================

"""
    PixelFrameChecker <: AbstractCapacityChecker

Capacity checker for PixelFrame sections.

Uses ACI 318-19 §22.4 for axial and flexural capacity, and
fib MC2010 §7.7-5 for FRC shear capacity.

# Fields
- `E_s_MPa`: Tendon elastic modulus in MPa (default 200_000)
- `f_py_MPa`: Tendon yield strength in MPa (default 1860)
- `γ_c`: fib partial safety factor for concrete (default 1.0)
- `min_depth_mm`: Minimum section bounding-box depth [mm] (default 0 = no limit)
- `min_width_mm`: Minimum section bounding-box width [mm] (default 0 = no limit)

# Minimum bounding box
Set `min_depth_mm` / `min_width_mm` to enforce a minimum section size.
This is used by the flat plate pipeline to grow PixelFrame columns for
punching shear: if a section fails punching, set the minimum to the
failed section's dimension + increment, then re-run `size_columns`.
The optimizer will then select the smallest feasible section that meets
both capacity AND bounding-box requirements, with optimal material grade.

# Usage
```julia
checker = PixelFrameChecker()
catalog = generate_pixelframe_catalog(...)
result = optimize_discrete(checker, demands, geometries, catalog, frc_material)

# After punching failure — require larger section
checker2 = PixelFrameChecker(min_depth_mm=280.0, min_width_mm=280.0)
result2 = optimize_discrete(checker2, demands, geometries, catalog, frc_material)
```
"""
struct PixelFrameChecker <: AbstractCapacityChecker
    E_s_MPa::Float64
    f_py_MPa::Float64
    γ_c::Float64
    min_depth_mm::Float64
    min_width_mm::Float64
end

"""
    PixelFrameChecker(; E_s_MPa=200_000, f_py_MPa=1860, γ_c=1.0, min_depth_mm=0, min_width_mm=0)

Keyword constructor for [`PixelFrameChecker`](@ref) with typical defaults.
"""
function PixelFrameChecker(;
    E_s_MPa::Real = 200_000.0,
    f_py_MPa::Real = 1860.0,
    γ_c::Real = 1.0,
    min_depth_mm::Real = 0.0,
    min_width_mm::Real = 0.0,
)
    PixelFrameChecker(Float64(E_s_MPa), Float64(f_py_MPa), Float64(γ_c),
                      Float64(min_depth_mm), Float64(min_width_mm))
end

# ==============================================================================
# Capacity Cache
# ==============================================================================

"""
    PixelFrameCapacityCache <: AbstractCapacityCache

Caches precomputed capacities, bounding-box dimensions, and objective
coefficients for PixelFrame sections.

All capacity values stored in N / N·m (consistent with AISC checker convention).
Bounding-box dimensions stored in mm for the minimum-size feasibility check.
"""
mutable struct PixelFrameCapacityCache <: AbstractCapacityCache
    Pu::Vector{Float64}         # Design axial capacity [N]
    Mu::Vector{Float64}         # Design flexural capacity [N·m]
    Vu::Vector{Float64}         # Design shear capacity [N]
    depth_mm::Vector{Float64}   # Section bounding-box depth [mm]
    width_mm::Vector{Float64}   # Section bounding-box width [mm]
    obj_coeffs::Vector{Float64} # Objective coefficients per section
end

"""
    PixelFrameCapacityCache(n_sections::Int)

Allocate a zero-initialized cache for `n_sections` PixelFrame catalog entries.
"""
function PixelFrameCapacityCache(n_sections::Int)
    PixelFrameCapacityCache(
        zeros(n_sections),
        zeros(n_sections),
        zeros(n_sections),
        zeros(n_sections),
        zeros(n_sections),
        zeros(n_sections),
    )
end

"""Create a [`PixelFrameCapacityCache`](@ref) sized for `n_sections` catalog entries."""
create_cache(::PixelFrameChecker, n_sections::Int) = PixelFrameCapacityCache(n_sections)

# ==============================================================================
# Interface: precompute_capacities!
# ==============================================================================

"""
    precompute_capacities!(checker, cache, catalog, material, objective)

Populate `cache` with axial (ACI 318-19 §22.4), flexural (ACI 318-19 §22.4.1.2),
shear (fib MC2010 §7.7-5), bounding-box, and objective values for every section
in `catalog`. Runs multi-threaded.
"""
function precompute_capacities!(
    checker::PixelFrameChecker,
    cache::PixelFrameCapacityCache,
    catalog::AbstractVector{<:PixelFrameSection},
    material::AbstractMaterial,
    objective::AbstractObjective,
)
    n = length(catalog)
    n == 0 && return
    E_s = checker.E_s_MPa * u"MPa"
    f_py = checker.f_py_MPa * u"MPa"

    # Determine objective unit from first section
    ref_obj = objective_value(objective, catalog[1], material, 1.0u"m")
    ref_unit = ref_obj isa Unitful.Quantity ? unit(ref_obj) : Unitful.NoUnits

    Threads.@threads for j in 1:n
        sec = catalog[j]

        # Axial capacity (ACI 318-19 §22.4.2.3)
        ax = pf_axial_capacity(sec; E_s=E_s)
        cache.Pu[j] = ustrip(u"N", ax.Pu)

        # Flexural capacity (ACI 318-19 §22.4.1.2)
        fl = pf_flexural_capacity(sec; E_s=E_s, f_py=f_py)
        cache.Mu[j] = ustrip(u"N*m", fl.Mu)

        # Shear capacity (fib MC2010 §7.7-5)
        Vu = frc_shear_capacity(sec; E_s=E_s, γ_c=checker.γ_c)
        cache.Vu[j] = ustrip(u"N", Vu)

        # Bounding box from polygon geometry (mm)
        cs = sec.section
        cache.depth_mm[j] = cs.ymax - cs.ymin
        cache.width_mm[j] = cs.xmax - cs.xmin

        # Objective coefficient (value per meter of element)
        val = objective_value(objective, sec, material, 1.0u"m")
        cache.obj_coeffs[j] = ref_unit != Unitful.NoUnits ? ustrip(ref_unit, val) : Float64(val)
    end
end

# ==============================================================================
# Interface: is_feasible
# ==============================================================================

"""
    is_feasible(checker, cache, j, section, material, demand, geometry) -> Bool

Check if a PixelFrame section satisfies all requirements:
1. Bounding box: depth ≥ min_depth_mm, width ≥ min_width_mm
2. Axial: Pu_capacity ≥ Pu_demand
3. Flexure: Mu_capacity ≥ Mu_demand
4. Shear: Vu_capacity ≥ Vu_demand

The bounding-box check (1) is evaluated first as a cheap geometric filter.
This supports punching-shear-driven column growth: set `min_depth_mm` /
`min_width_mm` on the checker to the failed section's size + increment.

Demands are extracted from `MemberDemand` and converted to N / N·m
via `to_newtons` / `to_newton_meters` (handles both Unitful and bare Real).
"""
function is_feasible(
    checker::PixelFrameChecker,
    cache::PixelFrameCapacityCache,
    j::Int,
    section::PixelFrameSection,
    material::AbstractMaterial,
    demand::MemberDemand,
    geometry::AbstractMemberGeometry,
)::Bool
    # Bounding-box check (punching shear / minimum size constraint)
    cache.depth_mm[j] ≥ checker.min_depth_mm || return false
    cache.width_mm[j] ≥ checker.min_width_mm || return false

    # Capacity checks
    Pu_dem = to_newtons(demand.Pu_c)
    Mu_dem = to_newton_meters(demand.Mux)
    Vu_dem = to_newtons(demand.Vu_strong)

    cache.Pu[j] ≥ Pu_dem || return false
    cache.Mu[j] ≥ Mu_dem || return false
    cache.Vu[j] ≥ Vu_dem || return false
    return true
end

# ==============================================================================
# Interface: get_objective_coeff
# ==============================================================================

"""Return the precomputed objective coefficient for section index `j`."""
function get_objective_coeff(
    checker::PixelFrameChecker,
    cache::PixelFrameCapacityCache,
    j::Int,
)::Float64
    cache.obj_coeffs[j]
end

# ==============================================================================
# Interface: error message
# ==============================================================================

"""Format a human-readable error message when no feasible PixelFrame section exists for `demand`."""
function get_feasibility_error_msg(
    checker::PixelFrameChecker,
    demand::MemberDemand,
    geometry::AbstractMemberGeometry,
)
    Pu = to_newtons(demand.Pu_c)
    Mu = to_newton_meters(demand.Mux)
    Vu = to_newtons(demand.Vu_strong)
    msg = "No feasible PixelFrame section: Pu=$(round(Pu/1e3, digits=1)) kN, " *
          "Mu=$(round(Mu/1e3, digits=1)) kN·m, Vu=$(round(Vu/1e3, digits=1)) kN"
    if checker.min_depth_mm > 0 || checker.min_width_mm > 0
        msg *= " (min bbox: $(checker.min_depth_mm)×$(checker.min_width_mm) mm)"
    end
    msg
end

# ==============================================================================
# Feasibility Explanation (Solver Trace)
# ==============================================================================

"""
    explain_feasibility(checker::PixelFrameChecker, cache, j, section, material, demand, geometry)

Evaluate all PixelFrame capacity filters without short-circuiting and return per-check
demand/capacity ratios. Mirrors `is_feasible` exactly but collects every intermediate result.

Checks are reported in SI units (N, N·m, m) to match the trace contract in
`StructuralSizer/src/optimize/core/interface.jl`.
"""
function explain_feasibility(
    checker::PixelFrameChecker,
    cache::PixelFrameCapacityCache,
    j::Int,
    section::PixelFrameSection,
    material::AbstractMaterial,
    demand::MemberDemand,
    geometry::AbstractMemberGeometry,
)::FeasibilityExplanation
    checks = CheckResult[]

    # --- 1. Bounding box minimums (meters) ---
    depth_m = cache.depth_mm[j] / 1000.0
    width_m = cache.width_mm[j] / 1000.0
    min_depth_m = checker.min_depth_mm / 1000.0
    min_width_m = checker.min_width_mm / 1000.0

    depth_ratio = depth_m > 0 ? min_depth_m / depth_m : (min_depth_m > 0 ? Inf : 0.0)
    width_ratio = width_m > 0 ? min_width_m / width_m : (min_width_m > 0 ? Inf : 0.0)

    push!(checks, CheckResult(
        "min_depth",
        depth_m ≥ min_depth_m,
        depth_ratio,
        min_depth_m,
        depth_m,
        "",
    ))
    push!(checks, CheckResult(
        "min_width",
        width_m ≥ min_width_m,
        width_ratio,
        min_width_m,
        width_m,
        "",
    ))

    # --- 2. Axial (ACI 318-19 §22.4.2.3) ---
    Pu_dem = to_newtons(demand.Pu_c)
    Pu_cap = cache.Pu[j]
    Pu_ratio = Pu_cap > 0 ? Pu_dem / Pu_cap : (Pu_dem > 0 ? Inf : 0.0)
    push!(checks, CheckResult(
        "axial",
        Pu_cap ≥ Pu_dem,
        Pu_ratio,
        Pu_dem,
        Pu_cap,
        "ACI 318-19 22.4.2.3",
    ))

    # --- 3. Flexure (ACI 318-19 §22.4.1.2) ---
    Mu_dem = to_newton_meters(demand.Mux)
    Mu_cap = cache.Mu[j]
    Mu_ratio = Mu_cap > 0 ? Mu_dem / Mu_cap : (Mu_dem > 0 ? Inf : 0.0)
    push!(checks, CheckResult(
        "flexure",
        Mu_cap ≥ Mu_dem,
        Mu_ratio,
        Mu_dem,
        Mu_cap,
        "ACI 318-19 22.4.1.2",
    ))

    # --- 4. Shear (fib MC2010 §7.7-5) ---
    Vu_dem = to_newtons(demand.Vu_strong)
    Vu_cap = cache.Vu[j]
    Vu_ratio = Vu_cap > 0 ? Vu_dem / Vu_cap : (Vu_dem > 0 ? Inf : 0.0)
    push!(checks, CheckResult(
        "shear",
        Vu_cap ≥ Vu_dem,
        Vu_ratio,
        Vu_dem,
        Vu_cap,
        "fib MC2010 7.7-5",
    ))

    all_pass = all(c -> c.passed, checks)
    ratios = [c.ratio for c in checks]
    gov_idx = argmax(ratios)
    gov = checks[gov_idx]

    FeasibilityExplanation(all_pass, checks, gov.name, gov.ratio)
end
