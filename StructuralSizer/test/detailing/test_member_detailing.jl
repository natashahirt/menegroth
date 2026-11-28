# ==============================================================================
# Bar placement of slabs, beams, columns, and footings against hand calculations
# ==============================================================================
#
# Every expected length below is worked by hand in inches from ACI 318-19:
# hooks Table 25.3.1, development Table 25.4.2.3 and Eq. 25.4.3.1(a), laps
# Table 25.5.2.1 and §25.5.5.1, and the member chapters cited in each testset.
# ==============================================================================

using Test
using Unitful
using StructuralSizer

_in(x) = ustrip(u"inch", x)

"""Centerline length of a 90-degree hook in inches: bend arc plus 12d_b tail."""
_hook90(db) = π / 2 * (6db + db) / 2 + 12db

"""Groups of a detail with a given role whose note contains `key`."""
_groups(md, role, key = "") = [g for g in md.groups if g.role === role && occursin(key, g.note)]

"Catalog area of one bar, in²."
_ab(size) = ustrip(u"inch^2", bar_area(size))

"Cross-sectional area of every bar in the groups, in². Each bar is counted once."
_group_as(groups) = sum(g -> g.count * _ab(g.bar_size), groups; init = 0.0)

"Takeoff mass of the groups, from the catalog weight and the centerline length."
_mass(groups) = sum(g -> bar_set_mass(bar_set(g)), groups; init = 0.0u"kg")

"Mass of `As` in² of bar `size` running `run`, at the catalog weight."
_smeared_mass(As, run, size) = (As / _ab(size)) * bar_set_mass(BarSet(size, 1, run))

"Area of `role` bars whose centerline spans elevation `z`, in²."
function _as_at(md, role, z)
    total = 0.0
    for g in md.groups
        g.role === role || continue
        zs = [p[2] for p in g.path]
        isempty(zs) && continue
        minimum(zs) - 1e-8 <= z <= maximum(zs) + 1e-8 || continue
        total += g.count * _ab(g.bar_size)
    end
    return total
end

@testset "Member detailing" begin

    @testset "stock_splices" begin
        n, L = stock_splices(30.0u"m", 18.288u"m", 1.0u"m")
        @test n == 1                                   # ⌈(30 − 18.288)/(18.288 − 1)⌉
        @test ustrip(u"m", L) ≈ 31.0
        n0, L0 = stock_splices(10.0u"m", 18.288u"m", 1.0u"m")
        @test n0 == 0 && ustrip(u"m", L0) ≈ 10.0
        @test_throws ArgumentError stock_splices(30.0u"m", 1.0u"m", 1.0u"m")
    end

    @testset "column_tie_spacing (§25.7.2.1)" begin
        # #8 bars, #3 ties, 16 in. column: min(16, 18, 16) = 16 in.
        @test _in(column_tie_spacing(8, 3, 16.0u"inch")) ≈ 16.0
        # #10 bars, #4 ties, 24 in.: min(16·1.27, 48·0.5, 24) = 20.32 in.
        @test _in(column_tie_spacing(10, 4, 24.0u"inch")) ≈ 20.32
    end

    # ── Flat plate, two 20 ft clear spans on 20 in. columns ────────────────
    # h = 8 in., cover 0.75 in., #5, f′c = 4000 psi, fy = 60 ksi.
    # d_top = 8 − 0.75 − 0.3125 = 6.9375 in., 5d = 34.69 in.
    # ℓd (favorable row, #5): 60000/(25·√4000)·0.625 = 23.72 in.
    # Column strip: e_long = max(0.30·240, 34.69, 23.72) = 72, e_rem = max(48, 23.72) = 48.
    # Middle strip: e = max(0.22·240, 23.72) = 52.8.
    @testset "flat plate line (Fig. 8.7.4.1.3)" begin
        cs = StripLayout(StripBars(5, 8), StripBars(5, 6), StripBars(5, 10), 120.0u"inch")
        ms = StripLayout(StripBars(5, 4), StripBars(5, 6), StripBars(5, 6), 120.0u"inch")
        common = (clear_spans = [240.0u"inch", 240.0u"inch"],
                  supports = fill(20.0u"inch", 3), column_strip = cs, middle_strip = ms,
                  h = 8.0u"inch", cover = 0.75u"inch",
                  fc = 4000.0u"psi", fy = 60_000.0u"psi")
        md = detail_flat_plate_line(; common...)
        hook = _hook90(0.625)

        @test isempty(md.warnings)          # ℓdh = 14.8 in. ≤ 19.25 in. at the edge

        ext_long = _groups(md, :top, "column strip, exterior support, long")
        @test length(ext_long) == 2
        @test all(g -> g.count == 4, ext_long)
        @test all(g -> _in(g.length) ≈ 20 + 72 - 0.75 + hook, ext_long)
        @test all(g -> g.shape in (:hook_start, :hook_end), ext_long)

        ext_rem = [g for g in _groups(md, :top, "column strip, exterior support")
                   if !occursin("long", g.note)]
        @test all(g -> g.count == 4 && _in(g.length) ≈ 20 + 48 - 0.75 + hook, ext_rem)

        int_long = only(_groups(md, :top, "column strip, interior support, long"))
        @test int_long.count == 5
        @test _in(int_long.length) ≈ 20 + 2 * 72
        int_rem = only([g for g in _groups(md, :top, "column strip, interior support")
                        if !occursin("long", g.note)])
        @test int_rem.count == 5 && _in(int_rem.length) ≈ 20 + 2 * 48

        # Two integrity bars from edge to edge less cover, hooked both ends.
        integ = only(_groups(md, :integrity))
        @test integ.count == 2 && integ.laps == 0 && integ.shape === :hook_both
        @test _in(integ.length) ≈ 540 - 1.5 + 2hook
        # Remaining 4 column-strip bottom bars, 6 in. into each exterior column.
        cs_bot = only(_groups(md, :bottom, "continuous"))
        @test cs_bot.count == 4 && _in(cs_bot.length) ≈ 526 - 14

        ms_ext = _groups(md, :top, "middle strip, exterior support")
        @test all(g -> g.count == 4 && _in(g.length) ≈ 20 + 52.8 - 0.75 + hook, ms_ext)
        @test all(g -> isempty(g.centerlines) || length(g.centerlines) == g.count, md.groups)
        @test all(w -> abs(_in(w[1][2] * u"m")) <= 60, int_long.centerlines)
        @test all(w -> 60 <= abs(_in(w[1][2] * u"m")) <= 120, ms_ext[1].centerlines)
        ms_int = only(_groups(md, :top, "middle strip, interior support"))
        @test ms_int.count == 6 && _in(ms_int.length) ≈ 20 + 2 * 52.8

        # Middle-strip bottom: 3 bars per span into the supports, 3 cut back
        # 0.15ℓn = 36 in. from each support centerline.
        ms_full = _groups(md, :bottom, "into supports")
        @test length(ms_full) == 2 && all(g -> g.count == 3 && _in(g.length) ≈ 262, ms_full)
        ms_cut = _groups(md, :bottom, "cutback")
        @test length(ms_cut) == 2 && all(g -> g.count == 3 && _in(g.length) ≈ 260 - 72, ms_cut)

        # Bar count across the line matches the strip designs.
        @test sum(g.count for g in md.groups if g.role === :top) == 2 * (8 + 4) + 10 + 6

        # No required area was passed, so each section reports its bar area as both.
        ab5 = ustrip(u"inch^2", bar_area(5))
        @test md.areas["primary_column_extneg_placed_in2"] ≈ 8 * ab5
        @test md.areas["primary_column_extneg_ideal_in2"] ≈ 8 * ab5
        @test md.areas["primary_column_pos_placed_in2"] ≈ 6 * ab5
        @test md.areas["primary_middle_intneg_placed_in2"] ≈ 6 * ab5
        @test any(n -> occursin("in² placed", n), md.notes)

        # A stated required area is the ideal; a short count is warned.
        asked = StripLayout(StripBars(5, 8, 2.0), StripBars(5, 6, 1.5), StripBars(5, 10, 2.5),
                            120.0u"inch")
        short = StripLayout(StripBars(5, 2, 5.0), StripBars(5, 0), StripBars(5, 0), 120.0u"inch")
        none = StripLayout(StripBars(5, 0), StripBars(5, 0), StripBars(5, 0), 120.0u"inch")
        mda = detail_flat_plate_line(; common..., column_strip = asked, middle_strip = ms)
        @test mda.areas["primary_column_extneg_ideal_in2"] ≈ 2.0
        @test mda.areas["primary_column_extneg_placed_in2"] ≈ 8 * ab5
        @test mda.areas["primary_column_extneg_placed_in2"] > mda.areas["primary_column_extneg_ideal_in2"]
        mds = detail_flat_plate_line(; common..., column_strip = short, middle_strip = none)
        @test mds.areas["primary_column_extneg_ideal_in2"] ≈ 5.0
        @test mds.areas["primary_column_extneg_placed_in2"] ≈ 2 * ab5
        @test any(w -> occursin("placed area", w), mds.warnings)

        # n_lines multiplies counts; mass is the sum of the groups.
        md3 = detail_flat_plate_line(; common..., n_lines = 3)
        @test [g.count for g in md3.groups] == 3 .* [g.count for g in md.groups]
        @test md3.areas["primary_column_extneg_placed_in2"] ≈ 3 * 8 * ab5
        @test md3.areas["primary_column_extneg_ideal_in2"] ≈ 3 * 8 * ab5
        @test ustrip(u"kg", detail_mass(md3)) ≈ 3 * ustrip(u"kg", detail_mass(md))
        @test ustrip(u"kg", detail_mass(md)) ≈
              sum(ustrip(u"kg", bar_set_mass(bar_set(g))) for g in md.groups)
        @test length(bar_schedule(md)) == length(md.groups)

        # Drop panels: 0.33ℓn = 79.2 in.
        mdd = detail_flat_plate_line(; common..., drop_panel = true)
        @test _in(only(_groups(mdd, :top, "column strip, interior support, long")).length) ≈
              20 + 2 * 79.2

        # 20 ft stock: integrity run 538.5 in., Class B lap (other-cases row)
        # 1.3 · 3·60000/(50·√4000)·0.625 = 46.25 in., ⌈298.5/193.75⌉ = 2 laps.
        mds = detail_flat_plate_line(; common..., stock = 20.0u"ft")
        integ_s = only(_groups(mds, :integrity))
        lapB = 1.3 * 3 * 60_000 / (50 * sqrt(4000)) * 0.625
        @test integ_s.laps == 2
        @test _in(integ_s.length) ≈ 538.5 + 2hook + 2lapB

        # A 12 in. column leaves 11.25 in. for a 14.8 in. hook: flagged.
        mdn = detail_flat_plate_line(; common..., supports = fill(12.0u"inch", 3))
        @test any(w -> occursin("ℓdh", w), mdn.warnings)

        @test_throws ArgumentError detail_flat_plate_line(; common..., supports = fill(20.0u"inch", 2))

        # Column-strip bars stay inside the strip; middle-strip bars sit outside it.
        @test all(g -> length(g.centerlines) == g.count, md.groups)
        col_y = [abs(_in(w[1][2] * u"m")) for g in md.groups if occursin("column strip", g.note) for w in g.centerlines]
        mid_y = [abs(_in(w[1][2] * u"m")) for g in md.groups if occursin("middle strip", g.note) for w in g.centerlines]
        @test all(y -> y <= 60, col_y)
        @test all(y -> 60 < y <= 120, mid_y)

        # Integrity bars inside the column core (§13.3.8.5). Six #5 bars spread
        # over 120 − 0.625 in. are 23.875 in. apart, the middle two at ±11.94 in.;
        # a 7.5 in. core half-width (20 in. column, bar centres 2.5 in. in)
        # moves the pair to ±(7.5 − 0.3125) in.
        integ_y(md) = sort([_in(w[1][2] * u"m") for w in only(_groups(md, :integrity)).centerlines])
        @test integ_y(md) ≈ [-11.9375, 11.9375]
        mdc = detail_flat_plate_line(; common..., core_half_width = 7.5u"inch")
        @test integ_y(mdc) ≈ [-7.1875, 7.1875]
        @test isempty(mdc.warnings)
        @test _group_as(_groups(mdc, :integrity)) + _group_as(_groups(mdc, :bottom, "continuous")) ≈
              _group_as(_groups(md, :integrity)) + _group_as(_groups(md, :bottom, "continuous"))
        # A core too narrow for two #5 bars at 1 in. clear is flagged.
        mdn2 = detail_flat_plate_line(; common..., core_half_width = 1.0u"inch")
        @test any(w -> occursin("integrity bars", w), mdn2.warnings)

        sec = RCColumnSection(b = 20.0u"inch", h = 16.0u"inch", bar_size = 8, n_bars = 8,
                              cover = 1.5u"inch", tie_bar_size = 4)
        col = (base = (section = sec,), θ = 0.0)
        # Bar centres 1.5 + 0.5 + 0.5 = 2.5 in. inside each face.
        @test _in(StructuralSizer._integrity_core_half(col, (1.0, 0.0))) ≈ 7.5
        @test _in(StructuralSizer._integrity_core_half(col, (0.0, 1.0))) ≈ 5.5
        @test StructuralSizer._integrity_core_half((base = (section = nothing,),), (1.0, 0.0)) === nothing
    end

    # ── Beam, 12 × 24 in., 4 #8 bottom, #3 stirrups, 30 ft c/c on 20 in. columns
    @testset "beam (§9.7)" begin
        sec = RCBeamSection(; b = 12.0u"inch", h = 24.0u"inch", bar_size = 8, n_bars = 4,
                            cover = 1.5u"inch", stirrup_size = 3)
        d = _in(sec.d)
        mats = (fc = 4000.0u"psi", fy = 60_000.0u"psi", fyt = 60_000.0u"psi")
        md = detail_beam(sec; span = 360.0u"inch", supports = (20.0u"inch", 20.0u"inch"),
                         exterior = (true, true), Vu = 40.0u"kip", mats...)
        hook8, hook4 = _hook90(1.0), _hook90(0.5)

        # ℓd (#8, favorable) = 60000/(20·√4000) = 47.4 in. > 18.5 in. → hooked;
        # ℓdh = 60000·1.6·1.25·0.867/(55·√4000) = 29.9 in. > 18.5 in. → warning.
        integ = only(_groups(md, :integrity))
        @test integ.count == 2                                  # max(2, ⌈4/4⌉)
        @test integ.shape === :hook_both
        @test _in(integ.length) ≈ 380 - 3 + 2hook8
        bot = only(_groups(md, :bottom))
        iy = [w[1][2] for w in integ.centerlines]
        by = [w[1][2] for w in bot.centerlines]
        @test length(unique(round.([iy; by]; digits = 6))) == 4
        @test bot.count == 2 && _in(bot.length) ≈ 377 + 2hook8
        @test any(w -> occursin("bottom bars at exterior support", w), md.warnings)

        hang = only(_groups(md, :hanger))
        @test hang.bar_size == 4 && hang.count == 2
        @test _in(hang.length) ≈ 377 + 2hook4

        # Stirrups. Vc = 2√f′c·b·d; Vs = Vu/0.75 − Vc; s_req = Av·fyt·d/Vs.
        # Vs ≤ 4√f′c·b·d → s_max = min(d/2, 24); Av/s_min = max(0.75√f′c, 50)·b/fyt.
        Vc = 2 * sqrt(4000) * 12 * d
        Vs = 40_000 / 0.75 - Vc
        s_gov = min(0.22 * 60_000 * d / Vs, d / 2, 0.22 / (max(0.75 * sqrt(4000), 50) * 12 / 60_000))
        s = floor(2s_gov) / 2
        st = only(_groups(md, :stirrup))
        @test _in(st.length) ≈ 2 * (12 - 3 - 0.375 + 24 - 3 - 0.375) +
                               2 * (3π / 4 * (4 * 0.375 + 0.375) / 2 + 3.0)
        @test st.count == ceil(Int, (358 - 22) / s - 1e-9) + 1
        @test length(st.centerlines) == st.count
        @test all(w -> length(w) >= 5 && w[1] == w[end], st.centerlines)
        @test first(st.x_positions) ≈ ustrip(u"m", 22.0u"inch")
        @test last(st.x_positions) ≈ ustrip(u"m", 358.0u"inch")
        @test maximum(diff(st.x_positions)) <= ustrip(u"m", s * u"inch") + 1e-9

        # Drawing outline: beam over both supports, then the two supports.
        @test length(md.outline) == 3
        @test collect(_in.(md.outline[1] .* u"m")) ≈ [0, 380, 0, 24] atol = 1e-9
        @test collect(_in.(md.outline[2] .* u"m")) ≈ [0, 20, -24, 0] atol = 1e-9
        @test collect(_in.(md.outline[3] .* u"m")) ≈ [360, 380, -24, 0] atol = 1e-9

        # Interior beam: 2 bars lap half a Class B lap past each centerline
        # (1.3 · 47.4 = 61.7 in.), the rest stop 6 in. into the supports.
        mdi = detail_beam(sec; span = 360.0u"inch", supports = (20.0u"inch", 20.0u"inch"),
                          exterior = (false, false), Vu = 40.0u"kip", mats...,
                          top_bars = (7, 3))
        lapB = 1.3 * 60_000 / (20 * sqrt(4000))
        @test _in(only(_groups(mdi, :integrity)).length) ≈ 360 + lapB
        @test _in(only(_groups(mdi, :bottom)).length) ≈ 352
        top = only(_groups(mdi, :top))
        @test top.bar_size == 7 && top.count == 3 && top.shape === :straight
        @test isempty(mdi.warnings)
        # The beam is drawn as far as the lapped bars run, plus cover. The #7 top
        # bars run farthest: ℓd = 60000·1.3(ψt)/(20·√4000)·0.875 in., Class B
        # lap 1.3ℓd, half of it past each centerline.
        half_top = 1.3 * 1.3 * 60_000 / (20 * sqrt(4000)) * 0.875 / 2
        @test collect(_in.(mdi.outline[1] .* u"m")) ≈ [10 - half_top - 1.5, 370 + half_top + 1.5, 0, 24]

        # Section As against the bars placed. Hangers are not required, so their
        # ideal area is zero. Stirrup area is one two-leg Av, not the whole run.
        @test md.areas["bottom_placed_in2"] ≈ 4 * ustrip(u"inch^2", bar_area(8))
        @test md.areas["bottom_ideal_in2"] ≈ md.areas["bottom_placed_in2"]
        @test md.areas["top_ideal_in2"] == 0.0
        @test md.areas["top_placed_in2"] ≈ 2 * ustrip(u"inch^2", bar_area(4))
        @test md.areas["stirrup_placed_in2"] ≈ 2 * ustrip(u"inch^2", bar_area(3))
        @test md.areas["stirrup_ideal_in2"] ≈ md.areas["stirrup_placed_in2"]
        @test mdi.areas["top_placed_in2"] ≈ 3 * ustrip(u"inch^2", bar_area(7))
        @test mdi.areas["top_ideal_in2"] ≈ mdi.areas["top_placed_in2"]
        @test any(n -> occursin("in² placed", n) && occursin("section As", n), md.notes)

        st = only(_groups(md, :stirrup))
        @test length(st.centerlines) == st.count
        @test all(w -> length(w) >= 5 && w[1] == w[end], st.centerlines)
        places = sort([w[1][2] for w in integ.centerlines])
        append!(places, (w[1][2] for w in bot.centerlines))
        @test length(unique(round.(places; digits = 6))) == integ.count + bot.count
    end

    # ── Columns, 12 ft story under an 8 in. slab ───────────────────────────
    @testset "column (§10.7, §25.7)" begin
        mats = (fc = 4000.0u"psi", fy = 60_000.0u"psi")
        sec = RCColumnSection(; b = 16.0u"inch", h = 16.0u"inch", bar_size = 8, n_bars = 8,
                              cover = 1.5u"inch", tie_bar_size = 3)
        md = detail_column(sec; height = 144.0u"inch", slab_above = 8.0u"inch", mats...)

        # Lap = max(compression 0.0005·60000·1 = 30, Class B 1.3·47.4 = 61.7) in.
        long = only(_groups(md, :longitudinal))
        @test long.count == 8
        @test _in(long.length) ≈ 144 + 1.3 * 60_000 / (20 * sqrt(4000))
        @test md.areas["longitudinal_placed_in2"] ≈ ustrip(u"inch^2", sec.As_total)
        @test md.areas["longitudinal_ideal_in2"] ≈ md.areas["longitudinal_placed_in2"]

        # Ties at 16 in. from 8 in. to 136.75 − 8 = 128.75 in.: ⌈120.75/16⌉ + 1 = 9.
        ties = only(_groups(md, :tie))
        @test ties.count == 9 && ties.bar_size == 3
        @test length(long.centerlines) == length(section_rebar_positions(sec))
        @test all(zip(long.centerlines, section_rebar_positions(sec))) do (w, p)
            w[1][2] ≈ p[1] && w[1][3] ≈ p[2]
        end
        @test length(ties.centerlines) == ties.count
        @test all(w -> length(w) >= 5 && w[1] == w[end], ties.centerlines)
        @test length(long.centerlines) == long.count
        @test all(zip(long.centerlines, section_rebar_positions(sec))) do (wire, p)
            wire[1][2] ≈ p[1] && wire[1][3] ≈ p[2]
        end
        @test length(ties.centerlines) == ties.count
        @test all(wire -> length(wire) >= 5 && wire[1] == wire[end], ties.centerlines)
        # A shear spacing inside §25.7.2.1 closes the ties up. It does not
        # space them farther than that clause.
        tight = detail_column(sec; height = 144.0u"inch", slab_above = 8.0u"inch",
                              tie_spacing = 6.0u"inch", mats...)
        tight_ties = only(_groups(tight, :tie))
        @test tight_ties.count > ties.count
        @test occursin("10.7.6.5.2", tight_ties.note)
        loose = detail_column(sec; height = 144.0u"inch", slab_above = 8.0u"inch",
                              tie_spacing = 24.0u"inch", mats...)
        @test only(_groups(loose, :tie)).count == ties.count
        @test _in(ties.length) ≈ 4 * (16 - 3 - 0.375) + 2 * (3π / 4 * (4 * 0.375 + 0.375) / 2 + 3.0)
        # Middle face bars sit 5.625 − 1 = 4.6 in. clear from the corners: no crossties.
        @test isempty(_groups(md, :crosstie))
        # Outline: column to the slab soffit, the slab, the column above to the lap end.
        @test length(md.outline) == 3
        @test collect(_in.(md.outline[1] .* u"m")) ≈ [0, 136, -8, 8]
        @test collect(_in.(md.outline[2] .* u"m")) ≈ [136, 144, -24, 24]
        @test collect(_in.(md.outline[3] .* u"m")) ≈ [144, 144 + 1.3 * 60_000 / (20 * sqrt(4000)) + 1.5, -8, 8]

        # Roof: 90-degree hook into the slab; ℓdc = 23.7 in. > 7.25 in. is flagged.
        roof = detail_column(sec; height = 144.0u"inch", slab_above = 8.0u"inch",
                             continues = false, mats...)
        r = only(_groups(roof, :longitudinal))
        @test r.shape === :hook_end
        @test _in(r.length) ≈ 144 - 0.75 - 0.5 + _hook90(1.0)
        @test any(w -> occursin("ℓdc", w), roof.warnings)
        @test length(roof.outline) == 2

        # 24 in. column with 12 #8 bars (4 per face): every alternate bar needs
        # support, so one crosstie each way per tie set.
        big = RCColumnSection(; b = 24.0u"inch", h = 24.0u"inch", bar_size = 8, n_bars = 12,
                              cover = 1.5u"inch", tie_bar_size = 3)
        mdb = detail_column(big; height = 144.0u"inch", slab_above = 8.0u"inch", mats...)
        nt = only(_groups(mdb, :tie)).count
        cts = _groups(mdb, :crosstie)
        @test length(cts) == 2
        @test all(g -> g.count == nt, cts)
        @test length(long.centerlines) == 8
        @test all(zip(long.centerlines, section_rebar_positions(sec))) do (wire, p)
            wire[1][2] ≈ p[1] && wire[1][3] ≈ p[2]
        end
        @test length(ties.centerlines) == ties.count
        @test all(wire -> length(wire) >= 5 && wire[1] == wire[end], ties.centerlines)
        @test all(g -> length(g.centerlines) == g.count, cts)

        # Spiral, D = 20 in.: ρs = 0.45(400/289 − 1)·4000/60000 = 0.01152,
        # #3 pitch s = 4·0.11/(17·ρs) = 2.246 in., 1.871 in. clear.
        circ = RCCircularSection(; D = 20.0u"inch", bar_size = 8, n_bars = 8, cover = 1.5u"inch")
        mdc = detail_column(circ; height = 144.0u"inch", slab_above = 8.0u"inch", mats...)
        sp = only(_groups(mdc, :spiral))
        ρs = 0.45 * (400 / 289 - 1) * 4000 / 60_000
        s = 4 * 0.11 / (17 * ρs)
        @test sp.bar_size == 3
        turns = 136.75 / s + 3
        @test _in(sp.length) ≈ turns * sqrt((π * (17 - 0.375))^2 + s^2) rtol = 1e-6
    end

    # ── Footings ────────────────────────────────────────────────────────────
    @testset "spread footing (§13.3.3, §16.3.4)" begin
        mats = (fc = 3000.0u"psi", fy = 60_000.0u"psi")
        # 8 ft square, 10 #6 each way under a 16 in. column. ℓd (favorable)
        # = 60000/(25·√3000)·0.75 = 32.9 in. ≤ (96 − 16)/2 − 3 = 37 in. → straight.
        md = detail_spread_footing(; B = 96.0u"inch", L = 96.0u"inch", D = 30.0u"inch",
                                   bar_size = 6, n_bars = 10,
                                   column = (16.0u"inch", 16.0u"inch"),
                                   column_bars = (8, 8), column_Ag = 256.0u"inch^2",
                                   column_lap = 30.0u"inch", mats...)
        F = _groups(md, :bottom)
        @test length(F) == 2
        @test all(g -> g.count == 10 && g.shape === :straight && _in(g.length) ≈ 90, F)
        # Dowels seat on the mat: 30 − (3 + 1.5 + 0.5) = 25 in. ≥ ℓdc = 21.9 in.
        dow = only(_groups(md, :dowel))
        @test dow.count == 8
        @test _in(dow.length) ≈ 25 + 30 + _hook90(1.0)
        @test isempty(md.warnings)
        ab6 = ustrip(u"inch^2", bar_area(6))
        @test md.areas["long_placed_in2"] ≈ 10 * ab6
        @test md.areas["long_ideal_in2"] ≈ md.areas["long_placed_in2"]
        @test md.areas["short_placed_in2"] ≈ 10 * ab6
        @test md.areas["short_ideal_in2"] ≈ md.areas["short_placed_in2"]
        @test md.areas["dowel_placed_in2"] ≈ 8 * ustrip(u"inch^2", bar_area(8))
        @test md.areas["dowel_ideal_in2"] ≈ md.areas["dowel_placed_in2"]
        # Outline: footing, then the column stub to the dowel ends (30 + 30 + 3 in.).
        @test collect(_in.(md.outline[1] .* u"m")) ≈ [0, 96, 0, 30]
        @test collect(_in.(md.outline[2] .* u"m")) ≈ [40, 56, 30, 63]

        # 24 in. thick: 19 in. of embedment < 21.9 in. is flagged.
        thin = detail_spread_footing(; B = 96.0u"inch", L = 96.0u"inch", D = 24.0u"inch",
                                     bar_size = 6, n_bars = 10,
                                     column = (16.0u"inch", 16.0u"inch"),
                                     column_bars = (8, 8), mats...)
        @test any(w -> occursin("ℓdc", w), thin.warnings)

        # 8 × 12 ft: β = 1.5, γs = 0.8, so 8 of 10 short bars in the band.
        rect = detail_spread_footing(; B = 96.0u"inch", L = 144.0u"inch", D = 30.0u"inch",
                                     bar_size = 6, n_bars = 10,
                                     column = (16.0u"inch", 16.0u"inch"), mats...)
        short = [g for g in rect.groups if g.direction === :short]
        @test sort([g.count for g in short]) == [2, 8]
        band = only(g for g in short if occursin("central band", g.note) && !occursin("outside", g.note))
        outside = only(g for g in short if occursin("outside", g.note))
        gap(g) = begin
            xs = sort([_in(w[1][1] * u"m") for w in g.centerlines])
            minimum(diff(xs))
        end
        @test gap(band) < gap(outside)
        @test _in(only(g for g in rect.groups if g.direction === :long).length) ≈ 138
        @test rect.areas["short_placed_in2"] ≈ 10 * ustrip(u"inch^2", bar_area(6))
        @test rect.areas["short_ideal_in2"] ≈ rect.areas["short_placed_in2"]
        @test rect.areas["long_placed_in2"] ≈ 10 * ustrip(u"inch^2", bar_area(6))
        band = only(g for g in short if occursin("central band", g.note) && !occursin("outside", g.note))
        outside = only(g for g in short if occursin("outside", g.note))
        gap(g) = minimum(diff(sort([_in(w[1][1] * u"m") for w in g.centerlines])))
        @test gap(band) < gap(outside)
    end
end

# The mat drawing uses the same bar count as the steel volume.
# ACI 318-11 §7.6.5 (corpus: aci-318-11, page 96).
@testset "mat bars match the steel-volume count" begin
    B, L, D = 10.0u"m", 10.0u"m", 24.0u"inch"
    cover = 3.0u"inch"
    Asx, Asy = 0.01u"m^2", 0.03u"m^2"
    opts = (bar_size_x = 8, bar_size_y = 8, cover = cover)
    bars = StructuralSizer.mat_flexure_bar_counts(B, L, D, Asx, Asx, Asy, Asy, opts)
    md = detail_mat(; B, L, D, cover, bar_size_x = 8, bar_size_y = 8,
                    As_x_bot = Asx, As_x_top = Asx, As_y_bot = Asy, As_y_top = Asy)
    counts = Dict(g.mark => g.count for g in md.groups)
    @test counts["MXB"] == bars.n_xb
    @test counts["MXT"] == bars.n_xt
    @test counts["MYB"] == bars.n_yb
    @test counts["MYT"] == bars.n_yt
    @test all(g -> length(g.centerlines) == g.count, md.groups)
    @test md.solid == (0.0, ustrip(u"m", L), 0.0, ustrip(u"m", B), 0.0, ustrip(u"m", D))
end

# ACI 318-19 §11.7 (corpus: aci-318-19, pp. 173–174) and §18.10.2 (p. 320).
# 12 in. wall, ρ = 0.0025, two curtains, #4: s = 2·0.20/(0.0025·12) = 13.33 in.,
# rounded down to the 0.5 in. step is 13 in., under min(3h, 18 in.) = 18 in.
@testset "wall bars" begin
    fc = 4000.0u"psi"
    fy = 60_000.0u"psi"
    common = (fc = fc, fy = fy, slab_above = 8.0u"inch")

    @testset "12 in. wall, #4 at 13 in." begin
        Ab = ustrip(u"inch^2", bar_area(4))
        s = floor(Int, 2 * Ab / (0.0025 * 12) / 0.5 + 1e-9) * 0.5
        @test s == 13.0
        md = detail_wall(; length = 20.0u"ft", height = 12.0u"ft", thickness = 12.0u"inch",
                         ρl = 0.0025, ρt = 0.0025, foundation_depth = 24.0u"inch", common...)
        @test any(n -> occursin("two layers", n), md.notes)
        v = only(_groups(md, :vertical, "full"))
        @test v.bar_size == 4 && v.count == 2 * length(v.x_positions)
        xs = sort(v.x_positions)
        @test length(xs) == 20
        @test maximum(diff(xs)) ≤ ustrip(u"m", 13.0u"inch") + 1e-9
        db = ustrip(u"m", bar_diameter(4))
        edge = ustrip(u"m", 0.75u"inch") + db / 2
        @test xs[1] ≈ edge && xs[end] ≈ ustrip(u"m", 20.0u"ft") - edge
        h = only(_groups(md, :horizontal))
        @test h.bar_size == 4 && h.shape === :hook_both
        zs = sort(h.z_positions)
        @test length(zs) == 11
        @test zs[1] ≈ ustrip(u"m", 6.5u"inch")
        @test maximum(diff(zs)) ≤ ustrip(u"m", 13.0u"inch") + 1e-9
        @test length(md.section_dots) == v.count
        @test md.outline[1][2] ≈ ustrip(u"m", 20.0u"ft")
        @test isempty(filter(w -> occursin("unchecked", w), md.warnings))

        # The flexure model uses Ast = ρl·ℓw·h (wall_axial_flexure_capacity_si).
        # Shear uses the same ρt·h per unit height. Placed area is the bar count
        # times the catalog area. The takeoff then multiplies by the centerline,
        # so hooks and dowels add mass without adding section area.
        As_l = 0.0025 * (20 * 12) * 12          # 7.20 in²
        As_t = 0.0025 * (12 * 12) * 12          # 4.32 in²
        @test _group_as([v]) ≈ 40 * 0.20
        @test _group_as([v]) / As_l ≈ 8.0 / 7.2
        @test _group_as([h]) ≈ 22 * 0.20
        @test _group_as([h]) / As_t ≈ 4.4 / 4.32
        smear_v = _smeared_mass(As_l, 12.0u"ft", 4)
        smear_h = _smeared_mass(As_t, 20.0u"ft", 4)
        @test _mass([v]) / smear_v ≈ (8.0 / 7.2) * (_in(v.length) / 144)
        @test _mass([h]) / smear_h ≈ (4.4 / 4.32) * (_in(h.length) / 240)
        dow = _groups(md, :dowel)
        @test _mass(dow) > 0.0u"kg"
        @test _group_as(dow) == _group_as([v])   # one dowel per vertical bar, not more area in the wall
        # Reported areas: the ratio, and one bar per station. Dowels stay out of it.
        @test md.areas["vertical_ideal_in2"] ≈ 7.2
        @test md.areas["vertical_placed_in2"] ≈ 8.0
        @test md.areas["horizontal_ideal_in2"] ≈ 4.32
        @test md.areas["horizontal_placed_in2"] ≈ 4.4
        @test any(n -> occursin("8.0 in² placed", n) && occursin("7.2 in²", n), md.notes)
        @test any(n -> occursin("4.4 in² placed", n) && occursin("4.32 in²", n), md.notes)
        @test !any(w -> occursin("below", w), md.warnings)
    end

    @testset "8 in. wall is one layer" begin
        md = detail_wall(; length = 20.0u"ft", height = 12.0u"ft", thickness = 8.0u"inch",
                         ρl = 0.0025, ρt = 0.0025, common...)
        @test any(n -> occursin("one layer", n), md.notes)
        v = only(_groups(md, :vertical, "full"))
        @test v.count == length(v.x_positions)
        # One curtain, #4 at 10 in.: 25 bars × 0.20 in² against ρ·ℓw·h = 4.80 in².
        @test _group_as([v]) ≈ 25 * 0.20
        @test _group_as([v]) / (0.0025 * (20 * 12) * 8) ≈ 5.0 / 4.8
        @test md.areas["vertical_placed_in2"] ≈ 5.0
        @test md.areas["vertical_ideal_in2"] ≈ 4.8
        @test any(w -> occursin("unchecked", w), md.warnings)
    end

    @testset "shear cap ℓw/5" begin
        md = detail_wall(; length = 60.0u"inch", height = 12.0u"ft", thickness = 12.0u"inch",
                         ρl = 0.0025, ρt = 0.0025, Vu = 5000.0u"kip", common...)
        @test any(n -> occursin("horizontal", n) && occursin("12.0", n), md.notes)
        @test any(n -> occursin("vertical", n) && occursin("13.0", n), md.notes)
    end

    @testset "opening trim and interrupted bars" begin
        md = detail_wall(; length = 20.0u"ft", height = 12.0u"ft", thickness = 12.0u"inch",
                         ρl = 0.0025, ρt = 0.0025,
                         openings = [(6.0u"ft", 0.0u"inch", 3.0u"ft", 7.0u"ft")], common...)
        @test length(md.voids) == 1
        @test !isempty(_groups(md, :vertical, "interrupted"))
        trim = _groups(md, :trim)
        @test length(trim) == 4
        @test all(g -> g.bar_size == 5 && g.count == 2, trim)
        ld = straight_development_length(5, fc, fy, 1.0; ψt = 1.3,
                                         favorable_cover = 0.75u"inch" >= bar_diameter(5))
        hook = hook_centerline_length(5; angle = 90)
        left = only(_groups(md, :trim, "left"))
        @test _in(left.length) ≈ _in(7.0u"ft") + _in(ld) + _in(hook)
        @test any(w -> occursin("lintel", w), md.warnings)
        # Every station still has one vertical bar, so the piece area matches the
        # solid wall. A cut through the door does not: those bars stop at the head.
        # Trim is added beside the opening and is not a substitute for them.
        pieces = _group_as(_groups(md, :vertical))
        @test pieces ≈ 40 * 0.20
        above = _as_at(md, :vertical, ustrip(u"m", 11.0u"ft"))
        through = _as_at(md, :vertical, ustrip(u"m", 3.0u"ft"))
        @test above ≈ pieces
        @test through < 0.0025 * (20 * 12) * 12
        @test through ≈ pieces - 3 * 2 * 0.20
        @test _group_as(trim) ≈ 8 * 0.31
        # The reported area keeps every station, so it still meets the gross ratio.
        @test md.areas["vertical_placed_in2"] ≈ 8.0
        @test md.areas["vertical_placed_in2"] > md.areas["vertical_ideal_in2"]
        @test !any(w -> occursin("placed area", w), md.warnings)
        # A door has no bar under the head, so no dowel is cut short there.
        @test !any(w -> occursin("sill", w), md.warnings)
    end

    @testset "dowel stops at a sill" begin
        md = detail_wall(; length = 20.0u"ft", height = 12.0u"ft", thickness = 12.0u"inch",
                         ρl = 0.0025, ρt = 0.0025,
                         openings = [(6.0u"ft", 2.0u"ft", 4.0u"ft", 4.0u"ft")], common...)
        sill = ustrip(u"m", 2.0u"ft")
        x0, x1 = ustrip(u"m", 6.0u"ft"), ustrip(u"m", 10.0u"ft")
        under = [g for g in _groups(md, :dowel) if any(x -> x0 < x < x1, g.x_positions)]
        beside = [g for g in _groups(md, :dowel) if any(x -> x < x0 || x > x1, g.x_positions)]
        @test !isempty(under)
        @test all(g -> maximum(p -> p[2], g.path) ≤ sill + 1e-6, under)
        @test any(g -> maximum(p -> p[2], g.path) > sill + 1e-3, beside)
        @test any(w -> occursin("sill", w), md.warnings)
        head = sill + ustrip(u"m", 4.0u"ft")
        crossed = false
        for g in md.groups
            shifts = !isempty(g.x_positions) ? [(x, 0.0) for x in g.x_positions] :
                     !isempty(g.z_positions) ? [(0.0, z) for z in g.z_positions] : [(0.0, 0.0)]
            for (dx, dz) in shifts
                moved = [(p[1] + dx, p[2] + dz) for p in g.path]
                for i in 1:(length(moved) - 1)
                    p, q = moved[i], moved[i + 1]
                    for t in 0.05:0.05:0.95
                        x = p[1] + t * (q[1] - p[1])
                        z = p[2] + t * (q[2] - p[2])
                        crossed |= x0 + 1e-4 < x < x1 - 1e-4 && sill + 1e-4 < z < head - 1e-4
                    end
                end
            end
        end
        @test !crossed
    end

    @testset "joined end laps, special curtains" begin
        md = detail_wall(; length = 20.0u"ft", height = 12.0u"ft", thickness = 12.0u"inch",
                         ρl = 0.0025, ρt = 0.0025, ends = (:joined, :free), common...)
        h = only(_groups(md, :horizontal))
        @test occursin("corner lap", h.note)
        @test h.path[1][1] < 0
        thin = detail_wall(; length = 8.0u"ft", height = 12.0u"ft", thickness = 8.0u"inch",
                           ρl = 0.0015, ρt = 0.0015, special = true, hw = 20.0u"ft",
                           Vu = 1.0u"kip", common...)
        @test any(n -> occursin("two layers", n), thin.notes)
        @test any(n -> occursin("raised to 0.0025", n), thin.notes)
    end

    @testset "boundary hoops are not invented" begin
        # §18.10.6.4 needs the neutral-axis depth. §18.7.5.2(a)–(d) does not
        # fix one crosstie arrangement. The web curtain is placed either way.
        # ρl = 0.01 is above 400/fy at Grade 60, so the tie warning is on,
        # and still no tie group appears.
        md = detail_wall(; length = 20.0u"ft", height = 12.0u"ft", thickness = 12.0u"inch",
                         ρl = 0.01, ρt = 0.0025, special = true, hw = 20.0u"ft",
                         Vu = 200.0u"kip", foundation_depth = 24.0u"inch", common...)
        roles = Set(g.role for g in md.groups)
        @test roles ⊆ Set([:vertical, :horizontal, :dowel, :trim])
        @test :vertical in roles && :horizontal in roles
        @test any(n -> occursin("boundary bars are not placed", n), md.notes)
        @test any(w -> occursin("18.10.6.5(b)", w), md.warnings)
        ordinary = detail_wall(; length = 20.0u"ft", height = 12.0u"ft",
                               thickness = 12.0u"inch", ρl = 0.01, ρt = 0.0025,
                               foundation_depth = 24.0u"inch", common...)
        @test !any(w -> occursin("18.10.6", w), ordinary.warnings)
        @test !any(n -> occursin("boundary bars are not placed", n), ordinary.notes)
        @test Set(g.role for g in ordinary.groups) ⊆ Set([:vertical, :horizontal, :dowel, :trim])

        # A known §18.10.6.4 length places hoops at both ends. 30 in. is
        # longer than twice the 12 in. thickness, so the hoops overlap.
        zoned = detail_wall(; length = 20.0u"ft", height = 12.0u"ft", thickness = 12.0u"inch",
                            ρl = 0.01, ρt = 0.0025, special = true, hw = 20.0u"ft",
                            Vu = 200.0u"kip", foundation_depth = 24.0u"inch",
                            boundary_zones = [(zone = 30.0u"inch", bar = 5, spacing = 6.0u"inch")],
                            critical_reach = 20.0u"ft", common...)
        hoops = [g for g in zoned.groups if g.role === :tie]
        @test length(hoops) == 1
        @test hoops[1].shape === :closed_tie
        @test hoops[1].count == length(hoops[1].centerlines)
        @test hoops[1].count > 4
        @test any(g -> g.role === :crosstie, zoned.groups)
        @test !any(n -> occursin("boundary bars are not placed", n), zoned.notes)
    end
end

@testset "Solid-head piece top bars" begin
    # 0.30 m deep: under 12 in. of concrete below the top bars, so ψt = 1.
    kw = (length = 1.5u"m", width = 0.9u"m", depth = 0.30u"m", d = 0.26u"m",
          cover = 0.75u"inch", fc = 4000.0u"psi", fy = 60_000.0u"psi")
    Mu = 120.0u"kN*m"
    # A face end runs ℓd into the rib; a continuous end half a Class B lap.
    md = StructuralSizer.detail_solid_head_piece(; kw..., Mu_neg = Mu,
                                                 ends = (:face, :continuous))
    g = only(md.groups)
    @test md.kind == :slab
    @test g.role == :top && g.direction == :primary && g.shape == :straight
    @test length(g.centerlines) == g.count
    bs, n = StructuralSizer._hogging_bars(Mu, kw.width, kw.d, kw.fc, kw.fy)
    @test g.bar_size == bs && g.count == n
    lam = StructuralSizer._detailing_λ(1.0)
    ℓd = StructuralSizer.straight_development_length(bs, kw.fc, kw.fy, lam;
        ψt = 1.0, coating = :uncoated, epoxy_close = true, favorable_cover = false)
    lap = StructuralSizer.tension_lap_length(bs, kw.fc, kw.fy, lam; as_ratio = 1.0,
        percent_spliced = 100.0, ψt = 1.0, coating = :uncoated, epoxy_close = true,
        favorable_cover = false)
    @test isapprox(g.length, kw.length + ℓd + lap / 2; rtol = 1e-9)
    @test any(n -> occursin("13.3.7", n), md.notes)
    @test isempty(md.warnings)
    # An exterior end is hooked; no moment places no bars.
    ext = StructuralSizer.detail_solid_head_piece(; kw..., Mu_neg = Mu,
                                                  ends = (:exterior, :face))
    @test only(ext.groups).shape == :hook_start
    none = StructuralSizer.detail_solid_head_piece(; kw..., Mu_neg = nothing,
                                                   ends = (:face, :face))
    @test isempty(none.groups)
    @test_throws ArgumentError StructuralSizer.detail_solid_head_piece(; kw...,
        Mu_neg = Mu, ends = (:face, :column))

    @testset "Edge-line bars stay on the slab" begin
        cs = StripLayout(StripBars(5, 8), StripBars(5, 6), StripBars(5, 10), 120.0u"inch")
        ms = StripLayout(StripBars(5, 4), StripBars(5, 6), StripBars(5, 6), 120.0u"inch")
        common = (clear_spans = [240.0u"inch", 240.0u"inch"],
                  supports = fill(20.0u"inch", 3), column_strip = cs, middle_strip = ms,
                  h = 8.0u"inch", cover = 0.75u"inch",
                  fc = 4000.0u"psi", fy = 60_000.0u"psi")
        ys(md) = [w[1][2] for g in md.groups for w in g.centerlines if !isempty(w)]
        full = detail_flat_plate_line(; common...)
        @test any(<(0), ys(full)) && any(>(0), ys(full))
        edge = detail_flat_plate_line(; common..., band = (0.0, ustrip(u"m", 240.0u"inch")))
        @test all(y -> -1e-8 <= y <= ustrip(u"m", 240.0u"inch") + 1e-6, ys(edge))
        wide = detail_flat_plate_line(; common..., band = (0.0, ustrip(u"m", 360.0u"inch")))
        @test maximum(ys(wide)) > maximum(ys(edge)) + 0.2
        @test minimum(ys(wide)) >= -1e-8
        # A second placement of the same band does not move a bar.
        again = detail_flat_plate_line(; common..., band = (0.0, ustrip(u"m", 240.0u"inch")))
        @test ys(again) == ys(edge)

        n0 = sum(g.count for g in full.groups)
        StructuralSizer._omit_bars_off_slab!(full, p -> p[2] >= 0.0)
        @test sum(g.count for g in full.groups) < n0
        @test all(p -> p[2] >= -1e-9, (p for g in full.groups for w in g.centerlines for p in w))
        @test any(occursin("outside the slab", w) for w in full.warnings)
        kept = sum(g.count for g in full.groups)
        StructuralSizer._omit_bars_off_slab!(full, p -> p[2] >= 0.0)
        @test sum(g.count for g in full.groups) == kept
    end

    @testset "Rebar takeoff is the placed bars" begin
        function strips(n_neg, n_pos; size = 5)
            ab = bar_area(size)
            neg = StripReinforcement(:int_neg, 50.0u"kN*m", n_neg * ab, ab, n_neg * ab,
                                     size, 6.0u"inch", n_neg, true)
            pos = StripReinforcement(:pos, 30.0u"kN*m", n_pos * ab, ab, n_pos * ab,
                                     size, 8.0u"inch", n_pos, true)
            ext = StripReinforcement(:ext_neg, 20.0u"kN*m", ab, ab, ab,
                                     size, 12.0u"inch", 1, true)
            return [neg, pos, ext]
        end
        function panel(l1, n_neg, n_pos)
            return FlatPlatePanelResult(
                l1, 14.0u"ft", 8.0u"inch", 100.0u"kN*m", 9.0u"kN/m^2",
                7.0u"ft", strips(n_neg, n_pos), 7.0u"ft", strips(max(1, n_neg ÷ 2), n_pos),
                (ok = true, max_ratio = 0.5, details = Dict()),
                (ok = true, Δ_total = 0.25u"inch", Δ_limit = 0.9u"inch", ratio = 0.3))
        end
        short = panel(18.0u"ft", 10, 6)
        placed = 2 * StructuralSizer._direction_placed_volume(
            short.column_strip_reinf, short.middle_strip_reinf,
            short.column_strip_width, short.middle_strip_width, short.l1, short.thickness)
        @test volume_per_area(short, :steel) * short.l1 * short.l2 ≈ placed
        # Every section over the full span, the previous takeoff, is more steel.
        smeared = 0.0u"m^3"
        for sr in vcat(short.column_strip_reinf, short.middle_strip_reinf)
            smeared += uconvert(u"m^2", sr.As_provided) * short.l1
        end
        @test placed < 2 * 1.10 * smeared
        heavy = panel(18.0u"ft", 20, 12)
        @test volume_per_area(heavy, :steel) > volume_per_area(short, :steel) * 1.8
        long = panel(30.0u"ft", 10, 6)
        @test volume_per_area(long, :steel) * long.l1 * long.l2 >
              volume_per_area(short, :steel) * short.l1 * short.l2
        again = panel(18.0u"ft", 10, 6)
        @test volume_per_area(again, :steel) ≈ volume_per_area(short, :steel)
    end

    # ── Gravity column outside the seismic system, SDC D–F ────────────────
    @testset "gravity column and joint (§18.14.3.3)" begin
        mats = (fc = 4000.0u"psi", fy = 60_000.0u"psi", fyt = 60_000.0u"psi")
        sec = RCColumnSection(; b = 16.0u"inch", h = 16.0u"inch", bar_size = 8, n_bars = 8,
                              cover = 1.5u"inch", tie_bar_size = 3)
        height = 120.0u"inch"
        slab = 8.0u"inch"
        md = detail_column(sec; height = height, slab_above = slab, mats...,
                           gravity_seismic = true)
        clear = ustrip(u"m", height - slab)
        lap = only(_groups(md, :longitudinal, "center half"))
        @test lap.path[1][1] ≈ clear / 4
        partner = only(_groups(md, :longitudinal, "story below"))
        @test partner.path[1][1] ≈ lap.path[1][1]
        @test partner.path[end][1] <= 3 * clear / 4 + 1e-6
        @test length(lap.centerlines) == lap.count
        ends = _groups(md, :tie, "18.7.5.3")
        @test length(ends) == 2
        mid = only(_groups(md, :tie, "18.7.5.5"))
        joint = only(_groups(md, :tie, "18.4.4.4"))
        @test joint.count >= 2
        for g in vcat(ends, [mid, joint])
            @test length(g.centerlines) == g.count
            @test all(w -> length(w) >= 4, g.centerlines)
        end
        # ℓo is the clear height over six, 18.67 in., and §18.7.5.3(a) is 4 in.
        bottom = ends[1].x_positions
        @test bottom[1] ≈ 0.0
        @test bottom[end] ≈ ustrip(u"m", special_column_hoop_length(16.0u"inch", clear * u"m"))
        @test maximum(diff(bottom)) <= ustrip(u"m", 4.0u"inch") + 1e-6
        ordinary = detail_column(sec; height = height, slab_above = slab, mats...)
        @test isempty(_groups(ordinary, :tie, "18.7.5.3"))
        tight = detail_column(sec; height = height, slab_above = slab, mats...,
                              gravity_seismic = true, tie_spacing = 2.0u"inch")
        tight_bottom = _groups(tight, :tie, "18.7.5.3")[1].x_positions
        @test maximum(diff(tight_bottom)) <= ustrip(u"m", 2.0u"inch") + 1e-6

        # §18.7.6: probable moment at 1.25 fy, then the shear, then the hoops.
        mpr = special_column_probable_moments(sec, RC_4000_60)
        at_fy = maximum(get_nominal_curve(generate_PM_diagram(sec, RC_4000_60)).Mn)
        @test ustrip(u"kip*ft", mpr.strong) > at_fy
        clear_in = ustrip(u"inch", height - slab)
        low = special_column_shear_design(sec, RC_4000_60, clear_in * u"inch";
                                          axials = (0.0u"kip",))
        @test low.concrete_omitted
        @test low.Ve_y ≈ 2 * low.Mpr_strong / (clear_in * u"inch")
        at_cut = 16.0u"inch" * 16.0u"inch" * 4000.0u"psi" / 20
        high = special_column_shear_design(sec, RC_4000_60, clear_in * u"inch";
                                           axials = (at_cut,))
        @test !high.concrete_omitted
        sheared = detail_column(sec; height = height, slab_above = slab, mats...,
                                gravity_seismic = true, material = RC_4000_60,
                                axials = (0.0u"kip",))
        @test any(n -> occursin("18.7.6", n), sheared.notes)
        sheared_bottom = _groups(sheared, :tie, "18.7.5.3")[1].x_positions
        @test maximum(diff(sheared_bottom)) <= ustrip(u"m", low.spacing) + 1e-6

        # 24 in. with 12 #8 bars: one crosstie each way in every hoop zone.
        big = RCColumnSection(; b = 24.0u"inch", h = 24.0u"inch", bar_size = 8, n_bars = 12,
                              cover = 1.5u"inch", tie_bar_size = 3)
        mdb = detail_column(big; height = 144.0u"inch", slab_above = 8.0u"inch", mats...,
                            gravity_seismic = true)
        zones = [g for g in mdb.groups if g.role === :tie]
        cts = _groups(mdb, :crosstie)
        @test length(cts) == 2 * length(zones)
        for g in cts
            @test length(g.centerlines) == g.count
        end
        @test sum(g.count for g in cts) == 2 * sum(g.count for g in zones)

        # Calculated forces within the design strength stay on §18.14.3.2:
        # the ordinary lap, and hoops over ℓo plus the full height.
        # Pu is the earthquake-included axial. Without Pu_gravity, (c) is not applied.
        within = detail_column(sec; height = height, slab_above = slab, mats...,
                               induced_within_strength = true, Pu = 100.0u"kip")
        @test isempty(_groups(within, :longitudinal, "center half"))
        @test any(n -> occursin("18.14.3.2(b)", n), within.notes)
        @test !isempty(_groups(within, :tie, "18.14.3.2(b)"))
        @test any(n -> occursin("was not passed", n), within.notes)

        # §18.14.3.2(c): half of Table 18.7.5.4 (a) and (b) over ℓo.
        # 2000 kip is above 0.35P0 for this 16 in. column.
        heavy = detail_column(sec; height = height, slab_above = slab, mats...,
                              induced_within_strength = true,
                              Pu_gravity = 2000.0u"kip")
        @test any(n -> occursin("18.14.3.2(c)", n), heavy.notes)
        @test !any(w -> occursin("not placed", w), heavy.warnings)
        ends_c = _groups(heavy, :tie, "18.14.3.2(c)")
        @test length(ends_c) == 2
        s_half = StructuralSizer._half_table_hoop_spacing(sec, mats.fc, mats.fyt)
        @test s_half !== nothing
        @test ustrip(u"inch", s_half) < 6
        @test maximum(diff(ends_c[1].x_positions)) <=
              ustrip(u"m", min(s_half, 6.0u"inch")) + 1e-6
        light = detail_column(sec; height = height, slab_above = slab, mats...,
                              induced_within_strength = true,
                              Pu_gravity = 50.0u"kip")
        @test any(n -> occursin("does not exceed 0.35P0", n), light.notes)
        @test isempty(_groups(light, :tie, "18.14.3.2(c)"))
        @test isempty(_groups(light, :tie, "18.7.5.7"))

        # §18.7.5.7: cover outside the confining hoop above 4 in.
        deep = RCColumnSection(; b = 20.0u"inch", h = 20.0u"inch", bar_size = 8,
                               n_bars = 8, cover = 5.0u"inch", tie_bar_size = 3)
        covered = detail_column(deep; height = height, slab_above = slab, mats...,
                                induced_within_strength = true,
                                Pu_gravity = 2000.0u"kip")
        extra = _groups(covered, :tie, "18.7.5.7")
        @test length(extra) == 2
        @test all(g -> maximum(diff(g.x_positions)) <= ustrip(u"m", 12.0u"inch") + 1e-6, extra)

        # §18.14.3.2 with a spiral. D = 60 in., 1.5 in. cover: Ag/Ach = 3600/3249.
        # (d) = 0.45(Ag/Ach − 1)·4000/60000 = 0.003241, (e) = 0.12·4000/60000 = 0.008.
        # Half of (e) is 0.004 > (d), so (c) sets ρs and the #3 pitch is
        # 4·0.11/(57·0.004) = 1.93 in. 0.35P0 with 24 #11 is about 4106 kip.
        round60 = RCCircularSection(; D = 60.0u"inch", bar_size = 11, n_bars = 24, cover = 1.5u"inch")
        sp_over = detail_column(round60; height = height, slab_above = slab, mats...,
                                induced_within_strength = true, Pu_gravity = 5000.0u"kip")
        sp = only(_groups(sp_over, :spiral))
        @test occursin("18.14.3.2(c)", sp.note)
        @test any(n -> occursin("(d) and (e)", n), sp_over.notes)
        @test !any(w -> occursin("keeps its ordinary", w), sp_over.warnings)
        @test ustrip(u"inch", sp.x_positions[2] * u"m") ≈ 4 * 0.11 / (57 * 0.004) rtol = 1e-3
        sp_under = detail_column(round60; height = height, slab_above = slab, mats...,
                                 induced_within_strength = true, Pu_gravity = 1000.0u"kip")
        sp2 = only(_groups(sp_under, :spiral))
        @test !occursin("18.14.3.2(c)", sp2.note)
        ρd = 0.45 * (3600 / 3249 - 1) * 4000 / 60_000
        @test ustrip(u"inch", sp2.x_positions[2] * u"m") ≈ 4 * 0.11 / (57 * ρd) rtol = 1e-3
        @test any(n -> occursin("spiral over the full height", n), sp_under.notes)

        # Circular ties and the §18.14.3.3 path are not detailed; they warn.
        tied = RCCircularSection(; D = 20.0u"inch", bar_size = 8, n_bars = 8,
                                 cover = 1.5u"inch", tie_type = :tied)
        tw = detail_column(tied; height = height, slab_above = slab, mats...,
                           induced_within_strength = true, Pu_gravity = 50.0u"kip")
        @test any(w -> occursin("keeps its ordinary ties", w), tw.warnings)
        sw = detail_column(round60; height = height, slab_above = slab, mats...,
                           gravity_seismic = true)
        @test any(w -> occursin("keeps its ordinary spiral", w), sw.warnings)
    end
end
