"""
    _transfer_reinforcement_pass(columns, moment_results, secondary_results,
                                 rebar_design, h, d, fc, fy;
                                 results, on_inadequate, on_result) -> (results, column)

Shared moment-transfer reinforcement assembly (ACI 318-11 §13.5.3, corpus:
aci-318-11, page 250) at every column.  Factors the per-column loop common to
the rule-of-thumb pass and the iterative pipeline; the site-specific handling of
an inadequate/failing transfer check is injected via `on_inadequate`.

For each column the governing transfer steel is computed from the biaxial
unbalanced moments; a column whose two transfer moments are both below
1e-6 kip·ft needs none and is skipped.  A non-finite transfer moment, or
transfer steel the section cannot develop (`transfer_section_inadequate`, which
includes a non-finite transfer moment), invokes `on_inadequate(i, reason)`:

- when it returns `true` the scan continues to the remaining columns (the
  rule-of-thumb pass records every failing column);
- when it returns `false` the pass stops immediately and reports that column's
  index in `column` (the iterative pipeline asks for more depth).

`results[i]` is filled with the `additional_transfer_bars` result for every
adequate column, and `on_result(i, col, gov, transfer)` runs afterwards for any
site-specific reporting.  Returns `(results, column)` where `column` is the
index that triggered an early stop, or `0` when every column was scanned.
"""
function _transfer_reinforcement_pass(columns, moment_results, secondary_results,
                                      rebar_design, h, d, fc, fy;
                                      results = Union{Nothing, NamedTuple}[nothing for _ in columns],
                                      on_inadequate,
                                      on_result = (i, col, gov, transfer) -> nothing)
    for (i, col) in enumerate(columns)
        Mub_i = moment_results.unbalanced_moments[i]
        Muy_i = isnothing(secondary_results) ? zero(Mub_i) :
                secondary_results.unbalanced_moments[i]
        if !(isfinite(Mub_i) && isfinite(Muy_i))
            on_inadequate(i, "transfer_moment_non_finite") ||
                return (results = results, column = i)
            continue
        end
        abs(ustrip(kip * u"ft", Mub_i)) < 1e-6 &&
            abs(ustrip(kip * u"ft", Muy_i)) < 1e-6 && continue

        gov = governing_transfer_reinforcement(
            Mub_i, Muy_i, col.c1, col.c2, h, d, fc, fy;
            position = col.position,
            free_edge_parallel = _infer_free_edge_parallel(col))
        if transfer_section_inadequate(gov.As)
            on_inadequate(i, "transfer_section_inadequate") ||
                return (results = results, column = i)
            continue
        end

        cs_neg_idx = col.position == :interior ? 3 : 1
        As_provided_cs = rebar_design.column_strip_reinf[cs_neg_idx].As_provided
        # ACI 318-11 §13.3.2 + §7.6.5 — slab-thickness-dependent s_max
        selected = select_bars(As_provided_cs, rebar_design.column_strip_width;
                               max_spacing=max_bar_spacing(h))
        Ab = bar_area(selected.bar_size)

        transfer = additional_transfer_bars(gov.As, As_provided_cs, gov.bb,
                                            rebar_design.column_strip_width, Ab)
        results[i] = transfer
        on_result(i, col, gov, transfer)
    end
    return (results = results, column = 0)
end

"""
    _transfer_sections_adequate(columns, moment_results, secondary_results, h, d, fc, fy) -> Bool

True when every column can develop its §13.5.3 transfer moment in a
tension-controlled section. `governing_transfer_reinforcement` returns a
non-finite `As` when it cannot (ACI 318-11 §10.3.4, the same rule as
`required_reinforcement`). The final design asks for more depth for that
column; checking it with the moments already in hand keeps that request
from arriving after punching has been resolved.

Reference: ACI 318-11 §13.5.3 (corpus: aci-318-11, page 250).
"""
function _transfer_sections_adequate(columns, moment_results, secondary_results, h, d, fc, fy)
    for (i, col) in enumerate(columns)
        Mub = moment_results.unbalanced_moments[i]
        Muy = isnothing(secondary_results) ? zero(Mub) :
              secondary_results.unbalanced_moments[i]
        (isfinite(Mub) && isfinite(Muy)) || return false
        gov = governing_transfer_reinforcement(
            Mub, Muy, col.c1, col.c2, h, d, fc, fy;
            position = col.position,
            free_edge_parallel = _infer_free_edge_parallel(col))
        transfer_section_inadequate(gov.As) && return false
    end
    return true
end

"""
    _pipeline_transfer_reinforcement(columns, moment_results, secondary_results,
                                     rebar_design, h, d, fc, fy; verbose)
        -> (ok, results, column)

Moment-transfer reinforcement (ACI 318-11 §13.5.3, corpus: aci-318-11,
page 250) at every column for the iterative pipeline.  A non-finite
transfer moment is rejected first; only then is a column whose transfer
moments are both below 1e-6 kip·ft skipped as needing none.

Stops at the first column whose transfer steel is not finite
(`transfer_section_inadequate`, which includes a non-finite transfer
moment) and returns `ok = false` with that column's index; the caller
reports `transfer_reinforcement` and asks for more depth.  Delegates the
shared §13.5.3 assembly to `_transfer_reinforcement_pass`, injecting the
early-stop inadequacy policy and the verbose per-column debug.
"""
function _pipeline_transfer_reinforcement(columns, moment_results, secondary_results,
                                          rebar_design, h, d, fc, fy;
                                          verbose::Bool = false)
    pass = _transfer_reinforcement_pass(
        columns, moment_results, secondary_results, rebar_design, h, d, fc, fy;
        on_inadequate = (i, reason) -> false,
        on_result = (i, col, gov, transfer) -> begin
            if verbose && transfer.n_bars_additional > 0
                @debug "MOMENT TRANSFER (ACI 8.4.2.3) — Column $i ($(col.position))" Mub=gov.Mu γf=round(gov.γf, digits=3) bb=gov.bb As_transfer=gov.As As_within_bb=transfer.As_within_bb n_additional=transfer.n_bars_additional
            end
        end,
    )
    return (ok = pass.column == 0, results = pass.results, column = pass.column)
end

"""
    _edge_beam_analysis_kwargs(opts) -> NamedTuple

Edge-beam keywords passed to every `run_moment_analysis` /
`run_secondary_moment_analysis` call alongside `βt`, so the iterative
pipeline (both phases) and the rule-of-thumb pass give the analysis the
same input.  `edge_beam_βt` is the user's explicit value only (0.0 when
`nothing`).  FEA sizes its edge-beam elements from `edge_beam_βt`, else
`βt`, and uses its own default only when both are 0 and `has_edge_beam` is
set; DDM/EFM accept both for API parity and use `βt`.
"""
_edge_beam_analysis_kwargs(opts) = (
    has_edge_beam = opts.has_edge_beam,
    edge_beam_βt  = opts.edge_beam_βt isa Number ? Float64(opts.edge_beam_βt) : 0.0,
)

