using Unitful

# A flanged wall section for §18.10.6.3 and for the neutral-axis depth
# §18.10.6.2 asks the caller to supply.
#
# The flange is one perpendicular wall at one end of the web. In the plane of
# the web an L and a T with the same flange width and thickness are the same
# section: the offset of an L out of that plane does not move area along ℓw.
# The flange zone is the last `tf` of the web length, and its width is `bf`.
# The intersection is not added twice. `bf == tw` is the rectangular wall.

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

"""
    wall_flanged_pm_at_c_si(fc, fy, Es, lw, tw, tf, bf, Ast, c;
                           flange_in_compression=true, εcu=0.003, nlayers=40) -> NamedTuple

Nominal `(Pn, Mn, εt)` at neutral-axis depth `c`, bare SI, compression
positive. The steel and the Whitney factor are the ones in
`wall_pm_at_c_si`. Only the concrete width changes. `c` and `y` are measured
from the compression face. `flange_in_compression` puts that face at the
flange. `Mn` is about mid-length, returned positive.

# Citation
ACI 318-19 §22.2, the same block and steel idealization as
`wall_pm_at_c_si` (corpus: aci-318-19). The flange width is the gross width,
not a second concrete force.
"""
function wall_flanged_pm_at_c_si(fc::Real, fy::Real, Es::Real,
                                lw::Real, tw::Real, tf::Real, bf::Real,
                                Ast::Real, c::Real;
                                flange_in_compression::Bool = true,
                                εcu::Real = 0.003, nlayers::Int = 40)
    (lw > 0 && tw > 0 && tf > 0 && bf > 0 && c > 0 && Ast >= 0) || throw(ArgumentError(
        "flanged wall capacity: lengths and c must be positive, and Ast non-negative"))
    tf < lw || throw(ArgumentError("flanged wall capacity: tf must be shorter than ℓw"))
    bf + 1e-12 >= tw || throw(ArgumentError(
        "flanged wall capacity: the flange width is at least the web thickness"))
    nlayers >= 1 || throw(ArgumentError("flanged wall capacity: nlayers must be positive"))
    β1 = _beta1_from_fc_psi(fc / Asap.PSI_TO_PA)
    a = min(β1 * c, lw)
    block = _flanged_whitney_block(lw, tw, tf, bf, a, flange_in_compression)
    Cc = 0.85 * fc * block.area
    y_Cc = block.ybar
    mid = lw / 2
    As_l = Ast / nlayers
    fc_st = 0.85 * fc
    Fs = 0.0
    Ms = 0.0
    εt = 0.0
    @inbounds for i in 1:nlayers
        y = (i - 0.5) / nlayers * lw
        εs = εcu * (y - c) / c
        fs = clamp(Es * εs, -fy, fy)
        Fi = y < a ? -As_l * (fs + fc_st) : -fs * As_l
        Fs += Fi
        Ms += Fi * (mid - y)
        if y > c
            εt = εs
        end
    end
    Pn = Cc + Fs
    Mn = Cc * (mid - y_Cc) + Ms
    return (Pn = Pn, Mn = abs(Mn), εt = εt, c = c, a = a, block_area = block.area)
end

"""
    wall_flanged_c_at_axial_si(fc, fy, Es, lw, tw, tf, bf, Ast, Nu;
                              flange_in_compression=true, εcu=0.003,
                              nlayers=40, tol=1e-6) -> NamedTuple

Neutral-axis depth where `Pn(c) = Nu`, by the same bisection as
`wall_moment_capacity_at_axial_si`. Outside the achievable range,
`converged` is false and `φMn` is zero.
"""
function wall_flanged_c_at_axial_si(fc::Real, fy::Real, Es::Real,
                                   lw::Real, tw::Real, tf::Real, bf::Real,
                                   Ast::Real, Nu::Real;
                                   flange_in_compression::Bool = true,
                                   εcu::Real = 0.003, nlayers::Int = 40, tol::Real = 1e-6)
    Pn(c) = wall_flanged_pm_at_c_si(fc, fy, Es, lw, tw, tf, bf, Ast, c;
                                   flange_in_compression = flange_in_compression,
                                   εcu = εcu, nlayers = nlayers).Pn
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
                                 εcu = εcu, nlayers = nlayers)
    φ = wall_phi_flexure(res.εt, εty)
    return (c = res.c, Pn = res.Pn, Mn = res.Mn, εt = res.εt, εty = εty,
            φ = φ, φMn = φ * res.Mn, tension_controlled = res.εt ≥ εty + 0.003,
            converged = true)
end
