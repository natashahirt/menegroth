# Why does steel_deck on topology/r2c1 fail deflection_ll for every section
# (W14X257 closest at 2.75x L/360) on a 6 m composite girder whose moment
# (384 kN·m) implies only ~0.3x deflection?
#
# Hypothesis: the governing deflection is a CANTILEVER/overhang tip, not a
# simple-span sag. topology/r2c1 sets its perimeter columns inboard of the
# slab edge (the 15.9 m² overhang found earlier), so perimeter beams
# cantilever past their end column. A cantilever tip deflects far more per
# unit moment than a simple span, and the limit uses l = 2x(overhang), so no
# section passes.
#
# This probe installs nominal sections (skips the 28 min composite repro),
# runs the real service-deflection routine, and for the worst beams reports
# whether an END node moves (cantilever) vs the interior sagging (simple span).
#
#     SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#         julia --project=StructuralStudies \
#         scripts/runners/diag_steel_deck_deflection.jl [plan] [section]

include(joinpath(@__DIR__, "sdf_nova_topology_systems.jl"))

using Printf
_as(x, u) = x isa Unitful.Quantity ? ustrip(u, x) : Float64(x)

function main()
    plan = length(ARGS) >= 1 ? ARGS[1] : "topology/r2c1"
    secname = length(ARGS) >= 2 ? ARGS[2] : "W24X76"
    @printf("=== %s  steel_deck  nominal %s ===\n", plan, secname)
    params = nova_system_parameters(plan, :steel_deck)

    struc = BuildingStructure(plan_skeleton(load_plan(plan)))
    prepare!(struc, params)
    to_asap!(struc; params = params, diaphragms = :none)
    SR.size_slabs!(struc; options = SS.resolve_floor_options(params), max_iterations = 10)
    sec = SR.W_CATALOG[secname]
    for b in struc.beams
        SS.set_section!(b, deepcopy(sec))
    end
    SS.update_analysis!(struc, :stiffness)

    # Real service-deflection routine: per-beam (δ_LL/l, δ_tot/l), with the
    # cantilever l = 2*overhang rule already applied.
    n = length(struc.beams)
    el_ll, el_tot, ratios = SS._relative_service_deflection(struc, collect(1:n))
    rows = [(i, ratios[i][1], ratios[i][2]) for i in 1:n]
    sort!(rows; by = r -> -r[2])

    # Classify each beam from a populated gravity solve: does an END node move
    # (cantilever) or only the interior (simple span)? The deflected shape is
    # what matters here, so the design-load solve is fine.
    SS._solve_struc_model!(struc)
    model = struc.asap_model
    function classify(bi)
        ids = Int[]
        for si in SS.segment_indices(struc.beams[bi])
            append!(ids, SS._frame_element_indices(struc, struc.segments[si].edge_idx))
        end
        filter!(i -> 1 <= i <= length(model.frame_elements), ids)
        isempty(ids) && return ("?", 0.0, 0.0, 0.0)
        # Read vertical (z) displacement straight off the solved Asap nodes.
        uzs = Float64[]
        for i in ids
            el = model.frame_elements[i]
            for nd in (el.nodeStart, el.nodeEnd)
                push!(uzs, _as(nd.displacement[3], u"m"))
            end
        end
        endnodes = (model.frame_elements[ids[1]].nodeStart,
                    model.frame_elements[ids[end]].nodeEnd)
        uz_end = maximum(abs(_as(nd.displacement[3], u"m")) for nd in endnodes)
        uz_max = maximum(abs, uzs)
        kind = uz_end > 0.5 * uz_max ? "CANTILEVER" : "span-sag"
        return (kind, uz_end * 1000, uz_max * 1000, 0.0)
    end

    @printf("\nworst beams by δ_LL/l ratio (nominal %s):\n", secname)
    @printf("  %-5s %-8s %-8s %-7s %-11s %10s %10s\n",
            "beam", "δLL/l", "δtot/l", "role", "class", "uz_end(mm)", "uz_max(mm)")
    for r in rows[1:min(12, length(rows))]
        bi = r[1]
        kind, uze, uzm, _ = classify(bi)
        @printf("  %-5d %-8.3f %-8.3f %-7s %-11s %10.1f %10.1f\n",
                bi, r[2] * 360, r[3] * 360, struc.beams[bi].role, kind, uze, uzm)
    end
    @printf("\n(δLL/l shown as a multiple of L/360; >1 fails. role/class tell geometry.)\n")
end

main()
