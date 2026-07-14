# =============================================================================
# Member connection defaults by (role, material, lateral_role)  — Phase 3
# =============================================================================
#
# Central multi-dispatch surface for the per-member connection idealizations the
# synthesizer's release resolver (`StructuralSynthesizer` `resolve_release`)
# needs before building the Asap model. Three entry points:
#
#   default_release(role, mat, lateral_role=:gravity) -> NTuple{2, Symbol}
#       Outer end-fixity symbols (:fixed | :pinned) for the member's two ends.
#   default_torsion_released(role, mat)               -> Bool
#       Whole-member torsion selector. `true` picks Asap's `:joist` element
#       release (pinned bending, RETAINED torsional GJ — the OWSJ idealization);
#       `false` gives `:freefree` when both ends are pinned. See the
#       `Beam.torsion_released` docstring for the naming caveat.
#   default_seat_eccentricity(role, mat, host_depth, member_depth)
#                                                     -> NTuple{4, Float64}
#       Asap `Element.eccentricity` = (axial_start, axial_end, transverse_y,
#       transverse_z) in metres (`external/Asap/src/Elements/K.jl`
#       §eccentricity_transformation!, args e_f1_1, e_f1_2, e_f2, e_f3).
#
# Design (matches the idiomatic dispatch used by `min_thickness`,
# `spanning_behavior`, `_size_span_floor`):
#   * The public methods below take the runtime `role`/`lateral_role` Symbols and
#     forward to `Val`-parameterized methods so every declared combination is a
#     distinct method — `methods(default_release)` enumerates them.
#   * Per-material specializations live WITH their material module
#     (`materials/steel.jl`, `materials/concrete.jl`, `materials/timber.jl`).
#   * The `AbstractMaterial` fallback errors explicitly on an undeclared
#     (role, material, lateral_role) combination rather than guessing.
#
# Every mapping is a connection idealization tied to engineering practice; the
# rationale (and its code citation, where a code governs) is stated at each
# specialization in the material modules.

# -----------------------------------------------------------------------------
# default_release
# -----------------------------------------------------------------------------

"""
    default_release(role::Symbol, mat::AbstractMaterial, lateral_role::Symbol=:gravity) -> NTuple{2, Symbol}

Default outer end-fixity symbols `(start, end)`, each `:fixed` or `:pinned`, for a
member of framing `role` (`:girder | :joist | :beam`), `mat`erial, and
`lateral_role` (`:gravity | :moment_frame | …`). Consumed by
`StructuralSynthesizer`'s `resolve_release` when a `Segment`'s release symbol is
`:default`.

Specializations are declared per material in `materials/{steel,concrete,timber}.jl`.
An undeclared `(role, material, lateral_role)` combination errors — this function
never guesses a connection idealization.
"""
default_release(role::Symbol, mat::AbstractMaterial, lateral_role::Symbol = :gravity) =
    default_release(Val(role), mat, Val(lateral_role))

# Compatibility: no beam material specified. `_build_edge_release_map` passes the
# building steel, which is `nothing` when the caller left `materials.steel`
# unset; the pre-Phase-3 placeholder returned fully-fixed ends in that case.
# ENGINEERING JUDGMENT: keep that neutral (moment-continuous) default so a design
# assembled without an explicit beam material still resolves rather than erroring.
# Not a code requirement.
default_release(::Symbol, ::Nothing, lateral_role::Symbol = :gravity) = (:fixed, :fixed)

# AbstractMaterial fallback — undeclared combination.
function default_release(::Val{R}, mat::AbstractMaterial, ::Val{L}) where {R, L}
    error("default_release: no release default declared for " *
          "(role = :$(R), material = $(typeof(mat)), lateral_role = :$(L)). " *
          "Declare a `default_release(::Val{:$(R)}, ::<MaterialType>, ::Val{:$(L)})` " *
          "method in the material's module (materials/steel.jl / concrete.jl / timber.jl).")
end

# -----------------------------------------------------------------------------
# default_torsion_released
# -----------------------------------------------------------------------------

"""
    default_torsion_released(role::Symbol, mat::AbstractMaterial) -> Bool

Default whole-member torsion selector for a member of framing `role` and
`mat`erial. `true` selects Asap's `:joist` element release (bending pinned,
torsional `GJ` RETAINED — the open-web steel joist idealization); `false` yields
`:freefree` for a pinned–pinned member. Only consulted when both member ends
resolve to `:pinned` (see `StructuralSynthesizer`'s `_release_enum`).

Specializations are declared per material in `materials/{steel,concrete,timber}.jl`.
An undeclared `(role, material)` combination errors.
"""
default_torsion_released(role::Symbol, mat::AbstractMaterial) =
    default_torsion_released(Val(role), mat)

# Compatibility: no beam material specified (see `default_release(::Symbol, ::Nothing, …)`).
# ENGINEERING JUDGMENT: reproduce the pre-Phase-3 placeholder (`false`), so a
# pinned–pinned member with no material resolves to `:freefree`, never `:joist`.
default_torsion_released(::Symbol, ::Nothing) = false

# AbstractMaterial fallback — undeclared combination.
function default_torsion_released(::Val{R}, mat::AbstractMaterial) where {R}
    error("default_torsion_released: no torsion default declared for " *
          "(role = :$(R), material = $(typeof(mat))). " *
          "Declare a `default_torsion_released(::Val{:$(R)}, ::<MaterialType>)` " *
          "method in the material's module.")
end

# -----------------------------------------------------------------------------
# default_seat_eccentricity
# -----------------------------------------------------------------------------

"""
    default_seat_eccentricity(role, mat::AbstractMaterial, host_depth, member_depth) -> NTuple{4, Float64}

Default Asap `Element.eccentricity` = `(axial_start, axial_end, transverse_y,
transverse_z)` in metres for a member of framing `role` and `mat`erial seated on
a host of depth `host_depth` (member itself has depth `member_depth`).
`host_depth`/`member_depth` may be Unitful lengths or plain numbers (metres);
both are normalized with `to_meters`.

The canonical non-zero case is a steel joist seated on top of a girder, offset
transversely by half the sum of the two member depths so the two centroids are
rigidly linked (`external/Asap/src/Elements/K.jl` §eccentricity_transformation!).
All other declared combinations return zeros. An undeclared `(role, material)`
combination errors.
"""
default_seat_eccentricity(role::Symbol, mat::AbstractMaterial, host_depth, member_depth) =
    default_seat_eccentricity(Val(role), mat, host_depth, member_depth)

# AbstractMaterial fallback — undeclared combination.
function default_seat_eccentricity(::Val{R}, mat::AbstractMaterial, host_depth, member_depth) where {R}
    error("default_seat_eccentricity: no seat eccentricity declared for " *
          "(role = :$(R), material = $(typeof(mat))). " *
          "Declare a `default_seat_eccentricity(::Val{:$(R)}, ::<MaterialType>, host_depth, member_depth)` " *
          "method in the material's module.")
end
