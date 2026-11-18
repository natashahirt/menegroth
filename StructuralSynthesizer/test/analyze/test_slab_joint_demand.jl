# The shear and moment a slab's members deliver to a column joint, read from
# a solved frame.
#
# A small frame: one fixed-base column, two loaded beams meeting at its top,
# and a loaded girder. The end actions at the top joint sum to zero. All the
# horizontal members together deliver the column's compression and its top
# end moment. Without the girder, the beams deliver the column's share less
# the girder's.

using Test
using Unitful
using Asap
using StructuralSynthesizer
using StructuralSizer

const SY = StructuralSynthesizer
const SS = StructuralSizer

@testset "slab demand at a column joint from the solved frame" begin
    ρ = 0.0u"kg/m^3"
    sec = SS.solid_head_section(0.3u"m", 0.5u"m", NWC_4000; density = ρ)
    top = Asap.Node([0.0u"m", 0.0u"m", 0.0u"m"], fill(true, 6))
    base = Asap.Node([0.0u"m", 0.0u"m", -3.0u"m"], fill(false, 6))
    east = Asap.Node([5.0u"m", 0.0u"m", 0.0u"m"], [false, false, false, true, true, true])
    north = Asap.Node([0.0u"m", 4.0u"m", 0.0u"m"], [false, false, false, true, true, true])
    west = Asap.Node([-6.0u"m", 0.0u"m", 0.0u"m"], [false, false, false, true, true, true])
    col = Asap.Element(base, top, sec, :column)
    rib_e = Asap.Element(top, east, sec, :rib)
    rib_n = Asap.Element(north, top, sec, :rib)
    girder = Asap.Element(top, west, sec, :girder)
    loads = Asap.AbstractLoad[
        Asap.TributaryLoad(rib_e, [0.0, 1.0], [1.0u"m", 1.0u"m"], 9_000.0u"Pa", (0.0, 0.0, -1.0)),
        Asap.TributaryLoad(rib_n, [0.0, 0.4, 1.0], [0.5u"m", 1.5u"m", 1.0u"m"], 7_000.0u"Pa",
                           (0.0, 0.0, -1.0)),
        Asap.TributaryLoad(girder, [0.0, 1.0], [2.0u"m", 2.0u"m"], 12_000.0u"Pa", (0.0, 0.0, -1.0)),
    ]
    model = Asap.Model([top, base, east, north, west], [col, rib_e, rib_n, girder], loads)
    Asap.solve!(model)
    load_map = Asap.get_elemental_loads(model)
    u = model.u
    ks(els) = [findfirst(e -> e === el, model.frame_elements) for el in els]
    k_col, k_e, k_n, k_g = ks([col, rib_e, rib_n, girder])

    # Every member's end actions at the free top joint balance.
    total = zeros(6)
    for (k, at_start) in ((k_col, false), (k_e, true), (k_n, false), (k_g, true))
        el = model.frame_elements[k]
        Fe = SY._element_end_actions(el, u, SY._case_loads(load_map, el))
        total .+= at_start ? Fe[1:6] : Fe[7:12]
    end
    @test maximum(abs, total) < 1e-6 * maximum(abs, SY._element_end_actions(col, u, Asap.AbstractLoad[]))

    # All horizontal members deliver what the column carries.
    Vu_all, M_all = SY._slab_joint_demand(model, [(k_e, true), (k_n, false), (k_g, true)], u, load_map)
    f = SY._element_forces_from_u(col, u, Asap.AbstractLoad[]; resolution = 3)
    Fe_col = col.K * u[col.globalID]
    @test Vu_all ≈ -f.P[end] rtol = 1e-8
    @test Vu_all > 0
    @test M_all[1] ≈ Fe_col[10] rtol = 1e-8 atol = 1e-6
    @test M_all[2] ≈ Fe_col[11] rtol = 1e-8 atol = 1e-6

    # The two ribs deliver the column's share less the girder's.
    Vu_ribs, _ = SY._slab_joint_demand(model, [(k_e, true), (k_n, false)], u, load_map)
    Vu_g, _ = SY._slab_joint_demand(model, [(k_g, true)], u, load_map)
    @test Vu_ribs + Vu_g ≈ Vu_all rtol = 1e-10
    @test 0 < Vu_ribs < Vu_all
end
