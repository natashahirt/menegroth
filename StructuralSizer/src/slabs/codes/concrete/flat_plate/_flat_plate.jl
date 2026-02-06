# =============================================================================
# CIP Flat Plate Design per ACI 318
# =============================================================================
#
# Directory structure:
#   types.jl              - Analysis method types (DDM, EFM) and result structures
#   pipeline.jl           - Main design orchestration (size_flat_plate!)
#
#   utils/
#     calculations.jl     - Pure ACI equations (material properties, stiffness)
#     helpers.jl          - Support functions (column finding, frame building)
#
#   design/
#     checks.jl           - Design checks (punching, deflection, one-way shear)
#     reinforcement.jl    - Strip reinforcement design (ACI 8.10.5)
#     results.jl          - Result struct builders
#
#   analysis/
#     ddm.jl              - Direct Design Method moment analysis
#     efm.jl              - Equivalent Frame Method moment analysis (ASAP)
#
# Usage:
#   # DDM (default - fastest for regular bays)
#   result = size_flat_plate!(struc, slab, col_opts)
#
#   # EFM (more accurate for irregular layouts)
#   result = size_flat_plate!(struc, slab, col_opts; method=EFM())
#
#   # MDDM (simplified coefficients)
#   result = size_flat_plate!(struc, slab, col_opts; method=DDM(:simplified))
#
# =============================================================================

# Types first (required by other modules)
include("types.jl")

# Utility functions (pure equations, support helpers)
include("utils/calculations.jl")
include("utils/helpers.jl")

# Design functions (checks, reinforcement, results)
include("design/checks.jl")
include("design/reinforcement.jl")
include("design/results.jl")

# Analysis methods (DDM and EFM produce identical MomentAnalysisResult)
include("analysis/ddm.jl")
include("analysis/efm.jl")

# Main design pipeline (orchestration only)
include("pipeline.jl")
