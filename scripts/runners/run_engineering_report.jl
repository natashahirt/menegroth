# =============================================================================
# Runner: Engineering Report
# =============================================================================
# Generates a dense engineering report for a designed building.
#
# Usage:
#   julia --project scripts/runners/run_engineering_report.jl
#
# Output: prints to stdout (pipe to file with `> report.txt` if desired).
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."))
Pkg.instantiate()

using Logging
global_logger(NullLogger())  # suppress solver noise

using Unitful
using StructuralSizer
using StructuralSynthesizer

# =============================================================================
# Build & design the building
# =============================================================================
skel = gen_medium_office(125.0u"ft", 90.0u"ft", 13.0u"ft", 5, 3, 3)
struc = BuildingStructure(skel)

design = design_building(struc, DesignParameters(
    name = "3-Story Flat Plate Office",
    max_iterations = 100,
    materials = StructuralSynthesizer.MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
    columns = ConcreteColumnOptions(section_shape = :rect),
    floor = FlatPlateOptions(
        method = EFM(),
        cover = 0.75u"inch",
        bar_size = 5,
        shear_studs = :always,
        min_h = 5.0u"inch",
    ),
    foundation_options = FoundationParameters(
        soil = medium_sand,
        pier_width = 0.35u"m",
        min_depth = 0.4u"m",
        group_tolerance = 0.15,
    ),
))

# =============================================================================
# Generate the engineering report
# =============================================================================
engineering_report(design)
