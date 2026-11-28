# =============================================================================
# One-Way Shear Check (ACI 318-19 §22.5)
# =============================================================================

"""
    _support_tension_steel(moment_results, b, h, d, fc, fy) -> Area

Top steel across width `b` at the one-way shear section: the steel
`required_reinforcement` gives for the smaller nonzero negative support
moment, and at least `minimum_reinforcement(b, h, fy)`. Placed steel is never
less than this, so Vc from it does not exceed Vc from the bars. When the
section is inadequate for flexure the floor is used.
"""
function _support_tension_steel(moment_results, b, h, d, fc, fy)
    As_min = minimum_reinforcement(b, h, fy)
    M_supports = filter(M -> ustrip(u"N*m", M) > 0,
                        [moment_results.M_neg_ext, moment_results.M_neg_int])
    isempty(M_supports) && return As_min
    As = required_reinforcement(minimum(M_supports), b, d, fc, fy;
                                εt_min = tension_controlled_strain(fy))
    return isfinite(As) ? max(As, As_min) : As_min
end

"""
    check_one_way_shear(moment_results, d, fc; h, fy, kwargs...) -> NamedTuple

Check one-way (beam) shear at the critical section (distance `d` from the
column face).

The governing demand is always the analytical frame-strip formula
`Vu = qu × l₂ × (ℓn/2 − d)`, so DDM, EFM, and FEA are sized on the same
check. A FEA section cut, when supplied as `fea_diag`, is reported and
does not change `ok` or `ratio`.

Vc is ACI 318-19 Table 22.5.5.1(c) through
[`one_way_shear_capacity_without_Av`](@ref), with ρw from
[`_support_tension_steel`](@ref) over the frame width ℓ₂.

# Keyword arguments
- `h`, `fy`: slab thickness and rebar yield strength, for ρw.
- `fea_diag`: named tuple from `_extract_fea_one_way_shear` (`Vu`,
  `cut_length`, `band_width`, `n_elements`). Diagnostic only.
- `fea_Vu`: accepted and ignored for governing. Kept so older callers
  cannot silently switch the demand back to the shell cut.
"""
function check_one_way_shear(moment_results, d, fc;
                             h::Length, fy::Pressure,
                             verbose=false, λ=1.0, φ_shear=0.75,
                             fea_Vu=nothing, fea_diag=nothing)
    l2 = moment_results.l2
    ln = moment_results.ln
    qu = moment_results.qu
    # Governing demand. Same formula for every analysis method.
    Vu = one_way_shear_demand(qu, l2, ln, d)
    source = :analytical

    Vu_fea = nothing
    fea_cut_length = nothing
    fea_band_width = nothing
    fea_n_elements = 0
    if !isnothing(fea_diag) && hasproperty(fea_diag, :Vu)
        Vu_fea = fea_diag.Vu
        fea_cut_length = fea_diag.cut_length
        fea_band_width = fea_diag.band_width
        fea_n_elements = fea_diag.n_elements
    elseif !isnothing(fea_Vu)
        Vu_fea = fea_Vu
    end

    As = _support_tension_steel(moment_results, l2, h, d, fc, fy)
    Vc = one_way_shear_capacity_without_Av(fc, l2, d, As; λ=λ)
    result = StructuralSizer.check_one_way_shear(Vu, Vc; φ=φ_shear)
    φVc = φ_shear * Vc
    fea_ratio = if isnothing(Vu_fea)
        NaN
    else
        ustrip(u"lbf", Vu_fea) / ustrip(u"lbf", φVc)
    end

    if verbose
        status = result.ok ? "✓ PASS" : "✗ FAIL"
        @debug "One-way shear ($source)" Vu=Vu Vc=Vc φVc=φVc ratio=round(result.ratio, digits=2) Vu_fea=Vu_fea fea_ratio=fea_ratio status=status
    end

    return (
        ok = result.ok,
        ratio = result.ratio,
        Vu = Vu,
        Vc = Vc,
        message = result.message,
        source = source,
        Vu_fea = Vu_fea,
        fea_ratio = fea_ratio,
        fea_cut_length = fea_cut_length,
        fea_band_width = fea_band_width,
        fea_n_elements = fea_n_elements,
    )
end

"""
    wall_one_way_shear(struc, slab, d, fc, qu; h, fy, λ=1, ϕ=0.75)

Beam-action shear at each wall that meets the slab.

The critical section extends across the width at `d` from the wall face, the
same distance the frame-strip check uses. Vu is the wall's tributary outside
that section. Vc is ACI 318-19 Table 22.5.5.1(c) on a width equal to the wall
length. ρw uses `minimum_reinforcement` (0.0018 h per unit width), since the
wall-strip top steel is not known here; more steel only raises Vc.
"""
function wall_one_way_shear(struc, slab, d::Length, fc::Pressure, qu::Pressure;
                            h::Length, fy::Pressure,
                            λ::Float64 = 1.0, ϕ::Float64 = 0.75)
    walls = _walls_meeting_slab(struc, slab)
    isempty(walls) && return NamedTuple[]
    checks = NamedTuple[]
    d_m = ustrip(u"m", d)
    for w in walls
        L = _wall_len_m(w)
        L < 1e-3 && continue
        A = _wall_trib_m2(w)
        A > 0 || continue
        outside = max(A - L * d_m, 0.0)
        outside > 0 || continue
        Vu = uconvert(kip, qu * (outside * u"m^2"))
        b = L * u"m"
        Vc = one_way_shear_capacity_without_Av(fc, b, d, minimum_reinforcement(b, h, fy); λ = λ)
        r = check_one_way_shear(Vu, Vc; φ = ϕ)
        push!(checks, (ok = r.ok, ratio = r.ratio, Vu = Vu, Vc = Vc, message = r.message))
    end
    return checks
end

