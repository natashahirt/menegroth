# ECC values from ICE Database v4.1 (Oct 2025) [kgCO₂e/kg]
# Source: data/ICE DB Educational V4.1 - Oct 2025.xlsx
#
# Steel, section: 1.61
# Steel, rebar: 1.72

"""ASTM A992 structural steel (Fy = 50 ksi, Fu = 65 ksi, ECC = 1.61 kgCO₂e/kg)."""
const A992_Steel = StructuralSteel(
    29000.0ksi,      # E
    11200.0ksi,      # G
    50.0ksi,         # Fy
    65.0ksi,         # Fu
    490.0u"lb/ft^3",    # ρ
    0.29,               # ν
    1.61u"kgCO2e/kg";   # ecc
    color = "#6E6E6E"
)

"""EN S355 structural steel (Fy = 355 MPa, Fu = 510 MPa, ECC = 1.61 kgCO₂e/kg)."""
const S355_Steel = StructuralSteel(
    210.0u"GPa",        # E
    80.7u"GPa",         # G
    355.0u"MPa",        # Fy
    510.0u"MPa",        # Fu
    7850.0u"kg/m^3",    # ρ
    0.30,               # ν
    1.61u"kgCO2e/kg";   # ecc
    color = "#6E6E6E"
)

"""ASTM A615 Grade 40 rebar (Fy = 40 ksi, Fu = 60 ksi, ECC = 1.72 kgCO₂e/kg)."""
const Rebar_40 = RebarSteel(29000.0ksi, 11200.0ksi, 40.0ksi, 60.0ksi, 490.0u"lb/ft^3", 0.30, 1.72u"kgCO2e/kg"; color = "#5A5A5A")

"""ASTM A615 Grade 60 rebar (Fy = 60 ksi, Fu = 90 ksi, ECC = 1.72 kgCO₂e/kg)."""
const Rebar_60 = RebarSteel(29000.0ksi, 11200.0ksi, 60.0ksi, 90.0ksi, 490.0u"lb/ft^3", 0.30, 1.72u"kgCO2e/kg"; color = "#5A5A5A")

"""ASTM A615 Grade 75 rebar (Fy = 75 ksi, Fu = 100 ksi, ECC = 1.72 kgCO₂e/kg)."""
const Rebar_75 = RebarSteel(29000.0ksi, 11200.0ksi, 75.0ksi, 100.0ksi, 490.0u"lb/ft^3", 0.30, 1.72u"kgCO2e/kg"; color = "#5A5A5A")

"""ASTM A615 Grade 80 rebar (Fy = 80 ksi, Fu = 105 ksi, ECC = 1.72 kgCO₂e/kg)."""
const Rebar_80 = RebarSteel(29000.0ksi, 11200.0ksi, 80.0ksi, 105.0ksi, 490.0u"lb/ft^3", 0.30, 1.72u"kgCO2e/kg"; color = "#5A5A5A")

"""ASTM A1044 headed shear stud steel (Fy = 51 ksi, Fu = 65 ksi, ECC = 1.72 kgCO₂e/kg)."""
const Stud_51 = RebarSteel(29000.0ksi, 11200.0ksi, 51.0ksi, 65.0ksi, 490.0u"lb/ft^3", 0.30, 1.72u"kgCO2e/kg"; color = "#5A5A5A")

# ==============================================================================
# Registry
# ==============================================================================

register_material!(A992_Steel, "A992")
register_material!(S355_Steel, "S355")
register_material!(Rebar_40, "Gr40")
register_material!(Rebar_60, "Gr60")
register_material!(Rebar_75, "Gr75")
register_material!(Rebar_80, "Gr80")
register_material!(Stud_51, "Stud51")

"""_fallback_material_name for unregistered `StructuralSteel`: formats as "Steel (Fy=XX ksi)"."""
_fallback_material_name(mat::StructuralSteel) = "Steel (Fy=$(round(Int, ustrip(ksi, mat.Fy))) ksi)"

"""
_fallback_material_name for unregistered `RebarSteel`: "Rebar (Fy=XX ksi)", with
the coating appended when it is not `:uncoated` (e.g. "Rebar (Fy=60 ksi, epoxy)").
"""
function _fallback_material_name(mat::RebarSteel)
    fy = round(Int, ustrip(ksi, mat.Fy))
    mat.coating === :uncoated && return "Rebar (Fy=$fy ksi)"
    return "Rebar (Fy=$fy ksi, $(mat.coating))"
end

# =============================================================================
# (role, material, lateral_role) connection defaults for structural steel
# =============================================================================
# Entry points and fallbacks are declared in `members/defaults.jl`; these are the
# per-combination specializations for `StructuralSteel` (= `Metal{StructuralSteelType}`).

# --- Steel joist (open-web steel joist, OWSJ) --------------------------------
# Simple (pinned) end connections: OWSJ end seats bear on the supporting girder
# and transmit essentially no moment. AISC 360-16 §B3.4a (corpus: aisc-360-16,
# page 69): "A simple connection transmits a negligible moment ... simple
# connections may be assumed to allow unrestrained relative rotation between the
# framing elements being connected." AISC 360-16 §J1.2 (page 169): "Simple
# connections of beams, girders and trusses shall be designed as flexible and
# are permitted to be proportioned for the reaction shears only."
default_release(::Val{:joist}, ::StructuralSteel, ::Val{:gravity}) = (:pinned, :pinned)
# ENGINEERING JUDGMENT (SJI OWSJ practice; SJI Standard Specifications not in the
# corpus): select Asap's `:joist` element release — pinned bending with RETAINED
# torsional GJ. The joist seat plus horizontal/diagonal bridging supplies
# torsional/lateral restraint about the joist's longitudinal axis while the
# bending ends stay released. `true` here means "use the OWSJ-style `:joist`
# element", NOT "torsion is released"; see the `Beam.torsion_released` docstring.
default_torsion_released(::Val{:joist}, ::StructuralSteel) = true
# ENGINEERING JUDGMENT (SJI OWSJ practice; SJI Standard Specifications not in the
# corpus): the top-of-girder centroid offset `+z = (host_depth + member_depth) / 2`
# is a MODELING DEFAULT reflecting OWSJ seat-on-girder practice. AISC 360-16 does
# not prescribe a joist seat offset; this is a modeling assumption, not a code
# requirement. The returned slot 3 is that physical upward offset (positive =
# global up). `Asap.orient_up_eccentricity` signs it for the member chord and
# roll where the element is built; this function cannot see the member
# direction. Designers using a different detail (for example, pocketed joists,
# top-copes, or embedded plates) should override the FramingLevel seat
# eccentricity for that group.
default_seat_eccentricity(::Val{:joist}, ::StructuralSteel, host_depth, member_depth) =
    (0.0, 0.0, (to_meters(host_depth) + to_meters(member_depth)) / 2, 0.0)

# --- Steel girder (column-to-column primary frame) ---------------------------
# ENGINEERING JUDGMENT (common practice): a gravity girder frames into its
# columns through a simple shear connection (shear tab, clip angles), modeled as
# pinned. AISC 360-16 §B3.4a (corpus: aisc-360-16, page 69): simple connections
# "may be assumed to allow unrestrained relative rotation"; §J1.2 (page 169):
# they "are permitted to be proportioned for the reaction shears only." A
# moment connection is a lateral-system choice: `:moment_frame` girders are
# fully restrained (FR), idealized as fixed per AISC 360-16 Commentary §B3.4
# (page 331).
default_release(::Val{:girder}, ::StructuralSteel, ::Val{:gravity}) = (:pinned, :pinned)
default_release(::Val{:girder}, ::StructuralSteel, ::Val{:moment_frame}) = (:fixed, :fixed)
default_torsion_released(::Val{:girder}, ::StructuralSteel) = false
default_seat_eccentricity(::Val{:girder}, ::StructuralSteel, host_depth, member_depth) =
    (0.0, 0.0, 0.0, 0.0)

# --- Steel beam (catch-all secondary member) ---------------------------------
# Same simple-shear-connection idealization as the gravity girder (AISC 360-16
# §B3.4a, page 69; §J1.2, page 169), whether the end lands on a column or a
# girder. A designer overrides per-end via the `Segment` release symbols for an
# actual moment connection. No seat offset by default.
default_release(::Val{:beam}, ::StructuralSteel, ::Val{:gravity}) = (:pinned, :pinned)
default_torsion_released(::Val{:beam}, ::StructuralSteel) = false
default_seat_eccentricity(::Val{:beam}, ::StructuralSteel, host_depth, member_depth) =
    (0.0, 0.0, 0.0, 0.0)