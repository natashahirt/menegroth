# Does a 3×3-bay story with beams on every column line mesh without zero-area
# triangles? Compares the current story_shell against the former outline
# (collinear boundary vertices dropped).
#
#   julia --project=StructuralSynthesizer scripts/runners/check_story_shell_flat_triangles.jl

using Unitful
using Asap
using StructuralSizer

const SZ = StructuralSizer

function bay_story(xs, ys)
    sec = Asap.ShellSection(0.15u"m", 30e9u"Pa", 0.2; ρ = 2400u"kg/m^3")
    panels = [SZ.StoryShellPanel([(xs[i], ys[j]), (xs[i + 1], ys[j]), (xs[i + 1], ys[j + 1]),
                                  (xs[i], ys[j + 1])], sec)
              for i in 1:(length(xs) - 1), j in 1:(length(ys) - 1)]
    steel = Asap.Section(6.6e-3u"m^2", 2.0e11u"Pa", 7.7e10u"Pa", 5.3e-5u"m^4",
                         1.8e-5u"m^4", 1e-6u"m^4")
    beams = SZ.ShellFrameBeam[]
    for y in ys, i in 1:(length(xs) - 1)
        push!(beams, SZ.ShellFrameBeam([(xs[i], y), (xs[i + 1], y)], steel;
                                       id = Symbol("x$(i)_$(y)"), release = :freefree))
    end
    for x in xs, j in 1:(length(ys) - 1)
        push!(beams, SZ.ShellFrameBeam([(x, ys[j]), (x, ys[j + 1])], steel;
                                       id = Symbol("y$(j)_$(x)"), release = :freefree))
    end
    return vec(panels), beams
end

flat_count(shells) = count(shells) do sh
    p = [(ustrip(u"m", n.position[1]), ustrip(u"m", n.position[2])) for n in sh.nodes]
    abs((p[2][1] - p[1][1]) * (p[3][2] - p[1][2]) - (p[2][2] - p[1][2]) * (p[3][1] - p[1][1])) < 1e-8
end

"""The mesh as story_shell built it before boundary line points became vertices."""
function former_mesh(panels, beams)
    outer, interior, holes = SZ._story_plate(panels, beams)
    lines = Vector{NTuple{2, Float64}}[]
    append!(lines, interior)
    for b in beams
        push!(lines, SZ._sample_polyline([SZ._story_quantize(p) for p in b.xy], 0.5))
    end
    corners = Tuple(Asap.Node([p[1] * u"m", p[2] * u"m", 0.0u"m"], :free) for p in outer)
    return Asap.Shell(corners, panels[1].section; holes = holes,
                      interior_constrained_lines = lines, edge_support_type = :free,
                      target_edge_length = 0.5u"m", id = :story)
end

for (xs, ys) in (([0.0, 5.49, 10.97, 16.46], [0.0, 4.27, 8.54, 12.81]),
                 ([0.0, 6.1, 12.2, 18.3], [0.0, 4.57, 9.14, 13.71]),
                 ([0.0, 7.3, 14.6, 21.9], [0.0, 5.33, 10.67, 16.0]))
    panels, beams = bay_story(xs, ys)
    old = flat_count(former_mesh(panels, beams))
    new = flat_count(SZ.story_shell(panels, beams; target_edge = 0.5u"m").shells)
    println("bays x=$(xs) y=$(ys): zero-area triangles former=$old  now=$new")
end
