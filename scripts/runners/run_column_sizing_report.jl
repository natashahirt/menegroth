# =============================================================================
# Runner: Column Sizing Validation Report
# =============================================================================
# Runs the column sizing report (MIP vs NLP + rectangular expansion).
#
# Usage (from repo root):
#   julia scripts/runners/run_column_sizing_report.jl
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."))

test_path = joinpath(@__DIR__, "..", "..", "StructuralSynthesizer", "test",
                     "sizing", "members", "test_column_sizing_report.jl")

include(test_path)
