# One bay spans 6 m between two concrete edge beams, on four corner columns.
# At midspan, the two frame moments plus the slab moment across the whole
# width must equal the static W·L/8 for every factored case. That holds only
# if the hung web's axial force times its offset is in the frame moment.
# The beam's shell demand is that frame moment alone; the slab keeps the rest.

using Test
using Unitful
using Asap
using StructuralSynthesizer
using StructuralSizer

const SY = StructuralSynthesizer
const SZ = StructuralSizer

function _edge_beam_bay(beam_section; Lx = 6.0, Ly = 4.0, h = 0.15, release = :fixedfixed)
    conc = NWC_4000
    panel = SZ.StoryShellPanel([(0.0, 0.0), (Lx, 0.0), (Lx, Ly), (0.0, Ly)],
                               Asap.ShellSection(h * u"m", conc.E, conc.ν; ρ = conc.ρ))
    mat = beam_section isa RCBeamSection ? conc : A992_Steel
    props = SZ.shell_beam_properties(beam_section, h * u"m", mat)
    beams = [SZ.ShellFrameBeam([(0.0, 0.0), (Lx, 0.0)], props.section;
                               eccentricity = props.eccentricity, id = :south,
                               release = release),
             SZ.ShellFrameBeam([(0.0, Ly), (Lx, Ly)], props.section;
                               eccentricity = props.eccentricity, id = :north,
                               release = release)]
    built = SZ.story_shell([panel], beams; target_edge = 0.5u"m")
    SY._pin_story_supports!(built.nodes, [(0.0, 0.0), (Lx, 0.0), (Lx, Ly), (0.0, Ly)])
    loads = Asap.AbstractLoad[Asap.AreaLoad(built.shells, 1.0u"Pa")]
    for el in built.frames
        push!(loads, Asap.GravityLoad(el, 9.80665u"m/s^2"))
    end
    model = Asap.Model(built.nodes, built.frames, built.shells, loads)
    Asap.process!(model)
    Asap.solve!(model)
    design = StoryPanelDesign(3.0u"kPa", 2.0u"kPa", h * u"m", (0.0, 1.0), OneWay())
    cases = story_load_cases(model, built.panel_index, [design])
    index = Dict(:south => 1, :north => 2)
    w_beam = ustrip(u"kg/m^3", props.section.ρ) * ustrip(u"m^2", props.section.A) * 9.80665
    return (; model, built, cases, index, Lx, Ly, w_beam)
end

"""Length of the line `x = c` inside a plan triangle."""
function _vertical_cut_length(el, c)
    p = [(ustrip(u"m", n.position[1]), ustrip(u"m", n.position[2])) for n in el.nodes]
    ys = Float64[]
    for k in 1:3
        (x1, y1), (x2, y2) = p[k], p[mod1(k + 1, 3)]
        (min(x1, x2) <= c <= max(x1, x2)) && x1 != x2 || continue
        push!(ys, y1 + (c - x1) / (x2 - x1) * (y2 - y1))
    end
    return length(ys) < 2 ? 0.0 : maximum(ys) - minimum(ys)
end

"""Sagging moment along global x of a hogging-positive element-frame tensor."""
function _sagging_x(el, M)
    a = el.LCS[1][1]
    b = el.LCS[2][1]
    return -(M[1] * a^2 + M[2] * b^2 + 2 * M[3] * a * b)
end

"""Sagging frame moment at the start of each frame piece that begins at `x`, summed."""
function _frame_moment_at(bay, c, x)
    (; model, built, cases) = bay
    gravity = Asap.AbstractLoad[ld for ld in model.loads if ld isa Asap.GravityLoad]
    el_loads = Asap.get_elemental_loads(gravity, length(model.frame_elements))
    total = 0.0
    for el in built.frames
        abs(ustrip(u"m", el.nodeStart.position[1]) - x) < 1e-6 || continue
        fw = SY._element_forces_from_u(el, cases.u_weight, el_loads[el.elementID]; resolution = 2)
        f1 = SY._element_forces_from_u(el, cases.u_unit[1], (); resolution = 2)
        total += sign(el.LCS[2][3]) * (c.weight * fw.My[1] + c.panel[1] * f1.My[1])
    end
    return total
end

"""One 6 × 4 m bay on four columns: skeleton, slab, steel beams, and a solved frame."""
function _one_bay_building(; Lx = 6.0, Ly = 4.0, z = 3.0)
    skel = BuildingSkeleton{Float64}()
    corners = [(0.0, 0.0), (Lx, 0.0), (Lx, Ly), (0.0, Ly)]
    vs = [add_vertex!(skel, [x, y, z]) for (x, y) in corners]
    for k in 1:4
        add_element!(skel, vs[k], vs[mod1(k + 1, 4)]; group = :beams)
    end
    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)
    struc = BuildingStructure(skel)
    spans = SpanInfo{Float64}(Lx, Ly, (0.0, 1.0), Ly)
    fidx = findfirst(f -> Set(f) == Set(vs), skel.face_vertex_indices)
    cell = Cell(fidx, Lx * Ly * u"m^2", spans, 2.0u"kN/m^2", 3.0u"kN/m^2")
    cell.floor_type = :one_way
    push!(struc.cells, cell)
    push!(struc.slabs, Slab{Float64}([1], CIPSlabResult(0.2, 0.2, 5.0), :one_way, spans,
                                     :interior, nothing, MaterialVolumes(), nothing, nothing,
                                     FramingLevel{Float64}[]))
    for e in sort(collect(skel.groups_edges[:beams]))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        push!(struc.beams, Beam([length(struc.segments)], L; role = :girder, level = 0))
    end

    # Frame for tributary sizing: beam elements first, so element index = edge index.
    floor = [Asap.Node([x * u"m", y * u"m", z * u"m"], fill(true, 6)) for (x, y) in corners]
    ground = [Asap.Node([x * u"m", y * u"m", 0.0u"m"], fill(false, 6)) for (x, y) in corners]
    beam_sec = StructuralSizer.to_asap_section(W("W12X26"), A992_Steel)
    col_sec = Asap.Section(0.05u"m^2", 200e9u"Pa", 77e9u"Pa",
                           1e-3u"m^4", 1e-3u"m^4", 1e-3u"m^4", 7850.0u"kg/m^3")
    # Each beam takes the building's own release (steel gravity: pinned).
    release_of = Dict(struc.segments[only(segment_indices(b))].edge_idx =>
                      SY.resolve_release(b, [struc.segments[only(segment_indices(b))]], A992_Steel)
                      for b in struc.beams)
    beam_els = [Asap.Element(floor[findfirst(==(a), vs)], floor[findfirst(==(b), vs)], beam_sec;
                             release = release_of[k])
                for (k, (a, b)) in enumerate(skel.edge_indices)]
    col_els = [Asap.Element(ground[k], floor[k], col_sec) for k in 1:4]
    loads = Asap.AbstractLoad[Asap.TributaryLoad(el, [0.0, 1.0], [1.0u"m", 1.0u"m"],
                                                 10_000.0u"Pa", (0.0, 0.0, -1.0))
                              for el in beam_els]
    model = Asap.Model(vcat(floor, ground), vcat(beam_els, col_els), loads)
    Asap.solve!(model)
    struc.asap_model = model
    compute_cell_tributaries!(struc)
    return struc, corners
end

const _STUD_OPTS = (composite = true,
                    composite_anchor_d = 0.75u"inch",
                    composite_anchor_length = 5.0u"inch",
                    composite_anchor_Fu = 65.0u"ksi")

@testset "Story shell beam demand" begin
    rect = RCBeamSection(b = 12u"inch", h = 20u"inch", bar_size = 9, n_bars = 3)

    @testset "Frames plus the full-width slab cut carry W·L/8" begin
        bay = _edge_beam_bay(rect)
        (; model, cases, Lx, Ly) = bay
        # Just off the frame station, so the cut never runs along a triangle edge.
        xc = Lx / 2 + 1e-7
        for c in cases.combinations
            frame = _frame_moment_at(bay, c, Lx / 2)
            slab = 0.0
            for (k, el) in enumerate(model.shell_elements)
                len = _vertical_cut_length(el, xc)
                len > 0 && (slab += len * _sagging_x(el, SZ._combined_moment(cases, c, k)))
            end
            W = c.panel[1] * Lx * Ly + c.weight * 2 * bay.w_beam * Lx
            @test frame + slab ≈ W * Lx / 8 rtol = 0.03
            @test frame > slab > 0
        end
    end

    @testset "A beam's shell demand is its frame force; the slab keeps its own bending" begin
        bay = _edge_beam_bay(rect)
        demands = story_shell_beam_demands(bay.model, bay.built.frames, bay.index, bay.cases)
        @test Set(keys(demands)) == Set([1, 2])
        south, north = demands[1], demands[2]
        @test south.Mu_pos ≈ north.Mu_pos rtol = 0.02
        @test south.Vu > 0
        # Midspan governs sagging on these simple edge beams.
        mid = maximum(c -> _frame_moment_at(bay, c, bay.Lx / 2), bay.cases.combinations)
        @test south.Mu_pos + north.Mu_pos ≈ mid rtol = 0.02
        M_static = maximum(c -> (c.panel[1] * bay.Lx * bay.Ly +
                                 c.weight * 2 * bay.w_beam * bay.Lx) * bay.Lx / 8,
                           bay.cases.combinations)
        @test south.Mu_pos + north.Mu_pos < M_static
    end

    @testset "A bare steel beam on the shell nodes" begin
        steel = ISymmSection(10u"inch", 8u"inch", 0.3u"inch", 0.5u"inch"; material = A992_Steel)
        bay = _edge_beam_bay(steel)
        demands = story_shell_beam_demands(bay.model, bay.built.frames, bay.index, bay.cases)
        @test demands[1].Mu_pos > 0
        @test demands[1].Mu_pos ≈ demands[2].Mu_pos rtol = 0.02
    end

    @testset "Beam sizing loops on the shell until sections hold" begin
        struc, corners = _one_bay_building()
        n_beams = length(struc.beams)
        opts = SteelBeamOptions(custom_catalog = [W("W12X26"), W("W16X40"), W("W21X55")],
                                deflection_limit = nothing, total_deflection_limit = nothing)
        out = size_beams_with_story_shell!(struc, opts; levels = [0],
            shell_kwargs = (target_edge = 1.0u"m", support_points = corners))
        @test out.converged
        @test 1 <= out.passes <= 4
        @test Set(keys(out.demands)) == Set(1:n_beams)
        @test all(b -> section(b) !== nothing, struc.beams)

        # The shell raises a demand. It never lowers one.
        groups, base = SY.member_group_demands(struc; member_edge_group = SY.BEAM_GROUP_SYMBOLS)
        g1 = findfirst(==(group_id(struc.beams[1])), groups)
        big = Dict(1 => ShellBeamDemand(1.0e9, 2.0e9, 3.0e9))
        _, raised = SY.member_group_demands(struc; member_edge_group = SY.BEAM_GROUP_SYMBOLS,
                                            shell_demands = big)
        @test raised[g1].Mux_pos == 1.0e9
        @test raised[g1].Mux_neg == 2.0e9
        @test raised[g1].Vu_strong == 3.0e9
        zero_d = Dict(i => ShellBeamDemand(0.0, 0.0, 0.0) for i in 1:n_beams)
        _, same = SY.member_group_demands(struc; member_edge_group = SY.BEAM_GROUP_SYMBOLS,
                                          shell_demands = zero_d)
        @test [d.Mux_pos for d in same] == [d.Mux_pos for d in base]
        @test [d.Vu_strong for d in same] == [d.Vu_strong for d in base]
        # Shell demands never touch the frame model's deflection.
        @test [d.δ_max_LL for d in raised] == [d.δ_max_LL for d in base]
        @test [d.δ_max_total for d in raised] == [d.δ_max_total for d in base]
    end

    @testset "Steel shell spans: each on its own length, scaled by inertia" begin
        sec, big = W("W16X26"), W("W21X55")
        mat = A992_Steel
        Ix(s) = ustrip(u"m^4", s.Ix)
        geom = SteelMemberGeometry(8.0u"m"; Lb = 1.0u"m")
        dem = MemberDemand(1; Mux = 1.0e3, Vu_strong = 1.0e3)
        function ok(spans, s)
            chk = AISCChecker(; deflection_limit = 1 / 360, shell_spans = [spans])
            cache = SZ.create_cache(chk, 1)
            SZ.precompute_capacities!(chk, cache, [s], mat, MinWeight())
            return SZ.is_feasible(chk, cache, 1, s, mat, dem, geom)
        end
        span(L, r; I = Ix(sec), name = "W16X26") =
            SZ.SteelShellSpan(; L = L, Δ_LL = r * L / 360, I_solved = I, solved = name)

        @test ok([span(8.0, 0.99)], sec)
        @test !ok([span(8.0, 1.01)], sec)
        # A short span past its own L/360 governs over a long span that passes.
        @test !ok([span(8.0, 0.5), span(2.0, 1.05)], sec)
        # A stiffer candidate scales the deflection down by I_solved / Ix.
        @test ok([span(8.0, 1.5)], big)
        @test Ix(sec) / Ix(big) * 1.5 < 1
        # The solved section is checked unscaled, whatever I_solved says.
        @test ok([span(8.0, 0.99; I = 2 * Ix(sec))], sec)
        @test !ok([span(8.0, 0.99; I = 2 * Ix(sec), name = nothing)], sec)
        # No spans, or no limit: no check.
        @test ok(SZ.SteelShellSpan[], sec)
        chk = AISCChecker(; deflection_limit = nothing, shell_spans = [[span(8.0, 5.0)]])
        @test SZ._steel_shell_ratio(chk, 1, sec, Ix(sec)) == 0.0
    end

    @testset "A shell moment field per combination, from the building field's end" begin
        steel = ISymmSection(10u"inch", 8u"inch", 0.3u"inch", 0.5u"inch"; material = A992_Steel)
        bay = _edge_beam_bay(steel)
        fwd = story_shell_beam_demands(bay.model, bay.built.frames, bay.index, bay.cases;
                                       origins = Dict(1 => (0.0, 0.0)))
        rev = story_shell_beam_demands(bay.model, bay.built.frames, bay.index, bay.cases;
                                       origins = Dict(1 => (bay.Lx, 0.0)))
        @test length(fwd[1].moment_fields) == length(bay.cases.combinations)
        @test isempty(fwd[2].moment_fields)
        for (k, c) in enumerate(bay.cases.combinations)
            f, r = fwd[1].moment_fields[k], rev[1].moment_fields[k]
            for s in (0.1, 0.3, 0.5)
                @test ustrip(u"N*m", f(s)) ≈ ustrip(u"N*m", r(1 - s)) rtol = 1e-9
            end
            # Midspan of the south beam is half the two symmetric frames.
            @test ustrip(u"N*m", f(0.5)) ≈ _frame_moment_at(bay, c, bay.Lx / 2) / 2 rtol = 0.02
            # The peak sagging moment of every field is within the envelope.
            @test maximum(s -> ustrip(u"N*m", f(s)), 0:0.01:1) <= fwd[1].Mu_pos * (1 + 1e-6)
        end
        @test_throws ArgumentError story_shell_beam_demands(
            bay.model, bay.built.frames, bay.index, bay.cases; origins = Dict(1 => (3.0, 1.0)))
    end

    @testset "Strength fields check anchors on their own zeros" begin
        sec = W("W16X26")
        mat = A992_Steel
        L = 8.0u"m"
        slab = SolidSlabOnBeam(7.5u"inch", 4.0u"ksi", 3644.0u"ksi", 145.0u"lb/ft^3",
                               29000.0u"ksi", 2.5u"m", 2.5u"m")
        anchor = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0u"ksi", 50.0u"ksi",
                                  7850.0u"kg/m^3")
        # Shored: the sagging check alone, with no bare-steel construction stage.
        ctx = CompositeContext(slab, anchor, L; shored = true, Lb_const = 1.0u"m")
        geom = SteelMemberGeometry(L; Lb = 1.0u"m")
        checker = AISCChecker(; deflection_limit = nothing, total_deflection_limit = nothing,
                              max_depth = Inf)
        cache = StructuralSizer.create_cache(checker, 1)
        StructuralSizer.precompute_capacities!(checker, cache, [sec], mat, MinWeight())
        # Near full composite: the anchors for the full span fit, not in 0.4 m.
        b = get_b_eff(slab, L)
        Cf = StructuralSizer._Cf_max(sec, mat, slab, b)
        M0 = 0.9 * ustrip(u"N*m", get_ϕMn_composite(sec, mat, slab, b, Cf).ϕMn)
        full = BeamSaggingField(nothing, nothing, s -> 4M0 * s * (1 - s) * u"N*m", [0.0, 1.0])
        # Same peak, but sagging only between s = 0.45 and 0.55: shear spans of 0.4 m.
        narrow = BeamSaggingField(nothing, nothing,
            s -> M0 * (1 - ((s - 0.5) / 0.05)^2) * u"N*m", [0.0, 1.0])
        dem = MemberDemand(1; Mux = M0, Mux_pos = M0, Mux_neg = 0.0, Vu_strong = 1.0e5)
        feasible(psc) = StructuralSizer.is_feasible(checker, cache, 1, sec, mat, dem, geom, psc)
        @test feasible(PerStationComposite(ctx, [full]))
        @test !feasible(PerStationComposite(ctx, [full]; strength_fields = [narrow]))
        @test_throws ArgumentError PerStationComposite(ctx, BeamSaggingField[];
                                                       strength_fields = [narrow])

        # Shell spans on a composite candidate use its own service inertia.
        Ls = 6.0
        Ix_s = ustrip(u"m^4", sec.Ix)
        svc(r; name) = [[SZ.SteelShellSpan(; L = Ls, Δ_LL = r * Ls / 360,
                                           I_solved = Ix_s, solved = name)]]
        # Near full composite, so the candidate has studs and I_LB > Ix.
        studded = MemberDemand(1; Mux = M0, Mux_pos = M0, Mux_neg = 0.0, Vu_strong = 1.0e5)
        function comp_ok(spans)
            chk = AISCChecker(; deflection_limit = 1 / 360, total_deflection_limit = nothing,
                              shell_spans = spans)
            c = SZ.create_cache(chk, 1)
            SZ.precompute_capacities!(chk, c, [sec], mat, MinWeight())
            return SZ.is_feasible(chk, c, 1, sec, mat, studded, geom, ctx)
        end
        @test comp_ok(svc(0.99; name = sec.name))
        @test !comp_ok(svc(1.01; name = sec.name))
        # Recorded as if solved bare: the composite inertia is larger, so the
        # same deflection scales down, once.
        @test comp_ok(svc(1.01; name = nothing))
    end

    @testset "Composite steel on the shell: composite stiffness and per-case fields" begin
        struc, corners = _one_bay_building()
        conc = Concrete(3644.0u"ksi", 4.0u"ksi", 145.0u"lb/ft^3", 0.20, 0.1)
        opts = SteelBeamOptions(; _STUD_OPTS...,
                                custom_catalog = [W("W12X26"), W("W16X40"), W("W21X55")],
                                deflection_limit = nothing, total_deflection_limit = nothing)
        out = size_beams_with_story_shell!(struc, opts; levels = [0], reanalyze = false,
            composite_concrete = conc, composite_t_slab = 8.0u"inch",
            shell_kwargs = (target_edge = 1.0u"m", support_points = corners))
        @test out.converged
        @test all(b -> section(b) !== nothing, struc.beams)
        @test all(d -> !isempty(d.moment_fields), values(out.demands))

        # Each piece takes the building model's inertia at its station, with
        # nothing removed: Eq. C-I3-1 has no slab self-bending for the shell to overlap.
        beam = struc.beams[1]
        prof = SY.composite_stiffness_profile(struc, beam)
        @test prof !== nothing
        res = analyze_story_shell(struc, 0; target_edge = 1.0u"m", support_points = corners,
                                  steel = A992_Steel)
        @test isempty(filter(r -> occursin("composite", r), res.reasons))
        bare = ustrip(u"m^4", section(beam).Ix)
        pieces = [el for el in res.built.frames if el.id === :beam_1]
        @test all(el -> ustrip(u"m^4", el.section.Ix) >= bare * (1 - 1e-12), pieces)
        x0, y0 = prof.origin
        total = sum(Float64(Asap.ElementProps(el).L) for el in pieces)
        for el in pieces
            a, b = SY._plan_xy(el.nodeStart), SY._plan_xy(el.nodeEnd)
            s = hypot((a[1] + b[1]) / 2 - x0, (a[2] + b[2]) / 2 - y0) / total
            @test ustrip(u"m^4", el.section.Ix) ≈ ustrip(u"m^4", SY.composite_stiffness_at(prof, s)) rtol = 1e-9
        end

        # Live-load span records carry the solved section's service inertia.
        recs = res.service_spans[1]
        @test !isempty(recs)
        @test all(r -> r isa SZ.SteelShellSpan, recs)
        @test all(r -> r.solved == section(beam).name, recs)
        # Studs only where strength needs them: none here, so I_LB falls back to Ix.
        @test all(r -> r.I_solved >= bare * (1 - 1e-12), recs)
        @test all(r -> r.I_solved ≈ SY._solved_service_inertia(prof), recs)
        @test all(r -> r.Δ_LL > 0, recs)

        # Pinned steel beams in both models: the shell releases the end pieces,
        # and the frame model and the shell sag over the same region.
        @test pieces[1] isa Asap.Element{Asap.FreeFixed}
        @test pieces[end] isa Asap.Element{Asap.FixedFree}
        @test all(el -> el isa Asap.Element{Asap.FixedFixed}, pieces[2:end-1])
        @test SY.composite_region_mismatch(prof, out.demands[1].moment_fields) < 0.05
        # Converged: the regions the last shell placed the stiffness on held.
        @test haskey(out.region_mismatch, 1)
        @test all(<=(0.05), values(out.region_mismatch))

        # Stiffness placed on given regions: a hogging end takes the cracked section.
        hog = [merge(first(prof.regions), (; s_left = 0.0, s_right = 0.8))]
        moved = analyze_story_shell(struc, 0; target_edge = 1.0u"m", support_points = corners,
                                    steel = A992_Steel, service = false,
                                    composite_regions = Dict(1 => hog))
        @test moved.composite_regions[1] == hog
        @test res.composite_regions[1] == prof.regions
        on = SY.composite_profile_on_regions(prof, hog)
        cracked = ustrip(u"m^4", SZ.get_I_cracked_negative(prof.section, prof.Asr;
                                                         d_rebar = prof.d_rebar))
        for el in (el for el in moved.built.frames if el.id === :beam_1)
            a, b = SY._plan_xy(el.nodeStart), SY._plan_xy(el.nodeEnd)
            s = hypot((a[1] + b[1]) / 2 - x0, (a[2] + b[2]) / 2 - y0) / total
            Ix = ustrip(u"m^4", el.section.Ix)
            @test Ix ≈ ustrip(u"m^4", SY.composite_stiffness_at(on, s)) rtol = 1e-9
            s > 0.8 + 1e-6 && @test Ix ≈ cracked rtol = 1e-9
        end
    end

    @testset "Composite regions: shift and anchor strength on new regions" begin
        r(a, b; q = 1.0) = (s_left = a, s_right = b, s_peak = (a + b) / 2, M_peak = q)
        @test SY._region_shift([r(0.0, 1.0)], nothing) == 0.0
        @test SY._region_shift([r(0.0, 1.0)], [r(0.0, 0.85)]) ≈ 0.15
        @test SY._region_shift([r(0.0, 1.0)], [r(0.0, 0.4), r(0.6, 1.0)]) == Inf
        prof = (regions = NamedTuple[r(0.0, 0.5), r(0.5, 1.0)], ΣQn = [3.0, 2.0])
        # Smallest overlapping anchor strength; no overlap drops the region.
        on = SY.composite_profile_on_regions(prof, NamedTuple[r(0.2, 0.9)])
        @test on.ΣQn == [2.0]
        on = SY.composite_profile_on_regions(prof, NamedTuple[r(0.1, 0.4)])
        @test on.ΣQn == [3.0]
        none = SY.composite_profile_on_regions((regions = NamedTuple[r(0.0, 0.3)], ΣQn = [1.0]),
                                               NamedTuple[r(0.5, 0.9)])
        @test isempty(none.regions)
    end

    @testset "Shell beam end releases" begin
        @test SZ._piece_release(:freefree, 1, 1) === :freefree
        @test SZ._piece_release(:joist, 1, 1) === :joist
        @test SZ._piece_release(:freefree, 1, 4) === :freefixed
        @test SZ._piece_release(:freefree, 4, 4) === :fixedfree
        @test SZ._piece_release(:freefree, 2, 4) === :fixedfixed
        @test SZ._piece_release(:freefixed, 4, 4) === :fixedfixed
        @test SZ._piece_release(:fixedfree, 1, 4) === :fixedfixed
        @test SZ._piece_release(:joist, 1, 3) === :freefixed
        @test_throws ArgumentError SZ.ShellFrameBeam([(0.0, 0.0), (1.0, 0.0)],
            SZ.to_asap_section(W("W12X26"), A992_Steel); release = :hinged)

        # A pinned steel beam takes no end moment from its own bending: only
        # the axial force through the offset reaches the shell node.
        steel = ISymmSection(10u"inch", 8u"inch", 0.3u"inch", 0.5u"inch"; material = A992_Steel)
        fixed = _edge_beam_bay(steel)
        pinned = _edge_beam_bay(steel; release = :freefree)
        f_end(bay) = maximum(c -> abs(_frame_moment_at(bay, c, 0.0)), bay.cases.combinations)
        f_mid(bay) = maximum(c -> _frame_moment_at(bay, c, bay.Lx / 2), bay.cases.combinations)
        @test f_end(pinned) < 0.05 * f_end(fixed)
        @test f_mid(pinned) > f_mid(fixed)
    end

    @testset "Cracked service shell" begin
        line = [(0.0, 0.0), (6.0, 0.0)]
        simple = SZ.shell_service_spans(line, [(0.0, 0.0), (6.0, 0.0)])
        @test length(simple) == 1
        @test !simple[1].cantilever && simple[1].n_continuous == 0

        two = SZ.shell_service_spans(line, [(0.0, 0.0), (3.0, 0.0), (6.0, 0.0)])
        @test length(two) == 2
        @test two[1].n_continuous == 1 && two[1].end1_continuous
        @test two[2].n_continuous == 1 && two[2].end0_continuous

        cants = SZ.shell_service_spans(line, [(3.0, 0.0)])
        @test length(cants) == 2 && all(sp.cantilever for sp in cants)

        @test SZ.chord_deflection([0.0, 0.5, 1.0], [0.0, -0.01, 0.0]) ≈ 0.01

        conc = NWC_4000
        Ec = ustrip(u"Pa", conc.E)
        Es = ustrip(u"Pa", Rebar_60.E)
        fr_ = ustrip(u"Pa", SZ.fr(conc.fc′)) * conc.λ
        @test SZ.slab_strip_inertia_ratio(0.0, 1e-3, 0.15, 0.12, Ec, Es, fr_) == 1.0
        @test SZ.slab_strip_inertia_ratio(1.0e6, 1e-3, 0.15, 0.12, Ec, Es, fr_) < 1.0

        sec = RCBeamSection(; b = 12u"inch", h = 16u"inch", bar_size = 8, n_bars = 3)
        bay = _edge_beam_bay(sec)
        u0 = copy(bay.model.u)
        E0 = [el.E for el in bay.built.shells]
        spec = SY.ShellServiceBeam(:south, [(0.0, 0.0), (bay.Lx, 0.0)], sec,
            [(0.0, 0.0), (bay.Lx, 0.0), (bay.Lx, bay.Ly), (0.0, bay.Ly)];
            half_width = _ -> 1.0, flange_width = _ -> 1.2, hf = 0.15,
            mu_neg = 5.0e4)
        design = SZ.StoryPanelDesign(40.0u"kPa", 20.0u"kPa", 0.15u"m", (0.0, 1.0), OneWay())
        out = SY.story_cracked_service(bay.model, bay.built, [design], [spec];
                                       concrete = conc, rebar = Rebar_60)
        @test out.converged
        @test haskey(out.spans, :south)
        span = only(out.spans[:south])
        @test !span.cantilever
        @test span.Δ_D > 0
        @test span.Δ_DL > span.Δ_D
        @test span.Δ_S == span.Δ_D
        @test span.Ma_S_pos == span.Ma_D_pos
        gross = SZ.rc_span_inertia(sec, span.bf, span.hf, 0.0, Float64[], span.Mu_neg;
                                    Ec = span.Ec, Es = span.Es, fr = span.fr,
                                    fc = span.fc, fy = span.fy)
        @test span.Ie_D <= gross.Ig * (1 + 1e-9)
        @test span.Ie_D < gross.Ig
        @test span.Ie_DL <= span.Ie_D * (1 + 1e-6)
        @test [el.E for el in bay.built.shells] == E0
        @test bay.model.u ≈ u0 rtol = 1e-6 atol = 1e-9

        # A shell deflection past L/360 rejects the section that was solved.
        long = SZ.RCShellSpan(; L = span.L, bf = span.bf, hf = span.hf,
            Ma_D_pos = span.Ma_D_pos, Ma_DL_pos = span.Ma_DL_pos,
            Δ_D = 0.002, Δ_DL = 0.05,
            Ie_D = span.Ie_D, Ie_DL = span.Ie_DL,
            Ec = span.Ec, Es = span.Es, fr = span.fr, fc = span.fc, fy = span.fy)
        @test !SZ.rc_shell_span_deflection(long, sec).ok
        short = SZ.RCShellSpan(; L = span.L, bf = span.bf, hf = span.hf,
            Ma_D_pos = span.Ma_D_pos, Ma_DL_pos = span.Ma_DL_pos,
            Δ_D = 1e-6, Δ_DL = 2e-6,
            Ie_D = span.Ie_D, Ie_DL = span.Ie_DL,
            Ec = span.Ec, Es = span.Es, fr = span.fr, fc = span.fc, fy = span.fy)
        @test SZ.rc_shell_span_deflection(short, sec).ok
    end
end
