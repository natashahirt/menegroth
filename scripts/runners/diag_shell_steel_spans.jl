# Diagnose the steel story-shell span records on the one-bay composite fixture
# from StructuralSynthesizer/test/analyze/test_story_shell_beams.jl.
ENV["SS_ENABLE_VISUALIZATION"] = "false"
ENV["SS_SKIP_SOLVER_WARMUP"] = "true"
using Unitful, Asap, StructuralSynthesizer, StructuralSizer
const SY = StructuralSynthesizer
const SZ = StructuralSizer

function one_bay(; Lx = 6.0, Ly = 4.0, z = 3.0)
    skel = BuildingSkeleton{Float64}()
    corners = [(0.0, 0.0), (Lx, 0.0), (Lx, Ly), (0.0, Ly)]
    vs = [add_vertex!(skel, [x, y, z]) for (x, y) in corners]
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
    push!(struc.slabs, Slab{Float64}([1], CIPSlabResult(0.2, 0.2, 5.0), :one_way, spans,
                                     :interior, nothing, MaterialVolumes(), nothing, nothing,
                                     FramingLevel{Float64}[]))
    for e in sort(collect(skel.groups_edges[:beams]))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        push!(struc.beams, Beam([length(struc.segments)], L; role = :girder, level = 0))
    end
    floor = [Asap.Node([x * u"m", y * u"m", z * u"m"], fill(true, 6)) for (x, y) in corners]
    ground = [Asap.Node([x * u"m", y * u"m", 0.0u"m"], fill(false, 6)) for (x, y) in corners]
    beam_sec = SZ.to_asap_section(W("W12X26"), A992_Steel)
    col_sec = Asap.Section(0.05u"m^2", 200e9u"Pa", 77e9u"Pa",
                           1e-3u"m^4", 1e-3u"m^4", 1e-3u"m^4", 7850.0u"kg/m^3")
    beam_els = [Asap.Element(floor[findfirst(==(a), vs)], floor[findfirst(==(b), vs)], beam_sec)
                for (a, b) in skel.edge_indices]
    col_els = [Asap.Element(ground[k], floor[k], col_sec) for k in 1:4]
    loads = Asap.AbstractLoad[Asap.TributaryLoad(el, [0.0, 1.0], [1.0u"m", 1.0u"m"],
                                                 10_000.0u"Pa", (0.0, 0.0, -1.0))
                              for el in beam_els]
    model = Asap.Model(vcat(floor, ground), vcat(beam_els, col_els), loads)
    Asap.solve!(model)
    struc.asap_model = model
    compute_cell_tributaries!(struc)
    return struc, corners
end

struc, corners = one_bay()
conc = Concrete(3644.0u"ksi", 4.0u"ksi", 145.0u"lb/ft^3", 0.20, 0.1)
opts = SteelBeamOptions(; composite = true, composite_anchor_d = 0.75u"inch",
                        composite_anchor_length = 5.0u"inch", composite_anchor_Fu = 65.0u"ksi",
                        custom_catalog = [W("W12X26"), W("W16X40"), W("W21X55")],
                        deflection_limit = nothing, total_deflection_limit = nothing)
out = size_beams_with_story_shell!(struc, opts; levels = [0], reanalyze = false,
    composite_concrete = conc, composite_t_slab = 8.0u"inch",
    shell_kwargs = (target_edge = 1.0u"m", support_points = corners))
beam = struc.beams[1]
prof = SY.composite_stiffness_profile(struc, beam)
println("section: ", section(beam).name, "  Ix = ", ustrip(u"m^4", section(beam).Ix))
println("profile regions: ", prof.regions)
println("profile ΣQn: ", prof.ΣQn, "  Asr = ", prof.Asr)
for s in (0.05, 0.25, 0.5)
    println("  I at s=$s: ", ustrip(u"m^4", uconvert(u"m^4", SY.composite_stiffness_at(prof, s))))
end
println("I_neg: ", ustrip(u"m^4", uconvert(u"m^4",
    SZ.get_I_cracked_negative(prof.section, prof.Asr; d_rebar = prof.d_rebar))))
println("I_solved: ", SY._solved_service_inertia(prof))
for (k, f) in enumerate(out.demands[1].moment_fields)
    println("shell field $k regions: ",
            [(r.s_left, r.s_right) for r in SZ.positive_moment_regions(f; breakpoints = f.breakpoints)])
end
println("region_mismatch: ", out.region_mismatch)
