#=
Category D office with a symmetric wall pair in each direction.

The sensitivity building puts one 9 m pier on each face, on opposite
corners. Those four piers already balance about the center. A two-bay
side has no grid edge at its midpoint, so the centered pair is both bays
on both opposite faces: each direction gets two full sides.

    SDC_CASE="D / A1" SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
        julia --project=StructuralSynthesizer scripts/runners/sdc_symmetric_piers.jl
=#

include(joinpath(@__DIR__, "sdc_design_sensitivity.jl"))

"Both bays on every face. Eight piers per story."
function _piers(bay)
    b = ustrip(u"m", bay)
    return ((0.0, 0.0, b, 0.0),
            (b, 0.0, 2b, 0.0),
            (0.0, 2b, b, 2b),
            (b, 2b, 2b, 2b),
            (0.0, 0.0, 0.0, b),
            (0.0, b, 0.0, 2b),
            (2b, 0.0, 2b, b),
            (2b, b, 2b, 2b))
end

struc, _ = office(; n=5)
nedges = length(get(struc.skeleton.groups_edges, :walls, Int[]))
nedges == 40 || error("symmetric office expected 40 wall edges, got $nedges")
println("symmetric wall edges: $nedges")
main()
