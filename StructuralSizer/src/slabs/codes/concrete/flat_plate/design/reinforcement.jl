# =============================================================================
# Flat Plate Reinforcement Design
# =============================================================================
#
# Strip reinforcement design per ACI 318-11 §13.6.4 (transverse distribution).
#
# Note: This file is included in StructuralSizer, inheriting Logging, etc.
# =============================================================================

# =============================================================================
# Strip Reinforcement Design
# =============================================================================

"""
    _design_strips_from_moments(M_neg_ext_cs, M_neg_int_cs, M_pos_cs,
                                M_neg_ext_ms, M_neg_int_ms, M_pos_ms,
                                l1, l2, d, fc, fy, h; label="", verbose=false,
                                drop_stations=nothing)

Shared core: given six Unitful design moments (column-strip and middle-strip
for exterior negative, positive, and interior negative), design reinforcement
for all strip locations. With a drop panel, `drop_stations = (ext, int)`
(`_drop_cs_stations`) sets the column-strip negative steel.

Strip widths follow ACI 318-11 §13.2.1 (verbatim):

  "Column strip is a design strip with a width on each side of a column
   centerline equal to 0.25·ℓ2 or 0.25·ℓ1, whichever is less."

so the **total** column-strip width is `min(ℓ1, ℓ2)/2` and (per §13.2.2)
the middle strip is bounded by two column strips:
`ms_width = ℓ2 − cs_width = ℓ2 − min(ℓ1, ℓ2)/2`.

Returns the standard named tuple
`(column_strip_width, column_strip_reinf, middle_strip_width,
  middle_strip_reinf, section_adequate)`.
"""
function _design_strips_from_moments(
    M_neg_ext_cs, M_neg_int_cs, M_pos_cs,
    M_neg_ext_ms, M_neg_int_ms, M_pos_ms,
    l1, l2, d, fc, fy, h;
    label::String = "",
    verbose::Bool = false,
    drop_stations = nothing,
)
    # ACI 318-11 §13.2.1 / §13.2.2 — column-strip width is governed by the
    # SHORTER of ℓ1 and ℓ2 (one quarter of min(ℓ1,ℓ2) on each side of the
    # column line); the middle strip occupies the remainder of ℓ2.
    cs_width = min(l1, l2) / 2
    ms_width = l2 - cs_width

    column_strip_reinf = StripReinforcement[
        design_single_strip(:ext_neg, M_neg_ext_cs, cs_width, d, fc, fy, h;
                            stations = drop_stations === nothing ? nothing : drop_stations.ext),
        design_single_strip(:pos,     M_pos_cs,     cs_width, d, fc, fy, h),
        design_single_strip(:int_neg, M_neg_int_cs, cs_width, d, fc, fy, h;
                            stations = drop_stations === nothing ? nothing : drop_stations.int),
    ]

    middle_strip_reinf = StripReinforcement[
        design_single_strip(:pos,     M_pos_ms,     ms_width, d, fc, fy, h),
        design_single_strip(:int_neg, M_neg_int_ms, ms_width, d, fc, fy, h),
    ]
    # Exterior negative in the middle strip is zero for a flat plate with
    # βt = 0, so it is omitted unless the fraction actually assigns moment.
    if abs(M_neg_ext_ms) > 1.0u"N*m"
        push!(middle_strip_reinf, design_single_strip(
            :ext_neg, M_neg_ext_ms, ms_width, d, fc, fy, h))
    end

    all_strips = vcat(column_strip_reinf, middle_strip_reinf)
    section_adequate = all(sr.section_adequate for sr in all_strips)

    if verbose
        tag = isempty(label) ? "Column strip" : "Column strip ($label)"
        @debug tag width=cs_width
        for sr in column_strip_reinf
            @debug "  $(sr.location)" Mu=uconvert(kip*u"ft", sr.Mu) As_reqd=sr.As_reqd As_provided=sr.As_provided adequate=sr.section_adequate
        end
        tag_ms = isempty(label) ? "Middle strip" : "Middle strip ($label)"
        @debug tag_ms width=ms_width
        for sr in middle_strip_reinf
            @debug "  $(sr.location)" Mu=uconvert(kip*u"ft", sr.Mu) As_reqd=sr.As_reqd As_provided=sr.As_provided adequate=sr.section_adequate
        end
    end

    return (
        column_strip_width = cs_width,
        column_strip_reinf = column_strip_reinf,
        middle_strip_width = ms_width,
        middle_strip_reinf = middle_strip_reinf,
        section_adequate   = section_adequate,
    )
end

"""
    _negative_moment_bins(col, span_axis) -> (exterior::Bool, interior::Bool)

Which negative-moment strip a column's span moment is distributed in. ACI
318-11 §13.6.4.1 / §13.6.4.2 (corpus: aci-318-11, page 255) are written per
support in the span direction: an interior support has slab on both sides
along the span, an exterior support is where the slab ends.

- Interior column: interior support.
- Corner column: the slab ends along both spans, exterior.
- Edge column: exterior when the span runs perpendicular to the free edge;
  interior when it runs along the edge (the slab continues past the column
  in the span direction). With no stored edge direction, or an edge skew to
  the span, both strips take the moment.
- No `span_axis`: edge columns are exterior.
"""
function _negative_moment_bins(col, span_axis)
    col.position == :interior && return (false, true)
    col.position == :edge || return (true, false)
    span_axis === nothing && return (true, false)
    perp = _span_moment_about_edge_axis(col, span_axis)
    perp === nothing && return (true, true)
    return perp ? (true, false) : (false, true)
end

"""
    design_strip_reinforcement(moment_results, columns, h, d, fc, fy, cover; verbose=false)

Design strip reinforcement using ACI 318-11 §13.6.4/.6 transverse distribution.

Design moments are derived from `moment_results.column_moments` — the
per-column moment vector populated by DDM, EFM, or FEA.  ACI transverse
distribution factors are applied per-column and then enveloped:

- Exterior supports: the §13.6.4.2 βt fraction → column strip
- Interior supports: 75% / 25% → column strip / middle strip
- Positive: 60% / 40% → column strip / middle strip

Exterior or interior is per support along the span, not the column's
position in plan (`_negative_moment_bins`).

# Arguments
- `moment_results`: MomentAnalysisResult (column_moments is the primary data)
- `columns`: Vector of column structs with `.position` field
- `h`: Slab thickness
- `d`: Effective depth
- `fc`, `fy`: Material strengths
- `cover`: Clear cover
- `drop`: drop panel oriented with `a_drop_1` along this span, or `nothing`.
  The column-strip negative steel then checks the column face on the
  §13.3.7 drop section, and the wall faces and the drop edge on the slab
  section (`_negative_cs_stations`).

# Returns
Named tuple with column_strip and middle_strip reinforcement vectors.
"""
function design_strip_reinforcement(moment_results, columns, h, d, fc, fy, cover;
                                    βt::Float64 = 0.0, verbose=false,
                                    struc=nothing, slab=nothing, span_axis=nothing,
                                    drop=nothing)
    l1, l2 = moment_results.l1, moment_results.l2
    section = drop_negative_section(drop, columns, d, min(l1, l2) / 2)
    s = aci_strip_moments(moment_results, columns; βt = βt, struc = struc, slab = slab,
                          span_axis = span_axis,
                          drop_edge = section === nothing ? nothing : section.x_edge)
    return _design_strips_from_moments(
        s.M_neg_ext_cs, s.M_neg_int_cs, s.M_pos_cs,
        s.M_neg_ext_ms, s.M_neg_int_ms, s.M_pos_ms,
        l1, l2, d, fc, fy, h;
        label="ACI fractions", verbose=verbose,
        drop_stations = _drop_cs_stations(s, min(l1, l2) / 2, d, section),
    )
end

"""
    aci_strip_moments(moment_results, columns; βt=0, struc=nothing, slab=nothing,
                      span_axis=nothing) -> NamedTuple

Column- and middle-strip design moments from the frame moments, ACI 318-11
§13.6.4 / §13.6.6 (corpus: aci-318-11, page 255). Each column's
`column_moments[i]` is distributed as an exterior or interior support moment
along the span (`_negative_moment_bins`) and enveloped. Short walls
(`short_wall_flexure_moments`) and the analysis wall-joint moments are
distributed with the same fractions. Fractions come from
`slab_column_strip_fractions` when the structure and span are known
(75/25 interior, the βt interpolation exterior, 60/40 positive otherwise).

Returns `(M_neg_ext_cs, M_neg_int_cs, M_pos_cs, M_neg_ext_ms, M_neg_int_ms,
M_pos_ms)`. Shared by `design_strip_reinforcement` and
`check_flexural_adequacy`, so the depth check and the steel see the same
moments.

The column-strip negative envelopes are also split by station, for a
flat slab whose column faces sit inside a drop panel: `cs_col_ext/int`
(column faces), `cs_wall_ext/int` (wall faces, no drop), and
`cs_edge_ext/int` (the drop edge, `drop_edge` past each column face).
The drop-edge moment comes from the clear-span statics
([`efm_span_hogging`](@ref) over `ln` with `w = qu·l2`) starting from the
column's face moment. ENGINEERING JUDGMENT: the far end takes the larger
negative envelope, which gives the smallest end shear and so the largest
moment at the drop edge, and the drop's own weight is left out, which
also only raises that moment. A result without `qu` and `ln` keeps the
face moment at the drop edge.
"""
function aci_strip_moments(moment_results, columns; βt::Float64 = 0.0,
                           struc = nothing, slab = nothing, span_axis = nothing,
                           drop_edge = nothing)
    l1 = moment_results.l1
    l2 = moment_results.l2
    fracs = if struc !== nothing && slab !== nothing && span_axis !== nothing
        slab_column_strip_fractions(struc, slab, columns, span_axis, l1, l2, βt)
    else
        (cs_int_neg = 0.75, cs_ext_neg = aci_col_strip_ext_neg_fraction(βt), cs_pos = 0.60)
    end
    cs_ext = fracs.cs_ext_neg
    cs_int = fracs.cs_int_neg
    wall_M = if struc !== nothing && slab !== nothing
        short_wall_flexure_moments(struc, slab, columns, moment_results.qu, l2;
                                   span_axis = span_axis)
    else
        nothing
    end

    z = zero(moment_results.M0)
    ext_cs = ext_ms = int_cs = int_ms = z
    col_ext = col_int = wall_ext = wall_int = edge_ext = edge_int = z
    add_ext(m) = (ext_cs = max(ext_cs, cs_ext * m); ext_ms = max(ext_ms, (1 - cs_ext) * m))
    add_int(m) = (int_cs = max(int_cs, cs_int * m); int_ms = max(int_ms, (1 - cs_int) * m))
    add_wall_ext(m) = (add_ext(m); wall_ext = max(wall_ext, cs_ext * m))
    add_wall_int(m) = (add_int(m); wall_int = max(wall_int, cs_int * m))

    at_edge = if drop_edge === nothing
        m -> z
    elseif !(hasproperty(moment_results, :qu) && hasproperty(moment_results, :ln))
        m -> m
    else
        w = moment_results.qu * l2
        M_far = max(moment_results.M_neg_ext, moment_results.M_neg_int)
        m -> max(uconvert(unit(z), efm_span_hogging(drop_edge, m, M_far, w,
                                                     moment_results.ln)), z)
    end

    for (i, col) in enumerate(columns)
        m = moment_results.column_moments[i]
        ext, int = _negative_moment_bins(col, span_axis)
        if int
            add_int(m)
            col_int = max(col_int, cs_int * m)
            edge_int = max(edge_int, cs_int * at_edge(m))
        end
        if ext
            add_ext(m)
            col_ext = max(col_ext, cs_ext * m)
            edge_ext = max(edge_ext, cs_ext * at_edge(m))
        end
    end
    if wall_M !== nothing
        add_wall_ext(wall_M.M_ext)
        add_wall_int(wall_M.M_int)
    end
    # The frame's wall-joint moment is the strip moment; it is not in column_moments.
    if hasproperty(moment_results, :M_wall_ext)
        add_wall_ext(moment_results.M_wall_ext)
        add_wall_int(moment_results.M_wall_int)
    end

    M_pos = moment_results.M_pos
    wall_M !== nothing && (M_pos = max(M_pos, wall_M.M_pos))
    return (M_neg_ext_cs = ext_cs, M_neg_int_cs = int_cs, M_pos_cs = fracs.cs_pos * M_pos,
            M_neg_ext_ms = ext_ms, M_neg_int_ms = int_ms, M_pos_ms = (1 - fracs.cs_pos) * M_pos,
            cs_col_ext = col_ext, cs_col_int = col_int,
            cs_wall_ext = wall_ext, cs_wall_int = wall_int,
            cs_edge_ext = edge_ext, cs_edge_int = edge_int)
end

"""
    _negative_cs_stations(M_col, M_wall, M_edge, b_cs, d, section) -> Vector

Sections a negative column-strip moment must pass when the column faces sit
in a drop panel (`section` from [`drop_negative_section`](@ref)). Each
entry is a station; each station lists `(Mu, b, d)` sections, any one of
which may carry it:

- column face: the stronger of the slab section `(b_cs, d)` and the drop
  section `(b_drop, d_drop)`. Both leave out concrete that is there, so
  either is a lower bound (ENGINEERING JUDGMENT);
- wall face: the slab section (a wall has no drop);
- drop edge: the slab section, at the drop-edge moment.
"""
_negative_cs_stations(M_col, M_wall, M_edge, b_cs, d, section) = [
    [(M_col, b_cs, d), (M_col, section.b, section.d)],
    [(M_wall, b_cs, d)],
    [(M_edge, b_cs, d)],
]

"""
    _stations_As(stations, fc, fy) -> Area

Steel for a set of stations: every station must pass, on its best section.
`Inf` when some station has no tension-controlled section.
"""
function _stations_As(stations, fc, fy)
    εt = tension_controlled_strain(fy)
    return maximum(stations) do alts
        minimum(((M, b, dd),) -> required_reinforcement(M, b, dd, fc, fy; εt_min = εt), alts)
    end
end

"""
    _drop_cs_stations(s, b_cs, d, section) -> Union{Nothing, NamedTuple}

`(ext, int)` station lists for the column-strip negative moments in
`s = aci_strip_moments(...)`, or `nothing` without a drop section.
"""
function _drop_cs_stations(s, b_cs, d, section)
    section === nothing && return nothing
    return (ext = _negative_cs_stations(s.cs_col_ext, s.cs_wall_ext, s.cs_edge_ext,
                                        b_cs, d, section),
            int = _negative_cs_stations(s.cs_col_int, s.cs_wall_int, s.cs_edge_int,
                                        b_cs, d, section))
end

"""
    design_strip_reinforcement_fea(fea_strip_moments, l1, l2, h, d, fc, fy, cover; verbose=false)

Design strip reinforcement using FEA-derived strip moments (direct integration).

Instead of applying ACI 318-11 §13.6.4/.6 tabulated fractions to frame-level moments,
this function uses column-strip and middle-strip moments extracted directly
from the shell model via `_extract_fea_strip_moments`.

# Arguments
- `fea_strip_moments`: NamedTuple from `_extract_fea_strip_moments` with
  `M_neg_ext_cs`, `M_neg_int_cs`, `M_pos_cs`, `M_neg_ext_ms`, `M_neg_int_ms`, `M_pos_ms`
  (bare Float64 in N·m).
- `l1`: Panel span in primary direction (for ACI 318-11 §13.2.1 strip-width rule)
- `l2`: Panel tributary width (for strip width calculation)
- `h`, `d`, `fc`, `fy`, `cover`: Same as `design_strip_reinforcement`

# Returns
Same named tuple format as `design_strip_reinforcement`.
"""
function design_strip_reinforcement_fea(fea_strip_moments, l1, l2, h, d, fc, fy, cover;
                                        verbose=false, drop_stations=nothing)
    # Convert bare N·m to Unitful moments
    M_neg_ext_cs = fea_strip_moments.M_neg_ext_cs * u"N*m"
    M_neg_int_cs = fea_strip_moments.M_neg_int_cs * u"N*m"
    M_pos_cs     = fea_strip_moments.M_pos_cs * u"N*m"
    M_neg_ext_ms = fea_strip_moments.M_neg_ext_ms * u"N*m"
    M_neg_int_ms = fea_strip_moments.M_neg_int_ms * u"N*m"
    M_pos_ms     = fea_strip_moments.M_pos_ms * u"N*m"

    return _design_strips_from_moments(
        M_neg_ext_cs, M_neg_int_cs, M_pos_cs,
        M_neg_ext_ms, M_neg_int_ms, M_pos_ms,
        l1, l2, d, fc, fy, h;
        label="FEA direct", verbose=verbose, drop_stations=drop_stations,
    )
end

"""
    _fea_drop_stations(column_strips, strips, moment_results, columns, d, l1, l2, drop;
                       βt, struc, slab, span_axis) -> Union{Nothing, NamedTuple}

`(ext, int)` column-strip negative stations for shell strip moments.
`column_strips` are the column-face cuts, `strips` the same after
`_add_wall_face_to_strips` (bare N·m). The drop-edge moment is the
column-face cut scaled by the frame statics' edge/face ratio from
`aci_strip_moments`. A bin that also carries a wall-face moment keeps
the summed moment on the slab section, without the drop.
"""
function _fea_drop_stations(column_strips, strips, moment_results, columns, d, l1, l2, drop;
                            βt::Float64 = 0.0, struc = nothing, slab = nothing,
                            span_axis = nothing)
    b_cs = min(l1, l2) / 2
    section = drop_negative_section(drop, columns, d, b_cs)
    section === nothing && return nothing
    s = aci_strip_moments(moment_results, columns; βt = βt, struc = struc, slab = slab,
                          span_axis = span_axis, drop_edge = section.x_edge)
    function stations(M_col_Nm, M_all_Nm, face, edge)
        M_col = M_col_Nm * u"N*m"
        M_all = M_all_Nm * u"N*m"
        r = face > zero(face) ? min(ustrip(Unitful.NoUnits, edge / face), 1.0) : 1.0
        M_all > M_col + 1.0u"N*m" && return [[(M_all, b_cs, d)], [(r * M_col, b_cs, d)]]
        return _negative_cs_stations(M_col, zero(M_col), r * M_col, b_cs, d, section)
    end
    return (ext = stations(column_strips.M_neg_ext_cs, strips.M_neg_ext_cs,
                           s.cs_col_ext, s.cs_edge_ext),
            int = stations(column_strips.M_neg_int_cs, strips.M_neg_int_cs,
                           s.cs_col_int, s.cs_edge_int))
end

"""
    design_single_strip(location, Mu, b, d, fc, fy, h) -> StripReinforcement

Design reinforcement for a single strip location.

# Arguments
- `location`: Strip location symbol (:ext_neg, :pos, :int_neg)
- `Mu`: Design moment
- `b`: Strip width
- `d`: Effective depth
- `fc`, `fy`: Material strengths
- `h`: Slab thickness (for minimum reinforcement)
- `stations`: optional `_negative_cs_stations` list; the steel is then the
  governing station's (`_stations_As`) instead of `Mu` on `(b, d)`. Bars are
  still spread over `b`.

# Returns
`StripReinforcement` with `section_adequate = false` if the section is too thin
(moment demand exceeds Whitney block capacity). Caller should increase depth.
"""
function design_single_strip(location::Symbol, Mu, b, d, fc, fy, h; stations = nothing)
    As_reqd = stations === nothing ?
        required_reinforcement(Mu, b, d, fc, fy; εt_min = tension_controlled_strain(fy)) :
        _stations_As(stations, fc, fy)
    As_min = minimum_reinforcement(b, h, fy)

    # Check for inadequate section (whitney.jl returns Inf when term > 1)
    if isinf(As_reqd)
        # Return a placeholder result with section_adequate = false
        return StripReinforcement(
            location,
            to_newton_meters(Mu) * u"N*m",
            Inf * u"m^2",
            uconvert(u"m^2", As_min),
            Inf * u"m^2",
            0,              # no bar size
            0.0u"m",        # no spacing
            0,              # no bars
            false           # section_adequate = false
        )
    end

    As_design = max(As_reqd, As_min)
    # ACI 318-11 §13.3.2 + §7.6.5 — pass the slab-thickness-dependent maximum
    # so thin slabs honor the 2h cap (the default 18″ is the §7.6.5 ceiling
    # only and is unconservative for h < 9″).
    bars = select_bars(As_design, b; max_spacing=max_bar_spacing(h))
    
    # Normalize all values to coherent SI (m², m, N·m)
    # Use to_newton_meters for moment (handles kip·ft → N·m conversion)
    return StripReinforcement(
        location,
        to_newton_meters(Mu) * u"N*m",
        uconvert(u"m^2", As_reqd),
        uconvert(u"m^2", As_min),
        uconvert(u"m^2", bars.As_provided),
        bars.bar_size,
        uconvert(u"m", bars.spacing),
        bars.n_bars,
        true            # section_adequate = true
    )
end

"""
Moments from a wall that is too short to use §13.6.4.3.

The wall-face moment used for design is the one on the analysis result.
This does not add a second moment from `qu`.
"""
function short_wall_flexure_moments(struc, slab, columns, qu, l2; span_axis = nothing)
    z = zero(qu) * l2^2 * l2
    return (M_ext = z, M_int = z, M_pos = z)
end

"""Largest moment that receives top bars: a column face or a wall face."""
function _top_bar_moment(moment_results)
    z = zero(moment_results.M0)
    m = isempty(moment_results.column_moments) ? z :
        maximum(abs, moment_results.column_moments)
    return max(m, abs(moment_results.M_wall_ext), abs(moment_results.M_wall_int))
end

"""
Add the wall-face strip moment to a shell strip envelope.

The shell extraction reports column faces. The wall face is a separate
station. The total is split with the same column-strip fractions the
frame method uses, so the sum of the column and middle strips is the
wall moment.
"""
function _add_wall_face_to_strips(strips, moment_results, struc, slab, columns,
                                  span_axis, l1, l2, βt::Float64)
    Mw_ext = ustrip(u"N*m", moment_results.M_wall_ext)
    Mw_int = ustrip(u"N*m", moment_results.M_wall_int)
    (Mw_ext <= 0 && Mw_int <= 0) && return strips
    fracs = slab_column_strip_fractions(struc, slab, columns, span_axis, l1, l2, βt)
    return (
        M_neg_ext_cs = strips.M_neg_ext_cs + fracs.cs_ext_neg * Mw_ext,
        M_neg_int_cs = strips.M_neg_int_cs + fracs.cs_int_neg * Mw_int,
        M_pos_cs     = strips.M_pos_cs,
        M_neg_ext_ms = strips.M_neg_ext_ms + (1 - fracs.cs_ext_neg) * Mw_ext,
        M_neg_int_ms = strips.M_neg_int_ms + (1 - fracs.cs_int_neg) * Mw_int,
        M_pos_ms     = strips.M_pos_ms,
    )
end

"""
ACI 318-11 §12.2.2 "other cases" development length of a deformed bar in tension
(corpus: aci-318-11, page 214). The spacing-and-cover row is not used, because
the bar's clear spacing and cover inside the wall are not known. `ψe = 1.0`
for uncoated bars. `ψt` is §12.2.4(a) (page 215); the product `ψt ψe` is not
taken greater than 1.7. `ℓd` is not less than 12 in. (§12.2.1). The §12.2.5
reduction for excess reinforcement is not applied.
"""
function tension_development_length(bar_size::Int, fc::Pressure, fy::Pressure, λ::Real;
                                    ψt::Real = 1.3)
    db_in = ustrip(u"inch", bar_diameter(bar_size))
    fy_psi = ustrip(u"psi", fy)
    sqrt_fc = sqrt(ustrip(u"psi", fc))
    denom = bar_size ≤ 6 ? 50.0 : 40.0
    ψ = min(Float64(ψt) * 1.0, 1.7)
    ld_in = (3.0 * fy_psi * ψ) / (denom * Float64(λ) * sqrt_fc) * db_in
    return max(ld_in, 12.0) * u"inch"
end

"""
ACI 318-11 §12.5.2 development length of a standard hook in tension
(corpus: aci-318-11, page 217). `ℓdh = (0.02 ψe fy / (λ √f'c)) db` with
`ψe = 1.0`, and not less than `8 db` or 6 in. (§12.5.1). The §12.5.3
reductions are not applied.
"""
function hooked_development_length(bar_size::Int, fc::Pressure, fy::Pressure, λ::Real)
    db_in = ustrip(u"inch", bar_diameter(bar_size))
    fy_psi = ustrip(u"psi", fy)
    sqrt_fc = sqrt(ustrip(u"psi", fc))
    ldh_in = (0.02 * 1.0 * fy_psi) / (Float64(λ) * sqrt_fc) * db_in
    return max(ldh_in, 8.0 * db_in, 6.0) * u"inch"
end

"""
ACI 318-11 §12.12.1 (corpus: aci-318-11, page 230): negative-moment
reinforcement is anchored in the supporting member by embedment length,
a hook, or mechanical anchorage. Mechanical anchorage is not detailed here.
`available` is the wall thickness minus the clear cover, measured from the
face where the moment is taken to the far end of the bar.
"""
function wall_negative_anchorage(bar_size::Int, fc::Pressure, fy::Pressure, λ::Real,
                                 thickness::Length, cover::Length; ψt::Real = 1.3)
    available = thickness - cover
    ld = tension_development_length(bar_size, fc, fy, λ; ψt = ψt)
    ldh = hooked_development_length(bar_size, fc, fy, λ)
    straight = available >= ld
    hook = available >= ldh
    return (
        ok = straight || hook,
        anchorage = straight ? :straight : (hook ? :hook : :insufficient),
        available = available,
        ld = ld,
        ldh = ldh,
        bar_size = bar_size,
    )
end

function _largest_strip_bar(rebar_design, location::Symbol)
    best = 0
    for group in (rebar_design.column_strip_reinf, rebar_design.middle_strip_reinf)
        for sr in group
            sr.location == location && sr.bar_size > best && (best = sr.bar_size)
        end
    end
    return best
end

function _min_perpendicular_wall_thickness(struc, slab, span_axis)
    ax = _span_unit_axis(span_axis)
    ax === nothing && return nothing
    tmin = nothing
    for seg in supporting_wall_segments(struc, slab)
        _wall_parallel_to_axis(seg, ax) && continue
        t = _wall_thickness(struc, seg)
        t === nothing && continue
        tmin = tmin === nothing ? t : min(tmin, t)
    end
    return tmin
end

"""
Anchorage of the top bars that were sized for a wall-face moment.

`ψt = 1.3` because the wall is cast with the slab, so more than 12 in. of
fresh concrete is cast below the horizontal bar (§12.2.4(a)). Returns
`nothing` when this direction has no wall moment to anchor.
"""
function wall_face_bar_anchorage(rebar_design, moment_results, struc, slab, columns,
                                 fc::Pressure, fy::Pressure, λ::Real, cover::Length,
                                 span_axis)
    rebar_design === nothing && return nothing
    hasproperty(moment_results, :M_wall_ext) || return nothing
    z = zero(moment_results.M_wall_ext)
    want_ext = moment_results.M_wall_ext > z
    want_int = moment_results.M_wall_int > z
    if hasproperty(moment_results, :qu) && hasproperty(moment_results, :l2)
        short = short_wall_flexure_moments(
            struc, slab, columns, moment_results.qu, moment_results.l2;
            span_axis = span_axis)
        want_ext |= short.M_ext > z
        want_int |= short.M_int > z
    end
    (want_ext || want_int) || return nothing
    thickness = _min_perpendicular_wall_thickness(struc, slab, span_axis)
    thickness === nothing && return nothing
    bars = Int[]
    want_ext && push!(bars, _largest_strip_bar(rebar_design, :ext_neg))
    want_int && push!(bars, _largest_strip_bar(rebar_design, :int_neg))
    filter!(>(0), bars)
    isempty(bars) && return nothing
    checks = [wall_negative_anchorage(b, fc, fy, Float64(λ), thickness, cover) for b in bars]
    failed = findfirst(c -> !c.ok, checks)
    return failed === nothing ? checks[1] : checks[failed]
end

