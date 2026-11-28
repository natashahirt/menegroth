# =============================================================================
# Sizing probe — opt-in whole-run stage timing + factorization accounting
# =============================================================================
#
# Installs an `Asap.AnalysisLog` and tags every factorization / solve with the
# design-graph stage that triggered it, so a runner can answer "where does a
# `design_building` run spend its time, and what forces each factorization".
#
# Opt-in through one `ScopedValue`. On the default path ([`SIZING_PROBE`](@ref)
# unset) `probe_stage` is a plain `f()` call and every hook is a single
# `ScopedValue` read, so production cost is nil and no signatures change.

using Base.ScopedValues: ScopedValue
using Base.ScopedValues: with as _scoped_with
using Printf: @printf

"""
    SizingProbe

Collector for one instrumented `design_building` run: the shared
`Asap.AnalysisLog` (factorization / solve events), the set of model ids that are
the building frame (so building solves are separable from slab / wall / shell
analyses), and one timed `span` per [`probe_stage`](@ref) scope.
"""
mutable struct SizingProbe
    log::Asap.AnalysisLog
    building_models::Set{UInt}
    spans::Vector{NamedTuple{(:label, :t0, :t1), Tuple{String, Float64, Float64}}}
end
SizingProbe() = SizingProbe(Asap.AnalysisLog(), Set{UInt}(),
    NamedTuple{(:label, :t0, :t1), Tuple{String, Float64, Float64}}[])

"The installed [`SizingProbe`](@ref), or `nothing` when instrumentation is off."
const SIZING_PROBE = ScopedValue{Union{Nothing, SizingProbe}}(nothing)

"""
    probe_stage(f, name)

Run `f` under stage `name`, nesting as `"parent/name"` for the enclosing label.
Records one span (inclusive wall time) and sets the Asap analysis label so every
factorization inside `f` is attributed to this stage. A plain `f()` when no
[`SizingProbe`](@ref) is installed.
"""
function probe_stage(f, name)
    p = SIZING_PROBE[]
    p === nothing && return f()
    parent = Asap.ANALYSIS_LABEL[]
    label = parent == "unlabeled" ? String(name) : string(parent, "/", name)
    t0 = time()
    try
        return _scoped_with(f, Asap.ANALYSIS_LABEL => label)
    finally
        push!(p.spans, (; label, t0, t1 = time()))
    end
end

"""
    probe_register_building_model!(model)

Record `model` as a building frame model, so its factorizations are reported as
building solves rather than lumped with slab / wall / shell analyses. No-op when
no [`SizingProbe`](@ref) is installed.
"""
function probe_register_building_model!(model)
    p = SIZING_PROBE[]
    p === nothing && return nothing
    push!(p.building_models, objectid(model))
    return nothing
end

"""
    with_sizing_probe(f, p::SizingProbe = SizingProbe()) -> (result, p)

Run `f` with `p` installed (both the `SizingProbe` and its `Asap.AnalysisLog`),
returning `f`'s result and the populated probe.
"""
function with_sizing_probe(f, p::SizingProbe = SizingProbe())
    result = Asap.with_analysis_log(p.log) do
        _scoped_with(() -> f(), SIZING_PROBE => p)
    end
    return result, p
end

# ─── Reporting ───────────────────────────────────────────────────────────────

"""
    probe_report([io], p::SizingProbe)

Print a per-stage breakdown of a [`SizingProbe`](@ref): inclusive wall time and
the factorization / refactorization / RHS counts attributed to each stage,
split into building-frame vs other (slab mesh, story shell, wall, …) models.
"""
probe_report(p::SizingProbe) = probe_report(stdout, p)

function probe_report(io::IO, p::SizingProbe)
    events = p.log.events

    # Stage wall time: aggregate inclusive spans by label.
    stage_time = Dict{String, Float64}()
    for s in p.spans
        stage_time[s.label] = get(stage_time, s.label, 0.0) + (s.t1 - s.t0)
    end

    # Factorization / solve counts by (label, is_building).
    counts = Dict{Tuple{String, Bool}, NamedTuple{(:factor, :refactor, :rhs),
                                                   Tuple{Int, Int, Int}}}()
    for ev in events
        is_bldg = ev.model_id in p.building_models
        k = (ev.label, is_bldg)
        c = get(counts, k, (; factor = 0, refactor = 0, rhs = 0))
        counts[k] = (;
            factor   = c.factor   + (ev.kind === :factor   ? 1 : 0),
            refactor = c.refactor + (ev.kind === :refactor ? 1 : 0),
            rhs      = c.rhs      + max(ev.n_rhs, 0))
    end

    labels = sort(collect(union(keys(stage_time), (k[1] for k in keys(counts)))))

    println(io, "\n==== SIZING PROBE REPORT ====")
    @printf(io, "%-38s %9s  %6s %8s %6s  %6s %8s %6s\n",
            "stage", "time(s)",
            "b.fac", "b.refac", "b.rhs", "o.fac", "o.refac", "o.rhs")
    total_t = 0.0
    tot = Dict(:bf => 0, :br => 0, :brhs => 0, :of => 0, :or => 0, :orhs => 0)
    for lbl in labels
        t = get(stage_time, lbl, NaN)
        isnan(t) || (total_t += t)
        b = get(counts, (lbl, true),  (; factor = 0, refactor = 0, rhs = 0))
        o = get(counts, (lbl, false), (; factor = 0, refactor = 0, rhs = 0))
        tot[:bf] += b.factor; tot[:br] += b.refactor; tot[:brhs] += b.rhs
        tot[:of] += o.factor; tot[:or] += o.refactor; tot[:orhs] += o.rhs
        @printf(io, "%-38s %9s  %6d %8d %6d  %6d %8d %6d\n",
                length(lbl) > 38 ? lbl[1:38] : lbl,
                isnan(t) ? "-" : string(round(t; digits = 2)),
                b.factor, b.refactor, b.rhs, o.factor, o.refactor, o.rhs)
    end
    println(io, repeat("-", 96))
    @printf(io, "%-38s %9s  %6d %8d %6d  %6d %8d %6d\n",
            "TOTAL", round(total_t; digits = 2),
            tot[:bf], tot[:br], tot[:brhs], tot[:of], tot[:or], tot[:orhs])
    println(io, "b.* = building-frame model;  o.* = other models (slab mesh / story shell / wall)")
    println(io, "fac = full factorization (new symbolic);  refac = in-place numeric;  rhs = right-hand sides")
    println(io, "=============================\n")
    return nothing
end
