# Phase 6 smoke test — MemberGroup.catalog_override + selector `catalog` kwarg
# + size_member_group! routing seam.
#
# Exercises the catalog-override plumbing added in Phase 6 of the
# joists-roles-materials plan:
#   1. MemberGroup carries a `catalog_override` field (back-compat constructors).
#   2. The StructuralSizer steel selector honours an explicit `catalog` kwarg.
#   3. size_member_group! routes a group's `catalog_override` to the selector:
#      `nothing` → material default catalog; non-nothing → the override wins.
#   4. FramingLevel.catalog_override (Phase 4) can hold a non-nothing value.
#
# Run:
#   SS_ENABLE_VISUALIZATION=false SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD=false \
#   julia --project=StructuralSynthesizer scripts/runners/run_phase6_catalog_smoke.jl

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer
using Asap  # units + model

# Build + analyse a simply-supported 20 ft steel beam under a factored line load,
# mirroring the integration-test setup. Returns the solved BuildingStructure and
# the sole beam edge id.
function _build_beam_struc()
    L_m = ustrip(u"m", 20.0u"ft")

    skel = BuildingSkeleton{Float64}()
    id1 = add_vertex!(skel, [0.0, 0.0, 0.0])
    id2 = add_vertex!(skel, [L_m, 0.0, 0.0])
    e1  = add_element!(skel, id1, id2)
    skel.groups_edges[:beams] = [e1]
    skel.groups_vertices[:support] = [id1, id2]
    rebuild_geometry_cache!(skel)

    struc = BuildingStructure(skel)
    initialize_segments!(struc)
    # Continuous bracing → Lb ≈ 0 (full plastic capacity, LTB not governing).
    for seg in struc.segments
        seg.Lb = zero(seg.L)
    end
    initialize_members!(struc)

    to_asap!(struc)
    model = struc.asap_model
    model.nodes[id1].dof = [false, false, false, false, false, false]
    model.nodes[id2].dof = [true,  true,  false, true,  true,  true]

    w_si = uconvert(u"N/m", 2.8u"kip/ft")
    push!(model.loads, Asap.LineLoad(model.elements[e1], [0.0u"N/m", 0.0u"N/m", -w_si]))
    Asap.process!(model)
    Asap.solve!(model)
    return struc, e1
end

@testset "Phase 6 — catalog override" begin

    # A restricted 2-section catalog: both W-shapes are much heavier than the
    # unconstrained optimum for this beam, so a section drawn from it proves the
    # override was honoured (the free optimum is a lighter shape not in the set).
    custom2 = [W("W21X44"), W("W24X68")]
    custom_names = Set(s.name for s in custom2)

    @testset "MemberGroup.catalog_override field + constructors" begin
        gid = UInt64(42)

        # 1-arg convenience: default override is nothing.
        g0 = MemberGroup(gid)
        @test g0.catalog_override === nothing
        @test g0.member_indices == Int[]
        @test g0.section === nothing

        # kwarg form: carries a non-nothing override.
        g1 = MemberGroup(gid; catalog_override = custom2)
        @test g1.catalog_override === custom2

        # 3-arg back-compat positional constructor still works (override → nothing).
        g2 = MemberGroup(gid, Int[1, 2], nothing)
        @test g2.catalog_override === nothing
        @test g2.member_indices == [1, 2]

        # Mutable: settable after construction (how Phase 5 will wire it).
        g0.catalog_override = custom2
        @test g0.catalog_override === custom2
    end

    @testset "Selector honours explicit `catalog` kwarg (StructuralSizer.size_beams)" begin
        Mu = [140.0u"kip*ft"]
        Vu = [28.0u"kip"]
        geoms = [StructuralSizer.SteelMemberGeometry(ustrip(u"m", 20.0u"ft"); Lb=0.0, Cb=1.0)]

        # Default (no override): free optimum is lighter than anything in custom2.
        res_def = StructuralSizer.size_beams(Mu, Vu, geoms, StructuralSizer.SteelBeamOptions())
        @test res_def.sections[1].name ∉ custom_names

        # With override: the selected section must come from the restricted set.
        res_ovr = StructuralSizer.size_beams(Mu, Vu, geoms,
                                             StructuralSizer.SteelBeamOptions(); catalog = custom2)
        @test res_ovr.sections[1].name ∈ custom_names
        # Lighter of the two feasible sections is chosen (MinVolume default).
        @test res_ovr.sections[1].name == "W21X44"
    end

    @testset "size_member_group! — default catalog when catalog_override === nothing" begin
        struc, _ = _build_beam_struc()
        # Establish the group, leave catalog_override at its default (nothing).
        build_member_groups!(struc; member_type = :beams)
        gid = first(keys(struc.member_groups))
        @test struc.member_groups[gid].catalog_override === nothing

        size_member_group!(struc, gid; member_edge_group = :beams,
                           material = A992_Steel, reanalyze = true)

        selected = struc.member_groups[gid].section
        @test selected !== nothing
        # Default all_W() selection is the light free optimum, not in custom2.
        @test selected.name ∉ custom_names
        # Sanity: section carries Mu = wL²/8 = 140 kip-ft.
        Mu = 140.0u"kip*ft"
        ϕMn = 0.9 * A992_Steel.Fy * selected.Zx
        @test ustrip(u"N*m", Mu) <= ustrip(u"N*m", ϕMn)
    end

    @testset "size_member_group! — honours catalog_override when set" begin
        struc, _ = _build_beam_struc()
        build_member_groups!(struc; member_type = :beams)
        gid = first(keys(struc.member_groups))

        # Phase-5-style wiring: set the group override before sizing.
        struc.member_groups[gid].catalog_override = custom2

        size_member_group!(struc, gid; member_edge_group = :beams,
                           material = A992_Steel, reanalyze = true)

        selected = struc.member_groups[gid].section
        @test selected !== nothing
        @test selected.name ∈ custom_names
        @test selected.name == "W21X44"

        # Override survived the member_group_demands rebuild (build_member_groups!
        # preserves catalog_override across the empty!/recreate cycle).
        @test struc.member_groups[gid].catalog_override === custom2
    end

    @testset "FramingLevel.catalog_override holds a non-nothing value (Phase 4 regression)" begin
        fl = FramingLevel{Float64}(
            slab_idx = 1, level = 1,
            pattern  = LinearAxisPattern{Float64}((1.0, 0.0), ustrip(u"m", 4.0u"ft"), nothing),
            role     = :joist,
            material = A992_Steel,
            catalog_override = custom2,
        )
        @test fl.catalog_override === custom2
    end
end
