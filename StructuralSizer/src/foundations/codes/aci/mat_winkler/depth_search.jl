"""
    _mat_grid_h(min_depth, depth_increment, k) → Length

Thickness after `k` successive additions of `depth_increment`, matching
the linear scan's grid `h_k = min_depth + k · depth_increment`.
"""
function _mat_grid_h(min_depth, depth_increment, k::Int)
    h = min_depth
    for _ in 1:k
        h += depth_increment
    end
    return h
end

"""
    _mat_depth_index(min_depth, depth_increment, h_target) → Int

First grid index `k ∈ 0:59` with `h_k ≥ h_target`. A target at or below
`min_depth` returns 0. A target above `h_59` clamps to 59.
"""
function _mat_depth_index(min_depth, depth_increment, h_target)
    tol = 1e-6u"inch"
    h = min_depth
    h_target <= h + tol && return 0
    for k in 1:59
        h += depth_increment
        h + tol >= h_target && return k
    end
    return 59
end

"""
    _mat_punching_h_seed(demands, fc, λ, ϕ, cover, db_half) → Length

Closed-form thickness *start* from the governing column. Not a design
result and not a lower bound.

ACI 318-11 §11.11.2.1(c) Eq. (11-33) (corpus: aci-318-11, page 201):

    Vc = 4 λ √f'c · b0 · d

with φ for shear from §9.3.2.3 (corpus: aci-318-11, page 128). For the
column with the largest factored `Pu`,

    d ≈ Pu / (b0 · φ · 4 λ √f'c).

`b0` is that column's interior critical perimeter at d/2
(§11.11.1.2, page 200): rectangular `b0 = 2(c1 + c2 + 2d)`, circular
`b0 = π(D + d)`. Eq. (11-33) is not taken as the lesser of
Eq. (11-31)–(11-33). Moment transfer (§11.11.7) and the soil pressure
inside the critical section are omitted, and both `Pu`'s stress and `b0`
depend on `d`, so this fixed point is not a lower bound. The thickness
loop still accepts or rejects `h`.
"""
function _mat_punching_h_seed(demands, fc, λ, ϕ, cover, db_half)
    cover_db = cover + db_half
    s = ϕ * 4.0 * λ * sqrt(max(ustrip(u"psi", fc), 0.0))
    (s <= 0 || !isfinite(s)) && return cover_db
    d_gov = 0.0
    for dem in demands
        Pu = ustrip(u"lbf", dem.Pu)
        Pu <= 0 && continue
        d_in = dem.shape == :circular ?
            _mat_circular_punch_d(ustrip(u"inch", dem.c1), Pu, s) :
            _mat_rect_punch_d(ustrip(u"inch", dem.c1), ustrip(u"inch", dem.c2), Pu, s)
        isfinite(d_in) && (d_gov = max(d_gov, d_in))
    end
    d_gov <= 0 && return cover_db
    return d_gov * u"inch" + cover_db
end

# Eq. (11-33) fixed point, rectangular interior perimeter. Start only.
# 4 s d² + 2 s (c1 + c2) d − Pu = 0.
function _mat_rect_punch_d(c1, c2, Pu, s)
    P = c1 + c2
    disc = P * P + 4.0 * Pu / s
    disc < 0 && return 0.0
    d = (-P + sqrt(disc)) / 4.0
    return isfinite(d) ? max(d, 0.0) : 0.0
end

# Eq. (11-33) fixed point, circular perimeter b0 = π(D + d). Start only.
function _mat_circular_punch_d(D, Pu, s)
    denom = s * π
    denom <= 0 && return 0.0
    disc = D * D + 4.0 * Pu / denom
    disc < 0 && return 0.0
    d = (-D + sqrt(disc)) / 2.0
    return isfinite(d) ? max(d, 0.0) : 0.0
end

