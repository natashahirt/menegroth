# =============================================================================
# Display Unit Preferences
# =============================================================================

"""
    DisplayUnits(system::Symbol=:imperial)

Unit preferences for design output display. All design data is stored in
coherent SI (m, m², m³, kN, kN·m, kPa, kg). `DisplayUnits` controls what
units are shown to the user in summaries, reports, and visualization labels.

Use presets `imperial` or `metric`, or customize individual categories.

# Categories
`:length`, `:thickness`, `:span`, `:area`, `:volume`, `:force`, `:moment`,
`:pressure`, `:stress`, `:weight`, `:mass`, `:deflection`, `:spacing`,
`:rebar_dia`, `:rebar_area`

# Example
```julia
# Use presets
params = DesignParameters(display_units = imperial)
params = DesignParameters(display_units = metric)

# Customize: imperial but volume in m³
du = DisplayUnits(:imperial)
du.units[:volume] = u"m^3"
params = DesignParameters(display_units = du)
```
"""
mutable struct DisplayUnits
    units::Dict{Symbol, Any}
end

"""Construct `DisplayUnits` from a system preset (`:imperial` or `:metric`)."""
function DisplayUnits(system::Symbol)
    system === :imperial ? DisplayUnits(_imperial_units()) :
    system === :metric   ? DisplayUnits(_metric_units()) :
    error("Unknown unit system :$system. Use :imperial or :metric.")
end

"""Build the imperial unit lookup table."""
function _imperial_units()
    Dict{Symbol, Any}(
        :length      => u"ft",
        :thickness   => u"inch",
        :span        => u"ft",
        :area        => u"ft^2",
        :volume      => u"ft^3",
        :force       => kip,
        :moment      => kip * u"ft",
        :pressure    => psf,
        :stress      => ksi,
        :weight      => u"lbf",
        :mass        => u"lb",
        :deflection  => u"inch",
        :spacing     => u"inch",
        :rebar_dia   => u"inch",
        :rebar_area  => u"inch^2",
    )
end

"""Build the metric unit lookup table."""
function _metric_units()
    Dict{Symbol, Any}(
        :length      => u"m",
        :thickness   => u"mm",
        :span        => u"m",
        :area        => u"m^2",
        :volume      => u"m^3",
        :force       => u"kN",
        :moment      => u"kN*m",
        :pressure    => u"kPa",
        :stress      => u"MPa",
        :weight      => u"kN",
        :mass        => u"kg",
        :deflection  => u"mm",
        :spacing     => u"mm",
        :rebar_dia   => u"mm",
        :rebar_area  => u"mm^2",
    )
end

const imperial = DisplayUnits(:imperial)
const metric   = DisplayUnits(:metric)

"""
    fmt(du::DisplayUnits, category::Symbol, value; digits=2)

Convert a Unitful value to display units and round.

# Example
```julia
fmt(imperial, :span, 12.192u"m")       # → 40.0 ft
fmt(imperial, :thickness, 0.2032u"m")  # → 8.0 inch
fmt(metric, :force, 100.0u"kN")        # → 100.0 kN
```
"""
fmt(du::DisplayUnits, cat::Symbol, val; digits=2) = round(du.units[cat], val; digits=digits)

