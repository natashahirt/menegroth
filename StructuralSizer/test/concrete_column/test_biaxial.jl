# ==============================================================================
# Tests for ACI 318-19 Biaxial Bending
# Reference: StructurePoint "Manual Design Procedure for Columns and Walls 
#            with Biaxial Bending (ACI 318-11/14/19)"
# Reference: StructurePoint "Biaxial Bending Interaction Diagrams for 
#            Rectangular Reinforced Concrete Column Design (ACI 318-19)"
# ==============================================================================

using Test
using StructuralSizer
using Unitful

# Load test data
include("test_data/biaxial_24x24.jl")
include("test_data/biaxial_rect_18x24.jl")

@testset "Biaxial Bending (ACI 318-19)" begin
    ref = BIAXIAL_24X24
    
    # =========================================================================
    @testset "Bresler Reciprocal Load Method" begin
        # Formula: 1/Pn = 1/Pnx + 1/Pny - 1/P0
        
        # Test basic calculation
        Pnx = ref.bresler_reciprocal.Pnx  # 2250 kip
        Pny = ref.bresler_reciprocal.Pny  # 2050 kip
        P0 = ref.uniaxial.P0               # 2584 kip
        
        Pn = StructuralSizer.bresler_reciprocal_load(Pnx, Pny, P0)
        
        # 1/Pn = 1/2250 + 1/2050 − 1/2584. That is 1834 kip, not the 1880 kip
        # previously stored on the example. With these uniaxial capacities the
        # reciprocal load is short of Pn,req = 1846 kip. A 5% slack is not a
        # provision of the method.
        Pn_formula = 1 / (1 / Pnx + 1 / Pny - 1 / P0)
        @test Pn ≈ Pn_formula rtol = 1e-12
        Pn_req = ref.required.Pn_req
        @test Pn < Pn_req
        
        # Pu/φ is 1200/0.65 = 1846.15 kip. The stored Pn_req of 1846 kip is
        # that quotient rounded to the nearest kip.
        nominal_demand = ref.demands.Pu / ref.required.φ
        util = StructuralSizer.check_bresler_reciprocal(nominal_demand, Pnx, Pny, P0)
        @test util ≈ nominal_demand / Pn rtol = 1e-12
        @test util > 1
    end
    
    # =========================================================================
    @testset "Bresler Load Contour Method" begin
        # Formula: (Mux/φMnx)^α + (Muy/φMny)^α ≤ 1.0
        
        # Use nominal capacities at Pn = 1846 kip
        φMnx = ref.uniaxial.Mnox * ref.required.φ  # φ×682.8 = 444 kip-ft
        φMny = ref.uniaxial.Mnoy * ref.required.φ  # Same for square section
        
        Mux = ref.demands.Mux  # 300 kip-ft
        Muy = ref.demands.Muy  # 125 kip-ft
        
        # Linear interaction (α = 1.0, conservative)
        util_linear = StructuralSizer.bresler_load_contour(Mux, Muy, φMnx, φMny; α=1.0)
        @test util_linear ≈ ref.bresler_contour.util_linear rtol=0.05
        
        # Typical α = 1.5
        util_alpha15 = StructuralSizer.bresler_load_contour(Mux, Muy, φMnx, φMny; α=1.5)
        @test util_alpha15 ≈ ref.bresler_contour.util_alpha15 rtol=0.10
        
        # Both should show adequate
        @test util_linear < 1.0
        @test util_alpha15 < 1.0
        
        # α = 1.5 should give lower utilization than α = 1.0
        @test util_alpha15 < util_linear
    end
    
    # =========================================================================
    @testset "PCA Load Contour Method" begin
        # EB712 Eq. (15): the smaller ratio takes the factor (1−β)/β.
        Mux = ref.demands.Mux
        Muy = ref.demands.Muy
        φMnox = ref.uniaxial.Mnox * ref.required.φ
        φMnoy = ref.uniaxial.Mnoy * ref.required.φ
        β = ref.pca_contour.β
        ratio_x = Mux / φMnox
        ratio_y = Muy / φMnoy
        slope = (1 - β) / β

        util = StructuralSizer.pca_load_contour(Mux, Muy, φMnox, φMnoy; β)
        @test ratio_x > ratio_y
        @test util ≈ ratio_x + slope * ratio_y rtol = 1e-12
        @test util ≈ ref.pca_contour.util atol = 0.001
        @test util < 1.0

        # The same line with the axes swapped.
        util_swap = StructuralSizer.pca_load_contour(Muy, Mux, φMnoy, φMnox; β)
        @test util_swap ≈ util rtol = 1e-12

        # Page 222: β = 0.5 is the straight line; β = 1.0 is each axis alone.
        @test StructuralSizer.pca_load_contour(Mux, Muy, φMnox, φMnoy; β = 0.5) ≈
              ratio_x + ratio_y rtol = 1e-12
        @test StructuralSizer.pca_load_contour(Mux, Muy, φMnox, φMnoy; β = 1.0) ≈
              max(ratio_x, ratio_y) rtol = 1e-12
        @test_throws ArgumentError StructuralSizer.pca_load_contour(
            Mux, Muy, φMnox, φMnoy; β = 0.4)
        @test_throws ArgumentError StructuralSizer.pca_load_contour(
            Mux, Muy, φMnox, φMnoy; β = 1.1)
    end
    
    # =========================================================================
    @testset "Biaxial Check with P-M Diagram" begin
        # Create column section (24×24 with 4 #11 bars at corners)
        section = RCColumnSection(
            b = 24.0u"inch",
            h = 24.0u"inch",
            cover = (2.0 + 0.5*1.41)u"inch",  # Clear cover + half bar diameter
            bar_size = 11,
            n_bars = 4,  # 4 corner bars
            tie_type = :tied
        )
        
        # Use proper ReinforcedConcreteMaterial (f'c = 5 ksi, fy = 60 ksi)
        mat = RC_5000_60
        
        # Generate P-M diagram
        diagram = generate_PM_diagram(section, mat; n_intermediate=20)
        
        # For square section, same diagram applies to both axes
        result = StructuralSizer.check_biaxial_simple(
            section, mat,
            ref.demands.Pu,
            ref.demands.Mux,
            ref.demands.Muy;
            α = 1.5
        )
        
        # Should be adequate
        @test result.adequate == true
        @test result.utilization < 1.0
    end
    
    # =========================================================================
    @testset "Edge Cases" begin
        # Zero moment in one direction
        util_uniaxial = StructuralSizer.bresler_load_contour(300.0, 0.0, 500.0, 500.0; α=1.5)
        @test util_uniaxial ≈ (300.0/500.0)^1.5 rtol=0.01
        
        # Equal moments both directions
        util_equal = StructuralSizer.bresler_load_contour(100.0, 100.0, 500.0, 500.0; α=1.5)
        @test util_equal ≈ 2 * (100.0/500.0)^1.5 rtol=0.01
        
        # Zero capacity should return Inf
        @test StructuralSizer.bresler_load_contour(100.0, 100.0, 0.0, 500.0) == Inf
        
        # Zero demand should return zero
        @test StructuralSizer.bresler_load_contour(0.0, 0.0, 500.0, 500.0) ≈ 0.0
        
        # Bresler reciprocal with zero capacity
        @test StructuralSizer.bresler_reciprocal_load(0.0, 1000.0, 2000.0) ≈ 0.0
    end
    
    # =========================================================================
    @testset "Comparison: Linear vs Parabolic Contour" begin
        # For the same demand, α=1.5 should always give lower or equal utilization 
        # compared to α=1.0 (linear is conservative)
        
        test_cases = [
            (100.0, 50.0, 300.0, 300.0),   # Low demand
            (200.0, 100.0, 300.0, 300.0),  # Medium demand
            (250.0, 150.0, 300.0, 300.0),  # High demand
        ]
        
        for (Mux, Muy, Mnx, Mny) in test_cases
            util_linear = StructuralSizer.bresler_load_contour(Mux, Muy, Mnx, Mny; α=1.0)
            util_para = StructuralSizer.bresler_load_contour(Mux, Muy, Mnx, Mny; α=1.5)
            @test util_para ≤ util_linear
        end
    end
    
    # =========================================================================
    @testset "Reference Values Verification" begin
        # Verify that our implementation matches the PDF exactly for key values
        
        # Mnx_req/Mnox = 461.5/682.8 = 0.676
        ratio_x = ref.bresler_contour.Mnx_demand / ref.bresler_contour.Mnox_cap
        @test ratio_x ≈ 0.676 rtol=0.01
        
        # Mny_req/Mnoy = 192.3/682.8 = 0.282
        ratio_y = ref.bresler_contour.Mny_demand / ref.bresler_contour.Mnoy_cap
        @test ratio_y ≈ 0.282 rtol=0.01
        
        # Linear utilization = 0.676 + 0.282 = 0.958
        @test ratio_x + ratio_y ≈ ref.bresler_contour.util_linear rtol=0.02
    end
end

# ==============================================================================
# Y-Axis P-M Diagram and Rectangular Biaxial Tests
# Reference: StructurePoint "Biaxial Bending Interaction Diagrams for 
#            Rectangular Reinforced Concrete Column Design (ACI 318-19)"
# ==============================================================================

@testset "Rectangular Biaxial Bending (Y-Axis P-M Diagram)" begin
    ref = BIAXIAL_RECT_18X24
    
    # Create rectangular section (18" × 24")
    section = RCColumnSection(
        b = ref.geometry.b * u"inch",
        h = ref.geometry.h * u"inch",
        cover = ref.geometry.cover * u"inch",
        bar_size = ref.reinforcement.bar_size,
        n_bars = ref.reinforcement.n_bars,
        tie_type = :tied
    )
    
    # Use proper ReinforcedConcreteMaterial (f'c = 4 ksi, fy = 60 ksi)
    mat = RC_4000_60
    
    # =========================================================================
    @testset "Y-Axis Effective Depth" begin
        # For y-axis bending, d is from right face to leftmost bars
        d_y = StructuralSizer.effective_depth(section, StructuralSizer.WeakAxis())
        
        # Expected: b - cover - tie - d_bar/2 ≈ 18 - 1.5 - 0.5 - 0.564 ≈ 15.44
        @test d_y ≈ ref.reinforcement.d_y rtol=0.05
        
        # d_y should be less than d_x (since b < h)
        # effective_depth returns units, effective_depth(::WeakAxis) returns stripped Float64
        d_x = ustrip(u"inch", StructuralSizer.effective_depth(section))
        @test d_y < d_x
    end
    
    # =========================================================================
    @testset "Y-Axis P-M Diagram Generation" begin
        # Generate diagram for y-axis bending
        diagram_y = generate_PM_diagram(section, mat, WeakAxis(); n_intermediate=15)
        
        # Check basic structure
        @test length(diagram_y.points) > 5
        @test haskey(diagram_y.control_points, :pure_compression)
        @test haskey(diagram_y.control_points, :balanced)
        @test haskey(diagram_y.control_points, :pure_bending)
        
        # Pure compression should be the same (section squashes uniformly)
        P0_y = get_control_point(diagram_y, :pure_compression).Pn
        @test P0_y ≈ ref.capacities.P0 rtol=0.05
        
        # Maximum moment capacity
        φMn_max_y = maximum(pt.φMn for pt in diagram_y.points)
        @test φMn_max_y ≈ ref.capacities.φMny_max rtol=0.10
    end
    
    # =========================================================================
    @testset "X-Axis vs Y-Axis Capacity Comparison" begin
        # Generate diagrams for both axes
        diagrams = generate_PM_diagrams_biaxial(section, mat; n_intermediate=15)
        
        # Pure compression should be equal
        P0_x = get_control_point(diagrams.x, :pure_compression).Pn
        P0_y = get_control_point(diagrams.y, :pure_compression).Pn
        @test P0_x ≈ P0_y rtol=0.01
        
        # Maximum moment capacities
        φMnx_max = maximum(pt.φMn for pt in diagrams.x.points)
        φMny_max = maximum(pt.φMn for pt in diagrams.y.points)
        
        # Y-axis capacity must be less than X-axis (since b < h)
        @test φMny_max < φMnx_max
        
        # Capacity ratio should roughly reflect aspect ratio
        ratio = φMny_max / φMnx_max
        @test ratio ≈ ref.capacities.capacity_ratio rtol=0.15
        
        # Verify against expected values
        @test φMnx_max ≈ ref.capacities.φMnx_max rtol=0.10
        @test φMny_max ≈ ref.capacities.φMny_max rtol=0.10
    end
    
    # =========================================================================
    @testset "Rectangular Biaxial Check" begin
        result = check_biaxial_rectangular(
            section, mat,
            ref.demands.Pu,
            ref.demands.Mux,
            ref.demands.Muy;
            method = :contour,
            α = ref.bresler_contour.α
        )
        
        # Should be adequate
        @test result.adequate == ref.bresler_contour.adequate
        
        # Utilization should match expected
        @test result.utilization ≈ ref.bresler_contour.util rtol=0.20
        
        # Capacities at Pu should match
        @test result.φMnx_at_Pu ≈ ref.bresler_contour.φMnx_at_Pu rtol=0.10
        @test result.φMny_at_Pu ≈ ref.bresler_contour.φMny_at_Pu rtol=0.10
    end
    
    # =========================================================================
    @testset "Auto-Detection (Square vs Rectangular)" begin
        # Rectangular section should be detected as non-square
        result_rect = check_biaxial_auto(
            section, mat,
            ref.demands.Pu,
            ref.demands.Mux,
            ref.demands.Muy
        )
        @test result_rect.is_square == false
        
        # Square section should be detected as square
        section_square = RCColumnSection(
            b = 20.0u"inch",
            h = 20.0u"inch",
            cover = 1.5u"inch",
            bar_size = 9,
            n_bars = 8,
            tie_type = :tied
        )
        result_square = check_biaxial_auto(
            section_square, mat,
            ref.demands.Pu,
            ref.demands.Mux,
            ref.demands.Muy
        )
        @test result_square.is_square == true
    end
    
    # =========================================================================
    @testset "Capacity at Various Axial Loads" begin
        diagrams = generate_PM_diagrams_biaxial(section, mat; n_intermediate=20)
        
        # At different axial loads, check that y-capacity < x-capacity
        test_loads = [100.0, 300.0, 500.0, 700.0]
        
        for Pu in test_loads
            φMnx = capacity_at_axial(diagrams.x, Pu)
            φMny = capacity_at_axial(diagrams.y, Pu)
            @test φMny < φMnx
        end
    end
    
    # =========================================================================
    @testset "Edge Cases - Uniaxial Moments" begin
        diagrams = generate_PM_diagrams_biaxial(section, mat)
        Pu = 400.0
        
        # Pure x-axis moment (Muy = 0)
        result_x_only = check_biaxial_rectangular(
            section, mat, Pu, 200.0, 0.0;
            method = :contour, α = 1.5
        )
        φMnx = capacity_at_axial(diagrams.x, Pu)
        expected_util = (200.0 / φMnx)^1.5
        @test result_x_only.utilization ≈ expected_util rtol=0.05
        
        # Pure y-axis moment (Mux = 0)
        result_y_only = check_biaxial_rectangular(
            section, mat, Pu, 0.0, 150.0;
            method = :contour, α = 1.5
        )
        φMny = capacity_at_axial(diagrams.y, Pu)
        expected_util_y = (150.0 / φMny)^1.5
        @test result_y_only.utilization ≈ expected_util_y rtol=0.05
    end

    @testset "PCA contour uses the diagram capacities" begin
        Pu = 400.0
        Mux, Muy = 200.0, 80.0
        pca = check_biaxial_rectangular(section, mat, Pu, Mux, Muy; method = :pca, β = 0.65)
        @test pca.method == :pca
        @test pca.utilization ≈ StructuralSizer.pca_load_contour(
            Mux, Muy, pca.φMnx_at_Pu, pca.φMny_at_Pu; β = 0.65) rtol = 1e-12
        @test pca.adequate == (pca.utilization ≤ 1.0)
    end
end

# Regression: a square section is not equally strong about both axes unless its
# bar layout is 90°-symmetric. The `:perimeter` layout puts the odd interior
# pair of a 6-bar square on the top/bottom faces (3 + 3 bars resisting Mx,
# 2 + 2 corner bars resisting My), so φMny < φMnx near balanced. The column
# checker used to reuse φMnx for φMny whenever b ≈ h, overstating y capacity.
@testset "Square Column with Asymmetric Bar Layout" begin
    mat = RC_4000_60
    sec6 = RCColumnSection(b = 16u"inch", h = 16u"inch", bar_size = 8, n_bars = 6)
    sec8 = RCColumnSection(b = 16u"inch", h = 16u"inch", bar_size = 8, n_bars = 8)

    @testset "Layout symmetry detection" begin
        @test StructuralSizer._bars_symmetric_90(sec6) == false
        @test StructuralSizer._bars_symmetric_90(sec8) == true
    end

    @testset "Weak-axis capacity is lower in the compression region" begin
        d6 = generate_PM_diagrams_biaxial(sec6, mat; n_intermediate = 20)
        d8 = generate_PM_diagrams_biaxial(sec8, mat; n_intermediate = 20)
        for Pu in (150.0, 250.0, 350.0)
            @test capacity_at_axial(d6.y, Pu) < capacity_at_axial(d6.x, Pu)
            @test capacity_at_axial(d8.y, Pu) ≈ capacity_at_axial(d8.x, Pu) rtol = 0.01
        end
    end

    @testset "check_biaxial_auto uses separate diagrams" begin
        r = check_biaxial_auto(sec6, mat, 250.0, 50.0, 50.0)
        @test r.is_square == true
        @test r.φMny_at_Pu < r.φMnx_at_Pu
    end

    @testset "ACIColumnChecker rejects My between φMny and φMnx" begin
        kip = StructuralSizer.Asap.kip
        checker = ACIColumnChecker(; include_slenderness = false, include_biaxial = true,
                                   fy_ksi = 60.0, Es_ksi = 29000.0)
        cache = StructuralSizer.create_cache(checker, 1)
        StructuralSizer.precompute_capacities!(checker, cache, [sec6], NWC_4000, MinVolume())
        @test cache.is_square[1] == true
        @test cache.diagrams_y[1] !== nothing

        Pu = 250.0
        φMnx = capacity_at_axial(cache.diagrams[1], Pu)
        φMny = capacity_at_axial(cache.diagrams_y[1], Pu)
        @test φMny < φMnx
        Mu = 0.5 * (φMnx + φMny)
        geom = ConcreteMemberGeometry(3.66; k = 1.0, braced = true)
        kft = kip * u"ft"
        about_x = RCColumnDemand(1; Pu = Pu * kip, Mux = Mu * kft, Muy = 0.0 * kft,
                                 M1x = 0.0 * kft, M1y = 0.0 * kft)
        about_y = RCColumnDemand(1; Pu = Pu * kip, Mux = 0.0 * kft, Muy = Mu * kft,
                                 M1x = 0.0 * kft, M1y = 0.0 * kft)
        @test StructuralSizer.is_feasible(checker, cache, 1, sec6, NWC_4000, about_x, geom) == true
        @test StructuralSizer.is_feasible(checker, cache, 1, sec6, NWC_4000, about_y, geom) == false
    end
end

# An enlarged column used to be re-barred for Mu only. The second moment
# was left for the full-building check, which then grew the section.
@testset "Enlarged column reinforcement resists both moments" begin
    mat = RC_4000_60
    Pu = 80.0
    bars = (bar_sizes = [6, 8, 10], n_bars_options = [4, 8, 12])
    orig = RCColumnSection(b = 16u"inch", h = 16u"inch", bar_size = 8, n_bars = 4)
    # Light uniaxial demand: the enlarged outline keeps the lightest legal bars.
    grown_uni = resize_column_with_reinforcement(
        orig, 20u"inch", 20u"inch", Pu, 30.0, mat; bars...)
    diagrams = generate_PM_diagrams_biaxial(grown_uni, mat; n_intermediate = 10)
    φMn = min(capacity_at_axial(diagrams.x, Pu), capacity_at_axial(diagrams.y, Pu))
    # Each moment is inside the uniaxial diagram. Together they fall outside
    # the load contour, so bars chosen for Mu alone are not enough.
    Mu = 0.75 * φMn
    Muy = 0.75 * φMn
    @test check_PM_capacity(diagrams.x, Pu, Mu).adequate
    @test check_biaxial_auto(grown_uni, mat, Pu, Mu, Muy).adequate == false
    grown = resize_column_with_reinforcement(
        orig, 20u"inch", 20u"inch", Pu, Mu, mat; Muy = Muy, bars...)
    @test check_biaxial_auto(grown, mat, Pu, Mu, Muy).adequate
    @test check_biaxial_auto(grown, mat, Pu, Muy, Mu).adequate
    @test ustrip(u"inch^2", grown.As_total) > ustrip(u"inch^2", grown_uni.As_total)
end
