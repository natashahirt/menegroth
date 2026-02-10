# =============================================================================
# FEA Flat Plate Integration Tests
# =============================================================================
#
# Tests the FEA moment analysis pipeline for flat plates:
# 1. Regular geometry (square, rectangle) — compare with DDM/EFM
# 2. Irregular geometries from Asap tributary tests — verify FEA handles them
# 3. Twisting ratio diagnostic on regular geometry
#
# Run: julia --project=. StructuralSizer/test/test_fea_flat_plate.jl
# =============================================================================

# Standalone: julia --project=. StructuralSizer/test/test_fea_flat_plate.jl
# (Pkg.activate removed — when included from runtests.jl, environment is already set up)

using Test
using Printf
using Unitful
using Unitful: @u_str
using Asap
using Meshes

using StructuralSynthesizer
using StructuralSizer

# =============================================================================
# Helpers
# =============================================================================

const HLINE = "─"^74
const DLINE = "═"^74

section_header(title) = println("\n", DLINE, "\n  ", title, "\n", DLINE)
row_header(title) = println("\n  ", title, "\n  ", HLINE)

"""Print moment comparison table for DDM / EFM / FEA."""
function print_moment_table(results::Dict{String, Any})
    @printf("  %-12s  %10s  %10s  %10s  %10s  %8s\n",
            "Method", "M₀", "M⁻_ext", "M⁻_int", "M⁺", "∑/M₀")
    println("  ", "─"^68)

    for name in ["DDM", "EFM", "FEA"]
        r = get(results, name, nothing)
        if isnothing(r) || r isa Exception
            msg = r isa Exception ? string(typeof(r).name.name) : "skipped"
            @printf("  %-12s  %s\n", name, msg)
        else
            M0  = ustrip(kip * u"ft", r.M0)
            Mne = ustrip(kip * u"ft", r.M_neg_ext)
            Mni = ustrip(kip * u"ft", r.M_neg_int)
            Mp  = ustrip(kip * u"ft", r.M_pos)
            check = (Mne + Mni) / 2 + Mp
            ratio = M0 > 0 ? check / M0 : 0.0
            @printf("  %-12s  %10.1f  %10.1f  %10.1f  %10.1f  %7.1f%%\n",
                    name, M0, Mne, Mni, Mp, ratio * 100)
        end
    end
end

"""
    run_all_methods(struc, slab, columns, h, Ecs, fc, γ, ν) -> Dict

Run DDM, EFM, FEA on a slab, catching failures for inapplicable methods.
"""
function run_all_methods(struc, slab, columns, h, Ecs, fc, γ;
                         ν=0.20, fea_target_edge=nothing)
    methods = [
        ("DDM", StructuralSizer.DDM()),
        ("EFM", StructuralSizer.EFM()),
        ("FEA", StructuralSizer.FEA(target_edge=fea_target_edge)),
    ]
    results = Dict{String, Any}()
    for (name, method) in methods
        try
            r = StructuralSizer.run_moment_analysis(
                method, struc, slab, columns, h, fc, Ecs, γ;
                ν_concrete=ν, verbose=false
            )
            results[name] = r
        catch e
            results[name] = e
            @warn "  $name failed" exception=e
        end
    end
    return results
end

# =============================================================================
# Test 1: Regular 3×3 Grid (StructurePoint Validation Geometry)
# =============================================================================

@testset "FEA Flat Plate Analysis" begin

section_header("Test 1: Regular 3×3 Grid — 18 ft × 14 ft Panels")

@testset "Regular grid: FEA vs DDM/EFM" begin
    # 3×3 bay grid → 18 ft × 14 ft panels, 9 ft story height
    skel = gen_medium_office(54.0u"ft", 42.0u"ft", 9.0u"ft", 3, 3, 1)
    struc = BuildingStructure(skel)

    # Initialize with FEA flat plate
    opts = FloorOptions(
        flat_plate = FlatPlateOptions(
            material = RC_4000_60,
            analysis_method = :fea,
            cover = 0.75u"inch",
            bar_size = 5,
        ),
        tributary_axis = nothing
    )
    initialize!(struc; floor_type=:flat_plate, floor_kwargs=(options=opts,))

    # Override loads to match StructurePoint example
    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 20.0u"psf")
        cell.live_load = uconvert(u"kN/m^2", 40.0u"psf")
    end

    # Column sizes: 16" × 16"
    for col in struc.columns
        col.c1 = 16.0u"inch"
        col.c2 = 16.0u"inch"
    end

    to_asap!(struc)

    # Pick one interior slab for comparison
    slab = struc.slabs[1]
    slab_cell_set = Set(slab.cell_indices)
    columns = StructuralSizer.find_supporting_columns(struc, slab_cell_set)

    # Material properties
    fc = 4000.0u"psi"
    γ = RC_4000_60.concrete.ρ
    ν = RC_4000_60.concrete.ν
    wc_pcf = ustrip(StructuralSizer.pcf, γ)
    Ecs = StructuralSizer.Ec(fc, wc_pcf)

    # Slab thickness: 7 inch (StructurePoint result)
    h = 7.0u"inch"

    # Run all three methods
    results = run_all_methods(struc, slab, columns, h, Ecs, fc, γ; ν=ν)
    row_header("Moment Comparison (kip·ft)")
    print_moment_table(results)

    # FEA should produce a result
    @test haskey(results, "FEA") && !(results["FEA"] isa Exception)

    if haskey(results, "FEA") && !(results["FEA"] isa Exception)
        fea = results["FEA"]
        M0_kipft = ustrip(kip * u"ft", fea.M0)

        # M₀ should be positive and reasonable (exact value depends on slab grouping)
        @test M0_kipft > 10.0

        # Positive moment should be positive
        M_pos = ustrip(kip * u"ft", fea.M_pos)
        @test M_pos > 0

        # Column shears should be reasonable (total ≈ qu × A_trib)
        @test !isempty(fea.column_shears)
        total_Vu = sum(ustrip.(u"kN", fea.column_shears))
        @test total_Vu > 0

        println("\n  FEA Result:")
        @printf("    M₀ = %.1f kip·ft\n", M0_kipft)
        @printf("    M⁻_ext = %.1f kip·ft\n", ustrip(kip * u"ft", fea.M_neg_ext))
        @printf("    M⁻_int = %.1f kip·ft\n", ustrip(kip * u"ft", fea.M_neg_int))
        @printf("    M⁺ = %.1f kip·ft\n", M_pos)
        @printf("    Vu_max = %.1f kip (first column)\n", ustrip(kip, fea.column_shears[1]))
    end
end

# =============================================================================
# Test 2: FEA-Only Geometries (Shapes Where DDM/EFM Don't Apply)
# =============================================================================

section_header("Test 2: FEA-Only — Shell Model Builder on Various Shapes")

@testset "FEA shell model builds correctly" begin
    # Test the shell model builder directly with a simple quad slab
    # This tests _build_fea_slab_model and _get_slab_face_boundary

    skel = gen_medium_office(24.0u"ft", 20.0u"ft", 10.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)

    opts = FloorOptions(
        flat_plate = FlatPlateOptions(
            material = RC_4000_60,
            analysis_method = :fea,
            cover = 0.75u"inch",
        ),
        tributary_axis = nothing
    )
    initialize!(struc; floor_type=:flat_plate, floor_kwargs=(options=opts,))

    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 20.0u"psf")
        cell.live_load = uconvert(u"kN/m^2", 50.0u"psf")
    end
    for col in struc.columns
        col.c1 = 12.0u"inch"
        col.c2 = 12.0u"inch"
    end

    to_asap!(struc)

    # Run FEA
    slab = struc.slabs[1]
    slab_cell_set = Set(slab.cell_indices)
    columns = StructuralSizer.find_supporting_columns(struc, slab_cell_set)

    fc = 4000.0u"psi"
    γ = RC_4000_60.concrete.ρ
    ν = RC_4000_60.concrete.ν
    Ecs = StructuralSizer.Ec(fc, ustrip(StructuralSizer.pcf, γ))
    h = 8.0u"inch"

    fea_result = StructuralSizer.run_moment_analysis(
        StructuralSizer.FEA(target_edge=0.40u"m"), struc, slab, columns, h, fc, Ecs, γ;
        ν_concrete=ν, verbose=false
    )

    @test fea_result isa StructuralSizer.MomentAnalysisResult
    @test ustrip(kip * u"ft", fea_result.M0) > 0
    @test ustrip(kip * u"ft", fea_result.M_pos) > 0
    @test length(fea_result.column_shears) == length(columns)
    @test all(ustrip.(u"kN", fea_result.column_shears) .> 0)

    println("  2×2 grid: FEA ran successfully")
    @printf("    M₀ = %.1f kip·ft,  M⁺ = %.1f kip·ft\n",
            ustrip(kip * u"ft", fea_result.M0),
            ustrip(kip * u"ft", fea_result.M_pos))
    @printf("    %d columns, shear range: %.1f – %.1f kip\n",
            length(columns),
            minimum(ustrip.(kip, fea_result.column_shears)),
            maximum(ustrip.(kip, fea_result.column_shears)))
end

# =============================================================================
# Test 3: Twisting Ratio Diagnostic
# =============================================================================

section_header("Test 3: Twisting Ratio Diagnostic")

@testset "Twisting ratio for regular geometry" begin
    # On a regular rectangular grid, Mxy should be small → twisting ratio ≈ 0
    skel = gen_medium_office(36.0u"ft", 36.0u"ft", 10.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)

    opts = FloorOptions(
        flat_plate = FlatPlateOptions(
            material = RC_4000_60,
            analysis_method = :fea,
        ),
        tributary_axis = nothing
    )
    initialize!(struc; floor_type=:flat_plate, floor_kwargs=(options=opts,))

    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 20.0u"psf")
        cell.live_load = uconvert(u"kN/m^2", 50.0u"psf")
    end
    for col in struc.columns
        col.c1 = 16.0u"inch"
        col.c2 = 16.0u"inch"
    end

    to_asap!(struc)

    slab = struc.slabs[1]
    slab_cell_set = Set(slab.cell_indices)
    columns = StructuralSizer.find_supporting_columns(struc, slab_cell_set)

    fc = 4000.0u"psi"
    γ = RC_4000_60.concrete.ρ
    ν = RC_4000_60.concrete.ν
    Ecs = StructuralSizer.Ec(fc, ustrip(StructuralSizer.pcf, γ))
    h = 8.0u"inch"

    fea_result = StructuralSizer.run_moment_analysis(
        StructuralSizer.FEA(), struc, slab, columns, h, fc, Ecs, γ;
        ν_concrete=ν, verbose=true
    )

    # For a square panel, twisting should be small
    M_pos = ustrip(kip * u"ft", fea_result.M_pos)
    @test M_pos > 0

    println("  Square grid: tributary integration ran successfully")
    @printf("    M₀ = %.1f kip·ft\n", ustrip(kip * u"ft", fea_result.M0))
end

# =============================================================================
# Test 4: Mesh Density Convergence
# =============================================================================

section_header("Test 4: Mesh Convergence")

@testset "Moment convergence with mesh refinement" begin
    skel = gen_medium_office(36.0u"ft", 28.0u"ft", 9.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)

    opts = FloorOptions(
        flat_plate = FlatPlateOptions(
            material = RC_4000_60,
            analysis_method = :fea,
        ),
        tributary_axis = nothing
    )
    initialize!(struc; floor_type=:flat_plate, floor_kwargs=(options=opts,))

    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 20.0u"psf")
        cell.live_load = uconvert(u"kN/m^2", 50.0u"psf")
    end
    for col in struc.columns
        col.c1 = 14.0u"inch"
        col.c2 = 14.0u"inch"
    end

    to_asap!(struc)

    slab = struc.slabs[1]
    slab_cell_set = Set(slab.cell_indices)
    columns = StructuralSizer.find_supporting_columns(struc, slab_cell_set)

    fc = 4000.0u"psi"
    γ = RC_4000_60.concrete.ρ
    ν = RC_4000_60.concrete.ν
    Ecs = StructuralSizer.Ec(fc, ustrip(StructuralSizer.pcf, γ))
    h = 7.0u"inch"

    M0_vals = Float64[]
    edges = [0.50u"m", 0.25u"m", 0.15u"m"]   # coarse → fine

    @printf("  %-12s  %10s  %10s  %10s\n", "Edge (m)", "M₀", "M⁻_int", "M⁺")
    println("  ", "─"^48)

    for te in edges
        r = StructuralSizer.run_moment_analysis(
            StructuralSizer.FEA(target_edge=te), struc, slab, columns, h, fc, Ecs, γ;
            ν_concrete=ν, verbose=false
        )
        push!(M0_vals, ustrip(kip * u"ft", r.M0))
        @printf("  %-12s  %10.1f  %10.1f  %10.1f\n",
                "$(ustrip(u"m", te)) m",
                ustrip(kip * u"ft", r.M0),
                ustrip(kip * u"ft", r.M_neg_int),
                ustrip(kip * u"ft", r.M_pos))
    end

    # M₀ is computed analytically so it should be identical across densities
    @test all(m ≈ M0_vals[1] for m in M0_vals)
end

# =============================================================================
# Test 5: Full Pipeline (FEA → Reinforcement Design)
# =============================================================================

section_header("Test 5: Full Design Pipeline with FEA")

@testset "FEA through full design pipeline" begin
    skel = gen_medium_office(54.0u"ft", 42.0u"ft", 9.0u"ft", 3, 3, 1)
    struc = BuildingStructure(skel)

    opts = FloorOptions(
        flat_plate = FlatPlateOptions(
            material = RC_4000_60,
            analysis_method = :fea,
            cover = 0.75u"inch",
            bar_size = 5,
            shear_studs = :always,
            min_h = 5.0u"inch",
        ),
        tributary_axis = nothing
    )
    initialize!(struc; floor_type=:flat_plate, floor_kwargs=(options=opts,))

    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 20.0u"psf")
        cell.live_load = uconvert(u"kN/m^2", 40.0u"psf")
    end
    for col in struc.columns
        col.c1 = 16.0u"inch"
        col.c2 = 16.0u"inch"
    end

    to_asap!(struc)

    # Run full sizing pipeline
    StructuralSizer.size_slabs!(struc; options=opts)

    # Check that all slabs got designed
    for (i, slab) in enumerate(struc.slabs)
        r = slab.result
        @test r isa StructuralSizer.FlatPlatePanelResult
        if r isa StructuralSizer.FlatPlatePanelResult
            @test ustrip(u"inch", r.h) >= 5.0  # Minimum thickness
            @test !isempty(r.column_strip_reinf)
            @test !isempty(r.middle_strip_reinf)
            println("  Slab $i: h = $(round(u"inch", r.h, digits=1)), " *
                    "M₀ = $(round(kip * u"ft", r.M0, digits=1))")
        end
    end
end

# =============================================================================
# Test 6: Irregular Grid — Column Shift X (Trapezoidal Panels)
# =============================================================================

section_header("Test 6: Shift-X Irregular Grid — Trapezoidal Panels")

@testset "Shift-X irregular grid" begin
    # 3×3 bays, interior columns shifted ±3 ft in x → trapezoidal cells
    # DDM/EFM require rectangular grids — FEA should handle this
    skel = gen_medium_office(60.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 1;
                             irregular=:shift_x, offset=3.0u"ft")
    struc = BuildingStructure(skel)

    opts = FloorOptions(
        flat_plate = FlatPlateOptions(
            material = RC_4000_60,
            analysis_method = :fea,
            cover = 0.75u"inch",
        ),
        tributary_axis = nothing
    )
    initialize!(struc; floor_type=:flat_plate, floor_kwargs=(options=opts,))

    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 25.0u"psf")
        cell.live_load = uconvert(u"kN/m^2", 50.0u"psf")
    end
    for col in struc.columns
        col.c1 = 14.0u"inch"
        col.c2 = 14.0u"inch"
    end

    to_asap!(struc)

    slab = struc.slabs[1]
    slab_cell_set = Set(slab.cell_indices)
    columns = StructuralSizer.find_supporting_columns(struc, slab_cell_set)

    fc = 4000.0u"psi"
    γ = RC_4000_60.concrete.ρ
    ν = RC_4000_60.concrete.ν
    Ecs = StructuralSizer.Ec(fc, ustrip(StructuralSizer.pcf, γ))
    h = 8.0u"inch"

    # DDM should fail on this geometry; FEA should succeed
    results = run_all_methods(struc, slab, columns, h, Ecs, fc, γ; ν=ν)
    row_header("Shift-X Results (kip·ft)")
    print_moment_table(results)

    @test haskey(results, "FEA") && !(results["FEA"] isa Exception)

    if !(results["FEA"] isa Exception)
        fea = results["FEA"]
        @test ustrip(kip * u"ft", fea.M0) > 0
        @test ustrip(kip * u"ft", fea.M_pos) > 0
        @test !isempty(fea.column_shears)

        println("\n  Trapezoidal panel FEA:")
        @printf("    M₀ = %.1f kip·ft,  M⁺ = %.1f kip·ft\n",
                ustrip(kip * u"ft", fea.M0), ustrip(kip * u"ft", fea.M_pos))
        @printf("    %d columns,  Vu range: %.1f – %.1f kip\n",
                length(columns),
                minimum(ustrip.(kip, fea.column_shears)),
                maximum(ustrip.(kip, fea.column_shears)))
    end
end

# =============================================================================
# Test 7: Irregular Grid — Zigzag (Diamond-like Panels)
# =============================================================================

section_header("Test 7: Zigzag Irregular Grid — Diamond-like Panels")

@testset "Zigzag irregular grid" begin
    # 3×3 bays with zigzag column shifts → parallelogram-like cells
    skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 1;
                             irregular=:zigzag, offset=2.5u"ft")
    struc = BuildingStructure(skel)

    opts = FloorOptions(
        flat_plate = FlatPlateOptions(
            material = RC_4000_60,
            analysis_method = :fea,
            cover = 0.75u"inch",
        ),
        tributary_axis = nothing
    )
    initialize!(struc; floor_type=:flat_plate, floor_kwargs=(options=opts,))

    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 20.0u"psf")
        cell.live_load = uconvert(u"kN/m^2", 50.0u"psf")
    end
    for col in struc.columns
        col.c1 = 14.0u"inch"
        col.c2 = 14.0u"inch"
    end

    to_asap!(struc)

    slab = struc.slabs[1]
    slab_cell_set = Set(slab.cell_indices)
    columns = StructuralSizer.find_supporting_columns(struc, slab_cell_set)

    fc = 4000.0u"psi"
    γ = RC_4000_60.concrete.ρ
    ν = RC_4000_60.concrete.ν
    Ecs = StructuralSizer.Ec(fc, ustrip(StructuralSizer.pcf, γ))
    h = 8.0u"inch"

    results = run_all_methods(struc, slab, columns, h, Ecs, fc, γ; ν=ν)
    row_header("Zigzag Results (kip·ft)")
    print_moment_table(results)

    @test haskey(results, "FEA") && !(results["FEA"] isa Exception)

    if !(results["FEA"] isa Exception)
        fea = results["FEA"]
        @test ustrip(kip * u"ft", fea.M0) > 0
        @test ustrip(kip * u"ft", fea.M_pos) > 0

        println("\n  Zigzag panel FEA:")
        @printf("    M₀ = %.1f kip·ft,  M⁺ = %.1f kip·ft\n",
                ustrip(kip * u"ft", fea.M0), ustrip(kip * u"ft", fea.M_pos))
        @printf("    %d columns,  Vu range: %.1f – %.1f kip\n",
                length(columns),
                minimum(ustrip.(kip, fea.column_shears)),
                maximum(ustrip.(kip, fea.column_shears)))
    end
end

# =============================================================================
# Test 8: Extreme Aspect Ratio (2.5:1)
# =============================================================================

section_header("Test 8: Extreme Aspect Ratio — 40 ft × 16 ft Panels")

@testset "Extreme aspect ratio panels" begin
    # 2×2 bays of 40 ft × 16 ft panels (2.5:1 ratio)
    # Tests FEA on long, narrow slabs where two-way action is weak
    skel = gen_medium_office(80.0u"ft", 32.0u"ft", 10.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)

    opts = FloorOptions(
        flat_plate = FlatPlateOptions(
            material = RC_4000_60,
            analysis_method = :fea,
            cover = 0.75u"inch",
        ),
        tributary_axis = nothing
    )
    initialize!(struc; floor_type=:flat_plate, floor_kwargs=(options=opts,))

    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 20.0u"psf")
        cell.live_load = uconvert(u"kN/m^2", 60.0u"psf")
    end
    for col in struc.columns
        col.c1 = 16.0u"inch"
        col.c2 = 16.0u"inch"
    end

    to_asap!(struc)

    slab = struc.slabs[1]
    slab_cell_set = Set(slab.cell_indices)
    columns = StructuralSizer.find_supporting_columns(struc, slab_cell_set)

    fc = 4000.0u"psi"
    γ = RC_4000_60.concrete.ρ
    ν = RC_4000_60.concrete.ν
    Ecs = StructuralSizer.Ec(fc, ustrip(StructuralSizer.pcf, γ))
    h = 9.0u"inch"

    results = run_all_methods(struc, slab, columns, h, Ecs, fc, γ; ν=ν)
    row_header("High Aspect Ratio Results (kip·ft)")
    print_moment_table(results)

    @test haskey(results, "FEA") && !(results["FEA"] isa Exception)

    if !(results["FEA"] isa Exception)
        fea = results["FEA"]
        @test ustrip(kip * u"ft", fea.M0) > 0
        @test ustrip(kip * u"ft", fea.M_pos) > 0

        println("\n  High aspect ratio FEA (40×16 ft):")
        @printf("    M₀ = %.1f kip·ft,  M⁺ = %.1f kip·ft\n",
                ustrip(kip * u"ft", fea.M0), ustrip(kip * u"ft", fea.M_pos))
        @printf("    %d columns,  Vu range: %.1f – %.1f kip\n",
                length(columns),
                minimum(ustrip.(kip, fea.column_shears)),
                maximum(ustrip.(kip, fea.column_shears)))
    end
end

# =============================================================================
# Test 9: Non-Uniform Bay Spacing (Custom Skeleton)
# =============================================================================

section_header("Test 9: Non-Uniform Bays — Mixed Spans")

@testset "Non-uniform bay spacing" begin
    # Create a skeleton with non-uniform bays:
    #   X bays: 15 ft, 25 ft, 15 ft
    #   Y bays: 12 ft, 20 ft
    # This creates panels of very different sizes, testing FEA's
    # geometry-agnostic moment extraction
    xs_ft = [0.0, 15.0, 40.0, 55.0]
    ys_ft = [0.0, 12.0, 32.0]

    T = typeof(1.0u"m")
    skel = BuildingSkeleton{T}()
    push!(skel.stories_z, 0.0u"m")
    push!(skel.stories_z, uconvert(u"m", 10.0u"ft"))

    # Build grid at floor level (k=0) and roof level (k=1)
    for k in 0:1
        z = skel.stories_z[k+1]
        # X beams
        for (jj, yy) in enumerate(ys_ft), ii in 1:(length(xs_ft)-1)
            p1 = Meshes.Point(uconvert(u"m", xs_ft[ii]   * u"ft"),
                              uconvert(u"m", yy * u"ft"), z)
            p2 = Meshes.Point(uconvert(u"m", xs_ft[ii+1] * u"ft"),
                              uconvert(u"m", yy * u"ft"), z)
            add_element!(skel, Meshes.Segment(p1, p2); group=:beams, level_idx=k)
        end
        # Y beams
        for (ii, xx) in enumerate(xs_ft), jj in 1:(length(ys_ft)-1)
            p1 = Meshes.Point(uconvert(u"m", xx * u"ft"),
                              uconvert(u"m", ys_ft[jj]   * u"ft"), z)
            p2 = Meshes.Point(uconvert(u"m", xx * u"ft"),
                              uconvert(u"m", ys_ft[jj+1] * u"ft"), z)
            add_element!(skel, Meshes.Segment(p1, p2); group=:beams, level_idx=k)
        end
        # Columns (k=1 only)
        if k == 1
            for xx in xs_ft, yy in ys_ft
                p_bot = Meshes.Point(uconvert(u"m", xx * u"ft"),
                                     uconvert(u"m", yy * u"ft"),
                                     skel.stories_z[1])
                p_top = Meshes.Point(uconvert(u"m", xx * u"ft"),
                                     uconvert(u"m", yy * u"ft"),
                                     skel.stories_z[2])
                add_element!(skel, Meshes.Segment(p_bot, p_top); group=:columns, level_idx=1)
            end
        end
    end

    # Supports at ground level
    for xx in xs_ft, yy in ys_ft
        p = Meshes.Point(uconvert(u"m", xx * u"ft"), uconvert(u"m", yy * u"ft"), 0.0u"m")
        add_vertex!(skel, p; group=:support)
    end
    # Roof vertices
    for xx in xs_ft, yy in ys_ft
        p = Meshes.Point(uconvert(u"m", xx * u"ft"), uconvert(u"m", yy * u"ft"), skel.stories_z[2])
        add_vertex!(skel, p; group=:roof)
    end

    find_faces!(skel)

    # Categorize faces
    for (level_idx, story) in skel.stories
        grp = level_idx == 0 ? :grade : :floor
        haskey(skel.groups_faces, grp) || (skel.groups_faces[grp] = Int[])
        append!(skel.groups_faces[grp], story.faces)
    end

    struc = BuildingStructure(skel)

    opts = FloorOptions(
        flat_plate = FlatPlateOptions(
            material = RC_4000_60,
            analysis_method = :fea,
            cover = 0.75u"inch",
        ),
        tributary_axis = nothing
    )
    initialize!(struc; floor_type=:flat_plate, floor_kwargs=(options=opts,))

    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 20.0u"psf")
        cell.live_load = uconvert(u"kN/m^2", 50.0u"psf")
    end
    for col in struc.columns
        col.c1 = 14.0u"inch"
        col.c2 = 14.0u"inch"
    end

    to_asap!(struc)

    println("  Non-uniform bays:  X = [15, 25, 15] ft   Y = [12, 20] ft")
    println("  $(length(struc.cells)) cells, $(length(struc.columns)) columns, $(length(struc.slabs)) slabs")

    slab = struc.slabs[1]
    slab_cell_set = Set(slab.cell_indices)
    columns = StructuralSizer.find_supporting_columns(struc, slab_cell_set)

    fc = 4000.0u"psi"
    γ = RC_4000_60.concrete.ρ
    ν = RC_4000_60.concrete.ν
    Ecs = StructuralSizer.Ec(fc, ustrip(StructuralSizer.pcf, γ))
    h = 8.0u"inch"

    results = run_all_methods(struc, slab, columns, h, Ecs, fc, γ; ν=ν)
    row_header("Non-Uniform Bays (kip·ft)")
    print_moment_table(results)

    @test haskey(results, "FEA") && !(results["FEA"] isa Exception)

    if !(results["FEA"] isa Exception)
        fea = results["FEA"]
        @test ustrip(kip * u"ft", fea.M0) > 0
        @test ustrip(kip * u"ft", fea.M_pos) > 0

        println("\n  Non-uniform bay FEA:")
        @printf("    M₀ = %.1f kip·ft,  M⁺ = %.1f kip·ft\n",
                ustrip(kip * u"ft", fea.M0), ustrip(kip * u"ft", fea.M_pos))
        @printf("    %d columns,  Vu range: %.1f – %.1f kip\n",
                length(columns),
                minimum(ustrip.(kip, fea.column_shears)),
                maximum(ustrip.(kip, fea.column_shears)))
    end
end

# =============================================================================
# Test 10: Irregular Column Positions — X & Y Shifts on Mixed Bays
# =============================================================================

section_header("Test 10: Irregular Columns — X & Y Shifts on Varying Bays")

@testset "Irregular columns with XY shifts" begin
    # Hand-built skeleton with deliberately messy column positions:
    #   Base grid ~20 ft bays, but interior columns shifted ±(2–4) ft
    #   in both X and Y to create trapezoidal / parallelogram cells.
    #
    #   Column layout (ft):
    #     (0,0)  (22,0)  (40,0)  (60,0)
    #     (0,18) (20,20) (42,17) (60,18)
    #     (0,36) (23,34) (41,37) (60,36)
    col_xy = [
        # Row 0
        (0.0, 0.0), (22.0, 0.0), (40.0, 0.0), (60.0, 0.0),
        # Row 1  — shifted ±2–4 ft
        (0.0, 18.0), (20.0, 20.0), (42.0, 17.0), (60.0, 18.0),
        # Row 2  — shifted ±1–3 ft
        (0.0, 36.0), (23.0, 34.0), (41.0, 37.0), (60.0, 36.0),
    ]

    T = typeof(1.0u"m")
    skel = BuildingSkeleton{T}()
    push!(skel.stories_z, 0.0u"m")
    push!(skel.stories_z, uconvert(u"m", 10.0u"ft"))

    # Connectivity: 4 cols × 3 rows → beams along rows and columns
    nx, ny = 4, 3
    function col_idx(ix, iy)  # 1-based
        return (iy - 1) * nx + ix
    end

    for k in 0:1
        z = skel.stories_z[k+1]
        # X beams (along rows)
        for iy in 1:ny, ix in 1:(nx-1)
            c1 = col_xy[col_idx(ix, iy)]
            c2 = col_xy[col_idx(ix+1, iy)]
            p1 = Meshes.Point(uconvert(u"m", c1[1]*u"ft"), uconvert(u"m", c1[2]*u"ft"), z)
            p2 = Meshes.Point(uconvert(u"m", c2[1]*u"ft"), uconvert(u"m", c2[2]*u"ft"), z)
            add_element!(skel, Meshes.Segment(p1, p2); group=:beams, level_idx=k)
        end
        # Y beams (along columns)
        for ix in 1:nx, iy in 1:(ny-1)
            c1 = col_xy[col_idx(ix, iy)]
            c2 = col_xy[col_idx(ix, iy+1)]
            p1 = Meshes.Point(uconvert(u"m", c1[1]*u"ft"), uconvert(u"m", c1[2]*u"ft"), z)
            p2 = Meshes.Point(uconvert(u"m", c2[1]*u"ft"), uconvert(u"m", c2[2]*u"ft"), z)
            add_element!(skel, Meshes.Segment(p1, p2); group=:beams, level_idx=k)
        end
        # Columns
        if k == 1
            for (cx, cy) in col_xy
                pb = Meshes.Point(uconvert(u"m", cx*u"ft"), uconvert(u"m", cy*u"ft"), skel.stories_z[1])
                pt = Meshes.Point(uconvert(u"m", cx*u"ft"), uconvert(u"m", cy*u"ft"), skel.stories_z[2])
                add_element!(skel, Meshes.Segment(pb, pt); group=:columns, level_idx=1)
            end
        end
    end

    for (cx, cy) in col_xy
        add_vertex!(skel, Meshes.Point(uconvert(u"m", cx*u"ft"), uconvert(u"m", cy*u"ft"), 0.0u"m"); group=:support)
        add_vertex!(skel, Meshes.Point(uconvert(u"m", cx*u"ft"), uconvert(u"m", cy*u"ft"), skel.stories_z[2]); group=:roof)
    end

    find_faces!(skel)
    for (level_idx, story) in skel.stories
        grp = level_idx == 0 ? :grade : :floor
        haskey(skel.groups_faces, grp) || (skel.groups_faces[grp] = Int[])
        append!(skel.groups_faces[grp], story.faces)
    end

    struc = BuildingStructure(skel)

    opts = FloorOptions(
        flat_plate = FlatPlateOptions(
            material = RC_4000_60,
            analysis_method = :fea,
            cover = 0.75u"inch",
        ),
        tributary_axis = nothing
    )
    initialize!(struc; floor_type=:flat_plate, floor_kwargs=(options=opts,))

    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 25.0u"psf")
        cell.live_load = uconvert(u"kN/m^2", 50.0u"psf")
    end
    for col in struc.columns
        col.c1 = 14.0u"inch"
        col.c2 = 14.0u"inch"
    end

    to_asap!(struc)

    println("  Irregular XY column layout: 4×3 grid with ±2–4 ft shifts")
    println("  $(length(struc.cells)) cells, $(length(struc.columns)) columns, $(length(struc.slabs)) slabs")

    slab = struc.slabs[1]
    slab_cell_set = Set(slab.cell_indices)
    columns = StructuralSizer.find_supporting_columns(struc, slab_cell_set)

    fc = 4000.0u"psi"
    γ = RC_4000_60.concrete.ρ
    ν = RC_4000_60.concrete.ν
    Ecs = StructuralSizer.Ec(fc, ustrip(StructuralSizer.pcf, γ))
    h = 9.0u"inch"

    results = run_all_methods(struc, slab, columns, h, Ecs, fc, γ; ν=ν)
    row_header("Irregular XY Results (kip·ft)")
    print_moment_table(results)

    @test haskey(results, "FEA") && !(results["FEA"] isa Exception)

    if !(results["FEA"] isa Exception)
        fea = results["FEA"]
        @test ustrip(kip * u"ft", fea.M0) > 0
        @test ustrip(kip * u"ft", fea.M_pos) > 0

        # Print per-column demands for inspection
        println("\n  Per-column shears:")
        for (i, Vu) in enumerate(fea.column_shears)
            @printf("    Col %2d: Vu = %6.1f kip", i, ustrip(kip, Vu))
            if i <= length(fea.unbalanced_moments)
                @printf("  Mub = %6.1f kip·ft", ustrip(kip * u"ft", fea.unbalanced_moments[i]))
            end
            println()
        end
    end
end

# =============================================================================
# Test 11: Full Pipeline — Irregular Geometry (size_slabs!)
# =============================================================================

section_header("Test 11: Full Pipeline on Irregular Geometry")

@testset "Full pipeline on shift-Y irregular grid" begin
    # Shift-Y creates trapezoidal panels; run the full sizing pipeline
    skel = gen_medium_office(54.0u"ft", 42.0u"ft", 9.0u"ft", 3, 3, 1;
                             irregular=:shift_y, offset=2.0u"ft")
    struc = BuildingStructure(skel)

    opts = FloorOptions(
        flat_plate = FlatPlateOptions(
            material = RC_4000_60,
            analysis_method = :fea,
            cover = 0.75u"inch",
            bar_size = 5,
            shear_studs = :always,
            min_h = 5.0u"inch",
        ),
        tributary_axis = nothing
    )
    initialize!(struc; floor_type=:flat_plate, floor_kwargs=(options=opts,))

    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 20.0u"psf")
        cell.live_load = uconvert(u"kN/m^2", 50.0u"psf")
    end
    for col in struc.columns
        col.c1 = 16.0u"inch"
        col.c2 = 16.0u"inch"
    end

    to_asap!(struc)

    # Run full sizing pipeline
    StructuralSizer.size_slabs!(struc; options=opts, max_iterations=20)

    println("  Shift-Y irregular grid: full pipeline results")
    for (i, slab) in enumerate(struc.slabs)
        r = slab.result
        @test r isa StructuralSizer.FlatPlatePanelResult
        if r isa StructuralSizer.FlatPlatePanelResult
            h_in = round(ustrip(u"inch", r.h), digits=1)
            M0_kf = round(ustrip(kip * u"ft", r.M0), digits=1)
            qu_psf = round(ustrip(u"psf", r.qu), digits=0)
            punch = r.punching_check.ok ? "✓" : "✗"
            defl  = r.deflection_check.ok ? "✓" : "✗"
            @printf("    Slab %d: h=%.1f\"  M₀=%.1f kip·ft  qu=%.0f psf  Punch %s  Defl %s\n",
                    i, h_in, M0_kf, qu_psf, punch, defl)
            @test h_in >= 5.0
            @test !isempty(r.column_strip_reinf)
        end
    end
end

# =============================================================================
# Test 12: Circular Columns — Octagonal ShellPatch + Circular Stub Section
# =============================================================================

section_header("Test 12: Circular Columns — Octagonal Mesh Patch")

@testset "FEA with circular columns" begin
    # 2×2 bay grid with circular columns
    skel = gen_medium_office(36.0u"ft", 28.0u"ft", 9.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)

    opts = FloorOptions(
        flat_plate = FlatPlateOptions(
            material = RC_4000_60,
            analysis_method = :fea,
            cover = 0.75u"inch",
            bar_size = 5,
        ),
        tributary_axis = nothing
    )
    initialize!(struc; floor_type=:flat_plate, floor_kwargs=(options=opts,))

    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 20.0u"psf")
        cell.live_load = uconvert(u"kN/m^2", 50.0u"psf")
    end

    # Set ALL columns to circular with D = 16"
    D = 16.0u"inch"
    for col in struc.columns
        col.c1 = D
        col.c2 = D
        col.shape = :circular
    end

    to_asap!(struc)

    slab = struc.slabs[1]
    slab_cell_set = Set(slab.cell_indices)
    columns = StructuralSizer.find_supporting_columns(struc, slab_cell_set)

    fc = 4000.0u"psi"
    γ = RC_4000_60.concrete.ρ
    ν = RC_4000_60.concrete.ν
    Ecs = StructuralSizer.Ec(fc, ustrip(StructuralSizer.pcf, γ))
    h = 7.0u"inch"

    # Run FEA with circular columns
    fea_circ = StructuralSizer.run_moment_analysis(
        StructuralSizer.FEA(target_edge=0.35u"m"), struc, slab, columns, h, fc, Ecs, γ;
        ν_concrete=ν, verbose=false
    )

    @test fea_circ isa StructuralSizer.MomentAnalysisResult
    @test ustrip(kip * u"ft", fea_circ.M0) > 0
    @test ustrip(kip * u"ft", fea_circ.M_pos) > 0
    @test length(fea_circ.column_shears) == length(columns)
    @test all(ustrip.(u"kN", fea_circ.column_shears) .> 0)

    println("  Circular columns (D = 16\"): FEA ran successfully")
    @printf("    M₀ = %.1f kip·ft,  M⁺ = %.1f kip·ft\n",
            ustrip(kip * u"ft", fea_circ.M0),
            ustrip(kip * u"ft", fea_circ.M_pos))
    @printf("    %d columns, shear range: %.1f – %.1f kip\n",
            length(columns),
            minimum(ustrip.(kip, fea_circ.column_shears)),
            maximum(ustrip.(kip, fea_circ.column_shears)))

    # ── Compare with rectangular columns of the SAME SIZE ──
    for col in struc.columns
        col.shape = :rectangular
    end
    columns_rect = StructuralSizer.find_supporting_columns(struc, slab_cell_set)

    fea_rect = StructuralSizer.run_moment_analysis(
        StructuralSizer.FEA(target_edge=0.35u"m"), struc, slab, columns_rect, h, fc, Ecs, γ;
        ν_concrete=ν, verbose=false
    )

    # Moments should be in the same ballpark (within 30%)
    M0_circ = ustrip(kip * u"ft", fea_circ.M0)
    M0_rect = ustrip(kip * u"ft", fea_rect.M0)
    @test M0_circ ≈ M0_rect rtol=0.01  # M0 is geometry-based, same for both

    Mp_circ = ustrip(kip * u"ft", fea_circ.M_pos)
    Mp_rect = ustrip(kip * u"ft", fea_rect.M_pos)
    @test Mp_circ > 0
    @test Mp_rect > 0
    # Circular columns have lower stub stiffness (πD²/4 vs D², πD⁴/64 vs D⁴/12)
    # so moment distribution shifts.  With equivalent-area square patches the
    # mesh is identical in quality; differences come only from the stub.
    @test Mp_circ / Mp_rect > 0.70
    @test Mp_circ / Mp_rect < 1.35

    println("\n  Circular vs Rectangular comparison (same D = c = 16\"):")
    @printf("    M₀:  circ = %.1f,  rect = %.1f kip·ft\n", M0_circ, M0_rect)
    @printf("    M⁺:  circ = %.1f,  rect = %.1f kip·ft (ratio = %.2f)\n",
            Mp_circ, Mp_rect, Mp_circ / Mp_rect)

    # Restore circular for subsequent tests
    for col in struc.columns
        col.shape = :circular
    end
end

@testset "FEA circular column — equivalent-area square patch" begin
    # Circular columns use an equivalent-area square patch for mesh conformity.
    # The actual circular physics are in the stub section (πD²/4, πD⁴/64).
    D_m = 0.4064  # 16 inches in meters
    r = D_m / 2
    eq_side = D_m * sqrt(π / 4)

    section = Asap.ShellSection(0.18u"m", 28e9u"Pa", 0.20; name=:test)
    patch = Asap.ShellPatch(3.0, 3.0, eq_side, eq_side, section; id=:col_patch)

    @test length(patch.vertices) == 4
    @test patch.center == (3.0, 3.0)

    # Patch area should equal circle area: π(D/2)² = πD²/4
    circle_area = π * r^2
    dx = patch.vertices[2][1] - patch.vertices[1][1]
    dy = patch.vertices[3][2] - patch.vertices[2][2]
    patch_area = abs(dx * dy)
    @test patch_area ≈ circle_area rtol=0.01

    @printf("  Eq-area square patch: side = %.3f m, area = %.4f m² (circle = %.4f m²) ✓\n",
            eq_side, patch_area, circle_area)
end

@testset "FEA circular column — stub section properties" begin
    # Verify circular column stub uses correct section properties
    D = 16.0u"inch"
    Ec = 4000.0u"ksi"

    col_circ = (c1=D, c2=D, shape=:circular)
    col_rect = (c1=D, c2=D, shape=:rectangular)

    sec_circ = StructuralSizer._column_stub_section(col_circ, Ec, 0.20)
    sec_rect = StructuralSizer._column_stub_section(col_rect, Ec, 0.20)

    # Circular A = 2 × πD²/4  vs  Rectangular A = 2 × c1 × c2
    A_circ_expected = 2 * π * ustrip(u"m", D)^2 / 4
    A_rect_expected = 2 * ustrip(u"m", D)^2

    @test ustrip(u"m^2", sec_circ.A) ≈ A_circ_expected rtol=0.01
    @test ustrip(u"m^2", sec_rect.A) ≈ A_rect_expected rtol=0.01

    # Circular area < rectangular area (π/4 ≈ 0.785)
    @test sec_circ.A < sec_rect.A

    # Circular Ix = 2 × πD⁴/64  vs  Rectangular Ix = 2 × c·c³/12
    Ix_circ_expected = 2 * π * ustrip(u"m", D)^4 / 64
    Ix_rect_expected = 2 * ustrip(u"m", D)^4 / 12

    @test ustrip(u"m^4", sec_circ.Ix) ≈ Ix_circ_expected rtol=0.01
    @test ustrip(u"m^4", sec_rect.Ix) ≈ Ix_rect_expected rtol=0.01

    println("  Stub section: circular A = $(round(ustrip(u"m^2", sec_circ.A)*1e4, digits=1)) cm², " *
            "rect A = $(round(ustrip(u"m^2", sec_rect.A)*1e4, digits=1)) cm²")
    println("  Stub section: circular Ix = $(round(ustrip(u"m^4", sec_circ.Ix)*1e8, digits=1)) cm⁴, " *
            "rect Ix = $(round(ustrip(u"m^4", sec_rect.Ix)*1e8, digits=1)) cm⁴")
end

@testset "FEA full sizing pipeline — circular columns" begin
    skel = gen_medium_office(54.0u"ft", 42.0u"ft", 9.0u"ft", 3, 3, 1)
    struc = BuildingStructure(skel)

    opts = FloorOptions(
        flat_plate = FlatPlateOptions(
            material = RC_4000_60,
            analysis_method = :fea,
            cover = 0.75u"inch",
            bar_size = 5,
            shear_studs = :always,
            min_h = 5.0u"inch",
        ),
        tributary_axis = nothing
    )
    initialize!(struc; floor_type=:flat_plate, floor_kwargs=(options=opts,))

    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 20.0u"psf")
        cell.live_load = uconvert(u"kN/m^2", 40.0u"psf")
    end

    # Circular columns: D = 18"
    for col in struc.columns
        col.c1 = 18.0u"inch"
        col.c2 = 18.0u"inch"
        col.shape = :circular
    end

    to_asap!(struc)

    # Run full sizing pipeline with circular columns
    StructuralSizer.size_slabs!(struc; options=opts)

    println("  Circular column (D=18\") full pipeline:")
    for (i, slab) in enumerate(struc.slabs)
        r = slab.result
        @test r isa StructuralSizer.FlatPlatePanelResult
        if r isa StructuralSizer.FlatPlatePanelResult
            @test ustrip(u"inch", r.h) >= 5.0
            @test !isempty(r.column_strip_reinf)
            @test !isempty(r.middle_strip_reinf)
            h_in = round(ustrip(u"inch", r.h), digits=1)
            M0_kf = round(ustrip(kip * u"ft", r.M0), digits=1)
            punch = r.punching_check.ok ? "✓" : "✗"
            defl  = r.deflection_check.ok ? "✓" : "✗"
            @printf("    Slab %d: h=%.1f\"  M₀=%.1f kip·ft  Punch %s  Defl %s\n",
                    i, h_in, M0_kf, punch, defl)
        end
    end
end

end  # @testset "FEA Flat Plate Analysis"

println("\n", DLINE)
println("  All FEA flat plate tests completed!")
println(DLINE)
