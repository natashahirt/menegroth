# Three inspectable beam scenes: naked steel, the same frame with collinear
# grouping, and composite steel. Each picture is the solved model.
ENV["SS_ENABLE_VISUALIZATION"] = "false"
ENV["SS_SKIP_SOLVER_WARMUP"] = "true"
println("loading")
flush(stdout)

using StructuralSynthesizer, StructuralSizer, Unitful

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const OUT = joinpath(ROOT, "viewer", "public")
const SS = StructuralSizer

function beam_z(struc, beam)
    si = first(segment_indices(beam))
    v1, v2 = struc.skeleton.edge_indices[struc.segments[si].edge_idx]
    z = struc.skeleton.geometry.vertex_coords
    return (z[v1, 3] + z[v2, 3]) / 2
end

function write_case(label, path, params;
                     size = (54.0u"ft", 42.0u"ft", 12.0u"ft", 3, 3, 2))
    skel = gen_medium_office(size...)
    design = design_building(BuildingStructure(skel), params)
    packet = build_scene(design)
    write_scene(path, packet)
    struc = design.structure
    model = design.asap_model
    println("== ", label)
    println("file ", path)
    println("analysis ", StructuralSynthesizer.analysis_scene_kind(model),
            "  frames ", length(model.frame_elements),
            "  shells ", length(model.shell_elements),
            "  nodes ", length(model.nodes))
    areas = Float64[]
    for el in model.shell_elements
        el.id === :wall && continue
        a, b, c = el.nodes
        ax, ay = ustrip(u"m", a.position[1]), ustrip(u"m", a.position[2])
        bx, by = ustrip(u"m", b.position[1]), ustrip(u"m", b.position[2])
        cx, cy = ustrip(u"m", c.position[1]), ustrip(u"m", c.position[2])
        push!(areas, abs((bx - ax) * (cy - ay) - (by - ay) * (cx - ax)) / 2)
    end
    if !isempty(areas)
        println("slab triangles ", length(areas),
                "  area ", round(minimum(areas); digits=3), " to ",
                round(maximum(areas); digits=3), " m^2")
    end
    zs = [round(beam_z(struc, beam); digits=3) for beam in struc.beams]
    println("beam elevations ", unique(sort(zs)))
    sections = String[]
    n_studs = 0
    for idx in sort!(collect(keys(design.beams)))
        br = design.beams[idx]
        layout = StructuralSynthesizer.composite_stud_placement(struc, struc.beams[idx])
        n = layout === nothing ? 0 : length(layout.s)
        n_studs += n
        push!(sections, string(br.section_size))
        println("  beam ", idx, "  ", br.section_size,
                "  z ", round(beam_z(struc, struc.beams[idx]); digits=2),
                "  studs ", n)
    end
    mesh = StructuralSynthesizer._composite_mesh(struc)
    n_layouts = mesh === nothing ? 0 : length(get(mesh, :stud_placement_index, ()))
    println("sections ", length(unique(sections)), " distinct, ", n_studs,
            " studs, layouts ", n_layouts)
    flush(stdout)
    return design
end

nwc = SS.NWC_4000
nwc145 = SS.Concrete(nwc.E, nwc.fc′, uconvert(u"kg/m^3", 145.0u"lb/ft^3"), 0.2, nwc.ecc)
naked = (
    floor = OneWayOptions(),
    materials = MaterialOptions(concrete = nwc, steel = SS.A992_Steel),
    beams = SteelBeamOptions(),
    columns = SteelColumnOptions(),
    skip_visualization = true,
)

want = isempty(ARGS) ? ["off", "on", "composite"] : ARGS
if "off" in want
    write_case("naked steel, collinear off", joinpath(OUT, "steel_beams.mgscene"),
               DesignParameters(; naked..., collinear_grouping = false))
end
if "on" in want
    write_case("naked steel, collinear on", joinpath(OUT, "steel_beams_collinear.mgscene"),
               DesignParameters(; naked..., collinear_grouping = true))
end
if "composite" in want
    # 2VLI does not pass a 14 ft unshored span. 10 ft bays are the span the
    # deck routine already carries.
    write_case("composite steel", joinpath(OUT, "steel_composite.mgscene"),
               DesignParameters(
                   floor = CompositeDeckOptions(deck_profile = "2VLI", fill_material = nwc145),
                   materials = MaterialOptions(concrete = nwc145, steel = SS.A992_Steel),
                   beams = SteelBeamOptions(composite = true,
                                        composite_slab_type = :deck,
                                        composite_deck_profile = "2VLI",
                                        composite_t_slab = 2.0u"inch"),
                   columns = SteelColumnOptions(),
                   collinear_grouping = false,
                   skip_visualization = true,
               );
               size = (40.0u"ft", 30.0u"ft", 12.0u"ft", 4, 3, 2))
end
println("done")
