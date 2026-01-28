# Test visualization of Voronoi vertex tributaries

using StructuralSynthesizer
using StructuralSizer
using Unitful
using GLMakie

println("=== Generating Building ===")
# Generate a 2x2 bay, 1 story building
skel = gen_medium_office(20.0u"m", 16.0u"m", 4.0u"m", 2, 2, 1)
struc = BuildingStructure(skel)
initialize!(struc)

println("Columns: ", length(struc.columns))
println("Cells: ", length(struc.cells))

println("\n=== Visualizing Edge Tributaries ===")
fig1 = visualize_cell_tributaries(struc)
save("edge_tributaries.png", fig1)
println("Saved: edge_tributaries.png")

println("\n=== Visualizing Vertex Tributaries (Story 1) ===")
fig2 = visualize_vertex_tributaries(struc; story=1)
save("vertex_tributaries.png", fig2)
println("Saved: vertex_tributaries.png")

println("\n=== Visualizing Combined (Cell 1) ===")
fig3 = visualize_tributaries_combined(struc, 1)
save("combined_tributaries.png", fig3)
println("Saved: combined_tributaries.png")

println("\n=== Testing color_by=:vertex_tributary in 3D visualize ===")
fig4 = visualize(struc; color_by=:vertex_tributary)
save("vertex_trib_3d.png", fig4)
println("Saved: vertex_trib_3d.png")

println("\n=== Testing color_by=:tributary (edge) in 3D visualize ===")
fig5 = visualize(struc; color_by=:tributary)
save("edge_trib_3d.png", fig5)
println("Saved: edge_trib_3d.png")

println("\n✓ All visualizations generated!")
println("Check the saved PNG files in the current directory.")
