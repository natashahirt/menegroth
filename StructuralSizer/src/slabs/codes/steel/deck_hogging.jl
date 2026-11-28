# Negative bending of the concrete on a composite deck.
#
# SDI C-2017 item 12 (corpus: sdi-c-2017, PDF p. 19): in a negative-moment
# region the deck is only a permanent form, and the concrete is designed as
# a conventional reinforced-concrete slab. Item 12 names the coefficient
# method of ACI 318 Section 6.5 as an acceptable analysis. The SDI reference
# list cites ACI 318-14, which is not in the corpus. The coefficients below
# are ACI 318-19 §6.5 (corpus: aci-318-19, PDF pp. 76–77).
#
# The deck is not counted as compression reinforcement (SDI commentary,
# PDF p. 19). The concrete rectangle is the one the caller passes: SDI does
# not say whether that thickness is the topping or the full slab.

const _POSITIVE_DIVISOR = Dict{Symbol,Int}(
    :positive_end_unrestrained => 11,
    :positive_end_integral => 14,
    :positive_interior => 16,
)

const _NEGATIVE_DIVISOR = Dict{Symbol,Int}(
    :negative_exterior_spandrel => 24,
    :negative_exterior_column => 16,
    :negative_first_interior_two_spans => 9,
    :negative_first_interior => 10,
    :negative_other_interior => 11,
)

"""
    deck_coefficient_moment(wu, clear_spans; location, span, service_live,
        service_dead, prismatic, spans_not_exceeding_10_ft=false,
        column_to_beam_stiffness_exceeds_8=false) -> NamedTuple

Factored moment `wu ln² / divisor` from ACI 318-19 Table 6.5.2
(corpus: aci-318-19, PDF p. 76).

`wu` is the factored uniform load on the strip, force per length. `clear_spans`
are the clear span lengths in order. One `wu` is the uniform load §6.5.1(b)
requires; a pattern of unequal loads is not this method.

Applicability, §6.5.1 (PDF p. 76):

- `(a)` `prismatic` must be `true`
- `(b)` the load is the single uniform `wu`
- `(c)` unfactored live load does not exceed three times unfactored dead load
- `(d)` at least two spans
- `(e)` the longer of two adjacent spans is not more than 20 percent longer
  than the shorter

For a negative moment, `ln` is the average of the adjacent clear spans
(Table 6.5.2, footnote 1). At an exterior support there is one adjacent
span, so `ln` is that clear span. `span` is the clear span at an exterior
face, and the left-hand span at an interior support (the support lies
between `span` and `span + 1`).

Divisors:

- positive, end span, discontinuous end unrestrained: 11
- positive, end span, discontinuous end integral with the support: 14
- positive, interior span: 16
- negative, interior face of an exterior support, spandrel beam: 24
- negative, interior face of an exterior support, column: 16
- negative, exterior face of the first interior support, two spans: 9
- negative, exterior face of the first interior support, more than two spans: 10
- negative, face of the other interior supports: 11

Table 6.5.2 also gives `wu ln²/12` at the face of all supports for slabs
with spans not exceeding 10 ft, and for beams whose column-stiffness sum
exceeds eight times the beam stiffness at each end of the span. The table
does not say whether the 10 ft length is the clear span. Pass
`spans_not_exceeding_10_ft=true` or `column_to_beam_stiffness_exceeds_8=true`
when that row applies. Either flag replaces the negative-moment divisor
with 12. A positive moment is unchanged.

§6.5.3 (PDF p. 77): these moments shall not be redistributed.
`redistribution_permitted` is `false`.
"""
function deck_coefficient_moment(wu, clear_spans;
        location::Symbol,
        span::Integer=1,
        service_live,
        service_dead,
        prismatic::Bool,
        spans_not_exceeding_10_ft::Bool=false,
        column_to_beam_stiffness_exceeds_8::Bool=false)
    _coefficient_gates(clear_spans, service_live, service_dead, prismatic)
    n = length(clear_spans)
    negative = haskey(_NEGATIVE_DIVISOR, location)
    positive = haskey(_POSITIVE_DIVISOR, location)
    negative || positive || throw(ArgumentError(
        "Unknown moment location :$location. See deck_coefficient_moment."))
    ln = _moment_clear_span(clear_spans, location, span, n)
    use_12 = negative && (spans_not_exceeding_10_ft || column_to_beam_stiffness_exceeds_8)
    divisor = use_12 ? 12 : (negative ? _NEGATIVE_DIVISOR[location] : _POSITIVE_DIVISOR[location])
    Mu = wu * ln^2 / divisor
    dimension(Mu) == dimension(1u"lbf" * u"ft") || throw(ArgumentError(
        "wu * ln^2 must be a moment. Pass wu as force per length on the strip and ln as a length."))
    return (
        Mu = Mu,
        wu = wu,
        ln = ln,
        divisor = divisor,
        location = location,
        redistribution_permitted = false,
        all_supports_coefficient = use_12,
        deck_as_compression_reinforcement = false,
    )
end

"""
    deck_coefficient_shear(wu, clear_spans; location, span, service_live,
        service_dead, prismatic) -> NamedTuple

Factored shear from ACI 318-19 Table 6.5.4 (corpus: aci-318-19, PDF p. 77).

- `:first_interior`: exterior face of the first interior support,
  `1.15 wu ln / 2`, and `span` must be an end span
- `:other`: face of any other support, `wu ln / 2`

`ln` is the clear span of `span`. The footnote that averages adjacent clear
spans applies to negative moments, not to this table. The §6.5.1 limits
are the same ones `deck_coefficient_moment` enforces.
"""
function deck_coefficient_shear(wu, clear_spans;
        location::Symbol,
        span::Integer,
        service_live,
        service_dead,
        prismatic::Bool)
    _coefficient_gates(clear_spans, service_live, service_dead, prismatic)
    n = length(clear_spans)
    1 <= span <= n || throw(ArgumentError("span $span is outside 1:$n."))
    if location === :first_interior
        _end_span(span, n) || throw(ArgumentError(
            "Table 6.5.4 places 1.15 wu ln/2 at the exterior face of the first interior support, in an end span."))
        factor = 1.15
    elseif location === :other
        factor = 1.0
    else
        throw(ArgumentError("Shear location must be :first_interior or :other."))
    end
    ln = clear_spans[span]
    Vu = factor * wu * ln / 2
    dimension(Vu) == dimension(1u"lbf") || throw(ArgumentError(
        "wu * ln must be a force. Pass wu as force per length on the strip and ln as a length."))
    return (
        Vu = Vu,
        wu = wu,
        ln = ln,
        factor = factor,
        location = location,
        redistribution_permitted = false,
    )
end

"""
    deck_cantilever_moment(wu, length) -> NamedTuple

Moment at the fixed end of a uniformly loaded cantilever, `wu length² / 2`.

This is equilibrium of that load. It is not a row of ACI 318-19 Table 6.5.2.
SDI C-2017 item 13 (corpus: sdi-c-2017, PDF p. 19) says the deck is only a
permanent form at a cantilever and the slab is designed for negative bending
per ACI 318. The commentary says the deck is not compression reinforcement.

ACI 318-19 §7.7.3.3 (PDF p. 97) excepts the free end of a cantilever from
the extension past a theoretical cutoff. A uniform cantilever does not change
sign, so §7.7.3.8.4's extension beyond a point of inflection is not applied
here. The bars at the support still have to be developed on each side of the
section (§7.7.3.1); that development length is not computed.
"""
function deck_cantilever_moment(wu, length)
    ustrip(u"inch", uconvert(u"inch", length)) > 0 || throw(ArgumentError(
        "Cantilever length must be positive."))
    Mu = wu * length^2 / 2
    dimension(Mu) == dimension(1u"lbf" * u"ft") || throw(ArgumentError(
        "wu * length^2 must be a moment. Pass wu as force per length and length as a length."))
    return (
        Mu = Mu,
        equilibrium = true,
        coefficient_method = false,
        deck_as_compression_reinforcement = false,
        development_length_evaluated = false,
    )
end

"""
    deck_negative_reinforcement(Mu, b, d, h, fc, fy, Es, db, clear_span) -> NamedTuple

Tension steel for a negative moment in the concrete on the deck, and the
embedment of one-third of those bars past the point of inflection.

`b`, `d`, and `h` describe the concrete rectangle the caller is designing.
`h` is the gross thickness of that rectangle and `d` is the effective depth
to the negative steel. SDI C-2017 item 12 does not define which concrete
thickness to use, and this function does not add rib concrete or deck steel.

The flexural area comes from `required_reinforcement` (Whitney block,
φ = 0.90). The result is rejected unless the section is tension-controlled:
net tensile strain at least `εty + 0.003`, with `εty = fy / Es`
(ACI 318-19 definition of a tension-controlled section, corpus: aci-318-19,
PDF p. 47). A transition-zone φ is not computed.

`As` is at least `0.0018 Ag`, with `Ag = b h` (ACI 318-19 §7.6.1.1,
PDF p. 94). SDI's commentary on item 12 says temperature and shrinkage
steel will most likely not be enough for negative bending; the flexural
area is still compared with this minimum.

ACI 318-19 §7.7.3.8.4 (PDF p. 98): at least one-third of the negative
moment reinforcement at a support shall extend beyond the point of inflection
by the greatest of `d`, `12 db`, and `ln/16`. Pass the clear span the bars
extend into. §7.7.3.1 and §7.7.3.4 also require a development length on each
side of a section and past a cutoff. That length is ACI 318-19 §25.4 and is
not evaluated (`development_length_evaluated = false`).
"""
function deck_negative_reinforcement(Mu, b, d, h, fc, fy, Es, db, clear_span)
    b_in = ustrip(u"inch", uconvert(u"inch", b))
    d_in = ustrip(u"inch", uconvert(u"inch", d))
    h_in = ustrip(u"inch", uconvert(u"inch", h))
    db_in = ustrip(u"inch", uconvert(u"inch", db))
    ln_in = ustrip(u"inch", uconvert(u"inch", clear_span))
    b_in > 0 && d_in > 0 && h_in > 0 && db_in > 0 && ln_in > 0 || throw(ArgumentError(
        "b, d, h, db, and clear_span must be positive."))
    d_in < h_in || throw(ArgumentError(
        "Effective depth d must be less than the gross thickness h."))
    ustrip(fy / Es) > 0 || throw(ArgumentError("fy / Es must be positive."))

    # ACI 318-19 §7.6.1.1 (corpus: aci-318-19, PDF p. 94): As,min = 0.0018 Ag.
    As_min = 0.0018 * b * h
    As_flex = required_reinforcement(Mu, b, d, fc, fy; εt_min = tension_controlled_strain(fy))
    isfinite(ustrip(u"inch^2", As_flex)) || throw(ArgumentError(
        "The concrete rectangle cannot carry Mu with φ = 0.90. Increase d or f'c."))
    As = max(As_flex, As_min)

    # Tension-controlled: εt ≥ εty + 0.003 (corpus: aci-318-19, PDF p. 47).
    εty = ustrip(fy / Es)
    a = stress_block_depth(As, fc, fy, b)
    c = neutral_axis_depth(a, fc)
    εt = tensile_strain(d, c)
    εt ≥ εty + 0.003 || throw(ArgumentError(
        "Section is not tension-controlled (εt = $(round(εt, digits=5)), " *
        "εty + 0.003 = $(round(εty + 0.003, digits=5))). Increase the effective depth."))

    # ACI 318-19 §7.7.3.8.4 (corpus: aci-318-19, PDF p. 98).
    extension = max(d, 12 * db, clear_span / 16)
    return (
        As = As,
        As_flexure = As_flex,
        As_min = As_min,
        εt = εt,
        fraction_past_inflection = 1/3,
        extension_beyond_inflection = extension,
        development_length_evaluated = false,
        deck_as_compression_reinforcement = false,
    )
end

function _coefficient_gates(clear_spans, service_live, service_dead, prismatic)
    prismatic || throw(ArgumentError(
        "ACI 318-19 §6.5.1(a): members must be prismatic (corpus: aci-318-19, PDF p. 76)."))
    n = length(clear_spans)
    n >= 2 || throw(ArgumentError(
        "ACI 318-19 §6.5.1(d): the coefficient method needs at least two spans."))
    vals = Float64[]
    for s in clear_spans
        x = ustrip(u"inch", uconvert(u"inch", s))
        x > 0 || throw(ArgumentError("Clear spans must be positive."))
        push!(vals, x)
    end
    for i in 1:(n - 1)
        longer = max(vals[i], vals[i + 1])
        shorter = min(vals[i], vals[i + 1])
        longer <= 1.2 * shorter + 1e-8 || throw(ArgumentError(
            "ACI 318-19 §6.5.1(e): adjacent clear spans differ by more than 20 percent of the shorter."))
    end
    service_dead > zero(service_dead) || throw(ArgumentError("Unfactored dead load must be positive."))
    ratio = ustrip(service_live / service_dead)
    ratio <= 3 || throw(ArgumentError(
        "ACI 318-19 §6.5.1(c): unfactored live load exceeds three times unfactored dead load (L/D = $ratio)."))
    return nothing
end

function _end_span(span, n)
    return span == 1 || span == n
end

function _moment_clear_span(clear_spans, location, span, n)
    if location === :negative_first_interior_two_spans
        n == 2 || throw(ArgumentError(
            "wu ln²/9 applies to two spans. This floor has $n."))
        return (clear_spans[1] + clear_spans[2]) / 2
    elseif location === :negative_first_interior
        n > 2 || throw(ArgumentError(
            "wu ln²/10 applies when there are more than two spans."))
        (span == 1 || span == n - 1) || throw(ArgumentError(
            "The first interior support is between spans 1 and 2, or between spans $(n - 1) and $n."))
        return (clear_spans[span] + clear_spans[span + 1]) / 2
    elseif location === :negative_other_interior
        n >= 4 || throw(ArgumentError(
            "An interior support that is not the first one needs at least four spans."))
        1 < span < n - 1 || throw(ArgumentError(
            "span $span is not an interior support between the first interior supports."))
        return (clear_spans[span] + clear_spans[span + 1]) / 2
    elseif location === :negative_exterior_spandrel || location === :negative_exterior_column
        _end_span(span, n) || throw(ArgumentError(
            "An exterior-support moment is on an end span."))
        return clear_spans[span]
    elseif location === :positive_end_unrestrained || location === :positive_end_integral
        _end_span(span, n) || throw(ArgumentError(
            "An end-span positive moment is on span 1 or span $n."))
        return clear_spans[span]
    elseif location === :positive_interior
        1 < span < n || throw(ArgumentError(
            "An interior-span positive moment needs a span that is not an end."))
        return clear_spans[span]
    else
        throw(ArgumentError("Unknown moment location :$location."))
    end
end
