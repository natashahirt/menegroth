# Composite Steel Deck
# Steel deck + concrete fill acting compositely. Floor sizing is in deck_floor.jl.

# One-way shear of the finished composite deck-slab.
# SDI C-2017 §2.4.B.9, Eq. 2.4.7 and Eq. 2.4.8 (corpus: sdi-c-2017, PDF p. 13).
# Ac is Figure 2-1 (PDF p. 14). VD is the nominal shear of the deck webs.
# `deck_pitch_nominal_web_shear` supplies it from the catalog column and
# AISI S100-16 §G2; `aisi_web_shear` evaluates §G2.1 when the flat web
# width is known.

"""
    deck_shear_lambda(wc) -> Float64

`λ` in SDI C-2017 Eq. 2.4.8 (corpus: sdi-c-2017, PDF p. 13): 1.0 when the
concrete density exceeds 130 lb/ft³, otherwise 0.75. Density equal to 130
lb/ft³ is 0.75.
"""
function deck_shear_lambda(wc)
    return uconvert(u"lb/ft^3", wc) > 130.0u"lb/ft^3" ? 1.0 : 0.75
end

"""
Area under a straight width `w0 → w1` over `y0 → y1`, clipped to `[0, pitch]`.
"""
function _clipped_width_area(y0, y1, w0, w1, pitch)
    dy = y1 - y0
    dy > 0 || return 0.0
    dw = w1 - w0
    breaks = Float64[y0, y1]
    if abs(dw) > 0
        for target in (0.0, pitch)
            f = (target - w0) / dw
            if 0.0 < f < 1.0
                push!(breaks, y0 + f * dy)
            end
        end
    end
    sort!(breaks)
    area = 0.0
    for i in 1:(length(breaks) - 1)
        a, b = breaks[i], breaks[i + 1]
        b - a < 1e-15 && continue
        wa = clamp(w0 + dw * (a - y0) / dy, 0.0, pitch)
        wb = clamp(w0 + dw * (b - y0) / dy, 0.0, pitch)
        area += (wa + wb) / 2 * (b - a)
    end
    return area
end

"""
    deck_shear_concrete_area(hr, rib_top, rib_bottom, pitch, t_slab) -> Area
    deck_shear_concrete_area(profile, t_slab) -> Area

Concrete area `Ac` resisting one-way shear on one deck pitch, SDI C-2017
Figure 2-1 (corpus: sdi-c-2017, PDF p. 14).

The area is the concrete between the two rib webs. The webs are extended
through the topping at the same slope. Where those extensions overlap, the
width is cut off at the deck pitch, which is the figure's top dimension.
Topping concrete that lies outside the extended webs, above the top flanges,
is not included. `t_slab` is the concrete thickness above the deck. The
result is for one pitch; the user note on the figure converts a per-pitch
strength to a unit width by `unit width / pitch`.
"""
function deck_shear_concrete_area(hr, rib_top, rib_bottom, pitch, t_slab)
    hr_in = ustrip(u"inch", uconvert(u"inch", hr))
    top = ustrip(u"inch", uconvert(u"inch", rib_top))
    bot = ustrip(u"inch", uconvert(u"inch", rib_bottom))
    p = ustrip(u"inch", uconvert(u"inch", pitch))
    t = ustrip(u"inch", uconvert(u"inch", t_slab))
    hr_in > 0 || throw(ArgumentError("Deck rib height must be positive."))
    p > 0 || throw(ArgumentError("Deck pitch must be positive."))
    t >= 0 || throw(ArgumentError("Concrete thickness above the deck must be ≥ 0."))
    (bot >= 0 && top >= 0) || throw(ArgumentError("Rib widths must be ≥ 0."))
    H = hr_in + t
    # One straight web line from the bottom of the rib through the topping.
    w_top = bot + (top - bot) / hr_in * H
    area_in2 = _clipped_width_area(0.0, H, bot, w_top, p)
    return area_in2 * u"inch^2"
end

function deck_shear_concrete_area(profile::CompositeDeckProfile, t_slab)
    return deck_shear_concrete_area(profile.hr, profile.rib_top, profile.rib_bottom,
                                    profile.pitch, t_slab)
end

"""
    deck_one_way_shear(fc, Ac, wc; VD=0, design=:lrfd) -> NamedTuple

One-way shear strength of a composite deck-slab on the area `Ac`.

SDI C-2017 §2.4.B.9 (corpus: sdi-c-2017, PDF p. 13):

    Vc = 2 λ √(f′c) Ac                         (Eq. 2.4.8a, pounds)
    φVn = φv Vc + φs VD ≤ φv (4 √(f′c) Ac)/1000 (Eq. 2.4.7a, kips)
    φv = 0.75, φs = 0.85

ASD uses Eq. 2.4.7c with Ωv = 2.00 and Ωs = 1.75. `design` is `:lrfd` or
`:asd`. `capacity` is φVn or Vn/Ω.

`VD` is the nominal shear strength of two deck webs (AISI S100). It defaults
to zero, so the deck webs are not credited. `Ac` and `VD` are for the same
width, one pitch when `Ac` comes from [`deck_shear_concrete_area`](@ref).
"""
function deck_one_way_shear(fc, Ac, wc; VD=0.0u"lbf", design::Symbol=:lrfd)
    design in (:lrfd, :asd) || throw(ArgumentError(
        "design must be :lrfd or :asd, got :$design."))
    fc_psi = ustrip(u"psi", uconvert(u"psi", fc))
    fc_psi > 0 || throw(ArgumentError("f′c must be positive."))
    Ac_in = ustrip(u"inch^2", uconvert(u"inch^2", Ac))
    Ac_in >= 0 || throw(ArgumentError("Ac must be ≥ 0."))
    VD_lbf = ustrip(u"lbf", uconvert(u"lbf", VD))
    VD_lbf >= 0 || throw(ArgumentError("Deck web shear VD must be ≥ 0."))
    λ = deck_shear_lambda(wc)
    √fc = sqrt(fc_psi)
    # Eq. 2.4.8a, pounds. Eq. 2.4.7a writes the upper bound in kips (/1000).
    Vc_lbf = 2 * λ * √fc * Ac_in
    cap_lbf = 4 * √fc * Ac_in
    ϕv, ϕs = 0.75, 0.85
    Ωv, Ωs = 2.00, 1.75
    if design === :lrfd
        section = ϕv * Vc_lbf + ϕs * VD_lbf
        upper = ϕv * cap_lbf
    else
        section = Vc_lbf / Ωv + VD_lbf / Ωs
        upper = cap_lbf / Ωv
    end
    capacity = min(section, upper)
    return (;
        design = design,
        λ = λ,
        Ac = uconvert(u"inch^2", Ac),
        Vc = Vc_lbf * u"lbf",
        VD = VD_lbf * u"lbf",
        capacity = capacity * u"lbf",
        upper_bound = upper * u"lbf",
        governing = section <= upper + 1e-9 ? :section : :upper_bound,
        deck_webs_included = VD_lbf > 0,
    )
end
