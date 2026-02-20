# =============================================================================
# StructuralSizer Constants
# =============================================================================
# Structural engineering constants for design and analysis.

module Constants

using Unitful
using Asap: Torque, Force, Length, Pressure, Area, psf

# =============================================================================
# Solver/Optimization Constants
# =============================================================================

const BIG_M = 1e9

export BIG_M

# =============================================================================
# ACI 318-11 Code Constants
# =============================================================================

# §10.6.4 — Crack control stress limit (psi)
const ACI_CRACK_CONTROL_FS_PSI = 40000

export ACI_CRACK_CONTROL_FS_PSI

# =============================================================================
# PCA Notes on ACI 318-11 — Stiffness Factors
# =============================================================================
# Used in Equivalent Frame Method (EFM) for flat plate analysis.

# Table A1: Slab-beam stiffness factor for c/l ≈ 0.08–0.10 (typical flat plate)
const PCA_K_SLAB = 4.127
# Table A7: Column stiffness factor for ta/tb = 1, H/Hc ≈ 1.07
const PCA_K_COL = 4.74
# Table A1: Fixed-end moment coefficient
const PCA_M_FACTOR = 0.08429
# Table A1: Carry-over factor (non-prismatic slab-beam)
const PCA_COF = 0.507

export PCA_K_SLAB, PCA_K_COL, PCA_M_FACTOR, PCA_COF

# =============================================================================
# PCA Notes on ACI 318-11 — Non-Prismatic Factors (Flat Slab)
# =============================================================================
# For flat slabs with drop panels, the non-prismatic section behaviour
# (varying k, COF, FEM) is handled by the ASAP elastic solver, which models
# actual varying I values directly.  Hardy Cross moment distribution is NOT
# used for flat slabs.
#
# The constants below are retained ONLY for validation / unit-test purposes.
# They are NOT used in production analysis.  See efm.jl for the ASAP-only
# EFM path for flat slabs.
#
# Reference values from StructurePoint DE-Two-Way-Flat-Slab (ACI 318-11):
#   c/l = 20/(30×12) = 0.056, a/l ≈ 5/30 = 0.167
# =============================================================================

# ── Slab-beam (PCA Tables A2, A3, A5) ──
const PCA_K_SLAB_NP     = 5.587   # stiffness factor
const PCA_COF_NP        = 0.578   # carryover factor
const PCA_M_NP_UNIFORM  = 0.0915  # FEM coefficient, uniform load
const PCA_M_NP_NEAR     = 0.0163  # FEM coefficient, near-end drop patch
const PCA_M_NP_FAR      = 0.002   # FEM coefficient, far-end drop patch

# ── Column (PCA Table A7) ──
const PCA_K_COL_NP_BOTTOM   = 5.318  # bottom column (ta/tb ≈ 1.85)
const PCA_K_COL_NP_TOP      = 4.879  # top column (ta/tb ≈ 0.54)
const PCA_COF_COL_NP_BOTTOM = 0.545
const PCA_COF_COL_NP_TOP    = 0.595

export PCA_K_SLAB_NP, PCA_COF_NP
export PCA_M_NP_UNIFORM, PCA_M_NP_NEAR, PCA_M_NP_FAR
export PCA_K_COL_NP_BOTTOM, PCA_K_COL_NP_TOP
export PCA_COF_COL_NP_BOTTOM, PCA_COF_COL_NP_TOP

# =============================================================================
# Load factors: use LoadCombination from loads/combinations.jl
# (DL_FACTOR / LL_FACTOR removed — replaced by default_combo.D / .L)
# =============================================================================

# =============================================================================
# Standard Units (for consistent internal representation)
# =============================================================================

const STANDARD_LENGTH = u"m"
const STANDARD_AREA = u"m^2"
const STANDARD_FORCE = u"kN"
const STANDARD_PRESSURE = u"kN/m^2"

export STANDARD_LENGTH, STANDARD_AREA, STANDARD_FORCE, STANDARD_PRESSURE

# =============================================================================
# Vector Helpers
end # module
