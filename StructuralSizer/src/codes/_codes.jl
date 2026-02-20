# ==============================================================================
# Shared Design Code Utilities
# ==============================================================================
# Element-agnostic ACI math (material properties, Whitney block, deflection,
# rebar catalog) used by both members/ and slabs/.
#
# Included BEFORE members/ and slabs/ in StructuralSizer.jl.
# ==============================================================================

include("aci/_aci_shared.jl")
include("aisc/fire.jl")
