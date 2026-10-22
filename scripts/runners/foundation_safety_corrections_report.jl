# Cumulative review: foundation / gravity safety items 1–15.
# Usage:
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer \
#     scripts/runners/foundation_safety_corrections_report.jl
#
# Numbers are computed here or taken from existing test constants.

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using Unitful
using Asap
using StructuralSizer
using StructuralSynthesizer

const SS = StructuralSizer

function _row(item, class, citation, oracle)
    println()
    println("ITEM $item  [$class]")
    println("  citation: $citation")
    println("  oracle:   $oracle")
end

function main()
    println("="^72)
    println("Foundation / gravity safety corrections — items 1–15")
    println("="^72)

    qu = 0.193u"kip/ft^2"
    l2 = 14.0u"ft"
    ln = 16.67u"ft"
    M0_oracle = qu * l2 * ln^2 / 8
    Mub_ext = 0.3 * M0_oracle
    M0_kipft = round(ustrip(kip * u"ft", M0_oracle); digits=3)
    Mub_kipft = round(ustrip(kip * u"ft", Mub_ext); digits=3)

    _row("1", "FIXED",
         "signed M+/M− envelopes (ACI 318-11 §13.7.6 / AISC 360-16 F/H)",
         "unsigned |M| envelope replaced by signed Mux_pos / Mux_neg (test_signed_demands.jl)")
    _row("2", "FIXED",
         "ACI 318-11 §13.7.6 pattern loading (corpus: aci-318-11, page 261)",
         "pattern-case station envelope; cache reused (test_pattern_loading.jl)")
    _row("3", "FIXED",
         "ACI 318-11 §13.6.3.6 (corpus: aci-318-11, page 255)",
         "Mub_ext = 0.3 Mo = $Mub_kipft kip·ft  (Mo = $M0_kipft kip·ft; test_ddm_edge_mub.jl)")
    _row("4", "FIXED",
         "ACI 318-11 §11.11.7 / R11.11.7.2 (corpus: aci-318-11, pages 209–211)",
         "corner/edge punching uses Mux and Muy (oracles Mux=30, Muy=20 kip·ft; test_corner_punching.jl)")
    _row("5", "FIXED",
         "FEA combo envelope (not a single combo)",
         "Myy-governing combo is retained (test_fea_combo_envelope.jl)")
    _row("6", "FIXED",
         "AISC 360-16 §G2.1(a) φv (corpus: aisc-360-16)",
         "φv = 1.00 for compact rolled webs meeting G2.1(a); else 0.90 (test_phi_v_provision.jl)")
    _row("7", "FIXED",
         "ACI 318-11 §11.2.1.2 / Eq. 11-4, 11-8 (corpus: aci-318-11)",
         "signed Nu in beam shear (test_signed_demands.jl NLP shear)")
    _row("8", "FIXED",
         "ACI 318-11 §15.8.1.2 (corpus: aci-318-11, page 275); ASCE 7-16 §2.3.1/§2.4.1",
         "signed Pu/Ps; extra D+L service solve (not Pu/1.4); mixed-sign strip L=82 ft vs zeroed 42 ft (test_foundation_demands.jl)")

    ur_h1 = SS._pixelframe_h1_interaction(0.6, 0.6, 0.0, 1.0, 1.0, 1.0)
    _row("9a", "RECLASSIFIED — CONSERVATIVE (gravity-only)",
         "group max|P| paired with max|M| (not concurrent)",
         "same-sign D+L cannot unload a coincident peak; no code change")
    _row("9b", "RECLASSIFIED — SCOPE until lateral/uplift",
         "AISC 360-16 §H1.2 tension+flexure (corpus: aisc-360-16, page 133)",
         "Pu_t collected in member_group_demands but size_columns raw-vector API does not forward it")
    _row("9c", "FIXED",
         "AISC 360-16 §H1.1 Eq. H1-1a analog (corpus: aisc-360-16, page 133); ENGINEERING JUDGMENT for PixelFrame",
         "Pu=0.6 φPn and Mux=0.6 φMn → UR = $(round(ur_h1; digits=3)) > 1 (must fail). Independent P,M would have passed.")

    c1 = 12.0u"inch"; c2 = 24.0u"inch"; d = 6.0u"inch"
    ori = SS._orient_edge_column(c1, c2, 80.0kip * u"ft", 10.0kip * u"ft";
                                 free_edge_parallel = :c1)
    geom_ok = SS.punching_geometry_edge(ori.c1, ori.c2, d)
    geom_bad = SS.punching_geometry_edge(c1, c2, d)
    b0_ok = round(ustrip(u"inch", geom_ok.b0); digits=2)
    b0_bad = round(ustrip(u"inch", geom_bad.b0); digits=2)
    _row("10", "FIXED",
         "ACI 318-11 §11.11.7 / R11.11.7.2 (corpus: aci-318-11, pages 209–211)",
         "named c1=12 in, c2=24 in, free edge // c1 → ACI c1=$(ustrip(u"inch", ori.c1)) in, M_edge=Mux; b0=$b0_ok in vs unswapped $b0_bad in")

    P = 100.0kip; B = 10.0u"ft"; L = 10.0u"ft"
    q = SS._eccentric_soil_pressure(P, P * (L / 6), 0.0kip * u"ft", B, L)
    _row("11", "FIXED",
         "ACI 336.2R §3.2.1 Eq. (3-1) / §4.1 (corpus: aci-336-combined-footings-mats, pages 6–7)",
         "e=L/6 → q_max/qu = $(round(ustrip(q.q_max / q.qu); digits=6)) (oracle 2.0); grouped IS combined now forwards Mux/Muy")

    _row("12", "RECLASSIFIED — DOCUMENTED/SCOPE",
         "AISC 360-16 Appendix 8 B2 (corpus: aisc-360-16)",
         "compute_B2 exists; AISCChecker does not apply it. SteelMemberGeometry.braced defaults to true.")

    fea = SS.FEA(design_approach = :area, moment_transform = :projection)
    _row("13", "FIXED (cheap) / documented default :frame+:projection",
         "FEA moment_transform (not a published-code clause)",
         ":area+:projection coerced to :wood_armer (got $(fea.moment_transform)). Default :frame+:projection is documented.")

    _row("14", "RECLASSIFIED — SCOPE in main pipeline; cheap ACI spread reject",
         "Asap.to_kip(Real) assumes kip",
         "ACI design_footing throws ArgumentError on bare-Real Pu. Main Asap path still assumes kip for Real.")

    sec = W("W16X26")
    sec.material = A992_Steel
    Lb = 20.0u"ft"
    φMn_ltb = ustrip(u"N*m", get_ϕMn(sec, A992_Steel; Lb = Lb, Cb = 1.0, axis = :strong))
    φMn_pl  = 0.9 * ustrip(u"Pa", A992_Steel.Fy) * ustrip(u"m^3", sec.Zx)
    φMn_pop = StructuralSynthesizer._steel_column_φMnx(sec, Lb; Cb = 1.0)
    _row("15", "FIXED",
         "AISC 360-16 §F2.2 / §H1.1 (corpus: aisc-360-16, pages 103 / 133)",
         "W16X26 Lb=20 ft: φMn_LTB=$(round(φMn_ltb/1000; digits=1)) kN·m; φMn_plastic=$(round(φMn_pl/1000; digits=1)) kN·m; populate helper=$(round(something(φMn_pop, NaN)/1000; digits=1)) kN·m. Mux between them fails sizer and populate, would have passed plastic Mp.")

    Ie_w = weighted_effective_Ie(100.0, 400.0, 400.0; position = :interior)
    _row("Ie relabel", "RELABELED",
         "ACI 435R-95 Eq. 4-1a/b (not in corpus). ACI 318-11 §9.5.2.4 (page 132) is simple average only.",
         "Ie_mid=100, Ie_sup=400 → weighted=$(Ie_w); simple avg=250")

    As_x = SS.governing_transfer_reinforcement(
        23.0kip * u"ft", 0.0kip * u"ft", 20.0u"inch", 30.0u"inch",
        8.0u"inch", 6.5u"inch", 4000.0u"psi", 60.0ksi; position = :edge)
    As_both = SS.governing_transfer_reinforcement(
        23.0kip * u"ft", 130.0kip * u"ft", 20.0u"inch", 30.0u"inch",
        8.0u"inch", 6.5u"inch", 4000.0u"psi", 60.0ksi; position = :edge)
    _row("leftover γf", "FIXED",
         "ACI 318-11 §13.5.3.1 (corpus: aci-318-11, page 250)",
         "20×30 edge, Mux=23 / Muy=130 kip·ft: As_Mux-only=$(round(ustrip(u"inch^2", As_x.As); digits=3)) in²; governing As=$(round(ustrip(u"inch^2", As_both.As); digits=3)) in² from Muy")

    d2 = FoundationDemand(2; Pu=-200.0u"kN", Ps=-200.0u"kN",
                          c1=18.0u"inch", c2=18.0u"inch")
    As_t = abs(d2.Pu) / (0.65 * RC_4000_60.rebar.Fy)
    _row("leftover As_tensile", "FIXED",
         "ACI 318-11 §15.8.1.2(b) (corpus: aci-318-11, page 275)",
         "Pu=−200 kN → As_tensile=$(round(ustrip(u"inch^2", As_t); digits=3)) in² stored on StripFootingResult")

    println()
    println("="^72)
    println("End of report. All numeric oracles computed above or cited from tests.")
    println("="^72)
end

main()
