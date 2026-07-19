# =============================================================================
# DesignGraph — Node Interface
# =============================================================================
#
# A `DesignNode` is a single unit of work in the design pipeline. Run 1 wraps
# the existing coarse pipeline stages (slab sizing, beam/column sizing,
# foundations) as nodes with a linear dependency chain, reproducing today's
# `design_building` loop exactly. The interface is intentionally small and
# dispatch-based so that later runs can register finer-grained per-group nodes
# and new element types WITHOUT modifying the executor:
#
#   node_key(node)      -> NodeKey        identity
#   dependencies(node)  -> Vector{NodeKey} nodes that must run first
#   needs_sync(node)    -> Bool           call sync_asap! after this node
#   run!(node, struc, params, ctx)        mutate `struc` (the actual work)
#
# =============================================================================

"""
    NodeKey

Identity type for a [`DesignNode`](@ref). A `Symbol` alias — small, stable, and
hashable.

Run 2 makes the *values* content-stable: node keys are derived from the stage
SEMANTICS (`:slab_sizing`, `:members`, `:foundations`, …), never from a stage's
positional index. The same key therefore denotes the same unit of work
regardless of which `DesignParameters` were used or which branch (flat-plate vs
beam/column) `build_pipeline` took. This is the invariant the incremental engine
(fingerprints, memo, per-node snapshots) keys off — see
[`canonical_node_keys`](@ref) for the stable identity set.
"""
const NodeKey = Symbol

"""
    DesignNode

Abstract supertype for a unit of work in a [`DesignGraph`](@ref).

Concrete nodes implement the four-function interface: [`node_key`](@ref),
[`dependencies`](@ref), [`needs_sync`](@ref), and [`run!`](@ref). The executor
dispatches only through this interface, so new node types can be added without
changing the executor.
"""
abstract type DesignNode end

"""
    node_key(node::DesignNode) -> NodeKey

Return the unique identity of `node` within its graph.
"""
function node_key end

"""
    dependencies(node::DesignNode) -> Vector{NodeKey}

Return the keys of nodes that must run before `node`. An empty vector means the
node has no predecessors (a root).
"""
function dependencies end

"""
    needs_sync(node::DesignNode) -> Bool

Whether the executor should call `sync_asap!(struc; params)` immediately after
running `node`. Mirrors `PipelineStage.needs_sync` so the graph reproduces the
exact `sync_asap!` placement of the pre-graph pipeline loop.
"""
function needs_sync end

"""
    run!(node::DesignNode, struc, params, ctx) -> Any

Execute `node`, mutating `struc` in place. `params` is the active
`DesignParameters`; `ctx` is a per-execution context threaded by the executor
(unused in Run 1, reserved for future caching/fingerprinting). The return value
is ignored by the executor.
"""
function run! end

# =============================================================================
# Provenance interface (Run 2)
# =============================================================================
#
# Every node declares, in a queryable form, exactly what it consumes and
# produces. The fingerprint (fingerprint.jl) and the dirty-frontier resolver
# (scheduler.jl) read ONLY these declarations — they never introspect the node's
# closure. The declarations must therefore be COMPLETE: a node must list every
# `DesignParameters` field it reads (`param_slice`) and every `BuildingStructure`
# field it mutates (`struc_writes`). Over-declaring is safe (extra recompute);
# under-declaring is a correctness bug (stale reuse), so declarations lean
# conservative.
#
#   param_slice(node)  -> Vector{Symbol}   DesignParameters field names read
#   struc_reads(node)  -> Vector{Symbol}   BuildingStructure fields read
#   struc_writes(node) -> Vector{Symbol}   BuildingStructure fields written
#   code_version(node) -> Symbol           node code-version tag (bump to invalidate)
#
# Defaults are empty / `:v1` so pre-Run-2 node types keep working unchanged.
# =============================================================================

"""
    param_slice(node::DesignNode) -> Vector{Symbol}

Names of the `DesignParameters` fields this node reads. This is the parameter
slice folded into the node's input fingerprint (see [`input_hash`](@ref)). Must
be complete: any field that can change the node's output belongs here. Defaults
to `Symbol[]`.
"""
param_slice(::DesignNode) = Symbol[]

"""
    struc_reads(node::DesignNode) -> Vector{Symbol}

Names of the `BuildingStructure` fields this node reads. Informational /
documentary provenance (the fingerprint keys off upstream OUTPUT hashes, not
this list). Defaults to `Symbol[]`.
"""
struc_reads(::DesignNode) = Symbol[]

"""
    struc_writes(node::DesignNode) -> Vector{Symbol}

Names of the `BuildingStructure` fields this node mutates. The node's OUTPUT
hash (see [`output_hash`](@ref)) is computed over exactly these fields, so the
list must be complete for early-cutoff to be safe. Defaults to `Symbol[]`.
"""
struc_writes(::DesignNode) = Symbol[]

"""
    code_version(node::DesignNode) -> Symbol

Code-version tag for the node's implementation. It is mixed into the node's
input fingerprint, so bumping it invalidates every memoized result for that node
(use when the node's computation changes but its identity/params do not).
Defaults to `:v1`.
"""
code_version(::DesignNode) = :v1

"""
    node_provenance(node::DesignNode) -> NamedTuple

Bundle a node's full provenance declaration as
`(key, deps, param_slice, reads, writes, code_version, needs_sync)`. Convenience
for the scheduler and for the invalidation-matrix tests that consume this API
from outside the module.
"""
node_provenance(node::DesignNode) = (
    key          = node_key(node),
    deps         = dependencies(node),
    param_slice  = param_slice(node),
    reads        = struc_reads(node),
    writes       = struc_writes(node),
    code_version = code_version(node),
    needs_sync   = needs_sync(node),
)

# =============================================================================
# StageNode — closure-backed concrete node
# =============================================================================

"""
    StageNode <: DesignNode

Concrete [`DesignNode`](@ref) that wraps a mutating closure plus metadata. This
is the workhorse node for Run 1: each coarse pipeline stage becomes one
`StageNode`, preserving the closure and `needs_sync` flag of the original
`PipelineStage` so behavior is byte-for-byte identical.

Fields:
- `key::NodeKey` — node identity.
- `deps::Vector{NodeKey}` — predecessor keys (dependency edges).
- `fn::Function` — closure `struc -> …` that performs the work (mutates `struc`).
- `sync::Bool` — whether `sync_asap!` runs after this node.
- `param_slice::Vector{Symbol}` — [`param_slice`](@ref) declaration.
- `reads::Vector{Symbol}` — [`struc_reads`](@ref) declaration.
- `writes::Vector{Symbol}` — [`struc_writes`](@ref) declaration.
- `code_version::Symbol` — [`code_version`](@ref) tag.

The 4-argument constructor (`StageNode(key, deps, fn, sync)`) is preserved for
back-compat and constructs a node with empty provenance (`Symbol[]`) and
`code_version = :v1` — used by pure-ordering fixtures that never touch the
incremental engine. `build_design_graph` uses the full constructor to attach the
real provenance declared in `provenance.jl`.
"""
struct StageNode <: DesignNode
    key::NodeKey
    deps::Vector{NodeKey}
    fn::Function
    sync::Bool
    param_slice::Vector{Symbol}
    reads::Vector{Symbol}
    writes::Vector{Symbol}
    code_version::Symbol
end

"""Back-compat constructor: a `StageNode` with empty provenance (`code_version = :v1`)."""
StageNode(key::NodeKey, deps::Vector{NodeKey}, fn, sync::Bool) =
    StageNode(key, deps, fn, sync, Symbol[], Symbol[], Symbol[], :v1)

node_key(node::StageNode) = node.key
dependencies(node::StageNode) = node.deps
needs_sync(node::StageNode) = node.sync
param_slice(node::StageNode) = node.param_slice
struc_reads(node::StageNode) = node.reads
struc_writes(node::StageNode) = node.writes
code_version(node::StageNode) = node.code_version

# Run 1: the closure already captures `params`/`tc`, so `run!` just invokes it.
# `params`/`ctx` are accepted for interface uniformity and future node types.
run!(node::StageNode, struc, params, ctx) = node.fn(struc)
