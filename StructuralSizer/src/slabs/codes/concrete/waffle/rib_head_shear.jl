# One-way shear of a rib leaving a solid head, and the three head checks together.
#
# ACI 318-11 §11.11.1.1 (corpus: aci-318-11, page 200) sends beam action to
# §11.1 through §11.4. §11.1.3.1 (page 166) places that section at d from the
# face of the support. The face here is the solid head. The 10 percent
# increase is [`Vc_joist`](@ref), and only when §8.13.2 and §8.13.3 are met.

"""
    check_rib_shear_at_head(Vu, bw, d, fc, joist; λ=1.0, φ=0.75) -> NamedTuple

One-way shear of one rib at d from the head face.

`Vu` is the factored shear on that rib at the section. `joist` is the
[`JoistConstruction`](@ref) when the rib is joist construction, and `nothing`
when it is an ordinary beam. The 1.10 factor is applied only by `Vc_joist`.
`λ` is the lightweight-concrete factor of §8.6.1 (Eq. 11-3).
"""
function check_rib_shear_at_head(Vu::Force, bw::Length, d::Length, fc::Pressure,
                                 joist::Union{Nothing, JoistConstruction} = nothing;
                                 λ::Float64 = 1.0, φ::Float64 = 0.75)
    plain = Vc_beam(bw, d, fc; λ)
    Vc = joist === nothing ? plain : Vc_joist(joist, bw, d, fc; λ)
    chk = check_one_way_shear(Vu, Vc; φ = φ)
    return (
        ok = chk.ok,
        ratio = chk.ratio,
        Vu = Vu,
        Vc = Vc,
        φVc = φ * Vc,
        joist_increase = !(Vc ≈ plain),
        section = :rib_one_way,
    )
end

"""
    check_rib_hogging_at_head(Mu, bw, d, fc, fy; stem=nothing) -> NamedTuple

Compression in the rib stem at the face of the solid head, under hogging.

The topping is in tension, so the Whitney block is bounded by the rib width.
ACI 318-11 §10.2.7 (corpus: aci-318-11, page 140). The capacity is the
tension-controlled limit of that rectangle: εt = 0.005 (§10.3.4, page 142)
and φ = 0.90 (§9.3.2.1, page 126), from [`max_singly_reinforced`](@ref).
More top steel would leave that limit.

`Mu` is the hogging moment at the face. `stem` is the rib depth below the
topping. When the block at this limit is deeper than `stem`, it enters the
topping, this width is not the section, and the check does not govern.
"""
function check_rib_hogging_at_head(Mu::Moment, bw::Length, d::Length, fc::Pressure,
                                  fy::Pressure; stem::Union{Nothing, Length} = nothing)
    Mu >= zero(Mu) || throw(ArgumentError(
        "the hogging moment is the positive component, got $Mu"))
    cap = max_singly_reinforced(bw, d, fc, fy)
    # §9.3.2.1 at the §10.3.4 limit. flexure_phi(0.005) is 0.90.
    φMn = flexure_phi(0.005) * cap.Mn_max
    if stem !== nothing && cap.a_max > stem
        return (
            ok = true,
            ratio = 0.0,
            Mu = Mu,
            φMn = φMn,
            in_stem = false,
            section = :rib_hogging,
        )
    end
    ratio = ustrip(u"N*m", Mu) / ustrip(u"N*m", φMn)
    return (
        ok = Mu <= φMn,
        ratio = ratio,
        Mu = Mu,
        φMn = φMn,
        in_stem = true,
        section = :rib_hogging,
    )
end

"""
    check_solid_head_punching(col, Vu, Mub, d_head, h_head, fc, ribs; kwargs...)
        -> NamedTuple

Column punching, rib-web punching, and one-way shear of each rib leaving the head.

`ribs` is a collection with `Vu`, `bw`, `d`, and optionally `joist` and
`outward`. The governing ratio is the largest of the three checks. `ok`
requires every one. `Vu` is the demand of the governing check. `direction` is the outward plan direction of the governing rib when one-way
shear or stem compression governs and that rib names one direction. When
column punching governs, it is that check's peak face, and only when one
vertex is strictly the peak. The rib-web section does not name a direction.
`fy` runs the hogging check on each rib that carries `Mu`.
"""
function check_solid_head_punching(col, Vu, Mub, d_head, h_head, fc, ribs;
                                  Muy = nothing,
                                  b0::Length, web_area::Area, head_width::Length,
                                  side_long::Length, side_short::Length,
                                  position::Symbol,
                                  qu::Union{Nothing, Pressure} = nothing,
                                  section_area::Union{Nothing, Area} = nothing,
                                  λ::Float64 = 1.0, φ::Float64 = 0.75,
                                  fy::Union{Nothing, Pressure} = nothing,
                                  column_kwargs...)
    isempty(ribs) && throw(ArgumentError(
        "each rib leaving the solid head needs its one-way shear at d from the head face"))
    column = check_solid_head_column_punching(col, Vu, Mub, d_head, h_head, fc;
                                              Muy = Muy, λ = λ, φ_shear = φ, column_kwargs...)
    outer = check_rib_web_punching(Vu, b0, web_area, head_width, fc;
                                   d_size = d_head,
                                   side_long = side_long, side_short = side_short,
                                   position = position, qu = qu, section_area = section_area,
                                   λ = λ, φ = φ)
    one_way = map(ribs) do rib
        joist = hasproperty(rib, :joist) ? rib.joist : nothing
        chk = check_rib_shear_at_head(rib.Vu, rib.bw, rib.d, fc, joist; λ = λ, φ = φ)
        outward = hasproperty(rib, :outward) ? rib.outward : nothing
        return merge(chk, (outward = outward,))
    end
    rib_ratio = maximum(r.ratio for r in one_way)
    hogging = NamedTuple[]
    if fy !== nothing
        for rib in ribs
            hasproperty(rib, :Mu) || continue
            stem = hasproperty(rib, :stem) ? rib.stem : nothing
            chk = check_rib_hogging_at_head(rib.Mu, rib.bw, rib.d, fc, fy; stem = stem)
            outward = hasproperty(rib, :outward) ? rib.outward : nothing
            push!(hogging, merge(chk, (outward = outward,)))
        end
    end
    hog_ratio = isempty(hogging) ? 0.0 : maximum(r.ratio for r in hogging)
    if column.ratio >= outer.ratio && column.ratio >= rib_ratio && column.ratio >= hog_ratio
        governing = :column
        ratio = column.ratio
        Vu_gov = Vu
        # The column check names a face only when one vertex is strictly the
        # peak and each axis moment stress is at least 2% of Vu/(b₀ d). A
        # tied face, a moment that does not move the peak, and the rib-web
        # section leave this empty.
        direction = hasproperty(column, :direction) ? column.direction : nothing
    elseif outer.ratio >= rib_ratio && outer.ratio >= hog_ratio
        governing = :rib_web
        ratio = outer.ratio
        Vu_gov = outer.Vu
        direction = nothing
    elseif rib_ratio >= hog_ratio
        governing = :rib_one_way
        ratio = rib_ratio
        i = argmax([r.ratio for r in one_way])
        Vu_gov = one_way[i].Vu
        # The one-way section sits on the rib that leaves the head. `outward`
        # is that rib's plan direction, measured by the caller. Two governing
        # ribs that leave in different directions do not name one side.
        direction = _one_way_growth_direction(one_way)
    else
        governing = :rib_hogging
        ratio = hog_ratio
        i = argmax([r.ratio for r in hogging])
        Vu_gov = Vu
        direction = _one_way_growth_direction(hogging)
    end
    Mu_gov = governing === :rib_hogging ? hogging[i].Mu : 0.0u"N*m"
    ok = column.ok && outer.ok && all(r.ok for r in one_way) && all(r.ok for r in hogging)
    return (
        ok = ok,
        ratio = ratio,
        governing = governing,
        Vu = Vu_gov,
        Mu = Mu_gov,
        direction = direction,
        column = column,
        rib_web = outer,
        ribs = one_way,
        hogging = hogging,
    )
end

"""The shared outward direction of the governing ribs, or `nothing`."""
function _one_way_growth_direction(one_way)
    isempty(one_way) && return nothing
    best = maximum(r.ratio for r in one_way)
    # ENGINEERING JUDGMENT: ribs within 2% of the governing ratio do not name a
    # side. An exact tie (1e-9) lets a rounding difference grow the head one
    # way around a column whose ribs are essentially the same.
    band = max(1e-6, 0.02 * best)
    facing = [r for r in one_way if r.ratio >= best - band]
    dir = nothing
    for r in facing
        r.outward === nothing && return nothing
        hypot(r.outward...) > 1e-12 || return nothing
        if dir === nothing
            dir = r.outward
        else
            a = hypot(dir...)
            b = hypot(r.outward...)
            ua = (dir[1] / a, dir[2] / a)
            ub = (r.outward[1] / b, r.outward[2] / b)
            hypot(ua[1] - ub[1], ua[2] - ub[2]) <= 1e-6 || return nothing
        end
    end
    return dir
end

"""
    govern_solid_head_checks(column, one_way, hogging; Vu) -> NamedTuple

The governing check among column punching, rib one-way shear, and stem
compression.

`column` is the general critical section: `ok`, `ratio`, and `direction`.
Rib-web eccentric shear is not included. Moment transfer through the rib
webs outside the head is not covered by a code clause. `Vu` is the shear
on the column section. When stem compression governs, `Mu` is that moment
and `Vu` stays the column shear.
"""
function govern_solid_head_checks(column, one_way, hogging; Vu::Force)
    rib_ratio = isempty(one_way) ? 0.0 : maximum(r.ratio for r in one_way)
    hog_ratio = isempty(hogging) ? 0.0 : maximum(r.ratio for r in hogging)
    if column.ratio >= rib_ratio && column.ratio >= hog_ratio
        governing = :column
        ratio = column.ratio
        Vu_gov = Vu
        direction = column.direction
        Mu_gov = 0.0u"N*m"
    elseif rib_ratio >= hog_ratio
        governing = :rib_one_way
        ratio = rib_ratio
        isempty(one_way) && throw(ArgumentError(
            "one-way shear governs and no rib leaves the solid head"))
        i = argmax([r.ratio for r in one_way])
        Vu_gov = one_way[i].Vu
        direction = _one_way_growth_direction(one_way)
        Mu_gov = 0.0u"N*m"
    else
        governing = :rib_hogging
        ratio = hog_ratio
        isempty(hogging) && throw(ArgumentError(
            "stem compression governs and no rib carries a hogging moment"))
        i = argmax([r.ratio for r in hogging])
        Vu_gov = Vu
        direction = _one_way_growth_direction(hogging)
        Mu_gov = hogging[i].Mu
    end
    ok = column.ok && all(r.ok for r in one_way) && all(r.ok for r in hogging)
    return (
        ok = ok,
        ratio = ratio,
        governing = governing,
        Vu = Vu_gov,
        Mu = Mu_gov,
        direction = direction,
        column = column,
        ribs = one_way,
        hogging = hogging,
    )
end
