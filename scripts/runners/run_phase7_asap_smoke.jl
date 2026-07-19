# Phase 7 smoke test — Asap leverage in the synthesizer (plan
# joists-roles-materials, Phase 7).
#
# Exercises the four Phase-7 sub-steps against a synthetic BuildingStructure:
#   (1) Element.eccentricity for joist-on-girder seat offsets — zero before
#       sizing, (0, 0, (host_d + joist_d)/2, 0) for the steel-joist-on-W-girder
#       case after sizing (via sync_asap!).
#   (2) load_routing dispatch — :shell_area emits Asap.AreaLoad when diaphragm
#       shells are present; :cell_tributary / no-shell emits TributaryLoad.
#   (3) compute_member_tributaries!(strategy=:shell_panels) guards on shell
#       presence and falls back to :cell_merge on the frame-only design model.
#   (4) sync_asap! parity — the release map (Phase 2) is honored and the seat
#       eccentricity is (re)populated from the now-known member depths.
#
# UPSTREAM ASAP GAP (documented, not fixed here — out of Phase 7 scope):
#   `Asap.local_K(::Element{R})` for every released type R (FixedFree, FreeFixed,
#   FreeFree, Joist) calls an UNDEFINED `k_*` helper (`k_joist`, `k_freefree`,
#   …) — see external/Asap/src/Elements/K.jl:293. Only the FixedFixed fast path
#   in `global_K!` avoids it. Therefore `Asap.process!`/`solve!` throw the moment
#   the model contains a `:joist`-release element (which every auto-generated
#   joist now is, via Phase 2/3). `to_asap!`/`sync_asap!` build the model
#   (`struc.asap_model` with elements + loads) BEFORE that `process!` call
#   (utils.jl:206 → 210), so this smoke inspects the fully-built pre-process
#   model and tolerates ONLY the specific `k_joist`/`k_*` UndefVarError. Wiring a
#   released-element stiffness belongs in Asap (Phase 8 / upstream), not here.
#
# Run:
#   SS_ENABLE_VISUALIZATION=false SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD=false \
#   julia --project=StructuralSynthesizer scripts/runners/run_phase7_asap_smoke.jl

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer
using Asap  # units + Element/AreaLoad

const SS = StructuralSynthesizer
const SZ = StructuralSizer

# Minimal Timber material (values irrelevant — only type/identity matters here;
# mirrors scripts/runners/run_phase5_populate_smoke.jl).
const SMOKE_TIMBER = Timber(:douglas_fir, :no1,
                            12.4e3u"MPa", 6.6e3u"MPa", 6.9u"MPa", 4.6u"MPa",
                            1.2u"MPa", 11.7u"MPa", 4.3u"MPa", 470.0u"kg/m^3", 0.31)

"""True iff `err` is the known upstream Asap released-element stiffness gap
(`k_joist` / `k_freefree` / … undefined in `Asap.local_K`). Anything else is a
real failure and is re-raised by the caller."""
function _is_asap_released_stiffness_gap(err)
    err isa UndefVarError || return false
    return err.var in (:k_joist, :k_freefree, :k_fixedfree, :k_freefixed, :k_fixedfixed)
end

"""Run `f()`; swallow ONLY the documented Asap released-element stiffness gap
(so the fully-built pre-`process!` model on `struc` remains inspectable), and
re-raise every other error."""
function tolerate_joist_stiffness_gap(f)
    try
        f()
    catch err
        _is_asap_released_stiffness_gap(err) || rethrow()
    end
    return nothing
end

"""Build one rectangular single-story bay at x-origin `x0`; return its four CCW
floor-vertex indices. All four boundary beams join `:beams`; corners are marked
as supports so the model is well-founded."""
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

"""Skeleton face index whose vertex set equals `corners`."""
function face_for_corners(skel, corners)
    want = Set(corners)
    idx = findfirst(vs -> Set(vs) == want, skel.face_vertex_indices)
    idx === nothing && error("no face found for corners $corners")
    return idx
end

@testset "Phase 7 — Asap leverage in synthesizer" begin
    # ── Geometry: two disjoint bays on one story ───────────────────────────
    skel = BuildingSkeleton{Float64}()
    corners_2w  = build_bay!(skel; x0 = 0.0)    # :two_way            → steel joists
    corners_mtj = build_bay!(skel; x0 = 12.0)   # :mass_timber_joist  → timber joists

    rebuild_stories!(skel)
    find_faces!(skel)
    rebuild_geometry_cache!(skel)

    struc = BuildingStructure(skel)

    A  = 48.0u"m^2"
    dl = 2.0u"kN/m^2"
    ll = 3.0u"kN/m^2"

    spans_2w  = SpanInfo{Float64}(8.0, 6.0, (1.0, 0.0), 7.0)
    spans_mtj = SpanInfo{Float64}(8.0, 6.0, (1.0, 0.0), 7.0)

    # self_weight must be a unitful pressure — it is pushed into the unitful
    # `Cell.self_weight` field by sync_asap! (length fields stay bare, as in the
    # Phase 5 smoke, since populate_levels! reads them as plain numbers).
    cip_2w     = CIPSlabResult(0.2, 0.2, 5.0u"kPa")
    mtj_result = TimberJoistResult("GLT 175x400", 0.4, ustrip(u"m", 600.0u"mm"),
                                   "CLT panel", 0.44, 0.05, 1.2u"kPa")

    function push_bay_slab!(corners, result, floor_type, spans)
        fidx = face_for_corners(skel, corners)
        cell = Cell(fidx, A, spans, dl, ll)
        cell.floor_type = floor_type
        push!(struc.cells, cell)
        cidx = length(struc.cells)
        slab = Slab{Float64}([cidx], result, floor_type, spans, :interior,
                             nothing, MaterialVolumes(), nothing, nothing,
                             FramingLevel{Float64}[])
        push!(struc.slabs, slab)
        return slab
    end

    slab_2w  = push_bay_slab!(corners_2w,  cip_2w,     :two_way,           spans_2w)
    slab_mtj = push_bay_slab!(corners_mtj, mtj_result, :mass_timber_joist, spans_mtj)

    # ── Host members (level-0 girders): one Segment + Beam per boundary edge.
    for e in sort(collect(skel.groups_edges[:beams]))
        L = ustrip(u"m", skel.geometry.edge_lengths[e])
        push!(struc.segments, Segment(e, L))
        seg_idx = length(struc.segments)
        push!(struc.beams, Beam([seg_idx], L; role = :girder, level = 0))
    end

    # ── Auto-generate joists (steel on the two-way bay, timber on the mtj bay).
    opts = (materials = (steel = A992_Steel, timber = SMOKE_TIMBER, concrete = NWC_4000),
            spacing = 2.0)
    populate_levels!(struc; opts = opts)

    steel_joists = [b for b in struc.beams
                    if SS.is_joist(b) && haskey(SS.volumes(b), A992_Steel)]
    timber_joists = [b for b in struc.beams
                     if SS.is_joist(b) && haskey(SS.volumes(b), SMOKE_TIMBER)]

    @testset "(b) joists generated" begin
        @test !isempty(steel_joists)
        @test !isempty(timber_joists)
    end

    params = DesignParameters(materials = MaterialOptions(steel = A992_Steel,
                                                          beam = A992_Steel))

    """First skeleton edge index owned by `beam`."""
    beam_edge(beam) = struc.segments[first(SS.segment_indices(beam))].edge_idx
    """Asap element for `beam`'s (single-segment) edge."""
    beam_element(beam) = struc.asap_model.elements[beam_edge(beam)]

    # ── (1)/(c) Phase-2 release map + pre-sizing eccentricity map ──────────
    @testset "(1) release map: steel joist ends → Asap :joist enum" begin
        rel_map = SS._build_edge_release_map(struc, A992_Steel)
        for jb in steel_joists
            @test get(rel_map, beam_edge(jb), :fixedfixed) === :joist
        end
    end

    @testset "(1) eccentricity map is zero before sizing" begin
        # Depths unknown (no section) ⇒ default_seat_eccentricity returns 0, so no
        # joist edge is tagged. This is the exact tuple `to_asap!` passes to
        # `Asap.Element(...; eccentricity=)` on the first (pre-sizing) pass.
        ecc_pre = SS._build_edge_eccentricity_map(struc, params)
        @test isempty(ecc_pre)
    end

    # ── (c) to_asap! before sizing: element carries the :joist release and a
    # zero seat offset (inspected on the pre-process model). ────────────────
    tolerate_joist_stiffness_gap(() -> to_asap!(struc; params = params))

    @testset "(c) initial to_asap!: :joist release + zero pre-sizing eccentricity" begin
        @test struc.asap_model !== nothing
        for jb in steel_joists
            el = beam_element(jb)
            @test SS._get_release_symbol(el) === :joist
            @test all(iszero, el.eccentricity)
        end
    end

    # ── Simulate a sizing pass: assign concrete sections. ──────────────────
    girder_sec = SZ.W("W16X40")
    joist_sec  = SZ.W("W12X26")
    host_d_m   = ustrip(u"m", SZ.section_depth(girder_sec))
    joist_d_m  = ustrip(u"m", SZ.section_depth(joist_sec))
    expected_ez = (host_d_m + joist_d_m) / 2

    for b in struc.beams
        if SS.level_of(b) == 0
            SS.set_section!(b, girder_sec)                 # host girders
        elseif b in steel_joists
            SS.set_section!(b, joist_sec)                  # steel joists
        end
    end

    # ── (4) eccentricity map AFTER sizing reflects the seat offset ─────────
    @testset "(4) post-sizing eccentricity map: steel-joist-on-W-girder seat" begin
        ecc_post = SS._build_edge_eccentricity_map(struc, params)
        for jb in steel_joists
            e = beam_edge(jb)
            @test haskey(ecc_post, e)
            tup = ecc_post[e]
            @test tup[1] == 0.0
            @test tup[2] == 0.0
            @test isapprox(tup[3], expected_ez; atol = 1e-9)
            @test tup[4] == 0.0
        end
        # Timber joists keep a zero seat offset (Phase-3 timber dispatch) ⇒ absent.
        for tj in timber_joists
            @test !haskey(ecc_post, beam_edge(tj))
        end
    end

    # ── (4)/(d) sync_asap!: mutates Element.eccentricity in place before the
    # (tolerated) reprocess; release map still honored. ─────────────────────
    tolerate_joist_stiffness_gap(() -> sync_asap!(struc; params = params))

    @testset "(d) sync_asap!: element eccentricity now carries the seat offset" begin
        for jb in steel_joists
            ecc = beam_element(jb).eccentricity
            @test ecc[1] == 0.0
            @test ecc[2] == 0.0
            @test isapprox(ecc[3], expected_ez; atol = 1e-9)
            @test ecc[4] == 0.0
        end
        for tj in timber_joists
            @test all(iszero, beam_element(tj).eccentricity)
        end
        for jb in steel_joists
            @test SS._get_release_symbol(beam_element(jb)) === :joist
        end
    end

    # ── (2) load-routing dispatch ──────────────────────────────────────────
    @testset "(2) _resolve_load_routing: shell-presence dispatch" begin
        dummy_shell = [1]                       # only emptiness is inspected
        @test SS._resolve_load_routing(:auto, Int[]) === :cell_tributary
        @test SS._resolve_load_routing(:auto, dummy_shell) === :shell_area
        @test SS._resolve_load_routing(:cell_tributary, dummy_shell) === :cell_tributary
        # :shell_area with no shells warns and falls back.
        @test SS._resolve_load_routing(:shell_area, Int[]) === :cell_tributary
        @test SS._resolve_load_routing(:shell_area, dummy_shell) === :shell_area
    end

    @testset "(2) emitted load types: cell tributary (no shells)" begin
        # No shells (diaphragms=:none) ⇒ :auto uses per-cell TributaryLoads.
        tolerate_joist_stiffness_gap(() ->
            to_asap!(struc; params = params, diaphragms = :none, load_routing = :auto))
        loads_cell = struc.asap_model.loads
        @test !any(ld -> ld isa Asap.AreaLoad, loads_cell)
        @test any(ld -> ld isa Asap.TributaryLoad, loads_cell)
    end

    @testset "(2) emitted load types: shell AreaLoad vs cell tributary" begin
        # Shell diaphragms require unitful slab thickness (ShellSection). Use a
        # dedicated CIP two-way bay whose length fields are unitful; joists are
        # still derived from opts.spacing (not the result), so populate is happy.
        shell_struc = let
            sk = BuildingSkeleton{Float64}()
            cs = build_bay!(sk; x0 = 0.0)
            rebuild_stories!(sk); find_faces!(sk); rebuild_geometry_cache!(sk)
            st = BuildingStructure(sk)
            cell = Cell(face_for_corners(sk, cs), A, spans_2w, dl, ll)
            cell.floor_type = :two_way
            push!(st.cells, cell)
            push!(st.slabs, Slab{Float64}([1],
                CIPSlabResult(0.2u"m", 0.2u"m", 5.0u"kPa"),
                :two_way, spans_2w, :interior, nothing, MaterialVolumes(),
                nothing, nothing, FramingLevel{Float64}[]))
            for e in sort(collect(sk.groups_edges[:beams]))
                L = ustrip(u"m", sk.geometry.edge_lengths[e])
                push!(st.segments, Segment(e, L))
                push!(st.beams, Beam([length(st.segments)], L; role = :girder, level = 0))
            end
            populate_levels!(st; opts = opts)
            st
        end

        # Shells present + :shell_area ⇒ Asap.AreaLoad is emitted.
        tolerate_joist_stiffness_gap(() ->
            to_asap!(shell_struc; params = params, diaphragms = :shell, load_routing = :shell_area))
        @test any(ld -> ld isa Asap.AreaLoad, shell_struc.asap_model.loads)

        # Explicit :cell_tributary always uses the per-cell path even with shells.
        tolerate_joist_stiffness_gap(() ->
            to_asap!(shell_struc; params = params, diaphragms = :shell, load_routing = :cell_tributary))
        @test !any(ld -> ld isa Asap.AreaLoad, shell_struc.asap_model.loads)
    end

    # ── (5) mixed-role framing level: interior_beams filters to :joist ─────
    # Phase 7 v2 regression: a FramingLevel may legally carry role=:beam members
    # (secondary girders / transfer beams). Those carry moment and must NOT be
    # idealized as pinned-end one-way joist strips by
    # Asap.AreaLoad(...; interior_beams=...). Build a level that mixes the
    # auto-generated :joist members with an injected :beam member, then assert the
    # emitted AreaLoad's interior_beams contains ONLY :joist members (the :beam is
    # still handed to distribute_to — it is not dropped from the model).
    @testset "(5) mixed-role framing level: interior_beams are :joist only" begin
        mixed_struc = let
            sk = BuildingSkeleton{Float64}()
            cs = build_bay!(sk; x0 = 0.0)
            rebuild_stories!(sk); find_faces!(sk); rebuild_geometry_cache!(sk)
            st = BuildingStructure(sk)
            cell = Cell(face_for_corners(sk, cs), A, spans_2w, dl, ll)
            cell.floor_type = :two_way
            push!(st.cells, cell)
            push!(st.slabs, Slab{Float64}([1],
                CIPSlabResult(0.2u"m", 0.2u"m", 5.0u"kPa"),
                :two_way, spans_2w, :interior, nothing, MaterialVolumes(),
                nothing, nothing, FramingLevel{Float64}[]))
            for e in sort(collect(sk.groups_edges[:beams]))
                L = ustrip(u"m", sk.geometry.edge_lengths[e])
                push!(st.segments, Segment(e, L))
                push!(st.beams, Beam([length(st.segments)], L; role = :girder, level = 0))
            end
            populate_levels!(st; opts = opts)
            st
        end

        # Inject a role=:beam member into the (level-1) framing group. Reuse a
        # boundary/girder edge as the secondary-girder geometry — the assertion
        # only needs a framing-level member whose role is :beam and whose edge
        # maps to a real frame element (so it WOULD land in interior_beams were
        # the role filter absent).
        sk = mixed_struc.skeleton
        fl1 = first(mixed_struc.slabs[1].framing_levels)
        grp = mixed_struc.member_groups[fl1.group_id]
        inj_edge = first(sort(collect(sk.groups_edges[:beams])))
        L_inj = ustrip(u"m", sk.geometry.edge_lengths[inj_edge])
        push!(mixed_struc.segments, Segment(inj_edge, L_inj))
        push!(mixed_struc.beams, Beam([length(mixed_struc.segments)], L_inj;
                                      role = :beam, level = 1))
        push!(grp.member_indices, length(mixed_struc.beams))

        # All framing-level members (mirrors the _create_shell_area_loads!
        # framing-level → member-group → beam traversal).
        function framing_level_members(struc)
            out = eltype(struc.beams)[]
            for slab in struc.slabs, fl in slab.framing_levels
                fl.group_id === nothing && continue
                g = get(struc.member_groups, fl.group_id, nothing)
                g === nothing && continue
                for mi in g.member_indices
                    (1 <= mi <= length(struc.beams)) || continue
                    push!(out, struc.beams[mi])
                end
            end
            return out
        end

        fl_members = framing_level_members(mixed_struc)
        @test any(b -> b.role === :beam, fl_members)      # fixture really is mixed-role
        @test any(b -> b.role === :joist, fl_members)

        tolerate_joist_stiffness_gap(() ->
            to_asap!(mixed_struc; params = params, diaphragms = :shell,
                     load_routing = :shell_area))

        model = mixed_struc.asap_model
        area_loads = Asap.AreaLoad[ld for ld in model.loads if ld isa Asap.AreaLoad]
        @test length(area_loads) == 1
        al = first(area_loads)

        # Position in model.elements == skeleton edge index (frame_elements are
        # built one-per-edge, in edge order, and Model stores that same vector).
        elem_edge = IdDict{Any, Int}()
        for (e, el) in enumerate(model.elements)
            elem_edge[el] = e
        end
        edge_role = Dict{Int, Symbol}()
        for b in fl_members, si in SS.segment_indices(b)
            edge_role[mixed_struc.segments[si].edge_idx] = b.role
        end

        # Every interior_beam maps back to a role=:joist framing member.
        @test !isempty(al.interior_beams)
        @test all(el -> get(edge_role, elem_edge[el], :missing) === :joist,
                  al.interior_beams)
        # The injected :beam edge is a framing member but is excluded from strips.
        @test get(edge_role, inj_edge, :missing) === :beam
        @test !any(el -> elem_edge[el] == inj_edge, al.interior_beams)
        # Filter dropped at least one framing-level member from interior_beams.
        @test length(al.interior_beams) < length(fl_members)
        # p7_rev_v2 gap: assert the excluded :beam edge still participates in
        # distribute_to as a moment-carrying support (Phase 7 v2 filter is
        # applied ONLY to interior_beams — distribute_to must retain every
        # framing member, boundary + role=:beam + role=:joist).
        @test any(el -> elem_edge[el] == inj_edge, al.distribute_to)

        # p7_rev_v2 gap: exercise the mixed fixture through sync_asap! to lock
        # the Phase 7 "rebuild parity" contract. `_sync_shell_area_pressures!`
        # currently only refreshes `al.pressure`, so the role filter on
        # interior_beams / distribute_to must survive a sync unchanged. If a
        # future sync_asap! rebuild path is added, this assertion will catch
        # regressions there.
        tolerate_joist_stiffness_gap(() -> sync_asap!(mixed_struc; params = params))
        model_synced = mixed_struc.asap_model
        area_loads_synced = Asap.AreaLoad[ld for ld in model_synced.loads if ld isa Asap.AreaLoad]
        @test length(area_loads_synced) == 1
        al_synced = first(area_loads_synced)
        elem_edge_synced = IdDict{Any, Int}()
        for (e, el) in enumerate(model_synced.elements)
            elem_edge_synced[el] = e
        end
        @test all(el -> get(edge_role, elem_edge_synced[el], :missing) === :joist,
                  al_synced.interior_beams)
        @test !any(el -> elem_edge_synced[el] == inj_edge, al_synced.interior_beams)
        @test any(el -> elem_edge_synced[el] == inj_edge, al_synced.distribute_to)
    end

    # ── (3) :shell_panels strategy guards + falls back on frame-only model ─
    @testset "(3) compute_member_tributaries!(:shell_panels) fallback" begin
        tolerate_joist_stiffness_gap(() -> to_asap!(struc; params = params, diaphragms = :none))
        # Frame-only design model has no shells ⇒ graceful fallback to :cell_merge.
        result = compute_member_tributaries!(struc; strategy = :shell_panels)
        @test result === struc
    end

    @info "Phase 7 smoke summary" n_beams=length(struc.beams) n_steel_joists=length(steel_joists) n_timber_joists=length(timber_joists) expected_ez=expected_ez
end
