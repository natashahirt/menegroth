# ==============================================================================
# Phase 6d — ASCE 7-22 §12.8 story forces on the rigid-diaphragm masters
# ==============================================================================
#
# Directional ELF forces, both signs of accidental torsion, and the linear
# story drift those forces produce. The coefficient, the vertical
# distribution, the story shear, the 5% eccentricity, the design
# displacement, and the stability coefficient are the StructuralSizer
# functions. This file only places those results on the building.
#
# The rigid diaphragm is the drift authority. Geometric P-delta is not
# solved: `Asap.solve_pdelta!` drops the rigid links. θ and the §12.8.7
# multiplier are computed from this linear solution. θ > θmax throws,
# which is the code's redesign limit.
#
# Wall design does not read these cases until
# `require_seismic_wall_demand_provisions` accepts them. Cracked stiffness,
# ρ on Eh, Ax on Mta, and the orthogonal combination are not applied in
# this file. This solve stays first-order so θ uses Δxe. The ordinary-wall
# stage multiplies these design story drifts by the §12.8.7 factor 1/(1−θ)
# and takes member forces from its own story geometric stiffness.
#
# Not done here, on purpose:
# - Wind story forces.
# - The §12.7.2 items a Cell cannot carry (storage live, snow, equipment).
#   The caller augments `sdl` before this runs. See `effective_seismic_weight`.
#   Wall self-weight and frame GravityLoad self-weight are included. A member
#   that spans a story is split half to each end. The half that lands on the
#   base is not above the base, so it stays out of W and Px.
# - Ie, R, SDS, S1, SD1, T, TL, Cd, and β are arguments. `SiteConditions` is
#   not read. Method :sa does not check §11.4.5 Exception 2; that is the
#   caller's, same as `seismic_response_coefficient`.
# - T is the period the caller wants used. This function does not compute Ta
#   or Cu. §12.8.6.2 allows the computed period without CuTa for drift; pass
#   that period in if that is the analysis you want.
# - Ax is reported from the analysis that used the unamplified 5% eccentricity.
#   Eq. 12.8-15 may be computed that way. Applying Ax back onto the moment
#   depends on Seismic Design Category and Type 1 horizontal irregularity,
#   which this function does not classify.
# - δdi = 0. The rigid link, and the straight line between the wall lines of
#   a flexible floor, neglect in-plane diaphragm deformation, which §12.8.6.5
#   permits when computing story drift.

"""One level above the base that receives an ELF story force."""
struct ElfLevel
    story::Int
    elevation_m::Float64
    "Height from the base to this level [m]. ASCE 7-22 Eq. 12.8-13."
    height_m::Float64
    "Story height below this level, hsx [m]. ASCE 7-22 Eq. 12.8-18."
    story_height_m::Float64
    "Effective seismic weight of this level [kN]. Slab dead load plus the wall and frame self-weight assigned here."
    weight_kN::Float64
    "Expected gravity on this level alone [kN]. 1.0D + 0.5L, including the same self-weight."
    gravity_kN::Float64
    "Expected gravity at this level and above [kN]. Px in Eq. 12.8-18."
    px_kN::Float64
    "Rigid-diaphragm master, or `nothing` when the diaphragm has no rigid links."
    master::Union{Nothing, Asap.Node}
    "Center of mass [m], the §12.8.6.5 drift point. Slab cells plus the self-weight assigned to this level."
    center_of_mass::NTuple{2, Float64}
    "Projected plan widths (extent along the first plan axis, along the second) [m], from the floor outline."
    plan_m::NTuple{2, Float64}
    "Outline extent in plan-axis coordinates, (min, max) along the first axis then the second [m]."
    bounds_m::NTuple{4, Float64}
    "Closed floor loops [m], from the story's slab faces. Open rings."
    outline::Vector{Vector{NTuple{2, Float64}}}
end

"""
One solved ELF case.

`purpose = :strength` uses the strength Cs (`for_drift=false`).
`purpose = :drift` uses the drift Cs (`for_drift=true`), which drops
Eq. 12.8-6 and keeps Eq. 12.8-7.

`torsion = :none` is the story force at the master.
`:plus` adds `Mz = +F·e` and `:minus` adds `Mz = -F·e`, with `e` the 5%
accidental eccentricity. The two signs are the two sides. The code does
not assign which side is positive.

`θ` and `multiplier` are filled for `:drift` cases. A `:strength` case
leaves them `nothing`. The drift limit itself is not judged here.

`direction` is `:x` or `:y`, the first or second plan axis of the analysis.
Displacements and drifts are along that axis. `design_cross_drift_m` is the
design story drift along the other axis, at the same center of mass.
"""
struct ElfCase
    direction::Symbol
    purpose::Symbol
    torsion::Symbol
    Cs::Float64
    V_kN::Float64
    k::Float64
    Fx_kN::Vector{Float64}
    Vx_kN::Vector{Float64}
    Mz_kN_m::Vector{Float64}
    "Elastic displacement at the center of mass, in the force direction [m]."
    elastic_m::Vector{Float64}
    "Design Earthquake Displacement at the center of mass [m]. δdi = 0."
    design_m::Vector{Float64}
    "Elastic story drift at the center of mass [m]."
    elastic_drift_m::Vector{Float64}
    "Design story drift at the center of mass [m]."
    design_drift_m::Vector{Float64}
    θ::Vector{Union{Float64, Nothing}}
    multiplier::Vector{Union{Float64, Nothing}}
    "Ax from this case's edge drifts, or `nothing` when δavg is not positive."
    Ax::Vector{Union{Float64, Nothing}}
    "Design story drift at the center of mass along the other plan axis [m]."
    design_cross_drift_m::Vector{Float64}
end

ElfCase(direction, purpose, torsion, Cs, V_kN, k, Fx_kN, Vx_kN, Mz_kN_m, elastic_m,
        design_m, elastic_drift_m, design_drift_m, θ, multiplier, Ax) =
    ElfCase(direction, purpose, torsion, Cs, V_kN, k, Fx_kN, Vx_kN, Mz_kN_m, elastic_m,
            design_m, elastic_drift_m, design_drift_m, θ, multiplier, Ax,
            zeros(length(design_drift_m)))

"""
Levels above the base, lowest first, every solved ELF case, and the plan
axis the case directions refer to.
"""
struct ElfStoryAnalysis
    levels::Vector{ElfLevel}
    cases::Vector{ElfCase}
    "Unit vector of the first plan axis. `:y` cases act along it turned 90° counterclockwise."
    plan_axis::NTuple{2, Float64}
    "Full displacement of each case, same order as `cases`. Empty when no solve was stored."
    displacements::Vector{Vector{Float64}}
end

ElfStoryAnalysis(levels, cases, plan_axis::NTuple{2, <:Real}) =
    ElfStoryAnalysis(levels, cases, NTuple{2, Float64}(plan_axis), Vector{Float64}[])

ElfStoryAnalysis(levels, cases) = ElfStoryAnalysis(levels, cases, (1.0, 0.0))

"""Unit force vector of one case direction."""
elf_direction_vector(analysis::ElfStoryAnalysis, direction::Symbol) =
    plan_axis_vector(analysis.plan_axis, direction)

"""
    elf_story_analysis(struc; method, SDS, S1, R, Ie, T, Cd, β, ...,
                       Ry=nothing, Cdy=nothing, Ω0y=nothing) -> ElfStoryAnalysis

Apply ASCE 7-22 §12.8 story forces to the rigid-diaphragm masters and solve
them as one batch on the reduced stiffness.

`R`, `Cd`, and `Ω0` are the X-direction row. Pass `Ry`, `Cdy`, and `Ω0y`
together when the Y-direction row differs. Omitting them uses the X row in
both directions. ASCE 7-22 §12.2.2 (corpus: asce-7-22, PDF page 176).

A rigid diaphragm puts the story force and the accidental torsion on the
master. A flexible diaphragm splits `(Fx, Fy)` among the lines of
seismic-system walls by tributary seismic weight
([`diaphragm_story_loads`](@ref)) and does not apply the 5% eccentricity.
ASCE 7-22 §12.8.4.2.1 (corpus: asce-7-22, PDF page 187) requires accidental
torsion only where diaphragms are not flexible, so the moment is not
replaced by a couple. A flexible floor reads center-of-mass drift and θ
between its wall lines, and leaves Ax unset. A `:semirigid` membrane floor
takes the force on its nodes by seismic weight and the torsion as nodal
forces, and reads drift from its seismic-system walls
([`_semirigid_story_loads`](@ref), [`_semirigid_disp_at`](@ref)). The solved
displacement of every case is kept on the analysis so a later pier read does
not solve again. A full-plate `:shell` floor throws.

`method` is `:sds` (Eq. 12.8-3, which needs `SD1` and `TL`) or `:sa`
(Eq. 12.8-2, which needs `Sa`). `between` is `:two` or `:interpolate` when
`0.5 < T < 2.5`; there is no default. `β` is required and is not defaulted
to 1.0. Pass `Ω0` when you want the `β >= 1.25/Ω0` check.

`plan_axis` is the first principal plan axis (see [`LateralDesign`](@ref)).
The `:x` cases act along it and the `:y` cases along it turned 90°
counterclockwise. The 5% eccentricity uses the outline width perpendicular to
the force, and drifts are measured along the force. The default is global X.

# Citations
ASCE 7-22 §12.8.3, §12.8.4.2, §12.8.6, §12.8.7 (corpus: asce-7-22,
PDF pages 185–188). The equations themselves are cited on the
StructuralSizer functions this calls.
"""
function elf_story_analysis(struc::BuildingStructure;
                            method::Symbol,
                            SDS::Real,
                            S1::Real,
                            R::Real,
                            Ie::Real,
                            T::Real,
                            Cd::Real,
                            β::Real,
                            SD1::Union{Real, Nothing}=nothing,
                            TL::Union{Real, Nothing}=nothing,
                            Sa::Union{Real, Nothing}=nothing,
                            Ω0::Union{Real, Nothing}=nothing,
                            between::Union{Symbol, Nothing}=nothing,
                            Ry::Union{Real, Nothing}=nothing,
                            Cdy::Union{Real, Nothing}=nothing,
                            Ω0y::Union{Real, Nothing}=nothing,
                            plan_axis::Tuple{Real, Real}=(1.0, 0.0),
                            flexible_accidental_torsion::Bool=false)
    axis = unit_plan_axis(plan_axis)
    struc.asap_model.processed || throw(ArgumentError(
        "elf_story_analysis: the Asap model is not processed. Call to_asap! first."))

    levels = _elf_levels(struc, axis)
    weights = [lv.weight_kN for lv in levels]
    heights = [lv.height_m for lv in levels]
    W = sum(weights)
    W > 0 || throw(ArgumentError(
        "elf_story_analysis: effective seismic weight above the base is zero."))

    # ASCE 7-22 §12.8.3 (corpus: asce-7-22, PDF page 186). `between` is the
    # caller's choice of k = 2 or linear interpolation. This function does
    # not pick one.
    k = vertical_distribution_exponent(T; between=between)

    cases = ElfCase[]
    load_cases = Vector{Vector{Asap.AbstractLoad}}()
    recover = Tuple{Float64, Union{Float64, Nothing}}[]
    for purpose in (:strength, :drift)
        for_drift = purpose == :drift
        for direction in (:x, :y)
            Rd, Cdd, Ω0d = _elf_direction_factors(direction, R, Cd, Ω0, Ry, Cdy, Ω0y)
            Cs = _elf_cs(method, for_drift, SDS, S1, Rd, Ie, T, SD1, TL, Sa)
            V = seismic_base_shear(Cs, W)
            dist = vertical_distribution(weights, heights, V, k)
            Vx = seismic_story_shear(dist.Fx, heights)
            for torsion in (:none, :plus, :minus)
                Mz = _elf_moments(levels, dist.Fx, direction, torsion)
                push!(load_cases, _elf_loads(struc, levels, dist.Fx, Mz,
                                             plan_axis_vector(axis, direction);
                                             flexible_accidental_torsion))
                push!(cases, ElfCase(direction, purpose, torsion, Cs, V, k,
                    copy(dist.Fx), copy(Vx), Mz,
                    Float64[], Float64[], Float64[], Float64[],
                    Union{Float64, Nothing}[], Union{Float64, Nothing}[],
                    Union{Float64, Nothing}[]))
                push!(recover, (Cdd, Ω0d))
            end
        end
    end

    displacements = Asap.solve(struc.asap_model, load_cases, lateral_solve_links(struc))
    length(displacements) == length(cases) || throw(ArgumentError(
        "elf_story_analysis: the solve returned $(length(displacements)) cases, expected $(length(cases))."))

    layout = isempty(struc.asap_rigid_links) ? _require_masterless_layout(struc, axis) : nothing
    solved = ElfCase[]
    for (i, u) in enumerate(displacements)
        Cdd, Ω0d = recover[i]
        push!(solved, _elf_recover(cases[i], levels, u, Ie, Cdd, β, Ω0d, axis, layout))
    end
    return ElfStoryAnalysis(levels, solved, axis, displacements)
end

"""
R, Cd, and Ω0 of one direction.

The Y row is used only when `Ry`, `Cdy`, and `Ω0y` are all passed.
ASCE 7-22 §12.2.2 (corpus: asce-7-22, PDF page 176).
"""
function _elf_direction_factors(direction::Symbol, R, Cd, Ω0, Ry, Cdy, Ω0y)
    yset = (Ry !== nothing, Cdy !== nothing, Ω0y !== nothing)
    if any(yset) && !all(yset)
        throw(ArgumentError(
            "elf_story_analysis: Ry, Cdy, and Ω0y are one Table 12.2-1 row. " *
            "Pass all three, or none to use R, Cd, and Ω0 in both directions. " *
            "ASCE 7-22 §12.2.2 (corpus: asce-7-22, PDF page 176)."))
    end
    direction === :y && Ry !== nothing && return Ry, Cdy, Ω0y
    return R, Cd, Ω0
end

"""Cs for one purpose. Missing :sds / :sa inputs throw here, before any solve."""
function _elf_cs(method, for_drift, SDS, S1, R, Ie, T, SD1, TL, Sa)
    if method == :sds
        SD1 === nothing && throw(ArgumentError(
            "elf_story_analysis: method :sds requires SD1."))
        TL === nothing && throw(ArgumentError(
            "elf_story_analysis: method :sds requires TL."))
        # ASCE 7-22 Eqs. 12.8-3, 12.8-4, 12.8-5 (corpus: asce-7-22, PDF page 185).
        return seismic_response_coefficient(; method=:sds, SDS, S1, R, Ie,
            SD1, T, TL, for_drift)
    elseif method == :sa
        Sa === nothing && throw(ArgumentError(
            "elf_story_analysis: method :sa requires Sa. Do not use :sa where " *
            "ASCE 7-22 §11.4.5 Exception 2 applies; this function does not check that."))
        # ASCE 7-22 Eq. 12.8-2 (corpus: asce-7-22, PDF page 185).
        return seismic_response_coefficient(; method=:sa, SDS, S1, R, Ie, Sa, for_drift)
    end
    throw(ArgumentError(
        "elf_story_analysis: method must be :sa or :sds; got $(repr(method))."))
end

"""Stories that have faces, in skeleton order. Each entry is `(idx, z, outline)`."""
function _faced_story_floors(skel)
    raw = NamedTuple[]
    for (idx, story) in skel.stories
        isempty(story.faces) && continue
        z = ustrip(u"m", story.elevation)
        push!(raw, (; idx, z, outline=story_floor_outline(skel, story)))
    end
    return raw
end

"""
Base elevation and the stories above it, lowest first.

`label` names the analysis in the error. The 1e-6 m gap that keeps the base
out of the list is the split wind and ELF already share. It is not
[`WALL_CUT_ZTOL_M`](@ref).
"""
function _stories_above_base(raw, label::AbstractString)
    isempty(raw) && throw(ArgumentError(
        "$label: the skeleton has no story with faces."))
    z_base = minimum(item.z for item in raw)
    above = [item for item in raw if item.z > z_base + 1e-6]
    isempty(above) && throw(ArgumentError(
        "$label: no story sits above the base elevation $(z_base) m."))
    sort!(above; by=item -> item.z)
    return z_base, above
end

"""
Rigid-diaphragm master at elevation `z`.

`nothing` when the building has no rigid links. A building that has links
and no master at this story throws. `label` names the analysis.
"""
function _level_master(struc, master_at, z, story_idx, label::AbstractString)
    master = get(master_at, round(Int, z * 1000), nothing)
    if master === nothing && !isempty(struc.asap_rigid_links)
        throw(ArgumentError(
            "$label: story $(story_idx) at $(z) m has no rigid-diaphragm master."))
    end
    return master
end

"Story height below `z`. Zero or negative throws. `label` names the analysis."
function _story_height_below(z, z_below, story_idx, label::AbstractString)
    hsx = z - z_below
    hsx > 0 || throw(ArgumentError(
        "$label: story height below story $(story_idx) is $(hsx) m."))
    return hsx
end

"""Masters already elected by the rigid-link pass, keyed by story elevation in millimetres."""
function _elf_masters(struc)
    story_z = _story_elevation_keys(struc.skeleton)
    master_at = Dict{Int, Asap.Node}()
    for link in struc.asap_rigid_links
        zk = round(Int, ustrip(u"m", link.nodeA.position[3]) * 1000)
        zk in story_z || continue
        master_at[zk] = link.nodeA
    end
    return master_at
end

"""Story elevations [m], one per skeleton story, in dict order."""
function _elf_story_elevations(skel)
    zs = Float64[]
    for (_, story) in skel.stories
        push!(zs, ustrip(u"m", story.elevation))
    end
    return zs
end

"""
Millimetre key of the story elevation within 1 mm of `z_m`.

Two story elevations inside that window throw. An elevation that matches
none throws. Self-weight is not left on a height that is not a floor.
"""
function _elf_elevation_key(z_m, elevs)
    best = 0
    best_d = Inf
    for (i, z) in pairs(elevs)
        d = abs(z - z_m)
        if d < best_d
            best_d = d
            best = i
        end
    end
    best_d <= 1e-3 || throw(ArgumentError(
        "elf_story_analysis: elevation $(z_m) m is more than 1 mm from every " *
        "story elevation ($(join(elevs, ", ")) m). Self-weight is assigned to " *
        "story levels only."))
    nclose = count(z -> abs(z - z_m) <= 1e-3, elevs)
    nclose == 1 || throw(ArgumentError(
        "elf_story_analysis: elevation $(z_m) m is within 1 mm of $(nclose) " *
        "story elevations."))
    return round(Int, elevs[best] * 1000)
end

"""Add `w` kN at plan `(x, y)` on story key `key`."""
function _elf_deposit!(acc, key, w, x, y, allowed)
    key in allowed || throw(ArgumentError(
        "elf_story_analysis: self-weight at elevation $(key) mm is neither the " *
        "base nor a level above the base."))
    prev = get(acc, key, (0.0, 0.0, 0.0))
    acc[key] = (prev[1] + w, prev[2] + w * x, prev[3] + w * y)
    return nothing
end

"""Unfactored `ρ t g A` of one wall triangle [kN]. `g` is [`Asap.GRAVITY`](@ref)."""
function _shell_self_weight_kN(sh::Asap.ShellTri3)
    sh.area > 0 || throw(ArgumentError(
        "elf_story_analysis: a wall shell has no area. Self-weight is ρ t g times area."))
    sh.ρ >= 0 || throw(ArgumentError(
        "elf_story_analysis: a wall shell has density $(sh.ρ) kg/m^3."))
    sh.thickness >= 0 || throw(ArgumentError(
        "elf_story_analysis: a wall shell has thickness $(sh.thickness) m."))
    # Same pressure as the unfactored dead case (`wall_self_weight_loads`).
    p = unfactored_wall_self_weight_pressure(sh)
    return ustrip(u"kN", p * sh.area * u"m^2")
end

"""
Unfactored `ρ A g L` of one frame [`Asap.GravityLoad`](@ref) [kN].

`load.factor` on the building model carries the strength dead factor
([`member_self_weight_acceleration`](@ref)), so the weight uses `g`.
"""
function _gravity_load_weight_kN(ld::Asap.GravityLoad)
    el = ld.element
    sec = el.section
    isnothing(sec) && throw(ArgumentError(
        "elf_story_analysis: a GravityLoad has no section. Frame self-weight is ρ A g L."))
    ρ = ustrip(u"kg/m^3", sec.ρ)
    A = ustrip(u"m^2", sec.A)
    ρ >= 0 || throw(ArgumentError(
        "elf_story_analysis: a GravityLoad section has density $(sec.ρ)."))
    A >= 0 || throw(ArgumentError(
        "elf_story_analysis: a GravityLoad section has area $(sec.A)."))
    g = ustrip(u"m/s^2", GRAVITY)
    L = ustrip(u"m", length(el))
    L > 0 || throw(ArgumentError(
        "elf_story_analysis: a GravityLoad member has length $(L) m."))
    return ρ * A * g * L / 1000
end

"""Plan coordinates and elevation of a frame node [m]."""
function _elf_node_xyz(node)
    p = node.position
    return (ustrip(u"m", p[1]), ustrip(u"m", p[2]), ustrip(u"m", p[3]))
end

"""
Wall-shell, frame, and drop-panel self-weight, item by item, at the story elevations.

Each item is `(key, weight_kN, a, b)`: a weight on story key `key` (millimetres)
spread uniformly along the plan segment from `a` to `b` [m]. A point is
`a == b`. Returns `(items, total_kN)`, `total_kN` being the sum of the sources.

# Engineering judgment
ASCE 7-22 §12.7.2 (corpus: asce-7-22, PDF page 184) includes the dead load
above the base and does not say how to assign a member that spans a story.
§12.8.7 (PDF page 188) likewise defines Px as the total vertical design load
at and above the level. User decision 2026-10-31: half of each wall, and half
of each frame member, goes to the story elevation at each end. A beam has
both ends at one elevation, so this places its whole weight on that floor.
The share that lands on the base elevation is not above the base.
A wall's half lies along its plan length, the segment whose centroid is the
plan midpoint; the wall's mass does not move in plan over the story.
"""
function _elf_weight_items(struc, elevs)
    _require_wall_shells_accounted(struc)
    items = Tuple{Int, Float64, NTuple{2, Float64}, NTuple{2, Float64}}[]
    total = 0.0

    for pier in struc.wall_mesh.piers
        (1 <= pier.wall_index <= length(struc.walls)) || throw(ArgumentError(
            "elf_story_analysis: pier wall index $(pier.wall_index) is outside " *
            "1:$(length(struc.walls))."))
        wall = struc.walls[pier.wall_index]
        span = _wall_pier_geometry(wall, struc.skeleton)
        w = 0.0
        for sh in pier.shells
            w += _shell_self_weight_kN(sh)
        end
        a = (span.x1, span.y1)
        b = (span.x2, span.y2)
        push!(items, (_elf_elevation_key(span.z_bot, elevs), 0.5 * w, a, b))
        push!(items, (_elf_elevation_key(span.z_top, elevs), 0.5 * w, a, b))
        total += w
    end

    model = struc.asap_model
    for ld in model.loads
        ld isa Asap.GravityLoad || continue
        w = _gravity_load_weight_kN(ld)
        x1, y1, z1 = _elf_node_xyz(ld.element.nodeStart)
        x2, y2, z2 = _elf_node_xyz(ld.element.nodeEnd)
        push!(items, (_elf_elevation_key(z1, elevs), 0.5 * w, (x1, y1), (x1, y1)))
        push!(items, (_elf_elevation_key(z2, elevs), 0.5 * w, (x2, y2), (x2, y2)))
        total += w
    end
    # Fire-protection coating is dead load on the same members, lumped the same way.
    for ld in unfactored_fire_coating_loads(model)
        w = abs(ustrip(u"N/m", ld.value[3])) * ustrip(u"m", length(ld.element)) / 1000
        x1, y1, z1 = _elf_node_xyz(ld.element.nodeStart)
        x2, y2, z2 = _elf_node_xyz(ld.element.nodeEnd)
        push!(items, (_elf_elevation_key(z1, elevs), 0.5 * w, (x1, y1), (x1, y1)))
        push!(items, (_elf_elevation_key(z2, elevs), 0.5 * w, (x2, y2), (x2, y2)))
        total += w
    end
    # Drop panels hang below the slab at the column top, so all of each
    # drop's weight goes to that floor elevation.
    for ld in unfactored_drop_panel_loads(struc)
        w = abs(ustrip(u"kN", ld.value[3]))
        x, y, z = _elf_node_xyz(ld.node)
        push!(items, (_elf_elevation_key(z, elevs), w, (x, y), (x, y)))
        total += w
    end
    return items, total
end

"""
Wall-shell and frame self-weight lumped onto story elevations.

Returns `(lumps, total_kN)`. `lumps` is a dict of millimetre elevation key to
`(weight_kN, weight·x, weight·y)`, with each item at its plan centroid.
`total_kN` is the sum before lumping. See [`_elf_weight_items`](@ref).
"""
function _elf_self_weight(struc, elevs, allowed)
    items, total = _elf_weight_items(struc, elevs)
    acc = Dict{Int, NTuple{3, Float64}}()
    for (key, w, a, b) in items
        _elf_deposit!(acc, key, w, 0.5 * (a[1] + b[1]), 0.5 * (a[2] + b[2]), allowed)
    end

    lumped = 0.0
    for (w, _, _) in values(acc)
        lumped += w
    end
    abs(lumped - total) <= 1e-6 || throw(ArgumentError(
        "elf_story_analysis: lumped self-weight $(lumped) kN does not match " *
        "the wall and frame sources $(total) kN."))
    return acc, total
end

"""
Every `:wall` shell on the model belongs to one pier, and every wall was meshed.

The dead case sums those shells. A shell missing from `wall_mesh` would be
missing from W.
"""
function _require_wall_shells_accounted(struc)
    if !isempty(struc.walls) && length(struc.wall_mesh.piers) != length(struc.walls)
        throw(ArgumentError(
            "elf_story_analysis: the building has $(length(struc.walls)) walls and " *
            "$(length(struc.wall_mesh.piers)) meshed piers. Run to_asap! so wall " *
            "self-weight is on the same mesh as the dead case."))
    end
    owned = Set{UInt64}()
    for pier in struc.wall_mesh.piers
        for sh in pier.shells
            push!(owned, objectid(sh))
        end
    end
    model = struc.asap_model
    isnothing(model) && return nothing
    for sh in model.shell_elements
        (sh isa Asap.ShellTri3 && sh.id === :wall) || continue
        objectid(sh) in owned || throw(ArgumentError(
            "elf_story_analysis: a :wall shell is not in wall_mesh. Its self-weight " *
            "would be in the dead case and missing from W. Run to_asap!."))
    end
    return nothing
end

"""
Levels above the base, lowest first.

The base is the lowest story elevation. A story at that elevation is the
base, not a level, and its weight is not given an `Fx` (the height from the
base would be zero, which Eq. 12.8-13 rejects). `Px` is the expected gravity
at the level and above it.

Wall and frame self-weight are added here. See [`_elf_self_weight`](@ref).
Plan widths and extents are along the plan axes of `axis`.
"""
function _elf_levels(struc, axis::NTuple{2, Float64}=(1.0, 0.0))
    e1, e2 = plan_axes(axis)
    skel = struc.skeleton
    cell_by_face = Dict{Int, eltype(struc.cells)}()
    for cell in struc.cells
        haskey(cell_by_face, cell.face_idx) && throw(ArgumentError(
            "elf_story_analysis: duplicate Cell.face_idx $(cell.face_idx)."))
        cell_by_face[cell.face_idx] = cell
    end

    master_at = _elf_masters(struc)
    raw = NamedTuple[]
    for (idx, story) in skel.stories
        isempty(story.faces) && continue
        z = ustrip(u"m", story.elevation)
        # The floor outline, not the axis-aligned box, is the plan the
        # accidental eccentricity is measured on. For a rectangle the
        # projected widths equal the box.
        outline = story_floor_outline(skel, story)
        pts = Tuple{Float64,Float64}[]
        for loop in outline
            append!(pts, loop)
        end
        a1min, a1max = extrema(p[1] * e1[1] + p[2] * e1[2] for p in pts)
        a2min, a2max = extrema(p[1] * e2[1] + p[2] * e2[2] for p in pts)
        # The width perpendicular to e2 is the extent along e1, and the reverse.
        x_extent = projected_plan_width(pts, e2)
        y_extent = projected_plan_width(pts, e1)
        weight = 0.0
        gravity = 0.0
        n_cells = 0
        # :grade and :unknown are omitted from the unfactored dead case. A cell
        # of either type above the base would be in W and absent from that case.
        omitted_floor = false
        for face in story.faces
            cell = get(cell_by_face, face, nothing)
            cell === nothing && continue
            n_cells += 1
            if cell.floor_type == :grade || cell.floor_type == :unknown
                omitted_floor = true
            end
            # ASCE 7-22 §12.7.2 (corpus: asce-7-22, PDF page 184): dead load.
            # The items a Cell cannot carry are not invented here.
            weight += ustrip(u"kN", effective_seismic_weight(cell))
            D = ustrip(u"kN", (cell.self_weight + cell.sdl) * cell.area)
            L0 = ustrip(u"kN", cell.live_load * cell.area)
            # The 100 lb/ft² threshold is on the unreduced intensity, per cell.
            psf = ustrip(u"psf", cell.live_load)
            # ASCE 7-22 §12.8.6.1 (corpus: asce-7-22, PDF page 187).
            gravity += drift_expected_gravity_load(D, L0, psf)
        end
        push!(raw, (; idx, z, weight, gravity, n_cells, omitted_floor,
            plan=(x_extent, y_extent),
            bounds=(a1min, a1max, a2min, a2max),
            outline=outline))
    end
    z_base, above = _stories_above_base(raw, "elf_story_analysis")
    for item in above
        item.omitted_floor && throw(ArgumentError(
            "elf_story_analysis: story $(item.idx) at $(item.z) m has a :grade or " *
            ":unknown cell. That dead load would be in W and is omitted from the " *
            "unfactored dead case."))
    end

    elevs = _elf_story_elevations(skel)
    base_key = _elf_elevation_key(z_base, elevs)
    allowed = Set{Int}([base_key])
    for item in above
        push!(allowed, _elf_elevation_key(item.z, elevs))
    end
    # ASCE 7-22 §12.7.2 (corpus: asce-7-22, PDF page 184): dead load above the
    # base, including walls and frames. §12.8.6.1 and §12.8.7 (PDF pages 187–188):
    # the same dead load is in Px. The half-story split is `_elf_self_weight`.
    lumps, total_sw = _elf_self_weight(struc, elevs, allowed)
    base_sw = get(lumps, base_key, (0.0, 0.0, 0.0))[1]

    levels = ElfLevel[]
    for (i, item) in enumerate(above)
        item.n_cells > 0 || throw(ArgumentError(
            "elf_story_analysis: story $(item.idx) is above the base and has no load cells."))
        master = _level_master(struc, master_at, item.z, item.idx, "elf_story_analysis")
        z_below = i == 1 ? z_base : above[i - 1].z
        hsx = _story_height_below(item.z, z_below, item.idx, "elf_story_analysis")
        key = _elf_elevation_key(item.z, elevs)
        w_sw, mx, my = get(lumps, key, (0.0, 0.0, 0.0))
        w_cell = item.weight
        # Self-weight is dead load and carries no floor live load, so 0.5L is
        # zero on this share. ASCE 7-22 §12.8.6.1 (corpus: asce-7-22, PDF page 187).
        weight = w_cell + w_sw
        gravity = item.gravity + w_sw
        cm_cell = story_center_of_mass(skel, skel.stories[item.idx], struc.cells)
        cm = ((w_cell * cm_cell[1] + mx) / weight, (w_cell * cm_cell[2] + my) / weight)
        push!(levels, ElfLevel(item.idx, item.z, item.z - z_base, hsx,
            weight, gravity, 0.0, master, cm, item.plan, item.bounds,
            item.outline))
    end

    above_cells = sum(item.weight for item in above)
    above_w = sum(lv.weight_kN for lv in levels)
    # Slab dead above the base, plus every wall and frame kilogram, equals the
    # level weights plus the share left at the base.
    expected = above_cells + (total_sw - base_sw)
    abs(above_w - expected) <= 1e-6 || throw(ArgumentError(
        "elf_story_analysis: level dead load $(above_w) kN does not match " *
        "slab dead above the base plus self-weight above the base ($(expected) kN)."))

    # Px is the expected gravity at the level and above, same accumulation
    # as story shear. Walk from the top down.
    px = 0.0
    for i in reverse(eachindex(levels))
        px += levels[i].gravity_kN
        levels[i] = ElfLevel(levels[i].story, levels[i].elevation_m,
            levels[i].height_m, levels[i].story_height_m, levels[i].weight_kN,
            levels[i].gravity_kN, px, levels[i].master, levels[i].center_of_mass,
            levels[i].plan_m, levels[i].bounds_m, levels[i].outline)
    end
    return levels
end

"""
Accidental torsion `Mz = ±F·e` at each level [kN·m].

`e` is 5% of the plan dimension perpendicular to the force, the projected
width of that story's floor outline. `:none` is a zero moment. `:plus` is `+F·e`.
"""
function _elf_moments(levels, Fx, direction, torsion)
    sign = torsion == :plus ? 1.0 : torsion == :minus ? -1.0 : 0.0
    Mz = Vector{Float64}(undef, length(levels))
    for i in eachindex(levels)
        # Perpendicular to X is the Y dimension, and the reverse.
        span = direction == :x ? levels[i].plan_m[2] : levels[i].plan_m[1]
        # ASCE 7-22 §12.8.4.2 (corpus: asce-7-22, PDF page 187).
        e = accidental_eccentricity(span)
        Mz[i] = sign * Fx[i] * e
    end
    return Mz
end

"""
Nodal force along the unit plan vector `d`.

A rigid diaphragm also takes the torsional moment when it is nonzero.
A flexible diaphragm does not. ASCE 7-22 §12.8.4.2.1 (corpus: asce-7-22,
PDF page 187) applies accidental torsion only where diaphragms are not flexible.
`flexible_accidental_torsion` adds it anyway, as a couple between the two
farthest wall lines, on top of the tributary split.
"""
function _elf_loads(struc, levels, Fx, Mz, d::NTuple{2, Float64};
                    flexible_accidental_torsion::Bool=false)
    Fxg = [Fx[i] * d[1] for i in eachindex(Fx)]
    Fyg = [Fx[i] * d[2] for i in eachindex(Fx)]
    loads = diaphragm_story_loads(struc, levels, Fxg, Fyg, Mz;
        force_id=:elf_story, moment_id=:elf_torsion)
    if flexible_accidental_torsion && struc.diaphragm_layout isa FlexibleDiaphragmLayout
        for i in eachindex(levels)
            append!(loads, _flexible_couple_loads(struc, levels[i].elevation_m, Mz[i],
                :elf_torsion, "accidental torsion: level $(levels[i].story)",
                "ASCE 7-22 §12.8.4.2 (corpus: asce-7-22, PDF page 187)"))
        end
    end
    return loads
end

"""
Displacement of the rigid floor at plan point `(x, y)`, along the unit plan vector `d`.

The rigid link enforces `u_B = u_A + θ_A × r_AB`, so
`u_x = u_xm − θz·(y − ym)` and `u_y = u_ym + θz·(x − xm)`.
"""
function _elf_disp_at(u, master, x, y, d::NTuple{2, Float64})
    xm = ustrip(u"m", master.position[1])
    ym = ustrip(u"m", master.position[2])
    gid = master.globalID
    θz = u[gid[6]]
    ux = u[gid[1]] - θz * (y - ym)
    uy = u[gid[2]] + θz * (x - xm)
    return ux * d[1] + uy * d[2]
end

"""
Elastic and design drift, θ, and Ax for one solved case.

A rigid floor reads each level at its own center of mass from the master.
A flexible floor reads it between the wall lines of `layout`
([`_flexible_disp_at`](@ref)), and the story below at the vertical projection
of this level's center of mass. Ax is left unset on a flexible floor: the
torsional irregularity ratio does not apply to flexible diaphragms (ASCE 7-22
§12.3.2.1.1, corpus: asce-7-22, PDF page 181).

A semirigid floor reads each level, and the edges for Ax, from the plan rigid
motion fitted to its seismic-system wall tops ([`_semirigid_disp_at`](@ref)).
"""
function _elf_recover(case, levels, u, Ie, Cd, β, Ω0, axis::NTuple{2, Float64}=(1.0, 0.0),
                      layout=nothing)
    flexible = levels[1].master === nothing
    if flexible
        any(lv -> lv.master !== nothing, levels) && throw(ArgumentError(
            "elf_story_analysis: some levels have a rigid master and some do not."))
        layout === nothing && throw(ArgumentError(
            "elf_story_analysis: a floor without a rigid master needs its wall " *
            "lines (flexible) or its seismic-system walls (semirigid) to read " *
            "the center-of-mass drift."))
    end
    semirigid = layout isa SemirigidDiaphragmLayout
    d = plan_axis_vector(axis, case.direction)
    cross_dir = case.direction === :x ? :y : :x
    other = plan_axis_vector(axis, cross_dir)
    n = length(levels)
    elastic = Vector{Float64}(undef, n)
    design = Vector{Float64}(undef, n)
    elastic_drift = Vector{Float64}(undef, n)
    design_drift = Vector{Float64}(undef, n)
    theta = Vector{Union{Float64, Nothing}}(undef, n)
    mult = Vector{Union{Float64, Nothing}}(undef, n)
    Ax = Vector{Union{Float64, Nothing}}(undef, n)
    cross_drift = Vector{Float64}(undef, n)
    cross_below = 0.0

    # θmax does not depend on the story. A :drift case that exceeds it throws.
    θmax = case.purpose == :drift ? stability_coefficient_limit(β, Cd; Ω0=Ω0) : nothing

    for i in 1:n
        lv = levels[i]
        cm = lv.center_of_mass
        if flexible
            # ASCE 7-22 §12.8.6.5 (corpus: asce-7-22, PDF page 188): where the
            # centers of mass do not align, the bottom of the story may be read
            # at the vertical projection of the center of mass at the top.
            δe = _floor_disp_at(u, layout, lv.elevation_m, case.direction, cm)
            δe_below = i == 1 ? 0.0 :
                _floor_disp_at(u, layout, levels[i - 1].elevation_m, case.direction, cm)
            δc = _floor_disp_at(u, layout, lv.elevation_m, cross_dir, cm)
            δc_below = i == 1 ? 0.0 :
                _floor_disp_at(u, layout, levels[i - 1].elevation_m, cross_dir, cm)
        else
            δe = _elf_disp_at(u, lv.master, cm[1], cm[2], d)
            δe_below = i == 1 ? 0.0 : elastic[i - 1]
            δc = _elf_disp_at(u, lv.master, cm[1], cm[2], other)
            δc_below = cross_below
            cross_below = δc
        end
        # The same center of mass, read along the other axis. This is what the
        # §12.5.1.2 combinations add as the 30% share of story drift.
        cross_drift[i] = design_story_drift(
            design_earthquake_displacement(Cd, δc, Ie, 0.0),
            design_earthquake_displacement(Cd, δc_below, Ie, 0.0))
        # δdi = 0: in-plane diaphragm deformation is neglected, which
        # §12.8.6.5 and commentary C12.8.6 (PDF page 729) permit for drift.
        # ASCE 7-22 Eq. 12.8-16 (corpus: asce-7-22, PDF page 187).
        δDE = design_earthquake_displacement(Cd, δe, Ie, 0.0)
        δDE_below = design_earthquake_displacement(Cd, δe_below, Ie, 0.0)
        elastic[i] = δe
        design[i] = δDE
        # Story drift is the difference of the displacements at the top and
        # bottom of the story. The design difference is §12.8.6.5 at the
        # center of mass (corpus: asce-7-22, PDF page 188).
        Δe = δe - δe_below
        elastic_drift[i] = Δe
        design_drift[i] = design_story_drift(δDE, δDE_below)

        if case.purpose == :drift
            # Eq. 12.8-18 uses the elastic story drift at the §12.8.6.5
            # location. The sign is the direction of motion; the coefficient
            # uses the magnitude.
            θ = stability_coefficient(lv.px_kN, lv.story_height_m, case.Vx_kN[i], abs(Δe))
            theta[i] = θ
            mult[i] = pdelta_displacement_multiplier(θ, θmax)
        else
            theta[i] = nothing
            mult[i] = nothing
        end

        Ax[i] = nothing
        flexible && !semirigid && continue
        d1, d2 = semirigid ?
            _semirigid_edge_drifts(u, layout, levels, i, case.direction, axis) :
            _elf_edge_drifts(u, levels, i, case.direction, axis)
        δmax = max(d1, d2)
        δavg = 0.5 * (d1 + d2)
        if δavg > 0 && δmax >= 0
            # ASCE 7-22 Eq. 12.8-15, computed at Ax = 1 (corpus: asce-7-22, PDF page 187).
            Ax[i] = torsional_amplification(δmax, δavg)
        end
    end

    return ElfCase(case.direction, case.purpose, case.torsion, case.Cs, case.V_kN,
        case.k, case.Fx_kN, case.Vx_kN, case.Mz_kN_m,
        elastic, design, elastic_drift, design_drift, theta, mult, Ax, cross_drift)
end

"""
Story drifts at the two edges perpendicular to the force, from the rigid-floor field.

The edges are the outline extremes across the force, on the line through the
master. Coordinates are along the plan axes.
"""
function _elf_edge_drifts(u, levels, i, direction, axis::NTuple{2, Float64}=(1.0, 0.0))
    e1, e2 = plan_axes(axis)
    d = direction === :x ? e1 : e2
    lv = levels[i]
    a1min, a1max, a2min, a2max = lv.bounds_m
    xm = ustrip(u"m", lv.master.position[1])
    ym = ustrip(u"m", lv.master.position[2])
    m1 = xm * e1[1] + ym * e1[2]
    m2 = xm * e2[1] + ym * e2[2]
    below = i == 1 ? nothing : levels[i - 1]
    coords = direction === :x ? ((m1, a2min), (m1, a2max)) : ((a1min, m2), (a1max, m2))
    drifts = ntuple(2) do j
        c1, c2 = coords[j]
        x = c1 * e1[1] + c2 * e2[1]
        y = c1 * e1[2] + c2 * e2[2]
        top = _elf_disp_at(u, lv.master, x, y, d)
        bot = below === nothing ? 0.0 : _elf_disp_at(u, below.master, x, y, d)
        return top - bot
    end
    return drifts
end
