# Phase 6d — ELF story forces on the rigid-diaphragm masters.
#
# The 1×1 office is the Phase 5 fixture. One :walls edge gives the floor a
# wall to tie into the diaphragm. The assertions are on the story forces,
# the torsion moments, and that the reduced solve moves the masters. They
# do not lock a displacement magnitude.

using Test
using Unitful
using Meshes
using Asap
using StructuralSynthesizer
using StructuralSizer

const _ELF_VAULT = VaultOptions(rise=1.0u"m", thickness=0.05u"m")

function _elf_xy(skel, vidx)
    c = Meshes.coords(skel.vertices[vidx])
    return (ustrip(u"m", c.x), ustrip(u"m", c.y))
end

function _elf_horizontal(skel, eidx)
    v1, v2 = skel.edge_indices[eidx]
    c1 = Meshes.coords(skel.vertices[v1])
    c2 = Meshes.coords(skel.vertices[v2])
    return abs(ustrip(u"m", c1.z) - ustrip(u"m", c2.z)) <= 1e-6
end

function _elf_plan_length(skel, eidx)
    v1, v2 = skel.edge_indices[eidx]
    x1, y1 = _elf_xy(skel, v1)
    x2, y2 = _elf_xy(skel, v2)
    return hypot(x2 - x1, y2 - y1)
end

"""1×1 office, two stories, one wall on story 0, rigid diaphragm."""
function _elf_building()
    skel = gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 1, 2)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    edges = [e for e in skel.stories[0].edges if e in beams && _elf_horizontal(skel, e)]
    @assert !isempty(edges)
    eidx = edges[argmax(_elf_plan_length.(Ref(skel), edges))]
    filter!(!=(eidx), skel.groups_edges[:beams])
    walls = get!(skel.groups_edges, :walls, Int[])
    eidx in walls || push!(walls, eidx)

    struc = BuildingStructure(skel)
    initialize!(struc;
        floor_type=:vault,
        material=NWC_4000,
        floor_opts=_ELF_VAULT,
        wall_thickness=0.3u"m")
    params = DesignParameters(materials=MaterialOptions(concrete=NWC_5000))
    to_asap!(struc; params=params, diaphragms=:rigid)
    return struc
end

function _elf_case(result, direction, purpose, torsion)
    hits = [c for c in result.cases
            if c.direction == direction && c.purpose == purpose && c.torsion == torsion]
    @assert length(hits) == 1
    return only(hits)
end

@testset "phase 6d ELF story cases" begin
    bare = BuildingStructure(gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 1, 1))
    @test_throws ArgumentError elf_story_analysis(bare;
        method=:sds, SDS=1.0, S1=0.2, R=8, Ie=1, T=0.4, Cd=4.0, β=1.0,
        SD1=0.3, TL=8)

    struc = _elf_building()
    @test !isempty(struc.asap_rigid_links)
    tied = [link for link in struc.asap_rigid_links if link.release[6] == false]
    @test !isempty(tied)
    @test all(link -> link.nodeA.dof[6] && link.nodeB.dof[6], tied)

    @test_throws ArgumentError elf_story_analysis(struc;
        method=:sds, SDS=0.05, S1=0.02, R=8, Ie=1.0, T=0.4, Cd=4.0, β=1.0, TL=8.0)
    @test_throws ArgumentError elf_story_analysis(struc;
        method=:sa, SDS=0.05, S1=0.02, R=8, Ie=1.0, T=0.4, Cd=4.0, β=1.0)

    # SDS·Ie/R = 0.00625 sits under the Eq. 12.8-6 floor of 0.01, and S1 < 0.6
    # so Eq. 12.8-7 does not apply. Strength keeps the floor. Drift drops it.
    # T = 0.4 s is the k = 1 side of §12.8.3, so `between` is not required.
    result = elf_story_analysis(struc;
        method=:sds, SDS=0.05, S1=0.02, R=8, Ie=1.0, T=0.4, Cd=4.0, β=1.0,
        SD1=0.02, TL=8.0)

    @test length(result.levels) >= 1
    @test length(result.cases) == 12
    @test issorted(result.levels; by=lv -> lv.height_m)
    @test all(lv -> lv.height_m > 0 && lv.weight_kN > 0 && lv.px_kN > 0, result.levels)

    weights = [lv.weight_kN for lv in result.levels]
    heights = [lv.height_m for lv in result.levels]
    strength = _elf_case(result, :x, :strength, :none)
    drift = _elf_case(result, :x, :drift, :none)
    plus = _elf_case(result, :x, :strength, :plus)
    minus = _elf_case(result, :x, :strength, :minus)

    @test strength.k == 1.0
    @test strength.Cs ≈ 0.01
    @test drift.Cs < strength.Cs
    @test drift.Cs ≈ seismic_response_coefficient(;
        method=:sds, SDS=0.05, S1=0.02, R=8, Ie=1.0, SD1=0.02, T=0.4, TL=8.0,
        for_drift=true)
    dist = vertical_distribution(weights, heights, strength.V_kN, strength.k)
    @test strength.Fx_kN ≈ dist.Fx
    @test sum(strength.Fx_kN) ≈ strength.V_kN atol=1e-9
    @test strength.Vx_kN ≈ seismic_story_shear(strength.Fx_kN, heights)
    @test all(==(0.0), strength.Mz_kN_m)

    ecc = [accidental_eccentricity(lv.plan_m[2]) for lv in result.levels]
    @test plus.Mz_kN_m ≈ plus.Fx_kN .* ecc
    @test minus.Mz_kN_m ≈ .- plus.Mz_kN_m
    @test plus.Fx_kN ≈ strength.Fx_kN

    @test all(isfinite, drift.elastic_m)
    @test drift.elastic_m[end] > 0
    @test drift.design_m ≈ (4.0 / 1.0) .* drift.elastic_m
    @test all(isnothing, strength.θ)
    θmax = stability_coefficient_limit(1.0, 4.0)
    for i in eachindex(drift.θ)
        @test drift.θ[i] <= θmax
        @test drift.multiplier[i] ≈ pdelta_displacement_multiplier(drift.θ[i], θmax)
    end

    ydrift = _elf_case(result, :y, :drift, :none)
    @test ydrift.elastic_m[end] > 0

    for c in result.cases
        @test all(a -> a === nothing || a >= 1, c.Ax)
    end

    # Table 12.12-1 on the drift cases only. Risk category and system are
    # required. A tiny allowable fails the same drifts that the real limit passes.
    checks = check_seismic_story_drift(result; risk_category=:II, system=:other)
    @test length(checks) == 2 * 3 * length(result.levels)
    @test all(c -> c.passes, checks)
    @test all(c -> c.allowable_m ≈ 0.020 * 4.0, checks)
    masonry = check_seismic_story_drift(result; risk_category=:II, system=:masonry_other)
    @test all(c -> c.allowable_m ≈ 0.007 * 4.0, masonry)
    @test all(c -> c.passes == (c.drift_m <= c.allowable_m), masonry)
    seismic = factored_seismic_cases(result, strength_1_2D_1_0E)
    @test length(seismic) == 6
    xnone = only(c for c in seismic if result.cases[c.case_index].direction === :x &&
                 result.cases[c.case_index].torsion === :none &&
                 result.cases[c.case_index].purpose === :strength)
    @test xnone.Fx_kN ≈ strength.Fx_kN
    @test all(==(0.0), xnone.Fy_kN)
    @test isempty(factored_seismic_cases(result, strength_1_2D_1_0W))
end
