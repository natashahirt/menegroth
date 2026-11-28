# RC joist ribs as T-beams: centered rib layout, the edge-rib group, and the
# ACI 318-11 §8.12 flange from the geometry (clear distance to the next web,
# measured from web faces). Corpus: aci-318-11, PDF page 119.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

const SS = StructuralSynthesizer
const SR = StructuralSizer

@testset "Joist T-beam flange geometry" begin
    # 2×2 bays of 20 ft × 15 ft. Ribs at 32 in do not divide the 15 ft bay:
    # n = ceil(W/32) − 1 = 5 ribs and end gaps (W − 4·32)/2 ≈ 26 in.
    # `gen_medium_office` rounds each bay to 0.01 m, so W is 4.57 m, not 180 in.
    skel = gen_medium_office(40.0u"ft", 30.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    spacing = 32.0u"inch"
    W_in = ustrip(u"inch", round(ustrip(u"m", 30.0u"ft") / 2; digits = 2) * u"m")
    end_gap = (W_in - 4 * 32) / 2
    params = DesignParameters(
        floor = SR.OneWayOptions(),
        beams = SR.ConcreteBeamOptions(material = SR.NWC_4000, include_flange = true),
        columns = SR.ConcreteColumnOptions(material = SR.NWC_4000),
        skip_visualization = true,
        framing_opts = (; materials = (; beam = SR.NWC_4000), spacing = spacing,
                        beam_options = SR.ConcreteBeamOptions(material = SR.NWC_4000,
                                                              include_flange = true)),
    )
    prepare!(struc, params)
    any(s -> s.result === nothing, struc.slabs) && size_slabs!(struc, params)

    levels = [(slab, fl) for slab in struc.slabs for fl in slab.framing_levels
              if fl.group_id !== nothing]
    @test !isempty(levels)
    SS.build_member_groups!(struc; member_type = :beams)
    chords = [SS._beam_chord(struc, b) for b in struc.beams]
    s_m = ustrip(u"m", spacing)

    for (slab, fl) in levels
        interior = struc.member_groups[fl.group_id].member_indices
        @test fl.edge_group_id !== nothing
        edge = struc.member_groups[fl.edge_group_id].member_indices
        @test length(edge) == 2
        @test length(interior) == 3
        @test Set(SS.level_member_indices(struc, fl)) == Set(vcat(interior, edge))

        # Centered layout: both edge ribs sit one end gap from the girder they face.
        for mi in edge
            lw, rw = SS._nearest_parallel_webs(chords, mi)
            webs = [w for w in (lw, rw) if w !== nothing]
            @test length(webs) == 2
            gaps = sort([w.dist_m for w in webs])
            @test gaps[1] ≈ ustrip(u"m", end_gap * u"inch") atol = 1e-6
            @test gaps[2] ≈ s_m atol = 1e-6
            girder = argmin(w -> w.dist_m, webs).neighbor
            @test SS.level_of(struc.beams[girder]) == 0
        end
        for mi in interior
            lw, rw = SS._nearest_parallel_webs(chords, mi)
            @test lw.dist_m ≈ s_m atol = 1e-6
            @test rw.dist_m ≈ s_m atol = 1e-6
        end
    end

    slab, fl = first(levels)
    hf = SR.total_depth(slab.result)
    specs = SS._compute_flange_params(struc, [fl.group_id, fl.edge_group_id])
    int_spec, edge_spec = specs
    @test int_spec.joist_spacing ≈ spacing
    @test int_spec.hf ≈ hf
    @test all(mf -> mf.one_side === nothing, int_spec.members)

    # Interior group, bw = 5 in, ribs at most 8 in (§8.13 rib catalog).
    #   middle rib: both neighbors in the batch, (32 − 5)/2 = 13.5 per side.
    #   rib next to an edge rib: (32 − 2.5 − 4)/2 = 12.75 on that side.
    # 8hf and ln/8 exceed both, so the narrowest is 5 + 13.5 + 12.75 = 31.25 in.
    bw = 5.0u"inch"
    @test 8 * hf > 13.5u"inch"
    batch = Set([fl.group_id])
    bf_int = SS._group_flange_width(struc, int_spec, bw; batch,
                                    rib_web_max = SR.MAX_JOIST_RIB_WIDTH)
    @test bf_int ≈ 31.25u"inch" atol = 1e-6u"inch"

    # Edge group: the girder is sized later, so it is taken as the widest
    # built-in web (30 in): (gap − 2.5 − 15)/2 ≈ 4.25 in on the girder side,
    # 12.75 in toward the interior rib, bf ≈ 22.0 in.
    bf_edge = SS._group_flange_width(struc, edge_spec, bw; batch = Set([fl.edge_group_id]),
                                     rib_web_max = SR.MAX_JOIST_RIB_WIDTH)
    @test bf_edge ≈ (5 + 12.75 + (end_gap - 2.5 - 15) / 2) * u"inch" atol = 1e-6u"inch"

    # The flange never decreases with the web (the NLP path relies on it).
    widths = [SS._group_flange_width(struc, int_spec, w * u"inch"; batch,
                                     rib_web_max = SR.MAX_JOIST_RIB_WIDTH) for w in 4:8]
    @test issorted(widths)

    # Girder parallel to the ribs: its overhang toward the bay stops at one-half
    # the clear distance to the first rib, not at the bay's mid-line.
    home = SS._framing_home(struc)
    rib = first(struc.member_groups[fl.edge_group_id].member_indices)
    lw, rw = SS._nearest_parallel_webs(chords, rib)
    girder = argmin(w -> w.dist_m, [w for w in (lw, rw) if w !== nothing]).neighbor
    @test !haskey(home, girder)
    gmf = SS._girder_member_flange(struc, girder, chords; field = false)
    @test gmf !== nothing
    toward_ribs = [w for w in (gmf.left_web, gmf.right_web)
                   if w !== nothing && haskey(home, w.neighbor)]
    @test length(toward_ribs) >= 1
    @test minimum(w -> w.dist_m, toward_ribs) ≈ ustrip(u"m", end_gap * u"inch") atol = 1e-6

    # `build_member_groups!` for columns empties this dict. The joists stay
    # findable from the group id stored on each beam.
    empty!(struc.member_groups)
    for (_, fl) in levels
        @test length(SS.level_member_indices(struc, fl)) == 5
    end
end
