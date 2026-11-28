# Write `<run_dir>/manifest_<experiment>.tsv` (array index, task id) and
# print the task count as the last line of stdout, for submit.sh.
#
#   julia --startup-file=no make_manifest.jl EXPERIMENT RUN_DIR
#   julia --startup-file=no make_manifest.jl --list      # counts for every experiment

include(joinpath(@__DIR__, "experiments.jl"))

if !isempty(ARGS) && ARGS[1] == "--list"
    for e in EXPERIMENTS
        println(rpad(e, 18), length(tasks(e)))
    end
    exit(0)
end

length(ARGS) == 2 || error("usage: make_manifest.jl EXPERIMENT RUN_DIR")
experiment, run_dir = ARGS
ts = tasks(experiment)
ids = [t.id for t in ts]
length(unique(ids)) == length(ids) || error("duplicate task ids in $(experiment)")

mkpath(run_dir)
path = joinpath(run_dir, "manifest_$(experiment).tsv")
if isfile(path)
    # A resubmission must see the same grid, or indices point at other tasks.
    old = [split(l, '\t')[2] for l in eachline(path) if !isempty(l)]
    old == ids || error("$(path) differs from the current grid; use a new RUN_TAG")
else
    open(path, "w") do io
        for (i, id) in enumerate(ids)
            println(io, i, '\t', id)
        end
    end
end
println(stderr, "manifest: ", path)
println(length(ts))
