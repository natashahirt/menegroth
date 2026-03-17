#!/usr/bin/env julia
# =============================================================================
# Smoke test: 3-storey high medium office
# =============================================================================
# Usage:
#   julia --project=StructuralSynthesizer scripts/runners/run_smoke_medium_office_3storey.jl
# =============================================================================

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] = get(ENV, "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD", "false")

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))
Pkg.instantiate()

using Unitful
using StructuralSizer
using StructuralSynthesizer

println("Running smoke test: 3-storey high medium office")

# User-provided geometry target:
# X=[0,159], Y=[0,108], Z levels=[0,14,28,42]
# => footprint 159ft x 108ft, 14ft storey height, 3 storeys.
# 8 x-bays and 5 y-bays yields 54 vertices/story and 216 total vertices.
skel = gen_medium_office(159.0u"ft", 108.0u"ft", 14.0u"ft", 8, 5, 3)
struc = BuildingStructure(skel)

params = DesignParameters(
    name = "smoke_3_storey_high_medium_office",
    max_iterations = 3,
    materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
    floor = FlatPlateOptions(method = DDM()),
)

design = design_building(struc, params)

@assert length(skel.vertices) == 216 "Smoke test failed: expected 216 vertices, got $(length(skel.vertices))"
@assert haskey(skel.groups_vertices, :support) "Smoke test failed: skeleton has no :support group"
@assert length(skel.groups_vertices[:support]) == 54 "Smoke test failed: expected 54 support vertices, got $(length(skel.groups_vertices[:support]))"
@assert haskey(skel.groups_edges, :beams) "Smoke test failed: skeleton has no :beams group"
@assert haskey(skel.groups_edges, :columns) "Smoke test failed: skeleton has no :columns group"
beams_per_level = 8 * (5 + 1) + (8 + 1) * 5
reference_mode_beams = 3 * beams_per_level # summary excludes roof beams
@assert reference_mode_beams == 279 "Smoke test failed: expected reference beam count 279, got $reference_mode_beams"
@assert length(skel.groups_edges[:columns]) == 162 "Smoke test failed: expected 162 columns, got $(length(skel.groups_edges[:columns]))"
@assert length(skel.stories_z) == 4 "Smoke test failed: expected 4 z-levels, got $(length(skel.stories_z))"

@assert length(design.columns) > 0 "Smoke test failed: no columns in design output"
@assert length(design.slabs) > 0 "Smoke test failed: no slabs in design output"
@assert design.compute_time_s > 0 "Smoke test failed: invalid compute time"

println("Smoke test passed.")
println("  vertices: $(length(skel.vertices))")
println("  beams (generator incl. roof): $(length(skel.groups_edges[:beams]))")
println("  beams (reference mode):       $reference_mode_beams")
println("  columns:  $(length(skel.groups_edges[:columns]))")
println("  supports: $(length(skel.groups_vertices[:support]))")
z_levels_ft = round.(ustrip.(u"ft", skel.stories_z), digits=2)
println("  z_levels: $(join(z_levels_ft, ", "))")
println("  sized columns: $(length(design.columns))")
println("  slabs:   $(length(design.slabs))")
println("  time_s:  $(round(design.compute_time_s, digits=2))")
