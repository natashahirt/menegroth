# =============================================================================
# Gate Orchestrator — run the four exact-first verify gates headless
# =============================================================================
#
# Runs the Phase 0 "static foundation" exact-first verify gates, each in its own
# fresh `julia` subprocess, and exits with an AGGREGATED code: 0 only when every
# gate passes, non-zero if ANY gate fails.
#
# Each gate is spawned as a SEPARATE subprocess on purpose: the gate runners end
# with `exit(main())`, so running them in-process (via `include`) would let the
# first gate's `exit()` abort the whole run and would let one gate's global state
# leak into the next. Isolated subprocesses give each gate a clean world and let
# us capture its exit code independently.
#
# The gates are referenced BY THEIR CURRENT PATHS (no runner is moved or renamed
# here — namespacing is a separate phase).
#
# Usage:
#   julia scripts/runners/run_all_gates.jl
#   julia scripts/runners/run_all_gates.jl --project=/abs/path/to/StructuralSynthesizer
#   SS_GATES_PROJECT=StructuralSynthesizer julia scripts/runners/run_all_gates.jl
#
# The child `--project` defaults to the `StructuralSynthesizer` environment the
# gate runners self-activate; override it with `--project=PATH` or the
# `SS_GATES_PROJECT` env var. Visualization is forced off for every child.
#
# Exit code: 0 when all gates pass, 1 otherwise.
# =============================================================================

using Printf

# Repo root is two levels up from scripts/runners/.
const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))

# Gates run in this order (cheapest-to-set-up first, broadest MIP coverage last).
const GATES = [
    joinpath(@__DIR__, "verify_design_graph.jl"),
    joinpath(@__DIR__, "verify_incremental_engine.jl"),
    joinpath(@__DIR__, "verify_design_graph_incremental.jl"),
    joinpath(@__DIR__, "verify_warm_state_incremental.jl"),
]

"""
    resolve_project(args) -> String

Resolve the child `--project` path. Precedence: a `--project=PATH` CLI argument,
then the `SS_GATES_PROJECT` env var, then the default `StructuralSynthesizer`
environment the gate runners self-activate. A relative value is resolved against
the repo root.
"""
function resolve_project(args::Vector{String})
    proj = nothing
    for a in args
        if startswith(a, "--project=")
            proj = a[length("--project=")+1:end]
        end
    end
    proj === nothing && (proj = get(ENV, "SS_GATES_PROJECT", "StructuralSynthesizer"))
    return isabspath(proj) ? proj : normpath(joinpath(REPO_ROOT, proj))
end

"""
    run_gate(gate, project) -> Int

Spawn a single gate in a fresh `julia` subprocess with visualization disabled and
return its exit code. `ignorestatus` keeps a failing gate from throwing so the
orchestrator can record the code and continue to the next gate.
"""
function run_gate(gate::String, project::String)
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    cmd   = `$julia --project=$project $gate`
    # Headless guards for the child (match the gate runners' own defaults).
    env   = copy(ENV)
    env["SS_ENABLE_VISUALIZATION"] = "false"
    env["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] =
        get(env, "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD", "false")
    proc = run(ignorestatus(setenv(cmd, env)); wait = true)
    return proc.exitcode
end

function main(args::Vector{String})
    project = resolve_project(args)
    println("="^70)
    println("Gate orchestrator — running $(length(GATES)) exact-first verify gates")
    println("  julia   : $(joinpath(Sys.BINDIR, Base.julia_exename()))")
    println("  project : $project")
    println("="^70)

    results = Tuple{String,Int}[]
    for gate in GATES
        name = basename(gate)
        println("\n" * "-"^70)
        println("▶ RUNNING $name")
        println("-"^70)
        code = run_gate(gate, project)
        push!(results, (name, code))
        println("\n$name exited with code $code " *
                (code == 0 ? "(PASS)" : "(FAIL)"))
    end

    println("\n" * "="^70)
    println("GATE SUMMARY")
    println("="^70)
    for (name, code) in results
        status = code == 0 ? "PASS" : "FAIL"
        @printf("  %-6s  %-40s (exit %d)\n", status, name, code)
    end
    n_fail = count(r -> r[2] != 0, results)
    println("-"^70)
    if n_fail == 0
        println("✓ ALL $(length(results)) GATES PASS")
    else
        println("✗ $n_fail / $(length(results)) GATE(S) FAILED")
    end
    println("="^70)

    return n_fail == 0 ? 0 : 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
