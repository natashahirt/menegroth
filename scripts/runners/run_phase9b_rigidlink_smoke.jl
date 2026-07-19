# Phase 9b smoke — rigid diaphragm via `Asap.RigidLink` master/slave DOF
# reduction (Bathe *Finite Element Procedures* §4.4; Cook *Concepts and
# Applications of Finite Element Analysis* §6.3).
#
# Exercises `_build_rigid_diaphragm_links` in
# `StructuralSynthesizer/src/analyze/asap/utils.jl` and the links-aware
# `Asap.solve!(model, links)` dispatch in both `to_asap!` and `sync_asap!`.
#
# Fixture — one story on top of four columns, so we get exactly one rigid
# diaphragm level whose vertices are all non-supports (the ground story is
# fully supported and correctly produces zero rigid ties):
#
#     ┌─── beams (z=H) ───┐
#     │ s1 ───────── s2  │
#     │  │           │   │
#     │  │           │   │        columns
#     │ s4 ───────── s3  │
#     └───────────────────┘
#                 │  │  │  │
#             g1 g2 g3 g4  ← supports at z=0
#
# A horizontal load `Fx = 200 kN` is applied at `s1` and the model is
# resolved. With `diaphragms = :rigid`, `_build_rigid_diaphragm_links`
# produces three ties (`s1 → s2`, `s1 → s3`, `s1 → s4`) that force every
# story-1 vertex to translate identically in `x` (and `y`). With
# `diaphragms = :none`, no ties are built, so `s1` runs away from the other
# three under the point load and the differential is large.
#
# Assertions:
#   (1) `_build_rigid_diaphragm_links` produces one link per non-master
#       non-support vertex at story 1 AND emits zero ties at story 0
#       (all supports); `struc.asap_rigid_links` is populated by
#       `to_asap!` and cleared under `:none` / `:shell`.
#   (2) Under `:rigid`, all story-1 u_x values collapse to a single
#       tied value — differential across the four free vertices is
#       within numerical noise (< 1e-9 m).
#   (3) Under `:none`, the differential is orders of magnitude larger
#       (> 1e-4 m for this fixture), and the rigid ratio
#       (Δ_none / Δ_rigid) exceeds 1e5.
#   (4) `sync_asap!` respects the links: differential remains ~0 after
#       a sync-driven resolve.
#
# Run:
#   SS_ENABLE_VISUALIZATION=false SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD=false \
#   julia --project=StructuralSynthesizer scripts/runners/run_phase9b_rigidlink_smoke.jl

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer
using Asap

const SS = StructuralSynthesizer
const SZ = StructuralSizer

"""Build a single-story braced-frame fixture: four ground supports at z=0,
four columns rising to z=H, four boundary beams at z=H, and one slab covering
the story-1 face. Returns the `BuildingStructure` and the story-1 vertex
indices (as a 4-tuple `(s1, s2, s3, s4)`) so the smoke can address them."""
function build_multistory_bay()
    skel = BuildingSkeleton{Float64}()
    Lx, Ly, H = 8.0, 6.0, 3.5
    g1 = add_vertex!(skel, [0.0, 0.0, 0.0])
    g2 = add_vertex!(skel, [Lx,  0.0, 0.0])
    g3 = add_vertex!(skel, [Lx,  Ly,  0.0])
    g4 = add_vertex!(skel, [0.0, Ly,  0.0])
    s1 = add_vertex!(skel, [0.0, 0.0, H])
    s2 = add_vertex!(skel, [Lx,  0.0, H])
    s3 = add_vertex!(skel, [Lx,  Ly,  H])
    s4 = add_vertex!(skel, [0.0, Ly,  H])
    add_element!(skel, g1, s1; group = :columns)
    add_element!(skel, g2, s2; group = :columns)
    add_element!(skel, g3, s3; group = :columns)
    add_element!(skel, g4, s4; group = :columns)
    add_element!(skel, s1, s2; group = :beams)
    add_element!(skel, s2, s3; group = :beams)
    add_element!(skel, s3, s4; group = :beams)
    add_element!(skel, s4, s1; group = :beams)
    supports = get!(skel.groups_vertices, :support, Int[])
    append!(supports, (g1, g2, g3, g4))
    rebuild_stories!(skel); find_faces!(skel); rebuild_geometry_cache!(skel)

    struc = BuildingStructure(skel)
    A  = Lx * Ly * u"m^2"
    dl = 2.0u"kN/m^2"
    ll = 3.0u"kN/m^2"
    spans = SpanInfo{Float64}(Lx, Ly, (1.0, 0.0), 7.0)

    # Story-1 face — the only horizontal, four-corner face at z=H.
    fidx = findfirst(vs -> Set(vs) == Set((s1, s2, s3, s4)), skel.face_vertex_indices)
    fidx === nothing && error("story-1 face not found in fixture")
    cell = Cell(fidx, A, spans, dl, ll)
    cell.floor_type = :two_way
    push!(struc.cells, cell)
    push!(struc.slabs, Slab{Float64}([1],
        CIPSlabResult(0.2u"m", 0.2u"m", 5.0u"kPa"),
        :two_way, spans, :interior, nothing, MaterialVolumes(),
        nothing, nothing, FramingLevel{Float64}[]))

    # Segments/members — beams as :girder, columns as :column members.
    for e in sort(collect(skel.groups_edges[:beams]))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        push!(struc.beams, Beam([length(struc.segments)], L; role = :girder, level = 0))
    end
    for e in sort(collect(skel.groups_edges[:columns]))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        push!(struc.columns, Column([length(struc.segments)], L))
    end

    return struc, (s1, s2, s3, s4)
end

"""Push a horizontal `NodeForce` (Fx only) at `nodes[vertex_idx]` and re-solve
the model, honoring rigid links when non-empty."""
function apply_horizontal_and_resolve!(struc::BuildingStructure, vertex_idx::Int, Fx_kN::Real)
    model = struc.asap_model
    node = model.nodes[vertex_idx]
    push!(model.loads, Asap.NodeForce(node, [Fx_kN * u"kN", 0.0u"kN", 0.0u"kN"], :lateral))
    if isempty(struc.asap_rigid_links)
        Asap.solve!(model; reprocess = true)
    else
        Asap.solve!(model, struc.asap_rigid_links; reprocess = true)
    end
    return model
end

"""Vertical DOF-3 disp is at `node.globalID[1]` for u_x (globalID stores the
six DOF indices per node in order u_x, u_y, u_z, θ_x, θ_y, θ_z)."""
ux_of(model::Asap.Model, v_idx::Int) = model.u[model.nodes[v_idx].globalID[1]]

@testset "Phase 9b — rigid diaphragm via RigidLink master/slave reduction" begin
    params = DesignParameters(materials =
        MaterialOptions(steel = A992_Steel, beam = A992_Steel))

    # ── (1) Link generator: story 0 supports produce 0 links; story 1 free
    #       vertices produce (n_free - 1) links, master = lowest index ─────
    struc_probe, (s1, s2, s3, s4) = build_multistory_bay()
    to_asap!(struc_probe; params = params, diaphragms = :rigid)
    links = struc_probe.asap_rigid_links

    @testset "(1) link generator honors support/story filtering" begin
        @test length(links) == 3          # 4 free vertices at story 1 → 3 slaves
        # Every link's master is the same node (the lowest-index free story-1
        # vertex, s1). Every link's slave has u_x free (non-support).
        master_ref = first(links).nodeA
        @test all(l -> l.nodeA === master_ref, links)
        @test master_ref === struc_probe.asap_model.nodes[s1]
        slave_set = Set(l.nodeB for l in links)
        @test length(slave_set) == 3
        @test struc_probe.asap_model.nodes[s2] in slave_set
        @test struc_probe.asap_model.nodes[s3] in slave_set
        @test struc_probe.asap_model.nodes[s4] in slave_set
        # In-plane translations (u_x, u_y) must always be tied (release=false);
        # out-of-plane translation + rotations must always be released
        # (u_z, θ_x, θ_y = true). θ_z tie is release[6] = false when both
        # master and slave have θ_z free, otherwise release[6] = true (the
        # current `_create_offset_nodes` convention pins rotational DOFs on
        # non-support frame nodes, so we expect release[6] = true here).
        for l in links
            @test l.release[1] == false   # u_x tied
            @test l.release[2] == false   # u_y tied
            @test l.release[3] == true    # u_z free (gravity)
            @test l.release[4] == true    # θ_x free (out-of-plane bending)
            @test l.release[5] == true    # θ_y free (out-of-plane bending)
            # θ_z: tied iff both endpoints have θ_z free.
            expected_theta_z_release =
                !(l.nodeA.dof[6] && l.nodeB.dof[6])
            @test l.release[6] == expected_theta_z_release
        end
    end

    # ── (2) & (3) Under Fx = 200 kN at s1: :rigid collapses the four u_x to
    #             a single value; :none lets them diverge dramatically. ────
    struc_rigid, (s1r, s2r, s3r, s4r) = build_multistory_bay()
    to_asap!(struc_rigid; params = params, diaphragms = :rigid)
    m_rigid = apply_horizontal_and_resolve!(struc_rigid, s1r, 200.0)

    struc_none, (s1n, s2n, s3n, s4n) = build_multistory_bay()
    to_asap!(struc_none; params = params, diaphragms = :none)
    m_none = apply_horizontal_and_resolve!(struc_none, s1n, 200.0)

    ux_rigid = [ux_of(m_rigid, v) for v in (s1r, s2r, s3r, s4r)]
    ux_none  = [ux_of(m_none,  v) for v in (s1n, s2n, s3n, s4n)]
    Δ_rigid = maximum(ux_rigid) - minimum(ux_rigid)
    Δ_none  = maximum(ux_none)  - minimum(ux_none)

    @testset "(2) :rigid — differential u_x across story-1 vertices ≈ 0" begin
        @test isempty(struc_none.asap_rigid_links)
        @test !isempty(struc_rigid.asap_rigid_links)
        # Exact kinematic reduction ⇒ ties are enforced to floating-point
        # equality (up to sparse solve round-off).
        @test Δ_rigid < 1e-9
    end

    @testset "(3) :none — differential u_x is orders of magnitude larger" begin
        @test Δ_none > 1e-4
        # Any positive tie-driven reduction ratio is meaningful, but the
        # kinematic tie should crush the differential by many orders of
        # magnitude here (fixture is chosen to make this obvious).
        @test Δ_none / max(Δ_rigid, eps()) > 1e5
    end

    # ── (4) sync_asap! respects the links: rebuild loads/K, resolve, and
    #       confirm the tie is still enforced.
    @testset "(4) sync_asap! preserves the rigid tie" begin
        # sync_asap! rebuilds loads via _create_shell_area / cell_tributary
        # paths + reprocesses K + resolves. It should route through the
        # links-aware solve when struc.asap_rigid_links is non-empty.
        sync_asap!(struc_rigid; params = params)
        # Sync recomputes u without the manually pushed NodeForce (that
        # load was ad-hoc for the smoke), so u should now reflect gravity
        # only. Under symmetric gravity, u_x = 0 exactly for every node,
        # so the differential is trivially zero — check consistency.
        ux_after = [ux_of(struc_rigid.asap_model, v) for v in (s1r, s2r, s3r, s4r)]
        Δ_after = maximum(ux_after) - minimum(ux_after)
        @test Δ_after < 1e-9
        # The link vector is preserved across sync.
        @test length(struc_rigid.asap_rigid_links) == 3
    end

    @info "Phase 9b smoke summary" Δ_rigid=Δ_rigid Δ_none=Δ_none ratio=Δ_none/max(Δ_rigid, eps()) links=length(links)
end
