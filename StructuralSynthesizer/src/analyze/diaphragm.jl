# ASCE 7-22 diaphragm idealization.
#
# The classifier chooses `:rigid`, `:flexible`, or `:shell` (semirigid).
# It does not build a model and it does not detect irregularities from geometry.
# `:none` is not a return value: it means the diaphragm model is off.

# ASCE 7-22 §12.3.1.2 (corpus: asce-7-22, PDF p. 179): span-to-depth of 3 or less.
const _SEISMIC_RIGID_SPAN_TO_DEPTH = 3

# ASCE 7-22 §26.2 DIAPHRAGM (corpus: asce-7-22, PDF p. 324): span-to-depth of 2 or less.
const _WIND_RIGID_SPAN_TO_DEPTH = 2

# ASCE 7-22 §12.3.1.3 Eq. 12.3-1 (corpus: asce-7-22, PDF p. 179): δ_MDD / Δ_ADVE > 2.
const _CALCULATED_FLEXIBLE_RATIO = 2

# ASCE 7-22 §12.3.1.2 (corpus: asce-7-22, PDF p. 179) names Type 2, 3, 4, and 5.
# Type 1 is omitted here because that sentence does not list it.
# Table 12.3-1 (corpus: asce-7-22, PDF p. 180) is the name of each type.
# The numbers are caller inputs. This file does not test the table's geometry.
const _RIGID_BLOCKING_HORIZONTAL_IRREGULARITIES = (2, 3, 4, 5)

# ASCE 7-22 §12.3.1.1 item 3(a) (corpus: asce-7-22, PDF p. 179):
# nonstructural topping no greater than 1.5 in. (38 mm).
const _LIGHT_FRAME_TOPPING_MAX = 1.5u"inch"

# ASCE 7-22 §12.3.1.1 (corpus: asce-7-22, PDF p. 179): untopped steel decking
# or wood structural panels.
const _SEISMIC_FLEXIBLE_CONSTRUCTION = (:untopped_steel_deck, :wood_structural_panels)

# One concrete-filled deck. ASCE 7-22 §12.3.1.2 (corpus: asce-7-22, PDF p. 179)
# names concrete-filled metal deck. ASCE 7-22 §26.2 DIAPHRAGM (corpus: asce-7-22,
# PDF p. 324) names concrete-filled steel deck. Both symbols are that deck.
const _CONCRETE_FILLED_DECK = (:concrete_filled_metal_deck, :concrete_filled_steel_deck)

# ASCE 7-22 §12.3.1.2 (corpus: asce-7-22, PDF p. 179): concrete slabs or
# concrete-filled metal deck. The span-to-depth limit stays 3.
const _SEISMIC_RIGID_CONSTRUCTION = (:concrete_slab, _CONCRETE_FILLED_DECK...)

# ASCE 7-22 §26.2 DIAPHRAGM (corpus: asce-7-22, PDF p. 324): untopped steel
# deck, concrete-filled steel deck, and concrete slab. The span-to-depth
# limit stays 2. Untopped steel deck is not added to the seismic list.
const _WIND_RIGID_CONSTRUCTION = (
    :untopped_steel_deck, _CONCRETE_FILLED_DECK..., :concrete_slab,
)
const _WIND_FLEXIBLE_CONSTRUCTION = :wood_structural_panels

# ASCE 7-22 §12.3.1.1 item 1 (corpus: asce-7-22, PDF p. 179).
const _FLEXIBLE_VERTICAL_ELEMENTS = (
    :steel_braced_frame,
    :steel_concrete_composite_braced_frame,
    :concrete_shear_wall,
    :masonry_shear_wall,
    :steel_shear_wall,
    :steel_concrete_composite_shear_wall,
)

"""
    classify_diaphragm_idealization(; loading, construction, span, depth,
        horizontal_irregularity_types, ...) -> Symbol

Choose `:rigid`, `:flexible`, or `:shell` for one diaphragm.

`loading` is `:seismic` or `:wind`. It has no default, and the two chapters
are not mixed: a seismic permission is not applied to wind, and the wind
span-to-depth limit is not applied to seismic.

`:shell` is the semirigid model required when the diaphragm is not permitted
to be flexible or rigid.

# Seismic — ASCE 7-22 §12.3.1, §12.3.1.1, §12.3.1.2, §12.3.1.3
# (corpus: asce-7-22, PDF p. 179)

§12.3.1: unless the diaphragm can be idealized as flexible or rigid under
§12.3.1.1, §12.3.1.2, or §12.3.1.3, the analysis includes the diaphragm
stiffness.

§12.3.1.1 permits untopped steel decking or wood structural panels to be
flexible when (1) the vertical elements are steel braced frames, steel and
concrete composite braced frames, or concrete, masonry, steel, or steel and
concrete composite shear walls; or (2) the building is a one- or two-family
dwelling; or (3) light-frame construction with no concrete topping over the
wood panels except nonstructural topping not greater than 1.5 in. (38 mm),
and each line of vertical elements complies with Table 12.12-1. Table 12.12-1
is not encoded. Item 3 applies only when the caller passes that compliance
as `true`.

§12.3.1.2 permits concrete slabs or concrete-filled metal deck with
span-to-depth of 3 or less to be rigid when the structure has no Type 2, 3,
4, or 5 horizontal structural irregularity. Type 1 does not block that
permission. A ratio of exactly 3 is permitted. A ratio above 3 is not.
`:concrete_filled_steel_deck` is that same filled deck. The wind limit of 2
is not applied here.

§12.3.1.3 Eq. 12.3-1 permits a diaphragm that meets neither §12.3.1.1 nor
§12.3.1.2 to be flexible where `δ_MDD / Δ_ADVE > 2`. The two displacements
are caller inputs. A ratio of exactly 2 does not qualify.

# Wind — ASCE 7-22 §26.2 DIAPHRAGM (corpus: asce-7-22, PDF p. 324)

Untopped steel decks, concrete-filled steel decks, and concrete slabs, each
with span-to-depth of 2 or less, may be rigid. Wood structural panels may be
flexible. A ratio of exactly 2 is permitted. A ratio above 2 is not.
`:concrete_filled_metal_deck` is that same filled deck. The seismic limit of
3 is not applied here, and Eq. 12.3-1 is not applied to wind.

# Arguments

- `loading::Symbol`: `:seismic` or `:wind`. Required.
- `construction::Symbol`: one of `:concrete_slab`, `:concrete_filled_metal_deck`,
  `:concrete_filled_steel_deck`, `:untopped_steel_deck`, `:wood_structural_panels`.
  `:concrete_filled_metal_deck` and `:concrete_filled_steel_deck` are one
  concrete-filled deck under both chapters. A symbol outside that list is not
  given a permission by renaming it.
- `span`, `depth`: the two lengths in the span-to-depth ratio. Both required.
  Passing `nothing` throws. They may both be lengths, or both bare numbers in
  the same unit.
- `horizontal_irregularity_types`: Table 12.3-1 type numbers supplied by the
  caller. Types outside 1–5 throw. This function does not read geometry.
- `vertical_elements`: one symbol, or a collection of them, for §12.3.1.1
  item 1. `nothing` or an empty collection means item 1 was not asserted.
- `one_or_two_family::Bool=false`: §12.3.1.1 item 2. The default does not
  grant the permission.
- `light_frame::Bool=false`: §12.3.1.1 item 3.
- `each_line_complies_table_12_12_1::Union{Nothing,Bool}=nothing`: the caller's
  statement that each line meets Table 12.12-1. `nothing` means item 3 does
  not apply.
- `topping_thickness`: length of topping on wood structural panels. `nothing`
  means the topping was not reported, so item 3 does not apply. Zero means
  no topping is placed.
- `topping_is_nonstructural::Union{Nothing,Bool}=nothing`: required for a
  topping thicker than zero. A topping that is not reported as nonstructural
  is not the §12.3.1.1 item 3(a) exception.
- `delta_mdd`, `delta_adve`: `δ_MDD` and `Δ_ADVE` for Eq. 12.3-1. Both or
  neither. One without the other throws.

§12.3.1.4 (hillside light-frame diaphragms) is not encoded.

Throws if `span`, `depth`, `construction`, or `loading` is missing. Throws if
§12.3.1.3 is the only remaining permission — the construction is not one that
§12.3.1.1 or §12.3.1.2 addresses — and the two displacements were not given.
"""
function classify_diaphragm_idealization(;
        loading,
        construction,
        span,
        depth,
        horizontal_irregularity_types,
        vertical_elements=nothing,
        one_or_two_family::Bool=false,
        light_frame::Bool=false,
        each_line_complies_table_12_12_1::Union{Nothing,Bool}=nothing,
        topping_thickness=nothing,
        topping_is_nonstructural::Union{Nothing,Bool}=nothing,
        delta_mdd=nothing,
        delta_adve=nothing)
    loading = _require_diaphragm_symbol(loading, "loading")
    loading in (:seismic, :wind) || throw(ArgumentError(
        "loading must be :seismic or :wind, got :$loading. There is no default, " *
        "and the stricter of the two chapters is not substituted."))
    construction = _require_diaphragm_symbol(construction, "construction")
    # Both lengths are required even when the granting clause does not use the
    # ratio, so a missing span cannot fall through to a permission.
    ratio = _span_to_depth_ratio(span, depth)
    irregularities = _horizontal_irregularity_types(horizontal_irregularity_types)
    disp_ratio = _optional_displacement_ratio(delta_mdd, delta_adve)

    if loading === :seismic
        return _classify_seismic_diaphragm(;
            construction, ratio, irregularities, vertical_elements,
            one_or_two_family, light_frame,
            each_line_complies_table_12_12_1,
            topping_thickness, topping_is_nonstructural, disp_ratio)
    end
    return _classify_wind_diaphragm(construction, ratio)
end

"""
    stricter_diaphragm_idealization(; kwargs...) -> Symbol

The idealization that satisfies both chapters at once.

Calls [`classify_diaphragm_idealization`](@ref) for `:seismic` and for
`:wind` with the same arguments. When the two agree, that answer is
returned. When they disagree, the answer is `:shell`.

# Engineering judgment
ASCE 7-22 §12.3.1 (corpus: asce-7-22, PDF page 179) and §26.2 (PDF page 324)
each permit an idealization for their own loading. They do not say what to do
when one model serves both. An idealization is used only when both chapters
permit it. A disagreement models the diaphragm stiffness, which §12.3.1
requires whenever the flexible and rigid permissions do not apply.
"""
function stricter_diaphragm_idealization(; kwargs...)
    seismic = classify_diaphragm_idealization(; loading=:seismic, kwargs...)
    wind = classify_diaphragm_idealization(; loading=:wind, kwargs...)
    seismic === wind && return seismic
    return :shell
end

"""
    governing_diaphragm_span_depth(struc; plan_axis, walls) -> (span, depth, type5)

The span and depth, in metres, of the diaphragm bay with the largest
span-to-depth ratio, and whether a measured wall is Table 12.3-1 Type 5.

For each plan axis, the walls parallel to that axis form lines. The span is
the longest distance between adjacent lines, and the depth is the floor
outline's width along the lines. An axis with fewer than two lines is
skipped. The pair with the largest ratio is returned, so one classification
covers every floor and both directions.

A wall that [`_pier_axis_direction`](@ref) calls `:skew` is Type 5. It is
left out of the axis-aligned lines. Two or more skewed walls parallel to
each other form their own lines, and the span is the perpendicular distance
between those lines. One skewed wall, with no wall parallel to it, defines
no span.

`walls` defaults to every wall. Pass the seismic-system walls when a system
is declared. A wall outside that list is neither a line nor Type 5.

# Engineering judgment
§12.3.1.2 and §26.2 state the ratio and not how to measure it on a floor.
Commentary C12.3.1.2 (corpus: asce-7-22, PDF page 713) calls it an indirect
measure of diaphragm flexure, and C12.3.1.3 describes the span as the
distance between lines of vertical elements. That distance, measured
perpendicular to a family of parallel walls, is used for a skewed family
as well. ASCE 7-22 Table 12.3-1 Type 5 (PDF page 180) is the vertical
elements that are not parallel to the major orthogonal axes. The parallel
test is the same 1e-8 test as [`_plan_vector_direction`](@ref).
"""
function governing_diaphragm_span_depth(struc::BuildingStructure;
                                       plan_axis::Tuple{Real,Real}=(1.0, 0.0),
                                       walls=nothing)
    axis = unit_plan_axis(plan_axis)
    e1, e2 = plan_axes(axis)
    ids = walls === nothing ? collect(eachindex(struc.walls)) : collect(walls)
    isempty(ids) && throw(ArgumentError(
        "diaphragm span: there are no walls to form lines, so the span between " *
        "vertical elements is not measured."))
    best = nothing
    type5 = false
    reached = false
    for (_, story) in struc.skeleton.stories
        isempty(story.faces) && continue
        z = ustrip(u"m", story.elevation)
        reaching = Int[]
        for i in ids
            g = _wall_pier_geometry(struc.walls[i], struc.skeleton)
            abs(g.z_top - z) <= WALL_CUT_ZTOL_M && push!(reaching, i)
        end
        isempty(reaching) && continue
        reached = true
        orthogonal = Int[]
        skewed = Int[]
        for i in reaching
            if _pier_axis_direction(struc.walls[i], axis) === :skew
                type5 = true
                push!(skewed, i)
            else
                push!(orthogonal, i)
            end
        end
        outline = story_floor_outline(struc.skeleton, story)
        pts = NTuple{2,Float64}[]
        for loop in outline
            append!(pts, loop)
        end
        isempty(pts) && throw(ArgumentError(
            "diaphragm span: the floor at $(z) m has faces and no outline."))
        for (direction, along, across) in ((:x, e1, e2), (:y, e2, e1))
            offsets = _diaphragm_line_offsets(struc, orthogonal, along, across)
            length(offsets) < 2 && continue
            span = maximum(offsets[k + 1] - offsets[k] for k in 1:(length(offsets) - 1))
            # Width along the lines: the extent perpendicular to `across`.
            depth = projected_plan_width(pts, across)
            depth > 0 || throw(ArgumentError(
                "diaphragm span: the floor at $(z) m has no width along $direction."))
            best = _wider_diaphragm_span(best, span, depth)
        end
        for (span, depth) in _skewed_diaphragm_spans(struc, skewed, pts)
            depth > 0 || throw(ArgumentError(
                "diaphragm span: the floor at $(z) m has no width along a skewed wall."))
            best = _wider_diaphragm_span(best, span, depth)
        end
    end
    best === nothing && throw(ArgumentError(
        reached ?
        "diaphragm span: every direction has fewer than two lines of walls, " *
        "so there is no span to classify." :
        "diaphragm span: no floor is reached by a wall, so there is no span to classify."))
    return best[1], best[2], type5
end

"Keep the pair with the larger span-to-depth ratio."
_wider_diaphragm_span(best, span, depth) =
    (best === nothing || span / depth > best[1] / best[2]) ? (span, depth) : best

"""
Perpendicular spans of skewed walls that share a direction.

Walls whose tangents agree within 1e-8 are one family, the same tolerance
as [`_plan_vector_direction`](@ref). Offsets within 1 mm are one line. A
family with one line contributes no span.
"""
function _skewed_diaphragm_spans(struc, ids, pts)
    families = Tuple{NTuple{2,Float64}, Vector{Int}}[]
    for i in ids
        tx, ty, _, _ = _pier_plan_axes(struc.walls[i])
        # One representative direction, so a reversed wall joins its family.
        if tx < 0 || (abs(tx) <= 1e-12 && ty < 0)
            tx, ty = -tx, -ty
        end
        k = findfirst(f -> abs(f[1][1] * tx + f[1][2] * ty) >= 1 - 1e-8, families)
        if k === nothing
            push!(families, ((tx, ty), [i]))
        else
            push!(families[k][2], i)
        end
    end
    pairs = Tuple{Float64,Float64}[]
    for (u, members) in families
        across = (-u[2], u[1])
        offsets = Float64[]
        for i in members
            g = _wall_pier_geometry(struc.walls[i], struc.skeleton)
            push!(offsets, 0.5 * ((g.x1 + g.x2) * across[1] + (g.y1 + g.y2) * across[2]))
        end
        sort!(offsets)
        lines = Float64[offsets[1]]
        for s in offsets
            s - lines[end] > _DIAPHRAGM_LINE_TOL_M && push!(lines, s)
        end
        length(lines) < 2 && continue
        span = maximum(lines[k + 1] - lines[k] for k in 1:(length(lines) - 1))
        # Width along the family: the extent perpendicular to `across`.
        push!(pairs, (span, projected_plan_width(pts, across)))
    end
    return pairs
end

"""Sorted offsets [m] of the walls parallel to `along`. The others are skipped."""
function _diaphragm_line_offsets(struc, ids, along, across)
    offsets = Float64[]
    for i in ids
        g = _wall_pier_geometry(struc.walls[i], struc.skeleton)
        dx, dy = g.x2 - g.x1, g.y2 - g.y1
        L = hypot(dx, dy)
        ux, uy = dx / L, dy / L
        abs(ux * along[1] + uy * along[2]) >= 1 - _DIAPHRAGM_AXIS_TOL || continue
        push!(offsets, 0.5 * ((g.x1 + g.x2) * across[1] + (g.y1 + g.y2) * across[2]))
    end
    isempty(offsets) && return offsets
    sort!(offsets)
    lines = Float64[offsets[1]]
    for s in offsets
        s - lines[end] > _DIAPHRAGM_LINE_TOL_M && push!(lines, s)
    end
    return lines
end

"""
    resolve_auto_diaphragm(struc, params) -> Symbol

`:rigid`, `:flexible`, or `:semirigid` for `diaphragm_mode = :auto`.

The span and depth are [`governing_diaphragm_span_depth`](@ref), using the
declared seismic-system walls when `params.lateral` is set. A skewed wall
among those adds Table 12.3-1 Type 5 to the stated irregularities. Types
1 through 4 stay as stated, and the caller's vector is not modified. The
idealization is [`stricter_diaphragm_idealization`](@ref). `:shell` is
built as the `:semirigid` membrane.
"""
function resolve_auto_diaphragm(struc::BuildingStructure, params::DesignParameters)
    params.diaphragm_construction === nothing && throw(ArgumentError(
        "to_asap!: diaphragm_mode :auto needs diaphragm_construction " *
        "(:concrete_slab, :concrete_filled_metal_deck, :concrete_filled_steel_deck, " *
        ":untopped_steel_deck, or :wood_structural_panels). It is not assumed."))
    params.diaphragm_irregularities === nothing && throw(ArgumentError(
        "to_asap!: diaphragm_mode :auto needs diaphragm_irregularities, the " *
        "Table 12.3-1 type numbers the caller states. An empty vector means " *
        "the caller states none. A wall that is not parallel to the plan axes " *
        "adds Type 5. Types 1, 2, 3, and 4 stay as stated."))
    wall_ids = nothing
    axis = (1.0, 0.0)
    if params.lateral !== nothing
        axis = params.lateral.plan_axis
        mx = seismic_members(struc, params.lateral.system_x).walls
        my = seismic_members(struc, params.lateral.system_y).walls
        wall_ids = unique(vcat(mx, my))
    end
    span, depth, type5 = governing_diaphragm_span_depth(struc; plan_axis=axis, walls=wall_ids)
    irregularities = copy(params.diaphragm_irregularities)
    type5 && (5 in irregularities || push!(irregularities, 5))
    ideal = stricter_diaphragm_idealization(;
        construction=params.diaphragm_construction,
        span, depth,
        horizontal_irregularity_types=irregularities)
    return ideal === :shell ? :semirigid : ideal
end

"""
    deck_floor_diaphragm(; loading, span, depth, horizontal_irregularity_types, kwargs...)

Idealization of a concrete-filled steel deck floor.

The construction is fixed to `:concrete_filled_metal_deck`. ASCE 7-22 §12.3.1.2
and §26.2 both name that deck (corpus: asce-7-22, PDF pp. 179, 324). This
classifies the analysis model only. It does not compute a diaphragm shear
strength. SDI C-2017 §2.4 item 7 (corpus: sdi-c-2017, PDF p. 10) sends that
strength to AISI S310.
"""
function deck_floor_diaphragm(;
        loading,
        span,
        depth,
        horizontal_irregularity_types,
        kwargs...)
    return classify_diaphragm_idealization(;
        loading,
        construction=:concrete_filled_metal_deck,
        span, depth, horizontal_irregularity_types,
        kwargs...)
end

"""Seismic idealization. `disp_ratio` is `nothing` when Eq. 12.3-1 was not supplied."""
function _classify_seismic_diaphragm(;
        construction, ratio, irregularities, vertical_elements,
        one_or_two_family, light_frame,
        each_line_complies_table_12_12_1,
        topping_thickness, topping_is_nonstructural, disp_ratio)
    # ASCE 7-22 §12.3.1.1 (corpus: asce-7-22, PDF p. 179).
    if _seismic_flexible_12_3_1_1(;
            construction, vertical_elements, one_or_two_family, light_frame,
            each_line_complies_table_12_12_1,
            topping_thickness, topping_is_nonstructural)
        return :flexible
    end
    # ASCE 7-22 §12.3.1.2 (corpus: asce-7-22, PDF p. 179).
    if _seismic_rigid_12_3_1_2(construction, ratio, irregularities)
        return :rigid
    end
    # ASCE 7-22 §12.3.1.3 Eq. 12.3-1 (corpus: asce-7-22, PDF p. 179):
    # only a diaphragm that meets neither §12.3.1.1 nor §12.3.1.2, and only
    # where the caller-supplied ratio is greater than 2.
    if disp_ratio !== nothing
        return disp_ratio > _CALCULATED_FLEXIBLE_RATIO ? :flexible : :shell
    end
    if !_seismic_clause_addresses(construction)
        throw(ArgumentError(
            "ASCE 7-22 §12.3.1.3 is the only remaining diaphragm permission for " *
            "construction :$construction, and δ_MDD and Δ_ADVE were not provided. " *
            "They are not computed here."))
    end
    # ASCE 7-22 §12.3.1 (corpus: asce-7-22, PDF p. 179): the analysis includes
    # the diaphragm stiffness when no flexible or rigid permission applies.
    return :shell
end

"""
Wind idealization from §26.2 only.

Eq. 12.3-1 is a Chapter 12 seismic test. It is not applied to wind, and the
seismic span-to-depth limit of 3 is not applied either.

`:concrete_filled_metal_deck` and `:concrete_filled_steel_deck` are the one
concrete-filled deck named in §26.2. Untopped steel deck stays on this wind
permission only.
"""
function _classify_wind_diaphragm(construction::Symbol, ratio::Float64)
    # ASCE 7-22 §26.2 DIAPHRAGM (corpus: asce-7-22, PDF p. 324):
    # wood structural panels may be idealized as flexible.
    construction === _WIND_FLEXIBLE_CONSTRUCTION && return :flexible
    # ASCE 7-22 §26.2 DIAPHRAGM (corpus: asce-7-22, PDF p. 324):
    # span-to-depth of 2 or less. Exactly 2 is permitted.
    if construction in _WIND_RIGID_CONSTRUCTION && ratio <= _WIND_RIGID_SPAN_TO_DEPTH
        return :rigid
    end
    return :shell
end

"""True when §12.3.1.1 permits the flexible idealization."""
function _seismic_flexible_12_3_1_1(;
        construction, vertical_elements, one_or_two_family, light_frame,
        each_line_complies_table_12_12_1,
        topping_thickness, topping_is_nonstructural)
    construction in _SEISMIC_FLEXIBLE_CONSTRUCTION || return false
    _flexible_item_1(vertical_elements) && return true
    # Item 2: one- and two-family dwellings. The construction is still
    # untopped steel decking or wood structural panels, checked above.
    one_or_two_family && return true
    return _flexible_item_3(;
        construction, light_frame, each_line_complies_table_12_12_1,
        topping_thickness, topping_is_nonstructural)
end

"""§12.3.1.1 item 1. An unstated vertical system does not grant the item."""
function _flexible_item_1(vertical_elements)::Bool
    elements = _vertical_element_symbols(vertical_elements)
    isempty(elements) && return false
    return all(e -> e in _FLEXIBLE_VERTICAL_ELEMENTS, elements)
end

"""
§12.3.1.1 item 3.

Item 3 does not apply unless the caller passes
`each_line_complies_table_12_12_1 === true`. Table 12.12-1 itself is not
encoded. The diaphragm in item 3(a) is a wood structural panel diaphragm.
"""
function _flexible_item_3(;
        construction, light_frame, each_line_complies_table_12_12_1,
        topping_thickness, topping_is_nonstructural)::Bool
    each_line_complies_table_12_12_1 !== true && return false
    light_frame || return false
    construction === :wood_structural_panels || return false
    return _light_frame_topping_permitted(topping_thickness, topping_is_nonstructural)
end

"""
§12.3.1.1 item 3(a): no concrete topping, except nonstructural topping not
greater than 1.5 in. (38 mm). A missing thickness is not read as zero.
"""
function _light_frame_topping_permitted(topping_thickness, topping_is_nonstructural)::Bool
    topping_thickness === nothing && return false
    topping_thickness isa Quantity || throw(ArgumentError(
        "topping_thickness must be a length, got $(typeof(topping_thickness))"))
    t = uconvert(u"inch", topping_thickness)
    t < 0u"inch" && throw(ArgumentError(
        "topping_thickness is negative ($topping_thickness)"))
    # No topping placed over the wood structural panel diaphragm.
    t == 0u"inch" && return true
    topping_is_nonstructural !== true && return false
    # ASCE 7-22 §12.3.1.1 item 3(a) (corpus: asce-7-22, PDF p. 179):
    # nonstructural topping no greater than 1.5 in. (38 mm).
    return t <= _LIGHT_FRAME_TOPPING_MAX
end

"""
§12.3.1.2. Exactly 3 is permitted. Type 1 does not block the permission.

`:concrete_filled_metal_deck` and `:concrete_filled_steel_deck` are the one
concrete-filled deck named in §12.3.1.2. The wind limit of 2 is not used.
"""
function _seismic_rigid_12_3_1_2(construction::Symbol, ratio::Float64, irregularities)::Bool
    construction in _SEISMIC_RIGID_CONSTRUCTION || return false
    # ASCE 7-22 §12.3.1.2 (corpus: asce-7-22, PDF p. 179): span-to-depth of 3 or less.
    ratio <= _SEISMIC_RIGID_SPAN_TO_DEPTH || return false
    # ASCE 7-22 §12.3.1.2 (corpus: asce-7-22, PDF p. 179): no Type 2, 3, 4, or 5.
    return !any(t -> t in _RIGID_BLOCKING_HORIZONTAL_IRREGULARITIES, irregularities)
end

"""True when §12.3.1.1 or §12.3.1.2 names this construction, whether or not the conditions pass."""
function _seismic_clause_addresses(construction::Symbol)::Bool
    return construction in _SEISMIC_FLEXIBLE_CONSTRUCTION ||
           construction in _SEISMIC_RIGID_CONSTRUCTION
end

function _require_diaphragm_symbol(value, name::AbstractString)::Symbol
    value === nothing && throw(ArgumentError("$name is required"))
    value isa Symbol || throw(ArgumentError(
        "$name must be a Symbol, got $(typeof(value))"))
    return value
end

"""Span-to-depth. Both values are required. The ratio is not rounded toward a limit."""
function _span_to_depth_ratio(span, depth)::Float64
    (span === nothing || depth === nothing) && throw(ArgumentError(
        "span and depth are required. Neither is assumed."))
    ratio = if span isa Quantity && depth isa Quantity
        ustrip(u"m", span) / ustrip(u"m", depth)
    elseif span isa Real && depth isa Real && !(span isa Bool) && !(depth isa Bool)
        float(span) / float(depth)
    else
        throw(ArgumentError(
            "span and depth must both be lengths, or both be real numbers in the same unit"))
    end
    isfinite(ratio) || throw(ArgumentError(
        "span-to-depth ratio is not finite (span=$span, depth=$depth)"))
    ratio > 0 || throw(ArgumentError(
        "span-to-depth ratio must be positive, got $ratio"))
    return ratio
end

"""
Table 12.3-1 type numbers as supplied by the caller.

Types other than 1, 2, 3, 4, and 5 throw. This does not decide whether a
plan is irregular.
"""
function _horizontal_irregularity_types(types)::Vector{Int}
    types isa AbstractVector || throw(ArgumentError(
        "horizontal_irregularity_types must be a vector of Table 12.3-1 type numbers " *
        "(1 through 5). The classifier does not detect irregularities."))
    out = Int[]
    for t in types
        (t isa Integer && !(t isa Bool)) || throw(ArgumentError(
            "horizontal irregularity type must be an integer 1–5, got $(repr(t))"))
        i = Int(t)
        i in 1:5 || throw(ArgumentError(
            "horizontal irregularity type $i is not in ASCE 7-22 Table 12.3-1. " *
            "It is not treated as absent."))
        push!(out, i)
    end
    return out
end

function _vertical_element_symbols(vertical_elements)::Vector{Symbol}
    vertical_elements === nothing && return Symbol[]
    if vertical_elements isa Symbol
        return Symbol[vertical_elements]
    end
    vertical_elements isa AbstractVector || throw(ArgumentError(
        "vertical_elements must be a Symbol, a vector of Symbols, or nothing"))
    out = Symbol[]
    for e in vertical_elements
        e isa Symbol || throw(ArgumentError(
            "vertical element must be a Symbol, got $(typeof(e))"))
        push!(out, e)
    end
    return out
end

"""
`nothing` when both displacements are omitted.

Throws when only one is present. Both values must be positive: Eq. 12.3-1
does not define a sign, and this function does not take an absolute value.
"""
function _optional_displacement_ratio(delta_mdd, delta_adve)::Union{Float64,Nothing}
    mdd_missing = delta_mdd === nothing
    adve_missing = delta_adve === nothing
    mdd_missing && adve_missing && return nothing
    (mdd_missing || adve_missing) && throw(ArgumentError(
        "ASCE 7-22 §12.3.1.3 needs both δ_MDD and Δ_ADVE. One was provided " *
        "and the other was not."))
    if (delta_mdd isa Quantity) != (delta_adve isa Quantity)
        throw(ArgumentError(
            "δ_MDD and Δ_ADVE must both be lengths or both be numbers in the same unit"))
    end
    mdd = _positive_displacement(delta_mdd, "δ_MDD")
    adve = _positive_displacement(delta_adve, "Δ_ADVE")
    return mdd / adve
end

function _positive_displacement(value, name::AbstractString)::Float64
    number = if value isa Quantity
        ustrip(u"m", value)
    elseif value isa Real && !(value isa Bool)
        float(value)
    else
        throw(ArgumentError("$name must be a positive length or number, got $(typeof(value))"))
    end
    isfinite(number) && number > 0 || throw(ArgumentError(
        "$name must be positive and finite, got $value. Eq. 12.3-1 states no sign convention."))
    return number
end

# ------------------------------------------------------------------------------
# Story forces: the rigid master, or the wall lines of a flexible floor.
# ------------------------------------------------------------------------------

"""
    _require_flexible_diaphragm_support!(struc)

Require what a `:flexible` diaphragm needs from the building before the model
is built: vertical elements, and no strut.

The story force goes to lines of seismic-system walls
([`flexible_diaphragm_layout!`](@ref)). The lateral stage builds those lines
from the declared system, so no tributary area is required here. A strut is a
brace: its force comes from the frame it braces, and no share is guessed for it.
"""
function _require_flexible_diaphragm_support!(struc)
    if !isempty(struc.struts)
        throw(ArgumentError(
            "to_asap!: a :flexible diaphragm sends the story force to lines of " *
            "seismic-system walls. A strut is a brace and is not on such a line. " *
            "No share or guessed fraction is assigned to it."))
    end
    isempty(struc.columns) && isempty(struc.walls) && throw(ArgumentError(
        "to_asap!: :flexible needs vertical elements. " *
        "This structure has no columns and no walls."))
    return struc
end

"""
    diaphragm_story_loads(struc, levels, Fx, Fy, Mz; force_id, moment_id)
        -> Vector{Asap.AbstractLoad}

Place one story force at each level.

`levels` are the ELF or wind levels, lowest first. `Fx`, `Fy`, and `Mz` are
kilonewtons and kilonewton-metres, one entry per level.

Rigid links present: the force and the moment go on each level's master. A
zero force is omitted and a zero moment is omitted. Drift stays on the
rigid link.

No rigid links: the floor is flexible, and the force goes to the lines of
seismic-system walls in `struc.diaphragm_layout`
([`flexible_diaphragm_layout!`](@ref)). Each component along a plan axis
is split among the lines parallel to that axis as simple spans between
adjacent lines: a line takes what lies between the midpoints to its
neighbours, and the outermost line takes everything beyond it. ELF levels
measure that by effective seismic weight; wind levels by the floor width
facing the wind. Within a line, each wall takes a share in proportion to
its length on a uniform top line load; the collector ties along the line
then set the split by stiffness.

`Mz` is not applied to a flexible floor. ASCE 7-22 §12.8.4.2.1 (corpus:
asce-7-22, PDF page 187) requires accidental torsion only where diaphragms
are not flexible, and C12.8.4.1 (PDF page 727) has the tributary mass
resisted with no explicitly computed torsion. The moment is not replaced
by a couple.

A `:semirigid` membrane floor takes the force on its mesh nodes, with `Mz`
as nodal torsion forces ([`_semirigid_story_loads`](@ref)). Wind levels pass
`centroids`, the point each level's `Mz` is about. A full-plate `:shell`
floor throws.

# Citation
ASCE 7-22 §12.8.4 and §12.8.4.1 (corpus: asce-7-22, PDF page 187): the story
shear goes to the vertical elements of the seismic force-resisting system,
and for flexible diaphragms the distribution accounts for the position and
distribution of the supported masses.
"""
function diaphragm_story_loads(struc::BuildingStructure, levels::AbstractVector,
                               Fx::AbstractVector{<:Real},
                               Fy::AbstractVector{<:Real},
                               Mz::AbstractVector{<:Real};
                               force_id::Symbol,
                               moment_id::Symbol,
                               centroids=nothing)
    n = length(levels)
    (length(Fx) == n && length(Fy) == n && length(Mz) == n) || throw(ArgumentError(
        "diaphragm story loads: levels, Fx, Fy, and Mz must be one entry per level."))
    if !isempty(struc.asap_rigid_links)
        return _rigid_story_loads([lv.master for lv in levels], Fx, Fy, Mz;
                                  force_id, moment_id)
    end
    if struc.diaphragm_layout isa SemirigidDiaphragmLayout
        return _semirigid_story_loads(struc, levels, Fx, Fy, Mz; force_id, centroids)
    end
    if _has_semirigid_diaphragm(struc)
        throw(ArgumentError(
            "diaphragm story loads: a full-plate :shell floor is not a rigid " *
            "master, not a split among wall lines, and not the :semirigid membrane."))
    end
    return _flexible_story_loads(struc, levels, Fx, Fy, Mz; force_id)
end

function _has_semirigid_diaphragm(struc)
    model = struc.asap_model
    model === nothing && return false
    for sh in model.shell_elements
        sh.id === :wall && continue
        return true
    end
    return false
end

function _rigid_story_loads(masters, Fx, Fy, Mz; force_id::Symbol, moment_id::Symbol)
    loads = Asap.AbstractLoad[]
    z = 0.0 * u"kN"
    for i in eachindex(masters)
        master = masters[i]
        master === nothing && throw(ArgumentError(
            "diaphragm story loads: level $i has rigid links and no master."))
        if Fx[i] != 0.0 || Fy[i] != 0.0
            push!(loads, Asap.NodeForce(master,
                [Fx[i] * u"kN", Fy[i] * u"kN", z], force_id))
        end
        if Mz[i] != 0.0
            push!(loads, Asap.NodeMoment(master,
                [0.0 * u"kN*m", 0.0 * u"kN*m", Mz[i] * u"kN*m"], moment_id))
        end
    end
    isempty(loads) && throw(ArgumentError(
        "diaphragm story loads: a case produced no story force and no torsion."))
    return loads
end

function _flexible_story_loads(struc, levels, Fx, Fy, Mz; force_id::Symbol)
    if !isempty(struc.struts)
        throw(ArgumentError(
            "flexible diaphragm: a strut is a brace and is not on a wall line. " *
            "No share or guessed fraction is assigned to it."))
    end
    layout = _require_flexible_layout(struc)
    loads = Asap.AbstractLoad[]
    for i in eachindex(levels)
        (Fx[i] == 0.0 && Fy[i] == 0.0) && continue
        append!(loads, _flexible_floor_loads(struc, layout, levels[i],
            Float64(Fx[i]), Float64(Fy[i]), force_id))
    end
    if isempty(loads)
        torsion = any(!iszero, Mz)
        throw(ArgumentError(
            torsion ?
            "flexible diaphragm: the 5% accidental eccentricity is not applied, " *
            "and this case has no story force to distribute." :
            "flexible diaphragm: a case produced no story force."))
    end
    return loads
end

"""
Story force of one level on its wall lines.

Each plan-axis component of `(Fx, Fy)` goes to the lines parallel to that
axis. A component that is zero to rounding is skipped, so a force along one
axis does not require lines along the other.
"""
function _flexible_floor_loads(struc, layout, level, Fx, Fy, force_id::Symbol)
    e1, e2 = plan_axes(layout.plan_axis)
    total = hypot(Fx, Fy)
    loads = Asap.AbstractLoad[]
    for (direction, d, n) in ((:x, e1, e2), (:y, e2, e1))
        F = Fx * d[1] + Fy * d[2]
        abs(F) <= 1e-12 * total && continue
        lines = _diaphragm_lines_at(layout, level.elevation_m, direction)
        isempty(lines) && throw(ArgumentError(
            "flexible diaphragm: no seismic-system wall line along $direction " *
            "reaches the floor at $(level.elevation_m) m, and the story force " *
            "has a component along it. ASCE 7-22 §12.8.4 (corpus: asce-7-22, " *
            "PDF page 187) sends the story shear to the vertical elements of " *
            "the seismic force-resisting system."))
        shares = _diaphragm_line_shares(lines, _strip_measure(struc, level, n))
        for (line, share) in zip(lines, shares)
            share == 0.0 && continue
            append!(loads, _diaphragm_line_loads(struc, line,
                F * share * d[1], F * share * d[2], force_id))
        end
    end
    return loads
end

"""
Fraction of a component each line takes, lines ordered by offset.

`measure(lo, hi)` is the weight or width between two offsets on the axis
across the lines. Line `k` takes the strip from the midpoint to the line
before it to the midpoint to the line after it; the first and last strips
are open, so the floor beyond the outermost lines goes to them.
"""
function _diaphragm_line_shares(lines, measure)
    n = length(lines)
    bounds = Vector{Float64}(undef, n + 1)
    bounds[1] = -Inf
    bounds[end] = Inf
    for k in 1:(n - 1)
        bounds[k + 1] = 0.5 * (lines[k].offset_m + lines[k + 1].offset_m)
    end
    parts = [measure(bounds[k], bounds[k + 1]) for k in 1:n]
    for p in parts
        (isfinite(p) && p >= 0) || throw(ArgumentError(
            "flexible diaphragm: a wall line's tributary measure is $p."))
    end
    total = sum(parts)
    total > 0 || throw(ArgumentError(
        "flexible diaphragm: the floor has no tributary weight or width for its wall lines."))
    return parts ./ total
end

"""Line force `(fx, fy)` [kN] on the walls of one line, each in proportion to its length."""
function _diaphragm_line_loads(struc, line, fx, fy, force_id::Symbol)
    lengths = Float64[]
    for i in line.walls
        g = _wall_pier_geometry(struc.walls[i], struc.skeleton)
        push!(lengths, hypot(g.x2 - g.x1, g.y2 - g.y1))
    end
    total = sum(lengths)
    loads = Asap.AbstractLoad[]
    for (i, L) in zip(line.walls, lengths)
        s = L / total
        append!(loads, _wall_floor_loads(struc, i, line.elevation_m,
            fx * s, fy * s, force_id))
    end
    return loads
end

"""
Uniform line load along the wall top whose resultant is `(fx, fy)` kilonewtons.

The stations are the wall-shell nodes at the floor, in order along the wall.
[`wall_edge_nodal_forces`](@ref) integrates a unit width at pressure `1/L`,
so the weights sum to 1 and each node takes that fraction of the share.
"""
function _wall_floor_loads(struc, wall_index::Int, elevation_m, fx, fy, force_id::Symbol)
    wall = struc.walls[wall_index]
    pier = _pier_by_wall_index(struc.wall_mesh, wall_index)
    geom = _wall_pier_geometry(wall, struc.skeleton)
    dx = geom.x2 - geom.x1
    dy = geom.y2 - geom.y1
    L = hypot(dx, dy)
    L > 0 || throw(ArgumentError(
        "flexible diaphragm: wall $wall_index has no plan length."))
    ux, uy = dx / L, dy / L
    seen = Set{UInt64}()
    edge = Tuple{Float64, Asap.Node}[]
    for sh in pier.shells
        for nd in sh.nodes
            abs(ustrip(u"m", nd.position[3]) - elevation_m) <= WALL_CUT_ZTOL_M || continue
            id = objectid(nd)
            id in seen && continue
            push!(seen, id)
            x = ustrip(u"m", nd.position[1])
            y = ustrip(u"m", nd.position[2])
            s = (x - geom.x1) * ux + (y - geom.y1) * uy
            push!(edge, (s, nd))
        end
    end
    length(edge) >= 2 || throw(ArgumentError(
        "flexible diaphragm: wall $wall_index has fewer than two shell nodes " *
        "at $(elevation_m) m. The share is not placed on one node."))
    sort!(edge; by=first)
    stations = [s for (s, _) in edge]
    span = stations[end] - stations[1]
    span > 1e-9 || throw(ArgumentError(
        "flexible diaphragm: wall $wall_index top nodes have no length."))
    # Width 1 over the stations, pressure 1/span: the integral is 1.
    weights = wall_edge_nodal_forces(stations,
        [WallWidthPiece(stations[1], stations[end], 0.0, 0.0, 1.0)],
        1.0 / span)
    loads = Asap.AbstractLoad[]
    for (k, (_, nd)) in enumerate(edge)
        w = weights[k]
        abs(w) <= 1e-12 && continue
        push!(loads, Asap.NodeForce(nd,
            [w * fx * u"kN", w * fy * u"kN", 0.0 * u"kN"], force_id))
    end
    return loads
end
