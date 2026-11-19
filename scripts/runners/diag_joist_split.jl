# Why a joist bay is not split along its joists.
#
# `_cell_split_joist_loads` returns `nothing` for several reasons, and the
# caller then leaves the whole panel on its boundary beams. This prints, for
# every cell of one plan, which test rejected the split.
#
#     SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#         julia --project=StructuralStudies scripts/runners/diag_joist_split.jl special/rhombus_8x12

include(joinpath(@__DIR__, "sdf_rib_design.jl"))

const SY = StructuralSynthesizer

"""The same steps as `_cell_split_joist_loads`, reporting each one."""
function report_cell(struc, ci, frames)
    cell = struc.cells[ci]
    skel = struc.skeleton
    vis = skel.face_vertex_indices[cell.face_idx]
    raw = NTuple{2, Float64}[SY._vertex_xy_m(skel, v) for v in vis]
    poly = SY._drop_collinear_vertices(raw)
    openings = [skel.openings[k].loop for k in SY.face_openings(skel, cell.face_idx)]
    area = SY._polygon_area_m2(poly) - sum(SY._overlap_area(poly, op) for op in openings; init = 0.0)
    z_cell = SY._vertex_z_m(skel, first(vis))
    interiors = Asap.FrameElement[]
    boundary = Asap.FrameElement[]
    joists_seen = 0
    joists_off_z = 0
    for beam in struc.beams
        for si in SY.segment_indices(beam)
            e = struc.segments[si].edge_idx
            1 <= e <= length(frames) || continue
            el = frames[e]
            el isa Asap.FrameElement || continue
            z_el = (ustrip(u"m", el.nodeStart.position[3]) + ustrip(u"m", el.nodeEnd.position[3])) / 2
            a = (ustrip(u"m", el.nodeStart.position[1]), ustrip(u"m", el.nodeStart.position[2]))
            b = (ustrip(u"m", el.nodeEnd.position[1]), ustrip(u"m", el.nodeEnd.position[2]))
            mx, my = (a[1] + b[1]) / 2, (a[2] + b[2]) / 2
            inside = SY._point_in_polygon_xy(mx, my, poly)
            beam.role === :joist && inside && (joists_seen += 1)
            if abs(z_el - z_cell) > 0.01
                beam.role === :joist && inside && (joists_off_z += 1)
                continue
            end
            if SY._point_on_polygon_boundary(mx, my, poly; tol = 1e-6)
                push!(boundary, el)
            elseif beam.role === :joist && inside
                push!(interiors, el)
            end
        end
    end
    println("cell $ci  corners $(length(raw)) -> $(length(poly))  area $(round(area; digits = 3)) m²")
    println("  joist elements inside $joists_seen  (off the floor z $joists_off_z)" *
            "  boundary $(length(boundary))  interior $(length(interiors))")
    isempty(interiors) && (println("  REJECT: no joist element inside the cell"); return)
    axis = nothing
    for el in interiors
        axis = SY._across_joist_axis(el)
        axis === nothing || break
    end
    axis === nothing && (println("  REJECT: no joist direction"); return)
    println("  across-joist axis $(round.(axis; digits = 4))")
    tls = try
        SY._joist_strip_loads(poly, openings, vcat(boundary, interiors), interiors, axis)
    catch err
        println("  REJECT: the split threw")
        println("    ", first(split(sprint(showerror, err), '\n')))
        return
    end
    tls === nothing && (println("  REJECT: the split returned nothing"); return)
    loaded = sum(SY._tributary_area_m2, tls; init = 0.0)
    ids = Set(objectid(el) for el in interiors)
    on_joists = sum((SY._tributary_area_m2(ld) for ld in tls if objectid(ld.element) in ids); init = 0.0)
    println("  split area $(round(loaded; digits = 3)) m²  ratio $(round(loaded / area; digits = 5))" *
            "  on joists $(round(on_joists; digits = 3)) m²")
    abs(loaded / area - 1.0) <= 1e-3 && return
    println("  REJECT: split area is off the cell area by more than 0.1 %")
    beams = vcat(boundary, interiors)
    for (k, sub) in enumerate(Asap._split_polygon_by_beams(poly, interiors))
        pts = [SY.Meshes.Point(p[1] * u"m", p[2] * u"m") for p in sub]
        tribs = Asap.get_tributary_polygons(pts; axis = axis)
        n = length(sub)
        got = 0.0
        missing_edges = String[]
        for i in 1:n
            a, b = sub[i], sub[mod1(i + 1, n)]
            ps, ws = Asap._extract_depth_profile(tribs[i])
            L = hypot(b[1] - a[1], b[2] - a[2])
            e_area = sum((0.5 * (ws[j] + ws[j + 1]) * (ps[j + 1] - ps[j]) * L
                          for j in 1:length(ps) - 1); init = 0.0)
            cover = sum((hi - lo for (_, lo, hi) in SY._beams_along_segment(beams, a, b)); init = 0.0)
            got += e_area
            cover < 0.999 && e_area > 1e-6 &&
                push!(missing_edges, "edge $i covered $(round(cover; digits = 3)) carries $(round(e_area; digits = 4)) m²")
        end
        sa = SY._polygon_area_m2(sub)
        (abs(got / sa - 1) > 1e-3 || !isempty(missing_edges)) &&
            println("    strip $k  $(n) sides  area $(round(sa; digits = 4))  " *
                    "tributary $(round(got; digits = 4))  ", join(missing_edges, "; "),
                    "\n      ", [round.(p; digits = 3) for p in sub])
    end
end

plan_name = isempty(ARGS) ? "special/rhombus_8x12" : ARGS[1]
params = rib_parameters(plan_name, :waffle)
struc = BuildingStructure(plan_skeleton(load_plan(plan_name)))
prepare!(struc, params)
SY.to_asap!(struc; params = params)
frames = struc.asap_model.frame_elements
println(plan_name, "  cells ", length(struc.cells), "  beams ", length(struc.beams),
        "  joists ", count(b -> b.role === :joist, struc.beams))
for slab in struc.slabs
    println("slab  framing levels ", length(slab.framing_levels), "  cells ", slab.cell_indices)
end
for ci in eachindex(struc.cells)
    report_cell(struc, ci, frames)
end
