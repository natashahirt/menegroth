
# ─── Name → object resolution helpers ────────────────────────────────────────

const CONCRETE_MAP = Dict{String, StructuralSizer.Concrete}(
    "NWC_3000" => StructuralSizer.NWC_3000,
    "NWC_4000" => StructuralSizer.NWC_4000,
    "NWC_5000" => StructuralSizer.NWC_5000,
    "NWC_6000" => StructuralSizer.NWC_6000,
    "Earthen_500" => StructuralSizer.Earthen_500,
    "Earthen_1000" => StructuralSizer.Earthen_1000,
    "Earthen_2000" => StructuralSizer.Earthen_2000,
    "Earthen_4000" => StructuralSizer.Earthen_4000,
    "Earthen_8000" => StructuralSizer.Earthen_8000,
)

const REBAR_MAP = Dict{String, StructuralSizer.RebarSteel}(
    "Rebar_40" => StructuralSizer.Rebar_40,
    "Rebar_60" => StructuralSizer.Rebar_60,
    "Rebar_75" => StructuralSizer.Rebar_75,
    "Rebar_80" => StructuralSizer.Rebar_80,
)

const STEEL_MAP = Dict{String, StructuralSizer.StructuralSteel}(
    "A992" => StructuralSizer.A992_Steel,
)

const SOIL_MAP = Dict{String, StructuralSizer.Soil}(
    "loose_sand"  => StructuralSizer.loose_sand,
    "medium_sand" => StructuralSizer.medium_sand,
    "dense_sand"  => StructuralSizer.dense_sand,
    "soft_clay"   => StructuralSizer.soft_clay,
    "stiff_clay"  => StructuralSizer.stiff_clay,
    "hard_clay"   => StructuralSizer.hard_clay,
)

"""Generic named-value resolver: look up `name` in `map`, or error listing options."""
function _resolve_from_map(name::String, map::Dict, label::String)
    haskey(map, name) && return map[name]
    error("Unknown $label: \"$name\". Options: $(join(keys(map), ", "))")
end

_resolve_concrete_name(name::String) = _resolve_from_map(name, CONCRETE_MAP, "concrete grade")
_resolve_rebar_name(name::String)    = _resolve_from_map(name, REBAR_MAP,    "rebar grade")
_resolve_steel_name(name::String)    = _resolve_from_map(name, STEEL_MAP,    "steel type")
_resolve_soil_name(name::String)     = _resolve_from_map(name, SOIL_MAP,     "soil type")

"""API coating names, the strings of `StructuralSizer.REBAR_COATINGS`."""
const REBAR_COATING_NAMES = Tuple(String(c) for c in StructuralSizer.REBAR_COATINGS)

"""Rebar grade from `materials.rebar` with the project coating from `materials.rebar_coating`."""
function _resolve_rebar(api_params::APIParams)
    rebar = _resolve_rebar_name(api_params.materials.rebar)
    coating = api_params.materials.rebar_coating
    coating in REBAR_COATING_NAMES || error(
        "Unknown rebar coating: \"$coating\". Options: $(join(REBAR_COATING_NAMES, ", "))")
    coating == "uncoated" && return rebar
    return StructuralSizer.with_coating(rebar, Symbol(coating))
end

"""Resolve all three material names from API params. Returns `(concrete, rebar, steel)`."""
function _resolve_materials(api_params::APIParams)
    return (
        _resolve_concrete_name(api_params.materials.concrete),
        _resolve_rebar(api_params),
        _resolve_steel_name(api_params.materials.steel),
    )
end
