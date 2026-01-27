# ==============================================================================
# Capacity Function Interface
# ==============================================================================
# Generic functions for each (Section, Material) pair.
# Concrete implementations provided by each design code module.

"""Design flexural strength (LRFD)."""
function get_ϕMn end

"""Design shear strength (LRFD)."""
function get_ϕVn end

"""Design compressive strength (LRFD)."""
function get_ϕPn end

"""Design tensile strength (LRFD)."""
function get_ϕTn end

"""Combined force interaction check. Returns utilization ratio (≤ 1.0 is safe)."""
function check_interaction end

# Nominal Capacity Interface (unfactored)

"""Nominal flexural strength."""
function get_Mn end

"""Nominal shear strength."""
function get_Vn end

"""Nominal compressive strength."""
function get_Pn end

"""Nominal tensile strength."""
function get_Tn end

# ==============================================================================
# Design Code Implementations
# ==============================================================================

# AISC 360: Structural Steel
include("aisc/_aisc.jl")

# NDS: Wood (stub)
include("nds/_nds.jl")

# ACI 318: Concrete (stub)
include("aci/_aci.jl")

# Future:
# include("eurocode/_eurocode.jl")
