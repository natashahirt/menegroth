# A solid head on a general rib arrangement.
#
# The head is the bays [`seed_column_head`](@ref) takes around the column.
# Those bays are cast as gross rectangles on the ribs that bound them
# (ACI 318-11 §13.7.3.1, corpus: aci-318-11, page 259). The frame is the
# arrangement, with a column stub at each column. A failing check grows one
# bay in its direction, or one ring when it names none, and the frame is
# solved again ([`resolve_column_head`](@ref)).
#
# ACI 318-19 §8.2.1 (corpus: aci-318-19, page 101) permits any analysis that
# satisfies equilibrium and compatibility. The skeleton on each bay is that
# load split. The clause does not prescribe the mesh.

"""
    analyze_arrangement_grillage(arr, heads, columns, pressure; kwargs...)
        -> NamedTuple

Solve the rib arrangement with `heads` cast solid.

`columns` are plan points in metres, each on a rib node. `pressure` is
pascals, downward. Each column is a stub fixed at its base. Ribs outside a
head keep the stem section `bw` by `h_rib`. Ribs on a head take the gross
rectangle from [`solid_edge_widths`](@ref), of depth `depth`. The model has
no self-weight: `pressure` is the whole load.

`rib_dims[e]`, when given, is `(bw, d, h)` in metres of the rib on edge `e`,
or `nothing` for an edge that takes `bw` by `h_rib`.

Returns the model, the upward reaction at each column, and the element index
of each arrangement edge.
"""
function analyze_arrangement_grillage(arr::StructuralSizer.RibArrangement,
                                      heads::AbstractVector{<:StructuralSizer.ColumnSolidHead},
                                      columns, pressure::Real;
                                      concrete::StructuralSizer.Concrete,
                                      depth::Length,
                                      bw::Length, h_rib::Length,
                                      column_size::Length = 0.40u"m",
                                      column_height::Length = 3.0u"m",
                                      rib_dims = nothing)
    isfinite(pressure) || throw(ArgumentError("panel pressure must be finite, got $pressure"))
    pressure >= 0 || throw(ArgumentError("panel pressure is not negative, got $pressure"))
    depth > zero(depth) || throw(ArgumentError("the solid head depth is positive, got $depth"))
    bw > zero(bw) || throw(ArgumentError("the rib web is positive, got $bw"))
    h_rib > zero(h_rib) || throw(ArgumentError("the rib depth is positive, got $h_rib"))
    column_size > zero(column_size) || throw(ArgumentError(
        "the column is positive, got $column_size"))
    column_height > zero(column_height) || throw(ArgumentError(
        "the column stub is positive, got $column_height"))
    length(columns) >= 1 || throw(ArgumentError("the grillage needs a column"))
    rib_dims === nothing || length(rib_dims) == length(arr.edges) || throw(ArgumentError(
        "rib_dims has $(length(rib_dims)) entries for $(length(arr.edges)) rib edges"))
    widths = StructuralSizer.solid_edge_widths(arr, heads)
    profiles = StructuralSizer.bay_edge_profiles(arr)
    ρ = 0.0u"kg/m^3"
    rib_sec = StructuralSizer.solid_head_section(bw, h_rib, concrete; density = ρ)
    own_secs = Dict{NTuple{2, Float64}, Any}()
    col_sec = StructuralSizer.solid_head_section(column_size, column_size, concrete; density = ρ)
    nodes = Asap.Node[]
    for (x, y) in arr.nodes
        push!(nodes, Asap.Node([x * u"m", y * u"m", 0.0u"m"], fill(true, 6)))
    end
    elements = Asap.Element[]
    loads = Asap.AbstractLoad[]
    for (e, (a, b)) in enumerate(arr.edges)
        sec = rib_sec
        own = rib_dims === nothing ? nothing : rib_dims[e]
        if own !== nothing
            sec = get!(own_secs, (own[1], own[3])) do
                StructuralSizer.solid_head_section(own[1] * u"m", own[3] * u"m", concrete;
                                                   density = ρ)
            end
        end
        w = get(widths, e, 0.0)
        if w > 0
            sec = StructuralSizer.solid_head_section(w * u"m", depth, concrete; density = ρ)
        end
        el = Asap.Element(nodes[a], nodes[b], sec, Symbol("rib_", e))
        push!(elements, el)
        prof = get(profiles, e, nothing)
        prof === nothing && throw(ArgumentError(
            "rib edge $e bounds no bay, so it has no load"))
        pos, wid = prof
        push!(loads, Asap.TributaryLoad(el, collect(Float64, pos),
                                         [wi * u"m" for wi in wid],
                                         pressure * u"Pa", (0.0, 0.0, -1.0)))
    end
    col_nodes = [_arrangement_column_node(arr, xy) for xy in columns]
    length(unique(col_nodes)) == length(col_nodes) || throw(ArgumentError(
        "two columns sit on the same rib node"))
    H = ustrip(u"m", column_height)
    bases = Asap.Node[]
    col_elements = Asap.Element[]
    for (k, node) in enumerate(col_nodes)
        p = arr.nodes[node]
        base = Asap.Node([p[1] * u"m", p[2] * u"m", -H * u"m"], fill(false, 6))
        push!(bases, base)
        push!(nodes, base)
        el = Asap.Element(base, nodes[node], col_sec, Symbol("column_", k))
        push!(col_elements, el)
        push!(elements, el)
    end
    model = Asap.Model(nodes, elements, loads)
    Asap.solve!(model)
    reactions = Float64[]
    for base in bases
        # Positive is upward, the same sign as a node fixed directly under
        # the slab. A fixed-base column on a continuous grillage can be in
        # tension; that reaction stays negative and is not a punching shear.
        push!(reactions, ustrip(u"N", base.reaction[3]))
    end
    return (
        model = model,
        reactions = reactions,
        column_elements = col_elements,
        n_edges = length(arr.edges),
    )
end

"""Arrangement node under `xy`, or an error naming the point."""
function _arrangement_column_node(arr, xy; tol::Float64 = 1e-4)
    p = (Float64(xy[1]), Float64(xy[2]))
    best = nothing
    best_d = tol
    for (k, q) in enumerate(arr.nodes)
        d = hypot(q[1] - p[1], q[2] - p[2])
        d <= best_d || continue
        best = k
        best_d = d
    end
    best === nothing && throw(ArgumentError(
        "no rib node is at ($(p[1]), $(p[2])) m"))
    return best
end

"""
Shear and moments the column stub delivers to the slab.

`Vu` is the upward force. `Mx` and `My` are the global end moment at the
slab, the same `K·u` components [`_joint_case_demand`](@ref) reads. The
general punching engine takes those as moments about the global axes.
"""
function _column_stub_demand(el, u)
    f = _element_forces_from_u(el, u, Asap.AbstractLoad[]; resolution = 3)
    # The element runs from the fixed base to the slab. A compression in
    # the column is a positive axial force at the base and the opposite
    # sign at the slab end. The upward force on the slab is that end compression.
    Vu = -f.P[end]
    Fe = el.K * u[el.globalID]
    return Vu, Fe[10], Fe[11]
end

"""Ribs that leave `head`, each `(path, outward)` in the solved edge order."""
function _arrangement_leaving_ribs(arr, head, n_edges::Int)
    solid = Set(head.bays)
    outline = Set{Int}()
    for bi in head.bays
        for v in arr.bays[bi].loop
            push!(outline, v)
        end
    end
    function bounds_head(e)
        for (k, bay) in enumerate(arr.bays)
            k in solid || continue
            e in bay.sides && return true
        end
        return false
    end
    ribs = NamedTuple[]
    for (e, (a, b)) in enumerate(arr.edges)
        bounds_head(e) && continue
        a_on = a in outline
        b_on = b in outline
        (a_on ⊻ b_on) || continue
        from = a_on ? a : b
        path = _arrangement_rib_path(arr, e, from, bounds_head)
        isempty(path) && continue
        far = a_on ? b : a
        dxy = arr.nodes[far] .- arr.nodes[from]
        L = hypot(dxy...)
        L > 1e-12 || continue
        # Edge elements are the first `n_edges` frame elements, in edge order.
        e <= n_edges || throw(ArgumentError("rib edge $e has no frame element"))
        push!(ribs, (path = path, outward = (dxy[1] / L, dxy[2] / L)))
    end
    return ribs
end

"""Collinear elements from edge `e`, walking away from `from` and off the head."""
function _arrangement_rib_path(arr, e::Int, from::Int, bounds_head)
    path = Tuple{Int, Bool}[]
    seen = Set{Int}()
    prev = from
    while true
        e in seen && break
        bounds_head(e) && break
        push!(seen, e)
        a, b = arr.edges[e]
        (a == prev || b == prev) || break
        from_start = a == prev
        push!(path, (e, from_start))
        nxt = from_start ? b : a
        step = arr.nodes[nxt] .- arr.nodes[prev]
        L = hypot(step...)
        L > 1e-12 || break
        step = step ./ L
        found = nothing
        for (j, (c, d)) in enumerate(arr.edges)
            j in seen && continue
            (c == nxt || d == nxt) || continue
            far = c == nxt ? d : c
            onward = arr.nodes[far] .- arr.nodes[nxt]
            Ls = hypot(onward...)
            Ls > 1e-12 || continue
            onward = onward ./ Ls
            onward[1] * step[1] + onward[2] * step[2] >= 1 - 1e-6 || continue
            found = j
            break
        end
        found === nothing && break
        e = found
        prev = nxt
    end
    return path
end

"""`(bw, d, h)` of the rib on edge `e`, metres, or the shared section."""
function _edge_rib_dims(rib_dims, e::Int, bw, d_rib, h_rib)
    own = rib_dims === nothing ? nothing : rib_dims[e]
    own === nothing && return (bw = bw, d = d_rib, h = h_rib)
    return (bw = own[1] * u"m", d = own[2] * u"m", h = own[3] * u"m")
end

"""Edge of `path` that holds the point `x` metres from the head face."""
function _path_edge_at(arr, path, x::Real)
    s = 0.0
    for (e, _) in path
        a, b = arr.edges[e]
        s += hypot((arr.nodes[b] .- arr.nodes[a])...)
        x <= s + 1e-9 && return e
    end
    return path[end][1]
end

"""
Column punching, one-way shear, and stem compression for one solved head.

The punching section is [`column_head_section`](@ref), at d/2 outside the
outline. The column reaction includes the load inside that section; the
shear on the section is the reaction minus that load, the same deduction
as [`check_rib_web_punching`](@ref). One-way shear is at d from the face,
where d is that of the rib piece at the face, and the section there is the
piece that holds that point. Hogging is at the face on the face piece, and
only the positive hogging component. `rib_dims` gives each edge its own
section; without it every rib is `bw`, `d_rib`, `h_rib`.
"""
function check_arrangement_head(arr, head, solved, pressure::Real;
                                concrete::StructuralSizer.Concrete,
                                d_head::Length, h_head::Length,
                                bw::Length, d_rib::Length, h_rib::Length,
                                fy::Pressure,
                                topping::Union{Nothing, Length} = nothing,
                                free_loops = (),
                                rib_dims = nothing)
    d_head > zero(d_head) || throw(ArgumentError(
        "the head's effective depth is positive, got $d_head"))
    section = StructuralSizer.column_head_section(arr, head, d_head; free_loops = free_loops)
    el = solved.column_element
    _, Mx, My = _column_stub_demand(el, solved.model.u)
    # The vertical force is the column's support reaction. Tension is not
    # a downward punching shear.
    Vu_N = max(solved.column_reaction, 0.0)
    area = section.area
    qu = pressure * u"Pa"
    inside = uconvert(u"N", qu * area)
    Vu = max(Vu_N * u"N" - inside, 0.0u"N")
    pts = [(p[1] * u"m", p[2] * u"m") for p in section.points]
    αs = section.closed ? 40 : 30
    column = StructuralSizer.punching_check_general(
        Vu, Mx * u"N*m", My * u"N*m", d_head, concrete.fc′, pts;
        closed = section.closed, αs = αs, λ = concrete.λ)
    col = (ok = column.ok, ratio = column.utilization, direction = column.direction)
    load_map = Asap.get_elemental_loads(solved.model)
    one_way = NamedTuple[]
    hogging = NamedTuple[]
    for rib in _arrangement_leaving_ribs(arr, head, solved.n_edges)
        face = _edge_rib_dims(rib_dims, rib.path[1][1], bw, d_rib, h_rib)
        stem = topping === nothing ? nothing : face.h - topping
        if stem !== nothing && stem < zero(stem)
            throw(ArgumentError("the topping is deeper than the rib, got $topping in $(face.h)"))
        end
        # ACI 318-11 §11.1.3.1: the section is at d from the face, or at the
        # end of the rib when the rib ends first.
        reach = _arrangement_path_length(arr, rib.path)
        x = min(ustrip(u"m", face.d), max(reach - 1e-6, 0.0))
        at = _edge_rib_dims(rib_dims, _path_edge_at(arr, rib.path, x), bw, d_rib, h_rib)
        Vu_rib = _path_shear(solved.model, rib.path, solved.model.u, load_map, x)
        chk = StructuralSizer.check_rib_shear_at_head(Vu_rib, at.bw, at.d, concrete.fc′;
                                                      λ = concrete.λ)
        push!(one_way, merge(chk, (outward = rib.outward, bw = at.bw, d = at.d)))
        Mu = _path_hogging(solved.model, rib.path, solved.model.u, load_map, 0.0)
        hog = StructuralSizer.check_rib_hogging_at_head(Mu, face.bw, face.d, concrete.fc′, fy;
                                                        stem = stem)
        push!(hogging, merge(hog, (outward = rib.outward, bw = face.bw, d = face.d)))
    end
    governed = StructuralSizer.govern_solid_head_checks(col, one_way, hogging; Vu = Vu)
    return merge(governed, (section = section, column_check = column))
end

"""Length, in metres, of a rib path of arrangement edges."""
function _arrangement_path_length(arr, path)
    s = 0.0
    for (e, _) in path
        a, b = arr.edges[e]
        s += hypot((arr.nodes[b] .- arr.nodes[a])...)
    end
    return s
end

"""Share of the arrangement area that the heads cover."""
function _solid_fraction(arr, heads)
    total = sum(b.area for b in arr.bays)
    total > 0 || return 0.0
    solid = 0.0
    for h in heads, b in h.bays
        solid += arr.bays[b].area
    end
    return solid / total
end

"""
    resolve_arrangement_heads(arr, columns, pressure; kwargs...) -> NamedTuple

Seed a head at each column, cast those bays solid, solve, and grow.
`heads` starts from those bays instead of the seed.

Each step grows the worst failing head and solves again. Column punching and
rib one-way shear at d from the head face grow it; stem compression does not.
The step goes one bay toward the column punching face when that check fails,
otherwise toward the failing ribs' shared outward direction, or one ring all
the way around when no side is named ([`grow_checked_column_head`](@ref)).
When that side is the slab edge or another head, the next of those is tried
([`_head_growth_directions`](@ref)).
The step is kept when the larger of the column punching and rib one-way
ratios falls. A step that meets another head or the slab edge, whose outline is not
one critical section, or that does not lower the ratio, is not taken,
and that head is left where it is. Another head
growing changes the frame, so a head that could not grow is tried again.
`stop` is `:passed` when every head passes, and `:stopped` when every
failing head has been tried on the final frame and cannot take another
useful step.

`outline` and `holes` are the free edges of the slab. The critical section
stops on them. A second call with the same arguments returns the same heads
and the same ratios.
"""
function resolve_arrangement_heads(arr::StructuralSizer.RibArrangement, columns, pressure::Real;
                                  outline = (),
                                  holes = (),
                                  concrete::StructuralSizer.Concrete,
                                  depth::Length, d_head::Length,
                                  bw::Length, d_rib::Length, h_rib::Length,
                                  fy::Pressure,
                                  topping::Union{Nothing, Length} = nothing,
                                  column_size::Length = 0.40u"m",
                                  column_height::Length = 3.0u"m",
                                  heads::Union{Nothing, AbstractVector{<:StructuralSizer.ColumnSolidHead}} = nothing,
                                  max_solid_fraction::Union{Nothing, Real} = nothing,
                                  rib_dims = nothing)
    if heads === nothing
        heads = StructuralSizer.ColumnSolidHead[
            StructuralSizer.seed_column_head(arr, xy) for xy in columns]
    else
        columns = [h.column for h in heads]
    end
    free_loops = isempty(outline) ? () : (outline, holes...)
    steps = 0
    capped = false
    stuck = falses(length(heads))
    local solved, checks
    while true
        solved, checks = _solve_arrangement_heads(arr, heads, columns, pressure;
            concrete = concrete, depth = depth, d_head = d_head,
            bw = bw, d_rib = d_rib, h_rib = h_rib, fy = fy, topping = topping,
            column_size = column_size, column_height = column_height,
            free_loops = free_loops, rib_dims = rib_dims)
        all(c -> c.ok, checks) && return (
            ok = true, heads = heads, checks = checks, steps = steps,
            stop = :passed, solved = solved)
        # The solid head grows for column punching and for a rib that fails
        # one-way shear on concrete alone. Stem compression is a rib-depth
        # problem and does not fill more pans.
        open = [i for i in eachindex(heads) if _head_grows(checks[i]) && !stuck[i]]
        if isempty(open)
            return (ok = false, heads = heads, checks = checks, steps = steps,
                    stop = capped ? :solid_cap : :stopped, solved = solved)
        end
        i = open[argmax([_head_growth_ratio(checks[k]) for k in open])]
        taken = [b for (k, h) in enumerate(heads) if k != i for b in h.bays]
        grown = nothing
        # The preferred side can be the slab edge: a column moment toward the
        # next slab names a face this slab's head cannot grow across. The
        # next side in the order is tried instead.
        for dir in _head_growth_directions(checks[i])
            step = try
                face = merge(checks[i], (direction = dir,))
                StructuralSizer.grow_checked_column_head(arr, heads[i], face;
                                                         taken = taken, free_loops = free_loops)
            catch err
                err isa ArgumentError || rethrow()
                _trace_head_step(heads[i], checks[i],
                                 "toward $(dir) threw: " * sprint(showerror, err))
                nothing
            end
            step === nothing && continue
            step.bays == heads[i].bays && continue
            # ENGINEERING JUDGMENT: growth stops once the solid bays cover
            # more than `max_solid_fraction` of the rib arrangement.
            if max_solid_fraction !== nothing
                trial_heads = copy(heads)
                trial_heads[i] = step
                if _solid_fraction(arr, trial_heads) > Float64(max_solid_fraction) + 1e-9
                    capped = true
                    _trace_head_step(heads[i], checks[i],
                                     "toward $(dir) would pass the solid-area cap")
                    continue
                end
            end
            grown = step
            break
        end
        if grown === nothing
            _trace_head_step(heads[i], checks[i], "no side can grow")
            stuck[i] = true
            continue
        end
        trial = copy(heads)
        trial[i] = grown
        # A step whose outline is not one critical section is not a head.
        trial_solved = try
            _solve_arrangement_heads(arr, trial, columns, pressure;
                concrete = concrete, depth = depth, d_head = d_head,
                bw = bw, d_rib = d_rib, h_rib = h_rib, fy = fy, topping = topping,
                column_size = column_size, column_height = column_height,
                free_loops = free_loops, rib_dims = rib_dims)
        catch err
            err isa ArgumentError || rethrow()
            _trace_head_step(heads[i], checks[i],
                             "trial with $(length(grown.bays)) bays threw: " * sprint(showerror, err))
            nothing
        end
        if trial_solved === nothing
            stuck[i] = true
            continue
        end
        _, trial_checks = trial_solved
        # Kept only when the ratio that grows the head falls.
        if _head_growth_ratio(trial_checks[i]) < _head_growth_ratio(checks[i]) - 1e-9
            _trace_head_step(heads[i], checks[i],
                             "grew to $(length(grown.bays)) bays, ratio " *
                             "$(round(_head_growth_ratio(trial_checks[i]); digits = 3))")
            heads = trial
            steps += 1
            # The other heads were judged on the previous frame.
            stuck .= false
            steps <= length(arr.bays) || throw(ArgumentError(
                "the solid heads grew once for every bay and have not passed"))
        else
            _trace_head_step(heads[i], checks[i],
                             "trial with $(length(grown.bays)) bays did not lower the ratio " *
                             "($(round(_head_growth_ratio(trial_checks[i]); digits = 3)))")
            stuck[i] = true
        end
    end
end

"""One line per growth attempt when `SS_TRACE_SOLID_HEADS=1`."""
function _trace_head_step(head, check, outcome::AbstractString)
    get(ENV, "SS_TRACE_SOLID_HEADS", "") == "1" || return
    println("solid head at $(head.column)  bays=$(length(head.bays))  ",
            "ratio=$(round(_head_growth_ratio(check); digits = 3))  ",
            "governing=$(check.governing)  $(outcome)")
    return
end

"""Ribs leaving the head that fail one-way shear on concrete alone."""
function _failing_one_way(check)
    hasproperty(check, :ribs) || return NamedTuple[]
    return [r for r in check.ribs if !r.ok]
end

"""
True when column punching fails or a rib leaving the head fails one-way shear.

Stem compression alone does not grow the head.
"""
function _head_grows(check)
    hasproperty(check, :column) && !check.column.ok && return true
    return !isempty(_failing_one_way(check))
end

"""
The side a growth step follows, or `nothing` for a ring.

A failing column punching check chooses: its face, including the 2% band in
`moment_names_a_face`. Otherwise the failing one-way ribs choose: their shared
outward direction, or none when they leave in different directions.
"""
function _head_growth_direction(check)
    if hasproperty(check, :column) && !check.column.ok
        return hasproperty(check.column, :direction) ? check.column.direction : nothing
    end
    failing = _failing_one_way(check)
    isempty(failing) && return hasproperty(check, :direction) ? check.direction : nothing
    return StructuralSizer._one_way_growth_direction(failing)
end

"""
Sides a growth step tries, in order: [`_head_growth_direction`](@ref), then
the failing ribs' shared outward direction, then one ring (`nothing`).
"""
function _head_growth_directions(check)
    dirs = Any[_head_growth_direction(check)]
    failing = _failing_one_way(check)
    isempty(failing) || push!(dirs, StructuralSizer._one_way_growth_direction(failing))
    push!(dirs, nothing)
    return unique(dirs)
end

"""
The ratio a growth step is judged on: the larger of column punching and rib
one-way shear. Stem compression is not in it.
"""
function _head_growth_ratio(check)
    hasproperty(check, :column) && hasproperty(check.column, :ratio) || return check.ratio
    rib = hasproperty(check, :ribs) && !isempty(check.ribs) ?
          maximum(r.ratio for r in check.ribs) : 0.0
    return max(check.column.ratio, rib)
end

"""Solve `heads` and check each column."""
function _solve_arrangement_heads(arr, heads, columns, pressure;
                                 free_loops, concrete, depth, d_head,
                                 bw, d_rib, h_rib, fy, topping,
                                 column_size, column_height, rib_dims = nothing)
    solved = analyze_arrangement_grillage(arr, heads, columns, pressure;
        concrete = concrete, depth = depth, bw = bw, h_rib = h_rib,
        column_size = column_size, column_height = column_height, rib_dims = rib_dims)
    checks = map(enumerate(heads)) do (i, head)
        one = (
            model = solved.model,
            n_edges = solved.n_edges,
            column_element = solved.column_elements[i],
            column_reaction = solved.reactions[i],
        )
        check_arrangement_head(arr, head, one, pressure;
            concrete = concrete, d_head = d_head, h_head = depth,
            bw = bw, d_rib = d_rib, h_rib = h_rib, fy = fy, topping = topping,
            free_loops = free_loops, rib_dims = rib_dims)
    end
    return solved, checks
end
