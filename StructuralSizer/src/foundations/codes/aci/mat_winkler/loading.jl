# ─────────────────────────────────────────────────────────────────────────────
# Column load application
# ─────────────────────────────────────────────────────────────────────────────

"""
    _find_nearest_node(nodes, x_m, y_m) → (node, dist)

Find the node closest to (x_m, y_m) in meters.
"""
function _find_nearest_node(nodes::Vector{Node}, x_m::Float64, y_m::Float64)
    best = nodes[1]
    best_d2 = Inf
    for node in nodes
        nx = ustrip(u"m", node.position[1])
        ny = ustrip(u"m", node.position[2])
        d2 = (nx - x_m)^2 + (ny - y_m)^2
        if d2 < best_d2
            best_d2 = d2
            best = node
        end
    end
    return best, sqrt(best_d2)
end

"""
    _mat_apply_column_loads(nodes, positions_loc_m, demands) → Vector{NodeForce}

Apply each column's Pu as a downward NodeForce at the nearest mesh node.
With ShellPatch, there is always a node at (or very near) the column center.
"""
function _mat_apply_column_loads(
    nodes::Vector{Node},
    positions_loc_m::Vector{NTuple{2, Float64}},
    demands::Vector{<:FoundationDemand}
)
    loads = NodeForce[]
    for (k, dem) in enumerate(demands)
        cx, cy = positions_loc_m[k]
        Pu_N = ustrip(u"N", dem.Pu)
        node, _ = _find_nearest_node(nodes, cx, cy)
        push!(loads, NodeForce(node, [0.0, 0.0, -Pu_N] .* u"N"))
    end
    return loads
end

