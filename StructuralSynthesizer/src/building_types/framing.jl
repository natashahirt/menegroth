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

Mirrors `StructuralSizer.WaffleRibGrid` (`nξ`, `nη`); Phase 5 fills these from
the panel's actual rib grid.
"""
struct IsoparametricPattern <: StructuralSizer.AbstractJoistPattern
    n_xi::Int
    n_eta::Int
end

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

Parameterized on the callable type `F` so any function/closure is stored without
boxing (no `::Function` field indirection).
"""
struct CustomPattern{F} <: StructuralSizer.AbstractJoistPattern
    generator::F
end

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
- `catalog_override::Any` (= `nothing`): per-level section catalog override
  (Phase 6); `nothing` ⇒ the material's standard catalog.
- `supports::Vector{Int}` (= `Int[]`): indices of the host members this level
  lands on; populated by Phase 5's `materialize_level!`.
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
    catalog_override::Any = nothing
    supports::Vector{Int} = Int[]
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
    level_idx == 1 ? IsoparametricPattern(grid.nξ, grid.nη) : nothing

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
