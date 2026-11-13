# =============================================================================
# Cracked service shell — geometry and the stiffness scale
# =============================================================================
#
# The story shell is solved gross for strength. Service deflection is a second
# family of solves on the same mesh: each reinforced-concrete span's web and
# the plates inside its flange are scaled to Ie/Ig, and the slab over a
# steel or composite hogging region is scaled the same way. This file holds
# the geometry and the scale. The iteration that re-solves lives with the
# building, because it reads the shell's displacements.

"""One span of a beam polyline, stations in `[0, 1]`."""
struct ShellServiceSpan
    s0::Float64
    s1::Float64
    cantilever::Bool
    n_continuous::Int
    end0_continuous::Bool
    end1_continuous::Bool
end

"""Length of an open plan polyline, in metres."""
function polyline_length(xy)
    n = length(xy)
    n >= 2 || return 0.0
    s = 0.0
    @inbounds for i in 1:(n - 1)
        s += hypot(xy[i + 1][1] - xy[i][1], xy[i + 1][2] - xy[i][2])
    end
    return s
end

"""Unit direction of `xy` at normalized station `s`."""
function polyline_direction(xy, s::Real)
    total = polyline_length(xy)
    total > 0 || return (1.0, 0.0)
    target = clamp(Float64(s), 0.0, 1.0) * total
    acc = 0.0
    @inbounds for i in 1:(length(xy) - 1)
        dx = xy[i + 1][1] - xy[i][1]
        dy = xy[i + 1][2] - xy[i][2]
        L = hypot(dx, dy)
        if acc + L >= target - 1e-9 || i == length(xy) - 1
            return L > 0 ? (dx / L, dy / L) : (1.0, 0.0)
        end
        acc += L
    end
    return (1.0, 0.0)
end

"""
    shell_service_spans(xy, support_xy; tol=0.02) -> Vector{ShellServiceSpan}

Spans of `xy` between supports. A support counts when its plan distance to
the polyline is within `tol` metres.

An end at station 0 or 1 is a simple end. An interior support is continuous.
A free end, with the nearest support inset from the beam end, is a cantilever
back to that support: ACI 318-11 §9.5.2.4 takes the cantilever's inertia at
the support section (corpus: aci-318-11, PDF p. 132).
"""
function shell_service_spans(xy, support_xy; tol::Float64 = 0.02)
    total = polyline_length(xy)
    total > 0 || return ShellServiceSpan[]
    ss = Float64[]
    for p in support_xy
        dist, s = _station_on_polyline(p[1], p[2], xy)
        dist <= tol || continue
        t = clamp(s / total, 0.0, 1.0)
        t = t < 1e-3 ? 0.0 : (t > 1 - 1e-3 ? 1.0 : t)
        push!(ss, t)
    end
    sort!(ss)
    stations = Float64[]
    for s in ss
        (isempty(stations) || s - stations[end] >= 1e-3) && push!(stations, s)
    end
    isempty(stations) && return ShellServiceSpan[]

    spans = ShellServiceSpan[]
    if stations[1] > 1e-3
        push!(spans, ShellServiceSpan(0.0, stations[1], true, 0, false, true))
    end
    for i in 1:(length(stations) - 1)
        a, b = stations[i], stations[i + 1]
        b - a <= 1e-3 && continue
        c0 = a > 1e-3
        c1 = b < 1 - 1e-3
        push!(spans, ShellServiceSpan(a, b, false, Int(c0) + Int(c1), c0, c1))
    end
    if stations[end] < 1 - 1e-3
        push!(spans, ShellServiceSpan(stations[end], 1.0, true, 0, true, false))
    end
    return spans
end

"""
Downward bow of `uz` relative to the chord through the first and last station.

`uz` is the global vertical displacement in metres, positive upward, so a
downward sag is negative. The result is a positive magnitude in metres.
"""
function chord_deflection(stations::AbstractVector{<:Real}, uz::AbstractVector{<:Real})
    n = length(stations)
    n == length(uz) || throw(ArgumentError("stations and displacements differ in length"))
    n <= 1 && return 0.0
    s0, s1 = stations[1], stations[end]
    u0, u1 = uz[1], uz[end]
    worst = 0.0
    for i in 1:n
        t = s1 == s0 ? 0.0 : (stations[i] - s0) / (s1 - s0)
        chord = u0 + t * (u1 - u0)
        worst = max(worst, -(uz[i] - chord))
    end
    return worst
end

"""
    slab_strip_inertia_ratio(Ma, As, h, d, Ec, Es, fr) -> Float64

`Ie/Ig` of a slab strip of unit width.

`Ma` is the service moment per unit width (N·m/m, top in tension), `As` the
top steel per unit width (m²/m), `h` and `d` in metres, and the moduli and
`fr` in pascals. The ratio is Eq. (9-8) with `Mcr` from Eq. (9-9)
(ACI 318-11 §9.5.2.3, corpus: aci-318-11, PDF p. 132). A strip that is not
in tension, or that has no top steel, stays at 1.

# ENGINEERING JUDGMENT
The strip is one metre wide so the ratio does not depend on how wide a
flange the caller assigns. `Ig` is the gross concrete section; the steel is
not transformed into it.
"""
function slab_strip_inertia_ratio(Ma::Real, As::Real, h::Real, d::Real,
                                  Ec::Real, Es::Real, fr_::Real)
    (Ma <= 0 || As <= 0 || h <= 0 || d <= 0) && return 1.0
    b = 1.0u"m"
    hq = h * u"m"
    Ig = uconvert(u"m^4", b * hq^3 / 12)
    # `As` is already per metre, so a one-metre strip has that area.
    Icr = uconvert(u"m^4", cracked_moment_of_inertia(
        As * u"m^2", b, d * u"m", Ec * u"Pa", Es * u"Pa"))
    Mcr = fr_ * u"Pa" * Ig / (hq / 2)
    Ie = effective_moment_of_inertia(Mcr, Ma * u"N*m", Ig, Icr)
    Ig_m = ustrip(u"m^4", Ig)
    Ig_m > 0 || return 1.0
    return clamp(ustrip(u"m^4", uconvert(u"m^4", Ie)) / Ig_m, 0.0, 1.0)
end

"""Same section with `E` and `G` multiplied by `k`. Area, inertia, and density stay."""
function section_scaled_moduli(sec::Asap.Section, k::Real)
    k == 1 && return sec
    return Asap.Section(sec.A, sec.E * k, sec.G * k, sec.Ix, sec.Iy, sec.J, sec.ρ;
                        Ay = sec.Ay, Az = sec.Az)
end

"""
Write `shell_k` onto each plate's modulus and `frame_k` onto each frame's
`E` and `G`, always from the stored gross values.

Scaling `E` (and `G`) rather than thickness keeps self-weight and the
membrane area. Bending stiffness of a plate goes with `E t³`, so the factor
`Ie/Ig` lands on `E`. Density is left alone.
"""
function apply_service_scales!(shells, frames, shell_k, frame_k, base_E, base_sections)
    length(shell_k) == length(shells) || throw(ArgumentError(
        "shell scale has $(length(shell_k)) entries for $(length(shells)) plates"))
    length(frame_k) == length(frames) || throw(ArgumentError(
        "frame scale has $(length(frame_k)) entries for $(length(frames)) frames"))
    @inbounds for i in eachindex(shells)
        shells[i].E = base_E[i] * shell_k[i]
    end
    @inbounds for i in eachindex(frames)
        frames[i].section = section_scaled_moduli(base_sections[i], frame_k[i])
    end
    return nothing
end
