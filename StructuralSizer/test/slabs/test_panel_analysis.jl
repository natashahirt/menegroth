# A regular one-way line may use ACI 318-11 §8.3.3 (corpus: aci-318-11,
# pages 112–113). A skewed face, unequal spans, or a two-way panel uses
# the existing area shell.

using Test
using Unitful
using StructuralSizer

const _wu = 1.0u"kip" / u"ft"
const _ln = 10.0u"ft"
const _wln2 = _wu * _ln^2

@testset "Panel analysis" begin
    @testset "A rectangle is a rectangle" begin
        rect = [(0.0, 0.0), (10.0, 0.0), (10.0, 4.0), (0.0, 4.0)]
        skew = [(0.0, 0.0), (10.0, 0.0), (11.0, 4.0), (1.0, 4.0)]
        trap = [(0.0, 0.0), (10.0, 0.0), (8.0, 4.0), (2.0, 4.0)]
        @test is_rectangular_panel(rect)
        @test !is_rectangular_panel(skew)
        @test !is_rectangular_panel(trap)
        @test !is_rectangular_panel([(0.0, 0.0), (4.0, 0.0), (2.0, 3.0)])
    end

    @testset "Coefficients only on a regular one-way line" begin
        spans = [10.0u"ft", 12.0u"ft"]
        method, reasons = select_panel_analysis(OneWay();
            n_spans = 2, clear_spans = spans,
            live = 80.0u"kN/m^2", dead = 40.0u"kN/m^2",
            rectangular = true)
        @test method isa OneWayMomentCoefficients
        @test isempty(reasons)

        # Exactly 20 percent is still permitted. Past that, it is not.
        @test select_panel_analysis(OneWay();
            n_spans = 2, clear_spans = [10.0u"ft", 12.0u"ft"],
            live = 1.0u"kN/m^2", dead = 1.0u"kN/m^2")[1] isa OneWayMomentCoefficients
        skewed = select_panel_analysis(OneWay();
            n_spans = 2, clear_spans = spans,
            live = 1.0u"kN/m^2", dead = 1.0u"kN/m^2",
            rectangular = false)
        @test skewed[1] isa FEA
        @test skewed[1].design_approach == :area
        @test skewed[1].moment_transform == :wood_armer
        @test skewed[1].pattern_mode == :fea_resolve

        unequal = select_panel_analysis(OneWay();
            n_spans = 2, clear_spans = [10.0u"ft", 13.0u"ft"],
            live = 1.0u"kN/m^2", dead = 1.0u"kN/m^2")
        @test unequal[1] isa FEA
        @test any(occursin("20 percent", r) for r in unequal[2])

        one = select_panel_analysis(OneWay();
            n_spans = 1, clear_spans = [10.0u"ft"],
            live = 1.0u"kN/m^2", dead = 1.0u"kN/m^2")
        @test one[1] isa FEA

        heavy = select_panel_analysis(OneWay();
            n_spans = 2, clear_spans = spans,
            live = 4.0u"kN/m^2", dead = 1.0u"kN/m^2")
        @test heavy[1] isa FEA
        @test any(occursin("three times", r) for r in heavy[2])
    end

    @testset "A two-way panel is the shell" begin
        method, reasons = select_panel_analysis(TwoWay();
            n_spans = 3, clear_spans = [10.0u"ft", 10.0u"ft", 10.0u"ft"],
            live = 1.0u"kN/m^2", dead = 1.0u"kN/m^2")
        @test method isa FEA
        @test method.design_approach == :area
        @test any(occursin("one-way", r) for r in reasons)
    end

    @testset "§8.3.3 moments for wu = 1 kip/ft and ln = 10 ft" begin
        interior = approximate_one_way_moments(_wu, _ln;
            span = :interior, n_spans = 3, support_face = :other_interior)
        @test isapprox(interior.M_pos, _wln2 / 16)
        @test isapprox(interior.M_neg_interior, _wln2 / 11)
        @test isapprox(interior.V_first_interior, _wu * _ln / 2)

        unrestrained = approximate_one_way_moments(_wu, _ln;
            span = :end, discontinuous = :unrestrained, n_spans = 2)
        @test isapprox(unrestrained.M_pos, _wln2 / 11)
        @test isapprox(unrestrained.M_neg_exterior, zero(_wln2))
        @test isapprox(unrestrained.M_neg_interior, _wln2 / 9)
        @test isapprox(unrestrained.V_first_interior, 1.15 * _wu * _ln / 2)

        many = approximate_one_way_moments(_wu, _ln;
            span = :end, discontinuous = :column, n_spans = 3)
        @test isapprox(many.M_pos, _wln2 / 14)
        @test isapprox(many.M_neg_exterior, _wln2 / 16)
        @test isapprox(many.M_neg_interior, _wln2 / 10)

        spandrel = approximate_one_way_moments(_wu, _ln;
            span = :end, discontinuous = :spandrel, n_spans = 2)
        @test isapprox(spandrel.M_neg_exterior, _wln2 / 24)

        short = approximate_one_way_moments(_wu, _ln;
            span = :end, discontinuous = :column, n_spans = 2, short_slab = true)
        @test isapprox(short.M_neg_exterior, _wln2 / 12)
        @test isapprox(short.M_neg_interior, _wln2 / 12)
        @test isapprox(short.M_pos, _wln2 / 14)
    end

    @testset "Elastic strip of a continuous topping" begin
        w = 1.0u"kip" / u"ft^2"
        L = 10.0u"ft"
        one = StructuralSizer.elastic_strip_moments(w, [L])
        @test one.M_neg == 0.0 * w * L^2
        @test isapprox(one.M_pos, w * L^2 / 8)
        two = StructuralSizer.elastic_strip_moments(w, [L, L])
        @test isapprox(two.M_neg, w * L^2 / 8)
        @test isapprox(two.M_pos, 9 / 128 * w * L^2)
    end

    @testset "Patterned strip envelopes §8.11.2 arrangements" begin
        d = 1.0u"kip" / u"ft^2"
        l = 2.0u"kip" / u"ft^2"
        L = 10.0u"ft"
        # Live load on one of two equal spans: M_B = -(w1 + w2) L² / 16, and
        # the loaded span peaks at R_A² / (2 w1) with R_A = w1 L / 2 + M_B / L.
        w1, w2 = d + l, d
        MB = -(w1 + w2) * L^2 / 16
        RA = w1 * L / 2 + MB / L
        two = StructuralSizer.patterned_strip_moments(d, l, [L, L])
        @test isapprox(two.M_pos, RA^2 / (2 * w1))
        @test isapprox(two.M_neg, (d + l) * L^2 / 8)
        full = StructuralSizer.elastic_strip_moments(d + l, [L, L])
        @test two.M_pos > full.M_pos
        # No live load is the unpatterned strip.
        none = StructuralSizer.patterned_strip_moments(d, 0.0 * l, [L, L, L])
        same = StructuralSizer.elastic_strip_moments(d, [L, L, L])
        @test isapprox(none.M_pos, same.M_pos) && isapprox(none.M_neg, same.M_neg)
        three = StructuralSizer.patterned_strip_moments(d, l, [L, L, L])
        full3 = StructuralSizer.elastic_strip_moments(d + l, [L, L, L])
        @test three.M_neg >= full3.M_neg && three.M_pos > full3.M_pos
    end

    @testset "A topping outside §8.3.3 still gets bars" begin
        info = StructuralSizer.one_way_topping_bars(4.0u"inch", 8.0u"ft",
            50.0u"psf", 200.0u"psf", NWC_4000, Rebar_60;
            n_spans = 1, cover = 0.75u"inch", bar_size = 4)
        @test info.analysis == :elastic
        @test info.bars.pos.section_adequate
        @test info.bars.pos.As_provided >= 0.0018 * 1.0u"m" * 4.0u"inch"
        @test any(occursin("§8.3.1", r) for r in info.reasons)
    end

    @testset "Rib hogging bars and the topping mat" begin
        sec = RCBeamSection(b = 12.0u"inch", h = 20.0u"inch", bar_size = 8, n_bars = 3)
        picked = StructuralSizer.hogging_bars(sec, 40.0u"kip*ft", 4.0u"ksi", 60.0u"ksi")
        @test picked !== nothing
        @test picked[2] >= 2
        info = StructuralSizer.one_way_topping_bars(3.0u"inch", 2.5u"ft",
            80.0u"psf", 50.0u"psf", NWC_4000, Rebar_60;
            n_spans = 4, cover = 0.75u"inch", bar_size = 4)
        @test info.analysis == :coefficients
        inner = StructuralSizer.one_way_topping_bars(3.0u"inch", 2.5u"ft",
            80.0u"psf", 50.0u"psf", NWC_4000, Rebar_60;
            n_spans = 4, cover = 0.75u"inch", bar_size = 4, inner_layer = true)
        @test inner.bars.pos.As_reqd > info.bars.pos.As_reqd
        cover = 0.75u"inch"
        # Two cover depths and four #4 layers need 3.5 in: a 3 in topping warns.
        thin = StructuralSizer.detail_rib_topping(; side = 20.0u"ft", across = 10.0u"ft", h = 3.0u"inch",
                                 cover = cover, along = info, across_bars = inner)
        @test any(occursin("do not fit", w) for w in thin.warnings)
        md = StructuralSizer.detail_rib_topping(; side = 20.0u"ft", across = 10.0u"ft", h = 4.5u"inch",
                                 cover = cover, along = info, across_bars = inner, solid_head = true)
        @test any(g -> g.role === :bottom && g.count > 0, md.groups)
        @test any(g -> g.direction === :secondary && g.centerlines[1][1][2] != g.centerlines[1][2][2],
                  md.groups)
        @test any(occursin("13.3.7", n) for n in md.notes)
        # Cover on each face, and the secondary bottom layer sits on the primary.
        zof(g) = g.centerlines[1][1][3]
        db = ustrip(u"m", bar_diameter(4))
        c = ustrip(u"m", cover)
        h_m = ustrip(u"m", 4.5u"inch")
        bot1 = only(g for g in md.groups if g.direction === :primary && g.role === :bottom)
        bot2 = only(g for g in md.groups if g.direction === :secondary && g.role === :bottom)
        @test zof(bot1) ≈ c + ustrip(u"m", bar_diameter(bot1.bar_size)) / 2
        @test zof(bot2) ≈ c + ustrip(u"m", bar_diameter(bot1.bar_size)) +
                          ustrip(u"m", bar_diameter(bot2.bar_size)) / 2
        top1 = only(g for g in md.groups if g.direction === :primary && g.role === :top)
        @test zof(top1) ≈ h_m - c - ustrip(u"m", bar_diameter(top1.bar_size)) / 2

        # Parallel to one-way ribs: the §7.12 mat only.
        ts = StructuralSizer.shrinkage_topping_bars(3.0u"inch", Rebar_60)
        @test ts.analysis == :shrinkage
        @test ts.bars.pos.As_provided >= 0.0018 * 1.0u"m" * 3.0u"inch"
        @test ts.bars.pos.spacing <= 15.0u"inch"
        @test ts.bars.ext_neg.spacing == 0.0u"m"
    end

    @testset "Two-way opening limits, ACI 318-11 §13.4" begin
        panel = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
        middle = [(4.0, 4.0), (6.0, 4.0), (6.0, 6.0), (4.0, 6.0)]
        ok, reasons = two_way_opening_needs_analysis(panel, [middle])
        @test !ok
        @test isempty(reasons)

        # Corner of the column strips, wider than one-eighth of the strip.
        corner = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
        needs, reasons = two_way_opening_needs_analysis(panel, [corner])
        @test needs
        @test any(occursin("13.4.2.2", r) for r in reasons)

        beams, reasons = two_way_opening_needs_analysis(panel, [middle]; has_beams = true)
        @test beams
        @test any(occursin("13.4.2", r) for r in reasons)
    end

    @testset "One-way support condition and thickness" begin
        cond = one_way_support_condition
        @test cond(:supported, :supported) == SIMPLE
        @test cond(:continuous, :supported) == ONE_END_CONT
        @test cond(:continuous, :continuous) == BOTH_ENDS_CONT
        @test cond(:free, :supported) == CANTILEVER
        @test_throws ArgumentError cond(:free, :free)

        ln = 10.0u"ft"
        h(s) = min_thickness(OneWay(), ln; fy = 60_000u"psi", support = s)
        @test h(CANTILEVER) ≈ ln / 10
        @test h(SIMPLE) ≈ ln / 20
        @test h(ONE_END_CONT) ≈ ln / 24
        @test h(BOTH_ENDS_CONT) ≈ ln / 28
        @test h(CANTILEVER) > h(SIMPLE) > h(ONE_END_CONT) > h(BOTH_ENDS_CONT)
        @test min_thickness(OneWay(), 16.0u"ft"; support = SIMPLE) > h(SIMPLE)
        @test thicker_support(BOTH_ENDS_CONT, SIMPLE) == SIMPLE
        @test thicker_support(CANTILEVER, SIMPLE) == CANTILEVER
    end

    @testset "An opening outside §13.4.2 uses the area shell" begin
        # Three 20 ft bays. DDM is permitted on the rectangle. The opening is
        # what changes the method.
        ft = 0.3048
        xs = [0.0, 20.0, 40.0, 60.0]
        pts = NTuple{2, Float64}[]
        ids = Dict{NTuple{2, Float64}, Int}()
        V(x, y) = get!(ids, (x, y)) do
            push!(pts, (x, y)); length(pts)
        end
        faces = Vector{Int}[]
        for i in 1:3, j in 1:3
            push!(faces, [V(xs[i], xs[j]), V(xs[i + 1], xs[j]),
                          V(xs[i + 1], xs[j + 1]), V(xs[i], xs[j + 1])])
        end
        col_vs = [V(x, y) for x in xs for y in xs]
        vc = [p[k] * ft for p in pts, k in 1:2]
        cells = Any[(face_idx = k, sdl = 4.8u"kN/m^2", live_load = 2.4u"kN/m^2",
                     self_weight = 0.0u"kN/m^2") for k in eachindex(faces)]
        cols = Any[(vertex_idx = v, position = :interior, c1 = 12.0u"inch", c2 = 12.0u"inch",
                    θ = 0.0, structural_offset = (0.0, 0.0)) for v in col_vs]
        slab = (cell_indices = collect(eachindex(faces)),
                spans = (primary = 20.0u"ft", secondary = 20.0u"ft", axis = (1.0, 0.0)))
        function with_opening(loop)
            skel = (geometry = (vertex_coords = vc,), face_vertex_indices = faces,
                    openings = [(loop = loop,)])
            struc = (cells = cells, slabs = Any[slab], columns = cols, skeleton = skel)
            return StructuralSizer.resolve_analysis_method(DDM(), struc, slab, cols, :fallback)
        end
        # Middle of the middle strips: §13.4.2.1 keeps the requested method.
        middle = [(8.0ft, 8.0ft), (12.0ft, 8.0ft), (12.0ft, 12.0ft), (8.0ft, 12.0ft)]
        kept, kept_why = with_opening(middle)
        @test kept isa DDM
        @test isempty(kept_why)
        # Corner, wider than one-eighth of the column strip: analysis.
        corner = [(0.3ft, 0.3ft), (8.0ft, 0.3ft), (8.0ft, 8.0ft), (0.3ft, 8.0ft)]
        used, why = with_opening(corner)
        @test used isa FEA
        @test used.design_approach == :area
        @test used.moment_transform == :wood_armer
        @test any(occursin("13.4.2", r) for r in why)
        # A still larger opening in the same corner is the same shell.
        bigger = [(0.3ft, 0.3ft), (12.0ft, 0.3ft), (12.0ft, 12.0ft), (0.3ft, 12.0ft)]
        again, _ = with_opening(bigger)
        @test again.design_approach == :area
    end

    @testset "Solid slabs and deck temperature steel" begin
        # 4 in slab, light load. On a 1 m strip, 18 in needs 3 bars and 3h = 12 in
        # needs 4. ACI 318-11 §7.6.5, page 96. The joist default stays §7.12.2.2.
        joist = StructuralSizer.one_way_topping_bars(4.0u"inch", 6.0u"ft",
            10.0u"psf", 20.0u"psf", NWC_4000, Rebar_60;
            n_spans = 1, cover = 0.75u"inch", bar_size = 4)
        solid = StructuralSizer.one_way_topping_bars(4.0u"inch", 6.0u"ft",
            10.0u"psf", 20.0u"psf", NWC_4000, Rebar_60;
            n_spans = 1, cover = 0.75u"inch", bar_size = 4,
            max_spacing = StructuralSizer.solid_slab_spacing(4.0u"inch"))
        @test joist.bars.pos.spacing <= 18.0u"inch"
        @test solid.bars.pos.spacing <= 12.0u"inch"
        @test solid.bars.pos.spacing < joist.bars.pos.spacing
        @test StructuralSizer.solid_slab_spacing(8.0u"inch") == 18.0u"inch"

        # Interior bay: §8.3.3 negative moment, so the top strip is not empty.
        interior = StructuralSizer.one_way_topping_bars(8.0u"inch", 12.0u"ft",
            80.0u"psf", 50.0u"psf", NWC_4000, Rebar_60;
            n_spans = 2, cover = 0.75u"inch", bar_size = 5,
            span = :interior, support_face = :first_interior,
            max_spacing = StructuralSizer.solid_slab_spacing(8.0u"inch"))
        @test interior.analysis == :coefficients
        @test interior.bars.int_neg.Mu > 0.0u"N*m"
        @test interior.bars.int_neg.spacing <= 18.0u"inch"

        # Shell envelope: 500 mm²/m bottom, nothing on top.
        shell = StructuralSizer.area_direction_bars(500e-6, 0.0;
            max_spacing = 18.0u"inch", reason = "test envelope")
        @test shell.bars.pos.As_provided >= 500e-6 * u"m^2"
        @test shell.bars.pos.spacing <= 18.0u"inch"
        @test shell.bars.int_neg.n_bars == 0

        # 2 in of concrete above the deck: 0.00075 × 2 in × 12 in/ft.
        As = 0.00075 * 2.0u"inch" * 12.0u"inch" / 1.0u"ft"
        deck = StructuralSizer.deck_temperature_bars(As, 4.0u"inch")
        @test deck.analysis == :temperature
        @test deck.bars.pos.As_provided >= As * 1.0u"m"
        @test deck.bars.pos.spacing <= 18.0u"inch"
        @test any(occursin("W1.4", r) for r in deck.reasons)
        mat = StructuralSizer.detail_temperature_mat(;
            side = 10.0u"ft", across = 10.0u"ft", h = 2.0u"inch",
            cover = 0.75u"inch", along = deck)
        @test length(mat.groups) == 2
        z1 = mat.groups[1].centerlines[1][1][3]
        z2 = mat.groups[2].centerlines[1][1][3]
        @test z1 == z2
        db = ustrip(u"m", StructuralSizer.bar_diameter(mat.groups[1].bar_size))
        @test z1 ≈ ustrip(u"m", 0.75u"inch") + db / 2
    end
end
