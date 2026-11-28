# Framing levels are sized one pass per level, from the slab outward, then
# the primary girders. A level with no beam_options uses the building-wide
# options. No framing is one pass.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

const SS = StructuralSynthesizer

function _pass_slab()
    struc = BuildingStructure(BuildingSkeleton{Float64}())
    spans = SpanInfo{Float64}(6.0, 8.0, (1.0, 0.0), 7.0)
    slab = Slab{Float64}([1], CIPSlabResult(0.2, 0.2, 5.0), :one_way, spans,
                         :interior, nothing, MaterialVolumes(), nothing, nothing,
                         FramingLevel{Float64}[])
    push!(struc.slabs, slab)
    return struc, slab
end

function _level(; level, gid, slab_idx = 1, options = nothing)
    FramingLevel{Float64}(
        slab_idx = slab_idx,
        level = level,
        pattern = LinearAxisPattern{Float64}((1.0, 0.0), 1.0, nothing),
        material = A992_Steel,
        group_id = gid,
        beam_options = options,
    )
end

@testset "beam sizing passes" begin
    default = SteelBeamOptions()
    struc, slab = _pass_slab()

    alone = SS._beam_sizing_passes(struc, default)
    @test length(alone) == 1
    @test alone[1].accept === nothing
    @test alone[1].own == false
    @test alone[1].opts === default

    joist = SteelBeamOptions(composite = false)
    # Inserted out of level order. The pass list sorts them.
    push!(slab.framing_levels, _level(level = 2, gid = UInt64(3), options = joist))
    push!(slab.framing_levels, _level(level = 1, gid = UInt64(1)))
    push!(slab.framing_levels, _level(level = 1, gid = UInt64(2), slab_idx = 2))
    push!(slab.framing_levels, _level(level = 3, gid = nothing))

    passes = SS._beam_sizing_passes(struc, default)
    @test length(passes) == 3

    @test passes[1].own == false
    @test passes[1].opts === default
    @test passes[1].accept(UInt64(1))
    @test passes[1].accept(UInt64(2))
    @test !passes[1].accept(UInt64(3))

    @test passes[2].own == true
    @test passes[2].opts === joist
    @test passes[2].accept(UInt64(3))
    @test !passes[2].accept(UInt64(1))

    # Groups no level owns, including an override aimed at a missing group.
    @test passes[3].own == false
    @test passes[3].opts === default
    @test !passes[3].accept(UInt64(1))
    @test passes[3].accept(UInt64(99))

    ovr = Dict{UInt64, MemberGroupSizingOverride}(
        UInt64(1) => MemberGroupSizingOverride(catalog = :joists),
        UInt64(99) => MemberGroupSizingOverride(catalog = :missing),
    )
    first = SS._overrides_in(ovr, passes[1].accept)
    @test haskey(first, UInt64(1))
    @test !haskey(first, UInt64(99))
    last = SS._overrides_in(ovr, passes[3].accept)
    @test haskey(last, UInt64(99))
    @test !haskey(last, UInt64(1))
    @test SS._overrides_in(nothing, passes[1].accept) === nothing

    beam = Beam(Int[], 1.0; role = :joist, level = 1)
    set_volumes!(beam, MaterialVolumes(A992_Steel => 0.0u"m^3"))
    @test SS._recorded_structural_steel(beam) === A992_Steel
end
