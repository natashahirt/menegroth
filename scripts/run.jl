using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))  # Activate root project
Pkg.instantiate()

using Revise
using Unitful
using StructuralBase      # Shared types & constants
using StructuralSizer     # Member-level sizing (materials)
using StructuralSynthesizer  # Geometry & BIM logic
using Asap

# Generate building geometry
skel = gen_medium_office(160.0u"ft", 110.0u"ft", 13.0u"ft", 4, 3, 4);
struc = BuildingStructure(skel);

to_asap!(struc);

# Visualize
visualize(skel)
visualize(skel, struc.asap_model, mode=:deflected, color_by=:displacement)

# Example: access materials from StructuralSizer
println("A992 Steel Fy: ", A992_Steel.Fy)

# Example: access constants from StructuralBase (re-exported through StructuralSynthesizer)
println("Standard Live Load (Floor): ", Constants.LL_FLOOR)

node_forces = filter(l -> l isa Asap.NodeForce, struc.asap_model.loads)
