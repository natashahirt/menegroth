"""Extract support positions as (x, y) length tuples for a mat layout.

The element type is fixed so an empty support list — a wall mat whose
columns all sit on the wall line — still dispatches on
`Vector{<:NTuple{2,<:Length}}`. An untyped comprehension over that empty
list comes back as `Tuple{Any,Any}`.
"""
function _support_positions_xy(struc, supp_indices::Vector{Int})
    skel = struc.skeleton
    PT = Tuple{typeof(1.0u"m"), typeof(1.0u"m")}
    return PT[
        let v = skel.vertices[struc.supports[i].vertex_idx]
            c = Meshes.coords(v)
            (uconvert(u"m", c.x), uconvert(u"m", c.y))
        end for i in supp_indices]
end

