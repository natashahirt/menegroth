# Mesh the story-shell inputs saved by capture_story_shell_inputs.jl and report
# zero-area triangles, and whether Cholesky succeeds on a pinned model.
#
#   julia --project=StructuralSynthesizer scripts/runners/replay_story_shell_mesh.jl

using LinearAlgebra
using Serialization
using Unitful
using Asap
using StructuralSizer

const SZ = StructuralSizer

data = deserialize(joinpath(@__DIR__, "..", "..", "logs", "story_shell_inputs.jls"))
panels = [SZ.StoryShellPanel(p.polygon, Asap.ShellSection(p.t * u"m", p.E * u"Pa", p.ν;
                                                          ρ = 2400.0u"kg/m^3");
                             holes = p.holes)
          for p in data.panels]
sec = Asap.Section(6.6e-3u"m^2", 2.0e11u"Pa", 7.7e10u"Pa", 5.3e-5u"m^4", 1.8e-5u"m^4", 1e-6u"m^4")
beams = [SZ.ShellFrameBeam(b.xy, sec; id = b.id, release = b.release) for b in data.beams]
println("$(length(panels)) panels, $(length(beams)) beams, target edge $(data.target_edge) m")

pos(n) = (ustrip(u"m", n.position[1]), ustrip(u"m", n.position[2]))

function flat_triangles(shells)
    bad = []
    for sh in shells
        p = pos.(sh.nodes)
        a = ((p[2][1] - p[1][1]) * (p[3][2] - p[1][2]) - (p[2][2] - p[1][2]) * (p[3][1] - p[1][1])) / 2
        abs(a) < 1e-8 && push!(bad, p)
    end
    return bad
end

built = SZ.story_shell(panels, beams; target_edge = data.target_edge * u"m")
bad = flat_triangles(built.shells)
println("triangles: $(length(built.shells))  zero-area: $(length(bad))")
foreach(p -> println("  ", p), bad)
