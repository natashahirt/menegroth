# Main test runner for StructuralSizer
# Run with: julia --project=. test/runtests.jl

using Test
using Unitful
using StructuralSizer
using StructuralBase: StructuralUnits  # For u"ksi", u"kip" etc. in tests

@testset "StructuralSizer Tests" begin
    include("cip/test_cip.jl")
    include("haile_vault/test_vault.jl")
    include("structs/test_member_hierarchy.jl")
    include("steel_member/test_aisc_beam_examples.jl")
    include("steel_member/test_handcalc_beam.jl")
    include("steel_member/test_aisc_column_examples.jl")
    include("tributary/test_spans.jl")
    include("tributary/test_tributary_workflow.jl")
    include("tributary/test_voronoi_tributaries.jl")
    include("foundations/test_spread_footing.jl")
end
