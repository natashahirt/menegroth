using Unitful

# A flanged wall section for §18.10.6.3 and for the neutral-axis depth
# §18.10.6.2 asks the caller to supply.
#
# One perpendicular wall at one end is an L or a T. A flange at each end is
# the C (or a box leg) in the plane of the web. The offset of an L out of
# that plane does not move area along ℓw. Each flange zone is the last `tf`
# of the web length at that end, and its width is `bf`. The intersection is
# not added twice. `bf == tw` is the rectangular wall. `As_flange` is
# vertical steel in that zone, added to the web's smeared `Ast`. Added end
# bars, when `As_end` is positive, sit at both ends as in
# `wall_pm_end_bars_at_c_si`.

"""
    wall_flanged_gross_section(lw, tw, tf, bf; flange_at=:positive) -> NamedTuple

Gross area, centroid, and in-plane inertia. `x` runs from the negative end
to the positive end. `flange_at` names which end carries the flange.
`centroid` is measured from the negative end.
"""
function wall_flanged_gross_section(lw::Length, tw::Length, tf::Length, bf::Length;
                                   flange_at::Symbol = :positive)
    flange_at in (:positive, :negative) || throw(ArgumentError(
        "flanged wall: the flange is at :positive or :negative (got :$flange_at)"))
    lw_m = ustrip(u"m", lw)
    tw_m = ustrip(u"m", tw)
    tf_m = ustrip(u"m", tf)
    bf_m = ustrip(u"m", bf)
    (lw_m > 0 && tw_m > 0 && tf_m > 0 && bf_m > 0) || throw(ArgumentError(
        "flanged wall: ℓw, the web thickness, the flange thickness, and the flange width must be positive"))
    tf_m < lw_m || throw(ArgumentError(
        "flanged wall: the flange thickness must be shorter than ℓw (got tf=$tf, ℓw=$lw)"))
    bf_m + 1e-12 >= tw_m || throw(ArgumentError(
        "flanged wall: the flange width is at least the web thickness"))
    stem = lw - tf
    area_stem = tw * stem
    area_flange = bf * tf
    area = area_stem + area_flange
    if flange_at === :positive
        x_stem = stem / 2
        x_flange = stem + tf / 2
    else
        x_flange = tf / 2
        x_stem = tf + stem / 2
    end
    centroid = (area_stem * x_stem + area_flange * x_flange) / area
    inertia = tw * stem^3 / 12 + area_stem * (x_stem - centroid)^2 +
              bf * tf^3 / 12 + area_flange * (x_flange - centroid)^2
    return (
        area = area,
        centroid = centroid,
        inertia = inertia,
        stem = stem,
        flange_at = flange_at,
    )
end

"""
    wall_flanged_fiber_stress(P, M, lw, tw, tf, bf; flange_at=:positive) -> NamedTuple

Extreme-fiber stress on the gross flanged section. Compression is positive.
A positive moment compresses the positive end. `P / A` is the axial part.
"""
function wall_flanged_fiber_stress(P, M, lw::Length, tw::Length, tf::Length, bf::Length;
                                  flange_at::Symbol = :positive)
    section = wall_flanged_gross_section(lw, tw, tf, bf; flange_at = flange_at)
    axial = P / section.area
    at_positive_end = axial + M * (lw - section.centroid) / section.inertia
    at_negative_end = axial - M * section.centroid / section.inertia
    return (
        at_positive_end = at_positive_end,
        at_negative_end = at_negative_end,
        axial = axial,
        section = section,
    )
end

# Whitney block of a flanged wall, measured from the compression face.
# Same 0.85 f′c block as `wall_pm_at_c_si`. Width is `bf` inside the flange
# and `tw` in the stem. The block does not double-count the intersection.
function _flanged_whitney_block(lw, tw, tf, bf, a, flange_in_compression::Bool)
    stem = lw - tf
    if flange_in_compression
        if a <= tf
            return (area = bf * a, ybar = a / 2)
        end
        area = bf * tf + tw * (a - tf)
        moment = bf * tf * (tf / 2) + tw * (a - tf) * ((tf + a) / 2)
        return (area = area, ybar = moment / area)
    end
    if a <= stem
        return (area = tw * a, ybar = a / 2)
    end
    area = tw * stem + bf * (a - stem)
    moment = tw * stem * (stem / 2) + bf * (a - stem) * ((stem + a) / 2)
    return (area = area, ybar = moment / area)
end

"Positive moment compresses the positive end, as in `wall_flanged_fiber_stress`."
function flange_end_compressed(flange_at::Symbol, moment::Real)
    flange_at in (:positive, :negative) || throw(ArgumentError(
        "flanged wall: the flange is at :positive or :negative (got :$flange_at)"))
    return flange_at === :positive ? moment >= 0 : moment < 0
end

# Area of `As_flange` on each layer. The zone is the last `tf` of ℓw, measured
# from the compression face when the flange is that face, otherwise from the
# far end. A zone that contains no layer center keeps the whole area on the
# layer nearest the zone centroid.
function _flange_layer_area(lw, tf, nlayers, As_flange, flange_in_compression::Bool)
    extra = zeros(nlayers)
    As_flange > 0 || return extra
    y0 = flange_in_compression ? 0.0 : (lw - tf)
    y1 = y0 + tf
    idxs = Int[]
    for i in 1:nlayers
        y = (i - 0.5) / nlayers * lw
        y > y0 && y <= y1 + 1e-12 && push!(idxs, i)
    end
    if isempty(idxs)
        yc = 0.5 * (y0 + y1)
        push!(idxs, clamp(round(Int, yc / lw * nlayers + 0.5), 1, nlayers))
    end
    share = As_flange / length(idxs)
    for i in idxs
        extra[i] = share
    end
    return extra
end

"""
    wall_flanged_pm_at_c_si(fc, fy, Es, lw, tw, tf, bf, Ast, c;
                           flange_in_compression=true, εcu=0.003, nlayers=40,
                           As_flange=0, As_end=0, inset=0) -> NamedTuple

Nominal `(Pn, Mn, εt)` at neutral-axis depth `c`, bare SI, compression
positive. The steel and the Whitney factor are the ones in
`wall_pm_at_c_si`. The concrete width is `bf` in the flange and `tw` in the
stem. `c` and `y` are measured from the compression face.
`flange_in_compression` puts that face at the flange. `Mn` is about
mid-length, returned positive.

`Ast` is the web steel, smeared along ℓw. `As_flange` is additional vertical
steel in the flange zone only. `As_end` is added area at each end, with the
same group at `inset` and at `ℓw − inset`, the placement in
`wall_pm_end_bars_at_c_si`. `As_flange = 0` and `As_end = 0` leave the
concrete-only flange.

# Citation
ACI 318-19 §22.2, the same block and steel idealization as
`wall_pm_at_c_si` (corpus: aci-318-19). The flange width is the gross width,
not a second concrete force.
"""
function wall_flanged_pm_at_c_si(fc::Real, fy::Real, Es::Real,
                                lw::Real, tw::Real, tf::Real, bf::Real,
                                Ast::Real, c::Real;
                                flange_in_compression::Bool = true,
                                εcu::Real = 0.003, nlayers::Int = 40,
                                As_flange::Real = 0.0, As_end::Real = 0.0,
                                inset::Real = 0.0)
    (lw > 0 && tw > 0 && tf > 0 && bf > 0 && c > 0 && Ast >= 0) || throw(ArgumentError(
        "flanged wall capacity: lengths and c must be positive, and Ast non-negative"))
    (As_flange >= 0 && As_end >= 0) || throw(ArgumentError(
        "flanged wall capacity: flange and end steel areas are non-negative"))
    tf < lw || throw(ArgumentError("flanged wall capacity: tf must be shorter than ℓw"))
    bf + 1e-12 >= tw || throw(ArgumentError(
        "flanged wall capacity: the flange width is at least the web thickness"))
    nlayers >= 1 || throw(ArgumentError("flanged wall capacity: nlayers must be positive"))
    if As_end > 0
        inset > 0 || throw(ArgumentError(
            "flanged wall capacity: the end-bar centroid is inset from the wall end"))
        2 * inset < lw || throw(ArgumentError(
            "flanged wall capacity: the two end groups overlap (inset $inset on ℓw $lw)"))
    end
    β1 = _beta1_from_fc_psi(fc / Asap.PSI_TO_PA)
    a = min(β1 * c, lw)
    block = _flanged_whitney_block(lw, tw, tf, bf, a, flange_in_compression)
    Cc = 0.85 * fc * block.area
    y_Cc = block.ybar
    mid = lw / 2
    As_l = Ast / nlayers
    extra = _flange_layer_area(lw, tf, nlayers, As_flange, flange_in_compression)
    fc_st = 0.85 * fc
    Fs = 0.0
    Ms = 0.0
    εt = 0.0
    @inbounds for i in 1:nlayers
        y = (i - 0.5) / nlayers * lw
        εs = εcu * (y - c) / c
        fs = clamp(Es * εs, -fy, fy)
        As_i = As_l + extra[i]
        Fi = y < a ? -As_i * (fs + fc_st) : -fs * As_i
        Fs += Fi
        Ms += Fi * (mid - y)
        if y > c
            εt = εs
        end
    end
    if As_end > 0
        for y in (inset, lw - inset)
            εs = εcu * (y - c) / c
            fs = clamp(Es * εs, -fy, fy)
            Fi = y < a ? -As_end * (fs + fc_st) : -fs * As_end
            Fs += Fi
            Ms += Fi * (mid - y)
            y > c && (εt = max(εt, εs))
        end
    end
    Pn = Cc + Fs
    Mn = Cc * (mid - y_Cc) + Ms
    return (Pn = Pn, Mn = abs(Mn), εt = εt, c = c, a = a, block_area = block.area)
end

"""
    wall_flanged_c_at_axial_si(fc, fy, Es, lw, tw, tf, bf, Ast, Nu;
                              flange_in_compression=true, εcu=0.003,
                              nlayers=40, tol=1e-6, As_flange=0, As_end=0,
                              inset=0) -> NamedTuple

Neutral-axis depth where `Pn(c) = Nu`, by the same bisection as
`wall_moment_capacity_at_axial_si`. `As_flange`, `As_end`, and `inset` are
the ones in [`wall_flanged_pm_at_c_si`](@ref). Outside the achievable range,
`converged` is false and `φMn` is zero.
"""
function wall_flanged_c_at_axial_si(fc::Real, fy::Real, Es::Real,
                                   lw::Real, tw::Real, tf::Real, bf::Real,
                                   Ast::Real, Nu::Real;
                                   flange_in_compression::Bool = true,
                                   εcu::Real = 0.003, nlayers::Int = 40, tol::Real = 1e-6,
                                   As_flange::Real = 0.0, As_end::Real = 0.0,
                                   inset::Real = 0.0)
    Pn(c) = wall_flanged_pm_at_c_si(fc, fy, Es, lw, tw, tf, bf, Ast, c;
                                   flange_in_compression = flange_in_compression,
                                   εcu = εcu, nlayers = nlayers,
                                   As_flange = As_flange, As_end = As_end,
                                   inset = inset).Pn
    c_lo = 1e-4 * lw
    c_hi = 2.0 * lw
    P_lo = Pn(c_lo)
    P_hi = Pn(c_hi)
    nexp = 0
    while (P_hi - Nu) < 0 && nexp < 40
        c_hi *= 2
        P_hi = Pn(c_hi)
        nexp += 1
    end
    εty = fy / Es
    if (P_lo - Nu) * (P_hi - Nu) > 0
        return (c = NaN, Pn = Nu, Mn = 0.0, εt = 0.0, εty = εty,
                φ = 0.65, φMn = 0.0, tension_controlled = false, converged = false)
    end
    c = 0.5 * (c_lo + c_hi)
    for _ in 1:100
        c = 0.5 * (c_lo + c_hi)
        Pc = Pn(c)
        if abs(Pc - Nu) < tol * max(abs(Nu), 1.0)
            break
        elseif (Pc - Nu) > 0
            c_hi = c
        else
            c_lo = c
        end
    end
    res = wall_flanged_pm_at_c_si(fc, fy, Es, lw, tw, tf, bf, Ast, c;
                                 flange_in_compression = flange_in_compression,
                                 εcu = εcu, nlayers = nlayers,
                                 As_flange = As_flange, As_end = As_end,
                                 inset = inset)
    φ = wall_phi_flexure(res.εt, εty)
    return (c = res.c, Pn = res.Pn, Mn = res.Mn, εt = res.εt, εty = εty,
            φ = φ, φMn = φ * res.Mn, tension_controlled = res.εt ≥ εty + 0.003,
            converged = true)
end

# ------------------------------------------------------------------------------
# A flange at each end
# ------------------------------------------------------------------------------

# Zones measured from the compression face: the compression flange, the web,
# then the tension flange. A zero thickness contributes nothing. The corner
# where a flange meets the web is the flange width only.
function _two_flange_zones(lw, tw, tf_c, bf_c, tf_t, bf_t)
    stem = lw - tf_c - tf_t
    stem > 0 || throw(ArgumentError(
        "flanged wall: the flanges leave no web between them"))
    return (
        (0.0, tf_c, bf_c),
        (tf_c, tf_c + stem, tw),
        (tf_c + stem, lw, bf_t),
    )
end

# Whitney block from the compression face. Width follows the zone. The
# intersection is not added as web on top of the flange.
function _two_flange_block(zones, a)
    area = 0.0
    moment = 0.0
    for (y0, y1, w) in zones
        a <= y0 && break
        yb = min(a, y1)
        h = yb - y0
        h > 0 || continue
        area += w * h
        moment += w * h * ((y0 + yb) / 2)
    end
    area > 0 || throw(ArgumentError("flanged wall: the stress block has no area"))
    return (area = area, ybar = moment / area)
end

"""
    wall_two_flange_gross_section(lw, tw, tf_pos, bf_pos, tf_neg, bf_neg) -> NamedTuple

Gross area, centroid, and in-plane inertia of a web with a flange at each
end. `x` runs from the negative end to the positive end. `centroid` is
measured from the negative end. A flange whose width is the web thickness
adds no area.

# Citation
ACI 318-19 §18.10.5.2 (corpus: aci-318-19, page 325): the effective flange
is measured from the face of the web. ACI 318-19 §22.2.2.4.1 (page 400):
the compression zone is bounded by the edges of the cross section.
"""
function wall_two_flange_gross_section(lw::Length, tw::Length,
                                      tf_pos::Length, bf_pos::Length,
                                      tf_neg::Length, bf_neg::Length)
    lw_m = ustrip(u"m", lw)
    tw_m = ustrip(u"m", tw)
    tfp = ustrip(u"m", tf_pos)
    tfn = ustrip(u"m", tf_neg)
    bfp = ustrip(u"m", bf_pos)
    bfn = ustrip(u"m", bf_neg)
    (lw_m > 0 && tw_m > 0 && tfp > 0 && tfn > 0 && bfp > 0 && bfn > 0) ||
        throw(ArgumentError(
            "two-flange wall: ℓw, the web, and both flanges must be positive"))
    tfp + tfn < lw_m || throw(ArgumentError(
        "two-flange wall: the flanges leave no web (tf $(tf_pos + tf_neg), ℓw $lw)"))
    (bfp + 1e-12 >= tw_m && bfn + 1e-12 >= tw_m) || throw(ArgumentError(
        "two-flange wall: each flange is at least as wide as the web"))
    stem = lw - tf_pos - tf_neg
    area_pos = bf_pos * tf_pos
    area_neg = bf_neg * tf_neg
    area_stem = tw * stem
    area = area_pos + area_neg + area_stem
    x_neg = tf_neg / 2
    x_stem = tf_neg + stem / 2
    x_pos = lw - tf_pos / 2
    centroid = (area_neg * x_neg + area_stem * x_stem + area_pos * x_pos) / area
    inertia = bf_neg * tf_neg^3 / 12 + area_neg * (x_neg - centroid)^2 +
              tw * stem^3 / 12 + area_stem * (x_stem - centroid)^2 +
              bf_pos * tf_pos^3 / 12 + area_pos * (x_pos - centroid)^2
    return (area = area, centroid = centroid, inertia = inertia, stem = stem)
end

"""
    wall_two_flange_fiber_stress(P, M, lw, tw, tf_pos, bf_pos, tf_neg, bf_neg) -> NamedTuple

Extreme-fiber stress on the gross section with a flange at each end.
Compression is positive. A positive moment compresses the positive end.
"""
function wall_two_flange_fiber_stress(P, M, lw::Length, tw::Length,
                                     tf_pos::Length, bf_pos::Length,
                                     tf_neg::Length, bf_neg::Length)
    section = wall_two_flange_gross_section(lw, tw, tf_pos, bf_pos, tf_neg, bf_neg)
    axial = P / section.area
    at_positive_end = axial + M * (lw - section.centroid) / section.inertia
    at_negative_end = axial - M * section.centroid / section.inertia
    return (
        at_positive_end = at_positive_end,
        at_negative_end = at_negative_end,
        axial = axial,
        section = section,
    )
end

"""
    wall_two_flange_pm_at_c_si(fc, fy, Es, lw, tw, tf_pos, bf_pos, tf_neg, bf_neg,
                              Ast, c; compress_positive=true, εcu=0.003,
                              nlayers=40, As_pos=0, As_neg=0, As_end=0, inset=0)
        -> NamedTuple

Nominal `(Pn, Mn, εt)` at neutral-axis depth `c`, bare SI, compression
positive. `c` and `y` are measured from the compression face. A positive
moment compresses the positive end, so `compress_positive` puts that face
there. The concrete width is the flange width inside each flange and the
web thickness between them. The corner is not counted twice.

`Ast` is the web steel, smeared along ℓw. `As_pos` and `As_neg` are
additional vertical steel in the positive and negative flange zones.
`As_end` is added area at each end, the placement in
`wall_pm_end_bars_at_c_si`. A second flange whose width equals the web and
whose `As` is zero is the one-flange section.

# Citation
ACI 318-19 §22.2.2.4.1 (corpus: aci-318-19, page 400): 0.85f′c over the
zone bounded by the edges of the cross section and a line parallel to the
neutral axis at a = β1 c. The steel idealization is the one in
`wall_pm_at_c_si`.
"""
function wall_two_flange_pm_at_c_si(fc::Real, fy::Real, Es::Real,
                                   lw::Real, tw::Real,
                                   tf_pos::Real, bf_pos::Real,
                                   tf_neg::Real, bf_neg::Real,
                                   Ast::Real, c::Real;
                                   compress_positive::Bool = true,
                                   εcu::Real = 0.003, nlayers::Int = 40,
                                   As_pos::Real = 0.0, As_neg::Real = 0.0,
                                   As_end::Real = 0.0, inset::Real = 0.0)
    (lw > 0 && tw > 0 && tf_pos > 0 && tf_neg > 0 && bf_pos > 0 && bf_neg > 0 &&
        c > 0 && Ast >= 0) || throw(ArgumentError(
        "two-flange wall capacity: lengths and c must be positive, and Ast non-negative"))
    (As_pos >= 0 && As_neg >= 0 && As_end >= 0) || throw(ArgumentError(
        "two-flange wall capacity: flange and end steel areas are non-negative"))
    tf_pos + tf_neg < lw || throw(ArgumentError(
        "two-flange wall capacity: the flanges leave no web"))
    (bf_pos + 1e-12 >= tw && bf_neg + 1e-12 >= tw) || throw(ArgumentError(
        "two-flange wall capacity: each flange is at least as wide as the web"))
    nlayers >= 1 || throw(ArgumentError("two-flange wall capacity: nlayers must be positive"))
    if As_end > 0
        inset > 0 || throw(ArgumentError(
            "two-flange wall capacity: the end-bar centroid is inset from the wall end"))
        2 * inset < lw || throw(ArgumentError(
            "two-flange wall capacity: the two end groups overlap (inset $inset on ℓw $lw)"))
    end
    tf_c, bf_c, As_c = compress_positive ?
        (tf_pos, bf_pos, As_pos) : (tf_neg, bf_neg, As_neg)
    tf_t, bf_t, As_t = compress_positive ?
        (tf_neg, bf_neg, As_neg) : (tf_pos, bf_pos, As_pos)
    β1 = _beta1_from_fc_psi(fc / Asap.PSI_TO_PA)
    a = min(β1 * c, lw)
    # ACI 318-19 §22.2.2.4.1 (corpus: aci-318-19, page 400).
    block = _two_flange_block(_two_flange_zones(lw, tw, tf_c, bf_c, tf_t, bf_t), a)
    Cc = 0.85 * fc * block.area
    y_Cc = block.ybar
    mid = lw / 2
    As_l = Ast / nlayers
    extra = _flange_layer_area(lw, tf_c, nlayers, As_c, true) .+
            _flange_layer_area(lw, tf_t, nlayers, As_t, false)
    fc_st = 0.85 * fc
    Fs = 0.0
    Ms = 0.0
    εt = 0.0
    @inbounds for i in 1:nlayers
        y = (i - 0.5) / nlayers * lw
        εs = εcu * (y - c) / c
        fs = clamp(Es * εs, -fy, fy)
        As_i = As_l + extra[i]
        Fi = y < a ? -As_i * (fs + fc_st) : -fs * As_i
        Fs += Fi
        Ms += Fi * (mid - y)
        if y > c
            εt = εs
        end
    end
    if As_end > 0
        for y in (inset, lw - inset)
            εs = εcu * (y - c) / c
            fs = clamp(Es * εs, -fy, fy)
            Fi = y < a ? -As_end * (fs + fc_st) : -fs * As_end
            Fs += Fi
            Ms += Fi * (mid - y)
            y > c && (εt = max(εt, εs))
        end
    end
    Pn = Cc + Fs
    Mn = Cc * (mid - y_Cc) + Ms
    return (Pn = Pn, Mn = abs(Mn), εt = εt, c = c, a = a, block_area = block.area)
end

"""
    wall_two_flange_c_at_axial_si(fc, fy, Es, lw, tw, tf_pos, bf_pos, tf_neg, bf_neg,
                                 Ast, Nu; compress_positive=true, ...) -> NamedTuple

Neutral-axis depth where `Pn(c) = Nu`, by the same bisection as
[`wall_flanged_c_at_axial_si`](@ref). Outside the achievable range,
`converged` is false and `φMn` is zero.
"""
function wall_two_flange_c_at_axial_si(fc::Real, fy::Real, Es::Real,
                                      lw::Real, tw::Real,
                                      tf_pos::Real, bf_pos::Real,
                                      tf_neg::Real, bf_neg::Real,
                                      Ast::Real, Nu::Real;
                                      compress_positive::Bool = true,
                                      εcu::Real = 0.003, nlayers::Int = 40, tol::Real = 1e-6,
                                      As_pos::Real = 0.0, As_neg::Real = 0.0,
                                      As_end::Real = 0.0, inset::Real = 0.0)
    Pn(c) = wall_two_flange_pm_at_c_si(
        fc, fy, Es, lw, tw, tf_pos, bf_pos, tf_neg, bf_neg, Ast, c;
        compress_positive = compress_positive, εcu = εcu, nlayers = nlayers,
        As_pos = As_pos, As_neg = As_neg, As_end = As_end, inset = inset).Pn
    c_lo = 1e-4 * lw
    c_hi = 2.0 * lw
    P_lo = Pn(c_lo)
    P_hi = Pn(c_hi)
    nexp = 0
    while (P_hi - Nu) < 0 && nexp < 40
        c_hi *= 2
        P_hi = Pn(c_hi)
        nexp += 1
    end
    εty = fy / Es
    if (P_lo - Nu) * (P_hi - Nu) > 0
        return (c = NaN, Pn = Nu, Mn = 0.0, εt = 0.0, εty = εty,
                φ = 0.65, φMn = 0.0, tension_controlled = false, converged = false)
    end
    c = 0.5 * (c_lo + c_hi)
    for _ in 1:100
        c = 0.5 * (c_lo + c_hi)
        Pc = Pn(c)
        if abs(Pc - Nu) < tol * max(abs(Nu), 1.0)
            break
        elseif (Pc - Nu) > 0
            c_hi = c
        else
            c_lo = c
        end
    end
    res = wall_two_flange_pm_at_c_si(
        fc, fy, Es, lw, tw, tf_pos, bf_pos, tf_neg, bf_neg, Ast, c;
        compress_positive = compress_positive, εcu = εcu, nlayers = nlayers,
        As_pos = As_pos, As_neg = As_neg, As_end = As_end, inset = inset)
    φ = wall_phi_flexure(res.εt, εty)
    return (c = res.c, Pn = res.Pn, Mn = res.Mn, εt = res.εt, εty = εty,
            φ = φ, φMn = φ * res.Mn, tension_controlled = res.εt ≥ εty + 0.003,
            converged = true)
end
