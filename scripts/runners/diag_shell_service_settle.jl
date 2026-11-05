# Why does the cracked service shell not settle on the 2×2 steel floor?
#
#   julia --project=StructuralSynthesizer scripts/runners/diag_shell_service_settle.jl
#
# Same floor and sections as diag_shell_steel_hogging.jl. Records every
# convergence test of `story_cracked_service` and reports which plate scale
# factors keep moving.

ENV["SS_ENABLE_VISUALIZATION"] = "false"
ENV["SS_SKIP_SOLVER_WARMUP"] = "true"

using Printf
using Asap
using Unitful
using StructuralSynthesizer
using StructuralSizer
const SY = StructuralSynthesizer

const HISTORY = Tuple{Vector{Float64}, Vector{Float64}}[]
@eval SY function _scales_settled(a, b, tol)
    push!(Main.HISTORY, (copy(a), copy(b)))
    length(a) == length(b) || return false
    return maximum(abs.(a .- b); init = 0.0) <= tol
end

skel = gen_medium_office(40.0u"ft", 40.0u"ft", 12.0u"ft", 2, 2, 1)
struc = BuildingStructure(skel)
initialize!(struc; floor_type = :one_way, floor_opts = OneWayOptions(),
            loads = GravityLoads(floor_LL = 50.0u"psf", floor_SDL = 15.0u"psf",
                                 roof_LL = 30.0u"psf", roof_SDL = 15.0u"psf"))
for col in struc.columns
    set_section!(col, W("W14X90"))
end
to_asap!(struc; params = DesignParameters(beams = SteelBeamOptions()), diaphragms = :none)
for i in 13:24
    set_section!(struc.beams[i], i in 19:24 ? W("W27X84") : W("W16X26"))
end

level = only(SY._story_shell_levels(struc))
res = analyze_story_shell(struc, level; target_edge = 1.0u"m", service = true,
                          steel = A992_Steel)
println("service_converged=", res.service_converged, "  tests recorded=", length(HISTORY))

shells = res.model.shell_elements
centroid(k) = Tuple(sum(ustrip(u"m", n.position[j]) for n in shells[k].nodes) / 3 for j in 1:2)
nshell = length(shells)
println("plates=", nshell, "  frames=", length(res.model.frame_elements))

for (t, (a, b)) in enumerate(HISTORY)
    kind = length(a) == nshell ? "shell" : "frame"
    d = abs.(a .- b)
    moving = findall(>(0.02), d)
    k = argmax(d)
    @printf("test %2d %-5s  softened=%4d  max|Δk|=%.3f at %d (%.2f,%.2f) %.3f→%.3f  moving=%d\n",
            t, kind, count(<(1.0), b), d[k], k, (kind == "shell" ? centroid(k) : (NaN, NaN))...,
            a[k], b[k], length(moving))
end

# Plates still moving on the last test of each level: are they flipping?
for (t, (a, b)) in enumerate(HISTORY)
    length(a) == nshell || continue
    (t == length(HISTORY) || length(HISTORY[t + 1][1]) != nshell ||
     HISTORY[t + 1][1] == ones(nshell)) || continue
    moving = findall(>(0.02), abs.(a .- b))
    isempty(moving) && continue
    println("\nlevel ending at test $t: $(length(moving)) plates still moving")
    for k in moving[1:min(end, 12)]
        traj = Float64[]
        s = t
        while s >= 1 && length(HISTORY[s][1]) == nshell
            pushfirst!(traj, HISTORY[s][2][k])
            HISTORY[s][1] == ones(nshell) && break
            s -= 1
        end
        @printf("  plate %4d at (%.2f,%.2f): k per iteration %s\n",
                k, centroid(k)..., string(round.(traj; digits = 3)))
    end
end
