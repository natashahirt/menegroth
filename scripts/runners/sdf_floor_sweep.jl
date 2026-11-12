# 2024 Slab Design Factors plans, one scene and one report per floor system.
#
# A right-click on the slab in the viewer lists every system that solved.
# Each report is the engineering schedule for that design, for an audit.
#
#     SS_ENABLE_VISUALIZATION=false julia --project=StructuralStudies \
#         scripts/runners/sdf_floor_sweep.jl
#
# Plans, chosen so a run finishes and a waffle pan still fits:
#   nova/e2c1            uniform 3.9 m panels. A 1.25 m pan fits three times,
#                        and the offcut is under half a module.
#   grid/x1y1            the rectangular grid that already completed a design.
#   topology/r2c1        a bay with a re-entrant joint.
#   star/e0c0            beams that meet at the center of a bay.
#   special/rhombus_8x12 a skewed four-column bay.
#
# Timber, post-tensioned, hollow-core, and non-composite deck throw
# UnsupportedFloorSystemError, so they are not in this sweep.

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "slab_design_factors", "study.jl"))

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const SCENE_DIR = joinpath(ROOT, "viewer", "public")
const REPORT_DIR = joinpath(ROOT, "logs", "sdf_floor_sweep")

"""1.25 m is a waffle pan. Three of them fit a nova/e2c1 panel."""
const WAFFLE_PAN_M = 1.25

const SWEEP_PLANS = [
    "nova/e2c1",
    "grid/x1y1",
    "topology/r2c1",
    "star/e0c0",
    "special/rhombus_8x12",
]

const SWEEP_SYSTEMS = [
    :one_way, :two_way, :waffle, :flat_plate, :flat_slab, :deck, :vault,
]

const SYSTEM_TITLE = Dict{Symbol, String}(
    :one_way => "one-way concrete",
    :two_way => "two-way concrete",
    :waffle => "waffle, 1.25 m pans",
    :flat_plate => "flat plate",
    :flat_slab => "flat slab",
    :deck => "composite deck",
    :vault => "vault",
)

"""File-safe plan name."""
_slug(name) = replace(name, "/" => "_")

"""
Parameters for one plan and one floor system.

Concrete systems share normal-weight 4000 psi concrete and T-beam flanges.
The composite deck is Melody Tan's 3VLI setup from [`system_parameters`](@ref).
The waffle is a two-way slab on a 1.25 m rib module. Flat plate and flat slab
keep the plan's beam lines and size them in concrete.
"""
function sweep_parameters(plan_name::AbstractString, system::Symbol)
    base = system === :deck ? :deck :
           system === :two_way || system === :waffle ? :two_way : :one_way
    params = system_parameters(plan_name, base)
    if system === :waffle
        params.floor = SR.TwoWayOptions()
        params.framing_opts = (
            materials = (concrete = SR.NWC_4000,),
            module_spacing = (WAFFLE_PAN_M, WAFFLE_PAN_M),
            analysis = :grillage,
            beam_options = SR.ConcreteBeamOptions(material = SR.NWC_4000, include_flange = true),
        )
    elseif system === :flat_plate
        params.floor = SR.FlatPlateOptions()
    elseif system === :flat_slab
        params.floor = SR.flat_slab()
    elseif system === :vault
        params.floor = SR.VaultOptions()
    end
    params.name = SYSTEM_TITLE[system]
    params.description = String(plan_name)
    params.max_iterations = 4
    params.skip_visualization = true
    return params
end

"""Write the engineering report, then the diagnostics the schedule does not carry."""
function _write_report(path, design, preamble::AbstractString)
    open(path, "w") do io
        println(io, preamble)
        println(io)
        try
            engineering_report(design; io = io)
        catch err
            println(io, "The engineering report could not be printed.")
            println(io, sprint(showerror, err))
        end
        println(io)
        println(io, "Diagnostics")
        isempty(design.diagnostics) && println(io, "(none)")
        for note in design.diagnostics
            println(io, note)
        end
    end
    return path
end

function _write_failure(path, preamble, err)
    open(path, "w") do io
        println(io, preamble)
        println(io)
        println(io, "This design did not finish.")
        println(io)
        println(io, sprint(showerror, err))
    end
    return path
end

"""Design every system of one plan. Solved designs go in one scene."""
function sweep_plan(plan_name::AbstractString)
    slug = _slug(plan_name)
    report_dir = joinpath(REPORT_DIR, slug)
    mkpath(report_dir)
    scene = joinpath(SCENE_DIR, "sdf_$(slug).mgscene")
    isfile(scene) && rm(scene)
    rows = NamedTuple[]
    struc = BuildingStructure(plan_skeleton(load_plan(plan_name)))
    for system in SWEEP_SYSTEMS
        title = SYSTEM_TITLE[system]
        println("  $plan_name  $title")
        report = joinpath(report_dir, "$(system).txt")
        preamble = "Plan: $plan_name\nSystem: $title\nScene: $(basename(scene))"
        t0 = time()
        local row
        try
            design = design_building(struc, sweep_parameters(plan_name, system))
            seconds = round(time() - t0; digits = 1)
            _write_report(report, design, preamble * "\nSeconds: $seconds\nStatus: solved")
            scene_id = ""
            scene_error = ""
            try
                scene_id = append_variant!(scene, design)
            catch err
                scene_error = sprint(showerror, err)
                open(report, "a") do io
                    println(io)
                    println(io, "The solved design was not added to the scene.")
                    println(io, scene_error)
                end
            end
            row = (;
                geometry = plan_name, system = string(system), title = title,
                status = "solved", seconds = seconds,
                scene = isempty(scene_id) ? "" : scene,
                variant = scene_id, report = report,
                error = scene_error,
            )
        catch err
            seconds = round(time() - t0; digits = 1)
            msg = replace(sprint(showerror, err), '\n' => ' ')
            _write_failure(report, preamble * "\nSeconds: $seconds\nStatus: failed", err)
            row = (;
                geometry = plan_name, system = string(system), title = title,
                status = "failed", seconds = seconds,
                scene = "", variant = "", report = report, error = msg,
            )
        end
        push!(rows, row)
        println("    $(row.status)  $(row.seconds)s")
    end
    return rows
end

mkpath(SCENE_DIR)
mkpath(REPORT_DIR)
println("Slab Design Factors floor sweep")
println("Reports: $REPORT_DIR")
rows = NamedTuple[]
for plan_name in SWEEP_PLANS
    append!(rows, sweep_plan(plan_name))
end
summary_path = joinpath(REPORT_DIR, "summary.csv")
CSV.write(summary_path, DataFrame(rows))
n_solved = count(row -> row.status == "solved", rows)
println("$(n_solved) solved, $(length(rows) - n_solved) failed. $summary_path")
