# One-way concrete joists are also solved with pinned ends, and beam groups are
# sized for the larger of that solve and the frame solve.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer
using Asap

const SS = StructuralSynthesizer
const SR = StructuralSizer

@testset "one-way concrete joists get a pinned-end envelope" begin
    skel = gen_medium_office(40.0u"ft", 30.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    beam_opts = SR.ConcreteBeamOptions(material = SR.NWC_4000, include_flange = true)
    params = DesignParameters(
        floor = SR.OneWayOptions(),
        beams = beam_opts,
        columns = SR.ConcreteColumnOptions(material = SR.NWC_4000),
        skip_visualization = true,
        framing_opts = (; materials = (; beam = SR.NWC_4000), spacing = 32.0u"inch",
                        beam_options = beam_opts),
    )
    prepare!(struc, params)
    any(s -> s.result === nothing, struc.slabs) && size_slabs!(struc, params)
    to_asap!(struc; params = params, diaphragms = :none)

    joists = Int[]
    for slab in struc.slabs, fl in slab.framing_levels
        append!(joists, (mi for mi in SS.level_member_indices(struc, fl)
                         if struc.beams[mi].role === :joist))
    end
    @test !isempty(joists)

    releases = SS._pinned_joist_releases(struc)
    joist_elements = Set(ei for mi in joists for si in SS.segment_indices(struc.beams[mi])
                         for ei in SS._frame_element_indices(struc, struc.segments[si].edge_idx))
    @test !isempty(releases)
    @test Set(keys(releases)) ⊆ joist_elements
    # Both ends of every joist are pinned, on one element or on its first and last.
    @test sum(r -> r === :joist ? 2 : 1, values(releases)) == 2 * length(joists)
    @test all(r -> r in (:joist, :freefixed, :fixedfree), values(releases))

    model = struc.asap_model
    frames_before = copy(model.frame_elements)
    loads_before = copy(model.loads)
    dead_before = struc.cell_dead_loads
    groups_before = struc.member_groups

    fixed = SS._beam_group_demands(struc, nothing; resolution = 41, shell_demands = nothing,
                                   service_deflection = false)
    gids_fixed, d_fixed = SS.member_group_demands(struc;
        member_edge_group = SS.BEAM_GROUP_SYMBOLS, resolution = 41,
        service_deflection = false)[1:2]
    gids_pinned, d_pinned = SS._with_pinned_joists(struc, releases) do
        @test struc.asap_model !== model
        for (ei, rel) in releases
            @test SS._release_symbol(struc.asap_model.frame_elements[ei]) === rel
        end
        SS.member_group_demands(struc; member_edge_group = SS.BEAM_GROUP_SYMBOLS,
                                resolution = 41, service_deflection = false)[1:2]
    end

    # The building is left as it was.
    @test struc.asap_model === model
    @test all(model.frame_elements .=== frames_before)
    @test all(model.loads .=== loads_before)
    @test struc.cell_dead_loads === dead_before
    @test struc.member_groups === groups_before

    @test gids_pinned == gids_fixed == fixed[1]
    joist_groups = Set(SS.group_id(struc.beams[mi]) for mi in joists)
    for (k, gid) in enumerate(gids_fixed)
        a, b, env = d_fixed[k], d_pinned[k], fixed[2][k]
        for f in (:Mux_pos, :Mux_neg, :Vu_strong, :Pu_c, :Pu_t)
            @test getfield(env, f) == max(getfield(a, f), getfield(b, f))
        end
        gid in joist_groups || continue
        # A pinned joist carries no end moment. Each joist is one span, so its
        # largest sagging moment is at least what the fixed-end joist had.
        @test b.Mux_neg <= 1e-6 * b.Mux_pos
        @test b.Mux_pos >= a.Mux_pos
    end
end
