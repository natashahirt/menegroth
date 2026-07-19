# Phase 1 verification: role taxonomy, level index, real classifier, helpers.
# Run: SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer \
#        scripts/runners/verify_phase1_roles.jl

using StructuralSynthesizer
using StructuralSizer
using Unitful
using Test

@testset "Phase 1 — roles, level, lateral_role, helpers" begin
    skel = gen_medium_office(20.0u"m", 15.0u"m", 4.0u"m", 2, 2, 2)
    struc = BuildingStructure(skel)
    initialize!(struc; floor_type=:vault, material=NWC_4000,
                floor_opts=VaultOptions(rise=1.0u"m", thickness=0.05u"m"))

    roles = [b.role for b in struc.beams]
    println("Beam count:   ", length(struc.beams))
    println("Unique roles: ", unique(roles))
    println("  :girder = ", count(==(:girder), roles))
    println("  :joist  = ", count(==(:joist),  roles))
    println("  :beam   = ", count(==(:beam),   roles))

    # New fields exist with correct Level-0 defaults on skeleton-input beams.
    @test all(b -> b.level == 0, struc.beams)
    @test all(b -> b.lateral_role == :gravity, struc.beams)

    # Roles are drawn from the new taxonomy only (no :infill).
    @test all(r -> r in (:girder, :joist, :beam), roles)

    # Helper functions agree with the role field.
    for b in struc.beams
        @test is_girder(b) == (b.role === :girder)
        @test is_joist(b)  == (b.role === :joist)
        @test is_beam(b)   == (b.role === :beam)
        @test level_of(b) == 0
        @test lateral_role_of(b) == :gravity
    end

    # Direct unit test of classify_beam_role on synthetic inputs.
    cbr = StructuralSynthesizer.classify_beam_role
    colverts = Set([1, 2, 3])
    slabedges = Set([10, 11])
    @test cbr((1, 2), [5], colverts, slabedges) == :girder      # both ends columns
    @test cbr((1, 9), [10], colverts, slabedges) == :joist      # slab-support edge, not girder
    @test cbr((1, 9), [7],  colverts, slabedges) == :beam       # neither
    @test cbr((2, 3), [10], colverts, slabedges) == :girder     # girder wins over slab-support
end

println("\n\u2713 Phase 1 verification complete.")
