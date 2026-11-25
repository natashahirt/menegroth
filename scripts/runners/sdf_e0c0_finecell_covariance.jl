#=
Is the FINE rib-mesh tributary partition reflection-covariant?

pass-0 [D] showed the per-edge canonical tributary of the first NE chain edge
(hub->(12.927,10.773)) and its y=10 mirror SE edge (hub->(12.927,9.227)) differ
AT THE INVARIANT HUB (canL=[1.921->0] vs [0->1.921]). That is a single-edge
divergence, so it is the FINE-CELL partition or the canonical left/right label,
NOT the multi-edge stitch. This isolates which.

Runs ONLY prepare! + pipeline stage 1 (slab sizing / rib mesh + tributaries),
skipping the ~28-min member loop. Then for the two mirror hub edges it dumps
EVERY adjacent cell's RAW edge tributary (local_edge_idx, profile_s, profile_w,
reversed flag) so mirror cells can be compared directly.

    SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
        julia --project=StructuralStudies scripts/runners/sdf_e0c0_finecell_covariance.jl
=#

include(joinpath(@__DIR__, "sdf_rib_design.jl"))

const SSy = StructuralSynthesizer
_r(x) = round(x; digits = 4)

"""Find the skeleton edge with endpoints near `p` and `q` (meters)."""
function _find_edge(skel, xy, p, q)
    near(a, t) = hypot(xy(a)[1] - t[1], xy(a)[2] - t[2]) <= 1e-3
    return findfirst(1:length(skel.edge_indices)) do e
        a, b = skel.edge_indices[e]
        (near(a, p) && near(b, q)) || (near(b, p) && near(a, q))
    end
end

"""Dump every adjacent cell's raw tributary for global edge `e`."""
function _dump_edge(struc, skel, xy, label, e)
    e === nothing && (println("  ", label, ": edge NOT FOUND"); return)
    av1, av2 = skel.edge_indices[e]
    println("  ", label, "  edge=", e,
            "  (av1,av2)=((", _r(xy(av1)[1]), ",", _r(xy(av1)[2]), ")->(",
            _r(xy(av2)[1]), ",", _r(xy(av2)[2]), "))")
    for (cell_idx, cell) in enumerate(struc.cells)
        face_edges = skel.face_edge_indices[cell.face_idx]
        local_idx = findfirst(==(e), face_edges)
        local_idx === nothing && continue
        tribs = SSy.cell_edge_tributaries(struc, cell_idx)
        tribs === nothing && continue
        idx = findfirst(t -> t.local_edge_idx == local_idx, tribs)
        idx === nothing && continue
        trib = tribs[idx]
        fverts = skel.face_vertex_indices[cell.face_idx]
        n = length(fverts)
        ev1 = fverts[local_idx]; ev2 = fverts[mod1(local_idx + 1, n)]
        reversed = (av1 == ev2 && av2 == ev1)
        cen = (sum(xy(v)[1] for v in fverts) / n, sum(xy(v)[2] for v in fverts) / n)
        println("      cell ", cell_idx, "  ft=", cell.floor_type,
                "  centroid=(", _r(cen[1]), ",", _r(cen[2]), ")  reversed=", reversed)
        println("          raw profile_s=", _r.(trib.profile_s))
        println("          raw profile_w=", _r.(trib.profile_w))
        println("          d (unsigned extent)=", _r.(trib.d), "  s=", _r.(trib.s))
    end
end

function main(plan = "star/e0c0")
    p = rib_parameters(plan, :waffle)
    p.skip_visualization = true
    struc = BuildingStructure(plan_skeleton(load_plan(plan)))

    t0 = time()
    SSy.prepare!(struc, p)
    stages = SSy.build_pipeline(p)
    stages[1].fn(struc)                                   # slab sizing (rib mesh)
    stages[1].needs_sync && SSy.sync_asap!(struc; params = p)
    println("prepare! + stage 1 done in ", round(time() - t0; digits = 1), " s; ",
            length(struc.cells), " cells")

    skel = struc.skeleton
    xy(v) = SSy._vertex_xy_m(skel, v)
    hub = (12.0, 10.0)
    e_ne = _find_edge(skel, xy, hub, (12.927, 10.773))
    e_se = _find_edge(skel, xy, hub, (12.927, 9.227))

    println("\n===== e0c0 FINE-CELL TRIBUTARY (hub edges, mirror across y=10) =====")
    _dump_edge(struc, skel, xy, "NE chain-edge 1", e_ne)
    _dump_edge(struc, skel, xy, "SE chain-edge 1 (mirror)", e_se)

    # All cells: centroid + one-way span axis. Mirror pairs across y=10 must have
    # axes (ax, ay) <-> (ax, -ay) for the partition to be reflection-covariant.
    println("\n-- all cells: idx | centroid | floor_type | spans.axis --")
    cen_of(c) = (vs = skel.face_vertex_indices[c.face_idx]; n = length(vs);
                 (sum(xy(v)[1] for v in vs) / n, sum(xy(v)[2] for v in vs) / n))
    cents = Dict{Int, NTuple{2, Float64}}()
    axes = Dict{Int, NTuple{2, Float64}}()
    for (ci, c) in enumerate(struc.cells)
        cen = cen_of(c); ax = c.spans.axis
        cents[ci] = cen; axes[ci] = (ax[1], ax[2])
        println("  cell ", lpad(ci, 2), "  (", _r(cen[1]), ",", _r(cen[2]), ")  ",
                rpad(string(c.floor_type), 9), "  axis=(", _r(ax[1]), ",", _r(ax[2]), ")")
    end
    # Pair each cell with its y=10 mirror (match centroid) and check axis covariance.
    println("\n-- mirror-pair axis covariance (axis must map (ax,ay)->(ax,-ay)) --")
    done = Set{Int}()
    for ci in sort(collect(keys(cents)))
        ci in done && continue
        cx, cy = cents[ci]
        mj = findfirst(cj -> cj != ci &&
            hypot(cents[cj][1] - cx, cents[cj][2] - (20.0 - cy)) < 0.05, collect(keys(cents)))
        mj === nothing && (println("  cell ", ci, "  NO mirror cell found"); continue)
        cj = collect(keys(cents))[mj]
        push!(done, ci); push!(done, cj)
        a1 = axes[ci]; a2 = axes[cj]
        d = min(hypot(a1[1] - a2[1], a1[2] + a2[2]), hypot(a1[1] + a2[1], a1[2] - a2[2]))
        println("  cells ", lpad(ci, 2), "<->", lpad(cj, 2),
                "  axis ", a1, " vs ", a2, "  |Δrefl|=", _r(d),
                d < 1e-3 ? "  OK" : "  <<< AXIS NOT REFLECTION-COVARIANT")
    end
    println("\n  Covariance: NE's adjacent cells (reflected across y=10) must match")
    println("  SE's adjacent cells with left/right (reversed) swapped and s->1-s.")
    println("===== END =====\n")
    return nothing
end

main(get(ENV, "DIAG_PLAN", "star/e0c0"))
