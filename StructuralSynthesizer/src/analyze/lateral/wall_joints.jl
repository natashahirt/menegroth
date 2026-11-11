# =============================================================================
# Joined ordinary walls: one check per leg, one shear-friction check per corner
# =============================================================================
# A connected plan (L, T, parallelogram, octagon, or anything else) is not a
# named shape. Each leg is a rectangular pier. The assembly exists so the
# legs share nodes and so the corner can be checked.
#
# ACI 318-19 §18.10.5.2 is the special-wall flange width. It is not applied
# here. Composite action shows up as axial force on the leg that the mesh
# delivers. There is no ordinary-wall flange width in Chapter 11.

"""Angle below which two centerlines are treated as one straight wall [rad]."""
const _WALL_COLINEAR_RAD = 1e-3

"""
    split_tee_junctions!(walls; tol=WALL_CORNER_TOL_M) -> walls

Where a wall end lands on the interior of another wall on the same story,
split the through-wall so both pieces end on that point.

The mesh can then share the nodes of the corner. A second call does nothing:
the stem now meets an endpoint, not an open segment. Colinear walls are not
split. Two interiors that cross (an X) are not detected; neither end lies on
the other wall.

The original through-wall object becomes the first piece and keeps its
segment indices and `wall_above`. Each added piece copies thickness, story,
reinforcement, concrete, height, and `wall_above`, and owns no segment.
"""
function split_tee_junctions!(walls::AbstractVector; tol::Real=WALL_CORNER_TOL_M)
    n0 = length(walls)
    n0 == 0 && return walls
    hits = Dict{Int, Vector{NTuple{2, Float64}}}()
    for i in 1:n0, j in 1:n0
        i == j && continue
        walls[i].story == walls[j].story || continue
        _folded_angle(_wall_dir(walls[i]), _wall_dir(walls[j])) <= _WALL_COLINEAR_RAD &&
            continue
        for (x, y) in ((walls[j].x1, walls[j].y1), (walls[j].x2, walls[j].y2))
            hit = _point_on_open_segment(walls[i], x, y, Float64(tol))
            hit === nothing && continue
            push!(get!(() -> NTuple{2, Float64}[], hits, i), hit)
        end
    end
    isempty(hits) && return walls
    rebuilt = Vector{eltype(walls)}()
    for i in 1:n0
        if haskey(hits, i)
            append!(rebuilt, _split_wall_at_points(walls[i], hits[i], Float64(tol)))
        else
            push!(rebuilt, walls[i])
        end
    end
    empty!(walls)
    append!(walls, rebuilt)
    return walls
end

"""
    joined_clear_length(wall, walls, wall_index; tol=WALL_CORNER_TOL_M) -> Float64

Centerline length minus the corner overlap at each end that meets another
wall on the same story, in metres.

At a joined end the overlap is `(t_other / 2) / sin(φ)`, where `φ` is the
angle between the centerlines folded into `(0, π/2]`. At 90° that is half
the other thickness. Several walls at one end contribute the largest single
overlap, not the sum. A colinear neighbour, including the other piece of a
split through-wall, contributes nothing.

A remaining length of `1e-6` m or less throws. The pier is not given a
zero or negative section.

# Engineering judgment
The overlap is the strip of this leg that lies inside the other wall. It is
not an ACI flange width. ACI 318-19 §18.10.5.2 (corpus: aci-318-19, PDF
page 325) applies to special structural walls and is not used.
"""
function joined_clear_length(wall::Wall, walls::AbstractVector, wall_index::Int;
                            tol::Real=WALL_CORNER_TOL_M)
    L = wall_length(wall)
    L > 0 || throw(ArgumentError(
        "joined wall $wall_index: the centerline has no length."))
    overlap = 0.0
    tol_m = Float64(tol)
    for (x, y) in ((wall.x1, wall.y1), (wall.x2, wall.y2))
        worst = 0.0
        for (j, other) in enumerate(walls)
            j == wall_index && continue
            other.story == wall.story || continue
            _end_meets_wall(other, x, y, tol_m) || continue
            φ = _folded_angle(_wall_dir(wall), _wall_dir(other))
            φ <= _WALL_COLINEAR_RAD && continue
            t_other = ustrip(u"m", other.thickness)
            worst = max(worst, (t_other / 2) / sin(φ))
        end
        overlap += worst
    end
    clear = L - overlap
    clear > 1e-6 || throw(ArgumentError(
        "joined wall $wall_index: clear length $(clear) m is not positive. " *
        "The pier is shorter than the walls that frame into its ends."))
    return clear
end

"""Ends of the walls in one assembly that meet, and the sharpest angle there."""
struct WallCorner
    wall_indices::Vector{Int}
    x::Float64
    y::Float64
    "Smallest non-colinear angle between centerlines, in `(0, π/2]`."
    φ::Float64
end

"""
    assembly_corners(walls, assembly; tol=WALL_CORNER_TOL_M) -> Vector{WallCorner}

Clusters of endpoints within `tol`. A cluster of one wall, or of only
colinear walls, is not a corner.
"""
function assembly_corners(walls::AbstractVector, assembly::WallAssembly;
                         tol::Real=WALL_CORNER_TOL_M)
    pts = Tuple{Float64, Float64, Int}[]
    for i in assembly.wall_indices
        w = walls[i]
        push!(pts, (w.x1, w.y1, i), (w.x2, w.y2, i))
    end
    used = falses(length(pts))
    tol2 = Float64(tol)^2
    corners = WallCorner[]
    for i in eachindex(pts)
        used[i] && continue
        cluster = Int[i]
        used[i] = true
        for j in (i + 1):length(pts)
            used[j] && continue
            dx = pts[i][1] - pts[j][1]
            dy = pts[i][2] - pts[j][2]
            dx * dx + dy * dy <= tol2 || continue
            used[j] = true
            push!(cluster, j)
        end
        here = sort!(unique(Int[pts[k][3] for k in cluster]))
        length(here) < 2 && continue
        φ = Inf
        for a in 1:(length(here) - 1), b in (a + 1):length(here)
            ang = _folded_angle(_wall_dir(walls[here[a]]), _wall_dir(walls[here[b]]))
            ang <= _WALL_COLINEAR_RAD && continue
            φ = min(φ, ang)
        end
        isfinite(φ) || continue
        push!(corners, WallCorner(here, pts[i][1], pts[i][2], φ))
    end
    return corners
end

"""
Shear-plane area and the horizontal steel crossing it.

# Engineering judgment
ACI 318-19 §22.9 does not define `Ac` for a wall corner. The plane is the
vertical intersection. Its height is the story height. Its width is the
thinner wall, divided by `sin(φ)` so a skew corner uses the mitered contact
instead of the perpendicular overlap. `Avf = ρt_max · Ac` takes the larger
transverse ratio as reinforcement perpendicular to that plane
(Eq. 22.9.4.2). The bars of a skew wall are not both perpendicular to one
plane; the perpendicular equation is still the one used, with that ratio.
Those bars count only if they develop `fy` on both sides of the plane,
§22.9.5.1 (corpus: aci-318-19, PDF page 436). That is assumed.

Different story heights at one corner throw. The lesser `f'c` is the
caller's job (Table 22.9.4.4, PDF page 435).
"""
function corner_shear_plane(walls::AbstractVector, corner::WallCorner)
    ts = Float64[]
    ρs = Float64[]
    hs = Float64[]
    for i in corner.wall_indices
        w = walls[i]
        push!(ts, ustrip(u"m", w.thickness))
        push!(ρs, w.ρt)
        push!(hs, ustrip(u"m", w.base.L))
    end
    hmin, hmax = extrema(hs)
    abs(hmax - hmin) <= 1e-3 || throw(ArgumentError(
        "wall corner at ($(corner.x), $(corner.y)): story heights differ " *
        "by $(hmax - hmin) m. One shear plane is not defined."))
    sinφ = sin(corner.φ)
    sinφ > 0 || throw(ArgumentError(
        "wall corner at ($(corner.x), $(corner.y)): the angle between the " *
        "legs is zero."))
    # ENGINEERING JUDGMENT: see the docstring. Not an ACI area.
    Ac = minimum(ts) * hmin / sinφ
    ρ = maximum(ρs)
    return (Ac=Ac, Avf=ρ * Ac, ρt=ρ)
end

"""
Vertical force one pier's shells deliver at nodes on the corner line.

Nodes on the pier bottom are omitted: that cut is the support, not the
joint. The value is the sum of `-(Ku + Q)` in `z` at the remaining nodes
within `tol` of `(x, y)`. Each triangle contributes its own nodal force.
"""
function joint_vertical_shear(shells, u::AbstractVector{<:Real}, x::Real, y::Real;
                             tol::Real=WALL_CORNER_TOL_M)
    z0 = Inf
    for sh in shells, nd in sh.nodes
        z0 = min(z0, _node_xyz(nd)[3])
    end
    isfinite(z0) || return 0.0
    tol2 = Float64(tol)^2
    s = 0.0
    for sh in shells
        f = _element_nodal_force(sh, u)
        for (k, nd) in enumerate(sh.nodes)
            px, py, pz = _node_xyz(nd)
            (px - x)^2 + (py - y)^2 <= tol2 || continue
            pz > z0 + WALL_CUT_ZTOL_M || continue
            s += f[(k - 1) * 6 + 3]
        end
    end
    return s
end

"""Largest absolute one-sided vertical force at the corner."""
function corner_vertical_shear(piers, u::AbstractVector{<:Real}, x::Real, y::Real)
    m = 0.0
    for pier in piers
        m = max(m, abs(joint_vertical_shear(pier.shells, u, x, y)))
    end
    return m
end

"""
    joined_assembly_cuts(mesh, assembly, u) -> NTuple{6, Float64}

Free-body resultant `(Fx, Fy, Fz, Mx, My, Mz)` of every leg, about one origin.

Each shell belongs to one leg, so a shared corner node is not counted twice.
[`check_story_cut_equilibrium`](@ref) is the equilibrium gate. This sum is
the assembly's share of that cut, for a test that compares it to the load.
"""
function joined_assembly_cuts(mesh::WallMesh, assembly::WallAssembly,
                             u::AbstractVector{<:Real})
    assembly.joined || throw(ArgumentError(
        "joined_assembly_cuts: the assembly is one pier. Use pier_wall_action."))
    all = NamedTuple{(:x, :y, :z, :fx, :fy, :fz, :mx, :my, :mz),
                     NTuple{9, Float64}}[]
    for idx in assembly.wall_indices
        pier = _pier_by_wall_index(mesh, idx)
        append!(all, _cut_contributions(pier.shells, u, _pier_bottom(pier)))
    end
    isempty(all) && throw(ArgumentError(
        "joined assembly on story $(assembly.story): no shell node lies on a " *
        "pier bottom."))
    return _sum_about(all, _cut_origin(all, all[1].z))
end

# ------------------------------------------------------------------------------
# Internals
# ------------------------------------------------------------------------------

function _wall_dir(w)
    dx = w.x2 - w.x1
    dy = w.y2 - w.y1
    L = hypot(dx, dy)
    L > 0 || return (1.0, 0.0)
    return (dx / L, dy / L)
end

"""Angle between two plan directions, folded into `[0, π/2]`."""
function _folded_angle(a::NTuple{2, Float64}, b::NTuple{2, Float64})
    c = clamp(a[1] * b[1] + a[2] * b[2], -1.0, 1.0)
    α = acos(c)
    return α <= π / 2 ? α : π - α
end

function _point_on_open_segment(wall, x::Float64, y::Float64, tol::Float64)
    dx = wall.x2 - wall.x1
    dy = wall.y2 - wall.y1
    L2 = dx * dx + dy * dy
    L2 > 0 || return nothing
    s = ((x - wall.x1) * dx + (y - wall.y1) * dy) / L2
    (0 < s < 1) || return nothing
    px = wall.x1 + s * dx
    py = wall.y1 + s * dy
    hypot(x - px, y - py) <= tol || return nothing
    hypot(px - wall.x1, py - wall.y1) <= tol && return nothing
    hypot(px - wall.x2, py - wall.y2) <= tol && return nothing
    return (px, py)
end

function _end_meets_wall(wall, x::Float64, y::Float64, tol::Float64)
    tol2 = tol * tol
    for (ex, ey) in ((wall.x1, wall.y1), (wall.x2, wall.y2))
        dx = x - ex
        dy = y - ey
        dx * dx + dy * dy <= tol2 && return true
    end
    return false
end

function _split_wall_at_points(w, pts, tol::Float64)
    dx = w.x2 - w.x1
    dy = w.y2 - w.y1
    L = hypot(dx, dy)
    L > 0 || return [w]
    ss = Float64[]
    for (x, y) in pts
        s = ((x - w.x1) * dx + (y - w.y1) * dy) / (L * L)
        (s > tol / L && s < 1 - tol / L) || continue
        any(t -> abs(t - s) * L <= tol, ss) && continue
        push!(ss, s)
    end
    isempty(ss) && return [w]
    sort!(ss)
    x1, y1, x2, y2 = w.x1, w.y1, w.x2, w.y2
    stations = vcat(0.0, ss, 1.0)
    at(s) = (x1 + s * (x2 - x1), y1 + s * (y2 - y1))
    a = at(stations[1])
    b = at(stations[2])
    w.x1, w.y1, w.x2, w.y2 = a[1], a[2], b[1], b[2]
    pieces = [w]
    above = w.wall_above
    for k in 2:(length(stations) - 1)
        p = at(stations[k])
        q = at(stations[k + 1])
        piece = Wall(Int[], w.base.L; thickness=w.thickness,
                     x1=p[1], y1=p[2], x2=q[1], y2=q[2],
                     story=w.story, ρl=w.ρl, ρt=w.ρt,
                     concrete=w.concrete, group_id=w.base.group_id)
        piece.wall_above = above
        push!(pieces, piece)
    end
    return pieces
end

"""
Governing factored vertical shear at one corner.

`vu(u)` is the unfactored magnitude for a displacement. It is combined with
the same strength readings as pier shear (`_gravity_readings`, `_wind_readings`,
`_seismic_readings`): `Eh = ρ QE` scales it, and `Ev` does not. The
second-order displacement of each component is the one solved on that
combination's factored-gravity stiffness.
"""
function _governing_joint_vu(vu, basic, second, wind, effects, rho, SDS)
    roof = basic.symbols[3]
    best = (case=:D, combination=:strength_1_4D, alternative=:only, Vu=0.0)
    function keep(case, action::CombinedWallAction)
        v = abs(action.V)
        v + 1e-9 < best.Vu && return nothing
        best = (case=case, combination=action.combination,
                alternative=action.alternative, Vu=v)
        return nothing
    end
    function grav(set)
        actions = ntuple(i -> WallAction(0.0, vu(set.u[i]), 0.0), 3)
        return PierGravityActions(roof, actions...)
    end
    for (combo, alt, key) in _gravity_readings(roof)
        keep(:D, combine_wall_action(combo, grav(second[key]); alternative=alt))
    end
    for (i, case) in enumerate(wind.cases)
        sym = _wind_case_symbol(i, case)
        for (combo, alt, key) in _wind_readings(roof)
            set = second[key]
            wact = WallAction(0.0, vu(set.u[3 + i]), 0.0)
            keep(sym, combine_wall_action(combo, grav(set); wind=wact, alternative=alt))
        end
    end
    nwind = first(values(second)).nwind
    for k in eachindex(effects)
        for (combo, alt, key) in _seismic_readings(roof)
            set = second[key]
            qe = WallAction(0.0, vu(set.u[3 + nwind + k]), 0.0)
            keep(effects[k].label,
                 combine_wall_action(combo, grav(set); qe, rho, SDS, alternative=alt))
        end
    end
    return best
end

"""
    select_corner_ratio(fc, fy, Ac, ρ_legs, Vu; λ=1.0, grid=ORDINARY_WALL_RHO_GRID)
        -> (ρ, check, capped)

Lightest horizontal ratio across one corner with `φVn ≥ Vu`.

The search starts at `ρ_legs`, the bars the legs already carry through the
corner. When those fail, it walks `grid` upward and stops at the first ratio
that passes. The legs keep their own ratios; the extra steel is local to
the corner.

When `Vu` exceeds `φ` times the Table 22.9.4.4 limit, no amount of steel
passes. `capped` is `true`, `ρ` stays at `ρ_legs`, and the failing check is
returned. A demand above the top of `grid` returns the top of `grid` and
its failing check.

`fc`, `fy` are pascals, `Ac` square metres, `Vu` newtons.

# Engineering judgment
ACI 318-19 §11.2.4.1 (corpus: aci-318-19, PDF page 168) requires walls to be
anchored to intersecting walls and gives no amount. The amount here is
shear friction, §22.9.4.2 (PDF page 434), with the Table 22.9.4.4 limit
(PDF page 435). Raising a corner ratio instead of the legs' `ρt` is a
choice of where the steel goes, not a code clause.
"""
function select_corner_ratio(fc::Real, fy::Real, Ac::Real, ρ_legs::Real, Vu::Real;
                             λ::Real=1.0, grid=ORDINARY_WALL_RHO_GRID)
    start = check_monolithic_shear_friction(fc, fy, Ac, ρ_legs * Ac, Vu; λ=λ)
    start.passed && return (ρ=Float64(ρ_legs), check=start, capped=false)
    limit = monolithic_shear_friction_si(fc, fy, Ac, 0.0; λ=λ).Vn_max
    abs(Vu) > WALL_PHI_SHEAR * limit + 1e-6 &&
        return (ρ=Float64(ρ_legs), check=start, capped=true)
    ρ, check = Float64(ρ_legs), start
    for r in grid
        r > ρ_legs + 1e-12 || continue
        ρ = Float64(r)
        check = check_monolithic_shear_friction(fc, fy, Ac, r * Ac, Vu; λ=λ)
        check.passed && break
    end
    return (ρ=ρ, check=check, capped=false)
end

"""
Check shear friction at each corner of a joined assembly and select the
corner's horizontal ratio.

Two records are stored on the lowest wall index at the corner: the shear-
friction check at the selected ratio, and the selected ratio itself
(reported, ratio 0). Out-of-plane demands are not part of either.
See [`select_corner_ratio`](@ref).

`Avf` counts horizontal bars as crossing the corner. ACI 318-19 §22.9.5.1
(corpus: aci-318-19, PDF page 436) requires them to develop `fy` on both
sides of the shear plane. Development needs bar sizes, which a wall does
not carry, so it is stated on the record and not checked. The extra corner
bars are not in the quantity takeoff.
"""
function _record_joined_joints!(checks, struc, basic, wind, second, effects, inputs,
                               plan_axis)
    material = inputs.material
    fc_mat = ustrip(u"Pa", material.concrete.fc′)
    fy = ustrip(u"Pa", material.transverse.Fy)
    λ = material.concrete.λ
    for assembly in struc.wall_mesh.assemblies
        assembly.joined || continue
        for corner in assembly_corners(struc.walls, assembly)
            plane = corner_shear_plane(struc.walls, corner)
            fc = fc_mat
            for i in corner.wall_indices
                concrete = struc.walls[i].concrete
                concrete === nothing && continue
                fc = min(fc, ustrip(u"Pa", concrete.fc′))
            end
            piers = [_pier_by_wall_index(struc.wall_mesh, i) for i in corner.wall_indices]
            vu = u -> corner_vertical_shear(piers, u, corner.x, corner.y)
            governed = _governing_joint_vu(vu, basic, second, wind, effects,
                                           inputs.rho, inputs.SDS)
            sel = select_corner_ratio(fc, fy, plane.Ac, plane.ρt, governed.Vu; λ=λ)
            result = sel.check
            host = minimum(corner.wall_indices)
            wall = struc.walls[host]
            direction = _pier_axis_direction(wall, plan_axis)
            names = join(corner.wall_indices, ", ")
            clause = result.code_clause * "; walls " * names *
                     "; corner ρ = $(sel.ρ)" *
                     "; bars anchored per 22.9.5.1 assumed, not checked"
            sel.capped && (clause *= "; Vu exceeds φ × the Table 22.9.4.4 limit, " *
                                     "so steel cannot pass it. A thicker wall is needed.")
            push!(checks[host], WallCheckRecord(
                host, wall.story, direction,
                governed.case, governed.combination, governed.alternative,
                "shear friction", result.passed, result.ratio,
                result.demand, result.capacity, clause))
            # The ratio is reported, not checked. ratio 0 keeps it off the
            # governing row of a passing design.
            push!(checks[host], WallCheckRecord(
                host, wall.story, direction,
                governed.case, governed.combination, governed.alternative,
                "corner horizontal ratio (selected)", true, 0.0,
                sel.ρ, plane.ρt,
                "selected corner ρ; capacity column is the larger leg ρt of walls " *
                names * "; extra corner bars are not in the quantity takeoff"))
        end
    end
    return checks
end

"""
Overlap, in metres, of this wall's end with a wall it frames into.
`(t_other / 2) / sin(φ)`. Zero when the end meets no other wall.
"""
function _joined_end_overlap(wall, walls, wall_index::Int, x::Float64, y::Float64,
                             tol::Float64)
    worst = 0.0
    for (j, other) in enumerate(walls)
        j == wall_index && continue
        other.story == wall.story || continue
        _end_meets_wall(other, x, y, tol) || continue
        φ = _folded_angle(_wall_dir(wall), _wall_dir(other))
        φ <= _WALL_COLINEAR_RAD && continue
        t_other = ustrip(u"m", other.thickness)
        worst = max(worst, (t_other / 2) / sin(φ))
    end
    return worst
end

"""
    refuse_openings_in_joined_corners!(walls; tol=WALL_CORNER_TOL_M) -> nothing

Throw when an opening enters the strip of a leg that lies inside the wall
it frames into.

The strip is the same overlap [`joined_clear_length`](@ref) subtracts:
`(t_other / 2) / sin(φ)` at each joined end. An opening there is not a pier
between the walls; it cuts the joint. A wall with no openings is left alone.
"""
function refuse_openings_in_joined_corners!(walls::AbstractVector;
                                           tol::Real=WALL_CORNER_TOL_M)
    tol_m = Float64(tol)
    for (i, wall) in enumerate(walls)
        isempty(wall.openings) && continue
        L = wall_length(wall)
        for (x, y, at_start) in ((wall.x1, wall.y1, true), (wall.x2, wall.y2, false))
            zone = _joined_end_overlap(wall, walls, i, x, y, tol_m)
            zone > tol_m || continue
            z0 = at_start ? 0.0 : L - zone
            z1 = at_start ? zone : L
            for op in wall.openings
                _interval_separation(op.s0, op.s0 + op.width, z0, z1) < tol_m || continue
                throw(ArgumentError(
                    "wall opening: an opening at s = $(op.s0) m on wall $i enters " *
                    "the joined corner at ($(x), $(y)) m. That strip is $(zone) m " *
                    "of this leg lying inside the wall it frames into."))
            end
        end
    end
    return nothing
end
