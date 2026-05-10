# ==============================================================================
# Circular Column P-M Interaction Tests
# ==============================================================================
# Tests for circular RC column P-M calculations against StructurePoint
# "Interaction Diagram - Circular Spiral Reinforced Concrete Column (ACI 318-19)"
# ==============================================================================

using Test
using StructuralSizer
using Unitful

# Load test data
if !@isdefined(CIRCULAR_20_MAT)
    include("test_data/circular_column_20dia.jl")
end

@testset "Circular Column P-M Interaction" begin
    
    # Create section matching StructurePoint example
    section = create_sp_circular_20_section()
    mat = CIRCULAR_20_MAT
    
    @testset "Section Properties" begin
        # Check section was created correctly
        @test section.tie_type == :spiral
        @test length(section.bars) == 8
        
        # Gross area
        Ag = ustrip(u"inch^2", section.Ag)
        @test Ag ≈ SP_CIRCULAR_20_PROPERTIES.Ag atol=0.1
        
        # Total steel area
        As = ustrip(u"inch^2", section.As_total)
        @test As ≈ SP_CIRCULAR_20_PROPERTIES.As_total atol=0.01
        
        # Diameter
        D = ustrip(u"inch", section.D)
        @test D ≈ SP_CIRCULAR_20_PROPERTIES.D atol=0.01
    end
    
    @testset "Material Constants" begin
        # β1 calculation (pass NamedTuple so beta1 knows fc is in ksi)
        β₁ = StructuralSizer.beta1(mat)
        @test β₁ ≈ SP_CIRCULAR_20_PROPERTIES.β1 atol=0.001
        
        # Yield strain
        εy = mat.fy / mat.Es
        @test εy ≈ SP_CIRCULAR_20_PROPERTIES.εy atol=0.00001
    end
    
    @testset "Circular Compression Zone Geometry" begin
        D = 20.0  # in
        
        # Test case from SP example: fs=0 point (a = 13.89 in)
        a = 13.89
        comp = StructuralSizer.circular_compression_zone(D, a)
        
        # θ should be ~112.9° = 1.97 rad
        θ_deg = rad2deg(comp.θ)
        @test θ_deg ≈ 112.9 atol=0.5
        
        # A_comp should be ~232.9 in²
        @test comp.A_comp ≈ 232.9 atol=1.0
        
        # ȳ from extreme compression should be ~2.24 in
        @test comp.y_bar ≈ 2.24 atol=0.1
    end
    
    @testset "Pure Compression Capacity (P₀)" begin
        P0 = StructuralSizer.pure_compression_capacity(section, mat)
        
        # P0 = 0.85*f'c*(Ag-As) + fy*As
        # P0 = 0.85*5*(314.16-10.16) + 60*10.16
        # P0 = 0.85*5*304 + 609.6 = 1292 + 609.6 = 1901.6 kip
        # SP shows φP0 = 1426.2 with φ=0.75
        # So P0 = 1426.2/0.75 = 1901.6 ✓
        
        expected_P0 = 1901.6
        @test P0 ≈ expected_P0 atol=2.0
        
        # Factored: φP0 = 0.75 * 1901.6 = 1426.2
        φP0 = 0.75 * P0
        @test φP0 ≈ SP_CIRCULAR_20_RESULTS.max_compression.φPn atol=1.0
    end
    
    @testset "Maximum Compression (Pn,max)" begin
        Pn_max = StructuralSizer.max_compression_capacity(section, mat)
        
        # For spiral: Pn,max = 0.85 * P0
        P0 = StructuralSizer.pure_compression_capacity(section, mat)
        @test Pn_max ≈ 0.85 * P0 atol=0.1
        
        # Factored: φPn,max = 0.75 * 0.85 * P0
        φPn_max = 0.75 * Pn_max
        @test φPn_max ≈ SP_CIRCULAR_20_RESULTS.allowable_compression.φPn atol=1.0
    end
    
    @testset "P-M at fs=0 (c=d)" begin
        # At fs=0, c = d (depth to extreme tension steel)
        d = StructuralSizer.extreme_tension_depth(section)
        @test d ≈ 17.37 atol=0.1  # Should match SP d5
        
        c = d
        result = StructuralSizer.calculate_phi_PM_at_c(section, mat, c)
        
        # SP Table 2: Pn=1312.64 kip, Mn=277.54 kip-ft, φ=0.75
        @test result.Pn ≈ SP_CIRCULAR_20_FS_ZERO.Pn atol=5.0
        @test result.Mn ≈ SP_CIRCULAR_20_FS_ZERO.Mn atol=3.0
        @test result.φ ≈ 0.75 atol=0.01
        
        # Factored values from Table 8
        @test result.φPn ≈ SP_CIRCULAR_20_RESULTS.fs_zero.φPn atol=5.0
        @test result.φMn ≈ SP_CIRCULAR_20_RESULTS.fs_zero.φMn atol=3.0
    end
    
    @testset "P-M at Balanced Point (fs=fy)" begin
        # At balanced, εt = εy
        # c = εcu * d / (εcu + εy)
        d = StructuralSizer.extreme_tension_depth(section)
        εy = mat.fy / mat.Es
        εcu = mat.εcu
        c = StructuralSizer.c_from_εt(εy, d, εcu)
        
        # SP shows c = 10.28 in at balanced
        @test c ≈ SP_CIRCULAR_20_BALANCED_DETAILS.c atol=0.1
        
        result = StructuralSizer.calculate_phi_PM_at_c(section, mat, c)
        
        # SP Table 4: Pn=519 kip, Mn=408 kip-ft
        @test result.Pn ≈ SP_CIRCULAR_20_BALANCED_DETAILS.Pn atol=5.0
        @test result.Mn ≈ SP_CIRCULAR_20_BALANCED_DETAILS.Mn atol=5.0
        @test result.φ ≈ 0.75 atol=0.01  # Just at compression-controlled limit
        
        # Factored values from Table 8
        @test result.φPn ≈ SP_CIRCULAR_20_RESULTS.balanced.φPn atol=5.0
        @test result.φMn ≈ SP_CIRCULAR_20_RESULTS.balanced.φMn atol=5.0
    end
    
    @testset "P-M at Tension Controlled (εt = εy + 0.003)" begin
        d = StructuralSizer.extreme_tension_depth(section)
        εy = mat.fy / mat.Es
        εt_target = εy + 0.003
        c = StructuralSizer.c_from_εt(εt_target, d, mat.εcu)
        
        result = StructuralSizer.calculate_phi_PM_at_c(section, mat, c)
        
        # At tension controlled, φ = 0.90
        @test result.φ ≈ 0.90 atol=0.01
        
        # Factored values from Table 8
        @test result.φPn ≈ SP_CIRCULAR_20_RESULTS.tension_controlled.φPn atol=3.0
        @test result.φMn ≈ SP_CIRCULAR_20_RESULTS.tension_controlled.φMn atol=5.0
    end
    
    @testset "Pure Tension Capacity" begin
        As_total = ustrip(u"inch^2", section.As_total)
        Pnt = -mat.fy * As_total  # Tension negative
        
        @test Pnt ≈ -609.6 atol=1.0  # = -60 * 10.16
        
        # Factored
        φPnt = 0.90 * Pnt
        @test φPnt ≈ SP_CIRCULAR_20_RESULTS.max_tension.φPn atol=1.0
    end
    
    @testset "Full P-M Interaction Diagram" begin
        diagram = StructuralSizer.generate_PM_diagram(section, mat; n_intermediate=10)
        
        # Check that we have control points
        @test length(diagram.points) > 8
        
        # Check pure compression point
        pt_comp = StructuralSizer.get_control_point(diagram, :pure_compression)
        @test pt_comp.φPn ≈ SP_CIRCULAR_20_RESULTS.max_compression.φPn atol=2.0
        @test pt_comp.φMn ≈ 0.0 atol=1.0
        
        # Check balanced point
        pt_bal = StructuralSizer.get_control_point(diagram, :balanced)
        @test pt_bal.φPn ≈ SP_CIRCULAR_20_RESULTS.balanced.φPn atol=5.0
        @test pt_bal.φMn ≈ SP_CIRCULAR_20_RESULTS.balanced.φMn atol=5.0
        
        # Check that curve is monotonic in the compression region
        curve = StructuralSizer.get_factored_curve(diagram)
        max_φMn = maximum(curve.φMn)
        @test max_φMn > 250  # Should have significant moment capacity
    end
    
    @testset "Capacity Check Functions" begin
        diagram = StructuralSizer.generate_PM_diagram(section, mat; n_intermediate=10)
        
        # Point clearly inside envelope should be adequate
        result1 = StructuralSizer.check_PM_capacity(diagram, 500.0, 200.0)
        @test result1.adequate == true
        @test result1.utilization < 1.0
        
        # Point at pure compression limit
        φPn_max = SP_CIRCULAR_20_RESULTS.allowable_compression.φPn
        result2 = StructuralSizer.check_PM_capacity(diagram, φPn_max * 0.95, 10.0)
        @test result2.adequate == true
        
        # Point clearly outside envelope should be inadequate
        result3 = StructuralSizer.check_PM_capacity(diagram, 1500.0, 400.0)
        @test result3.adequate == false
        @test result3.utilization > 1.0
    end

    @testset "ACI 10.3.6 axial cap (spiral)" begin
        # ACI 318-11 §10.3.6 Eq. (10-1): φPn,max = 0.85·φ·P0 (spiral). The
        # design check must refuse Pu > φPn,max even though the diagram still
        # carries the theoretical PURE_COMPRESSION point at φP0.
        diagram = StructuralSizer.generate_PM_diagram(section, mat; n_intermediate=10)
        φPn_max = StructuralSizer.get_control_point(diagram, :max_compression).φPn
        φP0     = StructuralSizer.get_control_point(diagram, :pure_compression).φPn

        @test φPn_max ≈ 0.85 * φP0 atol = 1.0  # MAX_COMPRESSION uses α·P0 exactly
        @test φPn_max < φP0

        # 95 % of cap → adequate (no moment).
        r_under = StructuralSizer.check_PM_capacity(diagram, 0.95 * φPn_max, 0.0)
        @test r_under.adequate

        # 105 % of cap → governs as :axial_cap.
        r_over = StructuralSizer.check_PM_capacity(diagram, 1.05 * φPn_max, 0.0)
        @test !r_over.adequate
        @test r_over.governing == :axial_cap
        @test r_over.utilization ≈ 1.05 atol = 1e-6
    end

    @testset "Capacity Interpolation" begin
        diagram = StructuralSizer.generate_PM_diagram(section, mat; n_intermediate=20)
        
        # Moment capacity at balanced axial load
        Pu_balanced = SP_CIRCULAR_20_RESULTS.balanced.φPn
        φMn_at_bal = StructuralSizer.capacity_at_axial(diagram, Pu_balanced)
        @test φMn_at_bal ≈ SP_CIRCULAR_20_RESULTS.balanced.φMn atol=10.0
        
        # Diagram query: `capacity_at_moment(diagram, 0.0)` returns the curve's
        # extreme point φP0 by design, since the curve still carries the
        # theoretical PURE_COMPRESSION point for plotting/diagnostics. The ACI
        # §10.3.6 cap is enforced one layer up in `check_PM_capacity`, NOT on
        # the curve itself — see the "ACI 10.3.6 axial cap" testset above.
        φPn_at_zero_M = StructuralSizer.capacity_at_moment(diagram, 0.0)
        @test φPn_at_zero_M ≈ SP_CIRCULAR_20_RESULTS.max_compression.φPn atol=10.0
    end
end

@testset "Circular Section Constructor" begin
    # Test automatic bar placement constructor
    section = StructuralSizer.RCCircularSection(
        D = 20u"inch",
        bar_size = 10,
        n_bars = 8,
        cover = 1.5u"inch",
        tie_type = :spiral
    )
    
    @test length(section.bars) == 8
    @test section.tie_type == :spiral
    
    # Total steel should be 8 × 1.27 = 10.16 in²
    @test ustrip(u"inch^2", section.As_total) ≈ 10.16 atol=0.01
    
    # Diameter should be 20 in
    @test ustrip(u"inch", section.D) ≈ 20.0 atol=0.01
    
    # Bars should be approximately on a circle
    D = ustrip(u"inch", section.D)
    center_x = D / 2
    center_y = D / 2
    
    radii = Float64[]
    for bar in section.bars
        x = ustrip(u"inch", bar.x)
        y = ustrip(u"inch", bar.y)
        r = sqrt((x - center_x)^2 + (y - center_y)^2)
        push!(radii, r)
    end
    
    # All bars should be at approximately the same radius
    @test maximum(radii) ≈ minimum(radii) atol=0.1
end

@testset "Circular Section Interface Functions" begin
    section = StructuralSizer.RCCircularSection(
        D = 20u"inch",
        bar_size = 10,
        n_bars = 8,
        cover = 1.5u"inch",
        tie_type = :spiral
    )
    
    # section_area
    @test ustrip(u"inch^2", StructuralSizer.section_area(section)) ≈ π * 20^2 / 4 atol=0.1
    
    # section_depth and section_width (both D for circular)
    @test ustrip(u"inch", StructuralSizer.section_depth(section)) ≈ 20.0 atol=0.01
    @test ustrip(u"inch", StructuralSizer.section_width(section)) ≈ 20.0 atol=0.01
    
    # n_bars
    @test StructuralSizer.n_bars(section) == 8
    
    # moment_of_inertia (πD⁴/64)
    I = StructuralSizer.moment_of_inertia(section, :x)
    I_expected = π * 20^4 / 64  # in^4
    @test ustrip(u"inch^4", I) ≈ I_expected atol=1.0
    
    # radius_of_gyration (D/4)
    r = StructuralSizer.radius_of_gyration(section, :x)
    @test ustrip(u"inch", r) ≈ 5.0 atol=0.1
end
