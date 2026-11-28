# ==============================================================================
# Transmission of Column Loads Through the Floor System
# ==============================================================================

"""
    joint_concrete_strength(fc_col, fc_floor; restrained_four_sides) -> Union{Nothing, Pressure}

Concrete strength for the strength of a column through a floor system, ACI
318-11 §10.12 (aci-318-11, p. 158). `nothing` when `fc_col ≤ 1.4·fc_floor`,
where no provision is needed.

- `restrained_four_sides = true`: §10.12.3,
  `0.75·fc_col + 0.35·fc_floor`, with `fc_col / fc_floor` taken no greater
  than 2.5.
- Otherwise (edge and corner columns): §10.12.2, the lower strength,
  `fc_floor`. The vertical dowels and spirals that clause also allows are not
  modeled; only the column's own bars are counted.

The §10.12.1 alternative, column concrete placed in the floor around the
column, is not used.
"""
function joint_concrete_strength(fc_col, fc_floor; restrained_four_sides::Bool)
    fc_col <= 1.4 * fc_floor && return nothing
    restrained_four_sides || return fc_floor
    return 0.75 * min(fc_col, 2.5 * fc_floor) + 0.35 * fc_floor
end

"""
    with_compressive_strength(c::Concrete, fc′) -> Concrete

`c` with its compressive strength replaced by `fc′`. Every other property,
including `E` and `εcu`, is kept. For a section strength check at a
different concrete strength, such as [`joint_concrete_strength`](@ref).
"""
with_compressive_strength(c::Concrete, fc′) =
    Concrete(c.E, fc′, c.ρ, c.ν, c.ecc; εcu = c.εcu, cost = c.cost, λ = c.λ,
             aggregate_type = c.aggregate_type, color = c.color)
