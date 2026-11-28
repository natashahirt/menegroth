# Run one array task: one entry of tasks(EXPERIMENT) from experiments.jl.
#
#   julia --project=StructuralStudies run_task.jl EXPERIMENT INDEX RUN_DIR
#
# A task runs one method at a time. Each method's designs (flat plate and
# flat slab for a heatmap task) are saved under RUN_DIR/EXPERIMENT/parts/ with
# their own .done marker as soon as they finish, so a task stopped by the
# 12 h limit or preemption resumes at the next unfinished method.
#
# When every method is done, the parts are joined into RUN_DIR/EXPERIMENT/:
#   <id>.csv, <id>_columns.csv, <id>_slabs.csv, <id>_failures.csv  results
#   <id>.csv.meta.json                                             git provenance
#   <id>.task.json                                                 Slurm, host, timing
#   <id>.done                                                      written last
# A task with a .done file is skipped. An exception leaves <id>.error and
# exits 1; the methods finished before it are kept.

using Dates

length(ARGS) == 3 || error("usage: run_task.jl EXPERIMENT INDEX RUN_DIR")
const EXPERIMENT = ARGS[1]
const INDEX      = parse(Int, ARGS[2])
const RUN_DIR    = ARGS[3]
const REPO       = normpath(joinpath(@__DIR__, "..", "..", ".."))

include(joinpath(@__DIR__, "experiments.jl"))
const TASK  = tasks(EXPERIMENT)[INDEX]
const OUT   = joinpath(RUN_DIR, EXPERIMENT)
const PARTS = joinpath(OUT, "parts")
mkpath(PARTS)
const DONE  = joinpath(OUT, "$(TASK.id).done")
const ERROR_FILE = joinpath(OUT, "$(TASK.id).error")
if isfile(DONE)
    println("skip $(TASK.id): done")
    exit(0)
end
rm(ERROR_FILE; force = true)

t_start = time()
started = now()
println("task $(EXPERIMENT)[$(INDEX)] $(TASK.id) on $(gethostname()) at $(started)")

include(joinpath(REPO, "StructuralStudies", "src", "flat_plate_methods",
                 "building_scale_analysis.jl"))
t_loaded = time()

const FEA_BASES = [
    ("FEA (frame)", (pattern_loading = true, pattern_mode = :efm_amp, design_approach = :frame)),
    ("FEA (area)",  (pattern_loading = true, pattern_mode = :efm_amp, design_approach = :area,
                     moment_transform = :wood_armer)),
]
const FEA_VARIANTS = [
    ("base",               (;)),
    ("nodal smoothing",    (field_smoothing = :nodal,)),
    ("torsion discount",   (concrete_torsion_discount = true,)),
    ("averaging 1.5",      (averaging_width_factor = 1.5,)),
    ("averaging 2",        (averaging_width_factor = 2.0,)),
    ("averaging 3",        (averaging_width_factor = 3.0,)),
    ("flexible footprint", (patch_stiffness_factor = 1.0,)),
    ("mesh 0.15 m",        (target_edge = 0.15u"m",)),
]

"""Method configurations for a method-set name from experiments.jl."""
function method_set(name::AbstractString)
    name == "all"      && return ALL_METHODS
    name == "core"     && return CORE_METHODS
    name == "section3" && return SECTION3_METHODS
    name == "smoke"    && return filter(m -> m.name in ("ACI Min", "DDM (Full)"), CORE_METHODS)
    if name == "fea_postproc"
        return [(key = Symbol("fea_pp_$(i)_$(j)"), name = "$(bn) | $(vn)",
                 method = SR.FEA(; merge(bkw, vkw)...))
                for (i, (bn, bkw)) in enumerate(FEA_BASES) for (j, (vn, vkw)) in enumerate(FEA_VARIANTS)]
    end
    error("unknown method set $(name)")
end

"""`min_h_variants` for a regime name."""
function regime_variants(name::AbstractString)
    name == "table_minimum"       && return [("table_minimum", nothing)]
    name == "computed_deflection" && return [("computed_deflection", COMPUTED_DEFLECTION_SEED)]
    error("unknown regime $(name)")
end

"""Run one method of the task, saving its files as part `part_id`."""
function run_part(task, mcfg, part_id)
    a = task.args
    kw = Base.structdiff(a, NamedTuple{(:methods, :regime, :sensitivity)})
    common = (methods = [mcfg], min_h_variants = regime_variants(a.regime),
              save = true, results_dir = PARTS, run_name = part_id)
    task.kind === :heatmap  && return dual_heatmap_sweep(; kw..., common...)
    task.kind === :building && return sweep_building(; kw..., common...)
    error("unknown task kind $(task.kind)")
end

"""Join the parts' tables into the task's files; return the main-table row count."""
function join_parts(part_ids)
    n_rows = 0
    for suffix in ("", "_columns", "_slabs", "_failures")
        dfs = DataFrame[]
        for pid in part_ids
            f = joinpath(PARTS, "$(pid)$(suffix).csv")
            isfile(f) && filesize(f) > 0 || continue
            d = CSV.read(f, DataFrame)
            nrow(d) > 0 && push!(dfs, d)
        end
        suffix == "" && (n_rows = sum(nrow, dfs; init = 0))
        out = joinpath(OUT, "$(TASK.id)$(suffix).csv")
        if !isempty(dfs)
            CSV.write(out, vcat(dfs...; cols = :union))
        elseif suffix == ""
            CSV.write(out, DataFrame())   # every design failed or was skipped
        end
    end
    write_run_meta(joinpath(OUT, "$(TASK.id).csv"); note = "cluster task $(TASK.id) args=$(repr(TASK.args))")
    return n_rows
end

function write_task_json(path; status, n_rows = 0, n_parts = 0, n_resumed = 0, err = "")
    esc(s) = replace(string(s), "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n")
    fields = [
        "id" => TASK.id, "experiment" => EXPERIMENT, "index" => INDEX,
        "status" => status, "rows" => n_rows,
        "parts" => n_parts, "parts_resumed" => n_resumed,
        "args" => repr(TASK.args),
        "slurm_job_id" => get(ENV, "SLURM_JOB_ID", ""),
        "slurm_array_job_id" => get(ENV, "SLURM_ARRAY_JOB_ID", ""),
        "slurm_array_task_id" => get(ENV, "SLURM_ARRAY_TASK_ID", ""),
        "slurm_partition" => get(ENV, "SLURM_JOB_PARTITION", ""),
        "resubmit_round" => get(ENV, "ROUND", "1"),
        "host" => gethostname(), "julia" => string(VERSION),
        "threads" => Threads.nthreads(),
        "gurobi_license" => get(ENV, "GRB_LICENSE_FILE", ""),
        "started" => string(started), "finished" => string(now()),
        "load_s" => round(t_loaded - t_start; digits = 1),
        "wall_s" => round(time() - t_start; digits = 1),
        "error" => err,
    ]
    open(path, "w") do io
        println(io, "{")
        for (i, (k, v)) in enumerate(fields)
            val = v isa Number ? string(v) : "\"$(esc(v))\""
            println(io, "  \"$(k)\": $(val)", i < length(fields) ? "," : "")
        end
        println(io, "}")
    end
end

methods  = method_set(TASK.args.methods)
part_ids = ["$(TASK.id)__m$(lpad(k, 2, '0'))" for k in eachindex(methods)]
n_resumed = 0
try
    for (k, mcfg) in enumerate(methods)
        pdone = joinpath(PARTS, "$(part_ids[k]).done")
        if isfile(pdone)
            global n_resumed += 1
            println("  part $(k)/$(length(methods)) $(mcfg.name): done earlier")
            continue
        end
        t_part = time()
        run_part(TASK, mcfg, part_ids[k])
        touch(pdone)
        println("  part $(k)/$(length(methods)) $(mcfg.name): $(round(time() - t_part; digits = 1)) s")
    end
    n_rows = join_parts(part_ids)
    write_task_json(joinpath(OUT, "$(TASK.id).task.json"); status = "done", n_rows,
                    n_parts = length(methods), n_resumed)
    touch(DONE)
    for pid in part_ids, suffix in (".csv", "_columns.csv", "_slabs.csv", "_failures.csv", ".csv.meta.json", ".done")
        rm(joinpath(PARTS, "$(pid)$(suffix)"); force = true)
    end
    println("done $(TASK.id): $(n_rows) rows in $(round(time() - t_start; digits = 1)) s ($(n_resumed) parts resumed)")
catch e
    msg = sprint(showerror, e, catch_backtrace())
    write(ERROR_FILE, msg)
    write_task_json(joinpath(OUT, "$(TASK.id).task.json"); status = "error",
                    n_parts = length(methods), n_resumed, err = first(msg, 2000))
    println(stderr, msg)
    exit(1)
end
