# Parse (without evaluating) Julia files and report syntax errors.
# Usage: julia scripts/runners/parse_check.jl [dir_or_file ...]
# Defaults to StructuralSizer/src and StructuralSynthesizer/src.

const ROOT = dirname(dirname(@__DIR__))

function jl_files(path)
    isfile(path) && return [path]
    out = String[]
    for (dir, _, files) in walkdir(path), f in files
        endswith(f, ".jl") && push!(out, joinpath(dir, f))
    end
    return out
end

targets = isempty(ARGS) ? [joinpath(ROOT, "StructuralSizer", "src"),
                           joinpath(ROOT, "StructuralSynthesizer", "src")] : ARGS
files = reduce(vcat, jl_files.(targets))
bad = 0
for f in files
    ex = Meta.parseall(read(f, String); filename=f)
    errs = Any[]
    walk(x) = x isa Expr && (x.head in (:error, :incomplete) ? push!(errs, x) : foreach(walk, x.args))
    walk(ex)
    isempty(errs) && continue
    global bad += 1
    println("✗ ", relpath(f, ROOT), ": ", first(errs))
end
println(bad == 0 ? "OK: $(length(files)) files parsed" : "$bad file(s) with syntax errors")
exit(bad == 0 ? 0 : 1)
