# ==============================================================================
# Steel Sections
# ==============================================================================
# Section types and catalogs for structural steel members.

# Abstract types for hollow sections (needed before section files)
"""Base type for hollow structural sections (rectangular HSS, round HSS, pipe)."""
abstract type AbstractHollowSection <: AbstractSection end

"""Base type for rectangular or square hollow sections (HSSRectSection)."""
abstract type AbstractRectHollowSection <: AbstractHollowSection end

"""Base type for round hollow sections and pipe (HSSRoundSection)."""
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
