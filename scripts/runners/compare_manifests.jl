#=
Report registered packages whose resolved versions differ across the repo's
manifests. Each mismatch means a separate precompile cache for every package
that depends on it, so switching environments triggers rebuilds. Stdlibs are
skipped: they follow the running Julia version, not the manifest.

Usage (from repo root):
    julia scripts/runners/compare_manifests.jl
Fix mismatches with `julia scripts/runners/align_manifests.jl`.
=#

using TOML

const MANIFESTS = ["Manifest.toml", "StructuralSizer/Manifest.toml",
                   "StructuralSynthesizer/Manifest.toml", "StructuralStudies/Manifest.toml"]

"""
    versions(path) -> Dict{String,String}

Package name → resolved version for registry-installed packages in one manifest.
"""
function versions(path::AbstractString)
    deps = TOML.parsefile(path)["deps"]
    return Dict(name => e[1]["version"] for (name, e) in deps
                if haskey(e[1], "git-tree-sha1") && haskey(e[1], "version"))
end

function main()
    found = filter(isfile, MANIFESTS)
    vs = Dict(m => versions(m) for m in found)
    names = sort!(collect(union((keys(v) for v in values(vs))...)))
    nmismatch = 0
    for name in names
        present = [(m, vs[m][name]) for m in found if haskey(vs[m], name)]
        length(unique(last.(present))) > 1 || continue
        nmismatch += 1
        println(rpad(name, 28), join(("$(dirname(m) == "" ? "root" : dirname(m))=$v" for (m, v) in present), "  "))
    end
    println(nmismatch == 0 ? "All shared packages agree." : "\n$nmismatch mismatched package(s).")
    exit(nmismatch == 0 ? 0 : 1)
end

main()
