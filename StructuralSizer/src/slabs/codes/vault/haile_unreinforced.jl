# Unreinforced Masonry/Concrete Vault Sizing
# Based on Haile's method for unreinforced thin shell parabolic vaults
#
# Reference: Haile method for three-hinge parabolic arch analysis
#
# Key assumptions:
# - Parabolic intrados geometry
# - Three-hinge arch behavior (momentless under UDL if shape matches pressure line)
# - No tensile capacity (unreinforced)
# - Extrados is intrados shifted vertically by shell thickness
# - Optional ribs modeled as flat-topped extensions above extrados


# =============================================================================
# Geometry Utilities
# =============================================================================

"""
Calculate arc length of a parabolic vault.

Intrados defined by: y(x) = (4h/s²) * x * (s - x)

Translation of getParabolicArcLength.m
"""
function parabolic_arc_length(span::Real, rise::Real)
    # y = (4h/s²) * (sx - x²)
    # dy/dx = (4h/s²) * (s - 2x)
    # L = integral of sqrt(1 + (dy/dx)²) dx from 0 to s
    k = 4 * rise / span^2
    integrand(x) = sqrt(1 + (k * (span - 2x))^2)
    L, _ = quadgk(integrand, 0, span)
    return L
end

"""
Intrados height at position x for parabolic vault.
y(x) = (4h/s²) * x * (s - x)
"""
intrados(x, span, rise) = (4rise / span^2) * (span * x - x^2)

"""
Extrados height at position x (intrados + shell thickness).
"""
extrados(x, span, rise, thickness) = intrados(x, span, rise) + thickness

"""
    get_vault_properties(span, rise, thickness, trib_depth, rib_depth, rib_apex_rise)

Calculate geometric properties (volumes, areas) for a parabolic vault cross-section.

All inputs are dimensionless (pre-stripped to consistent length units). The returned
values share those same implied length units.

# Arguments
- `span::Real`: Clear span (chord length).
- `rise::Real`: Rise at crown.
- `thickness::Real`: Shell thickness.
- `trib_depth::Real`: Tributary depth / rib spacing.
- `rib_depth::Real`: Rib width in the span direction (0 for no ribs).
- `rib_apex_rise::Real`: Additional rib height above extrados at apex (0 for no ribs).

# Returns
Named tuple with fields:
- `arc_length`: Parabolic arc length of the intrados.
- `shell_cs_area`: Shell cross-sectional area (thickness × span approximation).
- `shell_vol`: Shell volume (shell_cs_area × trib_depth).
- `rib_cs_area`: Rib cross-sectional area (0 if no ribs).
- `rib_vol`: Rib volume (rib_cs_area × rib_depth).
- `total_vol`: Total material volume (shell + ribs).

Reference: Haile's method for unreinforced parabolic vault geometry.
"""
function get_vault_properties(
    span::Real,
    rise::Real,
    thickness::Real,
    trib_depth::Real,
    rib_depth::Real,
    rib_apex_rise::Real
)
    # Shell volume: arc_length × thickness × trib_depth
    arc_len = parabolic_arc_length(span, rise)
    
    # Cross-sectional area of the shell (per unit depth)
    # Integral of (extrados - intrados) = thickness * span (linear shift approximation)
    shell_cs_area = thickness * span
    shell_vol = shell_cs_area * trib_depth
    
    # Rib calculations
    rib_cs_area = 0.0
    if rib_apex_rise > 0 && rib_depth > 0
        rib_top_height = rise + thickness + rib_apex_rise
        rib_integrand(x) = max(0.0, rib_top_height - extrados(x, span, rise, thickness))
        val, _ = quadgk(rib_integrand, 0, span)
        rib_cs_area = val
    end
    rib_vol = rib_cs_area * rib_depth
    
    return (
        arc_length = arc_len,
        shell_cs_area = shell_cs_area,
        shell_vol = shell_vol,
        rib_cs_area = rib_cs_area,
        rib_vol = rib_vol,
        total_vol = shell_vol + rib_vol
    )
end

"""
    vault_volume_per_area(span, rise, thickness, trib_depth, rib_depth, rib_apex_rise)

Calculate material volume per unit plan area for a vault.

Accounts for curved shell geometry (arc length > span) and ribs.
All inputs are dimensionless (pre-stripped to consistent length units).

# Arguments
- `span::Real`: Clear span (chord length).
- `rise::Real`: Rise at crown.
- `thickness::Real`: Shell thickness.
- `trib_depth::Real`: Tributary depth / rib spacing.
- `rib_depth::Real`: Rib width in the span direction (0 for no ribs).
- `rib_apex_rise::Real`: Additional rib height above extrados at apex (0 for no ribs).

# Returns
- `Real`: Volume per plan area [length³/length² = length].
"""
function vault_volume_per_area(
    span::Real,
    rise::Real,
    thickness::Real,
    trib_depth::Real,
    rib_depth::Real,
    rib_apex_rise::Real
)
    props = get_vault_properties(span, rise, thickness, trib_depth, rib_depth, rib_apex_rise)
    
    # Normalized to plan area (span × trib_depth)
    plan_area = span * trib_depth
    return props.total_vol / plan_area
end

# =============================================================================
# Symmetric Load Analysis (VaultStress.m)
# =============================================================================

"""
    vault_stress_symmetric(span, rise, trib_depth, thickness, rib_depth, rib_apex_rise, 
                          density, applied_load, finishing_load)

Calculate working stress and thrust for symmetric UDL case (three-hinge parabolic arch).

# Arguments (all Unitful quantities)
- `span::Length`: Clear span (chord length)
- `rise::Length`: Rise at crown
- `trib_depth::Length`: Tributary depth / rib spacing
- `thickness::Length`: Shell thickness
- `rib_depth::Length`: Rib width in span direction (0 for no ribs)
- `rib_apex_rise::Length`: Additional rib height above extrados at apex (0 for no ribs)
- `density::Density`: Material density
- `applied_load::Pressure`: Applied load intensity (SDL + Live)
- `finishing_load::Pressure`: Topping/screed load intensity

# Returns
Named tuple with Unitful quantities:
- `σ::Pressure`: Working stress at abutment
- `thrust::Force`: Horizontal thrust
- `self_weight::Pressure`: Self-weight intensity
- `vertical::Force`: Vertical reaction at support
"""
function vault_stress_symmetric(
    span::Length,
    rise::Length,
    trib_depth::Length,
    thickness::Length,
    rib_depth::Length,
    rib_apex_rise::Length,
    density::Unitful.Density,
    applied_load::Unitful.Pressure,
    finishing_load::Unitful.Pressure
)
    # Strip to consistent SI units for geometry calculations
    span_m = ustrip(u"m", span)
    rise_m = ustrip(u"m", rise)
    trib_m = ustrip(u"m", trib_depth)
    t_m = ustrip(u"m", thickness)
    rib_d_m = ustrip(u"m", rib_depth)
    rib_h_m = ustrip(u"m", rib_apex_rise)
    
    # --- Geometric Properties (dimensionless ratios, same units in = same units out) ---
    props = get_vault_properties(span_m, rise_m, t_m, trib_m, rib_d_m, rib_h_m)
    total_vol = props.total_vol * u"m^3"
    
    # --- Mass and Self-weight (Unitful handles all conversions) ---
    total_mass = total_vol * density                    # Volume × Density = Mass
    total_self_weight = total_mass * Asap.GRAVITY        # Mass × Acceleration = Force
    
    plan_area = span * trib_depth
    self_weight = total_self_weight / plan_area         # Force / Area = Pressure
    
    # --- Total distributed load ---
    # Convert pressure loads to line loads (force per unit span length)
    total_pressure = applied_load + finishing_load + self_weight
    total_UDL = total_pressure * trib_depth             # Pressure × Length = Force/Length
    
    # --- Three-hinge parabolic arch analysis ---
    # Vertical reaction at each support: V = wL/2
    vertical = (total_UDL * span) / 2                   # (Force/Length) × Length = Force
    
    # Horizontal thrust: H = wL²/(8h) for parabolic arch under UDL
    thrust = (total_UDL * span^2) / (8 * rise)          # Force
    
    # Resultant force at abutment
    resultant = sqrt(vertical^2 + thrust^2)             # Force
    
    # --- Working stress ---
    resisting_area = trib_depth * thickness             # Length × Length = Area
    resisting_area > 0u"m^2" || error("Resisting area must be positive")
    
    σ = resultant / resisting_area                      # Force / Area = Pressure
    
    return (σ=σ, thrust=thrust, self_weight=self_weight, vertical=vertical)
end

# =============================================================================
# Asymmetric Load Analysis (VaultStress_Asymmetric.m)
# =============================================================================

"""
    vault_stress_asymmetric(span, rise, trib_depth, thickness, rib_depth, rib_apex_rise,
                           density, applied_load, finishing_load)

Calculate working stress and thrust for asymmetric case (live load on half-span).

This represents pattern loading where live load acts only on one half of the span,
which typically produces higher stresses than symmetric loading.

# Arguments (all Unitful quantities)
Same as `vault_stress_symmetric`.

# Returns
Named tuple with same fields as `vault_stress_symmetric`.

Reference: Haile's VaultStress_Asymmetric.m
"""
function vault_stress_asymmetric(
    span::Length,
    rise::Length,
    trib_depth::Length,
    thickness::Length,
    rib_depth::Length,
    rib_apex_rise::Length,
    density::Unitful.Density,
    applied_load::Unitful.Pressure,
    finishing_load::Unitful.Pressure
)
    # For asymmetric analysis, only live load is asymmetric
    # Total UDL on half 1 (left): SW + finish + Live
    # Total UDL on half 2 (right): SW + finish
    
    # 1. Base symmetric self-weight and finishing (no applied load)
    base = vault_stress_symmetric(span, rise, trib_depth, thickness, rib_depth, rib_apex_rise,
                                  density, zero(applied_load), finishing_load)
    
    # Dead load intensity (line load)
    q_d = (base.vertical * 2) / span  # Force / Length = Force/Length
    
    # 2. Live load intensity (line load)
    q_l = applied_load * trib_depth   # Pressure × Length = Force/Length
    
    # 3. Asymmetric Thrust: H = (L²/16h) * (2q_d + q_l)
    thrust = (span^2 / (16 * rise)) * (2q_d + q_l)  # Force
    
    # 4. Vertical reactions
    # V1 (loaded side) = (L/8) * (4q_d + 3q_l)
    V1 = (span / 8) * (4q_d + 3q_l)  # Force
    
    # 5. Working stress at abutments (governed by V1)
    resisting_area = trib_depth * thickness  # Area
    resultant = sqrt(V1^2 + thrust^2)        # Force
    
    σ = resultant / resisting_area           # Force / Area = Pressure
    
    return (σ=σ, thrust=thrust, self_weight=base.self_weight, vertical=V1)
end

# =============================================================================
# Elastic Shortening Solver (solveFullyCoupledRise.m)
# =============================================================================

"""
    solve_equilibrium_rise(span, initial_rise, total_load, thickness, trib_depth, E;
                          deflection_limit=span/240)

Determine equilibrium rise accounting for elastic shortening.

Iteratively solves for rise h such that geometric shortening (arc length reduction)
equals elastic shortening (axial strain × arc length).

# Arguments (all Unitful quantities)
- `span::Length`: Clear span
- `initial_rise::Length`: Initial rise at crown
- `total_load::Pressure`: Total load intensity (self-weight + applied + finishing)
- `thickness::Length`: Shell thickness
- `trib_depth::Length`: Tributary depth
- `E::Pressure`: Material elastic modulus

# Keyword Arguments
- `deflection_limit::Length`: Maximum allowable rise deflection (default: span/240)

# Returns
Named tuple with:
- `final_rise::Length`: Equilibrium rise, or `NaN*u"m"` if non-convergent
- `converged::Bool`: Whether solver converged
- `deflection_ok::Bool`: Whether deflection ≤ limit

Ref: Haile's solveFullyCoupledRise.m
"""
function solve_equilibrium_rise(
    span::Length,
    initial_rise::Length,
    total_load::Unitful.Pressure,
    thickness::Length,
    trib_depth::Length,
    E::Unitful.Pressure;
    deflection_limit::Length = span / 240
)
    # Strip to consistent SI base units for root finding (which needs Float64)
    span_m = ustrip(u"m", span)
    initial_rise_m = ustrip(u"m", initial_rise)
    total_load_Pa = ustrip(u"Pa", total_load)
    thickness_m = ustrip(u"m", thickness)
    trib_depth_m = ustrip(u"m", trib_depth)
    E_Pa = ustrip(u"Pa", E)
    deflection_limit_m = ustrip(u"m", deflection_limit)
    
    A_springing = thickness_m * trib_depth_m  # m²
    
    # Residual function for root finding: f(h) = ΔL_geometry(h) - ΔL_elastic(h)
    # All values in SI base units (m, Pa, N)
    function residual(h_m)
        # 1. Arc length at this rise
        L = parabolic_arc_length(span_m, h_m)
        L0 = parabolic_arc_length(span_m, initial_rise_m)
        ΔL_geom = L0 - L
        
        # 2. Elastic shortening
        # w = load intensity [Pa] × tributary width [m] = N/m (line load)
        # H = wL² / 8h [N]
        # V = wL / 2 [N]
        # R = sqrt(H² + V²) [N]
        w = total_load_Pa * trib_depth_m
        H = (w * span_m^2) / (8 * h_m)
        V = (w * span_m) / 2
        R = sqrt(H^2 + V^2)
        
        # ΔL = R * L / (A * E) [m]
        ΔL_elastic = (R * L) / (A_springing * E_Pa)
        
        return ΔL_geom - ΔL_elastic
    end
    
    # Solve for final_rise
    try
        # Use Order0() which mimics MATLAB's fzero (derivative-free, search-based)
        final_rise_m = find_zero(residual, initial_rise_m, Order0())
        
        # Sanity checks
        if final_rise_m <= 0 || final_rise_m > initial_rise_m * 1.1
            return (final_rise=NaN*u"m", converged=false, deflection_ok=false)
        end
        
        # Check deflection
        deflection_m = abs(initial_rise_m - final_rise_m)
        deflection_ok = deflection_m <= deflection_limit_m
        
        return (final_rise=final_rise_m*u"m", converged=true, deflection_ok=deflection_ok)
    catch e
        # Silently fail for expected non-convergence cases
        return (final_rise=NaN*u"m", converged=false, deflection_ok=false)
    end
end

# =============================================================================
# Internal span-based sizing helper: _size_span_floor
# =============================================================================

"""
Size an unreinforced vault using Haile's method.

# Arguments
- `span`: Clear span (chord length) - any length unit
- `sdl`: Superimposed dead load - any force/area unit
- `live`: Live load - any force/area unit
- `rise`: Rise at crown (provide either `rise` or `lambda`, not both)
- `lambda`: Span/rise ratio (dimensionless)
- `thickness`: Shell thickness (optional - iterates to find minimum if omitted)
- `trib_depth`: Tributary depth / rib spacing (default: 1.0m)
- `rib_depth`: Rib width in span direction (default: 0.0m, no ribs)
- `rib_apex_rise`: Additional rib height above extrados at apex (default: 0.0m)
- `finishing_load`: Topping/screed load (default: 0.0)
- `allowable_stress`: Max allowable compressive stress [MPa] (default: 0.45 fc')
- `deflection_limit`: Max allowable rise deflection (default: span/240)
- `check_asymmetric`: Also check half-span live load case (default: true)
- `verbose`: Enable debug logging (default: false)

# Returns
`VaultResult{L,P,F}` preserving input unit types, with structured check results.

# Example
```julia
result = _size_span_floor(Vault(), 6.0u"m", 1.0u"kN/m^2", 2.0u"kN/m^2"; rise=1.0u"m")

# Check result
is_adequate(result)  # true if all checks pass
result.stress_check.ok
result.deflection_check.ok
```
"""
function _size_span_floor(::Vault, span::L, sdl::F, live::F;
                    material::Concrete=NWC_4000,
                    options::AbstractFloorOptions=VaultOptions(),
                    rise::Union{L,Nothing}=nothing,
                    lambda::Union{Real,Nothing}=nothing,
                    thickness::Union{L,Nothing}=nothing,
                    trib_depth::Union{L,Nothing}=nothing,
                    rib_depth::Union{L,Nothing}=nothing,
                    rib_apex_rise::Union{L,Nothing}=nothing,
                    finishing_load::Union{F,Nothing}=nothing,
                    allowable_stress::Union{Real,Nothing}=nothing,
                    deflection_limit::Union{L,Nothing}=nothing,
                    check_asymmetric::Union{Bool,Nothing}=nothing,
                    verbose::Bool=false) where {L, F}
    
    # =========================================================================
    # PHASE 1: RESOLVE OPTIONS (kwargs override VaultOptions defaults)
    # =========================================================================
    vopt = options isa VaultOptions ? options : VaultOptions()
    
    # Geometry: kwargs override VaultOptions (which has sensible defaults)
    rise = isnothing(rise) ? vopt.rise : rise
    lambda = isnothing(lambda) ? vopt.lambda : lambda
    thickness = isnothing(thickness) ? vopt.thickness : thickness
    trib_depth = isnothing(trib_depth) ? vopt.trib_depth : trib_depth
    rib_depth = isnothing(rib_depth) ? vopt.rib_depth : rib_depth
    rib_apex_rise = isnothing(rib_apex_rise) ? vopt.rib_apex_rise : rib_apex_rise
    finishing_load = isnothing(finishing_load) ? vopt.finishing_load : finishing_load
    check_asymmetric = isnothing(check_asymmetric) ? vopt.check_asymmetric : check_asymmetric
    
    # Validate rise/lambda (exactly one must be provided)
    if !isnothing(rise) && !isnothing(lambda)
        throw(ArgumentError("Provide either `rise` or `lambda`, not both"))
    elseif isnothing(rise) && isnothing(lambda)
        throw(ArgumentError(
            "Vault requires rise or lambda. Set via VaultOptions: " *
            "VaultOptions(rise=1.0u\"m\") or VaultOptions(lambda=6.0)"))
    end
    
    # Allowable stress: kwargs → VaultOptions → default 0.45fc'
    allowable_stress_val = if !isnothing(allowable_stress)
        allowable_stress * u"MPa"
    elseif !isnothing(vopt.allowable_stress)
        vopt.allowable_stress * u"MPa"
    else
        0.45 * material.fc′
    end
    
    # Deflection limit: kwargs → VaultOptions → default span/240
    defl_lim = if !isnothing(deflection_limit)
        deflection_limit
    elseif !isnothing(vopt.deflection_limit)
        vopt.deflection_limit
    else
        span / 240
    end
    
    # =========================================================================
    # PHASE 2: RESOLVE GEOMETRY (stay Unitful)
    # =========================================================================
    
    # Compute rise from lambda if needed
    actual_rise = isnothing(rise) ? span / lambda : rise
    actual_rise > 0u"m" || throw(ArgumentError("Rise must be positive (check lambda > 0)"))
    initial_rise = actual_rise
    
    # Thickness may be nothing (auto-sized in Phase 3)
    actual_thickness = thickness
    
    if verbose
        @debug "═══════════════════════════════════════════════════════════════"
        @debug "VAULT SIZING - Haile Analytical Method"
        @debug "═══════════════════════════════════════════════════════════════"
        @debug "Geometry" span=span rise=actual_rise λ=round(ustrip(span/actual_rise), digits=2) trib=trib_depth
        @debug "Material" fc′=material.fc′ E=material.E ρ=material.ρ σ_allow=allowable_stress_val
        @debug "Loading" SDL=sdl Live=live Finish=finishing_load
    end
    
    # =========================================================================
    # PHASE 3: DETERMINE THICKNESS
    # =========================================================================
    if isnothing(actual_thickness)
        if verbose
            @debug "───────────────────────────────────────────────────────────────"
            @debug "PHASE 3: Auto-sizing thickness"
        end
        actual_thickness = _find_min_thickness(
            span, actual_rise, trib_depth, rib_depth, rib_apex_rise,
            material.ρ, material.E, sdl + live, finishing_load,
            allowable_stress_val, defl_lim, check_asymmetric
        )
        verbose && @debug "  Selected thickness" t=actual_thickness
    end
    
    # =========================================================================
    # PHASE 4: SYMMETRIC LOAD ANALYSIS
    # =========================================================================
    if verbose
        @debug "───────────────────────────────────────────────────────────────"
        @debug "PHASE 4: Symmetric Load Analysis"
    end
    
    # Dead component: SW + finishing + SDL (no live)
    sym_dead = vault_stress_symmetric(
        span, actual_rise, trib_depth, actual_thickness, rib_depth, rib_apex_rise,
        material.ρ, sdl, finishing_load
    )
    
    # Live component: Live load only
    sym_live = vault_stress_symmetric(
        span, actual_rise, trib_depth, actual_thickness, rib_depth, rib_apex_rise,
        material.ρ, live, zero(finishing_load)
    )
    
    σ_sym = sym_dead.σ + sym_live.σ           # Pressure (Unitful)
    σ_max = σ_sym
    governing_case = :symmetric
    thrust_dead = sym_dead.thrust             # Force (Unitful)
    thrust_live = sym_live.thrust             # Force (Unitful)
    sw = sym_dead.self_weight                 # Pressure (Unitful)
    
    if verbose
        @debug "  Self-weight" sw=sw
        @debug "  Thrust (dead)" H=thrust_dead
        @debug "  Thrust (live)" H=thrust_live
        @debug "  Stress (symmetric)" σ=σ_sym
    end
    
    # =========================================================================
    # PHASE 5: ASYMMETRIC LOAD ANALYSIS (if enabled)
    # =========================================================================
    if check_asymmetric
        if verbose
            @debug "───────────────────────────────────────────────────────────────"
            @debug "PHASE 5: Asymmetric Load Analysis (half-span live)"
        end
        
        asym_total = vault_stress_asymmetric(
            span, actual_rise, trib_depth, actual_thickness, rib_depth, rib_apex_rise,
            material.ρ, sdl + live, finishing_load
        )
        σ_asym = asym_total.σ
        
        if σ_asym > σ_max
            σ_max = σ_asym
            governing_case = :asymmetric
        end
        
        verbose && @debug "  Stress (asymmetric)" σ=σ_asym governs=(governing_case==:asymmetric)
    end
    
    # =========================================================================
    # PHASE 6: ELASTIC SHORTENING CHECK
    # =========================================================================
    if verbose
        @debug "───────────────────────────────────────────────────────────────"
        @debug "PHASE 6: Elastic Shortening Analysis"
    end
    
    # Total load (all Unitful)
    total_load = sdl + live + sw + finishing_load
    eq = solve_equilibrium_rise(
        span, actual_rise, total_load, actual_thickness, trib_depth, material.E;
        deflection_limit=defl_lim
    )
    
    final_rise = eq.converged ? eq.final_rise : actual_rise
    deflection = abs(initial_rise - final_rise)
    
    if verbose
        @debug "  Initial rise" h₀=initial_rise
        @debug "  Final rise" h_f=final_rise
        @debug "  Deflection" δ=deflection limit=defl_lim
        @debug "  Converged" converged=eq.converged
    end
    
    # =========================================================================
    # PHASE 7: BUILD CHECK RESULTS
    # =========================================================================
    
    # Stress check - explicitly convert both to same unit before comparing
    σ_max_MPa = ustrip(u"MPa", σ_max)
    σ_allow_MPa = ustrip(u"MPa", allowable_stress_val)
    σ_ratio = σ_max_MPa / σ_allow_MPa  # dimensionless ratio
    stress_ok = σ_max_MPa <= σ_allow_MPa
    stress_check = (σ=σ_max_MPa, σ_allow=σ_allow_MPa, ratio=σ_ratio, ok=stress_ok)
    
    # Deflection check
    δ_ratio = eq.converged ? ustrip(deflection / defl_lim) : Inf
    deflection_ok = eq.converged && eq.deflection_ok
    deflection_m = ustrip(u"m", deflection)
    defl_lim_m = ustrip(u"m", defl_lim)
    deflection_check = (δ=deflection_m, limit=defl_lim_m, ratio=δ_ratio, ok=deflection_ok)
    
    # Convergence check
    convergence_check = (converged=eq.converged, iterations=0)  # Haile doesn't track iterations
    
    if verbose
        @debug "═══════════════════════════════════════════════════════════════"
        @debug "RESULT SUMMARY"
        @debug "  Stress check" σ=round(σ_max_MPa, digits=3) σ_allow=σ_allow_MPa ratio=round(σ_ratio, digits=2) ok=stress_ok
        @debug "  Deflection check" δ=round(deflection_m*1000, digits=1) limit=round(defl_lim_m*1000, digits=1) unit="mm" ok=deflection_ok
        @debug "  Convergence" converged=eq.converged
        @debug "  ADEQUATE" adequate=(stress_ok && deflection_ok && eq.converged)
    end
    
    # Warnings for failures (independent of verbose)
    !eq.converged && @warn "Elastic shortening solver did not converge"
    eq.converged && !eq.deflection_ok && @warn "Deflection exceeds limit: $(round(deflection_m*1000, digits=1)) mm > $(round(defl_lim_m*1000, digits=1)) mm"
    !stress_ok && @warn "Working stress exceeds allowable: $(round(σ_max_MPa, digits=3)) > $(round(σ_allow_MPa, digits=3)) MPa"
    
    # =========================================================================
    # PHASE 8: BUILD OUTPUT RESULT
    # =========================================================================
    
    # Geometric properties for output (need stripped values for geometry helper)
    final_rise_m = ustrip(u"m", final_rise)
    span_m = ustrip(u"m", span)
    t_m = ustrip(u"m", actual_thickness)
    trib_m = ustrip(u"m", trib_depth)
    rib_d_m = ustrip(u"m", rib_depth)
    rib_h_m = ustrip(u"m", rib_apex_rise)
    
    props = get_vault_properties(span_m, final_rise_m, t_m, trib_m, rib_d_m, rib_h_m)
    vol_per_area = props.total_vol / (span_m * trib_m)  # m³/m² = m
    
    # Normalize all outputs to coherent SI (m, kPa, kN/m)
    t_out = uconvert(u"m", actual_thickness)
    rise_out = uconvert(u"m", final_rise)
    arc_len_out = props.arc_length * u"m"
    
    # Thrust: force / trib_depth = force per unit length (line load at support)
    thrust_dead_line = thrust_dead / trib_depth
    thrust_live_line = thrust_live / trib_depth
    thrust_dead_out = uconvert(u"kN/m", thrust_dead_line)
    thrust_live_out = uconvert(u"kN/m", thrust_live_line)
    
    # Volume per area (m³/m² = m)
    vol_out = vol_per_area * u"m"
    
    sw_out = uconvert(u"kPa", sw)
    
    return VaultResult(
        t_out, rise_out, arc_len_out,
        thrust_dead_out, thrust_live_out,
        vol_out, sw_out,
        σ_max_MPa, governing_case,
        stress_check, deflection_check, convergence_check
    )
end

"""
    _find_min_thickness(span, rise, trib_depth, rib_depth, rib_apex_rise,
                        density, E, applied_load, finishing_load,
                        allowable_stress, deflection_limit, check_asymmetric;
                        t_min=0.03u"m", t_max=0.50u"m", t_step=0.005u"m")

Find minimum thickness satisfying stress and deflection constraints.

All arguments are Unitful quantities. Returns minimum thickness as Unitful Length.
"""
function _find_min_thickness(
    span::Length,
    rise::Length,
    trib_depth::Length,
    rib_depth::Length,
    rib_apex_rise::Length,
    density::Unitful.Density,
    E::Unitful.Pressure,
    applied_load::Unitful.Pressure,
    finishing_load::Unitful.Pressure,
    allowable_stress::Union{Unitful.Pressure, Nothing},
    deflection_limit::Length,
    check_asymmetric::Bool;
    t_min::Length = 0.03u"m",
    t_max::Length = 0.50u"m",
    t_step::Length = 0.005u"m"
)
    has_stress_check = !isnothing(allowable_stress)
    
    # Iterate over thickness range
    t_min_m = ustrip(u"m", t_min)
    t_max_m = ustrip(u"m", t_max)
    t_step_m = ustrip(u"m", t_step)
    
    for t_m in t_min_m:t_step_m:t_max_m
        t = t_m * u"m"
        
        if has_stress_check
            sym = vault_stress_symmetric(span, rise, trib_depth, t, rib_depth, rib_apex_rise,
                                         density, applied_load, finishing_load)
            σ_max = sym.σ
            sw = sym.self_weight
            
            if check_asymmetric
                asym = vault_stress_asymmetric(span, rise, trib_depth, t, rib_depth, rib_apex_rise,
                                               density, applied_load, finishing_load)
                if asym.σ > σ_max
                    σ_max = asym.σ
                end
            end
            
            # Stress check (both Unitful)
            σ_max > allowable_stress && continue
        else
            sym = vault_stress_symmetric(span, rise, trib_depth, t, rib_depth, rib_apex_rise,
                                         density, applied_load, finishing_load)
            sw = sym.self_weight
        end
        
        # Total load (all Unitful Pressure)
        total_load = applied_load + sw + finishing_load
        eq = solve_equilibrium_rise(span, rise, total_load, t, trib_depth, E;
                                    deflection_limit=deflection_limit)
        
        if eq.converged && eq.deflection_ok
            return t
        end
    end
    
    @warn "Could not find valid thickness in range [$(t_min), $(t_max)]"
    return t_max
end
