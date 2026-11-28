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
                     gravity_seismic::Bool = false,
                     induced_within_strength::Bool = false)
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
    if gravity_seismic || induced_within_strength
        limit = gravity_beam_transverse_limit(sec.d, bar_diameter(sec.bar_size);
                                              Pu = Nu === nothing ? 0.0u"N" : Nu,
                                              Ag = Ag, fc = fc)
        if gravity_seismic && !induced_within_strength
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
        else
            sd = merge(sd, (s_design = min(sd.s_design, limit.spacing),))
        end
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
    _locate_beam!(md, sec)
    return md
end

"""
Centerlines in the beam frame: `x` along the span, `y` across the web, `z` up
from the soffit. Bottom bars share one row. The continuous bars take the
first places in that row and the rest take what remains; which bar is
continuous is not given by the code, so the row is split in order.
"""
function _locate_beam!(md::MemberDetail, sec)
    m(x) = ustrip(u"m", x)
    bw, h = m(_beam_web(sec)), m(sec.h)
    cov = m(sec.cover)
    ds = m(bar_diameter(sec.stirrup_size))
    nb = sec.n_bars
    if nb > 0
        db = m(bar_diameter(sec.bar_size))
        ys = _spread(nb, -(bw / 2 - cov - ds - db / 2), bw / 2 - cov - ds - db / 2)
        integ = findfirst(g -> g.role === :integrity, md.groups)
        bot = findfirst(g -> g.role === :bottom, md.groups)
        n_cont = integ === nothing ? 0 : md.groups[integ].count
        n_rest = bot === nothing ? 0 : md.groups[bot].count
        n_cont + n_rest == nb || throw(ArgumentError(
            "bottom bars are $nb in the section and $(n_cont + n_rest) in the groups"))
        integ !== nothing && (md.groups[integ] = _with_centerlines(md.groups[integ], _wires_at_y(md.groups[integ].path, ys[1:n_cont])))
        bot !== nothing && (md.groups[bot] = _with_centerlines(md.groups[bot], _wires_at_y(md.groups[bot].path, ys[(n_cont + 1):end])))
    end
    top = findfirst(g -> g.role === :top || g.role === :hanger, md.groups)
    if top !== nothing
        g = md.groups[top]
        db = m(bar_diameter(g.bar_size))
        outer = bw / 2 - cov - ds - db / 2
        md.groups[top] = _with_centerlines(g, _wires_at_y(g.path, _spread(g.count, -outer, outer)))
    end
    st = findfirst(g -> g.role === :stirrup, md.groups)
    if st !== nothing
        inset = cov + ds / 2
        hy = bw / 2 - inset
        loop = ((-hy, inset), (hy, inset), (hy, h - inset), (-hy, h - inset))
        g = md.groups[st]
        md.groups[st] = _with_centerlines(g, _wires_at_x(loop, g.x_positions))
    end
    y_half = sec isa RCTBeamSection ? m(sec.bf) / 2 : m(sec.b) / 2
    box = md.outline[1]
    md.solid = (box[1], box[2], -y_half, y_half, 0.0, h)
    return nothing
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

"""
    hogging_bars(sec, Mu, fc, fy) -> (bar_size, n_bars) or nothing

Top bars for a factored negative moment `Mu`.

The compression block for that moment is in the web, so the width is `bw`
(or `b` for a rectangle), not the flange. The section's stored `d` is used
as the depth from the compression face to the top steel. That matches when
the top cover equals the bottom cover.

Returns `nothing` when the moment is zero or the bars do not fit.
"""
function hogging_bars(sec::Union{RCBeamSection, RCTBeamSection}, Mu, fc, fy)
    bw = sec isa RCTBeamSection ? sec.bw : sec.b
    return _hogging_bars(Mu, bw, sec.d, fc, fy)
end

function _hogging_bars(Mu, b, d, fc, fy)
    Mu > zero(Mu) || return nothing
    As = required_reinforcement(Mu, b, d, fc, fy)
    isfinite(ustrip(u"m^2", As)) || return nothing
    As > zero(As) || return nothing
    try
        picked = select_bars(As, b)
        return (picked.bar_size, picked.n_bars)
    catch err
        err isa InterruptException && rethrow()
        return nothing
    end
end

"""
    detail_solid_head_piece(; length, width, depth, d, cover, Mu_neg, ends, fc, fy,
                            λ=1.0, coating=:uncoated) -> MemberDetail

Top bars of one solid-head piece, drawn as a slab of the full rib depth
(`width × depth`), not as a beam cage. The bars are spread across the width.

`Mu_neg` is the piece's own factored hogging envelope. The bars are the area
for that moment on `width` at effective depth `d`, full length, since no
cutoff diagram is stored. `ends` names each end `:face` (a rib leaves the
head there), `:continuous` (another head piece continues), or `:exterior`
(nothing continues). Past a face the bars run a straight development length
ℓd into the rib (§25.4.2); at a continuous end they run half a Class B lap
past the end; at an exterior end they stop at the cover with a 90-degree hook.

No stirrups are placed: two-way shear at the head is the solid-head punching
check. ACI 318-11 §13.3.7 is not used.
"""
function detail_solid_head_piece(; length::Length, width::Length, depth::Length, d::Length,
                                 cover::Length, Mu_neg, ends::Tuple{Symbol, Symbol},
                                 fc, fy, λ::Real = 1.0, coating::Symbol = :uncoated)
    all(e -> e in (:face, :continuous, :exterior), ends) || throw(ArgumentError(
        "a head piece end is :face, :continuous, or :exterior, got $ends"))
    md = MemberDetail(:slab)
    m(x) = ustrip(u"m", x)
    L, h, w, cov = m(length), m(depth), m(width), m(cover)
    (L > 0 && h > 0 && w > 0) || throw(ArgumentError(
        "a head piece needs a positive length, width, and depth"))
    push!(md.notes, "Solid head: a slab of the full rib depth, no stirrups and no T-flange. Two-way shear is the head punching check.")
    push!(md.notes, "The other bar direction is the topping mat. ACI 318-11 §13.3.7 was not used.")
    md.solid = (0.0, L, -w / 2, w / 2, 0.0, h)
    push!(md.outline, (0.0, L, 0.0, h))
    Mu_neg === nothing && return md
    picked = _hogging_bars(Mu_neg, width, d, fc, fy)
    if picked === nothing
        Mu_neg > zero(Mu_neg) && push!(md.warnings,
            "the head piece's hogging moment does not fit top bars in its width")
        return md
    end
    bs, n = picked
    lam = _detailing_λ(λ)
    db = m(bar_diameter(bs))
    z = h - cov - db / 2
    ψt = (z - db / 2) > m(12.0u"inch") ? 1.3 : 1.0
    ℓd = m(straight_development_length(bs, fc, fy, lam; ψt = ψt, coating = coating,
                                       epoxy_close = true, favorable_cover = false))
    half_lap = m(tension_lap_length(bs, fc, fy, lam; as_ratio = 1.0, percent_spliced = 100.0,
                                    ψt = ψt, coating = coating, epoxy_close = true,
                                    favorable_cover = false)) / 2
    reach(e) = e === :face ? ℓd : e === :continuous ? half_lap : -cov
    x0, x1 = -reach(ends[1]), L + reach(ends[2])
    hook = m(hook_centerline_length(bs; angle = 90))
    tail = m(standard_hook(bs; angle = 90).extension)
    hs, he = ends[1] === :exterior, ends[2] === :exterior
    path = NTuple{2, Float64}[]
    hs && push!(path, first(_hook_tail(x0, z, tail, z - cov, -1, +1)))
    push!(path, (x0, z), (x1, z))
    he && push!(path, first(_hook_tail(x1, z, tail, z - cov, -1, -1)))
    shape = hs && he ? :hook_both : hs ? :hook_start : he ? :hook_end : :straight
    # The same bars, spread across the piece as a slab mat in the span
    # direction. One layer, cover in from each side of the width.
    ys = _spread(n, -w / 2 + cov + db / 2, w / 2 - cov - db / 2)
    push!(md.groups, BarGroup(; mark = "H1", role = :top, direction = :primary,
                              bar_size = bs, count = n,
                              length = ((x1 - x0) + (hs + he) * hook) * u"m",
                              shape = shape, path = path,
                              centerlines = _wires_at_y(path, ys),
                              note = "solid-head slab bars, span direction, piece hogging envelope"))
    return md
end

"""
    transverse_steel_per_length(sec, concrete, rebar) -> Area

Volume of closed-stirrup steel per unit length of a beam, at the spacing
[`design_beam_shear`](@ref) returns for no shear demand.

That spacing is the least steel that still meets ACI 318-11 §11.4.6.3 and
§11.4.5.1 (corpus: aci-318-11, PDF p. 174). A factored shear can only place
the stirrups closer. The wire length is the same closed loop the detailing
draws, two 135-degree hooks included.
"""
function transverse_steel_per_length(sec::Union{RCBeamSection, RCTBeamSection}, concrete, rebar)
    bw = _beam_web(sec)
    ds = bar_diameter(sec.stirrup_size)
    w_cl = bw - 2 * sec.cover - ds
    h_cl = sec.h - 2 * sec.cover - ds
    (w_cl > zero(w_cl) && h_cl > zero(h_cl)) || return zero(sec.As)
    sd = design_beam_shear(0.0u"lbf", bw, sec.d, concrete.fc′, rebar.Fy;
                           λ = concrete.λ, stirrup_bar = sec.stirrup_size)
    s = sd.s_design
    s > zero(s) || return zero(sec.As)
    len = _closed_loop_length(ustrip(u"m", w_cl), ustrip(u"m", h_cl), sec.stirrup_size) * u"m"
    return bar_area(sec.stirrup_size) * len / s
end
