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
- `ϕ_v`: Resistance factor for shear (`nothing` = per-provision: 1.00 only
  for AISC 360-16 §G2.1(a) rolled I-webs, else 0.90). An explicit value overrides.
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
    ϕ_v::Union{Nothing, Float64}
    ϕ_t::Float64
    deflection_limit::Union{Nothing, Float64}
    total_deflection_limit::Union{Nothing, Float64}
    max_depth::Float64  # meters, Inf for no limit
    prefer_penalty::Float64
end

function AISCChecker(;
    ϕ_b = 0.9,
    ϕ_c = 0.9,
    ϕ_v = nothing,
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
    # Only a real CompositeContext has slab/anchor data for Chapter I.
    # `true` is the SteelBeamOptions.composite sentinel (no slab data);
    # hogging Chapter F is applied below from Mux_neg, not from this flag.
    if section isa ISymmSection
        if demand.composite isa PerStationComposite
            return is_feasible(checker, cache, j, section, material, demand, geometry,
                               demand.composite)
        elseif demand.composite isa CompositeContext
            return is_feasible(checker, cache, j, section, material, demand, geometry,
                               demand.composite)
        end
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
    
    # AISC 360-16 Appendix 8 B2 (P-Δ) is DOCUMENTED/SCOPE: functions exist
    # (`compute_B2`) but are not applied here.  `SteelMemberGeometry.braced`
    # defaults to `true` (no sidesway); B2 must be applied externally when
    # `braced=false`.
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
    # AISC 360-16 Appendix 8 Eqs. A-8-1 / A-8-3 — corpus: aisc-360-16, pages 305–306.
    # Amplify sagging and hogging required moments the same way before H1.
    Mux_neg = to_newton_meters(demand.Mux_neg)
    Mux_amp = Mux
    Muy_amp = Muy
    Mux_neg_amp = Mux_neg
    
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
        
        # AISC A-8-3, α=1.0 for LRFD — corpus: aisc-360-16, page 306
        B1_x = compute_B1(Pu_c, Pe1_x, Cm_x; α=1.0)
        B1_y = compute_B1(Pu_c, Pe1_y, Cm_y; α=1.0)
        
        if isinf(B1_x) || isinf(B1_y)
            return false
        end
        
        Mux_amp = B1_x * Mux
        Muy_amp = B1_y * Muy
        Mux_neg_amp = B1_x * Mux_neg
    end
    
    # --- Hogging Chapter F (bottom-flange LTB: Lb=L, Cb=1.0) ---
    # AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103.
    # Mux_neg is always set (defaults to Mux). Do not gate on composite:
    # a CompositeContext takes the 8-arg path above; bare steel and the
    # `composite=true` sentinel both use Chapter F steel-alone here.
    # When a CompositeContext is present, §I3.2b (page 151) also refers
    # hogging to Chapter F; adequately braced = Lb ≤ Lp (Eq. F2-5, page 104).
    # ENGINEERING JUDGMENT: Cb_neg=1.0 — SteelMemberGeometry has only sagging Cb.
    ϕMn_neg = ϕMnx
    if section isa ISymmSection
        hog = _hogging_ltb_inputs(section, material, geometry)
        ϕMn_neg = _get_ϕMnx_cached!(cache, j, hog.Lb_neg_m, hog.Cb_neg,
                                    section, material, checker.ϕ_b)
        ϕMn_neg >= Mux_neg || return false
    end

    # --- H1 interaction: compression and tension, each with sagging and hogging ---
    # Hogging Mcx is Chapter F at Lb=L, Cb=1.0; do not credit deck-braced ϕMnx.
    # Compression Mr uses B1·Mux / B1·Muy (App. 8). Tension Mr is first-order
    # (§H1.2, page 134); hogging tension uses ϕMn_neg, not sagging ϕMnx.
    # AISC 360-16 §H1.1 Eqs. H1-1a/H1-1b — corpus: aisc-360-16, page 133.
    urs = _h1_pm_utilizations(Pu_c, Pu_t, Mux, Mux_neg, Muy,
                              ϕPnc, cache.ϕPn_tension[j], ϕMnx, ϕMn_neg,
                              cache.ϕMn_weak[j]; Mux_amp=Mux_amp, Muy_amp=Muy_amp,
                              Mux_neg_amp=Mux_neg_amp)
    urs.ur_c <= 1.0 || return false
    urs.ur_t <= 1.0 || return false
    urs.ur_t_neg <= 1.0 || return false
    if section isa ISymmSection
        urs.ur_c_neg <= 1.0 || return false
    end
    
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
# Hogging Chapter F inputs (bare steel + I3.2b steel-alone)
# ==============================================================================

"""
Hogging Chapter F LTB inputs (AISC 360-16 §F2.2, corpus: aisc-360-16, page 103).

Used for bare-steel 6-arg checks and for §I3.2b steel-alone strength
(corpus: aisc-360-16, page 151). Chapter F LTB is governed by the
compression flange. In hogging that flange is the bottom flange.
`geometry.Lb` is the top-flange (deck) brace spacing;
`SteelMemberGeometry` has no dedicated bottom-flange `Lb`, so `Lb_neg` is the
span `L`.

# ENGINEERING JUDGMENT
Hogging uses `Cb_neg = 1.0` unless a dedicated bottom-flange `Cb` already
exists. Do not invent a new geometry field — sagging `geometry.Cb` is not
the bottom-flange moment-gradient factor.

Adequately braced per §I3.2b(a) is `Lb ≤ Lp` (AISC 360-16 §F2.2 Eq. F2-5,
corpus: aisc-360-16, page 104), not Cb-inflated `Mn` reaching `Mp`.
"""
function _hogging_ltb_inputs(section::ISymmSection, material, geometry::SteelMemberGeometry)
    Lb_neg_m = to_meters(geometry.L)
    # ENGINEERING JUDGMENT: no dedicated bottom-flange Cb on SteelMemberGeometry.
    Cb_neg = 1.0
    # AISC 360-16 §F2.2, Eq. F2-5 — corpus: aisc-360-16, page 104
    Lp_m = ustrip(u"m", get_Lp_Lr(section, material).Lp)
    # AISC 360-16 §I3.2b(a) — corpus: aisc-360-16, page 151
    adequately_braced = Lb_neg_m <= Lp_m
    return (Lb_neg_m=Lb_neg_m, Cb_neg=Cb_neg, adequately_braced=adequately_braced)
end

"""
    _hogging_is_stricter(geometry::SteelMemberGeometry) -> Bool

`true` when hogging Chapter F is stricter than the sagging geometry:
deck-braced `Lb < L` or sagging `Cb > 1`.

Lengths compare in the geometry's own unit (stored metres) with the
existing `1e-9` float guard. Both inequalities are strict.

AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103.
# ENGINEERING JUDGMENT
`SteelMemberGeometry` has only sagging `Cb`. Hogging uses `Cb = 1.0`
when this is true (see [`_hogging_chapter_f_geometry`](@ref)).
"""
function _hogging_is_stricter(geometry::SteelMemberGeometry)
    tol = 1e-9 * oneunit(geometry.Lb)
    return geometry.Lb + tol < geometry.L || geometry.Cb > 1.0 + 1e-9
end

"""Hogging Chapter F geometry: `Lb=L`, `Cb=1.0`.

AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103.
# ENGINEERING JUDGMENT
`SteelMemberGeometry` has only sagging `Cb`. Hogging uses `Cb=1.0`.
"""
function _hogging_chapter_f_geometry(g::SteelMemberGeometry)
    SteelMemberGeometry(g.L; Lb=g.L, Cb=1.0, Kx=g.Kx, Ky=g.Ky, braced=g.braced)
end

"""I3.2b hogging design strength: Chapter F steel-alone, plus plastic
composite alternative only when §I3.2b(a–c) all hold."""
function _composite_ϕMn_neg(
    checker::AISCChecker,
    cache::AISCCapacityCache,
    j::Int,
    section::ISymmSection,
    material,
    geometry::SteelMemberGeometry,
    ctx::CompositeContext
)
    hog = _hogging_ltb_inputs(section, material, geometry)
    ϕMnx_steel_neg = _get_ϕMnx_cached!(cache, j, hog.Lb_neg_m, hog.Cb_neg,
                                        section, material, checker.ϕ_b)
    ϕMn_neg = ϕMnx_steel_neg
    Asr_m2 = ustrip(u"m^2", ctx.Asr)
    Fysr_Pa = ustrip(u"Pa", ctx.Fysr)
    # I3.2b alternative plastic hogging (φb = 0.90) only when:
    #   (a) compact and adequately braced per Chapter F: Lb ≤ Lp (Eq. F2-5),
    #   (b) headed studs/channels in the negative-moment region (`neg_moment`),
    #   (c) developed slab rebar Asr with Fysr.
    # Asr > 0 alone is not I3.2b(b). Adequately braced is Lb≤Lp, not
    # Cb-inflated Mn reaching Mp (AISC 360-16 §F2.2 Eq. F2-5, page 104).
    # AISC 360-16 §I3.2b(a–c) — corpus: aisc-360-16, page 151
    if ctx.neg_moment && is_compact(section, material) && Asr_m2 > 0 && Fysr_Pa > 0 &&
            hog.adequately_braced
        Mn_comp_neg = get_Mn_negative(section, material, ctx.Asr, ctx.Fysr)
        ϕMn_neg = max(ϕMn_neg, checker.ϕ_b * ustrip(u"N*m", Mn_comp_neg))
    end
    return ϕMn_neg
end

"""
AISC 360-16 §H1.1 compression, tension, and hogging P–M utilizations
(Eqs. H1-1a / H1-1b — corpus: aisc-360-16, page 133).

Required flexural strengths `Mr` for compression+flexure are second-order
moments: App. 8 B1 (P-δ) amplifies both the sagging and hogging faces
before H1 (AISC 360-16 Appendix 8 Eq. A-8-1 / A-8-3 — corpus: aisc-360-16,
pages 305–306; §C2.1 requires second-order required strengths — page 79).

`ϕMnx_sag` is sagging Mcx (Chapter F, or max(I3.2a composite, Chapter F) on
the CompositeContext path). `ϕMn_neg` is hogging Mcx (Chapter F at Lb=L,
Cb=1.0, or I3.2b). Axial Pc is Chapter E φPn — I2 is for encased/filled
columns, not slab-on-beam composite beams.

`Mux_amp` / `Mux_neg_amp` / `Muy_amp` are B1-amplified required moments
(default = first-order when B1 = 1). Tension+flexure uses first-order Mr
(App. 8 B1 applies to members subject to compression).

§H1.2 (page 134) limits flexure + tension by the same Eqs. H1-1a/H1-1b,
with Pc = φt·Pn from Section D2 and Mc from Chapter F. `ur_t` pairs tension
with the sagging face; `ur_t_neg` pairs it with the hogging face (`ϕMn_neg`).

Returns `(ur_c, ur_t, ur_c_neg, ur_t_neg)`. Adequate iff each ≤ 1.0.
"""
function _h1_pm_utilizations(
    Pu_c, Pu_t, Mux_sag, Mux_neg, Muy,
    ϕPnc, ϕPnt, ϕMnx_sag, ϕMn_neg, ϕMny;
    Mux_amp = Mux_sag,
    Muy_amp = Muy,
    Mux_neg_amp = Mux_neg,
)
    # AISC 360-16 §H1.1 Eqs. H1-1a/H1-1b — corpus: aisc-360-16, page 133
    # §H1.2 — same equations for flexure + tension, Pc = φt Pn (D2) — page 134
    # Compression Mr from App. 8 B1 — pages 305–306 (Eqs. A-8-1, A-8-3).
    # Tension Mr is first-order on each flexural face.
    ur_c = check_PMxMy_interaction(Pu_c, Mux_amp, Muy_amp, ϕPnc, ϕMnx_sag, ϕMny)
    ur_t = check_PMxMy_interaction(Pu_t, Mux_sag, Muy, ϕPnt, ϕMnx_sag, ϕMny)
    ur_c_neg = check_PMxMy_interaction(Pu_c, Mux_neg_amp, Muy_amp, ϕPnc, ϕMn_neg, ϕMny)
    ur_t_neg = check_PMxMy_interaction(Pu_t, Mux_neg, Muy, ϕPnt, ϕMn_neg, ϕMny)
    return (ur_c = ur_c, ur_t = ur_t, ur_c_neg = ur_c_neg, ur_t_neg = ur_t_neg)
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
5. **H1 interaction**: compression uses the larger of composite ϕMn and
   bare-steel ϕMn for sagging; hogging uses I3.2b ϕMn_neg with Pu via H1.
   Do not skip Pu because a CompositeContext is present.
"""
function is_feasible(
    checker::AISCChecker,
    cache::AISCCapacityCache,
    j::Int,
    section::ISymmSection,
    material::StructuralSteel,
    demand::MemberDemand,
    geometry::SteelMemberGeometry,
    ctx::CompositeContext;
    strength_Mux_pos::Union{Nothing, Float64} = nothing,
)::Bool
    Mux = to_newton_meters(demand.Mux)
    # Envelope stays on construction (§I3.1b). `strength_Mux_pos` is the
    # sagging moment at the governing station when the caller has a
    # per-station width; omitting it keeps the envelope (scalar path).
    Mux_pos_env = to_newton_meters(demand.Mux_pos)
    Mux_pos = strength_Mux_pos === nothing ? Mux_pos_env : strength_Mux_pos
    Mux_neg = to_newton_meters(demand.Mux_neg)
    Pu_c = to_newtons(demand.Pu_c)
    Pu_t = to_newtons(demand.Pu_t)
    Muy = to_newton_meters(demand.Muy)
    M1x = to_newton_meters(demand.M1x)
    M2x = to_newton_meters(demand.M2x)
    M1y = to_newton_meters(demand.M1y)
    M2y = to_newton_meters(demand.M2y)
    Vus = to_newtons(demand.Vu_strong)
    Vuw = to_newtons(demand.Vu_weak)
    L_m = to_meters(geometry.L)

    # --- Depth Check ---
    cache.depths[j] <= checker.max_depth || return false

    # --- Shear Checks (steel section alone — AISC G) ---
    cache.ϕVn_strong[j] >= Vus || return false
    cache.ϕVn_weak[j] >= Vuw || return false

    # --- Construction Stage (I3.1b) — unshored; all pre-composite loads ---
    # AISC 360-16 §I3.1b — corpus: aisc-360-16, page 151
    # Steel section alone must support all loads applied before concrete
    # attains 75% of f'c, including hogging. Envelope demand is used as a
    # proxy for those construction-stage moments (same convention as sagging).
    # Do not weaken vs unsigned Mux: if |Mux| exceeds both signed faces,
    # still check the larger value.
    if !ctx.shored
        Lb_const_m = ustrip(u"m", ctx.Lb_const)
        ϕMn_const = _get_ϕMnx_cached!(cache, j, Lb_const_m, 1.0, section, material, checker.ϕ_b)
        ϕMn_const >= max(abs(Mux), Mux_pos_env, Mux_neg) || return false
    end

    # --- Positive composite flexural capacity (I3.2a) ---
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

    # Use the greater of composite and bare-steel capacity (sagging)
    ϕMnx_steel = _get_ϕMnx_cached!(cache, j, to_meters(geometry.Lb), geometry.Cb,
                                     section, material, checker.ϕ_b)
    ϕMnx = max(ϕMn_comp, ϕMnx_steel)

    ϕMnx >= Mux_pos || return false

    # --- Negative flexural strength (I3.2b, corpus: aisc-360-16, page 151) ---
    ϕMn_neg = _composite_ϕMn_neg(checker, cache, j, section, material, geometry, ctx)
    ϕMn_neg >= Mux_neg || return false

    # --- H1 combined forces (do not skip Pu because CompositeContext is present) ---
    # Sagging Mcx: larger of I3.2a composite φMn and Chapter F φMn.
    # Hogging Mcx: I3.2b φMn_neg. Axial Pc: Chapter E φPn (I2 is encased/filled).
    # AISC 360-16 §H1.1 Eqs. H1-1a/H1-1b — corpus: aisc-360-16, page 133.
    # AISC 360-16 §I3.2a / §I3.2b — corpus: aisc-360-16, page 151.
    Lc_x = geometry.Kx * L_m
    Lc_y = geometry.Ky * L_m
    ϕPn_x = _get_ϕPn_cached!(cache, :strong, j, Lc_x, section, material)
    ϕPn_y = _get_ϕPn_cached!(cache, :weak, j, Lc_y, section, material)
    ϕPn_z = _get_ϕPn_cached!(cache, :torsional, j, Lc_y, section, material)
    ϕPnc = min(ϕPn_x, ϕPn_y, ϕPn_z)
    ϕMny = cache.ϕMn_weak[j]

    Mux_amp = Mux_pos
    Muy_amp = Muy
    Mux_neg_amp = Mux_neg
    if Pu_c > 0.0
        E = to_pascals(material.E)
        Ix = cache.Ix[j]
        Iy = to_meters_fourth(StructuralSizer.Iy(section))
        Lc1_x = geometry.Kx * L_m
        Lc1_y = geometry.Ky * L_m
        (Lc1_x > 0 && Lc1_y > 0) || return false
        Pe1_x = π^2 * E * Ix / Lc1_x^2
        Pe1_y = π^2 * E * Iy / Lc1_y^2
        Cm_x = compute_Cm(M1x, M2x; transverse_loading=demand.transverse_load)
        Cm_y = compute_Cm(M1y, M2y; transverse_loading=demand.transverse_load)
        # AISC 360-16 Appendix 8 Eq. A-8-3, α=1.0 for LRFD — corpus: aisc-360-16, page 306
        B1_x = compute_B1(Pu_c, Pe1_x, Cm_x; α=1.0)
        B1_y = compute_B1(Pu_c, Pe1_y, Cm_y; α=1.0)
        if isinf(B1_x) || isinf(B1_y)
            return false
        end
        Mux_amp = B1_x * Mux_pos
        Muy_amp = B1_y * Muy
        Mux_neg_amp = B1_x * Mux_neg
    end

    urs = _h1_pm_utilizations(Pu_c, Pu_t, Mux_pos, Mux_neg, Muy,
                              ϕPnc, cache.ϕPn_tension[j], ϕMnx, ϕMn_neg, ϕMny;
                              Mux_amp=Mux_amp, Muy_amp=Muy_amp,
                              Mux_neg_amp=Mux_neg_amp)
    urs.ur_c <= 1.0 || return false
    urs.ur_t <= 1.0 || return false
    urs.ur_t_neg <= 1.0 || return false
    urs.ur_c_neg <= 1.0 || return false

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

"""
Per-station composite feasibility.

Each beam in the group is checked at the sagging station that maximizes
`M⁺(s) / ϕMn(b_eff(s))` for this section (AISC 360-16 §I3.1a / §I3.2a,
corpus: aisc-360-16, PDF pp. 150–151). The scalar composite check then runs
at that station's width and moment. Construction (§I3.1b) and hogging
(§I3.2b) keep the demand envelopes.
"""
function is_feasible(
    checker::AISCChecker,
    cache::AISCCapacityCache,
    j::Int,
    section::ISymmSection,
    material::StructuralSteel,
    demand::MemberDemand,
    geometry::SteelMemberGeometry,
    psc::PerStationComposite,
)::Bool
    isempty(psc.fields) &&
        return is_feasible(checker, cache, j, section, material, demand, geometry, psc.ctx)

    ϕMnx_steel = _get_ϕMnx_cached!(cache, j, to_meters(geometry.Lb), geometry.Cb,
                                   section, material, checker.ϕ_b)
    for field in psc.fields
        g = governing_sagging_station(section, material, psc.ctx.slab, psc.ctx.L_beam,
                                      field.demand_of_s, ϕMnx_steel;
                                      left = field.left, right = field.right,
                                      extra_breakpoints = field.breakpoints,
                                      ϕ = checker.ϕ_b)
        g.dcr <= 1.0 || return false
        st = CompositeSaggingStation(g.b_eff, g.M_pos * u"N*m",
                                     g.spacing_left, g.spacing_right)
        ctx_i = context_at_sagging_station(psc.ctx, st)
        is_feasible(checker, cache, j, section, material, demand, geometry, ctx_i;
                    strength_Mux_pos = g.M_pos) || return false
    end
    return true
end

# ==============================================================================
# Composite Objective: Add Stud Cost
# ==============================================================================

"""
    composite_stud_contribution(ctx::CompositeContext, section::ISymmSection,
                                 material::StructuralSteel, objective) -> Unitful.Quantity

Compute the stud contribution to the objective function for a composite beam.
Returns the additional objective value as a typed quantity (`kg` for
[`MinWeight`](@ref), `kgCO2e` for [`MinCarbon`](@ref), `m^3` for
[`MinVolume`](@ref)) so it composes cleanly with `objective_value` at the
cache-build site.

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

    # Returns a typed Unitful quantity that matches the objective dimension —
    # the cache-build site (`precompute_capacities!`) reads `ref_unit` from
    # `objective_value` and applies `ustrip(ref_unit, ...)` at the JuMP boundary.
    if objective isa MinWeight
        return m_one * n_studs_total                           # kg
    elseif objective isa MinCarbon
        return m_one * n_studs_total * ctx.anchor.ecc          # kgCO₂e
    elseif objective isa MinVolume
        # Stud volume is small compared to beam steel; treat as zero per the
        # historical convention. Returning typed zero keeps caller arithmetic
        # type-stable.
        return 0.0u"m^3"
    else
        return 0.0
    end
end

# ==============================================================================
# Feasibility Explanation (Solver Trace)
# ==============================================================================

"""
    explain_feasibility(checker::AISCChecker, cache, j, section, material, demand, geometry)

Evaluate ALL AISC 360-16 checks without short-circuiting and return per-check
demand/capacity ratios. Mirrors the logic of `is_feasible` exactly but collects
every intermediate result.

Used post-solve by the trace system to explain section selection and rejection.
"""
function explain_feasibility(
    checker::AISCChecker,
    cache::AISCCapacityCache,
    j::Int,
    section::AbstractSection,
    material::StructuralSteel,
    demand::MemberDemand,
    geometry::SteelMemberGeometry
)::FeasibilityExplanation
    if section isa ISymmSection
        if demand.composite isa PerStationComposite
            return explain_feasibility(checker, cache, j, section, material, demand, geometry,
                                       demand.composite)
        elseif demand.composite isa CompositeContext
            return explain_feasibility(checker, cache, j, section, material, demand, geometry,
                                       demand.composite)
        end
    end

    checks = CheckResult[]

    # --- Extract demands (SI) ---
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

    # --- Depth Check ---
    d_section = cache.depths[j]
    d_limit = checker.max_depth
    d_ratio = d_limit > 0 ? d_section / d_limit : 0.0
    push!(checks, CheckResult("depth", d_section <= d_limit,
          d_ratio, d_section, d_limit, ""))

    # --- Shear: Strong Axis — AISC 360-16 G2 ---
    ϕVn_s = cache.ϕVn_strong[j]
    s_ratio_s = ϕVn_s > 0 ? Vus / ϕVn_s : (Vus > 0 ? Inf : 0.0)
    push!(checks, CheckResult("shear_strong", ϕVn_s >= Vus,
          s_ratio_s, Vus, ϕVn_s, "AISC 360-16 G2"))

    # --- Shear: Weak Axis ---
    ϕVn_w = cache.ϕVn_weak[j]
    s_ratio_w = ϕVn_w > 0 ? Vuw / ϕVn_w : (Vuw > 0 ? Inf : 0.0)
    push!(checks, CheckResult("shear_weak", ϕVn_w >= Vuw,
          s_ratio_w, Vuw, ϕVn_w, "AISC 360-16 G2"))

    # --- Flexural + Compression Capacities (needed for interaction) ---
    ϕMnx = _get_ϕMnx_cached!(cache, j, Lb_m, geometry.Cb, section, material, checker.ϕ_b)
    ϕMny = cache.ϕMn_weak[j]

    Lc_x = geometry.Kx * L_m
    Lc_y = geometry.Ky * L_m
    ϕPn_x = _get_ϕPn_cached!(cache, :strong, j, Lc_x, section, material)
    ϕPn_y = _get_ϕPn_cached!(cache, :weak, j, Lc_y, section, material)
    ϕPn_z = _get_ϕPn_cached!(cache, :torsional, j, Lc_y, section, material)
    ϕPnc = min(ϕPn_x, ϕPn_y, ϕPn_z)

    # --- B1 Moment Amplification — AISC Appendix 8 ---
    # AISC 360-16 Appendix 8 Eqs. A-8-1 / A-8-3 — corpus: aisc-360-16, pages 305–306.
    Mux_neg = to_newton_meters(demand.Mux_neg)
    Mux_amp = Mux
    Muy_amp = Muy
    Mux_neg_amp = Mux_neg
    b1_feasible = true

    if Pu_c > 0.0
        E = to_pascals(material.E)
        Ix_j = cache.Ix[j]
        Iy_j = to_meters_fourth(StructuralSizer.Iy(section))
        Lc1_x = geometry.Kx * L_m
        Lc1_y = geometry.Ky * L_m

        if Lc1_x > 0 && Lc1_y > 0
            Pe1_x = π^2 * E * Ix_j / Lc1_x^2
            Pe1_y = π^2 * E * Iy_j / Lc1_y^2
            Cm_x = compute_Cm(M1x, M2x; transverse_loading=demand.transverse_load)
            Cm_y = compute_Cm(M1y, M2y; transverse_loading=demand.transverse_load)
            B1_x = compute_B1(Pu_c, Pe1_x, Cm_x; α=1.0)
            B1_y = compute_B1(Pu_c, Pe1_y, Cm_y; α=1.0)
            b1_feasible = !isinf(B1_x) && !isinf(B1_y)
            if b1_feasible
                Mux_amp = B1_x * Mux
                Muy_amp = B1_y * Muy
                Mux_neg_amp = B1_x * Mux_neg
            end
        else
            b1_feasible = false
        end
    end

    # Report B1 amplification as a check (Pu/Pe ratio indicates stability)
    if Pu_c > 0.0 && Lc_x > 0
        Pe1_approx = ϕPnc > 0 ? Pu_c / ϕPnc : Inf
        push!(checks, CheckResult("b1_amplification", b1_feasible,
              b1_feasible ? Pe1_approx : Inf, Pu_c, ϕPnc, "AISC 360-16 App. 8"))
    end

    # --- Hogging Chapter F (bottom-flange LTB: Lb=L, Cb=1.0) ---
    # AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103.
    # Always reported for I-sections so explain does not tell only the
    # unsigned H1 story. Clause is §I3.2b when the hogging-only sentinel
    # is set; otherwise Chapter F (bare steel) / H1 when Pu > 0.
    # ENGINEERING JUDGMENT: Cb_neg=1.0 — SteelMemberGeometry has only sagging Cb.
    hog_stricter = false
    ϕMn_neg = ϕMnx
    if section isa ISymmSection
        hog = _hogging_ltb_inputs(section, material, geometry)
        ϕMn_neg = _get_ϕMnx_cached!(cache, j, hog.Lb_neg_m, hog.Cb_neg,
                                    section, material, checker.ϕ_b)
        hog_stricter = _hogging_is_stricter(geometry)
    end

    # --- H1 interaction: sagging, tension, hogging ---
    # AISC 360-16 §H1.1 Eqs. H1-1a/H1-1b — corpus: aisc-360-16, page 133.
    # Hogging Mr = B1·Mux_neg (App. 8) — corpus: aisc-360-16, pages 305–306.
    ϕPn_t = cache.ϕPn_tension[j]
    urs = _h1_pm_utilizations(Pu_c, Pu_t, Mux, Mux_neg, Muy,
                              ϕPnc, ϕPn_t, ϕMnx, ϕMn_neg, ϕMny;
                              Mux_amp=Mux_amp, Muy_amp=Muy_amp,
                              Mux_neg_amp=Mux_neg_amp)
    ur_c = b1_feasible ? urs.ur_c : Inf
    push!(checks, CheckResult("pm_interaction_compression", ur_c <= 1.0,
          ur_c, max(Pu_c, Mux_amp, Muy_amp), 1.0, "AISC 360-16 H1"))
    push!(checks, CheckResult("pm_interaction_tension", urs.ur_t <= 1.0,
          urs.ur_t, max(Pu_t, Mux, Muy), 1.0, "AISC 360-16 H1"))
    # §H1.2 (page 134): tension with the hogging face. First-order Mr, Mcx = ϕMn_neg.
    push!(checks, CheckResult("pm_interaction_tension_hogging", urs.ur_t_neg <= 1.0,
          urs.ur_t_neg, max(Pu_t, Mux_neg, Muy), 1.0, "AISC 360-16 H1.2"))
    if section isa ISymmSection
        flex_ratio = ϕMn_neg > 0 ? Mux_neg / ϕMn_neg : (Mux_neg > 0 ? Inf : 0.0)
        neg_ratio = max(flex_ratio, urs.ur_c_neg)
        neg_ok = ϕMn_neg >= Mux_neg && urs.ur_c_neg <= 1.0
        clause = if demand.composite === true
            "AISC 360-16 I3.2b"
        elseif Pu_c > 0
            "AISC 360-16 H1"
        else
            "AISC 360-16 F2"
        end
        push!(checks, CheckResult("flexure_neg", neg_ok,
              neg_ratio, Mux_neg, ϕMn_neg, clause))
    end

    # --- LL Deflection Check ---
    if !isnothing(checker.deflection_limit) && I_ref > 0 && δ_max_LL > 0
        δ_scaled = δ_max_LL * I_ref / cache.Ix[j]
        δ_ratio = δ_scaled / L_m
        limit_val = checker.deflection_limit
        push!(checks, CheckResult("deflection_ll", δ_ratio <= limit_val,
              δ_ratio / limit_val, δ_ratio, limit_val, "AISC 360-16 L"))
    end

    # --- Total Deflection Check ---
    if !isnothing(checker.total_deflection_limit) && I_ref > 0 && δ_max_total > 0
        δ_scaled = δ_max_total * I_ref / cache.Ix[j]
        δ_ratio = δ_scaled / L_m
        limit_val = checker.total_deflection_limit
        push!(checks, CheckResult("deflection_total", δ_ratio <= limit_val,
              δ_ratio / limit_val, δ_ratio, limit_val, "AISC 360-16 L"))
    end

    # --- Aggregate ---
    # Exclude informational checks (b1_amplification is a stability indicator,
    # not a demand/capacity utilization ratio) from governing determination.
    # When hogging Chapter F is stricter, unsigned H1 used sagging ϕMnx —
    # do not advertise it as the flexure story (flexure_neg / hogging H1 is).
    capacity_checks = filter(c -> c.name != "b1_amplification", checks)
    if hog_stricter && Mux_neg > 0
        capacity_checks = filter(c -> c.name != "pm_interaction_compression" &&
                                      c.name != "pm_interaction_tension",
                                 capacity_checks)
    end
    all_pass = all(c -> c.passed, checks)
    if isempty(capacity_checks)
        gov = CheckResult("none", true, 0.0, 0.0, 0.0, "")
    else
        gov_idx = argmax([c.ratio for c in capacity_checks])
        gov = capacity_checks[gov_idx]
    end

    FeasibilityExplanation(all_pass, checks, gov.name, gov.ratio)
end

"""
    explain_feasibility(checker, cache, j, section, material, demand, geometry, ctx)

Composite-aware diagnostic sibling of the `CompositeContext` `is_feasible`
overload. Evaluates construction both-face (I3.1b), hogging (I3.2b), and
H1 interaction so `explain.passed` matches `is_feasible`.
"""
function explain_feasibility(
    checker::AISCChecker,
    cache::AISCCapacityCache,
    j::Int,
    section::ISymmSection,
    material::StructuralSteel,
    demand::MemberDemand,
    geometry::SteelMemberGeometry,
    ctx::CompositeContext;
    strength_Mux_pos::Union{Nothing, Float64} = nothing,
)::FeasibilityExplanation
    checks = CheckResult[]

    Mux = to_newton_meters(demand.Mux)
    Mux_pos_env = to_newton_meters(demand.Mux_pos)
    Mux_pos = strength_Mux_pos === nothing ? Mux_pos_env : strength_Mux_pos
    Mux_neg = to_newton_meters(demand.Mux_neg)
    Pu_c = to_newtons(demand.Pu_c)
    Pu_t = to_newtons(demand.Pu_t)
    Muy = to_newton_meters(demand.Muy)
    M1x = to_newton_meters(demand.M1x)
    M2x = to_newton_meters(demand.M2x)
    M1y = to_newton_meters(demand.M1y)
    M2y = to_newton_meters(demand.M2y)
    Vus = to_newtons(demand.Vu_strong)
    Vuw = to_newtons(demand.Vu_weak)
    L_m = to_meters(geometry.L)
    δ_max_LL = to_meters(demand.δ_max_LL)
    δ_max_total = to_meters(demand.δ_max_total)
    I_ref = to_meters_fourth(demand.I_ref)

    # --- Depth ---
    d_section = cache.depths[j]
    d_limit = checker.max_depth
    d_ratio = d_limit > 0 ? d_section / d_limit : 0.0
    push!(checks, CheckResult("depth", d_section <= d_limit,
          d_ratio, d_section, d_limit, ""))

    # --- Shear (steel section alone — AISC G) ---
    ϕVn_s = cache.ϕVn_strong[j]
    s_ratio_s = ϕVn_s > 0 ? Vus / ϕVn_s : (Vus > 0 ? Inf : 0.0)
    push!(checks, CheckResult("shear_strong", ϕVn_s >= Vus,
          s_ratio_s, Vus, ϕVn_s, "AISC 360-16 G2"))

    ϕVn_w = cache.ϕVn_weak[j]
    s_ratio_w = ϕVn_w > 0 ? Vuw / ϕVn_w : (Vuw > 0 ? Inf : 0.0)
    push!(checks, CheckResult("shear_weak", ϕVn_w >= Vuw,
          s_ratio_w, Vuw, ϕVn_w, "AISC 360-16 G2"))

    # --- Construction Stage (I3.1b) — both faces ---
    # AISC 360-16 §I3.1b — corpus: aisc-360-16, page 151
    # Do not weaken vs unsigned Mux: if |Mux| exceeds both signed faces,
    # still check the larger value.
    if !ctx.shored
        Lb_const_m = ustrip(u"m", ctx.Lb_const)
        ϕMn_const = _get_ϕMnx_cached!(cache, j, Lb_const_m, 1.0, section, material, checker.ϕ_b)
        Mu_const = max(abs(Mux), Mux_pos_env, Mux_neg)
        c_ratio = ϕMn_const > 0 ? Mu_const / ϕMn_const : (Mu_const > 0 ? Inf : 0.0)
        push!(checks, CheckResult("construction_flexure", ϕMn_const >= Mu_const,
              c_ratio, Mu_const, ϕMn_const, "AISC 360-16 I3.1b"))
    end

    # --- Positive composite flexural capacity (I3.2a) ---
    b_eff = get_b_eff(ctx.slab, ctx.L_beam)
    Cf_max = ustrip(u"N", _Cf_max(section, material, ctx.slab, b_eff))
    ΣQn_full = Cf_max * u"N"

    ϕMn_comp = 0.0
    flexure_pos_ok = false
    try
        result = get_ϕMn_composite(section, material, ctx.slab, b_eff, ΣQn_full;
                                    ϕ=checker.ϕ_b)
        ϕMn_comp = ustrip(u"N*m", result.ϕMn)
        flexure_pos_ok = true
    catch e
        @debug "Composite flexure check failed — section infeasible" exception=(e, catch_backtrace())
    end

    ϕMnx_steel = _get_ϕMnx_cached!(cache, j, to_meters(geometry.Lb), geometry.Cb,
                                     section, material, checker.ϕ_b)
    ϕMnx = flexure_pos_ok ? max(ϕMn_comp, ϕMnx_steel) : 0.0
    pos_ratio = ϕMnx > 0 ? Mux_pos / ϕMnx : (Mux_pos > 0 ? Inf : 0.0)
    push!(checks, CheckResult("flexure_pos", flexure_pos_ok && ϕMnx >= Mux_pos,
          pos_ratio, Mux_pos, ϕMnx, "AISC 360-16 I3.2a"))

    # --- Negative flexural strength (I3.2b) + hogging H1 ---
    # AISC 360-16 §I3.2b — corpus: aisc-360-16, page 151
    # AISC 360-16 §F2.2 Eq. F2-5 — corpus: aisc-360-16, page 104
    # AISC 360-16 §H1.1 Eqs. H1-1a/H1-1b — corpus: aisc-360-16, page 133
    ϕMn_neg = _composite_ϕMn_neg(checker, cache, j, section, material, geometry, ctx)
    hog_stricter = _hogging_is_stricter(geometry)

    Lc_x = geometry.Kx * L_m
    Lc_y = geometry.Ky * L_m
    ϕPn_x = _get_ϕPn_cached!(cache, :strong, j, Lc_x, section, material)
    ϕPn_y = _get_ϕPn_cached!(cache, :weak, j, Lc_y, section, material)
    ϕPn_z = _get_ϕPn_cached!(cache, :torsional, j, Lc_y, section, material)
    ϕPnc = min(ϕPn_x, ϕPn_y, ϕPn_z)
    ϕMny = cache.ϕMn_weak[j]
    ϕPn_t = cache.ϕPn_tension[j]

    Mux_amp = Mux_pos
    Muy_amp = Muy
    Mux_neg_amp = Mux_neg
    b1_feasible = true
    if Pu_c > 0.0
        E = to_pascals(material.E)
        Ix_j = cache.Ix[j]
        Iy_j = to_meters_fourth(StructuralSizer.Iy(section))
        Lc1_x = geometry.Kx * L_m
        Lc1_y = geometry.Ky * L_m
        if Lc1_x > 0 && Lc1_y > 0
            Pe1_x = π^2 * E * Ix_j / Lc1_x^2
            Pe1_y = π^2 * E * Iy_j / Lc1_y^2
            Cm_x = compute_Cm(M1x, M2x; transverse_loading=demand.transverse_load)
            Cm_y = compute_Cm(M1y, M2y; transverse_loading=demand.transverse_load)
            B1_x = compute_B1(Pu_c, Pe1_x, Cm_x; α=1.0)
            B1_y = compute_B1(Pu_c, Pe1_y, Cm_y; α=1.0)
            b1_feasible = !isinf(B1_x) && !isinf(B1_y)
            if b1_feasible
                Mux_amp = B1_x * Mux_pos
                Muy_amp = B1_y * Muy
                Mux_neg_amp = B1_x * Mux_neg
            end
        else
            b1_feasible = false
        end
    end

    if Pu_c > 0.0 && Lc_x > 0
        Pe1_approx = ϕPnc > 0 ? Pu_c / ϕPnc : Inf
        push!(checks, CheckResult("b1_amplification", b1_feasible,
              b1_feasible ? Pe1_approx : Inf, Pu_c, ϕPnc, "AISC 360-16 App. 8"))
    end

    urs = _h1_pm_utilizations(Pu_c, Pu_t, Mux_pos, Mux_neg, Muy,
                              ϕPnc, ϕPn_t, ϕMnx, ϕMn_neg, ϕMny;
                              Mux_amp=Mux_amp, Muy_amp=Muy_amp,
                              Mux_neg_amp=Mux_neg_amp)
    ur_c = b1_feasible ? urs.ur_c : Inf
    push!(checks, CheckResult("pm_interaction_compression", ur_c <= 1.0,
          ur_c, max(Pu_c, Mux_amp, Muy_amp), 1.0, "AISC 360-16 H1"))
    push!(checks, CheckResult("pm_interaction_tension", urs.ur_t <= 1.0,
          urs.ur_t, max(Pu_t, Mux_pos, Muy), 1.0, "AISC 360-16 H1"))
    # §H1.2 (page 134): tension with the hogging face. First-order Mr, Mcx = ϕMn_neg.
    push!(checks, CheckResult("pm_interaction_tension_hogging", urs.ur_t_neg <= 1.0,
          urs.ur_t_neg, max(Pu_t, Mux_neg, Muy), 1.0, "AISC 360-16 H1.2"))

    flex_ratio = ϕMn_neg > 0 ? Mux_neg / ϕMn_neg : (Mux_neg > 0 ? Inf : 0.0)
    neg_ratio = max(flex_ratio, urs.ur_c_neg)
    neg_ok = ϕMn_neg >= Mux_neg && urs.ur_c_neg <= 1.0
    clause = Pu_c > 0 ? "AISC 360-16 H1" : "AISC 360-16 I3.2b"
    push!(checks, CheckResult("flexure_neg", neg_ok,
          neg_ratio, Mux_neg, ϕMn_neg, clause))

    # --- Deflection (Commentary I3.2) ---
    I_LB_m4 = ustrip(u"m^4", get_I_LB(section, material, ctx.slab, b_eff, ΣQn_full))
    I_steel_m4 = cache.Ix[j]

    if !isnothing(checker.deflection_limit) && I_ref > 0 && δ_max_LL > 0
        δ_scaled = δ_max_LL * I_ref / I_LB_m4
        δ_ratio = δ_scaled / L_m
        limit_val = checker.deflection_limit
        push!(checks, CheckResult("deflection_ll", δ_ratio <= limit_val,
              δ_ratio / limit_val, δ_ratio, limit_val, "AISC 360-16 I3.2"))
    end

    if !isnothing(checker.total_deflection_limit) && I_ref > 0 && δ_max_total > 0
        I_total_eff = ctx.shored ? I_LB_m4 : I_steel_m4
        δ_scaled = δ_max_total * I_ref / I_total_eff
        δ_ratio = δ_scaled / L_m
        limit_val = checker.total_deflection_limit
        push!(checks, CheckResult("deflection_total", δ_ratio <= limit_val,
              δ_ratio / limit_val, δ_ratio, limit_val, "AISC 360-16 I3.2"))
    end

    capacity_checks = filter(c -> c.name != "b1_amplification", checks)
    if hog_stricter && Mux_neg > 0
        capacity_checks = filter(c -> c.name != "pm_interaction_compression" &&
                                      c.name != "pm_interaction_tension",
                                 capacity_checks)
    end
    all_pass = all(c -> c.passed, checks)
    if isempty(capacity_checks)
        gov = CheckResult("none", true, 0.0, 0.0, 0.0, "")
    else
        gov_idx = argmax([c.ratio for c in capacity_checks])
        gov = capacity_checks[gov_idx]
    end

    FeasibilityExplanation(all_pass, checks, gov.name, gov.ratio)
end

"""Explain the beam in the group whose governing sagging station is the strictest."""
function explain_feasibility(
    checker::AISCChecker,
    cache::AISCCapacityCache,
    j::Int,
    section::ISymmSection,
    material::StructuralSteel,
    demand::MemberDemand,
    geometry::SteelMemberGeometry,
    psc::PerStationComposite,
)::FeasibilityExplanation
    isempty(psc.fields) &&
        return explain_feasibility(checker, cache, j, section, material, demand, geometry, psc.ctx)

    ϕMnx_steel = _get_ϕMnx_cached!(cache, j, to_meters(geometry.Lb), geometry.Cb,
                                   section, material, checker.ϕ_b)
    best = nothing
    for field in psc.fields
        g = governing_sagging_station(section, material, psc.ctx.slab, psc.ctx.L_beam,
                                      field.demand_of_s, ϕMnx_steel;
                                      left = field.left, right = field.right,
                                      extra_breakpoints = field.breakpoints,
                                      ϕ = checker.ϕ_b)
        st = CompositeSaggingStation(g.b_eff, g.M_pos * u"N*m",
                                     g.spacing_left, g.spacing_right)
        ctx_i = context_at_sagging_station(psc.ctx, st)
        ex = explain_feasibility(checker, cache, j, section, material, demand, geometry, ctx_i;
                                 strength_Mux_pos = g.M_pos)
        if best === nothing || (!ex.passed && best.passed) ||
                (ex.passed == best.passed && ex.governing_ratio > best.governing_ratio)
            best = ex
        end
    end
    return best
end
