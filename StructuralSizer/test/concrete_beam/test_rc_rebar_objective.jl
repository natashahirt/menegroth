# Weight, cost, and carbon of an RC section include the longitudinal bars.
# Ties and stirrups stay out, matching the continuous optimizer.
# Volume stays the gross area: steel replaces concrete.

using Test
using Unitful
using Asap
using StructuralSizer

const L = 1.0u"m"

"""Concrete mass of (Ag − As) plus steel mass of As, over `L`."""
function split_mass(Ag, As, concrete, rebar)
    Ac = Ag - As
    uconvert(u"kg", (Ac * concrete.ρ + As * rebar.ρ) * L)
end

@testset "RC objectives count longitudinal rebar" begin
    beam = RCBeamSection(b=12u"inch", h=20u"inch", bar_size=9, n_bars=3, stirrup_size=3)
    doubly = RCBeamSection(b=12u"inch", h=20u"inch", bar_size=9, n_bars=3,
                           bar_size_prime=6, n_bars_prime=2, stirrup_size=3)
    Ag = beam.b * beam.h
    As = beam.As + beam.As_prime
    @test As > zero(As)
    @test doubly.As_prime > beam.As_prime

    plain_w = objective_value(MinWeight(), beam, NWC_4000, L)
    split_w = objective_value(MinWeight(), beam, NWC_4000, L; rebar=Rebar_60)
    @test plain_w ≈ uconvert(u"kN", Ag * L * NWC_4000.ρ * 1u"gn")
    @test split_w ≈ uconvert(u"kN", split_mass(Ag, As, NWC_4000, Rebar_60) * 1u"gn")
    @test split_w > plain_w

    # Same gross section. Extra compression bars add weight only when rebar is counted.
    @test objective_value(MinWeight(), doubly, NWC_4000, L) ≈ plain_w
    @test objective_value(MinWeight(), doubly, NWC_4000, L; rebar=Rebar_60) > split_w

    @test objective_value(MinVolume(), beam, NWC_4000, L; rebar=Rebar_60) ≈
          uconvert(u"m^3", Ag * L)

    carbon = objective_value(MinCarbon(), beam, NWC_4000, L; rebar=Rebar_60)
    expected_c = uconvert(u"kgCO2e",
        (Ag - As) * L * NWC_4000.ρ * NWC_4000.ecc + As * L * Rebar_60.ρ * Rebar_60.ecc)
    @test carbon ≈ expected_c
    @test carbon > objective_value(MinCarbon(), beam, NWC_4000, L)

    conc = Concrete(NWC_4000.E, NWC_4000.fc′, NWC_4000.ρ, NWC_4000.ν, NWC_4000.ecc; cost=0.12)
    rebar = RebarSteel(Rebar_60.E, Rebar_60.G, Rebar_60.Fy, Rebar_60.Fu,
                       Rebar_60.ρ, Rebar_60.ν, Rebar_60.ecc; cost=0.90)
    cost = objective_value(MinCost(), beam, conc, L; rebar=rebar)
    mc = uconvert(u"kg", (Ag - As) * L * conc.ρ)
    ms = uconvert(u"kg", As * L * rebar.ρ)
    @test cost ≈ mc * 0.12 + ms * 0.90
    @test_throws ErrorException objective_value(MinCost(), beam, NWC_4000, L; rebar=Rebar_60)

    col = RCColumnSection(b=16u"inch", h=16u"inch", bar_size=8, n_bars=8)
    cAg = col.b * col.h
    col_w = objective_value(MinWeight(), col, NWC_4000, L; rebar=Rebar_60)
    @test col_w ≈ split_mass(cAg, col.As_total, NWC_4000, Rebar_60)
    @test col_w > objective_value(MinWeight(), col, NWC_4000, L)

    circ = RCCircularSection(; D=20.0u"inch", bar_size=8, n_bars=8, cover=1.5u"inch")
    circ_w = objective_value(MinWeight(), circ, NWC_4000, L; rebar=Rebar_60)
    @test circ_w ≈ split_mass(circ.Ag, circ.As_total, NWC_4000, Rebar_60)

    tbeam = RCTBeamSection(bw=12u"inch", h=24u"inch", bf=48u"inch", hf=5u"inch",
                           bar_size=9, n_bars=3)
    web = tbeam.bw * tbeam.h
    t_w = objective_value(MinWeight(), tbeam, NWC_4000, L; rebar=Rebar_60)
    @test t_w ≈ uconvert(u"kN",
        split_mass(web, tbeam.As + tbeam.As_prime, NWC_4000, Rebar_60) * 1u"gn")
    # The flange is slab concrete and is not in this objective.
    @test web < tbeam.bf * tbeam.hf + web
end
