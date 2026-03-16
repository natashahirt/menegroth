# =============================================================================
# Foundation Strategy Recommendation
# =============================================================================
#
# Uses Voronoi tributary areas and soil bearing capacity to recommend:
#   :spread  — individual spread footings (low coverage)
#   :strip   — spread footings with merging into strips where too close
#   :mat     — full mat foundation (high coverage ratio)
#
# Coverage ratio = Σ(required footing area per column) / building footprint
# =============================================================================

"""
    recommend_foundation_strategy(
        demands, tributary_areas, soil;
        opts = FoundationOptions()
    ) → Symbol

Recommend a foundation strategy based on the coverage ratio.

Each column's required footing area is `Ps / qa`. The coverage ratio is the
sum of these areas divided by the building footprint (convex hull of Voronoi
cells). When coverage exceeds the threshold, a mat foundation is recommended.

# Arguments
- `demands::Vector{FoundationDemand}`: Service + factored loads per column.
- `tributary_areas::Vector{<:Unitful.Area}`: Voronoi tributary area per column.
- `soil::Soil`: `qa` = net allowable bearing pressure.

# Keyword Arguments
- `opts::FoundationOptions`: Contains `mat_coverage_threshold` (default 0.50).

# Returns
- `:spread` — coverage < ~30%, all footings fit comfortably
- `:strip`  — coverage 30–50% or footings overlap, merge some into strips
- `:mat`    — coverage > threshold, go to a full mat

# Example
```julia
strategy = recommend_foundation_strategy(demands, voronoi_areas, soil)
# → :spread, :strip, or :mat
```
"""
function recommend_foundation_strategy(
    demands::Vector{<:FoundationDemand},
    tributary_areas::Vector{<:Unitful.Area},
    soil::Soil;
    opts::FoundationOptions = FoundationOptions()
)
    # If user explicitly chose a strategy, respect it
    if opts.strategy != :auto && opts.strategy != :auto_strip_spread
        return opts.strategy == :all_spread ? :spread :
               opts.strategy == :all_strip  ? :strip  :
               opts.strategy == :mat        ? :mat    :
               opts.strategy  # pass through
    end

    N = length(demands)
    qa_ksf = ustrip(ksf, soil.qa)

    # Required spread footing area per column (from service loads)
    req_areas_ft2 = [to_kip(d.Ps) / qa_ksf for d in demands]

    # Building footprint (sum of Voronoi tributary areas)
    footprint_ft2 = sum(ustrip(u"ft^2", a) for a in tributary_areas)

    # Total required footing area
    total_req_ft2 = sum(req_areas_ft2)

    # Coverage ratio
    coverage = total_req_ft2 / max(footprint_ft2, 1.0)

    # Decision logic
    result = if coverage > opts.mat_coverage_threshold
        :mat
    elseif coverage > 0.30
        # Moderate coverage — likely need some strips where footings overlap
        :strip
    else
        :spread
    end

    # auto_strip_spread: never pick mat; high coverage → strip
    if opts.strategy == :auto_strip_spread && result == :mat
        return :strip
    end
    return result
end
