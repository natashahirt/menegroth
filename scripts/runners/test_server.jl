#=
Persistent test server: loads one package once (with Revise tracking its source
and Asap's), then runs test files on request from `test_quiet.jl`. Source edits
are applied by Revise in seconds instead of triggering a full precompile.

Usage (from repo root, in a terminal you leave open):
    julia scripts/runners/test_server.jl StructuralSynthesizer
    julia scripts/runners/test_server.jl StructuralSizer

While it runs, `julia scripts/runners/test_quiet.jl <Package> [files...]` sends
its tests here automatically; pass `--fresh` there to force a clean process.
Stop with Ctrl-C.

Each request runs in a fresh anonymous module, so test-file globals never leak
between runs, but package-level mutable state (caches, solver envs) does persist.
If Revise cannot apply an edit (syntax error, unsupported change), the request
fails without running any tests; fix the error or restart the server.
=#

using Sockets, Logging, TOML

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))

isempty(ARGS) && error("usage: julia scripts/runners/test_server.jl <Package>")
const PKG = ARGS[1]
const PKG_DIR = joinpath(REPO_ROOT, PKG)
const TEST_DIR = joinpath(PKG_DIR, "test")
isdir(TEST_DIR) || error("no test directory at $TEST_DIR")

"""Port file `test_quiet.jl` reads to find this server."""
const PORT_FILE = joinpath(REPO_ROOT, "logs", "test_server_$PKG.port")

"""Status codes returned to the client in `DONE <code>`."""
const PASS, FAIL, REVISE_FAILED, BAD_REQUEST = 0, 1, 2, 3

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
Base.set_active_project(joinpath(PKG_DIR, "Project.toml"))
# Revise is only a dependency of the root environment; stack it after the package env.
push!(LOAD_PATH, REPO_ROOT)

if isfile(PORT_FILE)
    port = tryparse(Int, strip(read(PORT_FILE, String)))
    alive = port !== nothing && try close(connect(ip"127.0.0.1", port)); true catch; false end
    alive && error("a $PKG test server is already listening on port $port")
end

@info "Loading Revise and $PKG (precompiles first if the cache is stale)…"
using Revise
const PKG_SYM = Symbol(PKG)
@eval Main using Test, Unitful, Asap, $PKG_SYM
using Test: TestSetException

"""
    resolve_test_paths(files) -> Vector{String}

Absolute paths for `files` (relative to `<PKG>/test/`); `runtests.jl` when empty.
Rejects paths that escape the test directory.
"""
function resolve_test_paths(files::Vector{String})
    isempty(files) && return [joinpath(TEST_DIR, "runtests.jl")]
    paths = [normpath(joinpath(TEST_DIR, f)) for f in files]
    for p in paths
        startswith(p, TEST_DIR * "/") || throw(ArgumentError("test path outside $TEST_DIR: $p"))
        isfile(p) || throw(ArgumentError("no such test file: $p"))
    end
    return paths
end

"""
    run_tests(paths, full_suite) -> Int

Include `paths` in a fresh module with the same imports as `runtests.jl`; the
selected files are wrapped in one top-level `@testset`. Returns `PASS` or `FAIL`.
"""
function run_tests(paths::Vector{String}, full_suite::Bool)
    m = Module(:TestRun)
    Core.eval(m, :(include(p) = Base.include($m, p)))
    Core.eval(m, :(using Test, Unitful, Asap, $PKG_SYM))
    body = full_suite ? :(include($(paths[1]))) :
        :(@testset $("$PKG (selected)") begin $([:(include($p)) for p in paths]...) end)
    try
        cd(() -> Core.eval(m, body), TEST_DIR)
        return PASS
    catch err
        # A failing top-level @testset throws TestSetException after printing its summary.
        err isa TestSetException || (print("ERROR: "); showerror(stdout, err, catch_backtrace()); println())
        return FAIL
    end
end

"""
    handle_request(files, logpath) -> Int

Apply pending source edits with Revise, then run the tests, sending all output
(including solver C-library output) to `logpath`.
"""
function handle_request(files::Vector{String}, logpath::String)
    open(logpath, "w") do io
        redirect_stdio(; stdout=io, stderr=io) do
            with_logger(ConsoleLogger(io)) do
                try
                    Revise.revise(; throw=true)
                catch err
                    println("ERROR: Revise could not apply source changes; tests were NOT run.")
                    showerror(stdout, err, catch_backtrace())
                    println("\nFix the error and rerun, or restart the test server.")
                    return REVISE_FAILED
                end
                paths = try
                    resolve_test_paths(files)
                catch err
                    println("ERROR: ", sprint(showerror, err))
                    return BAD_REQUEST
                end
                return run_tests(paths, isempty(files))
            end
        end
    end
end

"""
    serve(server)

Accept one client at a time. Protocol: the client sends one tab-separated line
`RUN <logpath> <file>...`; the server replies `DONE <code>` when finished.
"""
function serve(server)
    while true
        sock = accept(server)
        try
            fields = split(readline(sock), '\t')
            if length(fields) < 2 || fields[1] != "RUN"
                println(sock, "DONE $BAD_REQUEST")
                continue
            end
            logpath, files = String(fields[2]), String.(fields[3:end])
            label = isempty(files) ? "full suite" : join(files, ", ")
            t0 = time()
            code = handle_request(files, logpath)
            @info "$(code == PASS ? "PASS" : "FAIL ($code)") in $(round(time() - t0; digits=1))s — $label"
            println(sock, "DONE $code")
        catch err
            err isa InterruptException && rethrow()
            @error "request failed" exception=(err, catch_backtrace())
        finally
            close(sock)
        end
    end
end

port, server = listenany(ip"127.0.0.1", 18_400)
mkpath(dirname(PORT_FILE))
write(PORT_FILE, string(port))
atexit(() -> rm(PORT_FILE; force=true))
@info "$PKG test server ready on port $port (Ctrl-C to stop)"
serve(server)
