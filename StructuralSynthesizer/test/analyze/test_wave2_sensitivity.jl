# Wave 2 behavior: the results have to move the way the clauses say, and a
# change in the input has to move them in the expected direction.
#
# - One-way thickness follows ACI 318-19 Table 7.3.1.1 (page 92). More
#   continuity makes the slab thinner. A single bay is simply supported.
# - Pattern live: three-quarter checkerboard hogging stays at or below the
#   all-loaded case (ACI 318-11 §13.7.6.3). Full live on adjacent spans
#   (ACI 318-19 §6.4.2) raises it. More loaded spans means more displacement.
#   Vertical reactions balance the applied load.
# - Flat-plate k: a flat plate is not a lateral system (the shear-wall core
#   takes sidesway), so a flat-plate column carries no sway moment and the
#   §10.10.7.3 Q-method uses k = 1.0 either way — braced (R10.10.6.3) when
#   nonsway, the §10.10.7.2 minimum when sway. The distinction a story makes
#   is the `braced` designation, not the k value: Q ≤ 0.05 is nonsway
#   (braced), Q > 0.05 is sway (ACI 318-11 §10.10.5.2). The alignment chart
#   (Fig. R10.10.1.1) is not consulted — a flat plate on pinned footings has
#   no finite sway k there, which is the physical statement that the frame
#   needs a lateral system; that is a clean upstream error, not a chart k.

using Test
using Unitful
using Asap
using LinearAlgebra

using StructuralSynthesizer
using StructuralSizer

function _plate(xb, yb, Lx, Ly; sdl=20.0u"psf", ll=80.0u"psf")
    skel = gen_medium_office(Lx, Ly, 12.0u"ft", xb, yb, 1)
    struc = BuildingStructure(skel)
    initialize!(struc; floor_type=:flat_plate, floor_opts=FlatPlateOptions(
        material = RC_4000_60, method = DDM(), cover = 0.75u"inch", bar_size = 5))
    for cell in struc.cells
        cell.sdl = uconvert(u"kN/m^2", sdl)
        cell.live_load = uconvert(u"kN/m^2", ll)
    end
    for col in struc.columns
        col.c1 = 16.0u"inch"
        col.c2 = 16.0u"inch"
    end
    return struc
end

@testset "Wave 2 sensitivity" begin
    @testset "One-way thickness follows continuity" begin
        skel = gen_medium_office(40.0u"ft", 10.0u"ft", 12.0u"ft", 1, 1, 1)
        single = BuildingStructure(skel)
        initialize!(single; floor_type=:auto)
        design_floors!(single; options=OneWayOptions())
        slab1 = only(single.slabs)
        @test StructuralSizer._slab_span_support(single, slab1) == StructuralSizer.SIMPLE
        raw = StructuralSizer.min_thickness(StructuralSizer.OneWay(), slab1.spans.primary;
                                            support = StructuralSizer.SIMPLE)
        # ℓ/20 is 6 in on a 10 ft bay. The stored span is a few millimetres
        # longer, and the sizer rounds up to the next 1/2 in.
        @test ustrip(u"inch", raw) ≈ 6.0 atol = 0.1

        skel3 = gen_medium_office(40.0u"ft", 30.0u"ft", 12.0u"ft", 1, 3, 1)
        three = BuildingStructure(skel3)
        initialize!(three; floor_type=:auto)
        design_floors!(three; options=OneWayOptions())
        floors = [s for s in three.slabs if s.floor_type == :one_way]
        @test length(floors) == 3
        supports = [StructuralSizer._slab_span_support(three, s) for s in floors]
        @test count(==(StructuralSizer.ONE_END_CONT), supports) == 2
        @test count(==(StructuralSizer.BOTH_ENDS_CONT), supports) == 1
        h_of(s) = s.result.thickness
        h_end = maximum(h_of(s) for (s, k) in zip(floors, supports)
                        if k == StructuralSizer.ONE_END_CONT)
        h_int = only(h_of(s) for (s, k) in zip(floors, supports)
                     if k == StructuralSizer.BOTH_ENDS_CONT)
        # More continuity, thinner slab. A single bay is the thickest.
        @test h_int < h_end
        @test h_end < slab1.result.thickness
    end

    @testset "Flat-plate k and the sway designation follow Q" begin
        struc = _plate(1, 1, 20.0u"ft", 20.0u"ft")
        col = first(struc.columns)
        slab = first(struc.slabs)
        h = 8.0u"inch"

        # No wall and no Q (story_properties unset): the proxy designates the
        # story sway. k = 1.0 (ACI 318-11 §10.10.7.2 minimum); no chart.
        g = StructuralSizer.flat_plate_column_geometry(col, slab, struc; h=h)
        @test !col.braced
        @test !g.braced
        @test g.kx == 1.0
        @test g.ky == 1.0

        # k does not depend on slab thickness or column size any more — the
        # alignment chart (the only thing those fed) is retired for flat plates.
        g_thick = StructuralSizer.flat_plate_column_geometry(col, slab, struc; h=12.0u"inch")
        @test g_thick.kx == 1.0
        @test g_thick.ky == 1.0
        col.c1 = col.c2 = 24.0u"inch"
        g_big = StructuralSizer.flat_plate_column_geometry(col, slab, struc; h=h)
        @test g_big.kx == 1.0
        col.c1 = col.c2 = 16.0u"inch"

        # §10.10.5.2. Q = 1000*0.4/(200*120) = 0.0167 ≤ 0.05 → nonsway, braced.
        col.story_properties = (ΣPu=1000.0, ΣPc=0.0, Vus=200.0, Δo=0.4, lc=120.0)
        g_ns = StructuralSizer.flat_plate_column_geometry(col, slab, struc; h=h)
        @test col.braced
        @test g_ns.braced
        @test g_ns.kx == 1.0
        @test g_ns.ky == 1.0

        # Q = 1000*2.0/(200*120) = 0.083 > 0.05 → sway. Designation flips to
        # unbraced; k stays 1.0 (the §10.10.7.3 along-length value, Ms = 0).
        col.story_properties = (ΣPu=1000.0, ΣPc=0.0, Vus=200.0, Δo=2.0, lc=120.0)
        g_sw = StructuralSizer.flat_plate_column_geometry(col, slab, struc; h=h)
        @test !col.braced
        @test !g_sw.braced
        @test g_sw.kx == 1.0
        @test g_sw.ky == 1.0
    end

    @testset "Pattern live, hogging, and vertical equilibrium" begin
        struc = _plate(3, 1, 90.0u"ft", 20.0u"ft"; ll=250.0u"psf")
        params = DesignParameters(pattern_loading=:checkerboard)
        to_asap!(struc; params)
        # A vault thrust that is not a cell tributary must survive into every case.
        el = first(struc.asap_model.frame_elements)
        thrust = Asap.LineLoad(el, [0.0u"N/m", 1000.0u"N/m", 0.0u"N/m"], :vault_thrust)
        push!(struc.asap_model.loads, thrust)
        cases = StructuralSynthesizer._generate_pattern_cases(struc)
        @test length(cases) > 3
        @test all(case -> any(ld -> ld === thrust, case), cases)

        sync_asap!(struc; params)
        model = struc.asap_model
        # Free-DOF residual of S u − (P − Pf). Element live load lives in Pf,
        # so a sum of P alone is not the applied load.
        residual = model.S * model.u - model.P + model.Pf
        residual[model.fixedDOFs] .= 0
        scale = max(1.0, maximum(abs, model.P) + maximum(abs, model.Pf))
        @test maximum(abs, residual) / scale < 1e-6

        Asap.post_process!(model)
        Asap.reactions!(model)
        Rz = sum(ustrip(u"N", n.reaction[3]) for n in model.nodes
                 if length(n.dof) >= 3 && n.dof[3] == false; init = 0.0)
        @test abs(Rz) > 1.0

        solved = StructuralSynthesizer._pattern_demand_cases(struc, params)
        @test solved !== nothing
        norms = [norm(u) for (u, _) in solved]
        # Every span loaded displaces at least as much as a partial pattern.
        @test norms[1] >= maximum(norms[2:end]) - 1e-6
        # Dropping live somewhere must drop the displacement.
        @test minimum(norms[2:end]) < norms[1] - 1e-8

        # Three-quarter checkerboard hogging stays at or below full load.
        # A §6.4.2 case leaves a span without live, so that beam's positive
        # moment drops. Support hogging on this line is still largest when
        # every span is loaded.
        n_quarter = 0
        n_pos_drop = 0
        beam_edges = Set(get(struc.skeleton.groups_edges, :beams, Int[]))
        for (edge_idx, beam) in enumerate(model.frame_elements)
            edge_idx in beam_edges || continue
            eid = beam.elementID
            (1 <= eid <= length(solved[1][2])) || continue
            f_full = StructuralSynthesizer._element_forces_from_u(
                beam, solved[1][1], solved[1][2][eid]; resolution=40)
            ly_z = beam.LCS[2][3]
            abs(ly_z) < 1e-8 && continue
            s = ly_z > 0 ? 1.0 : -1.0
            pos_full = maximum(max(0.0, f_full.My[k] * s) for k in eachindex(f_full.My))
            for i in 2:length(solved)
                f_pat = StructuralSynthesizer._element_forces_from_u(
                    beam, solved[i][1], solved[i][2][eid]; resolution=40)
                for k in eachindex(f_full.My)
                    hog_full = max(0.0, -f_full.My[k] * s)
                    hog_pat = max(0.0, -f_pat.My[k] * s)
                    i <= 3 && hog_pat > hog_full + 1e-6 && (n_quarter += 1)
                end
                if i > 3
                    pos_pat = maximum(max(0.0, f_pat.My[k] * s) for k in eachindex(f_pat.My))
                    pos_pat < pos_full - 1e-6 && (n_pos_drop += 1)
                end
            end
        end
        @test n_quarter == 0
        @test n_pos_drop > 0
    end
end
