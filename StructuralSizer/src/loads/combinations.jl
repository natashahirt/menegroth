# =============================================================================
# Load Combinations
# =============================================================================
# Configurable load combinations for structural design.
# Configurable load factors for structural design (ASCE 7-22).
#
# Standard combinations follow ASCE 7-22 strength design.
# =============================================================================

"""
    LoadCombination(; name, D, L, S, W, E)

A load combination for structural design.

# Fields
- `name::Symbol`: Identifier (e.g., :strength_1_2, :service)
- `D::Float64`: Dead load factor
- `L::Float64`: Live load factor
- `Lr::Float64`: Roof live load factor (default 0)
- `S::Float64`: Snow load factor (default 0)
- `R::Float64`: Rain load factor (default 0)
- `W::Float64`: Wind load factor (default 0)
- `E::Float64`: Factor on Eh, the horizontal seismic effect (default 0)
- `Ev::Float64`: Factor on the vertical seismic effect. +1 adds it, −1 subtracts it (default 0)

# Standard Combinations (ASCE 7-22 §2.3.1 and §2.3.6)
- `strength_1_4D`: 1.4D
- `strength_1_2D_1_6L`: 1.2D + 1.6L + (0.5Lr or 0.3S or 0.5R)
- `strength_1_2D_1_0W`: 1.2D + 1.0W + L + (0.5Lr or 0.3S or 0.5R)
- `strength_1_2D_1_0E`: 1.2D + Ev + Eh + L + 0.15S
- `strength_0_9D_1_0W`: 0.9D + 1.0W
- `strength_0_9D_1_0E`: 0.9D − Ev + Eh
- `ASD`: 1.0D + 1.0L (Allowable Stress Design)
- `service`: 1.0D + 1.0L (Serviceability checks)

# Examples
```julia
# Use a standard combination
combo = strength_1_2D_1_6L
p_factored = factored_pressure(combo, dead_load, live_load)

# Custom combination
custom = LoadCombination(name=:custom, D=1.35, L=1.5)  # Eurocode-ish
```
"""
Base.@kwdef struct LoadCombination
    name::Symbol = :strength
    D::Float64 = 1.2
    L::Float64 = 1.6
    Lr::Float64 = 0.0   # Roof live load
    S::Float64 = 0.0    # Snow
    R::Float64 = 0.0    # Rain
    W::Float64 = 0.0    # Wind
    "Factor on Eh, the horizontal seismic effect. ASCE 7-22 Eq. 12.4-3."
    E::Float64 = 0.0
    "Factor on Ev, the vertical seismic effect. +1 adds Ev, −1 subtracts it."
    Ev::Float64 = 0.0
end

# =============================================================================
# Standard Combinations (ASCE 7-22 §2.3.1)
# =============================================================================

"""ASCE 7-22 §2.3.1 Combination 1: 1.4D."""
const strength_1_4D = LoadCombination(
    name = :strength_1_4D,
    D = 1.4,
    L = 0.0
)

"""
ASCE 7-22 §2.3.1 combination 2a: 1.2D + 1.6L + (0.5Lr or 0.3S or 0.5R).

`Lr`, `S`, and `R` are alternatives (corpus: asce-7-22, PDF page 68).
[`factored_pressure`](@ref) adds every load that is passed, so pass one of them.
"""
const strength_1_2D_1_6L = LoadCombination(
    name = :strength_1_2D_1_6L,
    D = 1.2,
    L = 1.6,
    Lr = 0.5,
    S = 0.3,
    R = 0.5
)

"""
ASCE 7-22 §2.3.1 combination 3a: 1.2D + (1.6Lr or 1.0S or 1.6R) + (L or 0.5W).

The roof loads are alternatives, and so are `L` and `0.5W` (corpus:
asce-7-22, PDF page 68). Pass one from each group.
"""
const strength_1_2D_1_6Lr = LoadCombination(
    name = :strength_1_2D_1_6Lr,
    D = 1.2,
    L = 1.0,
    Lr = 1.6,
    S = 1.0,
    R = 1.6,
    W = 0.5
)

"""
ASCE 7-22 §2.3.1 combination 4a: 1.2D + 1.0W + L + (0.5Lr or 0.3S or 0.5R).

Tornado load `WT` may replace `W`. It is not a field here. The factor on `L`
is permitted to be 0.5 for some occupancies (corpus: asce-7-22, PDF page 68,
exception 1). This constant uses 1.0.
"""
const strength_1_2D_1_0W = LoadCombination(
    name = :strength_1_2D_1_0W,
    D = 1.2,
    L = 1.0,
    Lr = 0.5,
    S = 0.3,
    R = 0.5,
    W = 1.0
)

"""
ASCE 7-22 §2.3.6 combination 6: 1.2D + Ev + Eh + L + 0.15S.

`E` is the factor on Eh. `Ev` is the factor on the vertical effect, so
`+Ev` is `Ev = 1`. Ev itself is `0.2 SDS D` from Eq. 12.4-4a, computed by
[`vertical_seismic_load_effect`](@ref) and passed separately. The factor on
`L` is permitted to be 0.5 for some occupancies (corpus: asce-7-22, PDF
page 69). This constant uses 1.0. Overstrength `Emh` is not this constant.
"""
const strength_1_2D_1_0E = LoadCombination(
    name = :strength_1_2D_1_0E,
    D = 1.2,
    L = 1.0,
    S = 0.15,
    E = 1.0,
    Ev = 1.0
)

"""
ASCE 7-22 §2.3.1 Combination 5: 0.9D + 1.0W.

`L` is set to 0. The struct default is 1.6, and this combination has no
live load (corpus: asce-7-22, PDF page 68).
"""
const strength_0_9D_1_0W = LoadCombination(
    name = :strength_0_9D_1_0W,
    D = 0.9,
    L = 0.0,
    W = 1.0
)

"""
ASCE 7-22 §2.3.6 combination 7: 0.9D − Ev + Eh.

`E` is the factor on Eh. `Ev = -1` subtracts the vertical effect. Ev itself
is `0.2 SDS D` (corpus: asce-7-22, PDF page 69 and Eq. 12.4-4a, PDF page 183).
`L` is set to 0. The struct default is 1.6, and this combination has no
live load.
"""
const strength_0_9D_1_0E = LoadCombination(
    name = :strength_0_9D_1_0E,
    D = 0.9,
    L = 0.0,
    E = 1.0,
    Ev = -1.0
)

# =============================================================================
# Allowable-stress combinations for foundation soil pressure (ASCE 7-22 §2.4)
# =============================================================================
# §12.13.6 uses these when the geotechnical capacity is an allowable pressure.
# The 0.5 factor on L, the 25% overturning reduction (§12.13.4), and Ev = 0
# at the soil interface (§12.4.2.2 exception 2(b)) are permissions. They are
# not applied. §2.4.1 does not increase the allowable pressure.

"""ASCE 7-22 §2.4.1 combination 1a: D. PDF page 69."""
const asd_D = LoadCombination(name=:asd_D, D=1.0, L=0.0)

"""ASCE 7-22 §2.4.1 combination 2a: D + L. PDF page 69."""
const asd_D_L = LoadCombination(name=:asd_D_L, D=1.0, L=1.0)

"""
ASCE 7-22 §2.4.1 combination 3a: D + (Lr or 0.7S or R).

One roof companion is passed. PDF page 69.
"""
const asd_D_roof = LoadCombination(
    name=:asd_D_roof, D=1.0, L=0.0, Lr=1.0, S=0.7, R=1.0)

"""
ASCE 7-22 §2.4.1 combination 4a: D + 0.75L + 0.75(Lr or 0.7S or R).

PDF page 69. The snow companion factor is 0.75 × 0.7.
"""
const asd_D_075L = LoadCombination(
    name=:asd_D_075L, D=1.0, L=0.75, Lr=0.75, S=0.75 * 0.7, R=0.75)

"""ASCE 7-22 §2.4.1 combination 5a: D + 0.6W. PDF page 69."""
const asd_D_06W = LoadCombination(name=:asd_D_06W, D=1.0, L=0.0, W=0.6)

"""
ASCE 7-22 §2.4.1 combination 6a:
D + 0.75L + 0.75(0.6W) + 0.75(Lr or 0.7S or R).

The wind factor is 0.75 × 0.6 = 0.45. PDF page 69.
"""
const asd_D_075L_W = LoadCombination(
    name=:asd_D_075L_W, D=1.0, L=0.75, Lr=0.75, S=0.75 * 0.7, R=0.75, W=0.45)

"""ASCE 7-22 §2.4.1 combination 7a: 0.6D + 0.6W. PDF page 69."""
const asd_06D_06W = LoadCombination(name=:asd_06D_06W, D=0.6, L=0.0, W=0.6)

"""
ASCE 7-22 §2.4.5 combination 8: 1.0D + 0.7Ev + 0.7Eh.

`E` multiplies Eh. `Ev` multiplies the vertical effect 0.2 SDS D.
PDF page 70.
"""
const asd_D_E = LoadCombination(name=:asd_D_E, D=1.0, L=0.0, E=0.7, Ev=0.7)

"""
ASCE 7-22 §2.4.5 combination 9:
1.0D + 0.525Ev + 0.525Eh + 0.75L + 0.1S.

The 0.1 factor is on snow, not on roof live or rain. PDF page 70.
"""
const asd_D_E_L = LoadCombination(
    name=:asd_D_E_L, D=1.0, L=0.75, S=0.1, E=0.525, Ev=0.525)

"""
ASCE 7-22 §2.4.5 combination 10: 0.6D − 0.7Ev + 0.7Eh.

`Ev = -0.7` subtracts the vertical effect. PDF page 70.
"""
const asd_06D_E = LoadCombination(
    name=:asd_06D_E, D=0.6, L=0.0, E=0.7, Ev=-0.7)

"""Allowable Stress Design: 1.0D + 1.0L."""
const ASD = LoadCombination(
    name = :asd,
    D = 1.0,
    L = 1.0
)

"""Serviceability combination: 1.0D + 1.0L (unfactored, for deflection checks)."""
const service = LoadCombination(
    name = :service,
    D = 1.0,
    L = 1.0
)

"""Alias for the most common strength combination (1.2D + 1.6L)."""
const default_combo = strength_1_2D_1_6L

# =============================================================================
# Factored Pressure Functions
# =============================================================================

"""
    factored_pressure(combo::LoadCombination, dead, live)

Apply load combination factors to dead and live loads.
Returns `combo.D * dead + combo.L * live`.

# Example
```julia
p_u = factored_pressure(strength_1_2D_1_6L, 5.0u"kN/m^2", 3.0u"kN/m^2")
# → 1.2 * 5.0 + 1.6 * 3.0 = 10.8 kN/m²
```
"""
function factored_pressure(combo::LoadCombination, dead, live)
    return combo.D * dead + combo.L * live
end

"""
    factored_pressure(combo::LoadCombination; D=0, L=0, Lr=0, S=0, R=0, W=0, E=0, Ev=0)

Apply load combination with all load types.

# Example
```julia
p_u = factored_pressure(strength_1_2D_1_0W; 
    D=5.0u"kN/m^2", L=3.0u"kN/m^2", W=1.5u"kN/m^2")
# → 1.2*5.0 + 1.0*3.0 + 1.0*1.5 = 10.5 kN/m²
```
"""
function factored_pressure(combo::LoadCombination; 
    D=0.0, L=0.0, Lr=0.0, S=0.0, R=0.0, W=0.0, E=0.0, Ev=0.0
)
    # `E` is Eh. `Ev` is the vertical seismic effect from Eq. 12.4-4a.
    # Lr, S, and R are alternatives in §2.3.1. This sum includes every
    # load that is passed, so pass one companion from each "or" group.
    return (combo.D * D + combo.L * L + combo.Lr * Lr + 
            combo.S * S + combo.R * R + combo.W * W + combo.E * E +
            combo.Ev * Ev)
end

"""
    factored_load(combo::LoadCombination, dead, live)

Alias for `factored_pressure` - works for any load type (force, moment, etc.).
"""
factored_load(args...; kwargs...) = factored_pressure(args...; kwargs...)

# =============================================================================
# Envelope Functions
# =============================================================================

"""
    envelope_pressure(combos::Vector{LoadCombination}, dead, live)

Compute the maximum factored pressure across all combinations in `combos`.

For gravity-only analysis this is the correct conservative approach — all
combinations act in the same direction (downward). For lateral combinations
(wind/seismic), separate directional analysis is needed.

# Example
```julia
combos = [strength_1_4D, strength_1_2D_1_6L]
p_max = envelope_pressure(combos, 100.0u"Pa", 50.0u"Pa")
# → max(1.4×100, 1.2×100 + 1.6×50) = max(140, 200) = 200 Pa
```
"""
function envelope_pressure(combos::AbstractVector{LoadCombination}, dead::P, live::P) where P
    return maximum(factored_pressure(c, dead, live) for c in combos)
end

"""
    envelope_pressure(combos; D=0, L=0, Lr=0, S=0, R=0, W=0, E=0, Ev=0)

Full envelope with all load types.
"""
function envelope_pressure(combos::AbstractVector{LoadCombination};
    D::T=0.0, L::T=0.0, Lr::T=0.0, S::T=0.0, R::T=0.0, W::T=0.0, E::T=0.0, Ev::T=0.0
) where T
    return maximum(factored_pressure(c; D=D, L=L, Lr=Lr, S=S, R=R, W=W, E=E, Ev=Ev) for c in combos)
end

"""Single-combo convenience: treat a single `LoadCombination` as a length-1 vector."""
envelope_pressure(combo::LoadCombination, dead::P, live::P) where P =
    factored_pressure(combo, dead, live)

# =============================================================================
# Combination Sets
# =============================================================================

"""
    asce7_strength_combinations

All ASCE 7-22 strength load combinations for envelope analysis.
"""
const asce7_strength_combinations = [
    strength_1_4D,
    strength_1_2D_1_6L,
    strength_1_2D_1_6Lr,
    strength_1_2D_1_0W,
    strength_1_2D_1_0E,
    strength_0_9D_1_0W,
    strength_0_9D_1_0E
]

"""
    asce7_asd_foundation_combinations

ASCE 7-22 §2.4.1 combinations 1a–7a and §2.4.5 combinations 8–10, for
foundation soil pressure checked against an allowable pressure.

§12.13.6 (corpus: asce-7-22, PDF page 196). Flood, tornado, ice, and
overstrength are not in this list.
"""
const asce7_asd_foundation_combinations = [
    asd_D,
    asd_D_L,
    asd_D_roof,
    asd_D_075L,
    asd_D_06W,
    asd_D_075L_W,
    asd_06D_06W,
    asd_D_E,
    asd_D_E_L,
    asd_06D_E,
]

"""
    gravity_combinations

Common gravity-only combinations (no lateral).
"""
const gravity_combinations = [
    strength_1_4D,
    strength_1_2D_1_6L,
    service
]

"""
    lateral_strength_combinations() -> NTuple{4, LoadCombination}

The four existing strength constants whose lateral factor is 1.0:
[`strength_1_2D_1_0W`](@ref), [`strength_0_9D_1_0W`](@ref),
[`strength_1_2D_1_0E`](@ref), and [`strength_0_9D_1_0E`](@ref).

Wind is §2.3.1 combinations 4a and 5a: `1.2D + 1.0W + L + (0.5Lr or 0.3S
or 0.5R)` and `0.9D + 1.0W`. Earthquake is §2.3.6 combinations 6 and 7:
`1.2D + Ev + Eh + L + 0.15S` and `0.9D − Ev + Eh`. Wind and earthquake
need not act together.

The `W` and `E` fields are 1.0. `E` multiplies Eh, the horizontal story
force. `Ev` on the two seismic constants is +1 and −1, and it multiplies
the vertical effect `0.2 SDS D`, which is not part of the story shear.
Gravity factors and the 0.15 snow companion stay on the gravity load path.

# Citation
ASCE 7-22 §2.3.1 (corpus: asce-7-22, PDF page 68) and §2.3.6
(corpus: asce-7-22, PDF page 69).
"""
function lateral_strength_combinations()
    return (
        strength_1_2D_1_0W,
        strength_0_9D_1_0W,
        strength_1_2D_1_0E,
        strength_0_9D_1_0E,
    )
end

"""
    factored_lateral_components(combo, Fx, Fy, Mz; load) -> (Fx, Fy, Mz)

Scale a lateral force and its torsion by `combo.W` or `combo.E`.
`load` is `:W` or `:E`. Gravity factors are not applied.

The three inputs share one length and come back in that order, as `Float64`
vectors. A zero factor returns three empty vectors: that combination does
not include this load.
"""
function factored_lateral_components(combo::LoadCombination, Fx, Fy, Mz; load::Symbol)
    nFx = length(Fx)
    nFy = length(Fy)
    nMz = length(Mz)
    nFx == nFy == nMz || throw(ArgumentError(
        "lateral components must have the same length; got $nFx, $nFy, $nMz"))
    if load === :W
        factor = combo.W
    elseif load === :E
        factor = combo.E
    else
        throw(ArgumentError("load must be :W or :E; got $(repr(load))"))
    end
    factor == 0 && return (Float64[], Float64[], Float64[])
    return (factor .* Float64.(Fx), factor .* Float64.(Fy), factor .* Float64.(Mz))
end
