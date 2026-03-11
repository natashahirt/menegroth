# =============================================================================
# PCA Notes on ACI 318-11, Appendix 20A — Digitized Tables
# =============================================================================
#
# Moment distribution constants for slab-beam members (Table A1) and
# column stiffness/carry-over factors (Table A7).
#
# Reference: PCA Notes on ACI 318-11, EB712, Appendix 20A, pp. 20-13 to 20-19.
#
# These tables are used by the Equivalent Frame Method (EFM) to compute
# geometry-dependent stiffness factors, carry-over factors, and fixed-end
# moment coefficients — replacing the previously hardcoded constants.
#
# Table A1: Flat plate (prismatic slab-beam), equal columns at both ends
#   C_F1 = C_N1, C_F2 = C_N2
#   Indexed by (C_N1/l₁, C_N2/l₂)
#   Returns: k_NF (stiffness factor), C_NF (carry-over factor), m_NF (FEM coeff)
#
# Table A7: Column stiffness and carry-over factors
#   Indexed by (t_a/t_b, H/H_c)
#   Returns: k_AB (stiffness factor), C_AB (carry-over factor)
#
# =============================================================================

# =============================================================================
# Table A1 — Slab-Beam Stiffness (Flat Plate, Equal Columns)
# =============================================================================
# Section: C_F1 = C_N1; C_F2 = C_N2  (symmetric column dimensions)
#
# Row index: C_N1/l₁  (column dimension parallel to span / span length)
# Sub-row:   C_N2/l₂  (column dimension perpendicular to span / transverse width)
#
# For C_N1/l₁ = 0.00, C_N2/l₂ is irrelevant (—), so only one row.
# For each (C_N1/l₁, C_N2/l₂) pair: (k_NF, C_NF, m_NF)
#
# The m_NF values listed here are for uniform load only (a=0, b-a=1.0).
# The full table also has m_NF for partial loading (a≠0), but for our
# purposes (uniformly loaded slabs), only the a=0 column is needed:
#   m_NF(a=0) is the "Unif. Load Fixed end M. Coeff. (m_NF)" column.
# =============================================================================

"""
    PCA Table A1 data for prismatic flat plate slab-beams.

Section: C_F1 = C_N1; C_F2 = C_N2 (equal column sizes at near and far ends).

Each entry is `(k_NF, C_NF, m_NF)`:
- `k_NF`: stiffness factor  (K = k × Ecs × Is / l₁)
- `C_NF`: carry-over factor
- `m_NF`: fixed-end moment coefficient  (FEM = m × w × l₁²)

Indexed by `(C_N1/l₁, C_N2/l₂)`.
"""
const _TABLE_A1_DATA = Dict{Tuple{Float64, Float64}, NTuple{3, Float64}}(
    # ── C_N1/l₁ = 0.00 ──
    # When C_N1/l₁ = 0 the column has zero width in the span direction,
    # so C_N2/l₂ doesn't matter.  PCA lists a single row with C_N2/l₂ = —.
    # We store it at C_N2/l₂ = 0.00 and the interpolator handles it.
    (0.00, 0.00) => (4.00, 0.50, 0.0833),

    # ── C_N1/l₁ = 0.10 ──
    (0.10, 0.00) => (4.00, 0.50, 0.0833),
    (0.10, 0.10) => (4.18, 0.51, 0.0847),
    (0.10, 0.20) => (4.36, 0.52, 0.0860),
    (0.10, 0.30) => (4.53, 0.54, 0.0872),
    (0.10, 0.40) => (4.70, 0.55, 0.0882),

    # ── C_N1/l₁ = 0.20 ──
    (0.20, 0.00) => (4.00, 0.50, 0.0833),
    (0.20, 0.10) => (4.35, 0.52, 0.0857),
    (0.20, 0.20) => (4.72, 0.54, 0.0880),
    (0.20, 0.30) => (5.11, 0.56, 0.0901),
    (0.20, 0.40) => (5.51, 0.58, 0.0921),

    # ── C_N1/l₁ = 0.30 ──
    (0.30, 0.00) => (4.00, 0.50, 0.0833),
    (0.30, 0.10) => (4.49, 0.53, 0.0863),
    (0.30, 0.20) => (5.05, 0.56, 0.0893),
    (0.30, 0.30) => (5.69, 0.59, 0.0923),
    (0.30, 0.40) => (6.41, 0.61, 0.0951),

    # ── C_N1/l₁ = 0.40 ──
    (0.40, 0.00) => (4.00, 0.50, 0.0833),
    (0.40, 0.10) => (4.61, 0.53, 0.0866),
    (0.40, 0.20) => (5.35, 0.56, 0.0901),
    (0.40, 0.30) => (6.25, 0.60, 0.0936),
    (0.40, 0.40) => (7.37, 0.64, 0.0971),
)

"""Row values for C_N1/l₁ in Table A1."""
const _TABLE_A1_CN1_VALS = [0.00, 0.10, 0.20, 0.30, 0.40]

"""Sub-row values for C_N2/l₂ in Table A1."""
const _TABLE_A1_CN2_VALS = [0.00, 0.10, 0.20, 0.30, 0.40]


# =============================================================================
# Table A7 — Column Stiffness and Carry-Over Factors
# =============================================================================
# Indexed by (t_a/t_b, H/H_c).
#
# t_a = capital/bracket depth at top of column
# t_b = capital/bracket depth at bottom of column
# For flat plates without capitals: t_a = t_b = 0, so t_a/t_b = 0.
#   (PCA lists t_a/t_b = 0.00 as the first row.)
#
# H   = total story height (floor-to-floor)
# H_c = clear column height = H - h_slab  (for flat plates)
#
# Each entry: (k_AB, C_AB)
# - k_AB: column stiffness factor  (Kc = k × Ecc × Ic / H)
# - C_AB: column carry-over factor
#
# Note: For k_BA and C_BA (reading ta/tb as tb/ta), the table says
#       "For values of k_BA and C_BA read (ta/tb) as (tb/ta)."
#       For flat plates ta = tb, so k_AB = k_BA and C_AB = C_BA.
# =============================================================================

"""
    PCA Table A7 data for column stiffness and carry-over factors.

Each entry is `(k_AB, C_AB)`:
- `k_AB`: stiffness factor  (Kc = k × Ecc × Ic / H)
- `C_AB`: carry-over factor

Indexed by `(ta_over_tb, H_over_Hc)`.

For flat plates without column capitals, `ta/tb = 0` and
`H/Hc = H / (H - h_slab)`.
"""
const _TABLE_A7_DATA = Dict{Tuple{Float64, Float64}, NTuple{2, Float64}}(
    # ── ta/tb = 0.00 ──
    (0.00, 1.05) => (4.20, 0.57),
    (0.00, 1.10) => (4.40, 0.65),
    (0.00, 1.15) => (4.60, 0.73),
    (0.00, 1.20) => (4.80, 0.80),
    (0.00, 1.25) => (5.00, 0.87),
    (0.00, 1.30) => (5.20, 0.95),
    (0.00, 1.35) => (5.40, 1.03),
    (0.00, 1.40) => (5.60, 1.10),
    (0.00, 1.45) => (5.80, 1.17),
    (0.00, 1.50) => (6.00, 1.25),

    # ── ta/tb = 0.20 ──
    (0.20, 1.05) => (4.31, 0.56),
    (0.20, 1.10) => (4.62, 0.62),
    (0.20, 1.15) => (4.95, 0.68),
    (0.20, 1.20) => (5.30, 0.74),
    (0.20, 1.25) => (5.65, 0.80),
    (0.20, 1.30) => (6.02, 0.85),
    (0.20, 1.35) => (6.40, 0.91),
    (0.20, 1.40) => (6.79, 0.96),
    (0.20, 1.45) => (7.20, 1.01),
    (0.20, 1.50) => (7.62, 1.07),

    # ── ta/tb = 0.40 ──
    (0.40, 1.05) => (4.38, 0.55),
    (0.40, 1.10) => (4.79, 0.60),
    (0.40, 1.15) => (5.22, 0.65),
    (0.40, 1.20) => (5.67, 0.70),
    (0.40, 1.25) => (6.15, 0.74),
    (0.40, 1.30) => (6.65, 0.79),
    (0.40, 1.35) => (7.18, 0.83),
    (0.40, 1.40) => (7.74, 0.87),
    (0.40, 1.45) => (8.32, 0.91),
    (0.40, 1.50) => (8.94, 0.94),

    # ── ta/tb = 0.60 ──
    (0.60, 1.05) => (4.44, 0.55),
    (0.60, 1.10) => (4.91, 0.59),
    (0.60, 1.15) => (5.42, 0.63),
    (0.60, 1.20) => (5.96, 0.67),
    (0.60, 1.25) => (6.54, 0.70),
    (0.60, 1.30) => (7.15, 0.74),
    (0.60, 1.35) => (7.81, 0.77),
    (0.60, 1.40) => (8.50, 0.80),
    (0.60, 1.45) => (9.23, 0.83),
    (0.60, 1.50) => (10.01, 0.85),

    # ── ta/tb = 0.80 ──
    (0.80, 1.05) => (4.49, 0.54),
    (0.80, 1.10) => (5.01, 0.58),
    (0.80, 1.15) => (5.58, 0.61),
    (0.80, 1.20) => (6.19, 0.64),
    (0.80, 1.25) => (6.85, 0.67),
    (0.80, 1.30) => (7.56, 0.70),
    (0.80, 1.35) => (8.31, 0.72),
    (0.80, 1.40) => (9.12, 0.75),
    (0.80, 1.45) => (9.98, 0.77),
    (0.80, 1.50) => (10.89, 0.79),

    # ── ta/tb = 1.00 ──
    (1.00, 1.05) => (4.52, 0.54),
    (1.00, 1.10) => (5.09, 0.57),
    (1.00, 1.15) => (5.71, 0.60),
    (1.00, 1.20) => (6.38, 0.62),
    (1.00, 1.25) => (7.11, 0.65),
    (1.00, 1.30) => (7.89, 0.67),
    (1.00, 1.35) => (8.73, 0.69),
    (1.00, 1.40) => (9.63, 0.71),
    (1.00, 1.45) => (10.60, 0.73),
    (1.00, 1.50) => (11.62, 0.74),

    # ── ta/tb = 1.20 ──
    (1.20, 1.05) => (4.55, 0.53),
    (1.20, 1.10) => (5.16, 0.56),
    (1.20, 1.15) => (5.82, 0.59),
    (1.20, 1.20) => (6.54, 0.61),
    (1.20, 1.25) => (7.32, 0.63),
    (1.20, 1.30) => (8.17, 0.65),
    (1.20, 1.35) => (9.08, 0.66),
    (1.20, 1.40) => (10.07, 0.68),
    (1.20, 1.45) => (11.12, 0.69),
    (1.20, 1.50) => (12.25, 0.70),

    # ── ta/tb = 1.40 ──
    (1.40, 1.05) => (4.58, 0.53),
    (1.40, 1.10) => (5.21, 0.55),
    (1.40, 1.15) => (5.91, 0.58),
    (1.40, 1.20) => (6.68, 0.60),
    (1.40, 1.25) => (7.51, 0.61),
    (1.40, 1.30) => (8.41, 0.63),
    (1.40, 1.35) => (9.38, 0.64),
    (1.40, 1.40) => (10.43, 0.65),
    (1.40, 1.45) => (11.57, 0.66),
    (1.40, 1.50) => (12.78, 0.67),

    # ── ta/tb = 1.60 ──
    (1.60, 1.05) => (4.60, 0.53),
    (1.60, 1.10) => (5.26, 0.55),
    (1.60, 1.15) => (5.99, 0.57),
    (1.60, 1.20) => (6.79, 0.59),
    (1.60, 1.25) => (7.66, 0.60),
    (1.60, 1.30) => (8.61, 0.61),
    (1.60, 1.35) => (9.64, 0.62),
    (1.60, 1.40) => (10.75, 0.63),
    (1.60, 1.45) => (11.95, 0.64),
    (1.60, 1.50) => (13.24, 0.65),

    # ── ta/tb = 1.80 ──
    (1.80, 1.05) => (4.62, 0.52),
    (1.80, 1.10) => (5.30, 0.55),
    (1.80, 1.15) => (6.06, 0.56),
    (1.80, 1.20) => (6.89, 0.58),
    (1.80, 1.25) => (7.80, 0.59),
    (1.80, 1.30) => (8.79, 0.60),
    (1.80, 1.35) => (9.87, 0.61),
    (1.80, 1.40) => (11.03, 0.61),
    (1.80, 1.45) => (12.29, 0.62),
    (1.80, 1.50) => (13.65, 0.63),

    # ── ta/tb = 2.00 ──
    (2.00, 1.05) => (4.63, 0.52),
    (2.00, 1.10) => (5.34, 0.54),
    (2.00, 1.15) => (6.12, 0.56),
    (2.00, 1.20) => (6.98, 0.57),
    (2.00, 1.25) => (7.92, 0.58),
    (2.00, 1.30) => (8.94, 0.59),
    (2.00, 1.35) => (10.06, 0.59),
    (2.00, 1.40) => (11.27, 0.60),
    (2.00, 1.45) => (12.59, 0.60),
    (2.00, 1.50) => (14.00, 0.61),

    # ── ta/tb = 2.20 ──
    (2.20, 1.05) => (4.65, 0.52),
    (2.20, 1.10) => (5.37, 0.54),
    (2.20, 1.15) => (6.17, 0.55),
    (2.20, 1.20) => (7.05, 0.56),
    (2.20, 1.25) => (8.02, 0.57),
    (2.20, 1.30) => (9.08, 0.58),
    (2.20, 1.35) => (10.24, 0.58),
    (2.20, 1.40) => (11.49, 0.59),
    (2.20, 1.45) => (12.85, 0.59),
    (2.20, 1.50) => (14.31, 0.59),

    # ── ta/tb = 2.40 ──
    (2.40, 1.05) => (4.66, 0.52),
    (2.40, 1.10) => (5.40, 0.53),
    (2.40, 1.15) => (6.22, 0.55),
    (2.40, 1.20) => (7.12, 0.56),
    (2.40, 1.25) => (8.11, 0.56),
    (2.40, 1.30) => (9.20, 0.57),
    (2.40, 1.35) => (10.39, 0.57),
    (2.40, 1.40) => (11.68, 0.58),
    (2.40, 1.45) => (13.08, 0.58),
    (2.40, 1.50) => (14.60, 0.58),

    # ── ta/tb = 2.60 ──
    (2.60, 1.05) => (4.67, 0.52),
    (2.60, 1.10) => (5.42, 0.53),
    (2.60, 1.15) => (6.26, 0.54),
    (2.60, 1.20) => (7.18, 0.55),
    (2.60, 1.25) => (8.20, 0.55),
    (2.60, 1.30) => (9.31, 0.56),
    (2.60, 1.35) => (10.53, 0.56),
    (2.60, 1.40) => (11.86, 0.57),
    (2.60, 1.45) => (13.29, 0.57),
    (2.60, 1.50) => (14.85, 0.57),

    # ── ta/tb = 2.80 ──
    (2.80, 1.05) => (4.68, 0.52),
    (2.80, 1.10) => (5.44, 0.53),
    (2.80, 1.15) => (6.29, 0.54),
    (2.80, 1.20) => (7.23, 0.55),
    (2.80, 1.25) => (8.27, 0.55),
    (2.80, 1.30) => (9.41, 0.55),
    (2.80, 1.35) => (10.66, 0.56),
    (2.80, 1.40) => (12.01, 0.56),
    (2.80, 1.45) => (13.48, 0.56),
    (2.80, 1.50) => (15.07, 0.56),

    # ── ta/tb = 3.00 ──
    (3.00, 1.05) => (4.69, 0.52),
    (3.00, 1.10) => (5.46, 0.53),
    (3.00, 1.15) => (6.33, 0.54),
    (3.00, 1.20) => (7.28, 0.54),
    (3.00, 1.25) => (8.34, 0.55),
    (3.00, 1.30) => (9.50, 0.55),
    (3.00, 1.35) => (10.77, 0.55),
    (3.00, 1.40) => (12.15, 0.55),
    (3.00, 1.45) => (13.65, 0.55),
    (3.00, 1.50) => (15.28, 0.55),

    # ── ta/tb = 3.20 ──
    (3.20, 1.05) => (4.70, 0.52),
    (3.20, 1.10) => (5.48, 0.53),
    (3.20, 1.15) => (6.36, 0.53),
    (3.20, 1.20) => (7.33, 0.54),
    (3.20, 1.25) => (8.40, 0.54),
    (3.20, 1.30) => (9.58, 0.54),
    (3.20, 1.35) => (10.87, 0.54),
    (3.20, 1.40) => (12.28, 0.54),
    (3.20, 1.45) => (13.81, 0.54),
    (3.20, 1.50) => (15.47, 0.54),

    # ── ta/tb = 3.40 ──
    (3.40, 1.05) => (4.71, 0.51),
    (3.40, 1.10) => (5.50, 0.52),
    (3.40, 1.15) => (6.38, 0.53),
    (3.40, 1.20) => (7.37, 0.53),
    (3.40, 1.25) => (8.46, 0.54),
    (3.40, 1.30) => (9.65, 0.54),
    (3.40, 1.35) => (10.97, 0.54),
    (3.40, 1.40) => (12.40, 0.54),
    (3.40, 1.45) => (13.95, 0.53),
    (3.40, 1.50) => (15.64, 0.53),

    # ── ta/tb = 3.60 ──
    (3.60, 1.05) => (4.71, 0.51),
    (3.60, 1.10) => (5.51, 0.52),
    (3.60, 1.15) => (6.41, 0.53),
    (3.60, 1.20) => (7.41, 0.53),
    (3.60, 1.25) => (8.51, 0.53),
    (3.60, 1.30) => (9.72, 0.53),
    (3.60, 1.35) => (11.05, 0.53),
    (3.60, 1.40) => (12.51, 0.53),
    (3.60, 1.45) => (14.09, 0.53),
    (3.60, 1.50) => (15.80, 0.53),

    # ── ta/tb = 3.80 ──
    (3.80, 1.05) => (4.72, 0.51),
    (3.80, 1.10) => (5.53, 0.52),
    (3.80, 1.15) => (6.43, 0.53),
    (3.80, 1.20) => (7.44, 0.53),
    (3.80, 1.25) => (8.56, 0.53),
    (3.80, 1.30) => (9.78, 0.53),
    (3.80, 1.35) => (11.13, 0.53),
    (3.80, 1.40) => (12.60, 0.52),
    (3.80, 1.45) => (14.21, 0.52),
    (3.80, 1.50) => (15.95, 0.52),

    # ── ta/tb = 4.00 ──
    (4.00, 1.05) => (4.72, 0.51),
    (4.00, 1.10) => (5.54, 0.52),
    (4.00, 1.15) => (6.45, 0.52),
    (4.00, 1.20) => (7.47, 0.53),
    (4.00, 1.25) => (8.60, 0.53),
    (4.00, 1.30) => (9.84, 0.53),
    (4.00, 1.35) => (11.21, 0.52),
    (4.00, 1.40) => (12.70, 0.52),
    (4.00, 1.45) => (14.32, 0.52),
    (4.00, 1.50) => (16.08, 0.52),

    # ── ta/tb = 4.20 ──
    (4.20, 1.05) => (4.73, 0.51),
    (4.20, 1.10) => (5.55, 0.52),
    (4.20, 1.15) => (6.47, 0.52),
    (4.20, 1.20) => (7.50, 0.52),
    (4.20, 1.25) => (8.64, 0.52),
    (4.20, 1.30) => (9.90, 0.52),
    (4.20, 1.35) => (11.27, 0.52),
    (4.20, 1.40) => (12.78, 0.51),
    (4.20, 1.45) => (14.42, 0.51),
    (4.20, 1.50) => (16.20, 0.51),

    # ── ta/tb = 4.40 ──
    (4.40, 1.05) => (4.73, 0.51),
    (4.40, 1.10) => (5.56, 0.51),
    (4.40, 1.15) => (6.49, 0.52),
    (4.40, 1.20) => (7.53, 0.52),
    (4.40, 1.25) => (8.68, 0.52),
    (4.40, 1.30) => (9.95, 0.52),
    (4.40, 1.35) => (11.34, 0.51),
    (4.40, 1.40) => (12.86, 0.51),
    (4.40, 1.45) => (14.52, 0.51),
    (4.40, 1.50) => (16.32, 0.50),

    # ── ta/tb = 4.60 ──
    (4.60, 1.05) => (4.74, 0.51),
    (4.60, 1.10) => (5.57, 0.52),
    (4.60, 1.15) => (6.51, 0.52),
    (4.60, 1.20) => (7.55, 0.52),
    (4.60, 1.25) => (8.71, 0.52),
    (4.60, 1.30) => (9.99, 0.51),
    (4.60, 1.35) => (11.40, 0.51),
    (4.60, 1.40) => (12.93, 0.51),
    (4.60, 1.45) => (14.61, 0.50),
    (4.60, 1.50) => (16.43, 0.50),

    # ── ta/tb = 4.80 ──
    (4.80, 1.05) => (4.74, 0.51),
    (4.80, 1.10) => (5.58, 0.51),
    (4.80, 1.15) => (6.53, 0.52),
    (4.80, 1.20) => (7.58, 0.52),
    (4.80, 1.25) => (8.75, 0.52),
    (4.80, 1.30) => (10.03, 0.51),
    (4.80, 1.35) => (11.45, 0.51),
    (4.80, 1.40) => (13.00, 0.50),
    (4.80, 1.45) => (14.69, 0.50),
    (4.80, 1.50) => (16.53, 0.49),

    # ── ta/tb = 5.00 ──
    (5.00, 1.05) => (4.75, 0.51),
    (5.00, 1.10) => (5.59, 0.51),
    (5.00, 1.15) => (6.54, 0.52),
    (5.00, 1.20) => (7.60, 0.52),
    (5.00, 1.25) => (8.78, 0.51),
    (5.00, 1.30) => (10.07, 0.51),
    (5.00, 1.35) => (11.50, 0.51),
    (5.00, 1.40) => (13.07, 0.50),
    (5.00, 1.45) => (14.77, 0.49),
    (5.00, 1.50) => (16.62, 0.49),

    # ── ta/tb = 6.00 ──
    (6.00, 1.05) => (4.76, 0.51),
    (6.00, 1.10) => (5.63, 0.51),
    (6.00, 1.15) => (6.60, 0.51),
    (6.00, 1.20) => (7.69, 0.51),
    (6.00, 1.25) => (8.90, 0.51),
    (6.00, 1.30) => (10.24, 0.50),
    (6.00, 1.35) => (11.72, 0.49),
    (6.00, 1.40) => (13.33, 0.49),
    (6.00, 1.45) => (15.10, 0.48),
    (6.00, 1.50) => (17.02, 0.47),

    # ── ta/tb = 7.00 ──
    (7.00, 1.05) => (4.78, 0.51),
    (7.00, 1.10) => (5.66, 0.51),
    (7.00, 1.15) => (6.65, 0.51),
    (7.00, 1.20) => (7.76, 0.50),
    (7.00, 1.25) => (9.00, 0.50),
    (7.00, 1.30) => (10.37, 0.49),
    (7.00, 1.35) => (11.88, 0.48),
    (7.00, 1.40) => (13.54, 0.48),
    (7.00, 1.45) => (15.35, 0.47),
    (7.00, 1.50) => (17.32, 0.46),

    # ── ta/tb = 8.00 ──
    (8.00, 1.05) => (4.78, 0.51),
    (8.00, 1.10) => (5.68, 0.51),
    (8.00, 1.15) => (6.69, 0.50),
    (8.00, 1.20) => (7.82, 0.50),
    (8.00, 1.25) => (9.07, 0.50),
    (8.00, 1.30) => (10.47, 0.49),
    (8.00, 1.35) => (12.01, 0.48),
    (8.00, 1.40) => (13.70, 0.47),
    (8.00, 1.45) => (15.54, 0.46),
    (8.00, 1.50) => (17.56, 0.45),

    # ── ta/tb = 9.00 ──
    (9.00, 1.05) => (4.79, 0.50),
    (9.00, 1.10) => (5.69, 0.50),
    (9.00, 1.15) => (6.71, 0.50),
    (9.00, 1.20) => (7.86, 0.50),
    (9.00, 1.25) => (9.13, 0.49),
    (9.00, 1.30) => (10.55, 0.49),
    (9.00, 1.35) => (12.11, 0.48),
    (9.00, 1.40) => (13.83, 0.47),
    (9.00, 1.45) => (15.70, 0.46),
    (9.00, 1.50) => (17.74, 0.45),

    # ── ta/tb = 10.00 ──
    (10.00, 1.05) => (4.80, 0.50),
    (10.00, 1.10) => (5.71, 0.50),
    (10.00, 1.15) => (6.74, 0.50),
    (10.00, 1.20) => (7.89, 0.49),
    (10.00, 1.25) => (9.18, 0.49),
    (10.00, 1.30) => (10.61, 0.48),
    (10.00, 1.35) => (12.19, 0.47),
    (10.00, 1.40) => (13.93, 0.46),
    (10.00, 1.45) => (15.83, 0.45),
    (10.00, 1.50) => (17.90, 0.44),
)

"""Row values for ta/tb in Table A7."""
const _TABLE_A7_TA_TB_VALS = [
    0.00, 0.20, 0.40, 0.60, 0.80, 1.00, 1.20, 1.40, 1.60, 1.80,
    2.00, 2.20, 2.40, 2.60, 2.80, 3.00, 3.20, 3.40, 3.60, 3.80,
    4.00, 4.20, 4.40, 4.60, 4.80, 5.00, 6.00, 7.00, 8.00, 9.00, 10.00,
]

"""Column values for H/Hc in Table A7."""
const _TABLE_A7_H_HC_VALS = [1.05, 1.10, 1.15, 1.20, 1.25, 1.30, 1.35, 1.40, 1.45, 1.50]


# =============================================================================
# Bilinear Interpolation
# =============================================================================

"""
    _find_bracket(vals, x) -> (i_lo, i_hi, t)

Find the two adjacent entries in sorted vector `vals` that bracket `x`,
and return the interpolation parameter `t ∈ [0, 1]`.

If `x` is at or below the minimum, returns `(1, 1, 0.0)`.
If `x` is at or above the maximum, returns `(end, end, 0.0)`.
"""
function _find_bracket(vals::Vector{Float64}, x::Float64)
    n = length(vals)
    if x <= vals[1]
        return (1, 1, 0.0)
    elseif x >= vals[n]
        return (n, n, 0.0)
    end
    # Binary search for bracket
    lo = 1
    hi = n
    while hi - lo > 1
        mid = (lo + hi) ÷ 2
        if vals[mid] <= x
            lo = mid
        else
            hi = mid
        end
    end
    t = (x - vals[lo]) / (vals[hi] - vals[lo])
    return (lo, hi, t)
end

"""
    _interp_table_a1(c1_over_l1, c2_over_l2) -> (k_NF, C_NF, m_NF)

Bilinear interpolation of PCA Table A1 (flat plate slab-beam constants).

# Arguments
- `c1_over_l1`: C_N1/l₁ — column dimension parallel to span ÷ span length
- `c2_over_l2`: C_N2/l₂ — column dimension perpendicular to span ÷ transverse width

# Returns
Named tuple `(k, COF, m)`:
- `k`:   stiffness factor  (K_sb = k × E_cs × I_s / l₁)
- `COF`: carry-over factor
- `m`:   fixed-end moment coefficient  (FEM = m × w × l₁²)

# Reference
PCA Notes on ACI 318-11, Table A1, Section C_F1 = C_N1; C_F2 = C_N2.
"""
function _interp_table_a1(c1_over_l1::Float64, c2_over_l2::Float64)
    r1_vals = _TABLE_A1_CN1_VALS
    r2_vals = _TABLE_A1_CN2_VALS

    (i1_lo, i1_hi, t1) = _find_bracket(r1_vals, c1_over_l1)
    (i2_lo, i2_hi, t2) = _find_bracket(r2_vals, c2_over_l2)

    # When c1/l1 = 0.0, the table only has one row (c2/l2 doesn't matter).
    # If both bracket indices for c1/l1 point to the first row (0.0),
    # return the single row value directly.
    if i1_lo == 1 && i1_hi == 1
        return (k = 4.00, COF = 0.50, m = 0.0833)
    end

    # Fetch the four corner values
    r1_lo = r1_vals[i1_lo]
    r1_hi = r1_vals[i1_hi]
    r2_lo = r2_vals[i2_lo]
    r2_hi = r2_vals[i2_hi]

    # Helper to get table entry, handling the c1/l1=0 row
    function _get(r1, r2)
        if r1 == 0.0
            return _TABLE_A1_DATA[(0.00, 0.00)]
        end
        return _TABLE_A1_DATA[(r1, r2)]
    end

    v00 = _get(r1_lo, r2_lo)
    v01 = _get(r1_lo, r2_hi)
    v10 = _get(r1_hi, r2_lo)
    v11 = _get(r1_hi, r2_hi)

    # Bilinear interpolation for each component
    k   = (1-t1)*(1-t2)*v00[1] + (1-t1)*t2*v01[1] + t1*(1-t2)*v10[1] + t1*t2*v11[1]
    COF = (1-t1)*(1-t2)*v00[2] + (1-t1)*t2*v01[2] + t1*(1-t2)*v10[2] + t1*t2*v11[2]
    m   = (1-t1)*(1-t2)*v00[3] + (1-t1)*t2*v01[3] + t1*(1-t2)*v10[3] + t1*t2*v11[3]

    return (k = k, COF = COF, m = m)
end

"""
    _interp_table_a7(ta_over_tb, H_over_Hc) -> (k, COF)

Bilinear interpolation of PCA Table A7 (column stiffness and carry-over).

# Arguments
- `ta_over_tb`: capital depth ratio at top ÷ bottom (0 for flat plates without capitals)
- `H_over_Hc`:  story height ÷ clear column height  (H / (H - h_slab))

# Returns
Named tuple `(k, COF)`:
- `k`:   column stiffness factor  (K_c = k × E_cc × I_c / H)
- `COF`: column carry-over factor

# Reference
PCA Notes on ACI 318-11, Table A7.
"""
function _interp_table_a7(ta_over_tb::Float64, H_over_Hc::Float64)
    r1_vals = _TABLE_A7_TA_TB_VALS
    r2_vals = _TABLE_A7_H_HC_VALS

    (i1_lo, i1_hi, t1) = _find_bracket(r1_vals, ta_over_tb)
    (i2_lo, i2_hi, t2) = _find_bracket(r2_vals, H_over_Hc)

    r1_lo = r1_vals[i1_lo]
    r1_hi = r1_vals[i1_hi]
    r2_lo = r2_vals[i2_lo]
    r2_hi = r2_vals[i2_hi]

    v00 = _TABLE_A7_DATA[(r1_lo, r2_lo)]
    v01 = _TABLE_A7_DATA[(r1_lo, r2_hi)]
    v10 = _TABLE_A7_DATA[(r1_hi, r2_lo)]
    v11 = _TABLE_A7_DATA[(r1_hi, r2_hi)]

    k   = (1-t1)*(1-t2)*v00[1] + (1-t1)*t2*v01[1] + t1*(1-t2)*v10[1] + t1*t2*v11[1]
    COF = (1-t1)*(1-t2)*v00[2] + (1-t1)*t2*v01[2] + t1*(1-t2)*v10[2] + t1*t2*v11[2]

    return (k = k, COF = COF)
end


# =============================================================================
# Public API — Geometry-Aware PCA Factor Lookups
# =============================================================================

"""
    pca_slab_beam_factors(c1, l1, c2, l2) -> (k, COF, m)

Look up PCA Table A1 slab-beam stiffness factors for the given geometry.

Returns geometry-dependent values replacing the old hardcoded constants
`PCA_K_SLAB`, `PCA_COF`, `PCA_M_FACTOR`.

# Arguments
- `c1`: column dimension parallel to span (Length)
- `l1`: span length center-to-center (Length)
- `c2`: column dimension perpendicular to span (Length)
- `l2`: transverse panel width center-to-center (Length)

# Returns
Named tuple `(k, COF, m)`:
- `k`:   stiffness factor  (K_sb = k × E_cs × I_s / l₁)
- `COF`: carry-over factor
- `m`:   FEM coefficient  (FEM = m × w × l₁²)

# ACI 318-11 Reference
§13.7.3 — Slab-beam stiffness properties for equivalent frame analysis.
PCA Notes on ACI 318-11, Table A1 (prismatic flat plate).
"""
function pca_slab_beam_factors(c1, l1, c2, l2)
    c1_over_l1 = ustrip(c1) / ustrip(uconvert(unit(c1), l1))
    c2_over_l2 = ustrip(c2) / ustrip(uconvert(unit(c2), l2))
    return _interp_table_a1(Float64(c1_over_l1), Float64(c2_over_l2))
end

"""
    pca_column_factors(H, h; ta=0.0, tb=0.0) -> (k, COF)

Look up PCA Table A7 column stiffness factors for the given geometry.

Returns geometry-dependent values replacing the old hardcoded constant
`PCA_K_COL`.

# Arguments
- `H`:  story height floor-to-floor (Length)
- `h`:  slab thickness (Length)

# Keyword Arguments
- `ta`: depth of slab/capital at top of column (Length).
        Default: `h/2` (equal slab depth above and below → ta/tb = 1.0).
- `tb`: depth of slab/capital at bottom of column (Length).
        Default: `h/2` (equal slab depth above and below → ta/tb = 1.0).

For flat plates at a typical intermediate floor, `ta = tb = h/2` (equal slab
depths above and below the joint), giving `ta/tb = 1.0`.

# Returns
Named tuple `(k, COF)`:
- `k`:   column stiffness factor  (K_c = k × E_cc × I_c / H)
- `COF`: column carry-over factor

# ACI 318-11 Reference
§13.7.4 — Column stiffness for equivalent frame analysis.
PCA Notes on ACI 318-11, Table A7.
"""
function pca_column_factors(H, h; ta=nothing, tb=nothing)
    Hc = H - h  # clear column height
    H_over_Hc = Float64(ustrip(H) / ustrip(uconvert(unit(H), Hc)))

    # Default: ta = tb = h/2 → ta/tb = 1.0 (typical intermediate floor)
    if isnothing(ta) && isnothing(tb)
        ta_over_tb = 1.0
    elseif isnothing(ta) || isnothing(tb)
        error("Both ta and tb must be provided, or both omitted for default (ta/tb=1.0)")
    else
        # Convert to common unit before ratio (ta/tb may arrive in different units)
        ta_val = Float64(ustrip(u"inch", ta))
        tb_val = Float64(ustrip(u"inch", tb))
        ta_over_tb = tb_val == 0.0 ? 0.0 : ta_val / tb_val
    end

    return _interp_table_a7(ta_over_tb, H_over_Hc)
end

# =============================================================================
# Tables A2–A5 — Non-Prismatic Slab-Beam (Drop Panels)
# =============================================================================
# For slab-beams with drop panels at each column (extent = l₁/6 from each
# column centre).  Four tables for different drop-thickness ratios d/h:
#   A2: d = 0.25h,  A3: d = 0.50h,  A4: d = 0.75h,  A5: d = h
#
# Section: C_F1 = C_N1; C_F2 = C_N2 (equal columns at near and far ends)
#
# Each entry stores (k_NF, C_NF, m_uniform, m_a00, m_a02, m_a04, m_a06, m_a08)
# where m_uniform is the FEM coefficient for full uniform load and
# m_aXX are the FEM coefficients for a patch load of width (b−a)=0.2
# starting at a = 0.0, 0.2, 0.4, 0.6, 0.8 respectively.
#
# Reference: PCA Notes on ACI 318-11, EB712, Appendix 20A, pp. 20-14 to 20-17.
# =============================================================================

"""8-tuple type alias for non-prismatic table entries: (k, COF, m_unif, m_a00, m_a02, m_a04, m_a06, m_a08)."""
const _NP_ENTRY = NTuple{8, Float64}

# ── Table A2: Drop thickness = 0.25h ──
const _TABLE_A2_DATA = Dict{Tuple{Float64,Float64}, _NP_ENTRY}(
    # C_N1/l₁ = 0.00
    (0.00, 0.00) => (4.79, 0.54, 0.0879, 0.0157, 0.0309, 0.0263, 0.0129, 0.0022),
    # C_N1/l₁ = 0.10
    (0.10, 0.00) => (4.79, 0.54, 0.0879, 0.0157, 0.0309, 0.0263, 0.0129, 0.0022),
    (0.10, 0.10) => (4.99, 0.55, 0.0890, 0.0160, 0.0316, 0.0266, 0.0128, 0.0020),
    (0.10, 0.20) => (5.18, 0.56, 0.0901, 0.0163, 0.0322, 0.0270, 0.0127, 0.0019),
    (0.10, 0.30) => (5.37, 0.57, 0.0911, 0.0167, 0.0328, 0.0273, 0.0126, 0.0018),
    # C_N1/l₁ = 0.20
    (0.20, 0.00) => (4.79, 0.54, 0.0879, 0.0157, 0.0309, 0.0263, 0.0129, 0.0022),
    (0.20, 0.10) => (5.17, 0.56, 0.0900, 0.0161, 0.0320, 0.0269, 0.0128, 0.0020),
    (0.20, 0.20) => (5.56, 0.58, 0.0918, 0.0166, 0.0332, 0.0276, 0.0126, 0.0018),
    (0.20, 0.30) => (5.96, 0.60, 0.0936, 0.0171, 0.0344, 0.0282, 0.0124, 0.0016),
    # C_N1/l₁ = 0.30
    (0.30, 0.00) => (4.79, 0.54, 0.0879, 0.0157, 0.0309, 0.0263, 0.0129, 0.0022),
    (0.30, 0.10) => (5.32, 0.57, 0.0905, 0.0161, 0.0323, 0.0272, 0.0128, 0.0021),
    (0.30, 0.20) => (5.90, 0.59, 0.0930, 0.0166, 0.0338, 0.0281, 0.0127, 0.0019),
    (0.30, 0.30) => (6.55, 0.62, 0.0955, 0.0171, 0.0354, 0.0290, 0.0124, 0.0017),
)

# ── Table A3: Drop thickness = 0.50h ──
const _TABLE_A3_DATA = Dict{Tuple{Float64,Float64}, _NP_ENTRY}(
    (0.00, 0.00) => (5.84, 0.59, 0.0926, 0.0164, 0.0335, 0.0279, 0.0128, 0.0020),
    (0.10, 0.00) => (5.84, 0.59, 0.0926, 0.0164, 0.0335, 0.0279, 0.0128, 0.0020),
    (0.10, 0.10) => (6.04, 0.60, 0.0936, 0.0167, 0.0341, 0.0282, 0.0126, 0.0018),
    (0.10, 0.20) => (6.24, 0.61, 0.0940, 0.0170, 0.0347, 0.0285, 0.0125, 0.0017),
    (0.10, 0.30) => (6.43, 0.61, 0.0952, 0.0173, 0.0353, 0.0287, 0.0123, 0.0016),
    (0.20, 0.00) => (5.84, 0.59, 0.0926, 0.0164, 0.0335, 0.0279, 0.0128, 0.0020),
    (0.20, 0.10) => (6.22, 0.61, 0.0942, 0.0168, 0.0346, 0.0285, 0.0126, 0.0018),
    (0.20, 0.20) => (6.62, 0.62, 0.0957, 0.0172, 0.0356, 0.0290, 0.0123, 0.0016),
    (0.20, 0.30) => (7.01, 0.64, 0.0971, 0.0177, 0.0366, 0.0294, 0.0120, 0.0014),
    (0.30, 0.00) => (5.84, 0.59, 0.0926, 0.0164, 0.0335, 0.0279, 0.0128, 0.0020),
    (0.30, 0.10) => (6.37, 0.61, 0.0947, 0.0168, 0.0348, 0.0287, 0.0126, 0.0018),
    (0.30, 0.20) => (6.95, 0.63, 0.0967, 0.0172, 0.0362, 0.0294, 0.0123, 0.0016),
    (0.30, 0.30) => (7.57, 0.65, 0.0986, 0.0177, 0.0375, 0.0300, 0.0119, 0.0014),
)

# ── Table A4: Drop thickness = 0.75h ──
const _TABLE_A4_DATA = Dict{Tuple{Float64,Float64}, _NP_ENTRY}(
    (0.00, 0.00) => (6.92, 0.63, 0.0965, 0.0171, 0.0360, 0.0293, 0.0124, 0.0017),
    (0.10, 0.00) => (6.92, 0.63, 0.0965, 0.0171, 0.0360, 0.0293, 0.0124, 0.0017),
    (0.10, 0.10) => (7.12, 0.64, 0.0972, 0.0174, 0.0365, 0.0295, 0.0122, 0.0016),
    (0.10, 0.20) => (7.31, 0.64, 0.0978, 0.0176, 0.0370, 0.0297, 0.0120, 0.0014),
    (0.10, 0.30) => (7.48, 0.65, 0.0984, 0.0179, 0.0375, 0.0299, 0.0118, 0.0013),
    (0.20, 0.00) => (6.92, 0.63, 0.0965, 0.0171, 0.0360, 0.0293, 0.0124, 0.0017),
    (0.20, 0.10) => (7.12, 0.64, 0.0977, 0.0175, 0.0369, 0.0297, 0.0121, 0.0015),
    (0.20, 0.20) => (7.31, 0.65, 0.0988, 0.0178, 0.0378, 0.0301, 0.0118, 0.0013),
    (0.20, 0.30) => (7.48, 0.67, 0.0999, 0.0182, 0.0386, 0.0304, 0.0115, 0.0011),
    (0.30, 0.00) => (6.92, 0.63, 0.0965, 0.0171, 0.0360, 0.0293, 0.0124, 0.0017),
    (0.30, 0.10) => (7.29, 0.65, 0.0981, 0.0175, 0.0371, 0.0299, 0.0121, 0.0015),
    (0.30, 0.20) => (7.66, 0.66, 0.0996, 0.0179, 0.0383, 0.0304, 0.0117, 0.0013),
    (0.30, 0.30) => (8.02, 0.68, 0.1009, 0.0182, 0.0394, 0.0309, 0.0113, 0.0011),
)

# ── Table A5: Drop thickness = 1.00h ──
const _TABLE_A5_DATA = Dict{Tuple{Float64,Float64}, _NP_ENTRY}(
    (0.00, 0.00) => (7.89, 0.66, 0.0993, 0.0177, 0.0380, 0.0303, 0.0118, 0.0014),
    (0.10, 0.00) => (7.89, 0.66, 0.0993, 0.0177, 0.0380, 0.0303, 0.0118, 0.0014),
    (0.10, 0.10) => (8.07, 0.66, 0.0998, 0.0180, 0.0385, 0.0305, 0.0116, 0.0013),
    (0.10, 0.20) => (8.24, 0.67, 0.1003, 0.0182, 0.0389, 0.0306, 0.0115, 0.0012),
    (0.10, 0.30) => (8.40, 0.67, 0.1007, 0.0183, 0.0393, 0.0307, 0.0113, 0.0011),
    (0.20, 0.00) => (7.89, 0.66, 0.0993, 0.0177, 0.0380, 0.0303, 0.0118, 0.0014),
    (0.20, 0.10) => (8.22, 0.67, 0.1002, 0.0180, 0.0388, 0.0306, 0.0115, 0.0012),
    (0.20, 0.20) => (8.55, 0.68, 0.1010, 0.0183, 0.0395, 0.0309, 0.0112, 0.0011),
    (0.20, 0.30) => (9.87, 0.69, 0.1018, 0.0186, 0.0402, 0.0311, 0.0109, 0.0009),
    (0.30, 0.00) => (7.89, 0.66, 0.0993, 0.0177, 0.0380, 0.0303, 0.0118, 0.0014),
    (0.30, 0.10) => (8.35, 0.67, 0.1005, 0.0181, 0.0390, 0.0307, 0.0115, 0.0012),
    (0.30, 0.20) => (8.82, 0.68, 0.1016, 0.0184, 0.0399, 0.0311, 0.0111, 0.0011),
    (0.30, 0.30) => (9.28, 0.70, 0.1026, 0.0187, 0.0409, 0.0314, 0.0107, 0.0009),
)

"""Row values for C_N1/l₁ in Tables A2–A5."""
const _TABLE_NP_CN1_VALS = [0.00, 0.10, 0.20, 0.30]

"""Sub-row values for C_N2/l₂ in Tables A2–A5."""
const _TABLE_NP_CN2_VALS = [0.00, 0.10, 0.20, 0.30]

"""Drop thickness ratios d/h for Tables A2–A5."""
const _TABLE_NP_DH_VALS = [0.25, 0.50, 0.75, 1.00]

"""Partial-load position values a for the m_NF columns."""
const _TABLE_NP_A_VALS = [0.0, 0.2, 0.4, 0.6, 0.8]

"""Map from d/h ratio to the corresponding table data dict."""
const _TABLE_NP_BY_DH = Dict{Float64, Dict{Tuple{Float64,Float64}, _NP_ENTRY}}(
    0.25 => _TABLE_A2_DATA,
    0.50 => _TABLE_A3_DATA,
    0.75 => _TABLE_A4_DATA,
    1.00 => _TABLE_A5_DATA,
)


"""
    _interp_np_table(table, c1_over_l1, c2_over_l2) -> NTuple{8,Float64}

Bilinear interpolation of a single non-prismatic table (A2, A3, A4, or A5)
at the given (c₁/l₁, c₂/l₂) ratios.
"""
function _interp_np_table(
    table::Dict{Tuple{Float64,Float64}, _NP_ENTRY},
    c1_over_l1::Float64,
    c2_over_l2::Float64,
)
    r1_vals = _TABLE_NP_CN1_VALS
    r2_vals = _TABLE_NP_CN2_VALS

    (i1_lo, i1_hi, t1) = _find_bracket(r1_vals, c1_over_l1)
    (i2_lo, i2_hi, t2) = _find_bracket(r2_vals, c2_over_l2)

    # c1/l1 = 0.0 row: c2/l2 is irrelevant
    if i1_lo == 1 && i1_hi == 1
        return table[(0.00, 0.00)]
    end

    r1_lo = r1_vals[i1_lo]
    r1_hi = r1_vals[i1_hi]
    r2_lo = r2_vals[i2_lo]
    r2_hi = r2_vals[i2_hi]

    _get(r1, r2) = r1 == 0.0 ? table[(0.00, 0.00)] : table[(r1, r2)]

    v00 = _get(r1_lo, r2_lo)
    v01 = _get(r1_lo, r2_hi)
    v10 = _get(r1_hi, r2_lo)
    v11 = _get(r1_hi, r2_hi)

    result = ntuple(8) do j
        (1-t1)*(1-t2)*v00[j] + (1-t1)*t2*v01[j] +
        t1*(1-t2)*v10[j] + t1*t2*v11[j]
    end
    return result
end


"""
    pca_slab_beam_factors_np(c1, l1, c2, l2, h_drop, h_slab) -> NamedTuple

Look up PCA Tables A2–A5 non-prismatic slab-beam factors for a flat slab
with drop panels, interpolating over drop-thickness ratio d/h and column
dimension ratios c₁/l₁, c₂/l₂.

# Arguments
- `c1`: column dimension parallel to span (Length)
- `l1`: span length center-to-center (Length)
- `c2`: column dimension perpendicular to span (Length)
- `l2`: transverse panel width center-to-center (Length)
- `h_drop`: drop panel projection below slab soffit (Length)
- `h_slab`: slab thickness (Length)

# Returns
Named tuple with fields:
- `k`:   stiffness factor  (K_sb = k × E_cs × I_s / l₁)
- `COF`: carry-over factor
- `m_uniform`: FEM coefficient for full uniform load
- `m_patch`:   Vector of 5 FEM coefficients for patch loads at a = 0.0, 0.2, 0.4, 0.6, 0.8
               with (b−a) = 0.2

# ACI 318-11 Reference
§13.7.3 — Slab-beam stiffness properties for equivalent frame analysis.
PCA Notes on ACI 318-11, Tables A2–A5 (non-prismatic slab-beam with drop panels).
"""
function pca_slab_beam_factors_np(c1, l1, c2, l2, h_drop, h_slab)
    c1_over_l1 = Float64(ustrip(c1) / ustrip(uconvert(unit(c1), l1)))
    c2_over_l2 = Float64(ustrip(c2) / ustrip(uconvert(unit(c2), l2)))
    d_over_h   = Float64(ustrip(h_drop) / ustrip(uconvert(unit(h_drop), h_slab)))

    dh_vals = _TABLE_NP_DH_VALS

    # Bracket in d/h dimension
    (id_lo, id_hi, td) = _find_bracket(dh_vals, d_over_h)

    # Interpolate each table at (c1/l1, c2/l2)
    v_lo = _interp_np_table(_TABLE_NP_BY_DH[dh_vals[id_lo]], c1_over_l1, c2_over_l2)
    v_hi = _interp_np_table(_TABLE_NP_BY_DH[dh_vals[id_hi]], c1_over_l1, c2_over_l2)

    # Linear interpolation in d/h
    v = ntuple(8) do j
        (1 - td) * v_lo[j] + td * v_hi[j]
    end

    return (
        k         = v[1],
        COF       = v[2],
        m_uniform = v[3],
        m_patch   = (v[4], v[5], v[6], v[7], v[8]),
    )
end


"""
    pca_np_fem_coefficients(c1, l1, c2, l2, h_drop, h_slab, a_drop) -> (m_uniform, m_near, m_far)

Compute the three FEM coefficients needed for a non-prismatic slab-beam
with drop panels:

    FEM = m_uniform × w_slab × l₂ × l₁²
        + m_near × w_drop × b_drop × l₁²
        + m_far  × w_drop × b_drop × l₁²

The near-end patch starts at a = 0 with width (b−a) = 2×a_drop/l₁.
The far-end patch starts at a = 1 − 2×a_drop/l₁.

Since PCA tables give m_NF for (b−a) = 0.2, we interpolate in `a`
for the actual patch position and scale by the actual (b−a) ratio
relative to 0.2.

# Arguments
- `c1`, `l1`, `c2`, `l2`: column and span dimensions
- `h_drop`: drop panel projection
- `h_slab`: slab thickness
- `a_drop`: drop panel half-extent from column center (Length)

# Returns
Named tuple `(m_uniform, m_near, m_far)`.

# Reference
PCA Notes on ACI 318-11, Tables A2–A5.
"""
function pca_np_fem_coefficients(c1, l1, c2, l2, h_drop, h_slab, a_drop)
    sf = pca_slab_beam_factors_np(c1, l1, c2, l2, h_drop, h_slab)

    # Drop panel extent as fraction of span
    b_a_actual = Float64(2.0 * ustrip(a_drop) / ustrip(uconvert(unit(a_drop), l1)))

    # Near-end patch: starts at a = 0.0
    # Far-end patch: starts at a = 1.0 − b_a_actual
    a_near = 0.0
    a_far  = 1.0 - b_a_actual

    # Interpolate m_NF in the `a` dimension for each patch
    a_vals = _TABLE_NP_A_VALS
    m_vals = collect(sf.m_patch)

    function _interp_m_at_a(a_target::Float64)
        (ia_lo, ia_hi, ta) = _find_bracket(a_vals, a_target)
        return (1 - ta) * m_vals[ia_lo] + ta * m_vals[ia_hi]
    end

    # The tabulated m_NF values are for (b−a) = 0.2.
    # For a different patch width, scale linearly: m ∝ (b−a).
    scale = b_a_actual / 0.2

    m_near = _interp_m_at_a(a_near) * scale
    m_far  = _interp_m_at_a(a_far)  * scale

    return (m_uniform = sf.m_uniform, m_near = m_near, m_far = m_far)
end


export pca_slab_beam_factors, pca_column_factors
export pca_slab_beam_factors_np, pca_np_fem_coefficients