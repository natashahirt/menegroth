#=
Is the star/e0c0 skeleton/tessellation reflection-symmetric about y=10?

The e0c0 plan is meant to be non-chiral, yet the sized design is only
180deg-rotation symmetric (mirror reflection breaks) and the per-beam tributary
extent profiles of mirror girders differ. This probe tests the UPSTREAM mesh:
reflect every vertex across y=10, then check that edges and faces map onto
existing edges/faces. Anything without a mirror partner localizes where the
tessellation itself breaks reflection symmetry (the suspected chirality seed).

No design is run — just skeleton construction, so this is fast.

    SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
        julia --project=StructuralStudies scripts/runners/sdf_e0c0_mesh_symmetry.jl
=#

include(joinpath(@__DIR__, "sdf_rib_design.jl"))

const SSy = StructuralSynthesizer

_r2(x) = round(x; digits = 2)

function main(plan = "star/e0c0")
    struc = BuildingStructure(plan_skeleton(load_plan(plan)))
    skel = struc.skeleton
    nv = length(skel.vertices)
    println("\n===== e0c0 MESH REFLECTION SYMMETRY (axis y=10) =====")
    println("vertices=", nv,
            "  edges=", length(skel.edge_indices),
            "  faces=", length(skel.face_vertex_indices),
            "  cells=", length(struc.cells))

    xy(v) = SSy._vertex_xy_m(skel, v)
    ys = [xy(v)[2] for v in 1:nv]
    ymin, ymax = minimum(ys), maximum(ys)
    axis = (ymin + ymax) / 2
    println("y-range=[", _r2(ymin), ",", _r2(ymax), "]  reflection axis y=", _r2(axis))
    refl(p) = (p[1], 2axis - p[2])

    # Vertex -> its reflected vertex (nearest within tol).
    tol = 1e-4
    vmap = fill(0, nv)
    for v in 1:nv
        r = refl(xy(v))
        for w in 1:nv
            if hypot(xy(w)[1] - r[1], xy(w)[2] - r[2]) <= tol
                vmap[v] = w; break
            end
        end
    end
    unmapped_v = findall(==(0), vmap)
    println("\nvertices with NO reflected partner: ", length(unmapped_v),
            isempty(unmapped_v) ? "  (vertex set is mirror-symmetric)" : "")
    for v in unmapped_v[1:min(end, 10)]
        println("   v$v @ (", _r2(xy(v)[1]), ",", _r2(xy(v)[2]), ")")
    end

    # Edges: the reflected endpoint pair must be an existing edge.
    edgeset = Dict{Tuple{Int,Int}, Int}()
    for (e, (a, b)) in enumerate(skel.edge_indices)
        edgeset[minmax(a, b)] = e
    end
    bad_edges = Int[]
    for (e, (a, b)) in enumerate(skel.edge_indices)
        (vmap[a] == 0 || vmap[b] == 0) && (push!(bad_edges, e); continue)
        haskey(edgeset, minmax(vmap[a], vmap[b])) || push!(bad_edges, e)
    end
    println("\nedges with NO reflected partner: ", length(bad_edges))
    for e in bad_edges[1:min(end, 10)]
        a, b = skel.edge_indices[e]
        println("   e$e (", _r2(xy(a)[1]), ",", _r2(xy(a)[2]), ")->(",
                _r2(xy(b)[1]), ",", _r2(xy(b)[2]), ")")
    end

    # Faces: reflected vertex SET must be an existing face. Also report winding.
    faceset = Dict{Set{Int}, Int}()
    for (f, vs) in enumerate(skel.face_vertex_indices)
        faceset[Set(vs)] = f
    end
    signed_area(vs) = begin
        s = 0.0
        n = length(vs)
        for i in 1:n
            p = xy(vs[i]); q = xy(vs[mod1(i + 1, n)])
            s += p[1] * q[2] - q[1] * p[2]
        end
        s / 2
    end
    bad_faces = Int[]
    cw = 0; ccw = 0
    for (f, vs) in enumerate(skel.face_vertex_indices)
        signed_area(vs) >= 0 ? (ccw += 1) : (cw += 1)
        any(v -> vmap[v] == 0, vs) && (push!(bad_faces, f); continue)
        haskey(faceset, Set(vmap[v] for v in vs)) || push!(bad_faces, f)
    end
    println("\nfaces: ccw=", ccw, "  cw=", cw,
            "   (mixed winding is normal; consistent winding is the chirality carrier)")
    println("faces with NO reflected partner: ", length(bad_faces))
    for f in bad_faces[1:min(end, 10)]
        vs = skel.face_vertex_indices[f]
        println("   f$f verts=", [(_r2(xy(v)[1]), _r2(xy(v)[2])) for v in vs])
    end

    println("\nVERDICT: ",
            isempty(unmapped_v) && isempty(bad_edges) && isempty(bad_faces) ?
            "skeleton is reflection-symmetric => chirality is DOWNSTREAM (tributary/winding/solve), not the mesh." :
            "skeleton is NOT reflection-symmetric => the mesh/tessellation is the chirality seed.")
    println("===== END =====\n")
    return nothing
end

main(get(ENV, "DIAG_PLAN", "star/e0c0"))
