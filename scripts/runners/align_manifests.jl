#=
Align the other environments' manifests to StructuralSynthesizer/Manifest.toml
(the environment the API image ships), so every environment shares one
precompile cache per package; packages StructuralSynthesizer does not use follow
the root manifest. Only registered packages are touched; stdlibs follow the
running Julia version and are skipped. Run it twice if the first pass pulls in
new indirect dependencies.

Usage (from repo root; needs registry access; does not precompile):
    julia scripts/runners/align_manifests.jl
Then check with `julia scripts/runners/compare_manifests.jl`.
=#

using TOML
ENV["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
using Pkg

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const REFERENCE = joinpath(REPO_ROOT, "StructuralSynthesizer", "Manifest.toml")
const TARGETS = ["", "StructuralSizer", "StructuralStudies"]

"""
    registered_versions(manifest) -> Dict{String,VersionNumber}

Versions of registry-installed packages (entries with a `git-tree-sha1`).
"""
function registered_versions(manifest::AbstractString)
    out = Dict{String,VersionNumber}()
    for (name, entries) in TOML.parsefile(manifest)["deps"]
        e = entries[1]
        haskey(e, "git-tree-sha1") && haskey(e, "version") && (out[name] = VersionNumber(e["version"]))
    end
    return out
end

"""
    align!(env, ref)

Move every registered package in `env` whose version differs from `ref` to the
reference version. Indirect packages are temporarily added as direct
dependencies to fix their version, then removed from the project again.
"""
function align!(env::AbstractString, ref::Dict{String,VersionNumber})
    dir = joinpath(REPO_ROOT, env)
    current = registered_versions(joinpath(dir, "Manifest.toml"))
    todo = sort!([n for (n, v) in current if haskey(ref, n) && ref[n] != v])
    label = isempty(env) ? "root" : env
    isempty(todo) && return println("$label: already aligned")
    println("$label: ", join(("$n $(current[n]) → $(ref[n])" for n in todo), ", "))

    project = joinpath(dir, "Project.toml")
    original = read(project, String)
    direct = Set(keys(get(TOML.parse(original), "deps", Dict())))
    Pkg.activate(dir)
    Pkg.add([PackageSpec(; name=n, version=ref[n]) for n in todo]; preserve=Pkg.PRESERVE_ALL)
    indirect = filter(n -> n ∉ direct, todo)
    isempty(indirect) || Pkg.rm(indirect; mode=Pkg.PKGMODE_PROJECT)
    # Pkg rewrites the file (LF endings, added [compat]); keep the original when deps are unchanged.
    if keys(get(TOML.parsefile(project), "deps", Dict())) == direct
        write(project, original)
    else
        @warn "$label Project.toml deps changed; review the diff" project
    end
end

function main()
    # Packages StructuralSynthesizer doesn't use (e.g. plotting/table deps) follow the root manifest.
    ref = merge(registered_versions(joinpath(REPO_ROOT, "Manifest.toml")), registered_versions(REFERENCE))
    foreach(env -> align!(env, ref), TARGETS)
end

main()
