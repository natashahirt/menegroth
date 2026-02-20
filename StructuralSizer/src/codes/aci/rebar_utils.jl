# ==============================================================================
# Rebar Utilities (ASTM A615)
# ==============================================================================
#
# Convenience lookups and bar selection logic shared across all concrete
# element types (slabs, beams, columns).
#
# Single source of truth: members/sections/steel/rebar.jl (REBAR_CATALOG).
# This file provides lightweight accessors and selection helpers.
# ==============================================================================

"""
    bar_diameter(bar_size::Int) -> Length

Get rebar diameter for a given bar size (e.g., #5 → 0.625").

# Example
```julia
bar_diameter(5)  # 0.625 inch
```
"""
bar_diameter(bar_size::Int) = rebar(bar_size).diameter

"""
    bar_area(bar_size::Int) -> Area

Get rebar area for a given bar size (e.g., #5 → 0.31 in²).

# Example
```julia
bar_area(5)  # 0.31 inch²
```
"""
bar_area(bar_size::Int) = rebar(bar_size).A

"""
    infer_bar_size(As::Area) -> Int

Infer rebar size number from bar area by matching to ASTM A615 catalog.
Returns the closest match within 5% tolerance.

# Example
```julia
infer_bar_size(0.79u"inch^2")  # → 8 (#8 bar)
infer_bar_size(1.00u"inch^2")  # → 9 (#9 bar)
```
"""
function infer_bar_size(As::Area)
    As_in2 = ustrip(u"inch^2", As)

    best_size = 8
    best_diff = Inf

    for sz in rebar_sizes()
        area_in2 = ustrip(u"inch^2", rebar(sz).A)
        diff = abs(As_in2 - area_in2)
        if diff < best_diff
            best_diff = diff
            best_size = sz
        end
    end

    expected = ustrip(u"inch^2", rebar(best_size).A)
    if best_diff / expected > 0.05
        @warn "Bar area $As_in2 in² doesn't closely match standard sizes, using #$best_size"
    end

    return best_size
end

# ==============================================================================
# Bar Selection
# ==============================================================================

"""
    select_bars(As_reqd, strip_width; max_spacing=18u"inch", d_agg=0.75u"inch") -> NamedTuple

Select the smallest practical bar size (#4–#8) that satisfies:
  1. `As_provided ≥ As_reqd`
  2. `spacing ≤ max_spacing`
  3. `spacing ≥ s_min` (ACI 318-11 §7.6.1 minimum clear spacing)

The minimum center-to-center spacing is `s_clear_min + db`, where
`s_clear_min = max(1″, db, 4/3 × d_agg)`.

Errors if no bar size in the range can satisfy all three constraints
simultaneously — there is no silent fallback.

# Arguments
- `As_reqd`: Required steel area
- `strip_width`: Width of section or strip
- `max_spacing`: Maximum bar spacing (default 18″)
- `d_agg`: Nominal maximum aggregate size (default ¾″)

# Returns
Named tuple: `(bar_size, n_bars, spacing, As_provided)`

# Example
```julia
bars = select_bars(2.5u"inch^2", 60u"inch")
# → (bar_size=5, n_bars=9, spacing=6.67″, As_provided=2.79 in²)
```
"""
function select_bars(As_reqd::Area, strip_width::Length;
                     max_spacing=18u"inch", d_agg=0.75u"inch")
    for bar_size in [4, 5, 6, 7, 8]
        Ab = bar_area(bar_size)
        db = bar_diameter(bar_size)

        # ACI 318-11 §7.6.1 — minimum clear spacing → center-to-center
        s_min = max(1.0u"inch", db, 4//3 * d_agg) + db

        # Number of bars: satisfy both demand and max-spacing constraints
        n_demand  = ceil(Int, ustrip(u"inch^2", As_reqd) / ustrip(u"inch^2", Ab))
        n_spacing = ceil(Int, ustrip(u"inch", strip_width) / ustrip(u"inch", max_spacing))
        n_bars    = max(n_demand, n_spacing, 2)

        spacing = strip_width / n_bars
        spacing < s_min && continue   # can't physically fit — try next bar size

        As_provided = n_bars * Ab
        return (bar_size=bar_size, n_bars=n_bars, spacing=spacing, As_provided=As_provided)
    end

    error("select_bars: cannot fit reinforcement in $(ustrip(u"inch", strip_width))\" " *
          "strip for As = $(round(ustrip(u"inch^2", As_reqd); digits=3)) in²")
end

"""
    select_bars_for_size(As_reqd, strip_width, bar_size;
                         max_spacing=18u"inch", d_agg=0.75u"inch") -> NamedTuple

Select bars of a *specific* size to provide required steel area.

Unlike `select_bars`, this does not iterate through bar sizes — it computes
the number of bars of the given size needed to satisfy `As_reqd`, then
adjusts `n_bars` upward if the resulting spacing exceeds `max_spacing`.
Errors if the resulting spacing violates ACI 318-11 §7.6.1 minimum clear
spacing.

# Arguments
- `As_reqd`: Required steel area
- `strip_width`: Width of section or strip
- `bar_size`: Bar designation (e.g. 4 for #4)
- `max_spacing`: Maximum bar spacing (default 18″)
- `d_agg`: Nominal maximum aggregate size (default ¾″)

# Returns
Named tuple: `(bar_size, n_bars, spacing, As_provided)`

# Example
```julia
select_bars_for_size(2.0u"inch^2", 60u"inch", 5)
# → (bar_size=5, n_bars=7, spacing=8.57″, As_provided=2.17 in²)
```
"""
function select_bars_for_size(As_reqd::Area, strip_width::Length, bar_size::Int;
                              max_spacing=18u"inch", d_agg=0.75u"inch")
    Ab = bar_area(bar_size)
    db = bar_diameter(bar_size)

    # ACI 318-11 §7.6.1 — minimum clear spacing → center-to-center
    s_min = max(1.0u"inch", db, 4//3 * d_agg) + db

    # Number of bars: satisfy both demand and max-spacing constraints
    n_demand  = ceil(Int, ustrip(u"inch^2", As_reqd) / ustrip(u"inch^2", Ab))
    n_spacing = ceil(Int, ustrip(u"inch", strip_width) / ustrip(u"inch", max_spacing))
    n_bars    = max(n_demand, n_spacing, 2)
    spacing   = strip_width / n_bars

    if spacing < s_min
        error("select_bars_for_size: #$bar_size bars at $(round(u"inch", spacing; digits=2)) " *
              "violate min spacing $(round(u"inch", s_min; digits=2)) in " *
              "$(round(u"inch", strip_width; digits=1)) strip")
    end

    As_provided = n_bars * Ab
    return (bar_size=bar_size, n_bars=n_bars, spacing=spacing, As_provided=As_provided)
end

"""
    select_bars_candidates(As_reqd, strip_width; max_spacing=18u"inch",
                           sizes=[4,5,6,7,8]) -> Vector{NamedTuple}

Return bar selection results for *every* candidate size. Each entry is the
same named tuple as `select_bars` produces. The caller can then score them
by an objective (volume, cost, carbon) and pick the best.

# Example
```julia
candidates = select_bars_candidates(2.0u"inch^2", 60u"inch")
# → Vector of 5 tuples, one per bar size
```
"""
function select_bars_candidates(As_reqd::Area, strip_width::Length;
                                max_spacing=18u"inch", sizes=[4, 5, 6, 7, 8])
    return [select_bars_for_size(As_reqd, strip_width, sz; max_spacing) for sz in sizes]
end

# ==============================================================================