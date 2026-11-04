# Citation audit against the local corpus text.
#
#   julia scripts/runners/audit_citations.jl
#
# Reads clause comments in StructuralSizer, StructuralSynthesizer, and Asap,
# and checks each one against corpus/text using corpus/manifests/sources.yml.
# Writes logs/audit_citations.md and logs/audit_citations.csv.
# Does not modify library code.

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const SRC_ROOTS = [
    joinpath(ROOT, "StructuralSizer", "src"),
    joinpath(ROOT, "StructuralSynthesizer", "src"),
    joinpath(ROOT, "external", "Asap", "src"),
]
const MANIFEST = joinpath(ROOT, "corpus", "manifests", "sources.yml")
const OUT_MD = joinpath(ROOT, "logs", "audit_citations.md")
const OUT_CSV = joinpath(ROOT, "logs", "audit_citations.csv")

const CITE_RE = r"(ACI|AISC|CSA|fib|ASCE|AISI|NDS|SDPWS|TMS|IBC)(?:\s*([0-9]{1,4}))?(?:\s*[-/]\s*([0-9]{2,4}))?[^\n#]{0,60}?§\s*([0-9]+(?:\.[0-9]+)*)"
const EQ_RE = r"Eq\.?\s*\(?([0-9]+-[0-9]+)\)?"
const CORPUS_RE = r"corpus:\s*([A-Za-z0-9_.-]+)"
const PAGE_RE = r"page\s+([0-9]+)"
const NUM_RE = r"(?<![\d.])(\d+\.\d+|\d+)(?![\d.])"

struct Source
    id::String
    text_path::String
    family::String
    edition::String
    role::String
end

struct Finding
    severity::String
    kind::String
    file::String
    line::Int
    detail::String
end

function parse_manifest(path)
    sources = Source[]
    id = text_path = family = edition = role = ""
    function flush()
        isempty(id) && return
        push!(sources, Source(id, text_path, family, edition, role))
        id = text_path = family = edition = role = ""
    end
    for raw in eachline(path)
        line = strip(raw)
        startswith(line, "- id:") && (flush(); id = strip(split(line, ":", limit = 2)[2]))
        startswith(line, "text_path:") && (text_path = strip(split(line, ":", limit = 2)[2]))
        startswith(line, "family:") && (family = strip(split(line, ":", limit = 2)[2]))
        startswith(line, "edition:") && (edition = strip(strip(split(line, ":", limit = 2)[2]), ['"']))
        startswith(line, "role:") && (role = strip(split(line, ":", limit = 2)[2]))
    end
    flush()
    return sources
end

function comment_of(line)
    quoted = false
    for i in eachindex(line)
        c = line[i]
        if c == '"'
            quoted = !quoted
        elseif c == '#' && !quoted
            return line[i:end]
        end
    end
    return ""
end

"Edition year from 'ACI 318-11'. The standard number (318) is not a year."
function edition_year(tail)
    tail === nothing && return 0
    y = tryparse(Int, tail)
    return y === nothing ? 0 : y
end

function resolve_source(comment, sources)
    tag = match(CORPUS_RE, comment)
    if tag !== nothing
        id = tag.captures[1]
        src = findfirst(s -> s.id == id, sources)
        return src === nothing ? nothing : sources[src], id
    end
    return nothing, ""
end

function resolve_by_name(standard, year, comment, sources)
    year == 0 && return nothing
    yy = "-" * lpad(string(year % 100), 2, '0')
    std = lowercase(standard)
    hits = Source[]
    for s in sources
        blob = lowercase(s.id * " " * s.edition)
        occursin(std, blob) || continue
        occursin(yy, blob) || continue
        push!(hits, s)
    end
    length(hits) == 1 && return hits[1]
    codes = filter(s -> s.role == "codes", hits)
    length(codes) == 1 && return codes[1]
    commented = lowercase(comment)
    narrowed = filter(hits) do s
        any(m -> occursin(m.match, commented), eachmatch(r"[0-9]{2,4}", s.id))
    end
    return length(narrowed) == 1 ? narrowed[1] : nothing
end

mutable struct Doc
    collapsed::String
    pages::Dict{Int,String}
end

const DOCS = Dict{String,Doc}()

function load_doc(src::Source)
    haskey(DOCS, src.id) && return DOCS[src.id]
    path = joinpath(ROOT, src.text_path)
    if !isfile(path)
        DOCS[src.id] = Doc("", Dict{Int,String}())
        return DOCS[src.id]
    end
    text = read(path, String)
    pages = Dict{Int,String}()
    parts = split(text, r"PAGE\s+([0-9]+)")
    # parts: preamble, page number, body, page number, body, ...
    i = 2
    while i + 1 <= length(parts)
        n = tryparse(Int, parts[i])
        body = replace(parts[i + 1], r"\s+" => "")
        n !== nothing && (pages[n] = get(pages, n, "") * body)
        i += 2
    end
    DOCS[src.id] = Doc(replace(text, r"\s+" => ""), pages)
    return DOCS[src.id]
end

function clause_at(collapsed, clause)
    isempty(collapsed) && return nothing
    pat = Regex(replace(clause, "." => "\\.") * "(?!\\d)")
    return findfirst(pat, collapsed)
end

function numbers_worth_checking(comment, clause)
    skip = Set(split(clause, "."))
    push!(skip, "318", "360", "7", "11", "19", "16", "22", "10", "05", "02", "99")
    out = String[]
    for m in eachmatch(NUM_RE, comment)
        n = m.captures[1]
        n in skip && continue
        occursin(".", n) || occursin(Regex(n * "\\s*[√*]"), comment) || continue
        # Years and page numbers are not code factors.
        v = tryparse(Int, n)
        v !== nothing && (1900 <= v <= 2100) && continue
        push!(out, n)
    end
    return unique(out)
end

function window_has_number(collapsed, span, number)
    span === nothing && return false
    a = thisind(collapsed, max(1, first(span) - 1500))
    a = a < 1 ? 1 : a
    b0 = thisind(collapsed, min(ncodeunits(collapsed), last(span) + 1500))
    b0 = b0 < 1 ? 1 : b0
    b = min(lastindex(collapsed), b0 + ncodeunits(collapsed[b0]) - 1)
    return occursin(number, collapsed[a:b])
end

function audit_file(path, sources, findings, counts)
    lines = readlines(path)
    rel = relpath(path, ROOT)
    for (n, line) in enumerate(lines)
        comment = comment_of(line)
        isempty(comment) && continue
        counts["comments"] += 1
        cited = false
        for m in eachmatch(CITE_RE, comment)
            cited = true
            counts["citations"] += 1
            standard, _, tail, clause = m.captures
            year = edition_year(tail)
            src, tag = resolve_source(comment, sources)
            if src === nothing && !isempty(tag)
                push!(findings, Finding("review", "unknown_corpus_id", rel, n,
                    "corpus id '$tag' is not in sources.yml ($(standard) §$(clause))"))
                continue
            end
            if src === nothing
                src = resolve_by_name(standard, year, comment, sources)
            end
            if src === nothing
                kind = year == 0 ? "edition_missing" : "source_not_in_corpus"
                sev = year == 0 ? "review" : "review"
                push!(findings, Finding(sev, kind, rel, n,
                    "$(standard) §$(clause) has no resolvable corpus text"))
                continue
            end
            doc = load_doc(src)
            if isempty(doc.collapsed)
                push!(findings, Finding("review", "text_missing", rel, n,
                    "$(src.id) text file is missing for §$(clause)"))
                continue
            end
            span = clause_at(doc.collapsed, clause)
            if span === nothing
                push!(findings, Finding("wrong", "clause_not_found", rel, n,
                    "§$(clause) not found in $(src.id)"))
                continue
            end
            counts["clause_found"] += 1
            page_m = match(PAGE_RE, comment)
            if page_m !== nothing && !isempty(doc.pages)
                page = parse(Int, page_m.captures[1])
                near = false
                for p in (page - 1, page, page + 1)
                    haskey(doc.pages, p) && clause_at(doc.pages[p], clause) !== nothing && (near = true)
                end
                near || push!(findings, Finding("review", "page_mismatch", rel, n,
                    "§$(clause) is in $(src.id) but not on page $(page) ± 1"))
            end
            for number in numbers_worth_checking(comment, clause)
                window_has_number(doc.collapsed, span, number) || push!(findings, Finding(
                    "review", "number_not_in_clause", rel, n,
                    "comment number $(number) near §$(clause) is not in the $(src.id) window"))
            end
        end
        if !cited
            for m in eachmatch(EQ_RE, comment)
                counts["equations"] += 1
                src, _ = resolve_source(comment, sources)
                # Equation-only comments are checked when a corpus id is present.
                src === nothing && continue
                doc = load_doc(src)
                eq = m.captures[1]
                occursin(replace(eq, "-" => "-"), doc.collapsed) ||
                    occursin(replace(eq, "-" => ""), doc.collapsed) ||
                    push!(findings, Finding("review", "equation_not_found", rel, n,
                        "Eq. $(eq) not found in $(src.id)"))
            end
        end
    end
end

function walk(dir, sources, findings, counts)
    isdir(dir) || return
    for (root, _, files) in walkdir(dir)
        for file in files
            endswith(file, ".jl") || continue
            audit_file(joinpath(root, file), sources, findings, counts)
        end
    end
end

function csv_escape(s)
    return "\"" * replace(s, "\"" => "\"\"") * "\""
end

function write_reports(findings, counts)
    mkpath(dirname(OUT_MD))
    open(OUT_CSV, "w") do io
        println(io, "severity,kind,file,line,detail")
        for f in findings
            println(io, join((f.severity, f.kind, csv_escape(f.file), f.line, csv_escape(f.detail)), ","))
        end
    end
    by = Dict{String,Int}()
    for f in findings
        by[f.kind] = get(by, f.kind, 0) + 1
    end
    open(OUT_MD, "w") do io
        println(io, "# Citation audit")
        println(io)
        println(io, "Comments scanned: $(counts["comments"]). Clause citations: $(counts["citations"]). Clauses found in a resolved source: $(counts["clause_found"]). Equation-only comments checked: $(counts["equations"]).")
        println(io)
        println(io, "Findings: $(length(findings)).")
        println(io)
        for (k, v) in sort(collect(by); by = last, rev = true)
            println(io, "- $(k): $(v)")
        end
        println(io)
        println(io, "A `clause_not_found` row means the dotted clause number is not in the resolved corpus text after whitespace is removed. `page_mismatch` allows one page of OCR drift. `number_not_in_clause` is a review flag, not a confirmed wrong factor. When a name matches both the code and a guide, the `codes` role wins. Nothing here was changed in the library.")
        println(io)
        println(io, "## Mechanical pass")
        println(io)
        println(io, "Thread pools in `external/Asap/src/threading.jl` are empty consts filled from `__init__` up to `maxthreadid`. The Gurobi env pool is a tid-keyed dict, locked, and emptied from `__init__`. No other `threadid()` index into a precompile-sized array showed up in the three source trees.")
        println(io)
        println(io, "- `fea_mesh_key` includes column center, c1, c2, shape, position, and orientation. Shape was added 2026-11-03 (a circle is meshed as the equivalent-area square).")
        println(io, "- The checkerboard partition in `pattern_cases.jl` is recomputed per call. The process-wide `_CHECKERBOARD_CACHE` keyed by `objectid(skeleton)` was removed 2026-11-03; it ignored `struc.cells` and was unlocked.")
        println(io, "- `_DISCRETE_SOLVE_MEMO` keys on a value token of the inputs and is capped at 64. It is not a precompile-filled thread buffer.")
        println(io, "- Catalogs, PCA tables, and fire tables are immutable lookup data filled at load. They are not per-thread buffers.")
        println(io)
        println(io, "Docstring-step, duplicate-formula, and silent-fallback passes were not scripted in this run. The citation table below is the scripted half.")
        println(io)
        println(io, "| Severity | Kind | Location | Detail |")
        println(io, "|---|---|---|---|")
        for f in findings
            loc = "$(f.file):$(f.line)"
            detail = replace(f.detail, "|" => "/")
            println(io, "| $(f.severity) | $(f.kind) | $(loc) | $(detail) |")
        end
    end
end

function main()
    sources = parse_manifest(MANIFEST)
    findings = Finding[]
    counts = Dict("comments" => 0, "citations" => 0, "clause_found" => 0, "equations" => 0)
    for root in SRC_ROOTS
        walk(root, sources, findings, counts)
    end
    sort!(findings, by = f -> (f.severity != "wrong", f.kind, f.file, f.line))
    write_reports(findings, counts)
    println("sources ", length(sources))
    println("comments ", counts["comments"], " citations ", counts["citations"],
            " found ", counts["clause_found"], " findings ", length(findings))
    println("wrote ", OUT_MD)
end

main()
