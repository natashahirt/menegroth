using StructuralSizer
# Units are re-exported from StructuralSizer (via Asap)
using Asap
using Unitful
using Test

# ------------------------------------------------------------------------------
# Optional dependency: StructuralSynthesizer
# These tests exercise end-to-end BuildingSkeleton/BuildingStructure workflows,
# which live in StructuralSynthesizer (not a hard dependency of StructuralSizer).
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
# Hand Calculation Validation Test
# Scenario: Simply Supported Beam, 20 ft Span, Continuous Bracing
# Loads: 1.0 klf Dead + 1.0 klf Live
#
# LRFD Load Combination: 1.2D + 1.6L = 2.8 klf
# Mu = wL²/8 = 2.8 × 20² / 8 = 140 k-ft
#
# Expected selection: W16x26 (lightest section that passes)
# ==============================================================================

@testset "Hand Calculation Beam Validation" begin

    # ==========================================================================
    # Verify Load Calculation
    # ==========================================================================
    @testset "Load Calculation" begin
        w_D = 1.0  # klf
        w_L = 1.0  # klf
        w_u = 1.2 * w_D + 1.6 * w_L
        
        @test w_u ≈ 2.8  # klf factored
        
        L = 20.0  # ft
        Mu = w_u * L^2 / 8
        
        @test Mu ≈ 140.0  # k-ft
    end

    # ==========================================================================
    # Beam Sizing Test
    # ==========================================================================
    @testset "Beam Sizing - Simply Supported, Continuous Bracing" begin
        if !HAS_STRUCTURAL_SYNTHESIZER
            @info "Skipping (StructuralSynthesizer not available in this environment)"
            @test true
        else
        # 1. Geometry (20 ft span)
        L_ft = 20.0
        L_m  = ustrip(u"m", L_ft * u"ft")
        
        skel = BuildingSkeleton{Float64}()
        add_vertex!(skel, [0.0, 0.0, 0.0])
        add_vertex!(skel, [L_m, 0.0, 0.0])
        add_element!(skel, 1, 2)
        
        skel.groups_edges[:beams] = [1]
        skel.groups_vertices[:support] = [1, 2]

        # 2. Initialize
        struc = BuildingStructure(skel)
        initialize_segments!(struc)
        # Continuous bracing → Lb ≈ 0
        for seg in struc.segments
            seg.Lb = zero(seg.L)
        end
        initialize_members!(struc)
        
        # 3. Analysis model
        to_asap!(struc)
        model = struc.asap_model
        
        # Simply supported BCs
        model.nodes[1].dof = [false, false, false, false, false, false]
        model.nodes[2].dof = [true, true, false, true, true, true]
        
        # 4. Apply loads (LRFD factored: 1.2D + 1.6L = 2.8 klf)
        w_factored_klf = 2.8
        w_factored_si = uconvert(u"N/m", w_factored_klf * kip/u"ft")
        
        push!(model.loads, Asap.LineLoad(model.elements[1], [0.0u"N/m", 0.0u"N/m", -w_factored_si]))
        
        Asap.process!(model)
        Asap.solve!(model)
        
        # Expected moment: Mu = wL²/8 = 140 k-ft
        Mu_expected_kft = 140.0
        Mu_expected_Nm = ustrip(u"N*m", Mu_expected_kft * kip*u"ft")
        
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
        
        # Capacity check (continuous bracing → full Mp)
        ϕMn = 0.9 * A992_Steel.Fy * selected.Zx
        ϕMn_Nm = ustrip(u"N*m", ϕMn)
        
        ratio = Mu_expected_Nm / ϕMn_Nm
        
        # Must pass capacity check
        @test ratio <= 1.0
        
        # Expected: W16x26 is lightest passing section
        # Accept W16x26 or equivalent/lighter valid selection
        @test selected.name in ["W16X26", "W12X30", "W14X26"]
        
        # Weight should be reasonable (< 35 lb/ft for this demand)
        weight_lbft = ustrip(u"lb/ft", selected.A * selected.material.ρ)
        @test weight_lbft < 35.0
        end
    end

end
