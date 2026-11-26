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

    # Partition applied load by the role of the element it sits on, and count
    # how many TributaryLoads sit on each element (a double path shows as an
    # element carrying load from two sources, or joists + perimeter both > 0).
    model = struc.asap_model
    e_of_el = IdDict{Any, Int}()
    for e in eachindex(model.frame_elements)
        e_of_el[model.frame_elements[e]] = e
    end
    roles = Dict{Int, Symbol}()
    for b in struc.beams, si in SS.segment_indices(b)
        roles[struc.segments[si].edge_idx] = b.role
    end
    byrole = Dict{Symbol, Float64}()
    loads_per_edge = Dict{Int, Int}()
    force_per_edge = Dict{Int, Float64}()
    kinds = Dict{Symbol, Float64}()
    for ld in model.loads
        if ld isa Asap.TributaryLoad
            f = _trib_force_N(ld)
            e = get(e_of_el, ld.element, 0)
            r = get(roles, e, :none)
            byrole[r] = get(byrole, r, 0.0) + f
            loads_per_edge[e] = get(loads_per_edge, e, 0) + 1
            force_per_edge[e] = get(force_per_edge, e, 0.0) + f
        end
        k = nameof(typeof(ld))
        kinds[k] = get(kinds, k, 0.0) + 1
    end
    # Authoritative geometric area: sum TributaryLoad plan-area over the WHOLE
    # model (pressure-independent). If this equals the 480 m^2 floor, there is no
    # leak and the 4612 kN is purely the load factor x pressure.
    model_area = 0.0
    n_dead = 0; n_live = 0; n_other = 0
    for ld in struc.asap_model.loads
        ld isa Asap.TributaryLoad || continue
        p1 = ld.element.nodeStart.position; p2 = ld.element.nodeEnd.position
        L = hypot(_as(p2[1] - p1[1], u"m"), _as(p2[2] - p1[2], u"m"), _as(p2[3] - p1[3], u"m"))
        pos = ld.positions; w = ld._widths_m
        a = 0.0
        for i in 1:(length(pos) - 1)
            a += 0.5 * (w[i] + w[i + 1]) * (pos[i + 1] - pos[i]) * L
        end
        model_area += a
    end
    cell0 = first(c for c in struc.cells if c.floor_type != :grade)
    comb_p = _as(SS.envelope_pressure(params.load_combinations,
                 cell0.sdl + cell0.self_weight, cell0.live_load), u"kN/m^2")
    @printf("\nTOTAL model TributaryLoad geometric area: %.1f m^2  (floor = %.1f m^2, ratio %.3f)\n",
            model_area, net_area, model_area / net_area)
    @printf("factored envelope pressure (cell0): %.2f kPa ; area x that = %.1f kN vs applied %.1f kN\n",
            comb_p, model_area * comb_p, applied / 1e3)

    # Account the 15.8 m^2 gap: slab-edge strips (slab past the column
    # centerlines out to the column faces + conservative re-entrant corner excess).
    es = SS.slab_edge_strips(struc)
    es_area = 0.0; es_corner = 0.0
    for s in es
        L = hypot(s.b[1] - s.a[1], s.b[2] - s.a[2])
        es_area += s.width * L
        es_corner += s.corner_start + s.corner_end
    end
    @printf("\nslab-edge strips: %d strips  run-area %.2f m^2  corner-excess %.2f m^2  total %.2f m^2\n",
            length(es), es_area, es_corner, es_area + es_corner)
    @printf("  (floor %.1f + edge %.2f = %.1f vs model tributary %.1f m^2)\n",
            net_area, es_area + es_corner, net_area + es_area + es_corner, model_area)

    @printf("\napplied load by element role (kN):\n")
    for (r, f) in sort(collect(byrole); by = p -> -p[2])
        @printf("  %-10s %8.1f\n", r, f / 1e3)
    end
    @printf("load objects by type: %s\n", join(["$k=$(Int(v))" for (k, v) in kinds], "  "))
    multi = sort([(e, n) for (e, n) in loads_per_edge if n > 1]; by = t -> -t[2])
    @printf("edges carrying >1 TributaryLoad: %d\n", length(multi))
    for (e, n) in multi[1:min(6, length(multi))]
        @printf("  edge %-4d  %d loads  %.1f kN  role=%s\n",
                e, n, force_per_edge[e] / 1e3, get(roles, e, :none))
    end

    # Per-slab: applied load area (from the cell records to_asap! stored) vs the
    # net area of the cells the slab represents. Each routing path has a per-cell
    # conservation gate, so any slab with ratio != 1 localizes the leak.
    """Plan area (m^2) a TributaryLoad covers: 3D element length x mean width."""
    function _tl_area(ld)
        p1 = ld.element.nodeStart.position; p2 = ld.element.nodeEnd.position
        L = hypot(_as(p2[1] - p1[1], u"m"), _as(p2[2] - p1[2], u"m"),
                  _as(p2[3] - p1[3], u"m"))
        pos = ld.positions; w = ld._widths_m
        a = 0.0
        for i in 1:(length(pos) - 1)
            a += 0.5 * (w[i] + w[i + 1]) * (pos[i + 1] - pos[i]) * L
        end
        return a
    end
    @printf("\nper-slab applied-area vs cell net-area (ratio, should be 1.0):\n")
    for (si, slab) in enumerate(struc.slabs)
        cis = slab.cell_indices
        net = sum(_as(struc.cells[ci].area, u"m^2") for ci in cis; init = 0.0)
        app = 0.0
        for ci in cis
            for ld in get(struc.cell_tributary_loads, ci, Asap.TributaryLoad[])
                app += _tl_area(ld)
            end
        end
        flag = abs(app / max(net, 1e-9) - 1.0) > 0.01 ? "  <== LEAK" : ""
        @printf("  slab %-3d  cells %-2d  net %7.1f  applied %7.1f  ratio %.3f%s\n",
                si, length(cis), net, app, app / max(net, 1e-9), flag)
    end

    # Per-slab routing-path probe: which path handled each cell, and (for the
    # polygon-split path) the internal "gross" area the conservation gate checks
    # against vs the cell's true net area. A gate that passes at ratio ~1 while
    # the applied area exceeds cell.area means the gate's reference is inflated.
    skel = struc.skeleton
    frame_elements = model.frame_elements
    @printf("\nrouting-path probe per slab:\n")
    for (si, slab) in enumerate(struc.slabs)
        ci = first(slab.cell_indices)
        cell = struc.cells[ci]
        strips = SS._framed_slab_strip_geometry(struc, slab, frame_elements)
        poly = SS._drop_collinear_vertices(
            NTuple{2, Float64}[SS._vertex_xy_m(skel, v)
                               for v in skel.face_vertex_indices[cell.face_idx]])
        gross = SS._polygon_area_m2(poly)
        net = _as(cell.area, u"m^2")
        split = SS._cell_split_joist_loads(struc, cell, frame_elements)
        split_area = split === nothing ? 0.0 :
            sum(SS._tributary_area_m2, split; init = 0.0)
        path = strips !== nothing ? "STRIP($(length(strips)))" :
               split !== nothing ? "SPLIT" : "per-cell"
        @printf("  slab %-3d  %-10s  net %6.2f  gross(drop_collinear) %6.2f  split_area %6.2f  g/net %.3f\n",
                si, path, net, gross, split_area, gross / max(net, 1e-9))
    end

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
