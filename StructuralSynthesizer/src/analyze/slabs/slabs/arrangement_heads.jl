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
                                      column_height::Length = 3.0u"m")
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
    widths = StructuralSizer.solid_edge_widths(arr, heads)
    profiles = StructuralSizer.bay_edge_profiles(arr)
    ρ = 0.0u"kg/m^3"
    rib_sec = StructuralSizer.solid_head_section(bw, h_rib, concrete; density = ρ)
    col_sec = StructuralSizer.solid_head_section(column_size, column_size, concrete; density = ρ)
    nodes = Asap.Node[]
    for (x, y) in arr.nodes
        push!(nodes, Asap.Node([x * u"m", y * u"m", 0.0u"m"], fill(true, 6)))
    end
    elements = Asap.Element[]
    loads = Asap.AbstractLoad[]
    for (e, (a, b)) in enumerate(arr.edges)
        sec = rib_sec
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

"""
Column punching, one-way shear, and stem compression for one solved head.

The punching section is [`column_head_section`](@ref), at d/2 outside the
outline. The column reaction includes the load inside that section; the
shear on the section is the reaction minus that load, the same deduction
as [`check_rib_web_punching`](@ref). One-way shear is at `d_rib` from the
face. Hogging is at the face, and only the positive hogging component.
"""
function check_arrangement_head(arr, head, solved, pressure::Real;
                                concrete::StructuralSizer.Concrete,
                                d_head::Length, h_head::Length,
                                bw::Length, d_rib::Length, h_rib::Length,
                                fy::Pressure,
                                topping::Union{Nothing, Length} = nothing,
                                free_loops = ())
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
    d_m = ustrip(u"m", d_rib)
    stem = topping === nothing ? nothing : h_rib - topping
    if stem !== nothing && stem < zero(stem)
        throw(ArgumentError("the topping is deeper than the rib, got $topping in $h_rib"))
    end
    one_way = NamedTuple[]
    hogging = NamedTuple[]
    for rib in _arrangement_leaving_ribs(arr, head, solved.n_edges)
        # The section is at d from the face, or at the end of the rib when
        # the rib ends first.
        reach = _arrangement_path_length(arr, rib.path)
        Vu_rib = _path_shear(solved.model, rib.path, solved.model.u, load_map,
                             min(d_m, max(reach - 1e-6, 0.0)))
        chk = StructuralSizer.check_rib_shear_at_head(Vu_rib, bw, d_rib, concrete.fc′;
                                                      λ = concrete.λ)
        push!(one_way, merge(chk, (outward = rib.outward,)))
        Mu = _path_hogging(solved.model, rib.path, solved.model.u, load_map, 0.0)
        hog = StructuralSizer.check_rib_hogging_at_head(Mu, bw, d_rib, concrete.fc′, fy;
                                                        stem = stem)
        push!(hogging, merge(hog, (outward = rib.outward,)))
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

"""
    resolve_arrangement_heads(arr, columns, pressure; kwargs...) -> NamedTuple

Seed a head at each column, cast those bays solid, solve, and grow.

Each step grows the worst failing head and solves again: one bay toward a
named direction, or one ring all the way around when the check names none
([`grow_checked_column_head`](@ref)). The step is kept when its ratio
falls. A step that meets another head or the slab edge, or does not lower
the ratio, is not taken, and that head is left where it is. `stop` is
`:passed` when every head passes, and `:stopped` when a failing head cannot
take another useful step.

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
                                  column_height::Length = 3.0u"m")
    heads = StructuralSizer.ColumnSolidHead[StructuralSizer.seed_column_head(arr, xy) for xy in columns]
    free_loops = isempty(outline) ? () : (outline, holes...)
    steps = 0
    stuck = falses(length(heads))
    local solved, checks
    while true
        solved, checks = _solve_arrangement_heads(arr, heads, columns, pressure;
            concrete = concrete, depth = depth, d_head = d_head,
            bw = bw, d_rib = d_rib, h_rib = h_rib, fy = fy, topping = topping,
            column_size = column_size, column_height = column_height,
            free_loops = free_loops)
        all(c -> c.ok, checks) && return (
            ok = true, heads = heads, checks = checks, steps = steps,
            stop = :passed, solved = solved)
        open = [i for i in eachindex(heads) if !checks[i].ok && !stuck[i]]
        if isempty(open)
            return (ok = false, heads = heads, checks = checks, steps = steps,
                    stop = :stopped, solved = solved)
        end
        i = open[argmax([checks[k].ratio for k in open])]
        grown = try
            taken = [b for (k, h) in enumerate(heads) if k != i for b in h.bays]
            StructuralSizer.grow_checked_column_head(arr, heads[i], checks[i];
                                                     taken = taken, free_loops = free_loops)
        catch err
            err isa ArgumentError || rethrow()
            stuck[i] = true
            continue
        end
        if grown.bays == heads[i].bays
            stuck[i] = true
            continue
        end
        trial = copy(heads)
        trial[i] = grown
        _, trial_checks = _solve_arrangement_heads(arr, trial, columns, pressure;
            concrete = concrete, depth = depth, d_head = d_head,
            bw = bw, d_rib = d_rib, h_rib = h_rib, fy = fy, topping = topping,
            column_size = column_size, column_height = column_height,
            free_loops = free_loops)
        if trial_checks[i].ratio < checks[i].ratio - 1e-9
            heads = trial
            steps += 1
            steps <= length(arr.bays) || throw(ArgumentError(
                "the solid heads grew once for every bay and have not passed"))
        else
            stuck[i] = true
        end
    end
end

"""Solve `heads` and check each column."""
function _solve_arrangement_heads(arr, heads, columns, pressure;
                                 free_loops, concrete, depth, d_head,
                                 bw, d_rib, h_rib, fy, topping,
                                 column_size, column_height)
    solved = analyze_arrangement_grillage(arr, heads, columns, pressure;
        concrete = concrete, depth = depth, bw = bw, h_rib = h_rib,
        column_size = column_size, column_height = column_height)
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
            free_loops = free_loops)
    end
    return solved, checks
end
