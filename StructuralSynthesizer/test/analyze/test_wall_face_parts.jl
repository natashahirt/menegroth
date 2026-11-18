# One wall under one flat-plate panel. The shell's dead and live face
# moments rebuild the stored wall moment over 1.4D and 1.2D + 1.6L.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

@testset "wall-face dead and live parts rebuild the stored moment" begin
    # Two stories so the wall on story 1 has a floor above it.
    skel = gen_medium_office(6.0u"m", 6.0u"m", 3.0u"m", 1, 1, 2)
    beams = skel.groups_edges[:beams]
    level = [e for e in skel.stories[1].edges if e in beams]
    eidx = level[1]
    filter!(!=(eidx), beams)
    push!(get!(skel.groups_edges, :walls, Int[]), eidx)

    struc = BuildingStructure(skel)
    initialize!(struc;
        floor_type=:flat_plate,
        material=NWC_4000,
        floor_opts=FlatPlateOptions(
            material=RC_4000_60,
            method=FEA(target_edge=0.30u"m")),
        wall_thickness=0.30u"m")
    @test length(struc.walls) == 1
    for wall in struc.walls
        wall.concrete = RC_4000_60.concrete
    end
    for col in struc.columns
        col.c1 = 0.40u"m"
        col.c2 = 0.40u"m"
    end
    for cell in struc.cells
        cell.sdl = 1.0u"kPa"
        cell.live_load = 2.5u"kPa"
    end
    to_asap!(struc)

    z_floor = ustrip(u"m", skel.stories[1].elevation)
    slab = only(s for s in struc.slabs
                if (z = StructuralSizer._slab_elevation_m(struc, s)) !== nothing &&
                   abs(z - z_floor) <= 0.05)
    columns = StructuralSizer.find_supporting_columns(struc, Set(slab.cell_indices))
    fc = 4000.0u"psi"
    γ = RC_4000_60.concrete.ρ
    Ecs = StructuralSizer.Ec(fc, ustrip(StructuralSizer.pcf, γ))
    cache = StructuralSizer.FEAModelCache()
    result = StructuralSizer.run_moment_analysis(
        FEA(target_edge=0.30u"m"), struc, slab, columns, 0.20u"m", fc, Ecs, γ;
        ν_concrete=RC_4000_60.concrete.ν, cache=cache)

    @test max(abs(result.M_wall_ext), abs(result.secondary.M_wall_ext)) > 0u"N*m"
    setup = StructuralSizer._moment_analysis_setup(struc, slab, columns, 0.20u"m", γ)
    sec = StructuralSizer._secondary_moment_analysis_setup(struc, slab, columns, 0.20u"m", γ)
    for (ax, M) in ((setup.span_axis, result.M_wall_ext),
                    (sec.span_axis, result.secondary.M_wall_ext))
        parts = StructuralSizer._paired_wall_face_parts(cache, struc, slab, ax, M)
        M > 0u"N*m" || continue
        @test !isempty(parts)
        env = maximum(p -> max(1.4 * p[1], 1.2 * p[1] + 1.6 * p[2], 0.0), parts)
        @test env ≈ ustrip(u"N*m", M) rtol=1e-6
    end

    # The panel the wall stage reads carries the same split.
    none = StructuralSizer.StripReinforcement[]
    panel = FlatPlatePanelResult(
        6.0u"m", 6.0u"m", 0.20u"m", result.M0, result.qu,
        3.0u"m", none, 3.0u"m", none,
        (ok = true, max_ratio = 0.1, details = Dict{Int,NamedTuple}()),
        (ok = true, Δ_check = 0.01u"m", Δ_total = 0.01u"m", Δ_limit = 0.02u"m");
        M_wall = result.M_wall_ext,
        M_wall_secondary = result.secondary.M_wall_ext,
        wall_face_parts = StructuralSizer._paired_wall_face_parts(
            cache, struc, slab, setup.span_axis, result.M_wall_ext),
        wall_face_parts_secondary = StructuralSizer._paired_wall_face_parts(
            cache, struc, slab, sec.span_axis, result.secondary.M_wall_ext))
    slab.result = panel
    wall = only(struc.walls)
    basis = StructuralSynthesizer._governing_slab_basis(struc, wall)
    @test basis !== nothing
    @test basis.faces !== nothing
    @test !isempty(basis.faces)
end
