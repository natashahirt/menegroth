# Test visualization of Voronoi vertex tributaries

using StructuralSynthesizer
using StructuralSizer
using StructuralVisualization
using Unitful
using GLMakie

println("=== Generating Building ===")
# Generate a 2x2 bay, 1 story building
skel = gen_medium_office(20.0u"m", 16.0u"m", 4.0u"m", 2, 2, 1)
struc = BuildingStructure(skel)
# Use :vault (implemented) - OneWay/TwoWay/FlatPlate are stubs
initialize!(struc; floor_type=:vault)

println("Columns: ", length(struc.columns))
println("Cells: ", length(struc.cells))

println("\n=== Visualizing Edge Tributaries ===")
fig1 = visualize_cell_tributaries(struc)
# Don't save PNG during automated tests
println("Edge tributaries visualization OK")

println("\n=== Visualizing Vertex Tributaries (Story 1) ===")
fig2 = visualize_vertex_tributaries(struc; story=1)
# Don't save PNG during automated tests
println("Vertex tributaries visualization OK")

println("\n✓ All visualizations generated!")
