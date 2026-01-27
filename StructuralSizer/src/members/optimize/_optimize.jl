# ==============================================================================
# Optimization Module
# ==============================================================================
# NOTE: Files are included directly from _members.jl to control include order.
# This file exists for organizational reference only.
#
# Include order (in _members.jl):
#   1. interface.jl      - AbstractCapacityChecker, AbstractCapacityCache
#   2. geometry.jl       - SteelMemberGeometry, TimberMemberGeometry, etc.
#   3. demands.jl        - MemberDemand
#   4. objectives.jl     - MinWeight, MinVolume, MinCost, MinCarbon
#   5. (sections and codes loaded)
#   6. discrete_mip.jl   - optimize_discrete()
#
# Future optimization approaches:
#   - continuous_nlp.jl  - Continuous sizing (NLP)
#   - gradient.jl        - Differentiable optimization
