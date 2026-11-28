# ==============================================================================
# Member Sizing Options (Configuration Structs)
# ==============================================================================
# Material-specific configuration for column and beam sizing.
# Each type has sensible defaults — override only what you need.
#
# Steel uses a single struct (SteelMemberOptions) with aliases:
#   SteelColumnOptions = SteelMemberOptions
#   SteelBeamOptions   = SteelMemberOptions
# because AISC discrete sizing uses the same checker for both.
#
# Concrete has separate structs for columns vs beams because
# ACI design rules differ significantly (P-M interaction vs flexure/shear).

# ==============================================================================
# Steel Column Options
# ==============================================================================

"""
    SteelColumnOptions

Configuration for steel column sizing (AISC 360 P-M interaction).

Columns are governed by axial + flexural interaction — there is no member-level
deflection limit (story drift is checked at the system level, not here).

# Example
```julia
opts = SteelColumnOptions()
opts = SteelColumnOptions(section_type = :hss, max_depth = 0.4)
```

# Fields
- `material`: Steel grade (default: A992_Steel)
- `materials`: Vector of grades for multi-material MIP (default: nothing)
- `section_type`: `:w`, `:hss`, `:pipe`, `:w_and_hss` (default: `:w`)
- `catalog`: `:common`, `:preferred`, `:all` (default: `:preferred`)
- `custom_catalog`: Custom section vector (overrides catalog)
- `max_depth`: Maximum depth (default: Inf)
- `n_max_sections`: Limit unique sections, 0 = no limit (default: 0)
- `objective`: MinWeight(), MinVolume(), MinCost(), MinCarbon() (default: MinWeight())
- `solver`: `:auto`, `:highs`, `:gurobi` (default: `:auto`)
"""
Base.@kwdef struct SteelColumnOptions
    material::StructuralSteel = A992_Steel
    materials::Union{Nothing, Vector{<:StructuralSteel}} = nothing
    section_type::Symbol = :w
    catalog::Symbol = :preferred
    custom_catalog::Union{Nothing, Vector} = nothing
    max_depth::Length = Inf * u"mm"
    n_max_sections::Int = 0
    sizing_strategy::Symbol = :discrete
    objective::AbstractObjective = MinWeight()
    solver::Symbol = :auto
    time_limit_sec::Real = 30.0  # MIP solver time limit (discrete only)
end

# ==============================================================================
# Steel Beam Options
# ==============================================================================

"""
    SteelBeamOptions

Configuration for steel beam sizing (AISC 360 flexure + shear + deflection).

Beams default to L/360 LL and L/240 total (DL+LL) deflection checks. The deflection
constraints are only enforced when `δ_max_LL`/`δ_max_total`/`I_ref` are provided
in the demand (from Asap FEM or via `size_beams` kwargs). Set the relevant limit
to `nothing` to opt out.

# Example
```julia
opts = SteelBeamOptions()                                # L/360 LL, L/240 total
opts = SteelBeamOptions(deflection_limit = nothing,      # strength only
                        total_deflection_limit = nothing)
opts = SteelBeamOptions(composite = true,
                        composite_anchor_d = 0.75u"inch",
                        composite_anchor_length = 5.0u"inch",
                        composite_anchor_Fu = 65.0u"ksi")
```

`composite = false` does not read the composite fields. With `composite = true`,
a stud with all three fields unset is the named default
(`default_headed_stud`: 3/4 in, Fu = 65 ksi, AISC Manual 14th ed.); setting
only some of them throws. Thickness and concrete come
from the sized slab when those fields are left unset. Shoring defaults to
unshored, so the pre-cure check runs.

# Fields
- `material`: Steel grade (default: A992_Steel)
- `materials`: Vector of grades for multi-material MIP (default: nothing)
- `section_type`: `:w`, `:hss`, `:pipe`, `:w_and_hss` (default: `:w`)
- `catalog`: `:common`, `:preferred`, `:all` (default: `:preferred`)
- `custom_catalog`: Custom section vector (overrides catalog)
- `max_depth`: Maximum depth (default: Inf mm)
- `deflection_limit`: LL L/δ ratio (default: `1/360`). `nothing` to disable.
- `total_deflection_limit`: DL+LL L/δ ratio (default: `1/240`). `nothing` to disable.
- `composite`: Enable composite beam sizing via AISC 360 Chapter I (default: false)
- `composite_slab_type`: `:solid` or `:deck` (default: `:solid`)
- `composite_t_slab`: Slab thickness override. `nothing` reads the sized slab.
- `composite_deck_hr`, `composite_deck_wr`: required for `:deck` unless `composite_deck_profile` is set
- `composite_deck_orientation`: `:from_slab` (default) takes each beam's rib angle from its direction and the span axis of the slabs it supports. `:perpendicular` or `:parallel` asserts that orientation for every beam.
- `composite_deck_profile`: Vulcraft profile name (`"1.5VL"`, `"2VLI"`, `"3VLI"`, or a side-lap variant). Supplies `hr`, `wr`, and rib pitch; an explicit `hr`/`wr`/pitch must agree with it.
- `composite_deck_pitch`: rib spacing, perpendicular to the ribs, when no profile is named. Needed to place studs on skewed deck.
- `composite_deck_e_mid_ht`: AISC 360-22 §I8.2a `e_mid-ht` for perpendicular or skewed deck, measured perpendicular to the rib. `nothing` keeps `Rp = 0.6`.
- `composite_deck_anchorage_spacing`: deck attachment spacing, §I3.2c(d) (≤ 18 in). `nothing` reports it unchecked.
- `composite_anchor_d`, `composite_anchor_length`, `composite_anchor_Fu`: the stud. All unset uses the named default stud.
- `composite_twist_spacing`: spacing of twist restraints for the hogging check and Commentary Eq. C-F1-5. `nothing` uses the member span.
- `composite_deck_support_pattern`: deck support fastener pattern. `nothing` uses `"36/4"`, the DDM03 standard composite pattern. Reported only; no diaphragm strength is taken from those tables.
- `composite_deck_sidelap_per_span`: side-lap connectors between supports. `nothing` reports them as not supplied.
- `composite_diaphragm_Sn`: caller-supplied nominal diaphragm shear strength per unit length. `nothing` is the only default. It is reported beside the brace force and not compared with it.
- `composite_shored`: `true` skips the pre-cure steel check (default: false)
- `composite_d_rebar`: height of the negative-reinforcement centroid above the top of the steel. `nothing` is 0, which puts the bars on the top flange and gives the smallest cracked hogging inertia.
- `composite_cp_class`: SEI/ASCE 37-02 personnel class (default: `:medium`)
- `sizing_strategy`: `:discrete` (MIP catalog) or `:nlp` (continuous) (default: `:discrete`)
- `n_max_sections`: Limit unique sections, 0 = no limit (default: 0)
- `objective`: MinWeight(), MinVolume(), MinCost(), MinCarbon() (default: MinWeight())
- `solver`: `:auto`, `:highs`, `:gurobi` (default: `:auto`)
"""
Base.@kwdef struct SteelBeamOptions
    material::StructuralSteel = A992_Steel
    materials::Union{Nothing, Vector{<:StructuralSteel}} = nothing
    section_type::Symbol = :w
    catalog::Symbol = :preferred
    custom_catalog::Union{Nothing, Vector} = nothing
    max_depth::Length = Inf * u"mm"
    deflection_limit::Union{Nothing, Float64} = 1/360
    total_deflection_limit::Union{Nothing, Float64} = 1/240
    composite::Bool = false
    composite_slab_type::Symbol = :solid
    composite_t_slab::Union{Nothing, Length} = nothing
    composite_deck_hr::Union{Nothing, Length} = nothing
    composite_deck_wr::Union{Nothing, Length} = nothing
    composite_deck_orientation::Symbol = :from_slab
    composite_deck_profile::Union{Nothing, String} = nothing
    composite_deck_pitch::Union{Nothing, Length} = nothing
    composite_deck_e_mid_ht::Union{Nothing, Length} = nothing
    composite_deck_anchorage_spacing::Union{Nothing, Length} = nothing
    composite_anchor_d::Union{Nothing, Length} = nothing
    composite_anchor_length::Union{Nothing, Length} = nothing
    composite_anchor_Fu::Union{Nothing, Pressure} = nothing
    composite_twist_spacing::Union{Nothing, Length} = nothing
    composite_deck_support_pattern::Union{Nothing, String} = nothing
    composite_deck_sidelap_per_span::Union{Nothing, Int} = nothing
    composite_diaphragm_Sn::Union{Nothing, Unitful.Quantity} = nothing
    composite_shored::Bool = false
    composite_d_rebar::Union{Nothing, Length} = nothing
    composite_cp_class::Symbol = :medium
    n_max_sections::Int = 0
    sizing_strategy::Symbol = :discrete
    objective::AbstractObjective = MinWeight()
    solver::Symbol = :auto
    time_limit_sec::Real = 30.0  # MIP solver time limit (discrete only)
end

"""Union of steel column and beam options for shared dispatch paths."""
const SteelMemberOptions = Union{SteelColumnOptions, SteelBeamOptions}

"""Get LL deflection_limit: beams have it, columns return nothing."""
_deflection_limit(opts::SteelBeamOptions) = opts.deflection_limit
_deflection_limit(opts::SteelColumnOptions) = nothing

"""Get total deflection_limit: beams have it, columns return nothing."""
_total_deflection_limit(opts::SteelBeamOptions) = opts.total_deflection_limit
_total_deflection_limit(opts::SteelColumnOptions) = nothing

