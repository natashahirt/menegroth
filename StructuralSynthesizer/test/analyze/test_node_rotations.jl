# Frame-node rotations are free wherever an element restrains them, and beam
# end releases follow the beam sizing material.

using Test
using Unitful
using Asap
using StructuralSynthesizer
using StructuralSizer
const SS = StructuralSynthesizer

const _SEC = Asap.Section(4.18e-3u"m^2", 200e9u"Pa", 77e9u"Pa",
                          89.8e-6u"m^4", 11.4e-6u"m^4", 0.5e-6u"m^4", 7850.0u"kg/m^3")

_free_node(x, y, z) = Asap.Node([x, y, z] .* u"m", [true, true, true, false, false, false])

function _office(params)
    skel = gen_medium_office(40.0u"ft", 40.0u"ft", 12.0u"ft", 2, 2, 2)
    struc = BuildingStructure(skel)
    opts = FlatPlateOptions(material=RC_4000_60, method=DDM(), cover=0.75u"inch", bar_size=5)
    initialize!(struc; floor_type=:flat_plate, floor_opts=opts)
    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", 20.0u"psf")
        cell.live_load = uconvert(u"kN/m^2", 50.0u"psf")
    end
    to_asap!(struc; params=params)
    return struc
end

_edges(struc, members) = [struc.segments[si].edge_idx for m in members for si in SS.segment_indices(m)]
_max_end_moment(model, edges) =
    maximum(e -> maximum(abs, model.frame_elements[e].forces[[5, 6, 11, 12]]), edges)

@testset "frame node rotations" begin
    @testset "release material follows the beam sizing options" begin
        @test SS.beam_sizing_material(DesignParameters()) === A992_Steel
        @test SS.beam_sizing_material(DesignParameters(beams=ConcreteBeamOptions())) isa StructuralSizer.Concrete
        @test SS.beam_sizing_material(DesignParameters(beams=PixelFrameBeamOptions())) === nothing
        @test !hasfield(MaterialOptions, :beam)
    end

    @testset "a rotation only released ends meet stays fixed" begin
        a = Asap.Node([0.0, 0.0, 0.0] .* u"m", :fixed)
        b = _free_node(0.0, 0.0, 3.0)
        c = _free_node(4.0, 0.0, 3.0)
        col = Asap.Element(a, b, _SEC; release=:fixedfixed)
        beam = Asap.Element(b, c, _SEC; release=:freefree)
        SS._free_restrained_node_rotations!([a, b, c], [col, beam], Asap.ShellElement[])
        @test all(b.dof[4:6])
        @test !any(c.dof[4:6])
        @test !any(a.dof)
    end

    @testset "a member fixed at one end frees only the axes it restrains" begin
        a = Asap.Node([0.0, 0.0, 0.0] .* u"m", :fixed)
        d = _free_node(4.0, 0.0, 0.0)
        el = Asap.Element(d, a, _SEC; release=:fixedfree)
        SS._free_restrained_node_rotations!([a, d], [el], Asap.ShellElement[])
        @test d.dof[4:6] == [false, true, true]   # no torsion about the member axis

        e = _free_node(3.0, 3.0, 0.0)
        skew = Asap.Element(e, a, _SEC; release=:fixedfree)
        @test_throws ArgumentError SS._free_restrained_node_rotations!([a, e], [skew], Asap.ShellElement[])
    end

    @testset "fixed beam ends send moment into the columns" begin
        steel = _office(DesignParameters())
        conc = _office(DesignParameters(beams=ConcreteBeamOptions()))
        beam_edges = _edges(steel, steel.beams)
        col_edges = _edges(steel, steel.columns)

        @test all(e -> SS._get_release_symbol(steel.asap_model.frame_elements[e]) === :freefree, beam_edges)
        @test all(e -> SS._get_release_symbol(conc.asap_model.frame_elements[e]) === :fixedfixed, beam_edges)
        top = [nd for nd in conc.asap_model.nodes if nd.dof[1] && nd.dof[2] && nd.dof[3]]
        @test all(nd -> all(nd.dof[4:6]), top)

        @test _max_end_moment(conc.asap_model, col_edges) > 1e3          # N·m
        @test _max_end_moment(steel.asap_model, beam_edges) < 1e-6
    end
end
