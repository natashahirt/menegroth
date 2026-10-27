# Per-case worker function for sweep_design_building.jl (included on every
# worker after the spec file, which provides `build_case`).

# Element × material columns. Concrete is m³; rebar and structural steel are kg.
# The matching `*_ec_*` columns are kgCO₂e. Summing one material across the
# five element groups equals the building-level material total.
const _TAKEOFF_GROUPS = (:slab, :column, :beam, :strut, :foundation)
const _TAKEOFF_FIELDS = (:takeoff_slabs, :takeoff_columns, :takeoff_beams,
                         :takeoff_struts, :takeoff_foundations)

function _takeoff_column_names()
    names = Symbol[]
    for prefix in _TAKEOFF_GROUPS
        append!(names, (
            Symbol("$(prefix)_concrete_m3"),
            Symbol("$(prefix)_rebar_kg"),
            Symbol("$(prefix)_structural_steel_kg"),
            Symbol("$(prefix)_ec_concrete_kgCO2e"),
            Symbol("$(prefix)_ec_rebar_kgCO2e"),
            Symbol("$(prefix)_ec_structural_steel_kgCO2e"),
        ))
    end
    return Tuple(names)
end

const _TAKEOFF_COLUMNS = _takeoff_column_names()

const RESULT_COLUMNS = (:status, :seconds, :embodied_carbon_kgCO2e, :ec_slabs_kgCO2e,
                        :ec_columns_kgCO2e, :ec_foundations_kgCO2e,
                        :ec_concrete_kgCO2e, :ec_rebar_kgCO2e, :ec_structural_steel_kgCO2e,
                        :concrete_m3, :steel_kg, :rebar_kg,
                        _TAKEOFF_COLUMNS...,
                        :all_checks_pass, :critical_element, :critical_ratio, :error)

function _takeoff_row(summary)
    values = Float64[]
    for field in _TAKEOFF_FIELDS
        t = getfield(summary, field)
        append!(values, (
            ustrip(u"m^3", t.concrete_volume),
            ustrip(u"kg", t.rebar_mass),
            ustrip(u"kg", t.structural_steel_mass),
            ustrip(u"kgCO2e", t.concrete_ec),
            ustrip(u"kgCO2e", t.rebar_ec),
            ustrip(u"kgCO2e", t.structural_steel_ec),
        ))
    end
    return NamedTuple{_TAKEOFF_COLUMNS}(Tuple(values))
end

_takeoff_row_nan() = NamedTuple{_TAKEOFF_COLUMNS}(ntuple(_ -> NaN, length(_TAKEOFF_COLUMNS)))

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
        return merge((
                status = "ok", seconds = time() - t0,
                embodied_carbon_kgCO2e = kg(s.embodied_carbon), ec_slabs_kgCO2e = kg(s.embodied_carbon_slabs),
                ec_columns_kgCO2e = kg(s.embodied_carbon_columns),
                ec_foundations_kgCO2e = kg(s.embodied_carbon_foundations),
                ec_concrete_kgCO2e = kg(s.embodied_carbon_concrete),
                ec_rebar_kgCO2e = kg(s.embodied_carbon_rebar),
                ec_structural_steel_kgCO2e = kg(s.embodied_carbon_structural_steel),
                concrete_m3 = ustrip(u"m^3", s.concrete_volume), steel_kg = ustrip(u"kg", s.steel_weight),
                rebar_kg = ustrip(u"kg", s.rebar_weight),
            ), _takeoff_row(s), (
                all_checks_pass = s.all_checks_pass,
                critical_element = s.critical_element, critical_ratio = s.critical_ratio, error = "",
            ))
    catch e
        msg = first(split(sprint(showerror, e), '\n'))
        return merge((
                status = "error", seconds = time() - t0,
                embodied_carbon_kgCO2e = NaN, ec_slabs_kgCO2e = NaN, ec_columns_kgCO2e = NaN,
                ec_foundations_kgCO2e = NaN, ec_concrete_kgCO2e = NaN, ec_rebar_kgCO2e = NaN,
                ec_structural_steel_kgCO2e = NaN, concrete_m3 = NaN, steel_kg = NaN, rebar_kg = NaN,
            ), _takeoff_row_nan(), (
                all_checks_pass = false, critical_element = "", critical_ratio = NaN,
                error = msg[1:min(end, 200)],
            ))
    end
end
