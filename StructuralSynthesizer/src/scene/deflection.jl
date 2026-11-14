# Reference evaluation of the deflected shape stored in a scene packet.
# The viewer shader implements the same expressions. Both follow
# `unodal` in external/Asap/src/Analysis/displacements.jl.

"""
    hermite_local(ul, L, t, dy_particular, dz_particular) -> (dx, dy, dz)

Local-frame displacement at `t ∈ [0, 1]` along an element of length `L` (meters).

`ul` is the 12-vector `R * u_global` after the `etype2DOF` release mask,
the same local vector `unodal` uses. The
particular terms are the member-load contribution in the local y and z
directions (0 for an element with no member load).
"""
function hermite_local(ul::AbstractVector{<:Real}, L::Real, t::Real,
                       dy_particular::Real = 0, dz_particular::Real = 0)
    L > 0 || error("hermite_local: length must be positive (got $L)")
    (0 <= t <= 1) || error("hermite_local: t must be in [0, 1] (got $t)")
    xL = float(t)
    x = xL * float(L)
    dx = (1 - xL) * ul[1] + xL * ul[7]
    n1 = 1 - 3xL^2 + 2xL^3
    n2 = x * (1 - xL)^2
    n3 = 3xL^2 - 2xL^3
    n4 = x^2 / float(L) * (-1 + xL)
    dy = n1 * ul[2] + n2 * ul[6] + n3 * ul[8] + n4 * ul[12] + dy_particular
    dz = n1 * ul[3] + n2 * (-ul[5]) + n3 * ul[9] + n4 * (-ul[11]) + dz_particular
    return (dx, dy, dz)
end

"""
    scene_station_displacement(packet, element, station) -> NTuple{3,Float64}

Global displacement (meters) of frame element `element` (1-based) at station
`station` (1-based), using the Float32 values stored in the packet. Station
`stations` is the end node. This is the quantity the viewer draws.
"""
function scene_station_displacement(packet::ScenePacket, element::Int, station::Int)
    stations = Int(packet.meta["stations"])
    (1 <= station <= stations) || error("scene: station $station is outside 1:$stations")
    ul_all = scene_f32(packet, "element_local_dof")
    lcs_all = scene_f32(packet, "element_lcs")
    pairs = scene_u32(packet, "element_nodes")
    pos = scene_f32(packet, "node_position")
    n_elem = length(ul_all) ÷ 12
    (1 <= element <= n_elem) || error("scene: element $element is outside 1:$n_elem")

    ul = ul_all[(element - 1) * 12 + 1 : element * 12]
    lcs = lcs_all[(element - 1) * 9 + 1 : element * 9]
    a = Int(pairs[(element - 1) * 2 + 1]) + 1
    b = Int(pairs[(element - 1) * 2 + 2]) + 1
    p0 = ntuple(k -> pos[(a - 1) * 3 + k], 3)
    p1 = ntuple(k -> pos[(b - 1) * 3 + k], 3)
    L = sqrt((p1[1] - p0[1])^2 + (p1[2] - p0[2])^2 + (p1[3] - p0[3])^2)
    t = (station - 1) / (stations - 1)

    dy_p = 0.0
    dz_p = 0.0
    loaded = scene_u32(packet, "load_element")
    particular = scene_f32(packet, "load_particular")
    row = findfirst(==(UInt32(element - 1)), loaded)
    if row !== nothing
        base = (row - 1) * stations * 2 + (station - 1) * 2
        dy_p = particular[base + 1]
        dz_p = particular[base + 2]
    end

    dx, dy, dz = hermite_local(ul, L, t, dy_p, dz_p)
    lx = lcs[1:3]
    ly = lcs[4:6]
    lz = lcs[7:9]
    return (
        dx * lx[1] + dy * ly[1] + dz * lz[1],
        dx * lx[2] + dy * ly[2] + dz * lz[2],
        dx * lx[3] + dy * ly[3] + dz * lz[3],
    )
end
