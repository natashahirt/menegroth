# ==============================================================================
# Tests for ACI 318-19 Column P-M Interaction
# ==============================================================================
# Verified against StructurePoint Design Example:
# "Interaction Diagram - Tied Reinforced Concrete Column Design Strength (ACI 318-19)"
# Source: https://structurepoint.org/publication/design-examples.asp
# Version: May-24-2022

using Test
using Unitful
using StructuralSizer
using Asap: ksi

# Load verified StructurePoint test data (guard against redefinition)
if !@isdefined(TIED_16X16_SPCOLUMN)
    include("test_data/tied_column_16x16.jl")
end

@testset "Column P-M Interaction (StructurePoint Verification)" begin

    # ==========================================================================
    # Test Setup: Create section matching StructurePoint example exactly
    # ==========================================================================
    
    data = TIED_16X16_SPCOLUMN
    
    # Key parameters from PDF:
    # - Column: 16" × 16"
    # - Cover to bar center: 2.5" (d' = 2.5", d = 13.5")
    # - Reinforcement: 8 #9 bars (4 top + 4 bottom, TWO LAYERS only)
    # - f'c = 5 ksi, fy = 60 ksi
    
    # Calculate clear cover to match d' = 2.5" to bar center
    # edge_to_center = cover + tie_diam + bar_diam/2
    # 2.5 = cover + 0.5 + 0.564
    # cover = 2.5 - 1.064 = 1.436"
    cover = 1.436u"inch"
    
    section = RCColumnSection(
        b = 16u"inch",
        h = 16u"inch",
        bar_size = 9,
        n_bars = 8,
        cover = cover,
        tie_type = :tied,
        arrangement = :two_layer  # Critical: PDF uses 2 layers, not perimeter!
    )
    
    # Material properties as NamedTuple
    mat = data.materials
    
    # ==========================================================================
    # Verify Section Setup Matches PDF
    # ==========================================================================
    @testset "Section Setup Verification" begin
        # Gross area: 16 × 16 = 256 in²
        @test ustrip(u"inch^2", StructuralSizer.section_area(section)) ≈ 256.0 rtol=0.001
        
        # Total steel area: 8 × 1.00 = 8.0 in²
        @test ustrip(u"inch^2", section.As_total) ≈ 8.0 rtol=0.001
        
        # Verify bar arrangement: 4 bottom, 4 top (TWO LAYERS)
        y_coords = sort([ustrip(u"inch", bar.y) for bar in section.bars])
        @test count(y -> y ≈ 2.5, y_coords) == 4   # 4 bottom bars at d' = 2.5"
        @test count(y -> y ≈ 13.5, y_coords) == 4  # 4 top bars at d = 13.5" from bottom
        
        # Effective depth d = h - d' = 16 - 2.5 = 13.5"
        d_calc = ustrip(u"inch", StructuralSizer.effective_depth(section))
        @test d_calc ≈ 13.5 rtol=0.01
        
        # Compression steel depth d' = 2.5"
        d_prime_calc = ustrip(u"inch", StructuralSizer.compression_steel_depth(section))
        @test d_prime_calc ≈ 2.5 rtol=0.01
    end
    
    # ==========================================================================
    # Test 1: β₁ Factor (ACI 318-19 Table 22.2.2.4.3)
    # ==========================================================================
    @testset "Beta1 Factor" begin
        # f'c ≤ 4 ksi → β₁ = 0.85
        @test StructuralSizer.beta1(3.0ksi) == 0.85
        @test StructuralSizer.beta1(4.0ksi) == 0.85
        
        # f'c = 5 ksi → β₁ = 0.85 - 0.05(5-4)/1 = 0.80 (from PDF)
        @test StructuralSizer.beta1(5.0ksi) ≈ 0.80
        
        # f'c = 6 ksi → β₁ = 0.85 - 0.05(6-4) = 0.75
        @test StructuralSizer.beta1(6.0ksi) ≈ 0.75 atol=1e-6
        
        # f'c ≥ 8 ksi → β₁ = 0.65 (minimum)
        @test StructuralSizer.beta1(8.0ksi) ≈ 0.65 atol=1e-6
        @test StructuralSizer.beta1(10.0ksi) ≈ 0.65 atol=1e-6
    end
    
    # ==========================================================================
    # Test 2: Neutral Axis Calculation
    # ==========================================================================
    @testset "Neutral Axis from Strain" begin
        d = 13.5      # in (from PDF)
        εcu = 0.003   # in/in (ACI 318-19 22.2.2.1)
        εy = 60.0 / 29000.0  # = 0.00207
        
        # At fs = 0 (εt = 0): c = d = 13.5"
        c_zero = StructuralSizer.c_from_εt(0.0, d, εcu)
        @test c_zero ≈ d rtol=0.001
        
        # At balanced (εt = εy = 0.00207): 
        # c = d × εcu / (εcu + εt) = 13.5 × 0.003 / 0.00507 = 7.99" (from PDF)
        c_balanced = StructuralSizer.c_from_εt(εy, d, εcu)
        @test c_balanced ≈ 7.99 rtol=0.01
        
        # At tension-controlled (εt = εy + 0.003 = 0.00507):
        # c = 13.5 × 0.003 / (0.00507 + 0.003) = 5.02" (from PDF)
        c_tension = StructuralSizer.c_from_εt(0.00507, d, εcu)
        @test c_tension ≈ 5.02 rtol=0.01
    end
    
    # ==========================================================================
    # Test 3: Pure Compression Capacity P₀ (ACI 318-19 22.4.2.2)
    # ==========================================================================
    @testset "Pure Compression P0" begin
        # From PDF: P₀ = 0.85 × f'c × (Ag - Ast) + fy × Ast
        # P₀ = 0.85 × 5000 × (256 - 8) + 60000 × 8 = 1,054,000 + 480,000 = 1,534,000 lb
        # P₀ = 1534.0 kip (matches PDF exactly)
        
        P0 = StructuralSizer.pure_compression_capacity(section, mat)
        @test P0 ≈ 1534.0 rtol=0.001  # Must match PDF within 0.1%
        
        # Max compression = 0.80 × φP₀ per ACI Table 22.4.2.1
        # φP₀ = 0.65 × 1534.0 = 997.1 kip
        # Pn,max = 0.80 × 997.1 = 797.7 kip
        Pn_max = StructuralSizer.max_compression_capacity(section, mat)
        # Note: max_compression_capacity returns 0.80 × P₀ (nominal)
        @test Pn_max ≈ 0.80 * 1534.0 rtol=0.001
    end
    
    # ==========================================================================
    # Test 4: Steel Strain Calculation
    # ==========================================================================
    @testset "Steel Strain" begin
        h = 16.0      # section depth
        εcu = 0.003
        
        # From PDF at c = 13.5 (fs = 0 case):
        # Compression steel at d' = 2.5" from top:
        # ε = εcu × (c - d') / c = 0.003 × (13.5 - 2.5) / 13.5 = 0.00244
        ε_comp = StructuralSizer.calculate_steel_strain(2.5, 13.5, h, εcu)
        @test ε_comp ≈ -0.00244 rtol=0.01  # Negative = compression
        
        # Tension steel at d = 13.5" from top (y_bar_from_top = 13.5):
        # At c = 13.5, bar is at neutral axis: ε = 0
        ε_at_na = StructuralSizer.calculate_steel_strain(13.5, 13.5, h, εcu)
        @test abs(ε_at_na) < 1e-10
        
        # At balanced (c = 7.99), tension steel strain = εy = 0.00207
        ε_balanced = StructuralSizer.calculate_steel_strain(13.5, 7.99, h, εcu)
        @test ε_balanced ≈ 0.00207 rtol=0.02
    end
    
    # ==========================================================================
    # Test 5: Steel Stress (Elastic-Perfectly-Plastic)
    # ==========================================================================
    @testset "Steel Stress" begin
        fy = 60.0     # ksi
        Es = 29000.0  # ksi
        εy = fy / Es  # ≈ 0.00207
        
        # Elastic (below yield)
        @test StructuralSizer.calculate_steel_stress(0.001, fy, Es) ≈ 29.0 rtol=0.001
        
        # At yield
        @test StructuralSizer.calculate_steel_stress(εy, fy, Es) ≈ fy rtol=0.001
        
        # Beyond yield (capped at fy)
        @test StructuralSizer.calculate_steel_stress(0.01, fy, Es) ≈ fy rtol=0.001
        
        # Compression
        @test StructuralSizer.calculate_steel_stress(-0.001, fy, Es) ≈ -29.0 rtol=0.001
        @test StructuralSizer.calculate_steel_stress(-0.01, fy, Es) ≈ -fy rtol=0.001
    end
    
    # ==========================================================================
    # Test 6: P-M at Control Points - Verify Against StructurePoint
    # ==========================================================================
    @testset "P-M Control Points vs StructurePoint" begin
        cp = data.control_points
        
        # ------------------------------------------------------------------
        # Point 1: Maximum Compression (c → ∞, entire section compressed)
        # PDF: Pn = 1534.0 kip, Mn = 0 kip-ft
        # ------------------------------------------------------------------
        result_p0 = StructuralSizer.calculate_PM_at_c(section, mat, 100.0)
        @test result_p0.Pn ≈ cp.pure_compression.Pn rtol=0.005
        @test result_p0.Mn < 1.0  # Essentially zero moment
        
        # ------------------------------------------------------------------
        # Point 2: fs = 0 (c = d = 13.5")
        # PDF: Pn = 957.4 kip, Mn = 261.33 kip-ft
        # ------------------------------------------------------------------
        result_fs0 = StructuralSizer.calculate_PM_at_c(section, mat, 13.5)
        @test result_fs0.Pn ≈ cp.fs_zero.Pn rtol=0.02
        @test result_fs0.Mn ≈ cp.fs_zero.Mn rtol=0.02
        @test result_fs0.εt ≈ 0.0 atol=0.0001
        
        # ------------------------------------------------------------------
        # Point 3: fs = 0.5fy (c = 10.04")
        # PDF: Pn = 649.1 kip, Mn = 338.54 kip-ft
        # ------------------------------------------------------------------
        result_half = StructuralSizer.calculate_PM_at_c(section, mat, 10.04)
        @test result_half.Pn ≈ cp.fs_half_fy.Pn rtol=0.02
        @test result_half.Mn ≈ cp.fs_half_fy.Mn rtol=0.02
        
        # ------------------------------------------------------------------
        # Point 4: Balanced (fs = fy, c = 7.99")
        # PDF: Pn = 416.8 kip, Mn = 385.81 kip-ft
        # ------------------------------------------------------------------
        result_balanced = StructuralSizer.calculate_PM_at_c(section, mat, 7.99)
        @test result_balanced.Pn ≈ cp.balanced.Pn rtol=0.02
        @test result_balanced.Mn ≈ cp.balanced.Mn rtol=0.02
        
        # ------------------------------------------------------------------
        # Point 5: Tension Controlled (εt = 0.00507, c = 5.02")
        # PDF: Pn = 190.7 kip, Mn = 318.61 kip-ft
        # ------------------------------------------------------------------
        result_tension = StructuralSizer.calculate_PM_at_c(section, mat, 5.02)
        @test result_tension.Pn ≈ cp.tension_controlled.Pn rtol=0.02
        @test result_tension.Mn ≈ cp.tension_controlled.Mn rtol=0.02
        
        # ------------------------------------------------------------------
        # Point 6: Pure Bending (Pn ≈ 0, c = 3.25")
        # PDF: Pn ≈ 0 kip, Mn = 237.73 kip-ft
        # ------------------------------------------------------------------
        result_pure_m = StructuralSizer.calculate_PM_at_c(section, mat, 3.25)
        @test abs(result_pure_m.Pn) < 5.0  # Should be near zero
        @test result_pure_m.Mn ≈ cp.pure_bending.Mn rtol=0.02
    end
    
    # ==========================================================================
    # Test 7: Intermediate Calculation Values (Debugging)
    # ==========================================================================
    @testset "Intermediate Values at Balanced Point" begin
        # At balanced (c = 7.99"), verify intermediate calculations from PDF
        inter = data.intermediate.balanced
        β₁ = 0.80
        
        # Stress block depth a = β₁ × c = 0.80 × 7.99 = 6.39"
        a_calc = β₁ * 7.99
        @test a_calc ≈ inter.a rtol=0.01
        
        # Concrete compression Cc = 0.85 × f'c × a × b
        # Cc = 0.85 × 5 × 6.39 × 16 = 434.6 kip
        Cc_calc = 0.85 * 5.0 * a_calc * 16.0
        @test Cc_calc ≈ inter.Cc rtol=0.01
        
        # Compression steel strain (at d' = 2.5" from top)
        # ε = 0.003 × (c - d') / c = 0.003 × (7.99 - 2.5) / 7.99 = 0.00206
        ε_comp = 0.003 * (7.99 - 2.5) / 7.99
        @test ε_comp ≈ inter.εs_compression rtol=0.02
        
        # Compression steel stress (not yielded since ε < εy)
        εy = 60.0 / 29000.0  # = 0.00207
        @test ε_comp < εy  # Verify compression steel hasn't yielded
        fs_comp_ksi = ε_comp * 29000.0  # ksi
        fs_comp_psi = fs_comp_ksi * 1000  # convert to psi for comparison
        @test fs_comp_psi ≈ inter.fs_compression rtol=0.02
        
        # Compression steel force: Cs = (fs - 0.85*f'c) × As
        # Cs = (59778 - 0.85×5000) × 4 = (59778 - 4250) × 4 = 222.1 kip
        Cs_calc = (fs_comp_ksi - 0.85 * 5.0) * 4.0  # ksi units, 4 bars = kip
        @test Cs_calc ≈ inter.Cs rtol=0.02
        
        # Tension steel force: Ts = fy × As = 60 × 4 = 240 kip
        @test inter.Ts ≈ 240.0 rtol=0.001
    end
    
    # ==========================================================================
    # Test 8: φ Factor (ACI 318-19 Table 21.2.2)
    # ==========================================================================
    @testset "Phi Factor" begin
        # Yield strain for Grade 60: εy = 60/29000 = 0.00207
        εy = 60.0 / 29000.0
        fy_ksi = 60.0
        Es_ksi = 29000.0
        
        # Compression controlled (εt ≤ εy)
        @test StructuralSizer.phi_factor(0.0, :tied; fy_ksi, Es_ksi) ≈ 0.65
        @test StructuralSizer.phi_factor(εy, :tied; fy_ksi, Es_ksi) ≈ 0.65
        @test StructuralSizer.phi_factor(0.0, :spiral; fy_ksi, Es_ksi) ≈ 0.75
        
        # Tension controlled (εt ≥ εy + 0.003 = 0.00507)
        @test StructuralSizer.phi_factor(0.00507, :tied; fy_ksi, Es_ksi) ≈ 0.90
        @test StructuralSizer.phi_factor(0.01, :tied; fy_ksi, Es_ksi) ≈ 0.90
        @test StructuralSizer.phi_factor(0.00507, :spiral; fy_ksi, Es_ksi) ≈ 0.90
        
        # Transition zone: φ = 0.65 + 0.25(εt - εy)/0.003 for tied
        # At εt = εy + 0.0015 (midpoint): φ = 0.65 + 0.25 × 0.5 = 0.775
        εt_mid = εy + 0.0015
        @test StructuralSizer.phi_factor(εt_mid, :tied; fy_ksi, Es_ksi) ≈ 0.775 rtol=0.01
        
        # For spiral: φ = 0.75 + 0.15(εt - εy)/0.003
        # At midpoint: φ = 0.75 + 0.15 × 0.5 = 0.825
        @test StructuralSizer.phi_factor(εt_mid, :spiral; fy_ksi, Es_ksi) ≈ 0.825 rtol=0.01
    end
    
    # ==========================================================================
    # Test 9: Factored Capacities vs StructurePoint
    # ==========================================================================
    @testset "Factored Capacities (φPn, φMn)" begin
        cp = data.control_points
        
        # Maximum compression: φ = 0.65
        result_p0 = StructuralSizer.calculate_phi_PM_at_c(section, mat, 100.0)
        @test result_p0.φ ≈ 0.65 rtol=0.001
        @test result_p0.φPn ≈ cp.pure_compression.φPn rtol=0.01
        
        # fs = 0: φ = 0.65 (compression controlled)
        result_fs0 = StructuralSizer.calculate_phi_PM_at_c(section, mat, 13.5)
        @test result_fs0.φ ≈ 0.65 rtol=0.001
        @test result_fs0.φPn ≈ cp.fs_zero.φPn rtol=0.02
        @test result_fs0.φMn ≈ cp.fs_zero.φMn rtol=0.02
        
        # Balanced: φ = 0.65 (just at yield, still compression controlled)
        result_balanced = StructuralSizer.calculate_phi_PM_at_c(section, mat, 7.99)
        @test result_balanced.φ ≈ 0.65 rtol=0.01
        @test result_balanced.φPn ≈ cp.balanced.φPn rtol=0.02
        @test result_balanced.φMn ≈ cp.balanced.φMn rtol=0.02
        
        # Tension controlled: φ = 0.90
        result_tension = StructuralSizer.calculate_phi_PM_at_c(section, mat, 5.02)
        @test result_tension.φ ≈ 0.90 rtol=0.01
        @test result_tension.φPn ≈ cp.tension_controlled.φPn rtol=0.02
        @test result_tension.φMn ≈ cp.tension_controlled.φMn rtol=0.02
        
        # Pure bending: φ = 0.90
        result_pure_m = StructuralSizer.calculate_phi_PM_at_c(section, mat, 3.25)
        @test result_pure_m.φ ≈ 0.90 rtol=0.01
        @test result_pure_m.φMn ≈ cp.pure_bending.φMn rtol=0.02
    end
    
    # ==========================================================================
    # Test 10: Full P-M Diagram Generation
    # ==========================================================================
    @testset "P-M Diagram Generation" begin
        cp = data.control_points
        
        # Generate diagram
        diagram = StructuralSizer.generate_PM_diagram(section, mat; n_intermediate=0)
        
        # Should have 8 control points (per StructurePoint methodology + max compression)
        ctrl_pts = StructuralSizer.get_control_points(diagram)
        @test length(ctrl_pts) >= 7
        
        # Verify control point values match StructurePoint
        # Pure compression (P₀)
        pt_p0 = StructuralSizer.get_control_point(diagram, :pure_compression)
        @test pt_p0.Pn ≈ cp.pure_compression.Pn rtol=0.01
        @test pt_p0.φPn ≈ cp.pure_compression.φPn rtol=0.01
        
        # fs = 0
        pt_fs0 = StructuralSizer.get_control_point(diagram, :fs_zero)
        @test pt_fs0.Pn ≈ cp.fs_zero.Pn rtol=0.02
        @test pt_fs0.Mn ≈ cp.fs_zero.Mn rtol=0.02
        @test pt_fs0.φPn ≈ cp.fs_zero.φPn rtol=0.02
        @test pt_fs0.φMn ≈ cp.fs_zero.φMn rtol=0.02
        
        # Balanced point
        pt_bal = StructuralSizer.get_control_point(diagram, :balanced)
        @test pt_bal.Pn ≈ cp.balanced.Pn rtol=0.02
        @test pt_bal.Mn ≈ cp.balanced.Mn rtol=0.02
        @test pt_bal.φPn ≈ cp.balanced.φPn rtol=0.02
        @test pt_bal.φMn ≈ cp.balanced.φMn rtol=0.02
        
        # Tension controlled
        pt_tens = StructuralSizer.get_control_point(diagram, :tension_controlled)
        @test pt_tens.Pn ≈ cp.tension_controlled.Pn rtol=0.02
        @test pt_tens.Mn ≈ cp.tension_controlled.Mn rtol=0.02
        @test pt_tens.φ ≈ 0.90 rtol=0.01  # Should be tension-controlled
        
        # Pure bending
        pt_pure_m = StructuralSizer.get_control_point(diagram, :pure_bending)
        @test abs(pt_pure_m.Pn) < 5.0  # Near zero
        @test pt_pure_m.Mn ≈ cp.pure_bending.Mn rtol=0.03
        @test pt_pure_m.φMn ≈ cp.pure_bending.φMn rtol=0.03
        
        # Pure tension
        pt_tens_max = StructuralSizer.get_control_point(diagram, :pure_tension)
        @test pt_tens_max.Pn ≈ cp.pure_tension.Pn rtol=0.01
        @test pt_tens_max.Mn ≈ 0.0 atol=0.1
    end
    
    # ==========================================================================
    # Test 11: Diagram Curve Extraction
    # ==========================================================================
    @testset "Diagram Curve Extraction" begin
        diagram = StructuralSizer.generate_PM_diagram(section, mat; n_intermediate=10)
        
        # Get nominal curve
        nominal = StructuralSizer.get_nominal_curve(diagram)
        @test length(nominal.Pn) == length(nominal.Mn)
        @test length(nominal.Pn) > 10  # Should have intermediate points
        
        # Get factored curve
        factored = StructuralSizer.get_factored_curve(diagram)
        @test length(factored.φPn) == length(factored.φMn)
        
        # Factored values should be less than nominal
        for (Pn, φPn) in zip(nominal.Pn, factored.φPn)
            if Pn > 0  # Compression
                @test φPn ≤ Pn * 1.001  # Allow small numerical tolerance
            end
        end
        
        # All moments should be non-negative
        @test all(Mn -> Mn ≥ 0, nominal.Mn)
    end
    
    # ==========================================================================
    # Test 12: Capacity Check Functions
    # ==========================================================================
    @testset "Capacity Check Functions" begin
        diagram = StructuralSizer.generate_PM_diagram(section, mat; n_intermediate=20)
        cp = data.control_points
        
        # Test 1: Point well inside the envelope should be adequate
        # Use 50% of balanced point capacity
        Pu_safe = cp.balanced.φPn * 0.5
        Mu_safe = cp.balanced.φMn * 0.5
        result_safe = StructuralSizer.check_PM_capacity(diagram, Pu_safe, Mu_safe)
        @test result_safe.adequate == true
        @test result_safe.utilization < 1.0
        
        # Test 2: Point on the envelope should have utilization ≈ 1.0
        # Use the balanced control point values
        Pu_limit = cp.balanced.φPn
        Mu_limit = cp.balanced.φMn
        result_limit = StructuralSizer.check_PM_capacity(diagram, Pu_limit, Mu_limit)
        @test result_limit.utilization ≈ 1.0 rtol=0.15  # Allow tolerance for interpolation
        
        # Test 3: Point outside the envelope should not be adequate
        Pu_over = cp.balanced.φPn
        Mu_over = cp.balanced.φMn * 1.5
        result_over = StructuralSizer.check_PM_capacity(diagram, Pu_over, Mu_over)
        @test result_over.adequate == false
        @test result_over.utilization > 1.0
        
        # Test 4: Pure axial at max allowable compression (Pn,max = 0.80 * φP0)
        # φPn,max = 0.65 * 0.80 * P0 = 797.7 kip (from StructurePoint)
        # Use a value below this. Mu = 0 must be adequate (symmetric columns report φMn_at_Pu = 0 at Pu).
        Pu_axial = 700.0  # Well below 797.7 kip max
        result_axial = StructuralSizer.check_PM_capacity(diagram, Pu_axial, 0.0)
        @test result_axial.adequate == true
        
        # Test 5: Capacity at specific axial load
        φMn_cap = StructuralSizer.capacity_at_axial(diagram, cp.balanced.φPn)
        @test φMn_cap ≈ cp.balanced.φMn rtol=0.15
        
        # Test 6: Utilization ratio
        util = StructuralSizer.utilization_ratio(diagram, Pu_safe, Mu_safe)
        @test util < 1.0
    end
    
    # ==========================================================================
    # Test 13: P-M Trend Validation
    # ==========================================================================
    @testset "P-M Trends" begin
        # As c decreases:
        # - Pn should decrease (less compression)
        # - Mn should increase up to a peak, then decrease
        
        result_c15 = StructuralSizer.calculate_PM_at_c(section, mat, 15.0)  # High c
        result_c10 = StructuralSizer.calculate_PM_at_c(section, mat, 10.0)
        result_c8 = StructuralSizer.calculate_PM_at_c(section, mat, 8.0)   # Near balanced
        result_c5 = StructuralSizer.calculate_PM_at_c(section, mat, 5.0)
        result_c3 = StructuralSizer.calculate_PM_at_c(section, mat, 3.0)   # Low c
        
        # Pn decreases monotonically
        @test result_c15.Pn > result_c10.Pn
        @test result_c10.Pn > result_c8.Pn
        @test result_c8.Pn > result_c5.Pn
        @test result_c5.Pn > result_c3.Pn
        
        # Mn increases from high c to balanced region
        @test result_c10.Mn > result_c15.Mn
        @test result_c8.Mn > result_c10.Mn  # Peak near balanced
        
        # All values should be positive and reasonable
        for result in [result_c15, result_c10, result_c8, result_c5, result_c3]
            @test result.Pn > -100  # Compression or small tension
            @test result.Mn > 0     # Positive moment
            @test result.Mn < 500   # Reasonable magnitude
        end
    end

end
