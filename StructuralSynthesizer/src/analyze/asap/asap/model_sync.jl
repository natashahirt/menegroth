
"""
    _stiffness_token(struc, params) -> UInt

Bit-stable fingerprint of everything [`sync_asap!`](@ref) would otherwise rebuild
into the global stiffness: frame-section properties that enter `K` (A, E, G, Ix,
Iy, J, Ay, Az), element release type, end coordinates, current eccentricity, shell
thickness/E/ν and, for `ShellTri3`, the shear correction `κ`, shear stabilization
`shear_stab`, and drilling stabilization `drilling_scale` (each enters the element
stiffness), **and shell node positions** (in each shell's own node order), and
the joist-seat eccentricity map the sync is about to write. Shell node positions
are included so that moving a wall in plan, or re-attaching its shells to
different nodes — which both change `K` for the `ShellTri3` wall mesh in
`model.shell_elements` — invalidate the `loads_only` cached-factor reuse in
[`_loads_only_sync`](@ref). Load magnitudes are intentionally absent — they
change `P`, not `K`. Shell density `ρ` is intentionally absent — it enters mass,
not `K`.
"""
function _stiffness_token(struc::BuildingStructure, params::DesignParameters)
    model = struc.asap_model
    isnothing(model) && return UInt(0)
    h = UInt(0)
    frames = hasproperty(model, :frame_elements) ? model.frame_elements : Asap.Element[]
    for el in frames
        s = el.section
        props = s isa Asap.Section ?
            (ustrip(u"m^2", s.A), ustrip(u"Pa", s.E), ustrip(u"Pa", s.G),
             ustrip(u"m^4", s.Ix), ustrip(u"m^4", s.Iy), ustrip(u"m^4", s.J),
             ustrip(u"m^2", s.Ay), ustrip(u"m^2", s.Az)) :
            repr(s)
        p1 = el.nodeStart.position
        p2 = el.nodeEnd.position
        h = hash((
            typeof(el), props, el.eccentricity,
            ustrip(u"m", p1[1]), ustrip(u"m", p1[2]), ustrip(u"m", p1[3]),
            ustrip(u"m", p2[1]), ustrip(u"m", p2[2]), ustrip(u"m", p2[3]),
        ), h)
    end
    if hasproperty(model, :shell_elements)
        for sh in model.shell_elements
            # Shell stiffness properties that enter K. `ShellTri3` (the wall and
            # slab mesher output — `_mesh_wall_shells`, `to_asap!`) stores
            # thickness [m], E [Pa], ν, shear correction κ, shear stabilization
            # `shear_stab`, and drilling stabilization `drilling_scale` directly
            # as fields (it has no `.section` field). Density ρ enters mass, not
            # K, and is not hashed. For any other `ShellElement` subtype, fold
            # its concrete type so a type change is never missed.
            props = sh isa Asap.ShellTri3 ?
                (:shell, sh.thickness, sh.E, sh.ν,
                 sh.κ, sh.shear_stab, sh.drilling_scale) :
                (:shell, typeof(sh))
            h = hash(props, h)
            # Shell node positions (stripped to m) also enter K, so fold them in
            # the shell's OWN node order (that order defines its connectivity and
            # orientation — do not sort): moving a wall in plan, or reattaching
            # its shells to different nodes, changes K and must invalidate the
            # loads_only cached-factor reuse in `_loads_only_sync`.
            for n in sh.nodes
                p = n.position
                h = hash((ustrip(u"m", p[1]), ustrip(u"m", p[2]),
                          ustrip(u"m", p[3])), h)
            end
        end
    end
    eccs = sort!(collect(pairs(_build_edge_eccentricity_map(struc, params))))
    return hash(eccs, h)
end

"""
    _loads_only_sync(struc, params, token_before) -> Bool

True when a post-level [`sync_asap!`](@ref) may pass `loads_only=true`: the
stiffness token is unchanged across the level, so `K` was not touched and the
cached CHOLMOD factor (or a fresh factorization of the same `S`) is valid.

`SS_SYNC_LOADS_ONLY=off` forces the full refactorizing update. Any other value,
including an unset variable, selects this predicate. A changed section, node
coordinate, release, shell thickness, or joist eccentricity yields `false`.
"""
function _loads_only_sync(struc::BuildingStructure, params::DesignParameters, token_before)
    get(ENV, "SS_SYNC_LOADS_ONLY", "auto") == "off" && return false
    return _stiffness_token(struc, params) == token_before
end

"""
    sync_asap!(struc; params=DesignParameters())

Lightweight sync of the Asap model between pipeline stages.

Updates cell self-weights from current slab results, recomputes tributary load
pressures, refreshes the vault-thrust edge line-load magnitudes from the current
`governing_combo(params)`, and re-solves. Does **not** rebuild topology — only
loads change.

When `params.pattern_loading != :none`, performs multi-case solve with
checkerboard live load patterns and writes enveloped element forces back to the
model so downstream consumers (`_column_asap_Pu`, beam sizers, etc.) see the
governing demands.

# Factorization-aware reuse (`loads_only`)
`loads_only=false` (default) reproduces the exact prior behavior byte-for-byte: a
full `Asap.update!` rebuilds the element stiffness matrices and the global `S`
from scratch (which nulls the cached CHOLMOD factorization), then the solve
refactorizes. Pass `loads_only=true` ONLY when the caller can guarantee the
global stiffness `K` is UNCHANGED since the model was last assembled — i.e. no
section, geometry, or element-eccentricity change, only load magnitudes/combos or
self-weight moved. It then calls `Asap.update!(model; loads_only=true)`, which
rebuilds only the load vector `P` and PRESERVES the factorization (`external/Asap`
public API), so the subsequent `solve!(; reprocess=false)` reuses the cached
factor. Because CHOLMOD factorization of an identical `S` is deterministic, the
reused-factor solve is bit-identical to a cold refactorization — this is a pure
speed optimization, never a result change. Misusing it with a changed `K` yields
a STALE-factor wrong answer. The cold executor and the incremental scheduler set
it only when [`_loads_only_sync`](@ref) reports the stiffness token unchanged
(`SS_SYNC_LOADS_ONLY=off` forces a full update). The kwarg itself still defaults
to `false`.

See also: [`to_asap!`](@ref), [`snapshot!`](@ref), [`restore!`](@ref)
"""
function sync_asap!(struc::BuildingStructure;
                    params::DesignParameters=DesignParameters(),
                    loads_only::Bool=false)
    # 1. Push current slab self-weights into cells
    for slab in struc.slabs
        sw = StructuralSizer.self_weight(slab.result)
        for cell_idx in slab.cell_indices
            struc.cells[cell_idx].self_weight = sw
        end
    end
    
    use_patterns = _pattern_dead_split(struc, params)
    # A new slab thickness changes the shell stiffness, so the cached factor
    # cannot be reused even when the caller saw no change.
    _sync_flat_plate_shells!(struc, params) && (loads_only = false)
    
    # 2. Update tributary load pressures
    combo = governing_combo(params)
    for (cell_idx, cell) in enumerate(struc.cells)
        cell.floor_type == :grade && continue
        if use_patterns
            dead_p = uconvert(u"Pa", combo.D * (cell.sdl + cell.self_weight))
            live_p = uconvert(u"Pa", combo.L * cell.live_load)
            for tload in get(struc.cell_dead_loads, cell_idx, Asap.TributaryLoad[])
                tload.pressure = dead_p
            end
            for tload in get(struc.cell_live_loads, cell_idx, Asap.TributaryLoad[])
                tload.pressure = live_p
            end
        else
            combos = params.load_combinations
            dead = cell.sdl + cell.self_weight
            live = cell.live_load
            combined_p = uconvert(u"Pa", envelope_pressure(combos, dead, live))
            for tload in get(struc.cell_tributary_loads, cell_idx, Asap.TributaryLoad[])
                tload.pressure = combined_p
            end
        end
    end
    
    # Phase 7 — the sizing pass has run, so member depths are now known. Refresh
    # the joist-on-girder seat eccentricity (this is the pass where the steel
    # joist offset is actually applied) and any shell-area AreaLoad pressures.
    # Mutating the element eccentricity in place is sufficient: the reprocess
    # below recomputes each element's global stiffness, which folds in
    # `Element.eccentricity` (external/Asap/src/Elements/K.jl §global_K!).
    _sync_edge_eccentricity!(struc, params)
    _sync_shell_area_pressures!(struc, params)
    _sync_wall_self_weight!(struc, params)
    _sync_drop_panel_loads!(struc, params)
    _sync_member_self_weight!(struc, params)
    _sync_fire_coating_loads!(struc, params)
    _sync_vault_thrust_line_loads!(struc, params)
    _sync_slab_edge_strip_widths!(struc)

    # 3. Re-process stiffness and loads (topology unchanged). When the caller
    #    guarantees K is unchanged (loads_only), rebuild only P and keep the cached
    #    factorization; otherwise do the full (factorization-nulling) update. A
    #    loads_only reuse requires an already-assembled model — fall back to the
    #    full path if the model has not been processed yet.
    if struc.asap_model.processed
        Asap.update!(struc.asap_model; loads_only = loads_only)
    else
        Asap.process!(struc.asap_model)
    end
    
    # 4. Solve — single or multi-case. Both honor the rigid diaphragm links
    # `to_asap!` retained on `struc.asap_rigid_links`.
    if use_patterns && _should_run_patterns(struc, params)
        _solve_with_patterns!(struc, params)
    else
        _clear_pattern_solve_cache!(struc)
        _solve_struc_model!(struc)
    end
    
    return struc
end

"""
    _solve_struc_model!(struc) -> model

Solve `struc.asap_model` under the rigid-diaphragm links `to_asap!` built
(master/slave reduction, Bathe §4.4). A plain `Asap.solve!(model)` ignores
the links, so every re-solve of the building model goes through here.
Without links this is `Asap.solve!(model)`.
"""
function _solve_struc_model!(struc::BuildingStructure)
    model = struc.asap_model
    links = struc.asap_rigid_links
    isempty(links) && return Asap.solve!(model)
    require_diaphragm_node_stiffness(links, model.frame_elements, model.shell_elements)
    Asap.solve!(model, links; reprocess = !model.processed)
    return model
end

"""
Refresh the seat eccentricity of the Asap frame elements from the current member
depths (Phase 7 rebuild parity for [`sync_asap!`](@ref)). Recomputes the same
[`_build_edge_eccentricity_map`](@ref) used by `to_asap!` and writes each joist
edge's `Element.eccentricity` after `Asap.orient_up_eccentricity`, so the stored
slot 3 follows that element's roll. The subsequent reprocess applies it.
Elements not owned by a non-zero-offset joist are left untouched.
"""
function _sync_edge_eccentricity!(struc::BuildingStructure, params::DesignParameters)
    model = struc.asap_model
    isnothing(model) && return
    els = model.frame_elements
    for (edge_idx, ecc) in _build_edge_eccentricity_map(struc, params)
        (edge_idx >= 1 && edge_idx <= length(els)) || continue
        el = els[edge_idx]
        # `ecc` is physical (positive local y = global up). Sign slot 3 for
        # the roll already stored on this element.
        el.eccentricity = Asap.orient_up_eccentricity(
            ecc, el.nodeStart, el.nodeEnd; roll = el.Ψ)
    end
    return
end

"""
Refresh shell-area `Asap.AreaLoad` pressures from current cell self-weights
(Phase 7 rebuild parity for [`sync_asap!`](@ref)), mirroring the per-cell
tributary pressure refresh. `_create_shell_area_loads!` pushes exactly one
`AreaLoad` per non-grade slab in slab order. `:wall_self_weight` loads are
not slab pressures and are excluded. The refresh runs only when the
remaining loads are 1:1 with the eligible slabs; otherwise it is skipped.
When shell-area routing was not used there are no slab `AreaLoad`s and
this is a no-op.
"""
function _sync_shell_area_pressures!(struc::BuildingStructure, params::DesignParameters)
    model = struc.asap_model
    isnothing(model) && return
    area_loads = Asap.AreaLoad[ld for ld in model.loads
                               if ld isa Asap.AreaLoad && ld.id !== :wall_self_weight &&
                                  !(ld.id in _FP_LOAD_IDS)]
    isempty(area_loads) && return

    eligible = [slab for slab in struc.slabs
                if !isempty(slab.cell_indices) &&
                   struc.cells[first(slab.cell_indices)].floor_type != :grade]
    if length(eligible) != length(area_loads)
        @debug "sync_asap!: AreaLoad/slab count mismatch; skipping shell-area pressure refresh" n_loads=length(area_loads) n_slabs=length(eligible)
        return
    end

    combos = params.load_combinations
    for (slab, al) in zip(eligible, area_loads)
        cell0 = struc.cells[first(slab.cell_indices)]
        al.pressure = uconvert(u"Pa", envelope_pressure(combos,
                        cell0.sdl + cell0.self_weight, cell0.live_load))
    end
    return
end

"""
Refresh the vault-thrust `Asap.LineLoad` magnitudes from the current
`governing_combo(params)` (Run-2 `:load_combinations` parity for [`sync_asap!`](@ref)),
mirroring the per-cell tributary and shell-area pressure refresh. `to_asap!` step 6
BAKES these loads with a magnitude that depends on `governing_combo(params)`
(`vault_thrust_line_loads` → `eff.dead*combo.D + eff.live*combo.L`); a
`load_combinations` variation over a fixed prepared baseline changes
`governing_combo`, so without this refresh the frozen base-combo thrust would
diverge (unconservatively when the new combo has larger D/L).

This RELOCATES the existing, already-grounded derivation into the sync path — it
re-derives the edge line-load specs with the SAME [`slab_edge_line_loads`](@ref)
helper `to_asap!` uses (no thrust mechanics or load factors are re-derived here)
and writes each matching load's `value` in place. `to_asap!` tags every such load
`:vault_thrust`; the refresh matches those loads positionally in creation order
(equal-count guard, mirroring the shell-area refresh) and updates them. When no
vault thrust was built there are no `:vault_thrust` loads and this is a no-op.

Note on `design_building` byte-identity: on a `design_building` run this refresh is
NOT strictly a value no-op. `to_asap!` bakes the thrust from the ESTIMATE slab result
(from `initialize_slabs!`), while this sync — running after Stage-1 `size_slabs!` —
re-derives it from the SIZED slab result, so the thrust magnitude can change
(estimate → sized) even at constant `governing_combo`. `design_building` outputs stay
byte-identical on the current fixtures only because the vault thrust is not
member-governing there (it does not propagate into captured member sizing). A vault
whose members ARE lateral-thrust-governed would make `design_building` sensitive to
this refresh; the exact-first gate should add such a fixture before that case ships.
"""
function _sync_vault_thrust_line_loads!(struc::BuildingStructure, params::DesignParameters)
    model = struc.asap_model
    isnothing(model) && return
    thrust_loads = Asap.LineLoad[ld for ld in model.loads
                                 if ld isa Asap.LineLoad && ld.id === :vault_thrust]
    isempty(thrust_loads) && return

    # Re-derive the specs in the SAME (slab, spec) order `to_asap!` step 6 emits.
    specs = EdgeLineLoadSpec[]
    for slab in struc.slabs
        append!(specs, slab_edge_line_loads(struc, slab, params))
    end

    if length(specs) != length(thrust_loads)
        @debug "sync_asap!: vault-thrust load/spec count mismatch; skipping refresh" n_loads=length(thrust_loads) n_specs=length(specs)
        return
    end

    for (spec, ld) in zip(specs, thrust_loads)
        ld.value = [spec.w[1] * u"N/m", spec.w[2] * u"N/m", spec.w[3] * u"N/m"]
    end
    return
end

"""
    update_analysis!(struc, change; params) -> struc

Refresh the analysis after a stage, using the least work `change` allows.

- `:loads` — load magnitudes only. The factorization is kept (`sync_asap!`
  with `loads_only`).
- `:stiffness` — member sections changed and the mesh did not. Rebuild `K`
  and re-solve.
- `:geometry` — thickness, mesh, or connectivity changed. Rebuild the model.

A change that does not match one of these throws. Callers that need a
diaphragm override or a custom mesh still call `to_asap!` directly.
"""
function update_analysis!(struc::BuildingStructure, change::Symbol;
                          params::DesignParameters = DesignParameters(),
                          tc = nothing)
    change in (:loads, :stiffness, :geometry) || throw(ArgumentError(
        "analysis change :$change is not :loads, :stiffness, or :geometry"))
    StructuralSizer.emit!(tc, :workflow, "update_analysis!", "", :decision;
                          change = string(change))
    if change === :loads
        return sync_asap!(struc; params, loads_only = true)
    elseif change === :stiffness
        return _reanalyze_after_section_change!(struc)
    end
    frame = _sized_frame_state(struc.asap_model)
    to_asap!(struc; params)
    _restore_sized_frame_state!(struc, params, frame)
    return struc
end

"""
Frame-element sections and self-weight edges of a model, by skeleton edge.

`to_asap!` builds every frame element on a placeholder section and adds no
member self-weight; sizing writes both later. A rebuild after a wall change
uses this record to put them back.
"""
function _sized_frame_state(model)
    (isnothing(model) || isempty(model.frame_elements)) && return nothing
    edge_of = Dict(objectid(el) => i for (i, el) in enumerate(model.frame_elements))
    self_weight_edges = Int[]
    for ld in model.loads
        ld isa Asap.GravityLoad || continue
        i = get(edge_of, objectid(ld.element), nothing)
        i === nothing || push!(self_weight_edges, i)
    end
    return (sections = [el.section for el in model.frame_elements],
            self_weight_edges = self_weight_edges)
end

"""
Put the sized frame sections, member self-weight, and fire coating back on a
model `to_asap!` just rebuilt, then re-solve through [`sync_asap!`](@ref).
Wall and `:absent` edges keep the section the rebuild gave them.
"""
function _restore_sized_frame_state!(struc::BuildingStructure, params::DesignParameters,
                                     frame)
    frame === nothing && return struc
    model = struc.asap_model
    els = model.frame_elements
    length(els) == length(frame.sections) || throw(ArgumentError(
        "model rebuild: $(length(els)) frame elements after the rebuild, " *
        "$(length(frame.sections)) before. The skeleton edges changed."))
    inert = _inert_frame_edges(struc.skeleton)
    for (i, sec) in enumerate(frame.sections)
        i in inert || (els[i].section = sec)
    end
    a = member_self_weight_acceleration(params)
    for i in frame.self_weight_edges
        push!(model.loads, Asap.GravityLoad(els[i], a))
    end
    sync_asap!(struc; params)
    return struc
end

