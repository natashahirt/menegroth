# Run slab-related tests
using Test

@testset "Slab Tests" begin
        include("slabs/test_flat_plate.jl")
    include("slabs/test_efm_stiffness.jl")
    include("slabs/test_efm_pipeline.jl")
    include("slabs/test_shear_transfer.jl")
    include("slabs/test_ddm_edge_mub.jl")
    include("slabs/test_corner_punching.jl")
    include("slabs/test_fea_combo_envelope.jl")
end
