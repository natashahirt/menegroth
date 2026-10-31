
"""
    build_design_graph(struc::BuildingStructure, params::DesignParameters; tc=nothing)
        -> DesignGraph

Build the design pipeline as a [`DesignGraph`](@ref) of [`StageNode`](@ref)s.

**Fine per-slab topology (Run 3).** The coarse `:slab_sizing` stage is decomposed
into one node PER slab index — `slab_node_key(idx)` = `:slab_sizing_s{idx}`, each
running `size_slab!(struc, idx)` + that slab's volume update. The nodes are emitted
as ROOTS (no inter-slab edges) in ASCENDING `slab_idx` order, so
[`topological_levels`](@ref) places them ALL in ONE level listed in insertion
(== `eachindex`) order, and both [`execute_graph!`](@ref) and the incremental
scheduler ([`run_target!`](@ref)) process them SEQUENTIALLY in that order. The
level barrier then flushes `sync_asap!` exactly ONCE after the whole slab level.

This is byte-identical to the single-threaded coarse `size_slabs!` reference
(`StructuralSizer/src/slabs/sizing.jl` §`size_slabs!`, which iterates
`eachindex(struc.slabs)` when `Threads.nthreads() == 1`) because (a) the fine
nodes are processed in the SAME `eachindex` order — the decisive property, since
flat-plate slab sizing reads LIVE shared supporting-column `c1`/`c2` (DDM clear
span `ln = l1 - c1`, punching perimeter, deflection) and columns grow
MONOTONICALLY across slabs, so per-slab output is ORDER-DEPENDENT (an earlier
batch-coloring order broke this — Finding 1 P0); (b) the single post-level
`sync_asap!` matches the coarse pipeline's single post-slab-stage sync
(`size_slabs!` performs NO inter-slab sync — slab sizing never reads solved
`el.forces`, so there is no intermediate sync to reproduce and the barrier fires
once after the last slab node); (c) `_col_cache` is a pure, read-only memoization
after `precompute_capacities!` — recomputing per slab (passing `nothing`) yields
identical P-M capacities (see Finding 5 note in `slabs/sizing.jl`). The exact-first
gate (`verify_design_graph.jl`) verifies this end-to-end.

ENGINEERING JUDGMENT / KNOWN ISSUE — this PINS `design_building`'s slab order to
`eachindex` for determinism regardless of thread count, deliberately trading away
intra-run slab parallelism (`struc.slab_parallel_batches` no longer shapes the
graph). The pre-existing coarse thread-count non-determinism (single-thread
`eachindex` vs multithread batch order inside `size_slabs!`) is a SEPARATE known
issue not addressed here. The recommended proper future fix is an order-INDEPENDENT
two-pass (pre-grow all shared columns to their final size, then size every slab
against the final columns — deterministic AND parallelizable); it is NOT
implemented now (see NOTES). This is not a code requirement — it is a
byte-identity-preserving scope decision under `code-accuracy.mdc`.

**Coarse global nodes (unchanged placement/sync).** Member sizing stays a single
`:members` node (flat-plate `_reconcile_columns!` OR the ITERATIVE, beam↔column
COUPLED `_size_beams_columns!` loop — see the deferral note below), depending on
every per-slab node; foundations stays a single `:foundations` node after
`:members`. `_reconcile_columns!` / `harmonize_uniform_column_sizes!` / foundations
keep their exact current placement so `design_building` stays byte-identical.

Each node carries the provenance from `PIPELINE_PROVENANCE` (per-slab nodes inherit
`NODE_SLAB_SIZING`'s record via [`pipeline_provenance`](@ref)). `struc` is read for
its (fixed, prepare-time) slab count only (slab nodes are ordered by `eachindex`,
NOT by `slab_parallel_batches` — see the per-slab topology note above); the
member/foundation closures still come from [`build_pipeline`](@ref) so the graph
and the legacy stage loop stay in lock-step.

ENGINEERING JUDGMENT — columns stay coarse. `size_columns!` is a single global MIP
with no per-group API; splitting it would change the optimization semantics. And
`size_beams!` is batched across all groups while `size_member_group!` sizes one
steel group via a different solver path — plus for beam-based floors beams and
columns are sized in an ITERATIVE CONVERGENCE loop (`_size_beams_columns!`) whose
coupling cannot be reproduced by independent per-group nodes without breaking
byte-identity. Per-beam-group / per-column-group splitting is therefore DEFERRED to
a follow-up run (see NOTES). This is not a code requirement — it is a
byte-identity-preserving scope decision under `code-accuracy.mdc`.
"""
function build_design_graph(struc::BuildingStructure, params::DesignParameters;
                            tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing)
    stages = build_pipeline(params; tc=tc)

    has_foundations = !isnothing(params.foundation_options)
    has_ordinary_walls = params.lateral !== nothing
    expected_stages = 2 + (has_foundations ? 1 : 0) + (has_ordinary_walls ? 1 : 0)
    length(stages) == expected_stages || error(
        "build_design_graph: stage count mismatch " *
        "($(length(stages)) stages vs $expected_stages expected)")

    slab_stage   = stages[1]
    member_stage = stages[2]
    stage_i = 3
    fdn_stage = nothing
    if has_foundations
        fdn_stage = stages[stage_i]
        stage_i += 1
    end
    wall_stage = has_ordinary_walls ? stages[stage_i] : nothing

    graph_nodes = DesignNode[]
    slab_prov   = pipeline_provenance(NODE_SLAB_SIZING)

    # ── Fine per-slab nodes, emitted as ROOTS in ONE topological level ───────
    # (all slab nodes are edgeless roots ordered by `eachindex`, so
    # `topological_levels` places them in a SINGLE level with ONE barrier sync —
    # NOT one level per `slab_parallel_batches` batch; see the topology note above)
    n_slabs = length(struc.slabs)
    slab_keys_all = NodeKey[]
    if n_slabs == 0
        # No slabs: keep the coarse `:slab_sizing` node (its stage closure is a
        # no-op loop) so `:members` still has a stable slab-stage dependency and
        # the semantic identity is preserved.
        push!(graph_nodes, StageNode(NODE_SLAB_SIZING, NodeKey[], slab_stage.fn,
                                     slab_stage.needs_sync, slab_prov.param_slice,
                                     slab_prov.reads, slab_prov.writes,
                                     slab_prov.code_version))
        push!(slab_keys_all, NODE_SLAB_SIZING)
    else
        floor_opts      = resolve_floor_options(params)
        column_opts     = _get_column_opts(params)
        slab_floor_type = _infer_floor_type(floor_opts)
        # A scoped override stores that slab's own options. The building-wide
        # options stay the fallback, and the trace envelope still reports them.
        slab_opts = [
            _floor_options_for_slab(struc, sidx, params, floor_opts)
            for sidx in 1:n_slabs
        ]
        # One read-only P-M cache for every slab node. `_precompute` returns
        # nothing for NLP and for non-concrete columns, which is the same
        # cache the coarse `size_slabs!` would share. FINDING 5: the cache is
        # not written after `precompute_capacities!`. A leading vault must not
        # be the cache source: only a flat plate or flat slab has a column diagram.
        cache_idx = findfirst(
            i -> struc.slabs[i].floor_type in (:flat_plate, :flat_slab),
            1:n_slabs,
        )
        shared_col_cache = if cache_idx === nothing
            nothing
        else
            cache_request = floor_design_request(
                struc,
                cache_idx;
                options = slab_opts[cache_idx],
                column_options = column_opts,
                max_iterations = params.max_iterations,
                fire_rating = params.fire_rating,
            )
            StructuralSizer.prepare_floor_design_workspace(cache_request).column_cache
        end

        # ── EXACT-FIRST slab ordering (Finding 1, P0) ──────────────────────────
        # Emit the fine per-slab nodes as ROOTS (no inter-slab edges) in ascending
        # `slab_idx` order. `topological_levels` groups them into ONE level in
        # insertion (== `eachindex`) order, and both the direct executor and the
        # incremental scheduler process a level SEQUENTIALLY in that order — so the
        # fine path reproduces the single-threaded coarse `size_slabs!` reference
        # (`StructuralSizer/src/slabs/sizing.jl` §size_slabs!, `eachindex` branch).
        # Slab sizing reads LIVE shared column c1/c2 and columns grow monotonically,
        # so this order is the byte-identity invariant; `slab_parallel_batches`
        # (the earlier coloring order) is deliberately NOT used to shape the graph.
        # The single post-level `sync_asap!` (all nodes carry the stage's
        # `needs_sync`) matches the coarse pipeline's single post-slab-stage sync;
        # slab sizing performs no inter-slab sync (it never reads solved
        # `el.forces`), so there is no intermediate sync to reproduce.
        for sidx in 1:n_slabs
            key      = slab_node_key(sidx)
            this_opts   = slab_opts[sidx]
            base_fn     = _make_slab_node_fn(sidx, this_opts, column_opts, params, tc,
                                             shared_col_cache)
            base_fn_ctx = _make_slab_node_fn_ctx(sidx, this_opts, column_opts, params, tc,
                                                 shared_col_cache)
            is_first = sidx == 1
            is_last  = sidx == n_slabs
            # Finding 2: reproduce the legacy `stage_1_slabs` + `size_slabs!` trace
            # envelope around the per-slab `size_slab!` events (which `base_fn`
            # emits nested) so a traced `design_building` is byte-identical to the
            # pre-Run-3 sequence. The envelope is emitted at the slab-level
            # boundary: open on the first node, close on the last. `_emit_envelope`
            # keeps the cold (`fn`) and warm (`fn_ctx`) variants trace-identical.
            _emit_slab_envelope_open(struc) = begin
                if is_first
                    StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_1_slabs", :enter;
                                          floor_type=string(slab_floor_type))
                    StructuralSizer.emit!(tc, :slab, "size_slabs!", "", :enter;
                                          n_slabs=length(struc.slabs),
                                          options_type=string(typeof(floor_opts)),
                                          has_column_opts=!isnothing(column_opts),
                                          max_iterations=params.max_iterations)
                    # Fine graph pins slab processing to `eachindex` order regardless
                    # of thread count (Finding 1), so the coarse single-threaded
                    # `parallel=false` decision is the invariant reference event.
                    StructuralSizer.emit!(tc, :slab, "size_slabs!", "", :decision; parallel=false)
                end
            end
            _emit_slab_envelope_close() = begin
                if is_last
                    StructuralSizer.emit!(tc, :slab, "size_slabs!", "", :exit)
                    StructuralSizer.emit!(tc, :pipeline, "build_pipeline", "stage_1_slabs", :exit)
                end
            end
            fn = function (struc)
                _emit_slab_envelope_open(struc)
                base_fn(struc)
                _emit_slab_envelope_close()
                return nothing
            end
            # Warm variant: identical trace envelope + `_update_one_slab_volume!`,
            # only the internal `_col_cache` is reused from `ctx` (result-neutral).
            fn_ctx = function (struc, ctx)
                _emit_slab_envelope_open(struc)
                base_fn_ctx(struc, ctx)
                _emit_slab_envelope_close()
                return nothing
            end
            push!(graph_nodes, StageNode(key, NodeKey[], fn,
                                         slab_stage.needs_sync, slab_prov.param_slice,
                                         slab_prov.reads, slab_prov.writes,
                                         slab_prov.code_version, fn_ctx))
            push!(slab_keys_all, key)
        end
    end

    # ── Coarse member node depends on ALL slab nodes ────────────────────────
    mem_prov = pipeline_provenance(NODE_MEMBERS)
    push!(graph_nodes, StageNode(NODE_MEMBERS, copy(slab_keys_all), member_stage.fn,
                                 member_stage.needs_sync, mem_prov.param_slice,
                                 mem_prov.reads, mem_prov.writes, mem_prov.code_version))

    # ── Coarse foundation node after members (when requested) ───────────────
    if has_foundations
        fdn_prov = pipeline_provenance(NODE_FOUNDATIONS)
        push!(graph_nodes, StageNode(NODE_FOUNDATIONS, NodeKey[NODE_MEMBERS], fdn_stage.fn,
                                     fdn_stage.needs_sync, fdn_prov.param_slice,
                                     fdn_prov.reads, fdn_prov.writes, fdn_prov.code_version))
    end

    # Ordinary walls after foundations when those were requested, otherwise
    # after members. Checks do not change stiffness (`needs_sync` is false).
    if has_ordinary_walls
        wall_prov = pipeline_provenance(NODE_ORDINARY_WALLS)
        upstream = has_foundations ? NODE_FOUNDATIONS : NODE_MEMBERS
        push!(graph_nodes, StageNode(NODE_ORDINARY_WALLS, NodeKey[upstream], wall_stage.fn,
                                     wall_stage.needs_sync, wall_prov.param_slice,
                                     wall_prov.reads, wall_prov.writes, wall_prov.code_version))
    end

    return DesignGraph(graph_nodes)
end

"""
    _floor_options_for_slab(struc, slab_idx, params, global_opts) -> AbstractFloorOptions

Options for one slab. A slab whose floor type matches the building-wide
options uses those options. A scoped override that covers the slab's cells
supplies its own options, with the same concrete and column-cracking factor
the initializer applies. The last matching override wins.
"""
function _floor_options_for_slab(
    struc::BuildingStructure,
    slab_idx::Int,
    params::DesignParameters,
    global_opts::StructuralSizer.AbstractFloorOptions,
)
    slab = struc.slabs[slab_idx]
    StructuralSizer.floor_symbol(global_opts) == slab.floor_type && return global_opts
    chosen = nothing
    for ov in params.scoped_floor_overrides
        ov.floor_type == slab.floor_type || continue
        isdisjoint(_match_override_cells(struc, ov), slab.cell_indices) && continue
        opts = _scoped_override_floor_opts(ov)
        opts === nothing && continue
        concrete = something(ov.concrete, resolve_concrete(params))
        chosen = _apply_col_I_factor(
            _with_concrete_material(opts, concrete),
            params.column_I_factor,
        )
    end
    chosen === nothing && throw(ArgumentError(
        "slab $slab_idx is a $(slab.floor_type) floor, which $(typeof(global_opts)) " *
        "does not describe, and no scoped override covers its cells"))
    return chosen
end

"""
    _make_slab_node_fn(slab_idx, floor_opts, column_opts, params, tc, col_cache=nothing) -> Function

Closure for a fine per-slab [`StageNode`](@ref): size exactly `slab_idx` and update
its volume. Byte-identical to the coarse `size_slabs!` per-slab body — same
`size_slab!` arguments (`max_iterations`, `fire_rating`, `column_opts`) and the
same shared `_col_cache` — followed by [`_update_one_slab_volume!`](@ref) (the
per-slab body of `update_slab_volumes!`).

FINDING 5 — `_col_cache` purity. The coarse `size_slabs!` builds ONE
`_col_cache` (an `ACIColumnCapacityCache`) and shares it across every slab.
The fine nodes close over that same object (`shared_col_cache`), which is
`nothing` for NLP and for non-concrete columns. This is result-neutral because
the cache is READ-ONLY after `precompute_capacities!`: its mutable fields
(`diagrams`, `diagrams_y`, `depths`, `is_square`, `obj_coeffs`, `fc_ksi`, …) are
written ONLY in `precompute_capacities!` / `_precompute_diagrams!`
(`StructuralSizer/src/members/codes/aci/columns/checker.jl`), and the discrete
MIP consumes a PROVIDED cache exclusively through read accessors —
`is_feasible`, `check_capacity`, `get_objective_coeff`, `explain_feasibility`
(`StructuralSizer/src/optimize/solvers/discrete_mip.jl`; the sole write path is
its `cache === nothing` precompute branch). Sharing therefore yields the same
P-M capacities as rebuilding. `verify_design_graph.jl` is the exact-first check.
"""
function _make_slab_node_fn(slab_idx::Int, floor_opts, column_opts,
                            params::DesignParameters,
                            tc::Union{Nothing, StructuralSizer.TraceCollector},
                            col_cache = nothing)
    return function (struc)
        request = floor_design_request(
            struc,
            slab_idx;
            options = floor_opts,
            column_options = column_opts,
            max_iterations = params.max_iterations,
            fire_rating = params.fire_rating,
        )
        outcome = design_floor!(
            struc,
            request;
            verbose = false,
            workspace = StructuralSizer.FloorDesignWorkspace(col_cache),
            tc = tc,
        )
        _require_installable_floor(outcome, slab_idx)
        _update_one_slab_volume!(struc, slab_idx, floor_opts)
        return nothing
    end
end

"""
    _make_slab_node_fn_ctx(slab_idx, floor_opts, column_opts, params, tc, col_cache=nothing) -> Function

Warm-state (Run 6) counterpart to [`_make_slab_node_fn`](@ref): a `(struc, ctx)`
closure that passes the shared read-only column P-M cache from the warm context
([`warm_col_cache`](@ref)) as `_col_cache`. When the context carries no cache,
the cold graph cache is used. Both are read-only after `precompute_capacities!`
(FINDING 5).
"""
function _make_slab_node_fn_ctx(slab_idx::Int, floor_opts, column_opts,
                                params::DesignParameters,
                                tc::Union{Nothing, StructuralSizer.TraceCollector},
                                col_cache = nothing)
    return function (struc, ctx)
        warm = warm_col_cache(ctx)
        request = floor_design_request(
            struc,
            slab_idx;
            options = floor_opts,
            column_options = column_opts,
            max_iterations = params.max_iterations,
            fire_rating = params.fire_rating,
        )
        outcome = design_floor!(
            struc,
            request;
            verbose = false,
            workspace = StructuralSizer.FloorDesignWorkspace(
                warm === nothing ? col_cache : warm,
            ),
            tc = tc,
        )
        _require_installable_floor(outcome, slab_idx)
        _update_one_slab_volume!(struc, slab_idx, floor_opts)
        return nothing
    end
end

_accessory_stud_material(opts::StructuralSizer.FlatPlateOptions) = opts.stud_material
_accessory_stud_material(opts::StructuralSizer.FlatSlabOptions) = opts.base.stud_material
_accessory_stud_material(::StructuralSizer.AbstractFloorOptions) = StructuralSizer.Stud_51

"""Add `dv` onto the existing `mat` entry of a volume dict."""
function _bump_volume!(vols::MaterialVolumes, mat, dv)
    v = uconvert(u"m^3", dv)
    v > 0.0u"m^3" || return vols
    vols[mat] = get(vols, mat, 0.0u"m^3") + v
    return vols
end

function _concrete_volume_key(vols, fallback)
    for k in keys(vols)
        if k isa StructuralSizer.Concrete || k isa StructuralSizer.FiberReinforcedConcrete
            return k
        end
    end
    return fallback
end

"""
    _add_slab_accessory_volumes!(struc, slab, options)

Add drop-panel, shear-cap, and capital concrete, and shear-stud steel, to
`slab.volumes`. These are the same volume functions the summary used to add
beside the element volumes, so the takeoff and the carbon split see them.
Stud steel uses the floor options' stud material, not a generic density.
"""
function _add_slab_accessory_volumes!(struc, slab, options)
    concrete = _concrete_volume_key(slab.volumes, _primary_material(options))
    stud = _accessory_stud_material(options)
    r = slab.result
    if r isa StructuralSizer.FlatPlatePanelResult && hasproperty(r, :punching_check)
        pc = r.punching_check
        if hasproperty(pc, :details)
            for (col_idx, detail) in pc.details
                if hasproperty(detail, :studs) && !isnothing(detail.studs)
                    _bump_volume!(slab.volumes, stud, StructuralSizer.stud_steel_volume(detail.studs))
                end
                if hasproperty(detail, :shear_cap) && !isnothing(detail.shear_cap) &&
                        col_idx isa Integer && 1 <= col_idx <= length(struc.columns)
                    col = struc.columns[col_idx]
                    if !isnothing(col.c1) && !isnothing(col.c2)
                        _bump_volume!(slab.volumes, concrete, StructuralSizer.shear_cap_concrete_volume(
                            detail.shear_cap, col.c1, col.c2))
                    end
                end
                if hasproperty(detail, :capital) && !isnothing(detail.capital)
                    _bump_volume!(slab.volumes, concrete,
                        StructuralSizer.capital_concrete_volume(detail.capital))
                end
            end
        end
    end
    if !isnothing(slab.drop_panel)
        dp = slab.drop_panel
        slab_cells = Set(slab.cell_indices)
        bbox = _slab_bbox_m(struc, slab)
        for col in struc.columns
            isempty(intersect(col.tributary_cell_indices, slab_cells)) && continue
            v_idx = col.vertex_idx
            (v_idx < 1 || v_idx > length(struc.skeleton.vertices)) && continue
            c = Meshes.coords(struc.skeleton.vertices[v_idx])
            a1, a2 = _trimmed_drop_extents_m(dp, ustrip(u"m", c.x), ustrip(u"m", c.y), bbox)
            _bump_volume!(slab.volumes, concrete, StructuralSizer.drop_panel_concrete_volume(dp, a1, a2))
        end
    end
    return slab
end

"""Concrete, rebar, structural steel, and timber in one volume dict.

Rebar and structural steel use that material's density. A reinforced-concrete
lump with no separate rebar volume stays concrete: no reinforcement ratio is assumed.
"""
function _quantity_increments(vols)
    t = material_takeoff(vols)
    timber = 0.0u"m^3"
    for (mat, vol) in vols
        mat isa StructuralSizer.Timber || continue
        timber += uconvert(u"m^3", vol)
    end
    return (concrete = t.concrete_volume, rebar = t.rebar_mass,
            steel = t.structural_steel_mass, timber = timber)
end

"""
    _update_one_slab_volume!(struc, slab_idx, options; primary_material=nothing)

Recompute `struc.slabs[slab_idx].volumes` from its current result — the single-slab
body of [`update_slab_volumes!`](@ref) (same `_primary_material` / floor-area /
`_compute_slab_volumes` derivation), then add drop panels, shear caps, capitals,
and shear studs. No-op for a non-converged (`nothing`-result) slab.
"""
function _update_one_slab_volume!(struc::BuildingStructure, slab_idx::Int, options;
                                  primary_material=nothing)
    slab = struc.slabs[slab_idx]
    isnothing(slab.result) && return struc
    mat = isnothing(primary_material) ? _primary_material(options) : primary_material
    floor_area = sum(struc.cells[idx].area for idx in slab.cell_indices)
    slab.volumes = _compute_slab_volumes(slab.result, floor_area, mat, options)
    _add_slab_accessory_volumes!(struc, slab, options)
    return struc
end

"""
    _slab_supporting_columns(struc, slab_idx) -> Vector{Int}

The 1-based `struc.columns` indices whose tributary overlaps slab `slab_idx`'s
cells — the columns a per-slab node may grow. Mirrors the slab→column overlap in
[`compute_slab_parallel_batches!`](@ref); used by the scheduler's partial
per-slab restore ([`restore_slab_node_writes!`](@ref)) — a path now made
UNREACHABLE end-to-end by the partial-slab-target guard in `run_target!`
(scheduler.jl) and exercised only by direct unit tests.
"""
function _slab_supporting_columns(struc::BuildingStructure, slab_idx::Int)
    slab_cells = Set(struc.slabs[slab_idx].cell_indices)
    cols = Int[]
    for (c_idx, col) in enumerate(struc.columns)
        if !isempty(col.tributary_cell_indices) &&
           !isempty(intersect(col.tributary_cell_indices, slab_cells))
            push!(cols, c_idx)
        end
    end
    return cols
end

