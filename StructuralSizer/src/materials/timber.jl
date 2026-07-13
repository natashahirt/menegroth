# =============================================================================
# Timber Material Presets
# =============================================================================
#
# ECC values from ICE Database v4.1 (Oct 2025) [kgCO₂e/kg]
# Source: data/ICE DB Educational V4.1 - Oct 2025.xlsx
#
# Timber, general: 0.31
# Timber, glulam:  0.42
# Timber, CLT:     0.44
#
# Reference design values from NDS Supplement (Table 4A, 4B, etc.)
# These are adjusted by CD, CM, Ct, etc. in actual design.
#
# =============================================================================

# TODO: Add timber presets as needed
# Example:
# const Douglas_Fir_No1 = Timber(
#     :douglas_fir,
#     :no1,
#     12.4e9,      # E [Pa] (1.8e6 psi)
#     ...
# )

# =============================================================================
# (role, material, lateral_role) connection defaults for timber
# =============================================================================
# Entry points and fallbacks are declared in `members/defaults.jl`; these are the
# per-combination specializations for `Timber`.
#
# ENGINEERING JUDGMENT (NDS not in the corpus — no clause citation available):
# engineered-wood and sawn-lumber joists bear on their supports through simple
# bearing / joist-hanger connections that transmit shear only, so both ends are
# pinned and the connection provides no torsional restraint (`torsion_released =
# false` => the release resolver returns `:freefree`, all rotations released).
# Timber girders (glulam / heavy-timber primary members) are modeled with
# moment-continuous (fixed) ends by default; a designer overrides via the
# `Segment` release symbols for a genuinely pinned girder. These reflect common
# NDS-practice connection idealizations; they are not read from a code clause.

default_release(::Val{:joist}, ::Timber, ::Val{:gravity}) = (:pinned, :pinned)
default_release(::Val{:girder}, ::Timber, ::Val{:gravity}) = (:fixed, :fixed)

default_torsion_released(::Val{:joist}, ::Timber) = false
default_torsion_released(::Val{:girder}, ::Timber) = false

default_seat_eccentricity(::Val{:joist}, ::Timber, host_depth, member_depth) = (0.0, 0.0, 0.0, 0.0)
default_seat_eccentricity(::Val{:girder}, ::Timber, host_depth, member_depth) = (0.0, 0.0, 0.0, 0.0)
