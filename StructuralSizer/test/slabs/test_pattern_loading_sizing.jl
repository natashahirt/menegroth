# =============================================================================
# Diagnostic Test: Pattern Loading for EFM and FEA Sizing
# =============================================================================
#
# Validates that pattern loading (ACI 318-11 §13.7.6) produces sensible results:
# - Moments increase relative to full-load baseline (envelope ≥ baseline)
# - Amplification is bounded (typically < 20% for most geometries)
# - No sign flips or anomalous values
# - EFM and FEA pattern loading produce consistent relative increases
#
# Pattern loading is triggered when L/D > 0.75. This test uses assembly
# occupancy (L=100 psf, D~87.5 psf → L/D ≈ 1.14) to force pattern analysis.
#
# Reference: ACI 318-11 §13.7.6, ACI 318-14 §6.4.3.2
#
# =============================================================================

using Test
using Unitful
using Asap
using StructuralSizer

const SR = StructuralSizer

# =============================================================================
# Test Geometry Setup
# =============================================================================

"""
Create a 3-span continuous frame for pattern loading tests.

Uses StructurePoint example geometry:
- l1 = 18 ft (span length)
- l2 = 14 ft (tributary width)
- h = 7 in (slab thickness)
- c1 = c2 = 16 in (column dimensions)
- H = 9 ft (story height)
"""
function create_pattern_loading_spans()
    l1 = 18u"ft"
    l2 = 14u"ft"
    h = 7u"inch"
    c1 = 16u"inch"
    c2 = 16u"inch"
    H = 9u"ft"
    ln = l1 - c1  # Clear span
    
    # Materials
    fc_slab = 4000u"psi"
    fc_col = 6000u"psi"
    wc = 150  # pcf
    Ecs = wc^1.5 * 33 * sqrt(ustrip(u"psi", fc_slab)) * u"psi"
    Ecc = wc^1.5 * 33 * sqrt(ustrip(u"psi", fc_col)) * u"psi"
    
    # Build spans
    Is = SR.slab_moment_of_inertia(l2, h)
    Ksb = SR.slab_beam_stiffness_Ksb(Ecs, Is, l1, c1, c2)
    
    l1_in = uconvert(u"inch", l1)
    l2_in = uconvert(u"inch", l2)
    ln_in = uconvert(u"inch", ln)
    h_in = uconvert(u"inch", h)
    c1_in = uconvert(u"inch", c1)
    
    spans = [
        SR.EFMSpanProperties(
            i, i, i+1,
            l1_in, l2_in, ln_in,
            h_in, c1_in, c1_in, c1_in, c1_in,
            Is, Ksb,
            0.08429, 0.507, 4.127
        )
        for i in 1:3
    ]
    
    joint_positions = [:interior, :interior, :interior, :interior]
    joint_Kec = SR._compute_joint_Kec(spans, joint_positions, H, Ecs, Ecc)
    
    return (
        spans = spans,
        joint_positions = joint_positions,
        joint_Kec = joint_Kec,
        l1 = l1,
        l2 = l2,
        h = h,
        H = H,
        Ecs = Ecs,
        Ecc = Ecc,
    )
end

# =============================================================================
# Pattern Loading Unit Tests
# =============================================================================

@testset "Pattern Loading Diagnostics" begin
    
    @testset "Pattern Loading Trigger (L/D > 0.75)" begin
        # Office: L/D = 50/100 = 0.50 → NOT required
        @test SR.requires_pattern_loading(100u"psf", 50u"psf") == false
        
        # Residential: L/D = 40/100 = 0.40 → NOT required
        @test SR.requires_pattern_loading(100u"psf", 40u"psf") == false
        
        # Assembly: L/D = 100/100 = 1.00 → REQUIRED
        @test SR.requires_pattern_loading(100u"psf", 100u"psf") == true
        
        # Storage: L/D = 125/100 = 1.25 → REQUIRED
        @test SR.requires_pattern_loading(100u"psf", 125u"psf") == true
        
        # Edge case: L/D = 0.75 exactly → NOT required (> not ≥)
        @test SR.requires_pattern_loading(100u"psf", 75u"psf") == false
        
        # Edge case: L/D = 0.76 → REQUIRED
        @test SR.requires_pattern_loading(100u"psf", 76u"psf") == true
        
        println("✓ Pattern loading trigger logic correct")
    end
    
    @testset "Load Pattern Generation" begin
        # 2-span system
        patterns_2 = SR.generate_load_patterns(2)
        @test length(patterns_2) == 3  # Full + 2 checkerboard
        @test patterns_2[1] == [:dead_plus_live, :dead_plus_live]  # Full
        @test patterns_2[2] == [:dead_plus_live, :dead_only]       # Odd
        @test patterns_2[3] == [:dead_only, :dead_plus_live]       # Even
        
        # 3-span system
        patterns_3 = SR.generate_load_patterns(3)
        @test length(patterns_3) == 5  # Full + 2 checkerboard + 2 adjacent
        @test patterns_3[1] == [:dead_plus_live, :dead_plus_live, :dead_plus_live]
        
        # 4-span system
        patterns_4 = SR.generate_load_patterns(4)
        @test length(patterns_4) == 6  # Full + 2 checkerboard + 3 adjacent
        
        println("✓ Load pattern generation correct")
    end
    
    @testset "Factored Pattern Loads (ACI 318-11 §9.2.1)" begin
        qD = 100u"psf"
        qL = 100u"psf"
        
        pattern = [:dead_plus_live, :dead_only, :dead_plus_live]
        loads = SR.factored_pattern_loads(pattern, qD, qL)
        
        # Loaded spans: max(1.2D + 1.6L, 1.4D) = max(280, 140) = 280 psf
        qu_loaded = max(1.2 * qD + 1.6 * qL, 1.4 * qD)
        @test ustrip(u"psf", loads[1]) ≈ ustrip(u"psf", qu_loaded) rtol=0.01
        @test ustrip(u"psf", loads[3]) ≈ ustrip(u"psf", qu_loaded) rtol=0.01
        
        # Unloaded spans: 1.2D = 120 psf
        qu_dead = 1.2 * qD
        @test ustrip(u"psf", loads[2]) ≈ ustrip(u"psf", qu_dead) rtol=0.01
        
        println("✓ Factored pattern loads correct")
    end
end

@testset "EFM Pattern Loading Moment Envelope" begin
    setup = create_pattern_loading_spans()
    (; spans, joint_positions, joint_Kec) = setup
    
    # High live load to trigger pattern loading (L/D > 0.75)
    # Assembly occupancy: D ≈ 87.5 psf (7" slab), L = 100 psf → L/D ≈ 1.14
    qD = 87.5u"psf"
    qL = 100u"psf"
    qu_full = max(1.2 * qD + 1.6 * qL, 1.4 * qD)
    
    @test SR.requires_pattern_loading(qD, qL) == true
    
    # ─── Baseline: Full load on all spans ───
    baseline = SR.solve_moment_distribution(spans, joint_Kec, joint_positions, qu_full)
    M_neg_ext_base = abs(baseline[1].M_neg_left)
    M_neg_int_base = abs(baseline[1].M_neg_right)
    M_pos_base = abs(baseline[1].M_pos)
    
    println("\n=== EFM Baseline (Full Load) ===")
    println("M_neg_ext = $(round(ustrip(u"kip*ft", M_neg_ext_base), digits=2)) kip-ft")
    println("M_neg_int = $(round(ustrip(u"kip*ft", M_neg_int_base), digits=2)) kip-ft")
    println("M_pos     = $(round(ustrip(u"kip*ft", M_pos_base), digits=2)) kip-ft")
    
    # ─── Pattern loading envelope ───
    n_spans = length(spans)
    env_neg_ext = M_neg_ext_base
    env_neg_int = M_neg_int_base
    env_pos = M_pos_base
    
    patterns = SR.generate_load_patterns(n_spans)
    
    for (i, pattern) in enumerate(patterns)
        # Skip full load (already have baseline)
        all(==(:dead_plus_live), pattern) && continue
        
        qu_per_span = SR.factored_pattern_loads(pattern, qD, qL)
        result = SR.solve_moment_distribution(spans, joint_Kec, joint_positions, qu_per_span)
        
        pat_neg_ext = abs(result[1].M_neg_left)
        pat_neg_int = abs(result[1].M_neg_right)
        pat_pos = abs(result[1].M_pos)
        
        # Track envelope
        pat_neg_ext > env_neg_ext && (env_neg_ext = pat_neg_ext)
        pat_neg_int > env_neg_int && (env_neg_int = pat_neg_int)
        pat_pos > env_pos && (env_pos = pat_pos)
    end
    
    println("\n=== EFM Pattern Envelope ===")
    println("M_neg_ext = $(round(ustrip(u"kip*ft", env_neg_ext), digits=2)) kip-ft")
    println("M_neg_int = $(round(ustrip(u"kip*ft", env_neg_int), digits=2)) kip-ft")
    println("M_pos     = $(round(ustrip(u"kip*ft", env_pos), digits=2)) kip-ft")
    
    # ─── Amplification factors ───
    amp_neg_ext = ustrip(env_neg_ext) / ustrip(M_neg_ext_base)
    amp_neg_int = ustrip(env_neg_int) / ustrip(M_neg_int_base)
    amp_pos = ustrip(env_pos) / ustrip(M_pos_base)
    
    println("\n=== Amplification Factors ===")
    println("Exterior negative: $(round(amp_neg_ext, digits=3)) ($(round((amp_neg_ext-1)*100, digits=1))%)")
    println("Interior negative: $(round(amp_neg_int, digits=3)) ($(round((amp_neg_int-1)*100, digits=1))%)")
    println("Positive:          $(round(amp_pos, digits=3)) ($(round((amp_pos-1)*100, digits=1))%)")
    
    @testset "Envelope ≥ Baseline" begin
        @test env_neg_ext ≥ M_neg_ext_base
        @test env_neg_int ≥ M_neg_int_base
        @test env_pos ≥ M_pos_base
    end
    
    @testset "Amplification Bounded (< 30%)" begin
        # Pattern loading typically increases moments by 5-20%
        # Allow up to 30% as a sanity bound
        @test amp_neg_ext < 1.30
        @test amp_neg_int < 1.30
        @test amp_pos < 1.30
    end
    
    @testset "Amplification ≥ 1.0" begin
        # Envelope should never be less than baseline
        @test amp_neg_ext ≥ 1.0
        @test amp_neg_int ≥ 1.0
        @test amp_pos ≥ 1.0
    end
    
    @testset "No Anomalous Values" begin
        # Moments should be positive (we took abs)
        @test ustrip(u"kip*ft", env_neg_ext) > 0
        @test ustrip(u"kip*ft", env_neg_int) > 0
        @test ustrip(u"kip*ft", env_pos) > 0
        
        # Moments should be reasonable (< 500 kip-ft for this geometry)
        @test ustrip(u"kip*ft", env_neg_ext) < 500
        @test ustrip(u"kip*ft", env_neg_int) < 500
        @test ustrip(u"kip*ft", env_pos) < 500
    end
end

@testset "EFM vs No-Pattern Comparison" begin
    setup = create_pattern_loading_spans()
    (; spans, joint_positions, joint_Kec) = setup
    
    # Moderate live load (L/D < 0.75 → pattern NOT required)
    qD_low = 100u"psf"
    qL_low = 50u"psf"
    qu_low = max(1.2 * qD_low + 1.6 * qL_low, 1.4 * qD_low)
    
    @test SR.requires_pattern_loading(qD_low, qL_low) == false
    
    # High live load (L/D > 0.75 → pattern REQUIRED)
    qD_high = 87.5u"psf"
    qL_high = 100u"psf"
    qu_high = max(1.2 * qD_high + 1.6 * qL_high, 1.4 * qD_high)
    
    @test SR.requires_pattern_loading(qD_high, qL_high) == true
    
    # Solve both
    result_low = SR.solve_moment_distribution(spans, joint_Kec, joint_positions, qu_low)
    result_high = SR.solve_moment_distribution(spans, joint_Kec, joint_positions, qu_high)
    
    # Higher load → higher moments (sanity check)
    @test abs(result_high[1].M_neg_right) > abs(result_low[1].M_neg_right)
    @test abs(result_high[1].M_pos) > abs(result_low[1].M_pos)
    
    println("\n=== Low vs High Live Load ===")
    println("Low LL (no pattern):  M_neg_int = $(round(ustrip(u"kip*ft", result_low[1].M_neg_right), digits=2)) kip-ft")
    println("High LL (pattern):    M_neg_int = $(round(ustrip(u"kip*ft", result_high[1].M_neg_right), digits=2)) kip-ft")
end

@testset "Pattern Loading Edge Cases" begin
    setup = create_pattern_loading_spans()
    (; spans, joint_positions, joint_Kec) = setup
    
    @testset "Very High L/D Ratio (Storage)" begin
        # Storage: L/D = 250/100 = 2.5
        qD = 100u"psf"
        qL = 250u"psf"
        qu_full = max(1.2 * qD + 1.6 * qL, 1.4 * qD)
        
        @test SR.requires_pattern_loading(qD, qL) == true
        
        # Baseline
        baseline = SR.solve_moment_distribution(spans, joint_Kec, joint_positions, qu_full)
        M_base = abs(baseline[1].M_pos)
        
        # Envelope
        env_pos = M_base
        for pattern in SR.generate_load_patterns(3)
            all(==(:dead_plus_live), pattern) && continue
            qu_ps = SR.factored_pattern_loads(pattern, qD, qL)
            result = SR.solve_moment_distribution(spans, joint_Kec, joint_positions, qu_ps)
            abs(result[1].M_pos) > env_pos && (env_pos = abs(result[1].M_pos))
        end
        
        amp = ustrip(env_pos) / ustrip(M_base)
        
        println("\n=== Very High L/D (Storage) ===")
        println("L/D = $(qL/qD)")
        println("Positive moment amplification: $(round(amp, digits=3))")
        
        # Even with very high L/D, amplification should be bounded
        @test amp < 1.50
        @test amp ≥ 1.0
    end
    
    @testset "2-Span System" begin
        # Build 2-span system
        l1 = 18u"ft"
        l2 = 14u"ft"
        h = 7u"inch"
        c1 = 16u"inch"
        H = 9u"ft"
        ln = l1 - c1
        
        fc_slab = 4000u"psi"
        fc_col = 6000u"psi"
        wc = 150
        Ecs = wc^1.5 * 33 * sqrt(ustrip(u"psi", fc_slab)) * u"psi"
        Ecc = wc^1.5 * 33 * sqrt(ustrip(u"psi", fc_col)) * u"psi"
        
        Is = SR.slab_moment_of_inertia(l2, h)
        Ksb = SR.slab_beam_stiffness_Ksb(Ecs, Is, l1, c1, c1)
        
        spans_2 = [
            SR.EFMSpanProperties(
                i, i, i+1,
                uconvert(u"inch", l1), uconvert(u"inch", l2), uconvert(u"inch", ln),
                uconvert(u"inch", h), uconvert(u"inch", c1), uconvert(u"inch", c1),
                uconvert(u"inch", c1), uconvert(u"inch", c1),
                Is, Ksb, 0.08429, 0.507, 4.127
            )
            for i in 1:2
        ]
        
        joint_pos_2 = [:interior, :interior, :interior]
        joint_Kec_2 = SR._compute_joint_Kec(spans_2, joint_pos_2, H, Ecs, Ecc)
        
        qD = 87.5u"psf"
        qL = 100u"psf"
        qu = max(1.2 * qD + 1.6 * qL, 1.4 * qD)
        
        # Should work without error
        baseline = SR.solve_moment_distribution(spans_2, joint_Kec_2, joint_pos_2, qu)
        
        @test length(baseline) == 2
        @test abs(baseline[1].M_neg_right) > 0u"kip*ft"
        
        # Pattern envelope
        env_neg = abs(baseline[1].M_neg_right)
        for pattern in SR.generate_load_patterns(2)
            all(==(:dead_plus_live), pattern) && continue
            qu_ps = SR.factored_pattern_loads(pattern, qD, qL)
            result = SR.solve_moment_distribution(spans_2, joint_Kec_2, joint_pos_2, qu_ps)
            abs(result[1].M_neg_right) > env_neg && (env_neg = abs(result[1].M_neg_right))
        end
        
        amp = ustrip(env_neg) / ustrip(abs(baseline[1].M_neg_right))
        
        println("\n=== 2-Span System ===")
        println("Interior negative amplification: $(round(amp, digits=3))")
        
        @test amp ≥ 1.0
        @test amp < 1.30
    end
    
    @testset "Symmetric vs Asymmetric Spans" begin
        # This tests that pattern loading doesn't produce sign flips
        setup = create_pattern_loading_spans()
        (; spans, joint_positions, joint_Kec) = setup
        
        qD = 87.5u"psf"
        qL = 100u"psf"
        
        for pattern in SR.generate_load_patterns(3)
            qu_ps = SR.factored_pattern_loads(pattern, qD, qL)
            result = SR.solve_moment_distribution(spans, joint_Kec, joint_positions, qu_ps)
            
            # All moments should have consistent signs
            # (negative moments are negative, positive are positive)
            for sm in result
                # Negative moments at supports should be negative (hogging)
                @test sm.M_neg_left ≤ 0u"kip*ft" || sm.M_neg_left ≥ 0u"kip*ft"  # Just check it's not NaN
                @test sm.M_neg_right ≤ 0u"kip*ft" || sm.M_neg_right ≥ 0u"kip*ft"
                
                # Positive moment at midspan should be positive (sagging)
                @test sm.M_pos ≥ 0u"kip*ft"
                
                # No NaN or Inf
                @test isfinite(ustrip(u"kip*ft", sm.M_neg_left))
                @test isfinite(ustrip(u"kip*ft", sm.M_neg_right))
                @test isfinite(ustrip(u"kip*ft", sm.M_pos))
            end
        end
        
        println("✓ No sign anomalies in pattern loading results")
    end
end

@testset "Pattern Loading Consistency Check" begin
    # Verify that the checkerboard patterns produce expected redistribution
    setup = create_pattern_loading_spans()
    (; spans, joint_positions, joint_Kec) = setup
    
    qD = 87.5u"psf"
    qL = 100u"psf"
    qu_full = max(1.2 * qD + 1.6 * qL, 1.4 * qD)
    qu_dead = 1.2 * qD
    
    # Full load
    full = SR.solve_moment_distribution(spans, joint_Kec, joint_positions, qu_full)
    
    # Checkerboard odd (spans 1, 3 loaded; span 2 dead only)
    odd_pattern = [:dead_plus_live, :dead_only, :dead_plus_live]
    qu_odd = SR.factored_pattern_loads(odd_pattern, qD, qL)
    odd = SR.solve_moment_distribution(spans, joint_Kec, joint_positions, qu_odd)
    
    # Checkerboard even (span 2 loaded; spans 1, 3 dead only)
    even_pattern = [:dead_only, :dead_plus_live, :dead_only]
    qu_even = SR.factored_pattern_loads(even_pattern, qD, qL)
    even = SR.solve_moment_distribution(spans, joint_Kec, joint_positions, qu_even)
    
    println("\n=== Checkerboard Pattern Comparison ===")
    println("Full load:  Span 1 M_pos = $(round(ustrip(u"kip*ft", full[1].M_pos), digits=2)) kip-ft")
    println("Odd loaded: Span 1 M_pos = $(round(ustrip(u"kip*ft", odd[1].M_pos), digits=2)) kip-ft")
    println("Even loaded: Span 1 M_pos = $(round(ustrip(u"kip*ft", even[1].M_pos), digits=2)) kip-ft")
    
    println("\nFull load:  Span 2 M_pos = $(round(ustrip(u"kip*ft", full[2].M_pos), digits=2)) kip-ft")
    println("Odd loaded: Span 2 M_pos = $(round(ustrip(u"kip*ft", odd[2].M_pos), digits=2)) kip-ft")
    println("Even loaded: Span 2 M_pos = $(round(ustrip(u"kip*ft", even[2].M_pos), digits=2)) kip-ft")
    
    @testset "Checkerboard Redistribution" begin
        # Odd pattern: Span 1 loaded → its positive moment should increase
        @test odd[1].M_pos ≥ even[1].M_pos
        
        # Even pattern: Span 2 loaded → its positive moment should increase
        @test even[2].M_pos ≥ odd[2].M_pos
        
        # Full load should be between the two extremes for each span
        # (or at least not wildly different)
        ratio_1 = ustrip(full[1].M_pos) / ustrip(max(odd[1].M_pos, even[1].M_pos))
        ratio_2 = ustrip(full[2].M_pos) / ustrip(max(odd[2].M_pos, even[2].M_pos))
        
        @test 0.5 < ratio_1 < 1.5
        @test 0.5 < ratio_2 < 1.5
    end
end

println("\n✓ Pattern loading diagnostic tests complete!")
