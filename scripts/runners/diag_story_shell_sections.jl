# Which beam sections move on the auto-framing story shell, pass by pass.
#
# The floor is the design_building case in test_auto_framing_integration.jl:
# 54 ft × 42 ft, 3×3 bays, one story, steel joists at 24 in, concrete girders.
# Visualization is skipped; sizing is the same path that warns
# "still changed after 6 story-shell passes".
#
#   julia --project=StructuralSynthesizer scripts/runners/diag_story_shell_sections.jl
#
# Each line is one sizing pass. Pass 0 is the tributary sizing before any
# shell solve. A later pass that "repeats pass k" has the same section on
# every beam as pass k.

ENV["SS_ENABLE_VISUALIZATION"] = "false"
ENV["SS_SKIP_SOLVER_WARMUP"] = "true"
ENV["SS_TRACE_SHELL_PASSES"] = "1"

using Unitful
using StructuralSynthesizer
using StructuralSizer

const SS = StructuralSynthesizer

skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 1)
struc = BuildingStructure(skel)
api = SS.APIParams(
    floor_type = "one_way",
    skip_visualization = true,
    framing_levels = [
        SS.APIFramingLevel(material = "steel", spacing_in = 24.0),
        SS.APIFramingLevel(material = "concrete", role = "beam"),
    ],
)
params = json_to_params(api)
println("sizing the 3×3 auto-framing floor")
design = design_building(struc, params)
println("finished  beams=$(length(design.structure.beams))")
