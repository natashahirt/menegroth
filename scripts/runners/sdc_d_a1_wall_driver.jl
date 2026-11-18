#=
Design the D / A1 sensitivity office, write its scene, and print what holds
the walls at their thickness: the largest ratio of every wall check, the
drift ratio, and each §18.10.6.4 boundary decision.

    SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
        julia --project=StructuralSynthesizer scripts/runners/sdc_d_a1_wall_driver.jl
=#

include(joinpath(@__DIR__, "sdc_design_sensitivity.jl"))

const SCENE = joinpath(@__DIR__, "..", "..", "viewer", "public", "sdc-d-a1.mgscene")

function wall_driver()
    n = 5
    struc, conc = office(; n=n, bay=9.0u"m", story=4.0u"m", fc=4000.0u"psi")
    design = design_building(struc, design_params("D / A1", conc, n, :D, :A1,
                                                  1.0, 0.60, 0.40, 80.0u"psf"))
    export_scene(SCENE, design)
    println("wrote ", abspath(SCENE))

    println("---- walls ----")
    for (i, w) in enumerate(design.structure.walls)
        @printf("wall %2d  t %.1f in  ρl %.4f  ρt %.4f\n", i, inch(w.thickness), w.ρl, w.ρt)
    end

    println("---- largest ratio per check ----")
    worst = Dict{String, Any}()
    for r in Iterators.flatten(values(design.walls))
        best = get(worst, r.check, nothing)
        (best === nothing || r.ratio > best.ratio) && (worst[r.check] = r)
    end
    for r in sort(collect(values(worst)); by=r -> -r.ratio)
        @printf("%6.3f  %-50s wall %2d story %d  %s  %s\n", r.ratio, r.check,
                r.wall_index, r.story, r.combination, r.clause)
    end

    drifts = [d.drift_m / d.allowable_m for d in design.seismic_story_drift if d.allowable_m > 0]
    @printf("drift ratio max %.3f\n", isempty(drifts) ? 0.0 : maximum(drifts))

    println("---- §18.10.6.4 boundary decisions ----")
    result = design.structure.ordinary_wall_result
    if result !== nothing
        for i in sort(collect(keys(result.boundary)))
            d = result.boundary[i]
            mm(x) = x === nothing ? "-" : @sprintf("%.1f in", ustrip(u"inch", x * u"m"))
            println("wall $i  required $(d.required) by $(d.required_by)  route $(d.route)",
                    "  c $(mm(d.c_m))  min t $(mm(d.minimum_thickness_m))",
                    "  shortfall $(mm(d.thickness_shortfall_m))  hu $(mm(d.hu_m))")
        end
    end
end

wall_driver()
