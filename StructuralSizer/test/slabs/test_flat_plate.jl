# =============================================================================
# Tests for CIP Flat Plate Design
# Validates against StructurePoint 18×14 ft example (ACI 318-14)
# Reference: DE-Two-Way-Flat-Plate-Concrete-Floor-System-Analysis-and-Design-ACI-318-14-spSlab-v1000.pdf
# Version: May-07-2025
# =============================================================================

using Test
using Unitful
using Unitful: @u_str
using Asap  # Register Asap units with Unitful's @u_str
using StructuralSizer

# =============================================================================
# StructurePoint Reference Example
# =============================================================================
# Panel: 18 ft × 14 ft (N-S × E-W center-to-center)
# Columns: 16" × 16" square (f'c = 6000 psi for columns)
# Slab: h = 7" (f'c = 4000 psi, normal weight concrete)
# fy = 60,000 psi (Grade 60)
# SDL = 20 psf (partitions)
# LL = 40 psf (residential)
# Self-weight: 150 pcf × 7"/12 = 87.5 psf
# 
# Key Results from StructurePoint (DDM):
# - Clear span (long direction): ln = 18 ft - 16"/12 = 16.67 ft = 200 in
# - Factored load: qu = 193 psf = 0.193 ksf
# - Static moment: M₀ = 93.82 kip-ft
# - Average effective depth: d_avg = 5.75 in
# - Column strip width: 84 in (= l₂/2 × 12)
# - Middle strip width: 84 in
# =============================================================================

@testset "Flat Plate Design - StructurePoint Validation" begin
    
    # Material properties (slab)
    fc = 4000u"psi"
    fy = 60000u"psi"
    
    # Geometry (from StructurePoint example)
    l1 = 18u"ft"  # N-S span (longer)
    l2 = 14u"ft"  # E-W span (shorter)
    c1 = 16u"inch"  # Column size N-S
    c2 = 16u"inch"  # Column size E-W
    h = 7u"inch"    # Slab thickness
    
    @testset "Material Properties (ACI 19)" begin
        # ACI 19.2.2.1: Ec = 57000√f'c (psi)
        # For f'c = 4000 psi: Ec = 57000 × 63.25 = 3,605,000 psi = 3605 ksi
        Ec_calc = Ec(fc)
        @test ustrip(ksi, Ec_calc) ≈ 3605 rtol=0.01
        
        # ACI 22.2.2.4.3: β₁ varies with f'c
        # f'c ≤ 4000 psi: β₁ = 0.85
        @test β1(fc) == 0.85
        @test β1(5000u"psi") ≈ 0.80 atol=0.01
        @test β1(6000u"psi") ≈ 0.75 atol=0.01
        @test β1(7000u"psi") ≈ 0.70 atol=0.01
        @test β1(8000u"psi") == 0.65
        @test β1(10000u"psi") == 0.65  # Capped at 0.65
        
        # ACI 19.2.3.1: fr = 7.5√f'c (psi)
        # For f'c = 4000 psi: fr = 7.5 × 63.25 = 474.3 psi
        fr_calc = fr(fc)
        @test ustrip(u"psi", fr_calc) ≈ 474.3 rtol=0.01
    end
    
    @testset "Slab Thickness (ACI 8.3.1.1)" begin
        # Clear spans
        ln_NS = clear_span(l1, c1)  # N-S direction: 18 ft - 16"/12 = 16.67 ft
        ln_EW = clear_span(l2, c2)  # E-W direction: 14 ft - 16"/12 = 12.67 ft
        
        @test ustrip(u"ft", ln_NS) ≈ 16.67 rtol=0.01
        @test ustrip(u"ft", ln_EW) ≈ 12.67 rtol=0.01
        
        # ACI Table 8.3.1.1 - Minimum thickness for flat plates
        # Interior panels: h = ln/33
        # Exterior panels: h = ln/30
        # Longer clear span governs
        
        # Interior panel: h_min = 16.67 × 12 / 33 = 6.06" (StructurePoint uses 7")
        h_min_int = min_thickness(FlatPlate(), ln_NS; discontinuous_edge=false)
        @test ustrip(u"inch", h_min_int) ≈ 6.06 rtol=0.02
        
        # Exterior panel: h_min = 16.67 × 12 / 30 = 6.67"
        h_min_ext = min_thickness(FlatPlate(), ln_NS; discontinuous_edge=true)
        @test ustrip(u"inch", h_min_ext) ≈ 6.67 rtol=0.02
        
        # Absolute minimum = 5"
        short_span = 10u"ft"
        h_min_short = min_thickness(FlatPlate(), short_span)
        @test ustrip(u"inch", h_min_short) >= 5.0
        
        # StructurePoint uses h = 7" (satisfies both interior and exterior)
        @test h >= h_min_int
        @test h >= h_min_ext
    end
    
    @testset "Factored Loads (StructurePoint Example)" begin
        # Self-weight: 150 pcf × 7"/12 = 87.5 psf
        γ_conc = 150u"lbf/ft^3"
        sw = γ_conc * h |> psf
        @test ustrip(psf, sw) ≈ 87.5 rtol=0.01
        
        sdl = 20psf
        ll = 40psf  # StructurePoint uses 40 psf (residential)
        
        # Dead load: D = sw + SDL = 87.5 + 20 = 107.5 psf
        D = sw + sdl
        @test ustrip(psf, D) ≈ 107.5 rtol=0.01
        
        # Factored load: qu = 1.2D + 1.6L = 1.2(107.5) + 1.6(40) = 193.0 psf
        qu = 1.2 * D + 1.6 * ll
        @test ustrip(psf, qu) ≈ 193.0 rtol=0.01
    end
    
    @testset "Static Moment M₀ (ACI 8.10.3.2)" begin
        # M₀ = qu × l₂ × ln² / 8
        # From StructurePoint: qu = 0.193 ksf
        qu = 0.193ksf
        ln_NS = 16.67u"ft"  # Clear span in long direction
        
        # M0 = 0.193 × 14 × 16.67² / 8 = 93.82 kip-ft
        M0 = total_static_moment(qu, l2, ln_NS)
        @test ustrip(kip*u"ft", M0) ≈ 93.82 rtol=0.02
    end
    
    @testset "ACI DDM Longitudinal Distribution (Table 8.10.4.2)" begin
        # Verify ACI longitudinal distribution coefficients
        # End span: ext_neg = 26%, pos = 52%, int_neg = 70%
        # Interior span: neg = 65%, pos = 35%
        
        @test ACI_DDM_LONGITUDINAL.end_span.ext_neg ≈ 0.26 atol=0.01
        @test ACI_DDM_LONGITUDINAL.end_span.pos ≈ 0.52 atol=0.01
        @test ACI_DDM_LONGITUDINAL.end_span.int_neg ≈ 0.70 atol=0.01
        @test ACI_DDM_LONGITUDINAL.interior_span.neg ≈ 0.65 atol=0.01
        @test ACI_DDM_LONGITUDINAL.interior_span.pos ≈ 0.35 atol=0.01
    end
    
    @testset "Design Moments - DDM (StructurePoint Table 1)" begin
        M0 = 93.82kip*u"ft"
        
        # End span moment distribution (Table 1 from StructurePoint)
        # Exterior Negative: 0.26 × M₀ = 24.39 k-ft
        @test 0.26 * ustrip(kip*u"ft", M0) ≈ 24.39 rtol=0.02
        
        # Positive: 0.52 × M₀ = 48.79 k-ft
        @test 0.52 * ustrip(kip*u"ft", M0) ≈ 48.79 rtol=0.02
        
        # Interior Negative: 0.70 × M₀ = 65.67 k-ft
        @test 0.70 * ustrip(kip*u"ft", M0) ≈ 65.67 rtol=0.02
        
        # Interior span
        # Positive: 0.35 × M₀ = 32.84 k-ft
        @test 0.35 * ustrip(kip*u"ft", M0) ≈ 32.84 rtol=0.02
    end
    
    @testset "Moment Distribution - Full ACI DDM (StructurePoint Table 2)" begin
        M0 = 93.82kip*u"ft"
        l2_l1 = ustrip(u"ft", l2) / ustrip(u"ft", l1)  # 14/18 = 0.778
        
        # Full ACI DDM for end span
        moments_aci = distribute_moments_aci(M0, :end_span, l2_l1; edge_beam=false)
        
        # StructurePoint Table 2 values (Total Design Strip Moments):
        M_ext_neg = 0.26 * M0   # 24.39 k-ft
        M_pos = 0.52 * M0       # 48.79 k-ft
        M_int_neg = 0.70 * M0   # 65.67 k-ft
        
        # Column strip distribution (Table 2):
        # Exterior Negative: 100% to column strip (no edge beam)
        @test ustrip(kip*u"ft", moments_aci.column_strip.ext_neg) ≈ 24.39 rtol=0.05
        @test ustrip(kip*u"ft", moments_aci.middle_strip.ext_neg) ≈ 0.0 atol=0.5
        
        # Positive: 60% to column strip, 40% to middle strip
        @test ustrip(kip*u"ft", moments_aci.column_strip.pos) ≈ 29.27 rtol=0.05
        @test ustrip(kip*u"ft", moments_aci.middle_strip.pos) ≈ 19.52 rtol=0.05
        
        # Interior Negative: 75% to column strip, 25% to middle strip
        @test ustrip(kip*u"ft", moments_aci.column_strip.int_neg) ≈ 49.25 rtol=0.05
        @test ustrip(kip*u"ft", moments_aci.middle_strip.int_neg) ≈ 16.42 rtol=0.05
        
        # Interior span
        M0_int = M0  # Same M0 for comparison
        moments_int = distribute_moments_aci(M0_int, :interior_span, l2_l1)
        
        # Positive: 0.35 × M0, then 60% to column strip
        @test ustrip(kip*u"ft", moments_int.column_strip.pos) ≈ 19.70 rtol=0.05
        @test ustrip(kip*u"ft", moments_int.middle_strip.pos) ≈ 13.14 rtol=0.05
    end
    
    @testset "M-DDM Coefficients (Supplementary Doc Table S-1)" begin
        # Verify coefficient values from Broyles et al. Supplementary Document
        
        # End span coefficients
        end_cs = MDDM_COEFFICIENTS.end_span.column_strip
        end_ms = MDDM_COEFFICIENTS.end_span.middle_strip
        
        @test end_cs.ext_neg ≈ 0.27 atol=0.01
        @test end_cs.pos ≈ 0.345 atol=0.01
        @test end_cs.int_neg ≈ 0.55 atol=0.01
        @test end_ms.ext_neg ≈ 0.00 atol=0.01
        @test end_ms.pos ≈ 0.235 atol=0.01
        @test end_ms.int_neg ≈ 0.18 atol=0.01
        
        # Interior span coefficients
        int_cs = MDDM_COEFFICIENTS.interior_span.column_strip
        int_ms = MDDM_COEFFICIENTS.interior_span.middle_strip
        
        @test int_cs.neg ≈ 0.535 atol=0.01
        @test int_cs.pos ≈ 0.186 atol=0.01
        @test int_ms.neg ≈ 0.175 atol=0.01
        @test int_ms.pos ≈ 0.124 atol=0.01
        
        # Interior span coefficients should sum to ~1.0
        int_total = int_cs.neg + int_cs.pos + int_ms.neg + int_ms.pos
        @test int_total ≈ 1.02 rtol=0.02
    end
    
    @testset "Strip Widths (StructurePoint Example)" begin
        # Column strip width = l₂/2 = 14/2 = 7 ft = 84 in
        # (but not more than l₁/2)
        cs_width = min(l2, l1) / 2
        @test ustrip(u"ft", cs_width) == 7.0
        @test ustrip(u"inch", cs_width) == 84.0
        
        # Half column strip on each side = l₂/4 = 3.5 ft = 42 in
        half_cs = l2 / 4
        @test ustrip(u"ft", half_cs) == 3.5
        
        # Middle strip width also = 84 in for this example
        # (From StructurePoint: both strips are 84 in wide)
    end
    
    @testset "Reinforcement Design (ACI 22.2)" begin
        # From StructurePoint: d_avg = 5.75 in
        # d₁ = h - cover - db/2 = 7 - 0.75 - 0.5/2 = 6.0 in (top layer)
        # d₂ = h - cover - db - db/2 = 7 - 0.75 - 0.5 - 0.25 = 5.5 in (bottom layer)
        # d_avg = (d₁ + d₂) / 2 = h - cover - db = 5.75 in
        
        d = effective_depth(h; cover=0.75u"inch", bar_diameter=0.5u"inch")
        @test ustrip(u"inch", d) ≈ 5.75 rtol=0.02  # d_avg for two-way slab
        
        # Column strip width = 84 in
        b_cs = 84u"inch"
        
        # Minimum reinforcement: As,min = 0.0018 × b × h
        # = 0.0018 × 84 × 7 = 1.06 in² (matches StructurePoint Table 3)
        As_min = minimum_reinforcement(b_cs, h, fy)
        @test ustrip(u"inch^2", As_min) ≈ 1.06 rtol=0.02
        
        # Max spacing: s_max = min(2h, 18") = min(14", 18") = 14"
        s_max = max_bar_spacing(h)
        @test ustrip(u"inch", s_max) == 14.0
        
        # Design for exterior negative moment in column strip
        # Mu = 24.39 k-ft, b = 84 in, d = 5.75 in
        Mu = 24.39kip*u"ft"
        d_avg = 5.75u"inch"
        
        As_reqd = required_reinforcement(Mu, b_cs, d_avg, fc, fy)
        
        # StructurePoint: As,req = 0.96 in² < As,min = 1.06 in²
        @test ustrip(u"inch^2", As_reqd) ≈ 0.96 rtol=0.05
        @test As_reqd < As_min  # Minimum governs
    end
    
    @testset "Punching Shear (ACI 22.6)" begin
        d_avg = 5.75u"inch"
        
        # Critical section at d/2 from column face
        # b₀ = 4 × (c + d) for square interior column
        # b₀ = 4 × (16 + 5.75) = 4 × 21.75 = 87"
        b0 = punching_perimeter(c1, c2, d_avg)
        @test ustrip(u"inch", b0) ≈ 87 rtol=0.01
        
        # Punching shear capacity (ACI 22.6.5.2)
        # Vc = 4λ√f'c × b₀ × d = 4(1)(63.25)(87)(5.75) / 1000 = 126.55 kips
        Vc = punching_capacity_interior(b0, d_avg, fc; c1=c1, c2=c2)
        @test ustrip(kip, Vc) ≈ 126.55 rtol=0.05
        
        # Punching shear demand from StructurePoint
        # At = 18 × 14 = 252 ft² (tributary area)
        # Adjusted tributary = 252 - (21.75/12)² = 248.71 ft²
        qu = 0.193ksf
        At = 18u"ft" * 14u"ft"
        Vu = punching_demand(qu, At, c1, c2, d_avg)
        
        # StructurePoint: Vu = 48.00 kips
        @test ustrip(kip, Vu) ≈ 48.0 rtol=0.02
        
        # Check: φVc = 0.75 × 126.55 = 94.92 kip > Vu = 48.00 kip → OK
        check = check_punching_shear(Vu, Vc)
        @test check.ok
        @test check.ratio < 1.0
        @test check.ratio ≈ 48.0 / (0.75 * 126.55) rtol=0.05
    end
    
    @testset "Deflection Parameters (ACI 24.2)" begin
        b = 12u"inch"  # Per foot width
        
        # Gross moment of inertia: Ig = bh³/12
        # = 12 × 7³ / 12 = 343 in⁴ per foot width
        Ig = b * h^3 / 12
        @test ustrip(u"inch^4", Ig) ≈ 343 rtol=0.01
        
        # Cracking moment: Mcr = fr × Ig / yt
        # yt = h/2 = 3.5"
        # Mcr = 474.3 × 343 / 3.5 = 46,492 lb-in = 3.87 kip-ft per foot
        fr_val = fr(fc)
        Mcr = cracking_moment(fr_val, Ig, h)
        @test ustrip(kip*u"ft", Mcr) ≈ 3.87 rtol=0.05
        
        # Deflection limits (ACI Table 24.2.2)
        l = 18u"ft"  # Use longer span
        
        # Immediate deflection due to LL: l/360
        Δ_ll = deflection_limit(l, :immediate_ll)
        @test ustrip(u"inch", Δ_ll) ≈ 0.6 rtol=0.02  # 216/360 = 0.6"
        
        # Total deflection after attachment of non-structural elements: l/240
        Δ_total = deflection_limit(l, :total)
        @test ustrip(u"inch", Δ_total) ≈ 0.9 rtol=0.02  # 216/240 = 0.9"
        
        # Long-term deflection factor: λΔ = ξ / (1 + 50ρ')
        # For 5+ years (ξ = 2.0) with no compression steel (ρ' = 0):
        λΔ = long_term_deflection_factor(2.0, 0.0)
        @test λΔ == 2.0
    end
    
    @testset "Initial Column Estimate (Phase 2)" begin
        # Test the initial column size estimation
        # StructurePoint uses 16" × 16" columns for this example
        
        # For the 18×14 ft bay = 252 ft² tributary
        At = 252u"ft^2"
        qu = 193psf
        n_stories = 1  # Single story for basic check
        fc_col = 6000u"psi"  # Columns use higher f'c
        
        c = estimate_column_size(At, qu, n_stories, fc_col)
        
        # Should give reasonable column size
        @test ustrip(u"inch", c) >= 10  # Minimum practical
        @test ustrip(u"inch", c) <= 20  # Not oversized for single story
        
        # Test span-based estimate
        span = 18u"ft"
        c_span = estimate_column_size_from_span(span; ratio=15.0)
        
        # 18 ft / 15 = 1.2 ft = 14.4" → 15"
        @test ustrip(u"inch", c_span) ≈ 15 atol=2
    end
    
    @testset "Reinforcement Table Validation (StructurePoint Table 3)" begin
        # Validate against StructurePoint Table 3 - Required Slab Reinforcement for Flexure (DDM)
        # All values use b = 84 in, d = 5.75 in, As,min = 1.06 in²
        
        b = 84u"inch"
        d = 5.75u"inch"
        As_min_val = 1.06  # in²
        
        # Test cases from Table 3:
        test_cases = [
            # (Location, Mu_kft, As_req_in2)
            ("End Span CS Ext Neg", 24.39, 0.96),
            ("End Span CS Pos", 29.27, 1.16),
            ("End Span CS Int Neg", 49.25, 1.98),
            ("End Span MS Ext Neg", 0.00, 0.00),
            ("End Span MS Pos", 19.52, 0.77),
            ("End Span MS Int Neg", 16.42, 0.64),
            ("Int Span CS Pos", 19.70, 0.77),
            ("Int Span MS Pos", 13.14, 0.51),
        ]
        
        for (location, Mu_kft, As_expected) in test_cases
            if Mu_kft > 0
                Mu = Mu_kft * kip*u"ft"
                As_calc = required_reinforcement(Mu, b, d, fc, fy)
                @test ustrip(u"inch^2", As_calc) ≈ As_expected rtol=0.10
            end
        end
    end
    
    @testset "Two-Way Deflection - StructurePoint Validation (Pages 48-57)" begin
        # StructurePoint Table 9 validation for deflection calculations
        # Reference: DE-Two-Way-Flat-Plate Section 6.1
        
        # Material properties
        Ecs = 3.834e6u"psi"  # Page 50: Ec = 33 × wc^1.5 × √f'c = 3,834,000 psi
        fr_val = 474.34u"psi"  # Page 50: fr = 7.5√f'c = 474.34 psi
        Es = 29e6u"psi"
        
        # Section properties for frame strip
        Ig_frame = 4802u"inch^4"  # Page 50: l2×h³/12 = (14×12)×7³/12
        Ig_cs = 2401u"inch^4"    # Column strip: (7×12)×7³/12
        
        @test ustrip(u"inch^4", slab_moment_of_inertia(l2, h)) ≈ 4802 rtol=0.01
        @test ustrip(u"inch^4", slab_moment_of_inertia(l2/2, h)) ≈ 2401 rtol=0.01
        
        # Cracking moment (Page 50): Mcr = fr × Ig / yt = 474.34 × 4802 / 3.5 / 12000
        yt = h / 2  # 3.5 in
        Mcr = fr_val * Ig_frame / yt
        Mcr_kft = ustrip(kip*u"ft", uconvert(kip*u"ft", Mcr))
        @test Mcr_kft ≈ 54.23 rtol=0.02
        
        # Cracked moment of inertia (Page 50): Icr = 629 in⁴ for 17 #4 bars
        # n = Es/Ec = 7.56, kd = 1.18 in
        As_17_4 = 17 * 0.20u"inch^2"  # 17 #4 bars = 3.40 in²
        d_test = 5.75u"inch"
        Icr = cracked_moment_of_inertia(As_17_4, l2, d_test, Ecs, Es)
        @test ustrip(u"inch^4", Icr) ≈ 629 rtol=0.10
        
        # Effective moment of inertia (Page 52)
        # For D+L_full, Ma_neg = 64.13 k-ft at interior support
        Ma_neg = 64.13kip*u"ft"
        Ma_pos = 34.35kip*u"ft"
        Mcr_unit = 54.23kip*u"ft"
        
        # At negative section (cracked): Ie = 3,152 in⁴
        Ie_neg = effective_moment_of_inertia(Mcr_unit, Ma_neg, Ig_frame, Icr)
        @test ustrip(u"inch^4", Ie_neg) ≈ 3152 rtol=0.10
        
        # At positive section (uncracked since Mcr > Ma): Ie = Ig
        Ie_pos = effective_moment_of_inertia(Mcr_unit, Ma_pos, Ig_frame, Icr)
        @test ustrip(u"inch^4", Ie_pos) ≈ 4802 rtol=0.02
        
        # Averaged Ie for exterior span (Page 52):
        # Ie,avg = 0.85×Ie⁺ + 0.15×Ie⁻ = 4,555 in⁴
        Ie_avg_ext = 0.85 * Ie_pos + 0.15 * Ie_neg
        @test ustrip(u"inch^4", Ie_avg_ext) ≈ 4555 rtol=0.05
        
        # Load distribution factors (Page 56)
        # Exterior span: LDFc = (2×0.60 + 1.00 + 0.75)/4 = 0.738
        LDF_c_ext = load_distribution_factor(:column, :exterior)
        LDF_m_ext = load_distribution_factor(:middle, :exterior)
        
        @test LDF_c_ext ≈ 0.738 rtol=0.02
        @test LDF_m_ext ≈ 0.262 rtol=0.02
        @test LDF_c_ext + LDF_m_ext ≈ 1.0 rtol=0.01
        
        # Interior span LDFs (Page 53): LDFc = 0.675
        LDF_c_int = load_distribution_factor(:column, :interior)
        LDF_m_int = load_distribution_factor(:middle, :interior)
        
        @test LDF_c_int ≈ 0.675 rtol=0.02
        @test LDF_m_int ≈ 0.325 rtol=0.02
    end
end

println("All flat plate design tests passed!")

# =============================================================================
# Circular Column Tests
# Validates that all core slab calculations handle circular columns correctly.
# ACI 318-19 R22.6.4.1: Use equivalent square for clear span and torsional C;
# use actual circular geometry for interior punching (b₀ = π(D+d)).
# =============================================================================

@testset "Circular Column Support" begin

    D = 16u"inch"         # Circular column diameter (same area intent as 16" square)
    c_eq = equivalent_square_column(D)  # D√(π/4) ≈ 14.18"

    @testset "Equivalent Square Column" begin
        # c_eq = D × √(π/4) ≈ 0.886 D
        @test ustrip(u"inch", c_eq) ≈ 16 * sqrt(π / 4) rtol=0.001
        @test ustrip(u"inch", c_eq) ≈ 14.18 rtol=0.01

        # Area preservation: π D²/4 = c_eq²
        A_circle = π * D^2 / 4
        A_square = c_eq^2
        @test ustrip(u"inch^2", A_circle) ≈ ustrip(u"inch^2", A_square) rtol=0.001
    end

    @testset "Clear Span — Circular vs Rectangular" begin
        l1 = 18u"ft"

        # Rectangular: ln = l - c
        ln_rect = clear_span(l1, D)  # treats D as rectangular dimension
        @test ustrip(u"ft", ln_rect) ≈ 18 - 16/12 rtol=0.01

        # Circular: ln = l - c_eq (shorter deduction since c_eq < D)
        ln_circ = clear_span(l1, D; shape=:circular)
        @test ustrip(u"inch", ln_circ) ≈ ustrip(u"inch", l1) - ustrip(u"inch", c_eq) rtol=0.001

        # Circular clear span should be longer (less deduction)
        @test ln_circ > ln_rect
    end

    @testset "Punching Perimeter — Circular Interior" begin
        d = 5.75u"inch"

        # Rectangular: b₀ = 4(c+d) for square column
        b0_rect = punching_perimeter(D, D, d; shape=:rectangular)
        @test ustrip(u"inch", b0_rect) ≈ 4 * (16 + 5.75) rtol=0.001

        # Circular: b₀ = π(D+d)
        b0_circ = punching_perimeter(D, D, d; shape=:circular)
        @test ustrip(u"inch", b0_circ) ≈ π * (16 + 5.75) rtol=0.001

        # Circular perimeter < rectangular (circle minimizes perimeter for area)
        @test b0_circ < b0_rect
    end

    @testset "Punching Geometry — Circular Interior" begin
        d = 5.75u"inch"

        geom = punching_geometry_interior(D, D, d; shape=:circular)

        # b₀ = π(D+d)
        @test ustrip(u"inch", geom.b0) ≈ π * (16 + 5.75) rtol=0.001

        # b1 = b2 = b₀/4 (equivalent square sides of critical section)
        @test ustrip(u"inch", geom.b1) ≈ ustrip(u"inch", geom.b0) / 4 rtol=0.001
        @test geom.b1 ≈ geom.b2 rtol=0.001

        # cAB = b1/2
        @test geom.cAB ≈ geom.b1 / 2 rtol=0.001
    end

    @testset "Punching Capacity — Circular Interior" begin
        d = 5.75u"inch"
        fc = 4000u"psi"

        b0_circ = punching_perimeter(D, D, d; shape=:circular)
        Vc_circ = punching_capacity_interior(b0_circ, d, fc;
                    c1=D, c2=D, position=:interior, shape=:circular)

        # β = 1.0 for circular → (2+4/β) = 6 clause won't govern
        # 4√f'c should govern for circular (since β=1)
        vc_expected = 4 * sqrt(4000)  # psi
        Vc_expected = vc_expected * ustrip(u"inch", b0_circ) * ustrip(u"inch", d)
        @test ustrip(u"lbf", Vc_circ) ≈ Vc_expected rtol=0.02
    end

    @testset "Punching Demand — Circular Interior" begin
        d = 5.75u"inch"
        qu = 0.193ksf
        At = 18u"ft" * 14u"ft"

        # Rectangular deduction: (c+d)²
        Vu_rect = punching_demand(qu, At, D, D, d; shape=:rectangular)

        # Circular deduction: π(D+d)²/4
        Vu_circ = punching_demand(qu, At, D, D, d; shape=:circular)

        # Circular deduction area < rectangular → higher Vu
        @test Vu_circ > Vu_rect

        # Verify the demand formula: Vu = qu × (At - Ac)
        Ac_circ = π * (D + d)^2 / 4
        Vu_manual = qu * (At - Ac_circ)
        @test ustrip(kip, Vu_circ) ≈ ustrip(kip, Vu_manual) rtol=0.001
    end

    @testset "Punching Check — Circular vs Rectangular" begin
        d = 5.75u"inch"
        fc = 4000u"psi"
        qu = 0.193ksf
        At = 18u"ft" * 14u"ft"

        # Rectangular 16" square
        b0_rect = punching_perimeter(D, D, d; shape=:rectangular)
        Vc_rect = punching_capacity_interior(b0_rect, d, fc;
                    c1=D, c2=D, position=:interior, shape=:rectangular)
        Vu_rect = punching_demand(qu, At, D, D, d; shape=:rectangular)
        ratio_rect = ustrip(u"lbf", Vu_rect) / (0.75 * ustrip(u"lbf", Vc_rect))

        # Circular D=16"
        b0_circ = punching_perimeter(D, D, d; shape=:circular)
        Vc_circ = punching_capacity_interior(b0_circ, d, fc;
                    c1=D, c2=D, position=:interior, shape=:circular)
        Vu_circ = punching_demand(qu, At, D, D, d; shape=:circular)
        ratio_circ = ustrip(u"lbf", Vu_circ) / (0.75 * ustrip(u"lbf", Vc_circ))

        # Both should pass for this geometry
        @test ratio_rect < 1.0
        @test ratio_circ < 1.0

        # Circular column has higher utilization (less b₀, higher Vu)
        @test ratio_circ > ratio_rect
    end

    @testset "Column Moment of Inertia — Circular" begin
        # Rectangular: Ic = c1 × c2³ / 12
        Ic_rect = column_moment_of_inertia(D, D; shape=:rectangular)
        @test ustrip(u"inch^4", Ic_rect) ≈ 16^4 / 12 rtol=0.001

        # Circular: Ic = π D⁴ / 64
        Ic_circ = column_moment_of_inertia(D, D; shape=:circular)
        @test ustrip(u"inch^4", Ic_circ) ≈ π * 16^4 / 64 rtol=0.001

        # Both should be positive; ratio is 64/(12π) ≈ 1.698 (rect > circ for same D)
        @test ustrip(u"inch^4", Ic_circ) > 0
        @test ustrip(u"inch^4", Ic_rect) / ustrip(u"inch^4", Ic_circ) ≈ 64 / (12π) rtol=0.01
    end
end
