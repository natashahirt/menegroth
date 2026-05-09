#!/usr/bin/env julia

"""
    audit_docs_links.jl

Validates that Markdown links in `docs/src/**/*.md` resolve on disk.

Checks:
- Relative Markdown links that end in `.md` (optionally with `#anchor`) exist.
- Every page referenced in `docs/make.jl` exists under `docs/src/`.

Notes:
- Ignores external links (`http://`, `https://`) and Documenter refs (`@ref`).
- Only validates on-disk existence, not anchors within the target files.
"""

using Printf

const MD_LINK_RE = r"\]\(([^)]+\.md(?:#[^)]+)?)\)"

function collect_md_files(docs_src::AbstractString)::Vector{String}
    paths = String[]
    for (root, _, files) in walkdir(docs_src)
        for f in files
            endswith(f, ".md") || continue
            push!(paths, joinpath(root, f))
        end
    end
    return sort(paths)
end

function is_external(target::AbstractString)::Bool
    startswith(target, "http://") || startswith(target, "https://")
end

function is_doc_ref(target::AbstractString)::Bool
    # e.g. ](@ref) or ](@ref foo)
    occursin("@ref", target)
end

function strip_anchor(target::AbstractString)::String
    i = findfirst('#', target)
    i === nothing ? target : target[begin:prevind(target, i)]
end

function audit_relative_links(md_paths::Vector{String})
    missing = Tuple{String, String, String}[]

    for src in md_paths
        txt = read(src, String)
        for m in eachmatch(MD_LINK_RE, txt)
            target = m.captures[1]
            is_external(target) && continue
            is_doc_ref(target) && continue
            isempty(strip(target)) && continue

            rel = strip_anchor(target)
            isempty(strip(rel)) && continue

            abs_target = normpath(joinpath(dirname(src), rel))
            isfile(abs_target) || push!(missing, (src, target, abs_target))
        end
    end

    return missing
end

function audit_makedocs_pages(repo::AbstractString)
    mk = joinpath(repo, "docs", "make.jl")
    txt = read(mk, String)

    # Documenter pages are listed as strings like "path/to/page.md"
    paths = Set{String}()
    for m in eachmatch(r"\"([^\"]+\.md)\"", txt)
        push!(paths, m.captures[1])
    end

    missing = Tuple{String, String}[]
    for p in sort!(collect(paths))
        fp = joinpath(repo, "docs", "src", p)
        isfile(fp) || push!(missing, (p, fp))
    end

    return missing
end

function main()
    repo = abspath(joinpath(@__DIR__, "..", ".."))
    docs_src = joinpath(repo, "docs", "src")
    md_paths = collect_md_files(docs_src)

    missing_links = audit_relative_links(md_paths)
    missing_pages = audit_makedocs_pages(repo)

    if !isempty(missing_pages)
        @printf("ERROR: docs/make.jl references %d missing page(s):\n", length(missing_pages))
        for (p, fp) in missing_pages
            println("  - ", p, " -> ", fp)
        end
        println()
    else
        @printf("OK: docs/make.jl references %d pages; all exist.\n", 0 + length(Set([m.captures[1] for m in eachmatch(r"\"([^\"]+\.md)\"", read(joinpath(repo, "docs", "make.jl"), String))])))
    end

    if !isempty(missing_links)
        @printf("ERROR: found %d relative Markdown link(s) with missing targets:\n", length(missing_links))
        for (src, target, abs_target) in missing_links
            println("  - ", src, ": ", target, " -> ", abs_target)
        end
        exit(1)
    end

    isempty(missing_pages) || exit(1)
    @printf("OK: all relative `.md` link targets resolve across %d markdown files.\n", length(md_paths))
end

main()

