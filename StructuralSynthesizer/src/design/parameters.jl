# =============================================================================
# Design Parameters
# =============================================================================

"""
Face-scoped floor override from API/client input.

- `floor_type`: Target floor system (currently supports `:vault` in scoped mode).
- `vault_lambda`: Optional vault span/rise ratio override.
- `faces`: Selector polygons in meters, each as `[(x,y,z), ...]`.
"""
Base.@kwdef struct ScopedFloorOverride
    floor_type::Symbol = :vault
    method::String = "DDM"
    deflection_limit::String = "L_360"
    punching_strategy::String = "grow_columns"
    target_edge_m::Union{Float64, Nothing} = nothing
    concrete::Union{Concrete, Nothing} = nothing
    vault_lambda::Union{Float64, Nothing} = nothing
    faces::Vector{Vector{NTuple{3, Float64}}} = Vector{NTuple{3, Float64}}[]
    # Direction the matched cells span, `(x, y)`. `nothing` leaves the
    # building rule. Wins over `DesignParameters.tributary_axis`.
    span_axis::Union{Nothing, NTuple{2, Float64}} = nothing
end

"""
    MemberGroupSizingOverride(; catalog=nothing, deflection_limit=nothing, max_depth=nothing)

Per-member-group sizing override carried on `DesignParameters.member_group_overrides`
(keyed by the group's stable `UInt64` `group_id`). Each field is `nothing` by
default, meaning "fall through to the next resolution level" — so an override with
all fields unset is a no-op.

These are ENGINEERING sizing KNOBS (not published-code factors): a per-group section
`catalog`, an L/δ `deflection_limit` (e.g. `1/360`), and a `max_depth` cap. They are
honored on the per-group [`size_member_group!`](@ref) path AND (Phase B) on the
batched steel-beam stage ([`size_beams!`](@ref) → `_size_beams_impl!` →
`_beam_override_union_and_feasible`) used by `design_building`.

Per-knob precedence DIFFERS by path ([A-revert]):

- `size_member_group!` (highest first): this override's field
  (`member_group_overrides[gid]`) > the caller's global default kwarg.
- batched `size_beams!`: this override's field > the caller's global default
  kwarg. A framing level's own catalog is `FramingLevel.beam_options`, sized
  in that level's pass.

Field types are validated at construction: `deflection_limit` must be a
dimensionless `Real` L/δ ratio and `max_depth` a Unitful length, else the
constructor throws a `member_group_overrides` `ArgumentError` (so an ill-typed /
unit-mismatched value fails loud at the API boundary rather than surfacing as a
Unitful `DimensionError` deep inside the batched sizing mask).

!!! note "Scope (Run 4 / Phase B)"
    Only the fields a per-group sizer can honor are represented: `catalog`,
    `deflection_limit`, `max_depth`. Objective / total-deflection overrides have no
    per-group honoring path and are deliberately omitted rather than carried as
    silently-ignored knobs. Phase B threads these overrides into the batched STEEL
    beam stage as a per-group *narrowing* mask (see
    `_beam_override_union_and_feasible`): each knob can only tighten a group's
    candidate set relative to the global default. Effective overrides on
    column/strut groups, on flat-plate/flat-slab floors, on non-steel-beam sizing,
    or combined with `n_max_sections > 0` are still refused fail-loud by
    [`_assert_member_group_overrides_unsupported`](@ref).
"""
struct MemberGroupSizingOverride
    catalog::Any                                 # per-group section catalog, or nothing
    deflection_limit::Union{Nothing, Real}       # L/δ ratio (e.g. 1/360), or nothing
    max_depth::Union{Nothing, Unitful.Length}    # max section depth cap, or nothing

    # [P2-4] Validating constructor: reject an ill-typed / unit-mismatched knob with
    # a `member_group_overrides` ArgumentError at the API boundary, rather than
    # letting a bare-number `max_depth` (or a dimensioned `deflection_limit`) surface
    # as a Unitful DimensionError deep in the batched mask (`ovr.max_depth >
    # global_depth`, `section_depth(s) <= resolved_depth`). `catalog` is untouched.
    function MemberGroupSizingOverride(catalog, deflection_limit, max_depth)
        (deflection_limit === nothing || deflection_limit isa Real) ||
            throw(ArgumentError("member_group_overrides: deflection_limit must be a " *
                "dimensionless Real L/δ ratio (e.g. 1/360), got a " *
                "$(typeof(deflection_limit))"))
        (max_depth === nothing || max_depth isa Unitful.Length) ||
            throw(ArgumentError("member_group_overrides: max_depth must be a Unitful " *
                "length (e.g. 18.0u\"inch\"), got a $(typeof(max_depth))"))
        return new(catalog, deflection_limit, max_depth)
    end
end
MemberGroupSizingOverride(; catalog=nothing, deflection_limit=nothing, max_depth=nothing) =
    MemberGroupSizingOverride(catalog, deflection_limit, max_depth)

"""
    _is_effective(o::MemberGroupSizingOverride) -> Bool

Whether `o` sets ANY sizing knob (`catalog`, `deflection_limit`, or `max_depth`).
An override with all fields `nothing` is a documented no-op (see the
`MemberGroupSizingOverride` docstring), so `_is_effective` is `false` for it. Used
by the fail-loud member-group-override guard to refuse ONLY overrides that would
actually change a design (an all-unset entry must not throw — guard/docstring
consistency).
"""
_is_effective(o::MemberGroupSizingOverride) =
    o.catalog !== nothing || o.deflection_limit !== nothing || o.max_depth !== nothing

Base.@kwdef mutable struct DesignParameters
    # Identifiers
    name::String = "default"
    description::String = ""
    
    # ─── Gravity Loads (unfactored service level) ───
    loads::GravityLoads = GravityLoads()
    
    # ─── Materials (cascading) ───
    materials::MaterialOptions = MaterialOptions()
    
    # ─── Fire Rating ───
    # Building-level fire resistance requirement in hours.
    # Valid values: 0, 1, 1.5, 2, 3, 4  (0 = no fire design)
    # Concrete: controls min thickness, cover, dimensions (ACI 216.1)
    # Steel: controls coating thickness via fire_protection type
    fire_rating::Float64 = 0.0
    
    # ─── Fire Protection (steel members only) ───
    # Controls the type of fire protection coating applied to steel members.
    # Ignored for concrete elements (fire resistance is intrinsic via cover/thickness).
    # Override per-member via SteelBeamOptions/SteelColumnOptions fire_protection.
    fire_protection::StructuralSizer.FireProtection = StructuralSizer.SFRM()
    
    # ─── Member Sizing Options ───
    columns::Union{StructuralSizer.ColumnOptions, Nothing} = nothing
    beams::Union{StructuralSizer.BeamOptions, Nothing} = nothing
    
    # ─── Floor Specification ───
    # The type IS the floor system:
    #   DesignParameters(floor = FlatPlateOptions(method = EFM(solver=:asap)))
    #   DesignParameters(floor = VaultOptions(lambda = 8.0))
    floor::Union{StructuralSizer.AbstractFloorOptions, Nothing} = nothing
    
    # ─── Tributary Axis ───
    # Override tributary area partitioning (default: auto from floor type).
    # :isotropic → force straight skeleton; (x,y) tuple → directed partition.
    tributary_axis::Union{Nothing, Symbol, NTuple{2, Float64}} = nothing
    
    # ─── Foundation Options ───
    foundation_options::Union{FoundationParameters, Nothing} = nothing

    # ─── Face-scoped Floor Overrides ───
    # Optional geometry-scoped floor overrides (e.g., vault-only regions).
    # Coordinates are stored in meters as plain Float64 triplets.
    scoped_floor_overrides::Vector{ScopedFloorOverride} = ScopedFloorOverride[]
    
    # ─── Member Grouping ───
    # When true, separate collinear beams share one group_id and one section.
    # Edges that are already one beam are one member and are sized once without
    # this flag. A moment connection does not by itself require the same section.
    # Orthogonal to `uniform_column_sizing`, which is per story rather than along a line.
    collinear_grouping::Bool = false

    # ─── Per-Member-Group Sizing Overrides (Run 4 / Phase B) ───
    # Optional per-group sizing knobs keyed by the group's stable UInt64 group_id.
    # DEFAULTS to empty ⇒ byte-identical to today for every existing caller.
    #
    # Phase B: `member_group_overrides` is a LIVE `:members` node-slice input. It is
    # honored for ELIGIBLE STEEL BEAM groups by the BATCHED `design_building` /
    # incremental member stage (`_size_beams_columns!` → batched `size_beams!` →
    # `_size_beams_impl!` → `_beam_override_union_and_feasible`), threaded as a
    # per-group feasible-narrowing mask, AND on the isolated per-group
    # `size_member_group!` path. Because it feeds the `:members` param slice, a
    # change DIRTIES the member frontier — but it is NOT prepare-affecting (it never
    # alters the prepared model), so the incremental engine is reused, not rebuilt.
    #
    # A framing level's catalog is `FramingLevel.beam_options`. Un-honorable
    # effective targets (column/strut groups, flat-plate/flat-slab floors, non-steel
    # beam sizing, `n_max_sections > 0`, or a LOOSER-than-global knob) are refused
    # fail-loud by [`_assert_member_group_overrides_unsupported`](@ref). See
    # `MemberGroupSizingOverride`.
    member_group_overrides::Dict{UInt64, MemberGroupSizingOverride} =
        Dict{UInt64, MemberGroupSizingOverride}()

    # ─── Framing Auto-Generation (Phase 5, plan `joists-roles-materials`) ───
    # Options driving `populate_levels!`, which auto-generates the framing
    # hierarchy (girders, secondary beams, joists) above each slab during
    # `prepare!` (the `:populate_framing` prepare sub-step, before `to_asap!`).
    #
    # An empty NamedTuple (the default) is a STRICT no-op — flat-plate /
    # flat-slab / beam-supported flows are byte-identical unless a caller opts
    # in. Recognized keys (all optional): `:materials` (NamedTuple of member
    # materials by key `:steel`/`:timber`/`:concrete`/`:beam`), `:spacing`
    # (center-to-center joist spacing), and `:level_N` (NamedTuple schema for
    # framing level N ≥ 2). See `populate_levels!` for the full contract.
    #
    # `prepare!`/`design_building` honor this field when no explicit
    # `framing_opts` kwarg is supplied, so the REST API (`json_to_params`) can
    # drive framing auto-generation through a single design call.
    #
    # NOTE (incremental engine): this field is PREPARE-affecting and IS listed in
    # `PREPARE_AFFECTING_FIELDS` (scheduler.jl). Because `populate_levels!` mutates
    # the skeleton (appends joist edges, subdivides host edges), the stateful
    # `IncrementalEngine` cannot safely re-`prepare!` a reused baseline to change
    # framing — so `run_target!` rejects a `framing_opts` change on a reused engine
    # and a fresh `prepare_engine` (which prepares on an independent copy) is
    # required. The per-call `design_building` path (used by the REST API) re-runs
    # `prepare!` from a pristine structure every call and is unaffected.
    framing_opts::NamedTuple = NamedTuple()

    # ─── Uniform Column Sizing ───
    # :off      — each column sized independently (default). Minimises material
    #             and embodied carbon by right-sizing each column to its own demand.
    # :per_story — all columns on the same story get the governing (largest) size.
    #              Common for constructability / formwork reuse, but adds material
    #              to lightly-loaded columns.
    # :building  — every column in the structure gets the governing size. Simplest
    #              to construct but highest material use.
    # Harmonization is conservative: the largest required section in each group
    # is promoted to all siblings (safe because a bigger column only improves
    # axial/punching capacity vs what was already checked).
    # Not supported for PixelFrame columns (rejected at API validation).
    uniform_column_sizing::Symbol = :off

    # ─── Monolithic column self-weight coupling (default OFF) ───
    # When true, the STEEL discrete column stage replaces the "size against the
    # current self-weight → re-solve → re-size" ratchet with ONE certified MILP:
    # each column group's axial demand is written as a LINEAR function of every
    # column group's section choice via exact FE self-weight influence
    # coefficients φ (a column's own weight plus the share of other columns'
    # weight that redistributes onto it in the indeterminate frame), so the solver
    # returns the globally self-consistent column design in a single pass. See
    # `build_column_selfweight_coupling` (analyze/members/members/selfweight_coupling.jl)
    # and the discrete `LinearCapacityCoupling`. The coupling only GUIDES the
    # section choice; the surrounding member loop's held-check and
    # `_verify_installed_design!` still certify every installed column on a fresh
    # analysis, so an imperfect frozen-stiffness linearization can never pass an
    # unsafe design — at worst the loop takes one correction pass. Falls back to
    # the ratchet whenever the exact regime does not hold (non-steel/non-discrete
    # columns, a section-count cap, a section floor, a multi-material catalog, or
    # when pattern cases rather than the full-load solve govern the demand).
    # `false` (default) is byte-identical to the prior behavior.
    monolithic_column_selfweight::Bool = false
    
    # ─── Design Targets ───
    deflection_limit::Symbol = :L_360        # :L_240, :L_360, :L_480
    optimize_for::Symbol = :weight           # :weight, :carbon, :cost
    
    # ─── Load Combinations (factored) ───
    load_combinations::Vector{LoadCombination} = [default_combo]
    
    # ─── Pattern Loading (ACI 318-11 §13.7.6) ───
    pattern_loading::Symbol = :none
    
    # Diaphragm model. `:none` is off; it is not an ASCE 7 category.
    # `:rigid` is the in-plane rigid link (u_x, u_y, θ_z). `:shell` is a
    # full-plate slab. `:semirigid` is the in-plane membrane floor.
    # `:flexible` sends story force to the lines of seismic-system walls and
    # ties each line along itself. `:auto` measures the span and depth and
    # uses `stricter_diaphragm_idealization`: rigid or flexible only when both
    # wind and seismic permit it, and the membrane otherwise. `:auto` requires
    # `diaphragm_construction` and `diaphragm_irregularities`. A wall that is
    # not parallel to the plan axes adds Table 12.3-1 Type 5.
    diaphragm_mode::Symbol = :none
    diaphragm_E::Union{typeof(1.0u"Pa"), Nothing} = nothing
    diaphragm_ν::Float64 = 0.2
    diaphragm_construction::Union{Nothing, Symbol} = nothing
    # Table 12.3-1 type numbers. `nothing` means they were not stated.
    # An empty vector means the caller states there are none. `:auto` appends
    # type 5 when a wall used for the span is skewed, and leaves this vector
    # unchanged.
    diaphragm_irregularities::Union{Nothing, Vector{Int}} = nothing
    # `:semirigid` membrane modulus = slab modulus × factor. ACI 318-19
    # §12.4.2.4(c) (corpus: aci-318-19, PDF page 183) permits design values
    # from the envelope of upper- and lower-bound in-plane stiffness.
    # ENGINEERING JUDGMENT: upper bound 1.0 (gross section). Lower bound 0.35,
    # the cracked-wall Ig factor of ACI 318-19 Table 6.6.3.1.1(a) (PDF page 78)
    # borrowed for a slab acting in its plane; no code gives an in-plane
    # diaphragm factor. The model is meshed at the first entry.
    semirigid_stiffness_factors::NTuple{2, Float64} = (1.0, 0.35)

    # Lateral system and demand assignment. `nothing` means no lateral design:
    # a gravity-only building is unchanged. There is no default system.
    lateral::Union{Nothing, LateralDesign} = nothing
    # Required when `lateral` is set. Wind pressures, ELF inputs, and the
    # seismic-provision statements. Nothing here is filled in.
    wall_inputs::Union{Nothing, OrdinaryWallInputs} = nothing
    # Pier thickness for skeleton `:walls` edges. Required when that group is
    # non-empty. There is no default thickness.
    wall_thickness::Union{Nothing, typeof(1.0u"m")} = nothing
    # Columns and beams that lie inside a wall move to `:absent`, and the wall
    # is the support there. `false` keeps them as members.
    park_wall_overlaps::Bool = true
    # After a failed ordinary-wall check, jump to a thicker inch predicted
    # from this analysis and confirm. `:all` moves every wall together, so
    # one analysis can predict the next inch. A finer grouping re-solves,
    # because the walls no longer share one stiffness. A test that must
    # record the failure at the given t sets this false.
    jump_wall_thickness::Bool = true
    # Which walls share a thickness. See `WALL_THICKNESS_GROUPINGS`.
    # `:pier` sizes each wall on its own demand. `:all` moves every wall
    # together, so one analysis can predict the next inch.
    wall_thickness_grouping::Symbol = :pier
    # Thickness catalog. `:hard` errors when no thickness through
    # `wall_thickness_limit` passes. `:soft` steps that limit up by 12 in,
    # warns, and errors at 72 in.
    wall_catalog_constraint::Symbol = :soft
    wall_thickness_limit::typeof(1.0u"m") = 36.0u"inch"
    
    # Default frame element properties (before member sizing).
    # Use precomputed SI constants to avoid runtime Unitful conversion of ksi → Pa,
    # which can fail if Asap custom-unit basefactors are not yet registered.
    default_frame_E::typeof(1.0u"Pa") = _DEFAULT_FRAME_E
    default_frame_G::typeof(1.0u"Pa") = _DEFAULT_FRAME_G
    default_frame_ρ::typeof(1.0u"kg/m^3") = _DEFAULT_FRAME_ρ
    
    # ─── Flat-plate analysis model ───
    # `:building` analyses flat-plate and flat-slab floors as loaded shells of
    # the building model (`FEA(source = :building)`) in place of the floor
    # options' method. `:options` keeps the method the floor options name.
    flat_plate_analysis::Symbol = :building

    # ─── ACI Cracking Factors ───
    column_I_factor::Float64 = 0.70
    beam_I_factor::Float64 = 0.35
    
    # ─── Iteration Control ───
    max_iterations::Int = 20
    # ENGINEERING JUDGMENT. `true`: a rib piece that frames into a solid head
    # carries its shear with stirrups, designed by its own beam check (ACI
    # 318-11 §11.1.1, Vn = Vc + Vs; §8.13.8 keeps the joist Vc increase), and
    # the head grows only for punching and hogging. `false`: the piece is
    # sized for Vu ≤ φVc on concrete alone and the head grows for rib shear.
    rib_head_stirrups::Bool = true
    # Rib stem below the topping for every ribbed concrete story (waffle and
    # one-way joists). `nothing` lets the depth screen pick each story's stem
    # from `rib_stems` on carbon (docs/sizing-map/ribbed-floors.md).
    rib_stem::Union{Nothing, typeof(1.0u"inch")} = nothing
    # Stems the depth screen tries, shallowest first. `STANDARD_DOME_STEMS`
    # restricts a story to standard 30 in dome forms.
    rib_stems::Vector{typeof(1.0u"inch")} =
        [6.0, 8.0, 10.0, 12.0, 14.0, 16.0, 18.0, 20.0, 24.0] .* u"inch"
    # ACI 318-11 Table 9.5(b) (corpus: aci-318-11, PDF page 133) limit on the
    # deflection after nonstructural elements are attached: `:sensitive` is
    # l/480 (elements likely to be damaged), `:total` is l/240.
    rib_deflection_limit::Symbol = :sensitive
    # Continuous midspan compression-steel ratios ρ′ = As′/(bw·d) the deflection
    # screen may add to the ribs to cut the long-term multiplier λΔ = ξ/(1+50ρ′)
    # (ACI 318-11 §9.5.2.5, Eq. 9-11; corpus: aci-318-11, PDF page 132). The
    # screen escalates up this ladder only when depth alone fails Table 9.5(b),
    # and picks the (stem, ρ′) with the least total embodied carbon. `0.0` must
    # stay first so the no-added-steel case is always tried. ENGINEERING
    # JUDGMENT: the 0.02 cap keeps λΔ gains from flattening and the top mat
    # buildable; the bars are detailed continuous through midspan so §9.5.2.5
    # credits ρ′ there.
    rib_comp_steel_ratios::Vector{Float64} = [0.0, 0.005, 0.01, 0.015, 0.02]
    # Fraction of the immediate dead-load sag taken to occur before the
    # nonstructural elements are attached, and therefore deducted from the
    # after-attachment deflection (ACI 318-11 §9.5.2.6 / R9.5.2.6; corpus:
    # aci-318-11, PDF page 133: "the portion of the deflection before attachment
    # of the nonstructural elements may be deducted"). ENGINEERING JUDGMENT:
    # magnitude depends on the construction sequence; `0.0` (deduct nothing) is
    # the conservative default.
    rib_pre_attachment_dead_fraction::Float64 = 0.0
    # ENGINEERING JUDGMENT. A rib bay whose least centerline width, minus the
    # ribs, is below this joins the nearest solid head.
    min_rib_void::typeof(1.0u"inch") = 12.0u"inch"
    # ENGINEERING JUDGMENT. Solid heads stop growing once they cover more than
    # this fraction of the rib-bay area. The design is then reported short.
    solid_fraction_max::Float64 = 0.35
    
    # ─── Geometry Interpretation ───
    # When true (default), vertices are column and beam centerlines. The slab
    # edge sits outside them, flush with the largest column face on each side,
    # and moves when the columns are resized. The grid does not.
    # When false, vertices are a drawn slab edge. Preparation shifts the
    # boundary in by a fixed setback, once, and the same rule applies after that.
    geometry_is_centerline::Bool = true
    
    # ─── Display Preferences ───
    display_units::DisplayUnits = imperial
    
    # ─── Visualization ───
    # Target edge length for the visualization shell mesh (meters, plain Float64).
    # nothing → inherit from FEA target_edge or use adaptive default.
    visualization_target_edge_m::Union{Float64, Nothing} = nothing
    # When true, skip shell mesh build and visualization serialization entirely.
    skip_visualization::Bool = false
    # "minimal" → frame + slab boundaries only; "full" → deflected meshes, analytical.
    visualization_detail::String = "full"
end
