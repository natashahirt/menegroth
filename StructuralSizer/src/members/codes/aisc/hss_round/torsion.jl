# ==============================================================================
# AISC 360-16 - Torsion for Round HSS / Pipe (Section H3)
# ==============================================================================

"""
    torsional_constant_round_hss(D, t)

Torsional constant C for round HSS (AISC H3 User Note).

    C = π(D-t)²t / 2

# Arguments
- `D`: Outside diameter
- `t`: Design wall thickness (0.93 × nominal per B4.2)

# Returns
- `C`: Torsional constant [in³ or mm³]
"""
function torsional_constant_round_hss(D, t)
    return π * (D - t)^2 * t / 2
end

"""
    get_Fcr_torsion(s::HSSRoundSection, mat::Metal; L=nothing)

Critical torsional stress for round HSS per AISC H3.1(a).

Two potential buckling modes (H3-2a, H3-2b) - take the larger value, capped at 0.6Fy:

    Fcr1 = 1.23E / ((L/D) × (D/t)^(5/4))     (H3-2a)
    Fcr2 = 0.60E / (D/t)^(3/2)               (H3-2b)
    Fcr = min(max(Fcr1, Fcr2), 0.6Fy)

# Arguments
- `s`: Round HSS section
- `mat`: Material properties
- `L`: Member length (required for H3-2a). If `nothing`, only H3-2b is used (conservative).

# Notes
- H3-2a depends on L/D (length effect)
- H3-2b is independent of length (local buckling)
- For short members, H3-2a typically governs
- For long members or unknown L, H3-2b is conservative
"""
function get_Fcr_torsion(s::HSSRoundSection, mat::Metal; L=nothing)
    E, Fy = mat.E, mat.Fy
    D = s.OD  # Outside diameter (or s.D depending on your field name)
    t = s.t
    
    Dt = ustrip(D / t)
    
    # H3-2b: Local buckling (length-independent)
    Fcr2 = 0.60 * E / Dt^1.5
    
    if isnothing(L)
        # Conservative: use only H3-2b
        return min(Fcr2, 0.6 * Fy)
    end
    
    # H3-2a: Length-dependent buckling
    LD = ustrip(L / D)
    Fcr1 = 1.23 * E / (LD * Dt^1.25)
    
    # Take larger of the two (both are lower bounds on Fcr)
    Fcr = max(Fcr1, Fcr2)
    
    # Cap at shear yield
    return min(Fcr, 0.6 * Fy)
end

"""
    get_Tn(s::HSSRoundSection, mat::Metal; L=nothing)

Nominal torsional strength for round HSS per AISC H3-1.

    Tn = Fcr × C

# Arguments
- `s`: Round HSS section
- `mat`: Material properties
- `L`: Member length (optional, for more accurate Fcr)

# Returns
- `Tn`: Nominal torsional strength [kip-in or N-mm]
"""
function get_Tn(s::HSSRoundSection, mat::Metal; L=nothing)
    Fcr = get_Fcr_torsion(s, mat; L=L)
    C = torsional_constant_round_hss(s.OD, s.t)
    return Fcr * C
end

"""
    get_ϕTn(s::HSSRoundSection, mat::Metal; L=nothing, ϕ=0.90)

Design torsional strength (LRFD) for round HSS.
"""
get_ϕTn(s::HSSRoundSection, mat::Metal; L=nothing, ϕ=0.90) = ϕ * get_Tn(s, mat; L=L)

# Note: check_combined_torsion_interaction and can_neglect_torsion are defined
# in hss_rect/torsion.jl and apply to both rectangular and round HSS.
