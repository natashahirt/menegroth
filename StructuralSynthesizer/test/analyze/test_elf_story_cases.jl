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

"""
Story 0 is the support level and has no beam grid. Copy the story-1 beam
plan down to the column bases so a ground wall has an edge to claim.
"""
function _elf_grade_beams!(skel)
    beams = Set(get(skel.groups_edges, :beams, Int[]))
    any(e -> e in beams && _elf_horizontal(skel, e), skel.stories[0].edges) && return skel
    z0 = skel.stories_z[1]
    for e in skel.stories[1].edges
        (e in beams && _elf_horizontal(skel, e)) || continue
        v1, v2 = skel.edge_indices[e]
        x1, y1 = _elf_xy(skel, v1)
        x2, y2 = _elf_xy(skel, v2)
        StructuralSynthesizer.add_element!(skel, Meshes.Segment(
            Meshes.Point(x1 * u"m", y1 * u"m", z0),
            Meshes.Point(x2 * u"m", y2 * u"m", z0));
            group=:beams, level_idx=0)
    end
    # find_faces! has already run, so the grade faces are added here.
    at = Dict{NTuple{2, Float64}, Int}()
    for (k, v) in enumerate(skel.vertices)
        c = Meshes.coords(v)
        abs(ustrip(u"m", c.z) - ustrip(u"m", z0)) <= 1e-6 || continue
        at[(round(ustrip(u"m", c.x); digits=6), round(ustrip(u"m", c.y); digits=6))] = k
    end
    for face in skel.stories[1].faces
        cycle = Int[]
        for v in skel.face_vertex_indices[face]
            x, y = _elf_xy(skel, v)
            key = (round(x; digits=6), round(y; digits=6))
            haskey(at, key) || error("elf fixture: no grade vertex at $key")
            push!(cycle, at[key])
        end
        StructuralSynthesizer.add_face!(skel, Meshes.Ngon(skel.vertices[cycle]...);
                                        group=:grade, level_idx=0, v_indices=cycle)
    end
    return skel
end

"""1×1 office, two stories, one wall on story 0, rigid diaphragm."""
function _elf_building()
    skel = gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 1, 2)
    _elf_grade_beams!(skel)
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

"""Slab dead load [kN] on stories strictly above the lowest story with faces."""
function _elf_cells_above_base_kN(struc)
    skel = struc.skeleton
    z_base = Inf
    for (_, story) in skel.stories
        isempty(story.faces) && continue
        z_base = min(z_base, ustrip(u"m", story.elevation))
    end
    by_face = Dict(cell.face_idx => cell for cell in struc.cells)
    total = 0.0
    for (_, story) in skel.stories
        isempty(story.faces) && continue
        ustrip(u"m", story.elevation) > z_base + 1e-6 || continue
        for face in story.faces
            cell = get(by_face, face, nothing)
            cell === nothing && continue
            total += ustrip(u"kN", effective_seismic_weight(cell))
        end
    end
    return total
end

"""Downward force [kN] of the unfactored dead-load vector."""
function _elf_downward_kN(loads)
    total_N = 0.0
    for ld in loads
        if ld isa Asap.AreaLoad
            p = ustrip(u"Pa", ld.pressure)
            for sh in ld.shells
                total_N += p * sh.area * (-ld.direction[3])
            end
        elseif ld isa Asap.TributaryLoad
            L = ustrip(u"m", length(ld.element))
            s = ld.positions
            w = ld._widths_m
            area = 0.0
            for i in 1:(length(s) - 1)
                area += 0.5 * (w[i] + w[i + 1]) * (s[i + 1] - s[i]) * L
            end
            total_N += ld._pressure_Pa * area * (-ld.direction[3])
        elseif ld isa Asap.GravityLoad
            total_N += StructuralSynthesizer._gravity_load_weight_kN(ld) * 1000
        elseif ld isa Asap.LineLoad
            L = ustrip(u"m", length(ld.element))
            total_N += -ustrip(u"N/m", ld.value[3]) * L
        else
            error("elf dead-load check: unhandled $(typeof(ld))")
        end
    end
    return total_N / 1000
end

"""A frame column from the base to the story above, not a wall edge."""
function _elf_base_column(struc)
    wall_edges = Set(get(struc.skeleton.groups_edges, :walls, Int[]))
    for (i, el) in enumerate(struc.asap_model.frame_elements)
        i in wall_edges && continue
        # A column inside a wall is parked with a zero section. Its weight is
        # nothing, so the self-weight check needs a column that was built.
        ustrip(u"m^2", el.section.A) > 0 || continue
        z1 = ustrip(u"m", el.nodeStart.position[3])
        z2 = ustrip(u"m", el.nodeEnd.position[3])
        z_bot, z_top = minmax(z1, z2)
        abs(z_bot) <= 1e-6 && z_top > 1.0 && return el
    end
    error("elf fixture: no base column")
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
    # Ground-story wall: half its self-weight is on the levels, half stays at
    # the base. ASCE 7-22 §12.7.2 counts dead load above the base.
    w_wall = 0.0
    for pier in struc.wall_mesh.piers
        for sh in pier.shells
            w_wall += StructuralSynthesizer._shell_self_weight_kN(sh)
        end
    end
    @test w_wall > 0
    @test length(struc.wall_mesh.piers) == 1
    cells_above = _elf_cells_above_base_kN(struc)
    # 10 × 6 m plan, stories 4 m. One 10 m wall replaces that side of the
    # ground story, so the first band is the other 22 m and the roof band is
    # the full 32 m. Half of the first band stays at the base.
    # ASCE 7-22 §3.1.1 and §12.7.2 (corpus: asce-7-22, PDF pages 72 and 184).
    p = struc.cladding_SDL
    w_story1 = ustrip(u"kN", p * 22.0u"m" * 4.0u"m")
    w_story2 = ustrip(u"kN", p * 32.0u"m" * 4.0u"m")
    clad_above = 0.5 * w_story1 + w_story2
    clad_base = 0.5 * w_story1
    @test sum(lv.weight_kN for lv in result.levels) ≈
          cells_above + 0.5 * w_wall + clad_above rtol=1e-9
    # The unfactored dead case includes the whole wall, the whole façade, and
    # the slabs above the base, and omits the :grade slab at the base.
    # Equilibrium makes this resultant the vertical base reaction.
    dead = solve_gravity_basic_cases(struc)
    @test dead.symbols[1] === :D
    @test _elf_downward_kN(dead.loads[1]) ≈
          cells_above + w_wall + clad_above + clad_base rtol=1e-6 atol=1e-3
    clad_loads = [ld for ld in struc.asap_model.loads
                  if ld isa Asap.LineLoad && ld.id === :cladding]
    @test !isempty(clad_loads)
    bands = StructuralSynthesizer._cladding_bands(struc)
    w_bands = sum(ustrip(u"kN", p * b.length_m * u"m" * b.height_m * u"m") for b in bands)
    @test w_bands ≈ w_story1 + w_story2 rtol=1e-9
    factored_kN = sum(-ustrip(u"N/m", ld.value[3]) * ustrip(u"m", length(ld.element))
                      for ld in clad_loads) / 1000
    params = DesignParameters(materials=MaterialOptions(concrete=NWC_5000))
    factor = StructuralSynthesizer._wall_self_weight_dead_factor(params; patterned=false)
    @test factored_kN ≈ factor * (w_story1 + w_story2) rtol=1e-6

    # A base column's GravityLoad is unfactored ρAg. Half is above the base.
    struc2 = _elf_building()
    col = _elf_base_column(struc2)
    push!(struc2.asap_model.loads, Asap.GravityLoad(col, Asap.GRAVITY))
    w_col = StructuralSynthesizer._gravity_load_weight_kN(only(
        ld for ld in struc2.asap_model.loads if ld isa Asap.GravityLoad))
    @test w_col > 0
    result2 = elf_story_analysis(struc2;
        method=:sds, SDS=0.05, S1=0.02, R=8, Ie=1.0, T=0.4, Cd=4.0, β=1.0,
        SD1=0.02, TL=8.0)
    @test sum(lv.weight_kN for lv in result2.levels) ≈
          sum(lv.weight_kN for lv in result.levels) + 0.5 * w_col rtol=1e-9
    z_top = max(ustrip(u"m", col.nodeStart.position[3]),
                ustrip(u"m", col.nodeEnd.position[3]))
    i_top = findfirst(lv -> abs(lv.elevation_m - z_top) <= 1e-6, result2.levels)
    i_top_0 = findfirst(lv -> abs(lv.elevation_m - z_top) <= 1e-6, result.levels)
    @test i_top !== nothing
    @test result2.levels[i_top].weight_kN ≈
          result.levels[i_top_0].weight_kN + 0.5 * w_col rtol=1e-9
    @test result2.levels[i_top].gravity_kN ≈
          result.levels[i_top_0].gravity_kN + 0.5 * w_col rtol=1e-9
    @test result2.levels[i_top].px_kN ≈
          result.levels[i_top_0].px_kN + 0.5 * w_col rtol=1e-9

    seismic = factored_seismic_cases(result, strength_1_2D_1_0E)
    @test length(seismic) == 6
    xnone = only(c for c in seismic if result.cases[c.case_index].direction === :x &&
                 result.cases[c.case_index].torsion === :none &&
                 result.cases[c.case_index].purpose === :strength)
    @test xnone.Fx_kN ≈ strength.Fx_kN
    @test all(==(0.0), xnone.Fy_kN)
    @test isempty(factored_seismic_cases(result, strength_1_2D_1_0W))

    # wall_SDL of zero is an explicit façade of none. W returns to slab plus
    # the half of the wall that sits above the base.
    struc0 = _elf_building()
    params0 = DesignParameters(
        materials=MaterialOptions(concrete=NWC_5000),
        loads=GravityLoads(wall_SDL=0.0u"psf"))
    to_asap!(struc0; params=params0, diaphragms=:rigid)
    @test iszero(ustrip(struc0.cladding_SDL))
    @test !any(ld -> ld isa Asap.LineLoad && ld.id === :cladding, struc0.asap_model.loads)
    result0 = elf_story_analysis(struc0;
        method=:sds, SDS=0.05, S1=0.02, R=8, Ie=1.0, T=0.4, Cd=4.0, β=1.0,
        SD1=0.02, TL=8.0)
    w_wall0 = 0.0
    for pier in struc0.wall_mesh.piers
        for sh in pier.shells
            w_wall0 += StructuralSynthesizer._shell_self_weight_kN(sh)
        end
    end
    @test sum(lv.weight_kN for lv in result0.levels) ≈
          _elf_cells_above_base_kN(struc0) + 0.5 * w_wall0 rtol=1e-9
end
