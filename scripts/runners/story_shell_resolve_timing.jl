# Time one story-shell pass: a fresh mesh and solve (`analyze_story_shell`)
# against a re-solve of a kept mesh (`solve_story_shell!`).
#
#   julia --project=StructuralSynthesizer scripts/runners/story_shell_resolve_timing.jl

ENV["SS_ENABLE_VISUALIZATION"] = "false"
ENV["SS_SKIP_SOLVER_WARMUP"] = "true"

using Printf
using Unitful
using StructuralSynthesizer
using StructuralSizer

skel = gen_medium_office(40.0u"ft", 40.0u"ft", 12.0u"ft", 3, 3, 2)
struc = BuildingStructure(skel)
initialize!(struc; floor_type = :one_way, floor_opts = OneWayOptions())
colsec = RCColumnSection(; b = 18u"inch", h = 18u"inch", bar_size = 8, n_bars = 8)
beamsec = RCBeamSection(; b = 12u"inch", h = 24u"inch", bar_size = 8, n_bars = 4)
foreach(c -> set_section!(c, colsec), struc.columns)
foreach(b -> set_section!(b, beamsec), struc.beams)
to_asap!(struc; params = DesignParameters(beams = ConcreteBeamOptions()), diaphragms = :none)

level = first(StructuralSynthesizer._story_shell_levels(struc))
kw = (target_edge = 0.5u"m",)
best(f) = (f(); minimum(@elapsed(f()) for _ in 1:3))

shell = build_story_shell(struc, level; kw...)
res = solve_story_shell!(shell, struc; service = false)
println("level=$level  plates=$(length(res.model.shell_elements))  " *
        "beam pieces=$(length(res.model.frame_elements))  panels=$(length(res.shell_reinforcement))")
for service in (false, true)
    fresh = best(() -> analyze_story_shell(struc, level; kw..., service = service))
    kept = best(() -> solve_story_shell!(shell, struc; service = service))
    @printf("service=%-5s  fresh mesh %.3f s   kept mesh %.3f s   %.1f×\n",
            service, fresh, kept, fresh / kept)
end
