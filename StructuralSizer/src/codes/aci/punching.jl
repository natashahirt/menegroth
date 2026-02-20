# =============================================================================
# Shared ACI 318-11 Punching & Shear Utilities (Unitful)
# =============================================================================
#
# Element-agnostic ACI punching/shear math used by BOTH slabs and foundations.
# Included via codes/aci/_aci_shared.jl BEFORE slabs/ and foundations/.
#
# Contents:
#   §11.11      Punching (two-way) shear geometry, capacity, demand
#   §13.5.3     Moment transfer fractions (γf, γv)
#   R11.11.7.2  Combined punching stress with unbalanced moment (Jc)
#   §13.5.3.2   Effective slab width for moment transfer
#   §11.2       One-way (beam) shear capacity/demand
#   —           High-level punching_check for biaxial moment transfer
#
# All functions are fully Unitful.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# §11.11.1.2 — Critical Section Geometry
# ─────────────────────────────────────────────────────────────────────────────

"""
    punching_geometry_interior(c1, c2, d; shape=:rectangular)

4-sided critical section at d/2 from column face (interior column).

Returns `(b1, b2, b0, cAB)`.

- `b1`, `b2`: Critical section dimensions (c1+d, c2+d)
- `b0`: Total perimeter
- `cAB`: Centroid distance from face (b1/2 for symmetric)

Reference: ACI 318-11 §11.11.1.2
"""
function punching_geometry_interior(c1::Length, c2::Length, d::Length;
                                     shape::Symbol = :rectangular)
    if shape == :circular
        D = c1
        b0 = π * (D + d)
        b_sq = b0 / 4   # equivalent square side
        return (b1 = b_sq, b2 = b_sq, b0 = b0, cAB = b_sq / 2)
    end
    b1 = c1 + d
    b2 = c2 + d
    b0 = 2b1 + 2b2
    return (b1 = b1, b2 = b2, b0 = b0, cAB = b1 / 2)
end

"""
    punching_geometry_edge(c1, c2, d)

3-sided critical section for edge column.

Returns `(b1, b2, b0, cAB)`.

Reference: ACI 318-11 §11.11.1.2, StructurePoint §5.2(a)
"""
function punching_geometry_edge(c1::Length, c2::Length, d::Length)
    b1 = c1 + d / 2
    b2 = c2 + d
    b0 = 2b1 + b2
    cAB = b1^2 / (2b1 + b2)
    return (b1 = b1, b2 = b2, b0 = b0, cAB = cAB)
end

"""
    punching_geometry_corner(c1, c2, d)

2-sided critical section for corner column.

Returns `(b1, b2, b0, cAB_x, cAB_y)`.

Reference: ACI 318-11 §11.11.1.2
"""
function punching_geometry_corner(c1::Length, c2::Length, d::Length)
    b1 = c1 + d / 2
    b2 = c2 + d / 2
    b0 = b1 + b2
    denom = 2 * (b1 + b2)
    return (b1 = b1, b2 = b2, b0 = b0,
            cAB_x = b1^2 / denom, cAB_y = b2^2 / denom)
end

"""
    punching_geometry(c1, c2, d; position, shape)

Dispatch to the appropriate geometry function by column position.
"""
function punching_geometry(c1::Length, c2::Length, d::Length;
                           position::Symbol = :interior,
                           shape::Symbol = :rectangular)
    position == :interior && return punching_geometry_interior(c1, c2, d; shape = shape)
    position == :edge     && return punching_geometry_edge(c1, c2, d)
    return punching_geometry_corner(c1, c2, d)
end

"""
    punching_perimeter(c1, c2, d; shape=:rectangular)

Critical perimeter b₀ for an interior column.

Reference: ACI 318-11 §11.11.1.2
"""
function punching_perimeter(c1::Length, c2::Length, d::Length;
                             shape::Symbol = :rectangular)
    shape == :circular && return π * (c1 + d)
    return 2 * (c1 + d) + 2 * (c2 + d)
end

# ─────────────────────────────────────────────────────────────────────────────
# §11.11.2.1 — Column Factors
# ─────────────────────────────────────────────────────────────────────────────

"""
    punching_αs(position) → Int

ACI 318-11 §11.11.2.1(b) location factor: 40 interior, 30 edge, 20 corner.
"""
function punching_αs(position::Symbol)
    position == :interior ? 40 :
    position == :edge     ? 30 : 20
end

"""
    punching_β(c1, c2; shape=:rectangular)

Column aspect ratio β = long side / short side (1.0 for circular).
"""
function punching_β(c1::Length, c2::Length; shape::Symbol = :rectangular)
    shape == :circular && return 1.0
    short = min(c1, c2)
    return ustrip(u"inch", max(c1, c2)) / ustrip(u"inch", max(short, 1.0u"inch"))
end

# ─────────────────────────────────────────────────────────────────────────────
# §13.5.3 / §11.11.7 — Moment Transfer Fractions
# ─────────────────────────────────────────────────────────────────────────────

"""
    gamma_f(b1, b2) → Float64

Fraction of unbalanced moment transferred by flexure.

    γf = 1 / (1 + (2/3)√(b1/b2))

`b1` = critical section dimension in the span direction of the moment.

Reference: ACI 318-11 Eq. (13-1)
"""
function gamma_f(b1::Length, b2::Length)
    return 1.0 / (1.0 + (2.0 / 3.0) * sqrt(b1 / b2))
end

"""
    gamma_v(b1, b2) → Float64

Fraction of unbalanced moment transferred by eccentric shear: γv = 1 − γf.

Reference: ACI 318-11 Eq. (11-37)
"""
function gamma_v(b1::Length, b2::Length)
    return 1.0 - gamma_f(b1, b2)
end

"""
    effective_slab_width(c2, h; position=:interior)

Effective slab width for moment transfer by flexure.

- Interior: bb = c2 + 3h (1.5h each side)
- Edge/corner: bb = c2 + 1.5h (slab side only)

Reference: ACI 318-11 §13.5.3.2
"""
function effective_slab_width(c2::Length, h::Length; position::Symbol = :interior)
    position == :interior ? c2 + 3h : c2 + 1.5h
end

# ─────────────────────────────────────────────────────────────────────────────
# R11.11.7.2 — Polar Moment Jc of Critical Section
# ─────────────────────────────────────────────────────────────────────────────

"""
    polar_moment_Jc_interior(b1, b2, d)

Jc for interior column (4-sided, symmetric critical section).

    Jc = d b1³/6 + b1 d³/6 + d b2 (b1/2)² × 2

Reference: ACI 318-11 R11.11.7.2, StructurePoint p.44
"""
function polar_moment_Jc_interior(b1::Length, b2::Length, d::Length)
    cAB = b1 / 2
    return 2 * (b1 * d^3 / 12 + d * b1^3 / 12) + 2 * b2 * d * cAB^2
end

"""
    polar_moment_Jc_edge(b1, b2, d, cAB)

Jc for edge column (3-sided, asymmetric critical section).

    Jc = 2[b1 d³/12 + d b1³/12 + b1 d (b1/2−cAB)²] + b2 d cAB²

Two b1 sides (perpendicular to slab edge) get full in-plane + out-of-plane +
parallel-axis contributions.  The closing b2 side (parallel to the moment
transfer axis) contributes only its parallel-axis term (b2·d·cAB²); its
out-of-plane bending (b2·d³/12) is conventionally omitted per PCA practice.

Reference: ACI 318-11 R11.11.7.2, PCA Notes on ACI 318, StructurePoint p.42–43
"""
function polar_moment_Jc_edge(b1::Length, b2::Length, d::Length, cAB::Length)
    return 2 * (b1 * d^3 / 12 + d * b1^3 / 12 +
                b1 * d * (b1 / 2 - cAB)^2) +
           b2 * d * cAB^2
end

# ─────────────────────────────────────────────────────────────────────────────
# §11.11.2.1 — Punching Shear Capacity
# ─────────────────────────────────────────────────────────────────────────────

"""
    punching_capacity_stress(fc, β, αs, b0, d; λ=1.0) → Pressure

Nominal punching shear stress vc per ACI 318-11 §11.11.2.1:

    vc = min( (2+4/β)λ√f'c,  (αs d/b0+2)λ√f'c,  4λ√f'c )

Eq. (11-31), (11-32), (11-33) respectively. Returns vc as a Pressure (psi).
"""
function punching_capacity_stress(fc::Pressure, β::Float64, αs::Int,
                                   b0::Length, d::Length; λ::Float64 = 1.0)
    sqrt_fc = sqrt(ustrip(u"psi", fc))
    vc_a = (2 + 4 / β) * λ * sqrt_fc               # Eq. (11-31)
    vc_b = (αs * d / b0 + 2) * λ * sqrt_fc         # Eq. (11-32)
    vc_c = 4 * λ * sqrt_fc                          # Eq. (11-33)
    return min(vc_a, vc_b, vc_c) * u"psi"
end

"""
    punching_capacity_interior(b0, d, fc; ...) → Force

Nominal punching shear capacity Vc = vc × b₀ × d (as a force).
"""
function punching_capacity_interior(
    b0::Length, d::Length, fc::Pressure;
    c1::Length = 0u"inch", c2::Length = 0u"inch",
    λ::Float64 = 1.0, position::Symbol = :interior,
    shape::Symbol = :rectangular
)
    β = punching_β(c1, c2; shape = shape)
    αs = punching_αs(position)
    vc = punching_capacity_stress(fc, β, αs, b0, d; λ = λ)
    # vc (psi) × b0 (inch) × d (inch) → lbf
    Vc = ustrip(u"psi", vc) * ustrip(u"inch", b0) * ustrip(u"inch", d)
    return Vc * u"lbf"
end

# ─────────────────────────────────────────────────────────────────────────────
# Punching Shear Demand & Combined Stress
# ─────────────────────────────────────────────────────────────────────────────

"""
    punching_demand(qu, At, c1, c2, d; shape=:rectangular) → Force

Punching shear demand: Vu = qu × (At − Ac).
"""
function punching_demand(qu::Pressure, At::Area, c1::Length, c2::Length, d::Length;
                          shape::Symbol = :rectangular)
    Ac = shape == :circular ? π * (c1 + d)^2 / 4 : (c1 + d) * (c2 + d)
    return qu * (At - Ac)
end

"""
    combined_punching_stress(Vu, Mub, b0, d, γv, Jc, cAB) → Pressure

Direct + eccentric shear stress per ACI R8.4.4.2.3:

    vu = Vu/(b₀·d) + γv·Mub·cAB / Jc
"""
function combined_punching_stress(Vu::Force, Mub::Torque, b0::Length, d::Length,
                                   γv::Float64, Jc, cAB::Length)
    return Vu / (b0 * d) + γv * Mub * cAB / Jc
end

# ─────────────────────────────────────────────────────────────────────────────
# Simple Check Functions
# ─────────────────────────────────────────────────────────────────────────────

"""Check concentric punching: Vu ≤ φVc."""
function check_punching_shear(Vu, Vc; φ::Float64 = 0.75)
    φVc = φ * Vc
    ratio = Vu / φVc
    ok = ratio ≤ 1.0
    msg = ok ? "OK: Vu/φVc = $(round(ratio, digits=3))" :
               "NG: Vu/φVc = $(round(ratio, digits=3)) > 1.0"
    return (ok = ok, ratio = ratio, message = msg)
end

"""Check combined punching stress: vu ≤ φvc."""
function check_combined_punching(vu::Pressure, vc::Pressure; φ::Float64 = 0.75)
    ratio = vu / (φ * vc)
    ok = ratio ≤ 1.0
    msg = ok ? "OK: vu/φvc = $(round(ratio, digits=3))" :
               "NG: vu/φvc = $(round(ratio, digits=3)) > 1.0"
    return (ok = ok, ratio = ratio, message = msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# §11.2 — One-Way (Beam) Shear
# ─────────────────────────────────────────────────────────────────────────────

"""
    one_way_shear_capacity(fc, bw, d; λ=1.0) → Force

Vc = 2λ√f'c × bw × d (calibrated for psi/inch → lbf).

Reference: ACI 318-11 §11.2.1.1 (Eq. 11-3)
"""
function one_way_shear_capacity(fc::Pressure, bw::Length, d::Length;
                                 λ::Float64 = 1.0)
    Vc = 2 * λ * sqrt(ustrip(u"psi", fc)) * ustrip(u"inch", bw) * ustrip(u"inch", d)
    return Vc * u"lbf"
end

"""
    one_way_shear_demand(qu, bw, ln, d) → Force

One-way shear demand at critical section (d from support face):
    Vu = qu × bw × (ln/2 − d)

Reference: ACI 318-11 §11.1.3.1
"""
function one_way_shear_demand(qu::Pressure, bw::Length, ln::Length, d::Length)
    return qu * bw * ln / 2 - qu * bw * d
end

"""Check one-way shear: Vu ≤ φVc."""
function check_one_way_shear(Vu, Vc; φ::Float64 = 0.75)
    φVc = φ * Vc
    ratio = ustrip(u"lbf", Vu) / ustrip(u"lbf", φVc)
    ok = ratio ≤ 1.0
    msg = ok ? "OK: Vu/φVc = $(round(ratio, digits=3))" :
               "NG: Vu/φVc = $(round(ratio, digits=3)) > 1.0"
    return (ok = ok, ratio = ratio, message = msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# High-Level: Punching Check with Biaxial Unbalanced Moment
# ─────────────────────────────────────────────────────────────────────────────

"""
    punching_check(Vu, Mux, Muy, d, fc, c1, c2; ...) → NamedTuple

Full ACI 318-11 §11.11 + §11.11.7 punching shear check with eccentric shear
from biaxial unbalanced moments.

# Arguments
- `Vu::Force`: Net punching shear at critical section (Pu − qu·Ac)
- `Mux::Torque`, `Muy::Torque`: Unbalanced moments about x- and y-axes
- `d::Length`: Effective depth
- `fc::Pressure`: f'c
- `c1::Length`, `c2::Length`: Column dimensions (c1 = diameter for :circular)

# Keywords
- `position`: `:interior` (default), `:edge`, `:corner`
- `shape`: `:rectangular` (default), `:circular`
- `λ`: Lightweight factor (1.0)
- `ϕ`: Shear strength reduction factor (0.75)

# Returns
`(ok, utilization, vu, ϕvc, b0, geom)`

# Biaxial Interior Column
For interior columns with biaxial moment (Mux ≠ 0, Muy ≠ 0):

    vu = Vu/(b₀d) + γv_x |Mux| (b1/2) / Jc_x + γv_y |Muy| (b2/2) / Jc_y

where Jc_x and Jc_y are computed with b1, b2 swapped appropriately.
"""
function punching_check(
    Vu::Force, Mux::Torque, Muy::Torque,
    d::Length, fc::Pressure,
    c1::Length, c2::Length;
    position::Symbol = :interior,
    shape::Symbol = :rectangular,
    λ::Float64 = 1.0,
    ϕ::Float64 = 0.75
)
    # Geometry
    geom = punching_geometry(c1, c2, d; position = position, shape = shape)
    b0 = geom.b0

    # Capacity
    β = punching_β(c1, c2; shape = shape)
    αs = punching_αs(position)
    vc = punching_capacity_stress(fc, β, αs, b0, d; λ = λ)
    ϕvc = ϕ * vc

    # Direct shear stress
    v_direct = uconvert(u"psi", Vu / (b0 * d))

    # Moment magnitudes — test for zero
    Mux_zero = abs(to_kipft(Mux)) < 1e-10
    Muy_zero = abs(to_kipft(Muy)) < 1e-10

    if Mux_zero && Muy_zero
        # Concentric — simple stress
        vu = v_direct

    elseif position == :interior
        # Biaxial eccentric shear (superposition of both moment axes)
        b1 = c1 + d   # x-direction critical section dim
        b2 = c2 + d   # y-direction critical section dim

        # Mux transfers stress in x-direction: γv(b1, b2), Jc(b1, b2), cAB = b1/2
        γv_x  = gamma_v(b1, b2)
        Jc_x  = polar_moment_Jc_interior(b1, b2, d)
        cAB_x = b1 / 2

        # Muy transfers stress in y-direction: γv(b2, b1), Jc(b2, b1), cAB = b2/2
        γv_y  = gamma_v(b2, b1)
        Jc_y  = polar_moment_Jc_interior(b2, b1, d)
        cAB_y = b2 / 2

        v_Mux = uconvert(u"psi", γv_x * abs(Mux) * cAB_x / Jc_x)
        v_Muy = uconvert(u"psi", γv_y * abs(Muy) * cAB_y / Jc_y)
        vu = v_direct + v_Mux + v_Muy

    elseif position == :edge
        # Edge — primary moment perpendicular to free edge
        Mub = max(abs(Mux), abs(Muy))
        γv_val = gamma_v(geom.b1, geom.b2)
        Jc = polar_moment_Jc_edge(geom.b1, geom.b2, d, geom.cAB)
        e = c1 / 2 - geom.cAB
        Mub_adj = max(Mub - Vu * e, zero(Mub))
        v_moment = uconvert(u"psi", γv_val * Mub_adj * geom.cAB / Jc)
        vu = v_direct + v_moment

    else  # :corner — ACI 318-11 §11.11.7.1 applies moment transfer to all columns,
          # but direct shear only is used here (conservative for gravity loading).
        vu = v_direct
    end

    ok = vu ≤ ϕvc
    utilization = ustrip(u"psi", vu) / max(ustrip(u"psi", ϕvc), 1e-10)

    return (ok = ok, utilization = utilization, vu = vu, ϕvc = ϕvc,
            b0 = b0, geom = geom)
end

