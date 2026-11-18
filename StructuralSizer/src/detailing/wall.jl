# ==============================================================================
# Cast-in-place wall bar placement
# ==============================================================================
#
# Turns a smeared ratio (ρl, ρt) into bar groups. The provided ratio is never
# below the ratio that was passed in. Citations are ACI 318-19 (corpus:
# aci-318-19) unless a line says otherwise.
# ==============================================================================

"""
    detail_wall(; length, height, thickness, ρl, ρt, openings, curtains,
                cover, bar_sizes, spacing_step, Vu, shear_reinforcement_required,
                ends, below, above, slab_above, slab_cover, foundation_depth,
                fc, fy, λ, coating, stock, special, hw, boundary_zones,
                critical_reach) -> MemberDetail

Place the bars of one cast-in-place wall story.

`length` is ℓw, `height` is the story height, `thickness` is h. `openings`
are `(s0, z0, width, height)` from the start of the wall and the base.
`ends` is `(:free, :free)` or `:joined` where another wall frames in.
`below` is `:foundation` or `:wall`. `above` is `:roof` or `:wall`.
`hw` is the height of the whole wall stack; it defaults to `height`.

`special = true` applies §18.10.2 on top of Chapter 11. `boundary_zones`
are the §18.10.6.4 lengths, measured from each end of the wall. Each entry
is `(zone, bar, spacing)`: the element length, the longitudinal bar size,
and the longitudinal spacing. A bar size of 0 uses the web vertical bar.
Hoops and crossties are placed over those lengths. With no zone, the
boundary bars are not placed.
"""
function detail_wall(; length::Length, height::Length, thickness::Length,
                     ρl::Real, ρt::Real,
                     openings = Tuple{Length, Length, Length, Length}[],
                     curtains::Symbol = :auto,
                     cover::Length = 0.75u"inch",
                     bar_sizes::Tuple = (4, 5, 6),
                     spacing_step::Length = 0.5u"inch",
                     Vu::Union{Force, Nothing} = nothing,
                     shear_reinforcement_required::Bool = false,
                     ends::Tuple{Symbol, Symbol} = (:free, :free),
                     below::Symbol = :foundation,
                     above::Symbol = :roof,
                     slab_above::Length = 0.0u"inch",
                     slab_cover::Length = 0.75u"inch",
                     foundation_depth::Union{Length, Nothing} = nothing,
                     fc::Pressure, fy::Pressure,
                     λ::Real = 1.0, coating::Symbol = :uncoated,
                     stock::Length = 60.0u"ft",
                     special::Bool = false,
                     hw::Union{Length, Nothing} = nothing,
                     boundary_zones::AbstractVector = NamedTuple[],
                     critical_reach::Union{Length, Nothing} = nothing)
    foreach(e -> e in (:free, :joined) || throw(ArgumentError(
        "wall end must be :free or :joined, got :$e")), ends)
    below in (:foundation, :wall) || throw(ArgumentError(
        "below must be :foundation or :wall, got :$below"))
    above in (:roof, :wall) || throw(ArgumentError(
        "above must be :roof or :wall, got :$above"))
    curtains in (:auto, :one, :two) || throw(ArgumentError(
        "curtains must be :auto, :one, or :two, got :$curtains"))
    ρl >= 0 && ρt >= 0 || throw(ArgumentError("reinforcement ratios must be ≥ 0"))

    md = MemberDetail(:wall)
    Lm = ustrip(u"m", length)
    Hm = ustrip(u"m", height)
    tm = ustrip(u"m", thickness)
    (Lm > 0 && Hm > 0 && tm > 0) || throw(ArgumentError(
        "wall length, height, and thickness must be positive"))
    hw_m = hw === nothing ? Hm : ustrip(u"m", hw)
    lam = _detailing_λ(λ)
    cover_m = ustrip(u"m", cover)
    step_m = ustrip(u"m", spacing_step)
    step_m > 0 || throw(ArgumentError("spacing step must be positive"))

    holes = _wall_openings_m(openings, Lm, Hm, md)
    Vc = _wall_concrete_shear(fc, lam, hw_m * u"m", length, thickness)
    plain = Vc.plain
    if Vu !== nothing && ustrip(u"N", Vu) > ustrip(u"N", WALL_PHI_SHEAR * Vc.with_αc)
        shear_reinforcement_required = true
    end
    # ACI 318-19 §18.10.2.2 (corpus: aci-318-19, p. 320): two curtains if
    # Vu > 2λ√f′c·Acv or hw/ℓw ≥ 2. §11.7.2.3 (p. 174): two layers when h > 10 in.
    ncurt = _wall_curtain_count(thickness, curtains, special, Vu, plain, hw_m / Lm)
    ncurt == 2 && push!(md.notes, "two layers, one near each face")
    ncurt == 1 && push!(md.notes, "one layer")

    ρl_use, ρt_use = _wall_ratios(md, ρl, ρt, special, Vu, plain)
    # Spacing caps, §11.7.2.1 and §11.7.3.1 (pp. 173–174): min(3h, 18 in.),
    # and ℓw/3 or ℓw/5 when shear reinforcement is required for strength.
    # §18.10.2.1 (p. 320) also caps both ways at 18 in.
    cap_v = _wall_spacing_cap(thickness, length, :vertical, shear_reinforcement_required)
    cap_h = _wall_spacing_cap(thickness, length, :horizontal, shear_reinforcement_required)
    vert = _wall_pick_bars(ρl_use, thickness, ncurt, cap_v, bar_sizes, step_m, md, "vertical")
    horiz = _wall_pick_bars(ρt_use, thickness, ncurt, cap_h, bar_sizes, step_m, md, "horizontal")

    lap_v = vert === nothing ? 0.0u"m" : _wall_lap(vert.size, fc, fy, lam, coating, cover)
    if vert !== nothing
        _place_verticals!(md, vert, ncurt, Lm, Hm, cover_m, holes, lap_v, above,
                          slab_above, slab_cover, fc, fy, lam, coating, stock)
        _place_section_dots!(md, vert, ncurt, tm, cover_m)
    end
    if horiz !== nothing
        hook_free = _wall_hook_free_ends(special, Vu, plain)
        !special && hook_free && push!(md.notes,
            "standard hooks on free horizontal ends are detailing practice; " *
            "§18.10.6.5 requires them for special walls")
        _place_horizontals!(md, horiz, ncurt, Lm, Hm, cover_m, holes, ends, hook_free,
                            fc, fy, lam, coating, stock)
    end
    _place_trim!(md, holes, ncurt, Lm, Hm, cover_m, fc, fy, lam, coating)
    if !isempty(holes)
        push!(md.warnings,
            "the wall over an opening is not designed as a beam; no lintel bars are added")
    end
    below === :foundation && vert !== nothing && _place_dowels!(
        md, vert, ncurt, cover_m, foundation_depth, fc, fy, lam, coating, lap_v)
    placed_boundary = false
    if special && vert !== nothing && !isempty(boundary_zones)
        reach = something(critical_reach, length)
        for zone in boundary_zones
            placed_boundary |= _place_boundary_hoops!(
                md, zone, vert, Lm, Hm, tm, cover, fy, reach)
        end
    end
    _wall_tie_warning!(md, ρl_use, fy, special, placed_boundary)
    if special
        push!(md.notes,
            "§18.10.2.3's 12 ft extension is not placed: the uniform ratio has no flexural cutoff.")
        placed_boundary || push!(md.notes,
            "§18.10.6.4 boundary bars are not placed: the neutral-axis depth is not on the design.")
    end

    push!(md.outline, (0.0, Lm, 0.0, Hm))
    slab_m = ustrip(u"m", slab_above)
    slab_m > 0 && push!(md.outline, (0.0, Lm, Hm, Hm + slab_m))
    if below === :foundation && foundation_depth !== nothing
        d = ustrip(u"m", foundation_depth)
        d > 0 && push!(md.outline, (0.0, Lm, -d, 0.0))
    elseif below === :wall
        push!(md.outline, (0.0, Lm, -min(ustrip(u"m", lap_v), Hm), 0.0))
    end
    for (x0, x1, z0, z1) in holes
        push!(md.voids, (x0, x1, z0, z1))
    end
    _report_wall_areas!(md, ρl_use, ρt_use, length, height, thickness)
    _locate_wall!(md, ncurt, Lm, Hm, tm, cover_m, vert === nothing ? 0.0 : ustrip(u"m", bar_diameter(vert.size)))
    return md
end

"""
Centerlines in the wall frame: `x` along the wall, `y` through the thickness,
`z` up. Each curtain is the layer already used for the plan dots.
"""
function _locate_wall!(md::MemberDetail, ncurt::Int, L, H, t, cover, db)
    ys = ncurt == 1 ? [0.0] : [-(t / 2 - cover - db / 2), t / 2 - cover - db / 2]
    for i in eachindex(md.groups)
        g = md.groups[i]
        wires = Vector{NTuple{3, Float64}}[]
        if !isempty(g.x_positions)
            for x in g.x_positions, y in ys
                push!(wires, [(x + p[1], y, p[2]) for p in g.path])
            end
        elseif !isempty(g.z_positions)
            for z in g.z_positions, y in ys
                push!(wires, [(p[1], y, p[2] + z) for p in g.path])
            end
        else
            continue
        end
        md.groups[i] = _with_centerlines(g, wires)
    end
    md.solid = (0.0, L, -t / 2, t / 2, 0.0, H)
    return nothing
end

# ------------------------------------------------------------------------------
# Limits
# ------------------------------------------------------------------------------

"""Concrete shear terms of Eq. 11.5.4.3 with ρt = 0, in force units.

`with_αc` is αc·λ·√f′c·Acv. `plain` is λ·√f′c·Acv, the §18.10 term that does
not include αc. ACI 318-19 §11.5.4.3 and §18.10.2.1–2 (corpus: aci-318-19,
pp. 172 and 320).
"""
function _wall_concrete_shear(fc, λ, hw, lw, t)
    αc = wall_alpha_c(ustrip(u"m", lw) > 0 ? ustrip(u"m", hw) / ustrip(u"m", lw) : Inf)
    Acv = ustrip(u"inch", t) * ustrip(u"inch", lw) * u"inch^2"
    plain = lambda_sqrt_fc_Acv(λ, fc, Acv)
    return (with_αc = αc * plain, plain = plain)
end

function _wall_curtain_count(thickness, curtains, special, Vu, plain, hw_over_lw)
    curtains === :one && return 1
    curtains === :two && return 2
    n = ustrip(u"inch", thickness) > 10 ? 2 : 1
    if special && (hw_over_lw >= 2 || (Vu !== nothing && ustrip(u"N", Vu) > ustrip(u"N", 2 * plain)))
        n = 2
    end
    return n
end

function _wall_ratios(md, ρl, ρt, special, Vu, plain)
    ρl_use, ρt_use = Float64(ρl), Float64(ρt)
    special || return ρl_use, ρt_use
    # §18.10.2.1: both ratios at least 0.0025, except ρt may be the §11.6
    # value when Vu ≤ λ√f′c·Acv.
    if ρl_use < 0.0025
        ρl_use = 0.0025
        push!(md.notes, "vertical ratio raised to 0.0025 (§18.10.2.1)")
    end
    low_shear = Vu !== nothing && ustrip(u"N", Vu) <= ustrip(u"N", plain)
    if ρt_use < 0.0025 && !low_shear
        ρt_use = 0.0025
        push!(md.notes, "horizontal ratio raised to 0.0025 (§18.10.2.1)")
    end
    return ρl_use, ρt_use
end

function _wall_spacing_cap(thickness, length, direction, shear_required)
    # min(3h, 18 in.); shear strength adds ℓw/3 (vertical) or ℓw/5 (horizontal).
    cap = min(3 * ustrip(u"m", thickness), ustrip(u"m", 18.0u"inch"))
    if shear_required
        lw = ustrip(u"m", length)
        cap = min(cap, direction === :vertical ? lw / 3 : lw / 5)
    end
    return cap
end

"""
Smallest bar in `sizes` whose spacing, rounded down to `step`, provides at
least `ρ` and does not exceed `cap`. Returns `nothing` when `ρ` is 0.
"""
function _wall_pick_bars(ρ, thickness, ncurt, cap, sizes, step, md, word)
    ρ <= 0 && return nothing
    h = ustrip(u"m", thickness)
    chosen = nothing
    for size in sizes
        Ab = ustrip(u"m^2", bar_area(size))
        s_raw = ncurt * Ab / (ρ * h)
        s = _floor_step(min(s_raw, cap), step)
        s <= cap + 1e-9 || continue
        ρ_prov = ncurt * Ab / (s * h)
        ρ_prov + 1e-12 >= ρ || continue
        chosen = (size = size, spacing = s, ρ = ρ_prov)
        break
    end
    if chosen === nothing
        size = sizes[end]
        Ab = ustrip(u"m^2", bar_area(size))
        s = _floor_step(cap, step)
        chosen = (size = size, spacing = s, ρ = ncurt * Ab / (s * h))
        push!(md.warnings, "$word spacing cap $(round(cap; digits = 4)) m is exceeded " *
            "at the largest bar; #$(size) is placed at $(round(s; digits = 4)) m")
    end
    push!(md.notes, "$word #$(chosen.size) at $(round(ustrip(u"inch", chosen.spacing * u"m"); digits = 2)) in, " *
        "ρ provided $(round(chosen.ρ; digits = 5))")
    return chosen
end

_floor_step(s, step) = max(floor(Int, s / step + 1e-9), 1) * step

"""Longer of the compression lap and the Class B tension lap.

The bar force is not kept, so neither lap is ruled out. Same choice as
[`column_lap_length`](@ref). Table 25.5.2.1 and §25.5.5.1 (corpus:
aci-318-19, pp. 489 and 492).
"""
function _wall_lap(bar_size, fc, fy, λ, coating, cover)
    fav = cover >= bar_diameter(bar_size)
    return uconvert(u"m", max(
        compression_lap_length(bar_size, fc, fy; λ = λ, coating = coating),
        tension_lap_length(bar_size, fc, fy, λ; as_ratio = 1.0, percent_spliced = 100.0,
                           coating = coating, favorable_cover = fav)))
end

"""
Closed hoops and crossties over one boundary element, at both ends of the wall.

`zone.zone` is the §18.10.6.4 length from the wall end. `zone.bar` is the
longitudinal bar; 0 uses the web vertical. `zone.spacing` is that bar's
spacing. A hoop leg is at most twice the wall thickness (§18.10.6.4(f)).
A longer element is covered by overlapping hoops. A crosstie crosses the
thickness at every longitudinal station that is not a hoop corner.

The vertical spacing is §18.10.6.4(e). Inside `reach`, which the caller
sets to the greater of ℓw and Mu/(4Vu), the Table 18.10.6.5(b) limit is
the tighter one.
"""
function _place_boundary_hoops!(md, zone, vert, Lm, Hm, tm, cover, fy, reach)
    zone_m = ustrip(u"m", zone.zone)
    zone_m > 0 || return false
    cover_m = ustrip(u"m", cover)
    bar = zone.bar == 0 ? vert.size : Int(zone.bar)
    spacing_m = ustrip(u"m", zone.spacing)
    spacing_m > 0 || (spacing_m = vert.spacing)
    tie = boundary_tie_bar_size(bar).tie
    arranged = boundary_hoop_arrangement(tm * u"m", zone_m * u"m")
    if spacing_m * u"m" > arranged.hx + 1e-6u"m"
        push!(md.warnings,
            "boundary bars at $(round(spacing_m / 0.0254; digits = 1)) in. " *
            "are farther apart than hx of §18.10.6.4(f)")
    end
    hx = min(spacing_m * u"m", arranged.hx)
    grade = _boundary_grade(fy)
    least = min(tm, zone_m) * u"m"
    db = bar_diameter(bar)
    tight = boundary_element_vertical_spacing(least, db, hx;
                                            grade = grade, within_critical_reach = true)
    loose = boundary_element_vertical_spacing(least, db, hx;
                                            grade = grade, within_critical_reach = false)
    reach_m = min(max(ustrip(u"m", reach), cover_m), Hm - cover_m)
    z_tight = _spaced_positions(cover_m, reach_m, ustrip(u"m", tight.required))
    z_loose = reach_m >= Hm - cover_m - 1e-9 ? Float64[] :
              _spaced_positions(reach_m, Hm - cover_m, ustrip(u"m", loose.required))
    zs = unique(vcat(z_tight, z_loose))
    isempty(zs) && return false
    dt = ustrip(u"m", bar_diameter(tie))
    along = min(zone_m - 2 * cover_m - dt, ustrip(u"m", arranged.hoop_leg))
    through = tm - 2 * cover_m - dt
    (along > dt && through > dt) || return false
    overlap = ustrip(u"m", arranged.overlap)
    starts = _boundary_hoop_starts(zone_m - 2 * cover_m - dt, along, overlap)
    len = _closed_loop_length(along, through, tie; hook_angle = 135) * u"m"
    wires = Vector{NTuple{3, Float64}}[]
    for origin in (cover_m + dt / 2, Lm - zone_m + cover_m + dt / 2)
        for x0 in origin .+ starts
            for z in zs
                y0 = -through / 2
                y1 = through / 2
                x1 = x0 + along
                push!(wires, [(x0, y0, z), (x1, y0, z), (x1, y1, z),
                              (x0, y1, z), (x0, y0, z)])
            end
        end
    end
    s_in = round(ustrip(u"inch", tight.required); digits = 2)
    push!(md.groups, BarGroup(; mark = "WBH", role = :tie, direction = :transverse,
        bar_size = tie, count = length(wires), length = len, shape = :closed_tie,
        centerlines = wires,
        note = "boundary hoops, $(s_in) in. within the critical reach (§18.10.6.4(e), §18.10.6.4(f))"))
    _place_boundary_crossties!(md, zone_m, spacing_m, cover_m, Lm, tie, through, zs, starts, along)
    return true
end

"""Hoop starts along a zone, each leg at most `leg` long, overlapping by `overlap`."""
function _boundary_hoop_starts(available, leg, overlap)
    available <= leg + 1e-9 && return [0.0]
    step = max(leg - overlap, leg / 2)
    starts = Float64[]
    x = 0.0
    while x + leg < available - 1e-6
        push!(starts, x)
        x += step
    end
    push!(starts, max(available - leg, 0.0))
    return starts
end

"""A crosstie at each longitudinal station that is not a hoop corner."""
function _place_boundary_crossties!(md, zone_m, spacing_m, cover_m, Lm, tie, through, zs, starts, along)
    first = cover_m + spacing_m / 2
    last = zone_m - cover_m - spacing_m / 2
    last + 1e-9 < first && return nothing
    stations = _spaced_positions(first, last, spacing_m)
    isempty(stations) && return nothing
    corners = Float64[]
    for x0 in starts
        push!(corners, x0, x0 + along)
    end
    interior = [x for x in stations if all(c -> abs(x - c) > 0.5 * spacing_m, corners)]
    isempty(interior) && return nothing
    hook = ustrip(u"m", hook_centerline_length(tie; angle = 135, role = :stirrup))
    len = (through + 2 * hook) * u"m"
    wires = Vector{NTuple{3, Float64}}[]
    y0 = -through / 2
    y1 = through / 2
    for origin in (0.0, Lm - zone_m)
        for x in origin .+ interior
            for z in zs
                push!(wires, [(x, y0, z), (x, y1, z)])
            end
        end
    end
    push!(md.groups, BarGroup(; mark = "WBC", role = :crosstie, direction = :transverse,
        bar_size = tie, count = length(wires), length = len, shape = :crosstie,
        centerlines = wires,
        note = "a crosstie at every boundary bar that is not a hoop corner (§18.10.6.4(f))"))
    return nothing
end

function _boundary_grade(fy)
    ksi = ustrip(u"ksi", fy)
    abs(ksi - 60) <= 0.5 && return 60
    abs(ksi - 80) <= 0.5 && return 80
    abs(ksi - 100) <= 0.5 && return 100
    throw(ArgumentError(
        "boundary hoops: fy must be Grade 60, 80, or 100 (got $fy)"))
end

function _wall_hook_free_ends(special, Vu, plain)
    # §18.10.6.5(a) applies on a special wall. An ordinary wall keeps the hook.
    (special && Vu !== nothing) || return true
    return horizontal_edge_anchorage(Vu, plain).hook_required
end

function _wall_tie_warning!(md, ρl, fy, special, placed_boundary = false)
    # §11.7.4.1 (p. 174): ties when compression steel has Ast > 0.001 Ag.
    # The design does not say the vertical bars are required for compression,
    # so this is reported and not placed.
    ρl > 0.001 && push!(md.notes,
        "§11.7.4.1 ties are not placed: the design does not mark the vertical bars as compression steel")
    # §18.10.6.5(b): boundary ties when the boundary ratio exceeds 400/fy.
    if special && !placed_boundary && boundary_longitudinal_ratio(ρl, fy).exceeds
        push!(md.warnings,
            "boundary ratio exceeds 400/fy (§18.10.6.5(b)); ties need the §18.10.6.4 length, which is not on the design")
    end
    return nothing
end

# ------------------------------------------------------------------------------
# Bars
# ------------------------------------------------------------------------------

function _wall_openings_m(openings, Lm, Hm, md)
    holes = NTuple{4, Float64}[]
    for op in openings
        s0, z0, w, h = ustrip.(u"m", op)
        (w > 0 && h > 0) || continue
        x0, x1 = clamp(s0, 0.0, Lm), clamp(s0 + w, 0.0, Lm)
        z0c, z1 = clamp(z0, 0.0, Hm), clamp(z0 + h, 0.0, Hm)
        x1 - x0 > 1e-6 && z1 - z0c > 1e-6 || continue
        (x0 ≈ s0 && z0c ≈ z0 && x1 ≈ s0 + w && z1 ≈ z0 + h) ||
            push!(md.warnings, "an opening was clipped to the wall")
        push!(holes, (x0, x1, z0c, z1))
    end
    return holes
end

function _place_verticals!(md, vert, ncurt, Lm, Hm, cover, holes, lap, above,
                           slab_above, slab_cover, fc, fy, λ, coating, stock)
    db = ustrip(u"m", bar_diameter(vert.size))
    edge = cover + db / 2
    xs = _spaced_positions(edge, Lm - edge, vert.spacing)
    isempty(xs) && return nothing
    lap_m = above === :wall ? ustrip(u"m", lap) : 0.0
    hook = 0.0
    tail = 0.0
    if above === :roof
        hook_len = hook_centerline_length(vert.size; angle = 90)
        hook = ustrip(u"m", hook_len)
        tail = ustrip(u"m", standard_hook(vert.size; angle = 90).extension)
        room = ustrip(u"m", slab_above) - ustrip(u"m", slab_cover) - db / 2
        if tail > room + 1e-9
            push!(md.warnings, "roof hook tail $(round(tail; digits = 3)) m does not fit " *
                "in the slab above ($(round(max(room, 0.0); digits = 3)) m)")
        end
    end
    run = (Hm + lap_m) * u"m"
    n_spl, bar_len = stock_splices(run, stock, lap)
    total = bar_len + hook * u"m"
    full, cut = Int[], Tuple{Float64, Float64, Int}[]
    for (i, x) in enumerate(xs)
        spans = _subtract_intervals(0.0, Hm, [(z0, z1) for (x0, x1, z0, z1) in holes
                                              if x0 - 1e-9 <= x <= x1 + 1e-9])
        if length(spans) == 1 && spans[1][1] <= 1e-9 && spans[1][2] >= Hm - 1e-9
            push!(full, i)
        else
            for (z0, z1) in spans
                push!(cut, (z0, z1, i))
            end
        end
    end
    if !isempty(full)
        path = _vertical_path(0.0, Hm + lap_m, tail, above === :roof)
        push!(md.groups, BarGroup(; mark = "V1", role = :vertical, direction = :along,
            bar_size = vert.size, count = length(full) * ncurt, length = total,
            shape = above === :roof ? :hook_end : :straight, path = path,
            x_positions = xs[full], laps = n_spl,
            note = "full height, $ncurt curtain$(ncurt == 1 ? "" : "s")"))
    end
    groups = Dict{NTuple{2, Float64}, Vector{Float64}}()
    for (z0, z1, i) in cut
        push!(get!(groups, (round(z0; digits = 6), round(z1; digits = 6)), Float64[]), xs[i])
    end
    mark = 2
    for ((z0, z1), xpos) in sort!(collect(groups))
        reaches_roof = above === :roof && z1 >= Hm - 1e-6
        extra = reaches_roof ? hook : 0.0
        run_i = (z1 - z0) * u"m"
        n_i, len_i = stock_splices(run_i, stock, lap)
        push!(md.groups, BarGroup(; mark = "V$mark", role = :vertical, direction = :along,
            bar_size = vert.size, count = length(xpos) * ncurt,
            length = len_i + extra * u"m",
            shape = reaches_roof ? :hook_end : :straight,
            path = _vertical_path(z0, z1, tail, reaches_roof),
            x_positions = xpos, laps = n_i,
            note = "interrupted by an opening, $ncurt curtain$(ncurt == 1 ? "" : "s")"))
        mark += 1
    end
    return nothing
end

"""Path of one vertical bar at x = 0. A roof hook turns in +x."""
function _vertical_path(z0, z1, tail, hooked)
    path = [(0.0, z0), (0.0, z1)]
    hooked && push!(path, (tail, z1))
    return path
end

function _place_section_dots!(md, vert, ncurt, tm, cover)
    db = ustrip(u"m", bar_diameter(vert.size))
    ys = ncurt == 1 ? [0.0] : [-(tm / 2 - cover - db / 2), tm / 2 - cover - db / 2]
    edge = cover + db / 2
    # Stations are recomputed from the vertical groups so dots match the bars.
    xs = Float64[]
    for g in md.groups
        g.role === :vertical || continue
        append!(xs, g.x_positions)
    end
    unique!(sort!(xs))
    for x in xs, y in ys
        push!(md.section_dots, (x, y, db))
    end
    return nothing
end

function _place_horizontals!(md, horiz, ncurt, Lm, Hm, cover, holes, ends, hook_free,
                             fc, fy, λ, coating, stock)
    db = ustrip(u"m", bar_diameter(horiz.size))
    edge = cover + db / 2
    zs = Float64[]
    z = horiz.spacing / 2
    while z <= Hm - edge + 1e-9
        push!(zs, z)
        z += horiz.spacing
    end
    isempty(zs) && return nothing
    lap = _wall_lap(horiz.size, fc, fy, λ, coating, cover * u"m")
    lap_m = ustrip(u"m", lap)
    ext = hook_free ? ustrip(u"m", standard_hook(horiz.size; angle = 90).extension) : 0.0
    hook = hook_free ? ustrip(u"m", hook_centerline_length(horiz.size; angle = 90)) : 0.0
    # Bars that clear the same openings share a run. Hooks turn up when the
    # tail fits under the top of the wall, and down otherwise.
    buckets = Dict{Tuple, Vector{Float64}}()
    for z in zs
        spans = _subtract_intervals(edge, Lm - edge,
            [(x0, x1) for (x0, x1, z0, z1) in holes if z0 - 1e-9 <= z <= z1 + 1e-9])
        up = hook_free && z + ext <= Hm - edge + 1e-9
        for (x0, x1) in spans
            push!(get!(buckets, (round(x0; digits = 6), round(x1; digits = 6), up), Float64[]), z)
        end
    end
    mark = 1
    left_edge = edge
    right_edge = Lm - edge
    for ((x0, x1, up), zpos) in sort!(collect(buckets); by = first)
        at_left = abs(x0 - left_edge) <= 1e-4
        at_right = abs(x1 - right_edge) <= 1e-4
        x_start = ends[1] === :joined && at_left ? -lap_m : x0
        x_end = ends[2] === :joined && at_right ? Lm + lap_m : x1
        hook_left = ends[1] === :free && hook_free && at_left
        hook_right = ends[2] === :free && hook_free && at_right
        n_hooks = (hook_left ? 1 : 0) + (hook_right ? 1 : 0)
        run = (x_end - x_start) * u"m"
        n_spl, len = stock_splices(run, stock, lap)
        total = len + n_hooks * hook * u"m"
        path = _horizontal_path(x_start, x_end, ext, hook_left, hook_right, up)
        shape = n_hooks == 2 ? :hook_both : n_hooks == 1 ? (hook_left ? :hook_start : :hook_end) : :straight
        note = (ends[1] === :joined && at_left) || (ends[2] === :joined && at_right) ?
            "Class B corner lap $(round(ustrip(u"inch", lap); digits = 1)) in into the intersecting wall" :
            "free ends hooked"
        push!(md.groups, BarGroup(; mark = "H$mark", role = :horizontal, direction = :transverse,
            bar_size = horiz.size, count = length(zpos) * ncurt, length = total,
            shape = shape, path = path, z_positions = zpos, laps = n_spl,
            note = note * ", $ncurt curtain$(ncurt == 1 ? "" : "s")"))
        mark += 1
    end
    return nothing
end

"""Horizontal bar path at z = 0. Joined ends run a lap past the wall."""
function _horizontal_path(x0, x1, ext, hook_left, hook_right, up)
    path = NTuple{2, Float64}[]
    signz = up ? 1.0 : -1.0
    hook_left && push!(path, (x0, signz * ext))
    push!(path, (x0, 0.0), (x1, 0.0))
    hook_right && push!(path, (x1, signz * ext))
    return path
end

"""
    wall_horizontal_end_gap(detail, length) -> length or nothing

The larger gap between a concrete end and the horizontal web bars.

Each end's gap is the smallest distance from that end to a `:horizontal`
bar. A bar that crosses the end has gap zero. No horizontal bar returns
`nothing`. Whether that gap is within 6 in. is §18.10.6.4(k).
"""
function wall_horizontal_end_gap(md::MemberDetail, length::Length)
    L = ustrip(u"m", length)
    L > 0 || throw(ArgumentError(
        "horizontal end gap: wall length must be positive (got $length)"))
    left = Inf
    right = Inf
    found = false
    for g in md.groups
        g.role === :horizontal || continue
        isempty(g.path) && continue
        found = true
        x0, x1 = extrema(p[1] for p in g.path)
        left = min(left, max(0.0, x0))
        right = min(right, max(0.0, L - x1))
    end
    found || return nothing
    return max(left, right) * u"m"
end

function _place_trim!(md, holes, ncurt, Lm, Hm, cover, fc, fy, λ, coating)
    isempty(holes) && return nothing
    # §11.7.5.1 (p. 174): two No. 5 bars around an opening in a two-layer wall,
    # one No. 5 in a single-layer wall, each developed for fy at the corners.
    size = 5
    db = ustrip(u"m", bar_diameter(size))
    per_side = ncurt == 1 ? 1 : 2
    ld = ustrip(u"m", straight_development_length(size, fc, fy, λ; coating = coating,
                                                  ψt = 1.3, favorable_cover = cover * u"m" >= db * u"m"))
    ldh = ustrip(u"m", hooked_bar_development_length(size, fc, fy, λ; coating = coating,
                                                     side_cover = cover >= 6 * db))
    hook = ustrip(u"m", hook_centerline_length(size; angle = 90))
    ext = ustrip(u"m", standard_hook(size; angle = 90).extension)
    inset = cover + db / 2
    mark = 1
    for (x0, x1, z0, z1) in holes
        # Vertical trim, one each side of the opening.
        for (x, side) in ((x0 - inset, "left"), (x1 + inset, "right"))
            _trim_bar!(md, mark, :vertical, side, x, z0, z1, 0.0, Hm, ld, ldh, hook, ext,
                       per_side, size, true)
            mark += 1
        end
        for (z, side) in ((z0 - inset, "below"), (z1 + inset, "above"))
            _trim_bar!(md, mark, :horizontal, side, z, x0, x1, 0.0, Lm, ld, ldh, hook, ext,
                       per_side, size, false)
            mark += 1
        end
    end
    return nothing
end

"""
One trim bar. `along0`/`along1` is the opening side; the bar is extended `ld`
past each end and hooked where the wall ends first.
"""
function _trim_bar!(md, mark, role, side, fixed, a, b, lo, hi, ld, ldh, hook, ext,
                    count, size, vertical)
    start = a - ld
    stop = b + ld
    hooked_start = start < lo
    hooked_stop = stop > hi
    start = max(start, lo)
    stop = min(stop, hi)
    stop - start > 1e-6 || return nothing
    n_hooks = (hooked_start ? 1 : 0) + (hooked_stop ? 1 : 0)
    room_start = a - lo
    room_stop = hi - b
    if hooked_start && room_start + 1e-9 < ldh
        push!(md.warnings, "trim bar $side of an opening develops neither ℓd nor ℓdh at the corner")
    end
    if hooked_stop && room_stop + 1e-9 < ldh
        push!(md.warnings, "trim bar $side of an opening develops neither ℓd nor ℓdh at the corner")
    end
    len = (stop - start + n_hooks * hook) * u"m"
    xs, zs = Float64[], Float64[]
    if vertical
        path = [(0.0, start), (0.0, stop)]
        hooked_start && pushfirst!(path, (ext, start))
        hooked_stop && push!(path, (ext, stop))
        xs = [fixed]
    else
        path = [(start, 0.0), (stop, 0.0)]
        hooked_start && pushfirst!(path, (start, ext))
        hooked_stop && push!(path, (stop, ext))
        zs = [fixed]
    end
    push!(md.groups, BarGroup(; mark = "T$mark", role = :trim, direction = :along,
        bar_size = size, count = count, length = len,
        shape = n_hooks == 0 ? :straight : n_hooks == 2 ? :hook_both : :hook_end,
        path = path, x_positions = xs, z_positions = zs, laps = 0,
        note = "No. 5 trim, $side of opening"))
    return nothing
end

function _place_dowels!(md, vert, ncurt, cover, depth, fc, fy, λ, coating, lap)
    # §16.3.5.1 (p. 226): dowels or an extension of the wall bars. §16.3.4.2:
    # the steel across the joint satisfies §11.6.1, which the wall bars do.
    db = ustrip(u"m", bar_diameter(vert.size))
    ldh = hooked_bar_development_length(vert.size, fc, fy, λ; coating = coating,
                                        side_cover = cover >= 6 * db)
    ldc = compression_development_length(vert.size, fc, fy, λ)
    need = ustrip(u"m", max(ldh, ldc))
    if depth === nothing
        embed = need
        push!(md.warnings, "dowel embedment is unchecked: the wall foundation depth is not on the design")
    else
        have = ustrip(u"m", depth) - cover - db / 2
        embed = min(max(have, 0.0), need)
        have + 1e-9 < need && push!(md.warnings,
            "dowel embedment $(round(have; digits = 3)) m is shorter than ℓdh and ℓdc ($(round(need; digits = 3)) m)")
    end
    lap_m = ustrip(u"m", lap)
    ext = ustrip(u"m", standard_hook(vert.size; angle = 90).extension)
    hook = ustrip(u"m", hook_centerline_length(vert.size; angle = 90))
    # A full-height bar takes the Class B lap. A bar that starts at the base and
    # stops at a sill can only lap up to that sill; the rest would land in the opening.
    # Door jambs have no bar below the opening, so they are not doweled.
    runs = Dict{Float64, Vector{Float64}}()
    short = false
    for g in md.groups
        g.role === :vertical || continue
        from_base = startswith(g.note, "full") ||
            (occursin("interrupted", g.note) && !isempty(g.path) && g.path[1][2] <= 1e-9)
        from_base && !isempty(g.x_positions) || continue
        top = isempty(g.path) ? lap_m : maximum(p -> p[2], g.path)
        proj = min(lap_m, max(top, 0.0))
        proj + 1e-9 < lap_m && (short = true)
        append!(get!(runs, round(proj; digits = 6), Float64[]), g.x_positions)
    end
    short && push!(md.warnings,
        "dowel lap is cut short at an opening: the Class B lap does not fit below the sill")
    mark = 1
    for (proj, xs) in sort!(collect(runs); by = first)
        unique!(sort!(xs))
        (isempty(xs) || proj <= 1e-6) && continue
        cut = proj + 1e-9 < lap_m
        note = cut ? "dowel stopped at the sill" : "dowel, Class B lap into the wall bars"
        push!(md.groups, BarGroup(; mark = "D$mark", role = :dowel, direction = :along,
            bar_size = vert.size, count = length(xs) * ncurt,
            length = (embed + proj + hook) * u"m",
            shape = :hook_start, path = [(ext, -embed), (0.0, -embed), (0.0, proj)],
            x_positions = xs, laps = 1,
            note = note * ", $ncurt curtain$(ncurt == 1 ? "" : "s")"))
        mark += 1
    end
    return nothing
end

"""
Record the ratio area and the placed area, in in².

The ratio area is `ρl·ℓw·h` and `ρt·height·h`: the smeared area
[`wall_axial_flexure_capacity_si`](@ref) uses for vertical steel, and the
same product for the horizontal ratio. The placed area counts one bar per
station and curtain. An opening shortens a bar; it does not drop the station.
Trim and dowels are not included. A placed area below the ratio area is warned.
"""
function _report_wall_areas!(md, ρl, ρt, length, height, thickness)
    t = ustrip(u"inch", thickness)
    record_steel_area!(md, "vertical",
                       Float64(ρl) * ustrip(u"inch", length) * t,
                       _distributed_as_in2(md, :vertical); source = "ρl·ℓw·h")
    record_steel_area!(md, "horizontal",
                       Float64(ρt) * ustrip(u"inch", height) * t,
                       _distributed_as_in2(md, :horizontal); source = "ρt·height·h")
    return nothing
end

"Cross-sectional area, in², of one bar per station. Split runs count once."
function _distributed_as_in2(md, role)
    stations = Float64[]
    size = nothing
    ncurt = 1
    for g in md.groups
        g.role === role || continue
        pos = role === :vertical ? g.x_positions : g.z_positions
        isempty(pos) && continue
        append!(stations, pos)
        size = g.bar_size
        ncurt = div(g.count, length(pos))
    end
    size === nothing && return 0.0
    unique!(sort!(stations))
    return length(stations) * ncurt * ustrip(u"inch^2", bar_area(size))
end

"""Pieces of `[a, b]` outside every `(lo, hi)` hole."""
function _subtract_intervals(a, b, holes)
    segs = [(a, b)]
    for (lo, hi) in holes
        hi <= lo && continue
        next = Tuple{Float64, Float64}[]
        for (s0, s1) in segs
            if hi <= s0 + 1e-9 || lo >= s1 - 1e-9
                push!(next, (s0, s1))
            else
                lo > s0 + 1e-9 && push!(next, (s0, min(lo, s1)))
                hi < s1 - 1e-9 && push!(next, (max(hi, s0), s1))
            end
        end
        segs = next
    end
    return [s for s in segs if s[2] - s[1] > 1e-4]
end
