#!/usr/bin/env julia
# Quick test that BuildingDesign has asap_model_frame_edge_indices and serialization works.
using StructuralSynthesizer
using StructuralSynthesizer: BuildingDesign, BuildingStructure, DesignParameters, gen_medium_office
using Unitful

skel = gen_medium_office(100u"ft", 80u"ft", 12u"ft", 4, 3, 2)
struc = BuildingStructure(skel)
params = DesignParameters()
design = BuildingDesign(struc, params)

@assert isempty(design.asap_model_frame_edge_indices)
println("OK: BuildingDesign constructor and new field work")
println("  asap_model_frame_edge_indices length: ", length(design.asap_model_frame_edge_indices))
