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

