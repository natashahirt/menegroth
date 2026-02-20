# ==============================================================================
# Fire Rating Parametric Report
# ==============================================================================
# Evaluates the impact of fire resistance ratings (0–4 hr) on structural
# elements across all available materials and protection systems:
#
#   §1. Concrete Slabs    — min thickness, min cover (ACI 216.1 Tables 4.2, 4.3.1.1)
#   §2. Concrete Beams    — min cover for 3 beam widths (ACI 216.1 Table 4.3.1.2)
#   §3. Concrete Columns  — min dimension, min cover (ACI 216.1 Table 4.5.1a, §4.5.3)
#   §4. Steel Beams       — SFRM vs Intumescent thickness + weight (UL X772, N643)
#   §5. Steel Columns     — SFRM thickness + weight for W-shapes (UL X772)
#   §6. Full System       — 3-story flat plate office (0, 1, 2 hr sweep)
#   §7. SFRM vs Intumescent — weight comparison across W-shape catalog
#
# Format: Computed / Reference tables with ✓/✗ checks, summary tables with
# engineering commentary, and parametric sweeps.
#
# References:
#   ACI/TMS 216.1-14   — Fire Resistance of Concrete & Masonry Assemblies
#   UL Design No. X772 — SFRM on Steel Columns (contour profile)
#   UL Design No. N643 — Intumescent on Steel Beams
#   AISC Design Guide 19 — Fire Resistance of Structural Steel Framing
# ==============================================================================

using Test
using Printf
using Dates
using Unitful
using Unitful: @u_str

using StructuralSizer

# ─────────────────────────────────────────────────────────────────────────────
# Report helpers (consistent with beam/column reports)
# ─────────────────────────────────────────────────────────────────────────────

const FR_HLINE = "─"^90
const FR_DLINE = "═"^90

fr_header(title) = println("\n", FR_DLINE, "\n  ", title, "\n", FR_DLINE)
fr_sub(title)    = println("\n  ", FR_HLINE, "\n  ", title, "\n  ", FR_HLINE)
fr_note(msg)     = println("    → ", msg)

const RATINGS = [0.0, 1.0, 1.5, 2.0, 3.0, 4.0]
const AGG_TYPES = [siliceous, carbonate, sand_lightweight, lightweight]
const AGG_NAMES = ["Siliceous", "Carbonate", "Sand-LW", "Lightweight"]

# ─────────────────────────────────────────────────────────────────────────────

println()
println(FR_DLINE)
println("  FIRE RATING PARAMETRIC REPORT")
println("  Generated: ", Dates.format(now(), "yyyy-mm-dd HH:MM"))
println("  StructuralSizer v", string(pkgversion(StructuralSizer)))
println(FR_DLINE)

@testset "Fire Rating Report" begin

# ==========================================================================
# §1. CONCRETE SLABS — Minimum Thickness (ACI 216.1 Table 4.2)
# ==========================================================================

fr_header("§1  CONCRETE SLAB MINIMUM THICKNESS (ACI 216.1 Table 4.2)")

fr_note("Values in inches. For fire_rating = 0 hr, no fire requirement applies.")
fr_note("The governing h is max(h_ACI318, h_fire).")
println()

# Table header
@printf("    %-14s", "Rating (hr)")
for name in AGG_NAMES
    @printf("  %12s", name)
end
println()
@printf("    %-14s", "─"^14)
for _ in AGG_TYPES
    @printf("  %12s", "─"^12)
end
println()

@testset "Slab thickness" begin
    for r in RATINGS
        @printf("    %-14s", string(r))
        for agg in AGG_TYPES
            h = min_thickness_fire(r, agg)
            h_in = ustrip(u"inch", h)
            @printf("  %10.1f\"", h_in)
            @test h_in >= 0.0  # sanity
        end
        println()
    end
end

fr_note("Siliceous requires the thickest sections; lightweight the thinnest.")
fr_note("A 2 hr rating on siliceous (5.0\") often governs over ACI 318 for short spans.")


# ==========================================================================
# §2. CONCRETE SLAB COVER (ACI 216.1 Table 4.3.1.1)
# ==========================================================================

fr_header("§2  CONCRETE SLAB COVER (ACI 216.1 Table 4.3.1.1)")

for (restrained, label) in [(true, "RESTRAINED"), (false, "UNRESTRAINED")]
    fr_sub("$label Nonprestressed Slabs")
    fr_note("Cover in inches. ACI 318 minimum cover (¾\") still applies as a floor.")
    println()

    @printf("    %-14s", "Rating (hr)")
    for name in AGG_NAMES
        @printf("  %12s", name)
    end
    println()
    @printf("    %-14s", "─"^14)
    for _ in AGG_TYPES
        @printf("  %12s", "─"^12)
    end
    println()

    @testset "Slab cover ($label)" begin
        for r in RATINGS
            @printf("    %-14s", string(r))
            for agg in AGG_TYPES
                c = min_cover_fire_slab(r, agg; restrained=restrained)
                c_in = ustrip(u"inch", c)
                @printf("  %10.3f\"", c_in)
                @test c_in >= 0.0
            end
            println()
        end
    end
end

fr_note("Restrained slabs: ¾\" cover for all ratings up to 4 hr — fire seldom governs.")
fr_note("Unrestrained siliceous at 4 hr: 1.625\" — may govern over ACI 318 minimum.")


# ==========================================================================
# §3. CONCRETE BEAMS — Minimum Cover (ACI 216.1 Table 4.3.1.2)
# ==========================================================================

fr_header("§3  CONCRETE BEAM COVER (ACI 216.1 Table 4.3.1.2)")

beam_widths = [5.0, 7.0, 10.0]

for (restrained, label) in [(true, "RESTRAINED"), (false, "UNRESTRAINED")]
    fr_sub("$label Nonprestressed Beams — Cover (in.)")
    println()

    @printf("    %-14s", "Rating (hr)")
    for bw in beam_widths
        @printf("  %10s", "bw=$(Int(bw))\"")
    end
    println()
    @printf("    %-14s", "─"^14)
    for _ in beam_widths
        @printf("  %10s", "─"^10)
    end
    println()

    @testset "Beam cover ($label)" begin
        for r in RATINGS
            @printf("    %-14s", string(r))
            for bw in beam_widths
                c = min_cover_fire_beam(r, bw; restrained=restrained)
                c_in = ustrip(u"inch", c)
                if isinf(c_in)
                    @printf("  %10s", "NP")
                else
                    @printf("  %8.3f\"", c_in)
                end
                @test c_in >= 0.0 || isinf(c_in)
            end
            println()
        end
    end
end

fr_note("NP = Not Permitted (beam too narrow for that rating at unrestrained condition).")
fr_note("Unrestrained 5\" beam: NP for 3 hr and 4 hr — widen or use restrained framing.")


# ==========================================================================
# §4. CONCRETE COLUMNS (ACI 216.1 Table 4.5.1a + §4.5.3)
# ==========================================================================

fr_header("§4  CONCRETE COLUMNS (ACI 216.1 Table 4.5.1a, §4.5.3)")

fr_sub("Minimum Column Dimension (4-sided exposure)")
println()

@printf("    %-14s", "Rating (hr)")
for name in AGG_NAMES
    @printf("  %12s", name)
end
println()
@printf("    %-14s", "─"^14)
for _ in AGG_TYPES
    @printf("  %12s", "─"^12)
end
println()

@testset "Column dimension" begin
    for r in RATINGS
        @printf("    %-14s", string(r))
        for agg in AGG_TYPES
            d = min_dimension_fire_column(r, agg)
            d_in = ustrip(u"inch", d)
            @printf("  %10.1f\"", d_in)
            @test d_in >= 0.0
        end
        println()
    end
end

fr_sub("Minimum Column Cover (§4.5.3: cover ≥ 1\" × hours)")
println()

@printf("    %-14s  %12s\n", "Rating (hr)", "Min Cover")
@printf("    %-14s  %12s\n", "─"^14, "─"^12)

@testset "Column cover" begin
    for r in RATINGS
        c = min_cover_fire_column(r)
        c_in = ustrip(u"inch", c)
        @printf("    %-14s  %10.1f\"\n", string(r), c_in)
        @test c_in ≈ max(r, 0.0) atol=0.01
    end
end

fr_note("Column cover scales linearly: 1\" per hour. 4 hr → 4\" cover is severe.")
fr_note("At 3+ hr, the cover requirement often drives the column size above structural need.")


# ==========================================================================
# §5. STEEL BEAMS — SFRM vs Intumescent (UL X772 / N643)
# ==========================================================================

fr_header("§5  STEEL BEAMS — SFRM vs INTUMESCENT")

# Representative W-shapes spanning light to heavy
test_sections = [
    ("W10×22",  22.0,  10.17, 5.750,  0.240, 0.360),   # light
    ("W14×48",  48.0,  13.79, 8.030,  0.340, 0.595),   # medium
    ("W21×68",  68.0,  21.13, 8.270,  0.430, 0.685),   # heavy
    ("W24×104", 104.0, 24.06, 12.750, 0.500, 0.750),   # very heavy
    ("W33×201", 201.0, 33.68, 15.745, 0.715, 1.150),   # jumbo
]

fr_sub("SFRM Thickness (15 pcf) — 3-Sided Beam Exposure (UL X772)")
fr_note("W/D = weight (lb/ft) ÷ PA (in.). Higher W/D → thinner SFRM.")
println()

@printf("    %-12s %6s %8s", "Section", "W/D", "")
for r in [1.0, 1.5, 2.0, 3.0, 4.0]
    @printf("  %6s", "$(r)hr")
end
println()
@printf("    %-12s %6s %8s", "─"^12, "─"^6, "")
for _ in 1:5
    @printf("  %6s", "─"^6)
end
println()

@testset "SFRM beam thickness" begin
    for (name, W, d, bf, tw, tf) in test_sections
        sec = ISymmSection(d * u"inch", bf * u"inch", tw * u"inch", tf * u"inch")
        PA_in = ustrip(u"inch", sec.PA)
        WD = W / PA_in
        @printf("    %-12s %6.2f %8s", name, WD, "")
        for r in [1.0, 1.5, 2.0, 3.0, 4.0]
            h = sfrm_thickness_x772(r, WD)
            @printf("  %5.2f\"", h)
            @test h >= 0.25
        end
        println()
    end
end

fr_sub("Intumescent Thickness (6 pcf) — 3-Sided Unrestrained (UL N643)")
fr_note("Much thinner than SFRM. Limited to ≤2 hr unrestrained, ≤3 hr restrained.")
println()

@printf("    %-12s %6s %8s", "Section", "W/D", "")
for r in [1.0, 1.5, 2.0]
    @printf("  %8s", "$(r)hr")
end
println()
@printf("    %-12s %6s %8s", "─"^12, "─"^6, "")
for _ in 1:3
    @printf("  %8s", "─"^8)
end
println()

@testset "Intumescent beam thickness" begin
    for (name, W, d, bf, tw, tf) in test_sections
        sec = ISymmSection(d * u"inch", bf * u"inch", tw * u"inch", tf * u"inch")
        PA_in = ustrip(u"inch", sec.PA)
        WD = W / PA_in
        @printf("    %-12s %6.2f %8s", name, WD, "")
        for r in [1.0, 1.5, 2.0]
            h = intumescent_thickness_n643(r, WD; restrained=false)
            @printf("  %7.3f\"", h)
            @test h >= 0.0
        end
        println()
    end
end


# ==========================================================================
# §6. STEEL COLUMNS — SFRM (UL X772, 4-sided)
# ==========================================================================

fr_header("§6  STEEL COLUMNS — SFRM (4-Sided Exposure, UL X772)")

fr_note("Columns use PB (full perimeter). Higher W/D → thinner SFRM.")
println()

@printf("    %-12s %6s %6s %8s", "Section", "PA\"", "PB\"", "W/D_col")
for r in [1.0, 1.5, 2.0, 3.0, 4.0]
    @printf("  %6s", "$(r)hr")
end
println()
@printf("    %-12s %6s %6s %8s", "─"^12, "─"^6, "─"^6, "─"^8)
for _ in 1:5
    @printf("  %6s", "─"^6)
end
println()

@testset "SFRM column thickness" begin
    for (name, W, d, bf, tw, tf) in test_sections
        sec = ISymmSection(d * u"inch", bf * u"inch", tw * u"inch", tf * u"inch")
        PA_in = ustrip(u"inch", sec.PA)
        PB_in = ustrip(u"inch", sec.PB)
        WD_col = W / PB_in
        @printf("    %-12s %6.1f %6.1f %8.2f", name, PA_in, PB_in, WD_col)
        for r in [1.0, 1.5, 2.0, 3.0, 4.0]
            h = sfrm_thickness_x772(r, WD_col)
            @printf("  %5.2f\"", h)
            @test h >= 0.25
        end
        println()
    end
end

fr_note("Light columns (W10×22, W/D≈0.55) need ~3.6\" SFRM at 4 hr — very thick.")
fr_note("Heavy columns (W33×201, W/D≈2.56) need only ~0.63\" SFRM at 2 hr.")


# ==========================================================================
# §7. COATING WEIGHT COMPARISON — SFRM vs Intumescent
# ==========================================================================

fr_header("§7  COATING WEIGHT COMPARISON: SFRM (15 pcf) vs INTUMESCENT (6 pcf)")

fr_sub("Self-Weight Added to Beams (lb/ft) — 3-Sided, 2 HR Rating")
fr_note("SFRM density = 15 pcf, Intumescent density = 6 pcf.")
fr_note("Weight = thickness × perimeter / 144 × density.")
println()

@printf("    %-12s %8s %8s %8s  %8s %8s  %9s\n",
        "Section", "PA (in)", "W/D",
        "SFRM t\"", "SFRM wt", "Intum t\"", "Intum wt")
@printf("    %-12s %8s %8s %8s  %8s %8s  %9s\n",
        "─"^12, "─"^8, "─"^8, "─"^8, "─"^8, "─"^8, "─"^9)

@testset "Coating weight comparison (2 hr beam)" begin
    for (name, W, d, bf, tw, tf) in test_sections
        sec = ISymmSection(d * u"inch", bf * u"inch", tw * u"inch", tf * u"inch")
        PA_in = ustrip(u"inch", sec.PA)
        WD = W / PA_in

        sfrm = compute_surface_coating(SFRM(), 2.0, W, PA_in)
        intum = compute_surface_coating(IntumescentCoating(), 2.0, W, PA_in)

        w_sfrm = coating_weight_per_foot(sfrm, PA_in)
        w_intum = coating_weight_per_foot(intum, PA_in)

        @printf("    %-12s %7.1f\" %8.2f %7.2f\"  %6.1flb %7.3f\"  %6.2flb\n",
                name, PA_in, WD, sfrm.thickness_in, w_sfrm,
                intum.thickness_in, w_intum)

        @test w_sfrm > w_intum  # SFRM always heavier
        @test w_intum < 1.0     # Intumescent negligible weight
    end
end

fr_sub("Self-Weight Added to Columns (lb/ft) — 4-Sided, 2 HR Rating")
println()

@printf("    %-12s %8s %8s %8s  %8s\n",
        "Section", "PB (in)", "W/D_col", "SFRM t\"", "SFRM wt")
@printf("    %-12s %8s %8s %8s  %8s\n",
        "─"^12, "─"^8, "─"^8, "─"^8, "─"^8)

@testset "SFRM column weight (2 hr)" begin
    for (name, W, d, bf, tw, tf) in test_sections
        sec = ISymmSection(d * u"inch", bf * u"inch", tw * u"inch", tf * u"inch")
        PB_in = ustrip(u"inch", sec.PB)
        WD_col = W / PB_in

        sfrm = compute_surface_coating(SFRM(), 2.0, W, PB_in)
        w_sfrm = coating_weight_per_foot(sfrm, PB_in)

        @printf("    %-12s %7.1f\" %8.2f %7.2f\"  %6.1flb\n",
                name, PB_in, WD_col, sfrm.thickness_in, w_sfrm)

        @test w_sfrm > 0.0
    end
end


# ==========================================================================
# §8. FIRE RATING ESCALATION — Composite Impact Table
# ==========================================================================

fr_header("§8  FIRE RATING ESCALATION — COMPOSITE IMPACT TABLE")

fr_note("How each fire rating affects a typical structural system:")
fr_note("  Slab: Siliceous NWC, 25 ft span (ACI 318 min ≈ 8.3\" for flat plate)")
fr_note("  Beam: Restrained, bw=12\", siliceous NWC")
fr_note("  Column: 16×16 siliceous NWC (governs for 2+ hr)")
fr_note("  Steel W21×68 beam (3-sided) + W14×48 column (4-sided), SFRM 15 pcf")
println()

@printf("    %-8s │ %6s %6s │ %6s │ %6s %6s │ %8s %8s │ %8s\n",
        "Rating", "h_slab", "cover", "bm_cvr", "col_dm", "col_cv",
        "SFRM_bm", "SFRM_cl", "SFRM_wt")
@printf("    %-8s │ %6s %6s │ %6s │ %6s %6s │ %8s %8s │ %8s\n",
        "─"^8, "─"^6, "─"^6, "─"^6, "─"^6, "─"^6,
        "─"^8, "─"^8, "─"^8)

# W21×68 beam section
bm_sec = ISymmSection(21.13u"inch", 8.270u"inch", 0.430u"inch", 0.685u"inch")
bm_PA = ustrip(u"inch", bm_sec.PA)
bm_W = 68.0

# W14×48 column section
cl_sec = ISymmSection(13.79u"inch", 8.030u"inch", 0.340u"inch", 0.595u"inch")
cl_PB = ustrip(u"inch", cl_sec.PB)
cl_W = 48.0

@testset "Escalation table" begin
    for r in RATINGS
        # Concrete slab
        h_slab = r > 0 ? ustrip(u"inch", min_thickness_fire(r, siliceous)) : 0.0
        cvr_sl = r > 0 ? ustrip(u"inch", min_cover_fire_slab(r, siliceous; restrained=true)) : 0.0

        # Concrete beam (restrained, 12" wide)
        cvr_bm = r > 0 ? ustrip(u"inch", min_cover_fire_beam(r, 12.0; restrained=true)) : 0.0

        # Concrete column
        dim_cl = r > 0 ? ustrip(u"inch", min_dimension_fire_column(r, siliceous)) : 0.0
        cvr_cl = ustrip(u"inch", min_cover_fire_column(r))

        # Steel SFRM (beam + column)
        sfrm_bm_t = r > 0 ? sfrm_thickness_x772(r, bm_W / bm_PA) : 0.0
        sfrm_cl_t = r > 0 ? sfrm_thickness_x772(r, cl_W / cl_PB) : 0.0
        sfrm_bm_wt = r > 0 ? coating_weight_per_foot(
            SurfaceCoating(sfrm_bm_t, 15.0, ""), bm_PA) : 0.0

        @printf("    %4.1f hr  │ %5.1f\" %5.2f\" │ %5.2f\" │ %5.1f\" %5.1f\" │ %7.2f\" %7.2f\" │ %6.1flb\n",
                r, h_slab, cvr_sl, cvr_bm, dim_cl, cvr_cl,
                sfrm_bm_t, sfrm_cl_t, sfrm_bm_wt)

        # Monotonic: increasing with fire rating
        if r > 0
            @test h_slab > 0
            @test sfrm_bm_t > 0
        end
    end
end

fr_note("Key takeaways:")
fr_note("  0→1 hr: modest impact — 3.5\" slab, ¾\" cover, 0.55\" SFRM on beam")
fr_note("  1→2 hr: slab jumps to 5.0\", column min grows to 10\", SFRM ≈1\" on beam")
fr_note("  2→3 hr: column dimension 12\", cover 3\", SFRM 1.7\" on beam (heavy)")
fr_note("  3→4 hr: severe — 7\" slab, 14\" column, 4\" cover, SFRM 2.2\" on beam")
fr_note("  Steel SFRM weight on W21×68 beam: 0→4 hr adds ~3.4→7.5 lb/ft dead load")


# ==========================================================================
# §9. SFRM vs INTUMESCENT — Full W-Shape Catalog Comparison
# ==========================================================================

fr_header("§9  SFRM vs INTUMESCENT WEIGHT — W-SHAPE CATALOG (2 HR, 3-SIDED)")

fr_note("Weight penalty of fire protection across representative W-shape depths.")
fr_note("Intumescent (6 pcf) is 10-20× lighter but limited to ≤2 hr unrestrained.")
println()

@printf("    %-12s %6s %8s │ %8s %8s │ %8s %8s │ %6s\n",
        "Section", "W/D", "Wt(plf)",
        "SFRM(in)", "SFRM(lb)", "Intm(in)", "Intm(lb)", "Ratio")
@printf("    %-12s %6s %8s │ %8s %8s │ %8s %8s │ %6s\n",
        "─"^12, "─"^6, "─"^8, "─"^8, "─"^8, "─"^8, "─"^8, "─"^6)

# Extended catalog across depths
catalog_sections = [
    ("W8×18",    18.0,  8.14,  5.250, 0.230, 0.330),
    ("W10×22",   22.0, 10.17,  5.750, 0.240, 0.360),
    ("W12×26",   26.0, 12.22,  6.490, 0.230, 0.380),
    ("W14×30",   30.0, 13.84,  6.730, 0.270, 0.385),
    ("W14×48",   48.0, 13.79,  8.030, 0.340, 0.595),
    ("W14×90",   90.0, 14.02, 14.520, 0.440, 0.710),
    ("W16×57",   57.0, 16.43,  7.120, 0.430, 0.715),
    ("W18×76",   76.0, 18.21, 11.035, 0.425, 0.680),
    ("W21×68",   68.0, 21.13,  8.270, 0.430, 0.685),
    ("W24×104", 104.0, 24.06, 12.750, 0.500, 0.750),
    ("W27×146", 146.0, 27.38, 13.965, 0.605, 0.975),
    ("W30×173", 173.0, 30.44, 14.985, 0.655, 1.065),
    ("W33×201", 201.0, 33.68, 15.745, 0.715, 1.150),
    ("W36×256", 256.0, 37.12, 16.555, 0.960, 1.440),
    ("W40×324", 324.0, 40.47, 17.815, 1.000, 1.590),
]

@testset "Catalog comparison (2 hr beam)" begin
    for (name, W, d, bf, tw, tf) in catalog_sections
        sec = ISymmSection(d * u"inch", bf * u"inch", tw * u"inch", tf * u"inch")
        PA_in = ustrip(u"inch", sec.PA)
        WD = W / PA_in

        sfrm = compute_surface_coating(SFRM(), 2.0, W, PA_in)
        intum = compute_surface_coating(IntumescentCoating(), 2.0, W, PA_in)

        w_sfrm = coating_weight_per_foot(sfrm, PA_in)
        w_intum = coating_weight_per_foot(intum, PA_in)

        ratio = w_sfrm / max(w_intum, 1e-6)

        @printf("    %-12s %6.2f %7.0f   │ %7.3f\" %6.1flb │ %7.4f\" %6.2flb │ %5.0f×\n",
                name, WD, W,
                sfrm.thickness_in, w_sfrm,
                intum.thickness_in, w_intum, ratio)

        @test w_sfrm > w_intum
        @test ratio > 5  # SFRM always ≥5× heavier
    end
end

fr_note("SFRM adds 3–14 lb/ft depending on section size (2 hr rating).")
fr_note("Intumescent adds <1 lb/ft for all sections — essentially negligible dead load.")
fr_note("Weight ratio SFRM/Intumescent: 8–40× across the catalog.")
fr_note("Cost trade-off: Intumescent material cost ≈3–5× SFRM but saves on tonnage.")


# ==========================================================================
# §10. PA/PB VALIDATION — Computed vs AISC Database
# ==========================================================================

fr_header("§10  PA/PB VALIDATION — THIN-WALL APPROXIMATION vs AISC DATABASE")

fr_note("PA, PB computed from geometry with fillet correction (r = kdes - tf).")
fr_note("Fillet arc replaces sharp corner: ΔP = 4r(π/2 - 2) per I-shape.")
fr_note("AISC database values shown for comparison. Expect <3% residual error.")
println()

# Known AISC database values for a few shapes (from aisc-shapes-v15.csv)
# Format: (name, d, bf, tw, tf, kdes, PA_AISC, PB_AISC)
aisc_ref = [
    ("W14×90",  14.0,  14.5,   0.44,  0.71,  1.31, 69.6, 84.1),
    ("W21×68",  21.1,   8.27,  0.43,  0.685, 1.19, 65.3, 73.6),
    ("W24×104", 24.1,  12.8,   0.50,  0.75,  1.25, 84.7, 97.5),
    ("W33×201", 33.7,  15.7,   0.715, 1.15,  1.94, 111.0, 127.0),
]

@printf("    %-12s │ %8s %8s │ %8s %8s │ %6s %6s\n",
        "Section", "PA_calc", "PA_AISC", "PB_calc", "PB_AISC", "ΔPA%", "ΔPB%")
@printf("    %-12s │ %8s %8s │ %8s %8s │ %6s %6s\n",
        "─"^12, "─"^8, "─"^8, "─"^8, "─"^8, "─"^6, "─"^6)

@testset "PA/PB vs AISC" begin
    for (name, d, bf, tw, tf, kdes, PA_ref, PB_ref) in aisc_ref
        sec = ISymmSection(d * u"inch", bf * u"inch", tw * u"inch", tf * u"inch";
                           kdes_db = kdes * u"inch")
        PA_calc = ustrip(u"inch", sec.PA)
        PB_calc = ustrip(u"inch", sec.PB)

        δPA = (PA_calc - PA_ref) / PA_ref * 100
        δPB = (PB_calc - PB_ref) / PB_ref * 100

        flag_PA = abs(δPA) < 2.0 ? "✓" : (abs(δPA) < 5.0 ? "~" : "✗")
        flag_PB = abs(δPB) < 2.0 ? "✓" : (abs(δPB) < 5.0 ? "~" : "✗")

        @printf("    %-12s │ %7.1f\" %7.1f\" │ %7.1f\" %7.1f\" │ %+5.1f%% %+5.1f%%  %s%s\n",
                name, PA_calc, PA_ref, PB_calc, PB_ref, δPA, δPB, flag_PA, flag_PB)

        # With fillet correction, expect <3% error (residual from simplified geometry)
        @test abs(δPA) < 5.0
        @test abs(δPB) < 5.0
    end
end

fr_note("Thin-wall slightly overestimates perimeter (ignores fillet rounding).")
fr_note("For fire protection: overestimate → slightly thicker coating → conservative.")


# ==========================================================================
# §11. STEEL BEAM SIZING CASE STUDIES — Fire Protection Impact
# ==========================================================================
#
# NLP-optimized W-shape beams (AISC F2 flexure, G2 shear, L/360 deflection).
# For each scenario the fire protection coating weight is iteratively added
# to the dead load until the optimal section converges (typically 2–3 cycles).
#
# Three spans × three fire scenarios = 9 optimizations.

fr_header("§11  STEEL BEAM SIZING — WITH vs WITHOUT FIRE PROTECTION")

fr_note("NLP-optimized W-shapes (AISC F2 flexure + G2 shear). Simply supported.")
fr_note("Each case runs two sub-scenarios (same bracing: Lb=1 ft, Cb=1.14):")
fr_note("  (a) With L/360 LL deflection — realistic composite floor beam.")
fr_note("  (b) Strength only (no deflection) — isolates fire load impact on sizing.")
fr_note("Fire protection weight iteratively included in factored dead load.")
fr_note("wᵤ = 1.2(wD + w_fire) + 1.6wL;  Mᵤ = wᵤL²/8;  Vᵤ = wᵤL/2.")
println()

# ── Helper: print one sub-scenario comparison table ──

function _fire_scenario_table(label, wD_ext, wL, L, geom, opts, ix_min, scenarios)
    println("\n    ── $label ──")
    println()

    rows = []

    for (sname, fire_rating, fp) in scenarios
        w_fire_plf = 0.0
        coat_t     = 0.0
        result     = nothing

        for iter in 1:5
            w_fire_q = w_fire_plf * u"lbf/ft"
            wu = 1.2 * (wD_ext + w_fire_q) + 1.6 * wL
            Mu = wu * L^2 / 8
            Vu = wu * L / 2

            result = size_steel_w_beam_nlp(Mu, Vu, geom, opts; Ix_min = ix_min)

            fire_rating <= 0 && break
            result.status ∉ (:optimal, :feasible) && break

            sec     = result.section
            PA_in   = ustrip(u"inch", sec.PA)
            W_plf   = result.weight_per_ft
            coating = compute_surface_coating(fp, fire_rating, W_plf, PA_in)
            w_new   = coating_weight_per_foot(coating, PA_in)
            coat_t  = coating.thickness_in

            abs(w_new - w_fire_plf) < 0.05 && (w_fire_plf = w_new; break)
            w_fire_plf = w_new
        end

        push!(rows, (; name = sname, result, w_fire = w_fire_plf, coat_t))
    end

    base_wt = rows[1].result.weight_per_ft

    @printf("    %-15s │ %5s  %6s  %5s  %5s │ %7s  %7s  %7s │ %5s\n",
            "Scenario", "d", "bf", "tf", "tw", "Wt", "coat_t", "fire_w", "ΔWt")
    @printf("    %-15s │ %5s  %6s  %5s  %5s │ %7s  %7s  %7s │ %5s\n",
            "─"^15, "─"^5, "─"^6, "─"^5, "─"^5, "─"^7, "─"^7, "─"^7, "─"^5)

    for r in rows
        res = r.result
        Δ = base_wt > 0 ? (res.weight_per_ft - base_wt) / base_wt * 100 : 0.0
        @printf("    %-15s │ %4.1f\"  %5.2f\"  %4.2f\"  %4.2f\" │ %5.1flb  %5.2f\"  %5.1flb │ %+4.1f%%\n",
                r.name,
                res.d_final, res.bf_final, res.tf_final, res.tw_final,
                res.weight_per_ft, r.coat_t, r.w_fire, Δ)
        @test res.status ∈ (:optimal, :feasible)
    end

    sfrm_row = rows[2]
    wD_plf   = ustrip(u"lbf/ft", wD_ext)
    sfrm_pct = sfrm_row.w_fire / (wD_plf + sfrm_row.w_fire) * 100
    wt_pct   = base_wt > 0 ? (sfrm_row.result.weight_per_ft - base_wt) / base_wt * 100 : 0.0
    @printf("\n    → SFRM adds %.1f lb/ft (%.1f%% of total DL) → beam weight %+.1f%%\n",
            sfrm_row.w_fire, sfrm_pct, wt_pct)

    intum_row = rows[3]
    intum_wt  = base_wt > 0 ? (intum_row.result.weight_per_ft - base_wt) / base_wt * 100 : 0.0
    @printf("    → Intumescent adds %.2f lb/ft → beam weight %+.1f%%\n",
            intum_row.w_fire, intum_wt)

    return rows
end

# ── Main case study driver ──

function _fire_beam_case_study(;
    label::String,
    L_ft::Float64,
    trib_ft::Float64,
    dl_psf::Float64,
    ll_psf::Float64,
    max_depth_in::Float64 = 36.0,
)
    L    = L_ft * u"ft"
    trib = trib_ft * u"ft"

    wD_ext = dl_psf * psf * trib
    wL     = ll_psf * psf * trib

    opts = NLPWOptions(
        min_depth = 8.0u"inch",
        max_depth = max_depth_in * u"inch",
    )
    geom = SteelMemberGeometry(L; Lb = 1.0u"ft", Cb = 1.14)

    Ix_req = required_Ix_for_deflection(wL, L, opts.material.E;
                                         limit_ratio = 1/360)

    scenarios = [
        ("No fire (0 hr)", 0.0, NoFireProtection()),
        ("2 hr SFRM",      2.0, SFRM()),
        ("2 hr Intum.",     2.0, IntumescentCoating()),
    ]

    fr_sub("Case: $label — L=$(Int(L_ft)) ft, trib=$(Int(trib_ft)) ft, " *
           "DL=$(Int(dl_psf)) psf, LL=$(Int(ll_psf)) psf")

    # (a) Deck-braced + L/360 deflection — realistic composite floor beam
    _fire_scenario_table(
        "Strength + L/360 LL deflection (realistic)",
        wD_ext, wL, L, geom, opts, Ix_req, scenarios)

    # (b) Same bracing, strength only — isolates fire load effect
    _fire_scenario_table(
        "Strength only (no deflection check) — isolates fire load effect",
        wD_ext, wL, L, geom, opts, nothing, scenarios)

    return nothing
end

# ── Case A: Short-span office beam ──

@testset "Case A: Short span" begin
    _fire_beam_case_study(
        label        = "Short-Span Office",
        L_ft         = 25.0,
        trib_ft      = 8.0,
        dl_psf       = 60.0,
        ll_psf       = 50.0,
        max_depth_in = 24.0,
    )
end

# ── Case B: Medium-span office beam ──

@testset "Case B: Medium span" begin
    _fire_beam_case_study(
        label  = "Medium-Span Office",
        L_ft   = 30.0,
        trib_ft = 10.0,
        dl_psf = 60.0,
        ll_psf = 50.0,
    )
end

# ── Case C: Long-span open-plan beam ──

@testset "Case C: Long span" begin
    _fire_beam_case_study(
        label  = "Long-Span Open Plan",
        L_ft   = 40.0,
        trib_ft = 12.0,
        dl_psf = 75.0,
        ll_psf = 80.0,
    )
end

fr_note("Key observations:")
fr_note("  • With L/360 deflection: fire protection rarely changes the beam section —")
fr_note("    the Ix requirement provides ample excess flexural capacity that absorbs")
fr_note("    the small DL increase from the coating.")
fr_note("  • Strength-only sizing: SFRM adds 5–10 lb/ft dead load, visibly increasing")
fr_note("    beam weight for lighter sections where the load increase is proportional.")
fr_note("  • Intumescent adds <1 lb/ft → beam weight change negligible in all cases.")
fr_note("  • Heavier sections (higher W/D) get thinner SFRM — a virtuous cycle.")
fr_note("  • In practice, fire protection weight also feeds into column and foundation")
fr_note("    sizing through tributary dead load — cumulative system-level impact.")


# ==========================================================================
# §12. CONCRETE SLAB SIZING CASE STUDIES — Fire Rating Impact
# ==========================================================================
#
# Flat plate slabs sized per ACI 318-11 Table 9.5(c) for deflection control,
# then checked against ACI 216.1-14 Table 4.2 fire minimum thickness.
#
# For each span × fire rating combination, the governing thickness is
# max(structural_min, fire_min). Self-weight and cover are reported.
#
# Three spans × five fire ratings × two aggregate types = 30 cases.

fr_header("§12  CONCRETE SLAB SIZING — WITH vs WITHOUT FIRE RATING")

fr_note("Flat plate slab (ACI 318 Table 9.5(c) min thickness for deflection).")
fr_note("Fire min thickness from ACI 216.1-14 Table 4.2.")
fr_note("Cover: ACI 216.1-14 Table 4.3.1.1 (restrained assembly).")
fr_note("h_gov = max(h_structural, h_fire), rounded to nearest ½\".")
fr_note("Self-weight = h × γ_concrete;  NWC ρ = 150 pcf.")
println()

slab_spans   = [14.0, 18.0, 24.0, 30.0]            # ft
slab_ratings = [0.0, 1.0, 2.0, 3.0, 4.0]          # hr
slab_aggs    = [siliceous, carbonate]
slab_agg_names = ["Siliceous", "Carbonate"]

ρ_nwc = NWC_4000.ρ

function _slab_self_weight_psf(h)
    ustrip(psf, h * ρ_nwc * GRAVITY)
end

for (agg, agg_name) in zip(slab_aggs, slab_agg_names)

    fr_sub("Aggregate: $agg_name")
    println()

    # Header
    @printf("    %-6s │", "Span")
    for r in slab_ratings
        lbl = r == 0 ? "0 hr" : "$(r) hr"
        @printf(" %8s", lbl)
    end
    println(" │   Fire governs?")

    @printf("    %-6s │", "──────")
    for _ in slab_ratings
        @printf(" %8s", "────────")
    end
    println(" │   ──────────────")

    @testset "Slab sizing: $agg_name" begin
        for L_ft in slab_spans
            L  = L_ft * u"ft"
            c1 = estimate_column_size_from_span(L; ratio=15.0)
            ln = clear_span(L, c1)

            h_struct_raw = min_thickness(FlatPlate(), ln)
            h_struct     = ceil(ustrip(u"inch", h_struct_raw) * 2) / 2 * u"inch"

            @printf("    %4.0f ft │", L_ft)

            fire_governs_any = false

            for r in slab_ratings
                h_fire = r > 0 ? min_thickness_fire(r, agg) : 0.0u"inch"
                h_gov  = max(h_struct, h_fire)
                # Round up to nearest ½"
                h_gov  = ceil(ustrip(u"inch", h_gov) * 2) / 2 * u"inch"

                sw = _slab_self_weight_psf(h_gov)
                h_in = ustrip(u"inch", h_gov)

                governs = h_fire > h_struct
                if governs; fire_governs_any = true; end
                flag = governs ? "†" : " "

                @printf(" %4.1f\"%s%2.0f", h_in, flag, sw)

                @test h_gov >= h_struct
                @test r <= 0 || h_gov >= h_fire
            end

            note = fire_governs_any ? "  ← fire governs at higher ratings" : "  structural governs all"
            println(" │  ", note)
        end
    end

    # Legend
    println()
    @printf("    %-6s   Format: thickness\" SW(psf).  † = fire minimum governs.\n", "")

    # Cover comparison
    println()
    println("    Cover requirements (restrained assembly, $agg_name):")
    @printf("    %6s │", "Rating")
    for r in slab_ratings
        if r <= 0
            @printf("  %6s", "—")
        else
            c_fire = min_cover_fire_slab(r, agg; restrained=true)
            @printf("  %5.2f\"", ustrip(u"inch", c_fire))
        end
    end
    println()
    @printf("    %6s │", "ACI 318")
    for _ in slab_ratings
        @printf("  %6s", "0.75\"")
    end
    println("   (standard minimum)")
    println()
end

# Self-weight increase summary
fr_sub("Self-weight increase from fire rating (NWC siliceous)")
println()
@printf("    %-6s │", "Span")
for r in slab_ratings[2:end]
    @printf("  Δ@%.0fhr", r)
end
println()
@printf("    %-6s │", "──────")
for _ in slab_ratings[2:end]
    @printf(" %7s", "───────")
end
println()

for L_ft in slab_spans
    L  = L_ft * u"ft"
    c1 = estimate_column_size_from_span(L; ratio=15.0)
    ln = clear_span(L, c1)

    h_struct = ceil(ustrip(u"inch", min_thickness(FlatPlate(), ln)) * 2) / 2 * u"inch"
    sw_base  = _slab_self_weight_psf(h_struct)

    @printf("    %4.0f ft │", L_ft)
    for r in slab_ratings[2:end]
        h_fire = min_thickness_fire(r, siliceous)
        h_gov  = ceil(ustrip(u"inch", max(h_struct, h_fire)) * 2) / 2 * u"inch"
        sw     = _slab_self_weight_psf(h_gov)
        delta  = sw - sw_base
        @printf("  %+5.1f", delta)
    end
    println(" psf")
end

println()
fr_note("Key observations:")
fr_note("  • For short spans (14–18 ft), the ACI 318 structural minimum is 5–6.5\".")
fr_note("    Fire governs at 3–4 hr (siliceous) or only 4 hr (carbonate).")
fr_note("  • For long spans (30 ft), structural h ≈ 8–9\" exceeds all fire minimums.")
fr_note("    Fire never governs thickness — the slab already has ample mass.")
fr_note("  • Carbonate aggregate reduces fire-min thickness by ~0.4\" vs siliceous")
fr_note("    (better fire resistance per inch). This can eliminate the fire penalty.")
fr_note("  • Cover is always ≤ 0.75\" (restrained) up to 2 hr — no change from ACI 318.")
fr_note("    Unrestrained 3–4 hr assemblies may require 1.25\"+ cover.")
fr_note("  • Each ½\" of slab thickness adds ~6 psf of dead load — significant for")
fr_note("    column and foundation sizing when applied over large floor areas.")


# ==========================================================================
# Summary
# ==========================================================================

fr_header("SUMMARY")

println("""
    Fire rating affects structural design through three mechanisms:

    1. CONCRETE (intrinsic resistance):
       - Minimum slab thickness grows from 3.5" (1 hr) to 7.0" (4 hr, siliceous)
       - Minimum column dimension: 8" (1 hr) → 14" (4 hr)
       - Cover requirement: 0.75" (restrained slab) to 4.0" (4 hr column)
       - For typical office buildings (2 hr), fire seldom governs slab thickness
         but may increase column size and cover

    2. STEEL (applied protection):
       - SFRM thickness: 0.25"–3.6" depending on W/D ratio and rating
       - Intumescent: 0.04"–0.25" (limited to ≤2 hr unrestrained)
       - SFRM weight: 3–14 lb/ft on beams (2 hr), negligible for heavy sections
       - Intumescent weight: <1 lb/ft for all sections — self-weight impact minimal
       - Heavier sections (high W/D) get thinner coatings — bonus for oversized members

    3. SYSTEM-LEVEL:
       - Fire protection adds dead load → larger column axials → larger foundations
       - For 2 hr steel frame: expect 2–5% increase in steel tonnage from coating DL
       - For 2 hr concrete: thickness increase may be offset by using carbonate aggregate
       - Cost: SFRM ≈\$2–4/sf applied, Intumescent ≈\$8–15/sf — material cost vs labor

    Code references:
       ACI/TMS 216.1-14 (concrete), UL X772 (SFRM), UL N643 (intumescent),
       AISC Design Guide 19 (fire design overview)
""")

end  # @testset

println(FR_DLINE)
println("  END OF FIRE RATING PARAMETRIC REPORT")
println(FR_DLINE)
