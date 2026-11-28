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
        env = maximum(p -> max(1.4 * p.D, 1.2 * p.D + 1.6 * p.L, 0.0), parts)
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
    key = StructuralSizer._segment_key(((wall.x1, wall.y1), (wall.x2, wall.y2)))
    stored = vcat(panel.wall_face_parts, panel.wall_face_parts_secondary)
    @test any(p -> StructuralSizer._segment_key(((p.x1, p.y1), (p.x2, p.y2))) == key, stored)
    basis = StructuralSynthesizer._governing_slab_basis(struc, wall)
    @test basis !== nothing
    @test basis.faces !== nothing
    @test !isempty(basis.faces)

    # The equivalent frame stores dead and live per wall, and the final
    # design hands them to the panel the wall stage reads. A column at the
    # wall's end would be the frame joint, so the columns on the wall are
    # parked, as the shear-wall office does at pier ends.
    on_wall(col) = begin
        x, y = StructuralSizer._eq137_structural_xy(struc, col)
        dx, dy = wall.x2 - wall.x1, wall.y2 - wall.y1
        abs(dx * (y - wall.y1) - dy * (x - wall.x1)) / hypot(dx, dy) < 0.25
    end
    frame_columns = [col for col in columns if !on_wall(col)]
    @test length(frame_columns) == 2
    efm = EFM(solver=:hardy_cross)
    primary = StructuralSizer.run_moment_analysis(
        efm, struc, slab, frame_columns, 0.20u"m", fc, Ecs, γ; ν_concrete=RC_4000_60.concrete.ν)
    secondary = StructuralSizer.run_secondary_moment_analysis(
        efm, struc, slab, frame_columns, 0.20u"m", fc, Ecs, γ; ν_concrete=RC_4000_60.concrete.ν)
    efm_faces = vcat(primary.wall_faces, secondary.wall_faces)
    @test !isempty(efm_faces)
    @test all(p -> StructuralSizer._segment_key(((p.x1, p.y1), (p.x2, p.y2))) == key, efm_faces)
    @test all(p -> p.D > 0, efm_faces)
    handed = StructuralSizer._final_wall_face_parts(
        efm, nothing, struc, slab, frame_columns, 0.20u"m", γ, primary, secondary)
    @test handed[1] == primary.wall_faces
    @test handed[2] == secondary.wall_faces
    efm_panel = FlatPlatePanelResult(
        6.0u"m", 6.0u"m", 0.20u"m", primary.M0, primary.qu,
        3.0u"m", none, 3.0u"m", none,
        (ok = true, max_ratio = 0.1, details = Dict{Int,NamedTuple}()),
        (ok = true, Δ_check = 0.01u"m", Δ_total = 0.01u"m", Δ_limit = 0.02u"m");
        M_wall = primary.M_wall_ext,
        M_wall_secondary = secondary.M_wall_ext,
        wall_face_parts = handed[1],
        wall_face_parts_secondary = handed[2])
    slab.result = efm_panel
    efm_basis = StructuralSynthesizer._governing_slab_basis(struc, wall)
    @test efm_basis !== nothing
    @test efm_basis.faces !== nothing
    @test !isempty(efm_basis.faces)
    lw = StructuralSynthesizer.wall_length(wall) * u"m"
    @test StructuralSynthesizer._slab_moment_into_wall(struc, wall, lw) > 0u"N*m"
end
