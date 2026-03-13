# ==============================================================================
# AISC Capacity Checker
# ==============================================================================
# Implements AbstractCapacityChecker for AISC 360 steel design.

"""
    AISCChecker <: AbstractCapacityChecker

AISC 360-16 capacity checker for steel members.

# Options
- `ϕ_b`: Resistance factor for flexure (default 0.9)
- `ϕ_c`: Resistance factor for compression (default 0.9)
- `ϕ_v`: Resistance factor for shear (default 1.0 for rolled shapes)
- `ϕ_t`: Resistance factor for tension (default 0.9)
- `deflection_limit`: Optional L/δ LL-only limit (e.g., 1/360)
- `total_deflection_limit`: Optional L/δ DL+LL limit (e.g., 1/240)
- `max_depth`: Maximum section depth constraint
- `prefer_penalty`: Penalty factor for non-preferred sections (default 1.0 = no penalty)

# Usage
```julia
checker = AISCChecker(; deflection_limit=1/360, total_deflection_limit=1/240)
feasible = is_feasible(checker, W("W14x22"), A992_Steel, demand, geometry)
```
"""
struct AISCChecker <: AbstractCapacityChecker
    ϕ_b::Float64
    ϕ_c::Float64
    ϕ_v::Float64
    ϕ_t::Float64
    deflection_limit::Union{Nothing, Float64}
    total_deflection_limit::Union{Nothing, Float64}
    max_depth::Float64  # meters, Inf for no limit
    prefer_penalty::Float64
end

function AISCChecker(;
    ϕ_b = 0.9,
    ϕ_c = 0.9,
    ϕ_v = 1.0,
    ϕ_t = 0.9,
    deflection_limit = nothing,
    total_deflection_limit = nothing,
    max_depth = Inf,
    prefer_penalty = 1.0
)
    max_d = to_meters(max_depth)
    AISCChecker(ϕ_b, ϕ_c, ϕ_v, ϕ_t, deflection_limit, total_deflection_limit, max_d, prefer_penalty)
end

# ==============================================================================
# Capacity Cache (for reusing expensive calculations)
# ==============================================================================

"""
    AISCCapacityCache <: AbstractCapacityCache

Caches length-dependent capacity calculations to avoid recomputation.
Specific to AISC steel design checks.
"""
mutable struct AISCCapacityCache <: AbstractCapacityCache
    ϕPn_strong::Dict{Tuple{Int, Int}, Float64}   # (section_idx, Lc_mm) → ϕPn
    ϕPn_weak::Dict{Tuple{Int, Int}, Float64}
    ϕPn_torsional::Dict{Tuple{Int, Int}, Float64}
    ϕMn_strong::Dict{Tuple{Int, Int, Int}, Float64}  # (section_idx, Lb_mm, Cb_100) → ϕMn
    # Precomputed length-independent values (per section index)
    ϕVn_strong::Vector{Float64}
    ϕVn_weak::Vector{Float64}
    ϕMn_weak::Vector{Float64}
    ϕPn_tension::Vector{Float64}
    Ix::Vector{Float64}
    depths::Vector{Float64}
    obj_coeffs::Vector{Float64}
end

function AISCCapacityCache(n_sections::Int)
    AISCCapacityCache(
        Dict{Tuple{Int, Int}, Float64}(),
        Dict{Tuple{Int, Int}, Float64}(),
        Dict{Tuple{Int, Int}, Float64}(),
        Dict{Tuple{Int, Int, Int}, Float64}(),
        zeros(n_sections),
        zeros(n_sections),
        zeros(n_sections),
        zeros(n_sections),
        zeros(n_sections),
        zeros(n_sections),
        zeros(n_sections)
    )
end

"""
    create_cache(checker::AISCChecker, n_sections) -> AISCCapacityCache

Create an AISC-specific capacity cache for `n_sections` sections.
"""
create_cache(::AISCChecker, n_sections::Int) = AISCCapacityCache(n_sections)

"""Round length to nearest mm for cache key."""
@inline _length_key(L_m::Float64)::Int = round(Int, L_m * 1000)

"""
Get the strong-axis moment of inertia used for deflection scaling.

Not all steel section types store this with the same field name:
- `ISymmSection` / `HSSRectSection`: `Ix`
- `HSSRoundSection`: `I` (since Ix=Iy)
"""
@inline _Ix_for_deflection(s::AbstractSection) = Ix(s)

# ==============================================================================
# Interface Implementation
# ==============================================================================

"""
    precompute_capacities!(checker::AISCChecker, cache, catalog, material, geometries)

Precompute length-independent capacities for all sections.
"""
function precompute_capacities!(
    checker::AISCChecker,
    cache::AISCCapacityCache,
    catalog::AbstractVector{<:AbstractSection},
    material::StructuralSteel,
    objective::AbstractObjective
)
    n = length(catalog)
    
    # Determine target unit for objective
    ref_obj = objective_value(objective, catalog[1], material, 1.0u"m")
    ref_unit = unit(ref_obj)
    
    # Thread-safe: each iteration writes to distinct cache indices
    Threads.@threads for j in 1:n
        s = catalog[j]
        
        # Shear capacities (length-independent for rolled I-shapes)
        cache.ϕVn_strong[j] = ustrip(u"N", get_ϕVn(s, material; axis=:strong, ϕ=checker.ϕ_v))
        cache.ϕVn_weak[j] = ustrip(u"N", get_ϕVn(s, material; axis=:weak, ϕ=checker.ϕ_v))
        
        # Weak-axis flexure (length-independent for I-shapes)
        cache.ϕMn_weak[j] = ustrip(u"N*m", get_ϕMn(s, material; axis=:weak, ϕ=checker.ϕ_b))
        
        # Tension capacity
        cache.ϕPn_tension[j] = ustrip(u"N", get_ϕPn_tension(s, material))
        
        # Geometric properties
        cache.Ix[j] = ustrip(u"m^4", _Ix_for_deflection(s))
        cache.depths[j] = ustrip(u"m", section_depth(s))
        
        # Objective coefficient (value per meter)
        val = objective_value(objective, s, material, 1.0u"m")
        if ref_unit != Unitful.NoUnits
            cache.obj_coeffs[j] = ustrip(ref_unit, val)
        else
            cache.obj_coeffs[j] = val
        end
        
        # Apply penalty to non-preferred sections
        if checker.prefer_penalty > 1.0 && !s.is_preferred
            cache.obj_coeffs[j] *= checker.prefer_penalty
        end
    end
end

"""
    _get_ϕPn_cached!(cache, axis, j, Lc_m, section, material) -> Float64

Get cached compression capacity or compute and cache.
"""
function _get_ϕPn_cached!(
    cache::AISCCapacityCache,
    axis::Symbol,
    j::Int,
    Lc_m::Float64,
    section::AbstractSection,
    material::StructuralSteel
)::Float64
    Lc_key = _length_key(Lc_m)
    dict = if axis === :strong
        cache.ϕPn_strong
    elseif axis === :weak
        cache.ϕPn_weak
    else
        cache.ϕPn_torsional
    end
    
    key = (j, Lc_key)
    val = get(dict, key, nothing)
    if isnothing(val)
        Lc = Lc_m * u"m"
        val = ustrip(u"N", get_ϕPn(section, material, Lc; axis=axis))
        dict[key] = val
    end
    return val
end

"""
    _get_ϕMnx_cached!(cache, j, Lb_m, Cb, section, material, ϕ_b) -> Float64

Get cached strong-axis flexural capacity or compute and cache.
"""
function _get_ϕMnx_cached!(
    cache::AISCCapacityCache,
    j::Int,
    Lb_m::Float64,
    Cb::Float64,
    section::AbstractSection,
    material::StructuralSteel,
    ϕ_b::Float64
)::Float64
    Lb_key = _length_key(Lb_m)
    Cb_key = round(Int, Cb * 100)
    key = (j, Lb_key, Cb_key)
    
    val = get(cache.ϕMn_strong, key, nothing)
    if isnothing(val)
        Lb = Lb_m * u"m"
        val = ustrip(u"N*m", get_ϕMn(section, material; Lb=Lb, Cb=Cb, axis=:strong, ϕ=ϕ_b))
        cache.ϕMn_strong[key] = val
    end
    return val
end

"""
    is_feasible(checker::AISCChecker, cache, j, section, material, demand, geometry) -> Bool

Check if an I-section satisfies AISC 360 requirements for the given demand.
Uses cached capacities where available.

Includes B1 moment amplification (P-δ effects) per AISC Appendix 8 when
compression exists. For sway frames (geometry.braced=false), B2 should be
applied externally to Mlt before creating the demand (not yet integrated).
"""
function is_feasible(
    checker::AISCChecker,
    cache::AISCCapacityCache,
    j::Int,  # Section index in catalog
    section::AbstractSection,
    material::StructuralSteel,
    demand::MemberDemand,
    geometry::SteelMemberGeometry
)::Bool
    # --- Composite branch: delegate to composite overload ---
    if !isnothing(demand.composite) && section isa ISymmSection
        return is_feasible(checker, cache, j, section, material, demand, geometry,
                           demand.composite)
    end

    # Extract demand values (SI: N, N·m)
    Pu_c = to_newtons(demand.Pu_c)
    Pu_t = to_newtons(demand.Pu_t)
    Mux = to_newton_meters(demand.Mux)
    Muy = to_newton_meters(demand.Muy)
    M1x = to_newton_meters(demand.M1x)
    M2x = to_newton_meters(demand.M2x)
    M1y = to_newton_meters(demand.M1y)
    M2y = to_newton_meters(demand.M2y)
    Vus = to_newtons(demand.Vu_strong)
    Vuw = to_newtons(demand.Vu_weak)
    δ_max_LL = to_meters(demand.δ_max_LL)
    δ_max_total = to_meters(demand.δ_max_total)
    I_ref = to_meters_fourth(demand.I_ref)

    L_m = to_meters(geometry.L)
    Lb_m = to_meters(geometry.Lb)
    
    if !geometry.braced
        @warn "Sway frame (braced=false) specified but B2 amplification not implemented. " *
              "Only B1 (P-δ) effects are applied. Results may be unconservative for sway frames." maxlog=1
    end
    
    # --- Depth Check ---
    cache.depths[j] <= checker.max_depth || return false
    
    # --- Shear Checks ---
    cache.ϕVn_strong[j] >= Vus || return false
    cache.ϕVn_weak[j] >= Vuw || return false
    
    # --- Strong-Axis Flexure (with LTB) ---
    ϕMnx = _get_ϕMnx_cached!(cache, j, Lb_m, geometry.Cb, section, material, checker.ϕ_b)
    
    # --- Compression Capacity ---
    Lc_x = geometry.Kx * L_m
    Lc_y = geometry.Ky * L_m
    ϕPn_x = _get_ϕPn_cached!(cache, :strong, j, Lc_x, section, material)
    ϕPn_y = _get_ϕPn_cached!(cache, :weak, j, Lc_y, section, material)
    ϕPn_z = _get_ϕPn_cached!(cache, :torsional, j, Lc_y, section, material)
    ϕPnc = min(ϕPn_x, ϕPn_y, ϕPn_z)
    
    # --- B1 Moment Amplification (P-δ effects, AISC Appendix 8) ---
    Mux_amp = Mux
    Muy_amp = Muy
    
    if Pu_c > 0.0
        E = to_pascals(material.E)
        Ix = cache.Ix[j]
        Iy = to_meters_fourth(StructuralSizer.Iy(section))
        
        Lc1_x = geometry.Kx * L_m
        Lc1_y = geometry.Ky * L_m
        
        (Lc1_x > 0 && Lc1_y > 0) || return false  # zero unbraced length → skip P-δ
        
        Pe1_x = π^2 * E * Ix / Lc1_x^2
        Pe1_y = π^2 * E * Iy / Lc1_y^2
        
        Cm_x = compute_Cm(M1x, M2x; transverse_loading=demand.transverse_load)
        Cm_y = compute_Cm(M1y, M2y; transverse_loading=demand.transverse_load)
        
        # AISC A-8-3, α=1.0 for LRFD
        B1_x = compute_B1(Pu_c, Pe1_x, Cm_x; α=1.0)
        B1_y = compute_B1(Pu_c, Pe1_y, Cm_y; α=1.0)
        
        if isinf(B1_x) || isinf(B1_y)
            return false
        end
        
        Mux_amp = B1_x * Mux
        Muy_amp = B1_y * Muy
    end
    
    # --- Interaction Check: Compression (with amplified moments) ---
    ur_c = check_PMxMy_interaction(Pu_c, Mux_amp, Muy_amp, ϕPnc, ϕMnx, cache.ϕMn_weak[j])
    ur_c <= 1.0 || return false
    
    # --- Interaction Check: Tension ---
    ur_t = check_PMxMy_interaction(Pu_t, Mux, Muy, cache.ϕPn_tension[j], ϕMnx, cache.ϕMn_weak[j])
    ur_t <= 1.0 || return false
    
    # --- LL Deflection Check (e.g. L/360) ---
    if !isnothing(checker.deflection_limit) && I_ref > 0 && δ_max_LL > 0
        δ_scaled = δ_max_LL * I_ref / cache.Ix[j]
        δ_ratio = δ_scaled / L_m
        δ_ratio <= checker.deflection_limit || return false
    end
    
    # --- Total Deflection Check (e.g. L/240) ---
    if !isnothing(checker.total_deflection_limit) && I_ref > 0 && δ_max_total > 0
        δ_scaled = δ_max_total * I_ref / cache.Ix[j]
        δ_ratio = δ_scaled / L_m
        δ_ratio <= checker.total_deflection_limit || return false
    end
    
    return true
end

"""
    get_objective_coeff(checker::AISCChecker, cache, j) -> Float64

Get the precomputed objective coefficient for section j.
"""
function get_objective_coeff(checker::AISCChecker, cache::AISCCapacityCache, j::Int)::Float64
    cache.obj_coeffs[j]
end

"""
    get_feasibility_error_msg(checker::AISCChecker, demand, geometry) -> String

Generate descriptive error message for infeasible groups.
"""
function get_feasibility_error_msg(
    checker::AISCChecker,
    demand::MemberDemand,
    geometry::SteelMemberGeometry
)
    Pu_c = to_newtons(demand.Pu_c)
    Pu_t = to_newtons(demand.Pu_t)
    Mux = to_newton_meters(demand.Mux)
    Muy = to_newton_meters(demand.Muy)
    Vus = to_newtons(demand.Vu_strong)
    Vuw = to_newtons(demand.Vu_weak)
    
    "No feasible sections: Pu_c=$(Pu_c) N, Pu_t=$(Pu_t) N, " *
    "Mux=$(Mux) N·m, Muy=$(Muy) N·m, " *
    "Vus=$(Vus) N, Vuw=$(Vuw) N, " *
    "L=$(geometry.L), Lb=$(geometry.Lb)"
end

# ==============================================================================
# Composite Beam Feasibility (AISC 360-16 Chapter I)
# ==============================================================================

"""
    is_feasible(checker, cache, j, section::ISymmSection, material, demand, geometry,
                ctx::CompositeContext) -> Bool

Composite-aware feasibility check. When `CompositeContext` is provided:

1. **Construction stage** (I3.1b): bare steel check with `Lb_const` (skipped if shored).
2. **Composite ϕMn** (I3.2a): replaces the bare-steel strong-axis flexural capacity
   using the plastic stress distribution PNA solver with full stud strength.
3. **Deflection** (Commentary I3.2): uses `I_LB` (partial composite) for live-load
   deflection instead of bare-steel `Ix`.
4. **Shear and weak-axis** checks remain the same as bare steel.

The compression/interaction checks (H1) use the **larger** of composite ϕMn and
bare-steel ϕMn, since composite action only helps flexure.
"""
function is_feasible(
    checker::AISCChecker,
    cache::AISCCapacityCache,
    j::Int,
    section::ISymmSection,
    material::StructuralSteel,
    demand::MemberDemand,
    geometry::SteelMemberGeometry,
    ctx::CompositeContext
)::Bool
    Mux = to_newton_meters(demand.Mux)
    Vus = to_newtons(demand.Vu_strong)
    Vuw = to_newtons(demand.Vu_weak)
    L_m = to_meters(geometry.L)

    # --- Depth Check ---
    cache.depths[j] <= checker.max_depth || return false

    # --- Shear Checks (steel section alone — AISC G) ---
    cache.ϕVn_strong[j] >= Vus || return false
    cache.ϕVn_weak[j] >= Vuw || return false

    # --- Construction Stage (I3.1b) — unshored only ---
    if !ctx.shored
        Lb_const_m = ustrip(u"m", ctx.Lb_const)
        ϕMn_const = _get_ϕMnx_cached!(cache, j, Lb_const_m, 1.0, section, material, checker.ϕ_b)
        ϕMn_const >= Mux || return false
    end

    # --- Composite Flexural Capacity (I3.2a) ---
    b_eff = get_b_eff(ctx.slab, ctx.L_beam)
    Qn = get_Qn(ctx.anchor, ctx.slab)

    # Full composite: ΣQn = n_studs × Qn per half-span (use Cf_max as upper bound)
    Cf_max = ustrip(u"N", _Cf_max(section, material, ctx.slab, b_eff))
    ΣQn_full = Cf_max * u"N"

    local ϕMn_comp::Float64
    try
        result = get_ϕMn_composite(section, material, ctx.slab, b_eff, ΣQn_full;
                                    ϕ=checker.ϕ_b)
        ϕMn_comp = ustrip(u"N*m", result.ϕMn)
    catch e
        @debug "Composite flexure check failed — section infeasible" exception=(e, catch_backtrace())
        return false
    end

    # Use the greater of composite and bare-steel capacity
    ϕMnx_steel = _get_ϕMnx_cached!(cache, j, to_meters(geometry.Lb), geometry.Cb,
                                     section, material, checker.ϕ_b)
    ϕMnx = max(ϕMn_comp, ϕMnx_steel)

    # Pure flexure check (beams typically have Pu ≈ 0)
    ϕMnx >= Mux || return false

    # --- Deflection Checks (Commentary I3.2) ---
    I_LB_m4 = ustrip(u"m^4", get_I_LB(section, material, ctx.slab, b_eff, ΣQn_full))
    I_steel_m4 = cache.Ix[j]
    δ_max_LL = to_meters(demand.δ_max_LL)
    δ_max_total = to_meters(demand.δ_max_total)
    I_ref = to_meters_fourth(demand.I_ref)

    # LL deflection check (e.g. L/360) — uses I_LB for composite
    if !isnothing(checker.deflection_limit) && I_ref > 0 && δ_max_LL > 0
        δ_scaled = δ_max_LL * I_ref / I_LB_m4
        δ_ratio = δ_scaled / L_m
        δ_ratio <= checker.deflection_limit || return false
    end

    # Total deflection check (e.g. L/240) — DL uses I_steel (unshored) or I_LB (shored)
    if !isnothing(checker.total_deflection_limit) && I_ref > 0 && δ_max_total > 0
        I_total_eff = ctx.shored ? I_LB_m4 : I_steel_m4
        δ_scaled = δ_max_total * I_ref / I_total_eff
        δ_ratio = δ_scaled / L_m
        δ_ratio <= checker.total_deflection_limit || return false
    end

    return true
end

# ==============================================================================
# Composite Objective: Add Stud Cost
# ==============================================================================

"""
    composite_stud_contribution(ctx::CompositeContext, section::ISymmSection,
                                 material::StructuralSteel, objective) -> Float64

Compute the stud contribution to the objective function for a composite beam.
Returns the additional objective value (weight in kg, or ECC in kgCO₂e, etc.)
from all studs on the beam.

Assumes full composite (conservative for stud count).
"""
function composite_stud_contribution(
    ctx::CompositeContext,
    section::ISymmSection,
    material::StructuralSteel,
    objective::AbstractObjective
)
    b_eff = get_b_eff(ctx.slab, ctx.L_beam)
    Qn = get_Qn(ctx.anchor, ctx.slab)
    ustrip(u"N", Qn) > 0 || error("Stud shear strength Qn is zero — check anchor/slab inputs")
    Cf_max = _Cf_max(section, material, ctx.slab, b_eff)

    n_studs_half = ceil(Int, ustrip(u"N", Cf_max) / ustrip(u"N", Qn))
    n_studs_total = 2 * n_studs_half  # both sides of max moment
    m_one = stud_mass(ctx.anchor)

    if objective isa MinWeight
        return ustrip(u"kg", m_one) * n_studs_total
    elseif objective isa MinCarbon
        return ustrip(u"kg", m_one) * n_studs_total * ctx.anchor.ecc
    else
        return 0.0
    end
end
