# =============================================================================
# PixelFrame Section Polygon Extraction
# =============================================================================
#
# Extract the outer boundary polygon from a CompoundSection (stored on
# PixelFrameSection). Uses radial sweep to preserve concavities.
# CompoundSection geometry is in mm; output is in meters, centroid at origin.
# =============================================================================

"""
    _pixelframe_envelope_polygon(cs::CompoundSection) -> Vector{NTuple{2, Float64}}

Extract the single-loop boundary polygon from a CompoundSection.
Returns vertices in meters, centroid at origin. Preserves concavities via radial sweep.
"""
function _pixelframe_envelope_polygon(cs::CompoundSection)
    cx, cy = cs.centroid
    rings = Vector{Vector{NTuple{2, Float64}}}()
    for solid in cs.solids
        ring = NTuple{2, Float64}[]
        n = size(solid.points, 2)
        for j in 1:n
            # CompoundSection geometry is in mm
            y_m = (solid.points[1, j] - cx) * 1e-3
            z_m = (solid.points[2, j] - cy) * 1e-3
            push!(ring, (y_m, z_m))
        end
        length(ring) >= 3 && push!(rings, ring)
    end
    isempty(rings) && return NTuple{2, Float64}[]

    # Radial sweep from centroid preserves concavities
    n_angles = 180
    boundary = NTuple{2, Float64}[]
    for k in 0:(n_angles - 1)
        θ = 2π * k / n_angles
        d = (cos(θ), sin(θ))
        tmax = 0.0
        for ring in rings
            n = length(ring)
            for i in 1:n
                p = ring[i]
                q = ring[i == n ? 1 : i + 1]
                t = _ray_segment_intersection_distance(d, p, q)
                tmax = max(tmax, t)
            end
        end
        if tmax > 0
            push!(boundary, (tmax * d[1], tmax * d[2]))
        end
    end

    boundary = _dedupe_close_points(boundary; tol=1e-6)
    if length(boundary) < 3
        all_pts = NTuple{2, Float64}[]
        for ring in rings
            append!(all_pts, ring)
        end
        return _convex_hull_2d(all_pts)
    end
    return boundary
end

function _ray_segment_intersection_distance(d::NTuple{2, Float64}, p::NTuple{2, Float64}, q::NTuple{2, Float64})
    vx = q[1] - p[1]
    vy = q[2] - p[2]
    den = _cross2(d[1], d[2], vx, vy)
    abs(den) < 1e-12 && return 0.0
    t = _cross2(p[1], p[2], vx, vy) / den
    u = _cross2(p[1], p[2], d[1], d[2]) / den
    (t >= 0 && u >= 0 && u <= 1) ? t : 0.0
end

_cross2(ax::Float64, ay::Float64, bx::Float64, by::Float64) = ax * by - ay * bx

function _dedupe_close_points(points::Vector{NTuple{2, Float64}}; tol::Float64=1e-6)
    isempty(points) && return points
    out = NTuple{2, Float64}[points[1]]
    for i in 2:length(points)
        p = points[i]
        q = out[end]
        if hypot(p[1] - q[1], p[2] - q[2]) > tol
            push!(out, p)
        end
    end
    if length(out) >= 2 && hypot(out[1][1] - out[end][1], out[1][2] - out[end][2]) <= tol
        pop!(out)
    end
    return out
end

function _convex_hull_2d(points::Vector{NTuple{2, Float64}})
    isempty(points) && return NTuple{2, Float64}[]
    n = length(points)
    n <= 2 && return copy(points)
    # Graham scan
    start = argmin([(p[2], p[1]) for p in points])
    p0 = points[start]
    rest = [points[i] for i in 1:n if i != start]
    angle(p) = atan(p[2] - p0[2], p[1] - p0[1])
    sort!(rest; by=angle)
    hull = NTuple{2, Float64}[p0]
    for p in rest
        while length(hull) >= 2
            a, b = hull[end-1], hull[end]
            cross = (b[1] - a[1]) * (p[2] - a[2]) - (b[2] - a[2]) * (p[1] - a[1])
            cross >= 0 && break
            pop!(hull)
        end
        push!(hull, p)
    end
    return hull
end
