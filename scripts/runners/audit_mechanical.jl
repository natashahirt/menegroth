# The passes the citation audit did not run: docstring steps, duplicate
# formulas, and catch / @warn fallbacks.
#
#   julia scripts/runners/audit_mechanical.jl
#
# Writes logs/audit_mechanical.md. Does not modify library code.

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const SRC_ROOTS = [
    joinpath(ROOT, "StructuralSizer", "src"),
    joinpath(ROOT, "StructuralSynthesizer", "src"),
    joinpath(ROOT, "external", "Asap", "src"),
]
const OUT = joinpath(ROOT, "logs", "audit_mechanical.md")

const CONCEPTS = [
    r"\bb0\b" => "critical perimeter b0",
    r"γv|gamma_v|γ_v" => "moment-transfer fraction γv",
    r"function\s+effective_depth|function\s+d_eff" => "effective depth",
    r"function\s+Ec\b" => "concrete modulus Ec",
    r"φ\s*=\s*0\.\d+|phi\s*=\s*0\.\d+" => "strength-reduction factor",
]

struct Hit
    kind::String
    file::String
    line::Int
    text::String
end

function rel(path)
    return relpath(path, ROOT)
end

function files()
    out = String[]
    for root in SRC_ROOTS
        isdir(root) || continue
        for (dir, _, names) in walkdir(root)
            for name in names
                endswith(name, ".jl") || continue
                push!(out, joinpath(dir, name))
            end
        end
    end
    return out
end

"Docstrings that enumerate a procedure."
function docstring_steps(path, hits)
    lines = readlines(path)
    in_doc = false
    doc_start = 0
    buf = String[]
    function finish()
        text = join(buf, "\n")
        numbered = count(r"(?m)^\s*\d+[\.\)]\s+\S", text)
        stepped = occursin(r"Design Steps|# Steps|^\s*Steps:", text) || numbered >= 3
        if stepped
            push!(hits, Hit("docstring_steps", rel(path), doc_start,
                first(split(text, "\n"), 6) |> xs -> join(xs, " | ")))
        end
        empty!(buf)
    end
    for (n, line) in enumerate(lines)
        if !in_doc && occursin(r"^\"\"\"", strip(line))
            in_doc = true
            doc_start = n
            push!(buf, line)
            count(c -> c == '"', line) >= 6 && (finish(); in_doc = false)
        elseif in_doc
            push!(buf, line)
            occursin(r"\"\"\"\s*$", line) && (finish(); in_doc = false)
        end
    end
end

"catch blocks, with the first non-empty line of the handler."
function catch_blocks(path, hits)
    lines = readlines(path)
    for (n, line) in enumerate(lines)
        occursin(r"\bcatch\b", line) || continue
        body = ""
        for k in (n + 1):min(n + 6, length(lines))
            s = strip(lines[k])
            (isempty(s) || startswith(s, "#")) && continue
            body = s
            break
        end
        push!(hits, Hit("catch", rel(path), n, strip(line) * " → " * body))
    end
end

function warn_lines(path, hits)
    lines = readlines(path)
    for (n, line) in enumerate(lines)
        occursin(r"@warn\b", line) || continue
        push!(hits, Hit("warn", rel(path), n, strip(line)))
    end
end

function concept_lines(path, hits)
    lines = readlines(path)
    for (n, line) in enumerate(lines)
        for (pat, name) in CONCEPTS
            occursin(pat, line) || continue
            push!(hits, Hit(name, rel(path), n, strip(line)[1:min(end, 160)]))
            break
        end
    end
end

function write_report(hits)
    mkpath(dirname(OUT))
    open(OUT, "w") do io
        println(io, "# Mechanical audit passes")
        println(io)
        println(io, "Docstring procedures, duplicate formulas (`b0`, `γv`, effective depth, `Ec`, `φ`), `catch` handlers, and `@warn` sites. Hits are listed for review. Library code was not changed.")
        println(io)
        kinds = unique(h.kind for h in hits)
        for kind in kinds
            group = filter(h -> h.kind == kind, hits)
            println(io, "## $kind ($(length(group)))")
            println(io)
            for h in group
                text = replace(h.text, "|" => "/")
                println(io, "- $(h.file):$(h.line) — $text")
            end
            println(io)
        end
    end
end

function main()
    hits = Hit[]
    for path in files()
        docstring_steps(path, hits)
        catch_blocks(path, hits)
        warn_lines(path, hits)
        concept_lines(path, hits)
    end
    sort!(hits, by = h -> (h.kind, h.file, h.line))
    write_report(hits)
    counts = Dict{String,Int}()
    for h in hits
        counts[h.kind] = get(counts, h.kind, 0) + 1
    end
    println("hits ", length(hits))
    for (k, v) in sort(collect(counts))
        println(k, " ", v)
    end
    println("wrote ", OUT)
end

main()
