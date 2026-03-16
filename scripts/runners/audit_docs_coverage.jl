#!/usr/bin/env julia

"""
    audit_docs_coverage.jl

Quick audit for Documenter ` ```@docs ` coverage:

- Reads exported names from `StructuralSizer/src/StructuralSizer.jl` and
  `StructuralSynthesizer/src/StructuralSynthesizer.jl`.
- Scans `docs/src/**/*.md` for ` ```@docs ` blocks and collects referenced symbols.
- Reports exported "likely types" missing from any `@docs` block.

Heuristic: a "likely type" is an exported name that starts with an uppercase letter and
does not contain `_`. This intentionally excludes most preset constants like `NWC_4000`.
"""

using Printf

function read_exports(path::AbstractString)::Set{String}
    lines = readlines(path)
    exports = Set{String}()
    in_export = false
    buf = ""

    for raw in lines
        line = replace(raw, r"#.*$" => "")
        isempty(strip(line)) && continue

        if startswith(strip(line), "export ")
            in_export = true
            buf = strip(line)[length("export ") + 1:end]
        elseif in_export
            buf *= " " * strip(line)
        else
            continue
        end

        if !endswith(strip(buf), ",")
            for part in split(buf, ',')
                name = strip(part)
                isempty(name) && continue
                push!(exports, name)
            end
            in_export = false
            buf = ""
        end
    end

    return exports
end

function read_docs_symbols(md_paths::Vector{String})
    syms_exact = Set{String}()
    syms_unqualified = Set{String}()

    for p in md_paths
        txt = read(p, String)
        i = firstindex(txt)
        while true
            start = findnext("```@docs", txt, i)
            start === nothing && break
            block_start = start[1]
            after = start[2] + 1
            block_end = findnext("\n```", txt, after)
            block_end === nothing && break
            content = txt[after:block_end[1] - 1]
            for rawline in split(content, '\n')
                s = strip(rawline)
                isempty(s) && continue
                startswith(s, "#") && continue
                # Drop trailing inline comments.
                s = strip(replace(s, r"#.*$" => ""))
                isempty(s) && continue
                push!(syms_exact, s)
                if occursin('.', s)
                    push!(syms_unqualified, split(s, '.')[end])
                else
                    push!(syms_unqualified, s)
                end
            end
            i = block_end[2] + 1
        end
    end

    return syms_exact, syms_unqualified
end

function is_likely_type(name::String)::Bool
    isempty(name) && return false
    c = first(name)
    return isuppercase(c) && !occursin('_', name)
end

function main()
    repo = abspath(joinpath(@__DIR__, "..", ".."))
    sizer = joinpath(repo, "StructuralSizer", "src", "StructuralSizer.jl")
    synth = joinpath(repo, "StructuralSynthesizer", "src", "StructuralSynthesizer.jl")

    exports = union(read_exports(sizer), read_exports(synth))

    # Collect docs symbols
    docs_root = joinpath(repo, "docs", "src")
    md_paths = String[]
    for (root, _, files) in walkdir(docs_root)
        for f in files
            endswith(f, ".md") || continue
            push!(md_paths, joinpath(root, f))
        end
    end
    syms_exact, syms_unqualified = read_docs_symbols(md_paths)

    exported_types = sort([e for e in exports if is_likely_type(e)])
    missing = String[]
    for t in exported_types
        if !(t in syms_unqualified) && !(t in syms_exact)
            push!(missing, t)
        end
    end

    @printf("Exported names (union): %d\n", length(exports))
    @printf("Docs symbols (unqualified): %d\n", length(syms_unqualified))
    @printf("Likely exported types: %d\n", length(exported_types))
    @printf("Missing likely types from any @docs block: %d\n\n", length(missing))
    for t in missing
        println(t)
    end
end

main()

