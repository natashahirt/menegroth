# Compare the deck floor's computed weight and SDI Eq. 2.4.7c shear (f′c = 3000 psi)
# with the Vulcraft printed weight and Vno/Ω for every tabulated row.
ENV["SS_ENABLE_VISUALIZATION"] = "false"
using StructuralSizer, Unitful, Asap
const SS = StructuralSizer

conc = SS.Concrete(SS._aci_Ec(3000u"psi", 145u"lb/ft^3"), 3000u"psi", uconvert(u"kg/m^3", 145u"lb/ft^3"), 0.2, 0.1u"kgCO2e/kg")
for name in ("1.5VL", "2VLI", "3VLI")
    p = composite_deck_profile(name)
    for (d, row) in sort(collect(SS._SLAB_ASD_145[name]); by=first), g in SS._BEARING_GAGES
        c = deck_slab_candidate(p, d * u"inch", g, 8u"ft", 0u"psf", 0u"psf"; concrete=conc)
        println(rpad("$name $(d)in g$g", 16),
                " w calc ", round(ustrip(u"psf", c.self_weight); digits=2),
                " cat ", ustrip(u"psf", c.catalog_weight),
                " | V calc ", round(ustrip(u"kip/ft", c.Vn_over_Ω); digits=3),
                " cat ", ustrip(u"kip/ft", c.catalog_Vno_over_Ω),
                " ", c.shear.governing)
    end
end
