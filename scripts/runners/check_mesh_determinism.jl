# Build the same refined shell twice, after changing Julia's global RNG, and
# require the same triangle vertices. The mesher passes its own seeded
# generator into DelaunayTriangulation, so the mesh does not depend on
# Random.default_rng() or on an earlier mesh in the process.
#
#   julia --project=external/Asap scripts/runners/check_mesh_determinism.jl

ENV["SS_ENABLE_VISUALIZATION"] = "false"

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "external", "Asap"))

using Asap
using Random
using Unitful

function triangle_key(shells)
    rows = map(shells) do s
        pts = [ntuple(k -> round(Float64(ustrip(u"m", node.position[k])); digits=9), 3) for node in s.nodes]
        return sort!(pts)
    end
    return sort!(rows)
end

function build_shell()
    corners = (
        Node([0.0u"m", 0.0u"m", 0.0u"m"], :fixed),
        Node([8.0u"m", 0.0u"m", 0.0u"m"], :fixed),
        Node([8.0u"m", 6.0u"m", 0.0u"m"], :fixed),
        Node([0.0u"m", 6.0u"m", 0.0u"m"], :fixed),
    )
    interior = [Node([3.0u"m", 2.0u"m", 0.0u"m"], :free)]
    section = ShellSection(0.15u"m", 30u"GPa", 0.2; ρ=2400u"kg/m^3")
    return Shell(corners, 4, section;
                 interior_nodes=interior,
                 target_edge_length=1.2u"m",
                 refinement_edge_length=0.35u"m")
end

pts = [(0.0, 0.0), (3.0, 1.0), (3.0, 1.0), (8.0, 6.0)]
grid = Asap._PointGrid(pts)
for (x, y) in ((1.2, 0.4), (100.0, -50.0), (3.0, 1.0), (0.0, 0.0))
    got = Asap._min_dist(grid, x, y)
    truth = minimum(hypot(x - p[1], y - p[2]) for p in pts)
    if abs(got - truth) > 1e-9
        println("nearest-point mismatch at ($x, $y): $got vs $truth")
        exit(1)
    end
end
println("nearest-point grid matches the linear scan")

Random.seed!(1)
first = build_shell()
Random.seed!(99)
second = build_shell()

k1 = triangle_key(first)
k2 = triangle_key(second)
if k1 != k2
    println("MESH DIVERGED: $(length(first)) triangles vs $(length(second))")
    exit(1)
end
println("mesh repeat ok: $(length(first)) triangles, rng calls $(Asap._MESH_RNG_CALLS[])")
