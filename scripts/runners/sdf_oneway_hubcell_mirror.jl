#=
Does the one-way partition mirror a hub cell onto itself?

Cell 5 of star/e0c0 and its y=10 mirror (cell 2) are the same polygon.
This partitions the cell and its mirror with the span axis (0, +1) and
compares the load on each edge. A covariant partition gives the mirror
image the same load on the mirrored edge.

    julia --project=external/Asap scripts/runners/sdf_oneway_hubcell_mirror.jl
=#

using Asap
using Meshes: Point
using Unitful: @u_str

cell = [
    (12.0, 10.0), (12.9274, 10.7728), (13.9637, 11.6364), (15.0, 12.5),
    (16.0363, 13.3636), (17.0726, 14.2272), (18.0, 15.0), (12.0, 15.0),
    (12.0, 14.2272), (12.0, 13.3636), (12.0, 12.5), (12.0, 11.6364), (12.0, 10.7728),
]
mirror(p) = (p[1], 20.0 - p[2])
pts(xy) = [Point(x * u"m", y * u"m") for (x, y) in xy]

function by_edge(xy, axis)
    n = length(xy)
    tribs = get_tributary_polygons(pts(xy); axis = axis)
    return Dict((xy[t.local_edge_idx], xy[mod1(t.local_edge_idx + 1, n)]) =>
                (area = t.area, w = t.profile_w) for t in tribs)
end

a = by_edge(cell, [0.0, 1.0])
b = by_edge(mirror.(cell), [0.0, 1.0])
bad = String[]
for ((p, q), prof) in a
    got = get(b, (mirror(p), mirror(q)), nothing)
    got === nothing && (push!(bad, "missing edge $((p, q))"); continue)
    ok = isapprox(got.area, prof.area; atol = 1e-6) &&
         length(got.w) == length(prof.w) &&
         all(isapprox.(got.w, prof.w; atol = 1e-6))
    ok && continue
    push!(bad, string((p, q), " area ", round(prof.area; digits = 3),
                      " vs ", round(got.area; digits = 3),
                      "  w ", round.(prof.w; digits = 3), " vs ", round.(got.w; digits = 3)))
end
println.(bad)
println(isempty(bad) ? "COVARIANT on the hub cell" : "NOT covariant ($(length(bad)) edges)")
