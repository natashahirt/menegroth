"""
    _column_top_steel_minimum(col, Vu, b0, d, h, fc, fy; λ=1.0, φ=0.75, drop=nothing)
        -> (As, bslab, vuv)

Returns no extra top steel. ACI 318-11 does not contain the later §8.6.1.2
minimum, so the bars in the column band are the §13.5.3 transfer steel.
`As` is zero and the caller keeps that transfer steel.
"""
function _column_top_steel_minimum(col, Vu, b0, d, h, fc, fy;
                                   λ::Float64 = 1.0, φ::Float64 = 0.75, drop = nothing)
    return (As = 0.0u"inch^2", bslab = 0.0u"inch", vuv = 0.0u"psi")
end

"""
    _column_face_punching(punching, columns, d_punch, drop) -> Vector

Per-column `(b0 = ...)` of the critical section at d/2 from the column face.
Without a drop panel that is the punching result itself, openings included.
With one, a result governed by the column section is used as is. Where the
drop edge governed, the column-face perimeter is rebuilt from the column at
`d_punch` without openings.
"""
function _column_face_punching(punching, columns, d_punch, drop)
    drop === nothing && return punching
    return map(enumerate(columns)) do (i, col)
        r = punching[i]
        r !== nothing && get(r, :governing_section, :column) === :column && return r
        (b0 = punching_geometry(col.c1, col.c2, d_punch; position = col.position).b0,)
    end
end

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

`results[i]` is filled for every adequate column with
`(n_bars_additional, As_additional, c1, c2)`. `c1` and `c2` are the bars
added in the band of the moment spanning along that column axis
(`_strip_transfer_bars` fields plus `governs`); the totals are their sums.
Each direction is credited only with its own column-strip steel. Moments
and depths are put on the column axes by `_named_axis_demand`: `Mub` spans
along `span_axis` at `d`, the secondary moment at `d_secondary`.
`on_result(i, col, gov, transfer)` runs afterwards for any site-specific
reporting.  Returns `(results, column)` where `column` is the index that
triggered an early stop, or `0` when every column was scanned.

When `punching` (per-column results carrying `b0`) is given, the ACI 318-19
§8.6.1.2 steel from [`_column_top_steel_minimum`](@ref) is also checked, at
every column including those with no transfer moment. Its width is across
`c2`, so it is compared with the `c1` transfer bars and the larger governs
that band (`c1.governs = :min_top_steel_8_6_1_2`); the `c2` bars are kept.
`d_punch` and `drop` describe the column-face section (`d_total` and the
drop panel for a flat slab).

When the punching result carries `moment_transfer` (ACI 318-11 §13.5.3.3
fractions, corpus: aci-318-11, page 250), the transfer steel is sized with
those γf, and every axis that used §13.5.3.3(b) is re-checked for εt ≥ 0.010
with the steel placed in its band (`_placed_band_strain_ok`). A failure
invokes `on_inadequate(i, "gamma_f_increase_strain")`.
"""
function _transfer_reinforcement_pass(columns, moment_results, secondary_results,
                                      rebar_design, h, d, fc, fy;
                                      results = Union{Nothing, NamedTuple}[nothing for _ in columns],
                                      on_inadequate,
                                      on_result = (i, col, gov, transfer) -> nothing,
                                      punching = nothing, d_punch = d, drop = nothing,
                                      secondary_rebar_design = nothing,
                                      span_axis::NTuple{2, Float64} = (1.0, 0.0),
                                      d_secondary = nothing,
                                      λ::Float64 = 1.0, φ_shear::Float64 = 0.75)
    for (i, col) in enumerate(columns)
        Mub_i = moment_results.unbalanced_moments[i]
        Muy_i = isnothing(secondary_results) ? zero(Mub_i) :
                secondary_results.unbalanced_moments[i]
        if !(isfinite(Mub_i) && isfinite(Muy_i))
            on_inadequate(i, "transfer_moment_non_finite") ||
                return (results = results, column = i)
            continue
        end
        top_min = punching === nothing || punching[i] === nothing ? nothing :
            _column_top_steel_minimum(col, moment_results.column_shears[i], punching[i].b0,
                                      d_punch, h, fc, fy; λ = λ, φ = φ_shear, drop = drop)
        needs_top_min = top_min !== nothing && ustrip(u"inch^2", top_min.As) > 0
        no_transfer = abs(ustrip(kip * u"ft", Mub_i)) < 1e-6 &&
                      abs(ustrip(kip * u"ft", Muy_i)) < 1e-6
        no_transfer && !needs_top_min && continue

        mt = punching === nothing || punching[i] === nothing ? nothing :
            get(punching[i], :moment_transfer, nothing)
        ax = _named_axis_demand(col, Mub_i, Muy_i, d, something(d_secondary, d), span_axis)
        gov = no_transfer ? nothing : governing_transfer_reinforcement(
            ax.Mx, ax.My, col.c1, col.c2, h, ax.dx, fc, fy;
            position = col.position,
            free_edge_parallel = _infer_free_edge_parallel(col),
            γf_x = mt === nothing ? nothing : mt.γf_x,
            γf_y = mt === nothing ? nothing : mt.γf_y,
            d_y = ax.dy)
        if gov !== nothing && transfer_section_inadequate(gov.As)
            on_inadequate(i, "transfer_section_inadequate") ||
                return (results = results, column = i)
            continue
        end

        cs_neg_idx = col.position == :interior ? 3 : 1
        # The band for a moment contains that direction's column-strip bars.
        # `c1` steel is the primary strip when the span runs along `c1`.
        design_c1 = ax.along ? rebar_design : secondary_rebar_design
        design_c2 = ax.along ? secondary_rebar_design : rebar_design
        Ab_fallback = _strip_bar_area(rebar_design, h, cs_neg_idx)
        none = _strip_transfer_bars(nothing, 0.0u"inch^2", 0.0u"inch", h, cs_neg_idx, Ab_fallback)
        bars_c1 = gov === nothing ? none :
            _strip_transfer_bars(design_c1, gov.As_x, gov.bb_x, h, cs_neg_idx, Ab_fallback)
        bars_c2 = gov === nothing ? none :
            _strip_transfer_bars(design_c2, gov.As_y, gov.bb_y, h, cs_neg_idx, Ab_fallback)
        bars_c1 = (; bars_c1..., governs = gov === nothing ? :none : :moment_transfer)
        bars_c2 = (; bars_c2..., governs = gov === nothing ? :none : :moment_transfer)
        if needs_top_min
            # §8.6.1.2 width is measured across c2, so these bars run along c1
            # and share the c1 band. The larger requirement governs there.
            top = _strip_transfer_bars(design_c1, top_min.As, top_min.bslab, h,
                                       cs_neg_idx, Ab_fallback)
            if top.As_additional > bars_c1.As_additional
                bars_c1 = (; top..., governs = :min_top_steel_8_6_1_2)
            end
        end
        transfer = (n_bars_additional = bars_c1.n_bars_additional + bars_c2.n_bars_additional,
                    As_additional = bars_c1.As_additional + bars_c2.As_additional,
                    c1 = bars_c1, c2 = bars_c2)
        if gov !== nothing && mt !== nothing &&
           !_placed_band_strain_ok(mt, gov, transfer, design_c1, design_c2,
                                   cs_neg_idx, ax.dx, fc, fy; d_y = ax.dy)
            on_inadequate(i, "gamma_f_increase_strain") ||
                return (results = results, column = i)
            continue
        end
        results[i] = transfer
        gov === nothing || on_result(i, col, gov, transfer)
    end
    return (results = results, column = 0)
end

"""
    _placed_band_strain_ok(mt, gov, transfer, design_c1, design_c2,
                           cs_neg_idx, d, fc, fy; d_y = d) -> Bool

ACI 318-11 §13.5.3.3(b) (corpus: aci-318-11, page 250): εt in the §13.5.3.2
effective width is not less than 0.010. Checked on each axis that used (b),
with the steel placed in that band:

- the column-strip top steel of that direction (`design_c1` for the moment
  spanning along `c1`, `design_c2` for `c2`) in proportion to
  `bb / strip width`;
- plus the bars this pass adds in that band (`transfer.c1` / `transfer.c2`);
- and never less than the band's required transfer steel.

An axis with no transfer moment is skipped. A (b) increase on a direction
with no strip design cannot be checked and fails.
"""
function _placed_band_strain_ok(mt, gov, transfer, design_c1, design_c2,
                                cs_neg_idx, d, fc, fy; d_y = d)
    added(bars) = bars.n_bars_additional * bars.bar_area
    added_x = transfer === nothing ? 0.0u"inch^2" : added(transfer.c1)
    added_y = transfer === nothing ? 0.0u"inch^2" : added(transfer.c2)
    for (provision, As_req, bb, design, depth, added_axis) in
            ((mt.provision_x, gov.As_x, gov.bb_x, design_c1, d, added_x),
             (mt.provision_y, gov.As_y, gov.bb_y, design_c2, d_y, added_y))
        provision === :aci_13_5_3_3b || continue
        ustrip(u"inch^2", As_req) > 0 || continue
        design === nothing && return false
        As_cs = design.column_strip_reinf[cs_neg_idx].As_provided
        As_band = As_cs * (bb / design.column_strip_width) + added_axis
        As_placed = max(As_band, As_req)
        transfer_band_net_tensile_strain(As_placed, bb, depth, fc, fy) >= 0.010 - 1e-12 ||
            return false
    end
    return true
end

"""
    _strip_bar_area(design, h, cs_neg_idx) -> Area

Area of one bar in the column-strip selection that provides `design`'s steel
at the negative station `cs_neg_idx`.
"""
function _strip_bar_area(design, h, cs_neg_idx)
    As_cs = design.column_strip_reinf[cs_neg_idx].As_provided
    selected = select_bars(As_cs, design.column_strip_width; max_spacing = max_bar_spacing(h))
    return bar_area(selected.bar_size)
end

"""
    _named_axis_demand(col, Mub, Muy, d, d2, span_axis) -> (Mx, My, dx, dy, along)

Transfer moments and layer depths on the column's named axes. `Mub` spans
along `span_axis` at depth `d`; `Muy` is the other direction at the
inner-layer depth `d2`. `Mx` / `dx` belong to the moment spanning along `c1`.
"""
function _named_axis_demand(col, Mub, Muy, d, d2, span_axis)
    along = _span_along_c1(col, span_axis)
    Mx, My = along ? (Mub, Muy) : (Muy, Mub)
    dx, dy = along ? (d, d2) : (d2, d)
    return (Mx = Mx, My = My, dx = dx, dy = dy, along = along)
end

"""
    _strip_transfer_bars(design, As_req, bb, h, cs_neg_idx, Ab_fallback)
        -> (As_within_bb, As_additional, n_bars_additional, bar_area)

Additional bars for one moment, credited only with `design`'s column-strip
steel inside `bb` (ACI 318-11 §13.5.3.2, corpus: aci-318-11, page 250).
No design in that direction means none of the required steel is already
placed; the bars are then counted with `Ab_fallback`.
"""
function _strip_transfer_bars(design, As_req, bb, h, cs_neg_idx, Ab_fallback)
    if ustrip(u"inch^2", As_req) <= 0
        return (As_within_bb = 0.0u"inch^2", As_additional = 0.0u"inch^2",
                n_bars_additional = 0, bar_area = Ab_fallback)
    end
    if design === nothing
        n = ceil(Int, As_req / Ab_fallback)
        return (As_within_bb = 0.0u"inch^2", As_additional = As_req,
                n_bars_additional = n, bar_area = Ab_fallback)
    end
    Ab = _strip_bar_area(design, h, cs_neg_idx)
    As_cs = design.column_strip_reinf[cs_neg_idx].As_provided
    return (; additional_transfer_bars(As_req, As_cs, bb, design.column_strip_width, Ab)...,
            bar_area = Ab)
end

"""
    _transfer_sections_adequate(columns, moment_results, secondary_results, h, d, fc, fy;
                                span_axis = (1.0, 0.0), d_secondary = nothing) -> Bool

True when every column can develop its §13.5.3 transfer moment in a
tension-controlled section. `governing_transfer_reinforcement` returns a
non-finite `As` when it cannot (ACI 318-11 §10.3.4, the same rule as
`required_reinforcement`). The final design asks for more depth for that
column; checking it with the moments already in hand keeps that request
from arriving after punching has been resolved.

Moments, bands and depths are assigned as in the final pass
(`_named_axis_demand`), with `d_secondary` the inner-layer depth. Eq. (13-1)
is enough here: a §13.5.3.3 fraction is only taken where its band can
develop it (`moment_transfer_gamma_f`).

Reference: ACI 318-11 §13.5.3 (corpus: aci-318-11, page 250).
"""
function _transfer_sections_adequate(columns, moment_results, secondary_results, h, d, fc, fy;
                                     span_axis::NTuple{2, Float64} = (1.0, 0.0),
                                     d_secondary = nothing)
    for (i, col) in enumerate(columns)
        Mub = moment_results.unbalanced_moments[i]
        Muy = isnothing(secondary_results) ? zero(Mub) :
              secondary_results.unbalanced_moments[i]
        (isfinite(Mub) && isfinite(Muy)) || return false
        ax = _named_axis_demand(col, Mub, Muy, d, something(d_secondary, d), span_axis)
        gov = governing_transfer_reinforcement(
            ax.Mx, ax.My, col.c1, col.c2, h, ax.dx, fc, fy;
            position = col.position,
            free_edge_parallel = _infer_free_edge_parallel(col),
            d_y = ax.dy)
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
                                          verbose::Bool = false, kwargs...)
    pass = _transfer_reinforcement_pass(
        columns, moment_results, secondary_results, rebar_design, h, d, fc, fy;
        kwargs...,
        on_inadequate = (i, reason) -> false,
        on_result = (i, col, gov, transfer) -> begin
            if verbose && transfer.n_bars_additional > 0
                @debug "MOMENT TRANSFER (ACI 318-11 §13.5.3) — Column $i ($(col.position))" As_x=gov.As_x bb_x=gov.bb_x n_c1=transfer.c1.n_bars_additional c1_governs=transfer.c1.governs As_y=gov.As_y bb_y=gov.bb_y n_c2=transfer.c2.n_bars_additional
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

