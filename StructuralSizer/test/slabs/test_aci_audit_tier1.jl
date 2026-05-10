# =============================================================================
# Tier-1 ACI 318-11 Audit Tests for Flat-Plate Slab Pipeline
# =============================================================================
#
# Each `@testset` pins a *correctness gap* surfaced during the audit of the
# DDM / EFM / FEA flat-plate analysis chain.  The tests encode the **correct
# ACI 318-11 behaviour** so they will fail (or report `Broken`) on `main`
# until the corresponding fix lands.  Items not yet fixed use `@test_broken`
# to keep CI green; once fixed they will report "Test broken: passed", at
# which point the maintainer should promote them to `@test`.
#
# Provisions covered:
#   1. Column-strip width — ACI 318-11 §13.2.1
#   2. Maximum bar spacing — ACI 318-11 §13.3.2
#   3. DDM interior unbalanced moment for live-load pattern — ACI 318-11
#      §13.6.9.2 Eq. (13-7)
#   4. Effective depth for the inner (secondary-direction) reinforcement layer
#      — ACI 318-11 §7.7 / two-way slab convention
#   5. Edge-beam-aware exterior-negative column-strip fraction —
#      ACI 318-11 §13.6.4.2 (Table for αf₁ℓ₂/ℓ₁ = 0)
#   6. Moment-transfer γf adjustment under §13.5.3.3 (skipped — fix scoped
#      separately)
# =============================================================================

using Test
using Unitful
using Unitful: @u_str
using Asap
using StructuralSizer

const SS = StructuralSizer

# Tests 3 and 5 require an end-to-end building (DDM moment analysis on a real
# slab).  The `gen_*_grid` builders live in `StructuralSynthesizer`, which is
# an *optional* test-time dependency in this package.  Match the pattern used
# by `test_tributary_workflow.jl`.
const HAS_STRUCTURAL_SYNTHESIZER = let ok = true
    try
        @eval using StructuralSynthesizer
    catch
        ok = false
    end
    ok
end

@testset "ACI 318-11 Audit — Tier 1" begin

    fc = 4000u"psi"
    fy = 60_000u"psi"

    # ─────────────────────────────────────────────────────────────────────
    # 1.  Column-strip width — ACI 318-11 §13.2.1
    # ─────────────────────────────────────────────────────────────────────
    # ACI 318-11 §13.2.1 (verbatim, p. 244): "Column strip is a design strip
    # with a width on each side of a column centerline equal to 0.25·ℓ2 or
    # 0.25·ℓ1, whichever is less.  Column strip includes beams, if any."
    # §13.2.2 (verbatim, p. 244): "Middle strip is a design strip bounded by
    # two column strips."
    #
    # Combined: cs_width = min(ℓ1, ℓ2)/2,  ms_width = ℓ2 − cs_width.
    #
    # The fix routes both `_design_strips_from_moments` (and its FEA-direct
    # variant) and `check_flexural_adequacy` through the §13.2.1 rule, and
    # propagates the same width into the deflection check section
    # properties (`Ig_cs`, `Ig_ms`).
    @testset "1. Column-strip width = min(ℓ1, ℓ2)/2  (ACI 318-11 §13.2.1)" begin
        h  = 7.0u"inch"
        d  = 5.5u"inch"
        l1 = 16.0u"ft"   # primary (span direction) — short
        l2 = 24.0u"ft"   # secondary (tributary) — long

        # Mock per-strip moments — values are arbitrary but nonzero.
        Mu = 50.0kip * u"ft"

        result = SS._design_strips_from_moments(
            Mu, Mu, Mu, Mu, Mu, Mu,
            l1, l2, d, fc, fy, h;
            label="audit-cs-width", verbose=false,
        )

        cs_correct = min(l1, l2) / 2     # = 8 ft
        ms_correct = l2 - cs_correct      # = 16 ft

        # § 13.2.1 ⇒ CS = min/2 of the two side widths.
        @test result.column_strip_width ≈ cs_correct
        # § 13.2.2 ⇒ MS = remainder of ℓ2 (NOT another min/2 — the panel is
        # rectangular so MS is wider than CS when ℓ1 < ℓ2).
        @test result.middle_strip_width ≈ ms_correct

        # Symmetric (square) check: when ℓ1 = ℓ2 the rule reduces to ℓ/2 / ℓ/2.
        result_sq = SS._design_strips_from_moments(
            Mu, Mu, Mu, Mu, Mu, Mu,
            20.0u"ft", 20.0u"ft", d, fc, fy, h;
            label="audit-cs-width-sq", verbose=false,
        )
        @test result_sq.column_strip_width ≈ 10.0u"ft"
        @test result_sq.middle_strip_width ≈ 10.0u"ft"

        # Reverse aspect (ℓ1 > ℓ2): cs = ℓ2/2 (which equals min/2 here).
        result_wide = SS._design_strips_from_moments(
            Mu, Mu, Mu, Mu, Mu, Mu,
            30.0u"ft", 20.0u"ft", d, fc, fy, h;
            label="audit-cs-width-wide", verbose=false,
        )
        @test result_wide.column_strip_width ≈ 10.0u"ft"   # min(30,20)/2
        @test result_wide.middle_strip_width ≈ 10.0u"ft"   # 20 − 10
    end

    # ─────────────────────────────────────────────────────────────────────
    # 2.  Maximum bar spacing — ACI 318-11 §13.3.2 + §7.6.5
    # ─────────────────────────────────────────────────────────────────────
    # §13.3.2 (verbatim, p. 245): "Spacing of reinforcement at critical
    # sections shall not exceed two times the slab thickness ..."
    # §7.6.5  (verbatim, p. 96):  "primary flexural reinforcement shall not
    # be spaced farther apart than three times the wall or slab thickness,
    # nor farther apart than 18 in."
    # Combined: s_max = min(2h, 18 in) at two-way slab critical sections.
    #
    # `design_single_strip` and the post-design bar-selection sites in
    # `pipeline.jl` / `rule_of_thumb.jl` now thread `max_bar_spacing(h)`
    # through to `select_bars`.  The §7.6.5 default of 18″ inside
    # `select_bars` itself is preserved (it's still correct as a hard ceiling
    # when no slab thickness is supplied — e.g. beam reinforcement).
    @testset "2. Maximum bar spacing s_max = min(2h, 18 in)  (ACI 318-11 §13.3.2 + §7.6.5)" begin
        h_thin = 5.0u"inch"
        s_max_correct = SS.max_bar_spacing(h_thin)   # = 10 in for h=5″
        @test s_max_correct ≈ 10.0u"inch"

        # Modest demand & wide strip → light reinforcement → spacing limited
        # by `max_spacing`, NOT by demand.  With `max_bar_spacing(h)` now
        # threaded through `design_single_strip`, the spacing will respect
        # the §13.3.2 2h cap.
        As_reqd = 0.5u"inch^2"
        b_strip = 96.0u"inch"

        # Direct call: when the caller passes the correct s_max, the result
        # is compliant.  This is the call-shape used everywhere in the
        # flat-plate design pipeline post-fix.
        bars_strip = SS.design_single_strip(:pos, 30.0SS.kip*u"ft", b_strip,
                                            4.0u"inch", fc, fy, h_thin)
        @test bars_strip.spacing <= s_max_correct

        # Bare `select_bars` without explicit max_spacing keeps its §7.6.5
        # ceiling of 18″ as documented — that path is reserved for callers
        # that don't have a slab thickness in scope (e.g. beam design).
        bars_default = SS.select_bars(As_reqd, b_strip)
        @test bars_default.spacing <= 18.0u"inch"
    end

    # ─────────────────────────────────────────────────────────────────────
    # 3.  DDM interior unbalanced moment — ACI 318-11 Eq. (13-7)
    # ─────────────────────────────────────────────────────────────────────
    # ACI 318-11 §13.6.9.2 Eq. (13-7) gives the live-load pattern
    # unbalanced moment at interior supports of two-way slabs:
    #
    #   Mu = 0.07 · [(qD,u + 0.5·qL,u)·ℓ2·ℓn² − qD,u·ℓ2'·(ℓn')²]
    #
    # `_compute_column_demands_ddm` (ddm.jl) hard-codes
    # `Mub = is_ext ? M : 0.0 * M` for interior columns — i.e. interior
    # unbalanced moment = 0 regardless of the live-load pattern.  This is
    # only valid when adjacent spans and live load are perfectly symmetric;
    # ACI requires Eq. (13-7) for punching-shear moment-transfer design.
    @testset "3. DDM Eq. (13-7) interior unbalanced moment  (ACI 318-11 §13.6.9.2)" begin
        if !HAS_STRUCTURAL_SYNTHESIZER
            @info "Skipping Tier 1 / item 3 — StructuralSynthesizer not available."
            @test true
        else
            # Equal-span symmetric layout (3×3 office, 24×24 ft bays, 7″ slab).
            skel = gen_medium_office(72.0u"ft", 72.0u"ft", 9.0u"ft", 3, 3, 1)
            struc = BuildingStructure(skel)
            opts = FlatPlateOptions(method=DDM())
            initialize!(struc; material=NWC_4000, floor_type=:flat_plate,
                        floor_opts=opts)

            slab = first(struc.slabs)
            # `find_supporting_columns` lives in StructuralSizer and takes
            # the cell-index `Set{Int}` (not a `Slab`).  See
            # `StructuralSizer/src/slabs/codes/concrete/flat_plate/utils/helpers.jl`.
            cols = SS.find_supporting_columns(struc, Set(slab.cell_indices))
            h    = slab.result.thickness
            # `NWC_4000` is a `Concrete`, not a `ReinforcedConcreteMaterial`,
            # so use its fields directly.  `γ_concrete` in the analysis API
            # is mass density (`ρ`), passed straight into
            # `slab_self_weight(h, ρ)` (see analysis/common.jl).
            ρc   = NWC_4000.ρ
            fc′  = NWC_4000.fc′
            Ecs  = SS.Ec(NWC_4000)

            m_res = SS.run_moment_analysis(DDM(), struc, slab, cols, h,
                                           fc′, Ecs, ρc)

            # Identify interior columns and their unbalanced moments.
            int_idx = findall(c -> c.position == :interior, cols)
            @test !isempty(int_idx)

            Mub_int = [m_res.unbalanced_moments[i] for i in int_idx]

            # Hand-calc Eq. (13-7) for the centre interior column with
            # symmetric adjacent spans (ℓ2' = ℓ2, ℓn' = ℓn) and live load
            # applied to the checkerboard pattern (full DL+½LL on the
            # longer panel, DL only on the shorter): Mu collapses to
            # 0.07·0.5·qL·ℓ2·ℓn².
            qL  = m_res.qL
            ℓ2  = m_res.l2
            ℓn  = m_res.ln
            Mub_eq_13_7 = uconvert(SS.kip*u"ft", 0.07 * 0.5 * qL * ℓ2 * ℓn^2)

            # Correct ACI behaviour: every interior column's Mub equals the
            # symmetric Eq. (13-7) value within tolerance (the simplified
            # single-panel DDM path always uses the symmetric collapse).
            atol_M = 1.0 * SS.kip * u"ft"
            @test all(isapprox(abs(m), Mub_eq_13_7; atol=atol_M)
                       for m in Mub_int)
            # Pin the absolute magnitude as a sanity check.
            @test all(abs(m) > 0.0SS.kip*u"ft" for m in Mub_int)
        end
    end

    # ─────────────────────────────────────────────────────────────────────
    # 4.  Effective depth of inner (secondary) reinforcement layer
    # ─────────────────────────────────────────────────────────────────────
    # In a two-way slab the secondary-direction bars sit *inside* (below) the
    # primary-direction bars.  Their effective depth is therefore reduced by
    # one full primary bar diameter plus one half-secondary bar diameter:
    #
    #   d_inner = h − cover − db_primary − db_secondary/2
    #           = d − (db_primary/2 + db_secondary/2)
    #           = d − db        (when db_primary == db_secondary)
    #
    # `pipeline.jl` hard-codes `_db_inner = 0.625u"inch"` (a #5 bar) so
    # `d_inner = d − 0.625″`, which is wrong when the primary bars are #6 or
    # larger (heavily-reinforced thin slabs).  The fix is to read the actual
    # bar diameter selected by the primary design.
    @testset "4. d_inner uses actual primary bar diameter  (ACI 318-11 §7.7)" begin
        # In a two-way slab the secondary-direction bars sit *below* the
        # primary bars (cover per ACI 318-11 §7.7 + bar-spacing geometry of
        # §7.6 force a layered placement), so:
        #
        #   d_inner = h − cover − db_primary − db_secondary/2
        #
        # The pipeline previously hard-coded `_db_inner = 0.625″`
        # (assuming a #5 secondary bar) and computed
        # `d_inner = d_avg − 0.625″`, which conflates two different
        # references and silently shifts d_inner by up to ±½ bar diameter.
        # The fix exposes `inner_layer_effective_depth(h, cover,
        # db_primary, db_secondary)` and routes pipeline.jl through it.
        h     = 8.0u"inch"
        cover = 0.75u"inch"

        # Case A — secondary bar #5 (matches the hard-coded assumption,
        # but the buggy reference d_avg is still wrong by db/2).
        db_p_a = SS.bar_diameter(5)
        db_s_a = SS.bar_diameter(5)
        d_inner_a = SS.inner_layer_effective_depth(h, cover, db_p_a, db_s_a)
        @test d_inner_a ≈ 6.3125u"inch" atol=1e-4u"inch"

        # Case B — primary #7, secondary #8 (the hard-coded 0.625″ was
        # wrong but the net effect was conservative for this geometry).
        db_p_b = SS.bar_diameter(7)   # 0.875″
        db_s_b = SS.bar_diameter(8)   # 1.0″
        d_inner_b = SS.inner_layer_effective_depth(h, cover, db_p_b, db_s_b)
        @test d_inner_b ≈ (8.0 - 0.75 - 0.875 - 0.5)u"inch" atol=1e-4u"inch"

        # Case C — primary #8, secondary #11 (where the hard-coded 0.625″
        # was UNCONSERVATIVE: buggy d_inner > correct d_inner).  The fix
        # now produces the correct (smaller) d_inner.
        db_p_c = SS.bar_diameter(8)   # 1.0″
        db_s_c = SS.bar_diameter(11)  # 1.41″
        d_inner_c = SS.inner_layer_effective_depth(h, cover, db_p_c, db_s_c)
        d_avg_c   = SS.effective_depth(h; cover=cover, bar_diameter=db_p_c)
        d_inner_legacy_buggy = d_avg_c - 0.625u"inch"

        # Correct value
        @test d_inner_c ≈ (8.0 - 0.75 - 1.0 - 1.41 / 2)u"inch" atol=1e-4u"inch"
        # Pin that the legacy formula was unconservative for this case:
        @test d_inner_legacy_buggy > d_inner_c
        # And quantify the shift: buggy − correct = db_secondary/2 − 0.625″
        @test (d_inner_legacy_buggy - d_inner_c) ≈
              (db_s_c / 2 - 0.625u"inch") atol=1e-4u"inch"

        # Case D — symmetric (db_primary == db_secondary), the everyday
        # PCA flat-plate convention used in pipeline.jl.  d_inner reduces
        # algebraically to h − cover − 1.5·db.
        for db_size in 4:8
            db = SS.bar_diameter(db_size)
            d_in_sym = SS.inner_layer_effective_depth(h, cover, db, db)
            @test d_in_sym ≈ h - cover - 1.5 * db atol=1e-4u"inch"
        end
    end

    # ─────────────────────────────────────────────────────────────────────
    # 5.  Edge-beam-aware exterior-negative column-strip fraction
    # ─────────────────────────────────────────────────────────────────────
    # ACI 318-11 §13.6.4.2 (verbatim, p. 251 — Table for αf₁ℓ₂/ℓ₁ = 0):
    #   βt = 0       → 100 % of M_neg_ext to column strip
    #   βt ≥ 2.5     →  75 % of M_neg_ext to column strip (linear interp.)
    #
    # The fix routes `_βt_design` (resolved from `opts.edge_beam_βt` /
    # `has_edge_beam`) into both `design_strip_reinforcement` and
    # `check_flexural_adequacy`, so the §13.6.4.2 distribution lands on
    # CS / MS together (the MS now picks up the (1 − cs_frac) remainder
    # instead of being silently zero).
    @testset "5. CS ext-neg fraction interpolates by βt  (ACI 318-11 §13.6.4.2)" begin
        # Helper formula (already correct in calculations.jl)
        @test SS.aci_col_strip_ext_neg_fraction(0.0) ≈ 1.00
        @test SS.aci_col_strip_ext_neg_fraction(2.5) ≈ 0.75
        @test SS.aci_col_strip_ext_neg_fraction(5.0) ≈ 0.75
        @test SS.aci_col_strip_ext_neg_fraction(1.25) ≈ 0.875

        # Unit test the strip-design core directly: with the same exterior
        # column moment, the βt = 2.5 case should produce a CS ext-neg
        # moment 75 % of the βt = 0 case, and the MS should pick up the
        # remaining 25 %.
        h  = 8.0u"inch"
        d  = 6.5u"inch"
        l1 = 24.0u"ft"
        l2 = 24.0u"ft"
        Mu_ext = 100.0SS.kip * u"ft"
        zero_M = 0.0SS.kip * u"ft"

        # Stub a moment_results-like object via _design_strips_from_moments
        # called twice with the same per-strip moments — the exterior-neg
        # split happens upstream in `design_strip_reinforcement`, but we
        # can verify here via the underlying helper.
        cs0  = SS.aci_col_strip_ext_neg_fraction(0.0)   * Mu_ext
        cs25 = SS.aci_col_strip_ext_neg_fraction(2.5)   * Mu_ext
        ms0  = (1.0 - SS.aci_col_strip_ext_neg_fraction(0.0)) * Mu_ext
        ms25 = (1.0 - SS.aci_col_strip_ext_neg_fraction(2.5)) * Mu_ext

        @test cs0  ≈ 100.0SS.kip * u"ft" atol=1e-3SS.kip*u"ft"
        @test cs25 ≈  75.0SS.kip * u"ft" atol=1e-3SS.kip*u"ft"
        @test ms0  ≈   0.0SS.kip * u"ft" atol=1e-3SS.kip*u"ft"
        @test ms25 ≈  25.0SS.kip * u"ft" atol=1e-3SS.kip*u"ft"
        @test (cs25 / cs0) ≈ 0.75 atol=1e-3

        # End-to-end pin: a 3×3 grid with `edge_beam_βt = 2.5` should
        # produce an ext-neg CS design moment 75 % of the same grid with
        # no edge beam.  Requires StructuralSynthesizer for grid gen, and
        # `size_slabs!` to upgrade `slab.result` from the rule-of-thumb
        # `CIPSlabResult` (produced by `initialize!`) to the rich
        # `FlatPlatePanelResult` that exposes per-strip reinforcement.
        if !HAS_STRUCTURAL_SYNTHESIZER
            @info "Skipping Tier 1 / item 5 end-to-end pin — " *
                  "StructuralSynthesizer not available."
        else
            skel = gen_medium_office(72.0u"ft", 72.0u"ft", 9.0u"ft", 3, 3, 1)

            function _ext_neg_cs_moment(βt_value::Float64)
                struc = BuildingStructure(skel)
                opts = FlatPlateOptions(
                    method = DDM(),
                    edge_beam_βt = βt_value > 0 ? βt_value : nothing,
                )
                initialize!(struc; material=NWC_4000,
                            floor_type=:flat_plate, floor_opts=opts)
                # `initialize!` only runs the rule-of-thumb _size_span_floor
                # (returning a `CIPSlabResult`).  Run the full DDM design so
                # that `slab.result` becomes a `FlatPlatePanelResult` with
                # `column_strip_reinf` populated.
                SS.size_slabs!(struc; options=opts)
                slab = first(struc.slabs)
                ext_neg = filter(sr -> sr.location == :ext_neg,
                                 slab.result.column_strip_reinf)
                isempty(ext_neg) && return 0.0SS.kip * u"ft"
                return uconvert(SS.kip*u"ft", first(ext_neg).Mu)
            end

            M_no_eb   = _ext_neg_cs_moment(0.0)   # βt = 0 → 100 % to CS
            M_full_eb = _ext_neg_cs_moment(2.5)   # βt = 2.5 → 75 % to CS

            @test M_no_eb > 0.0SS.kip * u"ft"
            @test (M_full_eb / M_no_eb) ≈ 0.75 atol=0.05
        end
    end

    # ─────────────────────────────────────────────────────────────────────
    # 6.  γf adjustment under §13.5.3.3  (out of scope — see plan)
    # ─────────────────────────────────────────────────────────────────────
    # ACI 318-11 §13.5.3.3 permits a 25 % increase of γf for moment-transfer
    # by flexure under specific shear-stress and reinforcement-ratio limits.
    # The current pipeline always uses the §13.5.3.2 baseline value.  Fix is
    # scoped to a follow-up change set — test is intentionally skipped.
    @testset "6. γf §13.5.3.3 adjustment  (deferred)" begin
        @test_skip false  # placeholder — replace with concrete pin when fix lands.
    end

end
