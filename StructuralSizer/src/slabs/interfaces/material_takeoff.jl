# =============================================================================
# Common Interface
# =============================================================================

"""Self-weight (force per area)."""
self_weight(s::AbstractFloorResult) = s.self_weight

"""Total depth of floor system."""
total_depth(s::CIPSlabResult) = s.thickness
total_depth(s::ProfileResult) = s.depth
total_depth(s::CompositeDeckResult) = s.total_depth
total_depth(s::JoistDeckResult) = s.total_depth
total_depth(s::TimberPanelResult) = s.depth
total_depth(s::TimberJoistResult) = s.total_depth
total_depth(s::VaultResult) = s.thickness + s.rise
total_depth(s::ShapedSlabResult) = s.volume_per_area  # approximate

"""
    flange_thickness(s) -> Union{Length, Nothing}

Solid concrete thickness a supporting beam may engage as a flange (`hf` of an
RC T-beam, `t_slab` of a composite beam), or `nothing` when the floor offers
no solid flange. For a composite deck this is the fill above the ribs. A vault
(shell plus rise), a shaped slab (volume per area), and precast, timber, or
joist-deck floors are not monolithic solid flanges.
"""
flange_thickness(s::CIPSlabResult) = s.thickness
flange_thickness(s::CompositeDeckResult) = s.fill_depth
flange_thickness(::AbstractFloorResult) = nothing

"""Volume per unit area (single-material floors)."""
volume_per_area(s::CIPSlabResult) = s.volume_per_area
volume_per_area(s::ProfileResult) = s.volume_per_area
volume_per_area(s::TimberPanelResult) = s.volume_per_area
volume_per_area(s::TimberJoistResult) = s.volume_per_area
volume_per_area(s::VaultResult) = s.volume_per_area
volume_per_area(s::ShapedSlabResult) = s.volume_per_area

# =============================================================================
# Material Volumes Interface
# =============================================================================

"""Query which materials are present in a floor result."""
materials(::CIPSlabResult) = (:concrete,)
materials(::ProfileResult) = (:concrete,)
materials(::CompositeDeckResult) = (:steel, :concrete)
materials(::JoistDeckResult) = (:steel,)
materials(::TimberPanelResult) = (:timber,)
materials(::TimberJoistResult) = (:timber,)
materials(::VaultResult) = (:concrete,)
materials(::ShapedSlabResult) = (:concrete,)

"""Get material volume per unit floor plan area."""
function volume_per_area(r::AbstractFloorResult, mat::Symbol)
    mat in materials(r) || throw(ArgumentError("$(typeof(r)) does not contain material :$mat"))
    return _volume_impl(r, Val(mat))
end

# _volume_impl returns stored values (computed at sizing time)
_volume_impl(r::CIPSlabResult, ::Val{:concrete}) = r.volume_per_area
_volume_impl(r::ProfileResult, ::Val{:concrete}) = r.volume_per_area
_volume_impl(r::CompositeDeckResult, ::Val{:steel}) = r.steel_vol_per_area
_volume_impl(r::CompositeDeckResult, ::Val{:concrete}) = r.concrete_vol_per_area
_volume_impl(r::JoistDeckResult, ::Val{:steel}) = r.steel_vol_per_area
_volume_impl(r::TimberPanelResult, ::Val{:timber}) = r.volume_per_area
_volume_impl(r::TimberJoistResult, ::Val{:timber}) = r.volume_per_area
_volume_impl(r::VaultResult, ::Val{:concrete}) = r.volume_per_area
_volume_impl(r::ShapedSlabResult, ::Val{:concrete}) = r.volume_per_area

# FlatPlatePanelResult: concrete is just thickness, steel calculated from reinforcement
_volume_impl(r::FlatPlatePanelResult, ::Val{:concrete}) = r.volume_per_area
_volume_impl(r::FlatPlatePanelResult, ::Val{:steel}) = _calc_rebar_volume_per_area(r)

"""
    _governing_negative(reinf) -> StripBars

The heavier of the exterior and interior negative sections.

A panel result stores both sections and does not say which supports of this
panel are exterior. The takeoff places that heavier set at both ends of one span.
"""
function _governing_negative(reinf)
    exterior = _strip_at(reinf, :ext_neg)
    interior = _strip_at(reinf, :int_neg)
    steel(s) = s.n_bars <= 0 ? 0.0 : s.n_bars * ustrip(u"m^2", bar_area(s.bar_size))
    return steel(interior) > steel(exterior) ? interior : exterior
end

"""
Steel volume of the bars [`detail_flat_plate_line`](@ref) places for one span
of these strips.

The cutoff lengths are ACI 318-19 Fig. 8.7.4.1.3 (corpus: aci-318-19, PDF
p. 119). The panel result does not store cover or the design materials, so
development uses ¾ in. cover, 4 ksi concrete, and 60 ksi bars, the flat-plate
defaults. Hooks are in the bar length. There is no added percentage.
"""
function _direction_placed_volume(column_reinf, middle_reinf, column_width, middle_width, span, h)
    ustrip(u"m", span) > 0 || return 0.0u"m^3"
    ustrip(u"m", h) > 0 || return 0.0u"m^3"
    cw = column_width > 0u"m" ? column_width : 1.0u"m"
    mw = middle_width > 0u"m" ? middle_width : 1.0u"m"
    none = StripBars(0, 0)
    column = StripLayout(_governing_negative(column_reinf), _strip_at(column_reinf, :pos), none, cw)
    middle = StripLayout(_governing_negative(middle_reinf), _strip_at(middle_reinf, :pos), none, mw)
    if column.ext_neg.n_bars == 0 && column.pos.n_bars == 0 &&
       middle.ext_neg.n_bars == 0 && middle.pos.n_bars == 0
        return 0.0u"m^3"
    end
    md = detail_flat_plate_line(;
        clear_spans = [span], supports = [0.0u"m", 0.0u"m"],
        column_strip = column, middle_strip = middle,
        h = h, cover = 0.75u"inch", fc = 4000.0u"psi", fy = 60_000.0u"psi")
    volume = 0.0u"m^3"
    for g in md.groups
        volume += g.count * uconvert(u"m^2", bar_area(g.bar_size)) * uconvert(u"m", g.length)
    end
    return volume
end

"""
    _calc_rebar_volume_per_area(r::FlatPlatePanelResult) -> Length

Reinforcing steel volume per plan area, equal to the bars one span of the
design strips would place, divided by the panel area `l1 × l2`.

Each direction is placed once. A result with no secondary strips uses the
same bars again in that direction. The three moment sections are not each
run the full span: only the positive bars and the heavier negative set are
placed, at the cutoff lengths of Fig. 8.7.4.1.3.
"""
function _calc_rebar_volume_per_area(r::FlatPlatePanelResult)
    primary = _direction_placed_volume(r.column_strip_reinf, r.middle_strip_reinf,
                                       r.column_strip_width, r.middle_strip_width,
                                       r.l1, r.thickness)
    total = if isempty(r.secondary_column_strip_reinf)
        2 * primary
    else
        primary + _direction_placed_volume(
            r.secondary_column_strip_reinf, r.secondary_middle_strip_reinf,
            r.secondary_column_strip_width, r.secondary_middle_strip_width,
            r.l2, r.thickness)
    end
    panel_area = uconvert(u"m^2", r.l1 * r.l2)
    panel_area > 0.0u"m^2" || return 0.0u"m"
    return uconvert(u"m", total / panel_area)
end

"""Get all material volumes as a dictionary."""
function material_volumes(r::AbstractFloorResult)
    return Dict(mat => volume_per_area(r, mat) for mat in materials(r))
end

