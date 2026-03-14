# =============================================================================
# Vault Pipeline Integration Test
# =============================================================================
#
# Tests the full design pipeline for vault floor systems:
#   skeleton → structure → design_building(vault) → beams + columns sized
#
# The vault produces lateral thrust that beams must resist, and gravity loads
# that columns carry. This test verifies the entire chain works together.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

@testset "Vault Pipeline" begin

    # ─── Build a small 2×2 bay, 1-story building ────────────────────────
    skel = gen_medium_office(30.0u"ft", 24.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)

    # ─── Design parameters: vault floor with λ = 8 ──────────────────────
    params = DesignParameters(
        name = "vault_pipeline_test",
        floor = StructuralSizer.VaultOptions(
            lambda = 8.0,
            material = StructuralSizer.NWC_4000,
        ),
    )

    # ─── Run the full pipeline ──────────────────────────────────────────
    design = design_building(struc, params)

    # Helper: collect vault slabs
    vault_slabs = [s for s in struc.slabs if s.result isa StructuralSizer.VaultResult]

    # =====================================================================
    # 1. Slab results
    # =====================================================================
    @testset "Slab sizing" begin
        @test !isempty(design.slabs)
        @test !isempty(vault_slabs)

        for slab in vault_slabs
            r = slab.result
            @test r.thickness > 0.0u"m"
            @test r.rise > 0.0u"m"
            @test r.arc_length > 0.0u"m"
            @test r.volume_per_area > 0.0u"m"
            @test StructuralSizer.self_weight(r) > 0.0u"kPa"

            # Arc length > span (curved shell longer than chord)
            @test r.arc_length > slab.spans.primary
        end
    end

    # =====================================================================
    # 2. Vault thrust
    # =====================================================================
    @testset "Vault thrust" begin
        for slab in vault_slabs
            r = slab.result

            @test r.thrust_dead > 0.0u"kN/m"
            @test r.thrust_live > 0.0u"kN/m"

            H_total = StructuralSizer.total_thrust(r)
            @test H_total ≈ r.thrust_dead + r.thrust_live

            effects = StructuralSizer.structural_effects(r)
            @test length(effects) == 1
            @test effects[1] isa StructuralSizer.LateralThrust
        end
    end

    # =====================================================================
    # 3. Design checks
    # =====================================================================
    @testset "Design checks" begin
        for slab in vault_slabs
            r = slab.result

            @test r.stress_check.σ > 0.0
            @test r.stress_check.σ_allow > 0.0
            @test r.stress_check.ratio > 0.0
            @test r.stress_check.ok

            @test r.deflection_check.limit > 0.0
            @test r.deflection_check.ok

            @test r.convergence_check.converged

            @test StructuralSizer.is_adequate(r)
        end
    end

    # =====================================================================
    # 4. Beam sizing (beams must resist vault thrust)
    # =====================================================================
    @testset "Beam sizing" begin
        @test !isempty(design.beams)
        n_ok = count(r -> r.ok, values(design.beams))
        println("  Beams: $n_ok / $(length(design.beams)) pass")
    end

    # =====================================================================
    # 5. Column sizing
    # =====================================================================
    @testset "Column sizing" begin
        @test !isempty(design.columns)
        n_ok = count(r -> r.ok, values(design.columns))
        println("  Columns: $n_ok / $(length(design.columns)) pass")
    end

    # =====================================================================
    # 6. Design summary
    # =====================================================================
    @testset "Design summary" begin
        s = design.summary
        @test s.critical_ratio >= 0.0
        @test !isempty(s.critical_element)

        println("\n  ═══ Vault Pipeline Summary ═══")
        println("  Name: $(design.params.name)")
        println("  All pass: $(s.all_checks_pass)")
        println("  Critical: $(s.critical_element) (ratio=$(round(s.critical_ratio, digits=3)))")
        println("  Beams: $(length(design.beams))  Columns: $(length(design.columns))")

        for (i, slab) in enumerate(vault_slabs)
            r = slab.result
            println("\n  ─── Vault Slab $i ───")
            println("  Span:  $(round(u"ft", slab.spans.primary, digits=1))")
            println("  Rise:  $(round(u"inch", r.rise, digits=1))")
            println("  Shell: $(round(u"inch", r.thickness, digits=2))")
            println("  λ:     $(round(ustrip(slab.spans.primary / r.rise), digits=1))")
            println("  Thrust (D): $(round(u"kip/ft", r.thrust_dead, digits=2))")
            println("  Thrust (L): $(round(u"kip/ft", r.thrust_live, digits=2))")
            println("  σ/σ_allow:  $(round(r.stress_check.ratio, digits=3))")
        end
    end

    # =====================================================================
    # 7. Curved vault mesh serialization
    # =====================================================================
    @testset "Vault mesh serialization" begin
        # Run full design with analysis model
        build_analysis_model!(design)
        
        # Get visualization data
        output = StructuralSynthesizer.serialize_output(design)
        @test haskey(output, :visualization) || output.status == "ok"
        
        viz = output.visualization
        @test !isnothing(viz)
        
        # Check sized_slabs for vault-specific fields
        sized_slabs = viz.sized_slabs
        @test !isempty(sized_slabs)
        
        # Find vault slabs
        vault_sized = filter(s -> s.is_vault, sized_slabs)
        @test !isempty(vault_sized)
        
        for vslab in vault_sized
            @test vslab.is_vault
            @test !isempty(vslab.vault_mesh_vertices)
            @test !isempty(vslab.vault_mesh_faces)
            
            # Verify mesh is curved (Z varies)
            zs = [v[3] for v in vslab.vault_mesh_vertices]
            @test maximum(zs) > minimum(zs) + 0.1  # Rise > 0.1 ft
            
            # Verify face indices are valid
            n_verts = length(vslab.vault_mesh_vertices)
            for face in vslab.vault_mesh_faces
                @test length(face) == 3
                @test all(i -> 1 <= i <= n_verts, face)
            end
            
            println("  Vault mesh: $(n_verts) vertices, $(length(vslab.vault_mesh_faces)) faces")
            println("  Z range: $(round(minimum(zs), digits=2)) - $(round(maximum(zs), digits=2)) ft")
        end
    end

    # =====================================================================
    # 8. Sensitivity: λ variation
    # =====================================================================
    @testset "Lambda sensitivity" begin
        # Shallower vault (higher λ) → higher thrust: H = wL²/(8h), h = L/λ → H ∝ λ
        thrusts = Float64[]
        lambdas = [6.0, 8.0, 12.0]

        for λ in lambdas
            skel_i = gen_medium_office(30.0u"ft", 24.0u"ft", 12.0u"ft", 2, 2, 1)
            struc_i = BuildingStructure(skel_i)

            p = DesignParameters(
                name = "lambda_$λ",
                floor = StructuralSizer.VaultOptions(lambda = λ, material = StructuralSizer.NWC_4000),
            )

            d = design_building(struc_i, p)

            for slab in struc_i.slabs
                if slab.result isa StructuralSizer.VaultResult
                    push!(thrusts, ustrip(u"kN/m", StructuralSizer.total_thrust(slab.result)))
                    break
                end
            end
        end

        @test length(thrusts) == length(lambdas)
        for i in 1:length(thrusts)-1
            @test thrusts[i] < thrusts[i+1]
        end

        println("\n  Lambda sensitivity: λ = $lambdas → H = $(round.(thrusts, digits=1)) kN/m")
    end
end

println("\n✓ All vault pipeline tests passed!")
