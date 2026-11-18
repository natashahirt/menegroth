# A one-story, one-bay office designed twice, at two roof live loads.
# The solved model has to balance, and the heavier live load has to show up
# as a heavier building: larger factored reactions, and no thinner slab or
# lighter beams.

using Test
using Unitful
using LinearAlgebra
using StructuralSynthesizer
using StructuralSizer

const Asap = StructuralSynthesizer.Asap

function _design_one_bay(ll)
    skel = gen_medium_office(20.0u"ft", 20.0u"ft", 12.0u"ft", 1, 1, 1)
    design_building(BuildingStructure(skel), DesignParameters(
        name = "equilibrium",
        materials = MaterialOptions(concrete = NWC_4000),
        floor = OneWayOptions(),
        loads = GravityLoads(
            floor_LL = ll, roof_LL = ll,
            floor_SDL = 15.0u"psf", roof_SDL = 15.0u"psf"),
        skip_visualization = true,
        max_iterations = 3,
    ))
end

"""Vertical reactions, support demands, and the sizes a design actually installed."""
function _gravity_account(design)
    struc = design.structure
    model = struc.asap_model
    Asap.solve!(model)

    residual = model.S * model.u - model.P + model.Pf
    residual[model.fixedDOFs] .= 0
    scale = max(1.0, maximum(abs, model.P) + maximum(abs, model.Pf))

    Asap.post_process!(model)
    Asap.reactions!(model)
    initialize_supports!(struc)
    demands = support_demands(struc)

    fixed = 0.0u"kN"
    for n in model.nodes
        length(n.dof) >= 3 && n.dof[3] == false || continue
        fixed += uconvert(u"kN", n.reaction[3])
    end
    depths = [StructuralSizer.total_depth(s.result) for s in struc.slabs]
    areas = [b.base.section.A for b in struc.beams if b.base.section !== nothing]
    return (;
        residual = maximum(abs, residual) / scale,
        fixed,
        pu = sum(d.Pu for d in demands),
        ps = sum(d.Ps for d in demands),
        column_pu = [d.Pu for d in demands],
        depth = isempty(depths) ? nothing : maximum(depths),
        steel = isempty(areas) ? nothing : sum(areas),
    )
end

@testset "design_building gravity equilibrium and live-load sensitivity" begin
    light = _gravity_account(_design_one_bay(20.0u"psf"))
    heavy = _gravity_account(_design_one_bay(80.0u"psf"))

    for acct in (light, heavy)
        @test acct.residual < 1e-6
        @test acct.fixed > 1.0u"kN"
        @test acct.pu ≈ acct.fixed rtol = 1e-4
        # 1.2D + 1.6L exceeds service D + L once live load is present.
        @test acct.pu > acct.ps > 0.0u"kN"
        # A square bay on four columns shares the gravity. One column taking
        # several times the lightest is a surprise, not a design result.
        pus = ustrip.(u"kN", acct.column_pu)
        @test length(pus) == 4
        @test minimum(pus) > 0
        @test maximum(pus) / minimum(pus) < 1.5
    end

    @test heavy.pu > light.pu
    @test heavy.ps > light.ps
    @test heavy.depth >= light.depth
    @test heavy.steel >= light.steel
end
