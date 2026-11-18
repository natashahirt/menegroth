#=
Ordinary-wall thickness jump on the four-story core office.

Gravity strength combinations only. Wind and earthquake are not invented.
Starts at 4 in so ACI 318-19 Table 11.3.1.1 (min(lw, lc)/25 on the 8 m
core walls, lc = 3.6 m) has room to fire. `jump_wall_thickness` is the
production default.

    julia --project=StructuralSynthesizer scripts/runners/core_office_wall_jump.jl [start_inches]
=#

using Printf
using Unitful
using StructuralSynthesizer

include(joinpath(@__DIR__, "core_office_geometry.jl"))

const T0_IN = isempty(ARGS) ? 4.0 : parse(Float64, ARGS[1])
const T0 = uconvert(u"m", T0_IN * u"inch")

function wall_line(w)
    return @sprintf("(%.1f,%.1f)–(%.1f,%.1f) story %d  t=%.0f mm  ρl=%.4f  ρt=%.4f",
                    w.x1, w.y1, w.x2, w.y2, w.story,
                    ustrip(u"mm", w.thickness), w.ρl, w.ρt)
end

function count_fails(result)
    n = 0
    for records in values(result.checks)
        n += count(r -> !r.passed, records)
    end
    return n
end

function print_fails(struc, result; limit=40)
    n = 0
    for (idx, records) in sort(collect(result.checks); by=first)
        fails = filter(r -> !r.passed, records)
        isempty(fails) && continue
        println("wall ", idx, "  ", wall_line(struc.walls[idx]))
        for r in fails
            n += 1
            n > limit && continue
            println(@sprintf("  FAIL %-32s %s/%s  demand %.4g  capacity %.4g  ratio %.3f  %s",
                             r.check, r.case, r.combination,
                             r.demand, r.capacity, r.ratio, r.clause))
        end
    end
    n > limit && println("  … ", n - limit, " more failing records")
    return n
end

function run()
    println("Core office ordinary-wall thickness jump (gravity combinations)")
    println("  start t = ", T0, "  (", round(ustrip(u"inch", T0); digits=2), " in)")
    flush(stdout)

    skel = core_office_skeleton()
    struc = BuildingStructure(skel)
    t_init = @elapsed initialize!(struc;
        floor_type=:flat_plate,
        floor_opts=FlatPlateOptions(),
        material=NWC_4000,
        wall_thickness=T0)
    for wall in struc.walls
        wall.concrete = RC_4000_60.concrete
    end
    println("  walls: ", length(struc.walls),
            "  initialize: ", round(t_init; digits=1), " s")
    flush(stdout)

    params = DesignParameters(
        name="core-office-wall-jump",
        materials=MaterialOptions(concrete=RC_4000_60.concrete, rebar=Rebar_60),
        wall_thickness=T0,
        jump_wall_thickness=true,
        diaphragm_mode=:rigid,
        skip_visualization=true,
    )

    t_mesh = @elapsed to_asap!(struc; params, diaphragms=:rigid)
    t0 = shared_wall_thickness(struc.walls)
    println("  mesh: ", round(t_mesh; digits=1), " s  shared t0 = ", t0)
    flush(stdout)

    result = nothing
    t_stage = 0.0
    try
        t_stage = @elapsed result = design_ordinary_walls!(struc, params)
    catch err
        println("DESIGN THREW:")
        showerror(stdout, err, catch_backtrace())
        println()
        exit(1)
    end

    t_final = shared_wall_thickness(struc.walls)
    nfail = count_fails(result)
    println("  stage: ", round(t_stage; digits=1), " s")
    println("  t0     = ", t0, "  (", round(ustrip(u"inch", t0); digits=2), " in)")
    println("  t_final= ", t_final, "  (", round(ustrip(u"inch", t_final); digits=2), " in)")
    if t_final === nothing
        println("  jump: mixed thickness after the stage")
    elseif ustrip(u"m", t_final) > ustrip(u"m", t0) + 1e-4
        println("  jump: yes  Δt = ", t_final - t0)
    else
        println("  jump: no (thickness already passed)")
    end
    println("  failing records: ", nfail)
    print_fails(struc, result)
    for w in struc.walls
        println("  ", wall_line(w))
    end
    return result
end

run()
