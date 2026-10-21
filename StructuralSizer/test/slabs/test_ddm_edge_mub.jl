# =============================================================================
# DDM exterior unbalanced (transfer) moment — ACI 318-11 §13.6.3.6
# =============================================================================
#
# The gravity load moment transferred between slab and edge column is 0.3 Mo
# (ACI 318-11 §13.6.3.6, corpus: aci-318-11, page 255), where Mo is the
# adjacent end-span static moment from Eq. (13-4):
#
#   Mo = qu * l2 * ln^2 / 8                         (13-4, page 253)
#
# Slab flexural assignment at the exterior negative section stays the
# §13.6.3.3 coefficient (0.26 Mo without edge beam, page 254).
# Interior unbalanced moment stays Eq. (13-7) (page 258):
#
#   Mu = 0.07[(qDu + 0.5 qLu) l2 ln^2 − qDu' l2' (ln')^2]
# =============================================================================

using Test
using Unitful
using Asap
using StructuralSizer

const SS = StructuralSizer

@testset "DDM edge-column transfer moment (ACI 318-11 §13.6.3.6)" begin
    qu = 0.193u"kip/ft^2"
    qD = 0.100u"kip/ft^2"
    qL = 0.050u"kip/ft^2"
    l2 = 14.0u"ft"
    ln = 16.67u"ft"
    M0 = SS.total_static_moment(qu, l2, ln)
    # Independent Eq. (13-4) oracle — do not take Mo only from the helper.
    M0_oracle = qu * l2 * ln^2 / 8
    Mub_ext_oracle = 0.3 * M0_oracle   # §13.6.3.6
    M_neg_ext = 0.26 * M0              # §13.6.3.3, no edge beam (page 254)
    M_neg_int = 0.70 * M0
    M_pos     = 0.52 * M0

    col_ext = (position = :corner,)
    col_int = (position = :interior,)

    col_M, _, Mub = SS._compute_column_demands_ddm(
        nothing, [col_ext, col_int],
        M_neg_ext, M_neg_int, M_pos,
        qu, qD, qL, l2, ln, (1.0, 0.0), M0)

    @testset "Eq. (13-4) Mo hand-calc" begin
        @test ustrip(kip * u"ft", M0) ≈ ustrip(kip * u"ft", M0_oracle) rtol=1e-12
    end

    @testset "single-panel DDM" begin
        @test ustrip(kip * u"ft", Mub[1]) ≈ ustrip(kip * u"ft", Mub_ext_oracle) rtol=1e-12
        @test ustrip(kip * u"ft", col_M[1]) ≈ ustrip(kip * u"ft", M_neg_ext) rtol=1e-12
        @test abs(ustrip(kip * u"ft", Mub[1])) >
              abs(ustrip(kip * u"ft", M_neg_ext))   # 0.3 Mo > 0.26 Mo

        # ACI 318-11 §13.6.9.2 Eq. (13-7) (corpus: aci-318-11, page 258).
        # Equal adjacent spans ⇒ dead-load terms cancel.  Envelope of
        # §9.2.1 Eq. (9-1) and Eq. (9-2) (page 123): 1.2D+1.6L governs
        # here, so Mu = 0.07 * 0.5 * (1.6 qL) * l2 * ln^2, not the
        # service-load value.
        Mub_int_137 = SS.governing_interior_unbalanced_moment(
            qD, qL, l2, ln, qD, qL, l2, ln)
        Mub_service = 0.07 * 0.5 * qL * l2 * ln^2
        @test ustrip(kip * u"ft", Mub[2]) ≈ ustrip(kip * u"ft", Mub_int_137) rtol=1e-9
        @test ustrip(kip * u"ft", Mub_int_137) >
              ustrip(kip * u"ft", Mub_service) * 1.5
        @test ustrip(kip * u"ft", col_M[2]) ≈ ustrip(kip * u"ft", M_neg_int) rtol=1e-12
    end

    @testset "edge position uses the same 0.3 Mo" begin
        # Fallback `is_exterior_support` treats any non-interior position
        # as exterior, so :edge must also receive §13.6.3.6 (not 0.26 Mo).
        _, _, Mub_e = SS._compute_column_demands_ddm(
            nothing, [(position = :edge,)],
            M_neg_ext, M_neg_int, M_pos,
            qu, qD, qL, l2, ln, (1.0, 0.0), M0)
        @test ustrip(kip * u"ft", Mub_e[1]) ≈
              ustrip(kip * u"ft", Mub_ext_oracle) rtol=1e-12
    end

    @testset "multi-span DDM reuses adjacent-span M0" begin
        sm = [(
            span_idx = 1,
            ln = ln,
            M0 = M0,
            M_neg_left = M_neg_ext,
            M_pos = M_pos,
            M_neg_right = M_neg_int,
        )]
        cols = [(position = :corner,), (position = :corner,)]
        col_M2, _, Mub2 = SS._compute_column_demands_from_spans(
            nothing, cols, [true, true], sm, qu, qD, qL, l2)

        @test ustrip(kip * u"ft", Mub2[1]) ≈ ustrip(kip * u"ft", Mub_ext_oracle) rtol=1e-12
        @test ustrip(kip * u"ft", Mub2[2]) ≈ ustrip(kip * u"ft", Mub_ext_oracle) rtol=1e-12
        @test ustrip(kip * u"ft", col_M2[1]) ≈ ustrip(kip * u"ft", M_neg_ext) rtol=1e-12
        @test ustrip(kip * u"ft", col_M2[2]) ≈ ustrip(kip * u"ft", M_neg_int) rtol=1e-12
    end

    @testset "multi-span interior Eq. (13-7) factored envelope" begin
        ln_L = 18.0u"ft"
        ln_R = 14.0u"ft"
        M0_L = SS.total_static_moment(qu, l2, ln_L)
        M0_R = SS.total_static_moment(qu, l2, ln_R)
        spans = [
            (span_idx=1, ln=ln_L, M0=M0_L,
             M_neg_left=0.26*M0_L, M_pos=0.52*M0_L, M_neg_right=0.70*M0_L),
            (span_idx=2, ln=ln_R, M0=M0_R,
             M_neg_left=0.65*M0_R, M_pos=0.35*M0_R, M_neg_right=0.26*M0_R),
        ]
        cols = [(position=:corner,), (position=:interior,), (position=:corner,)]
        _, _, Mub3 = SS._compute_column_demands_from_spans(
            nothing, cols, [true, false, true], spans, qu, qD, qL, l2)

        # Service-load Eq. (13-7) understates the live term.  The helper
        # envelopes §9.2.1 Eq. (9-1) 1.4D and Eq. (9-2) 1.2D+1.6L.
        Mub_137 = SS.governing_interior_unbalanced_moment(
            qD, qL, l2, ln_L, qD, qL, l2, ln_R)
        Mub_service = 0.07 * ((qD + 0.5 * qL) * l2 * ln_L^2 - qD * l2 * ln_R^2)
        @test ustrip(kip * u"ft", Mub3[1]) ≈ ustrip(kip * u"ft", 0.3 * M0_L) rtol=1e-12
        @test ustrip(kip * u"ft", Mub3[3]) ≈ ustrip(kip * u"ft", 0.3 * M0_R) rtol=1e-12
        @test ustrip(kip * u"ft", Mub3[2]) ≈ ustrip(kip * u"ft", Mub_137) rtol=1e-9
        @test ustrip(kip * u"ft", Mub_137) > abs(ustrip(kip * u"ft", Mub_service))
    end
end
