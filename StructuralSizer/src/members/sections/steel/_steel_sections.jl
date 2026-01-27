# ==============================================================================
# Steel Sections
# ==============================================================================
# Section types and catalogs for structural steel members.

# I-shaped sections (W, S, M, HP shapes)
include("i_symm_section.jl")

# HSS sections (stub)
include("hss_section.jl")

# Catalogs
include("catalogs/aisc_w.jl")

# Future section types:
# include("angle_section.jl")      # Single and double angles
# include("channel_section.jl")    # C and MC shapes  
# include("tee_section.jl")        # WT, ST, MT shapes
# include("pipe_section.jl")       # Round HSS / Pipe

# Future catalogs:
# include("catalogs/aisc_hss.jl")
# include("catalogs/aisc_angles.jl")
