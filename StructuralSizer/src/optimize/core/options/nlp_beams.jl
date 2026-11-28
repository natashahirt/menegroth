"""
    NLPBeamOptions

Configuration for continuous (NLP) RC beam sizing.

Optimizes beam width (b), depth (h), and reinforcement ratio (ρ) to find the
minimum-area section satisfying ACI 318 flexure and shear requirements.

# Fields
## Materials
- `material`: Concrete material (default: NWC_4000)
- `rebar_material`: RebarSteel for longitudinal bars (default: Rebar_60)
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
    material::Concrete = NWC_4000
    rebar_material::RebarSteel = Rebar_60
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
    objective::AbstractObjective = MinWeight()
    maxiter::Int = 200
    tol::Float64 = 1e-4
    verbose::Bool = false

    # Post-processing
    snap::Bool = true
end

