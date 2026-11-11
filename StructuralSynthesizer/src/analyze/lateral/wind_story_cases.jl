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
# - The flexible-building eccentricity, Eq. 27.3-4.
# - A force at the base, or the whole building height dumped on the roof.
# - Figure 27.3-1 roof Cp. A sloped roof is refused, not returned as a
#   wall-only case.

"""One level above the base that receives a wind story force."""
struct WindStoryLevel
    story::Int
    elevation_m::Float64
    "Exposed wall height of this story [m]. The height ELF uses, hsx."
    story_height_m::Float64
    master::Asap.Node
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

`struc` must already have been through `to_asap!(; diaphragms=:rigid)` with
slabs, so `asap_rigid_links` is non-empty. A `:flexible` or `:none`
diaphragm leaves that list empty and throws. `flexible=true` throws before
any load is built.

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
                             roof::Symbol=:flat,
                             extra_directions=(),
                             perpendicular::Bool=true)
    if flexible
        throw(ArgumentError(
            "wind_story_analysis: flexible buildings are outside this slice. " *
            "ASCE 7-22 Eq. 27.3-4 is not implemented (corpus: asce-7-22, PDF page 353)."))
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

    isempty(struc.asap_rigid_links) && throw(ArgumentError(
        "wind_story_analysis: story forces use the rigid-diaphragm masters. " *
        "asap_rigid_links is empty. Call to_asap!(struc; diaphragms=:rigid) " *
        "with slabs present. A :flexible or :none diaphragm is not this distribution."))
    struc.asap_model.processed || throw(ArgumentError(
        "wind_story_analysis: the Asap model is not processed. Call to_asap! first."))

    levels = _wind_levels(struc)
    n = length(levels)
    length(qz) == n || throw(ArgumentError(
        "wind_story_analysis: qz has $(length(qz)) values and there are $n " *
        "levels above the base. One qz per level, lowest first."))

    calcs = Vector{NamedTuple}(undef, n)
    for i in 1:n
        lv = levels[i]
        qzi = _wind_plain("qz[$i]", qz[i])
        resultants = WindWallResultant[]
        for d in (direction_1, direction_2, extras...)
            push!(resultants, wind_wall_resultant(lv.outline, d; qz=qzi, qh, Kd, G,
                GCpi, qi, height=lv.story_height_m, flexible=false))
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
        M_master = _wind_master_moments(levels, calcs, Fx, Fy, Mz)
        push!(load_cases, _wind_loads(levels, Fx, Fy, M_master))
        push!(built, WindStoryCase(template.kind, template.direction, template.direction_2,
            template.sign_1, template.sign_2, Fx, Fy, M_master,
            Float64[], Float64[]))
    end
    _wind_append_minima!(built, load_cases, levels, calcs)

    displacements = Asap.solve(struc.asap_model, load_cases, struc.asap_rigid_links)
    length(displacements) == length(built) || throw(ArgumentError(
        "wind_story_analysis: the solve returned $(length(displacements)) cases, " *
        "expected $(length(built))."))

    solved = WindStoryCase[]
    for (i, u) in enumerate(displacements)
        ux = Float64[]
        uy = Float64[]
        for lv in levels
            x, y = _wind_master_disp(u, lv.master)
            push!(ux, x)
            push!(uy, y)
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

function _wind_append_minima!(built, load_cases, levels, calcs)
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
        M_master = _wind_master_moments(levels, calcs, Fx, Fy, Mz)
        push!(load_cases, _wind_loads(levels, Fx, Fy, M_master))
        push!(built, WindStoryCase(:minimum, direction, nothing, 0, 0,
            Fx, Fy, M_master, Float64[], Float64[]))
    end
    return nothing
end

"""Masters already elected by the rigid-link pass, and the levels above the base."""
function _wind_levels(struc)
    skel = struc.skeleton
    story_z = Set{Int}()
    for (_, story) in skel.stories
        push!(story_z, round(Int, ustrip(u"m", story.elevation) * 1000))
    end
    master_at = Dict{Int, Asap.Node}()
    for link in struc.asap_rigid_links
        zk = round(Int, ustrip(u"m", link.nodeA.position[3]) * 1000)
        zk in story_z || continue
        master_at[zk] = link.nodeA
    end

    raw = NamedTuple[]
    for (idx, story) in skel.stories
        isempty(story.faces) && continue
        z = ustrip(u"m", story.elevation)
        outline = story_floor_outline(skel, story)
        push!(raw, (; idx, z, outline))
    end
    isempty(raw) && throw(ArgumentError(
        "wind_story_analysis: the skeleton has no story with faces."))

    z_base = minimum(item.z for item in raw)
    # Same elevation split ELF uses to keep the base out of the story list.
    # Geometry, not a code factor. No wind force is applied at the base.
    above = [item for item in raw if item.z > z_base + 1e-6]
    isempty(above) && throw(ArgumentError(
        "wind_story_analysis: no story sits above the base elevation $(z_base) m."))
    sort!(above; by=item -> item.z)

    levels = WindStoryLevel[]
    for (i, item) in enumerate(above)
        zk = round(Int, item.z * 1000)
        haskey(master_at, zk) || throw(ArgumentError(
            "wind_story_analysis: story $(item.idx) at $(item.z) m has no rigid-diaphragm master."))
        z_below = i == 1 ? z_base : above[i - 1].z
        hsx = item.z - z_below
        hsx > 0 || throw(ArgumentError(
            "wind_story_analysis: story height below story $(item.idx) is $(hsx) m."))
        push!(levels, WindStoryLevel(item.idx, item.z, hsx, master_at[zk], item.outline))
    end
    return levels
end

function _wind_master_moments(levels, calcs, Fx, Fy, Mz)
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

function _wind_loads(levels, Fx, Fy, Mz)
    loads = Asap.AbstractLoad[]
    z = 0.0 * u"kN"
    for i in eachindex(levels)
        if Fx[i] != 0.0 || Fy[i] != 0.0
            push!(loads, Asap.NodeForce(levels[i].master,
                [Fx[i] * u"kN", Fy[i] * u"kN", z], :wind_story))
        end
        if Mz[i] != 0.0
            push!(loads, Asap.NodeMoment(levels[i].master,
                [0.0 * u"kN*m", 0.0 * u"kN*m", Mz[i] * u"kN*m"], :wind_torsion))
        end
    end
    isempty(loads) && throw(ArgumentError(
        "wind_story_analysis: a case produced no story force and no torsion."))
    return loads
end

"""
    _wind_loads(struc, levels, Fx, Fy, Mz, centroids)

Rigid-diaphragm story loads on each level's master.

`Mz` is already the moment at the master ([`_wind_master_moments`](@ref)),
so `centroids` is not used to place it. The ordinary-wall stage passes the
centroid anyway: a later semirigid placement will take the moment about
that point, and this call has the same arguments. An empty `centroids`
is a hand-built analysis. No rigid links throws: this is not the flexible
or semirigid distribution.
"""
function _wind_loads(struc::BuildingStructure, levels, Fx, Fy, Mz, centroids)
    n = length(levels)
    (length(Fx) == n && length(Fy) == n && length(Mz) == n) || throw(ArgumentError(
        "wind story loads: levels, Fx, Fy, and Mz must be one entry per level."))
    (isempty(centroids) || length(centroids) == n) || throw(ArgumentError(
        "wind story loads: $(length(centroids)) centroids for $n levels."))
    isempty(struc.asap_rigid_links) && throw(ArgumentError(
        "wind story loads: this placement puts the force and the moment on the " *
        "rigid-diaphragm master. asap_rigid_links is empty."))
    return _wind_loads(levels, Fx, Fy, Mz)
end

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
