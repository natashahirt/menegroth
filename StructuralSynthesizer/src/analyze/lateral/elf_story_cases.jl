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
# - δdi = 0. The rigid link neglects in-plane diaphragm deformation, which
#   §12.8.6 permits when computing story drift.

"""One level above the base that receives an ELF story force."""
struct ElfLevel
    story::Int
    elevation_m::Float64
    "Height from the base to this level [m]. ASCE 7-22 Eq. 12.8-13."
    height_m::Float64
    "Story height below this level, hsx [m]. ASCE 7-22 Eq. 12.8-18."
    story_height_m::Float64
    "Effective seismic weight of this level [kN]. Dead load only."
    weight_kN::Float64
    "Expected gravity on this level alone [kN]. 1.0D + 0.5L."
    gravity_kN::Float64
    "Expected gravity at this level and above [kN]. Px in Eq. 12.8-18."
    px_kN::Float64
    master::Asap.Node
    "Center of mass [m], the §12.8.6.5 drift point."
    center_of_mass::NTuple{2, Float64}
    "Projected plan widths (X extent, Y extent) [m], from the floor outline."
    plan_m::NTuple{2, Float64}
    "Vertex extent of the floor outline, (xmin, xmax, ymin, ymax) [m]."
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
end

"""Levels above the base, lowest first, and every solved ELF case."""
struct ElfStoryAnalysis
    levels::Vector{ElfLevel}
    cases::Vector{ElfCase}
end

"""
    elf_story_analysis(struc; method, SDS, S1, R, Ie, T, Cd, β, ...) -> ElfStoryAnalysis

Apply ASCE 7-22 §12.8 story forces to the rigid-diaphragm masters and solve
them as one batch on the reduced stiffness.

`struc` must already have been through `to_asap!(; diaphragms=:rigid)` with
slabs, so `asap_rigid_links` is non-empty. Any other diaphragm throws.

`method` is `:sds` (Eq. 12.8-3, which needs `SD1` and `TL`) or `:sa`
(Eq. 12.8-2, which needs `Sa`). `between` is `:two` or `:interpolate` when
`0.5 < T < 2.5`; there is no default. `β` is required and is not defaulted
to 1.0. Pass `Ω0` when you want the `β >= 1.25/Ω0` check.

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
                            between::Union{Symbol, Nothing}=nothing)
    isempty(struc.asap_rigid_links) && throw(ArgumentError(
        "elf_story_analysis: story forces and accidental torsion use the rigid-diaphragm " *
        "masters. asap_rigid_links is empty. Call to_asap!(struc; diaphragms=:rigid) " *
        "with slabs present. A flexible diaphragm is a different distribution."))
    struc.asap_model.processed || throw(ArgumentError(
        "elf_story_analysis: the Asap model is not processed. Call to_asap! first."))

    levels = _elf_levels(struc)
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
    for purpose in (:strength, :drift)
        for_drift = purpose == :drift
        Cs = _elf_cs(method, for_drift, SDS, S1, R, Ie, T, SD1, TL, Sa)
        V = seismic_base_shear(Cs, W)
        dist = vertical_distribution(weights, heights, V, k)
        Vx = seismic_story_shear(dist.Fx, heights)
        for direction in (:x, :y)
            for torsion in (:none, :plus, :minus)
                Mz = _elf_moments(levels, dist.Fx, direction, torsion)
                push!(load_cases, _elf_loads(levels, dist.Fx, Mz, direction))
                push!(cases, ElfCase(direction, purpose, torsion, Cs, V, k,
                    copy(dist.Fx), copy(Vx), Mz,
                    Float64[], Float64[], Float64[], Float64[],
                    Union{Float64, Nothing}[], Union{Float64, Nothing}[],
                    Union{Float64, Nothing}[]))
            end
        end
    end

    displacements = Asap.solve(struc.asap_model, load_cases, struc.asap_rigid_links)
    length(displacements) == length(cases) || throw(ArgumentError(
        "elf_story_analysis: the solve returned $(length(displacements)) cases, expected $(length(cases))."))

    solved = ElfCase[]
    for (i, u) in enumerate(displacements)
        push!(solved, _elf_recover(cases[i], levels, u, Ie, Cd, β, Ω0))
    end
    return ElfStoryAnalysis(levels, solved)
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

"""
Levels above the base, lowest first.

The base is the lowest story elevation. A story at that elevation is the
base, not a level, and its weight is not given an `Fx` (the height from the
base would be zero, which Eq. 12.8-13 rejects). `Px` is the expected gravity
at the level and above it.
"""
function _elf_levels(struc)
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
        xs = [p[1] for p in pts]
        ys = [p[2] for p in pts]
        xmin, xmax = extrema(xs)
        ymin, ymax = extrema(ys)
        # (0, 1) measures the width perpendicular to Y, which is the X extent.
        x_extent = projected_plan_width(pts, (0.0, 1.0))
        y_extent = projected_plan_width(pts, (1.0, 0.0))
        weight = 0.0
        gravity = 0.0
        n_cells = 0
        for face in story.faces
            cell = get(cell_by_face, face, nothing)
            cell === nothing && continue
            n_cells += 1
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
        push!(raw, (; idx, z, weight, gravity, n_cells,
            plan=(x_extent, y_extent),
            bounds=(xmin, xmax, ymin, ymax),
            outline=outline))
    end
    isempty(raw) && throw(ArgumentError(
        "elf_story_analysis: the skeleton has no story with faces."))

    z_base = minimum(item.z for item in raw)
    above = [item for item in raw if item.z > z_base + 1e-6]
    isempty(above) && throw(ArgumentError(
        "elf_story_analysis: no story sits above the base elevation $(z_base) m."))
    sort!(above; by=item -> item.z)

    levels = ElfLevel[]
    for (i, item) in enumerate(above)
        item.n_cells > 0 || throw(ArgumentError(
            "elf_story_analysis: story $(item.idx) is above the base and has no load cells."))
        zk = round(Int, item.z * 1000)
        haskey(master_at, zk) || throw(ArgumentError(
            "elf_story_analysis: story $(item.idx) at $(item.z) m has no rigid-diaphragm master."))
        z_below = i == 1 ? z_base : above[i - 1].z
        hsx = item.z - z_below
        hsx > 0 || throw(ArgumentError(
            "elf_story_analysis: story height below story $(item.idx) is $(hsx) m."))
        master = master_at[zk]
        cm = story_center_of_mass(skel, skel.stories[item.idx], struc.cells)
        push!(levels, ElfLevel(item.idx, item.z, item.z - z_base, hsx,
            item.weight, item.gravity, 0.0, master, cm, item.plan, item.bounds,
            item.outline))
    end

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

"""Nodal force, and the torsional moment when it is nonzero, at each master."""
function _elf_loads(levels, Fx, Mz, direction)
    loads = Asap.AbstractLoad[]
    z = 0.0 * u"kN"
    for i in eachindex(levels)
        fx = direction == :x ? Fx[i] * u"kN" : 0.0 * u"kN"
        fy = direction == :y ? Fx[i] * u"kN" : 0.0 * u"kN"
        if Fx[i] != 0.0
            push!(loads, Asap.NodeForce(levels[i].master, [fx, fy, z], :elf_story))
        end
        if Mz[i] != 0.0
            push!(loads, Asap.NodeMoment(levels[i].master,
                [0.0 * u"kN*m", 0.0 * u"kN*m", Mz[i] * u"kN*m"], :elf_torsion))
        end
    end
    isempty(loads) && throw(ArgumentError(
        "elf_story_analysis: a case produced no story force and no torsion."))
    return loads
end

"""
Displacement of the rigid floor at plan point `(x, y)`, in the force direction.

The rigid link enforces `u_B = u_A + θ_A × r_AB`, so
`u_x = u_xm − θz·(y − ym)` and `u_y = u_ym + θz·(x − xm)`.
"""
function _elf_disp_at(u, master, x, y, direction)
    xm = ustrip(u"m", master.position[1])
    ym = ustrip(u"m", master.position[2])
    gid = master.globalID
    ux = u[gid[1]]
    uy = u[gid[2]]
    θz = u[gid[6]]
    if direction == :x
        return ux - θz * (y - ym)
    end
    return uy + θz * (x - xm)
end

"""Elastic and design drift, θ, and Ax for one solved case."""
function _elf_recover(case, levels, u, Ie, Cd, β, Ω0)
    n = length(levels)
    elastic = Vector{Float64}(undef, n)
    design = Vector{Float64}(undef, n)
    elastic_drift = Vector{Float64}(undef, n)
    design_drift = Vector{Float64}(undef, n)
    theta = Vector{Union{Float64, Nothing}}(undef, n)
    mult = Vector{Union{Float64, Nothing}}(undef, n)
    Ax = Vector{Union{Float64, Nothing}}(undef, n)

    # θmax does not depend on the story. A :drift case that exceeds it throws.
    θmax = case.purpose == :drift ? stability_coefficient_limit(β, Cd; Ω0=Ω0) : nothing

    for i in 1:n
        lv = levels[i]
        ex, ey = lv.center_of_mass
        δe = _elf_disp_at(u, lv.master, ex, ey, case.direction)
        # δdi = 0: in-plane diaphragm deformation is neglected.
        # ASCE 7-22 Eq. 12.8-16 (corpus: asce-7-22, PDF page 187).
        δDE = design_earthquake_displacement(Cd, δe, Ie, 0.0)
        elastic[i] = δe
        design[i] = δDE
        if i == 1
            δe_below = 0.0
            δDE_below = 0.0
        else
            δe_below = elastic[i - 1]
            δDE_below = design[i - 1]
        end
        # Story drift is the difference of the displacements at the top and
        # bottom of the story. The design difference is §12.8.6.5 at the
        # center of mass (corpus: asce-7-22, PDF page 188).
        Δe = δe - δe_below
        ΔDE = design_story_drift(δDE, δDE_below)
        elastic_drift[i] = Δe
        design_drift[i] = ΔDE

        if case.purpose == :drift
            # Eq. 12.8-18 uses the elastic story drift. The sign is the
            # direction of motion; the coefficient uses the magnitude.
            θ = stability_coefficient(lv.px_kN, lv.story_height_m, case.Vx_kN[i], abs(Δe))
            theta[i] = θ
            mult[i] = pdelta_displacement_multiplier(θ, θmax)
        else
            theta[i] = nothing
            mult[i] = nothing
        end

        d1, d2 = _elf_edge_drifts(u, levels, i, case.direction)
        δmax = max(d1, d2)
        δavg = 0.5 * (d1 + d2)
        if δavg > 0 && δmax >= 0
            # ASCE 7-22 Eq. 12.8-15, computed at Ax = 1 (corpus: asce-7-22, PDF page 187).
            Ax[i] = torsional_amplification(δmax, δavg)
        else
            Ax[i] = nothing
        end
    end

    return ElfCase(case.direction, case.purpose, case.torsion, case.Cs, case.V_kN,
        case.k, case.Fx_kN, case.Vx_kN, case.Mz_kN_m,
        elastic, design, elastic_drift, design_drift, theta, mult, Ax)
end

"""Story drifts at the two edges perpendicular to the force, from the rigid-floor field."""
function _elf_edge_drifts(u, levels, i, direction)
    lv = levels[i]
    xmin, xmax, ymin, ymax = lv.bounds_m
    xm = ustrip(u"m", lv.master.position[1])
    ym = ustrip(u"m", lv.master.position[2])
    below = i == 1 ? nothing : levels[i - 1]
    if direction == :x
        edges = ((xm, ymin), (xm, ymax))
    else
        edges = ((xmin, ym), (xmax, ym))
    end
    drifts = ntuple(2) do j
        x, y = edges[j]
        top = _elf_disp_at(u, lv.master, x, y, direction)
        bot = below === nothing ? 0.0 : _elf_disp_at(u, below.master, x, y, direction)
        return top - bot
    end
    return drifts
end
