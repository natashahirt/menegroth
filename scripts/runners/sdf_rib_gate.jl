# Geometry gate for slab-on-rib floors on the 2024 Slab Design Factors plans.
#
# prepare! builds the frame, the ribs, and the deck fill beams. One-way then
# checks that every span has a beam or a wall. Composite deck checks that the
# span used for the unshored table is within the published one-span length.
#
#     SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#         julia --project=StructuralStudies scripts/runners/sdf_rib_gate.jl
#
#     ... sdf_rib_gate.jl --all          every plan, geometry only
#     ... sdf_rib_gate.jl --design       full design_building on the probe set
#     ... sdf_rib_gate.jl --all --design
#
# Named plans replace the probe set: sdf_rib_gate.jl nova/e2c1 grid/x1y1

using Dates

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "slab_design_factors", "study.jl"))

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const GATE_DIR = joinpath(ROOT, "logs", "sdf_rib_gate")
const WAFFLE_PAN_M = 1.25

const PROBE_PLANS = [
    "nova/e2c1",
    "grid/x1y1",
    "topology/r2c1",
    "star/e0c0",
    "special/rhombus_8x12",
    "validation/office",
    "validation/school",
    "validation/warehouse",
    "special/tan_121_seaport",
]

const RIB_SYSTEMS = [:one_way, :two_way, :waffle, :deck]

"""Every geometry file, as the name `load_plan` expects."""
function all_plan_names()
    names = String[]
    for (dir, _, files) in walkdir(SDF_ROOT)
        for file in files
            endswith(file, ".json") || continue
            rel = relpath(joinpath(dir, file), SDF_ROOT)
            push!(names, rel[1:end - 5])
        end
    end
    return sort!(names)
end

"""
Parameters for one plan and one slab-on-rib system.

Concrete floors are RC T-beams. The waffle is a two-way topping on a 1.25 m
rib module. The deck is Tan's 3VLI setup from [`system_parameters`](@ref).
"""
function rib_parameters(plan_name::AbstractString, system::Symbol)
    base = system === :deck ? :deck :
           system === :two_way || system === :waffle ? :two_way : :one_way
    params = system_parameters(plan_name, base)
    if system === :waffle
        params.floor = SR.TwoWayOptions()
        params.framing_opts = (
            materials = (concrete = SR.NWC_4000,),
            module_spacing = (WAFFLE_PAN_M, WAFFLE_PAN_M),
            analysis = :grillage,
            beam_options = SR.ConcreteBeamOptions(material = SR.NWC_4000,
                                                   include_flange = true),
        )
    end
    params.name = string(system)
    params.description = String(plan_name)
    params.max_iterations = 4
    params.skip_visualization = true
    return params
end

"""One-way spans have a beam or a wall, and a deck span fits the unshored table."""
function _assert_rib_geometry(struc, params, system::Symbol)
    if system === :one_way
        for slab in struc.slabs
            slab.floor_type == :one_way || continue
            StructuralSizer._slab_span_support(struc, slab)
        end
    elseif system === :deck
        limit = StructuralSizer.max_unshored_simple_span(params.floor.deck_profile)
        for (i, cell) in enumerate(struc.cells)
            cell.floor_type in (:grade, :unknown) && continue
            span = StructuralSynthesizer._cell_deck_span(struc, i)
            span <= limit || throw(ArgumentError(
                "deck cell $i spans $(round(u"ft", span; digits=2)); " *
                "the longest published one-span unshored length is " *
                "$(round(u"ft", limit; digits=2))"))
        end
    end
    return length(get(struc.skeleton.groups_edges, :joists, Int[]))
end

"""prepare! and the geometry checks. `--design` also runs `design_building`."""
function gate_plan(plan_name::AbstractString, system::Symbol, design::Bool)
    params = rib_parameters(plan_name, system)
    struc = BuildingStructure(plan_skeleton(load_plan(plan_name)))
    t0 = time()
    if design
        design_building(struc, params)
        return (status = "solved", seconds = round(time() - t0; digits = 1),
                joists = 0, error = "")
    end
    prepare!(struc, params)
    njoist = _assert_rib_geometry(struc, params, system)
    return (status = "ready", seconds = round(time() - t0; digits = 1),
            joists = njoist, error = "")
end

function main(args)
    design = "--design" in args
    every = "--all" in args
    named = filter(a -> !startswith(a, "--"), args)
    plans = !isempty(named) ? named : every ? all_plan_names() : PROBE_PLANS
    mkpath(GATE_DIR)
    stamp = Dates.format(now(), "yyyymmdd_HHMMSS")
    path = joinpath(GATE_DIR, (design ? "design_" : "geometry_") * stamp * ".csv")
    println(design ? "Full design" : "Geometry gate",
            "  ", length(plans), " plans × ", length(RIB_SYSTEMS), " systems")
    println("Log: $path")
    open(path, "w") do io
        println(io, "geometry,system,status,seconds,joists,error")
        n_ok = 0
        n_bad = 0
        for plan_name in plans, system in RIB_SYSTEMS
            print("  $plan_name  $system … ")
            local row
            try
                row = gate_plan(plan_name, system, design)
                n_ok += 1
            catch err
                n_bad += 1
                msg = replace(sprint(showerror, err), '\n' => ' ')
                row = (status = "failed", seconds = 0.0, joists = 0, error = msg)
                open(joinpath(GATE_DIR, stamp * "_" * replace(plan_name, "/" => "_") *
                              "_" * string(system) * ".txt"), "w") do trace
                    println(trace, sprint(showerror, err))
                    println(trace)
                    Base.show_backtrace(trace, catch_backtrace())
                end
            end
            println(row.status, "  ", row.seconds, "s")
            err = replace(row.error, '"' => "'")
            println(io, plan_name, ",", system, ",", row.status, ",",
                    row.seconds, ",", row.joists, ",\"", err, "\"")
            flush(io)
        end
        println(n_ok, " ok, ", n_bad, " failed. ", path)
    end
end

main(ARGS)
