# Weight and carbon of an RC section include the longitudinal bars and the
# ties or stirrups. Every RC weight is kilograms. Cost stays the gross volume.

using Test
using Unitful
using Asap
using StructuralSizer

const L_REBAR_OBJ = 1.0u"m"

"""Concrete on what the steel does not occupy, plus both steels, over `L_REBAR_OBJ`."""
function counted_mass(Ag, As_long, As_tr, concrete, rebar)
    Ac = Ag - As_long - As_tr
    uconvert(u"kg", (Ac * concrete.ρ + (As_long + As_tr) * rebar.ρ) * L_REBAR_OBJ)
end

@testset "RC objectives count longitudinal rebar" begin
    beam = RCBeamSection(b=12u"inch", h=20u"inch", bar_size=9, n_bars=3, stirrup_size=3)
    heavy_stir = RCBeamSection(b=12u"inch", h=20u"inch", bar_size=9, n_bars=3, stirrup_size=5)
    doubly = RCBeamSection(b=12u"inch", h=20u"inch", bar_size=9, n_bars=3,
                           bar_size_prime=6, n_bars_prime=2, stirrup_size=3)
    Ag = beam.b * beam.h
    As = beam.As + beam.As_prime
    As_tr = StructuralSizer.transverse_steel_per_length(beam, NWC_4000, Rebar_60)
    @test As > zero(As)
    @test As_tr > zero(As_tr)
    @test doubly.As_prime > beam.As_prime

    plain_w = objective_value(MinWeight(), beam, NWC_4000, L_REBAR_OBJ)
    split_w = objective_value(MinWeight(), beam, NWC_4000, L_REBAR_OBJ; rebar=Rebar_60)
    @test unit(plain_w) == u"kg"
    @test plain_w ≈ uconvert(u"kg", Ag * L_REBAR_OBJ * NWC_4000.ρ)
    @test split_w ≈ counted_mass(Ag, As, As_tr, NWC_4000, Rebar_60)
    # Stirrups add mass beyond the longitudinal bars.
    @test split_w > counted_mass(Ag, As, zero(As_tr), NWC_4000, Rebar_60)
    # A larger stirrup bar, same longitudinal steel, weighs more.
    @test objective_value(MinWeight(), heavy_stir, NWC_4000, L_REBAR_OBJ; rebar=Rebar_60) > split_w

    # Same gross section. Extra compression bars add weight only when rebar is counted.
    @test objective_value(MinWeight(), doubly, NWC_4000, L_REBAR_OBJ) ≈ plain_w
    @test objective_value(MinWeight(), doubly, NWC_4000, L_REBAR_OBJ; rebar=Rebar_60) > split_w

    # Cost and volume stay the gross concrete volume.
    @test objective_value(MinVolume(), beam, NWC_4000, L_REBAR_OBJ; rebar=Rebar_60) ≈
          uconvert(u"m^3", Ag * L_REBAR_OBJ)
    @test objective_value(MinCost(), beam, NWC_4000, L_REBAR_OBJ; rebar=Rebar_60) ≈
          uconvert(u"m^3", Ag * L_REBAR_OBJ)

    carbon = objective_value(MinCarbon(), beam, NWC_4000, L_REBAR_OBJ; rebar=Rebar_60)
    Ac = Ag - As - As_tr
    expected_c = uconvert(u"kgCO2e",
        (Ac * NWC_4000.ρ * NWC_4000.ecc + (As + As_tr) * Rebar_60.ρ * Rebar_60.ecc) * L_REBAR_OBJ)
    @test carbon ≈ expected_c
    @test carbon > objective_value(MinCarbon(), beam, NWC_4000, L_REBAR_OBJ)

    col = RCColumnSection(b=16u"inch", h=16u"inch", bar_size=8, n_bars=8)
    cAg = col.b * col.h
    c_tr = StructuralSizer.transverse_steel_per_length(col, NWC_4000, Rebar_60)
    @test c_tr > zero(c_tr)
    col_w = objective_value(MinWeight(), col, NWC_4000, L_REBAR_OBJ; rebar=Rebar_60)
    @test col_w ≈ counted_mass(cAg, col.As_total, c_tr, NWC_4000, Rebar_60)
    @test unit(col_w) == u"kg"

    circ = RCCircularSection(; D=20.0u"inch", bar_size=8, n_bars=8, cover=1.5u"inch")
    circ_tr = StructuralSizer.transverse_steel_per_length(circ, NWC_4000, Rebar_60)
    @test circ.tie_type == :spiral
    @test circ_tr > zero(circ_tr)
    circ_w = objective_value(MinWeight(), circ, NWC_4000, L_REBAR_OBJ; rebar=Rebar_60)
    @test circ_w ≈ counted_mass(circ.Ag, circ.As_total, circ_tr, NWC_4000, Rebar_60)

    tbeam = RCTBeamSection(bw=12u"inch", h=24u"inch", bf=48u"inch", hf=5u"inch",
                           bar_size=9, n_bars=3)
    web = tbeam.bw * tbeam.h
    t_tr = StructuralSizer.transverse_steel_per_length(tbeam, NWC_4000, Rebar_60)
    t_w = objective_value(MinWeight(), tbeam, NWC_4000, L_REBAR_OBJ; rebar=Rebar_60)
    @test unit(t_w) == u"kg"
    @test t_w ≈ counted_mass(web, tbeam.As + tbeam.As_prime, t_tr, NWC_4000, Rebar_60)
    # The flange is slab concrete and is not in this objective.
    @test web < tbeam.bf * tbeam.hf + web
end
