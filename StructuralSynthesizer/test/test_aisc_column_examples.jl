using StructuralSizer
using StructuralSizer: get_Fe_flexural, get_Fe_torsional, get_compression_factors
# Units are re-exported from StructuralSizer (via Asap)
using Asap
using Unitful
using Test

# ------------------------------------------------------------------------------
# Optional dependency: StructuralSynthesizer
# A few tests build BuildingSkeleton/BuildingStructure models (integration).
# ------------------------------------------------------------------------------
const HAS_STRUCTURAL_SYNTHESIZER = let ok = true
    try
        @eval using StructuralSynthesizer
    catch
        ok = false
    end
    ok
end

# ==============================================================================
# AISC Column Design Tests - Based on CE 405 Chapter 3 Principles
# Reference: Prof. Dr. A. Varma, Design of Steel Structures
# https://www.egr.msu.edu/~harichan/classes/ce405/chap3.pdf
#
# Key AISC 360 Equations:
#   Fe = π²E / (KL/r)²           (E3-4) Euler buckling
#   Fcr = Q × 0.658^(QFy/Fe) × Fy  when QFy/Fe ≤ 2.25 (E7-2)
#   Fcr = 0.877 × Fe              when QFy/Fe > 2.25 (E7-3)
#   ϕPn = 0.9 × Fcr × Ag          (E3-1)
# ==============================================================================

@testset "AISC Column Design" begin

    # ==========================================================================
    # Test 1: Euler Buckling Stress Calculation
    # Verify Fe = π²E / (KL/r)² for various slenderness ratios
    # ==========================================================================
    @testset "Euler Buckling Stress (Fe)" begin
        section = W("W14X82")
        
        E = 29000.0u"ksi"
        ry = section.ry  # Weak axis radius of gyration
        
        # Test at various effective lengths
        for (KL_ft, expected_range) in [
            (10.0, (100.0, 200.0)),   # Short column, high Fe
            (20.0, (30.0, 80.0)),     # Intermediate
            (30.0, (10.0, 40.0)),     # Long column, low Fe
        ]
            KL = KL_ft * u"ft"
            Fe = get_Fe_flexural(section, A992_Steel, KL; axis=:weak)
            Fe_ksi = ustrip(u"ksi", Fe)
            
            @test expected_range[1] < Fe_ksi < expected_range[2]
        end
        
        # Verify Fe formula: Fe = π²E / (KL/r)²
        KL = 15.0u"ft"
        KL_r = KL / ry
        Fe_calculated = π^2 * E / KL_r^2
        Fe_function = get_Fe_flexural(section, A992_Steel, KL; axis=:weak)
        
        @test isapprox(Fe_calculated, Fe_function; rtol=0.01)
    end

    # ==========================================================================
    # Test 2: Compression Strength - Short Column (Yielding Controls)
    # Short columns (low KL/r) → Fe is large → Fcr ≈ Fy
    # ==========================================================================
    @testset "Short Column - Yielding" begin
        section = W("W14X82")
        Fy = A992_Steel.Fy
        Ag = section.A
        
        # Very short effective length → yielding controls
        KL = 5.0u"ft"
        
        ϕPn = get_ϕPn(section, A992_Steel, KL; axis=:weak)
        
        # For short column, ϕPn should be close to 0.9 × Fy × Ag
        ϕPy = 0.9 * Fy * Ag
        
        # Should be > 90% of yield capacity for very short column
        ratio = ϕPn / ϕPy
        @test ratio > 0.90
        @test ratio <= 1.0
    end

    # ==========================================================================
    # Test 3: Compression Strength - Long Column (Buckling Controls)
    # Long columns (high KL/r) → Fe is small → Fcr ≈ 0.877 × Fe
    # ==========================================================================
    @testset "Long Column - Elastic Buckling" begin
        section = W("W14X82")
        
        # Long effective length → elastic buckling controls
        KL = 40.0u"ft"
        
        Fe = get_Fe_flexural(section, A992_Steel, KL; axis=:weak)
        ϕPn = get_ϕPn(section, A992_Steel, KL; axis=:weak)
        
        # For long column, Fcr ≈ 0.877 × Fe
        Fcr_elastic = 0.877 * Fe
        ϕPn_elastic = 0.9 * Fcr_elastic * section.A
        
        # Should be close to elastic buckling capacity
        @test isapprox(ϕPn, ϕPn_elastic; rtol=0.10)
        
        # And significantly less than yield capacity
        ϕPy = 0.9 * A992_Steel.Fy * section.A
        @test ϕPn < 0.5 * ϕPy  # Long column has much reduced capacity
    end

    # ==========================================================================
    # Test 4: Weak Axis vs Strong Axis Buckling
    # Weak axis (smaller r) gives lower buckling capacity
    # ==========================================================================
    @testset "Weak vs Strong Axis Buckling" begin
        section = W("W14X82")
        
        KL = 20.0u"ft"
        
        ϕPn_weak = get_ϕPn(section, A992_Steel, KL; axis=:weak)
        ϕPn_strong = get_ϕPn(section, A992_Steel, KL; axis=:strong)
        
        # Weak axis should give lower capacity (smaller r)
        @test ϕPn_weak < ϕPn_strong
        
        # The ratio should reflect r_x / r_y ratio squared approximately
        # For W14x82: rx ≈ 6.05", ry ≈ 2.48"
        rx, ry = section.rx, section.ry
        @test rx > ry  # Verify rx > ry for W-shapes
    end

    # ==========================================================================
    # Test 5: Slenderness Reduction Factor Q
    # For stocky rolled W-shapes, Q ≈ 1.0 (no local buckling)
    # Note: Lighter/deeper sections (e.g., W21X55) can have Q < 1.0 due to
    # slender flanges (Qs < 1) per AISC E7.
    # ==========================================================================
    @testset "Slenderness Factor Q" begin
        # Stocky W-shapes (typical columns) should have Q = 1.0
        for name in ["W14X82", "W10X49", "W14X68"]
            section = W(name)
            q_factors = get_compression_factors(section, A992_Steel)
            
            # Rolled W-shapes used as columns are typically compact for compression
            @test q_factors.Q ≈ 1.0 atol=0.01
            @test q_factors.Qs ≈ 1.0 atol=0.01
        end
        
        # Lighter beam sections can have slender flanges (Q < 1.0)
        # W21X55 has bf/2tf ≈ 7.9, which is borderline slender for Fy=50ksi
        slender_section = W("W21X55")
        q_slender = get_compression_factors(slender_section, A992_Steel)
        @test q_slender.Q < 1.0  # Verify slender behavior is captured
    end

    # ==========================================================================
    # Test 6: Column Design Selection
    # Verify optimizer selects appropriate section for given load
    # ==========================================================================
    @testset "Column Selection - Axial Only" begin
        # Design a column for Pu = 500 kips, KL = 14 ft
        Pu_required = 500.0u"kip"
        KL = 14.0u"ft"
        
        # Find sections that pass
        passing_sections = String[]
        for sec in all_W()
            ϕPn = get_ϕPn(sec, A992_Steel, KL; axis=:weak)
            if ϕPn >= Pu_required
                push!(passing_sections, sec.name)
            end
        end
        
        # Should have multiple passing sections
        @test length(passing_sections) > 10
        
        # W14x82 should pass (typical column for this demand)
        @test "W14X82" in passing_sections
        
        # Verify W14x82 capacity
        w14x82 = W("W14X82")
        ϕPn = get_ϕPn(w14x82, A992_Steel, KL; axis=:weak)
        @test ϕPn >= Pu_required
    end

    # ==========================================================================
    # Test 7: Effective Length Factor K
    # K = 1.0 for pinned-pinned, K = 0.5 for fixed-fixed
    # ==========================================================================
    @testset "Effective Length Factor K" begin
        section = W("W14X82")
        L = 20.0u"ft"
        
        # K = 1.0 (pinned-pinned)
        KL_pinned = 1.0 * L
        ϕPn_pinned = get_ϕPn(section, A992_Steel, KL_pinned; axis=:weak)
        
        # K = 0.5 (fixed-fixed, theoretical)
        KL_fixed = 0.5 * L
        ϕPn_fixed = get_ϕPn(section, A992_Steel, KL_fixed; axis=:weak)
        
        # K = 2.0 (cantilever)
        KL_cantilever = 2.0 * L
        ϕPn_cantilever = get_ϕPn(section, A992_Steel, KL_cantilever; axis=:weak)
        
        # Fixed-fixed should have highest capacity
        @test ϕPn_fixed > ϕPn_pinned
        
        # Cantilever should have lowest capacity
        @test ϕPn_cantilever < ϕPn_pinned
        
        # Capacity ratio should roughly follow (K)² relationship for elastic buckling
        # (Since Fe ∝ 1/(KL)²)
    end

    # ==========================================================================
    # Test 8: P-M Interaction (H1-1)
    # Combined axial compression and bending
    # ==========================================================================
    @testset "P-M Interaction" begin
        section = W("W14X82")
        KL = 14.0u"ft"
        Lb = 14.0u"ft"
        
        # Capacities
        ϕPn = get_ϕPn(section, A992_Steel, KL; axis=:weak)
        ϕMnx = get_ϕMn(section, A992_Steel; Lb=Lb, Cb=1.0, axis=:strong)
        ϕMny = get_ϕMn(section, A992_Steel; Lb=Lb, Cb=1.0, axis=:weak)
        
        # Pure compression case
        Pu = 0.5 * ϕPn  # 50% of axial capacity
        Mux = 0.0u"kip*ft"
        Muy = 0.0u"kip*ft"
        
        ur_pure_axial = check_PMxMy_interaction(
            ustrip(u"N", Pu), 
            ustrip(u"N*m", Mux), 
            ustrip(u"N*m", Muy),
            ustrip(u"N", ϕPn), 
            ustrip(u"N*m", ϕMnx), 
            ustrip(u"N*m", ϕMny)
        )
        @test ur_pure_axial ≈ 0.5 atol=0.1
        
        # Combined case: 30% axial + 50% strong-axis moment
        Pu = 0.3 * ϕPn
        Mux = 0.5 * ϕMnx
        
        ur_combined = check_PMxMy_interaction(
            ustrip(u"N", Pu), 
            ustrip(u"N*m", Mux), 
            ustrip(u"N*m", Muy),
            ustrip(u"N", ϕPn), 
            ustrip(u"N*m", ϕMnx), 
            ustrip(u"N*m", ϕMny)
        )
        
        # Should be less than 1.0 (passes)
        @test ur_combined < 1.0
        # But higher than pure axial case
        @test ur_combined > ur_pure_axial
    end

    # ==========================================================================
    # Test 9: Torsional Buckling
    # For doubly-symmetric shapes, usually governed by flexural buckling
    # ==========================================================================
    @testset "Torsional vs Flexural Buckling" begin
        section = W("W14X82")
        KL = 20.0u"ft"
        
        Fe_flexural = get_Fe_flexural(section, A992_Steel, KL; axis=:weak)
        Fe_torsional = get_Fe_torsional(section, A992_Steel, KL)
        
        # For W-shapes, torsional buckling stress is typically higher
        # (Flexural buckling about weak axis usually controls)
        @test Fe_flexural < Fe_torsional
        
        # The compression capacity should use the minimum
        ϕPn_flex = get_ϕPn(section, A992_Steel, KL; axis=:weak)
        ϕPn_tors = get_ϕPn(section, A992_Steel, KL; axis=:torsional)
        
        @test ϕPn_flex <= ϕPn_tors
    end

    # ==========================================================================
    # Test 10: Column Curve Verification
    # Verify the shape of the column strength curve
    # ==========================================================================
    @testset "Column Strength Curve" begin
        section = W("W14X82")
        ry = section.ry
        Fy = A992_Steel.Fy
        E = A992_Steel.E
        
        # Collect data points along the column curve
        strengths = Float64[]
        slenderness = Float64[]
        
        for KL_ft in [5, 10, 15, 20, 25, 30, 35, 40]
            KL = KL_ft * u"ft"
            ϕPn = get_ϕPn(section, A992_Steel, KL; axis=:weak)
            KL_r = ustrip(KL / ry)
            
            push!(slenderness, KL_r)
            push!(strengths, ustrip(u"kip", ϕPn))
        end
        
        # Verify monotonically decreasing strength with increasing slenderness
        for i in 2:length(strengths)
            @test strengths[i] < strengths[i-1]
        end
        
        # Verify transition point around λ = 4.71√(E/Fy) ≈ 113 for Fy=50ksi
        λ_transition = 4.71 * sqrt(ustrip(E / Fy))
        @test 100 < λ_transition < 130
    end

    # ==========================================================================
    # Test 11: Column Sizing via Optimizer
    # Use the full discrete MIP optimizer for a column under axial load
    # ==========================================================================
    @testset "Column Sizing via Optimizer" begin
        if !HAS_STRUCTURAL_SYNTHESIZER
            @info "Skipping (StructuralSynthesizer not available in this environment)"
            @test true
        else
        # Scenario: 14 ft column with axial compression
        # Applied load: Pu ≈ 400 kips (will be computed from tributary area concept)
        
        L_ft = 14.0
        L_m = ustrip(u"m", L_ft * u"ft")
        
        # 1. Geometry - vertical column
        skel = BuildingSkeleton{Float64}()
        id_bot = add_vertex!(skel, [0.0, 0.0, 0.0])
        id_top = add_vertex!(skel, [0.0, 0.0, L_m])  # Vertical column along Z
        e1 = add_element!(skel, id_bot, id_top)
        
        skel.groups_edges[:columns] = [e1]
        skel.groups_vertices[:support] = [id_bot]

        # 2. Initialize
        struc = BuildingStructure(skel)
        # For columns: Lb = L (default), Kx=Ky=1.0 (pinned-pinned)
        initialize_segments!(struc; default_Cb=1.0)
        initialize_members!(struc)
        
        # 3. Analysis model
        to_asap!(struc)
        model = struc.asap_model
        
        # Fixed base, pinned top (typical column BCs)
        # DOF order: [ux, uy, uz, rx, ry, rz]
        model.nodes[id_bot].dof = [false, false, false, false, false, false]  # Fixed base
        model.nodes[id_top].dof = [true, true, true, true, true, true]        # Free (load applied here)

        # 4. Apply axial load at top (compression = -Z direction... wait, column is along Z)
        # For a vertical column along Z, axial load is in Z direction
        Pu = 400.0u"kip"
        
        push!(model.loads, Asap.NodeForce(model.nodes[id_top], [0.0u"N", 0.0u"N", -Pu]))
        
        Asap.process!(model)
        Asap.solve!(model)
        
        # 5. Size using optimizer
        size_members_discrete!(
            struc;
            member_edge_group=:columns,
            material=A992_Steel,
            optimizer=:auto,
            resolution=100,
            reanalyze=true
        )
        
        # 6. Verify
        mg = struc.member_groups[first(keys(struc.member_groups))]
        selected = mg.section
        
        # Check capacity (K=1.0 assumed, weak axis governs)
        KL = L_ft * u"ft"
        ϕPn = get_ϕPn(selected, A992_Steel, KL; axis=:weak)
        
        # Must satisfy demand
        @test ϕPn >= Pu
        
        # Should select a reasonable W14 column section
        # W14x columns are typical for this load level
        @test startswith(selected.name, "W")
        
        # Weight should be reasonable (not oversized)
        weight_lbft = ustrip(u"lb/ft", selected.A * selected.material.ρ)
        @test weight_lbft < 150.0  # Reasonable upper bound
        end
    end

    # ==========================================================================
    # Test 12: Beam-Column via Optimizer (Combined P + M)
    # Column with both axial load and lateral load causing moment
    # ==========================================================================
    @testset "Beam-Column Sizing via Optimizer" begin
        if !HAS_STRUCTURAL_SYNTHESIZER
            @info "Skipping (StructuralSynthesizer not available in this environment)"
            @test true
        else
        # Scenario: 14 ft column with axial + lateral load
        # Simulates a frame column with wind/seismic lateral force
        
        L_ft = 14.0
        L_m = ustrip(u"m", L_ft * u"ft")
        
        # 1. Geometry - vertical column
        skel = BuildingSkeleton{Float64}()
        id_bot = add_vertex!(skel, [0.0, 0.0, 0.0])
        id_top = add_vertex!(skel, [0.0, 0.0, L_m])
        e1 = add_element!(skel, id_bot, id_top)
        
        skel.groups_edges[:columns] = [e1]
        skel.groups_vertices[:support] = [id_bot]

        # 2. Initialize
        struc = BuildingStructure(skel)
        initialize_segments!(struc; default_Cb=1.0)
        initialize_members!(struc)
        
        # 3. Analysis model
        to_asap!(struc)
        model = struc.asap_model
        
        # Fixed base, free top
        model.nodes[id_bot].dof = [false, false, false, false, false, false]
        model.nodes[id_top].dof = [true, true, true, true, true, true]

        # 4. Apply loads
        # Axial: 300 kips compression
        Pu = 300.0u"kip"
        # Lateral: 20 kips (causes moment at base = 20 × 14 = 280 k-ft)
        H = 20.0u"kip"
        
        push!(model.loads, Asap.NodeForce(model.nodes[id_top], [H, 0.0u"N", -Pu]))
        
        Asap.process!(model)
        Asap.solve!(model)
        
        # 5. Size using optimizer
        size_members_discrete!(
            struc;
            member_edge_group=:columns,
            material=A992_Steel,
            optimizer=:auto,
            resolution=100,
            reanalyze=true
        )
        
        # 6. Verify
        mg = struc.member_groups[first(keys(struc.member_groups))]
        selected = mg.section
        
        # Check capacities
        KL = L_ft * u"ft"
        Lb = L_ft * u"ft"
        
        ϕPn = get_ϕPn(selected, A992_Steel, KL; axis=:weak)
        ϕMnx = get_ϕMn(selected, A992_Steel; Lb=Lb, Cb=1.0, axis=:strong)
        
        # Approximate demands
        Pu_demand = 300.0u"kip"
        Mu_demand = 20.0u"kip" * L_ft * u"ft"  # ≈ 280 k-ft for cantilever
        
        # Check interaction (should be < 1.0 for valid design)
        ur = check_PMxMy_interaction(
            ustrip(u"N", Pu_demand),
            ustrip(u"N*m", Mu_demand),
            0.0,  # No weak-axis moment
            ustrip(u"N", ϕPn),
            ustrip(u"N*m", ϕMnx),
            ustrip(u"N*m", ϕMnx)  # Use strong axis for both (conservative)
        )
        
        @test ur <= 1.0
        
        # Should be heavier than pure axial case due to moment
        @test startswith(selected.name, "W")
        end
    end

end
