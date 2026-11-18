# ==============================================================================
# Column Reinforcement Design for Fixed Dimensions
# ==============================================================================

# kip·ft. Below this, Muy is treated as zero and the uniaxial diagram is used.
const _COLUMN_MUY_TOL = 1e-6

"""
    _reinforcement_adequate(section, mat, Pu, Mu, Muy; geometry=nothing, βdns=0.6,
                            both_orientations=false) -> Bool

True when `section` resists `(Pu, Mu, Muy)`. With `Muy` present, both
assignments of the two moments to the section axes must pass, because the
stored section does not record which global direction bends about the strong
axis; a square section with a 90°-symmetric bar layout gives the same result
both ways. A lone `Mu` is checked about the strong axis only, unless
`both_orientations` says its axis is unknown; then it must pass about each.

With `geometry`, each axis moment is first magnified by the nonsway
procedure, as the column checker does: single curvature is assumed
(`M1 = −M2`, so `Cm = 1.0`), δns above the ACI 318-19 §6.2.5.3 limit fails,
and on a slender axis with no moment the minimum moment is checked
uniaxially, not added to the biaxial combination (R6.6.4.5.4). `mat` must
then carry rebar properties ([`to_material_tuple`](@ref)).
"""
function _reinforcement_adequate(section::RCColumnSection, mat, Pu, Mu, Muy;
                                 geometry = nothing, βdns::Real = 0.6,
                                 both_orientations::Bool = false)
    Mu, Muy = abs(Mu), abs(Muy)
    # A lone `Mu` stays on the strong axis (wall piers rely on this) unless
    # the caller does not know its axis.
    orientations = if Muy > _COLUMN_MUY_TOL
        ((Mu, Muy), (Muy, Mu))
    elseif both_orientations
        ((Mu, 0.0), (0.0, Mu))
    else
        ((Mu, 0.0),)
    end
    for (Mx, My) in orientations
        if geometry !== nothing
            mt = to_material_tuple(mat)
            rx = magnify_moment_nonsway(section, mt, geometry, Pu, -Mx, Mx, StrongAxis(); βdns)
            ry = magnify_moment_nonsway(section, mt, geometry, Pu, -My, My, WeakAxis(); βdns)
            (rx.permitted && ry.permitted) || return false
            Mx = rx.Mc
            if My > _COLUMN_MUY_TOL
                My = ry.Mc
            elseif ry.slender
                diagram_y = generate_PM_diagram(section, mat, WeakAxis(); n_intermediate = 10)
                check_PM_capacity(diagram_y, Pu, ry.Mc).adequate || return false
            end
        end
        if My <= _COLUMN_MUY_TOL
            diagram = generate_PM_diagram(section, mat; n_intermediate = 10)
            check_PM_capacity(diagram, Pu, Mx).adequate || return false
        else
            check_biaxial_auto(section, mat, Pu, Mx, My).adequate || return false
        end
    end
    return true
end

"""
    design_column_reinforcement(
        b::Length, h::Length, 
        Pu::Real, Mu::Real, 
        mat;
        cover::Length = 1.5u"inch",
        tie_type::Symbol = :tied,
        bar_sizes = [6, 7, 8, 9, 10, 11],
        n_bars_options = [4, 6, 8, 10, 12, 14, 16, 20],
        min_rho::Float64 = 0.01,
        max_rho::Float64 = 0.08,
        Muy::Real = 0.0
    ) -> RCColumnSection

Design reinforcement for a column with fixed dimensions to resist given demands.

Uses P-M interaction analysis to find the minimum reinforcement that:
1. Provides adequate capacity for (Pu, Mu), and for both axes when `Muy` is set
2. Satisfies ACI 318-11 ρg limits (0.01 ≤ ρg ≤ 0.08)

# Arguments
- `b`, `h`: Column dimensions (with units)
- `Pu`: Factored axial load (kip, positive = compression)
- `Mu`: Factored moment about one axis (kip-ft)
- `Muy`: Factored moment about the other axis (kip-ft). Zero keeps the uniaxial check.
- `mat`: Concrete material
- `cover`: Clear cover (default 1.5")
- `tie_type`: :tied or :spiral
- `bar_sizes`: Available bar sizes to try (ascending order preferred)
- `n_bars_options`: Number of bars to try
- `min_rho`, `max_rho`: ACI reinforcement ratio limits

# Returns
RCColumnSection with minimum reinforcement that satisfies demands and ρg ≥ min_rho

# Notes
- Tries combinations in order of increasing steel area
- First valid combination is returned (minimum weight)
- Throws error if no valid combination found

# Example
```julia
b, h = 20u"inch", 20u"inch"
Pu, Mu = 300.0, 150.0  # kip, kip-ft
section = design_column_reinforcement(b, h, Pu, Mu, NWC_4000)
```
"""
function design_column_reinforcement(
    b::Length, h::Length, 
    Pu::Real, Mu::Real, 
    mat;
    cover::Length = 1.5u"inch",
    tie_type::Symbol = :tied,
    tie_bar_size::Int = 4,
    bar_sizes = [6, 7, 8, 9, 10, 11],
    n_bars_options::Union{Nothing, Vector{Int}} = nothing,
    min_rho::Float64 = 0.01,
    max_rho::Float64 = 0.08,
    Muy::Real = 0.0,
    geometry = nothing,
    βdns::Real = 0.6,
    both_orientations::Bool = false,
)
    # Convert dimensions
    b_in = ustrip(u"inch", b)
    h_in = ustrip(u"inch", h)
    Ag = b_in * h_in
    
    # Standard bar areas (ASTM A615)
    bar_areas = Dict(
        3 => 0.11, 4 => 0.20, 5 => 0.31, 6 => 0.44,
        7 => 0.60, 8 => 0.79, 9 => 1.00, 10 => 1.27,
        11 => 1.56, 14 => 2.25, 18 => 4.00
    )
    
    # Minimum number of bars (ACI 10.7.3.1)
    min_bars = tie_type == :spiral ? 6 : 4

    # Auto-extend bar counts for large columns so ρ_min is reachable.
    # With the largest standard bar (#11, Ab=1.56 in²), n_bars_max must satisfy
    # n * 1.56 / Ag ≥ min_rho ⟹ n ≥ ceil(min_rho * Ag / 1.56).
    # Use even counts only (symmetric placement) and cap at a practical 40.
    if n_bars_options === nothing
        As_min = min_rho * Ag
        Ab_max = maximum(bar_areas[bs] for bs in bar_sizes)
        n_needed = Int(ceil(As_min / Ab_max))
        n_ceil = max(20, n_needed + mod(n_needed, 2))   # round up to even
        n_ceil = min(n_ceil, 40)                          # practical ceiling
        n_bars_options = sort(unique([4, 6, 8, 10, 12, 14, 16, 20,
                                      collect(22:2:n_ceil)...]))
    end
    
    # Generate candidates sorted by steel area (ascending = minimum weight first)
    candidates = Tuple{Int, Int, Float64}[]  # (bar_size, n_bars, As)
    
    for bar_size in bar_sizes
        Ab = bar_areas[bar_size]
        for n_bars in n_bars_options
            n_bars >= min_bars || continue
            
            As = n_bars * Ab
            ρ = As / Ag
            
            # Skip if outside ACI limits
            (min_rho ≤ ρ ≤ max_rho) || continue
            
            push!(candidates, (bar_size, n_bars, As))
        end
    end
    
    # Sort by steel area (minimum first)
    sort!(candidates, by = x -> x[3])
    
    # Try each candidate. Only a layout that does not fit the outline is
    # skipped; any other error is a bug and propagates.
    for (bar_size, n_bars, As) in candidates
        section = try
            RCColumnSection(
                b = b, h = h,
                bar_size = bar_size,
                n_bars = n_bars,
                cover = cover,
                tie_type = tie_type,
                tie_bar_size = tie_bar_size
            )
        catch e
            e isa ArgumentError || rethrow()
            @debug "Skipping bar arrangement" n_bars bar_size exception=(e, catch_backtrace())
            continue
        end
        _reinforcement_adequate(section, mat, Pu, Mu, Muy; geometry, βdns,
                                both_orientations) && return section
    end
    
    # No valid combination found - try with maximum reinforcement
    # This indicates the column dimensions are too small for the demands
    muy_note = abs(Muy) > _COLUMN_MUY_TOL ? ", Muy=$(Muy) kip-ft" : ""
    error("Cannot design reinforcement for $(b_in)\"×$(h_in)\" column with Pu=$(Pu) kip, Mu=$(Mu) kip-ft$(muy_note). " *
          "Consider larger column dimensions.")
end

"""
    resize_column_with_reinforcement(
        section::RCColumnSection,
        new_b::Length, new_c::Length,
        Pu::Real, Mu::Real,
        mat;
        Muy::Real = 0.0,
        kwargs...
    ) -> RCColumnSection

Resize a column to new dimensions while properly re-designing reinforcement.

This replaces the simple `scale_column_section` approach when column dimensions
are increased (e.g., for punching shear requirements). Instead of keeping the
same bars (which would reduce ρg below 0.01), this function uses P-M analysis
to design new reinforcement appropriate for the larger section.

# Arguments
- `section`: Original RCColumnSection (used for cover and tie_type defaults)
- `new_b`, `new_c`: New column dimensions
- `Pu`, `Mu`: Design demands (kip, kip-ft)
- `Muy`: Moment about the other axis (kip-ft). Zero keeps the uniaxial check.
- `mat`: Concrete material
- `kwargs`: Passed to design_column_reinforcement

# Returns
New RCColumnSection with properly designed reinforcement

The search covers the same bar sizes as the column catalogs (#6–#18). If no
arrangement passes, the original section's bars (same count and size) are
placed in the new outline and kept when they pass at the new size. With
`Muy` set, both attempts use the biaxial check in both axis orientations.
A column at least as large in both directions with the same bars is no weaker,
so a section the catalog found adequate is not rejected only because it was
enlarged for punching. The error is raised only when both attempts fail.

# Example
```julia
# Original 16" column from P-M design
sec = RCColumnSection(b=16u"inch", h=16u"inch", bar_size=8, n_bars=8)

# Need 20" for punching shear - properly redesign reinforcement
new_sec = resize_column_with_reinforcement(sec, 20u"inch", 20u"inch", 300.0, 150.0, NWC_4000)
```
"""
function resize_column_with_reinforcement(
    section::RCColumnSection,
    new_b::Length, new_c::Length,
    Pu::Real, Mu::Real,
    mat;
    Muy::Real = 0.0,
    geometry = nothing,
    βdns::Real = 0.6,
    both_orientations::Bool = false,
    kwargs...
)
    kw = merge((bar_sizes = [6, 7, 8, 9, 10, 11, 14, 18],), kwargs)
    try
        # Use original section's cover and tie_type
        return design_column_reinforcement(
            new_b, new_c, Pu, Mu, mat;
            Muy = Muy,
            geometry = geometry,
            βdns = βdns,
            both_orientations = both_orientations,
            cover = section.cover,
            tie_type = section.tie_type,
            tie_bar_size = section.tie_bar_size,
            kw...
        )
    catch e
        e isa ErrorException || rethrow()
        kept = _same_bars_in_outline(section, new_b, new_c)
        if !isnothing(kept) &&
           _reinforcement_adequate(kept, mat, Pu, Mu, Muy; geometry, βdns, both_orientations)
            return kept
        end
        rethrow()
    end
end

"""
`section`'s bar count and size laid out in a `b × h` outline, or `nothing`
when that section is not valid (e.g. ρg below the ACI minimum).
"""
function _same_bars_in_outline(section::RCColumnSection, b::Length, h::Length)
    isempty(section.bars) && return nothing
    try
        return RCColumnSection(; b = b, h = h, bar_size = _bar_size_for_area(section.bars[1].As),
                               n_bars = length(section.bars),
                               cover = section.cover, tie_type = section.tie_type,
                               tie_bar_size = section.tie_bar_size)
    catch e
        e isa ArgumentError || rethrow()
        return nothing
    end
end

"""Standard bar size (#3–#18) whose area is closest to `As`."""
function _bar_size_for_area(As)
    As_in2 = ustrip(u"inch^2", As)
    sizes = (3, 4, 5, 6, 7, 8, 9, 10, 11, 14, 18)
    return sizes[argmin([abs(ustrip(u"inch^2", rebar(s).A) - As_in2) for s in sizes])]
end