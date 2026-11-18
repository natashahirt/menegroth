
# ─── Framing auto-generation (Phase 5, plan `joists-roles-materials`) ─────────

# Named timber presets available to the framing-material resolver. INTENTIONALLY
# EMPTY: no verified NDS Supplement (Table 4A/4B/…) reference design values for a
# timber species/grade are grounded in the corpus (the NDS is not a corpus
# source — see `.cursor/rules/corpus.mdc`). Structural material properties are
# safety-critical and MUST NOT be fabricated, so a JSON caller cannot select a
# timber preset until a grounded one is registered here. The direct
# `framing_opts.materials.timber = <Timber>` Julia path (a caller-supplied
# `StructuralSizer.Timber`) is unaffected and remains the supported way to drive
# mass-timber framing today.
const TIMBER_MAP = Dict{String, StructuralSizer.Timber}()

"""
Resolve a framing-level member material family name to a StructuralSizer
`AbstractMaterial`, drawing on the top-level `materials` block. `"steel"` →
structural steel (`materials.steel`); `"concrete"` → reinforced concrete
(`materials.concrete` + `materials.rebar`); `"timber"` → the named preset in
`materials.timber` (resolved via [`TIMBER_MAP`](@ref)). Errors on any other
value.

Timber is a recognized family (mass-timber joists are supported by the member
sizer via the NDS glulam path), but no NDS-grounded timber preset ships in the
material library yet, so a `"timber"` request errors unless `materials.timber`
names a registered preset. Structural material values are safety-critical and
are never fabricated here (`.cursor/rules/code-accuracy.mdc`).
"""
function _resolve_framing_material(name::AbstractString, api_params::APIParams)
    key = lowercase(strip(name))
    if key == "steel"
        return _resolve_steel_name(api_params.materials.steel)
    elseif key == "concrete"
        conc = _resolve_concrete_name(api_params.materials.concrete)
        reb  = _resolve_rebar(api_params)
        return StructuralSizer.ReinforcedConcreteMaterial(conc, reb)
    elseif key == "timber"
        preset = api_params.materials.timber
        preset === nothing && error(
            "framing_levels material \"timber\" requires a registered timber " *
            "preset named in materials.timber, but none was provided and no " *
            "NDS-grounded timber preset ships yet. Supply a Timber material via " *
            "the framing_opts Julia API, or register a verified preset in TIMBER_MAP.")
        return _resolve_from_map(preset, TIMBER_MAP, "timber preset")
    end
    error("Unknown framing_levels material \"$name\". Options: steel, concrete, timber.")
end

"""
Build the level-1 `opts.materials` NamedTuple for `populate_levels!`. `:beam` is
the universal fallback key resolved by every slab-type path in
`derive_framing_level`; the family key (`:steel`/`:concrete`) is added so a
slab type that prefers a specific family (e.g. OWSJ → `:steel`) picks it up.
"""
function _framing_materials_nt(name::AbstractString, mat)
    fam = Symbol(lowercase(strip(name)))
    return fam in (:steel, :concrete, :timber) ?
        NamedTuple{(fam, :beam)}((mat, mat)) : (; beam = mat)
end

"""
    _resolve_framing_opts(api_params::APIParams) -> NamedTuple

Translate `api_params.framing_levels` into the `opts` NamedTuple consumed by
`populate_levels!`. Returns an empty NamedTuple (a strict no-op) when no framing
levels are requested. Level 1 (framing directly on the slab — joists) sets
`:materials` plus optional `:spacing`/`:n_xi`/`:n_eta`/`:solid_head`/`:axis`/`:count`/`:end_fixity`
(its role is fixed by the slab type; `:axis`/`:count` apply
only to the opts-schema slab types). Levels 2+ each contribute a `:level_N`
schema NamedTuple (`:material`, and optional
`:spacing`/`:role`/`:count`/`:axis`/`:end_fixity`). Spacing is
given in inches on the wire and passed as a `u"inch"` quantity; `populate_levels!`
converts it to the structure's length unit. `end_fixity` is a 2-element release
vector parsed to an `NTuple{2, Symbol}`. Per-level `beam_options` are set on the
Julia opts, not on this wire payload.
"""
function _resolve_framing_opts(api_params::APIParams)
    levels = api_params.framing_levels
    isempty(levels) && return NamedTuple()

    # Level 1 (framing directly on the slab — joists). Geometry/role are fixed by
    # the slab type; the opts-schema slab types additionally honor axis/count.
    lvl1 = levels[1]
    mat1 = _resolve_framing_material(lvl1.material, api_params)
    opts = (; materials = _framing_materials_nt(lvl1.material, mat1))
    if lvl1.spacing_in !== nothing
        opts = merge(opts, (; spacing = lvl1.spacing_in * u"inch"))
    end
    _framing_rib_layout_level(lvl1, 1)
    lvl1.n_xi === nothing || (opts = merge(opts, (; n_xi = lvl1.n_xi)))
    lvl1.n_eta === nothing || (opts = merge(opts, (; n_eta = lvl1.n_eta)))
    if lvl1.module_spacing_in !== nothing
        sp = lvl1.module_spacing_in
        length(sp) == 2 || error(
            "module_spacing_in is [s1, s2] in inches, one per rib family; got $(length(sp)) values.")
        opts = merge(opts, (; module_spacing = (sp[1] * u"inch", sp[2] * u"inch")))
    end
    lvl1.module_angle_deg === nothing ||
        (opts = merge(opts, (; module_angle = deg2rad(lvl1.module_angle_deg))))
    lvl1.solid_head === nothing ||
        (opts = merge(opts, (; solid_head = Float64(lvl1.solid_head))))
    if lvl1.axis !== nothing && length(lvl1.axis) >= 2
        opts = merge(opts, (; axis = (Float64(lvl1.axis[1]), Float64(lvl1.axis[2]))))
    end
    lvl1.count !== nothing && (opts = merge(opts, (; count = lvl1.count)))
    let ef = _resolve_framing_end_fixity(lvl1.end_fixity)
        ef !== nothing && (opts = merge(opts, (; end_fixity = ef)))
    end
    if lvl1.analysis !== nothing
        opts = merge(opts, (; analysis = rib_analysis(lvl1.analysis)))
    end
    try
        _rib_layout_opts(opts)
    catch err
        err isa ArgumentError ? error(err.msg) : rethrow()
    end

    for k in 2:length(levels)
        lvl = levels[k]
        _framing_rib_layout_level(lvl, k)
        lvl.solid_head !== nothing && error(
            "solid_head belongs on framing level 1. Level $k is a beam level.")
        schema = (; material = _resolve_framing_material(lvl.material, api_params))
        lvl.spacing_in !== nothing &&
            (schema = merge(schema, (; spacing = lvl.spacing_in * u"inch")))
        lvl.role !== nothing &&
            (schema = merge(schema, (; role = Symbol(lowercase(strip(lvl.role))))))
        lvl.count !== nothing &&
            (schema = merge(schema, (; count = lvl.count)))
        if lvl.axis !== nothing && length(lvl.axis) >= 2
            schema = merge(schema, (; axis = (Float64(lvl.axis[1]), Float64(lvl.axis[2]))))
        end
        let ef = _resolve_framing_end_fixity(lvl.end_fixity)
            ef !== nothing && (schema = merge(schema, (; end_fixity = ef)))
        end
        if lvl.analysis !== nothing
            schema = merge(schema, (; analysis = rib_analysis(lvl.analysis)))
        end
        opts = merge(opts, NamedTuple{(Symbol("level_$k"),)}((schema,)))
    end
    return opts
end

"""
Wire-level checks on one framing level's rib layout fields.

A grillage layout (`n_xi`/`n_eta`, `module_spacing_in`, `module_angle_deg`,
analysis `"grillage"`) belongs on level 1: later levels are beam levels and
use spacing. Bay counts must each be at least 1. How the level-1 fields combine
is checked by [`_rib_layout_opts`](@ref) once they are options.
"""
function _framing_rib_layout_level(lvl::APIFramingLevel, level_idx::Int)
    layout = lvl.n_xi !== nothing || lvl.n_eta !== nothing ||
        lvl.module_spacing_in !== nothing || lvl.module_angle_deg !== nothing
    grillage = lvl.analysis !== nothing && rib_analysis(lvl.analysis) == :grillage
    if level_idx != 1
        (layout || grillage) && error(
            "n_xi/n_eta, module_spacing_in, and analysis \"grillage\" belong on framing " *
            "level 1. Level $level_idx is a beam level and uses spacing.")
        return nothing
    end
    for n in (lvl.n_xi, lvl.n_eta)
        n === nothing || n >= 1 || error(
            "n_xi and n_eta are bay counts and must each be at least 1, " *
            "got $(lvl.n_xi) by $(lvl.n_eta).")
    end
    return nothing
end

# Accepted per-end release symbols for a framing level's `end_fixity`. `:default`
# defers to the (role, material, lateral_role) release dispatch; the others are
# the explicit member-end releases the runtime `resolve_release` accepts.
const _FRAMING_END_FIXITY_VALUES = (:default, :pinned, :fixed, :free)

"""
Parse an API `end_fixity` (a 2-element `[start, end]` release-name vector) into an
`NTuple{2, Symbol}` for `FramingLevel.end_fixity`. Returns `nothing` when unset.
Errors on a wrong length or an unrecognized release name.
"""
function _resolve_framing_end_fixity(ef::Union{Vector{String}, Nothing})
    ef === nothing && return nothing
    length(ef) == 2 || error(
        "framing_levels end_fixity must have exactly 2 entries [start, end]; got $(length(ef)).")
    syms = ntuple(i -> Symbol(lowercase(strip(ef[i]))), 2)
    for s in syms
        s in _FRAMING_END_FIXITY_VALUES || error(
            "Unknown framing_levels end_fixity release \"$s\". " *
            "Options: $(join(_FRAMING_END_FIXITY_VALUES, ", ")).")
    end
    return syms
end


