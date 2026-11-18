# Commit reuses a slab proposal only when the envelope left that slab's
# columns at the dimensions the proposal already designed.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

const SY = StructuralSynthesizer
const SZ = StructuralSizer

@testset "A proposal matches the columns it already sized" begin
    same = SZ.FloorSupportUpdate(1, 0.30u"m", 0.40u"m", :rectangular, "sec", nothing)
    @test SY._support_update_installed(0.30u"m", 0.40u"m", :rectangular, "sec", same)
    @test !SY._support_update_installed(0.50u"m", 0.40u"m", :rectangular, "sec", same)
    @test !SY._support_update_installed(0.30u"m", 0.40u"m", :square, "sec", same)

    # No section on the update leaves the installed section alone.
    bare = SZ.FloorSupportUpdate(1, 0.30u"m", 0.40u"m", :rectangular, nothing, nothing)
    @test SY._support_update_installed(0.30u"m", 0.40u"m", :rectangular, "kept", bare)

    @test !SY._supports_still_match(BuildingStructure(BuildingSkeleton{Float64}()), nothing)
end

@testset "Analysis updates name the change" begin
    struc = BuildingStructure(BuildingSkeleton{Float64}())
    @test_throws ArgumentError SY.update_analysis!(struc, :mesh)
    tc = SZ.TraceCollector()
    @test_throws ArgumentError SY.update_analysis!(struc, :mesh; tc)
    @test isempty(tc.events)
end
