# =============================================================================
# Load Infrastructure
# =============================================================================
# Load combinations (ASCE 7-22), unfactored gravity loads, and pattern loading
# (ACI 318-11 §13.7.6) for structural design.

include("combinations.jl")
include("gravity.jl")
include("pattern_loading.jl")