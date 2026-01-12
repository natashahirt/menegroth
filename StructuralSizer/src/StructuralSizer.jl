module StructuralSizer

using Logging
using CSV
using StructuralBase
using Unitful

# Types (Metal, etc.)
include("types.jl")

# Materials
include("materials/steel.jl")
include("materials/concrete.jl")

# Sections (geometry + catalogs)
include("sections/_sections.jl")

# Design code checks
include("codes/_codes.jl")

# === Exports ===

# Types
export Metal, ISymmSection

# Materials
export A992_Steel, S355_Steel

# Sections
export W, W_names, all_W
export update!, update, geometry, get_coords

# AISC Checks
export get_slenderness, is_compact
export get_Mn, get_ϕMn, get_Lp_Lr, get_Fcr
export get_Vn, get_ϕVn, get_Cv1
export get_Pn, get_ϕPn, get_Fe, get_Fcr
export check_PM_interaction, check_PMxMy_interaction

end # module
