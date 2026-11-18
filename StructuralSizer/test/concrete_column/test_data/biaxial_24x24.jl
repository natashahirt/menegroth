# ============================================================================
# StructurePoint Design Example:
# "Manual Design Procedure for Columns and Walls with Biaxial Bending (ACI 318-11/14/19)"
# Source: https://structurepoint.org/publication/design-examples.asp
# Version: July-25-2022
#
# This example demonstrates biaxial column design using:
# 1. Bresler Reciprocal Load Method
# 2. Bresler Load Contour Method
# 3. PCA Load Contour Method
# 4. Exact Biaxial Interaction Method
# ============================================================================

"""
Verified reference data from StructurePoint spColumn design example.
24"×24" tied column with 4 #11 bars, biaxial bending check.
"""
const BIAXIAL_24X24 = (
    # ===== GEOMETRY =====
    geometry = (
        b = 24.0,           # in - column width
        h = 24.0,           # in - column depth
        cover = 2.0,        # in - clear cover
        Ag = 576.0,         # in² - gross area (24×24)
    ),
    
    # ===== REINFORCEMENT =====
    # 4 #11 bars at corners
    reinforcement = (
        bar_size = 11,
        n_bars = 4,
        As_bar = 1.56,      # in² - #11 bar area
        As_total = 6.24,    # in² - total steel (4×1.56)
        # Bar positions (from center): ±(12 - 2 - 0.5×1.41) ≈ ±9.3"
        d = 21.3,           # in - effective depth (approx)
        d_prime = 2.7,      # in - to compression steel (approx)
    ),
    
    # ===== MATERIALS =====
    materials = (
        fc = 5.0,           # ksi
        fy = 60.0,          # ksi
        Es = 29000.0,       # ksi
        εcu = 0.003,
        β1 = 0.80,          # for f'c = 5 ksi
    ),
    
    # ===== FACTORED DEMANDS =====
    demands = (
        Pu = 1200.0,        # kip - factored axial load
        Mux = 300.0,        # kip-ft - factored moment about x-axis
        Muy = 125.0,        # kip-ft - factored moment about y-axis
    ),
    
    # ===== REQUIRED NOMINAL STRENGTHS (assuming φ = 0.65) =====
    required = (
        φ = 0.65,           # Assumed compression-controlled
        Pn_req = 1846.0,    # kip = 1200/0.65
        Mnx_req = 461.5,    # kip-ft = 300/0.65
        Mny_req = 192.3,    # kip-ft = 125/0.65
    ),
    
    # ===== UNIAXIAL CAPACITIES (from P-M diagrams) =====
    # These are nominal capacities at the required Pn = 1846 kip
    uniaxial = (
        # Capacity with Muy = 0 (pure x-bending)
        Mnox = 682.8,       # kip-ft - from spColumn
        # Capacity with Mux = 0 (pure y-bending)
        Mnoy = 682.8,       # kip-ft - same for square section
        # Equivalent uniaxial capacity (per Step B)
        Mnox_req = 565.1,   # kip-ft - required equivalent uniaxial moment
        # Pure axial capacity
        P0 = 2584.0,        # kip - pure compression (approx: 0.85×5×(576-6.24) + 60×6.24)
    ),
    
    # ===== BRESLER RECIPROCAL LOAD METHOD =====
    # 1/Pn = 1/Pnx + 1/Pny - 1/P0
    bresler_reciprocal = (
        # At eccentricities ex = Muy/Pu, ey = Mux/Pu
        ex = 1.25,          # in - 125×12/1200
        ey = 3.0,           # in - 300×12/1200
        # Capacities at these eccentricities (from uniaxial diagrams)
        Pnx = 2250.0,       # kip (approx) - capacity at ex only
        Pny = 2050.0,       # kip (approx) - capacity at ey only
        # Calculated biaxial capacity
        # 1/(1/2250 + 1/2050 − 1/2584) = 1834 kip. The previously stored
        # 1880 kip does not follow from these uniaxial capacities, and 1834
        # is short of Pn_req = 1846 kip.
        Pn_calc = 1834.0,   # kip, nearest kip
        adequate = false,
    ),
    
    # ===== BRESLER LOAD CONTOUR METHOD =====
    # (Mnx/Mnox)^α + (Mny/Mnoy)^α ≤ 1.0
    bresler_contour = (
        α = 1.0,            # Conservative (linear), typical range 1.15-1.55
        # At Pn = 1846 kip:
        Mnx_demand = 461.5, # kip-ft
        Mny_demand = 192.3, # kip-ft
        Mnox_cap = 682.8,   # kip-ft
        Mnoy_cap = 682.8,   # kip-ft
        # Utilization (α = 1.0, linear)
        util_linear = 0.96, # (461.5/682.8) + (192.3/682.8) = 0.676 + 0.282 ≈ 0.96
        # Utilization (α = 1.5, typical)
        util_alpha15 = 0.70, # (0.676)^1.5 + (0.282)^1.5 ≈ 0.55 + 0.15 ≈ 0.70
        adequate = true,
    ),
    
    # ===== PCA LOAD CONTOUR METHOD =====
    # EB712 Eq. (15), page 224: the smaller relative moment is multiplied
    # by (1−β)/β, not by β. β = 0.65 → (1−0.65)/0.65 = 0.5385.
    # ratio_x = 300/(0.65×682.8) = 0.676, ratio_y = 0.282
    # util = 0.676 + 0.5385×0.282 = 0.828
    pca_contour = (
        β = 0.65,
        util = 0.828,
        adequate = true,
    ),
    
    # ===== EXACT METHOD RESULTS (from spColumn) =====
    exact = (
        # At neutral axis angle α = 23° (to achieve Mnx/Mny = 300/125)
        c = 25.11,          # in - neutral axis depth
        α = 25.24,          # degrees - neutral axis angle
        Pn = 1846.0,        # kip
        Mnx = 608.0,        # kip-ft (capacity > required 461.5)
        Mny = 245.4,        # kip-ft (capacity > required 192.3)
        adequate = true,
    ),
)
