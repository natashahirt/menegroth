# =============================================================================
# Framing hierarchy: public API  — Phase 4
# =============================================================================
#
# Manual attachment of a `FramingLevel` to a slab. Split from `framing.jl`
# (which defines the framing types, included before `cells.jl`) because this
# references `BuildingStructure` and `Slab`, so it must load after
# `structure.jl`.

"""
    attach_framing_level!(struc::BuildingStructure, slab::Slab, level::FramingLevel) -> FramingLevel

Manually attach a framing `level` to `slab`, appending it to
`slab.framing_levels`. Validates/sets `level.slab_idx`:

- if `level.slab_idx` is unset (`0`), it is set to the slab's index in
  `struc.slabs`;
- otherwise it must equal that index (an `ArgumentError` is thrown on mismatch).

Returns the (possibly updated) `level` so calls can be chained. The heavy lifting
— resolving the pattern to polylines and creating real `Beam{T}`s — is Phase 5's
`materialize_level!`; this only records the level on the slab.

# Example
```julia
# Steel joists at 4 ft on center across a two-way slab, spanning along +x.
slab  = struc.slabs[1]
level = FramingLevel{Float64}(
    slab_idx = 0,                                   # set by attach_framing_level!
    level    = 1,
    pattern  = LinearAxisPattern{Float64}((1.0, 0.0), ustrip(u"m", 4.0u"ft"), nothing),
    role     = :joist,
    material = A992_Steel,
)
attach_framing_level!(struc, slab, level)
@assert length(slab.framing_levels) == 1
```
"""
function attach_framing_level!(struc::BuildingStructure, slab::Slab, level::FramingLevel)
    idx = findfirst(s -> s === slab, struc.slabs)
    isnothing(idx) && throw(ArgumentError(
        "attach_framing_level!: slab is not a member of struc.slabs"))
    if level.slab_idx == 0
        level.slab_idx = idx
    elseif level.slab_idx != idx
        throw(ArgumentError(
            "attach_framing_level!: level.slab_idx ($(level.slab_idx)) does not match " *
            "the slab's index in struc.slabs ($idx)"))
    end
    push!(slab.framing_levels, level)
    return level
end

# -----------------------------------------------------------------------------
# joist_geometry — Slab entry point (needs Slab, so it lives here not framing.jl)
# -----------------------------------------------------------------------------

"""
    joist_geometry(slab::Slab, level_idx::Int) -> Union{Nothing, StructuralSizer.AbstractJoistPattern}

Framing-hierarchy entry point Phase 5's `derive_framing_level` calls: derive the
joist pattern `slab` intrinsically owns at framing `level_idx` from the slab's
REAL sizing data (rib grid / joist spacing) and span axis, routing on
`slab.floor_type`. Delegates to the data-bearing overloads in `framing.jl`:

- `:waffle`             → [`joist_geometry(::WaffleRibGrid, ::Int)`](@ref) when the
  result carries a `WaffleRibGrid` (via [`_waffle_rib_grid`](@ref); `nothing`
  today, since waffle sizing returns a `CIPSlabResult`);
- `:mass_timber_joist`  → [`joist_geometry(::TimberJoistResult, ::SpanInfo, ::Int)`](@ref);
- `:joist_roof_deck`    → [`joist_geometry(::JoistDeckResult, ::SpanInfo, ::Int)`](@ref).

Returns `nothing` for slab types that own no joist level, or when the required
data-bearing object is not present on `slab.result` (graceful default — no
placeholder geometry).
"""
function StructuralSizer.joist_geometry(slab::Slab, level_idx::Int)
    ft = slab.floor_type
    if ft === :waffle
        grid = _waffle_rib_grid(slab.result)
        return grid isa StructuralSizer.WaffleRibGrid ?
            StructuralSizer.joist_geometry(grid, level_idx) : nothing
    elseif ft === :mass_timber_joist
        return slab.result isa StructuralSizer.TimberJoistResult ?
            StructuralSizer.joist_geometry(slab.result, slab.spans, level_idx) : nothing
    elseif ft === :joist_roof_deck
        return slab.result isa StructuralSizer.JoistDeckResult ?
            StructuralSizer.joist_geometry(slab.result, slab.spans, level_idx) : nothing
    else
        return nothing
    end
end
