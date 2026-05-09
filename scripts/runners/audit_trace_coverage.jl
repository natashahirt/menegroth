#!/usr/bin/env julia
# =============================================================================
# Static Trace Coverage Audit
#
# Scans the codebase for:
#   1. TRACE_REGISTRY entries that lack emit! calls in their source
#   2. Decision-making functions not yet in TRACE_REGISTRY
#   3. Functions with tc kwarg that never call emit!
#
# Output: Markdown report on stdout (also written to REPORT_FILE if set).
# Exit code: 0 = clean, 1 = gaps found
#
# Usage:
#   julia --project=StructuralSizer scripts/runners/audit_trace_coverage.jl
# =============================================================================

ENV["SS_ENABLE_VISUALIZATION"] = "false"
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] = "false"

using StructuralSizer

const ROOT = joinpath(@__DIR__, "..", "..")
const SIZER_SRC = joinpath(ROOT, "StructuralSizer", "src")
const SYNTH_SRC = joinpath(ROOT, "StructuralSynthesizer", "src")

# ─── Helpers ──────────────────────────────────────────────────────────────────

"""Recursively collect all .jl files under a directory."""
function jl_files(dir::String)
    files = String[]
    isdir(dir) || return files
    for (root, _, filenames) in walkdir(dir)
        for f in filenames
            endswith(f, ".jl") && push!(files, joinpath(root, f))
        end
    end
    return files
end

"""Read file and return lines."""
read_lines(path::String) = readlines(path; keep=false)

"""Check if a file contains a pattern (simple string search)."""
function file_contains(path::String, pattern::String)
    for line in read_lines(path)
        occursin(pattern, line) && return true
    end
    return false
end

"""Count occurrences of a pattern in a file."""
function count_pattern(path::String, pattern::Regex)
    n = 0
    for line in read_lines(path)
        n += length(collect(eachmatch(pattern, line)))
    end
    return n
end

"""Extract function names matching a pattern from a file."""
function find_functions(path::String, pattern::Regex)
    results = Tuple{String, Int}[]  # (func_name, line_number)
    for (i, line) in enumerate(read_lines(path))
        m = match(pattern, line)
        if m !== nothing
            push!(results, (m[1], i))
        end
    end
    return results
end

"""Make path relative to ROOT for display."""
function relpath_display(path::String)
    rp = relpath(path, ROOT)
    return replace(rp, '\\' => '/')
end

# ─── Part 1: Audit TRACE_REGISTRY entries ─────────────────────────────────────

function audit_registry()
    registry = StructuralSizer.registered_functions()
    issues = Dict{String, Vector{String}}()  # file => issues

    println("## Part 1: TRACE_REGISTRY Coverage\n")
    println("| Function | Layer | Events | File | emit! calls | Status |")
    println("|----------|-------|--------|------|-------------|--------|")

    n_ok = 0
    n_warn = 0

    for ((func_name, layer), meta) in sort(collect(registry); by=first)
        file = isnothing(meta.file) ? "unknown" : meta.file
        events = join(meta.events, ", ")

        if isnothing(meta.file) || !isfile(meta.file)
            println("| `$func_name` | $layer | $events | ??? | - | **MISSING FILE** |")
            n_warn += 1
            continue
        end

        n_emit = count_pattern(meta.file, r"emit!\s*\(")
        has_enter = file_contains(meta.file, "emit!(tc") || file_contains(meta.file, "emit!(")
        rel = relpath_display(meta.file)

        if n_emit == 0
            status = "**NO EMIT CALLS**"
            n_warn += 1
        elseif :enter in meta.events && !file_contains(meta.file, ":enter")
            status = "⚠ missing :enter"
            n_warn += 1
        elseif :exit in meta.events && !file_contains(meta.file, ":exit")
            status = "⚠ missing :exit"
            n_warn += 1
        else
            status = "OK"
            n_ok += 1
        end

        println("| `$func_name` | $layer | $events | `$rel` | $n_emit | $status |")
    end

    println("\n**Registry:** $(length(registry)) functions, $n_ok OK, $n_warn warnings\n")
    return n_warn
end

# ─── Part 2: Unregistered decision functions ──────────────────────────────────

const DECISION_FUNC_PATTERNS = [
    r"^function\s+(optimize_\w+)\s*\(" => "optimize_*",
    r"^function\s+(size_\w+!?)\s*\(" => "size_*",
    r"^function\s+(design_\w+!?)\s*\(" => "design_*",
    r"^function\s+(_resolve_\w+!?)\s*\(" => "_resolve_*",
    r"^function\s+(_size_\w+!?)\s*\(" => "_size_*",
]

function audit_unregistered()
    registry = StructuralSizer.registered_functions()
    registered_names = Set(k[1] for k in keys(registry))

    println("## Part 2: Potentially Unregistered Decision Functions\n")
    println("Functions matching decision-making patterns not in TRACE_REGISTRY:\n")
    println("| Function | File | Line | Has tc? | Has emit!? |")
    println("|----------|------|------|---------|------------|")

    n_found = 0
    all_files = vcat(jl_files(SIZER_SRC), jl_files(SYNTH_SRC))

    for fpath in all_files
        lines = read_lines(fpath)
        content = join(lines, "\n")

        for (pat, _) in DECISION_FUNC_PATTERNS
            for (func_name, lineno) in find_functions(fpath, pat)
                sym = Symbol(func_name)
                sym in registered_names && continue

                # Skip private helpers, test helpers, etc.
                startswith(func_name, "__") && continue

                has_tc = occursin("tc", content) && occursin(r"tc\s*::\s*Union"s, content)
                has_emit = occursin("emit!(", content)
                rel = relpath_display(fpath)

                tc_str = has_tc ? "yes" : "**no**"
                emit_str = has_emit ? "yes" : "**no**"

                println("| `$func_name` | `$rel` | $lineno | $tc_str | $emit_str |")
                n_found += 1
            end
        end
    end

    if n_found == 0
        println("| _(none found)_ | | | | |")
    end

    println("\n**Unregistered decision functions:** $n_found\n")
    return n_found
end

# ─── Part 3: tc threading gaps ────────────────────────────────────────────────

function audit_tc_threading()
    println("## Part 3: `tc` Threading Gaps\n")
    println("Functions that accept `tc` but never call `emit!`:\n")
    println("| Function | File | Line |")
    println("|----------|------|------|")

    n_gaps = 0
    all_files = vcat(jl_files(SIZER_SRC), jl_files(SYNTH_SRC))

    for fpath in all_files
        lines = read_lines(fpath)

        for (i, line) in enumerate(lines)
            # Look for function signatures with tc kwarg
            m = match(r"^function\s+(\w+!?)\s*\(.*tc\s*::\s*Union", line)
            if m !== nothing
                func_name = m[1]
                # Check if this function body has emit! calls
                # Simple heuristic: scan until next top-level "end" or "function"
                body_start = i + 1
                body_end = min(i + 200, length(lines))
                depth = 1
                for j in body_start:body_end
                    l = lines[j]
                    if occursin(r"^\s*function\s+", l) || occursin(r"^end\s*$", l)
                        if depth <= 1
                            body_end = j
                            break
                        end
                    end
                end

                body = join(lines[body_start:body_end], "\n")
                if !occursin("emit!(", body)
                    rel = relpath_display(fpath)
                    println("| `$func_name` | `$rel` | $i |")
                    n_gaps += 1
                end
            end
        end
    end

    if n_gaps == 0
        println("| _(none found)_ | | |")
    end

    println("\n**Threading gaps:** $n_gaps\n")
    return n_gaps
end

# ─── Part 4: explain_feasibility coverage ─────────────────────────────────────

function audit_explain_feasibility()
    println("## Part 4: `explain_feasibility` Coverage\n")

    all_files = jl_files(SIZER_SRC)

    # Find all checker types
    checkers = String[]
    for fpath in all_files
        for (i, line) in enumerate(read_lines(fpath))
            m = match(r"struct\s+(\w+Checker)\s*(<:\s*AbstractCapacityChecker)?", line)
            if m !== nothing && m[2] !== nothing
                push!(checkers, m[1])
            end
        end
    end

    println("| Checker | has explain_feasibility? |")
    println("|---------|-------------------------|")

    n_missing = 0
    for checker in sort(checkers)
        has_impl = false
        for fpath in all_files
            content = read(fpath, String)
            if occursin("explain_feasibility(\n" * "    checker::$checker", content) ||
               occursin("explain_feasibility(checker::$checker", content) ||
               occursin("explain_feasibility(\n    checker::$checker", content) ||
               occursin(Regex("explain_feasibility\\([^)]*::\\s*$checker"), content)
                has_impl = true
                break
            end
        end

        status = has_impl ? "yes" : "**MISSING**"
        println("| `$checker` | $status |")
        if !has_impl
            n_missing += 1
        end
    end

    println("\n**Checkers:** $(length(checkers)), **missing explain_feasibility:** $n_missing\n")
    return n_missing
end

# ─── Main ─────────────────────────────────────────────────────────────────────

function main()
    println("# Trace Coverage Audit Report\n")
    println("_Generated: $(Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS"))_\n")
    println("---\n")

    total_issues = 0
    total_issues += audit_registry()
    println("---\n")
    total_issues += audit_unregistered()
    println("---\n")
    total_issues += audit_tc_threading()
    println("---\n")
    total_issues += audit_explain_feasibility()

    println("---\n")
    println("## Summary\n")
    if total_issues == 0
        println("**All clear.** No trace coverage gaps detected.")
    else
        println("**$total_issues issue(s) found.** See sections above for details.")
    end

    # Write to file if REPORT_FILE is set
    report_file = get(ENV, "REPORT_FILE", "")
    if !isempty(report_file)
        @info "Report would be written to $report_file (redirect stdout to capture)"
    end

    return total_issues > 0 ? 1 : 0
end

using Dates
exit(main())
