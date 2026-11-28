# One 2×2 bay, one-story office through size_beams_with_story_shell!.
#
#   julia --project=StructuralSynthesizer scripts/runners/story_shell_multibay.jl steel
#   julia --project=StructuralSynthesizer scripts/runners/story_shell_multibay.jl concrete
#
# The story is the roof, so each column stands on a fixed base and there is
# no column above. Reports shell sagging and hogging, and, for composite
# steel, how far the frame model's sagging regions sit from the shell's.

ENV["SS_ENABLE_VISUALIZATION"] = "false"
ENV["SS_SKIP_SOLVER_WARMUP"] = "true"

using Printf
using Asap
using Unitful
using StructuralSynthesizer
using StructuralSizer

const kind = length(ARGS) == 1 ? ARGS[1] : error("pass steel or concrete")
kind in ("steel", "concrete") || error("pass steel or concrete, got $kind")

skel = gen_medium_office(40.0u"ft", 40.0u"ft", 12.0u"ft", 2, 2, 1)
struc = BuildingStructure(skel)
initialize!(struc; floor_type = :one_way, floor_opts = OneWayOptions(),
            loads = GravityLoads(floor_LL = 50.0u"psf", floor_SDL = 15.0u"psf",
                                 roof_LL = 30.0u"psf", roof_SDL = 15.0u"psf"))

if kind == "steel"
    for col in struc.columns
        set_section!(col, W("W14X90"))
    end
    params = DesignParameters(beams = SteelBeamOptions())
    opts = SteelBeamOptions(;
        composite = true,
        composite_anchor_d = 0.75u"inch",
        composite_anchor_length = 5.0u"inch",
        composite_anchor_Fu = 65.0u"ksi",
        custom_catalog = [W("W16X26"), W("W18X35"), W("W21X44"), W("W27X84")],
        deflection_limit = nothing,
        total_deflection_limit = nothing,
    )
    extra = (composite_concrete = NWC_4000, composite_t_slab = 8.0u"inch", reanalyze = false)
else
    colsec = RCColumnSection(; b = 18u"inch", h = 18u"inch", bar_size = 8, n_bars = 8)
    for col in struc.columns
        set_section!(col, colsec)
    end
    params = DesignParameters(beams = ConcreteBeamOptions())
    opts = ConcreteBeamOptions(;
        custom_catalog = [RCBeamSection(; b = 12u"inch", h = h * u"inch",
                                        bar_size = 8, n_bars = 4)
                          for h in (16, 20, 24, 28, 36)],
        deflection_limit = nothing,
    )
    extra = (reanalyze = false,)
end

to_asap!(struc; params = params, diaphragms = :none)
levels = StructuralSynthesizer._story_shell_levels(struc)
println("kind=$kind  beams=$(length(struc.beams))  columns=$(length(struc.columns))  levels=$levels")

out = size_beams_with_story_shell!(struc, opts; levels = levels, max_passes = 3,
                                  shell_kwargs = (target_edge = 1.0u"m",), extra...)

println("converged=$(out.converged)  passes=$(out.passes)  service_converged=$(out.service_converged)")
println("region_mismatch=$(out.region_mismatch)")

shell = analyze_story_shell(struc, first(levels); target_edge = 1.0u"m", service = false,
                            steel = kind == "steel" ? A992_Steel : nothing)
println("springs=$(length(shell.model.springs))")
if !isempty(shell.model.springs)
    krx = [s.stiffness[4] for s in shell.model.springs]
    println("krx N·m/rad  min=$(minimum(krx))  max=$(maximum(krx))")
end

function _ratio(d)
    d.Mu_pos <= 0 && return NaN
    return d.Mu_neg / d.Mu_pos
end
ratios = [_ratio(d) for d in values(out.demands)]
println("beams in the shell demand=$(length(out.demands))")
println("Mu_neg/Mu_pos  min=$(minimum(ratios))  median=$(sort(ratios)[cld(end, 2)])  max=$(maximum(ratios))")
for (i, d) in sort(collect(out.demands); by = first)
    sec = section(struc.beams[i])
    name = hasproperty(sec, :name) && sec.name !== nothing ? sec.name :
           (sec isa RCBeamSection ? "RC $(sec.b)×$(sec.h)" : string(typeof(sec)))
    @printf("  beam %2d  %-16s  Mu+=%8.1f kN·m  Mu-=%8.1f kN·m  ratio=%.3f\n",
            i, name, d.Mu_pos / 1e3, d.Mu_neg / 1e3, _ratio(d))
end
