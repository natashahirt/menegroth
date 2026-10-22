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
    ustrip(b0) > 0 || throw(ArgumentError("Edge critical perimeter is zero (c1=$c1, c2=$c2, d=$d)"))
    cAB = b1^2 / (2b1 + b2)
    return (b1 = b1, b2 = b2, b0 = b0, cAB = cAB)
end

"""
    punching_geometry_corner(c1, c2, d)

2-sided critical section for corner column.

Returns `(b1, b2, b0, cAB_x, cAB_y)`.

`b1 = c1 + d/2`, `b2 = c2 + d/2` (two-sided section at d/2 from each
interior column face).  Centroid distances from the inner (slab-side)
face of each leg:

    cAB_x = b1² / [2(b1 + b2)]     (PCA Fig. 16-13 Case D, `c`)
    cAB_y = b2² / [2(b1 + b2)]

Reference: ACI 318-11 §11.11.1.2 (corpus: aci-318-11, page 209);
PCA EB712 Fig. 16-13 Case D (corpus: pca-eb712, page 486).
"""
function punching_geometry_corner(c1::Length, c2::Length, d::Length)
    b1 = c1 + d / 2
    b2 = c2 + d / 2
    b0 = b1 + b2
    denom = 2 * (b1 + b2)
    ustrip(denom) > 0 || throw(ArgumentError("Corner critical perimeter is zero (c1=$c1, c2=$c2, d=$d)"))
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

"""
    polar_modulus_Jc_over_c_corner(b1, b2, d)

Section modulus J/c of a two-sided (corner) critical section about the
axis associated with `b1`, per PCA Notes on ACI 318 Fig. 16-13 Case D:

    J/c = [b1² d (b1 + 4 b2) + d³ (b1 + b2)] / (6 b1)

`b1 = c1 + d/2` is the critical-section dimension in the direction of the
moment; `b2 = c2 + d/2` is the perpendicular leg.

ACI 318-11 R11.11.7.2 (page 211) gives Jc for an interior column and
states "Similar equations may be developed for Ac and Jc for columns
located at the edge or corner of a slab."  The closed-form corner
expression is taken from PCA EB712 Fig. 16-13 Case D (page 486), which
is the corpus source that writes the two-sided formula explicitly.

Reference: PCA EB712 Fig. 16-13 Case D (corpus: pca-eb712, page 486);
ACI 318-11 R11.11.7.2 (corpus: aci-318-11, page 211).
"""
function polar_modulus_Jc_over_c_corner(b1::Length, b2::Length, d::Length)
    return (b1^2 * d * (b1 + 4 * b2) + d^3 * (b1 + b2)) / (6 * b1)
end

"""
    polar_moment_Jc_corner(b1, b2, d, cAB)

Jc for a corner column (2-sided critical section).

    Jc = (J/c) · cAB

with J/c from `polar_modulus_Jc_over_c_corner` and
`cAB = b1² / [2(b1 + b2)]` (PCA Case D `c`).

Equivalent expanded form (matches the tabulated J/c × c; omits the
closing-leg out-of-plane `b2 d³/12` term, same PCA convention as
`polar_moment_Jc_edge`):

    Jc = b1 d³/12 + d b1³/12 + b1 d (b1/2 − cAB)² + b2 d cAB²

Reference: PCA EB712 Fig. 16-13 Case D (corpus: pca-eb712, page 486);
ACI 318-11 R11.11.7.2 (corpus: aci-318-11, page 211).
"""
function polar_moment_Jc_corner(b1::Length, b2::Length, d::Length, cAB::Length)
    return polar_modulus_Jc_over_c_corner(b1, b2, d) * cAB
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
# Edge-column orientation (ACI 318-11 §11.11.7 / R11.11.7.2)
# ─────────────────────────────────────────────────────────────────────────────

"""
    _governing_edge_moment(Mux, Muy) → Torque

Uniaxial 3-sided edge check can apply one transfer moment. When both
components are present, keep the larger |M| so `punching_check`'s
subsequent `Muy = 0` cannot drop the governing transfer. Single-axis
callers pass the other component as zero and keep that axis unchanged.

ENGINEERING JUDGMENT: ACI 318-11 §11.11.7.1 / R11.11.7.2 (corpus:
aci-318-11, pages 209–211) transfer γv Mu about the centroid of the
§11.11.1.2 critical section; they do not rank Mux vs Muy. The uniaxial
edge path takes `max(|Mux|, |Muy|)` so a leftover axis cannot govern.
"""
function _governing_edge_moment(Mux::Torque, Muy::Torque)
    Mux_zero = abs(to_kipft(Mux)) < 1e-10
    Muy_zero = abs(to_kipft(Muy)) < 1e-10
    Mux_zero && return Muy
    Muy_zero && return Mux
    return abs(to_kipft(Mux)) ≥ abs(to_kipft(Muy)) ? Mux : Muy
end

"""
    _orient_edge_column(c1, c2, Mux, Muy; free_edge_parallel=:c2)

ACI 318-11 R11.11.7.2 (corpus: aci-318-11, pages 209–211): `c1` is the column
dimension in the direction of the span for which moments are determined —
the dimension **perpendicular to the free edge**. The unbalanced moment used
on the 3-sided critical section is the moment about the axis **parallel to
the free edge**.

- `free_edge_parallel = :c1`: free edge runs along the named `c1` face;
  swap so ACI `c1` = named `c2`. Do **not** skip this swap.
- `free_edge_parallel = :c2` (default): caller already stored `c1` perp to
  the edge.

On **both** `:c1` and `:c2`, after any geometry swap, `M_edge` is the
governing `|M|` when both components are present (`_governing_edge_moment`).
Single-moment callers pass the edge transfer as `Mux` (or as `Muy` with
`Mux = 0`).
"""
function _orient_edge_column(c1::Length, c2::Length, Mux::Torque, Muy::Torque;
                             free_edge_parallel::Symbol = :c2)
    free_edge_parallel in (:c1, :c2) ||
        throw(ArgumentError("free_edge_parallel must be :c1 or :c2; got :$free_edge_parallel"))
    M_edge = _governing_edge_moment(Mux, Muy)
    if free_edge_parallel === :c1
        return (c1 = c2, c2 = c1, M_edge = M_edge)
    end
    return (c1 = c1, c2 = c2, M_edge = M_edge)
end

"""
    _infer_free_edge_parallel(col) -> Symbol

Infer `free_edge_parallel` from a column's `boundary_edge_dirs` (unit vector
along the slab free edge). Aligns the edge with local x (`:c1`) or local y
(`:c2`). Defaults to `:c2` when no boundary direction is stored (c1 already
perp to the edge — the historical convention).
"""
function _infer_free_edge_parallel(col)
    if hasproperty(col, :boundary_edge_dirs)
        dirs = getfield(col, :boundary_edge_dirs)
        if !isempty(dirs)
            θ = hasproperty(col, :θ) ? Float64(getfield(col, :θ)) : 0.0
            ex, ey = dirs[1]
            lx = abs(ex * cos(θ) + ey * sin(θ))
            ly = abs(-ex * sin(θ) + ey * cos(θ))
            return lx ≥ ly ? :c1 : :c2
        end
    end
    return :c2
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
- `free_edge_parallel`: For `:edge` only. `:c2` (default) means `c1` is
  already perp to the free edge; `:c1` means the free edge runs along the
  named `c1` face (swap so ACI `c1` = named `c2` — the swap is not
  skipped). On both `:c1` and `:c2`, after any geometry swap, the uniaxial
  transfer moment is `max(|Mux|, |Muy|)` when both are present.
  ACI 318-11 R11.11.7.2 (corpus: aci-318-11, pages 209–211).

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
    ϕ::Float64 = 0.75,
    free_edge_parallel::Symbol = :c2,
)
    if position == :edge
        ori = _orient_edge_column(c1, c2, Mux, Muy; free_edge_parallel = free_edge_parallel)
        c1 = ori.c1
        c2 = ori.c2
        Mux = ori.M_edge
        Muy = zero(Muy)
    end
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
        # Edge — ACI 318-11 §11.11.7 / R11.11.7.2 (corpus: aci-318-11,
        # pages 209–211): c1 is perp to the free edge (applied above);
        # transfer moment is about the axis parallel to the edge (`Mux`
        # after `_orient_edge_column`).
        Mub = abs(Mux)
        γv_val = gamma_v(geom.b1, geom.b2)
        Jc = polar_moment_Jc_edge(geom.b1, geom.b2, d, geom.cAB)
        e = c1 / 2 - geom.cAB
        Mub_adj = max(Mub - Vu * e, zero(Mub))
        v_moment = uconvert(u"psi", γv_val * Mub_adj * geom.cAB / Jc)
        vu = v_direct + v_moment

    else
        # :corner — two-sided critical section.  ACI 318-11 §11.11.7.1
        # (corpus: aci-318-11, page 209) transfers γv Mu by eccentricity of
        # shear at every slab-column connection, including corners.
        # γv from Eq. (11-37) / Eq. (13-1) with the 2-sided b1, b2
        # (§13.5.3.2, page 250).  Jc and cAB from PCA EB712 Fig. 16-13
        # Case D (page 486).  Each axis contributes (biaxial superposition,
        # same as the interior path).
        b1 = geom.b1
        b2 = geom.b2
        cAB_x = geom.cAB_x
        cAB_y = geom.cAB_y

        γv_x = gamma_v(b1, b2)
        γv_y = gamma_v(b2, b1)
        Jc_x = polar_moment_Jc_corner(b1, b2, d, cAB_x)
        Jc_y = polar_moment_Jc_corner(b2, b1, d, cAB_y)

        # Mu at the critical-section centroid (R11.11.7.2, page 210):
        # shift the column-centerline moment by Vu × e.
        e_x = c1 / 2 - cAB_x
        e_y = c2 / 2 - cAB_y
        Mux_adj = max(abs(Mux) - Vu * e_x, zero(Mux))
        Muy_adj = max(abs(Muy) - Vu * e_y, zero(Muy))

        v_Mux = uconvert(u"psi", γv_x * Mux_adj * cAB_x / Jc_x)
        v_Muy = uconvert(u"psi", γv_y * Muy_adj * cAB_y / Jc_y)
        vu = v_direct + v_Mux + v_Muy
    end

    ok = vu ≤ ϕvc
    utilization = ustrip(u"psi", vu) / max(ustrip(u"psi", ϕvc), 1e-10)

    return (ok = ok, utilization = utilization, vu = vu, ϕvc = ϕvc,
            b0 = b0, geom = geom)
end

