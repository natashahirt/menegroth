# =============================================================================
# Slab thickness jump
# =============================================================================
# One uniform-pressure analysis predicts the other half-inch thicknesses.
# The sizing loop confirms the prediction with one real analysis.

"""Demand fields that scale with the uniform factored pressure."""
const _SCALED_DEMAND_KEYS = (
    :M0, :M_neg_ext, :M_neg_int, :M_pos,
    :column_moments, :column_shears, :unbalanced_moments,
    :stub_moments_below, :stub_moments_above,
    :Vu_max, :M_wall_ext, :M_wall_int,
)

"""
    governing_uniform_pressure(qD, qL) -> Pressure

Larger of `1.2D + 1.6L` and `1.4D`.

Same pair `_moment_analysis_setup` stores on `MomentAnalysisResult.qu`.
"""
function governing_uniform_pressure(qD, qL)
    return max(factored_pressure(default_combo, qD, qL),
               factored_pressure(strength_1_4D, qD, qL))
end

"""
    loads_at_thickness(qD0, qL, h0, h, γ) -> (qD, qu)

Dead load at thickness `h` from an analysis at `h0`.

Superimposed dead load is `qD0 − h0·ρ·g`. Self-weight at the new thickness
is `h·ρ·g` (`slab_self_weight`). `qu` is `governing_uniform_pressure`.
"""
function loads_at_thickness(qD0, qL, h0, h, γ)
    sdl = qD0 - slab_self_weight(h0, γ)
    qD = sdl + slab_self_weight(h, γ)
    return (qD = qD, qu = governing_uniform_pressure(qD, qL))
end

"""
    thickness_scale_applies(result, drop_panel, h0, γ; stiffness_depends_on_h=false) -> Bool

True when moments and a gross elastic displacement can be scaled from `result`.

Scaling needs one uniform pressure. Pattern loading envelopes two patterns.
A drop panel's self-weight is not `h·ρ·g` over the whole panel. An edge-beam
`βt` recomputed from `h` changes the DDM coefficients. A stored dead load
below the self-weight at `h0` is not this split, so the scale is refused.
"""
function thickness_scale_applies(result, drop_panel, h0, γ; stiffness_depends_on_h::Bool = false)
    stiffness_depends_on_h && return false
    drop_panel !== nothing && return false
    result.pattern_loading && return false
    sdl = result.qD - slab_self_weight(h0, γ)
    return ustrip(psf, sdl) >= -1.0
end

_scale_demand(v::AbstractArray, r) = v .* r
_scale_demand(v, r) = v * r

function _scale_named_demands(nt::NamedTuple, r, qD, qu)
    vals = map(keys(nt)) do k
        v = nt[k]
        if k === :qu
            qu
        elseif k === :qD
            qD
        elseif k in _SCALED_DEMAND_KEYS
            _scale_demand(v, r)
        else
            v
        end
    end
    return NamedTuple{keys(nt)}(vals)
end

"""
    scale_moment_result(result, r, dscale, qD, qu) -> MomentAnalysisResult

Copy `result` with demands multiplied by `r = qu(h) / qu(h0)` and the gross
elastic panel displacement multiplied by `dscale`.

`dscale` is `r · (h0 / h)^3`. For a uniform pressure that product is the
split between superimposed load, which moves as `1/h^3`, and self-weight,
which moves as `1/h^2`, because self-weight pressure itself grows with `h`.
Column sizes and support locations stay the ones used in `result`.
"""
function scale_moment_result(result::MomentAnalysisResult, r, dscale, qD, qu)
    secondary = _scale_secondary(result.secondary, r, dscale, qD, qu)
    fea = result.fea_Δ_panel === nothing ? nothing : result.fea_Δ_panel * dscale
    scaled(v) = v === nothing ? nothing : v .* r
    return MomentAnalysisResult(
        result.M0 * r,
        result.M_neg_ext * r,
        result.M_neg_int * r,
        result.M_pos * r,
        qu, qD, result.qL,
        result.l1, result.l2, result.ln, result.c_avg,
        result.column_moments .* r,
        result.column_shears .* r,
        result.unbalanced_moments .* r,
        result.Vu_max * r;
        secondary = secondary,
        fea_Δ_panel = fea,
        pattern_loading = result.pattern_loading,
        M_wall_ext = result.M_wall_ext * r,
        M_wall_int = result.M_wall_int * r,
        M_neg_ext_face = scaled(result.M_neg_ext_face),
        M_neg_int_face = scaled(result.M_neg_int_face),
        stub_moments_below = scaled(result.stub_moments_below),
        stub_moments_above = scaled(result.stub_moments_above),
        wall_transfer = result.wall_transfer === nothing ? nothing :
            [(seg = w.seg, M = w.M * r) for w in result.wall_transfer],
    )
end

_scale_secondary(::Nothing, r, dscale, qD, qu) = nothing
_scale_secondary(sec::NamedTuple, r, dscale, qD, qu) = _scale_named_demands(sec, r, qD, qu)
_scale_secondary(sec::MomentAnalysisResult, r, dscale, qD, qu) =
    scale_moment_result(sec, r, dscale, qD, qu)

"""Half-inch thicknesses strictly above `h` and not above `h_max`."""
function _thickness_candidates(h::Length, h_increment::Length, h_max::Length)
    out = Length[]
    candidate = round_up_thickness(h + h_increment, h_increment)
    while candidate <= h_max + 1e-6u"inch"
        push!(out, candidate)
        nxt = round_up_thickness(candidate + h_increment, h_increment)
        nxt <= candidate + 1e-9u"inch" && break
        candidate = nxt
    end
    return out
end

"""
    propose_slab_thickness(h, h_increment, h_max, primary, secondary, γ; kwargs...) -> Length

Thinnest half-inch above `h`, and at most `h_max`, for which `passes` is true.

`passes(h_candidate, scaled_primary, scaled_secondary)` sees the analysis
scaled from the thickness `h` that produced `primary`. When the scale does
not apply, the result is one increment above `h`. When no candidate passes,
the result is one increment above the last candidate, which is past `h_max`,
so the sizing loop's `h > ℓn/10` guard stops the search.
"""
function propose_slab_thickness(h::Length, h_increment::Length, h_max::Length,
                                primary, secondary, γ;
                                drop_panel = nothing,
                                stiffness_depends_on_h::Bool = false,
                                passes = (hh, scaled_p, scaled_s) -> true)
    step = round_up_thickness(h + h_increment, h_increment)
    if !thickness_scale_applies(primary, drop_panel, h, γ;
                                stiffness_depends_on_h = stiffness_depends_on_h)
        return step
    end
    candidates = _thickness_candidates(h, h_increment, h_max)
    isempty(candidates) && return step
    qu0 = governing_uniform_pressure(primary.qD, primary.qL)
    qu0 == zero(qu0) && return step
    for candidate in candidates
        loads = loads_at_thickness(primary.qD, primary.qL, h, candidate, γ)
        r = ustrip(loads.qu / qu0)
        dscale = r * ustrip((h / candidate)^3)
        scaled_p = scale_moment_result(primary, r, dscale, loads.qD, loads.qu)
        scaled_s = _scale_secondary(secondary, r, dscale, loads.qD, loads.qu)
        if passes(candidate, scaled_p, scaled_s)
            return candidate
        end
    end
    return round_up_thickness(candidates[end] + h_increment, h_increment)
end

"""
    FLAT_PLATE_MIDSPAN_RHO_PRIME

Compression-steel ratio ρ′ used in the long-term multiplier
`λΔ = ξ / (1 + 50ρ′)`, ACI 318-11 §9.5.2.5 Eq. (9-11) (corpus: aci-318-11,
page 132). The clause takes ρ′ at midspan for simple and continuous spans.
The flat-plate reinforcement design places top bars only in the negative
moment regions at the supports and bottom bars at midspan, so no compression
steel passes through midspan and ρ′ = 0.
"""
const FLAT_PLATE_MIDSPAN_RHO_PRIME = 0.0

"""
    two_way_deflection(results, h, d, fc, fy, Es, Ecs, spans, γ, columns;
                       drop_panel=nothing, kwargs...) -> NamedTuple

`check_two_way_deflection`, with the composite drop-panel section when
`drop_panel` is given.
"""
function two_way_deflection(results, h, d, fc, fy, Es, Ecs, spans, γ, columns;
                            drop_panel = nothing, kwargs...)
    args = (results, h, d, fc, fy, Es, Ecs, spans, γ, columns)
    drop_panel === nothing && return check_two_way_deflection(args...; kwargs...)
    return check_two_way_deflection(args..., drop_panel; kwargs...)
end

"""
    secondary_two_way_deflection(moment_results, secondary_results, h, d_inner, fc, fy,
                                 Es, Ecs, spans, γ, columns; drop_panel=nothing, kwargs...)

Deflection along the secondary span: spans swapped, the secondary moments
on the primary loads (and FEA panel displacement, when present). The
secondary bars are the inner layer, so `Icr` uses `d_inner`. ρ′ is
`FLAT_PLATE_MIDSPAN_RHO_PRIME`.
"""
function secondary_two_way_deflection(moment_results, secondary_results, h, d_inner,
                                      fc, fy, Es, Ecs, spans, γ, columns;
                                      drop_panel = nothing, kwargs...)
    sec_spans = (primary = spans.secondary, secondary = spans.primary)
    proxy = (
        M_pos     = secondary_results.M_pos,
        M_neg_ext = secondary_results.M_neg_ext,
        M_neg_int = secondary_results.M_neg_int,
        qu        = moment_results.qu,
        qD        = moment_results.qD,
        qL        = moment_results.qL,
        fea_Δ_panel = hasproperty(moment_results, :fea_Δ_panel) ?
                      moment_results.fea_Δ_panel : nothing,
    )
    return two_way_deflection(proxy, h, d_inner, fc, fy, Es, Ecs, sec_spans, γ, columns;
                              drop_panel = drop_panel,
                              ρ_prime = FLAT_PLATE_MIDSPAN_RHO_PRIME, kwargs...)
end

"""
    phase_a_depth_passes(moment_results, secondary_results, h, d, ...) -> Bool

Deflection, one-way shear, flexure, and the transfer section at one thickness.

Same functions the Phase A loop uses after column sizes have stopped changing,
including the drop panel when one is given. A check that throws is a failure,
matching the loop. `struc === nothing` skips the wall shear and the
wall-strip flexure. `cover` and `bar_diameter`, when given, set the
inner-layer depth used for the secondary deflection, one-way shear and
transfer moment (otherwise `d`). Deflection and one-way shear are checked in
both directions. `λ` (required) is the lightweight factor used by the
modulus of rupture and the shear strengths.
"""
function phase_a_depth_passes(moment_results, secondary_results, h, d,
                              fc, fy, Es, Ecs, spans, γ, columns;
                              struc = nothing, slab = nothing,
                              limit_type::Symbol = :L_360,
                              deflection_Ie_method::Symbol = :aci318_19,
                              λ::Real, φ_shear::Float64 = 0.75,
                              βt::Float64 = 0.0, span_axis = nothing,
                              cover = nothing, bar_diameter = nothing,
                              drop_panel = nothing)
    d_inner = cover === nothing || bar_diameter === nothing ? nothing :
              inner_layer_effective_depth(h, cover, bar_diameter, bar_diameter)
    defl_kw = (; drop_panel = drop_panel, limit_type = limit_type,
               deflection_Ie_method = deflection_Ie_method, λ = λ)

    defl_ok = try
        two_way_deflection(moment_results, h, d, fc, fy, Es, Ecs, spans, γ, columns;
                           ρ_prime = FLAT_PLATE_MIDSPAN_RHO_PRIME, defl_kw...).ok
    catch e
        @debug "Deflection check (primary) failed" exception = (e, catch_backtrace())
        false
    end
    defl_ok || return false

    if secondary_results !== nothing
        sec_ok = try
            secondary_two_way_deflection(moment_results, secondary_results, h,
                                         something(d_inner, d), fc, fy, Es, Ecs, spans, γ,
                                         columns; defl_kw...).ok
        catch e
            @debug "Deflection check (secondary) failed" exception = (e, catch_backtrace())
            false
        end
        sec_ok || return false
    end

    shear = check_one_way_shear(moment_results, d, fc; h = h, fy = fy, λ = λ, φ_shear = φ_shear)
    shear.ok || return false
    if _has_frame_strip(secondary_results)
        sec_shear = check_one_way_shear(secondary_results, something(d_inner, d), fc;
                                        h = h, fy = fy, λ = λ, φ_shear = φ_shear)
        sec_shear.ok || return false
    end
    if struc !== nothing && slab !== nothing
        wall_shear = wall_one_way_shear(struc, slab, d, fc, moment_results.qu; h = h, fy = fy,
                                        λ = λ, ϕ = φ_shear)
        all(c -> c.ok, wall_shear) || return false
    end

    flexure = check_flexural_adequacy(moment_results, columns, d, fc; fy = fy,
                                      βt = βt, struc = struc, slab = slab,
                                      span_axis = span_axis, drop = drop_panel)
    flexure.ok || return false
    secondary_flexural_adequacy(secondary_results, columns, something(d_inner, d), fc, fy;
                                βt = βt, struc = struc, slab = slab,
                                span_axis = span_axis, drop = drop_panel).ok || return false
    return _transfer_sections_adequate(columns, moment_results, secondary_results,
                                       h, d, fc, fy;
                                       span_axis = something(span_axis, (1.0, 0.0)),
                                       d_secondary = d_inner)
end

"""
    secondary_flexural_adequacy(secondary_results, columns, d_inner, fc, fy; βt, struc, slab, span_axis)

`check_flexural_adequacy` along the secondary span at the inner-layer depth,
with the strip classification and the drop panel (`drop`, in primary
orientation) turned to the perpendicular axis. Passes when there are no
secondary moments.
"""
function secondary_flexural_adequacy(secondary_results, columns, d_inner, fc, fy;
                                     βt::Float64 = 0.0, struc = nothing, slab = nothing,
                                     span_axis = nothing, verbose::Bool = false,
                                     drop = nothing)
    _has_frame_strip(secondary_results) && hasproperty(secondary_results, :column_moments) ||
        return (ok = true, max_ratio = 0.0, governing_strip = :none)
    ax = something(span_axis, (1.0, 0.0))
    r = check_flexural_adequacy(secondary_results, columns, d_inner, fc; fy = fy,
                                βt = βt, struc = struc, slab = slab,
                                span_axis = (-ax[2], ax[1]), verbose = verbose,
                                drop = _transposed_drop(drop))
    return (ok = r.ok, max_ratio = r.max_ratio,
            governing_strip = Symbol("secondary_", r.governing_strip))
end

"""True when `r` carries the frame-strip quantities `check_one_way_shear` needs."""
_has_frame_strip(r) = r !== nothing &&
    all(p -> hasproperty(r, p), (:qu, :l2, :ln, :M_neg_ext, :M_neg_int))

"""
    punching_depth_passes(moment_results, secondary_results, columns, h, d, fc, struc, slab; kwargs...) -> Bool

Every column and every wall reaction passes punching at this depth.

Column size is the size already chosen. Demand is the scaled analysis.
Openings use `column_opening_punching` when a structure is supplied.
This is the last-resort thickness, after column growth and reinforcement
have already been refused. With a `drop_panel` (and the `cover` and
`bar_diameter` that set its depth) the flat-slab `check_punching` is used,
as in the Phase B loop.
"""
function punching_depth_passes(moment_results, secondary_results, columns, h, d, fc,
                               struc, slab; λ::Float64 = 1.0, φ_shear::Float64 = 0.75,
                               moment_transfer = nothing, drop_panel = nothing,
                               cover = nothing, bar_diameter = nothing)
    use_drop = drop_panel !== nothing && cover !== nothing && bar_diameter !== nothing
    if use_drop
        h_total = total_depth_at_drop(h, drop_panel)
        d_total = effective_depth(h_total; cover = cover, bar_diameter = bar_diameter)
    end
    for (i, col) in enumerate(columns)
        Muy = secondary_results === nothing ? nothing : secondary_results.unbalanced_moments[i]
        kwargs = (struc === nothing || slab === nothing) ? (;) :
                 punching_axis_kwargs(struc, slab, col)
        Vu = moment_results.column_shears[i]
        Mub = moment_results.unbalanced_moments[i]
        result = if use_drop
            check_punching(col, Vu, Mub, h, d, h_total, d_total, fc, drop_panel;
                           qu = moment_results.qu, Muy = Muy, verbose = false, col_idx = i,
                           λ = λ, φ_shear = φ_shear, kwargs...)
        else
            check_punching_for_column(col, Vu, Mub, d, h, fc;
                verbose = false, col_idx = i, λ = λ, φ_shear = φ_shear, Muy = Muy,
                moment_transfer = moment_transfer, kwargs...)
        end
        result.ok || return false
    end
    if struc !== nothing && slab !== nothing
        checks = wall_reaction_punching(struc, slab, d, fc, moment_results.qu;
                                        λ = λ, ϕ = φ_shear,
                                        wall_transfer = wall_transfer_of(moment_results,
                                                                         secondary_results))
        all(c -> c.ok, checks) || return false
    end
    return true
end
