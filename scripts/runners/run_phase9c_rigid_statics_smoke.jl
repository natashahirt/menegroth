# Phase 9c smoke — rigid-diaphragm physics validation via **column shear
# distribution** rather than global moment equilibrium.
#
# Phase 9b established that `Asap.RigidLink` master/slave DOF reduction
# collapses in-plane story displacements to exact kinematic equality
# (Δ_u_x = 0; 14 orders of magnitude tighter than the free-frame case).
# Phase 9c validates the *statics consequence* of that constraint by
# comparing column base horizontal reactions under identical loading
# with and without the rigid tie.
#
# Why not a global-moment equilibrium check?
#   The `BuildingStructure → Asap.Model` convention (see
#   `_create_offset_nodes` in `analyze/asap/utils.jl`) pins the rotational
#   DOFs on every non-support frame node, so story-1 vertices act as
#   "internal supports" that carry moment reactions. Under an eccentric
#   horizontal load, the applied torsional moment is absorbed largely by
#   those internal θ_z fixities (not by ground R_Mz), which makes a
#   ground-reaction-only ΣM_z check misleading. Force equilibrium in x
#   and y still holds cleanly and is asserted below; the substantive
#   physics check is the column shear distribution.
#
# Testsets:
#   (1) Symmetric loading — Fx = F/4 at each story-1 vertex.
#       Every column base R_x must equal -F/4 by symmetry.
#   (2) Eccentric loading under `:rigid` — Fx = F applied at s2 only.
#       Rigid tie ⇒ all four column tops share the same u_x ⇒ equal
#       column stiffness ⇒ every column base R_x = -F/4. This is the
#       "shear equalization" hallmark of a rigid diaphragm.
#   (3) Eccentric loading under `:none` — Fx = F at s2, no rigid tie.
#       Column shear differentiates: the loaded corner (g2, directly
#       below s2) takes the largest |R_x|; the diagonally-opposite
#       corner (g4) takes the smallest. This is the shear differential
#       the rigid tie eliminates.
#   (4) Force equilibrium — under both modes, ΣR_x = -F and ΣR_y = 0
#       hold within numerical noise.
#
# Run:
#   SS_ENABLE_VISUALIZATION=false SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD=false \
#   julia --project=StructuralSynthesizer scripts/runners/run_phase9c_rigid_statics_smoke.jl

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer
using Asap

const SS = StructuralSynthesizer
const SZ = StructuralSizer

"""Same four-column, one-story fixture used in Phase 9b."""
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
    spans = SpanInfo{Float64}(Lx, Ly, (1.0, 0.0), 7.0)
    fidx = findfirst(vs -> Set(vs) == Set((s1, s2, s3, s4)),
                     skel.face_vertex_indices)
    fidx === nothing && error("story-1 face not found")
    cell = Cell(fidx, A, spans, 2.0u"kN/m^2", 3.0u"kN/m^2")
    cell.floor_type = :two_way
    push!(struc.cells, cell)
    push!(struc.slabs, Slab{Float64}([1],
        CIPSlabResult(0.2u"m", 0.2u"m", 5.0u"kPa"),
        :two_way, spans, :interior, nothing, MaterialVolumes(),
        nothing, nothing, FramingLevel{Float64}[]))

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
    return struc, (g1, g2, g3, g4), (s1, s2, s3, s4), (Lx, Ly, H)
end

"""Apply horizontal `NodeForce` set + resolve, respecting rigid links."""
function apply_and_resolve!(struc::BuildingStructure,
                            loads::AbstractVector{<:Tuple{Int, <:Real}})
    model = struc.asap_model
    for (v_idx, Fx_kN) in loads
        node = model.nodes[v_idx]
        push!(model.loads,
              Asap.NodeForce(node, [Fx_kN * u"kN", 0.0u"kN", 0.0u"kN"], :lateral))
    end
    if isempty(struc.asap_rigid_links)
        Asap.solve!(model; reprocess = true)
    else
        Asap.solve!(model, struc.asap_rigid_links; reprocess = true)
    end
    return model
end

"""Ground-base translational reactions `(Rx, Ry)` in Newtons at vertex `v`."""
function base_shears(model::Asap.Model, v::Int)
    gid = model.nodes[v].globalID
    return (model.reactions[gid[1]], model.reactions[gid[2]])
end

@testset "Phase 9c — rigid-diaphragm shear distribution & equilibrium" begin
    params = DesignParameters(materials =
        MaterialOptions(steel = A992_Steel, beam = A992_Steel))
    N_per_kN = 1000.0
    tol_kN = 0.5                                   # 0.25% of a 200 kN load

    # ── (1) Symmetric loading — every column takes an equal share ────────
    @testset "(1) symmetric loading ⇒ four equal column shears" begin
        F_total_kN = 200.0
        F_each_kN  = F_total_kN / 4
        struc, grounds, stories, _ = build_multistory_bay()
        to_asap!(struc; params = params, diaphragms = :rigid)
        m = apply_and_resolve!(struc,
            [(stories[i], F_each_kN) for i in 1:4])

        Rx = [base_shears(m, g)[1] for g in grounds]
        Ry = [base_shears(m, g)[2] for g in grounds]

        for r in Rx
            @test isapprox(r, -F_total_kN * N_per_kN / 4;
                           atol = tol_kN * N_per_kN)
        end
        @test isapprox(sum(Ry), 0.0;                atol = tol_kN * N_per_kN)
        @test isapprox(sum(Rx), -F_total_kN * N_per_kN;
                       atol = tol_kN * N_per_kN)
    end

    # ── (2) Eccentric loading under :rigid — shear equalization ──────────
    @testset "(2) :rigid ⇒ equal column shears (rigid tie eliminates offset)" begin
        F_kN = 200.0
        struc, grounds, stories, _ = build_multistory_bay()
        s2 = stories[2]
        to_asap!(struc; params = params, diaphragms = :rigid)
        m = apply_and_resolve!(struc, [(s2, F_kN)])

        Rx = [base_shears(m, g)[1] for g in grounds]
        Ry = [base_shears(m, g)[2] for g in grounds]

        # Every column base carries exactly F/4 in x-direction, regardless
        # of the applied load's line of action — the tie enforces identical
        # u_x at all story-1 tops, so with equal column stiffnesses the
        # column shears must also be equal.
        for r in Rx
            @test isapprox(r, -F_kN * N_per_kN / 4;
                           atol = tol_kN * N_per_kN)
        end
        # Global force equilibrium.
        @test isapprox(sum(Rx), -F_kN * N_per_kN; atol = tol_kN * N_per_kN)
        @test isapprox(sum(Ry), 0.0;              atol = tol_kN * N_per_kN)
    end

    # ── (3) Eccentric loading under :none — shear differentiates ──────────
    @testset "(3) :none ⇒ column shear differential; loaded corner takes more" begin
        F_kN = 200.0
        struc, grounds, stories, _ = build_multistory_bay()
        s2 = stories[2]
        to_asap!(struc; params = params, diaphragms = :none)
        m = apply_and_resolve!(struc, [(s2, F_kN)])

        Rx = [base_shears(m, g)[1] for g in grounds]

        # Directional physics: g2 (directly below the loaded corner s2)
        # must carry the largest |R_x|; g4 (diagonally opposite) the
        # smallest. This is the shear differential the rigid tie removes.
        absRx = abs.(Rx)
        @test absRx[2] > absRx[1]              # loaded corner beats near-side col
        @test absRx[2] > absRx[3]              # …and beats far-side same-x col
        @test absRx[2] > absRx[4]              # …and beats diagonal-opposite col
        @test absRx[4] < absRx[1]              # diagonal-opposite is the smallest
        # Global force equilibrium still holds.
        @test isapprox(sum(Rx), -F_kN * N_per_kN; atol = tol_kN * N_per_kN)
        # The differential is dramatic — at least 3× spread on this bay.
        @test absRx[2] / max(absRx[4], eps()) > 3.0
    end

    # ── (4) Cross-check — same fixture, :rigid vs :none, ΣR_x invariant ──
    @testset "(4) global ΣR_x invariant across diaphragm modes" begin
        F_kN = 200.0
        struc_r, grounds_r, stories_r, _ = build_multistory_bay()
        to_asap!(struc_r; params = params, diaphragms = :rigid)
        m_r = apply_and_resolve!(struc_r, [(stories_r[2], F_kN)])
        struc_n, grounds_n, stories_n, _ = build_multistory_bay()
        to_asap!(struc_n; params = params, diaphragms = :none)
        m_n = apply_and_resolve!(struc_n, [(stories_n[2], F_kN)])

        Rx_r_sum = sum(base_shears(m_r, g)[1] for g in grounds_r)
        Rx_n_sum = sum(base_shears(m_n, g)[1] for g in grounds_n)
        @test isapprox(Rx_r_sum, -F_kN * N_per_kN; atol = tol_kN * N_per_kN)
        @test isapprox(Rx_n_sum, -F_kN * N_per_kN; atol = tol_kN * N_per_kN)
        # Diaphragm mode changes distribution, not total.
        @test isapprox(Rx_r_sum, Rx_n_sum;         atol = tol_kN * N_per_kN)
    end

    @info "Phase 9c smoke — rigid diaphragm shear distribution validated" note="all column shears equal under :rigid; asymmetric under :none; ΣR_x = -F in both"
end
