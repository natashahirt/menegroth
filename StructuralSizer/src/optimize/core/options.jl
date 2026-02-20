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
# Steel Member Options (columns + beams)
# ==============================================================================

"""
    SteelMemberOptions

Configuration for steel member sizing (columns **and** beams).

The same AISC checker + MIP optimizer serves both, so one struct covers both
use-cases.  The type aliases `SteelColumnOptions` and `SteelBeamOptions` are
provided for readability; they are the *same* type.

# Example
```julia
# Columns — W shapes, A992
opts = SteelColumnOptions()

# HSS columns with depth limit
opts = SteelColumnOptions(section_type = :hss, max_depth = 0.4)

# Floor beams with L/360 deflection check
opts = SteelBeamOptions(deflection_limit = 1/360)

# Roof beams — relaxed deflection
opts = SteelBeamOptions(deflection_limit = 1/240)
```

# Fields
- `material`: Steel grade (default: A992_Steel)
- `section_type`: `:w`, `:hss`, `:pipe`, `:w_and_hss` (default: `:w`)
- `catalog`: `:common`, `:preferred`, `:all` (default: `:preferred`)
- `custom_catalog`: Custom section vector (overrides catalog)
- `max_depth`: Maximum depth in meters (default: Inf)
- `deflection_limit`: L/δ ratio for serviceability, e.g. `1/360`.
  `nothing` = no deflection check (default: `nothing`)
- `n_max_sections`: Limit unique sections, 0 = no limit (default: 0)
- `objective`: MinVolume(), MinWeight(), MinCost(), MinCarbon() (default: MinVolume())
- `optimizer`: `:auto`, `:highs`, `:gurobi` (default: `:auto`)
"""
Base.@kwdef struct SteelMemberOptions
    material::StructuralSteel = A992_Steel
    section_type::Symbol = :w           # :w, :hss, :pipe, :w_and_hss
    catalog::Symbol = :preferred        # :common, :preferred, :all
    custom_catalog::Union{Nothing, Vector} = nothing
    max_depth::Length = Inf * u"m"
    deflection_limit::Union{Nothing, Float64} = nothing  # L/δ (beams)
    n_max_sections::Int = 0             # 0 = no limit
    objective::AbstractObjective = MinVolume()
    optimizer::Symbol = :auto           # :auto, :highs, :gurobi
end

"""Alias — steel columns and beams share the same AISC checker."""
const SteelColumnOptions = SteelMemberOptions

"""Alias — steel columns and beams share the same AISC checker."""
const SteelBeamOptions = SteelMemberOptions

# ==============================================================================
# Concrete Column Options
# ==============================================================================

"""
    ConcreteColumnOptions

Configuration for reinforced concrete column sizing.

# Example
```julia
opts = ConcreteColumnOptions()

opts = ConcreteColumnOptions(section_shape = :circular)

opts = ConcreteColumnOptions(
    grade = NWC_6000,
    section_shape = :rect,
    max_depth = 0.6,
)

opts = ConcreteColumnOptions(
    grade = NWC_5000,
    rebar_grade = Rebar_75,
    cover = 50.8u"mm",
    transverse_bar_size = :no4,
)
```

# Fields
- `grade`: Concrete material (default: NWC_4000)
- `section_shape`: `:rect` or `:circular` (default: `:rect`)
- `rebar_grade`: RebarSteel material for longitudinal bars (default: Rebar_60)
- `transverse_rebar_grade`: RebarSteel for ties/spirals (default: same as rebar_grade)
- `cover`: Clear cover to transverse reinforcement (default: 1.5" or 38mm)
- `transverse_bar_size`: Tie/spiral bar size, :no3, :no4, :no5 (default: :no4)
- `catalog`: `:standard`, `:low_capacity`, `:high_capacity`, `:all` (default: `:standard`)
- `custom_catalog`: Custom section vector (overrides catalog)
- `max_depth`: Maximum depth/diameter in meters (default: Inf)
- `n_max_sections`: Limit unique sections, 0 = no limit (default: 0)
- `include_slenderness`: Consider slenderness effects (default: true)
- `include_biaxial`: Consider biaxial bending (default: true)
- `βdns`: Sustained load ratio for slenderness (default: 0.6)
- `objective`: MinVolume(), MinWeight(), MinCost(), MinCarbon() (default: MinVolume())
- `optimizer`: `:auto`, `:highs`, `:gurobi` (default: `:auto`)
- `shape_constraint`: `:square`, `:bounded`, `:free` (default: `:square`)
  - `:square` — force c1 = c2 at every growth step (current behavior)
  - `:bounded` — allow rectangular columns, capped by `max_aspect_ratio`
  - `:free` — no aspect ratio constraint (research use only)
- `max_aspect_ratio`: Maximum c1/c2 or c2/c1 when `shape_constraint == :bounded` (default: 2.0)
- `size_increment`: Rounding increment for column dimensions (default: 0.5")

# Material Presets
- Concrete: NWC_3000, NWC_4000, NWC_5000, NWC_6000, NWC_GGBS, NWC_PFA
- Rebar: Rebar_40, Rebar_60, Rebar_75, Rebar_80

"""
Base.@kwdef struct ConcreteColumnOptions
    grade::Concrete = NWC_4000
    section_shape::Symbol = :rect       # :rect or :circular
    rebar_grade::RebarSteel = Rebar_60
    transverse_rebar_grade::Union{Nothing, RebarSteel} = nothing  # defaults to rebar_grade
    cover::Length = 38.1u"mm"                    # Clear cover to ties (≈1.5")
    transverse_bar_size::Symbol = :no4         # :no3, :no4, :no5
    catalog::Symbol = :standard         # :standard, :low_capacity, :high_capacity, :all
    custom_catalog::Union{Nothing, Vector} = nothing
    max_depth::Length = Inf * u"m"       # depth for rect, diameter for circular
    n_max_sections::Int = 0             # 0 = no limit
    include_slenderness::Bool = true
    include_biaxial::Bool = true
    βdns::Float64 = 0.6
    objective::AbstractObjective = MinVolume()
    optimizer::Symbol = :auto

    # ─── Column Shape / Growth Control ───
    # Controls how column dimensions (c1, c2) evolve during the slab-column
    # iteration loop when columns must grow for punching shear or P-M capacity.
    #   :square  — force c1 = c2 at every growth step (legacy default)
    #   :bounded — allow c1 ≠ c2, capped by max_aspect_ratio
    #   :free    — no aspect ratio constraint (research only)
    shape_constraint::Symbol = :square
    # Maximum c1/c2 or c2/c1 (only active when shape_constraint == :bounded).
    # ACI punching β factor penalizes aspect ratios > ~2 heavily (Eq. 22.6.5.2(a)).
    max_aspect_ratio::Float64 = 2.0
    # Rounding increment for column dimensions. The direct punching solve jumps
    # to the required size and rounds up to the nearest multiple of this value.
    size_increment::Length = 0.5u"inch"
end

# Import ksi for use in helper functions
using Asap: ksi

# Helper to get rebar yield strength from options
function get_rebar_fy(opts::ConcreteColumnOptions)
    uconvert(ksi, opts.rebar_grade.Fy)
end

# Helper to get effective transverse rebar grade
function get_transverse_rebar(opts::ConcreteColumnOptions)
    isnothing(opts.transverse_rebar_grade) ? opts.rebar_grade : opts.transverse_rebar_grade
end

# Helper to get transverse bar diameter in inches
const TRANSVERSE_BAR_DIAMETERS = Dict(
    :no3 => 0.375,  # 3/8"
    :no4 => 0.500,  # 1/2"
    :no5 => 0.625,  # 5/8"
)

function get_transverse_bar_diameter(opts::ConcreteColumnOptions)
    get(TRANSVERSE_BAR_DIAMETERS, opts.transverse_bar_size, 0.5)
end

# ==============================================================================
# Concrete Beam Options
# ==============================================================================

"""
    ConcreteBeamOptions

Configuration for reinforced concrete beam sizing (ACI 318 flexure + shear).

# Example
```julia
opts = ConcreteBeamOptions()

opts = ConcreteBeamOptions(
    grade = NWC_5000,
    rebar_grade = Rebar_75,
    deflection_limit = 1/480,
)

opts = ConcreteBeamOptions(
    cover = 50.8u"mm",
    transverse_bar_size = :no4,
    max_depth = 0.6,
)
```

# Fields
## Materials
- `grade`: Concrete material (default: NWC_4000)
- `rebar_grade`: RebarSteel for longitudinal bars (default: Rebar_60)
- `transverse_rebar_grade`: RebarSteel for stirrups (default: same as rebar_grade)
- `cover`: Clear cover to stirrups (default: 1.5" or 38mm)
- `transverse_bar_size`: Stirrup bar size :no3, :no4, :no5 (default: :no3)

## Catalog (discrete sizing)
- `catalog`: `:standard`, `:all` (default: `:standard`)
- `custom_catalog`: Custom section vector (overrides catalog)

## Dimension Constraints
- `max_depth`: Maximum overall depth in meters (default: Inf)
- `max_width`: Maximum width in meters (default: Inf)

## Design Settings
- `deflection_limit`: L/δ ratio, e.g. `1/360`.
  `nothing` = no check (default: `1/360`)
- `include_flange`: If `true`, the building-level sizing dispatcher
  (`size_beams!`) auto-computes the effective T-beam flange width and slab
  thickness from adjacent slabs and routes to the T-beam sizing API.
  The ACI 318-11 §8.12.2 effective flange width limits are applied
  automatically, using beam tributary width as `sw` and `edge_face_counts`
  for interior/edge classification.  (default: `false`)
- `catalog_size_tbeam`: T-beam catalog density when `include_flange=true`
  and method=`:discrete`.  `:standard`, `:small`, `:large` (default: `:standard`)

## Optimization
- `n_max_sections`: Limit unique sections, 0 = no limit (default: 0)
- `objective`: MinVolume(), MinWeight(), MinCost(), MinCarbon() (default: MinVolume())
- `optimizer`: `:auto`, `:highs`, `:gurobi` (default: `:auto`)
"""
Base.@kwdef struct ConcreteBeamOptions
    # Materials
    grade::Concrete = NWC_4000
    rebar_grade::RebarSteel = Rebar_60
    transverse_rebar_grade::Union{Nothing, RebarSteel} = nothing
    cover::Length = 38.1u"mm"            # ≈ 1.5" to stirrups
    transverse_bar_size::Symbol = :no3   # Stirrup bar size

    # Catalog (discrete)
    catalog::Symbol = :standard
    custom_catalog::Union{Nothing, Vector} = nothing

    # Dimension constraints
    max_depth::Length = Inf * u"m"
    max_width::Length = Inf * u"m"

    # Design settings
    deflection_limit::Union{Nothing, Float64} = 1/360
    include_flange::Bool = false
    catalog_size_tbeam::Symbol = :standard

    # Optimization
    n_max_sections::Int = 0
    objective::AbstractObjective = MinVolume()
    optimizer::Symbol = :auto
end

# Helpers for ConcreteBeamOptions (same API as column helpers)
function get_rebar_fy(opts::ConcreteBeamOptions)
    uconvert(ksi, opts.rebar_grade.Fy)
end

function get_transverse_rebar(opts::ConcreteBeamOptions)
    isnothing(opts.transverse_rebar_grade) ? opts.rebar_grade : opts.transverse_rebar_grade
end

function get_transverse_bar_diameter(opts::ConcreteBeamOptions)
    get(TRANSVERSE_BAR_DIAMETERS, opts.transverse_bar_size, 0.5)
end

# ==============================================================================
# Union Types for Dispatch
# ==============================================================================

"""Column sizing options (either steel or concrete)."""
const ColumnOptions = Union{SteelMemberOptions, ConcreteColumnOptions}

"""Beam sizing options (steel, concrete, or nothing)."""
const BeamOptions = Union{SteelMemberOptions, ConcreteBeamOptions}

"""Any member sizing options."""
const MemberOptions = Union{SteelMemberOptions, ConcreteColumnOptions, ConcreteBeamOptions}

# ==============================================================================
# Display
# ==============================================================================

function Base.show(io::IO, opts::SteelMemberOptions)
    mat_str = material_name(opts.material)
    sec_type = uppercase(string(opts.section_type))
    print(io, "SteelMemberOptions(", mat_str, " ", sec_type)
    isfinite(opts.max_depth) && print(io, ", max_depth=", opts.max_depth)
    !isnothing(opts.deflection_limit) && print(io, ", L/", Int(round(1/opts.deflection_limit)))
    opts.n_max_sections > 0 && print(io, ", n_max=", opts.n_max_sections)
    print(io, ")")
end

function Base.show(io::IO, opts::ConcreteColumnOptions)
    mat_str = material_name(opts.grade)
    shape_str = opts.section_shape == :circular ? "CIRCULAR" : "RECT"
    print(io, "ConcreteColumnOptions(", mat_str, " ", shape_str)
    isfinite(opts.max_depth) && print(io, ", max_depth=", opts.max_depth)
    opts.n_max_sections > 0 && print(io, ", n_max=", opts.n_max_sections)
    !opts.include_slenderness && print(io, ", no_slenderness")
    !opts.include_biaxial && print(io, ", no_biaxial")
    print(io, ")")
end

function Base.show(io::IO, opts::ConcreteBeamOptions)
    mat_str = material_name(opts.grade)
    print(io, "ConcreteBeamOptions(", mat_str)
    isfinite(opts.max_depth) && print(io, ", max_depth=", opts.max_depth)
    isfinite(opts.max_width) && print(io, ", max_width=", opts.max_width)
    if !isnothing(opts.deflection_limit)
        print(io, ", L/", Int(round(1/opts.deflection_limit)))
    end
    opts.n_max_sections > 0 && print(io, ", n_max=", opts.n_max_sections)
    print(io, ")")
end

# ==============================================================================
# NLP Column Options (Continuous Optimization)
# ==============================================================================

"""
    NLPColumnOptions

Configuration for continuous (NLP) RC column sizing using interior point optimization.

Unlike `ConcreteColumnOptions` which selects from a discrete catalog,
this optimizes column dimensions (b, h) and reinforcement ratio (ρg) continuously
to find the minimum-volume section that satisfies ACI 318 requirements.

# Example
```julia
opts = NLPColumnOptions()

opts = NLPColumnOptions(
    grade = NWC_5000,
    min_dim = 14.0u"inch",
    max_dim = 36.0u"inch",
    prefer_square = 0.1,
)

opts = NLPColumnOptions(
    aspect_limit = 1.5,
    dim_increment = 2.0u"inch",
)
```

# Fields
## Materials
- `grade`: Concrete material (default: NWC_4000)
- `rebar_grade`: RebarSteel for longitudinal bars (default: Rebar_60)
- `cover`: Clear cover to ties (default: 1.5" or 38mm)
- `tie_type`: :tied or :spiral (default: :tied)

## Dimension Bounds
- `min_dim`: Minimum column dimension (default: 8" — no ACI code minimum; practical floor from cover+ties+bars)
- `max_dim`: Maximum column dimension (default: 48")
- `dim_increment`: Round final dimensions to this increment (default: 2")
- `aspect_limit`: Maximum aspect ratio max(b,h)/min(b,h) (default: 3.0)
- `prefer_square`: Penalty factor for non-square sections, 0 = no penalty (default: 0.0)

## Design Settings
- `include_slenderness`: Consider moment magnification (default: true)
- `βdns`: Sustained load ratio for slenderness (default: 0.6)
- `bar_size`: Default bar size for reinforcement (default: 8 = #8 bars)

## Solver Settings
- `solver`: Optimization backend :ipopt, :grid, :nlopt (default: :ipopt)
- `objective`: MinVolume(), MinWeight(), MinCost(), MinCarbon() (default: MinVolume())
- `maxiter`: Maximum solver iterations (default: 200)
- `tol`: Convergence tolerance (default: 1e-4)
- `verbose`: Print solver progress (default: false)
"""
Base.@kwdef struct NLPColumnOptions
    # Materials
    grade::Concrete = NWC_4000
    rebar_grade::RebarSteel = Rebar_60
    cover::Length = 38.1u"mm"           # ≈ 1.5"
    tie_type::Symbol = :tied
    
    # Dimension bounds (no ACI code minimum; 8" is practical floor from cover+ties+bars)
    min_dim::Length = 8.0u"inch"
    max_dim::Length = 48.0u"inch"
    dim_increment::Length = 2.0u"inch"
    aspect_limit::Float64 = 3.0
    prefer_square::Float64 = 0.0
    
    # Design settings
    include_slenderness::Bool = true
    βdns::Float64 = 0.6
    bar_size::Int = 8
    ρ_max::Float64 = 0.06          # Practical max ρg for NLP (ACI allows 0.08, practical ≤ 0.06)
    
    # Solver settings
    solver::Symbol = :ipopt
    objective::AbstractObjective = MinVolume()
    maxiter::Int = 200
    tol::Float64 = 1e-4
    verbose::Bool = false
    n_multistart::Int = 1  # >1 enables multi-start for non-smooth P-M problems

    # Post-processing
    snap::Bool = true   # Round final dimensions to dim_increment
end

function Base.show(io::IO, opts::NLPColumnOptions)
    mat_str = material_name(opts.grade)
    min_in = round(Int, ustrip(u"inch", opts.min_dim))
    max_in = round(Int, ustrip(u"inch", opts.max_dim))
    print(io, "NLPColumnOptions(", mat_str)
    print(io, ", dims=", min_in, "\"-", max_in, "\"")
    opts.aspect_limit < 3.0 && print(io, ", aspect≤", opts.aspect_limit)
    opts.prefer_square > 0 && print(io, ", prefer_square")
    !opts.include_slenderness && print(io, ", no_slenderness")
    print(io, ", solver=:", opts.solver, ")")
end

# ==============================================================================
# NLP HSS Column Options (Continuous Steel Optimization)
# ==============================================================================

"""
    NLPHSSOptions

Configuration for continuous (NLP) HSS column sizing using interior point optimization.

Optimizes rectangular HSS dimensions (B, H, t) continuously to find the 
minimum-weight section that satisfies AISC 360 requirements. Uses smooth
approximations of AISC functions for compatibility with automatic differentiation.

# Example
```julia
opts = NLPHSSOptions()

opts = NLPHSSOptions(
    min_outer = 4.0u"inch",
    max_outer = 20.0u"inch",
    min_thickness = 0.125u"inch",
    max_thickness = 0.625u"inch",
)

opts = NLPHSSOptions(prefer_square = 0.2)

opts = NLPHSSOptions(use_ad = true)
```

# Fields
## Material
- `material`: Steel grade (default: A992_Steel)

## Dimension Bounds (for rectangular HSS: B × H × t)
- `min_outer`: Minimum outer dimension B or H (default: 4")
- `max_outer`: Maximum outer dimension B or H (default: 20")
- `min_thickness`: Minimum wall thickness t (default: 1/8" = 0.125")
- `max_thickness`: Maximum wall thickness t (default: 5/8" = 0.625")
- `thickness_increment`: Round thickness to standard sizes (default: 1/16")
- `outer_increment`: Round outer dims to standard sizes (default: 1")

## Design Constraints
- `aspect_limit`: Maximum aspect ratio max(B,H)/min(B,H) (default: 3.0)
- `prefer_square`: Penalty factor for non-square sections (default: 0.0)
- `min_b_t`: Minimum width-to-thickness ratio (default: 5.0)

## Solver Settings
- `solver`: Optimization backend :ipopt, :nlopt (default: :ipopt)
- `use_ad`: Use automatic differentiation for gradients (default: false, uses finite diff)
- `objective`: MinVolume(), MinWeight(), etc. (default: MinWeight())
- `maxiter`: Maximum solver iterations (default: 200)
- `tol`: Convergence tolerance (default: 1e-4)
- `verbose`: Print solver progress (default: false)
- `smooth_k`: Smoothing parameter for differentiable AISC functions (default: 20.0)
"""
Base.@kwdef struct NLPHSSOptions
    # Material
    material::StructuralSteel = A992_Steel
    
    # Dimension bounds (inches internally)
    min_outer::Length = 4.0u"inch"
    max_outer::Length = 20.0u"inch"
    min_thickness::Length = 0.125u"inch"   # 1/8"
    max_thickness::Length = 0.625u"inch"   # 5/8"
    thickness_increment::Length = 0.0625u"inch"  # 1/16"
    outer_increment::Length = 1.0u"inch"
    
    # Design constraints
    aspect_limit::Float64 = 3.0
    prefer_square::Float64 = 0.0
    min_b_t::Float64 = 5.0  # Practical minimum for fabrication
    
    # Solver settings
    solver::Symbol = :ipopt
    use_ad::Bool = false  # Use ForwardDiff for gradients
    objective::AbstractObjective = MinWeight()
    maxiter::Int = 200
    tol::Float64 = 1e-4
    verbose::Bool = false
    smooth_k::Float64 = 20.0  # Smoothing parameter for AISC functions

    # Post-processing
    snap::Bool = true   # Round final dimensions to outer_increment / thickness_increment
end

function Base.show(io::IO, opts::NLPHSSOptions)
    mat_str = material_name(opts.material)
    min_in = round(ustrip(u"inch", opts.min_outer), digits=1)
    max_in = round(ustrip(u"inch", opts.max_outer), digits=1)
    print(io, "NLPHSSOptions(", mat_str)
    print(io, ", outer=", min_in, "\"-", max_in, "\"")
    opts.aspect_limit < 3.0 && print(io, ", aspect≤", opts.aspect_limit)
    opts.prefer_square > 0 && print(io, ", prefer_square")
    opts.use_ad && print(io, ", AD")
    print(io, ", solver=:", opts.solver, ")")
end

# ==============================================================================
# NLP W Section Column Options (Continuous Steel Optimization)
# ==============================================================================

"""
    NLPWOptions

Configuration for continuous (NLP) W section column sizing using interior point optimization.

Optimizes W section dimensions (d, bf, tf, tw) continuously to find the 
minimum-weight section that satisfies AISC 360 requirements. Treats the
section as a parameterized I-shape (similar to a built-up or welded section).

**Note**: Unlike catalog W sections which have fixed proportions, this optimizer
finds optimal dimensions that may not match standard rolled shapes. The result
is a custom continuous section, not a catalog section.

# Example
```julia
opts = NLPWOptions()

opts = NLPWOptions(
    min_depth = 10.0u"inch",
    max_depth = 24.0u"inch",
)

opts = NLPWOptions(max_flange_width = 12.0u"inch")
```

# Design Variables
The optimizer treats the W section as having 4 independent dimensions:
- `d`: Overall depth
- `bf`: Flange width
- `tf`: Flange thickness
- `tw`: Web thickness

# Fields
## Material
- `material`: Steel grade (default: A992_Steel)

## Dimension Bounds
- `min_depth`: Minimum overall depth (default: 8")
- `max_depth`: Maximum overall depth (default: 36")
- `min_flange_width`: Minimum flange width (default: 4")
- `max_flange_width`: Maximum flange width (default: 18")
- `min_flange_thickness`: Minimum flange thickness (default: 0.25")
- `max_flange_thickness`: Maximum flange thickness (default: 2.0")
- `min_web_thickness`: Minimum web thickness (default: 0.25")
- `max_web_thickness`: Maximum web thickness (default: 1.0")

## Proportioning Constraints (typical for rolled shapes)
- `bf_d_min`: Minimum bf/d ratio (default: 0.3)
- `bf_d_max`: Maximum bf/d ratio (default: 1.0)
- `tf_tw_min`: Minimum tf/tw ratio (default: 1.0)
- `tf_tw_max`: Maximum tf/tw ratio (default: 3.0)

## Design Settings
- `require_compact`: Require compact flanges/web for plastic capacity (default: true)

## Solver Settings
- `solver`: Optimization backend :ipopt, :nlopt (default: :ipopt)
- `objective`: MinVolume(), MinWeight(), etc. (default: MinWeight())
- `maxiter`: Maximum solver iterations (default: 200)
- `tol`: Convergence tolerance (default: 1e-4)
- `verbose`: Print solver progress (default: false)
- `smooth_k`: Smoothing parameter for differentiable AISC functions (default: 20.0)
"""
Base.@kwdef struct NLPWOptions
    # Material
    material::StructuralSteel = A992_Steel
    
    # Dimension bounds (inches internally)
    min_depth::Length = 8.0u"inch"
    max_depth::Length = 36.0u"inch"
    min_flange_width::Length = 4.0u"inch"
    max_flange_width::Length = 18.0u"inch"
    min_flange_thickness::Length = 0.25u"inch"
    max_flange_thickness::Length = 2.0u"inch"
    min_web_thickness::Length = 0.25u"inch"
    max_web_thickness::Length = 1.0u"inch"
    
    # Proportioning constraints (typical ranges for rolled W shapes)
    bf_d_min::Float64 = 0.3    # Narrow flange limit
    bf_d_max::Float64 = 1.0    # Wide flange limit
    tf_tw_min::Float64 = 1.0   # Minimum tf/tw
    tf_tw_max::Float64 = 3.0   # Maximum tf/tw
    
    # Design settings
    require_compact::Bool = true    # Require compact for full plastic capacity
    
    # Solver settings
    solver::Symbol = :ipopt
    objective::AbstractObjective = MinWeight()
    maxiter::Int = 200
    tol::Float64 = 1e-4
    verbose::Bool = false
    smooth_k::Float64 = 20.0

    # Post-processing
    snap::Bool = true   # Round final dimensions to 1/16" increments
end

"""
    NLPBeamOptions

Configuration for continuous (NLP) RC beam sizing.

Optimizes beam width (b), depth (h), and reinforcement ratio (ρ) to find the
minimum-area section satisfying ACI 318 flexure and shear requirements.

# Fields
## Materials
- `grade`: Concrete material (default: NWC_4000)
- `rebar_grade`: RebarSteel for longitudinal bars (default: Rebar_60)
- `cover`: Clear cover to stirrups (default: 1.5")
- `stirrup_size`: Stirrup bar size (default: 3)
- `bar_size`: Longitudinal bar size (default: 8)

## Dimension Bounds
- `min_width`: Minimum beam width (default: 10")
- `max_width`: Maximum beam width (default: 24")
- `min_depth`: Minimum beam depth (default: 12")
- `max_depth`: Maximum beam depth (default: 36")
- `dim_increment`: Round final dimensions to this increment (default: 2")

## Solver Settings
- `solver`: Optimization backend :ipopt, :grid (default: :ipopt)
- `objective`: Optimization objective (default: MinVolume())
- `maxiter`: Maximum solver iterations (default: 200)
- `tol`: Convergence tolerance (default: 1e-4)
- `verbose`: Print solver progress (default: false)

## Post-processing
- `snap`: Round final dimensions to dim_increment (default: true)
"""
Base.@kwdef struct NLPBeamOptions
    # Materials
    grade::Concrete = NWC_4000
    rebar_grade::RebarSteel = Rebar_60
    cover::Length = 38.1u"mm"           # ≈ 1.5"
    stirrup_size::Int = 3
    bar_size::Int = 8

    # Dimension bounds
    min_width::Length = 10.0u"inch"
    max_width::Length = 24.0u"inch"
    min_depth::Length = 12.0u"inch"
    max_depth::Length = 36.0u"inch"
    dim_increment::Length = 2.0u"inch"

    # Solver settings
    solver::Symbol = :ipopt
    objective::AbstractObjective = MinVolume()
    maxiter::Int = 200
    tol::Float64 = 1e-4
    verbose::Bool = false

    # Post-processing
    snap::Bool = true
end

function Base.show(io::IO, opts::NLPBeamOptions)
    mat_str = material_name(opts.grade)
    bmin = round(Int, ustrip(u"inch", opts.min_width))
    bmax = round(Int, ustrip(u"inch", opts.max_width))
    hmin = round(Int, ustrip(u"inch", opts.min_depth))
    hmax = round(Int, ustrip(u"inch", opts.max_depth))
    print(io, "NLPBeamOptions(", mat_str,
          ", b=", bmin, "\"-", bmax, "\"",
          ", h=", hmin, "\"-", hmax, "\"",
          ", solver=:", opts.solver, ")")
end

function Base.show(io::IO, opts::NLPWOptions)
    mat_str = material_name(opts.material)
    d_min = round(Int, ustrip(u"inch", opts.min_depth))
    d_max = round(Int, ustrip(u"inch", opts.max_depth))
    print(io, "NLPWOptions(", mat_str)
    print(io, ", d=", d_min, "\"-", d_max, "\"")
    !opts.require_compact && print(io, ", allow_noncompact")
    print(io, ", solver=:", opts.solver, ")")
end
