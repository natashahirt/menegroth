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
    material = NWC_5000,
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
- `material`: Concrete material (default: NWC_4000)
- `rebar_material`: RebarSteel for longitudinal bars (default: Rebar_60)
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
    material::Concrete = NWC_4000
    rebar_material::RebarSteel = Rebar_60
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
    objective::AbstractObjective = MinWeight()
    maxiter::Int = 200
    tol::Float64 = 1e-4
    verbose::Bool = false
    n_multistart::Int = 1  # >1 enables multi-start for non-smooth P-M problems

    # Post-processing
    snap::Bool = true   # Round final dimensions to dim_increment
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

