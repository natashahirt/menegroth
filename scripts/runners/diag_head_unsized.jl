# Why rib pieces cut by a solid head stay unsized after sizing them.
# Rebuilds the "building casts solid heads" test bay and prints those pieces.
ENV["SS_ENABLE_VISUALIZATION"] = "false"
ENV["SS_SKIP_SOLVER_WARMUP"] = "true"
using Unitful, StructuralSynthesizer, StructuralSizer
const SY = StructuralSynthesizer

function bay(; Lx = 6.0, Ly = 4.0, z = 3.0)
    skel = BuildingSkeleton{Float64}()
    vs = [add_vertex!(skel, [x, y, z]) for (x, y) in ((0.0, 0.0), (Lx, 0.0), (Lx, Ly), (0.0, Ly))]
    for k in 1:4
        add_element!(skel, vs[k], vs[mod1(k + 1, 4)]; group = :beams)
    end
    rebuild_stories!(skel); find_faces!(skel); rebuild_geometry_cache!(skel)
    struc = BuildingStructure(skel)
    spans = SpanInfo{Float64}(Lx, Ly, (0.0, 1.0), Ly)
    fidx = findfirst(f -> Set(f) == Set(vs), skel.face_vertex_indices)
    cell = Cell(fidx, Lx * Ly * u"m^2", spans, 2.0u"kN/m^2", 3.0u"kN/m^2")
    cell.floor_type = :one_way
    push!(struc.cells, cell)
    push!(struc.slabs, Slab([1], CIPSlabResult(0.2, 0.2, 5.0), spans; floor_type = :one_way))
    return struc, vs
end

struc, vs = bay()
struc.skeleton.groups_vertices[:support] = copy(vs)
initialize_segments!(struc); initialize_members!(struc)
slab = only(struc.slabs)
concrete = StructuralSizer.NWC_4000
opts = StructuralSizer.ConcreteBeamOptions(material = concrete)
level = SY.FramingLevel{Float64}(slab_idx = 1, level = 1, pattern = IsoparametricPattern(4, 4, 0.25),
                                 material = concrete, analysis = :grillage, beam_options = opts)
push!(slab.framing_levels, level)
joists = SY.materialize_level!(struc, slab, level)
rib = StructuralSizer.RCTBeamSection(bw = 0.05u"m", h = 0.25u"m", bf = 0.40u"m",
                                     hf = 0.08u"m", bar_size = 5, n_bars = 2)
for beam in joists
    SY.group_id(beam) == level.solid_group_id && continue
    SY.set_section!(beam, rib)
end
struc.cells[1].live_load = 15.0u"kN/m^2"
for v in vs
    push!(struc.columns, Column{Float64}(base = MemberBase{Float64}(L = 3.0, Lb = 3.0),
                                         vertex_idx = v, c1 = 0.4, c2 = 0.4))
end
SY.grow_building_solid_heads!(struc, DesignParameters())
to_asap!(struc; diaphragms = :none)
ids = SY._unsized_rib_groups(struc, level)
println("unsized groups: ", length(ids))
for (bi, b) in enumerate(struc.beams)
    SY.group_id(b) in ids || continue
    segs = SY.segment_indices(b)
    edges = [struc.segments[si].edge_idx for si in segs]
    groups = [g for (g, es) in struc.skeleton.groups_edges if any(e in es for e in edges)]
    println("beam $bi role=$(b.role) gid=$(SY.group_id(b)) piece=$(SY.group_id(b) in level.piece_group_ids) ",
            "edges=$edges edge_groups=$groups")
end
owners_of = Dict{Int, Vector{Int}}()
for (bi, b) in enumerate(struc.beams), si in SY.segment_indices(b)
    push!(get!(owners_of, struc.segments[si].edge_idx, Int[]), bi)
end
shared = [(e, bs) for (e, bs) in owners_of if length(bs) > 1]
println("edges owned by more than one beam: ", length(shared), " ", first(shared, min(5, length(shared))))
arr, owners = SY.grillage_bays(struc, slab, level)
z = SY._slab_face_z_m(struc, slab)
adj = SY._level_frame_adjacency(struc.asap_model, z)
eb = SY._element_beam_map(struc)
for head in level.solid_heads
    for rib in SY._arrangement_leaving_ribs(arr, head, length(arr.edges))
        e1, fs = rib.path[1]
        a, b = arr.edges[e1]
        face = arr.nodes[fs ? a : b]
        hits = SY._elements_ending_at(struc.asap_model, SY._frame_element_indices(struc, owners[e1]),
                                      (face[1], face[2], z))
        k = hits[1][1]
        bi = eb[k]
        beam = struc.beams[bi]
        println("head $(head.column) face $face edge $(owners[e1]) element $k beam $bi ",
                "solid=$(SY.group_id(beam) == level.solid_group_id) sized=$(SY.section(beam) !== nothing) ",
                "owners=$(get(owners_of, owners[e1], Int[]))")
    end
end
function dump_unsized(tag)
    ids = SY._unsized_rib_groups(struc, level)
    println(tag, ": ", length(ids), " groups")
    beam_edges = Set{Int}()
    for g in SY.BEAM_GROUP_SYMBOLS
        union!(beam_edges, get(struc.skeleton.groups_edges, g, Int[]))
    end
    for (bi, b) in enumerate(struc.beams)
        SY.group_id(b) in ids || continue
        segs = SY.segment_indices(b)
        edges = [struc.segments[si].edge_idx for si in segs]
        in_beam = count(e -> e in beam_edges, edges)
        println("  beam $bi role=$(b.role) L=$(b.base.L) segs=$(length(segs)) ",
                "edges in beam groups $in_beam/$(length(edges)) gid=$(SY.group_id(b))")
    end
    dem = try
        SY._beam_group_demands(struc, g -> g in ids; resolution = 50, shell_demands = nothing)[1]
    catch err
        println("  demands threw: ", err)
        return ids
    end
    println("  groups with demands: ", length(dem), " of ", length(ids))
    return ids
end

println("--- grow on the solved building, concrete shear only ---")
try
    SY.grow_building_solid_heads!(struc, DesignParameters(rib_head_stirrups = false))
    report = level.solid_head_report
    println("stop=", report.stop, " steps=", report.steps,
            " bays=", [length(h.bays) for h in level.solid_heads],
            " one_way=", [round(r; digits = 2) for r in report.one_way_ratios])
catch err
    println("GROW THREW: ", err)
    showerror(stdout, err)
    println()
end
dump_unsized("after solved grow")
