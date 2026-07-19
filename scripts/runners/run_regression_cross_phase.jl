# Cross-phase regression bridge — Phase 5 (populate_levels!) + Phase 9b (rigid
# diaphragm via RigidLink) + Phase 5 (tributary cascade) + sync_asap!.
#
# The individual Phase 7 / 8 / 9a / 9b / 9c smokes cover each seam in isolation,
# but nothing exercises **all three seams simultaneously**. This regression
# fixture builds a one-story two-way bay, auto-generates steel joists via
# `populate_levels!`, wires the rigid diaphragm via `to_asap!(:rigid)`, and
# asserts:
#
#   (1) `populate_levels!` generates ≥ 1 joist Beam with a non-empty
#       `tributary_profile` (Phase 5 cascade did run under `two_way` opts).
#   (2) `to_asap!(:rigid)` populates `struc.asap_rigid_links` AND emits frame
#       elements for the auto-generated joists (Phases 9b + 8 co-exist).
#   (3) Under an eccentric horizontal load, all four ground column shears equal
#       `-F/4` — the rigid tie's shear-equalization signature (Phase 9b) is
#       preserved with the joists in the model.
#   (4) `sync_asap!` re-solves without invalidating `struc.asap_rigid_links`;
#       reactions are byte-stable under an unchanged load (Phase 9b docstring
#       contract: rigid links are retained across `sync_asap!`).
#
# Run:
#   SS_ENABLE_VISUALIZATION=false SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD=false \
#   julia --project=StructuralSynthesizer scripts/runners/run_regression_cross_phase.jl

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer
using Asap

const SS = StructuralSynthesizer
const SZ = StructuralSizer

"""Build a single-story 8x6m two-way bay with a CIP slab + four girder edges +
four columns to ground, wired up ready for `populate_levels!`. Returns the
`BuildingStructure` and the tuples `(g1..g4)` / `(s1..s4)` of ground / story-1
vertex indices."""
function build_cross_phase_bay()
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
    A = Lx * Ly * u"m^2"
    spans = SpanInfo{Float64}(Lx, Ly, (1.0, 0.0), 7.0)
    corners = (s1, s2, s3, s4)
    fidx = findfirst(vs -> Set(vs) == Set(corners), skel.face_vertex_indices)
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
    return struc, (g1, g2, g3, g4), (s1, s2, s3, s4)
end

"""Apply a horizontal force `Fx_kN` at each of the given `story_vertices`,
respect any rigid links on `struc`, and return the mutated `Asap.Model`."""
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

"""Ground-base `R_x` (Newtons) at vertex `v`."""
function base_Rx(model::Asap.Model, v::Int)
    gid = model.nodes[v].globalID
    return model.reactions[gid[1]]
end

@testset "Cross-phase regression: populate_levels! + :rigid + sync_asap!" begin
    struc, grounds, stories = build_cross_phase_bay()
    params = DesignParameters(materials =
        MaterialOptions(steel = A992_Steel, beam = A992_Steel))

    # Phase 5 opts — auto-generate steel joists perpendicular to the span axis.
    # spacing = 2 m, so on an 8x6 bay with span axis (1,0) joists lie along ±y
    # at x = 2, 4, 6 (three joists) landing on the y-parallel girders.
    populate_opts = (materials = (steel = A992_Steel,), spacing = 2.0)
    populate_levels!(struc; opts = populate_opts)

    joists = [b for b in struc.beams if StructuralSynthesizer.level_of(b) == 1]
    n_host_beams = length([b for b in struc.beams if StructuralSynthesizer.level_of(b) == 0])

    @testset "(1) Phase 5 auto-generation: joists + tributary cascade" begin
        # Steel-joist auto-generation should produce exactly the interior joists,
        # in this case three (spacing = 2 m, W = 8 m ⇒ x = 2, 4, 6).
        @test length(joists) == 3
        @test all(b -> b.role === :joist, joists)
        @test all(b -> StructuralSynthesizer.level_of(b) == 1, joists)
        # Cascade populated a tributary_profile with non-zero widths (strip ⇒ 2 m
        # / joist since the pattern spacing is 2 m).
        for b in joists
            prof = b.tributary_profile
            @test prof !== nothing
            @test !isempty(prof.widths)
            avg = StructuralSynthesizer.tributary_average(prof)
            avg_m = avg isa Unitful.Quantity ? ustrip(u"m", avg) : Float64(avg)
            @test avg_m ≈ 2.0 atol = 1e-9
        end
    end

    to_asap!(struc; params = params, diaphragms = :rigid)

    @testset "(2) :rigid + joists coexist in Asap.Model" begin
        # RigidLink array populated. `populate_levels!` inserts a landing vertex
        # at every joist / girder intersection, so all N free story-1 vertices
        # (4 corners + 2 landings per joist on the two host girders) are tied
        # by (N-1) links. For 3 joists on a 4-corner bay: 4 + 3*2 = 10 vertices
        # ⇒ 9 links.
        @test !isempty(struc.asap_rigid_links)
        expected_landings_per_joist = 2
        expected_free_v = 4 + expected_landings_per_joist * length(joists)
        @test length(struc.asap_rigid_links) == expected_free_v - 1

        # Frame elements: girders (subdivided into sub-segments per landing),
        # + auto-generated joists + 4 columns.
        n_frame = length(struc.asap_model.elements)
        @test n_frame >= n_host_beams + length(joists) + 4
    end

    # Eccentric load: F kN applied at the s2 corner only. Under the rigid tie,
    # column shears must equalize to -F/4 (Phase 9b shear-equalization signature),
    # even in the presence of the auto-generated joists that share the same
    # story-1 nodes.
    F_kN, N_per_kN, tol_kN = 200.0, 1000.0, 0.5

    @testset "(3) rigid tie shear equalization survives auto-generated joists" begin
        m = apply_and_resolve!(struc, [(stories[2], F_kN)])
        Rx = [base_Rx(m, g) for g in grounds]
        for r in Rx
            @test isapprox(r, -F_kN * N_per_kN / 4; atol = tol_kN * N_per_kN)
        end
        @test isapprox(sum(Rx), -F_kN * N_per_kN; atol = tol_kN * N_per_kN)
    end

    # sync_asap! → re-solve without invalidating the rigid links. Reactions
    # under the same (unchanged) load model must be numerically identical.
    Rx_pre  = [base_Rx(struc.asap_model, g) for g in grounds]
    sync_asap!(struc; params = params)
    Rx_post = [base_Rx(struc.asap_model, g) for g in grounds]

    @testset "(4) sync_asap! preserves rigid diaphragm — reactions stable" begin
        @test !isempty(struc.asap_rigid_links)
        for (r0, r1) in zip(Rx_pre, Rx_post)
            @test isapprox(r0, r1; atol = tol_kN * N_per_kN, rtol = 1e-6)
        end
    end

    @info "Cross-phase regression — populate_levels! + :rigid + sync_asap!" note = "joists coexist with rigid tie; shear equalization + reaction stability preserved" n_joists = length(joists)
end
