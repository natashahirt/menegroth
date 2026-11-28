# Floor system type hierarchy and result types

# =============================================================================
# Abstract Hierarchy
# =============================================================================

"""
    AbstractFloorSystem

Top-level abstract type for all floor / slab systems.

Every concrete subtype must implement at least `spanning_behavior` and
`required_materials`.  The spanning trait drives tributary area computation,
load distribution, and design-code dispatch.

# Subtypes
- `AbstractConcreteSlab` — cast-in-place and precast concrete
- `AbstractSteelFloor`   — metal deck systems
- `AbstractTimberFloor`  — mass-timber and joist systems
"""
abstract type AbstractFloorSystem end

# =============================================================================
# Spanning Behavior Traits
# =============================================================================

"""
Spanning behavior trait - determines how a floor system transfers load.

This is an intrinsic property of the floor type and cannot be overridden
by user options. It determines:
- Load distribution pattern (to edges vs columns)
- Which design code provisions apply  
- Default tributary area computation method

## Subtypes
- `OneWaySpanning`: Loads span primarily in one direction to edges
- `TwoWaySpanning`: Loads distribute to all edges (two-way action)
- `BeamlessSpanning`: Loads transfer directly to columns (no beams)
"""
abstract type SpanningBehavior end

"""One-way spanning: loads distributed to edges perpendicular to span direction."""
struct OneWaySpanning <: SpanningBehavior end

"""Two-way spanning: loads distributed to all edges (isotropic behavior)."""
struct TwoWaySpanning <: SpanningBehavior end

"""Beamless: loads transfer directly to columns (flat plate, flat slab)."""
struct BeamlessSpanning <: SpanningBehavior end

"""
    AbstractConcreteSlab <: AbstractFloorSystem

Abstract type for all concrete floor systems (cast-in-place and precast).
"""
abstract type AbstractConcreteSlab <: AbstractFloorSystem end

"""One-way reinforced concrete slab (ACI 318 Table 7.3.1.1)."""
struct OneWay <: AbstractConcreteSlab end

"""Two-way reinforced concrete slab (ACI 318 §8.3)."""
struct TwoWay <: AbstractConcreteSlab end

"""Flat plate — two-way beamless slab supported directly on columns (ACI 318 §8.2.4)."""
struct FlatPlate <: AbstractConcreteSlab end

"""Flat slab — flat plate with drop panels at columns (ACI 318 §8.2.4)."""
struct FlatSlab <: AbstractConcreteSlab end

"""Post-tensioned banded slab (two-way PT with banded tendons)."""
struct PTBanded <: AbstractConcreteSlab end

"""Waffle slab — two-way joist system with ribbed soffit (ACI 318 §9.8)."""
struct Waffle <: AbstractConcreteSlab end

"""Slab on grade (ground floor, not elevated)."""
struct Grade <: AbstractConcreteSlab end

"""Precast hollow-core plank (PCI standard profiles)."""
struct HollowCore <: AbstractConcreteSlab end

"""Unreinforced concrete vault — parabolic shell transferring load by compression."""
struct Vault <: AbstractConcreteSlab end

"""
    AbstractSteelFloor <: AbstractFloorSystem

Abstract type for steel floor/roof deck systems.
"""
abstract type AbstractSteelFloor <: AbstractFloorSystem end

"""Composite metal deck with concrete fill (one-way spanning)."""
struct CompositeDeck <: AbstractSteelFloor end

"""Non-composite metal deck without concrete fill (one-way spanning)."""
struct NonCompositeDeck <: AbstractSteelFloor end

"""Open-web steel joist with roof deck (one-way spanning)."""
struct JoistRoofDeck <: AbstractSteelFloor end

"""
    AbstractTimberFloor <: AbstractFloorSystem

Abstract type for mass-timber and timber-joist floor systems.
"""
abstract type AbstractTimberFloor <: AbstractFloorSystem end

"""Cross-laminated timber panel (CLT, one-way spanning)."""
struct CLT <: AbstractTimberFloor end

"""Dowel-laminated timber panel (DLT, one-way spanning)."""
struct DLT <: AbstractTimberFloor end

"""Nail-laminated timber panel (NLT, one-way spanning)."""
struct NLT <: AbstractTimberFloor end

"""Mass-timber joist floor (glulam or LVL joists with sheathing)."""
struct MassTimberJoist <: AbstractTimberFloor end

"""
    ShapedSlab <: AbstractConcreteSlab

User-defined slab geometry with a custom sizing function.

# Fields
- `sizing_fn::Function`: `(span_x, span_y, load, material) → ShapedSlabResult`
"""
struct ShapedSlab <: AbstractConcreteSlab
    sizing_fn::Function
end

# =============================================================================
# Spanning Behavior Trait Implementations
# =============================================================================

"""
    spanning_behavior(ft::AbstractFloorSystem) -> SpanningBehavior

Return the spanning behavior trait for a floor type.
This is intrinsic to the floor type and cannot be overridden by options.
"""
spanning_behavior(::AbstractFloorSystem) = OneWaySpanning()  # Conservative default

# --- One-way spanning ---
spanning_behavior(::OneWay) = OneWaySpanning()
spanning_behavior(::CompositeDeck) = OneWaySpanning()
spanning_behavior(::NonCompositeDeck) = OneWaySpanning()
spanning_behavior(::JoistRoofDeck) = OneWaySpanning()
spanning_behavior(::HollowCore) = OneWaySpanning()
spanning_behavior(::CLT) = OneWaySpanning()
spanning_behavior(::DLT) = OneWaySpanning()
spanning_behavior(::NLT) = OneWaySpanning()
spanning_behavior(::MassTimberJoist) = OneWaySpanning()
spanning_behavior(::Vault) = OneWaySpanning()

# --- Two-way spanning ---
spanning_behavior(::TwoWay) = TwoWaySpanning()
spanning_behavior(::Waffle) = TwoWaySpanning()
spanning_behavior(::PTBanded) = TwoWaySpanning()

# --- Beamless (columns only) ---
spanning_behavior(::FlatPlate) = BeamlessSpanning()
spanning_behavior(::FlatSlab) = BeamlessSpanning()

# --- Shaped follows inner function ---
spanning_behavior(::ShapedSlab) = TwoWaySpanning()  # Most shaped slabs are 2-way

# Convenience query functions
"""Is this floor type one-way spanning?"""
is_one_way(ft::AbstractFloorSystem) = spanning_behavior(ft) isa OneWaySpanning

"""Is this floor type two-way spanning (to edges)?"""
is_two_way(ft::AbstractFloorSystem) = spanning_behavior(ft) isa TwoWaySpanning

"""Is this floor type beamless (loads to columns)?"""
is_beamless(ft::AbstractFloorSystem) = spanning_behavior(ft) isa BeamlessSpanning

"""Does this floor type require column tributary areas (Voronoi)?"""
requires_column_tributaries(ft::AbstractFloorSystem) = is_beamless(ft)

# =============================================================================
# Support Conditions
# =============================================================================

"""
    SupportCondition

End-support condition for one-way/two-way slab span sizing.
Controls minimum thickness coefficients per ACI 318 Table 7.3.1.1.

# Values
- `SIMPLE` — simply supported
- `ONE_END_CONT` — one end continuous
- `BOTH_ENDS_CONT` — both ends continuous
- `CANTILEVER` — cantilever
"""
@enum SupportCondition begin
    SIMPLE
    ONE_END_CONT
    BOTH_ENDS_CONT
    CANTILEVER
end

# =============================================================================
# Material Requirements
# =============================================================================

"""Material symbols required by a floor type (used for EC and cost calculations)."""
required_materials(::AbstractConcreteSlab) = (:concrete,)
required_materials(::CompositeDeck) = (:steel, :concrete)
required_materials(::NonCompositeDeck) = (:steel,)
required_materials(::JoistRoofDeck) = (:steel,)
required_materials(::AbstractTimberFloor) = (:timber,)
required_materials(::ShapedSlab) = ()  # user-defined

# =============================================================================
# Joist Pattern Abstraction + Trait (Phase 4)
# =============================================================================
#
# `AbstractJoistPattern` is declared HERE (in the Sizer) rather than in the
# Synthesizer so the `joist_geometry` trait below — which is dispatched on the
# Sizer-owned `AbstractFloorSystem` types — can name it in its return type.
# StructuralSynthesizer depends on StructuralSizer (not the reverse), so the
# concrete pattern subtypes (`LinearAxisPattern`, `IsoparametricPattern`, …) and
# the floor-type overrides of `joist_geometry` that construct them live in the
# Synthesizer (`StructuralSynthesizer/src/building_types/framing.jl`), where
# auto-generation (Phase 5) happens. The Sizer only owns the abstract type and
# the `nothing` default.

"""
    AbstractJoistPattern

Abstract base for the joist-layout patterns used by the framing-hierarchy
levels (`FramingLevel`). Concrete subtypes (`LinearAxisPattern`,
`IsoparametricPattern`, `RadialPattern`, `CustomPattern`) are defined in
`StructuralSynthesizer`; the abstract type lives here so the [`joist_geometry`](@ref)
trait — dispatched on `AbstractFloorSystem` — can reference it.
"""
abstract type AbstractJoistPattern end

"""
    joist_geometry(slab::AbstractFloorSystem, level_idx::Int) -> Union{Nothing, AbstractJoistPattern}

Framing-hierarchy trait: the joist pattern that floor type `slab` intrinsically
generates at framing level `level_idx` (`1` = first generated level above the
skeleton). Returns `nothing` when the floor type does not own a pattern at that
level, decoupling Phase 5's `derive_framing_level` from slab internals.

The default returns `nothing` for every floor type and level; slab-owned joist
systems (`Waffle`, `MassTimberJoist`, `JoistRoofDeck`) override it in
`StructuralSynthesizer` (where the concrete pattern types are defined). The
overrides return a pattern whose numeric geometry is a placeholder — the real
divisions/spacing are resolved from slab geometry during Phase 5.
"""
joist_geometry(::AbstractFloorSystem, ::Int) = nothing

