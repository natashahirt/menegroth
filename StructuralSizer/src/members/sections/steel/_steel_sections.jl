# ==============================================================================
# Steel Sections
# ==============================================================================
# Section types and catalogs for structural steel members.

# Abstract types for hollow sections (needed before section files)

"""Abstract supertype for hollow steel sections (HSS and pipe)."""
abstract type AbstractHollowSection <: AbstractSection end

"""Abstract supertype for rectangular/square hollow steel sections."""
abstract type AbstractRectHollowSection <: AbstractHollowSection end

"""Abstract supertype for round hollow steel sections (HSS round and pipe)."""
abstract type AbstractRoundHollowSection <: AbstractHollowSection end

# I-shaped sections (W, S, M, HP shapes)
include("i_symm_section.jl")

# Hollow structural sections
include("hss_rect_section.jl")   # Rectangular/square HSS
include("hss_round_section.jl")  # Round HSS (pipe)

# Catalogs
include("catalogs/aisc_w.jl")
include("catalogs/aisc_hss.jl")

# Future section types:
# include("angle_section.jl")      # Single and double angles
# include("channel_section.jl")    # C and MC shapes  
# include("tee_section.jl")        # WT, ST, MT shapes
