#=
Quiet test runner: runs tests, writes the full output to a log file, and prints
only the Test Summary table plus failure/error excerpts. Keeps precompile and
test noise out of terminal (and agent) context.

If a persistent test server for the package is running (`test_server.jl`), the
tests run there, with no process startup or precompile cost. Otherwise they run
in a fresh child Julia process.

Usage (from repo root):
    julia scripts/runners/test_quiet.jl StructuralSynthesizer core/test_walls_bridge.jl [more files...]
    julia scripts/runners/test_quiet.jl StructuralSizer            # full suite (runtests.jl)
    julia scripts/runners/test_quiet.jl --fresh StructuralSizer …  # bypass the server

Test file paths are relative to `<Package>/test/`. Full log: `logs/test_<Package>_<timestamp>.log`.
Exit code mirrors the test run (non-zero on any failure/error).
=#

using Dates, Sockets

"""Max number of excerpt lines printed per failure/error block."""
const EXCERPT_LINES = 15
"""Hard cap on total printed excerpt lines, so a cascade of errors stays readable."""
const MAX_PRINTED = 250

const FAILURE_PATTERN = r"Test Failed at|Error During Test at|^ERROR:|LoadError"

"""Status code `test_server.jl` returns when Revise could not apply an edit."""
const REVISE_FAILED = 2

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
    run_child(pkg, files, logpath) -> Int

Run the tests in a fresh Julia process. A signalled child can report exit code 0,
so a killed run maps to `128 + signal` rather than passing.
"""
function run_child(pkg::AbstractString, files::Vector{String}, logpath::AbstractString)
    cmd = `$(Base.julia_cmd()) --color=no --project=$pkg -e $(build_child_code(pkg, files))`
    env = merge(ENV, Dict("SS_ENABLE_VISUALIZATION" => get(ENV, "SS_ENABLE_VISUALIZATION", "false")))
    proc = open(logpath, "w") do io
        run(pipeline(ignorestatus(setenv(cmd, env)); stdout=io, stderr=io))
    end
    proc.termsignal != 0 && return 128 + proc.termsignal
    return something(proc.exitcode, 1)
end

"""
    run_on_server(pkg, files, logpath) -> Union{Int,Nothing}

Send the request to a running `test_server.jl` for `pkg` and return its status
code, or `nothing` when no server is reachable.
"""
function run_on_server(pkg::AbstractString, files::Vector{String}, logpath::AbstractString)
    portfile = joinpath("logs", "test_server_$pkg.port")
    isfile(portfile) || return nothing
    port = tryparse(Int, strip(read(portfile, String)))
    sock = port === nothing ? nothing : try connect(ip"127.0.0.1", port) catch; nothing end
    if sock === nothing
        println("Stale test-server port file ($portfile); using a fresh process.")
        return nothing
    end
    println("Using $pkg test server on port $port.")
    println(sock, join(["RUN", logpath, files...], '\t'))
    reply = readline(sock)
    close(sock)
    m = match(r"^DONE (\d+)$", reply)
    m === nothing || return parse(Int, m[1])
    println("Test server closed the connection without a result (crashed or stopped).")
    return 1
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
    fresh = "--fresh" in args
    args = filter(!=("--fresh"), args)
    isempty(args) && error("usage: julia scripts/runners/test_quiet.jl [--fresh] <Package> [test files relative to <Package>/test/...]")
    pkg, files = args[1], args[2:end]
    isdir(joinpath(pkg, "test")) || error("no test directory at $(joinpath(pkg, "test")); run from repo root")

    mkpath("logs")
    logpath = abspath("logs", "test_$(pkg)_$(Dates.format(now(), "yyyymmdd_HHMMSS")).log")

    println("Running $(isempty(files) ? "full suite" : join(files, ", ")) for $pkg …")
    t0 = time()
    code = fresh ? nothing : run_on_server(pkg, files, logpath)
    code === nothing && (code = run_child(pkg, files, logpath))
    elapsed = round(time() - t0; digits=1)

    summarize(logpath)
    if code != 0
        why = code == REVISE_FAILED ? "Revise could not apply source changes" : "exit $code"
        println("\nFAIL ($why) in $(elapsed)s — full log: $logpath")
        exit(code)
    end
    println("\nPASS in $(elapsed)s — full log: $logpath")
    exit(0)
end

main(ARGS)
