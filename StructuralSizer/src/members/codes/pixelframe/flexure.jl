# ==============================================================================
# PixelFrame Flexural Capacity
# ==============================================================================
# Flexural capacity of PixelFrame sections per ACI 318-11 §18.7.2(b), Eq. (18-2)
# (unbonded post-tensioned tendons, span-to-depth ratio ≤ 35). The equation
# form is preserved verbatim in ACI 318-19 §20.3.2.4.1; we cite the 318-11
# clause because that is the edition present in the project corpus.
# Reference: Wongsittikan (2024), Eqs. 2.3–2.12.
#
# Uses polygon-based compression zone analysis via Asap's CompoundSection:
#   - depth_from_area: finds depth for a target compression area
#   - get_section_from_depth: clips the polygon at a given depth
#   - Compression centroid is computed from the actual clipped polygon
#
# Algorithm:
#   1. Estimate f_ps from ACI 318-11 Eq. (18-2)
#   2. Compute compression area A_comp = A_s × f_ps / (0.85 × fc′)
#   3. Clamp to 0.99 × A_g if needed; recalc f_ps
#   4. Find compression depth from polygon (depth_from_area)
#   5. Compute neutral axis c = compression_depth / β₁
#   6. Compute d_ps_from_top = (ymax - centroid_y) + d_ps
#   7. Check concrete strain ε_c = c × ε_ps / (d_ps_from_top - c)
#   8. If ε_c > 0.003, recalculate ε_ps and f_ps, loop back
#   9. Clip polygon at β₁×c → get compression section centroid
#  10. Moment arm = dps_from_top − (ymax − comp_centroid_y)  [thesis Eq. 2.11: ds − dcg]
#  11. Mu = ϕ × 0.85 × fc′ × A_comp × arm
#
# This matches the original Pixelframe.jl get_moment_capacity_prestressed.
# ==============================================================================

using Unitful
using Asap: CompoundSection, SolidSection, depth_from_area, sutherland_hodgman, sutherland_hodgman_abs, poly_area

# ==============================================================================
# ASTM A416 / A416M Grade 270 low-relaxation strand — design defaults
# ==============================================================================
# ACI 318-11 §3.5.6.1(c) (corpus: aci-318-11, page 53) lists ASTM A416 as the
# governing standard for seven-wire prestressing strand. Grade 270 specifies a
# minimum tensile strength f_pu = 270 ksi ≈ 1860 MPa (this is the standard
# product designation; the value itself is not quoted as a clause in ACI 318
# but follows ASTM A416 Grade 270 by reference).
#
# ACI 318-11 R18.7.2 (commentary, corpus: aci-318-11, page 300) sets the
# minimum f_py / f_pu ratio for ASTM A416 / A421 strand:
#   - low-relaxation strand and wire:  f_py / f_pu ≥ 0.90
#   - stress-relieved strand and wire: f_py / f_pu ≥ 0.85
#
# These defaults assume Grade 270 low-relaxation strand — the overwhelmingly
# common product in modern post-tensioned construction. Pass an explicit
# `f_py` kwarg when a different grade or stress-relieved product is in use.
"""ASTM A416 / A416M Grade 270 specified tensile strength `f_pu` (270 ksi ≈ 1860 MPa)."""
const ASTM_A416_GR270_FPU = 1860.0u"MPa"

"""ASTM A416 / A416M Grade 270 low-relaxation strand minimum specified yield strength
`f_py = 0.90 × f_pu = 1674 MPa` (per ACI 318-11 R18.7.2 commentary, corpus: aci-318-11,
page 300)."""
const ASTM_A416_GR270_LR_FPY = 0.90 * ASTM_A416_GR270_FPU

# ==============================================================================
# Helper: Whitney β₁ factor
# ==============================================================================

"""
    _pf_β1(fc′_MPa) -> Float64

Whitney stress block factor β₁ per ACI 318-11 §10.2.7.3 (preserved as
ACI 318-19 §22.2.2.4.3). Metric form: β₁ = 0.85 for `fc′ ≤ 28 MPa`,
linearly reduced by 0.05 per 7 MPa above 28 MPa, floored at 0.65.
"""
function _pf_β1(fc′_MPa::Real)
    clamp(0.85 - 0.05 * (fc′_MPa - 28.0) / 7.0, 0.65, 0.85)
end

# ==============================================================================
# Helper: Flexural strength reduction factor
# ==============================================================================

"""
    _pf_ϕ_flexure(εs) -> Float64

Strength reduction factor ϕ as a function of net tensile strain εs,
linearly interpolated across the transition region between
compression-controlled (ϕ = 0.65) and tension-controlled (ϕ = 0.90)
limits. Form per Wongsittikan (2024) Eq. 2.12, which mirrors
ACI 318-11 §9.3.2 / R9.3.2 (preserved as ACI 318-19 §21.2.2).
"""
function _pf_ϕ_flexure(εs::Real)
    clamp(0.65 + 0.25 * (εs - 0.002) / 0.003, 0.65, 0.90)
end

# ==============================================================================
# Helper: clip CompoundSection at depth from top → new CompoundSection
# ==============================================================================

"""
    _get_section_from_depth(cs::CompoundSection, depth_from_top) -> CompoundSection

Clip a CompoundSection at `depth_from_top` mm from the top (ymax).
Returns a new CompoundSection representing only the material above the cut line.

Ported from Pixelframe.jl `get_section_from_depth`.
"""
function _get_section_from_depth(cs::CompoundSection, depth_from_top::Real)
    y_cut = cs.ymax - depth_from_top

    cut_sections = SolidSection[]
    for s in cs.solids
        ymin_s, ymax_s = s.ymin, s.ymax
        if ymin_s ≤ y_cut ≤ ymax_s
            # Partially above cut → clip using sutherland_hodgman (depth from top of this sub-section)
            local_depth = ymax_s - y_cut
            clipped = sutherland_hodgman(s, local_depth; return_section=true)
            push!(cut_sections, clipped)
        elseif y_cut < ymin_s
            # Entire sub-section is above cut → keep it as-is
            push!(cut_sections, s)
        end
        # else: entirely below cut → skip
    end

    isempty(cut_sections) && error("No section area above cut at depth=$depth_from_top mm")
    return CompoundSection(cut_sections)
end

# ==============================================================================
# Main flexural capacity function
# ==============================================================================

"""
    pf_flexural_capacity(s::PixelFrameSection; E_s, f_py, Ω, max_iter) -> NamedTuple

Design flexural capacity of a PixelFrame section using polygon-based
compression zone analysis.

# Arguments
- `s`: PixelFrameSection (provides geometry, material, tendon properties)
- `E_s`: Tendon elastic modulus (default 200 GPa)
- `f_py`: Tendon yield strength (default [`ASTM_A416_GR270_LR_FPY`](@ref) = 1674 MPa,
  Grade 270 low-relaxation strand per ACI 318-11 R18.7.2 commentary)
- `Ω`: Strain reduction factor for unbonded tendons (default 0.33, conservative)
- `max_iter`: Maximum iterations for ε_c convergence loop (default 50)

# Returns
Named tuple `(Mu, f_ps, εs, εc, ϕ, c, converged)` where:
- `Mu`: Design flexural capacity (N·mm → Unitful)
- `f_ps`: Ultimate tendon stress at capacity (MPa → Unitful)
- `εs`: Tendon strain at capacity
- `εc`: Concrete compressive strain at top fiber
- `ϕ`: Strength reduction factor
- `c`: Neutral axis depth from top [mm → Unitful]
- `converged`: Whether the ε_c iteration converged

# Reference
ACI 318-11 §18.7.2(b), Eq. (18-2) — unbonded tendons, span-to-depth ≤ 35
  (corpus: aci-318-11, page 299). The equation form is preserved in
  ACI 318-19 §20.3.2.4.1.
Wongsittikan (2024) Eqs. 2.3–2.12.
"""
function pf_flexural_capacity(s::PixelFrameSection;
                               E_s::Pressure = 200.0u"GPa",
                               f_py::Pressure = ASTM_A416_GR270_LR_FPY,
                               Ω::Real = 0.33,
                               max_iter::Int = 50)
    cs = s.section  # CompoundSection (unitless, mm)

    # Extract in MPa / mm
    fc′_MPa = ustrip(u"MPa", s.material.fc′)
    A_g_mm2 = cs.area
    A_s_mm2 = ustrip(u"mm^2", s.A_s)
    f_pe_MPa = ustrip(u"MPa", s.f_pe)
    E_s_MPa = ustrip(u"MPa", E_s)
    f_py_MPa = ustrip(u"MPa", f_py)

    β1 = _pf_β1(fc′_MPa)

    # d_ps from centroid → d_ps from top
    d_ps_mm = ustrip(u"mm", s.d_ps)
    centroid_to_top = cs.ymax - cs.centroid[2]
    dps_from_top = centroid_to_top + d_ps_mm

    # Handle d_ps = 0 case (tendon at centroid) — elastic analysis
    if d_ps_mm ≈ 0.0
        I_section = cs.Ix
        dist_top = centroid_to_top
        dist_bot = cs.centroid[2] - cs.ymin
        Sx_top = I_section / dist_top
        Sx_bot = I_section / dist_bot
        initial_stress = f_pe_MPa * A_s_mm2 / A_g_mm2
        fr = 0.7 * sqrt(fc′_MPa)
        Mn_top = Sx_top * (fc′_MPa - initial_stress)
        Mn_bot = Sx_bot * (fr + initial_stress)
        Mn = min(Mn_top, Mn_bot)
        ϕMn = 0.65 * Mn / 1e6  # kN·m → but we return in N·mm
        Mu = 0.65 * Mn * u"N*mm"
        return (; Mu, f_ps=f_pe_MPa * u"MPa", εs=f_pe_MPa / E_s_MPa,
                  εc=0.0, ϕ=0.65, c=0.0u"mm", converged=true)
    end

    # Step 1: Initial estimate of f_ps — ACI 318-11 §18.7.2(b), Eq. (18-2)
    # (unbonded tendons, span/depth ≤ 35; corpus: aci-318-11, page 299).
    # Metric: 10,000 psi → 70 MPa, 60,000 psi → 420 MPa.
    #   f_ps = f_se + 70 + f'_c / (100 ρ_p),
    #   capped by the lesser of f_py and (f_se + 420 MPa).
    if f_pe_MPa ≈ 0.0
        f_ps_MPa = f_py_MPa
    else
        ρ = A_s_mm2 / A_g_mm2
        f_ps_MPa = min(
            f_pe_MPa + 70.0 + fc′_MPa / (100.0 * ρ),
            f_pe_MPa + 420.0,
            f_py_MPa,
        )
    end

    converged = false
    εps = 0.0
    εc = 0.0
    c_from_top = 0.0

    for _ in 1:max_iter
        # Step 2: Compression area from force balance
        A_comp = clamp(A_s_mm2 * f_ps_MPa / (0.85 * fc′_MPa), 0.0, 0.99 * A_g_mm2)

        # Recalculate f_ps in case clamped
        f_ps_MPa = 0.85 * fc′_MPa * A_comp / A_s_mm2

        # Step 3: Find compression depth from polygon
        compression_depth = depth_from_area(cs, A_comp; show_stats=false)

        # Step 4: Neutral axis depth
        c_from_top = compression_depth / β1

        # Check: c must be < dps_from_top
        if c_from_top ≥ dps_from_top
            return (; Mu=0.0u"N*mm", f_ps=0.0u"MPa", εs=0.0, εc=0.0,
                      ϕ=0.65, c=0.0u"mm", converged=false)
        end

        # Step 5: Strain compatibility
        εps = f_ps_MPa / E_s_MPa
        εps_bonded = εps / Ω
        εc = c_from_top * εps_bonded / (dps_from_top - c_from_top)

        if εc ≤ 0.003
            converged = true
            break
        end

        # Step 6: Recalculate with ε_c = 0.003 (slightly less for numerical stability)
        εps_new = 0.0029 * (dps_from_top - c_from_top) / c_from_top
        f_ps_MPa = min(εps_new * E_s_MPa, f_py_MPa)
        εps = εps_new
    end

    # Step 7: Compute moment from polygon compression zone
    compression_depth_from_top = β1 * c_from_top
    comp_section = _get_section_from_depth(cs, compression_depth_from_top)
    comp_centroid_y = comp_section.centroid[2]

    # Moment arm: ds − dcg (thesis Eq. 2.11)
    #   ds  = dps_from_top (tendon depth from top-most fiber)
    #   dcg = ymax − comp_centroid_y (compression centroid depth from top-most fiber)
    dcg = cs.ymax - comp_centroid_y
    arm = dps_from_top - dcg

    # Compression area (from the clipped polygon)
    A_comp_actual = comp_section.area

    ϕ = _pf_ϕ_flexure(εps / Ω)
    Mn_Nmm = 0.85 * fc′_MPa * A_comp_actual * arm
    Mu_Nmm = ϕ * Mn_Nmm

    Mu = Mu_Nmm * u"N*mm"
    f_ps = f_ps_MPa * u"MPa"
    c = c_from_top * u"mm"

    return (; Mu, f_ps, εs=εps, εc, ϕ, c, converged)
end
