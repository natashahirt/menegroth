"""
    _column_top_steel_minimum(col, Vu, b0, d, h, fc, fy; λ=1.0, φ=0.75, drop=nothing)
        -> (As, bslab, vuv)

ACI 318-19 §8.6.1.2 (corpus: aci-318-19, printed p. 111) top steel at a
column, from [`punching_minimum_top_steel`](@ref). `vuv = Vu / (b0 d)` is the
two-way shear stress without moment transfer, on the column critical section
whose perimeter is `b0`.

`bslab` is Table 8.4.2.2.3 (printed p. 105) across `c2`: each side the lesser
of 1.5h and the distance to the slab edge. The column is taken flush with the
slab edge. Corner columns have a free edge on one side (`c2 + 1.5h`). Edge
columns take `c2 + 3h` whichever way the edge runs; that is exact when the
edge is perpendicular to the span and asks for more steel than the code when
the edge is parallel to it. With a drop panel, each side is the lesser of 1.5
times the thickness at the drop and the drop extent past the column face plus
1.5h.
"""
function _column_top_steel_minimum(col, Vu, b0, d, h, fc, fy;
                                   λ::Float64 = 1.0, φ::Float64 = 0.75, drop = nothing)
    side = if drop === nothing
        1.5h
    else
        min(1.5 * total_depth_at_drop(h, drop), drop.a_drop_2 - col.c2 / 2 + 1.5h)
    end
    bslab = col.position == :corner ? col.c2 + side : col.c2 + 2side
    vuv = uconvert(u"psi", Vu / (b0 * d))
    As = punching_minimum_top_steel(vuv, bslab, b0, fc, fy, punching_αs(col.position);
                                    λ = λ, λs = size_effect_factor(d), φ = φ)
    return (As = As, bslab = bslab, vuv = vuv)
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

`results[i]` is filled with the `additional_transfer_bars` result for every
adequate column, and `on_result(i, col, gov, transfer)` runs afterwards for any
site-specific reporting.  Returns `(results, column)` where `column` is the
index that triggered an early stop, or `0` when every column was scanned.

When `punching` (per-column results carrying `b0`) is given, the ACI 318-19
§8.6.1.2 steel from [`_column_top_steel_minimum`](@ref) is also checked, at
every column including those with no transfer moment. The column gets
whichever of the two requirements adds more steel; `results[i]` then carries
`governs = :min_top_steel_8_6_1_2` instead of `:moment_transfer`. `d_punch`
and `drop` describe the column-face section (`d_total` and the drop panel
for a flat slab).

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
        gov = no_transfer ? nothing : governing_transfer_reinforcement(
            Mub_i, Muy_i, col.c1, col.c2, h, d, fc, fy;
            position = col.position,
            free_edge_parallel = _infer_free_edge_parallel(col),
            γf_x = mt === nothing ? nothing : mt.γf_x,
            γf_y = mt === nothing ? nothing : mt.γf_y)
        if gov !== nothing && transfer_section_inadequate(gov.As)
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
        cs_width = rebar_design.column_strip_width

        transfer = gov === nothing ? nothing :
            (; additional_transfer_bars(gov.As, As_provided_cs, gov.bb, cs_width, Ab)...,
             governs = :moment_transfer)
        if needs_top_min
            top = (; additional_transfer_bars(top_min.As, As_provided_cs, top_min.bslab,
                                              cs_width, Ab)...,
                   governs = :min_top_steel_8_6_1_2)
            if transfer === nothing || top.As_additional > transfer.As_additional
                transfer = top
            end
        end
        if gov !== nothing && mt !== nothing &&
           !_placed_band_strain_ok(mt, gov, transfer, Ab, rebar_design,
                                   secondary_rebar_design, cs_neg_idx, d, fc, fy)
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
    _placed_band_strain_ok(mt, gov, transfer, Ab, rebar_design, secondary_rebar_design,
                           cs_neg_idx, d, fc, fy) -> Bool

ACI 318-11 §13.5.3.3(b) (corpus: aci-318-11, page 250): εt in the §13.5.3.2
effective width is not less than 0.010. Checked on each axis that used (b),
with the steel placed in that band:

- the column-strip top steel of that direction (`rebar_design` for x,
  `secondary_rebar_design` for y) in proportion to `bb / strip width`;
- plus every bar this pass adds at the column, whichever band it was sized
  for, which can only lower εt;
- and never less than the band's required transfer steel.

An axis with no transfer moment is skipped. A y-axis (b) increase with no
secondary-direction design cannot be checked and fails.
"""
function _placed_band_strain_ok(mt, gov, transfer, Ab, rebar_design,
                                secondary_rebar_design, cs_neg_idx, d, fc, fy)
    added = transfer === nothing ? 0.0u"inch^2" : transfer.n_bars_additional * Ab
    for (provision, As_req, bb, design) in
            ((mt.provision_x, gov.As_x, gov.bb_x, rebar_design),
             (mt.provision_y, gov.As_y, gov.bb_y, secondary_rebar_design))
        provision === :aci_13_5_3_3b || continue
        ustrip(u"inch^2", As_req) > 0 || continue
        design === nothing && return false
        As_cs = design.column_strip_reinf[cs_neg_idx].As_provided
        As_band = As_cs * (bb / design.column_strip_width) + added
        As_placed = max(As_band, As_req)
        transfer_band_net_tensile_strain(As_placed, bb, d, fc, fy) >= 0.010 - 1e-12 ||
            return false
    end
    return true
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
                                          verbose::Bool = false, kwargs...)
    pass = _transfer_reinforcement_pass(
        columns, moment_results, secondary_results, rebar_design, h, d, fc, fy;
        kwargs...,
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

