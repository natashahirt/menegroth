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
# Flexible idealization: tributary split of a caller-supplied story force.
# to_asap! does not apply that force to a building.
# ------------------------------------------------------------------------------

"""
    distribute_flexible_diaphragm_story_force(story_force, tributary_areas)
        -> Vector{NTuple{2}}

Split one story force among vertical elements by tributary area.

`story_force` is `(Fx, Fy)`. Each element `i` receives
`story_force * (A_i / Σ A)`. A missing area (`nothing`), an empty list, a
negative area, or a non-positive total throws. A zero area is kept and
receives no force when some other area is positive.

ENGINEERING JUDGMENT: ASCE 7-22 §12.3.1.1 (corpus: asce-7-22, PDF p. 179)
permits the flexible idealization and does not state this split. The split
is the tributary distribution specified for `:flexible`. No additional factor
is applied. This function does not write loads onto a building.

The two components of `story_force` must already be in one unit. The areas
must already be in one unit. A `nothing` entry is missing geometry, not zero.
"""
function distribute_flexible_diaphragm_story_force(story_force, tributary_areas)
    (story_force isa Tuple && length(story_force) == 2) || throw(ArgumentError(
        "story_force must be an (Fx, Fy) tuple, got $(typeof(story_force))"))
    areas = _tributary_area_values(tributary_areas)
    total = sum(areas)
    isfinite(total) && total > 0 || throw(ArgumentError(
        "flexible-diaphragm tributary areas sum to $total; the story force is not distributed"))
    Fx, Fy = story_force
    return [(Fx * (a / total), Fy * (a / total)) for a in areas]
end

"""Numeric areas in the caller's unit. `nothing` and NaN throw."""
function _tributary_area_values(tributary_areas)::Vector{Float64}
    tributary_areas isa AbstractVector || throw(ArgumentError(
        "tributary_areas must be a vector of areas"))
    isempty(tributary_areas) && throw(ArgumentError(
        "flexible diaphragm has no tributary areas"))
    areas = Float64[]
    saw_quantity = false
    saw_bare = false
    for area in tributary_areas
        area === nothing && throw(ArgumentError(
            "a vertical element's tributary area is missing"))
        if area isa Quantity
            saw_quantity = true
        elseif area isa Real && !(area isa Bool)
            saw_bare = true
        else
            throw(ArgumentError(
                "tributary area must be a number or a length², got $(typeof(area))"))
        end
    end
    saw_quantity && saw_bare && throw(ArgumentError(
        "tributary areas must all be lengths² or all be numbers in the same unit"))
    for area in tributary_areas
        value = if area isa Quantity
            ustrip(u"m^2", area)
        else
            float(area)
        end
        isfinite(value) || throw(ArgumentError("tributary area is not finite ($area)"))
        value < 0 && throw(ArgumentError("tributary area is negative ($area)"))
        push!(areas, value)
    end
    return areas
end

"""
    _require_flexible_diaphragm_tributaries!(struc)

Require the geometry a `:flexible` diaphragm needs, and call the existing
column tributary path when that path can supply every vertical element's area.

Does not apply a story force and does not build a rigid link or a shell.

Throws when there are no floor cells, when there are no columns, when any
column has no positive tributary area, or when walls or struts are present.
No tributary-area path exists for walls or struts, so those buildings are
not given the column areas in their place.
"""
function _require_flexible_diaphragm_tributaries!(struc)
    isempty(struc.cells) && throw(ArgumentError(
        "to_asap!: :flexible needs floor cells to compute a tributary area. None are present."))
    if !isempty(struc.walls) || !isempty(struc.struts)
        throw(ArgumentError(
            "to_asap!: :flexible needs a tributary area for each vertical element. " *
            "No tributary-area path exists for walls or struts. " *
            "A rigid link or a shell is not substituted."))
    end
    isempty(struc.columns) && throw(ArgumentError(
        "to_asap!: :flexible needs vertical elements with tributary areas. " *
        "This structure has no columns."))
    # Existing gravity-tributary path. It does not apply a story force.
    compute_column_tributaries!(struc)
    for col in struc.columns
        area = column_tributary_area(struc, col)
        if area === nothing || !(ustrip(u"m^2", area) > 0)
            throw(ArgumentError(
                "to_asap!: :flexible is missing a positive tributary area for a column " *
                "(story $(col.story), vertex $(col.vertex_idx))."))
        end
    end
    return struc
end
