# -----------------------------------------------------------------------------
# derive_framing_level
# -----------------------------------------------------------------------------

"""
    derive_framing_level(slab::Slab{T}, level_idx::Int, opts::NamedTuple) -> Union{Nothing, FramingLevel{T}}

Decide the [`FramingLevel`](@ref) a slab should carry at framing `level_idx`, or
`nothing` if none. Keyed on `slab.floor_type::Symbol` (the current slab-type
discriminator — see `StructuralSynthesizer/src/building_types/cells.jl`). Never
throws for an unrecognized slab type: unknown types return `nothing` gracefully.

# Idempotence / manual respect (checked first, all slab types)
- If the slab already carries a level at `level_idx` that has been
  **materialized** (`group_id !== nothing`) → `nothing` (don't re-stack).
- If it carries an attached but **not-yet-materialized** level at `level_idx`
  (e.g. a manual `attach_framing_level!`) → that level is returned so
  `populate_levels!` materializes it.

# Level-1 behavior by slab type

| `floor_type`                              | level-1 result |
|-------------------------------------------|----------------|
| `:waffle`                                 | `IsoparametricPattern` from the slab's `WaffleRibGrid` (via `joist_geometry`); monolithic RC, `role=:joist`, material from `opts.materials.beam`/`.concrete`. `nothing` today (waffle sizing returns a `CIPSlabResult` with no rib grid). |
| `:mass_timber_joist`                      | `LinearAxisPattern` from `joist_geometry(slab,1)` (result `joist_spacing` + `spans.axis`); `role=:joist`, material `opts.materials.timber`. |
| `:joist_roof_deck`                        | same as mass-timber, OWSJ; material `opts.materials.steel`. |
| `:one_way`/`:two_way`/`:composite_deck`/`:non_composite_deck` | opts-schema `LinearAxisPattern`: axis ⟂ `spans.axis`, spacing `opts.spacing` (or ENGINEERING-JUDGMENT default). `nothing` when no material resolvable from `opts`. |
| `:flat_plate`/`:flat_slab`/`:hollow_core`/`:vault`/`:grade`/`:clt`/`:dlt`/`:nlt` and any other | `nothing`. |

For `level_idx ≥ 2`, only an `opts.level_N` `NamedTuple` schema produces a level
(see [`populate_levels!`](@ref)).

!!! note "Non-nullable material"
    `FramingLevel.material::AbstractMaterial` (Phase 4) is not nullable, so a
    level can only be derived when a member material is resolvable. When the
    relevant `opts.materials.*` key is unset, this returns `nothing` rather than
    a partially specified level — the graceful "unset ⇒ no level" path.
"""
function derive_framing_level(slab::Slab{T}, level_idx::Int, opts::NamedTuple) where {T}
    # --- idempotence / manual respect (all slab types) ---
    existing = _existing_level(slab, level_idx)
    if existing !== nothing
        return existing.group_id === nothing ? existing : nothing
    end

    level_idx >= 2 && return _derive_level_schema(slab, level_idx, opts)

    ft = slab.floor_type
    if ft === :waffle || ft === :mass_timber_joist || ft === :joist_roof_deck
        pattern = StructuralSizer.joist_geometry(slab, level_idx)
        pattern === nothing && return nothing
        mat = ft === :waffle          ? _resolve_level_material(opts, :beam, :concrete) :
              ft === :mass_timber_joist ? _resolve_level_material(opts, :timber, :beam) :
                                          _resolve_level_material(opts, :steel, :beam)  # OWSJ
        mat === nothing && return nothing
        # `axis`/`count` are fixed by the sized joist geometry for these slab
        # types; only the release/catalog controls are honored from `opts`.
        return FramingLevel{T}(slab_idx = 0, level = level_idx, pattern = pattern,
                               role = :joist, material = mat,
                               end_fixity = get(opts, :end_fixity, (:default, :default)),
                               beam_options = get(opts, :beam_options, nothing),
                               analysis = rib_analysis(get(opts, :analysis, :tributary)))
    elseif ft === :one_way || ft === :two_way ||
           ft === :composite_deck || ft === :non_composite_deck
        return _derive_schema_level(slab, level_idx, opts)
    else
        # :flat_plate, :flat_slab, :hollow_core, :vault, :grade, :clt, :dlt,
        # :nlt, and any unrecognized floor type → no auto-generated framing.
        return nothing
    end
end

"""First level on `slab` whose `level == level_idx`, or `nothing`."""
function _existing_level(slab::Slab, level_idx::Int)
    idx = findfirst(fl -> fl.level == level_idx, slab.framing_levels)
    return idx === nothing ? nothing : slab.framing_levels[idx]
end

"""
First resolvable material among `keys` in `opts.materials`, or `nothing`. Used
to fill the (non-nullable) `FramingLevel.material` for slab types that do not
carry their own member material.
"""
function _resolve_level_material(opts::NamedTuple, keys::Symbol...)
    mats = get(opts, :materials, NamedTuple())
    mats isa NamedTuple || return nothing
    for k in keys
        m = get(mats, k, nothing)
        m isa AbstractMaterial && return m
    end
    return nothing
end

"""
    _rib_layout_opts(opts) -> NamedTuple

Validate the level-1 rib layout keys of `opts` and return
`(grillage, layout)`. `layout` is `:bays` for `n_xi`/`n_eta` (an
[`IsoparametricPattern`](@ref)), `:module` for `module_spacing` (a
[`ModularRibPattern`](@ref), with optional `module_angle` in radians and
`module_origin` in metres), or `nothing`. A rib layout is a grillage, and a
grillage needs one. `solid_head` is a corner fraction of a quadrilateral panel,
so it goes with `n_xi`/`n_eta` only. Throws `ArgumentError` on any conflict.
"""
function _rib_layout_opts(opts::NamedTuple)
    nξ = get(opts, :n_xi, nothing)
    nη = get(opts, :n_eta, nothing)
    (nξ === nothing) == (nη === nothing) || throw(ArgumentError(
        "a grillage level needs both n_xi and n_eta"))
    counts = nξ !== nothing
    modular = haskey(opts, :module_spacing)
    counts && modular && throw(ArgumentError(
        "a grillage level gives n_xi/n_eta or module_spacing, not both"))
    if !modular && (haskey(opts, :module_angle) || haskey(opts, :module_origin))
        throw(ArgumentError("module_angle and module_origin go with module_spacing"))
    end
    layout = counts ? :bays : modular ? :module : nothing
    requested = get(opts, :analysis, layout === nothing ? :tributary : :grillage)
    grillage = rib_analysis(requested) == :grillage || layout !== nothing
    if grillage && layout === nothing
        throw(ArgumentError("a grillage level needs n_xi and n_eta, or module_spacing"))
    end
    if layout !== nothing && haskey(opts, :analysis) && rib_analysis(requested) == :tributary
        throw(ArgumentError(
            "n_xi/n_eta and module_spacing are a grillage. A tributary level uses spacing."))
    end
    if layout !== nothing && haskey(opts, :spacing)
        throw(ArgumentError(
            "a grillage level sends both spacing and a rib layout. " *
            "A grillage uses n_xi/n_eta or module_spacing; a tributary level uses spacing."))
    end
    if haskey(opts, :solid_head)
        grillage || throw(ArgumentError(
            "solid_head belongs on a grillage. A tributary level has no solid head."))
        layout === :module && throw(ArgumentError(
            "solid_head is a corner fraction of a quadrilateral panel and goes with " *
            "n_xi/n_eta, not module_spacing"))
        s = Float64(opts.solid_head)
        0 <= s < 0.5 || throw(ArgumentError(
            "solid_head is the fraction of the panel from each corner and must be " *
            "in [0, 1/2), got $s"))
    end
    return (; grillage, layout)
end

"""Plan length in metres from a `Unitful` length or a bare number of metres."""
_plan_m(x::Unitful.Length) = Float64(ustrip(u"m", x))
_plan_m(x::Real) = Float64(x)

"""The rib pattern of a validated grillage `layout` (see [`_rib_layout_opts`](@ref))."""
function _grillage_pattern(opts::NamedTuple, layout::Symbol)
    if layout === :bays
        nξ, nη = Int(opts.n_xi), Int(opts.n_eta)
        s = StructuralSizer.snapped_solid_head(Float64(get(opts, :solid_head, 0.0)), nξ, nη)
        return IsoparametricPattern(nξ, nη, s)
    end
    sp = opts.module_spacing
    length(sp) == 2 || throw(ArgumentError(
        "module_spacing is one spacing per rib family, got $(length(sp)) values"))
    origin = get(opts, :module_origin, nothing)
    origin === nothing || (origin = (_plan_m(origin[1]), _plan_m(origin[2])))
    return ModularRibPattern(Float64(get(opts, :module_angle, 0.0)),
                             (_plan_m(sp[1]), _plan_m(sp[2])), origin)
end

"""
opts-schema level for `:one_way` / `:two_way` / `:composite_deck` /
`:non_composite_deck` (level 1). Joists run ⟂ to `slab.spans.axis` at
`opts.spacing` (or an ENGINEERING-JUDGMENT default). Returns `nothing` when no
member material is resolvable from `opts.materials`.

Optional top-level `opts` keys are honored for this level-1 joist field:
`:axis` (joist run direction; defaults to ⟂ `slab.spans.axis`), `:count`
(explicit joist count), `:end_fixity`, and `:beam_options`
(level sizing options; see [`FramingLevel`](@ref)). These let a
caller override the schema-convention layout for the opts-schema slab types
(the joist-sizing slab types — mass-timber / OWSJ / waffle — take their level-1
geometry from the sized result instead; see [`derive_framing_level`](@ref)).
"""
function _derive_schema_level(slab::Slab{T}, level_idx::Int, opts::NamedTuple) where {T}
    plan = _rib_layout_opts(opts)
    if plan.grillage
        mat = _resolve_level_material(opts, :concrete, :beam, :steel, :timber)
        mat === nothing && return nothing
        pattern = _grillage_pattern(opts, plan.layout)
        return FramingLevel{T}(slab_idx = 0, level = level_idx, pattern = pattern,
                               role = :joist, material = mat,
                               end_fixity = get(opts, :end_fixity, (:default, :default)),
                               beam_options = get(opts, :beam_options, nothing),
                               analysis = :grillage)
    end
    mat = _resolve_level_material(opts, :steel, :beam, :timber, :concrete)
    mat === nothing && return nothing
    axis = slab.spans.axis
    perp = (-axis[2], axis[1])              # joists ⟂ span axis (schema convention)
    joist_axis = get(opts, :axis, perp)
    spacing = _resolve_schema_spacing(T, opts, mat)
    pattern = LinearAxisPattern{T}(joist_axis, spacing, get(opts, :count, nothing))
    return FramingLevel{T}(slab_idx = 0, level = level_idx, pattern = pattern,
                           role = :joist, material = mat,
                           end_fixity = get(opts, :end_fixity, (:default, :default)),
                           beam_options = get(opts, :beam_options, nothing),
                           analysis = rib_analysis(get(opts, :analysis, :tributary)))
end

"""
Schema joist spacing (structure length unit `T`): `opts.spacing` if present,
`nothing` for a count-only level (the layout and tributary width come from the
count), else the ENGINEERING-JUDGMENT per-material default.
"""
function _resolve_schema_spacing(::Type{T}, opts::NamedTuple, mat::AbstractMaterial) where {T}
    sp = get(opts, :spacing, nothing)
    count = get(opts, :count, nothing)
    sp !== nothing && count !== nothing && throw(ArgumentError(
        "a framing level gives both spacing and count; give one"))
    count === nothing || return nothing
    if sp !== nothing
        return _len_T(T, sp)
    end
    default_m = mat isa StructuralSizer.Timber ?
        _JUDGMENT_WOOD_JOIST_SPACING_M : _JUDGMENT_STEEL_JOIST_SPACING_M
    return _len_T(T, default_m)
end

"""
    _qualify_module_framing(opts, params) -> (NamedTuple, String)

Keep a module grid as a waffle only when its ribs are concrete and every
center spacing passes [`StructuralSizer.joist_center_feasible`](@ref).
ACI 318-11 §8.13.1–§8.13.3 (corpus: aci-318-11, page 120) is that test.
§8.13.4 otherwise: the two-way grillage is not built.

ENGINEERING JUDGMENT for what replaces it. A concrete module that fails
becomes one-way joists at [`StructuralSizer.joist_fallback_center_spacing`](@ref)
(4 in + 30 in), and a two-way floor becomes one-way so the slab spans onto
those joists. A module whose ribs are not concrete is not §8.13 joist
construction; it becomes one-way joists at the larger requested spacing,
and the floor system is left as given. The note is empty when nothing changes.
"""
function _qualify_module_framing(opts::NamedTuple, params)
    haskey(opts, :module_spacing) || return opts, ""
    sp = opts.module_spacing
    length(sp) == 2 || return opts, ""
    centers = [_module_length(s) for s in sp]
    concrete = _module_is_concrete(opts, params)
    if concrete && all(StructuralSizer.joist_center_feasible, centers)
        return opts, ""
    end
    spacing = concrete ? StructuralSizer.joist_fallback_center_spacing() : maximum(centers)
    if concrete && params.floor isa StructuralSizer.TwoWayOptions
        old = params.floor
        params.floor = StructuralSizer.OneWayOptions(
            material = old.material, cover = old.cover, bar_size = old.bar_size)
    end
    drop = (:module_spacing, :module_angle, :module_origin, :n_xi, :n_eta,
            :solid_head, :analysis)
    kept = [k => opts[k] for k in keys(opts) if k ∉ drop]
    qualified = merge((; kept...), (spacing = spacing, analysis = :tributary))
    requested = join((string(round(ustrip(u"inch", c); digits = 1)) * " in" for c in centers),
                     " by ")
    used = string(round(ustrip(u"inch", spacing); digits = 1)) * " in"
    note = if concrete
        "Module spacing $requested cannot meet ACI 318-11 §8.13.3 with a joist " *
        "rib (§8.13.2, corpus: aci-318-11, page 120). §8.13.4 applies: the floor " *
        "is one-way joists at $used, not a waffle."
    else
        "Module spacing $requested is not concrete joist construction (ACI 318-11 " *
        "§8.13.1, corpus: aci-318-11, page 120). It is laid out as one-way joists at $used."
    end
    @warn note
    if occursin("waffle", lowercase(params.name))
        params.name = concrete ? "one-way concrete joists" : "one-way joists"
    end
    params.description = isempty(params.description) ? note : params.description * "\n" * note
    params.framing_opts = qualified
    return qualified, note
end

"""Plan length as a `Length`. A bare number is metres, matching [`_plan_m`](@ref)."""
_module_length(x::Unitful.Length) = uconvert(u"m", x)
_module_length(x::Real) = Float64(x) * u"m"

"""
`true` when this module grid is monolithic concrete on a one-way or two-way
slab. ACI 318-11 §8.13.1 (corpus: aci-318-11, page 120) is that construction.
A deck, or any non-concrete rib, is not.
"""
function _module_is_concrete(opts::NamedTuple, params)
    floor = params.floor
    (floor isa StructuralSizer.OneWayOptions || floor isa StructuralSizer.TwoWayOptions) ||
        return false
    mat = _resolve_level_material(opts, :concrete, :beam)
    return mat isa StructuralSizer.Concrete ||
           mat isa StructuralSizer.ReinforcedConcreteMaterial
end

"""
Level `N ≥ 2` from an explicit `opts.level_N` `NamedTuple` schema. The schema
carries at least `:material`; optional `:axis`, `:spacing`, `:role`
(`:joist`|`:beam`), `:count`, `:end_fixity`, `:beam_options`.
Returns `nothing` when the key is absent or carries no material.

# Default axis (perpendicular alternation)
When the schema does not pin `:axis`, the level's joist run-direction alternates
so consecutive levels are mutually perpendicular (the standard girder →
secondary-beam → joist framing convention). Level 1's opts-schema joists run ⟂
to `slab.spans.axis` (see [`_derive_schema_level`](@ref)); so an even level
(2, 4, …) defaults to `slab.spans.axis` (⟂ to level 1) and an odd level ≥ 3
(3, 5, …) defaults to the perpendicular of `slab.spans.axis` (⟂ to level 2).
A prior bug hardcoded every level ≥ 2 to `slab.spans.axis`, which left Level 3
parallel to (instead of perpendicular to) Level 2.
"""
function _derive_level_schema(slab::Slab{T}, level_idx::Int, opts::NamedTuple) where {T}
    schema = get(opts, Symbol("level_$(level_idx)"), nothing)
    schema isa NamedTuple || return nothing
    mat = get(schema, :material, nothing)
    mat isa AbstractMaterial || return nothing
    # Default axis (perpendicular alternation): Level 1 (joists) defaults to
    # ⟂ slab.spans.axis. Even levels (2, 4, …) alternate to the preceding
    # level's axis — so Level 2 defaults to ⟂ Level 1 (parallel to slab axis).
    # A prior bug hardcoded alternation against the slab axis, not the
    # preceding level, which left Level 3 parallel to (instead of ⟂) Level 2.
    base_axis = slab.spans.axis
    perp_axis = (-base_axis[2], base_axis[1])
    
    default_axis = if level_idx == 1
        perp_axis
    else
        prev = _existing_level(slab, level_idx - 1)
        if prev !== nothing && prev.pattern isa LinearAxisPattern
            pax = prev.pattern.axis
            (-pax[2], pax[1])
        else
            # fallback for non-linear or missing level
            iseven(level_idx) ? base_axis : perp_axis
        end
    end
    axis = get(schema, :axis, default_axis)
    role = get(schema, :role, :beam)
    spacing = _resolve_schema_spacing(T, (; spacing = get(schema, :spacing, nothing),
                                          count = get(schema, :count, nothing)), mat)
    pattern = LinearAxisPattern{T}(axis, spacing, get(schema, :count, nothing))
    return FramingLevel{T}(slab_idx = 0, level = level_idx, pattern = pattern,
                           role = role, material = mat,
                           end_fixity = get(schema, :end_fixity, (:default, :default)),
                           beam_options = get(schema, :beam_options, nothing),
                           analysis = rib_analysis(get(schema, :analysis, :tributary)))
end

