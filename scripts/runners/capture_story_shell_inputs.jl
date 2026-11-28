# Save the panels and beam lines of the first story-shell mesh, then stop.
#
#   julia --project=StructuralSynthesizer scripts/runners/capture_story_shell_inputs.jl
#
# Same floor as diag_story_shell_sections.jl. Writes logs/story_shell_inputs.jls
# for replay_story_shell_mesh.jl.

ENV["SS_ENABLE_VISUALIZATION"] = "false"
ENV["SS_SKIP_SOLVER_WARMUP"] = "true"

using Serialization
using Unitful
using StructuralSynthesizer
using StructuralSizer

const SS = StructuralSynthesizer
const OUT = joinpath(@__DIR__, "..", "..", "logs", "story_shell_inputs.jls")

struct Captured <: Exception end

@eval StructuralSizer function story_shell(panels::AbstractVector{StoryShellPanel}, beams;
                                           target_edge::Length = 0.5u"m", section_at = nothing)
    data = (panels = [(polygon = p.polygon, holes = p.holes, t = p.section.thickness,
                       E = p.section.E, ν = p.section.ν) for p in panels],
            beams = [(xy = b.xy, id = b.id, release = b.release) for b in beams],
            target_edge = ustrip(u"m", target_edge))
    Main.serialize(Main.OUT, data)
    println("saved $(abspath(Main.OUT)): $(length(panels)) panels, $(length(beams)) beams")
    throw(Main.Captured())
end

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
try
    design_building(struc, json_to_params(api))
catch err
    err isa Captured || rethrow()
end
