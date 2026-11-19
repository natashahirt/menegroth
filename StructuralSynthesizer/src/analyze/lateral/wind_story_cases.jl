# ==============================================================================
# ASCE 7-22 Chapter 27 story forces on the rigid-diaphragm masters
# ==============================================================================
#
# Directional-procedure wall pressures, Figure 27.3-8 Cases 1–4, and the
# §27.1.5 minimum, placed on the rigid-diaphragm masters. The coefficients
# and the edge resultant are the StructuralSizer functions. This file only
# places those results on the building.
#
# `direction` is the horizontal direction the wind blows toward. It need not
# be a unit vector. Wind coming from +X is direction (-1, 0).
#
# Not done here, on purpose:
# - Wall sizing, Chapter 26 velocity pressure, roof Cp, open-building CN.
# - A force at the base, or the whole building height dumped on the roof.
# - Figure 27.3-1 roof Cp. A sloped roof is refused, not returned as a
#   wall-only case.
# Eq. 27.3-4 is used when `flexible=true` and `gust` supplies the §26.11
# terms. A flexible diaphragm is not a flexible building: the rigid 0.15 B
# eccentricity is still the one applied, and its moment is a couple on the
# wall lines.

"""One level above the base that receives a wind story force."""
struct WindStoryLevel
    story::Int
    elevation_m::Float64
    "Exposed wall height of this story [m]. The height ELF uses, hsx."
    story_height_m::Float64
    "Rigid-diaphragm master, or `nothing` when the diaphragm has no rigid links."
    master::Union{Nothing, Asap.Node}
    "Open floor rings [m], from [`story_floor_outline`](@ref)."
    outline::Vector{Vector{NTuple{2, Float64}}}
end

"""
One solved wind case.

`Mz_kN_m` is the moment applied at the rigid-diaphragm master, not the
moment about the outline centroid. `ux_m` and `uy_m` are the master's
solved displacements.
"""
struct WindStoryCase
    kind::Symbol
    direction::NTuple{2, Float64}
    direction_2::Union{Nothing, NTuple{2, Float64}}
    sign_1::Int
    sign_2::Int
    Fx_kN::Vector{Float64}
    Fy_kN::Vector{Float64}
    Mz_kN_m::Vector{Float64}
    ux_m::Vector{Float64}
    uy_m::Vector{Float64}
end

"""Levels above the base, lowest first, and every solved wind case."""
struct WindStoryAnalysis
    levels::Vector{WindStoryLevel}
    cases::Vector{WindStoryCase}
    "Full displacement of each case, same order as `cases`. Empty when no solve was stored."
    displacements::Vector{Vector{Float64}}
    "Plan point each level's moment is taken about. Empty on a hand-built analysis."
    centroids::Vector{NTuple{2,Float64}}
end

"""
Two-field analysis for a hand-built case list.

`displacements` and `centroids` are empty. A solved
[`wind_story_analysis`](@ref) fills both.
"""
WindStoryAnalysis(levels, cases) =
    WindStoryAnalysis(levels, cases, Vector{Float64}[], NTuple{2,Float64}[])

"""
    wind_story_analysis(struc; directions, qz, qh, Kd, G, GCpi, ...) -> WindStoryAnalysis

Apply ASCE 7-22 Chapter 27 MWFRS wall forces to the rigid-diaphragm masters
and solve them as one batch on the reduced stiffness.

A rigid diaphragm puts the resultant and its moment on the master.
A flexible diaphragm splits `(Fx, Fy)` among the lines of seismic-system
walls by the floor width each line takes facing the wind
([`diaphragm_story_loads`](@ref)). The resultant's
moment, including the move from the centroid to a master, is applied as a
couple on the wall lines that have a moment arm. ASCE 7-22 §12.8.4.2.1
(corpus: asce-7-22, PDF page 187) requires the 5% accidental eccentricity
only where diaphragms are not flexible; that seismic moment is not this
wind moment. `flexible=true` is a flexible building (§26.2, natural
frequency below 1 Hz) and replaces the 0.15 B eccentricity with Eq. 27.3-4.
`gust` then holds `eR`, `Iz`, `gQ`, `Q`, `gR`, and `R`. `eR` is one
distance or one distance per level above the base. `gust_site` instead
decides flexibility from §26.11 for each wind direction
([`_wind_site_gust`](@ref)); `G` is then the rigid-building factor. A `:semirigid`
membrane floor takes the force on its exterior edge and the moment about the
exterior-loop centroid ([`_semirigid_wind_forces`](@ref)); `Mz_kN_m` is then
that moment. A full-plate `:shell` floor throws from the shared story-load
builder.

`directions` is two plan directions, the structure's principal axes. They
must be perpendicular unless `perpendicular` is false. Two copies of one
direction, or opposite directions, throw either way. `perpendicular=false`
still builds Cases 3 and 4 from that skewed pair; Figure 27.3-8 defines
that combination for principal axes, so the override is the caller's choice.
Cases 1 and 2 run for each axis. Case 3 is
75% of both at once. Case 4 is 75% of Case 2 for both, with every sign of
the 0.15 B eccentricity. The opposite sense of a principal axis is not added.

`extra_directions` adds more wind directions. Each one gets Case 1, both
signs of Case 2, and its own §27.1.5 minimum. It is not combined into
Cases 3 or 4. A direction that repeats a principal axis, or repeats another
extra direction, throws. The opposite of a principal axis is allowed: that
sense is not already in the principal cases.
`qz` is one velocity pressure per level above the base, lowest first, in
kN/m². `qh`, `Kd`, `G`, and `GCpi` are scalars in that same pressure unit
(`Kd`, `G`, and `GCpi` are dimensionless). `qi` defaults to `qh`.

`roof` must be a Figure 27.3-1 roof (`:flat`, `:gable`, `:hip`,
`:monoslope`, or `:mansard`). Only `:flat` is analyzed. A flat roof's
external pressure is vertical and is not part of the horizontal story force.
Its §27.1.5 vertical projection is zero in every wind direction, so the
minimum case carries no roof term. A sloped roof's projection depends on the
wind direction and is not an input here. `:gable`, `:hip`, `:monoslope`, and `:mansard` throw
before any case is built: Figure 27.3-1 roof pressures are not applied in
this slice, so a sloped roof cannot be returned as a wall-only case. A roof
that is not drawn on the figure throws from `wind_figure_2731_roof`.

# Citations
ASCE 7-22 Eq. 27.3-1, §27.1.5, §27.3.1, Figure 27.3-1, Figure 27.3-8, and
§27.3.5 (corpus: asce-7-22, PDF pages 342–345 and 352–353). The equations
are cited on the StructuralSizer functions this calls.
"""
function wind_story_analysis(struc::BuildingStructure;
                             directions,
                             qz,
                             qh::Real,
                             Kd::Real,
                             G::Real,
                             GCpi::Real,
                             qi::Union{Real, Nothing}=nothing,
                             flexible::Bool=false,
                             gust=nothing,
                             gust_site=nothing,
                             roof::Symbol=:flat,
                             extra_directions=(),
                             perpendicular::Bool=true)
    if gust_site !== nothing && (flexible || gust !== nothing)
        throw(ArgumentError(
            "wind_story_analysis: gust_site decides the building's flexibility from " *
            "§26.11; do not also pass flexible or gust."))
    end
    if flexible && gust === nothing
        throw(ArgumentError(
            "wind_story_analysis: a flexible building uses ASCE 7-22 Eq. 27.3-4 " *
            "(corpus: asce-7-22, PDF page 353). Pass gust with eR, Iz, gQ, Q, " *
            "gR, and R from §26.11."))
    end
    wind_figure_2731_roof(roof)
    # ASCE 7-22 §27.3.1: "Pressure shall be applied simultaneously on
    # windward and leeward walls and on roof surfaces, as defined in
    # Figures 27.3-1, 27.3-2, and 27.3-3" (corpus: asce-7-22, PDF pages
    # 342–345). Table 27.2-1 Step 6 assigns Figure 27.3-1 to walls and to
    # flat, gable, hip, monoslope, or mansard roofs (PDF page 343).
    # This slice does not apply Figure 27.3-1 roof Cp. A sloped roof is
    # therefore refused before any case is built, rather than returned as
    # wall pressures alone. A flat roof stays in scope: §27.1.5 multiplies
    # 8 lb/ft² by the roof area projected onto a vertical plane normal to
    # the wind (PDF page 342), and that projection is zero. Its external
    # pressure is vertical and is not part of the horizontal story force.
    if roof !== :flat
        throw(ArgumentError(
            "wind_story_analysis: Figure 27.3-1 roof pressures are not applied " *
            "in this slice, so a sloped roof cannot be returned as a wall-only case " *
            "(roof=$(repr(roof)))."))
    end
    direction_1, direction_2 = _wind_two_directions(directions; perpendicular)
    extras = _wind_extra_directions(extra_directions, direction_1, direction_2)

    struc.asap_model.processed || throw(ArgumentError(
        "wind_story_analysis: the Asap model is not processed. Call to_asap! first."))

    levels = _wind_levels(struc)
    n = length(levels)
    length(qz) == n || throw(ArgumentError(
        "wind_story_analysis: qz has $(length(qz)) values and there are $n " *
        "levels above the base. One qz per level, lowest first."))

    all_directions = (direction_1, direction_2, extras...)
    site = gust_site === nothing ? nothing :
        _wind_site_gust(struc, levels, gust_site, all_directions, G)
    calcs = Vector{NamedTuple}(undef, n)
    for i in 1:n
        lv = levels[i]
        qzi = _wind_plain("qz[$i]", qz[i])
        resultants = WindWallResultant[]
        for (k, d) in enumerate(all_directions)
            Gd, flex_d, gust_d = site === nothing ?
                (G, flexible, _wind_level_gust(gust, i, n)) :
                (site[k].G, site[k].flexible, _wind_level_gust(site[k].gust, i, n))
            push!(resultants, wind_wall_resultant(lv.outline, d; qz=qzi, qh, Kd, G=Gd,
                GCpi, qi, height=lv.story_height_m, flexible=flex_d, gust=gust_d))
        end
        pts = NTuple{2, Float64}[]
        for loop in lv.outline
            append!(pts, loop)
        end
        for r in resultants
            _wind_match_extent(pts, r)
        end
        calcs[i] = (; resultants, pts)
    end

    story_cases = [wind_cases_from_resultants(calcs[i].resultants[1], calcs[i].resultants[2];
                       perpendicular) for i in 1:n]
    for k in 1:length(extras)
        for i in 1:n
            append!(story_cases[i], wind_direction_cases(calcs[i].resultants[2 + k]))
        end
    end
    ncase = length(story_cases[1])
    built = WindStoryCase[]
    load_cases = Vector{Vector{Asap.AbstractLoad}}()
    centroids = _wind_level_centroids(calcs)
    for j in 1:ncase
        template = story_cases[1][j]
        Fx = Float64[story_cases[i][j].Fx for i in 1:n]
        Fy = Float64[story_cases[i][j].Fy for i in 1:n]
        Mz = Float64[story_cases[i][j].Mz for i in 1:n]
        M_master = _wind_master_moments(levels, calcs, Fx, Fy, Mz;
                                        semirigid=_is_semirigid(struc))
        push!(load_cases, _wind_loads(struc, levels, Fx, Fy, M_master, centroids))
        push!(built, WindStoryCase(template.kind, template.direction, template.direction_2,
            template.sign_1, template.sign_2, Fx, Fy, M_master,
            Float64[], Float64[]))
    end
    _wind_append_minima!(struc, built, load_cases, levels, calcs)

    displacements = Asap.solve(struc.asap_model, load_cases, lateral_solve_links(struc))
    length(displacements) == length(built) || throw(ArgumentError(
        "wind_story_analysis: the solve returned $(length(displacements)) cases, " *
        "expected $(length(built))."))

    solved = WindStoryCase[]
    for (i, u) in enumerate(displacements)
        ux = Float64[]
        uy = Float64[]
        for lv in levels
            if lv.master === nothing
                # No rigid floor. The case does not report a master displacement.
                push!(ux, NaN)
                push!(uy, NaN)
            else
                x, y = _wind_master_disp(u, lv.master)
                push!(ux, x)
                push!(uy, y)
            end
        end
        c = built[i]
        push!(solved, WindStoryCase(c.kind, c.direction, c.direction_2,
            c.sign_1, c.sign_2, c.Fx_kN, c.Fy_kN, c.Mz_kN_m, ux, uy))
    end
    return WindStoryAnalysis(levels, solved, displacements, centroids)
end

"Plan centroid of each level's first wind resultant."
_wind_level_centroids(calcs) =
    NTuple{2,Float64}[c.resultants[1].centroid for c in calcs]

function _wind_append_minima!(struc, built, load_cases, levels, calcs)
    n = length(levels)
    nresult = length(calcs[1].resultants)
    for which in 1:nresult
        Fx = zeros(Float64, n)
        Fy = zeros(Float64, n)
        Mz = zeros(Float64, n)
        direction = calcs[1].resultants[which].direction
        for i in 1:n
            r = calcs[i].resultants[which]
            # projected_plan_width is the extent perpendicular to the wind,
            # which is B. §27.1.5's wall term uses that projected width.
            B = projected_plan_width(calcs[i].pts, (r.direction[1], r.direction[2]))
            wall_area = B * levels[i].story_height_m
            # Only a flat roof reaches here. Its vertical projection is zero.
            mini = wind_minimum_resultant(wall_area, 0.0, r.direction,
                r.centroid, r.geometric_center; system=:kN_m2)
            Fx[i] = mini.Fx
            Fy[i] = mini.Fy
            Mz[i] = mini.Mz
        end
        M_master = _wind_master_moments(levels, calcs, Fx, Fy, Mz;
                                        semirigid=_is_semirigid(struc))
        push!(load_cases, _wind_loads(struc, levels, Fx, Fy, M_master,
                                      _wind_level_centroids(calcs)))
        push!(built, WindStoryCase(:minimum, direction, nothing, 0, 0,
            Fx, Fy, M_master, Float64[], Float64[]))
    end
    return nothing
end

"""Levels above the base. The story list and the masters are the ones ELF uses."""
function _wind_levels(struc)
    # No wind force is applied at the base. The 1e-6 m split is `_stories_above_base`.
    master_at = _elf_masters(struc)
    z_base, above = _stories_above_base(_faced_story_floors(struc.skeleton),
                                        "wind_story_analysis")
    levels = WindStoryLevel[]
    for (i, item) in enumerate(above)
        master = _level_master(struc, master_at, item.z, item.idx, "wind_story_analysis")
        z_below = i == 1 ? z_base : above[i - 1].z
        hsx = _story_height_below(item.z, z_below, item.idx, "wind_story_analysis")
        push!(levels, WindStoryLevel(item.idx, item.z, hsx, master, item.outline))
    end
    return levels
end

function _wind_master_moments(levels, calcs, Fx, Fy, Mz; semirigid::Bool=false)
    # A membrane floor takes the moment about the exterior-loop centroid itself.
    semirigid && return copy(Mz)
    if any(lv -> lv.master === nothing, levels)
        # No master. The moment stays about the exterior centroid. A flexible
        # diaphragm turns it into a couple in `_wind_loads`. A semirigid floor
        # is handled above.
        return copy(Mz)
    end
    out = Vector{Float64}(undef, length(levels))
    for i in eachindex(levels)
        cx, cy = calcs[i].resultants[1].centroid
        master = levels[i].master
        xm = ustrip(u"m", master.position[1])
        ym = ustrip(u"m", master.position[2])
        # Force at the master, plus the centroid moment, plus the moment of
        # moving that force from the centroid to the master.
        out[i] = Mz[i] + (cx - xm) * Fy[i] - (cy - ym) * Fx[i]
    end
    return out
end

function _wind_loads(struc, levels, Fx, Fy, Mz, centroids)
    # An empty list is a hand-built analysis. A rigid floor does not use the
    # point. A membrane floor throws from the story-load builder.
    cents = isempty(centroids) ? nothing : centroids
    loads = diaphragm_story_loads(struc, levels, Fx, Fy, Mz;
        force_id=:wind_story, moment_id=:wind_torsion, centroids=cents)
    if struc.diaphragm_layout isa FlexibleDiaphragmLayout
        append!(loads, _wind_flexible_torsion(struc, levels, Mz, centroids, loads))
    end
    return loads
end

"""
Eq. 27.3-4 inputs for level `i`. `eR` is one distance or one per level.

A rigid building passes `gust = nothing`.
"""
function _wind_level_gust(gust, i::Int, n::Int)
    gust === nothing && return nothing
    eR = gust.eR
    eRi = eR isa AbstractVector ? eR[i] : eR
    length_ok = !(eR isa AbstractVector) || length(eR) == n
    length_ok || throw(ArgumentError(
        "wind_story_analysis: gust.eR has $(length(eR)) values and there are " *
        "$n levels above the base."))
    return (eR=eRi, Iz=gust.Iz, gQ=gust.gQ, Q=gust.Q, gR=gust.gR, R=gust.R)
end

const _M_TO_FT = 1 / 0.3048

"""
    _wind_site_gust(struc, levels, site, directions, G) -> Vector{NamedTuple}

Rigid or flexible, and the gust-effect factor, for each wind direction.

`site` holds `V_mph` (basic wind speed), `exposure` (`:B`, `:C`, `:D`), `β`
(damping, fraction of critical), and optionally `n1` [Hz], `eR` [m, one value
or one per level], and `frequency_system` (default `:other`, Eq. 26.11-4).

- A low-rise building (§26.2) is rigid (§26.11.2).
- Otherwise `n1` is `site.n1`, or the approximate `na` of §26.11.3 when
  §26.11.2.1 permits it: the lower of `frequency_system`'s equation and, when
  walls run along the wind, Eq. 26.11-5. Both are permitted lower bounds; the
  lower one is the conservative choice.
- `n1 ≥ 1 Hz` is rigid and keeps the caller's `G` (§26.11.4 permits 0.85).
  Below 1 Hz the building is flexible: `Gf` from Eq. 26.11-10, and the
  Eq. 27.3-4 terms with `site.eR`, which is required and is not assumed.

The plan must be the same at every level: `B` and `L` are single dimensions
in §26.11. h is the height of the top level above the base.

# Citation
ASCE 7-22 §26.2, §26.11.2–§26.11.5, §27.3.5 (corpus: asce-7-22, PDF pages
323, 338–340, and 353).
"""
function _wind_site_gust(struc, levels, site, directions, G)
    for key in (:V_mph, :exposure, :β)
        haskey(site, key) || throw(ArgumentError("gust_site needs $key"))
    end
    n1_given = get(site, :n1, nothing)
    system = get(site, :frequency_system, :other)
    z_base = levels[1].elevation_m - levels[1].story_height_m
    h_m = levels[end].elevation_m - z_base
    h_ft = h_m * _M_TO_FT
    pts_at(lv) = reduce(vcat, lv.outline; init=NTuple{2, Float64}[])
    # B is the extent normal to the wind, L the extent along it.
    dims(d) = [(B=projected_plan_width(pts_at(lv), d),
                L=projected_plan_width(pts_at(lv), (-d[2], d[1]))) for lv in levels]
    for d in directions
        ds = dims(d)
        all(x -> abs(x.B - ds[1].B) <= 0.01 * ds[1].B && abs(x.L - ds[1].L) <= 0.01 * ds[1].L, ds) ||
            throw(ArgumentError(
                "gust_site: the plan changes between levels; §26.11 takes one B and " *
                "one L. Pass flexible and gust instead."))
    end
    d1 = dims(directions[1])[1]
    least_ft = min(d1.B, d1.L) * _M_TO_FT
    low_rise = wind_low_rise(h_ft, least_ft)
    out = NamedTuple[]
    for d in directions
        dm = dims(d)[1]
        B_ft = dm.B * _M_TO_FT
        L_ft = dm.L * _M_TO_FT
        if low_rise
            push!(out, (G=G, flexible=false, gust=nothing, n1=nothing, low_rise=true))
            continue
        end
        n1 = n1_given
        if n1 === nothing
            heights = [(lv.elevation_m - z_base) * _M_TO_FT for lv in levels]
            Leff = wind_effective_length(heights, fill(L_ft, length(levels)))
            approximate_frequency_permitted(h_ft, Leff) || throw(ArgumentError(
                "gust_site: h = $(round(h_ft; digits=1)) ft is past the §26.11.2.1 " *
                "limits for the approximate frequency (h ≤ 300 ft and h < 4Leff = " *
                "$(round(4Leff; digits=1)) ft). Pass n1 from an analysis."))
            n1 = approximate_natural_frequency(h_ft; system)
            walls = _wind_shear_walls(struc, d, z_base)
            if !isempty(walls)
                AB = _wind_base_area_ft2(struc, levels[1].story)
                n1 = min(n1, shear_wall_natural_frequency(h_ft, AB, walls))
            end
        end
        if n1 >= 1.0
            push!(out, (G=G, flexible=false, gust=nothing, n1=n1, low_rise=false))
            continue
        end
        eR = get(site, :eR, nothing)
        eR === nothing && throw(ArgumentError(
            "gust_site: n1 = $(round(n1; digits=3)) Hz, so the building is flexible " *
            "(§26.2) and Eq. 27.3-4 needs eR, the distance from the elastic shear " *
            "center to the center of mass. Pass eR in metres."))
        gf = gust_effect_factor_flexible(h_ft, B_ft, L_ft; exposure=site.exposure,
                                         V_mph=site.V_mph, n1=n1, β=site.β)
        push!(out, (G=gf.Gf, flexible=true, n1=n1, low_rise=false,
                    gust=(eR=eR, Iz=gf.Iz, gQ=gf.gQ, Q=gf.Q, gR=gf.gR, R=gf.R)))
    end
    return out
end

"""
Shear walls along the unit plan direction `d`, one per plan line, as
`(A_ft2, D_ft, h_ft)` for Eq. 26.11-5. A line's height is its stack from the
lowest pier bottom to the highest pier top; its area is the lowest pier's
thickness times its length.
"""
function _wind_shear_walls(struc, d, z_base)
    stacks = Dict{NTuple{4, Int}, Vector{NamedTuple}}()
    for w in struc.walls
        g = _wall_pier_geometry(w, struc.skeleton)
        len = hypot(g.x2 - g.x1, g.y2 - g.y1)
        abs((g.x2 - g.x1) * d[1] + (g.y2 - g.y1) * d[2]) >= (1 - 1e-6) * len || continue
        a, b = (g.x1, g.y1) <= (g.x2, g.y2) ? ((g.x1, g.y1), (g.x2, g.y2)) : ((g.x2, g.y2), (g.x1, g.y1))
        key = (round(Int, a[1] * 1000), round(Int, a[2] * 1000),
               round(Int, b[1] * 1000), round(Int, b[2] * 1000))
        push!(get!(() -> NamedTuple[], stacks, key), (len=len, g...))
    end
    walls = NTuple{3, Float64}[]
    for piers in values(stacks)
        low = piers[argmin([p.z_bot for p in piers])]
        top = maximum(p.z_top for p in piers)
        D = low.len * _M_TO_FT
        push!(walls, (low.t_m * low.len * _M_TO_FT^2, D, (top - low.z_bot) * _M_TO_FT))
    end
    return walls
end

"Base area of the building [ft²]: the slab cells of the lowest story above the base."
function _wind_base_area_ft2(struc, story)
    faces = Set(struc.skeleton.stories[story].faces)
    area = 0.0
    for c in struc.cells
        c.face_idx in faces || continue
        c.floor_type === :grade && continue
        area += ustrip(u"m^2", c.area)
    end
    area > 0 || throw(ArgumentError(
        "gust_site: story $story has no slab area for AB in Eq. 26.11-5."))
    return area * _M_TO_FT^2
end

"""
Torsional wind moment on a flexible diaphragm, as a couple on two wall lines.

The lines are the pair, parallel to one plan axis, with the longest offset
span. The forces sum to zero. Their moment makes the story loads' moment
about the exterior centroid equal to `Mz`. The tributary split of `(Fx, Fy)`
already has a moment, and that part is not added again.

One line, or lines with no separation, cannot provide the arm.

# Citation
ASCE 7-22 §27.3.5 (corpus: asce-7-22, PDF page 353): the eccentricity is
considered for each principal axis. The sign is the sign already on `Mz`.
"""
function _wind_flexible_torsion(struc, levels, Mz, centroids, story_loads)
    loads = Asap.AbstractLoad[]
    for i in eachindex(levels)
        abs(Mz[i]) <= 1e-9 && continue
        isempty(centroids) && throw(ArgumentError(
            "wind eccentricity: level $(levels[i].story) has a torsional moment " *
            "and no centroid to take it about."))
        have = _story_load_moment(story_loads, levels[i].elevation_m, centroids[i])
        append!(loads, _flexible_couple_loads(struc, levels[i].elevation_m, Mz[i] - have,
            :wind_torsion, "wind eccentricity: level $(levels[i].story)",
            "ASCE 7-22 §27.3.5 (corpus: asce-7-22, PDF page 353)"))
    end
    return loads
end

"""
Self-equilibrating couple of moment `need` [kN·m] on one flexible floor.

The two lines are the pair, parallel to one plan axis, with the longest
offset span. One line, or lines with no separation, cannot provide the arm,
and `context` and `clause` name the requirement in the error.
"""
function _flexible_couple_loads(struc, elevation_m, need, load_id::Symbol,
                                context::AbstractString, clause::AbstractString)
    loads = Asap.AbstractLoad[]
    abs(need) <= 1e-6 && return loads
    layout = struc.diaphragm_layout
    e1, e2 = plan_axes(layout.plan_axis)
    best = nothing
    for (direction, d, n) in ((:x, e1, e2), (:y, e2, e1))
        lines = _diaphragm_lines_at(layout, elevation_m, direction)
        length(lines) < 2 && continue
        span = lines[end].offset_m - lines[1].offset_m
        span > 1e-6 || continue
        if best === nothing || span > best.span
            best = (d=d, n=n, lines=lines, span=span)
        end
    end
    best === nothing && throw(ArgumentError(
        "$context has a torsional moment and no two wall lines with a moment " *
        "arm. $clause requires it."))
    # Right-handed plan axes. A line of direction d sits at offset * n,
    # where n is the other plan axis. Force +f along d at the smaller
    # offset and −f at the larger offset has moment
    # f * (o1 − o2) * (n × d).
    d = best.d
    n = best.n
    cross = d[1] * n[2] - d[2] * n[1]
    f = need / (best.span * cross)
    append!(loads, _diaphragm_line_loads(struc, best.lines[1], f * d[1], f * d[2], load_id))
    append!(loads, _diaphragm_line_loads(struc, best.lines[end], -f * d[1], -f * d[2], load_id))
    return loads
end

"Moment of nodal story forces about `(cx, cy)`, at one floor elevation [kN·m]."
function _story_load_moment(loads, elevation_m, centroid)
    cx, cy = centroid
    m = 0.0
    for load in loads
        load isa Asap.NodeForce || continue
        abs(ustrip(u"m", load.node.position[3]) - elevation_m) <= WALL_CUT_ZTOL_M || continue
        fx = ustrip(u"kN", load.value[1])
        fy = ustrip(u"kN", load.value[2])
        x = ustrip(u"m", load.node.position[1])
        y = ustrip(u"m", load.node.position[2])
        m += (x - cx) * fy - (y - cy) * fx
    end
    return m
end

_is_semirigid(struc) = struc.diaphragm_layout isa SemirigidDiaphragmLayout

function _wind_master_disp(u, master)
    gid = master.globalID
    return (u[gid[1]], u[gid[2]])
end

function _wind_match_extent(pts, resultant)
    d = resultant.direction
    B = projected_plan_width(pts, (d[1], d[2]))
    L = projected_plan_width(pts, (-d[2], d[1]))
    _wind_close("B", B, resultant.B)
    _wind_close("L", L, resultant.L)
    return nothing
end

function _wind_close(name, a, b)
    scale = max(1.0, abs(a), abs(b))
    if abs(a - b) > 1e-8 * scale
        throw(ArgumentError(
            "wind_story_analysis: $name from projected_plan_width ($a) disagrees " *
            "with the Chapter 27 outline ($b)."))
    end
    return nothing
end

function _wind_two_directions(directions; perpendicular::Bool)
    n = length(directions)
    n == 2 || throw(ArgumentError(
        "wind_story_analysis: two principal directions are required; got $n."))
    return wind_principal_directions(directions[1], directions[2]; perpendicular)
end

function _wind_extra_directions(extra_directions, direction_1, direction_2)
    accepted = NTuple{2, Float64}[]
    for (i, raw) in enumerate(extra_directions)
        d = wind_unit_direction(raw)
        for existing in (direction_1, direction_2, accepted...)
            c = d[1] * existing[1] + d[2] * existing[2]
            # Same sense only. The opposite of a principal axis is a real
            # extra direction: Figure 27.3-8 does not add that sense itself.
            if c >= 1 - StructuralSizer.WIND_EDGE_PARALLEL_COS
                throw(ArgumentError(
                    "wind_story_analysis: extra_directions[$i] repeats a wind " *
                    "direction that is already included; got $raw."))
            end
        end
        push!(accepted, d)
    end
    return accepted
end

function _wind_plain(name, x)::Float64
    if !(x isa Real) || x isa Bool || !isfinite(Float64(x))
        throw(ArgumentError(
            "wind_story_analysis: $name must be a finite number; got $(repr(x))"))
    end
    return Float64(x)
end
