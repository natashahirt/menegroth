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
    one_way_shear_capacity_without_Av(fc, bw, d, As; λ=1.0) → Force

One-way Vc of a nonprestressed member with Av < Av,min and no axial load,
ACI 318-19 Table 22.5.5.1(c) (corpus: aci-318-19, printed p. 404):

    Vc = 8 λs λ (ρw)^(1/3) √f'c bw d,   ρw = As / (bw d)

not above 5 λ √f'c bw d (§22.5.5.1.1, printed p. 405). λs is Eq. (22.5.5.1.3).
√f'c is capped at 100 psi (§22.5.3.1). Slabs have no stirrups, so this is the
slab row. `As` is the longitudinal tension steel at the section.
"""
function one_way_shear_capacity_without_Av(fc::Pressure, bw::Length, d::Length, As::Area;
                                           λ::Float64 = 1.0)
    bw_in = ustrip(u"inch", bw)
    d_in = ustrip(u"inch", d)
    ρw = ustrip(u"inch^2", As) / (bw_in * d_in)
    sqrt_fc = _shear_sqrt_fc(fc)
    Vc = 8 * size_effect_factor(d) * λ * cbrt(max(ρw, 0.0)) * sqrt_fc * bw_in * d_in
    Vc_max = 5 * λ * sqrt_fc * bw_in * d_in
    return min(Vc, Vc_max) * u"lbf"
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

`M_edge` is the larger `|M|` (`_governing_edge_moment`). The punching
stress checks superpose both moments and use it only as a reported value.
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
  skipped). ACI 318-11 R11.11.7.2 (corpus: aci-318-11, pages 209–211).

At an edge column both moments are superposed: one about the axis parallel
to the free edge, shifted to the section centroid, and the other about the
symmetry axis. Which of `Mux`, `Muy` is which is not taken from the labels;
both assignments are evaluated and the worse governs. The slab kernel
(`check_punching_for_column`) resolves it from the free-edge direction.

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
        # pages 209–211): c1 is perp to the free edge (applied above). The
        # moment about the axis parallel to the edge is shifted to the
        # centroid by e = (b1 − cAB) − c1/2 (eccentricity_to_critical_centroid).
        # ENGINEERING JUDGMENT: the other moment, about the symmetry axis, is
        # superposed as at interior and corner columns, with b1 and b2
        # exchanged in γv and `polar_moment_Jc_edge_perpendicular`. Callers
        # do not label Mux/Muy relative to the edge uniformly, so both
        # assignments are evaluated and the worse governs.
        γv_val = gamma_v(geom.b1, geom.b2)
        Jc = polar_moment_Jc_edge(geom.b1, geom.b2, d, geom.cAB)
        e = eccentricity_to_critical_centroid(geom.b1, c1, geom.cAB)
        γv_p = gamma_v(geom.b2, geom.b1)
        Jc_p = polar_moment_Jc_edge_perpendicular(geom.b1, geom.b2, d)
        v_edge(M_par, M_oth) =
            shifted_moment_stress(γv_val, M_par, Vu, e, geom.cAB, geom.b1 - geom.cAB, Jc) +
            uconvert(u"psi", γv_p * abs(M_oth) * (geom.b2 / 2) / Jc_p)
        vu = v_direct + max(v_edge(Mux, Muy), v_edge(Muy, Mux))

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
        # e = (b − cAB) − c/2 on each free-edge axis.
        # See eccentricity_to_critical_centroid.
        # Face CD governs a moment the shift reverses (shifted_moment_stress).
        e_x = eccentricity_to_critical_centroid(b1, c1, cAB_x)
        e_y = eccentricity_to_critical_centroid(b2, c2, cAB_y)
        v_Mux = shifted_moment_stress(γv_x, Mux, Vu, e_x, cAB_x, b1 - cAB_x, Jc_x)
        v_Muy = shifted_moment_stress(γv_y, Muy, Vu, e_y, cAB_y, b2 - cAB_y, Jc_y)
        vu = v_direct + v_Mux + v_Muy
    end

    ok = vu ≤ ϕvc
    utilization = ustrip(u"psi", vu) / max(ustrip(u"psi", ϕvc), 1e-10)

    return (ok = ok, utilization = utilization, vu = vu, ϕvc = ϕvc,
            b0 = b0, geom = geom)
end

