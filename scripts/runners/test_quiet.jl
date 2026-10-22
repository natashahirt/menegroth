#=
Quiet test runner: runs tests in a child Julia process, writes the full output
to a log file, and prints only the Test Summary table plus failure/error excerpts.
Keeps precompile and test noise out of terminal (and agent) context.

Usage (from repo root):
    julia scripts/runners/test_quiet.jl StructuralSynthesizer core/test_walls_bridge.jl [more files...]
    julia scripts/runners/test_quiet.jl StructuralSizer            # full suite (runtests.jl)

Test file paths are relative to `<Package>/test/`. Full log: `logs/test_<Package>_<timestamp>.log`.
Exit code mirrors the child process (non-zero on any failure/error).
=#

using Dates

"""Max number of excerpt lines printed per failure/error block."""
const EXCERPT_LINES = 15
"""Hard cap on total printed excerpt lines, so a cascade of errors stays readable."""
const MAX_PRINTED = 250

const FAILURE_PATTERN = r"Test Failed at|Error During Test at|^ERROR:|LoadError"

"""
    build_child_code(pkg, files) -> String

Julia source for the child process: the full `runtests.jl` when `files` is empty,
otherwise the same imports `runtests.jl` uses followed by the requested files
inside one top-level `@testset`.
"""
function build_child_code(pkg::AbstractString, files::Vector{String})
    testdir = joinpath(pkg, "test")
    isempty(files) && return "include($(repr(abspath(testdir, "runtests.jl"))))"
    includes = join(("include($(repr(abspath(testdir, f))))" for f in files), "; ")
    return """
        using Test, Unitful, $pkg, Asap
        cd($(repr(abspath(testdir))))
        @testset "$pkg (selected)" begin $includes end
        """
end

"""
    summarize(logpath)

Print the `Test Summary:` table(s) and an excerpt after each failure/error marker.
"""
function summarize(logpath::AbstractString)
    lines = readlines(logpath)
    printed = 0
    i = 1
    while i <= length(lines) && printed < MAX_PRINTED
        line = lines[i]
        if occursin(FAILURE_PATTERN, line)
            stop = min(i + EXCERPT_LINES - 1, length(lines))
            next_marker = findnext(l -> occursin(FAILURE_PATTERN, l), lines, i + 1)
            next_marker !== nothing && next_marker <= stop && (stop = next_marker - 1)
            foreach(println, lines[i:stop])
            println("  ⋮")
            printed += stop - i + 2
            i = stop + 1
        else
            i += 1
        end
    end
    printed >= MAX_PRINTED && println("… excerpt cap reached; see full log.")

    in_summary = false
    for line in lines
        if startswith(line, "Test Summary:")
            in_summary = true
        end
        in_summary && println(line)
        in_summary && isempty(strip(line)) && (in_summary = false)
    end
end

function main(args)
    isempty(args) && error("usage: julia scripts/runners/test_quiet.jl <Package> [test files relative to <Package>/test/...]")
    pkg, files = args[1], args[2:end]
    isdir(joinpath(pkg, "test")) || error("no test directory at $(joinpath(pkg, "test")); run from repo root")

    mkpath("logs")
    logpath = abspath("logs", "test_$(pkg)_$(Dates.format(now(), "yyyymmdd_HHMMSS")).log")
    cmd = `$(Base.julia_cmd()) --color=no --project=$pkg -e $(build_child_code(pkg, files))`
    env = merge(ENV, Dict("SS_ENABLE_VISUALIZATION" => get(ENV, "SS_ENABLE_VISUALIZATION", "false")))

    println("Running $(isempty(files) ? "full suite" : join(files, ", ")) for $pkg …")
    t0 = time()
    proc = open(logpath, "w") do io
        run(pipeline(ignorestatus(setenv(cmd, env)); stdout=io, stderr=io))
    end
    elapsed = round(time() - t0; digits=1)

    summarize(logpath)
    status = proc.exitcode == 0 ? "PASS" : "FAIL (exit $(proc.exitcode))"
    println("\n$status in $(elapsed)s — full log: $logpath")
    exit(proc.exitcode)
end

main(ARGS)
