using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

const SS = StructuralSynthesizer

skel = gen_medium_office(30.0u"ft", 24.0u"ft", 10.0u"ft", 2, 2, 1)
struc = BuildingStructure(skel)

params = DesignParameters(
    floor = OneWayOptions(),
    materials = MaterialOptions(steel = A992_Steel, concrete = NWC_4000, rebar = Rebar_60),
    framing_opts = (;
        materials = (; steel = A992_Steel, beam = A992_Steel),
        spacing = 5.0u"ft",
    )
)

prepare!(struc, params)

println("n_beams = ", length(struc.beams))
joists = filter(b -> b.level == 1, struc.beams)
println("n_joists = ", length(joists))
@assert !isempty(joists)

# Validate face_vertex_indices / face_edge_indices internal consistency after
# _split_host_edge! ran (this is the exact defect under review: stale indices
# would crash _compute_inward_normal via SS.update_structural_offsets!).
for (f, verts) in enumerate(skel.face_vertex_indices)
    edges = skel.face_edge_indices[f]
    n = length(verts)
    @assert length(edges) == n "face $f: verts=$n edges=$(length(edges))"
    for i in 1:n
        v_a = verts[i]
        v_b = verts[mod1(i+1, n)]
        e = edges[i]
        ev1, ev2 = skel.edge_indices[e]
        ok = (ev1 == v_a && ev2 == v_b) || (ev1 == v_b && ev2 == v_a)
        i_next = mod1(i + 1, n)
        ev_pair = (ev1, ev2)
        @assert ok "face $f edge $i (edge_idx=$e) does not connect verts[$i]=$v_a -> verts[$i_next]=$v_b (edge_indices=$ev_pair)"
    end
end
println("face_vertex_indices / face_edge_indices consistency: OK")

# Now exercise the actual crash path: _compute_inward_normal via structural
# offsets, which requires walking boundary edges (including any that were
# subdivided by _split_host_edge!).
for col in struc.columns
    col.c1 = 12.0u"inch"
    col.c2 = 12.0u"inch"
end
SS.update_structural_offsets!(struc; input_is_centerline=false)
println("update_structural_offsets! completed without error")

n_nonzero = count(c -> c.position !== :interior, struc.columns)
println("n_edge_or_corner_columns = ", n_nonzero)

println("ALL CHECKS PASSED")
