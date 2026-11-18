# A one-way slab must have beams or walls to span between. On columns alone
# `initialize!` refuses the input instead of designing a slab with no supports.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

@testset "one-way slab support validation" begin
    @testset "column-only one-way slab throws" begin
        skel = gen_medium_office(24.0u"ft", 24.0u"ft", 10.0u"ft", 2, 2, 1)
        skel.groups_edges[:slab_edges] = pop!(skel.groups_edges, :beams)
        struc = BuildingStructure(skel)
        err = try
            initialize!(struc; floor_type = :one_way, floor_opts = OneWayOptions())
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin(":one_way", sprint(showerror, err))
    end

    @testset "beam-supported one-way slab initializes" begin
        skel = gen_medium_office(24.0u"ft", 24.0u"ft", 10.0u"ft", 2, 2, 1)
        struc = BuildingStructure(skel)
        @test initialize!(struc; floor_type = :one_way, floor_opts = OneWayOptions()) === struc
        @test !isempty(struc.slabs)
    end

    @testset "flat plate on columns alone is unaffected" begin
        skel = gen_medium_office(24.0u"ft", 24.0u"ft", 10.0u"ft", 2, 2, 1)
        skel.groups_edges[:slab_edges] = pop!(skel.groups_edges, :beams)
        struc = BuildingStructure(skel)
        @test initialize!(struc; floor_type = :flat_plate) === struc
    end
end
