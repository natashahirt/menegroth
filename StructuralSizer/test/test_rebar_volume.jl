# =============================================================================
# Test: Rebar Volume Calculation for EC in FlatPlatePanelResult
# =============================================================================
#
# Verifies that embodied carbon calculations include reinforcing steel,
# not just concrete volume.
#
# Run: julia --project=StructuralSynthesizer test/test_rebar_volume.jl
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using Test
using StructuralSynthesizer
using StructuralSizer
using Unitful
using Asap: kip, ksi, psf

@testset "Flat Plate Rebar Volume for EC" begin
    
    # Create and size a flat plate structure
    skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 1)
    struc = BuildingStructure(skel)
    opts = FlatPlateOptions()
    initialize!(struc; floor_type = :flat_plate, floor_opts = opts)
    
    for col in struc.columns
        col.c1 = 16.0u"inch"
        col.c2 = 16.0u"inch"
    end
    for cell in struc.cells
        cell.sdl = 20.0psf
        cell.live_load = 50.0psf
    end
    
    to_asap!(struc)
    size_slabs!(struc; options = opts, verbose = false)
    update_slab_volumes!(struc; options = opts)
    
    result = struc.slabs[1].result
    slab = struc.slabs[1]
    
    @testset "materials() includes steel" begin
        mats = StructuralSizer.materials(result)
        @test :concrete in mats
        @test :steel in mats
    end
    
    @testset "volume_per_area returns valid values" begin
        conc_vol = StructuralSizer.volume_per_area(result, :concrete)
        steel_vol = StructuralSizer.volume_per_area(result, :steel)
        
        @test conc_vol > 0.0u"m"
        @test steel_vol > 0.0u"m"
        
        # Steel should be 1-5% of concrete by volume (typical for RC)
        ratio = ustrip(steel_vol) / ustrip(conc_vol)
        @test 0.005 < ratio < 0.10  # 0.5% to 10%
    end
    
    @testset "slab.volumes includes both materials after update" begin
        @test length(slab.volumes) == 2
        
        has_concrete = any(mat isa StructuralSizer.Concrete for mat in keys(slab.volumes))
        has_steel = any(mat isa StructuralSizer.RebarSteel for mat in keys(slab.volumes))
        
        @test has_concrete
        @test has_steel
    end
    
    @testset "EC calculation includes rebar contribution" begin
        # Calculate EC for each material
        ec_by_mat = Dict{String, Float64}()
        for (mat, vol) in slab.volumes
            mass_kg = ustrip(u"kg", vol * mat.ρ)
            ec_val = mass_kg * mat.ecc
            mat_name = mat isa StructuralSizer.Concrete ? "concrete" : "steel"
            ec_by_mat[mat_name] = ec_val
        end
        
        @test haskey(ec_by_mat, "concrete")
        @test haskey(ec_by_mat, "steel")
        @test ec_by_mat["concrete"] > 0
        @test ec_by_mat["steel"] > 0
        
        # Steel typically contributes 40-70% of total slab EC
        total_ec = ec_by_mat["concrete"] + ec_by_mat["steel"]
        steel_fraction = ec_by_mat["steel"] / total_ec
        @test 0.3 < steel_fraction < 0.8
    end
end

println("\n✓ All rebar volume tests passed!")
