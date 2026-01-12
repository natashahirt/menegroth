# AISC 360 Chapter H - Design of Members for Combined Forces

"""
    check_PM_interaction(Pu, Mu, ϕPn, ϕMn; Pr=Pu, Mr=Mu)

Check combined axial and flexural interaction (AISC H1-1a, H1-1b).
Returns utilization ratio (should be ≤ 1.0 for safe design).

# Arguments
- `Pu`, `Mu`: Required forces
- `ϕPn`, `ϕMn`: Design strengths
- `Pr`, `Mr`: Optional - use if different from Pu/Mu (e.g., for biaxial bending)

# Returns
Utilization ratio. Design is safe if ≤ 1.0.
"""
function check_PM_interaction(Pu, Mu, ϕPn, ϕMn; Pr=Pu, Mr=Mu)
    if Pr / ϕPn >= 0.2
        # H1-1a: When axial force is significant
        util = Pr / ϕPn + 8/9 * (Mr / ϕMn)
    else
        # H1-1b: When axial force is small
        util = Pr / (2 * ϕPn) + Mr / ϕMn
    end
    return util
end

"""
    check_PM_interaction(s::ISymmSection, mat::Metal, Pu, Mu, Lb, Lc; ...)

Convenience wrapper that computes capacities and checks interaction.

# Arguments
- `s`: ISymmSection
- `mat`: Metal material
- `Pu`, `Mu`: Required forces
- `Lb`: Unbraced length for flexure
- `Lc`: Unbraced length for compression
- `axis`: Compression axis (`:weak` or `:strong`)
- `Cb`: Moment gradient factor for flexure
- `ϕ`: Resistance factor (default 0.90)
"""
function check_PM_interaction(s::ISymmSection, mat::Metal, Pu, Mu, Lb, Lc; 
                              axis=:weak, Cb=1.0, ϕ=0.90)
    ϕPn = get_ϕPn(s, mat, Lc; axis=axis, ϕ=ϕ)
    ϕMn = get_ϕMn(s, mat; Lb=Lb, Cb=Cb, ϕ=ϕ)
    return check_PM_interaction(Pu, Mu, ϕPn, ϕMn)
end

"""
    check_PMxMy_interaction(Pu, Mux, Muy, ϕPn, ϕMnx, ϕMny; Pr=Pu, Mrx=Mux, Mry=Muy)

Biaxial bending interaction check (AISC H1-2).
Returns utilization ratio.

# Arguments
- `Pu`, `Mux`, `Muy`: Required forces
- `ϕPn`, `ϕMnx`, `ϕMny`: Design strengths
- `Pr`, `Mrx`, `Mry`: Optional - use if different from Pu/Mux/Muy
"""
function check_PMxMy_interaction(Pu, Mux, Muy, ϕPn, ϕMnx, ϕMny; Pr=Pu, Mrx=Mux, Mry=Muy)
    if Pr / ϕPn >= 0.2
        # H1-2a
        util = Pr / ϕPn + 8/9 * (Mrx / ϕMnx + Mry / ϕMny)
    else
        # H1-2b
        util = Pr / (2 * ϕPn) + Mrx / ϕMnx + Mry / ϕMny
    end
    return util
end

"""
    check_PMxMy_interaction(s::ISymmSection, mat::Metal, Pu, Mux, Muy, Lbx, Lby, Lc; ...)

Convenience wrapper for biaxial bending that computes capacities.

# Arguments
- `s`: ISymmSection
- `mat`: Metal material
- `Pu`, `Mux`, `Muy`: Required forces
- `Lbx`: Unbraced length for strong-axis flexure
- `Lby`: Unbraced length for weak-axis flexure (typically 0 for I-sections)
- `Lc`: Unbraced length for compression
- `axis`: Compression axis (`:weak` or `:strong`)
- `Cb`: Moment gradient factor for strong-axis flexure
- `ϕ`: Resistance factor (default 0.90)

# Note
Weak-axis flexure (My) for I-sections is typically governed by yielding only.
This uses a simplified approach: ϕMny ≈ ϕ * Fy * Zy.
"""
function check_PMxMy_interaction(s::ISymmSection, mat::Metal, Pu, Mux, Muy, Lbx, Lby, Lc;
                                 axis=:weak, Cb=1.0, ϕ=0.90)
    # Strong axis flexure (with LTB)
    ϕMnx = get_ϕMn(s, mat; Lb=Lbx, Cb=Cb, ϕ=ϕ)
    
    # Weak axis flexure (typically yielding only for I-sections)
    # Simplified: no LTB for weak axis, use plastic moment
    Fy = mat.Fy
    ϕMny = ϕ * Fy * s.Zy
    
    # Compression
    ϕPn = get_ϕPn(s, mat, Lc; axis=axis, ϕ=ϕ)
    
    return check_PMxMy_interaction(Pu, Mux, Muy, ϕPn, ϕMnx, ϕMny)
end
