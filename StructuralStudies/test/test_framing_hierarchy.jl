# Support rank of the 2024 framing plans.
#
# These are the drawn beam lines, before filler joists are generated. A line
# with two column, wall, or support vertices is level 0 and is not cut. A
# longer line is cut where a shorter line that already reaches supports
# crosses it, so the beams of one straight run can carry more than one level.
#
# Wall nodes in the geometry files are not skeleton supports. This test marks
# the floor vertex at each wall node so the rank matches the support rule.

using Test
using Unitful
import Meshes

include(joinpath(@__DIR__, "..", "src", "slab_design_factors", "study.jl"))

const HIERARCHY_PLANS = [
    "grid/x1y1",
    "topology/r2c1",
    "star/e0c0",
    "star/e10c2",
    "nova/e3c4",
    "special/rhombus_8x12",
    "special/star_8x12",
    "special/tan_121_seaport",
    "validation/office",
]

function _floor_vertex(skel, x, y)
    hit = nothing
    best = -Inf
    for (v, p) in enumerate(skel.vertices)
        c = Meshes.coords(p)
        abs(ustrip(u"m", c.x) - x) < 1e-4 || continue
        abs(ustrip(u"m", c.y) - y) < 1e-4 || continue
        z = ustrip(u"m", c.z)
        z > best || continue
        best = z
        hit = v
    end
    return hit
end

"""Put each wall node on `:support` at the floor, and build the members."""
function _ranked(name)
    plan = load_plan(name)
    skel = plan_skeleton(plan)
    supports = get!(skel.groups_vertices, :support, Int[])
    for i in plan.walls
        x, y = plan.xy[i]
        v = _floor_vertex(skel, x, y)
        v === nothing && continue
        v in supports || push!(supports, v)
    end
    struc = BuildingStructure(skel)
    initialize_segments!(struc)
    initialize_members!(struc)
    SS.assign_framing_levels!(struc)
    return struc
end

function _check_plan(struc)
    lines = SS._frame_lines(struc)
    fixed = SS.beam_support_lookup(struc).fixed
    n_seed = 0
    n_cut = 0
    for ln in lines
        levels = [struc.beams[b].level for b in ln.beams]
        for lv in levels
            @test lv >= 0
            @test lv <= length(struc.beams)
        end
        length(unique(levels)) > 1 && (n_cut += 1)
        seeded = count(v -> v in fixed, ln.verts) >= 2
        seeded && (n_seed += 1)
        # A column line is not cut, so every beam on it stays level 0.
        seeded && @test all(==(0), levels)
    end
    counts = Dict{Int, Int}()
    for b in struc.beams
        counts[b.level] = get(counts, b.level, 0) + 1
    end
    return (counts = counts, lines = length(lines), seeds = n_seed, cut = n_cut)
end

@testset "2024 plan framing levels" begin
    if !isdir(SDF_ROOT)
        @test_skip "Slab Design Factors geometries are not beside this repo"
    else
        for name in HIERARCHY_PLANS
            @testset "$name" begin
                info = _check_plan(_ranked(name))
                order = sort!(collect(keys(info.counts)))
                parts = ["L$lv=$(info.counts[lv])" for lv in order]
                println(name, "  ", join(parts, "  "),
                        "  lines ", info.lines,
                        "  seeded ", info.seeds,
                        "  cut ", info.cut)
                @test !isempty(order)
                @test info.seeds > 0
            end
        end
    end
end
