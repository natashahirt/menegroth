# Floor systems for a Slab Design Factors plan.
#
# `one_way` and `two_way` are reinforced-concrete T-beam floors. `deck` is the
# composite steel deck and composite steel beams Melody Tan sized in ETABS
# (MEng thesis, 2016, §3.2 and §3.4), with the two catalog limits below.

"""Loads for one plan. Parametric grids use her office loads."""
function plan_loads(name::AbstractString)
    base = basename(name)
    if base == "office"
        (ll = 60.0, sdl = 20.0, occupancy = "office")
    elseif base == "school"
        (ll = 50.0, sdl = 20.0, occupancy = "school")
    elseif base == "warehouse"
        (ll = 250.0, sdl = 20.0, occupancy = "warehouse")
    else
        (ll = 60.0, sdl = 20.0, occupancy = "parametric")
    end
end

"""Normal-weight fill at 145 lb/ft³, the only density the unshored span table accepts."""
const DECK_FILL = SR.Concrete(SR.NWC_4000.E, SR.NWC_4000.fc′,
                              uconvert(u"kg/m^3", 145.0u"lb/ft^3"), 0.2, SR.NWC_4000.ecc)

"""
    system_parameters(name, system) -> DesignParameters

`deck` follows Tan's ETABS setup where the catalog allows it:

- A992 steel, composite beams, unshored, 3/4 in studs 6 in long with Fu = 65 ksi
  (her Appendix F).
- Deflection L/360 for live load and L/240 for dead plus live (§3.2).
- Deck profile `3VLI`. Her Table 3-1 is a 3 in rib at 12 in, 7.5 in over 4.5 in,
  with 3.25 in of concrete above the rib (6.25 in total). `3VLI` is the Vulcraft
  3 in profile (7.25 in over 4.75 in). Its tabulated totals are 5.0, 6.5, and
  7.5 in, so the sizer picks among those rather than 6.25 in.
- Fill density 145 lb/ft³. Her MATLAB set the concrete unit weight to 110, and
  the unshored-span table throws for anything other than 145
  (`select_unshored_deck_gage`).
- Her 500 plf perimeter facade is not applied.

Concrete floors use the same area loads, T-beam flanges, and normal-weight
4000 psi concrete. Columns are sized because the frame needs them; her study
did not design columns.
"""
function system_parameters(name::AbstractString, system::Symbol)
    loads = plan_loads(name)
    gravity = GravityLoads(
        floor_LL = loads.ll * u"psf",
        floor_SDL = loads.sdl * u"psf",
        roof_LL = loads.ll * u"psf",
        roof_SDL = loads.sdl * u"psf",
    )
    common = (;
        name = "sdf:$name:$system",
        loads = gravity,
        max_iterations = 8,
        skip_visualization = true,
    )
    if system === :one_way || system === :two_way
        return DesignParameters(;
            floor = system === :one_way ? SR.OneWayOptions() : SR.TwoWayOptions(),
            beams = SR.ConcreteBeamOptions(material = SR.NWC_4000, include_flange = true),
            columns = SR.ConcreteColumnOptions(material = SR.NWC_4000),
            materials = MaterialOptions(concrete = SR.NWC_4000, rebar = SR.Rebar_60),
            common...)
    elseif system === :deck
        return DesignParameters(;
            floor = SR.CompositeDeckOptions(
                deck_profile = "3VLI",
                fill_material = DECK_FILL,
                live_deflection_limit = 1 / 360,
                superimposed_deflection_limit = 1 / 240,
            ),
            beams = SR.SteelBeamOptions(
                composite = true,
                composite_slab_type = :deck,
                composite_deck_profile = "3VLI",
                composite_shored = false,
                composite_anchor_d = 0.75u"inch",
                composite_anchor_length = 6.0u"inch",
                composite_anchor_Fu = 65.0u"ksi",
                deflection_limit = 1 / 360,
                total_deflection_limit = 1 / 240,
            ),
            columns = SR.SteelColumnOptions(),
            materials = MaterialOptions(concrete = DECK_FILL, steel = SR.A992_Steel),
            common...)
    end
    throw(ArgumentError("Unknown floor system $system. Use :one_way, :two_way, or :deck."))
end
