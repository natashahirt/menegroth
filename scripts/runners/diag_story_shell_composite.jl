# Why does the story-shell path concentrate load onto a few girders when the
# frame-only one-way tributary solve spreads it (356 kN worst)?
#
# steel_rib_composite declares the floor two_way (127 mm slab) but also carries
# 116 one-way composite joists. The story shell meshes that slab as a two-way
# plate and hangs the beams below as frames offset to the slab mid-plane
# (composite-like). This probe installs a uniform nominal section (so we skip
# the 10 h sizing loop), solves ONE story shell and ONE plain frame on the SAME
# sections, and compares the worst girder shear from each path.
#
#     SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#         julia --project=StructuralStudies \
#         scripts/runners/diag_story_shell_composite.jl [plan] [section]

include(joinpath(@__DIR__, "sdf_nova_topology_systems.jl"))

using Printf
_as(x, u) = x isa Unitful.Quantity ? ustrip(u, x) : Float64(x)

function main()
    plan = length(ARGS) >= 1 ? ARGS[1] : "topology/r2c1"
    secname = length(ARGS) >= 2 ? ARGS[2] : "W24X76"
    @printf("=== %s  steel_rib_composite  nominal %s ===\n", plan, secname)
    params = nova_system_parameters(plan, :steel_rib_composite)

    struc = BuildingStructure(plan_skeleton(load_plan(plan)))
    prepare!(struc, params)
    to_asap!(struc; params = params, diaphragms = :none)
    SR.size_slabs!(struc; options = SS.resolve_floor_options(params), max_iterations = 10)

    sec = SR.W_CATALOG[secname]
    for b in struc.beams
        SS.set_section!(b, deepcopy(sec))
    end
    @printf("installed %s on %d beams (%d joists)\n", secname,
            length(struc.beams), count(b -> b.role === :joist, struc.beams))

    # Frame-only solve on these sections (one-way joist tributary already on the
    # model from to_asap!). Worst girder shear.
    SS.update_analysis!(struc, :stiffness)
    SS._solve_struc_model!(struc)
    eloads = Asap.get_elemental_loads(struc.asap_model)
    function frame_VM(b)
        V = 0.0; M = 0.0
        for si in SS.segment_indices(b)
            el = struc.asap_model.frame_elements[struc.segments[si].edge_idx]
            fd = Asap.ElementForceAndDisplacement(el, eloads[el.elementID]; resolution = 200)
            V = max(V, maximum(abs, fd.forces.Vy), maximum(abs, fd.forces.Vz))
            M = max(M, maximum(abs, fd.forces.My), maximum(abs, fd.forces.Mz))
        end
        return (V, M)
    end
    fr = sort([(i, frame_VM(b)...) for (i, b) in enumerate(struc.beams)]; by = r -> -r[2])
    @printf("\nFRAME (one-way joist tributary) worst shears:\n")
    for r in fr[1:min(5, length(fr))]
        @printf("  beam %-4d  V %8.1f kN  M %8.1f kN·m  role=%s\n",
                r[1], r[2] / 1e3, r[3] / 1e3, struc.beams[r[1]].role)
    end

    # Story shell on the same sections. Pick the level whose faces hold the slab.
    face0 = struc.cells[first(struc.slabs[1].cell_indices)].face_idx
    level = first(lv for lv in sort(collect(keys(struc.skeleton.stories)))
                  if face0 in struc.skeleton.stories[lv].faces)
    @printf("\n(slab is on story level %d)\n", level)
    shell = SS.build_story_shell(struc, level; steel = SR.A992_Steel)
    res = SS.solve_story_shell!(shell, struc; service = false)
    @printf("\nSHELL status %s, skipped %d beams\n", res.analysis_status, length(res.skipped_beams))
    sh = sort([(i, d.Vu, max(d.Mu_pos, d.Mu_neg)) for (i, d) in res.beam_demands]; by = r -> -r[2])
    @printf("STORY-SHELL (two-way plate + offset beams) worst shears:\n")
    for r in sh[1:min(8, length(sh))]
        b = struc.beams[r[1]]
        @printf("  beam %-4d  Vu %8.1f kN  Mu %8.1f kN·m  L %5.2f  role=%s\n",
                r[1], r[2] / 1e3, r[3] / 1e3, _as(SS.member_length(b), u"m"), b.role)
    end

    # Total shell AreaLoad for scale.
    sf = 0.0
    for ld in res.model.loads
        ld isa Asap.AreaLoad || continue
        p = _as(ld.pressure, u"N/m^2")
        for el in ld.shells
            sf += abs(p) * _as(Asap.area(el), u"m^2")
        end
    end
    @printf("\ntotal shell AreaLoad %.0f kN ; frame worst %.0f kN vs shell worst %.0f kN\n",
            sf / 1e3, fr[1][2] / 1e3, sh[1][2] / 1e3)
end

main()
