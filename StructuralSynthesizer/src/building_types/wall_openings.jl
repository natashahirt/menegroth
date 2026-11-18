# =============================================================================
# Wall openings
# =============================================================================
# A rectangular hole in one straight wall. Coordinates are the wall's own:
# `s` runs along the plan line, `z` runs up from the story base. The skeleton
# stores one spec per story, keyed by the wall's endpoint vertices, because
# `initialize_members!` rebuilds `Wall` from those edges.

"""
    WallOpening(s0, z0, width, height, kind)

One rectangular opening, in metres.

`s0` is the distance along the wall from its start. `z0` is the height of the
sill above the story base. `kind` is `:window`, `:door`, or `:other`.

The opening is geometry only. It does not select reinforcement.
"""
struct WallOpening
    s0::Float64
    z0::Float64
    width::Float64
    height::Float64
    kind::Symbol
    function WallOpening(s0::Real, z0::Real, width::Real, height::Real, kind::Symbol)
        kind in (:window, :door, :other) || throw(ArgumentError(
            "WallOpening kind must be :window, :door, or :other, got :$kind."))
        new(Float64(s0), Float64(z0), Float64(width), Float64(height), kind)
    end
end

"""
    WallOpeningSpec(v1, v2, story, opening)

An opening on the skeleton wall whose plan endpoints are vertices `v1` and
`v2`, on 0-based `story`.

`opening.s0` is measured from `v1` toward `v2`. A wall built in the opposite
direction mirrors `s0` when the opening is copied onto it.
"""
struct WallOpeningSpec
    v1::Int
    v2::Int
    story::Int
    opening::WallOpening
end
