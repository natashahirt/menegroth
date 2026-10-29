# Ordinary-wall checks for one isolated pier.
#
# The numerical checks already live in StructuralSizer. This file only maps one
# pier's concurrent (N, M, V) onto those functions and keeps the record.
# Thickness, length, and reinforcement are the wall's given values.

"""
    check_ordinary_wall(wall, actions; material, wall_index, case, boundary,
                        assembly=nothing, hw=nothing) -> Vector{WallCheckRecord}

Run the ordinary checks on one isolated pier for each strength combination in
`actions`. Each action is one concurrent `(N, M, V)`.

The checks are the existing ones:

- in-plane shear, `check_wall_inplane_shear` (ACI 318-19 §11.5.4.3)
- minimum reinforcement, `check_wall_min_reinforcement` (ACI 318-19 §11.6.2)
- in-plane axial-flexure, `check_wall_inplane_flexure` (ACI 318-19 §22.2 and §22.4.2.1)
- empirical bearing, `check_wall_bearing_empirical` (ACI 318-19 §11.5.3)

Out-of-plane flexure is not run. The in-plane action has no out-of-plane demand.

`material` is a `ReinforcedConcreteMaterial`. A plain concrete is refused:
this check does not assume a rebar grade. `boundary` selects the bearing-wall
`k` (`:restrained`, `:pinned`, or `:cantilever`). `case` names the basic case
the combination was built from.

`hw`, when passed, is the total wall height used by the shear and minimum-
reinforcement checks. When omitted, the height is this pier plus every
`wall_above`. The bearing unsupported height stays this story's height: the
floors brace the pier, and `boundary` supplies `k`.

The empirical method's eccentricity is out of plane (the resultant within the
middle third of the thickness, §11.5.3.1). This action does not carry an
out-of-plane moment, so the resultant is taken through the thickness (`e = 0`).
The in-plane moment is the axial-flexure check. A tensile axial force makes
the bearing method inapplicable; that result is recorded as a failure.

A joined `assembly` is refused. A failing check is recorded. The wall is not resized.
"""
function check_ordinary_wall(wall::Wall, actions::AbstractVector{CombinedWallAction};
                             material,
                             wall_index::Int,
                             case::Symbol,
                             boundary::Symbol,
                             assembly::Union{Nothing,WallAssembly}=nothing,
                             hw::Union{Nothing,Unitful.Length}=nothing)
    material isa ReinforcedConcreteMaterial || throw(ArgumentError(
        "ordinary wall check: material must be a ReinforcedConcreteMaterial " *
        "(concrete plus rebar). A plain concrete has no fy or fyt, and this " *
        "check does not assume a grade."))
    isempty(actions) && throw(ArgumentError(
        "ordinary wall check: there is no strength combination to check."))
    assembly !== nothing && refuse_joined_wall_design(assembly)
    _require_wall_concrete(wall, material)

    lw = wall_length(wall) * u"m"
    lw_m = ustrip(u"m", lw)
    lw_m > 0 || throw(ArgumentError("ordinary wall check: the pier has no length."))
    direction = _pier_principal_direction(wall)
    section = WallSection(lw, wall.thickness; ρl=wall.ρl, ρt=wall.ρt)
    height = hw === nothing ? _stacked_wall_height(wall) : hw
    ustrip(u"m", height) > 0 || throw(ArgumentError(
        "ordinary wall check: the wall height must be positive."))
    story_height = wall.base.L
    ustrip(u"m", story_height) > 0 || throw(ArgumentError(
        "ordinary wall check: the story height must be positive."))

    records = WallCheckRecord[]
    for action in actions
        # Shear strength is unsigned. The sign of V is the pier tangent.
        shear = check_wall_inplane_shear(section, material, abs(action.V), height)
        push!(records, _ordinary_record(wall_index, wall.story, direction, case, action, shear))
        for reinf in check_wall_min_reinforcement(section; hw=height)
            push!(records, _ordinary_record(wall_index, wall.story, direction, case, action, reinf))
        end
        flexure = check_wall_inplane_flexure(section, material, action.N, action.M)
        push!(records, _ordinary_record(wall_index, wall.story, direction, case, action, flexure))
        # e = 0: no out-of-plane eccentricity is in this action. lu is the plan
        # length; a shorter unsupported length is not known here.
        bearing = check_wall_bearing_empirical(section, material.concrete, action.N;
                                               e=0.0u"m", lc=story_height, lu=lw,
                                               boundary=boundary, foundation=false)
        push!(records, _ordinary_record(wall_index, wall.story, direction, case, action, bearing))
    end
    return records
end

function _ordinary_record(wall_index, story, direction, case, action, result::CheckResult)
    return WallCheckRecord(wall_index, story, direction, case,
                           action.combination, action.alternative,
                           result.name, result.passed, result.ratio,
                           result.demand, result.capacity, result.code_clause)
end

"""`:X` or `:Y` from the pier tangent. A skewed pier is outside this check."""
function _pier_principal_direction(wall)
    tx, ty, _, _ = _pier_plan_axes(wall)
    if abs(tx) >= 1 - 1e-8 && abs(ty) <= 1e-8
        return :X
    elseif abs(ty) >= 1 - 1e-8 && abs(tx) <= 1e-8
        return :Y
    else
        throw(ArgumentError(
            "ordinary wall check: pier is not on a principal axis " *
            "(tangent ($tx, $ty))."))
    end
end

"""This pier plus every wall stacked above it. A cycle is refused."""
function _stacked_wall_height(wall)
    h = wall.base.L
    seen = Set{UInt}()
    above = wall.wall_above
    while above !== nothing
        id = objectid(above)
        id in seen && throw(ArgumentError(
            "ordinary wall check: wall_above forms a cycle."))
        push!(seen, id)
        h += above.base.L
        above = above.wall_above
    end
    return h
end

function _require_wall_concrete(wall, material)
    wall.concrete === nothing && return nothing
    fc_wall = ustrip(u"Pa", wall.concrete.fc′)
    fc_mat = ustrip(u"Pa", material.concrete.fc′)
    isapprox(fc_wall, fc_mat; rtol=1e-6) || throw(ArgumentError(
        "ordinary wall check: wall.concrete f'c does not match the " *
        "reinforced-concrete material."))
    return nothing
end
