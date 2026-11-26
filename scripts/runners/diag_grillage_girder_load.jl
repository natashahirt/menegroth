# Why does one grillage girder draw ~1,770 kN of shear?
#
# topology/r2c1 as "steel ribs composite with a two-way slab" produced a
# 5 m girder with Vu = 1,772 kN and Mu = 2,100 kN·m, which implies an
# effective line load near 700 kN/m — about 14x a real office floor. This
# runner isolates the source at the LOAD-APPLICATION layer, before any
# composite sizing loop:
#
#   1. total applied downward force  vs  pressure x floor area  (double path?)
#   2. each beam's tributary average width                       (bad tributary?)
#   3. a plain gravity frame solve, worst beam groups by shear   (concentration?)
#
#     SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#         julia --project=StructuralStudies \
#         scripts/runners/diag_grillage_girder_load.jl [plan] [system]

include(joinpath(@__DIR__, "sdf_nova_topology_systems.jl"))

using Printf

const DIAG_PLAN = length(ARGS) >= 1 ? ARGS[1] : "topology/r2c1"
const DIAG_SYSTEM = length(ARGS) >= 2 ? Symbol(ARGS[2]) : :steel_rib_composite

"""Downward force (N) of one TributaryLoad: pressure x length x mean width."""
function _trib_force_N(ld::Asap.TributaryLoad)
    L = ld.element.length
    Lm = L isa Unitful.Quantity ? ustrip(u"m", L) : Float64(L)
    p = ld.positions
    w = ld._widths_m
    integ = 0.0
    for i in 1:(length(p) - 1)
        integ += 0.5 * (w[i] + w[i + 1]) * (p[i + 1] - p[i])
    end
    return ld._pressure_Pa * Lm * integ
end

"""Sum of every TributaryLoad on the model (N, downward positive)."""
function _total_applied_N(model)
    total = 0.0
    for ld in model.loads
        ld isa Asap.TributaryLoad || continue
        total += _trib_force_N(ld)
    end
    return total
end

"""Max |V| and |M| over a beam's segments from the solved model (N, N·m)."""
function _beam_VM(struc, beam, element_loads; resolution = 200)
    Vmax = 0.0; Mmax = 0.0
    for si in SS.segment_indices(beam)
        e = struc.segments[si].edge_idx
        el = struc.asap_model.frame_elements[e]
        ell = element_loads[el.elementID]
        fd = Asap.ElementForceAndDisplacement(el, ell; resolution = resolution)
        f = fd.forces
        Vmax = max(Vmax, maximum(abs, f.Vy), maximum(abs, f.Vz))
        Mmax = max(Mmax, maximum(abs, f.My), maximum(abs, f.Mz))
    end
    return (V = Vmax, M = Mmax)
end

_as(x, u) = x isa Unitful.Quantity ? ustrip(u, x) : Float64(x)

function main_diag()
    @printf("=== %s  %s ===\n", DIAG_PLAN, DIAG_SYSTEM)
    params = nova_system_parameters(DIAG_PLAN, DIAG_SYSTEM)
    params.max_iterations = 1

    struc = BuildingStructure(plan_skeleton(load_plan(DIAG_PLAN)))
    prepare!(struc, params)

    # Floor area and the applied pressure, straight off the cells.
    net_area = 0.0; press_env = 0.0; press_cell = Float64[]
    for cell in struc.cells
        cell.floor_type == :grade && continue
        a = _as(cell.area, u"m^2")
        net_area += a
        p = _as(cell.sdl, u"kN/m^2") + _as(cell.self_weight, u"kN/m^2") +
            _as(cell.live_load, u"kN/m^2")
        push!(press_cell, p)
        press_env = max(press_env, p)
    end
    @printf("cells: %d loaded, net area %.1f m^2\n", length(press_cell), net_area)
    @printf("service pressure per cell (sdl+sw+ll): min %.2f  max %.2f kPa\n",
            minimum(press_cell), maximum(press_cell))

    compute_member_tributaries!(struc)
    to_asap!(struc; params = params, diaphragms = :none)
    SS._solve_struc_model!(struc)

    applied = _total_applied_N(struc.asap_model)
    # Factored-ish reference: just the service pressure x area, for the ratio.
    svc_total = sum(press_cell[i] * 1.0 for i in eachindex(press_cell)) # kPa-weighted below
    svc_force = 0.0
    let i = 0
        for cell in struc.cells
            cell.floor_type == :grade && continue
            i += 1
            svc_force += press_cell[i] * 1e3 * _as(cell.area, u"m^2")
        end
    end
    @printf("\napplied TributaryLoad total: %.1f kN\n", applied / 1e3)
    @printf("service pressure x area:     %.1f kN\n", svc_force / 1e3)
    @printf("ratio applied/expected:      %.2f  (1.0 = no double path)\n",
            applied / svc_force)

    # Tributary widths per beam.
    widths = Tuple{Int, Float64, Float64, Symbol}[]  # (beam i, L, trib avg width, role)
    for (i, b) in enumerate(struc.beams)
        prof = b.tributary_profile
        w = prof === nothing ? 0.0 : _as(SS.tributary_average(prof), u"m")
        L = _as(SS.member_length(b), u"m")
        push!(widths, (i, L, w, b.role))
    end
    sort!(widths; by = t -> -t[3])
    @printf("\nwidest tributary beams (width m, span m, role):\n")
    for t in widths[1:min(8, length(widths))]
        @printf("  beam %-4d  width %6.2f  L %5.2f  %s\n", t[1], t[3], t[2], t[4])
    end

    # Solved gravity shear per beam group.
    element_loads = Asap.get_elemental_loads(struc.asap_model)
    worst = Tuple{Int, Float64, Float64}[]  # (beam i, V kN, M kNm)
    for (i, b) in enumerate(struc.beams)
        vm = _beam_VM(struc, b, element_loads)
        push!(worst, (i, vm.V / 1e3, vm.M / 1e3))
    end
    sort!(worst; by = t -> -t[2])
    @printf("\nhighest solved gravity shear (plain frame, no composite):\n")
    for t in worst[1:min(8, length(worst))]
        @printf("  beam %-4d  V %8.1f kN  M %8.1f kN·m\n", t[1], t[2], t[3])
    end
end

main_diag()
