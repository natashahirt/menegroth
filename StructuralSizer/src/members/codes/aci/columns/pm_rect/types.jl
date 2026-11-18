# ==============================================================================
# ACI 318-11 Column P-M Interaction
# ==============================================================================
# Strain compatibility analysis for reinforced concrete columns
# Reference: ACI 318-11 Chapter 10
#
# Material utilities (beta1, Ec, fr, extractors) are in aci_material_utils.jl

using Unitful
using Asap: to_inches, to_sqinches

# ==============================================================================
# Control Point Types for P-M Diagrams
# ==============================================================================

"""
    ControlPointType

Enumeration of standard control points on ACI P-M interaction diagrams.
"""
@enum ControlPointType begin
    PURE_COMPRESSION       # P₀ - all compression
    MAX_COMPRESSION        # Pn,max = α×P₀
    FS_ZERO               # fs = 0, c = d
    FS_HALF_FY            # fs = 0.5fy
    BALANCED              # fs = fy, εt = εy
    TENSION_CONTROLLED    # εt = εy + 0.003
    PURE_BENDING          # Pn ≈ 0
    PURE_TENSION          # All steel in tension
    INTERMEDIATE          # Unlabeled intermediate point
end

# Shared P-M diagram discretization for MIP checker, NLP, and post-check validation.
# Must match `generate_PM_diagram` default keyword.
const PM_DIAGRAM_N_INTERMEDIATE = 20

# ENGINEERING JUDGMENT: linear interpolation on a discretized factored P-M envelope
# can vary by a few percent with point placement. Prevents hairline false failures
# when feasibility and post-check share the same discretization. Not an ACI φ factor.
const PM_INTERACTION_UTIL_TOL = 0.03

