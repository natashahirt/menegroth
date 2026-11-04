#=
Toggle precompile workloads for local development by writing per-environment
`LocalPreferences.toml` files (gitignored, so Docker/CI keep the defaults).
Preferences are part of Julia's precompile cache key: each toggle triggers one
rebuild, and caches built with different settings never get mixed up.

Usage (from repo root):
    julia scripts/runners/dev_precompile.jl off     # skip all workloads (fastest rebuilds)
    julia scripts/runners/dev_precompile.jl on      # restore defaults (StructuralSizer light workload only)
    julia scripts/runners/dev_precompile.jl heavy   # defaults + StructuralSynthesizer heavy workload
    julia scripts/runners/dev_precompile.jl status
=#

using TOML

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
"""Environments whose `LocalPreferences.toml` this script manages."""
const ENVS = ["", "StructuralSizer", "StructuralSynthesizer", "StructuralStudies"]
const PACKAGES = ["StructuralSizer", "StructuralSynthesizer"]
"""Preference keys this script owns; `on` removes them to restore package defaults."""
const KEYS = ["precompile_workload", "heavy_precompile_workload"]

"""
    settings(mode) -> Dict{String,Dict{String,Bool}}

Package name → preferences to write for `mode`; empty means package defaults.
"""
function settings(mode::AbstractString)
    mode == "off"   && return Dict(p => Dict("precompile_workload" => false) for p in PACKAGES)
    mode == "on"    && return Dict{String,Dict{String,Bool}}()
    mode == "heavy" && return Dict("StructuralSynthesizer" => Dict("heavy_precompile_workload" => true))
    error("unknown mode $(repr(mode)); use off, on, heavy, or status")
end

"""
    apply!(path, wanted)

Replace this script's keys in the preferences file at `path` with `wanted`,
leaving any other packages' or keys' preferences untouched.
"""
function apply!(path::AbstractString, wanted)
    prefs = isfile(path) ? TOML.parsefile(path) : Dict{String,Any}()
    for pkg in PACKAGES
        section = get!(prefs, pkg, Dict{String,Any}())
        foreach(k -> delete!(section, k), KEYS)
        merge!(section, get(wanted, pkg, Dict{String,Bool}()))
        isempty(section) && delete!(prefs, pkg)
    end
    if isempty(prefs)
        rm(path; force=true)
    else
        open(io -> TOML.print(io, prefs; sorted=true), path, "w")
    end
end

function main(args)
    mode = isempty(args) ? "status" : args[1]
    paths = [joinpath(REPO_ROOT, e, "LocalPreferences.toml") for e in ENVS]
    if mode != "status"
        wanted = settings(mode)
        foreach(p -> apply!(p, wanted), paths)
        println("Precompile workloads set to '$mode'. The next load rebuilds affected packages once.")
    end
    for p in paths
        rel = relpath(p, REPO_ROOT)
        prefs = isfile(p) ? TOML.parsefile(p) : Dict{String,Any}()
        ours = ["$pkg.$k = $v" for pkg in PACKAGES for (k, v) in get(prefs, pkg, Dict()) if k in KEYS]
        println(rpad(rel, 44), isempty(ours) ? "defaults" : join(sort!(ours), ", "))
    end
end

main(ARGS)
