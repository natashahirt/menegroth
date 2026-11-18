#=
Cell-by-cell tributary split of the core office, before any design.

    julia --project=StructuralSynthesizer scripts/runners/core_office_tributary_audit.jl

For each cell at a floor and at the roof: its vertices, the column areas, each
wall's area, and how far column + wall is from the cell area.
=#

using StructuralSynthesizer
using StructuralSizer
using Unitful

include(joinpath(@__DIR__, "core_office_geometry.jl"))

struc = BuildingStructure(core_office_skeleton())
initialize!(struc; floor_type = :flat_plate, wall_thickness = 0.3u"m")
vc = struc.skeleton.geometry.vertex_coords

shoelace(p) = 0.5 * abs(sum(p[k][1] * p[mod1(k + 1, length(p))][2] -
                            p[mod1(k + 1, length(p))][1] * p[k][2] for k in eachindex(p)))

println("walls: ", length(struc.walls))
for (i, w) in enumerate(struc.walls)
    w.story in (1, 3) || continue
    println("  wall $i story $(w.story)  ($(w.x1), $(w.y1)) -> ($(w.x2), $(w.y2))  H = $(w.base.L)")
end

for z in (7.2, 14.4)
    println("\n== cells at z = $z")
    tot_cell = tot_col = tot_wall = 0.0
    for (ci, cell) in enumerate(struc.cells)
        vis = struc.skeleton.face_vertex_indices[cell.face_idx]
        all(v -> abs(vc[v, 3] - z) < 1e-3, vis) || continue
        pts = [(round(vc[v, 1]; digits = 2), round(vc[v, 2]; digits = 2)) for v in vis]
        a = shoelace(pts)
        col = sum((get(c.tributary_cell_areas, ci, 0.0) for c in struc.columns); init = 0.0)
        walls = [(i, w.story, w.tributary_cell_areas[ci]) for (i, w) in enumerate(struc.walls)
                 if haskey(w.tributary_cell_areas, ci)]
        wall = sum((t[3] for t in walls); init = 0.0)
        tot_cell += a; tot_col += col; tot_wall += wall
        println("cell $ci  verts $(length(pts)) $pts")
        println("    area $(round(a; digits = 2))  columns $(round(col; digits = 2))  walls $(round(wall; digits = 2))  " *
                "missing $(round(a - col - wall; digits = 2))")
        for (i, s, ar) in walls
            println("      wall $i (story $s) $(round(ar; digits = 3))")
        end
    end
    println("total cell $(round(tot_cell; digits = 2))  columns $(round(tot_col; digits = 2))  " *
            "walls $(round(tot_wall; digits = 2))  missing $(round(tot_cell - tot_col - tot_wall; digits = 2))")
end
