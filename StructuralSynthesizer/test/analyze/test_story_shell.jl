# Two bays, one shell. The interior concrete beam hangs below the soffit.
# The edge steel beam stays on the shell nodes. Tributary design is untouched:
# the shell forces are stored beside it, and the story is analyzed only
# because every beam had a section and the shell solved.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer
using Asap

function _two_bay_story()
    skel = BuildingSkeleton{Float64}()
    z = 3.0
    v1 = add_vertex!(skel, [0.0, 0.0, z])
    v2 = add_vertex!(skel, [4.0, 0.0, z])
    v3 = add_vertex!(skel, [8.0, 0.0, z])
    v4 = add_vertex!(skel, [8.0, 2.0, z])
    v5 = add_vertex!(skel, [4.0, 2.0, z])
    v6 = add_vertex!(skel, [0.0, 2.0, z])
    add_element!(skel, v1, v2; group = :beams)
    add_element!(skel, v2, v5; group = :beams)
    add_element!(skel, v5, v6; group = :beams)
    add_element!(skel, v6, v1; group = :beams)
    add_element!(skel, v2, v3; group = :beams)
    add_element!(skel, v3, v4; group = :beams)
    add_element!(skel, v4, v5; group = :beams)
    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)
    struc = BuildingStructure(skel)
    A = 8.0u"m^2"
    spans = SpanInfo{Float64}(4.0, 2.0, (1.0, 0.0), 3.0)
    function push_bay!(corners, h)
        want = Set(corners)
        fidx = findfirst(vs -> Set(vs) == want, skel.face_vertex_indices)
        fidx === nothing && error("no face for $corners")
        cell = Cell(fidx, A, spans, 2.0u"kN/m^2", 3.0u"kN/m^2")
        cell.floor_type = :two_way
        push!(struc.cells, cell)
        slab = Slab{Float64}([length(struc.cells)], CIPSlabResult(h, h, 5.0), :two_way, spans,
                             :interior, nothing, MaterialVolumes(), nothing, nothing,
                             FramingLevel{Float64}[])
        push!(struc.slabs, slab)
    end
    push_bay!((v1, v2, v5, v6), 0.20)
    push_bay!((v2, v3, v4, v5), 0.25)
    for e in sort(collect(skel.groups_edges[:beams]))
        Lb = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, StructuralSynthesizer.Segment(e, Lb))
        push!(struc.beams, Beam([length(struc.segments)], Lb; role = :girder, level = 0))
    end
    function beam_on(va, vb)
        for b in struc.beams
            e = struc.segments[only(segment_indices(b))].edge_idx
            x, y = skel.edge_indices[e]
            Set((x, y)) == Set((va, vb)) && return b
        end
        error("no beam on ($va, $vb)")
    end
    interior = beam_on(v2, v5)
    edge = beam_on(v6, v1)
    steel = ISymmSection(10u"inch", 8u"inch", 0.3u"inch", 0.5u"inch"; material = A992_Steel)
    for b in struc.beams
        set_section!(b, b === interior ?
            RCBeamSection(b = 12u"inch", h = 20u"inch", bar_size = 9, n_bars = 3) : steel)
    end
    supports = [(0.0, 0.0), (4.0, 0.0), (8.0, 0.0), (8.0, 2.0), (4.0, 2.0), (0.0, 2.0)]
    return struc, interior, edge, supports
end

@testset "Story shell" begin
    struc, interior, edge, supports = _two_bay_story()
    interior_section = section(interior)
    # Strength only: this fixture has no tributaries, which the service widths need.
    result = analyze_story_shell(struc, 0; target_edge = 1.0u"m", support_points = supports,
                                 service = false)

    @test result.analysis_status == :analyzed
    @test isempty(result.skipped_beams)
    @test result.model !== nothing
    for slab in struc.slabs
        @test slab.design_details.analysis_status == :analyzed
        @test slab.design_details.analysis_source == :story_shell
        @test !isempty(slab.design_details.shell_beam_forces)
    end

    left = result.built.shells[result.built.panel_index .== 1]
    right = result.built.shells[result.built.panel_index .== 2]
    @test all(el -> el.thickness ≈ 0.20, left)
    @test all(el -> el.thickness ≈ 0.25, right)

    i_int = findfirst(==(interior), struc.beams)
    i_edge = findfirst(==(edge), struc.beams)
    concrete_frames = [el for el in result.built.frames if el.id == Symbol("beam_", i_int)]
    steel_frames = [el for el in result.built.frames if el.id == Symbol("beam_", i_edge)]
    @test !isempty(concrete_frames)
    @test !isempty(steel_frames)
    y = ustrip(u"m", 0.25u"m" / 2 + 10u"inch")
    @test all(el -> el.eccentricity[3] ≈ -y, concrete_frames)
    @test all(el -> el.eccentricity == (0.0, 0.0, 0.0, 0.0), steel_frames)
    @test all(fs -> !isempty(fs) && any(!iszero, fs), values(result.beam_forces))

    # The shell sizes the slab bars. The beam keeps the section it had.
    @test section(interior) === interior_section
    bars = struc.slabs[1].design_details.shell_reinforcement
    @test length(bars) == 2
    @test bars[1].h ≈ 0.20
    @test bars[2].h ≈ 0.25
    @test bars[1].moment_transform == :wood_armer
    @test bars[1].d ≈ ustrip(u"m", effective_depth(0.20u"m"; two_way = true))
    @test bars[2].d ≈ ustrip(u"m", effective_depth(0.25u"m"; two_way = true))
    @test any(el -> el.As_x_bot > 0 || el.As_y_bot > 0, bars[1].elements)
    @test any(el -> el.As_x_bot > 0 || el.As_y_bot > 0, bars[2].elements)

    # A beam that still has no section keeps the story unanalyzed.
    bare = _two_bay_story()[1]
    for b in bare.beams
        set_section!(b, nothing)
    end
    held = analyze_story_shell(bare, 0; target_edge = 1.0u"m", support_points = supports, solve = false)
    @test held.analysis_status == :not_analyzed
    @test !isempty(held.skipped_beams)
    @test held.model === nothing
end

@testset "Column rotational springs" begin
    skel = gen_medium_office(6.0u"m", 6.0u"m", 3.0u"m", 1, 1, 2)
    struc = BuildingStructure(skel)
    initialize!(struc; floor_type = :one_way, floor_opts = OneWayOptions())
    colsec = RCColumnSection(; b = 12u"inch", h = 24u"inch", bar_size = 8, n_bars = 8)
    beamsec = RCBeamSection(; b = 12u"inch", h = 20u"inch", bar_size = 8, n_bars = 3)
    for col in struc.columns
        set_section!(col, colsec)
    end
    for b in struc.beams
        set_section!(b, beamsec)
    end

    below = struc.columns[findfirst(c -> c.story == 1, struc.columns)]
    L = StructuralSynthesizer._column_length_m(struc, below)
    E = ustrip(u"Pa", NWC_4000.E)
    b = ustrip(u"m", 12u"inch")
    h = ustrip(u"m", 24u"inch")
    # to_asap_section applies ACI 318-11 §10.10.4.1 once. 0.70 is that factor.
    Ix = 0.70 * b * h^3 / 12
    Iy = 0.70 * h * b^3 / 12
    k = StructuralSynthesizer._column_end_stiffness(struc, below, NWC_4000, nothing)
    @test L ≈ 3.0
    @test k[1] ≈ 4 * E * Ix / L
    @test k[2] ≈ 4 * E * Iy / L
    below.θ = π / 2
    swapped = StructuralSynthesizer._column_end_stiffness(struc, below, NWC_4000, nothing)
    @test swapped[1] ≈ k[2]
    @test swapped[2] ≈ k[1]
    below.θ = 0.0

    # The floor has a column below and a column above, so the spring is the sum.
    floor = analyze_story_shell(struc, 1; target_edge = 2.0u"m", service = false)
    @test floor.analysis_status == :analyzed
    @test length(floor.model.springs) == 4
    @test all(s -> s.stiffness[4] ≈ 2 * k[1], floor.model.springs)
    @test all(s -> s.stiffness[5] ≈ 2 * k[2], floor.model.springs)

    # The roof has only the column below it.
    roof = analyze_story_shell(struc, 2; target_edge = 2.0u"m", service = false)
    @test length(roof.model.springs) == 4
    @test all(s -> s.stiffness[4] ≈ k[1], roof.model.springs)

    function support_rotation(u, nodes)
        r = 0.0
        for n in nodes
            n.dof[3] && continue
            r = max(r, abs(u[n.globalID[4]]), abs(u[n.globalID[5]]))
        end
        return r
    end
    with_springs = support_rotation(floor.model.u, floor.model.nodes)
    empty!(floor.model.springs)
    Asap.update!(floor.model; values_only = true)
    Asap.solve!(floor.model)
    @test with_springs < support_rotation(floor.model.u, floor.model.nodes)
end
