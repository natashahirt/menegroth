# AISC 360 Chapter E - Design of Members for Compression

"""
    get_Fe(s::ISymmSection, mat::Metal, L; axis=:weak)

Elastic buckling stress (AISC E3-4, E4-4).
For doubly-symmetric I-sections, weak axis typically governs.

# Arguments
- `L`: Unbraced length (effective length KL, K=1.0 assumed)
- `axis`: `:weak` (y-axis) or `:strong` (x-axis)
"""
function get_Fe(s::ISymmSection, mat::Metal, L; axis=:weak)
    E = mat.E
    r = axis == :weak ? s.ry : s.rx
    KL_r = L / r
    Fe = π^2 * E / KL_r^2
    return Fe
end

"""
    get_Fcr(s::ISymmSection, mat::Metal, L; axis=:weak)

Critical stress for flexural buckling (AISC E3-2, E3-3).

# Arguments
- `L`: Unbraced length
- `axis`: `:weak` (default) or `:strong`
"""
function get_Fcr(s::ISymmSection, mat::Metal, L; axis=:weak)
    E, Fy = mat.E, mat.Fy
    r = axis == :weak ? s.ry : s.rx
    
    # Handle very short members (L ≈ 0) - yielding governs
    KL_r_val = ustrip(L / r)
    if KL_r_val <= 1e-6 || isnan(KL_r_val) || isinf(KL_r_val)
        return Fy
    end
    
    KL_r = L / r
    
    # E3-4: Elastic buckling stress
    Fe = π^2 * E / KL_r^2
    
    # E3-2 or E3-3: Critical stress
    limit = 4.71 * sqrt(E / Fy)
    if KL_r <= limit
        # Inelastic buckling (E3-2)
        # For very short members (Fe >> Fy), 0.658^(Fy/Fe) → 1.0, so Fcr → Fy
        Fe_val = ustrip(Fe)
        if Fe_val > 0 && !isinf(Fe_val)
            Fcr = (0.658^(Fy / Fe)) * Fy
        else
            Fcr = Fy
        end
    else
        # Elastic buckling (E3-3)
        Fcr = 0.877 * Fe
    end
    
    return Fcr
end

"""
    get_Pn(s::ISymmSection, mat::Metal, L; axis=:weak)

Nominal compressive strength (AISC E3-1).
Considers flexural buckling only (torsional buckling typically not critical for W-shapes).

# Arguments
- `L`: Unbraced length (effective length KL, K=1.0 assumed)
- `axis`: `:weak` (default) or `:strong`
"""
function get_Pn(s::ISymmSection, mat::Metal, L; axis=:weak)
    Fcr = get_Fcr(s, mat, L; axis=axis)
    Pn = Fcr * s.A
    return Pn
end

"""
    get_ϕPn(s::ISymmSection, mat::Metal, L; axis=:weak, ϕ=0.90)

Design compressive strength (LRFD).
"""
get_ϕPn(s::ISymmSection, mat::Metal, L; axis=:weak, ϕ=0.90) = ϕ * get_Pn(s, mat, L; axis=axis)
