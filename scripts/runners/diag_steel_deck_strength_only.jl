# Definitive view of the steel_deck deflection failure on topology/r2c1.
#
# The plan supports columns only every 12 m / 10 m on several frame lines, so a
# "6 m" beam piece is half of a 12 m support-to-support chord. To see the real
# story with properly STRENGTH-sized composite sections (not nominal), size
# with the deflection limit DISABLED so the design completes, then measure the
# actual live-load deflection δ/l of every beam against its chord span.
#
#     SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#         julia --project=StructuralStudies \
#         scripts/runners/diag_steel_deck_strength_only.jl [plan]

include(joinpath(@__DIR__, "sdf_nova_topology_systems.jl"))

using Printf
_as(x, u) = x isa Unitful.Quantity ? ustrip(u, x) : Float64(x)

function main()
    plan = length(ARGS) >= 1 ? ARGS[1] : "topology/r2c1"
    @printf("=== %s  steel_deck  (strength-only sizing, deflection measured after) ===\n", plan)
    params = nova_system_parameters(plan, :steel_deck)
    # Disable deflection limits so sizing completes on strength alone.
    base = params.beams
    params.beams = SR.SteelBeamOptions(
        composite = base.composite, composite_slab_type = base.composite_slab_type,
        composite_deck_profile = base.composite_deck_profile,
        composite_shored = base.composite_shored,
        deflection_limit = nothing, total_deflection_limit = nothing,
    )
    params.framing_opts = merge(params.framing_opts, (beam_options = params.beams,))
    params.max_iterations = 4

    struc = BuildingStructure(plan_skeleton(load_plan(plan)))
    t0 = time()
    design_building(struc, params; restore = false)
    @printf("sized in %.0f s\n", time() - t0)

    # Measure live-load deflection of every beam on the final sized model.
    n = length(struc.beams)
    _, _, ratios = SS._relative_service_deflection(struc, collect(1:n))
    rows = [(i, ratios[i][1] * 360, ratios[i][2] * 360) for i in 1:n]  # as multiples of 1/360
    sort!(rows; by = r -> -r[2])
    @printf("\nworst beams by δ_LL/(L/360) on the strength-sized design:\n")
    @printf("  %-5s %-9s %-9s %-7s %-10s %-10s\n",
            "beam", "δLL·360", "δtot·240", "role", "L(m)", "section")
    for r in rows[1:min(15, length(rows))]
        b = struc.beams[r[1]]
        secn = try; SS.section(b).name; catch; "?"; end
        @printf("  %-5d %-9.2f %-9.2f %-7s %-10.2f %-10s\n",
                r[1], r[2], r[3] * (360 / 240), String(b.role),
                _as(SS.member_length(b), u"m"), secn)
    end
    nfail = count(r -> r[2] > 1.0, rows)
    @printf("\n%d / %d beams exceed L/360 in live-load deflection even after strength sizing.\n",
            nfail, n)
end

main()
