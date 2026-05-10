# ==============================================================================
# ACI 318-11 Slenderness Effects (Moment Magnification)
# ==============================================================================
# Reference: ACI 318-11 Chapter 10
# Verified against StructurePoint spColumn Design Examples:
# - "Slender Column Design in Non-Sway Frame - Moment Magnification Method"
# - "Slenderness Effects for Concrete Columns in Sway Frame"
#
# Uses unified material utilities from aci_material_utils.jl

using Unitful
using Asap: to_inches, to_sqinches, ksi

# ==============================================================================
# Slenderness Check
# ==============================================================================

# ------------------------------------------------------------------------------
# Per-axis property helpers (rectangular sections)
# ------------------------------------------------------------------------------
# ACI 318-11 §10.10 evaluates slenderness in the *plane of bending*. For a
# rectangular column that means:
#   strong axis (bending about x):  dim = h, r = 0.3·h, k = kx,  Ig = b·h³/12
#   weak axis   (bending about y):  dim = b, r = 0.3·b, k = ky,  Ig = h·b³/12
# These tiny helpers keep the per-axis branch in one place so every downstream
# slenderness function reads the right number for the axis it was called with.

"Section dimension (in.) parallel to the bending plane (i.e. the depth used by ACI for r ≈ 0.3·dim)."
_axis_dim(section::RCColumnSection, ::StrongAxis) = to_inches(section.h)
_axis_dim(section::RCColumnSection, ::WeakAxis)   = to_inches(section.b)

"Effective length factor for the requested axis."
_axis_k(geometry, ::StrongAxis) = geometry.kx
_axis_k(geometry, ::WeakAxis)   = geometry.ky

"Gross moment of inertia (in⁴) about the requested bending axis."
function _axis_Ig(section::RCColumnSection, ::StrongAxis)
    b = to_inches(section.b); h = to_inches(section.h)
    return b * h^3 / 12
end
function _axis_Ig(section::RCColumnSection, ::WeakAxis)
    b = to_inches(section.b); h = to_inches(section.h)
    return h * b^3 / 12
end

"""
    slenderness_ratio(section, geometry, axis=StrongAxis()) -> Float64

Slenderness ratio `k·Lu/r` per ACI 318-11 §10.10.1, evaluated in the plane of
`axis` (`StrongAxis()` = bending about x, `WeakAxis()` = bending about y).
"""
function slenderness_ratio(section::RCColumnSection, geometry,
                           axis::BendingAxis = StrongAxis())
    # ACI §10.10.1.2: r ≈ 0.3·(section dimension in plane of bending).
    r = 0.3 * _axis_dim(section, axis)
    Lu = to_inches(geometry.Lu)
    return _axis_k(geometry, axis) * Lu / r
end

"""
    should_consider_slenderness(section, geometry, axis=StrongAxis(); M1=0.0, M2=1.0) -> Bool

Check whether slenderness effects govern per ACI 318-19 §6.2.5.1
(historically ACI 318-11 §10.10.1, but the M1/M2 sign convention was
updated in 318-19 to match AISC 360 — see commentary R6.2.5).

# Arguments
- `section`: RC column section
- `geometry`: Column geometry with `Lu`, `kx`, `ky`, `braced`
- `axis`: Bending axis (`StrongAxis()` default, `WeakAxis()` for weak-axis check)
- `M1`: Smaller factored end moment (kip-ft, |M1| ≤ |M2|)
- `M2`: Larger factored end moment (kip-ft)

# Sign convention (ACI 318-19 / AISC 360-16)
`M1/M2 > 0` ⇔ **double** curvature (best case),
`M1/M2 < 0` ⇔ **single** curvature (worst case).

# ACI 318-19 limits
- Non-sway (braced):  k·Lu/r ≤ 34 + 12·(M1/M2), capped at 40   (Eq. 6.2.5.1b/c)
- Sway (unbraced):    k·Lu/r ≤ 22                              (Eq. 6.2.5.1a)
"""
function should_consider_slenderness(
    section::RCColumnSection,
    geometry,
    axis::BendingAxis = StrongAxis();
    M1::Real = 0.0,
    M2::Real = 1.0,
)
    λ = slenderness_ratio(section, geometry, axis)

    if geometry.braced
        # ACI 318-19 §6.2.5.1(b), Eq. (6.2.5.1b)+(6.2.5.1c). Single curvature
        # (M1/M2 < 0) gives the *smaller* limit (more conservative); double
        # curvature (M1/M2 > 0) gives the *larger* limit (up to 40).
        M_ratio = M2 ≈ 0 ? 0.0 : M1 / M2
        limit = min(34 + 12 * M_ratio, 40)
        return λ > limit
    else
        # ACI 318-19 §6.2.5.1(a)
        return λ > 22
    end
end

# ==============================================================================
# Effective Stiffness (EI)_eff
# ==============================================================================

"""
    effective_stiffness(section, mat, axis=StrongAxis(); βdns=0.6, method=:accurate) -> Float64

Effective flexural stiffness `(EI)_eff` per ACI 318-11 §10.10.6.1, computed in
the plane of `axis`. For a rectangular column the gross moment of inertia and
the steel inertia about that axis differ between strong and weak directions:

* Strong (bending about x):  `Ig = b·h³/12`,  `Ise` summed about y = h/2
* Weak   (bending about y):  `Ig = h·b³/12`,  `Ise` summed about x = b/2

# Arguments
- `section`: RC column section
- `mat`: Material properties (fc, fy, Es)
- `axis`: Bending axis (`StrongAxis()` default, `WeakAxis()` available)
- `βdns`: Ratio of sustained to total factored axial load (default 0.6)
- `method`: `:accurate` (includes steel) or `:simplified` (0.4·Ec·Ig)

# Methods (ACI §10.10.6.1)
- `:accurate` (b):   (EI)_eff = (0.2·Ec·Ig + Es·Ise) / (1 + βdns)
- `:simplified` (a): (EI)_eff = 0.4·Ec·Ig / (1 + βdns)

spColumn uses the `:accurate` method.
"""
function effective_stiffness(
    section::RCColumnSection,
    mat,
    axis::BendingAxis = StrongAxis();
    βdns::Real = 0.6,
    method::Symbol = :accurate,
)
    Es = Es_ksi(mat)
    Ec = Ec_ksi(mat)

    Ig = _axis_Ig(section, axis)

    if method == :accurate
        # Method (b): includes the reinforcement's contribution about the axis.
        Ise = _calc_Ise(section, axis)
        return (0.2 * Ec * Ig + Es * Ise) / (1 + βdns)
    else
        # Method (a): gross-only.
        return 0.4 * Ec * Ig / (1 + βdns)
    end
end

"""
    _calc_Ise(section::RCColumnSection, axis=StrongAxis()) -> Float64

Moment of inertia of longitudinal reinforcement about the section centroid for
the requested bending `axis` (in⁴). Parallel-axis theorem only — each bar's
own inertia is negligible at typical bar diameters.

For strong-axis bending (about x) the lever arm is `bar.y − h/2`; for weak-axis
bending (about y) it is `bar.x − b/2`.
"""
function _calc_Ise(section::RCColumnSection, axis::BendingAxis = StrongAxis())
    h = to_inches(section.h)
    b = to_inches(section.b)
    cy, cx = h / 2, b / 2  # geometric centroid

    Ise = 0.0
    for bar in section.bars
        As = to_sqinches(bar.As)
        d = if axis isa StrongAxis
            to_inches(bar.y) - cy
        else
            to_inches(bar.x) - cx
        end
        Ise += As * d^2
    end
    return Ise
end

# ==============================================================================
# Critical Buckling Load
# ==============================================================================

"""
    critical_buckling_load(section, mat, geometry, axis=StrongAxis(); βdns=0.6) -> Float64

Euler critical buckling load `Pc = π²·(EI)_eff / (k·Lu)²` per ACI 318-11
§10.10.6.1, evaluated in the plane of `axis`. Both `(EI)_eff` and `k` are
axis-specific (`kx`, `ky`); for a non-square rectangular column `Pc` differs
between strong and weak axes.

Returns Pc in kip.
"""
function critical_buckling_load(
    section::RCColumnSection,
    mat,
    geometry,
    axis::BendingAxis = StrongAxis();
    βdns::Real = 0.6,
)
    EI_eff = effective_stiffness(section, mat, axis; βdns=βdns)
    Lu = to_inches(geometry.Lu)
    kLu = _axis_k(geometry, axis) * Lu
    return π^2 * EI_eff / kLu^2  # kip
end

# ==============================================================================
# Moment Magnification - Non-Sway Frame
# ==============================================================================

"""
    magnification_factor_nonsway(Pu, Pc; Cm::Real=1.0) -> Float64

Calculate moment magnification factor δns for non-sway frames.
Per ACI 318-11 §10.10.6.3.

δns = Cm / (1 - Pu/(0.75*Pc)) ≥ 1.0

# Arguments
- `Pu`: Factored axial load (kip)
- `Pc`: Critical buckling load (kip)
- `Cm`: Equivalent uniform moment factor (default 1.0)

# Returns
- Magnification factor δns ≥ 1.0
"""
function magnification_factor_nonsway(Pu::Real, Pc::Real; Cm::Real = 1.0)
    if Pu ≥ 0.75 * Pc
        # Section is unstable
        return Inf
    end
    
    δns = Cm / (1 - Pu / (0.75 * Pc))
    return max(δns, 1.0)
end

"""
    calc_Cm(M1::Real, M2::Real; transverse_load::Bool=false) -> Float64

Equivalent uniform moment factor `Cm` per ACI 318-19 §6.6.4.5.3
(Eq. 6.6.4.5.3a, historically ACI 318-11 §10.10.6.4 / AISC 360-16 §C2.1b).

`Cm = 0.6 − 0.4·(M1/M2)` if there are no transverse loads on the member
between supports; otherwise `Cm = 1.0`. ACI does not impose an explicit
floor on `Cm`, but `Cm ≥ 0.4` is the long-standing AISC/ACI convention
adopted here to avoid spurious negatives when `M1/M2 → +1`.

# Arguments
- `M1`: Smaller factored end moment (kip-ft, |M1| ≤ |M2|)
- `M2`: Larger factored end moment (kip-ft)
- `transverse_load`: True if transverse loads act between supports

# Sign convention (ACI 318-19 / AISC 360-16)
`M1/M2 > 0` ⇔ **double** curvature (best case → low Cm),
`M1/M2 < 0` ⇔ **single** curvature (worst case → high Cm).

# Returns
- `Cm` factor (dimensionless)
"""
function calc_Cm(M1::Real, M2::Real; transverse_load::Bool = false)
    if transverse_load
        return 1.0
    end

    if abs(M2) < 1e-6
        return 1.0
    end

    # ACI 318-19 Eq. (6.6.4.5.3a). Sign convention: M1/M2 > 0 = double curvature.
    M_ratio = M1 / M2
    Cm = 0.6 - 0.4 * M_ratio
    return max(Cm, 0.4)
end

"""
    minimum_moment(Pu::Real, h_in::Real) -> Float64

Calculate minimum design moment per ACI 318-11 §10.10.6.5.

M_min = Pu * (0.6 + 0.03h)

# Arguments
- `Pu`: Factored axial load (kip)
- `h_in`: Section dimension in direction of bending (in)

# Returns
- Minimum moment (kip-ft)
"""
function minimum_moment(Pu::Real, h::Real)
    # M_min = Pu × (0.6" + 0.03×h) per ACI §10.10.6.5
    # Pu in kip, h in inches → result in kip-in, converted to kip-ft
    return Pu * (0.6 + 0.03 * h) / 12
end

"""
    magnify_moment_nonsway(section, mat, geometry, Pu, M1, M2, axis=StrongAxis();
                           βdns=0.6, transverse_load=false) -> NamedTuple

Magnified design moment for a non-sway-frame column per ACI 318-11 §10.10.6,
evaluated in the plane of `axis`. For non-square rectangular columns the
weak-axis path uses the column's `b` (not `h`), `Ig = h·b³/12`, and `ky` from
the geometry, so a column non-slender about its strong axis can still amplify
about its weak axis.

# Arguments
- `section`: RC column section
- `mat`: Material properties
- `geometry`: Column geometry (`Lu`, `kx`, `ky`, `braced=true`)
- `Pu`: Factored axial load (kip)
- `M1`: Smaller factored end moment (kip-ft; |M1| ≤ |M2|). ACI 318-19 sign
  convention: `M1/M2 > 0` ⇔ **double** curvature, `M1/M2 < 0` ⇔ single
  curvature.
- `M2`: Larger factored end moment (kip-ft)
- `axis`: Bending axis to evaluate (`StrongAxis()` default, `WeakAxis()` available)
- `βdns`: Sustained load ratio (default 0.6)
- `transverse_load`: Whether transverse loads act between supports
  (ACI 318-19 §6.6.4.5.3 forces `Cm = 1.0`)

# Returns
NamedTuple with:
- `Mc`:      magnified design moment (kip-ft)
- `δns`:     non-sway magnification factor
- `Cm`:      equivalent uniform moment factor
- `Pc`:      critical buckling load (kip)
- `slender`: whether slenderness governed

# Reference
StructurePoint: "Slender Column Design in Non-Sway Frame".
"""
function magnify_moment_nonsway(
    section::RCColumnSection,
    mat,
    geometry,
    Pu::Real,
    M1::Real,
    M2::Real,
    axis::BendingAxis = StrongAxis();
    βdns::Real = 0.6,
    transverse_load::Bool = false,
)
    slender = should_consider_slenderness(section, geometry, axis; M1=M1, M2=M2)

    # M_min applies only inside the slenderness procedure per ACI 318-19
    # §6.6.4.5.4 (historically ACI 318-11 §10.10.6.5). When the slenderness
    # check does not trigger amplification we return |M2| unmodified — the
    # eccentricity floor is *not* a generic minimum on column moments, only a
    # check against the magnified moment when slenderness governs.
    if !slender
        return (Mc=abs(M2), δns=1.0, Cm=1.0, Pc=Inf, slender=false)
    end

    h_axis = _axis_dim(section, axis)
    Pc  = critical_buckling_load(section, mat, geometry, axis; βdns=βdns)
    Cm  = calc_Cm(M1, M2; transverse_load=transverse_load)
    δns = magnification_factor_nonsway(Pu, Pc; Cm=Cm)

    # ACI 318-19 §6.6.4.5.4 — minimum eccentricity check (M_min = Pu·(15+0.03·h) mm
    # in SI; here Pu·(0.6+0.03·h)/12 in kip·ft for h in inches).
    M_min = minimum_moment(Pu, h_axis)
    Mc = max(δns * abs(M2), M_min)

    return (Mc=Mc, δns=δns, Cm=Cm, Pc=Pc, slender=true)
end

# ==============================================================================
# Moment Magnification - Sway Frame
# ==============================================================================

"""
    magnification_factor_sway(ΣPu, ΣPc) -> Float64

Calculate sway magnification factor δs for sway frames.
Per ACI 318-11 §10.10.7.3.

δs = 1 / (1 - ΣPu/(0.75*ΣPc)) ≥ 1.0

# Arguments
- `ΣPu`: Sum of factored axial loads in story (kip)
- `ΣPc`: Sum of critical loads for all columns in story (kip)

# Returns
- Sway magnification factor δs
"""
function magnification_factor_sway(ΣPu::Real, ΣPc::Real)
    if ΣPu ≥ 0.75 * ΣPc
        return Inf  # Story is unstable
    end
    
    δs = 1 / (1 - ΣPu / (0.75 * ΣPc))
    return max(δs, 1.0)
end

"""
    magnify_moment_sway(M1ns, M2ns, M1s, M2s, δs) -> NamedTuple

Calculate magnified design moments for sway frame column.
Per ACI 318-11 §10.10.7.1.

# Arguments
- `M1ns, M2ns`: Non-sway moments at ends (kip-ft)
- `M1s, M2s`: Sway moments at ends (kip-ft)
- `δs`: Sway magnification factor

# Returns
NamedTuple with:
- `M1`: Magnified moment at end 1 (kip-ft)
- `M2`: Magnified moment at end 2 (kip-ft)
"""
function magnify_moment_sway(
    M1ns::Real, M2ns::Real,
    M1s::Real, M2s::Real,
    δs::Real
)
    M1 = M1ns + δs * M1s
    M2 = M2ns + δs * M2s
    return (M1=M1, M2=M2)
end

# ==============================================================================
# Complete Sway Frame Magnification (Per StructurePoint Examples)
# ==============================================================================
# Reference: StructurePoint "Slender Concrete Column Design in Sway Frames -
# Moment Magnification Method (ACI 318-11)" and "Slenderness Effects for
# Concrete Columns in Sway Frame - Moment Magnification Method (ACI 318-11)"
#
# For sway frames, the complete procedure involves:
# 1. Story stability check (Q index)
# 2. Sway magnification δs at column ends
# 3. Additional slenderness check along column length (δns on magnified moments)
# ==============================================================================

"""
    SwayStoryProperties

Properties of a story for sway frame analysis per ACI 318-11 §10.10.

# Fields
- `ΣPu`: Total factored vertical load in story (kip)
- `ΣPc`: Sum of critical buckling loads for all sway columns (kip)
- `Vus`: Factored horizontal story shear (kip)
- `Δo`: First-order relative story drift (in)
- `lc`: Story height from center-to-center of joints (in)
"""
struct SwayStoryProperties
    ΣPu::Float64
    ΣPc::Float64
    Vus::Float64
    Δo::Float64
    lc::Float64
end

"""
    stability_index(story::SwayStoryProperties) -> Float64

Calculate story stability index Q per ACI 318-11 §10.10.5.2.

Q = (ΣPu × Δo) / (Vus × lc)

# Returns
- Q: Stability index (Q > 0.05 indicates sway frame)

# Reference
ACI 318-11 §10.10.5.2: Story is sway if Q > 0.05
"""
function stability_index(story::SwayStoryProperties)
    if story.Vus ≈ 0 || story.lc ≈ 0
        return Inf  # Undefined without lateral load
    end
    return (story.ΣPu * story.Δo) / (story.Vus * story.lc)
end

"""
    is_sway_frame(story::SwayStoryProperties) -> Bool

Determine if story is a sway frame per ACI 318-11 §10.10.5.2.

A story is sway if Q > 0.05.
"""
function is_sway_frame(story::SwayStoryProperties)
    Q = stability_index(story)
    return Q > 0.05
end

"""
    magnification_factor_sway_Q(Q::Real) -> Float64

Calculate sway magnification factor δs using stability index Q method.
Per ACI 318-11 §10.10.7.3(a).

δs = 1 / (1 - Q) ≥ 1.0

This method requires stability index Q from drift analysis.
Valid when δs ≤ 1.5; if δs > 1.5, use second-order analysis.

# Arguments
- `Q`: Story stability index

# Returns
- δs: Sway magnification factor
"""
function magnification_factor_sway_Q(Q::Real)
    if Q ≥ 1.0
        return Inf  # Story is unstable
    end
    
    δs = 1 / (1 - Q)
    
    if δs > 1.5
        @debug "δs = $δs > 1.5 (Q-method); second-order analysis recommended (ACI 318-11 §10.10.7.3)"
    end
    
    return max(δs, 1.0)
end

"""
    effective_stiffness_sway(section, mat; βds::Real=0.0, method::Symbol=:accurate) -> Float64

Calculate effective flexural stiffness (EI)eff for sway frames.
Per ACI 318-11 §10.10.6.1.

# Arguments
- `section`: RC column section
- `mat`: Material properties
- `βds`: Ratio of max sustained shear to max shear in story (typically 0 for wind)
- `method`: `:accurate` (includes steel) or `:simplified`

# Returns
- (EI)eff in kip-in²

# Notes
- For sway frames, βds (not βdns) is used in the denominator
- βds = 0 for pure lateral loads (wind, seismic)
- βds = ratio of sustained lateral load to total lateral load

# Reference
StructurePoint: "Slender Concrete Column Design in Sway Frames"
"""
function effective_stiffness_sway(
    section::RCColumnSection, 
    mat;
    βds::Real = 0.0,
    method::Symbol = :accurate
)
    fc = fc_ksi(mat)
    Es = Es_ksi(mat)
    Ec = Ec_ksi(mat)
    
    # Section dimensions (inches) for Ig calculation
    b = to_inches(section.b)
    h = to_inches(section.h)
    Ig = b * h^3 / 12  # in⁴
    
    if method == :accurate
        Ise = _calc_Ise(section)
        EI_eff = (0.2 * Ec * Ig + Es * Ise) / (1 + βds)
    else
        EI_eff = 0.4 * Ec * Ig / (1 + βds)
    end
    
    return EI_eff
end

"""
    critical_buckling_load_sway(section, mat, geometry; βds::Real=0.0) -> Float64

Calculate critical buckling load Pc for sway frame columns.
Per ACI 318-11 §10.10.6.1.

# Arguments
- `section`: RC column section
- `mat`: Material properties  
- `geometry`: Column geometry with Lu, k (k should be sway k ≥ 1.0)
- `βds`: Sustained shear ratio (default 0.0 for wind/seismic)

# Returns
- Pc: Critical buckling load (kip)

# Notes
- For sway frames, use k ≥ 1.0 from alignment charts
- The effective length factor k for sway frames is typically 1.2 to 2.0
"""
function critical_buckling_load_sway(
    section::RCColumnSection,
    mat,
    geometry,
    axis::BendingAxis = StrongAxis();
    βds::Real = 0.0,
)
    EI_eff = effective_stiffness_sway(section, mat; βds=βds)

    Lu = to_inches(geometry.Lu)
    # ACI 318-11 §10.10.7: sway k is taken in the plane of sidesway, so per-axis
    # k_x / k_y matters here just as it does for the non-sway path.
    kLu = _axis_k(geometry, axis) * Lu

    return π^2 * EI_eff / kLu^2  # kip
end

"""
    magnify_moment_sway_complete(
        section, mat, geometry,
        Pu, M1ns, M2ns, M1s, M2s;
        story::Union{Nothing, SwayStoryProperties}=nothing,
        βds::Real=0.0, βdns::Real=0.6,
        transverse_load::Bool=false
    ) -> NamedTuple

Complete sway frame moment magnification per ACI 318-11 §10.10.6 and §10.10.7.

This implements the full procedure from StructurePoint design examples:
1. Calculate δs (sway magnification at column ends)
2. Magnify sway moments: M = Mns + δs × Ms
3. Check slenderness along column length (additional δns magnification)

# Arguments
- `section`: RC column section
- `mat`: Material properties
- `geometry`: Column geometry (Lu, k for sway frame, braced=false)
- `Pu`: Factored axial load (kip)
- `M1ns, M2ns`: Non-sway moments at ends 1 and 2 (kip-ft)
- `M1s, M2s`: Sway moments at ends 1 and 2 (kip-ft)
- `story`: Story properties for δs calculation (optional, uses ΣPu/ΣPc if provided)
- `βds`: Sustained shear ratio for sway stiffness (default 0.0 for wind)
- `βdns`: Sustained load ratio for non-sway stiffness (default 0.6)
- `transverse_load`: Whether transverse loads exist between supports

# Returns
NamedTuple with:
- `M1`: Final magnified moment at end 1 (kip-ft)
- `M2`: Final magnified moment at end 2 (kip-ft)
- `Mc`: Design moment (max of M1, M2, and slenderness check) (kip-ft)
- `δs`: Sway magnification factor
- `δns`: Non-sway magnification factor (for along-length check)
- `Q`: Stability index (if story provided)
- `sway_magnified`: Whether sway magnification was applied
- `length_magnified`: Whether along-length magnification was applied

# Reference
StructurePoint: "Slender Concrete Column Design in Sway Frames - Moment 
Magnification Method (ACI 318-11)"
"""
function magnify_moment_sway_complete(
    section::RCColumnSection,
    mat,
    geometry,
    Pu::Real,
    M1ns::Real, M2ns::Real,
    M1s::Real, M2s::Real;
    story::Union{Nothing, SwayStoryProperties} = nothing,
    βds::Real = 0.0,
    βdns::Real = 0.6,
    transverse_load::Bool = false
)
    # Section height (inches) for minimum moment and radius of gyration
    h = to_inches(section.h)
    
    # =========================================================================
    # Step 1: Calculate δs (sway magnification at ends)
    # Per ACI 318-11 §10.10.7.3
    # =========================================================================
    Q = NaN
    
    δs_method = :none

    if !isnothing(story)
        # Method (a): Use Q index (ACI 318-11 §10.10.7.3(a))
        Q = stability_index(story)
        δs_Q = magnification_factor_sway_Q(Q)
        
        # Method (b): Use ΣPu/ΣPc (ACI 318-11 §10.10.7.3(b))
        δs_Pc = magnification_factor_sway(story.ΣPu, story.ΣPc)
        
        if δs_Q <= 1.5
            # Q-method is adequate
            δs = δs_Q
            δs_method = :Q
        else
            # ACI 318-11 §10.10.7.3: when δs from Q > 1.5, use ΣPu/ΣPc method
            # or second-order analysis.  Fall back to ΣPu/ΣPc first; if that also
            # exceeds 1.5, flag for P-Δ iteration (caller should handle).
            δs = δs_Pc
            δs_method = :ΣPc
            if δs_Pc > 1.5 && isfinite(δs_Pc)
                @debug "δs = $(round(δs_Pc, digits=3)) > 1.5 (both Q and ΣPc methods); P-Δ analysis recommended (ACI 318-11 §10.10.4)"
                δs_method = :needs_P_delta
            else
                @debug "Q-method δs=$(round(δs_Q, digits=2)) > 1.5; fell back to ΣPc method δs=$(round(δs_Pc, digits=2))"
            end
        end
    else
        δs = 1.0
        @debug "No story properties provided; using δs = 1.0"
    end
    
    # =========================================================================
    # Step 2: Magnify moments at column ends
    # Per ACI 318-11 §10.10.7.1: M = Mns + δs × Ms
    # =========================================================================
    M1 = M1ns + δs * M1s
    M2 = M2ns + δs * M2s
    
    sway_magnified = δs > 1.0
    
    # =========================================================================
    # Step 3: Check slenderness along column length
    # Per ACI 318-11 §10.10.7: Use non-sway procedure on magnified moments
    # =========================================================================
    # Determine if slenderness check is needed
    # Use braced frame limits with M1, M2 from step 2
    
    # For along-length check, use non-sway k (typically 1.0 for braced ends)
    # Create a modified geometry with k = 1.0 for the along-length check
    k_nonsway = 1.0  # For members braced against sidesway (after sway magnification)
    
    # Calculate slenderness ratio for non-sway check
    r = 0.3 * h
    Lu = to_inches(geometry.Lu)
    λ = k_nonsway * Lu / r
    
    # Check if along-length magnification is needed (ACI 318-19 §6.2.5.1).
    # Sign convention: M1/M2 > 0 ⇔ double curvature (best case → larger limit).
    M_ratio = M2 ≈ 0 ? 0.0 : M1 / M2
    limit = min(34 + 12 * M_ratio, 40)

    length_magnified = false
    δns = 1.0
    Mc = max(abs(M1), abs(M2))

    if λ > limit
        # Need to magnify for P-δ effects along length
        # Use non-sway procedure per ACI 318-19 §6.6.4.5 (historically §10.10.6).

        # Synthetic geometry for the along-length check. Needs `kx`/`ky` because
        # the new `critical_buckling_load` signature reads `geometry.kx` /
        # `geometry.ky` via `_axis_k`. Both default to `k_nonsway = 1.0` since
        # this is the post-sway P-δ check inside the column length.
        geometry_nonsway = (Lu = geometry.Lu,
                            kx = k_nonsway, ky = k_nonsway,
                            braced = true)

        # Calculate Pc for non-sway (strong-axis: this sway path is
        # rectangular-section bending in the plane of sway, which by
        # convention is the strong axis here).
        Pc = critical_buckling_load(section, mat, geometry_nonsway; βdns=βdns)

        Cm  = calc_Cm(M1, M2; transverse_load=transverse_load)
        δns = magnification_factor_nonsway(Pu, Pc; Cm=Cm)

        # Final design moment (ACI §10.10.7)
        M_min = minimum_moment(Pu, h)
        Mc = max(δns * max(abs(M1), abs(M2)), M_min)

        length_magnified = δns > 1.0
    end

    return (
        M1 = M1,
        M2 = M2,
        Mc = Mc,
        δs = δs,
        δns = δns,
        Q = Q,
        sway_magnified = sway_magnified,
        length_magnified = length_magnified,
        δs_method = δs_method,
    )
end

# ==============================================================================
# Circular Column Sway Support
# ==============================================================================

"""
    effective_stiffness_sway(section::RCCircularSection, mat; βds=0.0, method=:accurate)

Calculate effective flexural stiffness for circular columns in sway frames.
"""
function effective_stiffness_sway(
    section::RCCircularSection, 
    mat;
    βds::Real = 0.0,
    method::Symbol = :accurate
)
    fc = fc_ksi(mat)
    Es = Es_ksi(mat)
    Ec = Ec_ksi(mat)
    
    # Diameter (inches) for Ig calculation
    D = to_inches(section.D)
    Ig = π * D^4 / 64  # in⁴
    
    if method == :accurate
        Ise = _calc_Ise(section)
        EI_eff = (0.2 * Ec * Ig + Es * Ise) / (1 + βds)
    else
        EI_eff = 0.4 * Ec * Ig / (1 + βds)
    end
    
    return EI_eff
end

"""
    critical_buckling_load_sway(section::RCCircularSection, mat, geometry, axis=StrongAxis(); βds=0.0)

Critical buckling load for circular columns in sway frames. The geometric
properties (D, Ig, Ise) are axisymmetric, but `k` may differ between axes
(e.g., one-way bracing), so this still dispatches on the requested axis.
"""
function critical_buckling_load_sway(
    section::RCCircularSection,
    mat,
    geometry,
    axis::BendingAxis = StrongAxis();
    βds::Real = 0.0,
)
    EI_eff = effective_stiffness_sway(section, mat; βds=βds)

    Lu = to_inches(geometry.Lu)
    kLu = _axis_k(geometry, axis) * Lu

    return π^2 * EI_eff / kLu^2  # kip
end

"""
    magnify_moment_sway_complete(section::RCCircularSection, ...)

Complete sway frame moment magnification for circular columns.
"""
function magnify_moment_sway_complete(
    section::RCCircularSection,
    mat,
    geometry,
    Pu::Real,
    M1ns::Real, M2ns::Real,
    M1s::Real, M2s::Real;
    story::Union{Nothing, SwayStoryProperties} = nothing,
    βds::Real = 0.0,
    βdns::Real = 0.6,
    transverse_load::Bool = false
)
    # Diameter and radius of gyration (inches)
    D = to_inches(section.D)
    r = 0.25 * D  # r = 0.25D for circular sections (ACI §10.10.1.2)
    
    # Step 1: Calculate δs — same tiered logic as rectangular columns
    Q = NaN
    δs_method = :none

    if !isnothing(story)
        Q = stability_index(story)
        δs_Q = magnification_factor_sway_Q(Q)
        δs_Pc = magnification_factor_sway(story.ΣPu, story.ΣPc)
        
        if δs_Q <= 1.5
            δs = δs_Q
            δs_method = :Q
        else
            δs = δs_Pc
            δs_method = :ΣPc
            if δs_Pc > 1.5 && isfinite(δs_Pc)
                @debug "δs = $(round(δs_Pc, digits=3)) > 1.5 (both methods); P-Δ analysis recommended (ACI 318-11 §10.10.4)"
                δs_method = :needs_P_delta
            end
        end
    else
        δs = 1.0
    end
    
    # Step 2: Magnify moments at ends
    M1 = M1ns + δs * M1s
    M2 = M2ns + δs * M2s
    sway_magnified = δs > 1.0
    
    k_nonsway = 1.0
    Lu = to_inches(geometry.Lu)
    λ = k_nonsway * Lu / r
    # ACI 318-19 §6.2.5.1 — M1/M2 > 0 ⇔ double curvature.
    M_ratio = M2 ≈ 0 ? 0.0 : M1 / M2
    limit = min(34 + 12 * M_ratio, 40)
    
    length_magnified = false
    δns = 1.0
    Mc = max(abs(M1), abs(M2))
    
    if λ > limit
        # `critical_buckling_load(::RCCircularSection, ...)` reads
        # `geometry.kx` / `geometry.ky` via `_axis_k`. Both default to
        # `k_nonsway = 1.0` for the post-sway P-δ check inside the column.
        geometry_nonsway = (Lu = geometry.Lu,
                            kx = k_nonsway, ky = k_nonsway,
                            braced = true)
        Pc = critical_buckling_load(section, mat, geometry_nonsway; βdns=βdns)
        Cm = calc_Cm(M1, M2; transverse_load=transverse_load)
        δns = magnification_factor_nonsway(Pu, Pc; Cm=Cm)

        M_min = minimum_moment(Pu, D)
        Mc = max(δns * max(abs(M1), abs(M2)), M_min)
        length_magnified = δns > 1.0
    end
    
    return (
        M1 = M1,
        M2 = M2,
        Mc = Mc,
        δs = δs,
        δns = δns,
        Q = Q,
        sway_magnified = sway_magnified,
        length_magnified = length_magnified,
        δs_method = δs_method,
    )
end

# ==============================================================================
# Circular Column Support
# ==============================================================================

"""
    slenderness_ratio(section::RCCircularSection, geometry, axis=StrongAxis()) -> Float64

Slenderness ratio `k·Lu/r` for circular sections per ACI 318-11 §10.10.1.2,
where `r = 0.25·D`. The radius of gyration is axisymmetric; only `k` is
axis-specific (one-way bracing → `kx ≠ ky`).
"""
function slenderness_ratio(section::RCCircularSection, geometry,
                           axis::BendingAxis = StrongAxis())
    D = to_inches(section.D)
    r = 0.25 * D  # ACI §10.10.1.2
    Lu = to_inches(geometry.Lu)
    return _axis_k(geometry, axis) * Lu / r
end

"""
    should_consider_slenderness(section::RCCircularSection, geometry, axis=StrongAxis(); M1, M2) -> Bool

Check slenderness for circular columns about the requested `axis`.
"""
function should_consider_slenderness(
    section::RCCircularSection,
    geometry,
    axis::BendingAxis = StrongAxis();
    M1::Real = 0.0,
    M2::Real = 1.0,
)
    λ = slenderness_ratio(section, geometry, axis)

    if geometry.braced
        # ACI 318-19 §6.2.5.1(b). Sign convention: M1/M2 > 0 = double curvature.
        M_ratio = M2 ≈ 0 ? 0.0 : M1 / M2
        limit = min(34 + 12 * M_ratio, 40)
        return λ > limit
    else
        return λ > 22
    end
end

"""
    effective_stiffness(section::RCCircularSection, mat, axis=StrongAxis(); βdns=0.6, method=:accurate) -> Float64

Effective flexural stiffness for a circular section. `Ig = π·D⁴/64` and `Ise`
are axisymmetric (independent of `axis`); the argument is accepted to keep the
dispatch shape identical to the rectangular path.
"""
function effective_stiffness(
    section::RCCircularSection,
    mat,
    ::BendingAxis = StrongAxis();
    βdns::Real = 0.6,
    method::Symbol = :accurate,
)
    Es = Es_ksi(mat)
    Ec = Ec_ksi(mat)

    # Gross moment of inertia for circular: Ig = πD⁴/64
    D = to_inches(section.D)
    Ig = π * D^4 / 64  # in⁴

    if method == :accurate
        Ise = _calc_Ise(section)  # axisymmetric — no axis arg needed
        return (0.2 * Ec * Ig + Es * Ise) / (1 + βdns)
    else
        return 0.4 * Ec * Ig / (1 + βdns)
    end
end

"""
    _calc_Ise(section::RCCircularSection) -> Float64

Moment of inertia of longitudinal reinforcement about the section centroid
(in⁴). Axisymmetric — same value for strong- and weak-axis bending.
"""
function _calc_Ise(section::RCCircularSection)
    D = to_inches(section.D)
    centroid = D / 2

    Ise = 0.0
    for bar in section.bars
        y_bar  = to_inches(bar.y)
        As_bar = to_sqinches(bar.As)
        d = y_bar - centroid
        Ise += As_bar * d^2
    end
    return Ise
end

# Trailing-axis form mirrors the rectangular API; circular Ise is axisymmetric
# so the axis tag is ignored here.
_calc_Ise(section::RCCircularSection, ::BendingAxis) = _calc_Ise(section)

"""
    critical_buckling_load(section::RCCircularSection, mat, geometry, axis=StrongAxis(); βdns=0.6) -> Float64

Critical buckling load for a circular column. Geometry is axisymmetric, so the
only per-axis quantity is `k` (`kx` vs `ky`).
"""
function critical_buckling_load(
    section::RCCircularSection,
    mat,
    geometry,
    axis::BendingAxis = StrongAxis();
    βdns::Real = 0.6,
)
    EI_eff = effective_stiffness(section, mat, axis; βdns=βdns)
    Lu = to_inches(geometry.Lu)
    kLu = _axis_k(geometry, axis) * Lu
    return π^2 * EI_eff / kLu^2  # kip
end

"""
    magnify_moment_nonsway(section::RCCircularSection, mat, geometry, Pu, M1, M2, axis=StrongAxis();
                           βdns=0.6, transverse_load=false) -> NamedTuple

Magnified design moment for a non-sway-frame circular column per ACI 318-11
§10.10.6, evaluated about `axis`. Geometric properties are axisymmetric; the
axis argument is honoured by `_axis_k(geometry, axis)` so columns with
direction-specific bracing still see the right `kx`/`ky`.
"""
function magnify_moment_nonsway(
    section::RCCircularSection,
    mat,
    geometry,
    Pu::Real,
    M1::Real,
    M2::Real,
    axis::BendingAxis = StrongAxis();
    βdns::Real = 0.6,
    transverse_load::Bool = false,
)
    slender = should_consider_slenderness(section, geometry, axis; M1=M1, M2=M2)

    # ACI 318-19 §6.6.4.5.4 — M_min only applies inside the slenderness
    # procedure. Non-slender circular columns return |M2| unmodified.
    if !slender
        return (Mc=abs(M2), δns=1.0, Cm=1.0, Pc=Inf, slender=false)
    end

    D = to_inches(section.D)
    Pc  = critical_buckling_load(section, mat, geometry, axis; βdns=βdns)
    Cm  = calc_Cm(M1, M2; transverse_load=transverse_load)
    δns = magnification_factor_nonsway(Pu, Pc; Cm=Cm)

    # ACI 318-19 §6.6.4.5.4 minimum-eccentricity check on the magnified moment.
    M_min = minimum_moment(Pu, D)
    Mc = max(δns * abs(M2), M_min)

    return (Mc=Mc, δns=δns, Cm=Cm, Pc=Pc, slender=true)
end
