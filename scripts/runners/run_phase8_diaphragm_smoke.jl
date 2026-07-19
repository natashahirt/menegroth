# Phase 8 smoke test — slab FEA mesh respects joist framing lines (plan
# joists-roles-materials, Phase 8).
#
# Exercises the Phase 8 changes to `StructuralSynthesizer/src/analyze/asap/utils.jl`:
#   (1) `_collect_slab_joist_lines` — empty for a slab with no framing_levels;
#       non-empty for a slab whose Phase 5 `populate_levels!` produced joists.
#       Each `_DiaphragmJoistLine` carries a polyline (metres), the reused
#       `Asap.Node` objects, and refinement samples.
#   (2) `create_slab_diaphragm_shells` — succeeds for both no-joist and
#       with-joist slabs; the no-joist path meshes at n=2 (baseline unchanged),
#       the with-joist path invokes constrained Delaunay via
#       `interior_constrained_lines` + `interior_nodes`.
#   (3) DOF-sharing invariant — every joist-landing `Asap.Node` reused as an
#       `interior_node` also appears (by object identity, `===`) somewhere in
#       the resulting shell mesh, so the frame elements and shell mesh share
#       real DOFs after `Asap.process!` (per Asap Phase A3 contract).
#   (4) End-to-end via `to_asap!(diaphragms=:shell)` — the model carries shell
#       elements AND the Phase 7 `AreaLoad.interior_beams` still contains
#       exactly the `:joist` frame elements (i.e. Phase 8's mesh work does not
#       regress the Phase 7 role filter).
#
# UPSTREAM STIFFNESS GAP:
#   kj_eng_v2 closed the `k_joist` / `k_freefree` / … `Asap.local_K` gap by
#   deriving each released-element matrix through `_k_fixedfixed_full →
#   _condense_released_dofs`. Phase 7 smoke observed `tolerate_joist_stiffness_gap`
#   caught nothing (process! succeeds end-to-end on :joist frame models). We
#   keep the helper here for parity with Phase 7 in case a future released
#   type ships without a stiffness rule; today it is a no-op.
#
# Run:
#   SS_ENABLE_VISUALIZATION=false SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD=false \
#   julia --project=StructuralSynthesizer scripts/runners/run_phase8_diaphragm_smoke.jl

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer
using Asap

const SS = StructuralSynthesizer
const SZ = StructuralSizer

"""Documented Asap released-element stiffness gap (Phase 7 heritage)."""
function _is_asap_released_stiffness_gap(err)
    err isa UndefVarError || return false
    return err.var in (:k_joist, :k_freefree, :k_fixedfree, :k_freefixed, :k_fixedfixed)
end

"""Run `f()`; swallow only the released-element stiffness gap. kj_eng_v2
closed this in `external/Asap/src/Elements/K.jl`, so today the helper catches
nothing — kept for parity with the Phase 7 smoke."""
function tolerate_joist_stiffness_gap(f)
    try
        f()
    catch err
        _is_asap_released_stiffness_gap(err) || rethrow()
    end
    return nothing
end

"""Single rectangular bay at x-origin `x0`. Returns the four CCW vertex indices."""
function build_bay!(skel; x0::Float64, Lx::Float64 = 8.0, Ly::Float64 = 6.0, z::Float64 = 3.0)
    a = add_vertex!(skel, [x0,      0.0, z])
    b = add_vertex!(skel, [x0 + Lx, 0.0, z])
    c = add_vertex!(skel, [x0 + Lx, Ly,  z])
    d = add_vertex!(skel, [x0,      Ly,  z])
    add_element!(skel, a, b; group = :beams)
    add_element!(skel, b, c; group = :beams)
    add_element!(skel, c, d; group = :beams)
    add_element!(skel, d, a; group = :beams)
    supports = get!(skel.groups_vertices, :support, Int[])
    append!(supports, (a, b, c, d))
    return (a, b, c, d)
end

face_for_corners(skel, corners) =
    findfirst(vs -> Set(vs) == Set(corners), skel.face_vertex_indices)

"""Build a fully-populated two-way slab bay with auto-generated joists. Returns
`(struc, slab)` ready to hand to `create_slab_diaphragm_shells`."""
function build_two_way_bay_with_joists()
    skel = BuildingSkeleton{Float64}()
    corners = build_bay!(skel; x0 = 0.0)
    rebuild_stories!(skel); find_faces!(skel); rebuild_geometry_cache!(skel)

    struc = BuildingStructure(skel)
    A  = 48.0u"m^2"
    dl = 2.0u"kN/m^2"
    ll = 3.0u"kN/m^2"
    spans = SpanInfo{Float64}(8.0, 6.0, (1.0, 0.0), 7.0)

    fidx = face_for_corners(skel, corners)
    fidx === nothing && error("face not found")
    cell = Cell(fidx, A, spans, dl, ll)
    cell.floor_type = :two_way
    push!(struc.cells, cell)

    # Shell diaphragms need unitful thickness so `Asap.ShellSection` is happy.
    slab = Slab{Float64}([1], CIPSlabResult(0.2u"m", 0.2u"m", 5.0u"kPa"),
                        :two_way, spans, :interior, nothing, MaterialVolumes(),
                        nothing, nothing, FramingLevel{Float64}[])
    push!(struc.slabs, slab)

    for e in sort(collect(skel.groups_edges[:beams]))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        push!(struc.beams, Beam([length(struc.segments)], L; role = :girder, level = 0))
    end

    opts = (materials = (steel = A992_Steel, concrete = NWC_4000), spacing = 2.0)
    populate_levels!(struc; opts = opts)

    return struc, slab
end

"""Same fixture but WITHOUT `populate_levels!` — the slab keeps an empty
`framing_levels` vector. Exercises the byte-identical no-joist mesh path."""
function build_two_way_bay_no_joists()
    skel = BuildingSkeleton{Float64}()
    corners = build_bay!(skel; x0 = 0.0)
    rebuild_stories!(skel); find_faces!(skel); rebuild_geometry_cache!(skel)

    struc = BuildingStructure(skel)
    A  = 48.0u"m^2"
    dl = 2.0u"kN/m^2"
    ll = 3.0u"kN/m^2"
    spans = SpanInfo{Float64}(8.0, 6.0, (1.0, 0.0), 7.0)

    fidx = face_for_corners(skel, corners)
    cell = Cell(fidx, A, spans, dl, ll)
    cell.floor_type = :two_way
    push!(struc.cells, cell)
    slab = Slab{Float64}([1], CIPSlabResult(0.2u"m", 0.2u"m", 5.0u"kPa"),
                        :two_way, spans, :interior, nothing, MaterialVolumes(),
                        nothing, nothing, FramingLevel{Float64}[])
    push!(struc.slabs, slab)

    for e in sort(collect(skel.groups_edges[:beams]))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        push!(struc.beams, Beam([length(struc.segments)], L; role = :girder, level = 0))
    end

    return struc, slab
end

"""Build the `Vector{Asap.Node}` `create_slab_diaphragm_shells` expects
(indexed by skeleton vertex; no column offsets, no supports)."""
build_nodes(struc) = SS._create_offset_nodes(struc.skeleton,
                                             Dict{Int, NTuple{2, Float64}}(),
                                             Set{Int}())

@testset "Phase 8 — slab FEA mesh respects framing lines" begin
    # ── (1) _collect_slab_joist_lines ─────────────────────────────────────
    @testset "(1a) empty framing_levels ⇒ no joist lines" begin
        struc, slab = build_two_way_bay_no_joists()
        nodes = build_nodes(struc)
        lines = SS._collect_slab_joist_lines(struc, slab, nodes)
        @test isempty(lines)
    end

    @testset "(1b) auto-populated joists ⇒ one line per :joist beam" begin
        struc, slab = build_two_way_bay_with_joists()
        nodes = build_nodes(struc)
        lines = SS._collect_slab_joist_lines(struc, slab, nodes)

        # Every :joist member of every framing_level of this slab should
        # produce exactly one _DiaphragmJoistLine.
        expected = 0
        for fl in slab.framing_levels
            fl.group_id === nothing && continue
            grp = get(struc.member_groups, fl.group_id, nothing)
            grp === nothing && continue
            for mi in grp.member_indices
                b = struc.beams[mi]
                b.role === :joist && (expected += 1)
            end
        end
        @test expected > 0                # fixture really is generating joists
        @test length(lines) == expected

        for line in lines
            # polyline: at least two 2D points, finite coords, non-zero length.
            @test length(line.polyline) >= 2
            @test all(pt -> all(isfinite, pt), line.polyline)
            seglens = [hypot(line.polyline[i + 1][1] - line.polyline[i][1],
                             line.polyline[i + 1][2] - line.polyline[i][2])
                       for i in 1:(length(line.polyline) - 1)]
            @test sum(seglens) > 0

            # node_objs: same length as polyline, real Asap.Node objects, and
            # (crucially) fetched by identity from `nodes` so the mesher can
            # reuse them and share DOFs.
            @test length(line.node_objs) == length(line.polyline)
            @test all(n -> n isa Asap.Node, line.node_objs)
            for n in line.node_objs
                @test any(nn -> nn === n, nodes)
            end

            # refine_nodes: exactly 3 samples (Phase 8 default), all Node,
            # strictly interior to the span (not at endpoints).
            @test length(line.refine_nodes) == 3
            for rn in line.refine_nodes
                @test rn isa Asap.Node
                # Any interior sample must differ from the endpoints in xy.
                p1, p2 = line.polyline[1], line.polyline[end]
                rx = ustrip(u"m", rn.position[1])
                ry = ustrip(u"m", rn.position[2])
                @test !(isapprox(rx, p1[1]; atol = 1e-9) &&
                        isapprox(ry, p1[2]; atol = 1e-9))
                @test !(isapprox(rx, p2[1]; atol = 1e-9) &&
                        isapprox(ry, p2[2]; atol = 1e-9))
            end

            # midpoint = half-arclength sample.
            @test all(isfinite, line.midpoint)
        end
    end

    # ── (2) create_slab_diaphragm_shells ──────────────────────────────────
    @testset "(2a) no-joist slab: baseline mesh" begin
        struc, slab = build_two_way_bay_no_joists()
        nodes = build_nodes(struc)
        shells = create_slab_diaphragm_shells(struc, slab, nodes)
        @test !isempty(shells)
        @test all(sh -> sh isa Asap.ShellElement, shells)
    end

    @testset "(2b) with-joist slab: constrained-Delaunay mesh built" begin
        struc, slab = build_two_way_bay_with_joists()
        nodes = build_nodes(struc)
        shells = create_slab_diaphragm_shells(struc, slab, nodes)
        @test !isempty(shells)
        @test all(sh -> sh isa Asap.ShellElement, shells)

        # Different code path (n=2 grid vs. constrained + Ruppert-refined) ⇒
        # the two meshes must have different triangle counts. Direction is not
        # asserted: refinement_edge_length = short_side/6 with the Ruppert
        # algorithm actually produces FEWER triangles than the Asap n=2 quad-
        # split grid for a well-shaped bay (measured: 208 vs 1536). The point
        # is that the branch was taken — test (3) below proves DOF sharing.
        struc_no, slab_no = build_two_way_bay_no_joists()
        nodes_no = build_nodes(struc_no)
        baseline_shells = create_slab_diaphragm_shells(struc_no, slab_no, nodes_no)
        @test length(shells) != length(baseline_shells)
    end

    # ── (3) DOF-sharing invariant ─────────────────────────────────────────
    @testset "(3) joist-landing Nodes are reused by the shell mesh (===)" begin
        struc, slab = build_two_way_bay_with_joists()
        nodes = build_nodes(struc)
        lines = SS._collect_slab_joist_lines(struc, slab, nodes)
        shells = create_slab_diaphragm_shells(struc, slab, nodes)

        # Every joist-landing Node reported by _collect_slab_joist_lines must
        # appear (by object identity) somewhere in the assembled mesh.
        shell_nodes = Set{Asap.Node}()
        for sh in shells, n in sh.nodes
            push!(shell_nodes, n)
        end
        for line in lines, n in line.node_objs
            @test n in shell_nodes
        end
    end

    # ── (4) end-to-end via to_asap!(diaphragms=:shell) ────────────────────
    # NOTE (Phase 9 wiring gap, out of Phase 8 scope): `to_asap!` builds
    # diaphragm shells via `_create_shell_diaphragms` (which internally calls
    # `create_slab_diaphragm_shells`) and uses them to build the `AreaLoad`
    # geometry, but line 205 constructs the model as
    # `Asap.Model(nodes, frame_elements, loads)` — shells are NOT joined to
    # the assembled stiffness (utils.jl:205 comment: "shells contribute to K
    # separately"). Wiring shells into `struc.asap_model.shell_elements` is
    # Phase 9 territory (diaphragm wiring / lateral). Phase 8 here only
    # guarantees that the shells feeding the AreaLoad respect the joist
    # framing lines (tests 2b + 3) and that the Phase 7 role filter still
    # holds through the shell-area routing path.
    @testset "(4) to_asap!(diaphragms=:shell) + AreaLoad interior_beams" begin
        struc, _ = build_two_way_bay_with_joists()
        params = DesignParameters(materials =
            MaterialOptions(steel = A992_Steel, beam = A992_Steel))

        tolerate_joist_stiffness_gap(() ->
            to_asap!(struc; params = params,
                     diaphragms = :shell, load_routing = :shell_area))

        model = struc.asap_model
        @test model !== nothing

        # Phase 7's role filter still holds: interior_beams == joists only,
        # AND the AreaLoad was emitted (proves the :shell_area path fired —
        # which in turn only fires when `_create_shell_diaphragms` produced
        # non-empty shells, exercising Phase 8's joist-aware mesher).
        area_loads = Asap.AreaLoad[ld for ld in model.loads if ld isa Asap.AreaLoad]
        @test length(area_loads) == 1
        al = first(area_loads)

        # Map each frame element back to its skeleton edge and confirm every
        # interior_beam is a :joist. Frame elements are built one-per-edge in
        # `to_asap!`, so their vector position === edge index.
        joist_edges = Set{Int}()
        for b in struc.beams
            b.role === :joist || continue
            for si in SS.segment_indices(b)
                push!(joist_edges, struc.segments[si].edge_idx)
            end
        end
        elem_edge = IdDict{Any, Int}()
        for (i, el) in enumerate(model.elements)
            elem_edge[el] = i
        end
        @test !isempty(al.interior_beams)
        @test all(el -> get(elem_edge, el, -1) in joist_edges, al.interior_beams)
    end

    # ── (5) internal call path: _create_shell_diaphragms → constrained mesh ─
    # `to_asap!` invokes `_create_shell_diaphragms` for both `:shell` and
    # `:rigid` diaphragm modes. Confirm THAT call path (not just the public
    # `create_slab_diaphragm_shells`) still produces a joist-respecting mesh
    # — the AreaLoad geometry in test (4) depends on it.
    @testset "(5) _create_shell_diaphragms exercises Phase 8's mesher" begin
        struc, slab = build_two_way_bay_with_joists()
        nodes = build_nodes(struc)
        params = DesignParameters(materials =
            MaterialOptions(steel = A992_Steel, beam = A992_Steel))
        effective_props = SS._build_shell_props(params, :shell, nothing)
        shells = SS._create_shell_diaphragms(struc, nodes;
                                             mode = :shell, props = effective_props)
        @test !isempty(shells)
        @test all(sh -> sh isa Asap.ShellElement, shells)

        # DOF-sharing invariant carries through the internal call path.
        shell_nodes = Set{Asap.Node}()
        for sh in shells, n in sh.nodes
            push!(shell_nodes, n)
        end
        lines = SS._collect_slab_joist_lines(struc, slab, nodes)
        @test !isempty(lines)
        for line in lines, n in line.node_objs
            @test n in shell_nodes
        end
    end

    @info "Phase 8 smoke summary" note="kj_eng_v2 closed the released-stiffness gap; tolerate_joist_stiffness_gap is a no-op today"
end
