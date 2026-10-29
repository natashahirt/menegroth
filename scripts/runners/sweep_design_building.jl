# =============================================================================
# Warm parametric sweep over `design_building`
# =============================================================================
#
# Runs many buildings in a few long-lived worker processes, so package loading
# and JIT compilation are paid once per worker instead of once per building.
# Rows are appended to the output CSV as each building finishes; re-running
# with the same output skips case ids already present (resumable).
#
#   julia scripts/runners/sweep_design_building.jl SPEC.jl [options]
#
#   SPEC.jl            defines `sweep_cases()` -> Vector of NamedTuples (each with
#                      an `id` field; other fields become CSV columns) and
#                      `build_case(case)` -> (BuildingStructure, DesignParameters).
#                      Example: scripts/runners/sweep_specs/flat_plate_grid.jl
#   --workers N        worker processes (default: max(1, CPU_THREADS ÷ 4))
#   --threads K        Julia threads per worker (default: CPU_THREADS ÷ N)
#   --sysimage PATH    start workers from a sysimage (see build_sweep_sysimage.jl)
#   --out PATH         output CSV (default: logs/sweep_<spec name>.csv)
#   --limit M          run only the first M pending cases
#
# Processes, not threads, are used across buildings because the sizing path
# keeps module-level caches that are not guaranteed to be thread-safe.
# =============================================================================

using Distributed, Dates, Printf, Pkg

const REPO = normpath(joinpath(@__DIR__, "..", ".."))
const PROJECT = joinpath(REPO, "StructuralSynthesizer")
ENV["SS_ENABLE_VISUALIZATION"] = "false"
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] = "false"
Pkg.activate(PROJECT; io = devnull)

function parse_args(args)
    isempty(args) && error("usage: sweep_design_building.jl SPEC.jl [--workers N] [--threads K] [--sysimage PATH] [--out PATH] [--limit M]")
    opts = Dict{String, String}("spec" => abspath(args[1]))
    i = 2
    while i <= length(args)
        startswith(args[i], "--") || error("unexpected argument $(args[i])")
        opts[args[i][3:end]] = args[i + 1]
        i += 2
    end
    nw = parse(Int, get(opts, "workers", string(max(1, Sys.CPU_THREADS ÷ 4))))
    nt = parse(Int, get(opts, "threads", string(max(1, Sys.CPU_THREADS ÷ nw))))
    name = splitext(basename(opts["spec"]))[1]
    out = abspath(get(opts, "out", joinpath(REPO, "logs", "sweep_$(name).csv")))
    limit = haskey(opts, "limit") ? parse(Int, opts["limit"]) : typemax(Int)
    return (; spec = opts["spec"], nw, nt, sysimage = get(opts, "sysimage", nothing), out, limit)
end

const CFG = parse_args(ARGS)

exeflags = ["--project=$PROJECT", "--threads=$(CFG.nt)"]
CFG.sysimage === nothing || push!(exeflags, "--sysimage=$(abspath(CFG.sysimage))")
env = ["SS_ENABLE_VISUALIZATION" => "false", "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD" => "false"]

@info "Starting workers" workers=CFG.nw threads_per_worker=CFG.nt sysimage=CFG.sysimage
t_start = time()
addprocs(CFG.nw; exeflags, env)

@everywhere begin
    using Logging, LinearAlgebra
    using Unitful, Asap, StructuralSizer, StructuralSynthesizer
    BLAS.set_num_threads(Threads.nthreads())
end
@everywhere include($(CFG.spec))
@everywhere include($(joinpath(@__DIR__, "sweep_case_runner.jl")))

cases = sweep_cases()
ids = [string(c.id) for c in cases]
allunique(ids) || error("sweep_cases() returned duplicate ids")

done = Set{String}()
if isfile(CFG.out)
    for line in Iterators.drop(eachline(CFG.out), 1)
        push!(done, first(split(line, ',')))
    end
end
pending = [i for i in eachindex(cases) if !(ids[i] in done)]
pending = pending[1:min(end, CFG.limit)]
@info "Sweep" spec=CFG.spec total=length(cases) already_done=length(done) to_run=length(pending) out=CFG.out
@printf("workers ready in %.1f s\n", time() - t_start)

param_cols = [k for k in keys(cases[1]) if k != :id]
mkpath(dirname(CFG.out))
if !isfile(CFG.out)
    open(CFG.out, "w") do io
        println(io, join(vcat("id", string.(param_cols), collect(RESULT_COLUMNS)), ","))
    end
end

csvcell(x) = (s = string(x); occursin(r"[,\"\n]", s) ? "\"" * replace(s, "\"" => "\"\"") * "\"" : s)

queue = Channel{Int}(length(pending))
foreach(i -> put!(queue, i), pending)
close(queue)
n_done = Ref(0)
out_lock = ReentrantLock()

@sync for w in workers()
    @async for i in queue
        row = remotecall_fetch(run_sweep_case, w, cases[i])
        c = cases[i]
        line = join(csvcell.(vcat(ids[i], [getfield(c, k) for k in param_cols], collect(values(row)))), ",")
        lock(out_lock) do
            open(io -> println(io, line), CFG.out, "a")
            n_done[] += 1
            @printf("[%s] %3d/%d  %-28s %-6s %7.1f s  (worker %d)\n", Dates.format(now(), "HH:MM:SS"),
                    n_done[], length(pending), ids[i], row.status, row.seconds, w)
        end
    end
end

@printf("sweep finished: %d cases in %.1f s wall\n", length(pending), time() - t_start)
rmprocs(workers())
