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
    # Full vertex loops of every cell touching the hub (12,10): see the
    # tessellation and why mirror edges land on non-mirror cells.
    println("\n-- cells touching hub (12,10): full vertex loops --")
    hub_v = findfirst(v -> hypot(xy(v)[1] - 12.0, xy(v)[2] - 10.0) < 1e-3, 1:length(skel.vertices))
    for (ci, c) in enumerate(struc.cells)
        vs = skel.face_vertex_indices[c.face_idx]
        hub_v in vs || continue
        loop = [(_r(xy(v)[1]), _r(xy(v)[2])) for v in vs]
        println("  cell ", lpad(ci, 2), "  ft=", rpad(string(c.floor_type), 9),
                " axis=(", _r(c.spans.axis[1]), ",", _r(c.spans.axis[2]), ")")
        println("        loop=", loop)
    end

    # Confirm the duplicated-edge hypothesis: list EVERY global edge whose
    # endpoints match the NE / SE diagonal's first segment, and which cell faces
    # reference each. Two distinct edge ids for one geometric segment => dup.
    println("\n-- global edges coincident with each hub-diagonal first segment --")
    function _coincident(p, q)
        near(a, t) = hypot(xy(a)[1] - t[1], xy(a)[2] - t[2]) <= 1e-3
        for e in 1:length(skel.edge_indices)
            a, b = skel.edge_indices[e]
            ((near(a, p) && near(b, q)) || (near(b, p) && near(a, q))) || continue
            faces = [ci for (ci, c) in enumerate(struc.cells)
                     if e in skel.face_edge_indices[c.face_idx]]
            println("    edge ", e, "  (", skel.edge_indices[e], ")  referenced by cells ", faces)
        end
    end
    println("  NE seg (12,10)-(12.927,10.773):"); _coincident((12.0, 10.0), (12.9274, 10.7728))
    println("  SE seg (12,10)-(12.927,9.227):");  _coincident((12.0, 10.0), (12.9274, 9.2272))

    # Mirror cells 5<->2 and 4<->3: are their one-way partitions + support
    # weights reflection-covariant? If weights mirror but tributaries don't =>
    # partition ALGORITHM is handed; if weights differ => support assignment.
    println("\n-- mirror cell partition detail (5<->2 fat-at-hub, 4<->3 thin) --")
    function _cell_detail(ci)
        c = struc.cells[ci]
        vs = skel.face_vertex_indices[c.face_idx]
        fe = skel.face_edge_indices[c.face_idx]
        w = try SSy._partition_weights(c, (c.spans.axis[1], c.spans.axis[2]), skel)
            catch err; "ERR:$(err)" end
        println("  cell ", ci, "  face_edges=", collect(fe))
        println("      support weights=", w isa AbstractVector ? _r.(w) : w)
        tribs = SSy.cell_edge_tributaries(struc, ci)
        if tribs !== nothing
            for t in tribs
                ge = fe[t.local_edge_idx]
                println("      loc=", t.local_edge_idx, " (gedge ", ge, ")  area=",
                        _r(t.area), "  pw=", _r.(t.profile_w))
            end
        end
    end
    for ci in (5, 2, 4, 3); _cell_detail(ci); end

    println("\n  Covariance: NE's adjacent cells (reflected across y=10) must match")
    println("  SE's adjacent cells with left/right (reversed) swapped and s->1-s.")

    # ------------------------------------------------------------------
    # DECISIVE: full stitched per-girder tributary (hub -> corner) for the
    # four hub diagonals. This is the actual flange/load input to the
    # composite check. If NE vs SE (y=10 mirror) and NE vs NW (x=12 mirror)
    # disagree here, the chirality is SEEDED in the tributary partition, not
    # a downstream bistable tie-break.
    # ------------------------------------------------------------------
    hub = (12.0, 10.0)
    corners = Dict("NE" => (18.0, 15.0), "NW" => (6.0, 15.0),
                   "SE" => (18.0, 5.0),  "SW" => (6.0, 5.0))
    onseg(t) = begin  # is point t on the hub->corner segment?
        (c) -> let dx = c[1]-hub[1], dy = c[2]-hub[2],
                   tx = t[1]-hub[1], ty = t[2]-hub[2],
                   L2 = dx*dx+dy*dy
            u = (tx*dx+ty*dy)/L2
            (-0.01 <= u <= 1.01) && abs(tx*dy - ty*dx)/sqrt(L2) <= 1e-2
        end
    end
    function girder_edges(corner)
        pred = onseg(corner)
        es = Int[]
        for e in 1:length(skel.edge_indices)
            a, b = skel.edge_indices[e]
            (pred(xy(a)) && pred(xy(b))) || continue
            push!(es, e)
        end
        # order by distance of edge midpoint from hub
        sort!(es, by = e -> begin a,b = skel.edge_indices[e]
            m = ((xy(a)[1]+xy(b)[1])/2, (xy(a)[2]+xy(b)[2])/2)
            hypot(m[1]-hub[1], m[2]-hub[2]) end)
        return es
    end
    println("\n-- DECISIVE: full per-girder stitched tributary (hub -> corner) --")
    gstore = Dict{String, Vector{Any}}()
    for name in ("NE", "NW", "SE", "SW")
        corner = corners[name]
        es = girder_edges(corner)
        println("  girder ", name, "  hub->", corner, "  edges=", es)
        rows = Any[]
        for e in es
            a, b = skel.edge_indices[e]
            # orient hub-side endpoint first (s=0 at hub)
            hub_first = hypot(xy(a)[1]-hub[1], xy(a)[2]-hub[2]) <
                        hypot(xy(b)[1]-hub[1], xy(b)[2]-hub[2])
            L, R = SSy._edge_perside_canonical(struc, e)
            # canonical s=0 is at edge_indices[e][1]; if that's NOT the hub side,
            # flip so printed profiles read hub->corner (and swap L/R handedness).
            if !hub_first
                flip(p) = p === nothing ? nothing : (reverse(1.0 .- p[1]), reverse(p[2]))
                L, R = flip(R), flip(L)
            end
            ex(p) = p === nothing ? "none" : string(_r.(p[2]))
            println("      edge ", lpad(e,3), "  L=", ex(L), "  R=", ex(R))
            push!(rows, (e, L, R))
        end
        gstore[name] = rows
    end
    # Compare total (L+R extent) at each segment's hub/far end across mirrors.
    function totseq(name)
        seq = Float64[]
        for (_, L, R) in gstore[name]
            lv = L === nothing ? [0.0,0.0] : L[2]
            rv = R === nothing ? [0.0,0.0] : R[2]
            push!(seq, (lv[1]+rv[1]))          # hub-end total extent
            push!(seq, (lv[end]+rv[end]))      # far-end total extent
        end
        return seq
    end
    for (a,b,axis) in (("NE","SE","y=10"), ("NE","NW","x=12"), ("NE","SW","180deg"))
        sa, sb = totseq(a), totseq(b)
        n = min(length(sa), length(sb))
        d = n == 0 ? NaN : maximum(abs.(sa[1:n] .- sb[1:n]))
        println("  TOTAL-extent seq ", a, " vs ", b, " (", axis, "):  ",
                _r.(sa), "  vs  ", _r.(sb), "   maxΔ=", _r(d),
                d < 1e-4 ? "  SYMMETRIC" : "  <<< CHIRAL SEED")
    end

    println("===== END =====\n")
    return nothing
end

main(get(ENV, "DIAG_PLAN", "star/e0c0"))
