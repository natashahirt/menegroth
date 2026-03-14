#!/usr/bin/env julia
# Test analytical visualization fields: shell forces, frame forces, diverging/sequential color data.
# Usage: julia --project=StructuralSynthesizer scripts/runners/run_analytical_viz_test.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using StructuralSynthesizer
using StructuralSizer
using Test
using Unitful

@testset "Analytical Visualization" begin

    # ─── Build a small 2×2 bay, 1-story flat plate building ──────────
    skel = gen_medium_office(30.0u"ft", 24.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)

    params = DesignParameters(
        name = "analytical_viz_test",
        floor = FlatPlateOptions(method = FEA()),
        materials = MaterialOptions(concrete = NWC_4000),
        max_iterations = 3,
    )

    design = design_building(struc, params)
    build_analysis_model!(design)
    output = design_to_json(design)

    @test output.status == "ok"
    viz = output.visualization
    @test !isnothing(viz)

    # ─── Frame element analytical fields ─────────────────────────────
    @testset "Frame element analytical fields" begin
        fe = viz.frame_elements
        @test !isempty(fe)

        for elem in fe
            @test hasfield(typeof(elem), :max_axial_force)
            @test hasfield(typeof(elem), :max_moment)
            @test hasfield(typeof(elem), :max_shear)
            @test elem.max_axial_force isa Float64
            @test elem.max_moment isa Float64
            @test elem.max_shear isa Float64
        end

        # At least some elements should have non-zero axial force
        @test any(e -> e.max_axial_force != 0.0, fe)

        # Gravity-loaded columns should be in compression (P < 0)
        columns = filter(e -> e.element_type == "column", fe)
        if !isempty(columns)
            @test any(e -> e.max_axial_force < 0, columns)
            println("  Columns: $(length(columns)), axial range: " *
                    "$(minimum(e.max_axial_force for e in columns)) to " *
                    "$(maximum(e.max_axial_force for e in columns))")
        end

        # Beams (if present) should have moments; columns-only building may have M=0
        beams = filter(e -> e.element_type == "beam", fe)
        if !isempty(beams)
            @test any(e -> e.max_moment != 0.0, beams)
        else
            println("  (no beams in this model — moment/shear may be zero for columns)")
        end

        println("  Frame elements: $(length(fe))")
    end

    # ─── Deflected slab mesh analytical fields ───────────────────────
    @testset "Slab mesh analytical fields" begin
        meshes = viz.deflected_slab_meshes
        @test !isempty(meshes)

        for mesh in meshes
            n_faces = length(mesh.faces)
            @test n_faces > 0

            # All face arrays should be present and same length as faces
            @test length(mesh.face_bending_moment) == n_faces
            @test length(mesh.face_membrane_force) == n_faces
            @test length(mesh.face_shear_force) == n_faces
            @test length(mesh.face_von_mises) == n_faces
            @test length(mesh.face_surface_stress) == n_faces

            # Signed quantities should have non-zero values
            @test any(v -> v != 0, mesh.face_bending_moment)
            @test any(v -> v != 0, mesh.face_surface_stress)
            # Membrane forces may be zero for a flat plate under pure gravity (no in-plane loads)
            if any(v -> v != 0, mesh.face_membrane_force)
                println("    Membrane force: non-zero (in-plane loads present)")
            else
                println("    Membrane force: all zero (pure bending, no in-plane loads — expected for flat plate)")
            end

            # Unsigned quantities should be ≥ 0
            @test all(v -> v >= 0, mesh.face_shear_force)
            @test all(v -> v >= 0, mesh.face_von_mises)

            println("  Slab $(mesh.slab_id): $(n_faces) faces")
            println("    Bending: $(round(minimum(mesh.face_bending_moment); digits=2)) to " *
                    "$(round(maximum(mesh.face_bending_moment); digits=2))")
            println("    Membrane: $(round(minimum(mesh.face_membrane_force); digits=2)) to " *
                    "$(round(maximum(mesh.face_membrane_force); digits=2))")
            println("    Shear: 0 to $(round(maximum(mesh.face_shear_force); digits=2))")
            println("    Von Mises: 0 to $(round(maximum(mesh.face_von_mises); digits=2))")
            println("    Surface σ: $(round(minimum(mesh.face_surface_stress); digits=2)) to " *
                    "$(round(maximum(mesh.face_surface_stress); digits=2))")
        end
    end

    # ─── Global maxima for color normalization ───────────────────────
    @testset "Global analytical maxima" begin
        @test viz.max_frame_axial >= 0
        @test viz.max_frame_moment >= 0
        @test viz.max_frame_shear >= 0
        @test viz.max_slab_bending >= 0
        @test viz.max_slab_membrane >= 0
        @test viz.max_slab_shear >= 0
        @test viz.max_slab_von_mises >= 0
        @test viz.max_slab_surface_stress >= 0

        # For a real building, these should be non-zero
        @test viz.max_frame_axial > 0
        @test viz.max_slab_bending > 0
        @test viz.max_slab_von_mises > 0

        println("  Global maxima:")
        println("    Frame: axial=$(viz.max_frame_axial), moment=$(viz.max_frame_moment), shear=$(viz.max_frame_shear)")
        println("    Slab: bending=$(viz.max_slab_bending), membrane=$(viz.max_slab_membrane), " *
                "shear=$(viz.max_slab_shear)")
        println("    Slab: von_mises=$(viz.max_slab_von_mises), surface_stress=$(viz.max_slab_surface_stress)")
    end

    # ─── Diverging symmetry check ────────────────────────────────────
    @testset "Diverging color symmetry" begin
        meshes = viz.deflected_slab_meshes
        if !isempty(meshes)
            all_bending = vcat([m.face_bending_moment for m in meshes]...)
            if !isempty(all_bending)
                @test viz.max_slab_bending ≈ maximum(abs, all_bending) atol=0.01
            end

            all_membrane = vcat([m.face_membrane_force for m in meshes]...)
            if !isempty(all_membrane)
                @test viz.max_slab_membrane ≈ maximum(abs, all_membrane) atol=0.01
            end
        end

        fe = viz.frame_elements
        if !isempty(fe)
            @test viz.max_frame_axial ≈ maximum(abs(e.max_axial_force) for e in fe) atol=0.01
        end

        println("  Diverging symmetry checks passed")
    end

end

println("\n✓ All analytical visualization tests passed!")
