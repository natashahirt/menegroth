# ==============================================================================
# Wall-cache contract (Phase 4) — classes, fingerprints, and a refusing stub
# ==============================================================================
# The cache itself is not implemented. It lands with the unified frame-shell
# model. Nothing here assembles a stiffness, factorizes, solves, or hashes a
# model. `design_building`, `to_asap!`, and the design-graph scheduler must
# not call `apply_wall_cache_class`.

"""
    WallCacheClass

How much of a previous wall analysis a later cache would be allowed to reuse.
Strictness increases in enumerator order: `checks_only` < `loads_only` <
`stiffness_only` < `topology`. A weaker request is refused. It is never
rewritten into the stricter class.

- `checks_only` — rerun checks. Does not solve. May reuse the mesh, sparsity,
  symbolic factorization, numeric factorization, assembled `K`, load routing,
  load vectors, solved states, and recovery maps.
- `loads_only` — reuse the assembled `K` and its numeric factorization, and
  solve new right-hand sides. May also reuse the mesh, sparsity, symbolic
  factorization, load routing, and recovery maps. Must not reuse solved states
  from a different right-hand side.
- `stiffness_only` — reuse the mesh, sparsity, symbolic factorization, load
  routing, and recovery maps, then update numeric values and refactorize.
  Must not reuse the numeric factorization or a previous solved state, and
  must not be served by `sync_asap!(; loads_only=true)`.
- `topology` — rebuild. Reuses none of the analysis artifacts above.

P-delta and accidental torsion are separate solves, not a `loads_only` reuse.
This contract states no code factor for either effect.

The later implementation must call these existing primitives and must not
reimplement them. This file does not wrap or invoke them.

- `Asap.solve(model, cases)` — non-mutating multi-right-hand-side solve on
  `FrameModel` and unified `Model` (`external/Asap/src/Model/analysis.jl`).
  One cached factorization, then a new right-hand side per case. This is not
  `solve!`.
- `sync_asap!(struc; loads_only=true)` — `analyze/asap/utils.jl`. Calls
  `Asap.update!(model; loads_only=true)`, rebuilds only the load vector, and
  keeps the cached factorization. Legal only when the assembled stiffness is
  unchanged.
"""
@enum WallCacheClass begin
    checks_only = 0
    loads_only = 1
    stiffness_only = 2
    topology = 3
end

"""
    checks_only

Rerun checks on the stored analysis. Does not solve. See [`WallCacheClass`](@ref).
"""
checks_only

"""
    loads_only

Reuse assembled `K` and its factorization; solve new right-hand sides.
P-delta and accidental torsion are separate solves, not a `loads_only` reuse.
See [`WallCacheClass`](@ref).
"""
loads_only

"""
    stiffness_only

Reuse mesh, sparsity, symbolic factorization, load routing, and recovery maps;
update numbers and refactorize. See [`WallCacheClass`](@ref).
"""
stiffness_only

"""
    topology

Rebuild the wall analysis. See [`WallCacheClass`](@ref).
"""
topology

"""Rank of a cache class. Higher means stricter (less reuse)."""
function _wall_cache_rank(class::WallCacheClass)::Int
    if class === checks_only
        return 0
    elseif class === loads_only
        return 1
    elseif class === stiffness_only
        return 2
    elseif class === topology
        return 3
    else
        throw(ArgumentError("unknown wall cache class $(class)"))
    end
end

"""
    refuse_wall_cache_class(requested, also_required...) -> WallCacheClass

Return `requested` when every `also_required` class is equally or less strict.
Throw `ArgumentError` when any `also_required` class is stricter. The throw is
the whole result: this function does not substitute the stricter class.

A `loads_only` request together with a `stiffness_only` or `topology`
requirement throws. A request that is already stricter than the requirement
is unchanged.
"""
function refuse_wall_cache_class(requested::WallCacheClass, also_required::WallCacheClass...)
    requested_rank = _wall_cache_rank(requested)
    strictest = requested
    for required in also_required
        if _wall_cache_rank(required) > _wall_cache_rank(strictest)
            strictest = required
        end
    end
    if _wall_cache_rank(strictest) > requested_rank
        throw(ArgumentError(
            "requested wall cache class $(requested) but stricter class $(strictest) " *
            "is also required; refusing to downgrade"))
    end
    return requested
end

"""
    apply_wall_cache_class(requested, required=requested)

Refuse to run. The wall cache is not implemented and lands with the unified
model. `design_building`, `to_asap!`, and the design-graph scheduler must not
call this.

When `required` is stricter than `requested`, throws from
[`refuse_wall_cache_class`](@ref) and does not downgrade. Otherwise throws
`ArgumentError` because there is no cache to apply.
"""
function apply_wall_cache_class(requested::WallCacheClass,
                                required::WallCacheClass=requested)
    refuse_wall_cache_class(requested, required)
    throw(ArgumentError(
        "the wall cache is not implemented and lands with the unified model"))
end

"""
    WallFingerprintKind

One named fingerprint a later wall cache must keep separate from the others.
Holding a kind does not read a model and does not compute a hash.
"""
struct WallFingerprintKind
    name::Symbol
end

"""
    FINGERPRINT_TOPOLOGY

Fingerprint kind `:topology`. Reads element connectivity, story stacking,
shared-node identity, support fixity, and diaphragm membership. Does not read
section or material numbers, load magnitudes, or displacements.
"""
const FINGERPRINT_TOPOLOGY = WallFingerprintKind(:topology)

"""
    FINGERPRINT_DOF_MAP

Fingerprint kind `:dof_map`. Reads the free and fixed equation numbering
produced from connectivity and restraint codes. Does not read stiffness
numbers or load magnitudes.
"""
const FINGERPRINT_DOF_MAP = WallFingerprintKind(:dof_map)

"""
    FINGERPRINT_SCATTER_MAPS

Fingerprint kind `:scatter_maps`. Reads the element-local to global index maps
used to scatter element matrices. Those maps are fixed by connectivity and the
DOF map. Does not read numeric matrix entries or loads.
"""
const FINGERPRINT_SCATTER_MAPS = WallFingerprintKind(:scatter_maps)

"""
    FINGERPRINT_LOAD_VECTORS

Fingerprint kind `:load_vectors`. Reads load magnitudes, the positions where
those loads are applied, and the DOF map they assemble onto. Does not read
the stiffness matrix.
"""
const FINGERPRINT_LOAD_VECTORS = WallFingerprintKind(:load_vectors)

"""
    FINGERPRINT_SOLVED_STATES

Fingerprint kind `:solved_states`. Reads the factorization and the load vector
of each solved case. A P-delta solve and an accidental-torsion solve are
distinct states. Does not read checker inputs that never enter a solve.
"""
const FINGERPRINT_SOLVED_STATES = WallFingerprintKind(:solved_states)

"""
    FINGERPRINT_RECOVERY_MAPS

Fingerprint kind `:recovery_maps`. Reads the mesh, element orientation, and
DOF map used to recover story drift and per-wall forces. Does not read load
magnitudes or the displacement vector of a particular case.
"""
const FINGERPRINT_RECOVERY_MAPS = WallFingerprintKind(:recovery_maps)

"""
The six fingerprint kinds, named and not computed. This tuple does not hash a model.
"""
const WALL_FINGERPRINT_KINDS = (
    FINGERPRINT_TOPOLOGY,
    FINGERPRINT_DOF_MAP,
    FINGERPRINT_SCATTER_MAPS,
    FINGERPRINT_LOAD_VECTORS,
    FINGERPRINT_SOLVED_STATES,
    FINGERPRINT_RECOVERY_MAPS,
)

"""
    WALL_CACHE_PRIMITIVES

Names of the existing functions the later wall-cache implementation must call.
Stored as text so this file does not wrap or invoke them.

- `Asap.solve(model, cases)` — multi-right-hand-side factorization reuse.
- `sync_asap!(struc; loads_only=true)` — load-vector rebuild with the cached factor kept.
"""
const WALL_CACHE_PRIMITIVES = (
    "Asap.solve(model, cases)",
    "sync_asap!(struc; loads_only=true)",
)

export apply_wall_cache_class
