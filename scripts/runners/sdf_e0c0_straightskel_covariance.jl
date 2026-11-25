#=
Is the TWO-WAY STRAIGHT-SKELETON tributary partition (axis = nothing)
reflection-covariant?

`sdf_e0c0_trib_covariance.jl` proved the ONE-WAY partition covariant, but it only
ever passed non-nothing axes. The e0c0 hub cells are waffle/two-way, so their
tributary uses `get_tributary_polygons(V)` with NO axis — the straight skeleton.
`sdf_e0c0_pass0_handedness.jl` [D] showed the hub-girder tributary lands on
NON-mirror edges of the two mirror chains, which points here. This tests the one
path never tested: reflect a hub cell across y=10 and compare the straight-
skeleton per-edge profiles. Covariant iff every edge's (profile_s, profile_w)
matches its mirror; any mismatch localizes the chirality to the straight skeleton.

Pure geometry, NO design run.

    SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
        julia --project=StructuralStudies scripts/runners/sdf_e0c0_straightskel_covariance.jl
=#

include(joinpath(@__DIR__, "sdf_rib_design.jl"))

const SSy = StructuralSynthesizer
import Meshes

_r(x) = round(x; digits = 4)
ustrip_area(t) = t.area isa Unitful.Quantity ? ustrip(u"m^2", t.area) : Float64(t.area)

"""Straight-skeleton (axis = nothing) per-edge geometry invariants of loop `V`:
one `(area, mean_width, max_width)` tuple per edge. Reflection is an isometry,
so a covariant partition yields the SAME MULTISET of these tuples for a cell and
its mirror — this sidesteps edge-ordering/orientation bookkeeping entirely."""
function _edge_invariants(V)
    tribs = Asap.get_tributary_polygons(V)          # no axis => straight skeleton
    out = NTuple{3, Float64}[]
    for t in tribs
        w = t.profile_w
        mw = isempty(w) ? 0.0 : sum(w) / length(w)
        xw = isempty(w) ? 0.0 : maximum(w)
        push!(out, (_r(ustrip_area(t)), _r(mw), _r(xw)))
    end
    return sort(out)                                # multiset => sort for compare
end

"""Worst element-wise gap between two sorted per-edge invariant multisets."""
function _cmp(label, pa, pb)
    if length(pa) != length(pb)
        println("  [", label, "] EDGE-COUNT MISMATCH: ", length(pa), " vs ", length(pb))
        return Inf
    end
    worst = 0.0
    for i in eachindex(pa)
        worst = max(worst, maximum(abs.(pa[i] .- pb[i])))
    end
    println("  [", label, "] worst |Δ(area,mean_w,max_w)| over sorted edges = ", _r(worst))
    println("        original: ", pa)
    println("        mirror  : ", pb)
    return worst
end

function main(plan = "star/e0c0")
    struc = BuildingStructure(plan_skeleton(load_plan(plan)))
    skel = struc.skeleton
    nv = length(skel.vertices)
    xy(v) = SSy._vertex_xy_m(skel, v)
    axisy = (minimum(xy(v)[2] for v in 1:nv) + maximum(xy(v)[2] for v in 1:nv)) / 2
    println("\n===== e0c0 STRAIGHT-SKELETON (axis=nothing) REFLECTION COVARIANCE (y=", _r(axisy), ") =====")

    pt_of(v; refl = false) = begin
        x, y = xy(v); z = SSy._vertex_z_m(skel, v)
        Meshes.Point(x * u"m", (refl ? 2axisy - y : y) * u"m", z * u"m")
    end

    # The hub girder edge ->(18,15) and its adjacent faces (same as trib_covariance).
    hub = (12.0, 10.0)
    near(v, p) = hypot(xy(v)[1] - p[1], xy(v)[2] - p[2]) <= 1e-4
    find_edge(p2) = findfirst(e -> begin
        a, b = skel.edge_indices[e]
        (near(a, hub) && near(b, p2)) || (near(b, hub) && near(a, p2))
    end, 1:length(skel.edge_indices))
    e_ne = find_edge((18.0, 15.0))
    e_ne === nothing && (println("  (edge not found; aborting)"); return)
    faces = [f for f in 1:length(skel.face_edge_indices) if e_ne in skel.face_edge_indices[f]]
    println("hub->(18,15) girder edge=", e_ne, "  adjacent faces=", faces)

    overall = 0.0
    for f in faces
        idxs = skel.face_vertex_indices[f]
        coords = [(_r(xy(i)[1]), _r(xy(i)[2])) for i in idxs]
        println("\nface ", f, " verts=", coords)
        V  = [pt_of(i) for i in idxs]
        # Reflected cell: reflect each vertex, then reverse the loop so it stays
        # CCW (reflection flips orientation). Multiset compare is order-free.
        Vr = reverse([pt_of(i; refl = true) for i in idxs])
        w = _cmp("face $f", _edge_invariants(V), _edge_invariants(Vr))
        overall = max(overall, w)
    end

    println("\nVERDICT: ",
            overall <= 1e-6 ?
            "straight skeleton IS reflection-covariant => chirality is ELSEWHERE." :
            overall == Inf ?
            "straight skeleton NOT covariant (edge-count/length mismatch) => it is the chirality carrier." :
            "straight skeleton NOT reflection-covariant (max Δ=$(_r(overall))) => it is the chirality carrier.")
    println("===== END =====\n")
    return nothing
end

main(get(ENV, "DIAG_PLAN", "star/e0c0"))
