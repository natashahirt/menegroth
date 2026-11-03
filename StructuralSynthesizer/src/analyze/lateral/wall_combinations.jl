# =============================================================================
# One strength combination, one concurrent pier (N, M, V)
# =============================================================================
# Each pier keeps the cut from one basic case. A combination scales that set.
# Axial force from one case is not paired with shear or moment from another.
#
# N is compression-positive, in newtons, matching the wall P–M checkers.
# V is in-plane shear along the pier, in newtons. M is the in-plane moment
# about the horizontal normal through the cut centroid, in newton-metres.
# Out-of-plane shear and moment are not in this resultant.

"""In-plane axial force, shear, and moment of one pier for one case."""
struct WallAction
    "Compression-positive axial force [N]."
    N::Float64
    "In-plane shear, positive along the pier from (x1, y1) toward (x2, y2) [N]."
    V::Float64
    "In-plane moment about the horizontal normal through the cut centroid [N·m]."
    M::Float64
end

WallAction() = WallAction(0.0, 0.0, 0.0)

"""Dead, floor live, and the one roof companion for one pier."""
struct PierGravityActions
    "`:Lr`, `:S`, or `:R`. The companion `companion` belongs to."
    roof::Symbol
    D::WallAction
    L::WallAction
    companion::WallAction
end

"""
One combination applied to one concurrent set.

`alternative` is `:only` when the combination has a single reading.
Combination 3 is emitted twice: `:L` uses floor live and no wind, `:W` uses
`0.5W` and no floor live. Those two are the alternatives in §2.3.1, not a sum.
"""
struct CombinedWallAction
    combination::Symbol
    alternative::Symbol
    N::Float64
    V::Float64
    M::Float64
end

"""
    wall_action_from_global(wall, Fx, Fy, Fz, Mx, My, Mz) -> WallAction

Project a pier-cut resultant into the pier's in-plane axes.

The cut components are the load on the free body above the cut, in global
axes, about the cut centroid. `+z` is up. Compression is the upward force
the pier delivers, so `N = -Fz`.

The in-plane tangent is `(x2 - x1, y2 - y1)`. The horizontal normal is that
tangent turned 90° counterclockwise. `V` is the shear along the tangent.
`M` is the moment about the normal.
"""
function wall_action_from_global(wall::Wall, Fx, Fy, Fz, Mx, My, Mz)
    tx, ty, nx, ny = _pier_plan_axes(wall)
    return WallAction(
        -Float64(Fz),
        Float64(Fx) * tx + Float64(Fy) * ty,
        Float64(Mx) * nx + Float64(My) * ny)
end

"""
    pier_wall_action(wall, pier, u; loads=[], fixed_end_from_loads=false) -> WallAction

In-plane `(N, V, M)` from this pier's shells at its bottom nodes.

The tangent is the meshed bottom edge, oriented with `(x2 - x1, y2 - y1)`.
A column centerline offset moves that edge onto the frame nodes.

`fixed_end_from_loads` reads fixed-end forces from `loads` instead of the
`Q` stored on the element. A basic-case displacement is not the load set
last processed onto the model.
"""
function pier_wall_action(wall::Wall, pier::WallPierMesh, u::AbstractVector{<:Real};
                          loads=Asap.AbstractLoad[],
                          fixed_end_from_loads::Bool=false)
    z = _pier_bottom(pier)
    qmap = fixed_end_from_loads ? _fixed_end_by_element(loads) : nothing
    contrib = _cut_contributions(pier.shells, u, z; qmap=qmap)
    isempty(contrib) && throw(ArgumentError(
        "pier_wall_action: wall $(pier.wall_index) has no shell node on its " *
        "bottom at z = $(z) m."))
    origin = _cut_origin(contrib, z)
    Fx, Fy, Fz, Mx, My, Mz = _sum_about(contrib, origin)
    tx, ty, nx, ny = _meshed_plan_axes(wall, pier)
    return WallAction(
        -Float64(Fz),
        Float64(Fx) * tx + Float64(Fy) * ty,
        Float64(Mx) * nx + Float64(My) * ny)
end

"""
    pier_gravity_actions(struc, basic, pier) -> PierGravityActions

`(N, V, M)` of one pier for unfactored dead, floor live, and the roof
companion in `basic`.
"""
function pier_gravity_actions(struc::BuildingStructure, basic::GravityBasicCases,
                              pier::WallPierMesh)
    length(basic.symbols) == 3 || throw(ArgumentError(
        "pier_gravity_actions: expected [:D, :L, roof], got $(basic.symbols)."))
    basic.symbols[1] === :D && basic.symbols[2] === :L || throw(ArgumentError(
        "pier_gravity_actions: the first two cases must be :D and :L, " *
        "got $(basic.symbols)."))
    roof = basic.symbols[3]
    roof in (:Lr, :S, :R) || throw(ArgumentError(
        "pier_gravity_actions: the roof companion must be :Lr, :S, or :R, " *
        "got :$roof."))
    wall = struc.walls[pier.wall_index]
    actions = ntuple(3) do i
        pier_wall_action(wall, pier, basic.u[i];
                         loads=basic.loads[i], fixed_end_from_loads=true)
    end
    return PierGravityActions(roof, actions[1], actions[2], actions[3])
end

"""
    assembly_wall_action(struc, assembly, u; kwargs...) -> WallAction

The single pier of an assembly that is not joined. A joined assembly throws
[`refuse_joined_wall_design`](@ref): an ordinary wall has no flange width here.
"""
function assembly_wall_action(struc::BuildingStructure, assembly::WallAssembly,
                              u::AbstractVector{<:Real}; kwargs...)
    refuse_joined_wall_design(assembly)
    idx = only(assembly.wall_indices)
    pier = _pier_by_wall_index(struc.wall_mesh, idx)
    return pier_wall_action(struc.walls[idx], pier, u; kwargs...)
end

"""
    combine_wall_action(combo, gravity; wind, qe, rho, SDS, alternative=:only) -> CombinedWallAction

Scale one pier's basic actions by one [`LoadCombination`](@ref).

`gravity.D`, `gravity.L`, and `gravity.companion` stay together. `wind` is
one wind case. `qe` is one strength seismic case before `ρ`. `Eh = ρ QE`
multiplies the axial force, shear, and moment of that case. `Ev = 0.2 SDS D`
is added to the axial force only.

`Lr`, `S`, and `R` are not added together. Only `gravity.roof` is passed.
A nonzero `W` without `wind`, or a nonzero `E` or `Ev` without `qe`, `ρ`,
and (for `Ev`) `SDS`, throws. Nothing is filled in.

# Citations
ASCE 7-22 §2.3.1 (corpus: asce-7-22, PDF page 68) and §2.3.6 (PDF page 69).
The factors are the fields of `combo`, from
[`asce7_strength_combinations`](@ref).
Eq. 12.4-3, `Eh = ρ QE` (PDF page 183).
Eq. 12.4-4a, `Ev = 0.2 SDS D` (PDF page 183), through
[`vertical_seismic_load_effect`](@ref).
"""
function combine_wall_action(combo::LoadCombination, gravity::PierGravityActions;
                             wind::Union{Nothing, WallAction}=nothing,
                             qe::Union{Nothing, WallAction}=nothing,
                             rho::Union{Nothing, Real}=nothing,
                             SDS::Union{Nothing, Real}=nothing,
                             alternative::Symbol=:only)
    alternative in (:only, :L, :W) || throw(ArgumentError(
        "combine_wall_action: alternative must be :only, :L, or :W, " *
        "got $(repr(alternative))."))
    if alternative !== :only && combo.name !== :strength_1_2D_1_6Lr
        throw(ArgumentError(
            "combine_wall_action: :L and :W are the two readings of " *
            "combination 3 (1.2D + roof + (L or 0.5W)). $(combo.name) " *
            "is not that combination."))
    end
    roof = gravity.roof
    use_wind = alternative === :L ? false : combo.W != 0.0
    use_live = alternative === :W ? false : true
    use_eh = combo.E != 0.0
    use_ev = combo.Ev != 0.0
    if use_wind && isnothing(wind)
        throw(ArgumentError(
            "combine_wall_action: $(combo.name) has a wind factor and no wind " *
            "case was passed. Pass one wind case."))
    end
    if (use_eh || use_ev) && isnothing(qe)
        throw(ArgumentError(
            "combine_wall_action: $(combo.name) includes earthquake and no " *
            "strength seismic case was passed."))
    end
    ρ = use_eh ? _require_rho(rho) : 1.0
    ev_N = 0.0
    if use_ev
        isnothing(SDS) && throw(ArgumentError(
            "combine_wall_action: $(combo.name) includes Ev and SDS was not " *
            "passed. Ev = 0.2 SDS D is not assumed."))
        # ASCE 7-22 Eq. 12.4-4a (corpus: asce-7-22, PDF page 183).
        # ENGINEERING JUDGMENT: D in that equation is the dead-load effect.
        # Here Ev is applied to the pier's axial dead effect only. Dead shear
        # and dead moment keep the D factor and are not also scaled by 0.2 SDS.
        ev_N = vertical_seismic_load_effect(SDS, gravity.D.N)
    end
    live = use_live ? gravity.L : WallAction()
    wind_a = use_wind ? wind : WallAction()
    eh = use_eh ? WallAction(ρ * qe.N, ρ * qe.V, ρ * qe.M) : WallAction()
    N = _factored_component(combo, roof, gravity.D.N, live.N, gravity.companion.N,
                            wind_a.N, eh.N, ev_N)
    V = _factored_component(combo, roof, gravity.D.V, live.V, gravity.companion.V,
                            wind_a.V, eh.V, 0.0)
    M = _factored_component(combo, roof, gravity.D.M, live.M, gravity.companion.M,
                            wind_a.M, eh.M, 0.0)
    return CombinedWallAction(combo.name, alternative, N, V, M)
end

"""
    wall_strength_actions(gravity; wind, qe, rho, SDS) -> Vector{CombinedWallAction}

Every strength combination on one pier, each once.

Wind and the strength seismic case are required. Eight results: the six
combinations that have one reading, and both readings of combination 3.
`ρ` and `SDS` are required because the two earthquake combinations are in
the list. No redundancy factor and no `SDS` are assumed.
"""
function wall_strength_actions(gravity::PierGravityActions;
                               wind::WallAction,
                               qe::WallAction,
                               rho::Real,
                               SDS::Real)
    out = CombinedWallAction[]
    for combo in asce7_strength_combinations
        if combo.name === :strength_1_2D_1_6Lr
            push!(out, combine_wall_action(combo, gravity; wind, qe, rho, SDS,
                                            alternative=:L))
            push!(out, combine_wall_action(combo, gravity; wind, qe, rho, SDS,
                                            alternative=:W))
        else
            push!(out, combine_wall_action(combo, gravity; wind, qe, rho, SDS))
        end
    end
    return out
end

"""
    wind_pier_actions(struc, analysis, pier) -> Vector{WallAction}

Re-solve each stored Chapter 27 case and read this pier. The story analysis
keeps master displacements only. The forces re-solved here are the `Fx`,
`Fy`, and `Mz` already on the case. `model.u` is not replaced.
"""
function wind_pier_actions(struc::BuildingStructure, analysis::WindStoryAnalysis,
                           pier::WallPierMesh)
    cases = Vector{Vector{Asap.AbstractLoad}}(undef, length(analysis.cases))
    for (j, case) in enumerate(analysis.cases)
        cases[j] = _wind_loads(analysis.levels, case.Fx_kN, case.Fy_kN, case.Mz_kN_m)
    end
    return _story_case_pier_actions(struc, cases, pier)
end

"""
    seismic_strength_pier_actions(struc, analysis, pier) -> (indices, actions)

Re-solve each `:strength` ELF case and read this pier. `:drift` cases are
omitted. `indices[k]` is the case in `analysis.cases` that produced
`actions[k]`. The action is `QE`, before `ρ`. `model.u` is not replaced.
"""
function seismic_strength_pier_actions(struc::BuildingStructure,
                                       analysis::ElfStoryAnalysis,
                                       pier::WallPierMesh)
    effects = seismic_effect_cases(analysis; orthogonal=false)
    indices = [only(e.terms)[1] for e in effects]
    return indices, seismic_strength_pier_actions(struc, analysis, pier, effects)
end

"""
    seismic_strength_pier_actions(struc, analysis, pier, effects) -> Vector{WallAction}

One `QE` action per [`SeismicEffectCase`](@ref), in the order of `effects`.
"""
function seismic_strength_pier_actions(struc::BuildingStructure,
                                       analysis::ElfStoryAnalysis,
                                       pier::WallPierMesh,
                                       effects::AbstractVector{SeismicEffectCase})
    cases = [seismic_effect_loads(analysis, e) for e in effects]
    return _story_case_pier_actions(struc, cases, pier)
end

# ------------------------------------------------------------------------------
# Internals
# ------------------------------------------------------------------------------

function _pier_plan_axes(wall)
    dx = wall.x2 - wall.x1
    dy = wall.y2 - wall.y1
    L = hypot(dx, dy)
    L > 0 || throw(ArgumentError(
        "wall action: pier $(wall.x1),$(wall.y1) to $(wall.x2),$(wall.y2) has no length."))
    tx = dx / L
    ty = dy / L
    return tx, ty, -ty, tx
end

"""
In-plane axes of the meshed pier, oriented with the architectural wall.

The tangent is the bottom edge of the shells. A column offset can move that
edge off `(x1, y1)–(x2, y2)` without changing which end is the start. The
architectural tangent breaks a tie so shear keeps its sign.
"""
function _meshed_plan_axes(wall, pier::WallPierMesh)
    tx, ty, nx, ny = _pier_plan_axes(wall)
    z = _pier_bottom(pier)
    pts = Tuple{Float64, Float64}[]
    for sh in pier.shells, nd in sh.nodes
        xyz = _node_xyz(nd)
        abs(xyz[3] - z) > 1e-6 && continue
        xy = (xyz[1], xyz[2])
        any(p -> hypot(p[1] - xy[1], p[2] - xy[2]) <= 1e-9, pts) && continue
        push!(pts, xy)
    end
    length(pts) < 2 && return tx, ty, nx, ny
    best = -1.0
    a = pts[1]
    b = pts[2]
    for i in eachindex(pts), j in (i + 1):length(pts)
        d = hypot(pts[j][1] - pts[i][1], pts[j][2] - pts[i][2])
        d <= best && continue
        best = d
        a = pts[i]
        b = pts[j]
    end
    dx = b[1] - a[1]
    dy = b[2] - a[2]
    L = hypot(dx, dy)
    L > 0 || return tx, ty, nx, ny
    mx = dx / L
    my = dy / L
    if mx * tx + my * ty < 0
        mx = -mx
        my = -my
    end
    return mx, my, -my, mx
end

function _pier_by_wall_index(mesh::WallMesh, wall_index::Int)
    i = findfirst(p -> p.wall_index == wall_index, mesh.piers)
    i === nothing && throw(ArgumentError(
        "wall action: wall $wall_index is not in the current mesh."))
    return mesh.piers[i]
end

"""One roof companion. The other two roof keywords stay at zero."""
function _factored_component(combo, roof::Symbol, D, L, companion, W, E, Ev)
    if roof === :Lr
        return factored_pressure(combo; D, L, Lr=companion, W, E, Ev)
    elseif roof === :S
        return factored_pressure(combo; D, L, S=companion, W, E, Ev)
    elseif roof === :R
        return factored_pressure(combo; D, L, R=companion, W, E, Ev)
    else
        throw(ArgumentError(
            "wall action: the roof companion must be :Lr, :S, or :R, got :$roof."))
    end
end

function _require_rho(rho)
    isnothing(rho) && throw(ArgumentError(
        "ρ is required. ASCE 7-22 Eq. 12.4-3 (corpus: asce-7-22, PDF page 183) " *
        "is Eh = ρ QE. No redundancy factor is assumed."))
    ρ = Float64(rho)
    (isfinite(ρ) && ρ > 0) || throw(ArgumentError(
        "ρ must be a finite number > 0; got $rho."))
    return ρ
end

function _story_case_pier_actions(struc, cases, pier::WallPierMesh)
    isempty(cases) && return WallAction[]
    model = struc.asap_model
    isnothing(model) && throw(ArgumentError(
        "wall action: the building has no Asap model. Run to_asap! first."))
    u = Asap.solve(model, cases, struc.asap_rigid_links)
    wall = struc.walls[pier.wall_index]
    return [pier_wall_action(wall, pier, u[i];
                             loads=cases[i], fixed_end_from_loads=true)
            for i in eachindex(u)]
end
