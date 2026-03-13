using StructuralSizer
# Units are re-exported from StructuralSizer (via Asap)
using Asap
using Unitful
using Test

# ------------------------------------------------------------------------------
# Optional dependency: StructuralSynthesizer
# Some example tests build BuildingSkeleton/BuildingStructure models (integration).
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
# AISC Design Examples - CE 405: Design of Steel Structures
# Reference: Prof. Dr. A. Varma, Chapter 2
# https://www.egr.msu.edu/~harichan/classes/ce405/chap2.pdf
# ==============================================================================

@testset "AISC Chapter 2 Beam Examples" begin

    # ==========================================================================
    # Example 2.1 (Adapted): Section Properties Verification
    # ==========================================================================
    @testset "Section Properties (Example 2.1 Concepts)" begin
        section = W("W21X55")
        
        # AISC 15th Ed. values for W21x55
        A_expected  = 16.2u"inch^2"
        Zx_expected = 126.0u"inch^3"
        Sx_expected = 110.0u"inch^3"
        
        # Verify properties within 5% tolerance (SI conversion rounding)
        @test isapprox(section.A, A_expected; rtol=0.05)
        @test isapprox(section.Zx, Zx_expected; rtol=0.05)
        @test isapprox(section.Sx, Sx_expected; rtol=0.05)
        
        # Shape factor f = Z/S ≈ 1.1 for W-shapes
        f = ustrip(section.Zx / section.Sx)
        @test 1.05 < f < 1.25
        
        # Capacity calculations
        Fy = 50.0ksi
        Mp = Fy * section.Zx
        My = Fy * section.Sx
        ϕMp = 0.9 * Mp
        
        # Per AISC Spec F1.1: ϕMp ≤ 1.5My
        @test ϕMp <= 1.5 * My
    end

    # ==========================================================================
    # Compact Section Classification (Example 2.6 Step IV/V)
    # ==========================================================================
    @testset "Compact Section Check" begin
        section = W("W21X55")
        
        E  = 29000.0  # ksi (unitless for ratio)
        Fy = 50.0     # ksi
        
        # Limiting slenderness for compact sections
        λp_flange = 0.38 * sqrt(E / Fy)  # = 9.15
        λp_web    = 3.76 * sqrt(E / Fy)  # = 90.55
        
        @test section.λ_f < λp_flange  # Flange compact
        @test section.λ_w < λp_web     # Web compact
        
        # Verify expected values from example
        @test section.λ_f ≈ 7.87 atol=0.1
        @test λp_flange ≈ 9.15 atol=0.05
        @test λp_web ≈ 90.55 atol=0.1
    end

    # ==========================================================================
    # Cb Calculation Verification (Example 2.6)
    # ==========================================================================
    @testset "Cb Calculation" begin
        # Moment function: M(x) = 62.24x - 4.52x²/2 (k-ft, x in ft)
        M(x) = 62.24 * x - 4.52 * x^2 / 2
        
        # Quarter-points along Lb = 12 ft
        MA   = M(3.0)
        MB   = M(6.0)
        MC   = M(9.0)
        Mmax = M(12.0)
        
        # Cb formula (AISC Eq. F1-1)
        Cb = 12.5 * Mmax / (2.5 * Mmax + 3 * MA + 4 * MB + 3 * MC)
        
        @test MA ≈ 166.38 atol=0.01
        @test MB ≈ 292.08 atol=0.01
        @test MC ≈ 377.10 atol=0.01
        @test Mmax ≈ 421.44 atol=0.01
        @test Cb ≈ 1.37 atol=0.01
    end

    # ==========================================================================
    # Example 2.4: Simply Supported Beam, Full Unbraced Length
    #
    # 24 ft span, Lb = 24 ft (bracing at ends only), Cb = 1.14
    # wL = 3.0 kip/ft (live), wsw = 0.1 kip/ft (self-weight)
    # wu = 1.2(0.1) + 1.6(3.0) = 4.92 kip/ft
    # Mu = wu × L²/8 = 354.24 k-ft
    # Mu/Cb = 310.74 k-ft
    # Expected selection: W16x67
    # ==========================================================================
    @testset "Example 2.4 - Unbraced Beam" begin
        if !HAS_STRUCTURAL_SYNTHESIZER
            @info "Skipping (StructuralSynthesizer not available in this environment)"
            @test true
        else
        # Verify load calculation
        w_sw = 0.1   # kip/ft (self-weight)
        w_L  = 3.0   # kip/ft (live)
        w_u  = 1.2 * w_sw + 1.6 * w_L
        @test w_u ≈ 4.92 atol=0.01
        
        L = 24.0  # ft
        Mu = w_u * L^2 / 8
        @test Mu ≈ 354.24 atol=0.1
        
        # Cb = 1.14 for parabolic moment (uniform load)
        Cb = 1.14
        Mu_over_Cb = Mu / Cb
        @test Mu_over_Cb ≈ 310.74 atol=0.5
        
        # 1. Geometry
        L_m = ustrip(u"m", L * u"ft")
        
        skel = BuildingSkeleton{Float64}()
        id1 = add_vertex!(skel, [0.0, 0.0, 0.0])
        id2 = add_vertex!(skel, [L_m, 0.0, 0.0])
        e1  = add_element!(skel, id1, id2)
        
        skel.groups_edges[:beams] = [e1]
        skel.groups_vertices[:support] = [id1, id2]

        # 2. Initialize (Lb = full span by default, Cb = 1.14)
        struc = BuildingStructure(skel)
        initialize_segments!(struc; default_Cb=1.14)
        initialize_members!(struc)
        
        # 3. Analysis model
        to_asap!(struc)
        model = struc.asap_model
        
        # Simply supported BCs
        model.nodes[id1].dof = [false, false, false, false, false, false]
        model.nodes[id2].dof = [true, true, false, true, true, true]

        # 4. Loads (pre-factored) - LineLoad expects Unitful quantities
        w_u_si = uconvert(u"N/m", w_u * kip/u"ft")
        push!(model.loads, Asap.LineLoad(model.elements[e1], [0.0u"N/m", 0.0u"N/m", -w_u_si]))
        
        Asap.process!(model)
        Asap.solve!(model)
        
        # 5. Size
        size_steel_members!(
            struc;
            member_edge_group=:beams,
            material=A992_Steel,
            solver=:auto,
            resolution=20,
            reanalyze=true
        )
        
        # 6. Verify
        mg = struc.member_groups[first(keys(struc.member_groups))]
        selected = mg.section
        
        ϕMn = get_ϕMn(selected, A992_Steel; Lb=24.0u"ft", Cb=1.14, axis=:strong)
        ϕMn_kft = ustrip(kip*u"ft", ϕMn)
        
        # Must satisfy demand
        @test ϕMn_kft >= 354.24
        
        # Textbook selects W16X67; optimizer may pick W14X74 or similar
        # depending on catalog ordering and reanalysis with self-weight.
        # Accept any adequate W-shape ≤ 80 lb/ft.
        @test selected.name in ("W16X67", "W14X74")
        end
    end

    # ==========================================================================
    # Example 2.5: Multi-Span Beam with Point Loads
    #
    # Total length: 30 ft (A-B: 12 ft, B-C: 8 ft, C-D: 10 ft)
    # Lateral bracing at A, B, C, D (load and reaction points)
    # Loads:
    #   wsw = 0.1 kip/ft → wu = 0.12 kip/ft
    #   PL = 30 kips at B and C → Pu = 48 kips each
    # Reactions: RA = 46.6 kips, RD = 53 kips
    # Max moments: 550.6 k-ft at B, 524 k-ft at C
    # ==========================================================================
    @testset "Example 2.5 - Multi-Span with Point Loads" begin
        if !HAS_STRUCTURAL_SYNTHESIZER
            @info "Skipping (StructuralSynthesizer not available in this environment)"
            @test true
        else
        # Verify load calculations
        w_sw = 0.1   # kip/ft
        w_u  = 1.2 * w_sw
        @test w_u ≈ 0.12 atol=0.01
        
        P_L = 30.0   # kips (live)
        P_u = 1.6 * P_L
        @test P_u ≈ 48.0 atol=0.01
        
        # Span lengths
        L_AB = 12.0  # ft
        L_BC = 8.0   # ft
        L_CD = 10.0  # ft
        L_total = L_AB + L_BC + L_CD
        @test L_total ≈ 30.0
        
        # Convert to meters
        x_A = 0.0
        x_B = ustrip(u"m", L_AB * u"ft")
        x_C = ustrip(u"m", (L_AB + L_BC) * u"ft")
        x_D = ustrip(u"m", L_total * u"ft")
        
        # 1. Geometry (4 nodes, 3 elements)
        skel = BuildingSkeleton{Float64}()
        idA = add_vertex!(skel, [x_A, 0.0, 0.0])
        idB = add_vertex!(skel, [x_B, 0.0, 0.0])
        idC = add_vertex!(skel, [x_C, 0.0, 0.0])
        idD = add_vertex!(skel, [x_D, 0.0, 0.0])
        
        e_AB = add_element!(skel, idA, idB)
        e_BC = add_element!(skel, idB, idC)
        e_CD = add_element!(skel, idC, idD)
        
        # All 3 elements in ONE member group → sized with same section
        skel.groups_edges[:beams] = [e_AB, e_BC, e_CD]
        skel.groups_vertices[:support] = [idA, idD]

        # 2. Initialize
        # Each segment has its own Lb (segment length), but all share one section
        # Lb defaults to full span (L), Cb = 1.0 (conservative)
        struc = BuildingStructure(skel)
        initialize_segments!(struc; default_Cb=1.0)
        initialize_members!(struc)
        
        # Assign same group_id to all members → single member group (continuous beam)
        beam_group_id = UInt64(hash(:continuous_beam))
        for m in struc.beams
            set_group_id!(m, beam_group_id)
        end
        
        # 3. Analysis model
        to_asap!(struc)
        model = struc.asap_model
        
        # Simply supported: Pin at A, Roller at D
        # DOF order: [ux, uy, uz, rx, ry, rz], false=fixed, true=free
        # Pin: fix translations, free rotations (especially ry for bending about Y)
        # Roller: allow X movement, fix Y/Z, free rotations
        model.nodes[idA].dof = [false, false, false, true, true, true]   # Pin
        model.nodes[idD].dof = [true, false, false, true, true, true]    # Roller

        # 4. Loads (Unitful quantities required)
        w_u_si = uconvert(u"N/m", w_u * kip/u"ft")
        P_u_si = uconvert(u"N", P_u * kip)
        
        # Distributed load on all elements
        push!(model.loads, Asap.LineLoad(model.elements[e_AB], [0.0u"N/m", 0.0u"N/m", -w_u_si]))
        push!(model.loads, Asap.LineLoad(model.elements[e_BC], [0.0u"N/m", 0.0u"N/m", -w_u_si]))
        push!(model.loads, Asap.LineLoad(model.elements[e_CD], [0.0u"N/m", 0.0u"N/m", -w_u_si]))
        
        # Point loads at B and C
        push!(model.loads, Asap.NodeForce(model.nodes[idB], [0.0u"N", 0.0u"N", -P_u_si]))
        push!(model.loads, Asap.NodeForce(model.nodes[idC], [0.0u"N", 0.0u"N", -P_u_si]))
        
        Asap.process!(model)
        Asap.solve!(model)
        
        # 5. Size (controlling moment ≈ 550.6 k-ft)
        size_steel_members!(
            struc;
            member_edge_group=:beams,
            material=A992_Steel,
            solver=:auto,
            resolution=20,
            reanalyze=true
        )
        
        # 6. Verify
        # Key test: Only ONE member group for all 3 segments
        @test length(struc.member_groups) == 1
        
        mg = struc.member_groups[first(keys(struc.member_groups))]
        selected = mg.section
        
        # Verify all 3 segments share the same section (single member group)
        @test length(mg.member_indices) == 3
        
        # Use the most critical span (AB with Lb=12ft) for capacity check
        # The example would determine Cb for each span; use conservative Cb=1.0
        ϕMn = get_ϕMn(selected, A992_Steel; Lb=12.0u"ft", Cb=1.0, axis=:strong)
        ϕMn_kft = ustrip(kip*u"ft", ϕMn)
        
        # Must satisfy controlling demand (≈ 550.6 k-ft)
        @test ϕMn_kft >= 550.0
        
        # Weight should be reasonable for this demand
        weight_lbft = ustrip(u"lb/ft", selected.A * selected.material.ρ)
        @test weight_lbft < 100.0  # Reasonable upper bound
        end
    end

    # ==========================================================================
    # Example 2.6: Simply Supported Beam Design
    #
    # 24 ft span, Lb = 12 ft, Cb = 1.37
    # w_u = 4.52 kip/ft, P_u = 16.0 kips at mid-span
    # M_u = 421.44 k-ft
    # Expected selection: W21x55
    # ==========================================================================
    @testset "Example 2.6 - Beam Design" begin
        if !HAS_STRUCTURAL_SYNTHESIZER
            @info "Skipping (StructuralSynthesizer not available in this environment)"
            @test true
        else
        # 1. Geometry
        L_m = ustrip(u"m", 24.0 * u"ft")
        
        skel = BuildingSkeleton{Float64}()
        id1 = add_vertex!(skel, [0.0, 0.0, 0.0])
        id2 = add_vertex!(skel, [L_m, 0.0, 0.0])
        e1  = add_element!(skel, id1, id2)
        
        skel.groups_edges[:beams] = [e1]
        skel.groups_vertices[:support] = [id1, id2]

        # 2. Initialize
        struc = BuildingStructure(skel)
        initialize_segments!(struc; default_Cb=1.37)
        # Lb = 12 ft (half of 24 ft span) - two bracing points
        for seg in struc.segments
            seg.Lb = seg.L * 0.5
        end
        initialize_members!(struc)
        
        # 3. Analysis model
        to_asap!(struc)
        model = struc.asap_model
        
        # Simply supported BCs
        model.nodes[id1].dof = [false, false, false, false, false, false]
        model.nodes[id2].dof = [true, true, false, true, true, true]

        # 4. Loads (pre-factored, Unitful)
        w_u_si = uconvert(u"N/m", 4.52 * kip/u"ft")
        P_u_si = uconvert(u"N", 16.0 * kip)
        
        push!(model.loads, Asap.LineLoad(model.elements[e1], [0.0u"N/m", 0.0u"N/m", -w_u_si]))
        push!(model.loads, Asap.PointLoad(model.elements[e1], 0.5, [0.0u"N", 0.0u"N", -P_u_si]))
        
        Asap.process!(model)
        Asap.solve!(model)
        
        # 5. Size
        size_steel_members!(
            struc;
            member_edge_group=:beams,
            material=A992_Steel,
            solver=:auto,
            resolution=20,
            reanalyze=true
        )
        
        # 6. Verify
        mg = struc.member_groups[first(keys(struc.member_groups))]
        selected = mg.section
        
        ϕMn = get_ϕMn(selected, A992_Steel; Lb=12.0u"ft", Cb=1.37, axis=:strong)
        ϕMn_kft = ustrip(kip*u"ft", ϕMn)
        
        # Must satisfy demand
        @test ϕMn_kft >= 421.44
        
        # Textbook selects W21X55; optimizer may pick W18X60 or similar
        # depending on catalog ordering and reanalysis with self-weight.
        @test selected.name in ("W21X55", "W18X60")
        end
    end

end
