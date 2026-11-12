# =============================================================================
# Framing hierarchy: joist patterns + FramingLevel container  — Phase 4
# =============================================================================
#
# The multi-level framing model (plan `joists-roles-materials`, Phase 4). A slab
# owns zero or more `FramingLevel`s (levels 1, 2, …); level 0 is the primary
# column-to-column skeleton and does NOT get a `FramingLevel`. Each level pairs a
# geometric `AbstractJoistPattern` (how joist lines are laid out in the slab's
# local 2D frame) with the member metadata (role, material, releases, catalog)
# needed to materialize real `Beam{T}`s in Phase 5.
#
# `AbstractJoistPattern` itself is declared in StructuralSizer
# (`slabs/types.jl`) so the Sizer-side `joist_geometry` trait can name it; the
# concrete subtypes below extend it. Auto-generation (`populate_levels!` /
# `materialize_level!`) is Phase 5 and lives elsewhere.
#
# Include order: this file defines the `FramingLevel{T}` type referenced by
# `Slab{T}.framing_levels`, so it is included BEFORE `cells.jl`. The public
# `attach_framing_level!` mutator (which needs `BuildingStructure`/`Slab`) lives
# in `framing_api.jl`, included after `structure.jl`.
#
# 2D coordinate convention: patterns are expressed in the slab-local planar
# frame. Direction/point 2-tuples use `NTuple{2, Float64}` to match the rest of
# the module (`TributaryProfile.axis`, `SpanInfo.axis`, `Column.boundary_edge_dirs`);
# the module does not use StaticArrays.

# -----------------------------------------------------------------------------
# Joist patterns
# -----------------------------------------------------------------------------

# ...
# box-section connections.
# =============================================================================

# Reserved edge group symbols for beam-like members (Phase 5 integration).
# Used by sizing, demand extraction, and load paths to ensure generated
# framing (joists, secondary beams) is treated as part of the beam set.
const BEAM_GROUP_SYMBOLS = (:beams, :joists, :secondary, :girder)

"""
    LinearAxisPattern{T} <: AbstractJoistPattern

Parallel joists running along a fixed in-plane direction — the one-way joist
field (steel OWSJ over a deck, mass-timber joists, secondary beams).

# Fields
- `axis::NTuple{2, Float64}`: unit direction of the joists in the slab-local 2D
  frame. Joist lines are parallel to this axis; they are laid out at `spacing`
  intervals perpendicular to it.
- `spacing::Union{T, Nothing}`: center-to-center joist spacing (a length in the
  slab's `T` unit). `nothing` ⇒ unresolved; derived from the slab extent / floor
  schema in Phase 5.
- `count::Union{Int, Nothing}`: explicit number of joists. `nothing` ⇒ derived
  from the slab extent and `spacing` later.

At least one of `spacing` / `count` is expected to be resolved before
materialization; both `nothing` means "derive entirely from slab geometry".
"""
struct LinearAxisPattern{T} <: StructuralSizer.AbstractJoistPattern
    axis::NTuple{2, Float64}
    spacing::Union{T, Nothing}
    count::Union{Int, Nothing}
end

"""
    IsoparametricPattern <: AbstractJoistPattern

Two-family rib grid over an isoparametric quad panel (Nervi-style RC waffle):
ribs run along lines of constant ξ and constant η, dividing the panel into
`n_xi × n_eta` modules in parametric space.

# Fields
- `n_xi::Int`: number of rib modules in the first (ξ) isoparametric direction.
- `n_eta::Int`: number of rib modules in the second (η) isoparametric direction.
- `solid_head::Float64`: fraction of the panel, measured from each corner in
  both directions, that is cast solid. `0` is an open rib grid. The fraction
  is in `[0, 1/2)` so the four corner heads do not meet. A positive value is
  snapped up to a whole rib module by [`snapped_solid_head`](@ref) before the
  beams are cut.

Mirrors `StructuralSizer.WaffleRibGrid` (`nξ`, `nη`, `solid_head`).
"""
struct IsoparametricPattern <: StructuralSizer.AbstractJoistPattern
    n_xi::Int
    n_eta::Int
    solid_head::Float64

    function IsoparametricPattern(n_xi::Integer, n_eta::Integer, solid_head::Real = 0.0)
        s = Float64(solid_head)
        0 <= s < 0.5 || throw(ArgumentError(
            "solid_head is the fraction of the panel from each corner and must be " *
            "in [0, 1/2), got $s"))
        return new(Int(n_xi), Int(n_eta), s)
    end
end

"""
    ModularRibPattern <: AbstractJoistPattern

Two orthogonal families of straight ribs at a fixed module, laid over any slab
outline and clipped to it and to its holes. This is the waffle form grid at an
angle: the slab boundary cuts the edge modules, and those cut bays carry their
load by their own isotropic skeleton.

# Fields
- `angle::Float64`: direction of family 1, radians from the slab-local x axis.
  Family 2 runs at `angle + π/2`.
- `spacing::NTuple{2, Float64}`: center-to-center rib spacing of family 1 and
  family 2, metres.
- `origin::Union{Nothing, NTuple{2, Float64}}`: a plan point, metres, that one
  rib of each family passes through. `nothing` centers each family on the slab
  so its two end gaps are equal and in `(s/2, s]`.

Both families are regularly spaced and orthogonal, which is the layout ACI
318-11 §8.13.1 (corpus: aci-318-11, page 120) describes as joist construction.
A modular level is analyzed as a grillage.
"""
struct ModularRibPattern <: StructuralSizer.AbstractJoistPattern
    angle::Float64
    spacing::NTuple{2, Float64}
    origin::Union{Nothing, NTuple{2, Float64}}

    function ModularRibPattern(angle::Real, spacing, origin = nothing)
        s = (Float64(spacing[1]), Float64(spacing[2]))
        (s[1] > 0 && s[2] > 0 && all(isfinite, s)) || throw(ArgumentError(
            "rib spacing must be positive and finite, got $s"))
        isfinite(angle) || throw(ArgumentError("rib angle must be finite, got $angle"))
        o = origin === nothing ? nothing : (Float64(origin[1]), Float64(origin[2]))
        return new(Float64(angle), s, o)
    end
end

"""Plan area of one full module, m²."""
module_area(p::ModularRibPattern) = p.spacing[1] * p.spacing[2]

"""
    RadialPattern{T} <: AbstractJoistPattern

Joists radiating from a center point at a constant angular pitch (radial ribs of
a circular / dome slab).

# Fields
- `center::NTuple{2, Float64}`: origin of the radial fan in slab-local 2D coords.
- `angular_spacing::T`: angular pitch between adjacent joists (radians).
- `n::Int`: number of radial joists.
"""
struct RadialPattern{T} <: StructuralSizer.AbstractJoistPattern
    center::NTuple{2, Float64}
    angular_spacing::T
    n::Int
end

"""
    CustomPattern{F} <: AbstractJoistPattern

Escape hatch for arbitrary joist layouts. Wraps a user callable that, given the
slab, produces joist polylines directly.

# Fields
- `generator::F`: a callable `slab -> Vector{Vector{NTuple{2, Float64}}}` — one
  inner vector of slab-local 2D points per joist polyline.
- `sagitta`: tolerance, in the same length unit as the polyline. `0` keeps the
  chord through the ends. A positive value cuts the polyline with
  [`curved_rib_polyline`](@ref) and materializes that finite chain.

Parameterized on the callable type `F` so any function/closure is stored without
boxing (no `::Function` field indirection).
"""
struct CustomPattern{F} <: StructuralSizer.AbstractJoistPattern
    generator::F
    sagitta::Float64
end

CustomPattern(generator) = CustomPattern{typeof(generator)}(generator, 0.0)
CustomPattern(generator, sagitta::Real) = CustomPattern{typeof(generator)}(generator, Float64(sagitta))

# -----------------------------------------------------------------------------
# FramingLevel
# -----------------------------------------------------------------------------

"""
    FramingLevel{T}

One generated framing level attached to a slab (level `1, 2, …`; level 0 is the
primary skeleton and has no `FramingLevel`). Pairs a geometric
[`AbstractJoistPattern`](@ref) with the member metadata Phase 5's
`materialize_level!` needs to create real `Beam{T}`s.

The type parameter `T` matches the owning `Slab{T}`'s length unit so
`Slab.framing_levels::Vector{FramingLevel{T}}` is concretely typed; the pattern
and material are stored as their abstract types (mirroring how `Beam`/`MemberBase`
store `section::Union{AbstractSection, Nothing}` non-parametrically).

# Fields
- `slab_idx::Int`: index of the owning slab in `BuildingStructure.slabs`.
- `level::Int`: framing-hierarchy level (`1, 2, …`).
- `pattern::AbstractJoistPattern`: joist layout for this level.
- `role::Symbol` (= `:joist`): member role — `:joist` (supports the slab) or
  `:beam` (secondary beam that carries a further level).
- `material::AbstractMaterial`: member material (required).
- `end_fixity::NTuple{2, Symbol}` (= `(:default, :default)`): per-end release
  override; `:default` defers to the `(role, material, lateral_role)` dispatch
  (`StructuralSizer.default_release`).
- `torsion_released::Union{Nothing, Bool}` (= `nothing`): whole-member torsion
  selector; `nothing` defers to `StructuralSizer.default_torsion_released`. See
  the [`Beam`](@ref) docstring for the naming caveat.
- `group_id::Union{UInt64, Nothing}` (= `nothing`): optimization group hash,
  assigned at materialization.
- `supports::Vector{Int}` (= `Int[]`): indices of the host members this level
  lands on; populated by Phase 5's `materialize_level!`.
- `beam_options::Union{Nothing, BeamOptions}` (= `nothing`): sizing options for
  this level's member group. `nothing` ⇒ the building-wide `params.beams`.
  Nothing is merged: the object is used whole. Set it when the level differs
  from the girders in material, composite action, catalog, depth, or deflection
  limit. A catalog goes on `custom_catalog` (steel) or the concrete catalog
  fields. `n_max_sections` applies inside this level's pass, not across levels.
  See [`size_beams!`](@ref).
- `edge_group_id::Union{UInt64, Nothing}` (= `nothing`): second member group
  holding the two outermost joists of a concrete `LinearAxisPattern` level. Their
  T-beam flange is cut short by the edge of the bay, so they are sized on their
  own rather than setting the flange of every rib. `nothing` when the level has
  one group. Read the level's members with [`level_member_indices`](@ref).
- `analysis::Symbol` (= `:tributary`): who carries this level's panel load.
  `:tributary` is the uniform joist strip. `:grillage` is the rib frame: every
  bay enclosed by the ribs and the slab boundary puts its isotropic skeleton on
  the ribs around it ([`rib_analysis`](@ref)). A [`ModularRibPattern`](@ref)
  level must be `:grillage`. Any other symbol is an error.
- `solid_group_id::Union{UInt64, Nothing}` (= `nothing`): members cut out of
  the ribs and the perimeter girders where a solid head starts. They are not
  catalog-sized with the joists. [`assign_solid_head_sections!`](@ref) gives
  each one the gross rectangle for stiffness and weighs only the concrete
  below the topping. `nothing` when the level has no solid head.
- `solid_heads`: the bays cast solid around each column. Empty until
  [`grow_building_solid_heads!`](@ref) resolves them. While it is empty, a
  positive `solid_head` fraction is those corner bays.
- `solid_head_report`: the resolver's ratios, or `nothing` before it runs.
"""
@kwdef mutable struct FramingLevel{T}
    slab_idx::Int
    level::Int
    pattern::StructuralSizer.AbstractJoistPattern
    role::Symbol = :joist
    material::AbstractMaterial
    end_fixity::NTuple{2, Symbol} = (:default, :default)
    torsion_released::Union{Nothing, Bool} = nothing
    group_id::Union{UInt64, Nothing} = nothing
    supports::Vector{Int} = Int[]
    beam_options::Union{Nothing, StructuralSizer.BeamOptions} = nothing
    edge_group_id::Union{UInt64, Nothing} = nothing
    analysis::Symbol = :tributary
    solid_group_id::Union{UInt64, Nothing} = nothing
    solid_heads::Vector{StructuralSizer.ColumnSolidHead} = StructuralSizer.ColumnSolidHead[]
    solid_head_report::Union{Nothing, NamedTuple} = nothing
end

"""`:tributary` or `:grillage`. Anything else is an error."""
const RIB_ANALYSES = (:tributary, :grillage)

"""
    rib_analysis(level) -> Symbol
    rib_analysis(name) -> Symbol

The panel-load owner of a framing level. `name` is a `Symbol` or a string.
`:tributary` keeps the uniform joist strip. `:grillage` puts each rib bay's
straight skeleton on the frame and does not also design those ribs with the story
shell.
"""
function rib_analysis(name::Symbol)
    name in RIB_ANALYSES || throw(ArgumentError(
        "unknown rib analysis :$name. A framing level uses :tributary or :grillage."))
    return name
end
rib_analysis(name::AbstractString) = rib_analysis(Symbol(lowercase(strip(name))))
rib_analysis(fl::FramingLevel) = rib_analysis(fl.analysis)

"""Member-group ids of a materialized framing level (empty when unmaterialized)."""
level_group_ids(fl::FramingLevel) =
    UInt64[g for g in (fl.group_id, fl.edge_group_id, fl.solid_group_id) if g !== nothing]

"""Groups the beam catalog sizes. The solid-head group is claimed, not sized."""
level_sizing_group_ids(fl::FramingLevel) =
    UInt64[g for g in (fl.group_id, fl.edge_group_id) if g !== nothing]

"""
    level_member_indices(struc, fl) -> Vector{Int}

Indices into `struc.beams` of every member of framing level `fl`, across its
interior, edge, and solid-head groups, in ascending order.

Read from each beam's `group_id`. `struc.member_groups` only holds the member
type last passed to `build_member_groups!`, so after column sizing it no longer
contains these beam groups.
"""
function level_member_indices(struc, fl::FramingLevel)
    gids = Set(level_group_ids(fl))
    isempty(gids) && return Int[]
    return sort!(Int[i for (i, b) in enumerate(struc.beams) if group_id(b) in gids])
end

# -----------------------------------------------------------------------------
# joist_geometry trait overrides — DERIVED from data-bearing objects
# -----------------------------------------------------------------------------
#
# ARCHITECTURE: these extend `StructuralSizer.joist_geometry` (whose default
# `joist_geometry(::AbstractFloorSystem, ::Int) = nothing` lives in
# `StructuralSizer/src/slabs/types.jl`). Unlike the removed singleton-marker
# overrides — which returned HARDCODED placeholder patterns
# (`IsoparametricPattern(1, 1)`, `LinearAxisPattern{Float64}((1.0, 0.0), …)`)
# because a bare `Waffle()` / `MassTimberJoist()` / `JoistRoofDeck()` singleton
# carries no geometry — these dispatch on objects that DO carry the geometry
# (`WaffleRibGrid`, the joist sizing results), so the returned pattern's numbers
# are the slab's real values.
#
# The concrete pattern types constructed here (`IsoparametricPattern`,
# `LinearAxisPattern`) are Synthesizer-owned, so — unlike the Sizer-owned
# `WaffleRibGrid` / result types they read from — every overload that BUILDS a
# pattern MUST live here, on the Synthesizer side of the
# `StructuralSynthesizer → StructuralSizer` dependency edge (the Sizer cannot
# name a Synthesizer type). The `Slab`-based entry point that routes to these
# lives in `framing_api.jl` (it needs `Slab`, defined after this file loads).

"""
    joist_geometry(grid::StructuralSizer.WaffleRibGrid, level_idx::Int)

Waffle rib grid → two-family [`IsoparametricPattern`](@ref) at level 1
(monolithic RC waffle). The rib-module counts are read verbatim from the grid's
`nξ` / `nη` fields (`StructuralSizer/src/slabs/codes/concrete/waffle/types.jl`,
`WaffleRibGrid`); levels ≥ 2 own no pattern (`nothing`).
"""
StructuralSizer.joist_geometry(grid::StructuralSizer.WaffleRibGrid, level_idx::Int) =
    level_idx == 1 ? IsoparametricPattern(grid.nξ, grid.nη, grid.solid_head) : nothing

"""
    joist_geometry(result::StructuralSizer.TimberJoistResult, spans::SpanInfo, level_idx::Int)

Mass-timber joist sizing result → one-way [`LinearAxisPattern`](@ref) at level 1.
Joists run along the slab's real span axis (`spans.axis`) at the sized
center-to-center `result.joist_spacing` (`StructuralSizer/src/slabs/types.jl`,
`TimberJoistResult`); `count` is left `nothing` — derived from the slab extent
and spacing at materialization. Levels ≥ 2: `nothing`.
"""
StructuralSizer.joist_geometry(result::StructuralSizer.TimberJoistResult,
                               spans::SpanInfo, level_idx::Int) =
    level_idx == 1 ?
        LinearAxisPattern{typeof(result.joist_spacing)}(
            spans.axis, result.joist_spacing, nothing) :
        nothing

"""
    joist_geometry(result::StructuralSizer.JoistDeckResult, spans::SpanInfo, level_idx::Int)

Open-web steel joist + deck sizing result → one-way [`LinearAxisPattern`](@ref)
at level 1, identical treatment to the mass-timber joist field: joists along
`spans.axis` at the sized `result.joist_spacing`
(`StructuralSizer/src/slabs/types.jl`, `JoistDeckResult`), `count` deferred.
Levels ≥ 2: `nothing`.
"""
StructuralSizer.joist_geometry(result::StructuralSizer.JoistDeckResult,
                               spans::SpanInfo, level_idx::Int) =
    level_idx == 1 ?
        LinearAxisPattern{typeof(result.joist_spacing)}(
            spans.axis, result.joist_spacing, nothing) :
        nothing

"""
    _waffle_rib_grid(result::StructuralSizer.AbstractFloorResult) -> Union{Nothing, StructuralSizer.WaffleRibGrid}

Extract the `WaffleRibGrid` a waffle slab's sizing result carries, or `nothing`
when the result stores none. Waffle sizing currently returns a `CIPSlabResult`
with no rib grid (see `_size_span_floor(::Waffle, …)` in
`StructuralSizer/src/slabs/codes/concrete/sizing.jl`), so this returns `nothing`
until a rib-grid-bearing waffle result exists. Kept as a single extension point
so the Phase-5 seam lands in exactly one place.
"""
_waffle_rib_grid(result::StructuralSizer.AbstractFloorResult) =
    hasproperty(result, :rib_grid) ? getproperty(result, :rib_grid) : nothing
