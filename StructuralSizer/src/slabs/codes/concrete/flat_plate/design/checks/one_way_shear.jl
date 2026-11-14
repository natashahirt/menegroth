# =============================================================================
# One-Way Shear Check (ACI 318-11 §22.5)
# =============================================================================

"""
    check_one_way_shear(moment_results, d, fc; kwargs...) -> NamedTuple

Check one-way (beam) shear at the critical section (distance `d` from the
column face).

The governing demand is always the analytical frame-strip formula
`Vu = qu × l₂ × (ℓn/2 − d)`, so DDM, EFM, and FEA are sized on the same
check. A FEA section cut, when supplied as `fea_diag`, is reported and
does not change `ok` or `ratio`.

# Reference
ACI 318-11 §11.1.3.1 and §11.2.1.1 (Eq. 11-3), via `one_way_shear_demand`
and `one_way_shear_capacity`.

# Keyword arguments
- `h`, `fy`: accepted from the slab loop. ACI 318-11 Eq. (11-3) does not
  use them (corpus: aci-318-11, §11.2.1.1, page 168). The more detailed
  Eq. (11-5) does, and this check stays on Eq. (11-3).
- `fea_diag`: named tuple from `_extract_fea_one_way_shear` (`Vu`,
  `cut_length`, `band_width`, `n_elements`). Diagnostic only.
- `fea_Vu`: accepted and ignored for governing. Kept so older callers
  cannot silently switch the demand back to the shell cut.
"""
function check_one_way_shear(moment_results, d, fc;
                             verbose=false, λ=1.0, φ_shear=0.75,
                             h=nothing, fy=nothing,
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

    Vc = one_way_shear_capacity(fc, l2, d; λ=λ)
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

ACI 318-11 §11.11.1.1 (corpus: aci-318-11, page 200): the critical section
extends across the wall, and the slab is designed by §11.1 through §11.4.
§11.1.3.1 (page 166) places that section a distance `d` from the wall face,
so `Vu` is `qu` times the wall's tributary area outside the strip of width
`d`. `Vc` is Eq. (11-3) on a width equal to the wall length. `h` and `fy`
are accepted and unused, for the same reason as [`check_one_way_shear`](@ref).
"""
function wall_one_way_shear(struc, slab, d::Length, fc::Pressure, qu::Pressure;
                            h=nothing, fy=nothing,
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
        Vu = uconvert(u"kip", qu * (outside * u"m^2"))
        b = L * u"m"
        Vc = one_way_shear_capacity(fc, b, d; λ = λ)
        r = check_one_way_shear(Vu, Vc; φ = ϕ)
        push!(checks, (ok = r.ok, ratio = r.ratio, Vu = Vu, Vc = Vc, message = r.message))
    end
    return checks
end

