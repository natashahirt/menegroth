# Joist ribs as T-beams: the §8.12 clear-distance cap, the per-web flange,
# the §8.13 rib catalog, and the §8.13.8 shear increase in the beam checker.
# Corpus: aci-318-11, PDF pages 119–121 (§8.12, §8.13), 97 (§7.7.1).

using Test
using Unitful
using StructuralSizer
using Asap: kip

const SS = StructuralSizer

@testset "Joist ribs (ACI 318-11 §8.12, §8.13)" begin
    @testset "§8.12 clear-distance cap and one-sided override" begin
        bw, hf, ln = 6u"inch", 3u"inch", 360u"inch"
        side = SS.SideExtentProfile(ustrip(u"m", 30u"inch"))
        # Both sides: min(8hf = 24, ln/8 = 45, d = 30) = 24 per side.
        @test SS.flange_width_at_station(bw, hf, ln, 0.5; left = side, right = side) ≈
              54u"inch"
        # Half the clear distance to the next web, 12 in, governs.
        bf = SS.flange_width_at_station(bw, hf, ln, 0.5; left = side, right = side,
                                        left_clear = 12u"inch", right_clear = 12u"inch")
        @test bf ≈ 30u"inch"
        # §8.12.3 on both present sides: min(6hf = 18, ln/12 = 30, d = 30) = 18.
        @test SS.flange_width_at_station(bw, hf, ln, 0.5; left = side, right = side,
                                         one_side = true) ≈ 42u"inch"
        # A negative clear distance contributes no overhang.
        @test SS.flange_width_at_station(bw, hf, ln, 0.5; left = side, right = side,
                                         left_clear = -1u"inch") ≈ 30u"inch"
    end

    @testset "§8.13 rib catalog" begin
        s = 30u"inch"
        hf = 3u"inch"
        # Interior rib between ribs of the same web: half clear = (s − bw)/2,
        # so bf = bw + 2·min(8hf, (s − bw)/2) = s here.
        bf_of = bw -> bw + 2 * min(8 * hf, (s - bw) / 2)
        cat = joist_rc_tbeams(flange_width = bf_of, flange_thickness = hf, center_spacing = s)
        @test !isempty(cat)
        for sec in cat
            bw_in = ustrip(u"inch", sec.bw)
            stem_in = ustrip(u"inch", sec.h - sec.hf)
            @test 4 <= bw_in <= 8                                   # §8.13.2
            @test stem_in <= 3.5 * bw_in + 1e-9                     # §8.13.2
            @test ustrip(u"inch", s) - bw_in <= 30                  # §8.13.3
            @test ustrip(u"inch", sec.cover) ≈ 0.75                 # §7.7.1(c)
            @test sec.bf ≈ bf_of(sec.bw)
            @test check_joist_construction(JoistConstruction(sec, s, :one_way)).vc_increase_permitted
        end
        @test any(sec -> sec.n_bars == 1, cat)
        @test maximum(sec -> sec.bw, cat) <= SS.MAX_JOIST_RIB_WIDTH

        # 40 in centers leave more than 30 in clear for every rib up to 8 in.
        @test isempty(joist_rc_tbeams(flange_width = 40u"inch", flange_thickness = hf,
                                      center_spacing = 40u"inch"))
        @test joist_center_feasible(30u"inch")
        @test joist_center_feasible(joist_fallback_center_spacing())
        @test joist_center_feasible(8u"inch" + 30u"inch")
        @test !joist_center_feasible(40u"inch")
        @test ustrip(u"inch", joist_fallback_center_spacing()) == 34

        # A function flange in the standard family varies with the web.
        std = standard_rc_tbeams(flange_width = bw -> bw + 40u"inch", flange_thickness = 5u"inch")
        @test all(sec -> sec.bf ≈ sec.bw + 40u"inch", std)
    end

    @testset "§8.13.8 Vc increase in the checker" begin
        rib = RCTBeamSection(bw = 6u"inch", h = 15u"inch", bf = 30u"inch", hf = 3u"inch",
                             bar_size = 5, n_bars = 1, cover = 0.75u"inch")
        plain = ACIBeamChecker()
        joist = ACIBeamChecker(joist_spacing = 30u"inch")
        @test SS._checker_vc_factor(plain, rib) == 1.0
        @test SS._checker_vc_factor(joist, rib) == 1.10
        # 40 in centers: 34 in clear fails §8.13.3, no increase.
        @test SS._checker_vc_factor(ACIBeamChecker(joist_spacing = 40u"inch"), rib) == 1.0
        # Rectangular sections are never ribs.
        rect = RCBeamSection(b = 12u"inch", h = 20u"inch", bar_size = 6, n_bars = 3)
        @test SS._checker_vc_factor(joist, rect) == 1.0

        fc_psi = 4000.0
        sqrt_fc = sqrt(fc_psi)
        bw_in = 6.0
        d_in = ustrip(u"inch", rib.d)
        expected = 0.75 * (1.10 * 2 * sqrt_fc * bw_in * d_in + 8 * sqrt_fc * bw_in * d_in) / 1000
        @test SS._compute_φVn_max(rib, fc_psi, 1.0; vc_factor = 1.10) ≈ expected
        # Axial path: the factor scales Vc only.
        Ag = bw_in * 15.0
        base = SS._φVn_with_axial(bw_in, d_in, Ag, Ag, fc_psi, 1.0, 0.0)
        boosted = SS._φVn_with_axial(bw_in, d_in, Ag, Ag, fc_psi, 1.0, 0.0; vc_factor = 1.10)
        @test boosted - base ≈ 0.75 * 0.10 * 2 * sqrt_fc * bw_in * d_in / 1000
    end

    @testset "size_tbeams picks ribs at joist spacing" begin
        s = 30u"inch"
        hf = 3u"inch"
        bf_of = bw -> bw + 2 * min(8 * hf, (s - bw) / 2)
        opts = ConcreteBeamOptions(include_flange = true)
        res = size_tbeams([12.0kip * u"ft"], [4.0kip], [ConcreteMemberGeometry(6.0u"m")], opts;
                          flange_width = bf_of, flange_thickness = hf, joist_spacing = s)
        sec = only(res.sections)
        @test sec.bw <= SS.MAX_JOIST_RIB_WIDTH
        @test sec.bf ≈ bf_of(sec.bw)
        @test check_joist_construction(JoistConstruction(sec, s, :one_way)).vc_increase_permitted
    end

    @testset "check_tbeam_section reports what the sizer reported" begin
        s = 30u"inch"
        hf = 3u"inch"
        bf_of = bw -> bw + 2 * min(8 * hf, (s - bw) / 2)
        opts = ConcreteBeamOptions(include_flange = true)
        Mu, Vu, geom = 12.0kip * u"ft", 4.0kip, ConcreteMemberGeometry(6.0u"m")
        res = size_tbeams([Mu], [Vu], [geom], opts;
                          flange_width = bf_of, flange_thickness = hf, joist_spacing = s)
        sec = only(res.sections)
        expl = SS.check_tbeam_section(sec, Mu, Vu, geom, opts; joist_spacing = s)
        sized = only(res.explanations)
        @test expl.passed
        @test expl.governing_check == sized.governing_check
        @test expl.governing_ratio ≈ sized.governing_ratio
        @test [c.ratio for c in expl.checks] ≈ [c.ratio for c in sized.checks]
        # §8.13.8 follows the spacing the checker is given. It raises Vc only,
        # so the shear ratio grows by less than 1.10 without it.
        shear_at(e) = only(c for c in e.checks if c.name == "shear").ratio
        plain = SS.check_tbeam_section(sec, Mu, Vu, geom, opts)
        @test shear_at(expl) < shear_at(plain) < 1.10 * shear_at(expl) + 1e-12
        # Past the section's flexure capacity it fails.
        flex = only(c for c in expl.checks if c.name == "flexure")
        over = SS.check_tbeam_section(sec, Mu * (1.5 / flex.ratio), Vu, geom, opts;
                                      joist_spacing = s)
        @test !over.passed
    end

    @testset "a rib line is limited by its narrowest piece" begin
        # ACI 318-11 §8.13.2: depth ≤ 3-1/2 × the minimum width of the rib.
        wide = SS.joist_rib_line([4.0, 8.0], [14.0, 14.0])
        @test wide.width_ok && wide.depth_ok
        deep = SS.joist_rib_line([4.0u"inch", 8.0u"inch"], [14.0u"inch", 20.0u"inch"])
        @test deep.width_ok && !deep.depth_ok
        @test deep.bw_required_in ≈ 20.0 / 3.5
        narrow = SS.joist_rib_line([3.0, 8.0], [10.0, 10.0])
        @test !narrow.width_ok
    end

    @testset "withholding stirrups removes Vs from φVn" begin
        # ENGINEERING JUDGMENT on top of §11.4.7.9: vs_factor = 0 is concrete alone.
        bw, d, Ag, fc = 6.0, 10.0, 6.0 * 12.0, 4000.0
        full = SS._φVn_with_axial(bw, d, Ag, Ag, fc, 1.0, 0.0)
        plain = SS._φVn_with_axial(bw, d, Ag, Ag, fc, 1.0, 0.0; vs_factor = 0.0)
        @test plain < full
        @test plain ≈ 0.75 * 2 * sqrt(fc) * bw * d / 1000.0
    end
end
