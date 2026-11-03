# Inputs for the ordinary-wall stage.
#
# Every code number is required. This struct does not look up a wind pressure,
# a seismic coefficient, or a redundancy factor, and it does not fill one in
# when the field is missing.

"""
    OrdinaryWallInputs(; directions, qz, qh, Kd, G, GCpi, roof, method, SDS, ...)

Numbers and statements the ordinary-wall stage passes through.

Wind pressures and the ELF coefficients are the caller's. `roof` is the one
gravity companion (`:Lr`, `:S`, or `:R`), the single roof pressure stored on
the building. It is not the Figure 27.3-1 roof shape: that analysis stays on
a flat roof, and a sloped roof is refused there.

`SD1` and `TL` are required by ELF method `:sds`. `Sa` is required by `:sa`.
`between` is required when `0.5 < T < 2.5`. `R`, `Cd`, and `Ω0` come from the
Table 12.2-1 row on `DesignParameters.lateral`, not from these inputs.
`extra_directions` defaults to no directions beyond the two principal axes.

`qi` is not a field. The wind analysis uses `qh` for the internal pressure.
`drift_system` is the Table 12.12-1 symbol (`:other`, `:masonry_other`), not
the lateral-system type. `rho` is applied to `Eh` by the stage.

`pdelta_included_in_member_forces` must be false. The stage's ELF solve is
linear, and the stage multiplies seismic member forces and design story
drifts by `1/(1−θ)` from ASCE 7-22 §12.8.7. A true value would count that
effect twice.

`orthogonal_combination` asks the stage to use the §12.5.1.2(a) 100% + 30%
effects. The stage also uses them, whatever this field says, when §12.5.3 or
§12.5.4 does not permit the independent procedure. `type5_horizontal_irregularity`
is the caller's statement; a wall on neither plan axis makes it true.

The other Bool fields are the caller's statements for the seismic-provision
gate. This struct does not decide them.
"""
Base.@kwdef struct OrdinaryWallInputs
    directions::NTuple{2, NTuple{2, Float64}}
    qz::Vector{Float64}
    qh::Float64
    Kd::Float64
    G::Float64
    GCpi::Float64
    roof::Symbol
    method::Symbol
    SDS::Float64
    S1::Float64
    Ie::Float64
    T::Float64
    β::Float64
    rho::Float64
    sdc::Symbol
    risk_category::Symbol
    drift_system::Symbol
    boundary::Symbol
    material::ReinforcedConcreteMaterial
    model_uses_cracked_section_stiffness::Bool
    sustained_lateral_loads::Bool
    sustained_lateral_divisor_applied::Bool
    type1_horizontal_irregularity::Bool
    type5_horizontal_irregularity::Bool
    orthogonal_combination::Bool
    orthogonal_12_5_4_conditions_absent::Bool
    ax_applied_to_accidental_torsion::Bool
    pdelta_included_in_member_forces::Bool
    SD1::Union{Float64, Nothing} = nothing
    TL::Union{Float64, Nothing} = nothing
    Sa::Union{Float64, Nothing} = nothing
    between::Union{Symbol, Nothing} = nothing
    extra_directions::Vector{NTuple{2, Float64}} = NTuple{2, Float64}[]
end
