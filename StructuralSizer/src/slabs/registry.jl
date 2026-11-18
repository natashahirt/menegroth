# =============================================================================
# Symbol ↔ Type Mapping
# =============================================================================

"""Registry mapping `Symbol` → singleton `AbstractFloorSystem` instance."""
const floor_type_map = Dict{Symbol, AbstractFloorSystem}(
    :one_way => OneWay(),
    :two_way => TwoWay(),
    :flat_plate => FlatPlate(),
    :flat_slab => FlatSlab(),
    :pt_banded => PTBanded(),
    :waffle => Waffle(),
    :hollow_core => HollowCore(),
    :vault => Vault(),
    :composite_deck => CompositeDeck(),
    :non_composite_deck => NonCompositeDeck(),
    :joist_roof_deck => JoistRoofDeck(),
    :clt => CLT(),
    :dlt => DLT(),
    :nlt => NLT(),
    :mass_timber_joist => MassTimberJoist(),
    :grade => Grade(),
)

"""Reverse registry mapping concrete `Type` → `Symbol`."""
const floor_symbol_map = Dict{Type, Symbol}(
    typeof(v) => k for (k, v) in pairs(floor_type_map)
)

"""Convert symbol to floor type for dispatch."""
function floor_type(s::Symbol)
    haskey(floor_type_map, s) || throw(KeyError("Unknown floor type: $s"))
    return floor_type_map[s]
end

"""Convert floor type to symbol for storage."""
function floor_symbol(t::AbstractFloorSystem)
    T = typeof(t)
    haskey(floor_symbol_map, T) || throw(KeyError("Unknown floor type: $T"))
    return floor_symbol_map[T]
end

"""
    infer_floor_type(span_x, span_y; axis=nothing) -> Symbol

One-way or two-way from the two spans.

ACI 318-19 R8.3.1.2 (corpus: aci-318-19, PDF p. 103): a panel whose
long-to-short span is greater than 2 uses the one-way rules. At 2 or
below, the panel is two-way. A supplied `axis` forces one-way; two-way
is the automatic result, not a second flag. The span along that axis is
the caller's responsibility (`SpanInfo` with the same axis).
"""
function infer_floor_type(span_x, span_y; axis=nothing)
    axis !== nothing && return :one_way
    short = min(span_x, span_y)
    short > zero(short) || throw(ArgumentError(
        "A panel span must be positive to classify one-way or two-way."))
    return max(span_x, span_y) / short > 2.0 ? :one_way : :two_way
end
