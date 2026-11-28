# Read the stiffness saved by diag_not_spd.jl and find the huge entries.
#
#   julia --project=StructuralSynthesizer scripts/runners/diag_not_spd_offline.jl
#
# Lists the free DOFs whose diagonal is far above the rest, the node each
# belongs to, and the other nodes it is coupled to with a comparable entry,
# with the plan distance between them.

using LinearAlgebra
using Serialization
using SparseArrays
using Printf

const DOF_NAME = ("ux", "uy", "uz", "rx", "ry", "rz")

data = deserialize(joinpath(@__DIR__, "..", "..", "logs", "not_spd_model.jls"))
K, free, nodes = data.K, data.free, data.nodes
owner = Dict{Int, Tuple{Int, Int}}()
for (ni, n) in enumerate(nodes), (k, g) in enumerate(n.gid)
    owner[g] = (ni, k)
end

d = diag(K)
med = sort(abs.(d))[length(d) ÷ 2]
println("free DOFs=$(length(d))  median diag=$(@sprintf("%.3g", med))  max diag=$(@sprintf("%.3g", maximum(d)))")
for e in (12, 15, 20, 25, 30, 40)
    @printf("  diag > 1e%d: %d\n", e, count(>(10.0^e), d))
end

big = findall(>(1e30), d)
println("\nDOFs with diag > 1e30, by node:")
seen = Set{Int}()
rows = rowvals(K)
vals = nonzeros(K)
for j in big
    ni, k = owner[free[j]]
    ni in seen && continue
    push!(seen, ni)
    n = nodes[ni]
    partners = Dict{Int, Float64}()
    for r in nzrange(K, j)
        i = rows[r]
        abs(vals[r]) > 1e-3 * d[j] || continue
        nj, _ = owner[free[i]]
        nj == ni && continue
        partners[nj] = max(get(partners, nj, 0.0), abs(vals[r]))
    end
    println("node $(n.id) $(n.tag) $(n.xyz)  $(DOF_NAME[k]) diag=$(@sprintf("%.3g", d[j]))")
    for (nj, v) in partners
        m = nodes[nj]
        dist = norm(m.xyz .- n.xyz)
        println("    coupled to node $(m.id) $(m.tag) $(m.xyz)  |K|=$(@sprintf("%.3g", v))  distance=$(@sprintf("%.3g", dist)) m")
    end
    println("    elements: ", join(n.elements, "; "))
    length(seen) >= 15 && break
end
println("\nnodes with huge DOFs: $(length(Set(owner[free[j]][1] for j in big)))")
