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
- `deflection_limit`: Optional L/δ limit (e.g., 1/360)
- `max_depth`: Maximum section depth constraint
- `prefer_penalty`: Penalty factor for non-preferred sections (default 1.0 = no penalty)

# Usage
```julia
checker = AISCChecker(; deflection_limit=1/360, prefer_penalty=1.05)
feasible = is_feasible(checker, W("W14x22"), A992_Steel, demand, geometry)
```
"""
struct AISCChecker <: AbstractCapacityChecker
    ϕ_b::Float64
    ϕ_c::Float64
    ϕ_v::Float64
    ϕ_t::Float64
    deflection_limit::Union{Nothing, Float64}
    max_depth::Float64  # meters, Inf for no limit
    prefer_penalty::Float64
end

function AISCChecker(;
    ϕ_b = 0.9,
    ϕ_c = 0.9,
    ϕ_v = 1.0,
    ϕ_t = 0.9,
    deflection_limit = nothing,
    max_depth = Inf,
    prefer_penalty = 1.0
)
    max_d = max_depth isa Unitful.Quantity ? ustrip(uconvert(u"m", max_depth)) : Float64(max_depth)
    AISCChecker(ϕ_b, ϕ_c, ϕ_v, ϕ_t, deflection_limit, max_d, prefer_penalty)
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

# ==============================================================================
# Interface Implementation
# ==============================================================================

"""
    precompute_capacities!(checker::AISCChecker, cache, catalogue, material, geometries)

Precompute length-independent capacities for all sections.
"""
function precompute_capacities!(
    checker::AISCChecker,
    cache::AISCCapacityCache,
    catalogue::AbstractVector{<:ISymmSection},
    material::StructuralSteel,
    objective::AbstractObjective
)
    n = length(catalogue)
    
    # Determine target unit for objective
    ref_obj = objective_value(objective, catalogue[1], material, 1.0u"m")
    ref_unit = ref_obj isa Unitful.Quantity ? unit(ref_obj) : Unitful.NoUnits
    
    for j in 1:n
        s = catalogue[j]
        
        # Shear capacities (length-independent for rolled I-shapes)
        cache.ϕVn_strong[j] = ustrip(uconvert(u"N", get_ϕVn(s, material; axis=:strong, ϕ=checker.ϕ_v)))
        cache.ϕVn_weak[j] = ustrip(uconvert(u"N", get_ϕVn(s, material; axis=:weak, ϕ=checker.ϕ_v)))
        
        # Weak-axis flexure (length-independent for I-shapes)
        cache.ϕMn_weak[j] = ustrip(uconvert(u"N*m", get_ϕMn(s, material; axis=:weak, ϕ=checker.ϕ_b)))
        
        # Tension capacity
        cache.ϕPn_tension[j] = ustrip(uconvert(u"N", get_ϕPn_tension(s, material)))
        
        # Geometric properties
        cache.Ix[j] = ustrip(uconvert(u"m^4", s.Ix))
        cache.depths[j] = ustrip(uconvert(u"m", depth(s)))
        
        # Objective coefficient (value per meter)
        val = objective_value(objective, s, material, 1.0u"m")
        if ref_unit != Unitful.NoUnits
            cache.obj_coeffs[j] = ustrip(uconvert(ref_unit, val))
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
    section::ISymmSection,
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
        val = ustrip(uconvert(u"N", get_ϕPn(section, material, Lc; axis=axis)))
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
    section::ISymmSection,
    material::StructuralSteel,
    ϕ_b::Float64
)::Float64
    Lb_key = _length_key(Lb_m)
    Cb_key = round(Int, Cb * 100)
    key = (j, Lb_key, Cb_key)
    
    val = get(cache.ϕMn_strong, key, nothing)
    if isnothing(val)
        Lb = Lb_m * u"m"
        val = ustrip(uconvert(u"N*m", get_ϕMn(section, material; Lb=Lb, Cb=Cb, axis=:strong, ϕ=ϕ_b)))
        cache.ϕMn_strong[key] = val
    end
    return val
end

"""
    is_feasible(checker::AISCChecker, cache, j, section, material, demand, geometry) -> Bool

Check if an I-section satisfies AISC 360 requirements for the given demand.
Uses cached capacities where available.
"""
function is_feasible(
    checker::AISCChecker,
    cache::AISCCapacityCache,
    j::Int,  # Section index in catalogue
    section::ISymmSection,
    material::StructuralSteel,
    demand::MemberDemand,
    geometry::SteelMemberGeometry
)::Bool
    # Extract demand values (SI: N, N*m)
    Pu_c = demand.Pu_c isa Unitful.Quantity ? ustrip(uconvert(u"N", demand.Pu_c)) : Float64(demand.Pu_c)
    Pu_t = demand.Pu_t isa Unitful.Quantity ? ustrip(uconvert(u"N", demand.Pu_t)) : Float64(demand.Pu_t)
    Mux = demand.Mux isa Unitful.Quantity ? ustrip(uconvert(u"N*m", demand.Mux)) : Float64(demand.Mux)
    Muy = demand.Muy isa Unitful.Quantity ? ustrip(uconvert(u"N*m", demand.Muy)) : Float64(demand.Muy)
    Vus = demand.Vu_strong isa Unitful.Quantity ? ustrip(uconvert(u"N", demand.Vu_strong)) : Float64(demand.Vu_strong)
    Vuw = demand.Vu_weak isa Unitful.Quantity ? ustrip(uconvert(u"N", demand.Vu_weak)) : Float64(demand.Vu_weak)
    δ_max = demand.δ_max isa Unitful.Quantity ? ustrip(uconvert(u"m", demand.δ_max)) : Float64(demand.δ_max)
    I_ref = demand.I_ref isa Unitful.Quantity ? ustrip(uconvert(u"m^4", demand.I_ref)) : Float64(demand.I_ref)
    
    # --- Depth Check ---
    cache.depths[j] <= checker.max_depth || return false
    
    # --- Shear Checks ---
    cache.ϕVn_strong[j] >= Vus || return false
    cache.ϕVn_weak[j] >= Vuw || return false
    
    # --- Strong-Axis Flexure (with LTB) ---
    ϕMnx = _get_ϕMnx_cached!(cache, j, geometry.Lb, geometry.Cb, section, material, checker.ϕ_b)
    
    # --- Compression Capacity ---
    Lc_x = geometry.Kx * geometry.L
    Lc_y = geometry.Ky * geometry.L
    ϕPn_x = _get_ϕPn_cached!(cache, :strong, j, Lc_x, section, material)
    ϕPn_y = _get_ϕPn_cached!(cache, :weak, j, Lc_y, section, material)
    ϕPn_z = _get_ϕPn_cached!(cache, :torsional, j, Lc_y, section, material)
    ϕPnc = min(ϕPn_x, ϕPn_y, ϕPn_z)
    
    # --- Interaction Check: Compression ---
    ur_c = check_PMxMy_interaction(Pu_c, Mux, Muy, ϕPnc, ϕMnx, cache.ϕMn_weak[j])
    ur_c <= 1.0 || return false
    
    # --- Interaction Check: Tension ---
    ur_t = check_PMxMy_interaction(Pu_t, Mux, Muy, cache.ϕPn_tension[j], ϕMnx, cache.ϕMn_weak[j])
    ur_t <= 1.0 || return false
    
    # --- Deflection Check (Optional) ---
    if !isnothing(checker.deflection_limit) && I_ref > 0 && δ_max > 0
        δ_scaled = δ_max * I_ref / cache.Ix[j]
        δ_ratio = δ_scaled / geometry.L
        δ_ratio <= checker.deflection_limit || return false
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
    Pu_c = demand.Pu_c isa Unitful.Quantity ? ustrip(uconvert(u"N", demand.Pu_c)) : demand.Pu_c
    Pu_t = demand.Pu_t isa Unitful.Quantity ? ustrip(uconvert(u"N", demand.Pu_t)) : demand.Pu_t
    Mux = demand.Mux isa Unitful.Quantity ? ustrip(uconvert(u"N*m", demand.Mux)) : demand.Mux
    Muy = demand.Muy isa Unitful.Quantity ? ustrip(uconvert(u"N*m", demand.Muy)) : demand.Muy
    Vus = demand.Vu_strong isa Unitful.Quantity ? ustrip(uconvert(u"N", demand.Vu_strong)) : demand.Vu_strong
    Vuw = demand.Vu_weak isa Unitful.Quantity ? ustrip(uconvert(u"N", demand.Vu_weak)) : demand.Vu_weak
    
    "No feasible sections: Pu_c=$(Pu_c) N, Pu_t=$(Pu_t) N, " *
    "Mux=$(Mux) N*m, Muy=$(Muy) N*m, " *
    "Vus=$(Vus) N, Vuw=$(Vuw) N, " *
    "L=$(geometry.L) m, Lb=$(geometry.Lb) m"
end
