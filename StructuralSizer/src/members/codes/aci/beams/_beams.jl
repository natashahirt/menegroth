# ==============================================================================
# ACI 318 Beam Design
# ==============================================================================
# Flexural design (Whitney block, min reinforcement, strain checks)
# Shear design (Vc, Vs, stirrup sizing, spacing limits)
# Serviceability (deflection — immediate + long-term)

include("flexure.jl")
include("shear.jl")
include("serviceability.jl")

# Torsion design (ACI 318-11 §11.5 — threshold, adequacy, reinforcement)
include("torsion.jl")

# T-beam flexural design (effective flange width, T-beam decomposition)
include("t_flexure.jl")

# Capacity checker (implements AbstractCapacityChecker for optimize_discrete)
include("checker.jl")

# T-beam extensions for checker (dispatches on RCTBeamSection)
include("t_checker.jl")