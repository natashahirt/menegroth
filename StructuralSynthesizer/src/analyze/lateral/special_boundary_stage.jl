# =============================================================================
# Special-boundary decision on the forces the ordinary stage already has
# =============================================================================
# ACI 318-19 §18.10.6.2 (corpus: aci-318-19, page 326) is the route at the base
# of a continuous line when hwcs/ℓw ≥ 2 and the design displacement is known.
# Every other pier stays on §18.10.6.3. Continuity is a fact of the stack.
# Thickness is not changed here.

"""Earthquake strength combinations. §18.10.6.3 reads combinations that include E."""
const _BOUNDARY_EARTHQUAKE = (:strength_1_2D_1_0E, :strength_0_9D_1_0E)

"""
One pier on a special row.

Lengths are metres. `σ_Pa` is the maximum extreme-fiber stress from the
earthquake combinations, compression positive. A negative value is tension
at both fibers. `c_m`, `zone_length_m`, and `minimum_thickness_m` are
`nothing` when §18.10.6.4 does not apply or the neutral-axis depth did not
converge. `thickness_shortfall_m` is how far the web thickness is below
that width when the web is the compression zone. It is zero when a flange
is the compression zone: that width is the flange width, which this jump
does not resize. It is `nothing` when no width was required.
`floor_ratio` and `floor_meets` are §18.10.6.4(h) when an element is
required and a floor strength was stated. Both stay `nothing` otherwise.
`δu_m` is the design displacement when the route is §18.10.6.2, and
`nothing` on the stress route.
"""
struct SpecialBoundaryDecision
    continuous::Bool
    single_critical_section::Bool
    route::Symbol
    required::Union{Nothing, Bool}
    required_by::Symbol
    governing_end::Symbol
    σ_Pa::Float64
    c_m::Union{Nothing, Float64}
    zone_length_m::Union{Nothing, Float64}
    minimum_thickness_m::Union{Nothing, Float64}
    thickness_shortfall_m::Union{Nothing, Float64}
    hu_m::Float64
    hw_m::Float64
    flanged::Bool
    floor_ratio::Union{Nothing, Float64}
    floor_meets::Union{Nothing, Bool}
    "§18.10.6.2 δu at the top of the wall [m], or `nothing` on the stress route."
    δu_m::Union{Nothing, Float64}
end

"""
    wall_line_members(wall, walls) -> Vector

This wall and every wall on its `wall_above` line, from the bottom story
up. Two walls pointing at the same wall above, or a cycle, throw.
"""
function wall_line_members(wall, walls)
    below_of = Dict{UInt, eltype(walls)}()
    for w in walls
        w.wall_above === nothing && continue
        id = objectid(w.wall_above)
        if haskey(below_of, id)
            throw(ArgumentError(
                "wall stack: two walls list the same wall as wall_above."))
        end
        below_of[id] = w
    end
    bottom = wall
    descending = Set{UInt}()
    while true
        id = objectid(bottom)
        id in descending && throw(ArgumentError("wall stack: wall_above cycles below the pier."))
        push!(descending, id)
        below = get(below_of, id, nothing)
        below === nothing && break
        bottom = below
    end
    line = [bottom]
    node = bottom.wall_above
    # The walk down already visited every wall above the bottom. A fresh set
    # catches a cycle in `wall_above` without treating that walk as one.
    climbing = Set{UInt}([objectid(bottom)])
    while node !== nothing
        id = objectid(node)
        id in climbing && throw(ArgumentError("wall stack: wall_above cycles above the pier."))
        push!(climbing, id)
        push!(line, node)
        node = node.wall_above
    end
    return line
end

"""
    wall_stack_continuous(wall, walls) -> Bool

True when the plan line reaches story 0 and no story on the line has an
opening.

ACI 318-19 §18.10.6.2 (corpus: aci-318-19, page 326) asks whether the wall
is effectively continuous from the base of the structure to the top of the
wall. An opening breaks that pier. Story 0 is the base. A single critical
section is not this fact.
"""
function wall_stack_continuous(wall, walls)
    line = wall_line_members(wall, walls)
    line[1].story == 0 || return false
    return all(isempty(w.openings) for w in line)
end

"Full height of the plan line, base to top."
function _line_height(line)
    h = line[1].base.L
    for w in line[2:end]
        h = h + w.base.L
    end
    return h
end

"`:positive` at `(x2, y2)`, `:negative` at `(x1, y1)`, or `nothing`."
function _boundary_end(wall, x, y)
    if hypot(x - wall.x1, y - wall.y1) <= WALL_CORNER_TOL_M
        return :negative
    end
    if hypot(x - wall.x2, y - wall.y2) <= WALL_CORNER_TOL_M
        return :positive
    end
    return nothing
end

"""
One flange at one end, or `nothing` for a rectangular pier.

`bf` is the web thickness plus the overhang past each web face. Each
overhang is the lesser of the concrete that is there and the §18.10.5.2
limit. No adjacent web is assumed, so the limit is 25 percent of the height
above the section. Two flanges, one at each end, throw: the section model
is one flange.
"""
function _boundary_flange(wall, walls, wall_index, assembly, height_above)
    assembly === nothing && return nothing
    assembly.joined || return nothing
    ends = Tuple{Symbol, Vector{Int}}[]
    for corner in assembly_corners(walls, assembly)
        wall_index in corner.wall_indices || continue
        at = _boundary_end(wall, corner.x, corner.y)
        at === nothing && continue
        perps = Int[]
        for j in corner.wall_indices
            j == wall_index && continue
            _folded_angle(_wall_dir(wall), _wall_dir(walls[j])) <= _WALL_COLINEAR_RAD &&
                continue
            push!(perps, j)
        end
        isempty(perps) && continue
        push!(ends, (at, perps))
    end
    isempty(ends) && return nothing
    length(ends) == 1 || throw(ArgumentError(
        "special boundary: wall $wall_index has a flange at both ends. " *
        "The gross section used here has one flange."))
    at, perps = only(ends)
    _, _, nx, ny = _pier_plan_axes(wall)
    tw = wall.thickness
    code = effective_flange_overhang(height_above).overhang
    side = Dict{Int, typeof(1.0u"m")}(-1 => zero(tw), 1 => zero(tw))
    tf = nothing
    for j in perps
        other = walls[j]
        tf === nothing || ustrip(u"m", other.thickness) ≈ ustrip(u"m", tf) ||
            throw(ArgumentError(
                "special boundary: wall $wall_index meets flange walls of " *
                "different thickness."))
        tf = other.thickness
        jx = at === :negative ? wall.x1 : wall.x2
        jy = at === :negative ? wall.y1 : wall.y2
        d1 = hypot(other.x1 - jx, other.y1 - jy)
        d2 = hypot(other.x2 - jx, other.y2 - jy)
        far = d1 >= d2 ? (other.x1, other.y1) : (other.x2, other.y2)
        along = (far[1] - jx) * nx + (far[2] - jy) * ny
        along == 0 && continue
        key = along > 0 ? 1 : -1
        reach = hypot(far[1] - jx, far[2] - jy)
        overhang = max(zero(tw), reach * u"m" - tw / 2)
        side[key] = max(side[key], overhang)
    end
    tf === nothing && return nothing
    left = min(side[-1], code)
    right = min(side[1], code)
    return (at = at, tw = tw, tf = tf, bf = tw + left + right)
end

"Fiber stress. Positive `M` compresses the positive end, matching the pier cut."
function _boundary_fiber_stress(N, M, lw, tw, flange)
    P = N * u"N"
    moment = M * u"N*m"
    if flange === nothing
        return wall_gross_fiber_stress(P, moment, lw, tw)
    end
    return wall_flanged_fiber_stress(P, moment, lw, flange.tw, flange.tf, flange.bf;
                                    flange_at = flange.at)
end

"""
Neutral-axis depth in metres at factored axial `Nu`, from the compression
face. `nothing` when no equilibrium depth exists.
"""
function _boundary_neutral_axis(material, lw, tw, ρl, Nu, flange, compression_end;
                                end_area=nothing, end_inset=nothing)
    fc = ustrip(u"Pa", material.concrete.fc′)
    fy = ustrip(u"Pa", material.rebar.Fy)
    Es = ustrip(u"Pa", material.rebar.E)
    lw_m = ustrip(u"m", lw)
    tw_m = ustrip(u"m", tw)
    Ast = ρl * lw_m * tw_m
    if end_area !== nothing
        flange === nothing || throw(ArgumentError(
            "special boundary: end bars are not placed in a flanged section."))
        found = wall_end_bar_capacity_si(fc, fy, Es, lw_m, tw_m, Ast, end_area, end_inset, Nu)
    elseif flange === nothing
        found = wall_moment_capacity_at_axial_si(fc, fy, Es, lw_m, tw_m, Ast, Nu)
    else
        found = wall_flanged_c_at_axial_si(
            fc, fy, Es, lw_m, tw_m, ustrip(u"m", flange.tf), ustrip(u"m", flange.bf),
            Ast, Nu; flange_in_compression = compression_end === flange.at)
    end
    found.converged || return nothing
    return found.c
end

"""
    elf_design_displacement(cases, direction, level) -> NamedTuple

δu from the drift-purpose ELF cases along `:x` or `:y`.

The value is the largest absolute `design_m` at `level` among torsion
`:none`, `:plus`, and `:minus`. A strength-purpose case is not read. The
sign on `design_m` is the sense of motion along the axis. `torsion` names
the case that supplied the value. An equal second case does not replace it.

# Citation
ASCE 7-22 §12.8.6.3, Eq. 12.8-16 (corpus: asce-7-22, PDF page 187).
ACI 318-19 §18.10.6.2 (corpus: aci-318-19, page 326): δu is that displacement
at the top of the wall.
"""
function elf_design_displacement(cases, direction::Symbol, level::Int)
    direction in (:x, :y) || throw(ArgumentError(
        "design displacement: direction is :x or :y (got :$direction)"))
    level >= 1 || throw(ArgumentError(
        "design displacement: level index must be positive (got $level)"))
    best = nothing
    torsion = nothing
    n = 0
    for case in cases
        case.purpose === :drift || continue
        case.direction === direction || continue
        case.torsion in (:none, :plus, :minus) || continue
        length(case.design_m) >= level || throw(ArgumentError(
            "design displacement: level $level is past a drift case " *
            "($(length(case.design_m)) levels)"))
        n += 1
        # The equation uses a length. The stored sign is the sense of motion.
        δ = abs(case.design_m[level])
        if best === nothing || δ > best
            best = δ
            torsion = case.torsion
        end
    end
    n > 0 || throw(ArgumentError(
        "design displacement: no drift-purpose case along :$direction"))
    return (δu_m = best, torsion = torsion)
end

"""
    elf_level_for_height(heights_m, height_m) -> Int

The level whose height above the base is the wall-top height.

The nearest level more than 1 mm away is refused. δu is not interpolated
between floors.
"""
function elf_level_for_height(heights_m, height_m::Real)
    height_m > 0 || throw(ArgumentError(
        "design displacement: wall height must be positive (got $height_m)"))
    isempty(heights_m) && throw(ArgumentError(
        "design displacement: the ELF analysis has no levels"))
    best_i = 0
    best_d = Inf
    for (i, h) in enumerate(heights_m)
        d = abs(h - height_m)
        d + 1e-9 < best_d || continue
        best_d = d
        best_i = i
    end
    best_d <= 1e-3 || throw(ArgumentError(
        "design displacement: wall top at $(height_m) m is not a floor level " *
        "(nearest floor is $(best_d) m away)"))
    return best_i
end

"""
    elf_wall_design_displacement(analysis, height_m, pier_direction) -> NamedTuple

δu at the floor whose height above the base is `height_m`, along the pier.

`pier_direction` is `:X` or `:Y`. A skew pier is not a stored ELF axis.
"""
function elf_wall_design_displacement(analysis::ElfStoryAnalysis, height_m::Real,
                                     pier_direction::Symbol)
    axis = pier_direction === :X ? :x : pier_direction === :Y ? :y :
        throw(ArgumentError(
            "design displacement: pier direction :$pier_direction is not a plan axis"))
    level = elf_level_for_height([lv.height_m for lv in analysis.levels], height_m)
    found = elf_design_displacement(analysis.cases, axis, level)
    return (δu_m = found.δu_m, torsion = found.torsion, level = level)
end

"""
    special_boundary_decision(wall, walls, wall_index, assembly, actions, material;
                             fc_floor=nothing, δu=nothing, elf=nothing,
                             pier_direction=nothing) -> SpecialBoundaryDecision

The boundary decision for one pier.

Earthquake combinations supply the fiber stress. Dead and wind combinations
are not read. The gross section is rectangular, or flanged when one
perpendicular wall meets an end. `hu` is this story's height: the floors
brace the compression edge.

§18.10.6.2 is the route at story 0 of a continuous line with hwcs/ℓw ≥ 2
when δu is known. δu is the drift-purpose design displacement at the floor
on top of that line, along the pier. Pass it as `δu`, or pass `elf` and
`pier_direction` and it is read from the analysis. A segment beside an
opening stays a rectangle on §18.10.6.3. A pier above the base stays there
too: the critical section is the base.

`c` is the largest §22.2 neutral-axis depth at the factored axial of the
earthquake strength combinations. R18.10.6.2 ties that axial to the
combination that produces δu. Those combinations are the factored earthquake
combinations this stage has. `fc_floor` is read only when an element is
required.
"""
function special_boundary_decision(wall, walls, wall_index, assembly, actions, material;
                                  single_critical_section::Bool = false,
                                  fc_floor = nothing,
                                  section_length = nothing,
                                  hu_override = nothing,
                                  δu = nothing,
                                  elf = nothing,
                                  pier_direction = nothing,
                                  end_area = nothing,
                                  end_inset = nothing)
    if single_critical_section && δu === nothing && elf === nothing
        throw(ArgumentError(
            "special boundary: §18.10.6.2 needs the design displacement δu."))
    end
    δu !== nothing && elf !== nothing && throw(ArgumentError(
        "special boundary: pass δu or the ELF analysis, not both."))
    line = wall_line_members(wall, walls)
    continuous = line[1].story == 0 && all(isempty(w.openings) for w in line)
    hw = _line_height(line)
    hwcs = _stacked_wall_height(wall)
    hu = hu_override === nothing ? wall.base.L : hu_override
    lw = section_length === nothing ?
        hypot(wall.x2 - wall.x1, wall.y2 - wall.y1) * u"m" : section_length
    lw_m = ustrip(u"m", lw)
    lw_m > 0 || throw(ArgumentError(
        "special boundary: wall $wall_index has no length."))
    ustrip(u"m", hu) > 0 || throw(ArgumentError(
        "special boundary: wall $wall_index has no story height."))
    # A segment beside an opening is its own rectangle. The wall's flange
    # belongs to the gross pier, not to this segment.
    flange = section_length === nothing ?
        _boundary_flange(wall, walls, wall_index, assembly, hwcs) : nothing
    best = -Inf
    governing = :positive
    n_eq = 0
    for action in actions
        action.combination in _BOUNDARY_EARTHQUAKE || continue
        n_eq += 1
        stress = _boundary_fiber_stress(action.N, action.M, lw, wall.thickness, flange)
        for (name, value) in ((:positive, stress.at_positive_end),
                              (:negative, stress.at_negative_end))
            σ = ustrip(u"Pa", value)
            if σ > best + 1.0
                best = σ
                governing = name
            end
        end
    end
    n_eq > 0 || throw(ArgumentError(
        "special boundary: wall $wall_index has no earthquake combination. " *
        "§18.10.6.3 reads combinations that include E."))
    fc = material.concrete.fc′
    σ_check = max(best, 0.0) * u"Pa"
    classified = stress_boundary_element(σ_check, fc)
    # §18.10.6.2 applies at the base of a continuous line, hwcs/ℓw ≥ 2, with δu
    # at the top of that line. A segment beside an opening is not that line.
    # ACI 318-19 §18.10.6.2 (corpus: aci-318-19, page 326).
    slender = ustrip(u"m", hwcs) / lw_m >= 2
    at_base = wall.story == 0 && continuous && section_length === nothing
    δu_use = nothing
    if at_base && slender
        if elf !== nothing && pier_direction in (:X, :Y)
            found = elf_wall_design_displacement(elf, ustrip(u"m", hw), pier_direction)
            δu_use = found.δu_m * u"m"
        elseif δu !== nothing
            δu_use = δu
        end
    end
    c_m = nothing
    c_face = governing
    if classified.triggered || δu_use !== nothing
        c_m, c_face = _largest_earthquake_c(
            material, lw, wall.thickness, wall.ρl, actions, flange;
            end_area, end_inset)
    end
    zone_length = nothing
    minimum = nothing
    shortfall = nothing
    route = :stress
    critical = false
    δu_stored = nothing
    if δu_use !== nothing
        c_m === nothing && throw(ArgumentError(
            "special boundary: wall $wall_index has no neutral-axis depth, so " *
            "§18.10.6.2(a) is not evaluated."))
        # §18.10.6.2(a) (corpus: aci-318-19, page 326). c is the largest §22.2
        # depth at the factored axial of the earthquake strength combinations.
        # R18.10.6.2 (same page) names the combination that produces δu. The
        # axials in hand are those earthquake combinations.
        trigger = displacement_boundary_element(
            c_m * u"m", lw, δu_use, hwcs; single_critical_section = true)
        trigger.required isa Bool || throw(ArgumentError(
            "special boundary: wall $wall_index is on §18.10.6.2 and the " *
            "section did not apply."))
        route = :displacement
        critical = true
        δu_stored = ustrip(u"m", δu_use)
        governing = c_face
        if trigger.required
            required = true
            required_by = :displacement
            zone_length, minimum, shortfall = _boundary_zone_record(
                wall, flange, governing, lw, hu, hw, c_m, true, true)
        else
            required = false
            required_by = :not_required
        end
    elseif classified.triggered && c_m !== nothing
        # §18.10.6.4(b) measures the compression zone that is in compression.
        # A flange there is bf. The web is the zone otherwise.
        web_is_zone = flange === nothing || governing !== flange.at
        b = web_is_zone ? wall.thickness : flange.bf
        result = special_boundary_composer(;
            lw = lw, hwcs = hwcs, hw = hw,
            continuous = continuous, single_critical_section = false,
            σ = σ_check, fc = fc, b = b, hu = hu, c = c_m * u"m",
            in_compression = flange !== nothing && governing === flange.at,
            effective_flange_width = flange === nothing ? nothing : flange.bf,
            height_above_section = flange === nothing ? nothing : hwcs)
        result.route === :stress || throw(ArgumentError(
            "special boundary: wall $wall_index took the $(result.route) route. " *
            "A single critical section is not stated."))
        result.required === true || throw(ArgumentError(
            "special boundary: wall $wall_index stress exceeds 0.2f′c and the " *
            "composer did not require an element."))
        zone_length = ustrip(u"m", result.length.length)
        tmin = boundary_minimum_thickness(result)
        minimum = tmin === nothing ? nothing : ustrip(u"m", tmin)
        # The jump adds this to the web thickness. bf is not that thickness.
        if minimum !== nothing && web_is_zone
            shortfall = max(0.0, minimum - ustrip(u"m", wall.thickness))
        elseif minimum !== nothing
            shortfall = 0.0
        end
        required = true
        required_by = :stress
    elseif classified.triggered
        required = true
        required_by = :stress
    elseif classified.may_discontinue
        required = false
        required_by = :may_discontinue
    else
        required = nothing
        required_by = :between
    end
    # §18.10.6.4(h) (corpus: aci-318-19, page 328): the floor at the element
    # is at least 0.7 f′c of the wall. Equality meets it. No stated floor
    # strength is not read as a pass.
    floor_ratio = nothing
    floor_meets = nothing
    if required === true && fc_floor !== nothing
        checked = floor_concrete_at_boundary(fc_floor, fc)
        floor_ratio = checked.ratio
        floor_meets = checked.meets
    end
    return SpecialBoundaryDecision(
        continuous, critical, route, required, required_by, governing, best,
        c_m, zone_length, minimum, shortfall, ustrip(u"m", hu), ustrip(u"m", hw),
        flange !== nothing, floor_ratio, floor_meets, δu_stored)
end

"""
Largest §22.2 neutral-axis depth among the earthquake combinations, and the
compression face that produced it.

An action with both fibers in tension is skipped. No converged depth returns
`(nothing, :positive)`.
"""
function _largest_earthquake_c(material, lw, tw, ρl, actions, flange;
                              end_area=nothing, end_inset=nothing)
    largest = nothing
    face = :positive
    for action in actions
        action.combination in _BOUNDARY_EARTHQUAKE || continue
        stress = _boundary_fiber_stress(action.N, action.M, lw, tw, flange)
        pos = ustrip(u"Pa", stress.at_positive_end)
        neg = ustrip(u"Pa", stress.at_negative_end)
        max(pos, neg) > 0 || continue
        end_face = pos >= neg ? :positive : :negative
        found = _boundary_neutral_axis(material, lw, tw, ρl, action.N, flange, end_face;
                                      end_area, end_inset)
        found === nothing && continue
        if largest === nothing || found > largest
            largest = found
            face = end_face
        end
    end
    return largest, face
end

"""
§18.10.6.4 length and thickness for a required element, and the web shortfall.

`critical` opens the 12 in. floor of §18.10.6.4(c) together with the other
gates inside [`compression_zone_width`](@ref). A flange in compression does
not resize the web, so its shortfall is zero.
"""
function _boundary_zone_record(wall, flange, face, lw, hu, hw, c_m, continuous, critical)
    web_is_zone = flange === nothing || face !== flange.at
    # §18.10.6.4(a) and (b)–(c) (corpus: aci-318-19, page 327).
    length = boundary_element_horizontal_length(c_m * u"m", lw)
    zone = compression_zone_width(hu, hw, lw, c_m * u"m";
                                 continuous = continuous,
                                 single_critical_section = critical)
    minimum = ustrip(u"m", zone.required)
    shortfall = web_is_zone ? max(0.0, minimum - ustrip(u"m", wall.thickness)) : 0.0
    return ustrip(u"m", length.length), minimum, shortfall
end

"""
Specified f′c of `params.floor`, or `nothing` when the design did not state one.

[`resolve_floor_options`](@ref) substitutes a flat plate when `floor` is
empty. That substitution is not a stated floor strength.
"""
function _boundary_floor_fc(params)
    opts = params.floor
    opts === nothing && return nothing
    hasproperty(opts, :material) || return nothing
    mat = opts.material
    hasproperty(mat, :fc′) && return mat.fc′
    hasproperty(mat, :concrete) && return mat.concrete.fc′
    return nothing
end

"True when this pier's direction is Table 12.2-1 row A.1 or B.4."
function _pier_on_special_row(direction::Symbol, row_x::Symbol, row_y::Symbol)
    if direction === :X
        return row_x in (:A1, :B4)
    elseif direction === :Y
        return row_y in (:A1, :B4)
    elseif direction === :skew
        return row_x in (:A1, :B4) && row_y in (:A1, :B4)
    end
    throw(ArgumentError("special boundary: pier direction $(direction) is not :X, :Y, or :skew."))
end
