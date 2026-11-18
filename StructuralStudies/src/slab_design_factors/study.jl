# Slab Design Factors geometries through design_building.
#
# One framing plan is designed three ways: a one-way slab on RC T-beams, a
# two-way slab on RC T-beams, and a composite steel deck on composite steel
# beams. Validation plans also carry Melody Tan's transcribed ETABS sections,
# one per beam line.
#
#   include this file, then
#   run_study(["grid/x1y1"], [:one_way, :two_way])
#   run_study(VALIDATION_PLANS, [:deck])

include(joinpath(@__DIR__, "..", "init.jl"))

using JSON3
using Meshes
using Printf

include(joinpath(@__DIR__, "geometry.jl"))
include(joinpath(@__DIR__, "systems.jl"))

const RESULTS_DIR = joinpath(@__DIR__, "results")

"""Smallest parametric plan that completed a concrete design in the first probe."""
const SMOKE_PLANS = ["grid/x1y1"]

"""Plans with a transcribed ETABS section list."""
const VALIDATION_PLANS = ["validation/office", "validation/school", "validation/warehouse"]

const SYSTEMS = [:one_way, :two_way, :deck]

"""Pounds per foot from an AISC-style name, or `nothing`."""
function designation_plf(name::AbstractString)
    c = canonical_w(name)
    startswith(c, "W") || return nothing
    parts = split(c[2:end], 'X')
    length(parts) == 2 || return nothing
    return tryparse(Float64, String(parts[2]))
end

"""Plan coordinates of a beam's segment ends, and its average elevation in meters."""
function _beam_plan(struc, beam)
    pts = NTuple{2, Float64}[]
    zsum = 0.0
    n = 0
    for si in SS.segment_indices(beam)
        for v in struc.skeleton.edge_indices[struc.segments[si].edge_idx]
            c = Meshes.coords(struc.skeleton.vertices[v])
            push!(pts, (ustrip(u"m", c.x), ustrip(u"m", c.y)))
            zsum += ustrip(u"m", c.z)
            n += 1
        end
    end
    return pts, n == 0 ? 0.0 : zsum / n
end

"""True when `p` lies on the segment from `a` to `b`."""
function _on_segment(p::NTuple{2, Float64}, a::NTuple{2, Float64}, b::NTuple{2, Float64};
                     tol::Float64 = 1e-5)
    dx, dy = b[1] - a[1], b[2] - a[2]
    L2 = dx * dx + dy * dy
    L2 < 1e-18 && return hypot(p[1] - a[1], p[2] - a[2]) <= tol
    t = ((p[1] - a[1]) * dx + (p[2] - a[2]) * dy) / L2
    (-1e-4 <= t <= 1 + 1e-4) || return false
    px, py = a[1] + t * dx, a[2] + t * dy
    return (p[1] - px)^2 + (p[2] - py)^2 <= tol^2
end

"""
Floor-level beams lying on each plan line, in file order.

A line that was split at a joint contributes one beam per piece. Grade copies
of the plan are left out.
"""
function floor_beams(struc, plan::SdfPlan)
    H = ustrip(u"m", uconvert(u"m", STORY_HEIGHT))
    located = Tuple{Any, Vector{NTuple{2, Float64}}}[]
    for b in struc.beams
        pts, z = _beam_plan(struc, b)
        abs(z - H) < 1e-2 || continue
        push!(located, (b, pts))
    end
    out = Vector{Vector{Any}}()
    for (ia, ib) in plan.lines
        a, b = plan.xy[ia], plan.xy[ib]
        hits = Any[beam for (beam, pts) in located if all(p -> _on_segment(p, a, b), pts)]
        push!(out, hits)
    end
    return out
end

"""Plan length of one beam line, in feet."""
function line_length_ft(plan::SdfPlan, i::Int)
    a, b = plan.lines[i]
    dx = plan.xy[a][1] - plan.xy[b][1]
    dy = plan.xy[a][2] - plan.xy[b][2]
    return sqrt(dx^2 + dy^2) * 3.280839895
end

"""Summary row plus one row per floor beam."""
function _collect(plan::SdfPlan, system::Symbol, design, seconds::Float64)
    struc = design.structure
    beams = floor_beams(struc, plan)
    loads = plan_loads(plan.name)
    depths = Float64[]
    floor_types = String[]
    for slab in struc.slabs
        push!(floor_types, string(slab.floor_type))
        slab.result === nothing && continue
        push!(depths, ustrip(u"inch", SR.total_depth(slab.result)))
    end
    ours_lb = 0.0
    etabs_lb = 0.0
    compared = 0
    matched = 0
    unsized = 0
    beam_rows = NamedTuple[]
    for (i, pieces) in enumerate(beams)
        isempty(pieces) && (unsized += 1)
        names = String[]
        for beam in pieces
            sec = SS.section(beam)
            sec === nothing && (unsized += 1; continue)
            sec.name === nothing && continue
            plf = designation_plf(sec.name)
            L = ustrip(u"ft", SS.member_length(beam))
            plf !== nothing && (ours_lb += plf * L)
            push!(names, sec.name)
        end
        ours = join(unique(names), "+")
        L = line_length_ft(plan, i)
        etabs = isempty(plan.sections) ? nothing : plan.sections[i]
        etabs_name = etabs === nothing ? "" : w_name(etabs[1], etabs[2])
        etabs === nothing || (etabs_lb += etabs[2] * L)
        same = ""
        if !isempty(plan.sections) && system === :deck && etabs !== nothing && !isempty(ours)
            compared += 1
            same = all(n -> canonical_w(n) == etabs_name, names) ? "yes" : "no"
            same == "yes" && (matched += 1)
        end
        push!(beam_rows, (;
            geometry = plan.name, system = string(system), line = i,
            length_ft = round(L; digits = 2),
            section = ours, etabs = etabs_name, match = same,
        ))
    end
    summary = (;
        geometry = plan.name,
        occupancy = loads.occupancy,
        ll_psf = loads.ll,
        sdl_psf = loads.sdl,
        n_nodes = length(plan.xy),
        n_beams = length(plan.lines),
        n_columns = length(plan.columns),
        n_holes = length(plan.holes),
        system = string(system),
        status = "ok",
        seconds = round(seconds; digits = 1),
        floor_types = join(unique(floor_types), ","),
        depth_in = isempty(depths) ? "" : @sprintf("%.1f–%.1f", extrema(depths)...),
        n_floor_beams = sum(length, beams; init = 0),
        n_unsized = unsized,
        n_diagnostics = length(design.diagnostics),
        steel_lb = round(ours_lb; digits = 0),
        etabs_lb = isempty(plan.sections) ? NaN : round(etabs_lb; digits = 0),
        n_compared = compared,
        n_matched = matched,
        error = "",
    )
    return summary, beam_rows
end

function _failed(plan::SdfPlan, system::Symbol, err, seconds::Float64)
    loads = plan_loads(plan.name)
    msg = replace(first(sprint(showerror, err), 500), '\n' => ' ')
    summary = (;
        geometry = plan.name, occupancy = loads.occupancy,
        ll_psf = loads.ll, sdl_psf = loads.sdl,
        n_nodes = length(plan.xy), n_beams = length(plan.lines),
        n_columns = length(plan.columns), n_holes = length(plan.holes),
        system = string(system), status = "fail",
        seconds = round(seconds; digits = 1),
        floor_types = "", depth_in = "", n_floor_beams = 0, n_unsized = 0,
        n_diagnostics = 0, steel_lb = 0.0, etabs_lb = NaN,
        n_compared = 0, n_matched = 0, error = msg,
    )
    return summary, NamedTuple[]
end

"""Design one plan as one floor system. A thrown design is a failed row, not a thrown study."""
function run_case(name::AbstractString, system::Symbol)
    plan = load_plan(name)
    t0 = time()
    try
        struc = BuildingStructure(plan_skeleton(plan))
        design = design_building(struc, system_parameters(name, system); restore = false)
        return _collect(plan, system, design, time() - t0)
    catch err
        return _failed(plan, system, err, time() - t0)
    end
end

"""
    run_study(names, systems) -> (summary, beams)

Design each plan as each system and write a summary CSV and a per-beam CSV
under `results/`. Transcribed sections are compared on the `:deck` system only.
"""
function run_study(names::Vector{<:AbstractString}=SMOKE_PLANS,
                   systems::Vector{Symbol}=SYSTEMS)
    print_header("Slab Design Factors geometries")
    summaries = NamedTuple[]
    beams = NamedTuple[]
    for name in names, system in systems
        println("  $name  $system")
        summary, rows = run_case(name, system)
        push!(summaries, summary)
        append!(beams, rows)
        println("    $(summary.status)  $(summary.seconds)s  $(summary.error)")
    end
    summary_path = output_filename("sdf_summary", RESULTS_DIR)
    beam_path = output_filename("sdf_beams", RESULTS_DIR)
    CSV.write(summary_path, DataFrame(summaries))
    isempty(beams) || CSV.write(beam_path, DataFrame(beams))
    n_fail = count(s -> s.status == "fail", summaries)
    write_run_meta(summary_path; note = "Slab Design Factors floor-system study",
                   extra = "beams=$(basename(beam_path))")
    print_footer(length(summaries) - n_fail, n_fail, summary_path)
    return DataFrame(summaries), DataFrame(beams)
end

"""Plans that exercise diagonals, T-junctions, and holes. `grid/x0y0` is the rectangle."""
const COVERAGE_PLANS = [
    "grid/x0y0",
    "grid/x1y1",
    "topology/r2c1",
    "topology/r7c1",
    "nova/e1c1",
    "star/e0c0",
    "star/e10c2",
    "special/rhombus_8x12",
    "special/star_8x12",
    "special/school",
    "validation/office",
    "validation/school",
    "validation/warehouse",
]

"""Tributary area of one beam, in square meters."""
function _beam_area_m2(beam)
    prof = beam.tributary_profile
    prof === nothing && return 0.0
    w = SS.tributary_average(prof)
    wm = w isa Unitful.Quantity ? ustrip(u"m", w) : Float64(w)
    L = SS.member_length(beam)
    Lm = L isa Unitful.Quantity ? ustrip(u"m", L) : Float64(L)
    return wm * Lm
end

"""
    tributary_balance(name, system) -> NamedTuple

Initialize one plan and compare three areas, all in square meters:

- `gross`: floor faces before openings
- `net`: the cell areas the floor load is applied to
- `polygons`: the sum of the per-edge tributary polygons
- `beams`: the same area after it is written onto the floor beams

A partition with no overlap and no gap has `polygons ≈ gross` and `beams ≈ polygons`.
`net` is smaller than `gross` by the openings. The service load (superimposed
dead plus live, no self-weight yet) is that pressure times `net` on the cells.
"""
function tributary_balance(name::AbstractString, system::Symbol)
    plan = load_plan(name)
    struc = BuildingStructure(plan_skeleton(plan))
    params = system_parameters(name, system)
    initialize!(struc; loads = params.loads,
                floor_type = SR.floor_symbol(params.floor),
                floor_opts = params.floor)
    compute_member_tributaries!(struc)
    gross = 0.0
    net = 0.0
    polygons = 0.0
    load_kN = 0.0
    worst = 0.0
    ncell = 0
    pressure = nothing
    for (i, cell) in enumerate(struc.cells)
        cell.floor_type == :grade && continue
        ncell += 1
        a = ustrip(u"m^2", cell.area)
        g = ustrip(u"m^2", face_area(struc.skeleton, cell.face_idx))
        tribs = cell_edge_tributaries(struc, i)
        ta = tribs === nothing ? 0.0 : sum(t.area for t in tribs; init = 0.0)
        p = ustrip(u"kN/m^2", cell.sdl) + ustrip(u"kN/m^2", cell.live_load)
        pressure === nothing && (pressure = p)
        gross += g
        net += a
        polygons += ta
        load_kN += p * a
        worst = max(worst, abs(ta - a))
    end
    H = ustrip(u"m", uconvert(u"m", STORY_HEIGHT))
    beams = 0.0
    nbeam = 0
    nbare = 0
    for b in struc.beams
        _, z = _beam_plan(struc, b)
        abs(z - H) < 1e-2 || continue
        nbeam += 1
        area = _beam_area_m2(b)
        area <= 1e-8 && (nbare += 1)
        beams += area
    end
    beam_kN = pressure === nothing ? 0.0 : pressure * beams
    return (;
        geometry = plan.name, system = string(system),
        n_cells = ncell, n_beams = nbeam, n_bare = nbare,
        gross_m2 = gross, net_m2 = net, polygon_m2 = polygons, beam_m2 = beams,
        worst_cell_m2 = worst,
        cell_kN = load_kN, beam_kN = beam_kN,
        n_edges = length(get(struc.skeleton.groups_edges, :beams, Int[])),
        n_lines = length(plan.lines),
    )
end

"""Run [`tributary_balance`](@ref) on each plan and system. A thrown initialize is a failed row."""
function coverage_report(names = COVERAGE_PLANS, systems = [:one_way, :two_way])
    rows = NamedTuple[]
    for name in names, system in systems
        try
            row = tributary_balance(name, system)
            push!(rows, (; row..., status = "ok", error = ""))
            @printf("  %-24s %-8s  gross %8.2f  net %8.2f  poly %8.2f  beams %8.2f  load %6.0f / %6.0f kN\n",
                    name, system, row.gross_m2, row.net_m2, row.polygon_m2, row.beam_m2,
                    row.cell_kN, row.beam_kN)
        catch err
            msg = replace(first(sprint(showerror, err), 240), '\n' => ' ')
            push!(rows, (;
                geometry = name, system = string(system),
                n_cells = 0, n_beams = 0, n_bare = 0,
                gross_m2 = NaN, net_m2 = NaN, polygon_m2 = NaN, beam_m2 = NaN,
                worst_cell_m2 = NaN, cell_kN = NaN, beam_kN = NaN,
                n_edges = 0, n_lines = 0, status = "fail", error = msg,
            ))
            println("  $name  $system  FAIL  $msg")
        end
    end
    return DataFrame(rows)
end
