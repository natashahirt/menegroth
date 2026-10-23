#!/usr/bin/env julia
# Validate corner_critical_section (half-plane clipper) against the known
# orthogonal reductions, then exercise a non-orthogonal wedge.
using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))
using StructuralSizer
using Unitful
const SS = StructuralSizer

c1 = 16.0u"inch"; c2 = 16.0u"inch"; d = 6.0u"inch"
inch(x) = ustrip(u"inch", x)

function b0_of(pts, closed)
    p = SS.critical_section_properties(pts, d; closed = closed)
    return ustrip(u"inch", p.b0), p
end

println("=== Orthogonal CONVEX corner (expect b0 = c1+c2+d = 38) ===")
pts_c, cl_c = SS.corner_critical_section(c1, c2, d, :convex, [(-1.0, 0.0), (0.0, -1.0)])
b0c, pc = b0_of(pts_c, cl_c)
println("  closed=$cl_c  nverts=$(length(pts_c))  b0=$b0c")
for p in pts_c; println("    (", round(inch(p[1]),digits=3), ", ", round(inch(p[2]),digits=3), ")"); end
# reference: rectangular :corner
rc, rcl = SS.rectangular_critical_section(c1, c2, d; position = :corner)
b0r, _ = b0_of(rc, rcl)
println("  rectangular(:corner) b0=$b0r")

println("\n=== Orthogonal RE-ENTRANT corner (expect b0 = 2(c1+c2)+3d = 82) ===")
pts_r, cl_r = SS.corner_critical_section(c1, c2, d, :reentrant, [(-1.0, 0.0), (0.0, -1.0)])
b0rr, prr = b0_of(pts_r, cl_r)
println("  closed=$cl_r  nverts=$(length(pts_r))  b0=$b0rr")
for p in pts_r; println("    (", round(inch(p[1]),digits=3), ", ", round(inch(p[2]),digits=3), ")"); end
# legacy hexagon (over-counts by d)
hx, hcl = SS.reentrant_critical_section(c1, c2, d)
b0h, _ = b0_of(hx, hcl)
println("  legacy reentrant hexagon b0=$b0h  (expect 88, over by d=6)")

println("\n=== Non-orthogonal 60deg CONVEX wedge (sanity: open, b0 reasonable) ===")
# two edges at 120deg apart interior; inward normals at ±60deg from -y
θ = deg2rad(30)
n1 = (-sin(θ),  -cos(θ))   # tilted inward normal
n2 = ( sin(θ),  -cos(θ))
pts_w, cl_w = SS.corner_critical_section(c1, c2, d, :convex, [n1, n2])
b0w, pw = b0_of(pts_w, cl_w)
println("  closed=$cl_w  nverts=$(length(pts_w))  b0=$b0w  θp=$(pw.θp)")
for p in pts_w; println("    (", round(inch(p[1]),digits=3), ", ", round(inch(p[2]),digits=3), ")"); end

println("\nDONE")
