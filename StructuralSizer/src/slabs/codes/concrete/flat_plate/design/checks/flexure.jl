# =============================================================================
# Flexural Adequacy Check (ACI 318-19 §21.2.2)
# =============================================================================

"""
    check_flexural_adequacy(moment_results, columns, d, fc; fy=60 ksi, verbose=false) -> NamedTuple

Verify that all strip locations remain tension-controlled (Rn ≤ Rn_max).

Computes the resistance coefficient Rn = Mu / (φ·b·d²) for each strip and
compares against `Rn_max`, the Rn at which εt = εty + 0.003 (ACI 318-19
Table 21.2.2, [`tension_controlled_strain`](@ref); 0.005 for Grade 60). The
slab pipeline passes the same limit to `required_reinforcement`, so a depth
that passes here also gets finite steel there. If any strip exceeds the limit
the section needs more depth.

With the §22.2.2 stress block, c/d = 0.003/(0.003 + εt,min),
ω = 0.85·β₁·c/d, and Rn_max = ω·f'c·(1 − ω/1.7).

Strip moments are `aci_strip_moments`, the same ACI 318-11 §13.6.4/.6
distribution `design_strip_reinforcement` designs the steel for. An EFM
result that still carries face moments is checked at the §13.7.7.1
critical section (`_efm_moments_at_face`), as final design is.

With `drop` (oriented with `a_drop_1` along this span), the column-strip
negative moment is checked at the same stations the steel is designed for
(`_negative_cs_stations`): the column face on the better of the slab
section and the ACI 318-11 §13.3.7 drop section, and the wall faces and
the drop edge on the slab section.

# Returns
Named tuple `(ok, max_ratio, governing_strip)` where
- `ok::Bool`:  true when all strips satisfy Rn ≤ Rn_max
- `max_ratio`: worst-case Rn / Rn_max across all strips
- `governing_strip`: symbol identifying the controlling location
"""
function check_flexural_adequacy(moment_results, columns, d, fc;
                                 βt::Float64 = 0.0, verbose=false,
                                 fy::Pressure = 60_000.0u"psi",
                                 struc=nothing, slab=nothing, span_axis=nothing,
                                 drop=nothing)
    moment_results isa MomentAnalysisResult &&
        (moment_results = _efm_moments_at_face(moment_results))
    φ = 0.9
    ω_tc = 0.85 * beta1(fc) * (0.003 / (0.003 + tension_controlled_strain(fy)))
    Rn_max = ω_tc * fc * (1 - ω_tc / 1.7)

    l1 = moment_results.l1
    l2 = moment_results.l2
    # ACI 318-11 §13.2.1 / §13.2.2 — column strip = min(ℓ1, ℓ2)/2 total width;
    # middle strip = remainder of ℓ2.
    cs_width = min(l1, l2) / 2
    ms_width = l2 - cs_width

    section = drop_negative_section(drop, columns, d, cs_width)
    s = aci_strip_moments(moment_results, columns; βt = βt, struc = struc, slab = slab,
                          span_axis = span_axis,
                          drop_edge = section === nothing ? nothing : section.x_edge)
    drop_st = _drop_cs_stations(s, cs_width, d, section)
    slab_only(Mu, b) = [[(Mu, b, d)]]
    strips = [
        (:ext_neg_cs, drop_st === nothing ? slab_only(s.M_neg_ext_cs, cs_width) : drop_st.ext),
        (:ext_neg_ms, slab_only(s.M_neg_ext_ms, ms_width)),
        (:int_neg_cs, drop_st === nothing ? slab_only(s.M_neg_int_cs, cs_width) : drop_st.int),
        (:pos_cs,     slab_only(s.M_pos_cs, cs_width)),
        (:int_neg_ms, slab_only(s.M_neg_int_ms, ms_width)),
        (:pos_ms,     slab_only(s.M_pos_ms, ms_width)),
    ]

    # uconvert before dividing: ft/inch stays NoDims but ustrip counts it as 12.
    section_ratio((Mu, b, dd)) = ustrip(NoUnits, uconvert(u"psi", Mu / (φ * b * dd^2)) / Rn_max)

    max_ratio = 0.0
    governing = :none

    for (label, stations) in strips
        ratio = maximum(alts -> minimum(section_ratio, alts), stations)
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

