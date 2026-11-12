# Solid-head punching.
#
# The outer section is spSlab Eq. 2-14 (sp-de-two-way-waffle-slab-aci318-14,
# reference text pages 61–62): d_v = 4 × 17 in × 7.32 in / 150 in = 3.32 in,
# and v_u = V_u / (b_0 d_v). The example's 1.10 on v_c and its eccentric
# shear are not applied. The column section keeps moment transfer. One-way
# rib shear, at d from the head face, is the only check that can take the
# joist increase.

using Test
using Unitful
using StructuralSizer

const SS = StructuralSizer

@testset "rib-web punching is the spSlab equivalent thickness, direct shear only" begin
    web = 4 * 17.0u"inch" * 7.32u"inch"
    width = 150.0u"inch"
    d_v = SS.equivalent_rib_thickness(web, width)
    @test ustrip(u"inch", d_v) ≈ 3.32 rtol = 1e-3

    Vu = 133.02u"kip"
    b0 = 339.75u"inch"
    fc = 5000.0u"psi"
    # A 10 in depth keeps λs = 1, so the capacity is the example's (ACI 318-14).
    chk = SS.check_rib_web_punching(Vu, b0, web, width, fc; d_size = 10.0u"inch",
                                    side_long = 159.88u"inch", side_short = 89.94u"inch",
                                    position = :edge)
    @test ustrip(u"inch", chk.d_equivalent) ≈ 3.32 rtol = 1e-3
    @test ustrip(u"psi", chk.vu) ≈ 117.94 rtol = 1e-3
    @test chk.vu ≈ Vu / (b0 * chk.d_equivalent)
    # Page 62 reports φv_c = 133.77 psi with the 1.10 still in v_c.
    # Without that factor the same term is 133.77 / 1.10.
    @test ustrip(u"psi", chk.φvc) ≈ 133.77 / 1.10 rtol = 1e-2
    @test chk.ok
    # λs comes from the member depth, not the 3.32 in smeared web.
    deep = SS.check_rib_web_punching(Vu, b0, web, width, fc; d_size = 15.88u"inch",
                                     side_long = 159.88u"inch", side_short = 89.94u"inch",
                                     position = :edge)
    @test deep.φvc ≈ SS.size_effect_factor(15.88u"inch") * chk.φvc
    @test chk.eccentric_shear == false
    @test chk.joist_increase == false
    @test occursin("not covered by a code clause", chk.eccentric_shear_note)

    qu = 0.340u"kip" / (1.0u"ft"^2)
    area = (89.94u"inch") * (159.88u"inch")
    deducted = SS.check_rib_web_punching(Vu + qu * area, b0, web, width, fc; d_size = 10.0u"inch",
                                         side_long = 159.88u"inch", side_short = 89.94u"inch",
                                         position = :edge, qu = qu, section_area = area)
    @test deducted.Vu ≈ Vu rtol = 1e-6
    @test_throws ArgumentError SS.check_rib_web_punching(Vu, b0, web, width, fc; d_size = 10.0u"inch",
        side_long = 89.0u"inch", side_short = 100.0u"inch", position = :edge)
end

@testset "column punching through the head keeps moment transfer and no 1.10" begin
    col = (position = :interior, c1 = 20.0u"inch", c2 = 20.0u"inch", shape = :rectangular)
    d = 15.88u"inch"
    h = 17.0u"inch"
    fc = 5000.0u"psi"
    Vu = 100.0u"kip"
    Mub = 50.0u"kip" * u"ft"
    wrapped = SS.check_solid_head_column_punching(col, Vu, Mub, d, h, fc)
    direct = SS.check_punching_for_column(col, Vu, Mub, d, h, fc)
    @test wrapped.vu ≈ direct.vu
    @test wrapped.ratio ≈ direct.ratio
    @test wrapped.eccentric_shear
    @test wrapped.joist_increase == false
    @test wrapped.section === :column
end

@testset "one-way rib shear at the head takes 1.10 only when the joist qualifies" begin
    qualifying = JoistConstruction(:two_orthogonal, 6u"inch", 14u"inch", 24u"inch", 3u"inch")
    narrow = JoistConstruction(:one_way, 3.9u"inch", 12u"inch", 20u"inch", 2.5u"inch")
    bw = 6.0u"inch"
    d = 14.0u"inch"
    fc = 4000.0u"psi"
    raised = SS.check_rib_shear_at_head(1.0u"kip", bw, d, fc, qualifying)
    plain = SS.check_rib_shear_at_head(1.0u"kip", bw, d, fc, narrow)
    beam = SS.check_rib_shear_at_head(1.0u"kip", bw, d, fc, nothing)
    @test raised.joist_increase
    @test raised.Vc ≈ SS.JOIST_ONE_WAY_VC_FACTOR * plain.Vc
    @test plain.joist_increase == false
    @test beam.Vc ≈ plain.Vc
    @test raised.section === :rib_one_way
end

@testset "the three head checks govern together" begin
    col = (position = :edge, c1 = 20.0u"inch", c2 = 20.0u"inch", shape = :rectangular)
    web = 4 * 17.0u"inch" * 7.32u"inch"
    qualifying = JoistConstruction(:two_orthogonal, 6u"inch", 14u"inch", 24u"inch", 3u"inch")
    rib = (Vu = 1.0u"kip", bw = 6.0u"inch", d = 14.0u"inch", joist = qualifying)
    chk = SS.check_solid_head_punching(col, 133.02u"kip", 40.0u"kip" * u"ft",
                                       15.88u"inch", 17.0u"inch", 5000.0u"psi", [rib];
                                       b0 = 339.75u"inch", web_area = web, head_width = 150.0u"inch",
                                       side_long = 159.88u"inch", side_short = 89.94u"inch",
                                       position = :edge)
    @test chk.rib_web.eccentric_shear == false
    @test chk.column.eccentric_shear
    @test chk.ribs[1].joist_increase
    @test chk.governing in (:column, :rib_web, :rib_one_way)
    @test chk.direction === nothing

    # Both column moments are nonzero, so one corner is the peak. The rib
    # shear is too small to govern. ACI 318-11 R11.11.7.2, page 210.
    col_in = (position = :interior, c1 = 16.0u"inch", c2 = 16.0u"inch",
              shape = :rectangular, θ = 0.0)
    faced = SS.check_solid_head_punching(
        col_in, 200.0u"kip", 80.0u"kip" * u"ft", 6.0u"inch", 8.0u"inch", 4000.0u"psi",
        [(Vu = 0.1u"kip", bw = 6.0u"inch", d = 5.0u"inch", joist = nothing)];
        Muy = 40.0u"kip" * u"ft", b0 = 80.0u"inch", web_area = web,
        head_width = 40.0u"inch", side_long = 40.0u"inch", side_short = 40.0u"inch",
        position = :interior, θ = 0.0, span_axis = (1.0, 0.0))
    @test faced.governing === :column
    @test faced.direction !== nothing
    @test faced.direction[1] > 0 && faced.direction[2] > 0
    @test chk.Vu > 0u"N"
    @test chk.ok == (chk.column.ok && chk.rib_web.ok && chk.ribs[1].ok)
    @test_throws ArgumentError SS.check_solid_head_punching(
        col, 1.0u"kip", 0.0u"kip"*u"ft", 10.0u"inch", 12.0u"inch", 4000.0u"psi", [];
        b0 = 40.0u"inch", web_area = web, head_width = 150.0u"inch",
        side_long = 20.0u"inch", side_short = 20.0u"inch", position = :edge)
end

@testset "hogging compression in the stem grows along that rib" begin
    # ACI 318-11 §10.2.7 and §10.3.4. The limit is max_singly_reinforced at
    # εt = 0.005, φ = 0.90. A wider stem raises the capacity. A deeper block
    # than the stem is not this section.
    bw = 6.0u"inch"
    d = 14.0u"inch"
    fc = 4000.0u"psi"
    fy = 60.0u"ksi"
    cap = SS.max_singly_reinforced(bw, d, fc, fy)
    φMn = 0.90 * cap.Mn_max
    under = SS.check_rib_hogging_at_head(0.5 * φMn, bw, d, fc, fy)
    over = SS.check_rib_hogging_at_head(1.5 * φMn, bw, d, fc, fy)
    @test under.ok && under.ratio ≈ 0.5
    @test !over.ok && over.ratio ≈ 1.5
    @test over.φMn ≈ φMn
    wide = SS.check_rib_hogging_at_head(1.5 * φMn, 2 * bw, d, fc, fy)
    deeper = SS.check_rib_hogging_at_head(1.5 * φMn, bw, 1.2 * d, fc, fy)
    @test wide.φMn > over.φMn
    @test deeper.ratio < over.ratio
    deep = SS.check_rib_hogging_at_head(1.5 * φMn, bw, d, fc, fy; stem = 0.5u"inch")
    @test deep.ok && deep.in_stem == false
    again = SS.check_rib_hogging_at_head(1.5 * φMn, bw, d, fc, fy)
    @test again.ratio ≈ over.ratio

    col = (position = :interior, c1 = 16.0u"inch", c2 = 16.0u"inch",
           shape = :rectangular, θ = 0.0)
    web = 4 * 6.0u"inch" * 14.0u"inch"
    rib = (Vu = 0.1u"kip", bw = bw, d = d, joist = nothing,
           outward = (1.0, 0.0), Mu = 1.5 * φMn)
    chk = SS.check_solid_head_punching(
        col, 5.0u"kip", 0.0u"kip" * u"ft", 16.0u"inch", 18.0u"inch", fc, [rib];
        b0 = 80.0u"inch", web_area = web, head_width = 40.0u"inch",
        side_long = 40.0u"inch", side_short = 40.0u"inch", position = :interior, fy = fy)
    @test chk.governing === :rib_hogging && !chk.ok
    @test chk.direction == (1.0, 0.0)
    @test chk.Mu ≈ 1.5 * φMn
    zero = SS.check_solid_head_punching(
        col, 0.0u"kip", 0.0u"kip" * u"ft", 16.0u"inch", 18.0u"inch", fc,
        [(Vu = 0.1u"kip", bw = bw, d = d, joist = nothing,
          outward = (1.0, 0.0), Mu = 0.0u"N*m")];
        b0 = 80.0u"inch", web_area = web, head_width = 40.0u"inch",
        side_long = 40.0u"inch", side_short = 40.0u"inch", position = :interior, fy = fy)
    @test zero.governing !== :rib_hogging
end

@testset "the waffle example's exterior head" begin
    # sp-de-two-way-waffle-slab-aci318-14, pages 55–56 and 61–63.
    # Column section: 20 in square, d = 15.88 in through the 17 in head.
    # Vu = 163.66 kip and the joint moment 462.75 kip·ft are before the
    # centroid correction. The example's combined stress is 200.10 psi and
    # φvc = 212.13 psi (ACI 318-14, no size effect). d > 10 in, so the
    # size-effect factor in our capacity is below 1.
    col = (position = :edge, c1 = 20.0u"inch", c2 = 20.0u"inch", shape = :rectangular)
    column = SS.check_solid_head_column_punching(
        col, 163.66u"kip", 462.75u"kip" * u"ft", 15.88u"inch", 17.0u"inch", 5000.0u"psi";
        free_edge_parallel = :c2)
    @test ustrip(u"inch", column.b0) ≈ 91.75 atol = 0.02
    @test ustrip(u"psi", column.vu) ≈ 200.10 atol = 0.2
    λs = SS.size_effect_factor(15.88u"inch")
    @test λs < 1
    @test ustrip(u"psi", column.φvc) ≈ 212.13 * λs atol = 0.2
    @test column.ok == false
    @test column.joist_increase == false

    # Outer section, page 61. The head face is 82 in from the free edge and
    # the drop is 12 ft parallel to that edge. vu = 117.94 psi.
    d_off = 15.88u"inch"
    section = SS.rib_web_critical_section(82.0u"inch", 144.0u"inch", d_off; position = :edge)
    web = 4 * 17.0u"inch" * 7.32u"inch"
    outer = SS.check_rib_web_punching(133.02u"kip", section.b0, web, 150.0u"inch", 5000.0u"psi";
                                      d_size = d_off,
                                      side_long = section.side_long, side_short = section.side_short,
                                      position = :edge)
    @test ustrip(u"inch", outer.d_equivalent) ≈ 3.32 atol = 0.01
    @test ustrip(u"psi", outer.vu) ≈ 117.94 atol = 0.05
    # Page 62, three-term capacity with the 1.10 still in: φvc = 133.77 psi.
    # Page 63 then drops the (2 + αs d/b0) term (spSlab Eq. 2-46) and gets
    # φvc = 116.67 psi. That reduced capacity is not used. ACI 318-19's size
    # effect at d = 15.88 in brings φvc below vu, so the section fails here
    # where the 318-14 example passes it.
    @test ustrip(u"psi", outer.φvc) ≈ 133.77 / 1.10 * λs atol = 0.3
    @test outer.ok == false
    @test outer.eccentric_shear == false
end

@testset "a failing head grows by one rib module" begin
    # Exterior head, page 61: b1 = 20/2 + 15.88/2 + 144/2 = 89.94 in,
    # b2 = 15.88 + 144 = 159.88 in. The offset is the head's 15.88 in,
    # not the 3.32 in equivalent thickness.
    d_off = 15.88u"inch"
    edge = SS.rib_web_critical_section(82.0u"inch", 144.0u"inch", d_off; position = :edge)
    @test ustrip(u"inch", edge.b1) ≈ 89.94 atol = 0.02
    @test ustrip(u"inch", edge.b2) ≈ 159.88 atol = 0.02
    @test ustrip(u"inch", edge.b0) ≈ 339.75 atol = 0.02
    @test edge.section_area ≈ edge.b1 * edge.b2
    corner = SS.rib_web_critical_section(82.0u"inch", 82.0u"inch", d_off; position = :corner)
    @test ustrip(u"inch", corner.b0) ≈ 179.88 atol = 0.02
    interior = SS.rib_web_critical_section(144.0u"inch", 144.0u"inch", d_off; position = :interior)
    @test ustrip(u"inch", interior.b0) ≈ 639.52 atol = 0.05
    @test_throws ArgumentError SS.rib_web_critical_section(82.0u"inch", 82.0u"inch", d_off;
                                                          position = :capital)

    # One web per module the head covers. 0.2 is not yet snapped.
    @test SS.ribs_across_solid_head(8, 0.25) == 2
    @test SS.ribs_across_solid_head(4, 0.25) == 1
    @test_throws ArgumentError SS.ribs_across_solid_head(8, 0.2)
    @test_throws ArgumentError SS.ribs_across_solid_head(8, 0.0)
end
