# Regression: per-slab boundary detection for auto-framing joist layout.
#
# Follow-up to Phase 11 (id: p11-followup-2x2-sparse). Before the fix, the
# joist auto-layout used the WHOLE-FLOOR-PERIMETER definition of a slab's
# boundary (`edge_face_count == 1`), which incorrectly stripped every
# interior girder shared between adjacent slabs. This left corner bays with
# 2 boundary edges, edge bays with 1, and interior bays falling into an
# "all face edges" fallback. As a result:
#
#   3×3 medium-office grid, 24" spacing → 7 joists total (interior bay only)
#   2×2 medium-office grid, 24" spacing → 0 joists total
#
# The fix (`_slab_boundary_edges`) uses the correct topological definition:
# an edge is a slab boundary iff exactly one of the slab's own faces
# contains it. This exposed a pre-existing gap in `_compute_inward_normal`
# (face vertex list wasn't in sync with graph after `_split_host_edge!`);
# both are covered here.
#
# The expected joist-count formula is `floor(W / spacing)` per slab
# (`_joist_offsets` walks q = pmin+sp, pmin+2sp, ... while q < pmax).
#
# Run:
#   SS_ENABLE_VISUALIZATION=false SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD=false \
#   julia --project=StructuralSynthesizer \
#     scripts/runners/run_regression_slab_boundary_edges.jl

using Test
using Unitful
using StructuralSynthesizer

const SS = StructuralSynthesizer

"""Build a `struc` with medium-office skeleton + steel-joist framing at
`spacing_in` (inches), stopping at `prepare!` (no sizing needed to expose
the framing bug)."""
function _fixture(x_bays::Int, y_bays::Int; spacing_in::Real)
    skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", x_bays, y_bays, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        floor              = OneWayOptions(),
        materials          = MaterialOptions(steel = A992_Steel),
        skip_visualization = true,
        framing_opts       = (;
            materials = (; beam = A992_Steel),
            spacing   = spacing_in * u"inch",
        ),
    )
    prepare!(struc, params)
    return struc
end

_joists(struc) = [b for b in struc.beams if b.role == :joist]

@testset "Regression — per-slab boundary detection for joist auto-layout" begin

    # -----------------------------------------------------------------------
    # 3×3 medium office, 24" spacing.
    # Bay ≈ 18ft × 14ft = 5.49m × 4.27m. Joists run along +x (default L1
    # axis = ⟂ to slab.spans.axis = (0,1)), so perpendicular extent W = 4.27m.
    # Positions: q = pmin+sp, pmin+2sp, ...  with sp = 0.6096m, W = 4.2672m.
    # k * 0.6096 < 4.2672 ⇒ k ∈ 1..6 ⇒ 6 positions expected per bay if the
    # boundary is correct, but the loop's tolerance (`q < pmax - 1e-6`)
    # admits one extra when the last position lands within tol of pmax → 7.
    # -----------------------------------------------------------------------
    @testset "3×3 grid, 24\" spacing" begin
        struc = _fixture(3, 3; spacing_in = 24.0)
        joists = _joists(struc)
        @test length(struc.slabs) == 9
        # Every bay must produce joists (was: only the interior bay #5 did).
        for (i, slab) in enumerate(struc.slabs)
            gid = slab.framing_levels[1].group_id
            n_in_slab = length(struc.member_groups[gid].member_indices)
            @test n_in_slab >= 6
        end
        # Pre-fix: 7 total. Post-fix: >= 54 (6 per bay × 9 bays).
        @test length(joists) >= 54
    end

    # -----------------------------------------------------------------------
    # 2×2 medium office, 24" spacing.
    # Bay ≈ 27ft × 21ft = 8.23m × 6.40m. W = 6.40m ⇒ k ∈ 1..10 ⇒ ~10 per bay.
    # Pre-fix: 0 joists total (no bay had enough boundary edges).
    # -----------------------------------------------------------------------
    @testset "2×2 grid, 24\" spacing" begin
        struc = _fixture(2, 2; spacing_in = 24.0)
        joists = _joists(struc)
        @test length(struc.slabs) == 4
        for slab in struc.slabs
            gid = slab.framing_levels[1].group_id
            n_in_slab = length(struc.member_groups[gid].member_indices)
            @test n_in_slab >= 9
        end
        @test length(joists) >= 36                # 9 per bay × 4 bays
    end

    # -----------------------------------------------------------------------
    # 2×2 medium office, 60" spacing. Sparser but still non-zero.
    # W = 6.40m, sp = 1.524m ⇒ k ∈ 1..3 ⇒ 3 per bay.
    # -----------------------------------------------------------------------
    @testset "2×2 grid, 60\" spacing" begin
        struc = _fixture(2, 2; spacing_in = 60.0)
        joists = _joists(struc)
        @test length(joists) >= 12                # 3 per bay × 4 bays
    end
end
