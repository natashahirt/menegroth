# =============================================================================
# Flexural Adequacy Check (ACI 318-11 §9.3.2)
# =============================================================================

"""
    check_flexural_adequacy(moment_results, columns, d, fc; verbose=false) -> NamedTuple

Verify that all strip locations remain tension-controlled (Rn ≤ Rn_max).

Computes the resistance coefficient Rn = Mu / (φ·b·d²) for each strip and
compares against `Rn_max`, the Rn at which εt = 0.005 (ACI 318-11 §10.3.4,
corpus: aci-318-11, page 142). This is the same limit `required_reinforcement`
enforces, so a depth that passes here also gets finite steel there. If any
strip exceeds the limit the section needs more depth.

With the §10.2.7.1 stress block (page 140), c/d = 0.003/(0.003 + 0.005) = 3/8,
ω = 0.85·β₁·c/d, and Rn_max = ω·f'c·(1 − ω/1.7).

Uses the same ACI 318-11 §13.6.4/.6 transverse distribution as `design_strip_reinforcement`:
exterior negative → column-strip fraction from βt (§13.6.4.2); interior
negative → 75 / 25 %; positive → 60 / 40 %.

`fy`, `struc`, `slab`, and `span_axis` are accepted from the slab loop.
§10.3.4 fixes the tension-controlled strain at 0.005, so `fy` does not
change `Rn_max`. The strip moments are taken from `moment_results`.

# Returns
Named tuple `(ok, max_ratio, governing_strip)` where
- `ok::Bool`:  true when all strips satisfy Rn ≤ Rn_max
- `max_ratio`: worst-case Rn / Rn_max across all strips
- `governing_strip`: symbol identifying the controlling location
"""
function check_flexural_adequacy(moment_results, columns, d, fc;
                                 βt::Float64 = 0.0, verbose=false,
                                 fy=nothing, struc=nothing, slab=nothing,
                                 span_axis=nothing)
    φ = 0.9
    ω_tc = 0.85 * beta1(fc) * (0.003 / (0.003 + 0.005))
    Rn_max = ω_tc * fc * (1 - ω_tc / 1.7)

    l1 = moment_results.l1
    l2 = moment_results.l2
    # ACI 318-11 §13.2.1 / §13.2.2 — column strip = min(ℓ1, ℓ2)/2 total width;
    # middle strip = remainder of ℓ2.
    cs_width = min(l1, l2) / 2
    ms_width = l2 - cs_width

    # ACI 318-11 §13.6.4.2 — exterior-negative column-strip fraction depends
    # on edge-beam torsional stiffness βt (linear interp 100%→75% over [0, 2.5]).
    cs_ext_frac = aci_col_strip_ext_neg_fraction(βt)
    ms_ext_frac = 1.0 - cs_ext_frac

    # Derive strip design moments (mirrors design_strip_reinforcement)
    zero_M = zero(moment_results.M0)
    M_neg_ext_cs = zero_M
    M_neg_ext_ms = zero_M
    M_neg_int_cs = zero_M
    M_neg_int_ms = zero_M

    for (i, col) in enumerate(columns)
        m = moment_results.column_moments[i]
        if col.position == :interior
            M_neg_int_cs = max(M_neg_int_cs, 0.75 * m)
            M_neg_int_ms = max(M_neg_int_ms, 0.25 * m)
        else
            M_neg_ext_cs = max(M_neg_ext_cs, cs_ext_frac * m)
            M_neg_ext_ms = max(M_neg_ext_ms, ms_ext_frac * m)
        end
    end

    M_pos_cs = 0.60 * moment_results.M_pos
    M_pos_ms = 0.40 * moment_results.M_pos

    # Collect (label, Mu, strip width) for every strip location
    strips = [
        (:ext_neg_cs,  M_neg_ext_cs, cs_width),
        (:ext_neg_ms,  M_neg_ext_ms, ms_width),
        (:int_neg_cs,  M_neg_int_cs, cs_width),
        (:pos_cs,      M_pos_cs,     cs_width),
        (:int_neg_ms,  M_neg_int_ms, ms_width),
        (:pos_ms,      M_pos_ms,     ms_width),
    ]

    max_ratio = 0.0
    governing = :none

    for (label, Mu, b) in strips
        # uconvert before dividing: ft/inch stays NoDims but ustrip counts it as 12.
        Rn = uconvert(u"psi", Mu / (φ * b * d^2))
        ratio = ustrip(NoUnits, Rn / Rn_max)
        if ratio > max_ratio
            max_ratio = ratio
            governing = label
        end
    end

    ok = max_ratio ≤ 1.0

    if verbose
        status = ok ? "✓ PASS" : "✗ FAIL"
        @debug "Flexural adequacy (tension-controlled)" Rn_max=Rn_max max_ratio=round(max_ratio, digits=3) governing=governing status=status
    end

    return (ok=ok, max_ratio=max_ratio, governing_strip=governing)
end

