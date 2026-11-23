# ==============================================================================
# Shared, material-agnostic column-design utilities
# ==============================================================================
# Bridges the per-code second-order procedures (ACI 318-11 §10.10, AISC 360-16
# Appendix 8) that are defined in aci/ and aisc/. Included AFTER those modules so
# `SwayStoryProperties`, `B2StoryProperties`, and the B1/B2/δs primitives exist.

include("story_stability.jl")   # StoryStability record + ACI/AISC adapters
include("column_moments.jl")    # design_column_moments trait (material-dispatched)
