module Constants
    using Unitful 

    # 1. Define standard US units (structural engineering defaults)
    Unitful.@unit lbf "lbf" PoundForce 4.4482216152605u"N" false
    Unitful.@unit kip "kip" Kip 1000 * lbf false
    Unitful.@unit psf "psf" PoundPerSquareFoot 47.88025898u"N/m^2" false
    Unitful.@unit ksi "ksi" KipPerSquareInch 6.894757e6u"Pa" false  # 1 ksi = 6.895 MPa

    # 2. Physical Constants
    const GRAVITY = 9.80665u"m/s^2" # acceleration due to gravity

    # 3. Material Densities (kg/m³)
    const ρ_CONCRETE = 2400.0u"kg/m^3"
    const ρ_STEEL = 7850.0u"kg/m^3"
    const ρ_REBAR = 7850.0u"kg/m^3"

    # 4. Embodied Carbon Coefficients (kgCO2e/kg or kgCO2e/m³)
    const ECC_STEEL = 1.22
    const ECC_CONCRETE = 0.152 # from CLF
    const ECC_REBAR = 0.854

    # 5. Solver/Optimization Constants
    const BIG_M = 1e9

    # 6. Load Factors (ASCE 7 Strength)
    const DL_FACTOR = 1.2
    const LL_FACTOR = 1.6

    # 7. Standard Building Loads (needs to be kN/m² for ASAP compatibility)
    # Live loads (converted to kN/m^2)
    const LL_GRADE = uconvert(u"kN/m^2", 100.0 * psf)
    const LL_FLOOR = uconvert(u"kN/m^2", 80.0 * psf) # above grade
    const LL_ROOF  = uconvert(u"kN/m^2", 20.0 * psf) # roof live

    # Superimposed dead loads (converted to kN/m^2)
    const SDL_FLOOR = uconvert(u"kN/m^2", 15.0 * psf)
    const SDL_ROOF  = uconvert(u"kN/m^2", 15.0 * psf)
    const SDL_WALL  = uconvert(u"kN/m^2", 10.0 * psf) # per wall area

    # 8. Factored Loads (Pre-calculated for convenience)
    const LL_GRADE_f = LL_GRADE * LL_FACTOR
    const LL_FLOOR_f = LL_FLOOR * LL_FACTOR
    const LL_ROOF_f  = LL_ROOF  * LL_FACTOR

    const SDL_FLOOR_f = SDL_FLOOR * DL_FACTOR
    const SDL_ROOF_f  = SDL_ROOF  * DL_FACTOR

    # 9. Metric Reinforcement (Standard units for the package)
    const STANDARD_LENGTH = u"m"
    const STANDARD_AREA   = u"m^2"
    const STANDARD_FORCE  = u"kN"
    const STANDARD_PRESSURE = u"kN/m^2"
end
