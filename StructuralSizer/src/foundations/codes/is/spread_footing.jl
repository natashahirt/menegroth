# Spread footing design per IS 456 / ACI 318 principles
#
# Based on limit state design with checks for:
# 1. Bearing capacity
# 2. Punching shear (two-way)
# 3. One-way shear (beam shear)
# 4. Flexure (bending moment)

"""
    design_footing(::SpreadFooting, demand, soil, concrete, rebar; kwargs...)

Design a square spread footing for the given demand (IS 456).

# Arguments
- `demand::FoundationDemand`: Factored loads from structural analysis
- `soil::Soil`: Geotechnical parameters
- `concrete::Concrete`: Concrete material
- `rebar::Metal`: Reinforcement material

# Keyword Arguments
- `pier_width`: Column/pier width (default 0.3m)
- `rebar_dia`: Rebar diameter (default 16mm)
- `cover`: Concrete cover (default 75mm)
- `SF`: Factor of safety for bearing (default 1.5)
- `ϕ_flexure`: Strength reduction factor for flexure (default 0.9)
- `ϕ_shear`: Strength reduction factor for shear (default 0.75)
- `min_depth`: Minimum footing depth (default 0.3m)

# Returns
- `SpreadFootingResult` with dimensions, reinforcement, and volumes
"""
function design_footing(::SpreadFooting,
    demand::FoundationDemand,
    soil::Soil,
    concrete::Concrete,
    rebar::Metal;
    pier_width=0.3u"m",
    rebar_dia=16u"mm",
    cover=75u"mm",
    SF=1.5,
    ϕ_flexure=0.9,
    ϕ_shear=0.75,
    min_depth=0.3u"m",
)
    # Extract material properties
    fc′ = concrete.fc′
    fy = rebar.Fy
    qa = soil.qa
    
    # Convert to consistent units (SI)
    Pu = uconvert(u"kN", demand.Pu)
    qa_kPa = uconvert(u"kPa", qa)
    fc_MPa = uconvert(u"MPa", fc′)
    fy_MPa = uconvert(u"MPa", fy)
    pier_m = uconvert(u"m", pier_width)
    rebar_m = uconvert(u"m", rebar_dia)
    cover_m = uconvert(u"m", cover)
    
    # ==========================================================================
    # 1. Bearing Capacity → Footing Size
    # ==========================================================================
    # Required area: A_req = P_service / q_allowable
    # For factored load with SF: A_req = P_u * SF / q_a
    A_req = Pu * SF / qa_kPa
    A_req = uconvert(u"m^2", A_req)  # Ensure proper unit simplification
    B = sqrt(A_req)  # Square footing
    B = max(B, pier_m + 0.3u"m")  # Minimum projection
    
    # Factored bearing pressure
    q_u = Pu / B^2
    utilization = ustrip(q_u / qa_kPa)
    
    # ==========================================================================
    # 2. Punching Shear → Minimum Depth
    # ==========================================================================
    # Critical perimeter at d/2 from column face
    # V_punch = P_u - q_u * (pier + d)^2
    # Capacity: v_c = 0.33 * √fc′ (MPa, per ACI 318)
    # or v_c = 0.25 * √fc′ (conservative, per IS 456)
    
    τ_c = 0.25 * sqrt(ustrip(fc_MPa)) * u"MPa"  # Punching shear stress capacity
    
    # Solve for d iteratively (punching shear governs for typical cases)
    # V_u / (b_0 * d) ≤ ϕ * v_c  where b_0 = 4*(pier + d)
    # This leads to a quadratic in d
    
    # Simplified: use quadratic formula approach
    # P_u - q_u*(pier+d)² ≤ ϕ*τ_c * 4*(pier+d)*d
    # Let x = pier + d, then d = x - pier
    # P_u - q_u*x² ≤ ϕ*τ_c * 4*x*(x - pier)
    
    # Iterative solution (simpler to understand)
    d_ps = 0.2u"m"  # Initial guess
    for _ in 1:20
        b_0 = 4 * (pier_m + d_ps)  # Critical perimeter
        V_punch = Pu - q_u * (pier_m + d_ps)^2
        V_punch = max(V_punch, 0.0u"kN")
        d_req = V_punch / (ϕ_shear * τ_c * b_0)
        d_req = uconvert(u"m", d_req)
        
        if abs(d_req - d_ps) < 0.001u"m"
            break
        end
        d_ps = 0.5 * (d_ps + d_req)
    end
    d_ps = max(d_ps, 0.15u"m")  # Minimum effective depth
    
    # ==========================================================================
    # 3. One-Way (Beam) Shear
    # ==========================================================================
    # Critical section at distance d from column face
    # V_beam = q_u * B * ((B - pier)/2 - d)
    
    τ_beam = 0.17 * sqrt(ustrip(fc_MPa)) * u"MPa"  # One-way shear capacity (ACI)
    
    cantilever = (B - pier_m) / 2
    V_beam = q_u * B * max(cantilever - d_ps, 0.0u"m")
    d_bs = V_beam / (ϕ_shear * τ_beam * B)
    d_bs = uconvert(u"m", d_bs)
    
    # ==========================================================================
    # 4. Flexure → Reinforcement
    # ==========================================================================
    # Critical section at column face
    # M_u = q_u * B * (cantilever)² / 2
    
    M_u = q_u * B * cantilever^2 / 2
    M_u = uconvert(u"kN*m", M_u)
    
    # Required depth for flexure (singly reinforced)
    # M_u = ϕ * ρ * fy * b * d² * (1 - 0.59*ρ*fy/fc)
    # For typical ρ ≈ 0.002-0.005, simplify:
    # d_bm² ≈ M_u / (ϕ * 0.9 * fc * 0.15 * B)  (approximate lever arm)
    
    # More accurate: use Ru coefficient
    # M_u = ϕ * Ru * fc * B * d²  where Ru = ρ*(fy/fc)*(1 - 0.59*ρ*fy/fc)
    # For balanced design, Ru_max ≈ 0.138 (fy=415MPa, fc=25MPa)
    Ru = 0.138  # Conservative
    d_bm_sq = M_u / (ϕ_flexure * Ru * fc_MPa * B)
    d_bm = sqrt(uconvert(u"m^2", d_bm_sq))
    
    # ==========================================================================
    # 5. Governing Depth
    # ==========================================================================
    d = max(d_ps, d_bs, d_bm, 0.15u"m")
    D = d + rebar_m + cover_m  # Total depth
    D = max(D, min_depth)
    d = D - cover_m - rebar_m / 2  # Actual effective depth
    
    # ==========================================================================
    # 6. Calculate Reinforcement
    # ==========================================================================
    # As = M_u / (ϕ * fy * (d - a/2))
    # where a = As * fy / (0.85 * fc * B)
    
    # Iterative solution for As
    jd = 0.9 * d  # Initial lever arm estimate
    As = M_u / (ϕ_flexure * fy_MPa * jd)
    As = uconvert(u"mm^2", As)
    
    for _ in 1:10
        a = As * fy_MPa / (0.85 * fc_MPa * B)
        a = uconvert(u"m", a)
        jd_new = d - a / 2
        As_new = M_u / (ϕ_flexure * fy_MPa * jd_new)
        As_new = uconvert(u"mm^2", As_new)
        
        if abs(As_new - As) < 1.0u"mm^2"
            break
        end
        As = As_new
    end
    
    # Minimum reinforcement (0.0018 * b * D for slabs, use 0.0012 for footings)
    As_min = 0.0012 * B * D
    As_min = uconvert(u"mm^2", As_min)
    As = max(As, As_min)
    
    # Per unit width (dimension reduces to Length: m²/m = m)
    As_per_m = uconvert(u"m", As / B)
    
    # Number of bars
    A_bar = π * rebar_dia^2 / 4
    A_bar = uconvert(u"mm^2", A_bar)
    n_bars = ceil(Int, ustrip(As / A_bar))
    n_bars = max(n_bars, 4)  # Minimum 4 bars each way
    
    # ==========================================================================
    # 7. Compute Volumes
    # ==========================================================================
    V_concrete = B * B * D
    V_concrete = uconvert(u"m^3", V_concrete)
    
    # Steel: both directions
    bar_length = B - 2 * cover
    V_steel = 2 * n_bars * A_bar * bar_length
    V_steel = uconvert(u"m^3", V_steel)
    
    # ==========================================================================
    # 8. Structural Checks (warnings)
    # ==========================================================================
    ρ = As / (B * d)
    ρ_val = ustrip(u"m/m", ρ)
    
    if ρ_val < 0.0012
        @warn "Reinforcement ratio below minimum ($(round(ρ_val*100, digits=3))% < 0.12%)"
    end
    
    if d_bm > d_ps
        @warn "Flexure governs depth (d_bm=$(round(u"mm", d_bm)) > d_ps=$(round(u"mm", d_ps)))"
    end
    
    # Development length check
    Ld = rebar_dia * fy_MPa / (4 * 1.2 * 1.6u"MPa")  # Simplified
    Ld = uconvert(u"m", Ld)
    available = cantilever - cover_m
    if Ld > available
        @warn "Development length insufficient (Ld=$(round(u"mm", Ld)) > available=$(round(u"mm", available)))"
    end
    
    # Normalize all outputs to coherent SI (m, m³)
    As_per_m_si = uconvert(u"m", As_per_m)  # mm²/m → m²/m = m
    rebar_dia_m = uconvert(u"m", rebar_dia)
    
    return SpreadFootingResult{typeof(B), typeof(V_concrete), typeof(Pu)}(
        B,              # Width (m)
        B,              # Length (m, square)
        D,              # Depth (m)
        d,              # Effective depth (m)
        As_per_m_si,    # Rebar area per meter (m²/m = m)
        n_bars,         # Rebar count each way
        rebar_dia_m,    # Rebar diameter (m)
        V_concrete,     # Concrete volume (m³)
        V_steel,        # Steel volume (m³)
        utilization
    )
end

"""
    check_spread_footing(result, demand, soil, concrete; SF=1.5)

Verify that an existing spread footing design is adequate.

Returns a named tuple with check results.
"""
function check_spread_footing(
    result::SpreadFootingResult,
    demand::FoundationDemand,
    soil::Soil,
    concrete::Concrete;
    SF=1.5,
    ϕ_shear=0.75,
)
    Pu = uconvert(u"kN", demand.Pu)
    qa = uconvert(u"kPa", soil.qa)
    fc_MPa = uconvert(u"MPa", concrete.fc′)
    
    B = result.B
    D = result.D
    d = result.d
    
    # Bearing check
    q_actual = Pu / (B * result.L_ftg)
    q_allowable = qa / SF
    bearing_ok = q_actual ≤ q_allowable * 1.0  # Ensure units match
    
    # Punching shear check (would need pier_width as input for full check)
    τ_c = 0.25 * sqrt(ustrip(fc_MPa)) * u"MPa"
    # Simplified: assume pier_width = B/3
    pier_est = B / 3
    b_0 = 4 * (pier_est + d)
    V_punch = Pu - q_actual * (pier_est + d)^2
    τ_actual = V_punch / (b_0 * d)
    punching_ok = τ_actual ≤ ϕ_shear * τ_c
    
    return (
        bearing_ok = bearing_ok,
        bearing_utilization = ustrip(q_actual / q_allowable),
        punching_ok = punching_ok,
        punching_utilization = ustrip(τ_actual / (ϕ_shear * τ_c)),
    )
end
