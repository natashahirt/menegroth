# Cell geometry helpers for tributary area calculation
#
# Pure geometry types and functions - no external dependencies
# Extraction from BuildingSkeleton happens in StructuralSynthesizer

"""
    CellGeometry

Cached geometry for a single cell (bay).
All coordinates are in base units (typically meters).
"""
struct CellGeometry
    cell_idx::Int
    face_idx::Int
    vertices::Vector{NTuple{2, Float64}}  # (x, y) coordinates in order (CCW)
    edge_indices::Vector{Int}              # skeleton edge indices in order
    edge_lengths::Vector{Float64}          # length of each edge
    area::Float64                          # polygon area
end

"""
    CellGeometry(vertices, edge_indices; cell_idx=0, face_idx=0)

Construct CellGeometry from vertices, computing edge lengths and area.
"""
function CellGeometry(
    vertices::Vector{NTuple{2, Float64}},
    edge_indices::Vector{Int};
    cell_idx::Int = 0,
    face_idx::Int = 0,
)
    n = length(vertices)
    n >= 3 || throw(ArgumentError("Polygon must have at least 3 vertices"))
    
    # Compute edge lengths
    lengths = Float64[]
    for i in 1:n
        j = mod1(i + 1, n)
        dx = vertices[j][1] - vertices[i][1]
        dy = vertices[j][2] - vertices[i][2]
        push!(lengths, sqrt(dx^2 + dy^2))
    end
    
    # Compute area via shoelace formula
    area = polygon_area(vertices)
    
    return CellGeometry(cell_idx, face_idx, vertices, edge_indices, lengths, area)
end

"""
    polygon_area(verts::Vector{NTuple{2, Float64}}) -> Float64

Compute signed area of a polygon using the shoelace formula.
Returns positive for CCW winding, negative for CW.
"""
function polygon_area(verts::Vector{NTuple{2, Float64}})
    n = length(verts)
    n < 3 && return 0.0
    
    area = 0.0
    for i in 1:n
        j = mod1(i + 1, n)
        area += verts[i][1] * verts[j][2]
        area -= verts[j][1] * verts[i][2]
    end
    return abs(area) / 2
end

"""
    polygon_centroid(verts::Vector{NTuple{2, Float64}}) -> NTuple{2, Float64}

Compute centroid of a polygon given as ordered vertices.
"""
function polygon_centroid(verts::Vector{NTuple{2, Float64}})
    n = length(verts)
    n > 0 || return (0.0, 0.0)
    
    cx = sum(v[1] for v in verts) / n
    cy = sum(v[2] for v in verts) / n
    return (cx, cy)
end

"""
    edge_midpoint(verts, edge_idx) -> NTuple{2, Float64}

Get midpoint of edge `edge_idx` (1-indexed, wraps around).
"""
function edge_midpoint(verts::Vector{NTuple{2, Float64}}, edge_idx::Int)
    n = length(verts)
    i = mod1(edge_idx, n)
    j = mod1(edge_idx + 1, n)
    return ((verts[i][1] + verts[j][1]) / 2, (verts[i][2] + verts[j][2]) / 2)
end

"""
    is_convex(verts::Vector{NTuple{2, Float64}}) -> Bool

Check if polygon vertices form a convex shape (CCW or CW ordering).
"""
function is_convex(verts::Vector{NTuple{2, Float64}})
    n = length(verts)
    n < 3 && return false
    
    sign_sum = 0
    for i in 1:n
        j = mod1(i + 1, n)
        k = mod1(i + 2, n)
        
        # Cross product of consecutive edge vectors
        v1 = (verts[j][1] - verts[i][1], verts[j][2] - verts[i][2])
        v2 = (verts[k][1] - verts[j][1], verts[k][2] - verts[j][2])
        cross = v1[1] * v2[2] - v1[2] * v2[1]
        
        if abs(cross) > 1e-10
            sign_sum += sign(cross)
        end
    end
    
    # Convex if all cross products have the same sign
    return abs(sign_sum) == n
end

"""
    interior_angles(verts::Vector{NTuple{2, Float64}}) -> Vector{Float64}

Compute interior angles (radians) at each vertex of a convex polygon.
"""
function interior_angles(verts::Vector{NTuple{2, Float64}})
    n = length(verts)
    angles = Float64[]
    
    for i in 1:n
        prev = mod1(i - 1, n)
        next = mod1(i + 1, n)
        
        # Vectors from vertex i to neighbors
        v1 = (verts[prev][1] - verts[i][1], verts[prev][2] - verts[i][2])
        v2 = (verts[next][1] - verts[i][1], verts[next][2] - verts[i][2])
        
        # Angle between vectors (interior angle)
        dot = v1[1] * v2[1] + v1[2] * v2[2]
        mag1 = sqrt(v1[1]^2 + v1[2]^2)
        mag2 = sqrt(v2[1]^2 + v2[2]^2)
        
        if mag1 > 0 && mag2 > 0
            cos_angle = clamp(dot / (mag1 * mag2), -1.0, 1.0)
            push!(angles, acos(cos_angle))
        else
            push!(angles, 0.0)
        end
    end
    
    return angles
end
