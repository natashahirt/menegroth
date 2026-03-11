# ==============================================================================
# Composite Beam Design Report — AISC 360-16 Chapter I
# ==============================================================================
# Generates a formatted engineering report summarizing all composite beam
# design checks: section properties, slab/stud parameters, effective width,
# flexural strength, construction stage, deflection, stud layout, and
# negative moment (if applicable).
#
# Lives in StructuralSynthesizer/postprocess alongside the other reports.
# Uses Printf (already imported by _postprocess.jl) and calls into
# StructuralSizer's composite API via the @reexport chain.

"""
    report_composite_beam(section::ISymmSection, material, ctx::CompositeContext;
                          Mu, Vu, w_DL, w_LL,
                          Mu_const=nothing, Vu_const=nothing,
                          w_const_DL=nothing,
                          δ_limit_ratio=1/360,
                          δ_const_limit=nothing,
                          Cb=1.0,
                          io::IO=stdout) -> NamedTuple

Print a comprehensive composite beam design report and return a summary of
all check results.

# Required Arguments
- `section`: Steel W-shape (doubly symmetric I)
- `material`: `StructuralSteel` (e.g. `A992_Steel`)
- `ctx`: `CompositeContext` with slab, anchor, span, shored flag, etc.
- `Mu`: Required factored moment (LRFD)
- `Vu`: Required factored shear
- `w_DL`: Service dead load per unit length
- `w_LL`: Service live load per unit length

# Optional Arguments
- `Mu_const`: Construction-stage factored moment (defaults to `Mu`)
- `Vu_const`: Construction-stage factored shear (defaults to `Vu`)
- `w_const_DL`: Construction dead load for deflection (defaults to `w_DL`)
- `δ_limit_ratio`: Live load deflection limit (default `L/360`)
- `δ_const_limit`: Absolute construction deflection limit (e.g. `2.5u"inch"`)
- `Cb`: Moment gradient factor (default 1.0)
- `io`: Output stream (default `stdout`)
"""
function report_composite_beam(
    section::ISymmSection,
    material,
    ctx::CompositeContext;
    Mu,
    Vu,
    w_DL,
    w_LL,
    Mu_const=nothing,
    Vu_const=nothing,
    w_const_DL=nothing,
    δ_limit_ratio=1/360,
    δ_const_limit=nothing,
    Cb=1.0,
    io::IO=stdout
)
    Mu_const  = something(Mu_const, Mu)
    Vu_const  = something(Vu_const, Vu)
    w_const_DL = something(w_const_DL, w_DL)
    L = ctx.L_beam

    hline = "─"^78
    dline = "═"^78

    _sec(title)  = println(io, "\n", dline, "\n  ", title, "\n", dline)
    _sub(title)  = println(io, "\n  ", hline, "\n  ", title, "\n  ", hline)
    _row(l, v)   = @printf(io, "    %-36s %s\n", l, v)
    _row2(l, v, u) = @printf(io, "    %-36s %10.3f %s\n", l, v, u)
    _chk(l, ok)  = @printf(io, "    %-36s %s\n", l, ok ? "✓ OK" : "✗ FAIL")
    _blank()     = println(io)

    # ======================================================================
    # Header
    # ======================================================================
    _sec("COMPOSITE BEAM DESIGN CHECK — AISC 360-16 Chapter I")
    _row("Section", string(section.name))
    _row("Material", @sprintf("Fy = %.1f ksi, E = %d ksi",
        ustrip(u"ksi", material.Fy), round(Int, ustrip(u"ksi", material.E))))
    _row("Span", @sprintf("%.2f ft", ustrip(u"ft", L)))
    _row("Construction", ctx.shored ? "Shored" : "Unshored")

    # ======================================================================
    # Section Properties
    # ======================================================================
    _sub("Steel Section Properties")
    _row2("d  (depth)",          ustrip(u"inch", section.d), "in.")
    _row2("bf (flange width)",   ustrip(u"inch", section.bf), "in.")
    _row2("tf (flange thick.)",  ustrip(u"inch", section.tf), "in.")
    _row2("tw (web thick.)",     ustrip(u"inch", section.tw), "in.")
    _row2("A  (area)",           ustrip(u"inch^2", section.A), "in.²")
    _row2("Ix (strong-axis I)",  ustrip(u"inch^4", section.Ix), "in.⁴")
    _row2("Zx (plastic mod.)",   ustrip(u"inch^3", section.Zx), "in.³")

    # ======================================================================
    # Slab Properties
    # ======================================================================
    _sub("Slab Properties")
    slab = ctx.slab
    if slab isa DeckSlabOnBeam
        _row("Type", "Metal deck composite slab")
        _row2("t_slab (conc. above deck)", ustrip(u"inch", slab.t_slab), "in.")
        _row2("hr    (rib height)",        ustrip(u"inch", slab.hr), "in.")
        _row2("wr    (rib width)",         ustrip(u"inch", slab.wr), "in.")
        _row("Deck orientation", string(slab.deck_orientation))
    else
        _row("Type", "Solid reinforced concrete slab")
        _row2("t_slab", ustrip(u"inch", slab.t_slab), "in.")
    end
    _row2("fc′", ustrip(u"ksi", slab.fc′), "ksi")
    _row2("Ec",  ustrip(u"ksi", slab.Ec), "ksi")
    _row2("n = Es/Ec", slab.n, "")

    # ======================================================================
    # Stud Properties
    # ======================================================================
    _sub("Steel Headed Stud Anchor (AISC I8)")
    anchor = ctx.anchor
    _row2("d_sa (diameter)", ustrip(u"inch", anchor.d_sa), "in.")
    _row2("l_sa (length)",   ustrip(u"inch", anchor.l_sa), "in.")
    _row2("Fu",              ustrip(u"ksi", anchor.Fu), "ksi")
    _row("Studs per row",    string(anchor.n_per_row))

    # Stud validation
    diam_ok = true
    try validate_stud_diameter(anchor, section.tf) catch; diam_ok = false end
    len_ok = true
    try validate_stud_length(anchor, slab) catch; len_ok = false end
    _chk("d_sa ≤ 2.5 tf (I8.1)", diam_ok)
    _chk("l_sa ≥ 4 d_sa (I8.2)", len_ok)

    Rg, Rp = StructuralSizer._Rg_Rp(anchor, slab)
    _row2("Rg", Rg, "")
    _row2("Rp", Rp, "")

    Qn = get_Qn(anchor, slab)
    _row2("Qn (single stud)", ustrip(u"kip", Qn), "kips")

    # ======================================================================
    # Effective Width (I3.1a)
    # ======================================================================
    _sub("Effective Width (AISC I3.1a)")
    b_eff = get_b_eff(slab, L)
    _row2("b_eff", ustrip(u"ft", b_eff), "ft")
    _row2("b_eff", ustrip(u"inch", b_eff), "in.")

    # ======================================================================
    # Compression Force and Composite Ratio
    # ======================================================================
    _sub("Compression Force (AISC I3.2d)")
    Ac = StructuralSizer._Ac(slab, b_eff)
    V_conc  = 0.85 * slab.fc′ * Ac
    V_steel = material.Fy * section.A
    Cf_max  = StructuralSizer._Cf_max(section, material, slab, b_eff)
    ΣQn_full = Cf_max  # full composite

    _row2("V′_concrete = 0.85 fc′ Ac",  ustrip(u"kip", V_conc), "kips")
    _row2("V′_steel    = Fy As",         ustrip(u"kip", V_steel), "kips")
    _row2("Cf_max = min(V′c, V′s)",      ustrip(u"kip", Cf_max), "kips")

    # Partial composite solver: find minimum ΣQn for Mu
    Mn_target = Mu / 0.9  # back out from ϕMn requirement
    partial = find_required_ΣQn(section, material, slab, b_eff, Mn_target, Qn; ϕ=0.9)
    ΣQn = partial.ΣQn
    n_studs_half = partial.n_studs_half
    n_studs_total = 2 * n_studs_half
    composite_ratio = ustrip(u"N", ΣQn) / ustrip(u"N", Cf_max)

    _blank()
    _row2("Required ΣQn", ustrip(u"kip", ΣQn), "kips")
    _row2("Composite ratio (ΣQn/Cf_max)", composite_ratio * 100, "%")
    _row("Studs per half-span", string(n_studs_half))
    _row("Total studs", string(n_studs_total))
    _chk("ΣQn ≥ 0.25 Cf_max (I3.2d(5))", ΣQn >= 0.25 * Cf_max)
    _chk("Full composite sufficient", partial.sufficient)

    # ======================================================================
    # Stress Block Depth
    # ======================================================================
    _sub("Stress Block Depth")
    Cf = get_Cf(section, material, slab, b_eff, ΣQn)
    a = Cf / (0.85 * slab.fc′ * b_eff)
    total_depth = StructuralSizer._total_slab_depth(slab)
    _row2("a = Cf / (0.85 fc′ b_eff)", ustrip(u"inch", a), "in.")
    _row2("Total slab depth (t_slab + hr)", ustrip(u"inch", total_depth), "in.")
    _chk("a ≤ t_slab", a <= slab.t_slab)

    # ======================================================================
    # Positive Flexural Strength (I3.2a)
    # ======================================================================
    _sub("Positive Flexural Strength (AISC I3.2a)")

    web_compact = true
    try StructuralSizer._check_web_compact_composite(section, material) catch; web_compact = false end
    _chk("Web compact for plastic method", web_compact)

    result_comp = get_ϕMn_composite(section, material, slab, b_eff, ΣQn)
    ϕMn_comp = result_comp.ϕMn

    # Bare steel capacity — fully braced (ϕMp) and at service Lb for context
    Mp = material.Fy * section.Zx
    ϕMp = 0.9 * Mp
    ϕMn_steel_Lb = get_ϕMn(section, material; Lb=L, Cb=Cb, axis=:strong)

    _blank()
    _row2("ϕMp (bare steel, Lb=0)", ustrip(u"kip*ft", ϕMp), "kip-ft")
    _row2("ϕMn (bare steel, Lb=L)", ustrip(u"kip*ft", ϕMn_steel_Lb), "kip-ft")
    _row2("ϕMn (composite)",        ustrip(u"kip*ft", ϕMn_comp), "kip-ft")
    _row2("Mu (required)",          ustrip(u"kip*ft", Mu), "kip-ft")
    _row2("y_pna (from slab top)",  ustrip(u"inch", result_comp.y_pna), "in.")
    _blank()
    util_M = ustrip(u"N*m", Mu) / ustrip(u"N*m", ϕMn_comp)
    _row2("Flexure utilization (Mu/ϕMn)", util_M, "")
    flexure_ok = ϕMn_comp >= Mu
    _chk("ϕMn_composite ≥ Mu", flexure_ok)

    # ======================================================================
    # Shear (Chapter G — steel section alone)
    # ======================================================================
    _sub("Shear Strength (AISC Chapter G)")
    ϕVn = get_ϕVn(section, material; axis=:strong)
    _row2("ϕVn (steel section)",  ustrip(u"kip", ϕVn), "kips")
    _row2("Vu (required)",        ustrip(u"kip", Vu), "kips")
    util_V = ustrip(u"N", Vu) / ustrip(u"N", ϕVn)
    _row2("Shear utilization (Vu/ϕVn)", util_V, "")
    shear_ok = ϕVn >= Vu
    _chk("ϕVn ≥ Vu", shear_ok)

    # ======================================================================
    # Construction Stage (I3.1b)
    # ======================================================================
    const_flex_ok = true
    const_shear_ok = true
    const_defl_ok = true

    if !ctx.shored
        _sub("Construction Stage — Unshored (AISC I3.1b)")
        _row2("Lb_const", ustrip(u"ft", ctx.Lb_const), "ft")

        r_const = check_construction(section, material, Mu_const, Vu_const;
                                      Lb_const=ctx.Lb_const, Cb_const=Cb)
        const_flex_ok = r_const.flexure_ok
        const_shear_ok = r_const.shear_ok
        _row2("ϕMn_steel (construction)", ustrip(u"kip*ft", r_const.ϕMn_steel), "kip-ft")
        _row2("Mu_const",                 ustrip(u"kip*ft", Mu_const), "kip-ft")
        _chk("ϕMn_steel ≥ Mu_const", const_flex_ok)
        _row2("ϕVn_steel (construction)", ustrip(u"kip", r_const.ϕVn_steel), "kips")
        _row2("Vu_const",                 ustrip(u"kip", Vu_const), "kips")
        _chk("ϕVn_steel ≥ Vu_const", const_shear_ok)

        if δ_const_limit !== nothing
            _blank()
            Es = material.E
            I_steel = section.Ix
            δ_const = 5 * w_const_DL * L^4 / (384 * Es * I_steel)
            _row2("δ_construction", ustrip(u"inch", δ_const), "in.")
            _row2("δ_const limit",  ustrip(u"inch", δ_const_limit), "in.")
            const_defl_ok = δ_const <= δ_const_limit
            _chk("δ_construction ≤ limit", const_defl_ok)
            _row2("Ix_required", ustrip(u"inch^4",
                5 * w_const_DL * L^4 / (384 * Es * δ_const_limit)), "in.⁴")
            _row2("Ix_provided", ustrip(u"inch^4", I_steel), "in.⁴")
        end
    end

    # ======================================================================
    # Deflection (Commentary I3.2)
    # ======================================================================
    _sub("Deflection Checks (Commentary I3.2)")
    defl = check_composite_deflection(
        section, material, slab, b_eff, ΣQn,
        L, w_DL, w_LL;
        shored=ctx.shored,
        δ_limit_ratio=δ_limit_ratio,
        δ_const_limit=δ_const_limit
    )

    I_tr = get_I_transformed(section, slab, b_eff)
    I_LB = defl.I_LB

    _row2("I_transformed (full composite)", ustrip(u"inch^4", I_tr), "in.⁴")
    _row2("I_LB (lower bound, partial)",    ustrip(u"inch^4", I_LB), "in.⁴")
    _row2("I_steel",                        ustrip(u"inch^4", section.Ix), "in.⁴")
    _blank()
    _row2("δ_DL",       ustrip(u"inch", defl.δ_DL), "in.")
    _row2("δ_LL",       ustrip(u"inch", defl.δ_LL), "in.")
    _row2("δ_total",    ustrip(u"inch", defl.δ_total), "in.")
    _row2("δ_LL limit (L/$(Int(round(1/δ_limit_ratio))))", ustrip(u"inch", defl.δ_LL_limit), "in.")
    defl_ok = defl.ok_LL
    _chk("δ_LL ≤ L/$(Int(round(1/δ_limit_ratio)))", defl_ok)

    if !ctx.shored
        _row("DL deflection basis", "Steel Ix alone (unshored)")
        _row("LL deflection basis", "I_LB (composite)")
    else
        _row("All deflection basis", "I_LB (shored — composite for all loads)")
    end

    # ======================================================================
    # Stud Layout
    # ======================================================================
    _sub("Stud Layout Summary")
    _row("Studs per half-span", string(n_studs_half))
    _row("Total studs", string(n_studs_total))

    n_rows_half = ceil(Int, n_studs_half / anchor.n_per_row)
    L_half = L / 2
    if n_rows_half > 1
        spacing = L_half / n_rows_half
        _row2("Avg. longitudinal spacing", ustrip(u"inch", spacing), "in.")
        s_min = 6 * anchor.d_sa
        s_max = min(8 * slab.t_slab, 36.0u"inch")
        _row2("Min spacing (6 d_sa)", ustrip(u"inch", s_min), "in.")
        _row2("Max spacing (8 t_slab or 36 in.)", ustrip(u"inch", s_max), "in.")
        spacing_ok = spacing >= s_min && spacing <= s_max
        _chk("Spacing within limits (I8.2d)", spacing_ok)
    end

    m_one = stud_mass(anchor)
    total_mass_kg = ustrip(u"kg", m_one) * n_studs_total
    _row2("Mass per stud", ustrip(u"kg", m_one), "kg")
    _row2("Total stud mass", total_mass_kg, "kg")
    _row2("Total stud ECC", total_mass_kg * anchor.ecc, "kgCO₂e")

    # ======================================================================
    # Negative Moment (I3.2b) — if requested
    # ======================================================================
    neg_ok = true
    if ctx.neg_moment
        _sub("Negative Moment (AISC I3.2b)")
        _row2("Asr (slab rebar within b_eff)", ustrip(u"inch^2", ctx.Asr), "in.²")
        _row2("Fysr",                          ustrip(u"ksi", ctx.Fysr), "ksi")
        Mn_neg = get_Mn_negative(section, material, ctx.Asr, ctx.Fysr)
        ϕMn_neg = 0.9 * Mn_neg
        _row2("ϕMn_negative", ustrip(u"kip*ft", ϕMn_neg), "kip-ft")
        _row2("Mp (bare steel)", ustrip(u"kip*ft", Mp), "kip-ft")
    end

    # ======================================================================
    # Summary
    # ======================================================================
    _sec("SUMMARY")
    all_ok = flexure_ok && shear_ok && const_flex_ok && const_shear_ok &&
             const_defl_ok && defl_ok && partial.sufficient && web_compact &&
             diam_ok && len_ok && neg_ok

    _chk("Flexure (composite ϕMn ≥ Mu)", flexure_ok)
    _chk("Shear (ϕVn ≥ Vu)", shear_ok)
    if !ctx.shored
        _chk("Construction flexure", const_flex_ok)
        _chk("Construction shear", const_shear_ok)
        if δ_const_limit !== nothing
            _chk("Construction deflection", const_defl_ok)
        end
    end
    _chk("Live load deflection", defl_ok)
    _chk("Web compactness (plastic method)", web_compact)
    _chk("Stud diameter (I8.1)", diam_ok)
    _chk("Stud length (I8.2)", len_ok)
    _chk("Composite sufficient (partial solver)", partial.sufficient)
    _blank()

    status = all_ok ? "✓ ALL CHECKS PASS" : "✗ DESIGN INADEQUATE"
    _row("Overall", status)
    _blank()
    println(io, dline)

    return (;
        ok=all_ok,
        flexure_ok, shear_ok,
        const_flex_ok, const_shear_ok, const_defl_ok,
        defl_ok,
        web_compact, diam_ok, len_ok,
        ϕMn_comp, ϕMp, ϕMn_steel_Lb, ϕVn,
        Mu, Vu,
        util_M, util_V,
        b_eff, Cf=Cf, a, ΣQn,
        n_studs_half, n_studs_total,
        composite_ratio,
        I_LB, I_tr,
        δ_DL=defl.δ_DL, δ_LL=defl.δ_LL, δ_total=defl.δ_total,
    )
end
