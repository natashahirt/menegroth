# ==============================================================================
# Reinforced concrete beams — bars, anchorage, and stirrups (ACI 318-19 Ch. 9)
# ==============================================================================
#
# A beam is detailed alone, support face to support face. Its bars run into
# both supports; at a continuous support the integrity and top bars lap with
# the bars of the next beam inside the joint.
#
# The sizing step keeps peak demands, not a moment and shear diagram. Without
# a diagram, bars are not cut off: top and bottom bars run the full length and
# stirrups keep one spacing, the one the peak shear needs. That is the
# conservative end of §9.7.3 and §9.7.6.
# ==============================================================================

_beam_web(sec::RCBeamSection) = sec.b
_beam_web(sec::RCTBeamSection) = sec.bw

"""
    detail_beam(sec; span, supports, exterior, fc, fy, fyt, Vu, kwargs...) -> MemberDetail

Bars of one rectangular or T-beam between two supports.

# Keywords
- `span`: center-to-center length.
- `supports`: support widths along the beam at the start and end.
- `exterior`: `(start, end)`; `true` where the beam does not continue past
  the support.
- `fc`, `fy`, `fyt`, `λ`, `coating`: materials.
- `Vu`: peak factored shear. `Nu`: signed axial force (compression positive).
- `top_bars`: `(bar_size, n_bars)` of the hogging steel, or `nothing` when
  the beam has no hogging demand.
- `stock`: stock bar length.
- `first_stirrup`: distance from the support face to the first stirrup.

# Bars
- Bottom: all bars run between supports. At an exterior support they run to
  the far face less cover and are hooked where the straight embedment is
  shorter than ℓd (§9.7.3.8.2 asks this only of lateral-system beams; it is
  applied to all). At a continuous support they run 6 in. past the face
  (§9.7.3.8.2 asks it of one-quarter of the bars). `max(2, ⌈n/4⌉)` of them run
  past the support centerline by half a Class B lap so they are continuous with
  the next beam (§9.7.7.1(a), §9.7.7.5).
- Top: the hogging steel, or the compression steel where its area is larger,
  runs the full length. Without a moment diagram the inflection points in
  §9.7.3.8.4 are not known, so the bars are not cut. With no hogging demand
  and no compression steel, two No. 4 hanger bars (or the stirrup size if
  larger) hold the stirrups; the code does not require them. At an exterior
  support top bars end in a 90-degree hook, at a continuous support they lap
  half a Class B lap past the centerline.
- Stirrups: closed two-leg stirrups with 135-degree hooks (§9.7.7.1(c)),
  spacing from the shear design rounded down to 0.5 in., from
  `first_stirrup` past each face.
"""
function detail_beam(sec::Union{RCBeamSection, RCTBeamSection}; span::Length,
                     supports::Tuple, exterior::Tuple{Bool, Bool}, fc, fy, fyt,
                     Vu, λ::Real = 1.0, coating::Symbol = :uncoated, Nu = nothing,
                     top_bars = nothing, stock::Length = 60.0u"ft",
                     first_stirrup::Length = 2.0u"inch",
                     gravity_seismic::Bool = false)
    md = MemberDetail(:beam)
    m(x) = ustrip(u"m", x)
    lam = _detailing_λ(λ)
    c1, c2 = m(supports[1]), m(supports[2])
    ℓn = m(span) - c1 / 2 - c2 / 2
    ℓn > 0 || throw(ArgumentError("supports leave no clear span (span = $span)"))
    bw, h, d, cov = m(_beam_web(sec)), m(sec.h), m(sec.d), m(sec.cover)
    ds = m(bar_diameter(sec.stirrup_size))

    xL1, xR1 = 0.0, c1
    xL2 = xR1 + ℓn
    xR2 = xL2 + c2
    xc1, xc2 = c1 / 2, xL2 + c2 / 2
    total = xR2

    serial = Ref(0)
    function add!(role, bs, count, x0, x1, z, hook_start, hook_end, hook_dir; laps = 0,
                  lap_len = 0.0, note = "")
        (count > 0 && x1 > x0) || return
        hook = m(hook_centerline_length(bs; angle = 90))
        tail = m(standard_hook(bs; angle = 90).extension)
        room = hook_dir < 0 ? z - cov - ds : (h - cov - ds) - z
        path = NTuple{2, Float64}[]
        hook_start && push!(path, first(_hook_tail(x0, z, tail, room, hook_dir, +1)))
        push!(path, (x0, z), (x1, z))
        hook_end && push!(path, first(_hook_tail(x1, z, tail, room, hook_dir, -1)))
        len = (x1 - x0) + (hook_start + hook_end) * hook + laps * lap_len
        shape = hook_start && hook_end ? :hook_both : hook_start ? :hook_start :
                hook_end ? :hook_end : :straight
        serial[] += 1
        push!(md.groups, BarGroup(; mark = "B$(serial[])", role = role, direction = :along,
                                  bar_size = bs, count = count, length = len * u"m",
                                  shape = shape, path = path, laps = laps, note = note))
    end

    # Table 25.4.2.3 first row: sizing keeps clear spacing ≥ d_b (§25.2.1) and
    # stirrups are at least the code minimum, so cover decides the row.
    fav(bs) = cov + ds >= m(bar_diameter(bs))
    lap_b(bs; ψt = 1.0) = m(tension_lap_length(bs, fc, fy, lam; as_ratio = 1.0,
                                               percent_spliced = 100.0, ψt = ψt,
                                               coating = coating, epoxy_close = true,
                                               favorable_cover = fav(bs)))
    ld(bs; ψt = 1.0) = m(straight_development_length(bs, fc, fy, lam; ψt = ψt,
                                                     coating = coating, epoxy_close = true,
                                                     favorable_cover = fav(bs)))
    ldh(bs) = m(hooked_bar_development_length(bs, fc, fy, lam; coating = coating))
    function hook_check!(bs, avail, what)
        ldh(bs) <= avail + 1e-9 || push!(md.warnings,
            "$(what): hooked development ℓdh = $(round(ldh(bs) / 0.0254; digits = 1)) in. " *
            "exceeds the $(round(avail / 0.0254; digits = 1)) in. available in the support (§25.4.3)")
    end

    # ── Bottom bars ────────────────────────────────────────────────────────
    nb, bsb = sec.n_bars, sec.bar_size
    zb = cov + ds + m(bar_diameter(bsb)) / 2
    if nb > 0
        n_cont = min(nb, max(2, cld(nb, 4)))
        half_lap = lap_b(bsb) / 2
        ends = map((1, 2)) do k
            ext, xc, face, far = k == 1 ? (exterior[1], xc1, xR1, xL1 + cov) :
                                          (exterior[2], xc2, xL2, xR2 - cov)
            if ext
                avail = abs(face - far)
                hooked = avail < ld(bsb) - 1e-9
                hooked && hook_check!(bsb, avail, "bottom bars at exterior support $k")
                (far, far, hooked)
            else
                six = m(_SIX_INCH)
                (k == 1 ? face - six : face + six, k == 1 ? xc - half_lap : xc + half_lap, false)
            end
        end
        (a_plain, a_cont, hs), (b_plain, b_cont, he) = ends
        run = b_cont - a_cont
        laps, _ = stock_splices(run * u"m", stock, 2 * half_lap * u"m")
        add!(:integrity, bsb, n_cont, a_cont, b_cont, zb, hs, he, +1; laps = laps,
             lap_len = 2 * half_lap, note = "continuous bottom bars (§9.7.7.1(a))")
        add!(:bottom, bsb, nb - n_cont, a_plain, b_plain, zb, hs, he, +1;
             note = "bottom bars")
    end

    # ── Top bars ───────────────────────────────────────────────────────────
    top = _beam_top_bars(sec, top_bars)
    if top !== nothing
        bst, nt, why = top
        zt = h - cov - ds - m(bar_diameter(bst)) / 2
        ψt = (zt - m(bar_diameter(bst)) / 2) > m(12.0u"inch") ? 1.3 : 1.0
        half_lap = lap_b(bst; ψt = ψt) / 2
        a = exterior[1] ? xL1 + cov : xc1 - half_lap
        b = exterior[2] ? xR2 - cov : xc2 + half_lap
        exterior[1] && hook_check!(bst, c1 - cov, "top bars at exterior support 1")
        exterior[2] && hook_check!(bst, c2 - cov, "top bars at exterior support 2")
        laps, _ = stock_splices((b - a) * u"m", stock, 2 * half_lap * u"m")
        add!(why === :hanger ? :hanger : :top, bst, nt, a, b, zt, exterior[1], exterior[2], -1;
             laps = laps, lap_len = 2 * half_lap,
             note = why === :hanger ? "hanger bars, not required by the code" :
                    why === :compression ? "compression bars, full length" :
                    "hogging bars, full length (no moment diagram for cutoffs)")
    end

    # ── Stirrups ───────────────────────────────────────────────────────────
    Ag = _beam_web(sec) * sec.h
    sd = design_beam_shear(uconvert(u"lbf", Vu), _beam_web(sec), sec.d, fc, fyt;
                           λ = λ, stirrup_bar = sec.stirrup_size,
                           Nu = Nu, Ag = isnothing(Nu) ? nothing : Ag)
    shear_clause = ""
    if gravity_seismic
        limit = gravity_beam_transverse_limit(sec.d, bar_diameter(sec.bar_size);
                                              Pu = Nu === nothing ? 0.0u"N" : Nu,
                                              Ag = Ag, fc = fc)
        seismic = gravity_beam_seismic_shear(sec, ℓn * u"m", Vu, fc, fy;
                                            Nu = Nu === nothing ? 0.0u"N" : Nu)
        if seismic.ok
            sd = design_beam_shear(seismic.Ve, _beam_web(sec), sec.d, fc, fyt;
                                   λ = λ, stirrup_bar = sec.stirrup_size,
                                   Nu = Nu, Ag = Ag,
                                   omit_concrete = seismic.concrete_omitted)
            s_seis = min(sd.s_design, limit.spacing)
            sd = merge(sd, (s_design = s_seis,))
            vc = seismic.concrete_omitted ? "Vc = 0" : "Vc counted"
            shear_clause = ", Ve $(round(ustrip(u"kip", seismic.Ve); digits = 1)) kip, $vc (§18.6.5)"
        else
            push!(md.warnings, "probable moment did not converge; stirrups use the factored shear (§18.6.5)")
            sd = merge(sd, (s_design = min(sd.s_design, limit.spacing),))
        end
        mats = special_moment_frame_materials(fc, fy; lightweight = λ < 1)
        append!(md.warnings, mats.warnings)
        append!(md.notes, mats.notes)
        append!(md.notes, special_frame_splice_notes())
        push!(md.notes, "transverse reinforcement throughout at no more than d/2 (§18.14.3.2(a))")
    end
    sd.section_adequate || push!(md.warnings,
        "shear: Vs required exceeds 8√f′c·bw·d; the section is too small (§22.5.1.2)")
    s = m(sd.s_design)
    if !(s > 0)
        push!(md.warnings, "shear: no positive stirrup spacing satisfies the design")
    else
        x0 = xR1 + m(first_stirrup)
        x1 = xL2 - m(first_stirrup)
        xs = _spaced_positions(x0, x1, s)
        w_cl = bw - 2cov - ds
        h_cl = h - 2cov - ds
        len = _closed_loop_length(w_cl, h_cl, sec.stirrup_size; hook_angle = 135)
        across = bw - 2cov - 2ds
        limit = ustrip(u"lbf", sd.Vs_req) <=
                4 * sqrt(ustrip(u"psi", fc)) * ustrip(u"inch", _beam_web(sec)) * ustrip(u"inch", sec.d) ?
                d : d / 2
        across <= min(limit, m(24.0u"inch")) + 1e-9 || push!(md.warnings,
            "shear: two stirrup legs are $(round(across / 0.0254; digits = 1)) in. apart, " *
            "more than Table 9.7.6.2.2 allows across the width; more legs are needed")
        serial[] += 1
        push!(md.groups, BarGroup(; mark = "B$(serial[])", role = :stirrup, direction = :transverse,
                                  bar_size = sec.stirrup_size, count = length(xs),
                                  length = len * u"m", shape = :closed_stirrup,
                                  path = [(0.0, cov + ds / 2), (0.0, h - cov - ds / 2)],
                                  x_positions = xs,
                                  note = "closed, 135-degree hooks, at $(round(s / 0.0254; digits = 1)) in.$(shear_clause)"))
    end

    # Beam carried past a continuous support as far as its bars run; supports
    # drawn as column stubs one beam depth deep.
    ext = _path_extent(md)
    xa = ext === nothing ? xL1 : min(xL1, ext[1] - cov)
    xb = ext === nothing ? xR2 : max(xR2, ext[2] + cov)
    push!(md.outline, (xa, xb, 0.0, h), (xL1, xR1, -h, 0.0), (xL2, xR2, -h, 0.0))

    push!(md.notes, "No moment diagram is stored, so no bar is cut off and stirrups keep one spacing.")
    sec isa RCTBeamSection && push!(md.notes,
        "Distribution of flange tension bars (§24.3.4) is not detailed.")
    _report_beam_areas!(md, sec, top)
    return md
end

"""
Bottom, top, and stirrup areas.

Bottom ideal area is the section's `As` (the bars selected for the beam).
Top ideal area is the hogging or compression steel; hanger bars are placed
with an ideal area of zero because the code does not require them. Stirrup
area is the two-leg `Av` of the shear design, one stirrup, not the whole run.
"""
function _report_beam_areas!(md, sec, top)
    record_steel_area!(md, "bottom", ustrip(u"inch^2", sec.As),
                       _placed_area_in2(md, :bottom, :integrity); source = "the section As")
    if top !== nothing
        bst, nt, why = top
        placed = nt * ustrip(u"inch^2", bar_area(bst))
        ideal = why === :hanger ? 0.0 : placed
        source = why === :hanger ? "the design; hanger bars are not required" : "the top bars"
        record_steel_area!(md, "top", ideal, placed; source = source)
    end
    Av = 2 * ustrip(u"inch^2", bar_area(sec.stirrup_size))
    placed_st = any(g -> g.role === :stirrup && g.count > 0, md.groups) ? Av : 0.0
    record_steel_area!(md, "stirrup", Av, placed_st; source = "two-leg Av")
    return nothing
end

"""
Top layer of a beam: `(bar_size, n_bars, why)`. `why` is `:hogging`,
`:compression`, or `:hanger`. The larger of the hogging and compression
steel areas is kept, since both sit in the top layer.
"""
function _beam_top_bars(sec, top_bars)
    hog = top_bars === nothing ? nothing : (Int(top_bars[1]), Int(top_bars[2]))
    comp = sec.n_bars_prime > 0 && sec.bar_size_prime > 0 ?
           (sec.bar_size_prime, sec.n_bars_prime) : nothing
    area(t) = t[2] * ustrip(u"inch^2", bar_area(t[1]))
    if hog !== nothing && comp !== nothing
        return area(hog) >= area(comp) ? (hog..., :hogging) : (comp..., :compression)
    end
    hog !== nothing && return (hog..., :hogging)
    comp !== nothing && return (comp..., :compression)
    return (max(4, sec.stirrup_size), 2, :hanger)
end
