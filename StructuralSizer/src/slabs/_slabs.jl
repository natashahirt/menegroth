# Slab types (dispatch targets)
include("types.jl")

# User-facing sizing options + guidance
include("options.jl")

# Sizing codes (must come before dispatcher)
include("codes/_codes.jl")

# ACI strip geometry utilities (column/middle strip split)
# Generic tributary computation is now in Asap
include("utils/_utils.jl")

# Top-level slab sizing dispatcher
# Dispatches to appropriate sizing function based on floor type
include("sizing.jl")

# Floor optimization (NLP for vaults, etc.)
# Must come after codes/ which define sizing functions
include("optimize/_optimize.jl")