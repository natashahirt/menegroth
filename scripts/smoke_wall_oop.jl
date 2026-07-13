# Standalone oracle-validation smoke test for the ACI 318-19 §11.8 out-of-plane
# slender wall module (StructuralSizer/src/walls/out_of_plane.jl). Runs the
# bare-SI core in isolation — no full-package load — against the spWall tilt-up
# worked example (corpus: sp-de-tilt-up-wall-aci19, note-w0000014). Immune to any
# concurrent edits to the rest of the package sources.

using Unitful
using Printf

# --- minimal prerequisites the module's bare-SI core references ---------------
const _KSI_TO_PA = 6.894757e6
_beta1_from_fc_psi(fc_psi) = fc_psi ≤ 4000 ? 0.85 :
                             fc_psi ≥ 8000 ? 0.65 : 0.85 - 0.05 * (fc_psi - 4000) / 1000
function wall_phi_flexure(εt::Real, εty::Real)
    εt_tc = εty + 0.003
    εt ≤ εty   && return 0.65
    εt ≥ εt_tc && return 0.90
    return 0.65 + 0.25 * (εt - εty) / 0.003
end

include(joinpath(@__DIR__, "..", "StructuralSizer", "src", "walls", "out_of_plane.jl"))

# --- unit conversions (US → SI) ----------------------------------------------
const IN = 0.0254; const FT = 0.3048; const KIP = 4448.2216
const PSI = 6894.757; const IN2 = IN^2; const IN4 = IN^4
const KIPFT = KIP * FT; const KIP_PER_FT = KIP / FT

# --- oracle inputs ------------------------------------------------------------
fc = 4000 * PSI; fy = 60000 * PSI; Es = 29e6 * PSI
b = 180 * IN; h = 6.25 * IN; d = 3.13 * IN; lc = 29.5 * FT; e = 3.0 * IN
As = 7.04 * IN2
Pua = 20.64 * KIP; Pum = 43.49 * KIP; wu = 0.204 * KIP_PER_FT

str = oop_slender_wall_strength_si(fc, fy, Es, b, h, d, lc, e, As, Pua, Pum, wu)

npass = Ref(0); nfail = Ref(0)
function check(name, got, want, unit; rtol=1e-2)
    ok = isapprox(got, want; rtol=rtol)
    ok ? npass[] += 1 : nfail[] += 1
    @printf("  [%s] %-26s got %-12.4f want %-12.4f (%s)\n",
            ok ? "OK" : "XX", name, got, want, unit)
end

println("=== §11.8 out-of-plane slender wall — spWall tilt-up oracle ===")
check("Ase (in^2)", str.Ase / IN2, 7.76, "in^2")
check("a (in)",     str.a / IN,    0.761, "in"; rtol=2e-2)
check("c (in)",     str.c / IN,    0.896, "in"; rtol=2e-2)
check("εt",         str.εt,        0.0075, "-"; rtol=3e-2)
check("Icr (in^4)", str.Icr / IN4, 353.56, "in^4"; rtol=2e-2)
check("Kb (kip)",   str.Kb / KIP,  97.64, "kip"; rtol=2e-2)
check("Mua (k-ft)", str.Mua / KIPFT, 24.77, "kip-ft")
check("Mu (k-ft)",  str.Mu / KIPFT,  61.00, "kip-ft"; rtol=2e-2)
check("Mcr (k-ft)", str.Mcr / KIPFT, 46.32, "kip-ft")
check("Mn (k-ft)",  str.Mn / KIPFT,  106.55, "kip-ft")
check("φMn (k-ft)", str.φMn / KIPFT, 95.89, "kip-ft")
check("Δu (in)",    str.Δu / IN,     9.995, "in"; rtol=2e-2)
@printf("  tension_controlled = %s (want true),  φ = %.2f (want 0.90),  stable = %s\n",
        str.tension_controlled, str.φ, str.stable)

# --- gates --------------------------------------------------------------------
Msa = 20.32 * KIPFT; Ps = 26.24 * KIP
svc = oop_service_deflection_si(Msa, Ps, str.Mcr, str.Mn, str.Ec, str.Ig, str.Icr, lc)
check("Δcr (in)", svc.Δcr / IN, 0.550, "in"; rtol=2e-2)
check("Δs (in)",  svc.Δs / IN,  0.247, "in"; rtol=5e-2)

gates = oop_slender_wall_gates(str, fc, b, h, lc, Pum; Δs=svc.Δs)
check("σ_axial (psi)", gates.σ_axial / PSI, 38.66, "psi"; rtol=2e-2)
check("σ_limit (psi)", gates.σ_limit / PSI, 240.0, "psi")
@printf("  gates: b(TC)=%s c(φMn≥Mcr)=%s d(σ≤0.06f'c)=%s e(Δs≤lc/150)=%s → applicable=%s\n",
        gates.gate_b, gates.gate_c, gates.gate_d, gates.gate_e, gates.applicable)

@printf("\n=== %d passed, %d failed ===\n", npass[], nfail[])
exit(nfail[] == 0 ? 0 : 1)
