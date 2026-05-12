# AISC 360-16 Appendix 8 - Approximate Second-Order Analysis
# B1/B2 moment amplification factors for beam-columns

"""
    compute_Cm(M1, M2; transverse_loading=false)

Equivalent uniform moment factor `Cm` per AISC 360-16 Appendix 8, Eq. A-8-4
(corpus aisc-360-16, p. 244).

For beam-columns **without** transverse loading between supports:

    Cm = 0.6 - 0.4 (M1 / M2)                                    (Eq. A-8-4)

where `M1` and `M2` are the smaller and larger end moments respectively.
The sign convention from §App.8.2.1.2 is `M1/M2 > 0` for reverse curvature
(both ends bent in the same direction) and `M1/M2 < 0` for single curvature.

For beam-columns **with** transverse loading between supports, Cm may be
determined by analysis or, conservatively, taken as `Cm = 1.0`.

# Arguments
- `M1`: Smaller end moment, signed per the §App.8.2.1.2 convention
        (positive for reverse curvature, negative for single curvature)
- `M2`: Larger end moment (absolute value), must be > 0
- `transverse_loading`: `true` to use the conservative `Cm = 1.0` for members
        with transverse loads between supports

# Notes
- AISC 360-16 Eq. A-8-4 has **no upper or lower bound** on `Cm`. Values can
  range from `Cm = 1.0` (single curvature, M1 = -M2) down to `Cm = 0.2`
  (full reverse curvature, M1 = +M2). The lower values are physically
  beneficial because reverse curvature reduces the destabilizing P-δ effect.
"""
function compute_Cm(M1, M2; transverse_loading::Bool=false)
    if transverse_loading
        return 1.0
    end
    # Guard against M2 = 0 (e.g., pinned-pinned with no end moments).
    if abs(M2) < 1e-10
        return 1.0
    end
    # AISC 360-16 §App.8.2.1.2, Eq. A-8-4 — no clamp; the spec gives Cm directly.
    return 0.6 - 0.4 * (M1 / M2)
end

"""
    compute_Pe1(E, I, Lc1)

Elastic critical buckling strength assuming no lateral translation (AISC A-8-5).

    Pe1 = π²EI / Lc1²

# Arguments
- `E`: Modulus of elasticity [ksi or MPa]
- `I`: Moment of inertia in the plane of bending [in⁴ or mm⁴]
- `Lc1`: Effective length assuming no lateral translation [in or mm]
        Typically equal to the unbraced length L for braced frames.
"""
function compute_Pe1(E, I, Lc1)
    return π^2 * E * I / Lc1^2
end

"""
    compute_B1(Pr, Pe1, Cm; α=1.0)

B1 multiplier for P-δ effects (AISC Appendix 8, Eq. A-8-3).

    B1 = Cm / (1 - α·Pr/Pe1) ≥ 1.0

# Arguments
- `Pr`: Required axial strength (first-order estimate, Pnt + Plt) [kip or N]
- `Pe1`: Elastic critical buckling strength (from `compute_Pe1`) [kip or N]
- `Cm`: Equivalent uniform moment factor (from `compute_Cm`)
- `α`: 1.0 for LRFD, 1.6 for ASD

# Notes
- B1 = 1.0 for members not subject to compression (Pr ≤ 0)
- Returns Inf if the member is unstable (α·Pr/Pe1 ≥ 1.0)
"""
function compute_B1(Pr, Pe1, Cm; α::Float64=1.0)
    # No amplification needed for tension
    if Pr <= 0
        return 1.0
    end
    
    ratio = α * Pr / Pe1
    
    # Check for instability
    if ratio >= 1.0
        return Inf  # Buckling failure
    end
    
    B1 = Cm / (1.0 - ratio)
    return max(B1, 1.0)
end

"""
    compute_B1(Pr, E, I, L, M1, M2; K=1.0, α=1.0, transverse_loading=false)

Convenience function to compute B1 from basic parameters.

# Arguments
- `Pr`: Required axial strength [kip or N]
- `E`: Modulus of elasticity [ksi or MPa]
- `I`: Moment of inertia in plane of bending [in⁴ or mm⁴]
- `L`: Unbraced length [in or mm]
- `M1`: Smaller end moment (signed per curvature convention)
- `M2`: Larger end moment (absolute value)
- `K`: Effective length factor (typically 1.0 for braced)
- `α`: 1.0 for LRFD, 1.6 for ASD
- `transverse_loading`: Whether transverse loads exist between supports
"""
function compute_B1(Pr, E, I, L, M1, M2; K::Float64=1.0, α::Float64=1.0, transverse_loading::Bool=false)
    Lc1 = K * L
    Pe1 = compute_Pe1(E, I, Lc1)
    Cm = compute_Cm(M1, M2; transverse_loading=transverse_loading)
    return compute_B1(Pr, Pe1, Cm; α=α)
end

"""
    compute_RM(Pmf, Pstory)

RM factor for P-Δ effects (AISC A-8-8).

    RM = 1 - 0.15(Pmf/Pstory)

# Arguments
- `Pmf`: Total vertical load in moment frame columns in the story [kip or N]
- `Pstory`: Total vertical load in the story [kip or N]

# Notes
- RM = 0.85 as lower bound for stories with moment frames
- RM = 1.0 for braced frame systems (Pmf = 0)
"""
function compute_RM(Pmf, Pstory)
    if Pstory <= 0
        return 1.0
    end
    return 1.0 - 0.15 * (Pmf / Pstory)
end

"""
    compute_Pe_story(H, L, ΔH, RM)

Elastic critical buckling strength for a story (AISC A-8-7).

    Pe_story = RM · H · L / ΔH

# Arguments
- `H`: Total story shear in direction of translation [kip or N]
- `L`: Story height [in or mm]
- `ΔH`: First-order inter-story drift due to H [in or mm]
- `RM`: RM factor (from `compute_RM`), or use 0.85 for moment frames, 1.0 for braced

# Notes
- H and ΔH must be from consistent loading
- When ΔH varies over the plan, use average weighted by vertical load or maximum
"""
function compute_Pe_story(H, L, ΔH, RM)
    if abs(ΔH) < 1e-10
        return Inf  # No drift → infinite stiffness
    end
    return RM * H * L / ΔH
end

"""
    compute_B2(Pstory, Pe_story; α=1.0)

B2 multiplier for P-Δ effects (AISC Appendix 8, Eq. A-8-6).

    B2 = 1 / (1 - α·Pstory/Pe_story) ≥ 1.0

# Arguments
- `Pstory`: Total vertical load on the story [kip or N]
- `Pe_story`: Elastic critical buckling strength for the story [kip or N]
- `α`: 1.0 for LRFD, 1.6 for ASD

# Notes
- Includes loads in ALL columns (not just LFRS)
- Returns Inf if the story is unstable (α·Pstory/Pe_story ≥ 1.0)
"""
function compute_B2(Pstory, Pe_story; α::Float64=1.0)
    # Check for no sway (braced frames have B2 = 1.0)
    if Pe_story == Inf
        return 1.0
    end
    
    ratio = α * Pstory / Pe_story
    
    # Check for instability
    if ratio >= 1.0
        return Inf  # Story buckling failure
    end
    
    B2 = 1.0 / (1.0 - ratio)
    return max(B2, 1.0)
end

"""
    compute_B2(Pstory, H, L, ΔH; Pmf=0.0, α=1.0)

Convenience function to compute B2 from basic story parameters.

# Arguments
- `Pstory`: Total vertical load on the story [kip or N]
- `H`: Total story shear [kip or N]
- `L`: Story height [in or mm]
- `ΔH`: First-order inter-story drift [in or mm]
- `Pmf`: Total load in moment frame columns (0 for braced frames) [kip or N]
- `α`: 1.0 for LRFD, 1.6 for ASD
"""
function compute_B2(Pstory, H, L, ΔH; Pmf::Float64=0.0, α::Float64=1.0)
    RM = compute_RM(Pmf, Pstory)
    Pe_story = compute_Pe_story(H, L, ΔH, RM)
    return compute_B2(Pstory, Pe_story; α=α)
end

"""
    amplify_moments(Mnt, Mlt, B1, B2)

Compute required second-order moment (AISC A-8-1).

    Mr = B1·Mnt + B2·Mlt

# Arguments
- `Mnt`: First-order moment with structure restrained (no lateral translation)
- `Mlt`: First-order moment due to lateral translation only
- `B1`: P-δ amplification factor
- `B2`: P-Δ amplification factor

# Returns
- `Mr`: Required second-order flexural strength
"""
function amplify_moments(Mnt, Mlt, B1, B2)
    return B1 * Mnt + B2 * Mlt
end

"""
    amplify_axial(Pnt, Plt, B2)

Compute required second-order axial strength (AISC A-8-2).

    Pr = Pnt + B2·Plt

# Arguments
- `Pnt`: First-order axial force with structure restrained
- `Plt`: First-order axial force due to lateral translation only
- `B2`: P-Δ amplification factor

# Returns
- `Pr`: Required second-order axial strength
"""
function amplify_axial(Pnt, Plt, B2)
    return Pnt + B2 * Plt
end

"""
    B2StoryProperties

Container for story-level data needed for B2 calculation (AISC 360 Appendix 8).

# Fields
- `Pstory`: Total vertical load on the story [kip or N]
- `H`: Story shear used to compute drift [kip or N]
- `L`: Story height [in or mm]
- `ΔH`: First-order inter-story drift [in or mm]
- `Pmf`: Total load in moment frame columns [kip or N]
- `RM`: RM factor (computed from Pmf/Pstory)
- `Pe_story`: Elastic critical buckling strength for the story [kip or N]
- `B2`: Computed B2 multiplier
"""
struct B2StoryProperties
    Pstory::Float64
    H::Float64
    L::Float64
    ΔH::Float64
    Pmf::Float64
    RM::Float64
    Pe_story::Float64
    B2::Float64
end

"""
    B2StoryProperties(Pstory, H, L, ΔH; Pmf=0.0, α=1.0)

Construct B2StoryProperties and compute derived values.
"""
function B2StoryProperties(Pstory, H, L, ΔH; Pmf::Float64=0.0, α::Float64=1.0)
    RM = compute_RM(Pmf, Pstory)
    Pe_story = compute_Pe_story(H, L, ΔH, RM)
    B2 = compute_B2(Pstory, Pe_story; α=α)
    return B2StoryProperties(
        Float64(Pstory), Float64(H), Float64(L), Float64(ΔH),
        Float64(Pmf), Float64(RM), Float64(Pe_story), Float64(B2)
    )
end
