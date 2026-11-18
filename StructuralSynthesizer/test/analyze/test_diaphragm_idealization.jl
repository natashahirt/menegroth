# HAND CHECK — ASCE 7-22 diaphragm idealization.
#
# Not a published example. Each case is the clause's own limit:
# §12.3.1 / §12.3.1.1 / §12.3.1.2 / §12.3.1.3 Eq. 12.3-1 (PDF p. 179),
# Table 12.3-1 type numbers as caller inputs (PDF p. 180), and the §26.2
# wind diaphragm (PDF p. 324). source_id: asce-7-22.

using Test
using Unitful
using Meshes
using StructuralSynthesizer
using StructuralSizer

"""Classifier call with the required inputs named once."""
function _ideal(; loading, construction, span, depth, irregularities=Int[], kwargs...)
    return classify_diaphragm_idealization(;
        loading, construction, span, depth,
        horizontal_irregularity_types=irregularities,
        kwargs...)
end

@testset "ASCE 7-22 diaphragm idealization" begin
    @testset "HAND CHECK seismic rigid, flexible, and semirigid" begin
        # §12.3.1.2: concrete slab, span/depth = 3, no Type 2–5 → rigid.
        @test _ideal(; loading=:seismic, construction=:concrete_slab,
                     span=3, depth=1) === :rigid
        # Exactly 3 with lengths, not bare numbers.
        @test _ideal(; loading=:seismic, construction=:concrete_slab,
                     span=9.0u"m", depth=3.0u"m") === :rigid
        # Above 3 is not permitted.
        @test _ideal(; loading=:seismic, construction=:concrete_slab,
                     span=3.01, depth=1) === :shell
        # Type 4 blocks the rigid permission. Type 1 does not.
        @test _ideal(; loading=:seismic, construction=:concrete_slab,
                     span=3, depth=1, irregularities=[4]) === :shell
        @test _ideal(; loading=:seismic, construction=:concrete_slab,
                     span=3, depth=1, irregularities=[1]) === :rigid
        for t in (2, 3, 5)
            @test _ideal(; loading=:seismic, construction=:concrete_slab,
                         span=3, depth=1, irregularities=[t]) === :shell
        end
        # §12.3.1.1 item 1: untopped steel deck over concrete shear walls.
        # The ratio is 10, so this is not a rigid permission.
        @test _ideal(; loading=:seismic, construction=:untopped_steel_deck,
                     span=10, depth=1,
                     vertical_elements=:concrete_shear_wall) === :flexible
        # Eq. 12.3-1 is strictly greater than 2. Neither §12.3.1.1 nor
        # §12.3.1.2 permits this slab (span/depth = 4).
        @test _ideal(; loading=:seismic, construction=:concrete_slab,
                     span=4, depth=1,
                     delta_mdd=2.0, delta_adve=1.0) === :shell
        @test _ideal(; loading=:seismic, construction=:concrete_slab,
                     span=4, depth=1,
                     delta_mdd=2.01, delta_adve=1.0) === :flexible
    end

    @testset "HAND CHECK wind does not borrow the seismic limit" begin
        @test _ideal(; loading=:wind, construction=:concrete_slab,
                     span=2, depth=1) === :rigid
        @test _ideal(; loading=:wind, construction=:concrete_slab,
                     span=2.5, depth=1) === :shell
        # The same slab is rigid for seismic. The classifier does not keep
        # the stricter of the two chapters.
        @test _ideal(; loading=:seismic, construction=:concrete_slab,
                     span=2.5, depth=1) === :rigid
        # §26.2 does not name Type 4. A ratio of 2 stays rigid.
        @test _ideal(; loading=:wind, construction=:concrete_slab,
                     span=2, depth=1, irregularities=[4]) === :rigid
        @test _ideal(; loading=:wind, construction=:wood_structural_panels,
                     span=1, depth=1) === :flexible
        @test _ideal(; loading=:wind, construction=:untopped_steel_deck,
                     span=2, depth=1) === :rigid
    end

    @testset "HAND CHECK filled-deck names are one construction" begin
        # §26.2: concrete-filled steel deck, span/depth = 2 → rigid.
        # `:concrete_filled_metal_deck` is that same deck. Exactly 2 is permitted.
        @test _ideal(; loading=:wind, construction=:concrete_filled_steel_deck,
                     span=2, depth=1) === :rigid
        @test _ideal(; loading=:wind, construction=:concrete_filled_metal_deck,
                     span=2, depth=1) === :rigid
        # Just above 2 is not rigid. The seismic limit of 3 is not used,
        # and a Type 4 irregularity is not a §26.2 test.
        @test _ideal(; loading=:wind, construction=:concrete_filled_metal_deck,
                     span=2.01, depth=1) === :shell
        @test _ideal(; loading=:wind, construction=:concrete_filled_metal_deck,
                     span=2, depth=1, irregularities=[4]) === :rigid
        # Eq. 12.3-1 is not applied to wind. A displacement ratio above 2
        # does not make this shell into a flexible diaphragm.
        @test _ideal(; loading=:wind, construction=:concrete_filled_metal_deck,
                     span=2.01, depth=1,
                     delta_mdd=3.0, delta_adve=1.0) === :shell
        # §12.3.1.2: concrete-filled metal deck, span/depth = 3, no Type 2–5
        # → rigid. `:concrete_filled_steel_deck` is that same deck.
        # Exactly 3 is permitted. The wind limit of 2 is not used.
        @test _ideal(; loading=:seismic, construction=:concrete_filled_metal_deck,
                     span=3, depth=1) === :rigid
        @test _ideal(; loading=:seismic, construction=:concrete_filled_steel_deck,
                     span=3, depth=1) === :rigid
        @test _ideal(; loading=:seismic, construction=:concrete_filled_steel_deck,
                     span=2.5, depth=1) === :rigid
        # Just above 3 is not rigid. An empty irregularity list does not
        # invent a Type 2–5 irregularity, and Type 4 still blocks a ratio of 3.
        @test _ideal(; loading=:seismic, construction=:concrete_filled_steel_deck,
                     span=3.01, depth=1) === :shell
        @test _ideal(; loading=:seismic, construction=:concrete_filled_steel_deck,
                     span=3, depth=1, irregularities=Int[]) === :rigid
        @test _ideal(; loading=:seismic, construction=:concrete_filled_steel_deck,
                     span=3, depth=1, irregularities=[4]) === :shell
        # Untopped steel deck is wind-rigid at a ratio of 2 and is not
        # seismic-rigid. No §12.3.1.1 item is asserted here.
        @test _ideal(; loading=:seismic, construction=:untopped_steel_deck,
                     span=2, depth=1) === :shell
    end

    @testset "HAND CHECK §12.3.1.1 item 3 is caller-supplied" begin
        # Wood panels, not a listed vertical system, not a dwelling.
        # Item 3 is the only flexible permission, and only when the caller
        # says each line complies and the topping is within 1.5 in.
        item3 = (;
            loading=:seismic, construction=:wood_structural_panels,
            span=8, depth=1, vertical_elements=:moment_frame,
            light_frame=true, each_line_complies_table_12_12_1=true,
        )
        @test _ideal(; item3..., topping_thickness=1.5u"inch",
                     topping_is_nonstructural=true) === :flexible
        @test _ideal(; item3..., topping_thickness=38u"mm",
                     topping_is_nonstructural=true) === :flexible
        @test _ideal(; item3..., topping_thickness=0u"inch") === :flexible
        @test _ideal(; item3..., topping_thickness=1.5u"inch" + 1u"mm",
                     topping_is_nonstructural=true) === :shell
        # The compliance flag was not passed, so item 3 does not apply.
        @test _ideal(; loading=:seismic, construction=:wood_structural_panels,
                     span=8, depth=1, vertical_elements=:moment_frame,
                     light_frame=true, topping_thickness=0u"inch") === :shell
    end

    @testset "missing inputs throw" begin
        @test_throws ArgumentError _ideal(; loading=:seismic,
            construction=:concrete_slab, span=nothing, depth=1)
        @test_throws ArgumentError classify_diaphragm_idealization(;
            loading=:seismic, construction=:gypsum_panel, span=4, depth=1,
            horizontal_irregularity_types=Int[])
        @test_throws ArgumentError _ideal(; loading=:seismic,
            construction=:gypsum_panel, span=4, depth=1, delta_mdd=2.01)
        @test_throws ArgumentError _ideal(; loading=:other,
            construction=:concrete_slab, span=3, depth=1)
    end

    @testset "HAND CHECK simple spans between wall lines" begin
        # Lines at 0, 4, 10 m on a floor uniform from 0 to 10 m. Strips end at
        # the midpoints 2 and 7 m; the outer strips are open, so the floor past
        # the outermost lines goes to them: 2, 5, 3 m -> 0.2, 0.5, 0.3.
        line(off) = StructuralSynthesizer.DiaphragmLine(4.0, :x, off, Int[], Asap.Node[])
        uniform(lo, hi) = max(0.0, min(hi, 10.0) - max(lo, 0.0))
        shares = StructuralSynthesizer._diaphragm_line_shares(line.([0.0, 4.0, 10.0]), uniform)
        @test shares ≈ [0.2, 0.5, 0.3]
        @test StructuralSynthesizer._diaphragm_line_shares([line(5.0)], uniform) ≈ [1.0]
        @test_throws ArgumentError StructuralSynthesizer._diaphragm_line_shares(
            line.([0.0, 4.0]), (lo, hi) -> 0.0)

        # A 10 x 6 m rectangle cut at 1 <= y <= 4 keeps 10 x 3 = 30 m².
        rect = [(0.0, 0.0), (10.0, 0.0), (10.0, 6.0), (0.0, 6.0)]
        @test StructuralSynthesizer._strip_area(rect, (0.0, 1.0), 1.0, 4.0) ≈ 30.0
        @test StructuralSynthesizer._strip_area(rect, (0.0, 1.0), -Inf, Inf) ≈ 60.0
        @test StructuralSynthesizer._strip_area(rect, (1.0, 0.0), 7.5, Inf) ≈ 15.0
        # A wall along x at y = 3 is a point across y. On the shared bound
        # it is in exactly one strip.
        seg = ((0.0, 3.0), (10.0, 3.0))
        frac(lo, hi) = StructuralSynthesizer._strip_fraction(seg..., (0.0, 1.0), lo, hi)
        @test frac(-Inf, 3.0) + frac(3.0, Inf) == 1.0
        # A wall along y from 0 to 6, cut at 3: half each side.
        @test StructuralSynthesizer._strip_fraction((0.0, 0.0), (0.0, 6.0),
            (0.0, 1.0), -Inf, 3.0) ≈ 0.5
    end

    @testset "to_asap! :flexible" begin
        skel = gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 1, 1)
        bare = BuildingStructure(skel)
        err = try
            to_asap!(bare; diaphragms=:bogus)
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin(":flexible", sprint(showerror, err))
        @test_throws ArgumentError to_asap!(bare; diaphragms=:flexible)

        initialize!(bare)
        params = DesignParameters(diaphragm_mode=:flexible)
        model = to_asap!(bare; params=params)
        @test params.diaphragm_mode === :flexible
        @test isempty(bare.asap_rigid_links)
        @test isempty(model.shell_elements)
        # No story force was written onto the model.
        @test all(l -> !(l isa Asap.NodeForce), model.loads)
    end

    @testset "a strut is refused on a flexible diaphragm" begin
        skel = gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 1, 1)
        struc = BuildingStructure(skel)
        initialize!(struc)
        push!(struc.struts, Strut([1], 4.0u"m"))
        err = try
            to_asap!(struc; diaphragms=:flexible)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        msg = sprint(showerror, err)
        @test occursin("strut", msg)
        @test !occursin("walls or struts", msg)
    end

    @testset "Concrete-filled deck floor" begin
        # The construction is fixed. Seismic §12.3.1.2 (PDF p. 179):
        # span/depth of 3 is rigid; above 3 is a shell. Wind §26.2
        # (PDF p. 324) uses 2, not the seismic 3.
        @test deck_floor_diaphragm(; loading=:seismic, span=30.0u"ft", depth=10.0u"ft",
                horizontal_irregularity_types=Int[]) === :rigid
        @test deck_floor_diaphragm(; loading=:seismic, span=40.0u"ft", depth=10.0u"ft",
                horizontal_irregularity_types=Int[]) === :shell
        @test deck_floor_diaphragm(; loading=:wind, span=20.0u"ft", depth=10.0u"ft",
                horizontal_irregularity_types=Int[]) === :rigid
        @test deck_floor_diaphragm(; loading=:wind, span=30.0u"ft", depth=10.0u"ft",
                horizontal_irregularity_types=Int[]) === :shell
        # A type 2 horizontal irregularity blocks the seismic rigid permission.
        @test deck_floor_diaphragm(; loading=:seismic, span=30.0u"ft", depth=10.0u"ft",
                horizontal_irregularity_types=[2]) === :shell
    end

    @testset "HAND CHECK the stricter of wind and seismic" begin
        # Concrete, span/depth 2: both chapters permit rigid.
        @test stricter_diaphragm_idealization(; construction=:concrete_slab,
            span=20.0, depth=10.0, horizontal_irregularity_types=Int[]) === :rigid
        # Span/depth 2.5: seismic §12.3.1.2 still permits rigid, wind §26.2 does not.
        @test stricter_diaphragm_idealization(; construction=:concrete_slab,
            span=25.0, depth=10.0, horizontal_irregularity_types=Int[]) === :shell
        # Span/depth 4: neither chapter permits an idealization.
        @test stricter_diaphragm_idealization(; construction=:concrete_slab,
            span=40.0, depth=10.0, horizontal_irregularity_types=Int[]) === :shell
        # A type 2 irregularity blocks the seismic rigid permission. Wind would allow it.
        @test stricter_diaphragm_idealization(; construction=:concrete_slab,
            span=20.0, depth=10.0, horizontal_irregularity_types=[2]) === :shell
        # Untopped deck on shear walls, span/depth 2: seismic flexible, wind rigid.
        @test stricter_diaphragm_idealization(; construction=:untopped_steel_deck,
            span=20.0, depth=10.0, horizontal_irregularity_types=Int[],
            vertical_elements=:concrete_shear_wall) === :shell
        # Wood panels on shear walls: both chapters permit flexible.
        @test stricter_diaphragm_idealization(; construction=:wood_structural_panels,
            span=40.0, depth=10.0, horizontal_irregularity_types=Int[],
            vertical_elements=:concrete_shear_wall) === :flexible
    end

    @testset "flexible story force" begin
        function _flex_xyz(skel, vidx)
            c = Meshes.coords(skel.vertices[vidx])
            return (ustrip(u"m", c.x), ustrip(u"m", c.y), ustrip(u"m", c.z))
        end

        near(a, b) = abs(a - b) <= 1e-6
        # 10 × 6 m plan, one bay along x and two 3 m bays along y.
        SIDES = Dict(
            :south => ((x1, y1, x2, y2) -> near(y1, 0) && near(y2, 0), 1),
            :long => ((x1, y1, x2, y2) -> (near(y1, 0) && near(y2, 0)) ||
                                          (near(y1, 6) && near(y2, 6)), 2),
            :perimeter => ((x1, y1, x2, y2) -> (near(y1, 0) && near(y2, 0)) ||
                                               (near(y1, 6) && near(y2, 6)) ||
                                               (near(x1, 0) && near(x2, 0)) ||
                                               (near(x1, 10) && near(x2, 10)), 6),
        )

        function claim_sides!(skel, nstory, sides)
            on_side, expected = SIDES[sides]
            beams = Set(get(skel.groups_edges, :beams, Int[]))
            walls = get!(skel.groups_edges, :walls, Int[])
            for story in 0:(nstory - 1)
                picked = Int[]
                for e in skel.stories[story].edges
                    e in beams || continue
                    v1, v2 = skel.edge_indices[e]
                    x1, y1, z1 = _flex_xyz(skel, v1)
                    x2, y2, z2 = _flex_xyz(skel, v2)
                    near(z1, z2) || continue
                    on_side(x1, y1, x2, y2) || continue
                    push!(picked, e)
                end
                length(picked) == expected || error(
                    "flexible fixture: story $story has $(length(picked)) $sides edges")
                for eidx in picked
                    filter!(!=(eidx), skel.groups_edges[:beams])
                    delete!(beams, eidx)
                    eidx in walls || push!(walls, eidx)
                end
            end
            return skel
        end

        function flex_office(; nstory=3, sides=:perimeter, drop_columns=false, params=nothing)
            skel = gen_medium_office(10.0u"m", 6.0u"m", 4.0u"m", 1, 2, nstory)
            claim_sides!(skel, nstory, sides)
            struc = BuildingStructure(skel)
            initialize!(struc; wall_thickness=0.3u"m", material=NWC_4000)
            for wall in struc.walls
                wall.concrete = RC_4000_60.concrete
            end
            drop_columns && empty!(struc.columns)
            p = params === nothing ? DesignParameters(diaphragm_mode=:flexible) : params
            to_asap!(struc; params=p)
            return struc
        end

        walls_a3 = LateralDesign(; system=WallsSeismicSystem(:A3), assignment=BuildingUnit())

        function laid_out(; kwargs...)
            struc = flex_office(; kwargs...)
            flexible_diaphragm_layout!(struc, walls_a3)
            return struc
        end

        # A corner node is on an x line and a y line. Each load carries one
        # component, so it is credited to the line along that component.
        function force_by_line(loads, lines)
            node_line = Dict{Tuple{UInt64, Symbol}, Int}()
            for (k, line) in enumerate(lines), nd in line.nodes
                node_line[(objectid(nd), line.direction)] = k
            end
            out = zeros(length(lines), 2)
            for load in loads
                fx = ustrip(u"kN", load.value[1])
                fy = ustrip(u"kN", load.value[2])
                (fx != 0 && fy != 0) && error("a line load has two components")
                k = node_line[(objectid(load.node), fx != 0 ? :x : :y)]
                out[k, 1] += fx
                out[k, 2] += fy
            end
            return out
        end

        @testset "wall lines and collector ties" begin
            struc = laid_out(; nstory=1, drop_columns=true)
            layout = struc.diaphragm_layout
            @test layout isa FlexibleDiaphragmLayout
            xl = sort([l for l in layout.lines if l.direction === :x]; by=l -> l.offset_m)
            yl = sort([l for l in layout.lines if l.direction === :y]; by=l -> l.offset_m)
            @test [l.offset_m for l in xl] ≈ [0.0, 6.0]
            @test [l.offset_m for l in yl] ≈ [0.0, 10.0]
            @test all(l -> length(l.walls) == 1, xl)
            # Each short side is two collinear 3 m walls: one line.
            @test all(l -> length(l.walls) == 2, yl)
            @test length(layout.links) == sum(length(l.nodes) - 1 for l in layout.lines)
            # The tie holds only the translation along the line, from the
            # line's first node. A corner node is on two lines, one per axis.
            @test all(link -> count(!, link.release) == 1, layout.links)
            for line in layout.lines
                k = line.direction === :x ? 1 : 2
                mine = [link for link in layout.links
                        if link.release == ntuple(i -> i != k, 6) && link.nodeB in line.nodes]
                @test length(mine) == length(line.nodes) - 1
                @test all(link -> link.nodeA === first(line.nodes), mine)
            end
            @test length(StructuralSynthesizer.lateral_solve_links(struc)) == length(layout.links)
        end

        @testset "line forces follow tributary seismic weight; columns take none" begin
            struc = laid_out(; nstory=1)
            @test !isempty(struc.columns)
            layout = struc.diaphragm_layout
            levels = StructuralSynthesizer._elf_levels(struc)
            @test length(levels) == 1
            @test only(levels).master === nothing
            loads = StructuralSynthesizer.diaphragm_story_loads(struc, levels,
                [40.0], [10.0], [3.0]; force_id=:elf_story, moment_id=:elf_torsion)
            @test all(l -> l isa Asap.NodeForce, loads)
            # Every load is on a wall-line node, so a gravity column is not loaded.
            line_nodes = Set(objectid(nd) for l in layout.lines for nd in l.nodes)
            @test all(l -> objectid(l.node) in line_nodes, loads)
            lines = layout.lines
            f = force_by_line(loads, lines)
            @test sum(f[:, 1]) ≈ 40.0 atol=1e-6
            @test sum(f[:, 2]) ≈ 10.0 atol=1e-6
            # Each share equals that line's strip of the ELF weight.
            lv = only(levels)
            for direction in (:x, :y)
                ls = StructuralSynthesizer._diaphragm_lines_at(layout, lv.elevation_m, direction)
                n = direction === :x ? (0.0, 1.0) : (1.0, 0.0)
                measure = StructuralSynthesizer._strip_measure(struc, lv, n)
                mid = 0.5 * (ls[1].offset_m + ls[2].offset_m)
                F = direction === :x ? 40.0 : 10.0
                col = direction === :x ? 1 : 2
                expected = F .* [measure(-Inf, mid), measure(mid, Inf)] ./ lv.weight_kN
                got = [f[findfirst(l -> l === li, lines), col] for li in ls]
                @test got ≈ expected rtol=1e-9
            end
        end

        @testset "opt-in accidental torsion is a couple on the farthest lines" begin
            struc = laid_out(; nstory=1)
            levels = StructuralSynthesizer._elf_levels(struc)
            base = StructuralSynthesizer._elf_loads(struc, levels, [40.0], [0.0], (1.0, 0.0))
            # §12.8.4.2.1: by default the moment is not applied on a flexible floor.
            off = StructuralSynthesizer._elf_loads(struc, levels, [40.0], [12.0], (1.0, 0.0))
            @test length(off) == length(base)
            on = StructuralSynthesizer._elf_loads(struc, levels, [40.0], [12.0], (1.0, 0.0);
                                                  flexible_accidental_torsion=true)
            extra = on[(length(base) + 1):end]
            @test !isempty(extra)
            fx = sum(ustrip(u"kN", l.value[1]) for l in extra)
            fy = sum(ustrip(u"kN", l.value[2]) for l in extra)
            mz = sum(ustrip(u"m", l.node.position[1]) * ustrip(u"kN", l.value[2]) -
                     ustrip(u"m", l.node.position[2]) * ustrip(u"kN", l.value[1]) for l in extra)
            @test fx ≈ 0.0 atol=1e-9
            @test fy ≈ 0.0 atol=1e-9
            @test mz ≈ 12.0 rtol=1e-9
            # The y lines (x = 0 and 10 m) are farther apart than the x lines.
            @test all(l -> abs(ustrip(u"kN", l.value[1])) <= 1e-12, extra)
        end

        @testset "a component with no wall line along it throws" begin
            struc = laid_out(; nstory=1, sides=:long)
            @test all(l -> l.direction === :x, struc.diaphragm_layout.lines)
            levels = StructuralSynthesizer._elf_levels(struc)
            loads = StructuralSynthesizer.diaphragm_story_loads(struc, levels,
                [40.0], [0.0], [0.0]; force_id=:elf_story, moment_id=:elf_torsion)
            @test !isempty(loads)
            err = try
                StructuralSynthesizer.diaphragm_story_loads(struc, levels,
                    [0.0], [10.0], [0.0]; force_id=:elf_story, moment_id=:elf_torsion)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("along y", sprint(showerror, err))
        end

        @testset "no wall lines built throws" begin
            struc = flex_office(; nstory=1)
            @test struc.diaphragm_layout === nothing
            levels = StructuralSynthesizer._elf_levels(struc)
            @test_throws ArgumentError StructuralSynthesizer.diaphragm_story_loads(struc, levels,
                [40.0], [0.0], [0.0]; force_id=:elf_story, moment_id=:elf_torsion)
        end

        @testset "a strut is still refused" begin
            struc = laid_out(; nstory=1)
            push!(struc.struts, Strut([1], 4.0u"m"))
            @test_throws ArgumentError flexible_diaphragm_layout!(struc, walls_a3)
            levels = StructuralSynthesizer._elf_levels(struc)
            err = try
                StructuralSynthesizer.diaphragm_story_loads(struc, levels, [40.0], [0.0], [0.0];
                    force_id=:elf_story, moment_id=:elf_torsion)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("strut", sprint(showerror, err))
        end

        @testset "center-of-mass drift is read between the lines" begin
            struc = laid_out(; nstory=2)
            layout = struc.diaphragm_layout
            elf = elf_story_analysis(struc; method=:sds, SDS=0.05, S1=0.02, R=5.0, Ie=1.0,
                T=0.4, Cd=4.5, β=1.0, SD1=0.02, TL=8.0)
            for (case, u) in zip(elf.cases, elf.displacements)
                # The collector tie: every node on a line moves together along it.
                for line in layout.lines
                    k = line.direction === :x ? 1 : 2
                    v = [u[nd.globalID[k]] for nd in line.nodes]
                    @test maximum(v) - minimum(v) <= 1e-9 * max(1.0, maximum(abs.(v)))
                end
                case.purpose === :drift || continue
                d = case.direction === :x ? (1.0, 0.0) : (0.0, 1.0)
                for (i, lv) in enumerate(elf.levels)
                    ls = StructuralSynthesizer._diaphragm_lines_at(layout, lv.elevation_m,
                                                                   case.direction)
                    @test length(ls) == 2
                    s = case.direction === :x ? lv.center_of_mass[2] : lv.center_of_mass[1]
                    t = (s - ls[1].offset_m) / (ls[2].offset_m - ls[1].offset_m)
                    @test 0 <= t <= 1
                    δ = (1 - t) * StructuralSynthesizer._line_displacement(u, ls[1], d) +
                        t * StructuralSynthesizer._line_displacement(u, ls[2], d)
                    @test case.elastic_m[i] ≈ δ rtol=1e-9
                    @test case.θ[i] !== nothing && case.θ[i] >= 0
                    @test case.Ax[i] === nothing
                end
                @test case.elastic_drift_m[1] ≈ case.elastic_m[1]
                @test case.elastic_drift_m[2] ≈ case.elastic_m[2] - case.elastic_m[1]
            end
            # A point beyond the outermost lines is not extrapolated.
            u = first(elf.displacements)
            z = first(elf.levels).elevation_m
            @test_throws ArgumentError StructuralSynthesizer._flexible_disp_at(
                u, layout, z, :x, (5.0, 7.0))
            @test_throws ArgumentError StructuralSynthesizer._flexible_disp_at(
                u, layout, z, :y, (-1.0, 3.0))
        end

        @testset "the ordinary-wall stage checks drift on a flexible floor" begin
            lateral = DesignParameters(
                diaphragm_mode=:flexible,
                lateral=walls_a3,
                wall_inputs=OrdinaryWallInputs(;
                    directions=((1.0, 0.0), (0.0, 1.0)),
                    qz=[1.0, 1.5, 2.0],
                    qh=2.0,
                    Kd=1.0,
                    G=0.85,
                    GCpi=0.18,
                    roof=:Lr,
                    method=:sds,
                    SDS=0.05,
                    S1=0.02,
                    Ie=1.0,
                    T=0.4,
                    β=1.0,
                    SD1=0.02,
                    TL=8.0,
                    rho=1.0,
                    sdc=:B,
                    risk_category=:II,
                    drift_system=:other,
                    boundary=:pinned,
                    material=RC_4000_60,
                    model_uses_cracked_section_stiffness=true,
                    sustained_lateral_loads=false,
                    sustained_lateral_divisor_applied=false,
                    type1_horizontal_irregularity=false,
                    type5_horizontal_irregularity=false,
                    orthogonal_combination=false,
                    orthogonal_12_5_4_conditions_absent=false,
                    ax_applied_to_accidental_torsion=false,
                    pdelta_included_in_member_forces=false,
                ),
                skip_visualization=true,
            )
            struc = flex_office(; nstory=3, params=lateral)
            @test isempty(struc.asap_rigid_links)
            result = design_ordinary_walls!(struc, lateral)
            @test result isa OrdinaryWallResult
            @test isempty(struc.asap_rigid_links)
            @test struc.diaphragm_layout isa FlexibleDiaphragmLayout
            @test !isempty(result.drift)
            @test result.max_story_stability > 0
            @test !isempty(result.checks)
            design = BuildingDesign(struc, lateral)
            StructuralSynthesizer._capture_ordinary_walls!(design, struc)
            StructuralSynthesizer._compute_design_summary!(design, struc, lateral)
            @test !any(d -> occursin("not checked", d), design.diagnostics)
            # An empty drift list on this flexible lateral floor does not pass.
            design.seismic_story_drift = Any[]
            StructuralSynthesizer._compute_design_summary!(design, struc, lateral)
            @test design.summary.all_checks_pass == false
            @test any(d -> occursin("not checked", d), design.diagnostics)
        end
    end
end
