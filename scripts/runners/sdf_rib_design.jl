# Slab-on-rib designs, scenes, and engineering reports for the 2024 plans.
#
# One-way concrete, two-way concrete, waffle, and composite deck. Flat plate,
# flat slab, and vault are not run.
#
#     SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#         julia --project=StructuralStudies scripts/runners/sdf_rib_design.jl
#
# Named plans replace the default set.

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "slab_design_factors", "study.jl"))

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const SCENE_DIR = joinpath(ROOT, "viewer", "public")
const REPORT_DIR = joinpath(ROOT, "logs", "sdf_rib_design")
const WAFFLE_PAN_M = 1.25

const DESIGN_PLANS = [
    "nova/e3c4",
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

const SYSTEM_TITLE = Dict{Symbol, String}(
    :one_way => "one-way concrete",
    :two_way => "two-way concrete",
    :waffle => "waffle, 1.25 m pans",
    :deck => "composite deck",
)

_slug(name) = replace(name, "/" => "_")

"""Parameters for one plan and one slab-on-rib system."""
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
    params.name = SYSTEM_TITLE[system]
    params.description = String(plan_name)
    params.max_iterations = 4
    params.skip_visualization = true
    return params
end

"""
48 in T-beams on a member no longer than 6 m.

The large catalog's deepest section is 48 in. A span near 4 m that only
closes with that depth is reported and left as sized.
"""
function _deep_short_notes(design)
    notes = String[]
    for beam in design.structure.beams
        sec = try
            section(beam)
        catch
            nothing
        end
        sec === nothing && continue
        depth = try
            StructuralSizer.section_depth(sec)
        catch
            continue
        end
        din = depth isa Unitful.Quantity ? ustrip(u"inch", depth) : Float64(depth)
        L = beam.base.L
        Lm = L isa Unitful.Quantity ? ustrip(u"m", L) : Float64(L)
        din >= 47.5 && Lm <= 6.0 &&
            push!(notes, "depth $(round(din; digits = 1)) in on a $(round(Lm; digits = 2)) m member")
    end
    return notes
end

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

"""Design the rib systems of one plan. Solved designs share one scene."""
function design_plan(plan_name::AbstractString)
    slug = _slug(plan_name)
    report_dir = joinpath(REPORT_DIR, slug)
    mkpath(report_dir)
    scene = joinpath(SCENE_DIR, "sdf_$(slug).mgscene")
    isfile(scene) && rm(scene)
    rows = NamedTuple[]
    for system in RIB_SYSTEMS
        title = SYSTEM_TITLE[system]
        println("  $plan_name  $title")
        report = joinpath(report_dir, "$(system).txt")
        preamble = "Plan: $plan_name\nSystem: $title\nScene: $(basename(scene))"
        t0 = time()
        try
            struc = BuildingStructure(plan_skeleton(load_plan(plan_name)))
            design = design_building(struc, rib_parameters(plan_name, system))
            seconds = round(time() - t0; digits = 1)
            deep = _deep_short_notes(design)
            extra = isempty(deep) ? "" : "\nDeep short members:\n" * join(deep, "\n")
            _write_report(report, design, preamble * "\nSeconds: $seconds\nStatus: solved" * extra)
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
            push!(rows, (;
                geometry = plan_name, system = string(system), title = title,
                status = "solved", seconds = seconds,
                scene = isempty(scene_id) ? "" : scene,
                variant = scene_id, report = report,
                error = scene_error, deep = join(deep, "; "),
            ))
            println("    solved  ", seconds, "s",
                    isempty(deep) ? "" : "  DEEP SHORT: $(length(deep))")
        catch err
            seconds = round(time() - t0; digits = 1)
            msg = sprint(showerror, err)
            open(report, "w") do io
                println(io, preamble)
                println(io)
                println(io, "This design did not finish.")
                println(io)
                println(io, msg)
            end
            push!(rows, (;
                geometry = plan_name, system = string(system), title = title,
                status = "failed", seconds = seconds,
                scene = "", variant = "", report = report,
                error = replace(msg, '\n' => ' '), deep = "",
            ))
            println("    failed  ", seconds, "s")
            occursin("No feasible sections", msg) && rethrow()
        end
    end
    return rows
end

function main(args)
    plans = isempty(args) ? DESIGN_PLANS : String.(args)
    mkpath(REPORT_DIR)
    stamp = Dates.format(now(), "yyyymmdd_HHMMSS")
    csv_path = joinpath(REPORT_DIR, "design_$(stamp).csv")
    println("Rib design  ", length(plans), " plans × ", length(RIB_SYSTEMS), " systems")
    println("Log: $csv_path")
    open(csv_path, "w") do io
        println(io, "geometry,system,status,seconds,scene,variant,report,deep,error")
        for plan_name in plans
            for row in design_plan(plan_name)
                err = replace(row.error, '"' => "'")
                deep = replace(row.deep, '"' => "'")
                println(io, row.geometry, ",", row.system, ",", row.status, ",",
                        row.seconds, ",", row.scene, ",", row.variant, ",",
                        row.report, ",\"", deep, "\",\"", err, "\"")
                flush(io)
            end
        end
    end
    println("Wrote ", csv_path)
end

"""
Design the waffle of one plan again and replace that variant in its scene.

The other systems in the file stay. The new scene is the grillage frame the
waffle was solved on.
"""
function refresh_waffle_scene(plan_name::AbstractString)
    scene = joinpath(SCENE_DIR, "sdf_$(_slug(plan_name)).mgscene")
    isfile(scene) || error("no scene at $scene")
    struc = BuildingStructure(plan_skeleton(load_plan(plan_name)))
    design = design_building(struc, rib_parameters(plan_name, :waffle))
    label = SYSTEM_TITLE[:waffle]
    index = read_variant_index(scene)
    waffle_ids = String[]
    for variant in index["variants"]
        name = string(get(get(variant["params"], "name", Dict()), "label", ""))
        name == label && push!(waffle_ids, variant["id"])
    end
    isempty(waffle_ids) && @warn "no waffle variant to replace" scene
    if length(waffle_ids) == length(index["variants"])
        # The file is only this waffle. A drop would leave it empty.
        tmp = scene * ".next"
        isfile(tmp) && rm(tmp)
        id = append_variant!(tmp, design)
        mv(tmp, scene; force = true)
    else
        for old in waffle_ids
            drop_variant!(scene, old)
        end
        id = append_variant!(scene, design)
        compact_variants!(scene)
    end
    shells = length(design.asap_model.shell_elements)
    frames = length(design.asap_model.frame_elements)
    println("replaced $(join(waffle_ids, ", ")) with $id")
    println("scene $scene  frames=$frames  shells=$shells")
    return id
end

"""One line per framing level, plus the analysis-model counts."""
function _framing_summary(design)
    lines = String[]
    for (si, slab) in enumerate(design.structure.slabs)
        for fl in slab.framing_levels
            pat = fl.pattern
            kind = pat isa ModularRibPattern ? "module" :
                   pat isa LinearAxisPattern ? "joists" : string(typeof(pat))
            push!(lines, "slab $si  $kind  analysis=$(fl.analysis)  spacing=$(pat isa ModularRibPattern || pat isa LinearAxisPattern ? pat.spacing : nothing)")
            rr = fl.rib_report
            if rr !== nothing
                push!(lines, "    rib stem $(rr.stem)  sets=$(rr.n_sets)  failed=$(rr.n_failed)  " *
                             "carbon=$(round(ustrip(rr.carbon); digits = 0)) kgCO2e" *
                             (isempty(rr.reasons) ? "" : "  reasons=$(rr.reasons)"))
                d = rr.deflection
                d === nothing || push!(lines,
                    "    deflection ok=$(d.ok)  live=$(round(d.live.ratio; digits = 2))  " *
                    "long-term($(d.limit))=$(round(d.long_term.ratio; digits = 2))  " *
                    "ρ′=$(round(get(rr, :comp_steel_ratio, 0.0); digits = 4))  " *
                    "l=$(round(d.long_term.l; digits = 2)) m  bays=$(d.n_bays)  converged=$(d.converged)")
                rr.screen === nothing || for t in rr.screen
                    push!(lines, "      stem $(t.stem)  strength=$(t.strength)  " *
                                 "carbon=$(round(ustrip(t.carbon); digits = 0))  deflection=$(t.deflection)")
                end
            end
            isempty(fl.solid_heads) && continue
            bays = [length(h.bays) for h in fl.solid_heads]
            rep = fl.solid_head_report
            if rep === nothing
                push!(lines, "    solid bays $bays")
            else
                r2(v) = [round(x; digits = 2) for x in v]
                push!(lines, "    solid bays $bays  stop=$(rep.stop)  ok=$(rep.ok)  steps=$(rep.steps)  ratios=$(r2(rep.ratios))")
                if hasproperty(rep, :column_ratios)
                    push!(lines, "    seeded $(rep.seeded_bays)  after void closure $(rep.closed_bays)  " *
                                 "governing $(rep.governing)")
                    push!(lines, "    punching $(r2(rep.column_ratios))  one-way $(r2(rep.one_way_ratios))  " *
                                 "hogging $(r2(rep.hogging_ratios))")
                    push!(lines, "    governing rib bw=$(r2(rep.rib_bw_in)) in  d=$(r2(rep.rib_d_in)) in  " *
                                 "head d=$(round(rep.head_d_in; digits = 1)) in")
                end
            end
        end
    end
    model = design.asap_model
    if model === nothing && design.structure.asap_model !== nothing
        model = design.structure.asap_model
    end
    if model === nothing
        push!(lines, "frames=(no analysis model)  shells=(no analysis model)")
    else
        push!(lines, "frames=$(length(model.frame_elements))  shells=$(length(model.shell_elements))")
    end
    s = design.summary
    push!(lines, "pass=$(s.all_checks_pass)  critical=$(s.critical_element)  ratio=$(s.critical_ratio)")
    return join(lines, "\n")
end

"""
Loose concrete waffle, 30 in waffle, and the loose module as steel deck.

The loose concrete module cannot meet ACI 318-11 §8.13.3, so it is designed
as one-way joists. The 30 in module stays a waffle. The steel module is not
§8.13 construction, so it is steel joists and deck.
"""
function design_grid_qualification(plan_name::AbstractString = "grid/x1y1";
                                   only::Union{Nothing, AbstractString} = nothing,
                                   scene_file::Union{Nothing, AbstractString} = nothing)
    scene = scene_file === nothing ?
        joinpath(SCENE_DIR, "sdf_$(_slug(plan_name))_qualification.mgscene") :
        String(scene_file)
    isfile(scene) && rm(scene)
    wanted = only === nothing ? nothing : Set(strip(s) for s in split(only, ",") if !isempty(strip(s)))
    report_dir = joinpath(REPORT_DIR, _slug(plan_name) * "_qualification")
    mkpath(report_dir)
    pan_in = uconvert(u"m", 30.0u"inch")
    jobs = [
        ("loose_waffle", rib_parameters(plan_name, :waffle)),
        ("dense_waffle", let p = rib_parameters(plan_name, :waffle)
            p.framing_opts = merge(p.framing_opts, (module_spacing = (pan_in, pan_in),))
            p.name = "waffle, 30 in pans"
            p
        end),
        ("steel_joists", let p = system_parameters(plan_name, :deck)
            p.framing_opts = (
                materials = (steel = SR.A992_Steel,),
                module_spacing = (WAFFLE_PAN_M, WAFFLE_PAN_M),
                analysis = :grillage,
                beam_options = p.beams,
            )
            p.name = "steel joists, 1.25 m"
            p.description = String(plan_name)
            p.max_iterations = 4
            p.skip_visualization = true
            p
        end),
    ]
    for (tag, params) in jobs
        wanted === nothing || tag in wanted || continue
        params.skip_visualization = false
        println("  $plan_name  $(params.name)")
        t0 = time()
        report = joinpath(report_dir, "$tag.txt")
        try
            struc = BuildingStructure(plan_skeleton(load_plan(plan_name)))
            design = design_building(struc, params)
            seconds = round(time() - t0; digits = 1)
            summary = _framing_summary(design)
            println(summary)
            println("    ", seconds, "s")
            println(params.description)
            _write_report(report, design,
                "Plan: $plan_name\nSystem: $(params.name)\nSeconds: $seconds\n\n$summary\n")
            try
                append_variant!(scene, design)
                println("    scene $scene")
            catch err
                msg = sprint(showerror, err)
                println("    scene failed")
                println(msg)
                open(report, "a") do io
                    println(io)
                    println(io, "Scene write failed")
                    println(io, msg)
                end
            end
        catch err
            seconds = round(time() - t0; digits = 1)
            msg = sprint(showerror, err, catch_backtrace())
            println("    failed  ", seconds, "s")
            println(msg)
            open(report, "w") do io
                println(io, "Plan: $plan_name\nSystem: $(params.name)\nSeconds: $seconds")
                println(io, params.description)
                println(io)
                println(io, msg)
            end
        end
    end
    return scene
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
