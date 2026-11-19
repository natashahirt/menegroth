# =============================================================================
# Material Resolution (convenience accessors from DesignParameters)
# =============================================================================

"""Resolve slab concrete from design parameters."""
resolve_concrete(params::DesignParameters, override=nothing) =
    something(override, resolve_slab_concrete(params.materials))

"""Resolve slab rebar from design parameters."""
resolve_rebar(params::DesignParameters, override=nothing) =
    something(override, resolve_slab_rebar(params.materials))

"""Resolve slab RC material from design parameters."""
function resolve_rc_material(params::DesignParameters, override=nothing)
    !isnothing(override) && return override
    resolve_slab_rc(params.materials)
end

"""
    column_concrete(params) -> Concrete
    column_rebar(params) -> RebarSteel

Concrete and rebar of the RC columns, for every strength check, takeoff,
embodied-carbon count, and stiffness. Concrete `params.columns` options win.
Without them, the material cascade gives the value (`resolve_column_concrete`,
default 6 ksi; `resolve_column_rebar`, default Grade 60).
[`check_column_materials`](@ref) rejects a cascade that names a different
material from the options.
"""
column_concrete(params::DesignParameters) =
    params.columns isa ConcreteColumnOptions ? params.columns.material :
    resolve_column_concrete(params.materials)

column_rebar(params::DesignParameters) =
    params.columns isa ConcreteColumnOptions ? params.columns.rebar_material :
    resolve_column_rebar(params.materials)

"""
    concrete_column_options(params) -> ConcreteColumnOptions

`params.columns` when it is concrete. Otherwise the default options with the
column concrete and rebar of the material cascade, so the columns are checked
in the material they are taken off in.
"""
concrete_column_options(params::DesignParameters) =
    params.columns isa ConcreteColumnOptions ? params.columns :
    ConcreteColumnOptions(material = resolve_column_concrete(params.materials),
                          rebar_material = resolve_column_rebar(params.materials))

"""
    check_column_materials(params)

Throw an `ArgumentError` when concrete `params.columns` and the material
cascade both name a column concrete or rebar and they differ. The cascade
names one through `materials.column`, or through `materials.concrete` /
`materials.rebar`.
"""
function check_column_materials(params::DesignParameters)
    opts = params.columns
    opts isa ConcreteColumnOptions || return nothing
    m = params.materials
    conc = something(isnothing(m.column) ? nothing : m.column.concrete, m.concrete, Some(nothing))
    reb = something(isnothing(m.column) ? nothing : m.column.rebar, m.rebar, Some(nothing))
    if conc !== nothing && opts.materials === nothing && !isequal(conc, opts.material)
        throw(ArgumentError(
            "Column concrete is set twice and differs: params.columns.material = " *
            "$(StructuralSizer.material_name(opts.material)) but params.materials gives $(StructuralSizer.material_name(conc)). " *
            "Set one, or make them the same."))
    end
    if reb !== nothing && !isequal(reb, opts.rebar_material)
        throw(ArgumentError(
            "Column rebar is set twice and differs: params.columns.rebar_material = " *
            "$(StructuralSizer.material_name(opts.rebar_material)) but params.materials gives $(StructuralSizer.material_name(reb)). " *
            "Set one, or make them the same."))
    end
    return nothing
end

"""
    resolve_floor_options(params::DesignParameters) -> AbstractFloorOptions

Resolve the effective floor options from `params`.  Returns a typed
`AbstractFloorOptions`.  Applies the
material cascade from `params.materials` into the floor options.
"""
function resolve_floor_options(params::DesignParameters)
    floor = something(params.floor, StructuralSizer.FlatPlateOptions())
    check_material_compatibility(params.materials, floor)
    check_column_materials(params)
    cascaded = _apply_material_cascade(params.materials, floor)
    # ACI 318-11 §10.10.4.1 — `params.column_I_factor` is the single source of truth
    # for flat-plate COLUMN cracked stiffness. Thread it into the floor options so the
    # FEA path (which reads `opts.col_I_factor`) uses the param rather than the field
    # default. At the default `column_I_factor = 0.70` this matches the field default
    # → byte-exact no-op.
    return _apply_flat_plate_analysis(
        _apply_col_I_factor(cascaded, params.column_I_factor), params)
end

"""
    _apply_flat_plate_analysis(opts, params) -> opts

Under `params.flat_plate_analysis = :building`, a flat plate or flat slab is
analysed on the building model: `FEA(source = :building)`, keeping the other
settings of an `FEA` method the options already name. `:options` returns
`opts` unchanged.
"""
function _apply_flat_plate_analysis(opts::StructuralSizer.FlatPlateOptions,
                                    params::DesignParameters)
    mode = params.flat_plate_analysis
    mode in (:building, :options) || throw(ArgumentError(
        "flat_plate_analysis must be :building or :options (got :$mode)"))
    mode === :options && return opts
    m = opts.method
    @set opts.method = m isa StructuralSizer.FEA ?
        StructuralSizer.with_fea_source(m, :building) : StructuralSizer.FEA(source = :building)
end

function _apply_flat_plate_analysis(opts::StructuralSizer.FlatSlabOptions,
                                    params::DesignParameters)
    @set opts.base = _apply_flat_plate_analysis(opts.base, params)
end

_apply_flat_plate_analysis(opts::StructuralSizer.AbstractFloorOptions, ::DesignParameters) = opts

# --- Material cascade into floor options (using Accessors @set) ---

"""Cascade user-specified materials into `FlatPlateOptions`."""
function _apply_material_cascade(mat::MaterialOptions, opts::StructuralSizer.FlatPlateOptions)
    _has_material(mat) || return opts
    @set opts.material = resolve_slab_rc(mat)
end

"""Cascade user-specified materials into `FlatSlabOptions` (delegates to the base options)."""
function _apply_material_cascade(mat::MaterialOptions, opts::StructuralSizer.FlatSlabOptions)
    _has_material(mat) || return opts
    new_base = _apply_material_cascade(mat, opts.base)
    @set opts.base = new_base
end

"""Cascade user-specified materials into `TwoWayOptions`."""
function _apply_material_cascade(mat::MaterialOptions, opts::StructuralSizer.TwoWayOptions)
    _has_material(mat) || return opts
    @set opts.material = resolve_slab_rc(mat)
end

"""Cascade user-specified materials into `OneWayOptions`."""
function _apply_material_cascade(mat::MaterialOptions, opts::StructuralSizer.OneWayOptions)
    _has_material(mat) || return opts
    @set opts.material = resolve_slab_rc(mat)
end

"""Cascade user-specified materials into `VaultOptions`."""
function _apply_material_cascade(mat::MaterialOptions, opts::StructuralSizer.VaultOptions)
    _has_material(mat) || return opts
    @set opts.material = resolve_slab_concrete(mat)
end

# Fallback: no material fields to cascade into
"""Fallback: no material fields to cascade into; return options unchanged."""
_apply_material_cascade(::MaterialOptions, opts::StructuralSizer.AbstractFloorOptions) = opts

"""True if any material is set on `mat`."""
_has_material(m::MaterialOptions) =
    !isnothing(m.slab) || !isnothing(m.column) || !isnothing(m.concrete) || !isnothing(m.rebar)

# --- Column cracking factor into floor options (using Accessors @set) ---
# ACI 318-11 §10.10.4.1 — reduced (cracked) column moment of inertia (0.70·Ig).
# `params.column_I_factor` is the single source of truth; mirror the
# `_apply_material_cascade` multiple-dispatch pattern so option types that have no
# column cracking factor fall through unchanged (must not crash).

"""Warn when a floor-option column factor disagrees with the param, then return the param.

`params.column_I_factor` stays the value that runs. The warning records both
numbers and which one ran. Equal values stay silent (default 0.70 is a no-op).
"""
function _warn_col_I_conflict(options_value::Real, column_I_factor::Real, options_label::AbstractString)
    ran = Float64(column_I_factor)
    opts_val = Float64(options_value)
    if opts_val != ran
        @warn string(options_label, ".col_I_factor differs from params.column_I_factor; ",
                     "params.column_I_factor ran") options_col_I_factor=opts_val params_column_I_factor=ran
    end
    return ran
end

"""Set the FEA column cracking factor on `FlatPlateOptions` (ACI 318-11 §10.10.4.1)."""
function _apply_col_I_factor(opts::StructuralSizer.FlatPlateOptions, column_I_factor::Real)
    ran = _warn_col_I_conflict(opts.col_I_factor, column_I_factor, "FlatPlateOptions")
    @set opts.col_I_factor = ran  # ACI 318-11 §10.10.4.1
end

"""Set the FEA column cracking factor on `FlatSlabOptions` (delegates to the wrapped `base`)."""
function _apply_col_I_factor(opts::StructuralSizer.FlatSlabOptions, column_I_factor::Real)
    ran = _warn_col_I_conflict(opts.base.col_I_factor, column_I_factor, "FlatSlabOptions.base")
    @set opts.base.col_I_factor = ran  # ACI 318-11 §10.10.4.1
end

# Fallback: option types without a column cracking factor (OneWayOptions, VaultOptions, …)
"""Fallback: floor options with no column cracking factor; return options unchanged."""
_apply_col_I_factor(opts::StructuralSizer.AbstractFloorOptions, ::Real) = opts

# =============================================================================
# `with` helper (Accessors-based, replaces _with)
# =============================================================================

"""
    with(params::DesignParameters; kwargs...) -> DesignParameters

Create a modified copy of `DesignParameters`.

# Example
```julia
base = DesignParameters(materials = MaterialOptions(concrete = NWC_5000))
v1 = with(base; floor = FlatPlateOptions(method = EFM(solver=:asap)))
v2 = with(base; floor = FlatSlabOptions(), loads = GravityLoads(floor_LL = 80.0psf))
```
"""
with(params::DesignParameters; kwargs...) = setproperties(params, (; kwargs...))

"""
    ResolvedDesignContext

Immutable ownership boundary for one design run. `params` and
`framing_opts` are deep copies, so later caller mutation cannot change an
active run. `content_hash` fingerprints the effective inputs after explicit
framing options have been resolved against `DesignParameters.framing_opts`.
"""
struct ResolvedDesignContext
    params::DesignParameters
    framing_opts::NamedTuple
    content_hash::String
end

"""
    resolve_design_context(params; framing_opts=NamedTuple())

Copy and normalize the effective inputs for a design run.
"""
function resolve_design_context(
    params::DesignParameters;
    framing_opts::NamedTuple = NamedTuple(),
)
    owned_params = deepcopy(params)
    effective_framing = isempty(framing_opts) ?
        deepcopy(owned_params.framing_opts) : deepcopy(framing_opts)
    run_hash = content_hash((owned_params, effective_framing))
    return ResolvedDesignContext(owned_params, effective_framing, run_hash)
end

"""Primary (governing) strength combination from a DesignParameters."""
governing_combo(p::DesignParameters) = first(p.load_combinations)

"""
    resolve_member_group_override(params::DesignParameters, gid::UInt64)
        -> Union{MemberGroupSizingOverride, Nothing}

The per-group sizing override for `gid` from `params.member_group_overrides`, or
`nothing` when the group has no override. Pass the result as the `override` kwarg
to [`size_member_group!`](@ref). Returns `nothing` (a no-op) for every group when
`member_group_overrides` is empty (the default), keeping all existing callers
byte-identical.
"""
resolve_member_group_override(params::DesignParameters, gid::UInt64) =
    get(params.member_group_overrides, gid, nothing)

"""
    resolve_objective(sym::Symbol) -> AbstractObjective

Map a DesignParameters `optimize_for` symbol to its StructuralSizer objective type.
"""
function resolve_objective(sym::Symbol)
    sym === :weight && return StructuralSizer.MinWeight()
    sym === :carbon && return StructuralSizer.MinCarbon()
    sym === :cost   && return StructuralSizer.MinCost(1.0)
    sym === :volume && return StructuralSizer.MinVolume()
    return StructuralSizer.MinWeight()
end

# ─── Fire rating validation ───
const VALID_FIRE_RATINGS = (0.0, 1.0, 1.5, 2.0, 3.0, 4.0)

"""
    validate_fire_rating(rating::Real) -> Float64

Validate fire resistance rating. Must be one of: 0, 1, 1.5, 2, 3, 4 hours.
Throws `ArgumentError` for invalid values.
"""
function validate_fire_rating(rating::Real)
    r = Float64(rating)
    r in VALID_FIRE_RATINGS && return r
    throw(ArgumentError(
        "Invalid fire_rating = $r. Must be one of $(VALID_FIRE_RATINGS) hours."
    ))
end

"""True if the design requires fire protection (fire_rating > 0)."""
has_fire_rating(p::DesignParameters) = p.fire_rating > 0.0

