# =============================================================================
# Gravity Loads — Unfactored service-level loads
# =============================================================================
#
# Configurable unfactored service loads that flow through
# DesignParameters → initialize! → cells.
#
# Each field accepts any Unitful pressure (psf, kPa, Pa, lbf/ft², …).
# Mixed units across fields are fine:
#   GravityLoads(floor_LL = 2.4u"kPa", floor_SDL = 15.0psf)
#
# Reference: ASCE 7-22 Table 4.3-1 (minimum uniformly distributed live loads)
# =============================================================================

"""
    GravityLoads(; floor_LL, roof_LL, grade_LL, floor_SDL, roof_SDL, wall_SDL)

Unfactored service-level gravity loads for a building.

Stamped onto `Cell.sdl` / `Cell.live_load` during `initialize_cells!` and
then factored by `LoadCombination`s when building the Asap model.

# Fields
- `floor_LL`:  Floor live load (ASCE 7-22 Table 4.3-1)
- `roof_LL`:   Roof live load
- `grade_LL`:  Grade / ground floor live load
- `floor_SDL`: Superimposed dead load — floor finish, MEP, partitions
- `roof_SDL`:  Superimposed dead load — roofing, insulation, MEP
- `wall_SDL`:  Cladding / curtain wall dead load (per unit area of wall)

# Presets
| Preset              | floor_LL | floor_SDL | Notes                           |
|:--------------------|:---------|:----------|:--------------------------------|
| `default_loads`     | 80 psf   | 15 psf    | Conservative (incl. partitions) |
| `office_loads`      | 50 psf   | 15 psf    | ASCE 7 Table 4.3-1             |
| `residential_loads` | 40 psf   | 10 psf    | Dwellings                       |
| `assembly_loads`    | 100 psf  | 20 psf    | Movable seating                 |
| `retail_loads`      | 100 psf  | 15 psf    | First floor retail              |
| `storage_loads`     | 125 psf  | 15 psf    | Light storage                   |
| `parking_loads`     | 40 psf   |  5 psf    | Passenger vehicles              |

# Example
```julia
# Use a preset
params = DesignParameters(loads = office_loads)

# Custom loads
params = DesignParameters(
    loads = GravityLoads(floor_LL = 65.0psf, floor_SDL = 20.0psf),
)

# Sweep live loads in a parametric study
for ll in [40, 50, 65, 80, 100]
    design = design_building(struc, DesignParameters(
        loads = GravityLoads(floor_LL = Float64(ll) * psf),
    ))
end
```
"""
struct GravityLoads
    floor_LL::Pressure
    roof_LL::Pressure
    grade_LL::Pressure
    floor_SDL::Pressure
    roof_SDL::Pressure
    wall_SDL::Pressure
end

# Keyword constructor with psf defaults (matching previous Constants.jl values)
function GravityLoads(;
    floor_LL  = 80.0psf,
    roof_LL   = 20.0psf,
    grade_LL  = 100.0psf,
    floor_SDL = 15.0psf,
    roof_SDL  = 15.0psf,
    wall_SDL  = 10.0psf,
)
    GravityLoads(floor_LL, roof_LL, grade_LL, floor_SDL, roof_SDL, wall_SDL)
end

function Base.show(io::IO, g::GravityLoads)
    print(io, "GravityLoads(floor_LL=$(g.floor_LL), roof_LL=$(g.roof_LL), ",
              "grade_LL=$(g.grade_LL), floor_SDL=$(g.floor_SDL), ",
              "roof_SDL=$(g.roof_SDL), wall_SDL=$(g.wall_SDL))")
end

# =============================================================================
# Standard Presets (ASCE 7-22 Table 4.3-1)
# =============================================================================

"""Default loads: conservative LL with partition allowance."""
const default_loads = GravityLoads()

"""Office occupancy: 50 psf LL per ASCE 7-22 Table 4.3-1."""
const office_loads = GravityLoads(floor_LL = 50.0psf)

"""Residential (one/two-family dwellings): 40 psf LL, light SDL."""
const residential_loads = GravityLoads(floor_LL = 40.0psf, floor_SDL = 10.0psf)

"""Assembly with movable seating: 100 psf LL."""
const assembly_loads = GravityLoads(floor_LL = 100.0psf, floor_SDL = 20.0psf)

"""Retail (first floor / ground): 100 psf LL."""
const retail_loads = GravityLoads(floor_LL = 100.0psf)

"""Light storage: 125 psf LL."""
const storage_loads = GravityLoads(floor_LL = 125.0psf)

"""Parking garage (passenger vehicles): 40 psf LL, minimal SDL."""
const parking_loads = GravityLoads(floor_LL = 40.0psf, floor_SDL = 5.0psf)

"""Hospital / institutional: 60 psf LL, heavier SDL for equipment."""
const hospital_loads = GravityLoads(floor_LL = 60.0psf, floor_SDL = 25.0psf)

"""School classrooms: 40 psf LL."""
const school_loads = GravityLoads(floor_LL = 40.0psf)

# =============================================================================
# Load Map Helper
# =============================================================================

"""
    load_map(g::GravityLoads)

Build the `(floor_group => (LL, SDL))` mapping for `initialize_cells!`.

Returns:
```
[:grade => (g.grade_LL, g.floor_SDL),
 :floor => (g.floor_LL, g.floor_SDL),
 :roof  => (g.roof_LL,  g.roof_SDL)]
```
"""
function load_map(g::GravityLoads)
    return [
        :grade => (g.grade_LL, g.floor_SDL),
        :floor => (g.floor_LL, g.floor_SDL),
        :roof  => (g.roof_LL,  g.roof_SDL),
    ]
end
