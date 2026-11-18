# Merge per-task outputs into one file per table, and list unfinished tasks.
#
#   julia --project=StructuralStudies merge_results.jl RUN_DIR [EXPERIMENT ...]
#
# For each experiment writes RUN_DIR/<experiment>.csv, _columns.csv,
# _slabs.csv and _failures.csv (columns are the union across tasks; every row
# gets `task_id`), plus <experiment>_missing.tsv with the array index, id and
# status of every task without a .done file. followup.sh resubmits the
# "unfinished" ones.

using CSV, DataFrames

isempty(ARGS) && error("usage: merge_results.jl RUN_DIR [EXPERIMENT ...]")
run_dir = ARGS[1]
include(joinpath(@__DIR__, "experiments.jl"))
exps = length(ARGS) > 1 ? ARGS[2:end] : filter(e -> isdir(joinpath(run_dir, e)), EXPERIMENTS)

const TABLES = ["", "_columns", "_slabs", "_failures"]

for exp in exps
    dir = joinpath(run_dir, exp)
    isdir(dir) || (println("$(exp): no results"); continue)
    ids = [t.id for t in tasks(exp)]
    for suffix in TABLES
        parts = DataFrame[]
        for id in ids
            f = joinpath(dir, "$(id)$(suffix).csv")
            isfile(f) || continue
            d = CSV.read(f, DataFrame)
            nrow(d) == 0 && continue
            d.task_id .= id
            push!(parts, d)
        end
        isempty(parts) && continue
        out = joinpath(run_dir, "$(exp)$(suffix).csv")
        CSV.write(out, vcat(parts...; cols = :union))
        println("$(exp)$(suffix): $(sum(nrow, parts)) rows from $(length(parts)) tasks → $(out)")
    end
    missing_idx = [i for (i, id) in enumerate(ids) if !isfile(joinpath(dir, "$(id).done"))]
    errored = count(id -> isfile(joinpath(dir, "$(id).error")), ids)
    # status: "error" (an exception; not resubmitted automatically) or
    # "unfinished" (time limit, preemption, node failure, or not yet run)
    open(joinpath(run_dir, "$(exp)_missing.tsv"), "w") do io
        for i in missing_idx
            status = isfile(joinpath(dir, "$(ids[i]).error")) ? "error" : "unfinished"
            println(io, i, '\t', ids[i], '\t', status)
        end
    end
    println("$(exp): $(length(ids) - length(missing_idx))/$(length(ids)) tasks done, ",
            "$(length(missing_idx)) missing ($(errored) with .error)")
end
