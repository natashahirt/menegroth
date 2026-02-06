# =============================================================================
# Flat Plate Design Checks
# =============================================================================
#
# ACI 318 design checks for flat plate slabs:
# - Punching shear (§22.6)
# - Two-way deflection (§24.2)
# - One-way shear (§22.5)
#
# These wrap the pure ACI equations from calculations.jl with logging and
# result struct construction.
#
# Note: This file is included in StructuralSizer, inheriting Logging, etc.
# =============================================================================

# =============================================================================
# Punching Shear Check (ACI 318-19 §22.6)
# =============================================================================

"""
    check_punching_for_column(col, Vu, Mub, d, h, fc; kwargs...) -> NamedTuple

Check punching shear for a single column with combined stress method.

For exterior columns, adjusts Mub for reaction eccentricity per StructurePoint:
    Mub_adjusted = Mub - Vu × e_centroid

where e_centroid is the distance from column centerline to critical section centroid.

# Arguments
- `col`: Column with position (:interior, :edge, :corner) and dimensions (c1, c2)
- `Vu`: Factored shear demand
- `Mub`: Unbalanced moment
- `d`: Effective slab depth
- `h`: Total slab thickness
- `fc`: Concrete compressive strength

# Keyword Arguments
- `verbose`: Enable debug logging
- `col_idx`: Column index for logging
- `λ`: Lightweight concrete factor (default: 1.0)
- `φ_shear`: Strength reduction factor (default: 0.75)

# Returns
Named tuple with `(ok, ratio, vu, φvc, b0, Jc)`
"""
function check_punching_for_column(col, Vu, Mub, d, h, fc;
                                   verbose=false, col_idx=1, λ=1.0, φ_shear=0.75)
    c1 = col.c1
    c2 = col.c2
    
    # Get geometry and compute eccentricity correction for Mub
    if col.position == :interior
        geom = punching_geometry_interior(c1, c2, d)
        Jc = polar_moment_Jc_interior(c1, c2, d)
        γv_val = gamma_v(c1, c2)
        cAB = (c1 + d) / 2
        Mub_adjusted = Mub  # No eccentricity correction for interior
        
    elseif col.position == :edge
        geom = punching_geometry_edge(c1, c2, d)
        Jc = polar_moment_Jc_edge(c1, c2, d)
        γv_val = gamma_v(c1, c2)
        cAB = geom.cAB
        # Eccentricity: column center to critical section centroid
        e_centroid = c1 / 2 - cAB
        Mub_adjusted = max(0.0kip*u"ft", Mub - Vu * e_centroid)
        
    else  # :corner
        geom = punching_geometry_corner(c1, c2, d)
        cAB = max(geom.cAB_x, geom.cAB_y)
        Jc = polar_moment_Jc_edge(c1, c2, d, cAB) / 2
        γv_val = gamma_v(c1, c2)
        e_x = c1 / 2 - geom.cAB_x
        e_y = c2 / 2 - geom.cAB_y
        e_centroid = max(e_x, e_y)
        Mub_adjusted = max(0.0kip*u"ft", Mub - Vu * e_centroid)
    end
    
    b0 = geom.b0
    vu = combined_punching_stress(Vu, Mub_adjusted, b0, d, γv_val, Jc, cAB)
    
    c1_in = ustrip(u"inch", c1)
    c2_in = ustrip(u"inch", c2)
    β = max(c1_in, c2_in) / max(min(c1_in, c2_in), 1.0)
    αs = punching_αs(col.position)
    
    vc = punching_capacity_stress(fc, β, αs, b0, d; λ=λ)
    φvc = φ_shear * vc
    
    ok = vu <= φvc
    ratio = ustrip(u"psi", vu) / ustrip(u"psi", φvc)
    
    if verbose
        status = ok ? "✓ PASS" : "✗ FAIL"
        @debug "Column $col_idx ($(col.position))" c1=c1 c2=c2 b0=b0 β=round(β, digits=2) αs=αs
        if col.position != :interior
            @debug "  Mub correction" Mub_original=Mub Mub_adjusted=Mub_adjusted e_centroid=e_centroid
        end
        @debug "  Demand" Vu=Vu γv=round(γv_val, digits=3) Mub=Mub_adjusted
        @debug "  Stress" vu=round(ustrip(u"psi", vu), digits=1) φvc=round(ustrip(u"psi", φvc), digits=1) ratio=round(ratio, digits=2) status=status
    end
    
    return (ok=ok, ratio=ratio, vu=vu, φvc=φvc, b0=b0, Jc=Jc)
end

# =============================================================================
# Two-Way Deflection Check (ACI 318-19 §24.2)
# =============================================================================

"""
    check_two_way_deflection(moment_results, h, d, fc, fy, Es, Ecs, spans, γ_concrete, 
                             columns; verbose=false, limit_type=:L_360) -> NamedTuple

Check two-way deflection using crossing beam method.

Combines column strip and middle strip deflections with long-term factors
to compute total panel deflection.

# Arguments
- `moment_results`: MomentAnalysisResult with geometry and loads
- `h`: Slab thickness
- `d`: Effective depth
- `fc`, `fy`, `Es`, `Ecs`: Material properties
- `spans`: Slab spans (primary, secondary)
- `γ_concrete`: Concrete density
- `columns`: Supporting columns (for position classification)

# Keyword Arguments
- `verbose`: Enable debug logging
- `limit_type`: `:L_240`, `:L_360` (default), or `:L_480`

# Returns
Named tuple with deflection check results
"""
function check_two_way_deflection(moment_results, h, d, fc, fy, Es, Ecs, spans, γ_concrete,
                                  columns; verbose=false, limit_type::Symbol=:L_360)
    l1 = spans.primary
    l2 = spans.secondary
    ln = moment_results.ln
    
    has_exterior = any(col.position != :interior for col in columns)
    position = has_exterior ? :exterior : :interior
    
    w_D = moment_results.qD * l2
    w_L = moment_results.qL * l2
    w_service = w_D + w_L
    
    # Section properties
    Ig_frame = slab_moment_of_inertia(l2, h)
    Ig_cs = slab_moment_of_inertia(l2/2, h)
    Ig_ms = slab_moment_of_inertia(l2/2, h)
    
    # Cracking check
    fr_val = fr(fc)
    Mcr = cracking_moment(fr_val, Ig_frame, h)
    Ma = moment_results.M_pos / 1.4  # Service moment
    
    # Effective moment of inertia
    As_est = minimum_reinforcement(l2, h, fy)
    Icr = cracked_moment_of_inertia(As_est, l2, d, Ecs, Es)
    Ie_frame = effective_moment_of_inertia(Mcr, Ma, Ig_frame, Icr)
    Ie_uncracked = Ig_frame
    
    # Load distribution factors
    LDF_c = load_distribution_factor(:column, position)
    LDF_m = load_distribution_factor(:middle, position)
    
    # Frame deflections
    Δ_frame_D = frame_deflection_fixed(w_D, l1, Ecs, Ie_uncracked)
    Δ_frame_DL = frame_deflection_fixed(w_service, l1, Ecs, Ie_frame)
    
    # Strip deflections
    Δc_fixed_D = strip_deflection_fixed(Δ_frame_D, LDF_c, Ie_uncracked, Ig_cs)
    Δm_fixed_D = strip_deflection_fixed(Δ_frame_D, LDF_m, Ie_uncracked, Ig_ms)
    Δc_fixed_DL = strip_deflection_fixed(Δ_frame_DL, LDF_c, Ie_frame, Ig_cs)
    Δm_fixed_DL = strip_deflection_fixed(Δ_frame_DL, LDF_m, Ie_frame, Ig_ms)
    
    # Rotation contributions (10% factor for joint rotation)
    Δc_rotation = 0.10 * Δc_fixed_DL
    Δm_rotation = 0.10 * Δm_fixed_DL
    
    # Immediate deflections
    Δcx_i = uconvert(u"inch", Δc_fixed_DL + Δc_rotation)
    Δmx_i = uconvert(u"inch", Δm_fixed_DL + Δm_rotation)
    Δ_panel_i = two_way_panel_deflection(Δcx_i, Δmx_i)
    
    # Long-term factor (ξ=2.0, ρ'=0 typical)
    λ_Δ = long_term_deflection_factor(2.0, 0.0)
    
    # Dead load only deflection (for long-term)
    Δcx_D = uconvert(u"inch", Δc_fixed_D + 0.10 * Δc_fixed_D)
    Δmx_D = uconvert(u"inch", Δm_fixed_D + 0.10 * Δm_fixed_D)
    Δ_panel_D = two_way_panel_deflection(Δcx_D, Δmx_D)
    
    # Total deflection: dead×(1+λ) + live
    Δ_total = Δ_panel_D * (1 + λ_Δ) + (Δ_panel_i - Δ_panel_D)
    
    # Determine limit
    limit_sym = if limit_type == :L_240
        :total
    elseif limit_type == :L_480
        :sensitive
    else
        :immediate_ll
    end
    
    Δ_limit = deflection_limit(l1, limit_sym)
    ok = Δ_total <= Δ_limit
    
    if verbose
        status = ok ? "✓ PASS" : "✗ FAIL"
        @debug "Frame strip" Ig=Ig_frame Ie=Ie_frame Mcr=uconvert(kip*u"ft", Mcr) Ma=uconvert(kip*u"ft", Ma)
        @debug "Load distribution" LDF_c=round(LDF_c, digits=3) LDF_m=round(LDF_m, digits=3) position=position
        @debug "Strip deflections (immed)" Δcx=Δcx_i Δmx=Δmx_i
        @debug "Panel deflection" Δ_panel_i=Δ_panel_i λ_Δ=λ_Δ Δ_total=Δ_total
        @debug "Limit check" Δ_limit=Δ_limit ratio=round(ustrip(Δ_total)/ustrip(Δ_limit), digits=2) status=status
    end
    
    return (ok=ok, Δ_total=Δ_total, Δ_limit=Δ_limit, Δi=Δ_panel_i, λ_Δ=λ_Δ,
            Δcx=Δcx_i, Δmx=Δmx_i, LDF_c=LDF_c, LDF_m=LDF_m)
end

# =============================================================================
# One-Way Shear Check (ACI 318-19 §22.5)
# =============================================================================

"""
    check_one_way_shear(moment_results, d, fc; verbose=false, λ=1.0, φ_shear=0.75) -> NamedTuple

Check one-way (beam) shear capacity.

# Returns
Named tuple with `(ok, ratio, Vu, Vc, message)`
"""
function check_one_way_shear(moment_results, d, fc; verbose=false, λ=1.0, φ_shear=0.75)
    Vu = moment_results.Vu_max
    l2 = moment_results.l2
    
    Vc = one_way_shear_capacity(fc, l2, d; λ=λ)
    result = StructuralSizer.check_one_way_shear(Vu, Vc; φ=φ_shear)
    
    if verbose
        status = result.passes ? "✓ PASS" : "✗ FAIL"
        φVc = φ_shear * Vc
        @debug "One-way shear" Vu=Vu Vc=Vc φVc=φVc ratio=round(result.ratio, digits=2) status=status
    end
    
    return (ok=result.passes, ratio=result.ratio, Vu=Vu, Vc=Vc, message=result.message)
end

# =============================================================================
# Exports
# =============================================================================

export check_punching_for_column, check_two_way_deflection, check_one_way_shear
