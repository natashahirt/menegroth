# ACI 318-19 §18.10.6.2(a), Eq. (18.10.6.2a) (corpus: aci-318-19, page 326).
# 1.5 δu/hwcs ≥ ℓw/(600 c), with δu/hwcs not taken below 0.005.
# The section applies when hwcs/ℓw ≥ 2 and the wall has one critical section.

using Test
using Unitful
using StructuralSizer

@testset "Displacement boundary element, Eq. (18.10.6.2a)" begin
    lw = 20.0u"ft"
    hw = 60.0u"ft"
    # δu/hw = 6/720 = 0.008333. Left side 1.5 × 0.008333 = 0.0125.
    # c = 40 in: ℓw/(600 c) = 240/(600×40) = 0.010. 0.0125 ≥ 0.010.
    needs = displacement_boundary_element(40.0u"inch", lw, 6.0u"inch", hw;
                                          single_critical_section = true)
    @test needs.applicable
    @test needs.required
    @test needs.slenderness ≈ 3.0
    @test needs.drift_ratio ≈ 6 / 720
    @test needs.demand ≈ 0.0125
    @test needs.neutral_axis_term ≈ 0.010

    # Same wall at the 0.005 floor. Left side 1.5 × 0.005 = 0.0075 < 0.010.
    held = displacement_boundary_element(40.0u"inch", lw, 0.1u"inch", hw;
                                         single_critical_section = true)
    @test held.drift_ratio ≈ 0.005
    @test held.required == false

    # A deeper neutral axis at that floor: ℓw/(600×80 in) = 0.005 ≤ 0.0075.
    deep = displacement_boundary_element(80.0u"inch", lw, 0.1u"inch", hw;
                                         single_critical_section = true)
    @test deep.required

    # hwcs/ℓw = 1.5 < 2, so §18.10.6.2 does not apply.
    short = displacement_boundary_element(80.0u"inch", lw, 12.0u"inch", 30.0u"ft";
                                          single_critical_section = true)
    @test short.slenderness ≈ 1.5
    @test !short.applicable
    @test short.required === nothing

    # Tall enough, but not a single critical section.
    several = displacement_boundary_element(80.0u"inch", lw, 12.0u"inch", hw;
                                            single_critical_section = false)
    @test !several.applicable
    @test several.required === nothing

    @test_throws ArgumentError displacement_boundary_element(
        0.0u"inch", lw, 6.0u"inch", hw; single_critical_section = true)
end

# §18.10.6.2(b)(i) (corpus: aci-318-19, page 326): the greater of ℓw and Mu/4Vu.
# The question is which candidate sets the extension, and what a bad sign does.
@testset "Vertical extension is the longer of the wall length and Mu/4Vu" begin
    lw = 20.0u"ft"
    # Mu/4Vu = 4000 kip·ft / (4 × 50 kip) = 20 ft, the same as ℓw.
    tied = boundary_transverse_extension(lw, 4000.0u"kip*ft", 50.0u"kip")
    @test tied.from_length ≈ tied.from_shear
    @test tied.extension ≈ 20.0u"ft"

    # Twice the moment: Mu/4Vu = 40 ft, so the shear term sets the extension.
    long = boundary_transverse_extension(lw, 8000.0u"kip*ft", 50.0u"kip")
    @test long.from_shear ≈ 40.0u"ft"
    @test long.from_shear > long.from_length
    @test long.extension ≈ long.from_shear

    # Half the moment: Mu/4Vu = 10 ft, so ℓw sets the extension.
    short = boundary_transverse_extension(lw, 2000.0u"kip*ft", 50.0u"kip")
    @test short.from_shear ≈ 10.0u"ft"
    @test short.extension ≈ short.from_length

    # A zero shear would make Mu/4Vu infinite and hide behind no real length.
    @test_throws ArgumentError boundary_transverse_extension(lw, 4000.0u"kip*ft", 0.0u"kip")
    # A negative moment would make the shear term lose, and the wall length
    # would be reported as if the hinge demand were small.
    @test_throws ArgumentError boundary_transverse_extension(lw, -4000.0u"kip*ft", 50.0u"kip")
end

# §18.10.6.4(a) (corpus: aci-318-19, page 327).
# c − 0.1ℓw exceeds c/2 exactly when c > 0.2ℓw. Below that, c/2 wins,
# including when c − 0.1ℓw is negative.
@testset "Horizontal length switches at c = 0.2ℓw" begin
    lw = 200.0u"inch"
    # c = 0.2 × 200 in. = 40 in. Both candidates are 20 in.
    tied = boundary_element_horizontal_length(40.0u"inch", lw)
    @test tied.from_offset ≈ 20.0u"inch"
    @test tied.from_half ≈ 20.0u"inch"
    @test tied.length ≈ 20.0u"inch"

    # c = 30 in. < 40 in. Offset is 10 in., half is 15 in.
    shallow = boundary_element_horizontal_length(30.0u"inch", lw)
    @test shallow.from_offset ≈ 10.0u"inch"
    @test shallow.from_half ≈ 15.0u"inch"
    @test shallow.length ≈ shallow.from_half

    # c = 80 in. Offset is 60 in., half is 40 in.
    deep = boundary_element_horizontal_length(80.0u"inch", lw)
    @test deep.from_offset ≈ 60.0u"inch"
    @test deep.length ≈ deep.from_offset

    # c = 10 in. Offset is −10 in. The length is still c/2, not zero.
    tiny = boundary_element_horizontal_length(10.0u"inch", lw)
    @test tiny.from_offset < 0.0u"inch"
    @test tiny.length ≈ 5.0u"inch"
    @test tiny.length ≈ tiny.from_half
end

# §18.10.6.4(b) is hu/16 on every wall. §18.10.6.4(c) adds a 12 in. floor
# only when every gate is open. The required width is the greater of the
# limits that apply, so a tall unsupported height can beat the 12 in. floor.
@testset "Compression-zone width: hu/16, and a 12 in. floor when every gate is open" begin
    # The gates of (c), each one at its edge: hw/ℓw = 2 and c/ℓw = 3/8.
    open_gates = (continuous = true, single_critical_section = true)
    at_edge = compression_zone_width(16.0u"ft", 400.0u"inch", 200.0u"inch", 75.0u"inch";
                                     open_gates...)
    @test at_edge.slenderness ≈ 2.0
    @test at_edge.neutral_axis_ratio ≈ 0.375
    @test at_edge.tall && at_edge.deep && at_edge.floor_applies
    # hu = 16 ft, so hu/16 = 12 in., the same as the floor.
    @test at_edge.from_unsupported ≈ 12.0u"inch"
    @test at_edge.required ≈ 12.0u"inch"

    # Just short of 3/8. The floor stays shut and the width is hu/16.
    not_deep = compression_zone_width(16.0u"ft", 400.0u"inch", 200.0u"inch", 74.0u"inch";
                                      open_gates...)
    @test not_deep.neutral_axis_ratio ≈ 0.37
    @test !not_deep.deep && !not_deep.floor_applies
    @test not_deep.thickness_floor === nothing
    @test not_deep.required ≈ not_deep.from_unsupported

    # Tall and deep, but not continuous. One false gate is enough.
    broken = compression_zone_width(16.0u"ft", 400.0u"inch", 200.0u"inch", 75.0u"inch";
                                    continuous = false, single_critical_section = true)
    @test broken.deep && broken.tall && !broken.floor_applies

    # hu = 8 ft → hu/16 = 6 in. The 12 in. floor is the one that governs.
    short_height = compression_zone_width(8.0u"ft", 400.0u"inch", 200.0u"inch", 75.0u"inch";
                                          open_gates...)
    @test short_height.from_unsupported ≈ 6.0u"inch"
    @test short_height.required ≈ 12.0u"inch"

    # hu = 32 ft → hu/16 = 24 in., which is past the 12 in. floor.
    tall_height = compression_zone_width(32.0u"ft", 400.0u"inch", 200.0u"inch", 75.0u"inch";
                                         open_gates...)
    @test tall_height.from_unsupported ≈ 24.0u"inch"
    @test tall_height.required ≈ tall_height.from_unsupported
end

# Eq. (18.10.6.2b) and §18.10.6.2(b)(iii) (corpus: aci-318-19, page 326).
# δc/hwcs = (1/100)(4 − (1/50)(ℓw/b)(c/b) − Ve/(8 f′c Acv)), not below 0.015.
# The comparison uses that floored value, not the raw one.
@testset "Drift capacity floors at 0.015 and is compared with 1.5 δu/hwcs" begin
    b = 12.0u"inch"
    c = 12.0u"inch"
    # (ℓw/b)(c/b) = 10, so the geometry term is 10/50 = 0.2. No shear.
    # raw = (4 − 0.2)/100 = 0.038.
    calm = boundary_drift_capacity(120.0u"inch", b, c, 0.0u"kip", 4.0u"ksi", 1000.0u"inch^2",
                                   7.2u"inch", 60.0u"ft")
    @test calm.geometry_term ≈ 0.2
    @test calm.shear_term ≈ 0.0
    @test calm.raw ≈ 0.038
    @test !calm.floored
    # δu/hwcs = 7.2 in. / 720 in. = 0.01. Demand = 0.015. 0.038 meets it.
    @test calm.demand ≈ 0.015
    @test calm.meets

    # Same capacity, demand 1.5 × 0.03 = 0.045, which is past 0.038.
    over = boundary_drift_capacity(120.0u"inch", b, c, 0.0u"kip", 4.0u"ksi", 1000.0u"inch^2",
                                   21.6u"inch", 60.0u"ft")
    @test over.demand ≈ 0.045
    @test over.raw ≈ 0.038
    @test !over.meets

    # A demand that sits between the raw value and the 0.015 floor.
    # Raw is driven negative by the shear term, so the ratio used is 0.015.
    # 8 × 4 ksi × 1000 in² = 32_000 kip. Ve = 160_000 kip → shear term = 5.
    # raw = (4 − 0.2 − 5)/100 = −0.012.
    # Demand 1.5 × 0.008 = 0.012, which fails against the raw value and
    # passes against the floored one.
    lifted = boundary_drift_capacity(120.0u"inch", b, c, 160_000.0u"kip", 4.0u"ksi",
                                     1000.0u"inch^2", 5.76u"inch", 60.0u"ft")
    @test lifted.shear_term ≈ 5.0
    @test lifted.raw < 0.015
    @test lifted.floored
    @test lifted.ratio ≈ 0.015
    @test lifted.demand ≈ 0.012
    @test lifted.meets

    # The 0.005 floor belongs to the (a) trigger. A drift of 0.001 is not
    # raised before the 1.5 multiplier here: demand is 0.0015.
    small = boundary_drift_capacity(120.0u"inch", b, c, 0.0u"kip", 4.0u"ksi", 1000.0u"inch^2",
                                    0.72u"inch", 60.0u"ft")
    @test small.demand ≈ 0.0015
end

# §18.10.6.3 (corpus: aci-318-19, page 327).
# "Exceeds 0.2f′c" does not include 0.2. "Less than 0.15f′c" does not
# include 0.15. The band between them neither starts nor ends the element.
@testset "Stress trigger and the stop limit are not the same cut" begin
    fc = 5.0u"ksi"
    at_trigger = stress_boundary_element(0.2 * fc, fc)
    @test at_trigger.ratio ≈ 0.2
    @test !at_trigger.triggered
    @test !at_trigger.may_discontinue

    over = stress_boundary_element(0.2 * fc + 1.0u"psi", fc)
    @test over.triggered
    @test !over.may_discontinue

    at_stop = stress_boundary_element(0.15 * fc, fc)
    @test at_stop.ratio ≈ 0.15
    @test !at_stop.triggered
    @test !at_stop.may_discontinue

    under = stress_boundary_element(0.15 * fc - 1.0u"psi", fc)
    @test !under.triggered
    @test under.may_discontinue

    # 0.17f′c is inside the band.
    band = stress_boundary_element(0.17 * fc, fc)
    @test band.ratio ≈ 0.17
    @test !band.triggered
    @test !band.may_discontinue

    @test_throws ArgumentError stress_boundary_element(-1.0u"psi", fc)
end

# Table 18.10.6.4(g) (corpus: aci-318-19, page 328).
# f′c/fyt = 6/60 = 0.1.
# Rectilinear: (a) = (b) when 0.3(Ag/Ach − 1) = 0.09, so Ag/Ach = 1.3.
# Spiral: (c) = (d) when 0.45(Ag/Ach − 1) = 0.12, so Ag/Ach = 1 + 0.12/0.45.
@testset "Confinement amount switches from the constant term to the cover term" begin
    fc = 6.0u"ksi"
    fyt = 60.0u"ksi"
    # Ag/Ach = 1.3. Both rectilinear expressions are 0.009.
    tied = boundary_transverse_amount(130.0u"inch^2", 100.0u"inch^2", fc, fyt)
    @test tied.style === :rectilinear
    @test tied.area_ratio ≈ 1.3
    @test tied.cover_term ≈ 0.009
    @test tied.constant_term ≈ 0.009
    @test tied.required ≈ 0.009

    # No cover outside the core. The cover term is zero and 0.09 f′c/fyt governs.
    flush = boundary_transverse_amount(100.0u"inch^2", 100.0u"inch^2", fc, fyt)
    @test flush.cover_term ≈ 0.0
    @test flush.required ≈ flush.constant_term

    # Ag/Ach = 2. Cover term 0.3 × 1 × 0.1 = 0.03.
    thick_cover = boundary_transverse_amount(200.0u"inch^2", 100.0u"inch^2", fc, fyt)
    @test thick_cover.cover_term ≈ 0.03
    @test thick_cover.required ≈ thick_cover.cover_term

    # A core reported larger than the gross section makes the cover term
    # negative. The constant term still governs.
    inverted = boundary_transverse_amount(80.0u"inch^2", 100.0u"inch^2", fc, fyt)
    @test inverted.cover_term < 0
    @test inverted.required ≈ inverted.constant_term

    # Spiral crossover: Ag/Ach = 1 + 0.12/0.45 = 19/15. Both terms are 0.012.
    spiral_tie = boundary_transverse_amount(19.0u"inch^2", 15.0u"inch^2", fc, fyt; spiral = true)
    @test spiral_tie.style === :spiral
    @test spiral_tie.area_ratio ≈ 19 / 15
    @test spiral_tie.cover_term ≈ 0.012
    @test spiral_tie.constant_term ≈ 0.012

    # Ag/Ach = 1.2 is below that crossover, so the 0.12 f′c/fyt term governs.
    spiral_low = boundary_transverse_amount(12.0u"inch^2", 10.0u"inch^2", fc, fyt; spiral = true)
    @test spiral_low.cover_term ≈ 0.45 * 0.2 * 0.1
    @test spiral_low.cover_term < spiral_low.constant_term
    @test spiral_low.required ≈ spiral_low.constant_term
end

# §18.10.5.2 (corpus: aci-318-19, page 325).
# From the face of the web: the lesser of half the distance to an adjacent
# web and 25 percent of the wall height above the section. A detailed
# analysis replaces that overhang and leaves the code value visible.
@testset "Effective flange overhang is the shorter of the two reaches" begin
    # Height 16 ft → 4 ft. Adjacent web 20 ft away → half is 10 ft.
    # The height reach is the shorter one.
    by_height = effective_flange_overhang(16.0u"ft"; distance_to_adjacent_web = 20.0u"ft")
    @test by_height.from_height ≈ 4.0u"ft"
    @test by_height.from_adjacent ≈ 10.0u"ft"
    @test by_height.code_overhang ≈ by_height.from_height
    @test by_height.overhang ≈ by_height.code_overhang
    @test !by_height.detailed

    # Adjacent web 6 ft away → half is 3 ft, under the 4 ft height reach.
    by_web = effective_flange_overhang(16.0u"ft"; distance_to_adjacent_web = 6.0u"ft")
    @test by_web.from_adjacent ≈ 3.0u"ft"
    @test by_web.code_overhang ≈ by_web.from_adjacent

    # The two reaches meet when the adjacent web is 8 ft away: half is 4 ft.
    tied = effective_flange_overhang(16.0u"ft"; distance_to_adjacent_web = 8.0u"ft")
    @test tied.from_adjacent ≈ tied.from_height
    @test tied.code_overhang ≈ 4.0u"ft"

    # No second web. The half-distance candidate is absent and the height
    # reach is the overhang.
    alone = effective_flange_overhang(16.0u"ft")
    @test alone.from_adjacent === nothing
    @test alone.code_overhang ≈ alone.from_height

    # A detailed analysis of 18 in. is used. The code overhang stays 4 ft.
    studied = effective_flange_overhang(16.0u"ft"; distance_to_adjacent_web = 20.0u"ft",
                                       detailed = 18.0u"inch")
    @test studied.detailed
    @test studied.code_overhang ≈ 4.0u"ft"
    @test studied.overhang ≈ 18.0u"inch"

    @test_throws ArgumentError effective_flange_overhang(0.0u"ft")
    @test_throws ArgumentError effective_flange_overhang(16.0u"ft";
                                                        distance_to_adjacent_web = 0.0u"ft")
end

# §18.10.6.4(d) (corpus: aci-318-19, page 327).
# The flange width and the 12 in. web extension are different directions.
# The 12 in. does not grow with the flange.
@testset "A compression flange is included, and the element enters the web 12 in." begin
    edge = flanged_boundary_element(; in_compression = true,
                                    effective_flange_width = 30.0u"inch")
    @test edge.applies
    @test edge.included_width ≈ 30.0u"inch"
    @test edge.web_extension ≈ 12.0u"inch"

    wide = flanged_boundary_element(; in_compression = true,
                                   effective_flange_width = 8.0u"ft")
    @test wide.included_width ≈ 8.0u"ft"
    @test wide.web_extension ≈ 12.0u"inch"

    # The same width on a tension edge does not open (d).
    tension = flanged_boundary_element(; in_compression = false,
                                      effective_flange_width = 30.0u"inch")
    @test !tension.applies
    @test tension.included_width === nothing
    @test tension.web_extension === nothing

    # A rectangular edge has no flange width and does not open (d).
    plain = flanged_boundary_element(; in_compression = false)
    @test !plain.applies

    @test_throws ArgumentError flanged_boundary_element(; in_compression = true)
    @test_throws ArgumentError flanged_boundary_element(; in_compression = true,
                                                       effective_flange_width = 0.0u"inch")
end

# §18.10.6.4(f) (corpus: aci-318-19, page 328).
# hx switches at 21 in., where two-thirds of the thickness is 14 in.
# The hoop overlap switches at 9 in., where two-thirds of the thickness is 6 in.
@testset "Hoop spacing switches from the thickness term to the fixed cap" begin
    # 12 in. thick: two-thirds is 8 in. hx is 8 in. Overlap stays at 6 in.
    # A hoop leg may be 24 in.
    ordinary = boundary_transverse_spacing(12.0u"inch")
    @test ordinary.hx_from_thickness ≈ 8.0u"inch"
    @test ordinary.hx ≈ ordinary.hx_from_thickness
    @test ordinary.overlap ≈ 6.0u"inch"
    @test ordinary.hoop_leg ≈ 24.0u"inch"

    # 21 in.: both hx candidates are 14 in.
    hx_tie = boundary_transverse_spacing(21.0u"inch")
    @test hx_tie.hx_from_thickness ≈ 14.0u"inch"
    @test hx_tie.hx_from_cap ≈ hx_tie.hx_from_thickness
    @test hx_tie.hx ≈ 14.0u"inch"

    # 30 in.: two-thirds is 20 in., so the 14 in. cap sets hx.
    thick = boundary_transverse_spacing(30.0u"inch")
    @test thick.hx_from_thickness ≈ 20.0u"inch"
    @test thick.hx ≈ thick.hx_from_cap
    @test thick.hoop_leg ≈ 60.0u"inch"

    # 9 in.: both overlap candidates are 6 in. hx is still the thickness term.
    overlap_tie = boundary_transverse_spacing(9.0u"inch")
    @test overlap_tie.overlap_from_thickness ≈ 6.0u"inch"
    @test overlap_tie.overlap ≈ 6.0u"inch"
    @test overlap_tie.hx ≈ 6.0u"inch"

    # 6 in.: two-thirds is 4 in., so the overlap drops below the 6 in. cap.
    thin = boundary_transverse_spacing(6.0u"inch")
    @test thin.overlap_from_thickness ≈ 4.0u"inch"
    @test thin.overlap ≈ thin.overlap_from_thickness
    @test thin.hx ≈ 4.0u"inch"

    @test_throws ArgumentError boundary_transverse_spacing(0.0u"inch")
end

# Eq. (18.7.5.3) (corpus: aci-318-19, page 311).
# so = 4 + (14 − hx)/3 inches. It shall not exceed 6 in. and need not
# be taken less than 4 in. The raw value hits 4 in. at hx = 14 in. and
# hits 6 in. at hx = 8 in.
@testset "so rises as the supported bars get closer, between 4 and 6 in." begin
    at_floor = transverse_spacing_so(14.0u"inch")
    @test at_floor.raw ≈ 4.0u"inch"
    @test !at_floor.floored && !at_floor.capped
    @test at_floor.so ≈ 4.0u"inch"

    mid = transverse_spacing_so(11.0u"inch")
    @test mid.raw ≈ 5.0u"inch"
    @test mid.so ≈ mid.raw

    at_cap = transverse_spacing_so(8.0u"inch")
    @test at_cap.raw ≈ 6.0u"inch"
    @test !at_cap.capped
    @test at_cap.so ≈ 6.0u"inch"

    # hx = 5 in. The equation gives 7 in., and the 6 in. cap is what is used.
    over = transverse_spacing_so(5.0u"inch")
    @test over.raw ≈ 7.0u"inch"
    @test over.capped
    @test over.so ≈ 6.0u"inch"

    # hx = 20 in. The equation gives 2 in., and the value need not be taken
    # below 4 in.
    under = transverse_spacing_so(20.0u"inch")
    @test under.raw ≈ 2.0u"inch"
    @test under.floored
    @test under.so ≈ 4.0u"inch"
end

# Table 18.10.6.5(b) (corpus: aci-318-19, page 332).
# Inside the critical reach the inch cap is 6 in. for every grade, and the
# bar multiple tightens from 6db to 5db to 4db. Outside it, Grade 60 opens
# to 8db and 8 in.; Grades 80 and 100 stay at 6db and 6 in.
@testset "Tie-table spacing tightens inside the critical reach" begin
    # db = 0.5 in. Grade 60 outside: 8db = 4 in., under the 8 in. cap.
    # Inside: 6db = 3 in., under the 6 in. cap.
    small_out = wall_boundary_tie_spacing(0.5u"inch"; grade = 60, within_critical_reach = false)
    @test small_out.from_bar ≈ 4.0u"inch"
    @test small_out.spacing ≈ small_out.from_bar
    small_in = wall_boundary_tie_spacing(0.5u"inch"; grade = 60, within_critical_reach = true)
    @test small_in.spacing ≈ 3.0u"inch"
    @test small_in.spacing < small_out.spacing

    # db = 1.5 in. Grade 60 inside: 6db = 9 in., so the 6 in. cap governs.
    # Outside: 8db = 12 in., so the 8 in. cap governs.
    large_in = wall_boundary_tie_spacing(1.5u"inch"; grade = 60, within_critical_reach = true)
    @test large_in.from_bar ≈ 9.0u"inch"
    @test large_in.spacing ≈ 6.0u"inch"
    large_out = wall_boundary_tie_spacing(1.5u"inch"; grade = 60, within_critical_reach = false)
    @test large_out.spacing ≈ 8.0u"inch"

    # Grade 80, db = 1 in. Inside, 5db = 5 in. Outside, 6db = 6 in.,
    # which is also the cap.
    g80_in = wall_boundary_tie_spacing(1.0u"inch"; grade = 80, within_critical_reach = true)
    @test g80_in.factor == 5
    @test g80_in.spacing ≈ 5.0u"inch"
    g80_out = wall_boundary_tie_spacing(1.0u"inch"; grade = 80, within_critical_reach = false)
    @test g80_out.spacing ≈ 6.0u"inch"

    # Grade 100, db = 1 in. Inside, 4db = 4 in. Outside, 6db = 6 in.
    g100_in = wall_boundary_tie_spacing(1.0u"inch"; grade = 100, within_critical_reach = true)
    @test g100_in.spacing ≈ 4.0u"inch"
    g100_out = wall_boundary_tie_spacing(1.0u"inch"; grade = 100, within_critical_reach = false)
    @test g100_out.spacing ≈ 6.0u"inch"

    @test_throws ArgumentError wall_boundary_tie_spacing(1.0u"inch"; grade = 40,
                                                        within_critical_reach = true)
end

# §18.10.6.4(e) (corpus: aci-318-19, page 328).
# The column's one-fourth becomes one-third of the least boundary dimension.
# That term, the bar-diameter term, so, and the table are then the least of
# the ones that apply. Grade 100 has no §18.7.5.3 bar-diameter term.
@testset "Vertical spacing is the tightest of the dimension, the bar, so, and the table" begin
    # Least dimension 12 in. One-third is 4 in. One-fourth would have been 3 in.
    # Grade 60, db = 1 in. so 6db = 6 in. hx = 14 in. so so = 4 in.
    # Inside the reach the table is min(6 in., 6 in.) = 6 in.
    # The 4 in. terms govern, and they are the one-third and so.
    both = boundary_element_vertical_spacing(12.0u"inch", 1.0u"inch", 14.0u"inch";
                                            grade = 60, within_critical_reach = true)
    @test both.from_dimension ≈ 4.0u"inch"
    @test both.from_dimension > 12.0u"inch" / 4
    @test both.from_bar ≈ 6.0u"inch"
    @test both.from_so ≈ 4.0u"inch"
    @test both.from_table ≈ 6.0u"inch"
    @test both.required ≈ 4.0u"inch"

    # Least dimension 24 in. → 8 in. hx = 11 in. → so = 5 in.
    # Grade 60, db = 1.5 in. → 6db = 9 in. Table inside = 6 in.
    # so is the only term at 5 in.
    by_so = boundary_element_vertical_spacing(24.0u"inch", 1.5u"inch", 11.0u"inch";
                                             grade = 60, within_critical_reach = true)
    @test by_so.from_so ≈ 5.0u"inch"
    @test by_so.from_dimension ≈ 8.0u"inch"
    @test by_so.from_table ≈ 6.0u"inch"
    @test by_so.required ≈ by_so.from_so

    # Grade 80, db = 1.5 in. 5db = 7.5 in. Table inside caps at 6 in.
    # Least dimension 36 in. → 12 in. hx = 5 in. → so = 6 in.
    # The table and so tie at 6 in., and 5db is looser.
    g80 = boundary_element_vertical_spacing(36.0u"inch", 1.5u"inch", 5.0u"inch";
                                           grade = 80, within_critical_reach = true)
    @test g80.from_bar ≈ 7.5u"inch"
    @test g80.from_table ≈ 6.0u"inch"
    @test g80.from_so ≈ 6.0u"inch"
    @test g80.required ≈ 6.0u"inch"

    # Grade 100 has no bar-diameter term from §18.7.5.3. db = 1 in.
    # Inside, the table is 4db = 4 in. Least dimension 24 in. → 8 in.
    # hx = 8 in. → so = 6 in. The table is the tight one.
    g100 = boundary_element_vertical_spacing(24.0u"inch", 1.0u"inch", 8.0u"inch";
                                            grade = 100, within_critical_reach = true)
    @test g100.from_bar === nothing
    @test g100.from_table ≈ 4.0u"inch"
    @test g100.from_so ≈ 6.0u"inch"
    @test g100.required ≈ g100.from_table
end

# §18.10.6.4(h), (i), (j), and (k) (corpus: aci-318-19, pages 328–329).
@testset "Floor strength, web-bar spacing, support embedment, and the web-bar hook" begin
    fc = 5.0u"ksi"
    at = floor_concrete_at_boundary(0.7 * fc, fc)
    @test at.ratio ≈ 0.7
    @test at.meets
    under = floor_concrete_at_boundary(0.7 * fc - 1.0u"psi", fc)
    @test !under.meets

    # 12 in. is still within the web-bar spacing limit. Past it is not.
    @test web_vertical_support_spacing(12.0u"inch").meets
    @test !web_vertical_support_spacing(12.1u"inch").meets

    # ℓd = 18 in. into a beam or slab: the extension is ℓd.
    beam = boundary_support_extension(18.0u"inch")
    @test beam.from_footing === nothing
    @test beam.required ≈ 18.0u"inch"

    # ℓd = 8 in. into a footing: the 12 in. floor is longer.
    short_ld = boundary_support_extension(8.0u"inch"; into_foundation = true)
    @test short_ld.from_footing ≈ 12.0u"inch"
    @test short_ld.required ≈ short_ld.from_footing

    # ℓd = 20 in. into a footing: development is longer than 12 in.
    long_ld = boundary_support_extension(20.0u"inch"; into_foundation = true)
    @test long_ld.required ≈ long_ld.from_development

    # §18.13.2.4 asking for 16 in. beats both 12 in. and an ℓd of 10 in.
    deeper = boundary_support_extension(10.0u"inch"; into_foundation = true,
                                       foundation_minimum = 16.0u"inch")
    @test deeper.from_footing ≈ 16.0u"inch"
    @test deeper.required ≈ 16.0u"inch"

    # The tie: ℓd = 12 in. into a footing. Both candidates are 12 in.
    tied = boundary_support_extension(12.0u"inch"; into_foundation = true)
    @test tied.from_development ≈ tied.from_footing
    @test tied.required ≈ 12.0u"inch"

    # A 6 in. gap still reaches the wall end. A nanometer of binary rounding does too.
    # A hundredth of an inch past 6 in. does not.
    @test web_end_within_six_inches(6.0u"inch")
    @test web_end_within_six_inches(6.0u"inch" + 1e-10u"m")
    @test !web_end_within_six_inches(6.0u"inch" + 0.01u"inch")

    # A 6 in. gap still reaches the wall end. A longer gap does not.
    # Equal force per length does not exceed, so a straight bar is permitted
    # when the boundary can develop it.
    equal = horizontal_web_termination(6.0u"inch"; can_develop = true,
                                      web_asfy_per_s = 10.0u"kip/ft",
                                      boundary_asfyt_per_s = 10.0u"kip/ft")
    @test equal.reaches
    @test equal.force_ratio ≈ 1.0
    @test equal.straight_permitted
    @test !equal.hook_required

    over = horizontal_web_termination(6.0u"inch"; can_develop = true,
                                     web_asfy_per_s = 12.0u"kip/ft",
                                     boundary_asfyt_per_s = 10.0u"kip/ft")
    @test over.hook_required
    @test !over.straight_permitted

    # A boundary that cannot develop the bar still needs the hook, even
    # when the web force is the smaller one.
    short_boundary = horizontal_web_termination(3.0u"inch"; can_develop = false)
    @test short_boundary.reaches
    @test short_boundary.hook_required
    @test short_boundary.force_ratio === nothing

    past = horizontal_web_termination(6.1u"inch"; can_develop = false)
    @test !past.reaches
end

# §18.10.6.2(b)(ii) (corpus: aci-318-19, page 326; radical read from the page).
# b ≥ √(0.025 ℓw c). Meeting it is the alternative to the drift check (iii):
# the drift is not evaluated. The NEHRP example prints 19.3 in. for
# √(0.025 × 95 × 164); the expression is 19.74 in.
@testset "A wide enough compression zone skips the drift check" begin
    # ℓw = 120 in., c = 12 in. √(0.025 × 120 × 12) = √36 = 6 in.
    # The drift below would fail: demand 0.045 against a raw capacity of 0.038.
    # b = 12 in. meets (ii), so the drift is never computed.
    wide = boundary_width_or_drift(120.0u"inch", 12.0u"inch", 12.0u"inch", 0.0u"kip",
                                  4.0u"ksi", 1000.0u"inch^2", 21.6u"inch", 60.0u"ft")
    @test wide.width.required ≈ 6.0u"inch"
    @test wide.by === :width
    @test wide.satisfied
    @test wide.drift === nothing

    # b = 6 in. is the expression itself, so (ii) still holds.
    exact = boundary_zone_width_minimum(6.0u"inch", 120.0u"inch", 12.0u"inch")
    @test exact.required ≈ 6.0u"inch"
    @test exact.meets

    # b = 5 in. misses (ii). The same failing drift is now what decides.
    short = boundary_width_or_drift(120.0u"inch", 5.0u"inch", 12.0u"inch", 0.0u"kip",
                                   4.0u"ksi", 1000.0u"inch^2", 21.6u"inch", 60.0u"ft")
    @test short.by === :drift
    @test short.drift !== nothing
    @test !short.drift.meets
    @test !short.satisfied

    # Same short wall, drift demand 0.015 against raw 0.038. (iii) carries it.
    saved = boundary_width_or_drift(120.0u"inch", 5.0u"inch", 12.0u"inch", 0.0u"kip",
                                   4.0u"ksi", 1000.0u"inch^2", 7.2u"inch", 60.0u"ft")
    @test saved.by === :drift
    @test saved.drift.meets
    @test saved.satisfied

    # NEHRP 2020 Vol. 1, PDF page 158: ℓw = 164 in., c = 95 in., b = 26 in.
    # √(0.025 × 95 × 164) = √389.5 ≈ 19.74 in., not the printed 19.3 in.
    nehrp = boundary_zone_width_minimum(26.0u"inch", 164.0u"inch", 95.0u"inch")
    @test nehrp.required ≈ sqrt(0.025 * 95 * 164) * u"inch"
    @test nehrp.required > 19.3u"inch"
    @test nehrp.meets
end

# §18.10.6.5(a) (corpus: aci-318-19, page 332; radical read from the page).
# λ√f′c·Acv with f′c in psi. A hook is required unless Vu is less than that
# force. Vu equal to it still needs the hook.
@testset "Edge hook is waived only below λ√f′c·Acv" begin
    # λ = 1, f′c = 4 ksi, Acv = 1000 in². √4000 × 1000 lbf.
    strength = lambda_sqrt_fc_Acv(1.0, 4.0u"ksi", 1000.0u"inch^2")
    @test strength ≈ (sqrt(4000) * 1000) * u"lbf"

    at = horizontal_edge_anchorage(strength, strength)
    @test !at.exempt
    @test at.hook_required

    under = horizontal_edge_anchorage(strength - 1.0u"lbf", strength)
    @test under.exempt
    @test !under.hook_required

    quiet = horizontal_edge_anchorage(0.0u"kip", strength)
    @test quiet.exempt
end

# §18.10.6.5(b) (corpus: aci-318-19, page 332).
# ρ exceeds 400/fy, with 400 in psi. Equality does not. Above the cut, the
# transverse reinforcement runs the §18.10.6.4(a) length, hx stays within
# 14 in., and the vertical spacing stays within Table 18.10.6.5(b).
@testset "Boundary ties open only above 400/fy" begin
    fy = 60.0u"ksi"
    cut = boundary_longitudinal_ratio(0.0, fy)
    # 400 psi / 60,000 psi = 1/150.
    @test cut.limit ≈ 400 / 60_000
    at = boundary_longitudinal_ratio(cut.limit, fy)
    @test !at.exceeds
    over = boundary_longitudinal_ratio(cut.limit + 1e-6, fy)
    @test over.exceeds

    # Below the cut, the length and the spacing are not asked for.
    shut = boundary_ratio_ties(cut.limit, fy, 95.0u"inch", 164.0u"inch", 6.0u"inch",
                              14.0u"inch", 1.0u"inch"; grade = 60,
                              within_critical_reach = true)
    @test !shut.exceeds
    @test shut.length === nothing
    @test shut.spacing_limit === nothing

    # NEHRP section: c = 95 in., ℓw = 164 in. c − 0.1ℓw = 78.6 in., c/2 = 47.5 in.
    # Grade 60, db = 1 in., inside the critical reach: the table is 6 in.
    open = boundary_ratio_ties(cut.limit + 1e-6, fy, 95.0u"inch", 164.0u"inch",
                             6.0u"inch", 14.0u"inch", 1.0u"inch"; grade = 60,
                             within_critical_reach = true)
    @test open.exceeds
    @test open.length ≈ 78.6u"inch"
    @test open.spacing_limit ≈ 6.0u"inch"
    @test open.spacing_meets
    @test open.hx_meets

    # One step past each cap. 14 in. itself met; past it does not.
    loose = boundary_ratio_ties(cut.limit + 1e-6, fy, 95.0u"inch", 164.0u"inch",
                              6.1u"inch", 14.1u"inch", 1.0u"inch"; grade = 60,
                              within_critical_reach = true)
    @test !loose.spacing_meets
    @test !loose.hx_meets
end

# Eq. (18.10.3.1) and Table 18.10.3.1.2 (corpus: aci-318-19, page 323).
# Ωv is 1.0 at hwcs/ℓw = 1.5 and below. Above that it is the greater of
# Mpr/Mu and 1.5, unless a detailed analysis supplies a smaller value,
# which still cannot go below 1.0.
@testset "Overstrength stays at 1.0 until the wall is taller than 1.5" begin
    squat = special_wall_overstrength(15.0u"ft", 10.0u"ft", 2.0u"kip*ft", 1.0u"kip*ft")
    @test !squat.tall
    @test squat.Ωv == 1.0
    @test squat.from_moments === nothing
    @test_throws ArgumentError special_wall_overstrength(
        15.0u"ft", 10.0u"ft", 2.0u"kip*ft", 1.0u"kip*ft"; detailed = 1.2)

    # Mpr/Mu = 1.2. The 1.5 floor is the larger one.
    floored = special_wall_overstrength(15.1u"ft", 10.0u"ft", 1.2u"kip*ft", 1.0u"kip*ft")
    @test floored.tall
    @test floored.from_moments ≈ 1.2
    @test floored.Ωv == 1.5

    # Mpr/Mu = 2. The moment ratio governs.
    moments = special_wall_overstrength(15.1u"ft", 10.0u"ft", 2.0u"kip*ft", 1.0u"kip*ft")
    @test moments.Ωv ≈ 2.0

    # The footnote may use 1.2 instead of 2, and it may not use 0.4.
    eased = special_wall_overstrength(15.1u"ft", 10.0u"ft", 2.0u"kip*ft", 1.0u"kip*ft";
                                     detailed = 1.2)
    @test eased.detailed
    @test eased.Ωv == 1.2
    held = special_wall_overstrength(15.1u"ft", 10.0u"ft", 2.0u"kip*ft", 1.0u"kip*ft";
                                    detailed = 0.4)
    @test held.Ωv == 1.0
end

# §18.10.3.1.3 (corpus: aci-318-19, page 323).
# hwcs/ℓw below 2 gives ωv = 1. At 2 the story formulas start.
# ns ≤ 6 uses 0.9 + ns/10. Above 6 uses 1.3 + ns/30, not past 1.8.
# ns is raised to 0.007 hwcs when hwcs is in inches.
@testset "Dynamic amplification changes formula at six stories" begin
    short = special_wall_dynamic_amplification(19.9u"ft", 10.0u"ft", 12)
    @test short.branch === :short
    @test short.ωv == 1.0
    @test short.stories === nothing

    # hwcs = 20 ft = 240 in. 0.007 × 240 = 1.68, so ns = 6 is not raised.
    # 0.9 + 6/10 = 1.5. One step past 6 uses the other formula.
    six = special_wall_dynamic_amplification(20.0u"ft", 10.0u"ft", 6)
    @test six.branch === :few
    @test six.stories ≈ 6
    @test six.ωv ≈ 1.5
    @test !six.floored
    past = special_wall_dynamic_amplification(20.0u"ft", 10.0u"ft", 6.0001)
    @test past.branch === :many
    @test past.ωv ≈ 1.3 + 6.0001 / 30
    @test !past.capped

    # hwcs = 1000 in. 0.007 × 1000 = 7, so a reported 1 story is used as 7.
    # 1.3 + 7/30 = 1.5333. Thirty stories hits the 1.8 cap: 1.3 + 30/30 = 2.3.
    raised = special_wall_dynamic_amplification(1000.0u"inch", 400.0u"inch", 1)
    @test raised.floored
    @test raised.stories ≈ 7
    @test raised.branch === :many
    @test raised.ωv ≈ 1.3 + 7 / 30
    capped = special_wall_dynamic_amplification(20.0u"ft", 10.0u"ft", 30)
    @test capped.capped
    @test capped.ωv == 1.8
    # ns = 15 lands on 1.8 exactly, so the cap does not reduce it.
    on_cap = special_wall_dynamic_amplification(20.0u"ft", 10.0u"ft", 15)
    @test on_cap.ωv == 1.8
    @test !on_cap.capped
end

# Eq. (18.10.3.1): Ve = Ωv ωv Vu, and not above 3 Vu.
@testset "Design shear stops at three times Vu" begin
    under = special_wall_design_shear(100.0u"kip", 1.5, 1.5)
    @test under.product ≈ 225.0u"kip"
    @test under.cap ≈ 300.0u"kip"
    @test under.Ve ≈ 225.0u"kip"
    @test !under.capped

    over = special_wall_design_shear(100.0u"kip", 2.0, 1.8)
    @test over.product ≈ 360.0u"kip"
    @test over.Ve ≈ 300.0u"kip"
    @test over.capped

    # The product equal to 3 Vu is the limit, not a reduction.
    at = special_wall_design_shear(100.0u"kip", 1.0, 3.0)
    @test at.Ve ≈ at.cap
    @test !at.capped
end

# §18.10.4.4 (corpus: aci-318-19, page 324). 8√f′c Acv for the group,
# 10√f′c Acw for one segment. No λ.
@testset "Special-wall shear caps have no λ" begin
    group = special_wall_shear_limit(4.0u"ksi", 1000.0u"inch^2")
    @test group.factor == 8
    @test group.limit ≈ (8 * sqrt(4000) * 1000) * u"lbf"
    one = special_wall_shear_limit(4.0u"ksi", 1000.0u"inch^2"; individual = true)
    @test one.factor == 10
    @test one.limit ≈ (10 * sqrt(4000) * 1000) * u"lbf"
    # The Chapter 11 cap would multiply by λ. This one does not.
    @test group.limit > (8 * 0.75 * sqrt(4000) * 1000) * u"lbf"
end

# §18.10.6.3 reads the extreme fiber of a linearly elastic gross section.
# Rectangle: σ = P/Ag ± M (ℓw/2) / I, I = t ℓw³/12.
@testset "Gross-section fiber stress splits axial and flexure" begin
    # t = 12 in., ℓw = 120 in. Ag = 1440 in². I = 1,728,000 in⁴.
    # P = 1440 kip is 1 ksi. M = 28,800 kip·in puts another 1 ksi on one end.
    P = 1440.0u"kip"
    M = 28800.0u"kip*inch"
    both = wall_gross_fiber_stress(P, 0.0u"kip*inch", 120.0u"inch", 12.0u"inch")
    @test both.axial ≈ 1.0u"ksi"
    @test both.flexure ≈ 0.0u"ksi"
    @test both.at_positive_end ≈ 1.0u"ksi"
    @test both.at_negative_end ≈ 1.0u"ksi"

    bent = wall_gross_fiber_stress(P, M, 120.0u"inch", 12.0u"inch")
    @test bent.flexure ≈ 1.0u"ksi"
    @test bent.at_positive_end ≈ 2.0u"ksi"
    @test bent.at_negative_end ≈ 0.0u"ksi"

    # The opposite moment swaps the ends.
    flipped = wall_gross_fiber_stress(P, -M, 120.0u"inch", 12.0u"inch")
    @test flipped.at_positive_end ≈ 0.0u"ksi"
    @test flipped.at_negative_end ≈ 2.0u"ksi"

    # Tension is negative compression. Both ends.
    tension = wall_gross_fiber_stress(-P, 0.0u"kip*inch", 120.0u"inch", 12.0u"inch")
    @test tension.at_positive_end ≈ -1.0u"ksi"
    @test tension.at_negative_end ≈ -1.0u"ksi"
end

# Table 18.10.6.4(g): s ≤ Ash / (ratio · bc). The vertical spacing already
# required for the boundary is the other limit. The smaller one governs,
# and they share the result when they are equal.
@testset "Hoop spacing is the tighter of confinement and the vertical cap" begin
    # Ash = 0.40 in², bc = 10 in., ratio = 0.009.
    # s = 0.40 / (0.009 × 10) = 4.444 in.
    Ash = 0.40u"inch^2"
    bc = 10.0u"inch"
    ratio = 0.009
    amount = boundary_hoop_spacing(Ash, bc, ratio, 6.0u"inch")
    @test amount.from_amount ≈ (0.40 / 0.09) * u"inch"
    @test amount.by === :amount
    @test amount.spacing ≈ amount.from_amount

    vertical = boundary_hoop_spacing(Ash, bc, ratio, 3.0u"inch")
    @test vertical.by === :vertical
    @test vertical.spacing ≈ 3.0u"inch"

    tied = boundary_hoop_spacing(Ash, bc, ratio, amount.from_amount)
    @test tied.by === :both
    @test tied.spacing ≈ amount.from_amount
end

# §18.10.2.3(b) (corpus: aci-318-19, page 320): where yielding is likely,
# development lengths are 1.25 times the values calculated for fy in tension.
# That value is §25.4.2.1, including its 12 in. minimum.
@testset "Yielding multiplies the tension development length" begin
    fy = 60.0u"ksi"
    # No. 3, favorable cover, √f′c at the 100 psi cap.
    # (1 · 60000) / (25 · 100) · 0.375 = 9 in., so the 12 in. floor is the length.
    kw = (; favorable_cover = true)
    plain = boundary_bar_development(3, 10.0u"ksi", fy; kw...)
    @test plain == straight_development_length(3, 10.0u"ksi", fy; kw...)
    @test plain ≈ 12.0u"inch"
    yielded = boundary_bar_development(3, 10.0u"ksi", fy; yielding_likely = true, kw...)
    @test yielded ≈ 1.25 * plain
    @test yielded ≈ 15.0u"inch"
    # 8 ksi still leaves the No. 3 equation under 12 in. The floor governs, so
    # f′c does not move the 1.25 length.
    softer = boundary_bar_development(3, 8.0u"ksi", fy; yielding_likely = true, kw...)
    @test softer ≈ yielded
    # No. 4 at 8 ksi is past 12 in. Only the development length moves.
    four = boundary_bar_development(4, 8.0u"ksi", fy; yielding_likely = true, kw...)
    @test four > softer
    @test four ≈ 1.25 * straight_development_length(4, 8.0u"ksi", fy; kw...)
    @test boundary_bar_development(4, 8.0u"ksi", fy; kw...) ==
        straight_development_length(4, 8.0u"ksi", fy; kw...)
    # The footing floor is §18.10.6.4(j)'s other term. It does not change ℓd,
    # and 15 in. is longer than 12 in., so development governs.
    ext = boundary_support_extension(yielded; into_foundation = true)
    @test ext.from_development ≈ yielded
    @test ext.from_footing ≈ 12.0u"inch"
    @test ext.required ≈ ext.from_development
end

# §25.7.2.2 (corpus: aci-318-19, page 501). No. 10 takes a No. 3 tie.
# No. 11, and any bundled bar, takes a No. 4. Crossties match the tie.
@testset "Tie size follows the enclosed bar" begin
    small = boundary_tie_bar_size(10)
    @test small.tie == 3
    @test small.crosstie == small.tie
    @test boundary_tie_bar_size(3).tie == 3
    @test boundary_tie_bar_size(11).tie == 4
    bundled = boundary_tie_bar_size(10; bundled = true)
    @test bundled.tie == 4
    @test boundary_tie_bar_size(8; bundled = true).tie == bundled.tie
    @test boundary_tie_bar_size(8).tie == 3
    @test boundary_tie_bar_size(14).tie == 4
    # No. 12 and No. 15 are not bars.
    @test_throws ArgumentError boundary_tie_bar_size(12)
    @test_throws ArgumentError boundary_tie_bar_size(15)
end

# Longer than twice the thickness needs overlapping hoops. Equality does not.
# hx is the lesser of 14 in. and two-thirds of the thickness.
@testset "Hoop arrangement opens on the element length" begin
    t = 12.0u"inch"
    one = boundary_hoop_arrangement(t, 24.0u"inch")
    @test one.hx ≈ 8.0u"inch"
    @test !one.overlapping_hoops
    @test one.crosstie_every_bar
    @test one.code_clear_limit ≈ 6.0u"inch"
    over = boundary_hoop_arrangement(t, 24.0u"inch" + 0.01u"inch")
    @test over.overlapping_hoops
    @test over.hx ≈ one.hx
    # A thicker element moves hx and can drop the overlap at the same length.
    thick = boundary_hoop_arrangement(18.0u"inch", 24.0u"inch")
    @test thick.hx ≈ 12.0u"inch"
    @test !thick.overlapping_hoops
    @test thick.hx != one.hx
end

# §18.10.7. ℓn/h ≥ 4 is a frame beam. ℓn/h < 2 and Vu at 4λ√f′c·Acw is diagonal.
# Between them the code permits either, and this function does not choose.
@testset "Coupling beam route follows aspect and shear" begin
    fc = 4.0u"ksi"
    Acw = 200.0u"inch^2"
    h = 24.0u"inch"
    quiet = coupling_beam_route(8.0u"ft", h, 1.0u"kip", 1.0, fc, Acw)
    @test quiet.aspect ≈ 4.0
    @test quiet.route === :moment_frame
    @test quiet.section == "18.10.7.1"
    @test quiet.stability_waived == false
    short = coupling_beam_route(4.0u"ft", h, quiet.shear_threshold, 1.0, fc, Acw)
    @test short.aspect ≈ 2.0
    @test short.route === :either
    deep = coupling_beam_route(4.0u"ft" - 0.01u"inch", h, quiet.shear_threshold, 1.0, fc, Acw)
    @test deep.route === :diagonal
    @test deep.section == "18.10.7.2"
    under = coupling_beam_route(4.0u"ft" - 0.01u"inch", h,
                                quiet.shear_threshold - 1.0u"lbf", 1.0, fc, Acw)
    @test under.route === :either
    @test under.section == "18.10.7.3"
    # λ moves the shear threshold and not the aspect route.
    heavy = coupling_beam_route(8.0u"ft", h, 1.0u"kip", 0.75, fc, Acw)
    @test heavy.route === quiet.route
    @test heavy.shear_threshold < quiet.shear_threshold
    # The diagonal strength is 2·Avd·fy·sinα, capped at 10√f′c·Acw.
    α = 30u"°"
    steel = coupling_beam_diagonal_strength(0.2u"inch^2", 60.0u"ksi", α, fc, Acw)
    @test steel.by === :steel
    @test steel.Vn ≈ 2 * 0.2u"inch^2" * 60.0u"ksi" * sin(ustrip(u"rad", α))
    capped = coupling_beam_diagonal_strength(4.0u"inch^2", 60.0u"ksi", α, fc, Acw)
    @test capped.by === :cap
    @test capped.cap ≈ (10 * sqrt(4000) * 200) * u"lbf"
    @test capped.Vn ≈ capped.cap
    @test steel.cap ≈ capped.cap
end

# §18.14.3.1: moments from δu that are not calculated require §18.14.3.3.
# §18.14.3.2(a): hoops open only when Pu exceeds Ag·f′c/10.
@testset "A gravity frame outside the system takes §18.14" begin
    open = gravity_frame_seismic_section(; sdc = :C,
        induced_forces_calculated = false, induced_exceeds_strength = true)
    @test open.applies == false
    unchecked = gravity_frame_seismic_section(; sdc = :D,
        induced_forces_calculated = false, induced_exceeds_strength = false)
    @test unchecked.section == "18.14.3.3"
    held = gravity_frame_seismic_section(; sdc = :D,
        induced_forces_calculated = true, induced_exceeds_strength = false)
    @test held.section == "18.14.3.2"
    over = gravity_frame_seismic_section(; sdc = :F,
        induced_forces_calculated = true, induced_exceeds_strength = true)
    @test over.section == "18.14.3.3"
    Ag = 200.0u"inch^2"
    fc = 4.0u"ksi"
    d = 20.0u"inch"
    cut = Ag * fc / 10
    at = gravity_beam_transverse_limit(d, 1.0u"inch"; Pu = cut, Ag = Ag, fc = fc)
    @test at.hoops_required == false
    @test at.spacing ≈ 10.0u"inch"
    past = gravity_beam_transverse_limit(d, 1.0u"inch"; Pu = cut + 1.0u"lbf", Ag = Ag, fc = fc)
    @test past.hoops_required
    @test past.spacing ≈ 6.0u"inch"
    @test past.from_depth ≈ at.from_depth
    fine = gravity_beam_transverse_limit(d, 0.5u"inch"; Pu = cut + 1.0u"lbf", Ag = Ag, fc = fc)
    @test fine.spacing ≈ 3.0u"inch"
    shallow = gravity_beam_transverse_limit(8.0u"inch", 1.0u"inch";
                                            Pu = cut + 1.0u"lbf", Ag = Ag, fc = fc)
    @test shallow.hoops_required
    @test shallow.spacing ≈ 4.0u"inch"
end

# §18.14.5 (corpus: aci-318-19, PDF pages 354–355). The exemption is checked
# before the sloping line. Equality of the line requires reinforcement.
@testset "Slab-column shear follows the §18.14.5 line" begin
    fc = 4000.0u"psi"
    quiet = gravity_slab_column_shear(0.005, 0.70, fc)
    @test !quiet.required
    @test quiet.exempt == 0.005
    above = gravity_slab_column_shear(0.006, 0.70, fc)
    @test above.required
    @test abs(above.drift_limit) < 1e-9
    on_line = gravity_slab_column_shear(0.020, 0.30, fc)
    @test on_line.required
    @test on_line.drift_limit ≈ 0.020
    under = gravity_slab_column_shear(0.019, 0.30, fc)
    @test !under.required
    zero = gravity_slab_column_shear(0.035, 0.0, fc)
    @test zero.required
    @test zero.vs ≈ (3.5 * sqrt(4000)) * u"psi"
    @test zero.extension_thicknesses == 4
    pt_exempt = gravity_slab_column_shear(0.010, 0.50, fc;
        prestressed=true, fpc_meets_8_6_2_1=true)
    @test !pt_exempt.required
    @test pt_exempt.post_tensioned
    pt_line = gravity_slab_column_shear(0.025, 0.30, fc;
        prestressed=true, fpc_meets_8_6_2_1=true)
    @test pt_line.required
    @test pt_line.drift_limit ≈ 0.025
    plain = gravity_slab_column_shear(0.006, 0.0, fc;
        prestressed=true, fpc_meets_8_6_2_1=false)
    @test !plain.post_tensioned
    @test !plain.required
end

# §18.7.5.1 (corpus: aci-318-19, PDF page 309): ℓo is the greatest of the three.
@testset "Special-column hoop length is the greatest of depth, ℓu/6, and 18 in." begin
    @test special_column_hoop_length(16.0u"inch", 8.0u"ft") ≈ 18.0u"inch"
    @test special_column_hoop_length(24.0u"inch", 8.0u"ft") ≈ 24.0u"inch"
    @test special_column_hoop_length(20.0u"inch", 12.0u"ft") ≈ 24.0u"inch"
end

# §18.7.6.1.1 (corpus: aci-318-19, PDF page 312). Ve is the probable-moment
# shear, not below the analyzed shear, and need not exceed the beam joint.
@testset "Special-column shear is the probable-moment shear, floored at Vu" begin
    shear = special_column_design_shear(100.0u"kip*ft", 100.0u"kip*ft", 10.0u"ft", 10.0u"kip")
    @test shear.from_column ≈ 20.0u"kip"
    @test shear.Ve ≈ 20.0u"kip"
    floored = special_column_design_shear(100.0u"kip*ft", 100.0u"kip*ft", 10.0u"ft", 30.0u"kip")
    @test floored.Ve ≈ 30.0u"kip"
    capped = special_column_design_shear(100.0u"kip*ft", 100.0u"kip*ft", 10.0u"ft", 10.0u"kip";
                                         beam_shear=12.0u"kip")
    @test capped.Ve ≈ 12.0u"kip"
    held = special_column_design_shear(100.0u"kip*ft", 100.0u"kip*ft", 10.0u"ft", 15.0u"kip";
                                       beam_shear=12.0u"kip")
    @test held.Ve ≈ 15.0u"kip"
end

# §18.2.5 through §20.2.2.5, required by §18.14.3.3(a).
@testset "Special-moment-frame materials are Grade 60 or 80 and at least 3000 psi" begin
    ok = special_moment_frame_materials(4000.0u"psi", 60.0u"ksi")
    @test ok.ok
    @test !special_moment_frame_materials(2500.0u"psi", 60.0u"ksi").ok
    @test !special_moment_frame_materials(4000.0u"psi", 40.0u"ksi").ok
    @test special_moment_frame_materials(4000.0u"psi", 80.0u"ksi").ok
    @test !special_moment_frame_materials(4000.0u"psi", 100.0u"ksi").ok
    @test special_moment_frame_materials(5000.0u"psi", 60.0u"ksi"; lightweight = true).ok
    @test !special_moment_frame_materials(6000.0u"psi", 60.0u"ksi"; lightweight = true).ok
end

# §18.14.3.3(b): the beam stirrups follow §18.6.5 and stay within d/2.
@testset "A gravity beam in a high category is designed for its probable shear" begin
    sec = RCBeamSection(; b = 12.0u"inch", h = 24.0u"inch", bar_size = 8, n_bars = 4,
                        cover = 1.5u"inch", stirrup_size = 3)
    md = detail_beam(sec; span = 360.0u"inch", supports = (20.0u"inch", 20.0u"inch"),
                     exterior = (true, true), Vu = 40.0u"kip",
                     fc = 4000.0u"psi", fy = 60_000.0u"psi", fyt = 60_000.0u"psi",
                     gravity_seismic = true)
    stirrups = only(g for g in md.groups if g.role === :stirrup)
    @test occursin("18.6.5", stirrups.note)
    @test any(n -> occursin("18.14.3.2", n), md.notes)
    gaps = diff(stirrups.x_positions)
    @test maximum(gaps) <= ustrip(u"m", sec.d / 2) + 1e-6
    @test !any(w -> occursin("20.2.2.5", w), md.warnings)
end
