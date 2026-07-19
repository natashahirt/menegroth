# =============================================================================
# DesignGraph module aggregator
# =============================================================================
#
# Structural scaffolding for the incremental content-addressed design DAG.
# Run 1 (foundation): node interface + graph container + sequential executor.
# No caching / fingerprinting / incremental logic yet — those arrive in later
# runs. `design_building` builds a graph (see `build_design_graph` in
# design_workflow.jl) and executes it, producing a `BuildingDesign` identical to
# the pre-graph pipeline.
#
# Include order: node interface first (types + generic functions), then the
# graph container (uses NodeKey / DesignNode), then the executor (uses both).
#
# Run 2 adds the incremental engine on top of the Run-1 layer:
#   provenance.jl  — canonical NodeKeys + per-node provenance table
#   fingerprint.jl — content-addressed input/output hashes (uses node provenance)
#   scheduler.jl   — demand-driven incremental scheduler + memo (uses all above,
#                    plus prepare!/sync_asap!/capture_design resolved at call time)
#   session.jl     — stateful variation API (DesignSession/redesign/vary) layered
#                    on top of the scheduler; purely additive, never re-implements it
# =============================================================================

include("node.jl")
include("graph.jl")
include("provenance.jl")
include("fingerprint.jl")
include("executor.jl")
include("scheduler.jl")
include("session.jl")
