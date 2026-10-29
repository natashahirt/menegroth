# Adversarial check of wall_node! base fixity. Not part of the suite.
# SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer scripts/runners/check_wall_base_fixity.jl

using StructuralSynthesizer
using StructuralSizer
using Asap
using Unitful
using Meshes
using LinearAlgebra

const FIXED = [false, false, false, false, false, false]
const FRAME_DOF = [true, true, true, false, false, false]  # true = free

function _skel_with_stories(elevs::Pair{Int, typeof(1.0u"m")}...)
    T = typeof(1.0u"m")
    skel = BuildingSkeleton{T}()
    for (k, z) in elevs
        skel.stories[k] = Story{T}(z, Int[], Int[], Int[])
    end
    return skel
end

function _frame_node(x, y, z; dof=copy(FRAME_DOF))
    Asap.Node([x, y, z] .* u"m", copy(dof))
end

function _wall(x1, y1, x2, y2, z_story::Int, height)
    Wall([1], height; thickness=0.2u"m",
         x1=x1, y1=y1, x2=x2, y2=y2,
         story=z_story, concrete=NWC_4000)
end

function _mesh(walls, frame_nodes; shells=Asap.ShellElement[])
    skel = _skel_with_stories(0 => 0.0u"m", 1 => 4.0u"m", 2 => 8.0u"m")
    struc = BuildingStructure(skel)
    append!(struc.walls, walls)
    params = DesignParameters(materials=MaterialOptions(concrete=NWC_4000))
    return StructuralSynthesizer._mesh_wall_shells(struc, params, frame_nodes, shells)
end

function _dof_of(shells, x, y, z; atol=1e-9)
    hits = Asap.Node[]
    for sh in shells
        for nd in sh.nodes
            p = nd.position
            dx = ustrip(u"m", p[1]) - x
            dy = ustrip(u"m", p[2]) - y
            dz = ustrip(u"m", p[3]) - z
            if hypot(dx, dy, dz) <= atol && !(any(h === nd for h in hits))
                push!(hits, nd)
            end
        end
    end
    return hits
end

function _report(label, ok, detail)
    println(ok ? "PASS" : "FAIL", "  ", label, "  ", detail)
    return ok
end

println("=== fixDict check (true means free) ===")
println("  :fixed => ", Asap.fixDict[:fixed])
println("  :free  => ", Asap.fixDict[:free])

# ---------------------------------------------------------------------------
# P0-1. Reused frame node at the lowest wall base keeps its dof vector.
# Story elevation 4 m, one wall based there, frame node (0, 0, 4).
# ---------------------------------------------------------------------------
println("\n=== P0-1 reused frame node at lowest base ===")
frame = _frame_node(0.0, 0.0, 4.0)
dof_before = copy(frame.dof)
vec_before = frame.dof
shells, _ = _mesh([_wall(0.0, 0.0, 6.0, 0.0, 1, 3.0u"m")], Asap.Node[frame])
p0_1 = _report(
    "reused (0,0,4) dof unchanged and not all-false",
    frame.dof == FRAME_DOF && frame.dof === vec_before && frame.dof == dof_before && frame.dof != FIXED,
    "dof=$(frame.dof) same_vector=$(frame.dof === vec_before)",
)

# New nodes on that same base, farther than 1 mm from the frame node.
mid = _dof_of(shells, 3.0, 0.0, 4.0)
far = _dof_of(shells, 6.0, 0.0, 4.0)
p0_2a = _report(
    "new midpoint (3,0,4) is fixed",
    length(mid) == 1 && mid[1].dof == FIXED && mid[1] !== frame,
    "n=$(length(mid)) dof=$(isempty(mid) ? "missing" : mid[1].dof)",
)
p0_2b = _report(
    "new end (6,0,4) is fixed",
    length(far) == 1 && far[1].dof == FIXED && far[1] !== frame,
    "n=$(length(far)) dof=$(isempty(far) ? "missing" : far[1].dof)",
)

# ---------------------------------------------------------------------------
# P0-2. No frame node within 1 mm of any base node. All three base nodes fixed.
# ---------------------------------------------------------------------------
println("\n=== P0-2 new base nodes, frame 2 m away ===")
frame_far = _frame_node(0.0, 0.0, 4.0)
dof_far_before = copy(frame_far.dof)
shells2, _ = _mesh([_wall(2.0, 0.0, 8.0, 0.0, 1, 3.0u"m")], Asap.Node[frame_far])
p0_2_flags = Bool[]
for (x, name) in ((2.0, "start"), (5.0, "mid"), (8.0, "end"))
    hits = _dof_of(shells2, x, 0.0, 4.0)
    ok = length(hits) == 1 && hits[1].dof == FIXED && hits[1] !== frame_far
    push!(p0_2_flags, _report("new base $name ($x,0,4) fixed", ok,
                    "n=$(length(hits)) dof=$(isempty(hits) ? "missing" : hits[1].dof)"))
end
push!(p0_2_flags, _report("distant frame node dof unchanged",
                frame_far.dof == dof_far_before,
                "dof=$(frame_far.dof)"))
p0_2 = all(p0_2_flags)

# Top of that wall must not be fixed (3 m above the base).
top = _dof_of(shells2, 2.0, 0.0, 7.0)
_report("new crown (2,0,7) is free, not fixed",
        length(top) == 1 && top[1].dof == Asap.fixDict[:free],
        "dof=$(isempty(top) ? "missing" : top[1].dof)")

# ---------------------------------------------------------------------------
# P0-3. Building with no walls: frame element count and wall shells.
# ---------------------------------------------------------------------------
println("\n=== P0-3 building with no walls ===")
function _bare_frame(; wall_edges=false)
    T = typeof(1.0u"m")
    skel = BuildingSkeleton{T}()
    skel.vertices = [
        Meshes.Point(0.0u"m", 0.0u"m", 0.0u"m"),
        Meshes.Point(0.0u"m", 0.0u"m", 4.0u"m"),
    ]
    skel.edge_indices = [(1, 2)]
    skel.geometry = GeometryCache(
        [0.0 0.0 0.0; 0.0 0.0 4.0],
        Vector{typeof(1.0u"m")}(),
        Vector{typeof(1.0u"m^2")}(),
        Dict{Int,Int}(), Dict{Int,Int}(),
    )
    skel.groups_vertices[:support] = [1]
    wall_edges && (skel.groups_edges[:walls] = [1])
    skel.stories[0] = Story{T}(0.0u"m", [1], Int[], Int[])
    skel.stories[1] = Story{T}(4.0u"m", [2], Int[], Int[])
    struc = BuildingStructure(skel)
    params = DesignParameters(materials=MaterialOptions(concrete=NWC_4000),
                              diaphragm_mode=:none)
    err = nothing
    try
        to_asap!(struc; params, diaphragms=:none)
    catch e
        err = e
    end
    model = struc.asap_model
    n_frame = isnothing(model) ? -1 : length(model.frame_elements)
    n_wall = 0
    if !isnothing(model)
        for sh in model.shell_elements
            sh.id === :wall && (n_wall += 1)
        end
    end
    areas = Float64[]
    if !isnothing(model)
        for el in model.frame_elements
            push!(areas, ustrip(u"m^2", el.section.A))
        end
    end
    return (n_frame=n_frame, n_wall=n_wall, n_edges=length(skel.edge_indices),
            areas=areas, err=err,
            base_dof=isnothing(model) ? Bool[] : copy(model.nodes[1].dof),
            top_dof=isnothing(model) ? Bool[] : copy(model.nodes[2].dof))
end

bare = _bare_frame()
p0_3 = _report(
    "no walls: frame count == edge count and no wall shells",
    bare.n_frame == bare.n_edges == 1 && bare.n_wall == 0 &&
        bare.base_dof == FIXED && bare.top_dof == FRAME_DOF,
    "n_frame=$(bare.n_frame) n_wall=$(bare.n_wall) areas=$(bare.areas) " *
    "base=$(bare.base_dof) top=$(bare.top_dof) err=$(bare.err === nothing ? "none" : typeof(bare.err))",
)

# Empty Wall vector, but the only edge is in :walls. Count stays 1; section may not.
println("\n=== probe: empty walls vector, :walls edge group ===")
grouped = _bare_frame(wall_edges=true)
_report(
    "empty Wall vector + :walls edge keeps placeholder area",
    length(grouped.areas) == 1 && grouped.areas[1] > 0 && grouped.n_wall == 0,
    "n_frame=$(grouped.n_frame) n_wall=$(grouped.n_wall) areas=$(grouped.areas) " *
    "err=$(grouped.err === nothing ? "none" : typeof(grouped.err))",
)

# ---------------------------------------------------------------------------
# Probe: second wall whose base is not the lowest, no frame node nearby.
# ---------------------------------------------------------------------------
println("\n=== probe: grade wall and a wall based 4 m higher ===")
shells3, nodes3 = _mesh([
    _wall(0.0, 0.0, 4.0, 0.0, 0, 4.0u"m"),   # base z = 0
    _wall(20.0, 0.0, 24.0, 0.0, 1, 4.0u"m"), # base z = 4, isolated in plan
], Asap.Node[])
low = _dof_of(shells3, 0.0, 0.0, 0.0)
high = _dof_of(shells3, 20.0, 0.0, 4.0)
high_top = _dof_of(shells3, 20.0, 0.0, 8.0)
_report("lowest base (0,0,0) fixed",
        length(low) == 1 && low[1].dof == FIXED,
        "dof=$(isempty(low) ? "missing" : low[1].dof)")
high_all_free = length(high) == 1 && high[1].dof == Asap.fixDict[:free]
_report("upper base (20,0,4) is fixed (expect this to FAIL if only the global min is fixed)",
        length(high) == 1 && high[1].dof == FIXED,
        "dof=$(isempty(high) ? "missing" : high[1].dof)")
_report("upper crown (20,0,8) free",
        length(high_top) == 1 && high_top[1].dof == Asap.fixDict[:free],
        "dof=$(isempty(high_top) ? "missing" : high_top[1].dof)")
n_free_upper = count(nd -> nd.dof == Asap.fixDict[:free] &&
                            ustrip(u"m", nd.position[1]) > 10, nodes3)
println("  upper-wall nodes that are fully free: $n_free_upper / $(count(nd -> ustrip(u"m", nd.position[1]) > 10, nodes3))")

# ---------------------------------------------------------------------------
# Probe: pier shorter than the 1 mm share tolerance. Top should be a new node.
# ---------------------------------------------------------------------------
println("\n=== probe: pier height 0.5 mm ===")
function _probe_short()
    try
        short_shells, _ = _mesh([_wall(0.0, 0.0, 2.0, 0.0, 0, 0.0005u"m")], Asap.Node[])
        b = _dof_of(short_shells, 0.0, 0.0, 0.0)
        t = _dof_of(short_shells, 0.0, 0.0, 0.0005)
        same = !isempty(b) && !isempty(t) && b[1] === t[1]
        area0 = any(sh -> sh.area == 0.0, short_shells)
        _report("0.5 mm pier crown is a distinct node",
                !same && length(t) == 1,
                "same_object=$same n_top=$(length(t)) zero_area=$area0 n_shells=$(length(short_shells))")
    catch e
        _report("0.5 mm pier meshes", false, "threw $(typeof(e)): $e")
    end
end
_probe_short()

println("\n=== probe: solve two-wall mesh ===")
function _probe_solve(shells)
    nodes = Asap.Node[]
    seen = Set{UInt64}()
    for sh in shells
        for nd in sh.nodes
            id = objectid(nd)
            id in seen && continue
            push!(seen, id)
            push!(nodes, nd)
        end
    end
    model = Asap.Model(nodes, shells, Asap.AbstractLoad[])
    Asap.process!(model)
    idx = model.freeDOFs
    K = Matrix(model.S[idx, idx])
    # Numerical rank at the scale of the shell stiffness, not machine eps.
    vals = svdvals(K)
    scale = maximum(vals)
    nullity = count(v -> v <= 1e-8 * scale, vals)
    println("  free_dofs=$(length(idx)) rank_deficiency=$nullity largest_sv=$scale smallest_sv=$(vals[end])")
end
_probe_solve(shells3)

println("\n=== probe: 0.5 mm shell nodes ===")
function _probe_short_nodes()
    short_shells, _ = _mesh([_wall(0.0, 0.0, 2.0, 0.0, 0, 0.0005u"m")], Asap.Node[])
    zs = Float64[]
    for sh in short_shells
        println("  area=$(sh.area) nodes=" * join((
            (round(ustrip(u"m", nd.position[1]); digits=6),
             round(ustrip(u"m", nd.position[3]); digits=6),
             nd.dof) for nd in sh.nodes), " | "))
    end
end
_probe_short_nodes()

# ---------------------------------------------------------------------------
# Probe: free shell node sits on the lowest base; no frame node within 1 mm.
# ---------------------------------------------------------------------------
println("\n=== probe: free shell node on the lowest base ===")
shell_nd = Asap.Node([0.0u"m", 0.0u"m", 4.0u"m"], :free, :diaphragm)
shell_dof_before = copy(shell_nd.dof)
# A one-triangle stand-in so the node is visible as an existing shell node.
dummy = Asap.ShellTri3(
    (shell_nd,
     Asap.Node([1.0u"m", 0.0u"m", 4.0u"m"], :free),
     Asap.Node([0.0u"m", 1.0u"m", 4.0u"m"], :free)),
    0.2u"m", NWC_4000.E, NWC_4000.ν; id=:diaphragm, ρ=0.0)
shells4, _ = _mesh([_wall(0.0, 0.0, 6.0, 0.0, 1, 3.0u"m")], Asap.Node[];
                   shells=Asap.ShellElement[dummy])
_report("reused free shell node at (0,0,4) keeps all-free dof",
        shell_nd.dof == shell_dof_before == Asap.fixDict[:free],
        "dof=$(shell_nd.dof)")
base_hits = _dof_of(shells4, 0.0, 0.0, 4.0)
_report("lowest base (0,0,4) got a fixed node despite the free shell node",
        any(nd.dof == FIXED for nd in base_hits),
        "n=$(length(base_hits)) dofs=$( [nd.dof for nd in base_hits] )")

println("\n=== summary flags ===")
println("p0_1_reused_kept=$(p0_1) p0_2_new_fixed=$(p0_2 && p0_2a && p0_2b) p0_3_no_walls=$(p0_3)")
println("upper_base_all_free=$(high_all_free)")
