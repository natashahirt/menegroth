# Per-case worker function for sweep_design_building.jl (included on every
# worker after the spec file, which provides `build_case`).

const RESULT_COLUMNS = (:status, :seconds, :embodied_carbon_kgCO2e, :ec_slabs_kgCO2e,
                        :ec_columns_kgCO2e, :ec_foundations_kgCO2e,
                        :ec_concrete_kgCO2e, :ec_rebar_kgCO2e, :ec_structural_steel_kgCO2e,
                        :concrete_m3, :steel_kg,
                        :rebar_kg, :all_checks_pass, :critical_element, :critical_ratio, :error)

"""
    run_sweep_case(case) -> NamedTuple

Build and design one sweep case; never throws. Field order matches `RESULT_COLUMNS`.
"""
function run_sweep_case(case)
    t0 = time()
    try
        struc, params = build_case(case)
        d = with_logger(NullLogger()) do
            design_building(struc, params)
        end
        s = d.summary
        kg(x) = ustrip(u"kgCO2e", x)
        return (status = "ok", seconds = time() - t0,
                embodied_carbon_kgCO2e = kg(s.embodied_carbon), ec_slabs_kgCO2e = kg(s.embodied_carbon_slabs),
                ec_columns_kgCO2e = kg(s.embodied_carbon_columns),
                ec_foundations_kgCO2e = kg(s.embodied_carbon_foundations),
                ec_concrete_kgCO2e = kg(s.embodied_carbon_concrete),
                ec_rebar_kgCO2e = kg(s.embodied_carbon_rebar),
                ec_structural_steel_kgCO2e = kg(s.embodied_carbon_structural_steel),
                concrete_m3 = ustrip(u"m^3", s.concrete_volume), steel_kg = ustrip(u"kg", s.steel_weight),
                rebar_kg = ustrip(u"kg", s.rebar_weight), all_checks_pass = s.all_checks_pass,
                critical_element = s.critical_element, critical_ratio = s.critical_ratio, error = "")
    catch e
        msg = first(split(sprint(showerror, e), '\n'))
        return (status = "error", seconds = time() - t0,
                embodied_carbon_kgCO2e = NaN, ec_slabs_kgCO2e = NaN, ec_columns_kgCO2e = NaN,
                ec_foundations_kgCO2e = NaN, ec_concrete_kgCO2e = NaN, ec_rebar_kgCO2e = NaN,
                ec_structural_steel_kgCO2e = NaN, concrete_m3 = NaN, steel_kg = NaN, rebar_kg = NaN,
                all_checks_pass = false, critical_element = "", critical_ratio = NaN,
                error = msg[1:min(end, 200)])
    end
end
