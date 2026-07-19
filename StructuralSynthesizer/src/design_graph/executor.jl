# =============================================================================
# DesignGraph — Executor
# =============================================================================
#
# Level-barrier executor: walk the graph in dependency LEVELS (Kahn waves) and
# call `sync_asap!` exactly ONCE after a completed level that requires a sync
# (any node in the level declaring `needs_sync`), rather than once per node. For
# the current coarse linear chain every level holds exactly one node, so this
# reproduces the pre-graph `design_building` loop byte-for-byte:
#
#   for stage in build_pipeline(params; tc=tc)
#       stage.fn(struc)
#       stage.needs_sync && sync_asap!(struc; params=params)
#   end
#
# The barrier is the generalization the next wave (fine per-group sizing nodes)
# builds on: a level holding MULTIPLE sizing nodes syncs the whole-model once
# after the level instead of once per node.
#
# The executor is deliberately trace-silent: node closures emit their own trace
# events (as the pipeline stages always did), so the executor adds nothing to
# `design.solver_trace`, keeping outputs byte-for-byte identical. No
# parallelism yet — nodes within a level run sequentially in insertion order.
# =============================================================================

"""
    execute_graph!(g::DesignGraph, struc::BuildingStructure,
                   params::DesignParameters; ctx=nothing) -> struc

Run every node in `g` against `struc`, in dependency [`topological_levels`](@ref)
order. After each completed level, call `sync_asap!(struc; params=params)` once if
the level requires a sync ([`level_needs_sync`](@ref) — any node in the level
declares [`needs_sync`](@ref)). For the linear coarse chain each level is a single
node, so this is the identical run/sync sequence as the per-node pipeline loop.

`ctx` is threaded to each node's [`run!`](@ref) for future extension (caching /
fingerprinting) and is unused in Run 1. Returns the mutated `struc`.
"""
function execute_graph!(g::DesignGraph, struc::BuildingStructure,
                        params::DesignParameters; ctx=nothing)
    for level in topological_levels(g)
        for key in level
            run!(get_node(g, key), struc, params, ctx)
        end
        level_needs_sync(g, level) && sync_asap!(struc; params=params)
    end
    return struc
end
