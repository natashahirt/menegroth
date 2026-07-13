# ==============================================================================
# Structural Walls — lateral-force-resisting system (shear walls)
# ==============================================================================
# Efficiency foundation for shear-wall layout optimization (plan S1-S4). Builds
# up in tiers, each layered on the one before without reworking the wall type or
# checker:
#
#   wall_section.jl      S1  WallSection + analytic, differentiable in-plane
#                            lateral stiffness (ACI effective-stiffness based).
#   checker.jl           S1  Demand-decoupled ACI 318-19 §11.5.4 in-plane shear
#                            strength + minimum-reinforcement checks (CheckResult).
#   lateral_evaluator.jl S2  AbstractLateralEvaluator interface + differentiable
#                            ReducedDiaphragmEvaluator (3 DOF/story, rank-1/wall,
#                            analytic sensitivities) — the cheap tier.
#   fem_evaluator.jl     S3  FEMLateralEvaluator (Asap shells) — validation tier
#                            (assembly wiring pending, todo-w0000004).
#   layout_problem.jl    S4  WallLayoutNLPProblem <: AbstractNLPProblem — gradient
#                            topology optimization over a candidate ground
#                            structure; carbon-first, drift/multi-objective ready.
#
# All formulas cite ACI 318-19 clauses + the StructurePoint worked examples in
# the corpus; clause/page references are marked VERIFY pending zettelkasten
# extraction (see skill `implement-design-system`, stage 1).

include("wall_section.jl")
include("checker.jl")
include("lateral_evaluator.jl")
include("fem_evaluator.jl")
include("layout_problem.jl")
