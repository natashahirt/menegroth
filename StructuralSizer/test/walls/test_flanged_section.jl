# Gross-section stress for §18.10.6.3 and the strain-compatibility neutral
# axis for §18.10.6.2, on a wall with a flange at one end. An L and a T with
# the same flange width are the same section in the plane of the web.

using Test
using Unitful
using StructuralSizer

@testset "A flange the thickness of the web is the rectangular section" begin
    lw = 120.0u"inch"
    t = 12.0u"inch"
    P = 1440.0u"kip"
    M = 28800.0u"kip*inch"
    rect = wall_gross_fiber_stress(P, M, lw, t)
    for flange_at in (:positive, :negative)
        flanged = wall_flanged_fiber_stress(P, M, lw, t, t, t; flange_at = flange_at)
        @test flanged.section.centroid ≈ lw / 2
        @test flanged.section.area ≈ t * lw
        @test flanged.at_positive_end ≈ rect.at_positive_end
        @test flanged.at_negative_end ≈ rect.at_negative_end
        @test flanged.axial ≈ 1.0u"ksi"
    end
    # No moment. Both fibers are the axial stress, on a rectangle and on a flange.
    quiet = wall_flanged_fiber_stress(P, 0.0u"kip*inch", lw, t, 12.0u"inch", 48.0u"inch")
    @test quiet.at_positive_end ≈ quiet.at_negative_end
    @test quiet.at_positive_end ≈ quiet.axial
    @test quiet.axial < 1.0u"ksi"
end

@testset "A wider flange moves the centroid toward itself and lowers that fiber" begin
    lw = 120.0u"inch"
    tw = 12.0u"inch"
    tf = 12.0u"inch"
    P = 1440.0u"kip"
    M = 28800.0u"kip*inch"
    narrow = wall_flanged_gross_section(lw, tw, tf, 24.0u"inch"; flange_at = :positive)
    wide = wall_flanged_gross_section(lw, tw, tf, 72.0u"inch"; flange_at = :positive)
    @test narrow.centroid > lw / 2
    @test wide.centroid > narrow.centroid
    @test wide.area > narrow.area
    @test wide.inertia > narrow.inertia

    # Same axial force. More area, less stress, and the two ends stay equal.
    axial_narrow = wall_flanged_fiber_stress(P, 0.0u"kip*inch", lw, tw, tf, 24.0u"inch")
    axial_wide = wall_flanged_fiber_stress(P, 0.0u"kip*inch", lw, tw, tf, 72.0u"inch")
    @test axial_wide.axial < axial_narrow.axial
    @test axial_wide.at_positive_end ≈ axial_wide.at_negative_end

    # Positive moment compresses the positive end. A flange there lowers that
    # fiber below the rectangular 2 ksi and can drop it through the stress cuts.
    rect = wall_gross_fiber_stress(P, M, lw, tw)
    @test rect.at_positive_end ≈ 2.0u"ksi"
    flanged = wall_flanged_fiber_stress(P, M, lw, tw, 24.0u"inch", 120.0u"inch")
    @test flanged.at_positive_end < rect.at_positive_end
    @test flanged.at_positive_end < 0.15 * 4.0u"ksi"

    # The mirror section with the opposite moment swaps the two fibers.
    mirrored = wall_flanged_fiber_stress(P, -M, lw, tw, 24.0u"inch", 120.0u"inch";
                                        flange_at = :negative)
    @test mirrored.at_negative_end ≈ flanged.at_positive_end
    @test mirrored.at_positive_end ≈ flanged.at_negative_end

    # hwcs/ℓw < 2, so the route is stress. The rectangular fiber is above
    # 0.2 f′c. The flanged fiber is below 0.15 f′c.
    fc = 4.0u"ksi"
    common = (
        lw = lw, hw = 250.0u"inch", hwcs = 150.0u"inch",
        continuous = false, single_critical_section = false,
        fc = fc, c = 40.0u"inch", b = 16.0u"inch", hu = 32.0u"inch",
        Vu = 200.0u"kip", λ = 1.0, Acv = lw * tw,
    )
    triggered = special_boundary_composer(; common..., σ = rect.at_positive_end)
    @test triggered.route === :stress
    @test triggered.required_by === :stress
    eased = special_boundary_composer(; common..., σ = flanged.at_positive_end)
    @test eased.required_by === :may_discontinue
    @test eased.length === nothing
end

@testset "Strain compatibility recovers the rectangle, then the flange changes c" begin
    psi = Asap.PSI_TO_PA
    fc = 4000.0 * psi
    fy = 60000.0 * psi
    Es = 29000000.0 * psi
    lw = 3.0
    tw = 0.30
    tf = 0.30
    Ast = 0.01 * lw * tw
    c = 0.80
    rect = wall_pm_at_c_si(fc, fy, Es, lw, tw, Ast, c)
    for flange_in_compression in (true, false)
        same = wall_flanged_pm_at_c_si(fc, fy, Es, lw, tw, tf, tw, Ast, c;
                                      flange_in_compression = flange_in_compression)
        @test same.Pn ≈ rect.Pn
        @test same.Mn ≈ rect.Mn
        @test same.εt ≈ rect.εt
    end

    # a = 0.85 c. c = 0.20 m keeps the block inside a 0.30 m flange.
    c_in = 0.20
    a = 0.85 * c_in
    @test a < tf
    bf = 1.20
    inside = wall_flanged_pm_at_c_si(fc, fy, Es, lw, tw, tf, bf, Ast, c_in;
                                   flange_in_compression = true)
    @test inside.a ≈ a
    @test inside.block_area ≈ bf * a
    web_face = wall_flanged_pm_at_c_si(fc, fy, Es, lw, tw, tf, bf, Ast, c_in;
                                     flange_in_compression = false)
    @test web_face.block_area ≈ tw * a
    @test inside.Pn > web_face.Pn

    # The block crosses the flange. Area is the flange plus the stem part.
    c_past = 1.0
    a_past = 0.85 * c_past
    @test a_past > tf
    crossed = wall_flanged_pm_at_c_si(fc, fy, Es, lw, tw, tf, bf, Ast, c_past)
    @test crossed.block_area ≈ bf * tf + tw * (a_past - tf)
    @test crossed.Pn > inside.Pn

    # The same axial force. A deeper demand needs a deeper axis, and a flange
    # on the compression face reaches that force at a smaller axis than the web.
    Nu = rect.Pn
    web = wall_flanged_c_at_axial_si(fc, fy, Es, lw, tw, tf, tw, Ast, Nu)
    flange = wall_flanged_c_at_axial_si(fc, fy, Es, lw, tw, tf, bf, Ast, Nu;
                                      flange_in_compression = true)
    tip = wall_flanged_c_at_axial_si(fc, fy, Es, lw, tw, tf, bf, Ast, Nu;
                                   flange_in_compression = false)
    @test web.converged && flange.converged && tip.converged
    @test web.c ≈ c rtol = 1e-3
    @test flange.c < web.c
    heavier = wall_flanged_c_at_axial_si(fc, fy, Es, lw, tw, tf, bf, Ast, 1.2 * Nu;
                                       flange_in_compression = true)
    @test heavier.converged
    @test heavier.c > flange.c

    # Above the squash load there is no axis, and the moment is not invented.
    squash = wall_flanged_c_at_axial_si(fc, fy, Es, lw, tw, tf, bf, Ast, 1e12)
    @test !squash.converged
    @test squash.φMn == 0.0
end

@testset "Return bars in the flange zone raise the tension-side moment" begin
    psi = Asap.PSI_TO_PA
    fc = 4000.0 * psi
    fy = 60000.0 * psi
    Es = 29000000.0 * psi
    lw = 3.0
    tw = 0.30
    tf = 0.30
    bf = 1.20
    Ast = 0.0025 * lw * tw
    c = 0.40
    bare = wall_flanged_pm_at_c_si(fc, fy, Es, lw, tw, tf, bf, Ast, c;
                                  flange_in_compression = false)
    zero = wall_flanged_pm_at_c_si(fc, fy, Es, lw, tw, tf, bf, Ast, c;
                                  flange_in_compression = false, As_flange = 0.0)
    @test zero.Pn ≈ bare.Pn
    @test zero.Mn ≈ bare.Mn
    # The flange is the tension face. Its bars sit past the neutral axis.
    with = wall_flanged_pm_at_c_si(fc, fy, Es, lw, tw, tf, bf, Ast, c;
                                  flange_in_compression = false, As_flange = 0.004)
    @test with.Mn > bare.Mn
    # A flange thinner than a layer still places the area on the nearest layer.
    thin = wall_flanged_pm_at_c_si(fc, fy, Es, lw, tw, 0.02, bf, Ast, c;
                                  flange_in_compression = true, As_flange = 0.004)
    none = wall_flanged_pm_at_c_si(fc, fy, Es, lw, tw, 0.02, bf, Ast, c;
                                  flange_in_compression = true)
    @test thin.Pn != none.Pn || thin.Mn != none.Mn
    # Added bars at both ends, the same group the rectangular section uses.
    ended = wall_flanged_pm_at_c_si(fc, fy, Es, lw, tw, tf, bf, Ast, c;
                                   flange_in_compression = false, As_flange = 0.004,
                                   As_end = 0.001, inset = 0.15)
    @test ended.Mn > with.Mn
    @test flange_end_compressed(:positive, 1.0)
    @test !flange_end_compressed(:negative, 1.0)
    @test flange_end_compressed(:negative, -1.0)
end

@testset "A flange at each end uses one Whitney block" begin
    psi = Asap.PSI_TO_PA
    fc = 4000.0 * psi
    fy = 60000.0 * psi
    Es = 29000000.0 * psi
    lw = 3.0
    tw = 0.30
    tf = 0.25
    bf = 1.20
    tf_far = 0.20
    Ast = 0.0025 * lw * tw
    # A far end as wide as the web, with no bars, is the one-flange section.
    c = 0.50
    one = wall_flanged_pm_at_c_si(fc, fy, Es, lw, tw, tf, bf, Ast, c;
                                 flange_in_compression = true, As_flange = 0.003)
    same = wall_two_flange_pm_at_c_si(fc, fy, Es, lw, tw, tf, bf, tf_far, tw, Ast, c;
                                     compress_positive = true, As_pos = 0.003, As_neg = 0.0)
    @test same.Pn ≈ one.Pn rtol = 1e-8
    @test same.Mn ≈ one.Mn rtol = 1e-8
    @test same.block_area ≈ one.block_area rtol = 1e-8
    # Bars at the far end raise the moment when that end is in tension.
    both = wall_two_flange_pm_at_c_si(fc, fy, Es, lw, tw, tf, bf, tf_far, 0.90, Ast, c;
                                     compress_positive = true, As_pos = 0.003, As_neg = 0.004)
    @test both.Mn > same.Mn
    # a through both flanges: bf_pos*tf_pos + tw*stem + bf_neg*tf_neg, once.
    deep = wall_two_flange_pm_at_c_si(fc, fy, Es, lw, tw, tf, bf, tf_far, 0.90, Ast, 2 * lw;
                                     compress_positive = true)
    stem = lw - tf - tf_far
    @test deep.a ≈ lw
    @test deep.block_area ≈ bf * tf + tw * stem + 0.90 * tf_far rtol = 1e-8
    gross = wall_two_flange_gross_section(
        lw * u"m", tw * u"m", tf * u"m", bf * u"m", tf_far * u"m", tw * u"m")
    one_gross = wall_flanged_gross_section(
        lw * u"m", tw * u"m", tf * u"m", bf * u"m"; flange_at = :positive)
    @test ustrip(u"m^2", gross.area) ≈ ustrip(u"m^2", one_gross.area)
    @test ustrip(u"m", gross.centroid) ≈ ustrip(u"m", one_gross.centroid)
end
