# =============================================================================
# Corner punching — slab-path parity with punching_check
# =============================================================================
#
# Hand-calc oracles (this file + foundations/test_corner_punching.jl) use
# PCA EB712 Fig. 16-13 Case D / ACI 318-11 R11.11.7.2:
#
#   b1 = c1 + d/2,  b2 = c2 + d/2                   (§11.11.1.2, page 200)
#   c  = b1² / [2(b1 + b2)]                         (PCA Case D, page 486)
#   J/c = [b1² d (b1 + 4 b2) + d³ (b1 + b2)] / (6 b1)
#   γf  = 1 / (1 + (2/3)√(b1/b2))                   Eq. (13-1), page 250
#   γv  = 1 − γf                                    Eq. (11-37), page 209
#   vu  = Vu/(b0 d) + γv Mux,adj c_x / Jc_x
#                       + γv Muy,adj c_y / Jc_y     (§11.11.7.2, page 210)
#
# This file also checks that `check_punching_for_column` matches
# `punching_check` at a corner (including biaxial Muy), not Jc_edge/2.
# =============================================================================

using Test
using Unitful
using Asap
using StructuralSizer

const SS = StructuralSizer

@testset "Corner punching — slab / shared-API parity" begin
    c1 = 16.0u"inch"
    c2 = 16.0u"inch"
    d  = 5.75u"inch"
    h  = 7.0u"inch"
    fc = 4000.0u"psi"
    Vu = 40.0kip
    Mux = 30.0kip * u"ft"
    Muy = 20.0kip * u"ft"

    col = (position = :corner, c1 = c1, c2 = c2, shape = :rectangular)

    # Independent PCA Case D / §11.11.7.2 oracle (square column ⇒ γv_x = γv_y).
    b1 = c1 + d / 2
    b2 = c2 + d / 2
    b0 = b1 + b2
    cAB_x = b1^2 / (2 * (b1 + b2))
    cAB_y = b2^2 / (2 * (b1 + b2))
    J_over_c_x = (b1^2 * d * (b1 + 4 * b2) + d^3 * (b1 + b2)) / (6 * b1)
    J_over_c_y = (b2^2 * d * (b2 + 4 * b1) + d^3 * (b2 + b1)) / (6 * b2)
    Jc_x = J_over_c_x * cAB_x
    Jc_y = J_over_c_y * cAB_y
    γv_x = 1.0 - 1.0 / (1.0 + (2.0 / 3.0) * sqrt(b1 / b2))
    γv_y = 1.0 - 1.0 / (1.0 + (2.0 / 3.0) * sqrt(b2 / b1))
    Mux_adj = max(abs(Mux) - Vu * (c1 / 2 - cAB_x), zero(Mux))
    Muy_adj = max(abs(Muy) - Vu * (c2 / 2 - cAB_y), zero(Muy))
    vu_oracle = uconvert(u"psi", Vu / (b0 * d)) +
                uconvert(u"psi", γv_x * Mux_adj * cAB_x / Jc_x) +
                uconvert(u"psi", γv_y * Muy_adj * cAB_y / Jc_y)

    r_api = SS.punching_check(Vu, Mux, Muy, d, fc, c1, c2; position = :corner)
    r_slab = SS.check_punching_for_column(col, Vu, Mux, d, h, fc; Muy = Muy)
    r_direct = SS.punching_check(Vu, zero(Mux), zero(Muy), d, fc, c1, c2;
                                 position = :corner)

    @test ustrip(u"psi", r_api.vu) ≈ ustrip(u"psi", vu_oracle) rtol=1e-9
    @test ustrip(u"psi", r_slab.vu) ≈ ustrip(u"psi", vu_oracle) rtol=1e-9
    @test r_slab.ok == r_api.ok
    # Moment transfer must raise vu above concentric (the old corner path
    # dropped Mub and used vu = v_direct).
    @test ustrip(u"psi", r_api.vu) > ustrip(u"psi", r_direct.vu)

    # Uniaxial (Muy omitted) matches punching_check with Muy = 0.
    r_slab_x = SS.check_punching_for_column(col, Vu, Mux, d, h, fc)
    r_api_x  = SS.punching_check(Vu, Mux, zero(Muy), d, fc, c1, c2; position = :corner)
    @test ustrip(u"psi", r_slab_x.vu) ≈ ustrip(u"psi", r_api_x.vu) rtol=1e-9
end

@testset "Corner punching — production Muy (20×30 panel, governing 130 axis)" begin
    # Critic breaking input: 20×30 ft panel, corner 16×16, d = 5.75 in,
    # qu = 0.193 ksf.  Exterior transfer = 0.3 M0 per ACI 318-11 §13.6.3.6
    # (corpus: aci-318-11, page 255).  On centerline spans this is
    # Mub_x ≈ 87 kip-ft (short) and Mub_y ≈ 130 kip-ft (long).
    # ACI 318-11 §11.11.7.1 (page 209) + PCA EB712 Fig. 16-13 Case D
    # (page 486) require both axes; omitting Muy punches uniaxially on 87.
    l1 = 20.0u"ft"
    l2 = 30.0u"ft"
    qu = 0.193u"kip/ft^2"
    c1 = 16.0u"inch"
    c2 = 16.0u"inch"
    d  = 5.75u"inch"
    h  = 7.0u"inch"
    fc = 4000.0u"psi"

    M0_x = qu * l2 * l1^2 / 8
    M0_y = qu * l1 * l2^2 / 8
    Mux = 0.3 * M0_x
    Muy = 0.3 * M0_y
    @test ustrip(kip * u"ft", Mux) ≈ 86.85 atol=0.2
    @test ustrip(kip * u"ft", Muy) ≈ 130.275 atol=0.2

    # Corner tributary: (ℓ1/2)×(ℓ2/2).
    Vu = qu * (l1 / 2) * (l2 / 2)
    col = (position = :corner, c1 = c1, c2 = c2, shape = :rectangular)

    r_old = SS.check_punching_for_column(col, Vu, Mux, d, h, fc)  # Muy defaults to 0
    r_new = SS.check_punching_for_column(col, Vu, Mux, d, h, fc; Muy = Muy)
    r_y   = SS.check_punching_for_column(col, Vu, zero(Mux), d, h, fc; Muy = Muy)
    r_api = SS.punching_check(Vu, Mux, Muy, d, fc, c1, c2; position = :corner)

    @test ustrip(u"psi", r_new.vu) ≈ ustrip(u"psi", r_api.vu) rtol=1e-9
    # Governing long-axis moment must raise vu above the uniaxial-87 path.
    @test ustrip(u"psi", r_new.vu) > ustrip(u"psi", r_old.vu)
    @test ustrip(u"psi", r_y.vu) > ustrip(u"psi", r_old.vu)
    # Additive superposition (P2 deferred): both axes contribute.
    @test ustrip(u"psi", r_new.vu) > ustrip(u"psi", r_y.vu)

    # Drop-panel wrapper forwards Muy to the column-face check.
    drop = SS.DropPanelGeometry(2.5u"inch", 4.0u"ft", 4.0u"ft")
    h_tot = SS.total_depth_at_drop(h, drop)
    d_tot = d + drop.h_drop
    r_col_tot = SS.check_punching_for_column(col, Vu, Mux, d_tot, h_tot, fc; Muy = Muy)
    wrap_old = SS.check_punching(col, Vu, Mux, h, d, h_tot, d_tot, fc, drop)
    wrap_new = SS.check_punching(col, Vu, Mux, h, d, h_tot, d_tot, fc, drop; Muy = Muy)
    @test wrap_new.governing_section == :column
    @test wrap_new.ratio > wrap_old.ratio
    @test ustrip(u"psi", wrap_new.vu) ≈ ustrip(u"psi", r_col_tot.vu) rtol=1e-6
end

# Rectangular corner: γv_x ≠ γv_y, both PCA Case D axes still add.
@testset "Corner punching — rectangular column edge (γv_x ≠ γv_y)" begin
    c1 = 16.0u"inch"
    c2 = 24.0u"inch"
    d  = 5.75u"inch"
    h  = 7.0u"inch"
    fc = 4000.0u"psi"
    Vu = 40.0kip
    Mux = 30.0kip * u"ft"
    Muy = 45.0kip * u"ft"
    col = (position = :corner, c1 = c1, c2 = c2, shape = :rectangular)

    r_old = SS.check_punching_for_column(col, Vu, Mux, d, h, fc)
    r_new = SS.check_punching_for_column(col, Vu, Mux, d, h, fc; Muy = Muy)
    r_api = SS.punching_check(Vu, Mux, Muy, d, fc, c1, c2; position = :corner)
    @test ustrip(u"psi", r_new.vu) ≈ ustrip(u"psi", r_api.vu) rtol=1e-9
    @test ustrip(u"psi", r_new.vu) > ustrip(u"psi", r_old.vu)
    # Zero Muy (explicit) matches the omitted-keyword uniaxial path.
    r_zero = SS.check_punching_for_column(col, Vu, Mux, d, h, fc; Muy = zero(Muy))
    @test ustrip(u"psi", r_zero.vu) ≈ ustrip(u"psi", r_old.vu) rtol=1e-12
end

# Verbose corner must bind e_centroid (was UndefVarError at checks.jl ~153).
@testset "Corner punching — verbose e_centroid is bound" begin
    col = (position = :corner, c1 = 16.0u"inch", c2 = 16.0u"inch", shape = :rectangular)
    r = SS.check_punching_for_column(col, 40.0kip, 30.0kip * u"ft", 5.75u"inch",
                                     7.0u"inch", 4000.0u"psi";
                                     verbose = true, Muy = 20.0kip * u"ft")
    @test haskey(r, :vu) || hasproperty(r, :vu)
    @test ustrip(u"psi", r.vu) > 0
end

# =============================================================================
# Edge — 20×30 free-edge oracle (must not discard Muy)
# =============================================================================
#
# Column on the 20-ft free edge: interior in the primary frame
# (Mux = Eq. 13-7, O(10) kip-ft), exterior in the secondary
# (Muy = 0.3 M0_y ≈ 130 kip-ft).  punching_check(; position=:edge)
# takes max(|Mux|, |Muy|).  The slab kernel must not be weaker.

@testset "Edge punching — 20×30 panel applies Muy (max |Mux|, |Muy|)" begin
    l1 = 20.0u"ft"          # along free edge (interior in this frame)
    l2 = 30.0u"ft"          # perpendicular to free edge (exterior)
    qu = 0.193u"kip/ft^2"
    qLu = 0.064u"kip/ft^2"  # 1.6 × 40 psf
    c1 = 16.0u"inch"
    c2 = 16.0u"inch"
    d  = 5.75u"inch"
    h  = 7.0u"inch"
    fc = 4000.0u"psi"

    # ACI 318-11 §13.6.9.2 Eq. (13-7) symmetric form (corpus: aci-318-11, page 258).
    ln = l1 - c1
    Mux = 0.07 * 0.5 * qLu * l2 * ln^2
    # ACI 318-11 §13.6.3.6 (corpus: aci-318-11, page 255) on the long axis.
    M0_y = qu * l1 * l2^2 / 8
    Muy = 0.3 * M0_y
    @test 5 < ustrip(kip * u"ft", Mux) < 30   # Eq. 13-7 is O(10), not 0
    @test ustrip(kip * u"ft", Muy) ≈ 130.275 atol=0.2
    @test ustrip(kip * u"ft", Muy) > 4 * ustrip(kip * u"ft", Mux)

    # Mid-edge tributary of a 20-ft bay on the 30-ft span: ℓ1 × (ℓ2/2).
    Vu = qu * l1 * (l2 / 2)
    col = (position = :edge, c1 = c1, c2 = c2, shape = :rectangular)

    r_old = SS.check_punching_for_column(col, Vu, Mux, d, h, fc)  # Muy omitted
    r_new = SS.check_punching_for_column(col, Vu, Mux, d, h, fc; Muy = Muy)
    r_y   = SS.check_punching_for_column(col, Vu, zero(Mux), d, h, fc; Muy = Muy)
    r_api = SS.punching_check(Vu, Mux, Muy, d, fc, c1, c2; position = :edge)

    @test ustrip(u"psi", r_new.vu) ≈ ustrip(u"psi", r_api.vu) rtol=1e-9
    # Discarded-Muy path: vu(Mux, Muy) collapses to vu(Mux, 0) and these fail.
    @test ustrip(u"psi", r_new.vu) > ustrip(u"psi", r_old.vu)
    @test ustrip(u"psi", r_y.vu) > ustrip(u"psi", r_old.vu)
    # :edge takes max(|Mux|, |Muy|) = |Muy|, so Muy-only matches both-axes.
    @test ustrip(u"psi", r_new.vu) ≈ ustrip(u"psi", r_y.vu) rtol=1e-9
    # Omitted Muy stays uniaxial on Mux (parity with punching_check Mux-only).
    r_api_x = SS.punching_check(Vu, Mux, zero(Muy), d, fc, c1, c2; position = :edge)
    @test ustrip(u"psi", r_old.vu) ≈ ustrip(u"psi", r_api_x.vu) rtol=1e-9

    # Drop-panel wrapper must forward Muy on :edge (same as :corner).
    drop = SS.DropPanelGeometry(2.5u"inch", 4.0u"ft", 4.0u"ft")
    h_tot = SS.total_depth_at_drop(h, drop)
    d_tot = d + drop.h_drop
    r_col_tot = SS.check_punching_for_column(col, Vu, Mux, d_tot, h_tot, fc; Muy = Muy)
    wrap_old = SS.check_punching(col, Vu, Mux, h, d, h_tot, d_tot, fc, drop)
    wrap_new = SS.check_punching(col, Vu, Mux, h, d, h_tot, d_tot, fc, drop; Muy = Muy)
    @test wrap_new.governing_section == :column
    @test wrap_new.ratio > wrap_old.ratio
    @test ustrip(u"psi", wrap_new.vu) ≈ ustrip(u"psi", r_col_tot.vu) rtol=1e-6
end

# Production edge columns fill `boundary_edge_dirs` via classify_column_position.
# A left-edge dir (-1, 0) infers :c1; the uniaxial check must still use |Muy|.
@testset "Edge punching — production boundary_edge_dirs infers :c1, keeps |Muy|" begin
    l1 = 20.0u"ft"
    l2 = 30.0u"ft"
    qu = 0.193u"kip/ft^2"
    qLu = 0.064u"kip/ft^2"
    c1 = 16.0u"inch"
    c2 = 16.0u"inch"
    d  = 5.75u"inch"
    h  = 7.0u"inch"
    fc = 4000.0u"psi"

    ln = l1 - c1
    Mux = 0.07 * 0.5 * qLu * l2 * ln^2
    M0_y = qu * l1 * l2^2 / 8
    Muy = 0.3 * M0_y
    @test 5 < ustrip(kip * u"ft", Mux) < 30
    @test ustrip(kip * u"ft", Muy) ≈ 130.275 atol=0.2

    Vu = qu * l1 * (l2 / 2)
    col = (position = :edge, c1 = c1, c2 = c2, shape = :rectangular,
           boundary_edge_dirs = [(-1.0, 0.0)], θ = 0.0)
    @test SS._infer_free_edge_parallel(col) === :c1

    r_prod = SS.check_punching_for_column(col, Vu, Mux, d, h, fc; Muy = Muy)
    r_drop = SS.check_punching_for_column(col, Vu, Mux, d, h, fc)
    r_gov  = SS.check_punching_for_column(col, Vu, zero(Mux), d, h, fc; Muy = Muy)
    r_api  = SS.punching_check(Vu, Mux, Muy, d, fc, c1, c2;
                               position = :edge, free_edge_parallel = :c1)

    @test ustrip(u"psi", r_prod.vu) ≈ ustrip(u"psi", r_api.vu) rtol=1e-9
    @test ustrip(u"psi", r_prod.vu) ≈ ustrip(u"psi", r_gov.vu) rtol=1e-9
    @test ustrip(u"psi", r_prod.vu) > ustrip(u"psi", r_drop.vu)
end

@testset "P0: pipeline punch geom cache accepts 6-tuple including edge_par" begin
    # size_flat_plate! keys on (c1_m, c2_m, d_m, position, shape, edge_par).
    # A 5-tuple Dict throws MethodError on the first :edge fill.
    cache = Dict{Tuple{Float64,Float64,Float64,Symbol,Symbol,Symbol}, NamedTuple}()
    c1 = 12.0u"inch"
    c2 = 24.0u"inch"
    d  = 6.0u"inch"
    h  = 8.0u"inch"
    fc = 4000.0u"psi"
    Vu = 50.0kip
    Mux = 80.0kip * u"ft"
    Muy = 10.0kip * u"ft"
    col = (position = :edge, c1 = c1, c2 = c2, shape = :rectangular)

    key_c1 = (ustrip(u"m", c1), ustrip(u"m", c2), ustrip(u"m", d),
              :edge, :rectangular, :c1)
    cache[key_c1] = (ok = true,)  # 6-tuple insert must not throw
    @test haskey(cache, key_c1)
    empty!(cache)

    r_c1 = SS.check_punching_for_column(col, Vu, Mux, d, h, fc;
                                        Muy = Muy, free_edge_parallel = :c1,
                                        _geom_cache = cache)
    r_c2 = SS.check_punching_for_column(col, Vu, Mux, d, h, fc;
                                        Muy = Muy, free_edge_parallel = :c2,
                                        _geom_cache = cache)
    @test ustrip(u"psi", r_c1.vu) > 0
    @test ustrip(u"psi", r_c2.vu) > 0
    @test length(cache) == 2
    @test r_c1.vu != r_c2.vu

    cache5 = Dict{Tuple{Float64,Float64,Float64,Symbol,Symbol}, NamedTuple}()
    @test_throws MethodError SS.check_punching_for_column(
        col, Vu, Mux, d, h, fc; Muy = Muy, free_edge_parallel = :c1,
        _geom_cache = cache5)
end

# Interior — shared API already superposes both axes; slab path must match.
@testset "Interior punching — biaxial Muy superposition" begin
    c1 = 16.0u"inch"
    c2 = 16.0u"inch"
    d  = 5.75u"inch"
    h  = 7.0u"inch"
    fc = 4000.0u"psi"
    Vu = 50.0kip
    Mux = 10.0kip * u"ft"
    Muy = 25.0kip * u"ft"
    col = (position = :interior, c1 = c1, c2 = c2, shape = :rectangular)

    r_old = SS.check_punching_for_column(col, Vu, Mux, d, h, fc)
    r_new = SS.check_punching_for_column(col, Vu, Mux, d, h, fc; Muy = Muy)
    r_api = SS.punching_check(Vu, Mux, Muy, d, fc, c1, c2; position = :interior)

    @test ustrip(u"psi", r_new.vu) ≈ ustrip(u"psi", r_api.vu) rtol=1e-9
    # Discarded-Muy path: superposition collapses to Mux-only and this fails.
    @test ustrip(u"psi", r_new.vu) > ustrip(u"psi", r_old.vu)
    r_api_x = SS.punching_check(Vu, Mux, zero(Muy), d, fc, c1, c2; position = :interior)
    @test ustrip(u"psi", r_old.vu) ≈ ustrip(u"psi", r_api_x.vu) rtol=1e-9
    r_y = SS.check_punching_for_column(col, Vu, zero(Mux), d, h, fc; Muy = Muy)
    @test ustrip(u"psi", r_y.vu) > ustrip(u"psi", r_old.vu)
    # Interior adds both axes (unlike :edge max).
    @test ustrip(u"psi", r_new.vu) > ustrip(u"psi", r_y.vu)
end

# =============================================================================
# Production-caller oracles
# =============================================================================
#
# The API tests above would still pass if pipeline / rule-of-thumb / NLP
# forgot to forward Muy.  These oracles call those production functions.

"""Build the 20×30 ft corner NLP problem used by the production evaluate() path."""
function _make_2030_corner_nlp(;
    sdl = 20.0psf,
    qL  = 40.0psf,
    h_min_in = 6.0,
    h_max_in = 14.0,
    c_min_in = 10.0,
    c_max_in = 24.0,
    positions = [:corner],
    trib_ft2 = [150.0],   # (20/2)×(30/2)
)
    mat = RC_4000_60
    fc  = mat.concrete.fc′
    fy  = mat.rebar.Fy
    Es  = mat.rebar.E
    γ_c = mat.concrete.ρ
    λ   = mat.concrete.λ
    wc_pcf = ustrip(pcf, γ_c)
    Ecs = Ec(fc, wc_pcf)
    FlatPlateNLPProblem(
        mat, fc, fy, Es, Ecs, γ_c, λ,
        20.0u"ft", 30.0u"ft", sdl, qL,
        positions, trib_ft2, 2 * ustrip(u"m", 10.0u"ft"),
        0.26, 0.70, 0.52,
        0.75u"inch", bar_diameter(5),
        0.90, 0.75, :L_360,
        (h_min_in, h_max_in), (c_min_in, c_max_in),
        [4, 5, 6, 7, 8],
        MinVolume(),
    )
end

"""Replay evaluate()'s load / 0.3 Mo transfer / punching block (does not call evaluate)."""
function _nlp_corner_punching(p::FlatPlateNLPProblem, h_in::Float64, c_in::Float64; use_muy::Bool)
    h = h_in * u"inch"
    c = c_in * u"inch"
    d = effective_depth(h; cover=p.cover, bar_diameter=p.bar_dia)
    sw  = SS.slab_self_weight(h, p.γ_concrete)
    qD  = uconvert(psf, p.sdl) + sw
    qL  = uconvert(psf, p.qL)
    qu  = max(factored_pressure(default_combo, qD, qL),
              factored_pressure(strength_1_4D, qD, qL))
    l1 = uconvert(u"ft", p.l1)
    l2 = uconvert(u"ft", p.l2)
    c_ft = uconvert(u"ft", c)
    ln  = clear_span(l1, c_ft)
    ln2 = clear_span(l2, c_ft)
    M0   = total_static_moment(qu, l2, ln)
    M0_y = total_static_moment(qu, l1, ln2)
    # ACI 318-11 §13.6.3.6 (corpus: aci-318-11, page 255)
    Mux = 0.3 * M0
    Muy = use_muy ? 0.3 * M0_y : zero(M0)
    Vu  = uconvert(kip, qu * p.column_trib_ft2[1] * u"ft^2")
    col = (c1=c, c2=c, position=:corner)
    punch = check_punching_for_column(col, Vu, Mux, d, h, p.fc;
                                      λ=p.λ, φ_shear=p.φ_shear,
                                      Muy = use_muy ? Muy : nothing)
    moment_results = MomentAnalysisResult(
        uconvert(kip * u"ft", M0),
        uconvert(kip * u"ft", 0.26 * M0),
        uconvert(kip * u"ft", 0.70 * M0),
        uconvert(kip * u"ft", 0.52 * M0),
        qu, qD, qL, l1, l2, ln, c_ft,
        [uconvert(kip * u"ft", 0.26 * M0)],
        [Vu],
        [uconvert(kip * u"ft", Mux)],
        uconvert(kip, qu * l2 * ln / 2),
    )
    shear = SS.check_one_way_shear(moment_results, d, p.fc; λ=p.λ, φ_shear=p.φ_shear)
    return (punch=punch, shear=shear, Mux=Mux, Muy=0.3 * M0_y, Vu=Vu, qu=qu, d=d, h=h)
end

@testset "Corner punching — NLP evaluate() forwards Muy" begin
    # Production evaluate() must punch the 20×30 corner as (Mux, Muy), not (Mux, 0).
    # ACI 318-11 §11.11.7.1 (corpus: aci-318-11, page 209) + §13.6.3.6 (page 255).
    p = _make_2030_corner_nlp()

    # At h=7″ the critic's qu≈0.193 ksf; clear-span 0.3 Mo is slightly below
    # the centerline 87 / 130 kip-ft pair, but the long axis still governs.
    d7 = _nlp_corner_punching(p, 7.0, 16.0; use_muy=true)
    @test ustrip(kip * u"ft", d7.Mux) > 70
    @test ustrip(kip * u"ft", d7.Muy) > ustrip(kip * u"ft", d7.Mux)
    @test ustrip(kip * u"ft", d7.Muy) > 100

    r_uni = _nlp_corner_punching(p, 7.0, 16.0; use_muy=false).punch
    r_bi  = d7.punch
    @test ustrip(u"psi", r_bi.vu) > ustrip(u"psi", r_uni.vu)

    # Discriminant: uniaxial punching + one-way pass, biaxial punching fails.
    # evaluate() checks punching before rebar, so infeasible ⇒ it forwarded Muy.
    # A thick slab (h=12″) keeps one-way / deflection from governing.
    found = nothing
    for c_in in 10.0:1.0:18.0
        uni = _nlp_corner_punching(p, 12.0, c_in; use_muy=false)
        bi  = _nlp_corner_punching(p, 12.0, c_in; use_muy=true)
        if uni.punch.ok && uni.shear.ok && !bi.punch.ok
            found = c_in
            break
        end
    end
    @test !isnothing(found)
    feasible, obj, _ = evaluate(p, [12.0, found])
    @test feasible == false
    @test obj == Inf

    # Same thickness with a large column: biaxial punching passes, so evaluate
    # is not rejected by the (Mux, 0) path.  If this is feasible, the failure
    # above is specifically the missing-Muy bug, not a global check collapse.
    big = _nlp_corner_punching(p, 12.0, 24.0; use_muy=true)
    if big.punch.ok && big.shear.ok
        f_big, obj_big, _ = evaluate(p, [12.0, 24.0])
        @test f_big == true
        @test obj_big < Inf
    end
end

# Optional: live pipeline / rule-of-thumb callers (need StructuralSynthesizer).
const HAS_STRUCTURAL_SYNTHESIZER = let ok = true
    try
        @eval using StructuralSynthesizer
    catch
        ok = false
    end
    ok
end

@testset "Corner punching — pipeline / RuleOfThumb pass Muy" begin
    if !HAS_STRUCTURAL_SYNTHESIZER
        @info "Skipping production pipeline oracle — StructuralSynthesizer not available."
        @test true
    else
        skel = gen_medium_office(20.0u"ft", 30.0u"ft", 10.0u"ft", 1, 1, 1)
        struc = BuildingStructure(skel)
        opts = FlatPlateOptions(min_h = 7.0u"inch")
        initialize!(struc; floor_type = :flat_plate, floor_opts = opts)
        for col in struc.columns
            col.c1 = 16.0u"inch"
            col.c2 = 16.0u"inch"
        end
        slab = first(struc.slabs)
        col_opts = ConcreteColumnOptions()

        rot = SS.size_flat_plate!(struc, slab, col_opts;
                                  method = RuleOfThumb(), opts = opts, verbose = false)
        @test !isnothing(rot.slab_result)
        details = rot.slab_result.punching_check.details
        @test !isempty(details)

        h = rot.h_final
        d = effective_depth(h; cover = opts.cover, bar_diameter = bar_diameter(opts.bar_size))
        mat = opts.material
        fc = mat.concrete.fc′
        ρc = mat.concrete.ρ
        Ecs = Ec(fc, ustrip(pcf, ρc))
        cols = SS.find_supporting_columns(struc, Set(slab.cell_indices))
        primary = SS.run_moment_analysis(DDM(), struc, slab, cols, h, fc, Ecs, ρc)
        secondary = SS.run_secondary_moment_analysis(DDM(), struc, slab, cols, h, fc, Ecs, ρc)

        n_corners = 0
        for (i, col) in enumerate(cols)
            col.position == :corner || continue
            n_corners += 1
            gidx = findfirst(==(col), struc.columns)
            pr = details[gidx]
            r_old = SS.check_punching_for_column(
                col, primary.column_shears[i], primary.unbalanced_moments[i], d, h, fc)
            r_new = SS.check_punching_for_column(
                col, primary.column_shears[i], primary.unbalanced_moments[i], d, h, fc;
                Muy = secondary.unbalanced_moments[i])
            # Long-axis transfer must exceed the short-axis 0.3 Mo (20×30).
            @test ustrip(kip * u"ft", secondary.unbalanced_moments[i]) >
                  ustrip(kip * u"ft", primary.unbalanced_moments[i])
            @test ustrip(u"psi", r_new.vu) > ustrip(u"psi", r_old.vu)
            # Production vu is the biaxial path, not (Mux, 0).
            @test ustrip(u"psi", pr.vu) ≈ ustrip(u"psi", r_new.vu) rtol=0.08
            @test abs(ustrip(u"psi", pr.vu) - ustrip(u"psi", r_new.vu)) <
                  abs(ustrip(u"psi", pr.vu) - ustrip(u"psi", r_old.vu))
        end
        @test n_corners == 4

        # Iterative DDM pipeline on a fresh 20×30: same corner oracle.
        skel2 = gen_medium_office(20.0u"ft", 30.0u"ft", 10.0u"ft", 1, 1, 1)
        struc2 = BuildingStructure(skel2)
        opts2 = FlatPlateOptions(min_h = 7.0u"inch")
        initialize!(struc2; floor_type = :flat_plate, floor_opts = opts2)
        for col in struc2.columns
            col.c1 = 16.0u"inch"
            col.c2 = 16.0u"inch"
        end
        slab2 = first(struc2.slabs)
        pipe = SS.size_flat_plate!(struc2, slab2, ConcreteColumnOptions();
                                   method = DDM(), opts = opts2, verbose = false)
        @test !isnothing(pipe.slab_result)
        h2 = pipe.h_final
        d2 = effective_depth(h2; cover = opts2.cover,
                             bar_diameter = bar_diameter(opts2.bar_size))
        cols2 = SS.find_supporting_columns(struc2, Set(slab2.cell_indices))
        prim2 = SS.run_moment_analysis(DDM(), struc2, slab2, cols2, h2, fc, Ecs, ρc)
        sec2  = SS.run_secondary_moment_analysis(DDM(), struc2, slab2, cols2, h2, fc, Ecs, ρc)
        details2 = pipe.slab_result.punching_check.details
        n_c2 = 0
        for (i, col) in enumerate(cols2)
            col.position == :corner || continue
            n_c2 += 1
            gidx = findfirst(==(col), struc2.columns)
            pr = details2[gidx]
            r_old = SS.check_punching_for_column(
                col, prim2.column_shears[i], prim2.unbalanced_moments[i], d2, h2, fc)
            r_new = SS.check_punching_for_column(
                col, prim2.column_shears[i], prim2.unbalanced_moments[i], d2, h2, fc;
                Muy = sec2.unbalanced_moments[i])
            @test ustrip(u"psi", pr.vu) ≈ ustrip(u"psi", r_new.vu) rtol=0.08
            @test abs(ustrip(u"psi", pr.vu) - ustrip(u"psi", r_new.vu)) <
                  abs(ustrip(u"psi", pr.vu) - ustrip(u"psi", r_old.vu))
        end
        @test n_c2 == 4
    end
end
