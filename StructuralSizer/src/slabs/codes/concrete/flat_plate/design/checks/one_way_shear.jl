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
- `fea_diag`: named tuple from `_extract_fea_one_way_shear` (`Vu`,
  `cut_length`, `band_width`, `n_elements`). Diagnostic only.
- `fea_Vu`: accepted and ignored for governing. Kept so older callers
  cannot silently switch the demand back to the shell cut.
"""
function check_one_way_shear(moment_results, d, fc;
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

