# ==============================================================================
# ACI 318 T-Beam Flexural Design
# ==============================================================================
#
# T-beam specific flexural design per ACI 318-11.
# Uses shared Whitney stress block from codes/aci/whitney.jl.
#
# Key ACI sections:
#   8.12.2   - Effective flange width (ACI 318-11 §8.12.2)
#   10.2.7   - Whitney stress block (T-beam decomposition)
#   10.5.1   - Minimum flexural reinforcement (uses bw)
# ==============================================================================

using Unitful

# ==============================================================================
# Effective Flange Width (ACI 318-11 §8.12.2)
# ==============================================================================

"""
    effective_flange_width(; bw, hf, sw, ln, position=:interior) -> Length

Effective flange width for a T-beam per ACI 318-11 §8.12.2.

# Arguments
- `bw`: Web width
- `hf`: Flange (slab) thickness
- `sw`: Clear distance between adjacent webs
- `ln`: Clear span length
- `position`: `:interior` (flanges both sides) or `:edge` (flange one side)

# Interior beams (flanges on each side)
Each overhanging flange width ≤ least of:
- 8hf
- sw/2
- ln/8

# Edge beams (flange on one side only)
Overhanging flange width ≤ least of:
- 6hf
- sw/2
- ln/12

# Returns
Effective flange width bf (with units).

# Example
```julia
bf = effective_flange_width(bw=12u"inch", hf=5u"inch", sw=48u"inch", ln=240u"inch")
# Each side: min(40, 24, 30) = 24 → bf = 12 + 2×24 = 60 in
```
"""
function effective_flange_width(;
    bw::Length, hf::Length, sw::Length, ln::Length,
    position::Symbol = :interior,
)
    if position == :interior
        overhang = min(8 * hf, sw / 2, ln / 8)
        return bw + 2 * overhang
    elseif position == :edge
        overhang = min(6 * hf, sw / 2, ln / 12)
        return bw + overhang
    else
        error("Unknown position: $position. Use :interior or :edge")
    end
end

# ==============================================================================
# T-Beam Flexural Design
# ==============================================================================

"""
    design_tbeam_flexure(Mu, bw, d, bf, hf, fc, fy; ...) -> NamedTuple

T-beam flexural design for a singly reinforced section.

Checks whether the Whitney stress block falls within the flange
(rectangular behavior with width bf) or extends into the web
(true T-beam decomposition).

# Arguments
- `Mu`: Factored moment demand
- `bw`: Web width
- `d`: Effective depth
- `bf`: Effective flange width
- `hf`: Flange (slab) thickness
- `fc`: Concrete compressive strength
- `fy`: Steel yield strength

# Returns
Named tuple with:
- `case`: `:flange` or `:web`
- `As_required`, `As_min`, `As_design`
- `a`, `c`, `εt`, `φ`, `tension_controlled`
- `Cf`, `Cw` (compression forces; Cf = 0 for flange case)
- `bars`: Bar selection (placed in web width bw)

# Reference
- ACI 318-11 §10.2.7 (Whitney stress block)
- ACI 318-11 §8.12.2 (effective flange width)
"""
function design_tbeam_flexure(Mu::Moment, bw::Length, d::Length,
                               bf::Length, hf::Length,
                               fc::Pressure, fy::Pressure;
                               cover = 1.5u"inch",
                               d_stirrup = 0.375u"inch",
                               d_agg = 0.75u"inch")

    φ_assumed = 0.90

    # Try as rectangular beam with full flange width
    As_trial = required_reinforcement(Mu, bf, d, fc, fy)
    if isinf(As_trial)
        error("T-beam section inadequate: moment demand exceeds capacity. Increase d or f'c.")
    end
    a_trial = stress_block_depth(As_trial, fc, fy, bf)

    # Minimum reinforcement uses bw (ACI 318-11 §10.5.1)
    As_min = beam_min_reinforcement(bw, d, fc, fy)

    if a_trial ≤ hf
        # ----- Stress block in flange: rectangular behavior with bf -----
        As_design = max(As_trial, As_min)
        a = stress_block_depth(As_design, fc, fy, bf)
        c = neutral_axis_depth(a, fc)
        εt = tensile_strain(d, c)
        φ_actual = flexure_phi(εt)
        tc = is_tension_controlled(εt)

        bars = select_beam_bars(As_design, bw;
            cover=cover, d_stirrup=d_stirrup, d_agg=d_agg, fy=fy)

        return (
            case = :flange,
            As_required = As_trial,
            As_min = As_min,
            As_design = As_design,
            a = a,
            c = c,
            εt = εt,
            φ = φ_actual,
            tension_controlled = tc,
            Cf = 0.0u"lbf",
            Cw = 0.0u"lbf",
            bars = bars,
        )
    else
        # ----- True T-beam: stress block extends into web -----
        fc_psi = ustrip(u"psi", fc)
        fy_psi = ustrip(u"psi", fy)
        bf_in  = ustrip(u"inch", bf)
        bw_in  = ustrip(u"inch", bw)
        hf_in  = ustrip(u"inch", hf)
        d_in   = ustrip(u"inch", d)

        # Flange overhang compression
        Cf_lb = 0.85 * fc_psi * (bf_in - bw_in) * hf_in
        Mf_lbin = Cf_lb * (d_in - hf_in / 2)

        # Moment to be carried by web
        Mu_lbin = ustrip(u"lbf*inch", Mu)
        Mw_lbin = Mu_lbin / φ_assumed - Mf_lbin

        # Required web reinforcement from Whitney on bw × d
        Rn_w = Mw_lbin / (bw_in * d_in^2)
        β = beta1(fc)
        term = 2 * Rn_w / (β * fc_psi)
        term < 1.0 || error("T-beam web inadequate: increase h or bw")
        ρ_w = (β * fc_psi / fy_psi) * (1 - sqrt(1 - term))
        Asw_in = ρ_w * bw_in * d_in

        # Flange overhang reinforcement
        Asf_in = Cf_lb / fy_psi

        As_required = (Asw_in + Asf_in) * u"inch^2"
        As_design = max(As_required, As_min)

        # Recompute stress block for design As
        As_des_in = ustrip(u"inch^2", As_design)
        Cw_lb = As_des_in * fy_psi - Cf_lb
        a_in = Cw_lb / (0.85 * fc_psi * bw_in)

        β1_val = beta1(fc)
        c_in = a_in / β1_val
        εt_val = c_in > 0 ? 0.003 * (d_in - c_in) / c_in : Inf
        φ_actual = flexure_phi(εt_val)
        tc = is_tension_controlled(εt_val)

        # Bar selection in web width
        bars = select_beam_bars(As_design, bw;
            cover=cover, d_stirrup=d_stirrup, d_agg=d_agg, fy=fy)

        return (
            case = :web,
            As_required = As_required,
            As_min = As_min,
            As_design = As_design,
            a = a_in * u"inch",
            c = c_in * u"inch",
            εt = εt_val,
            φ = φ_actual,
            tension_controlled = tc,
            Cf = Cf_lb * u"lbf",
            Cw = Cw_lb * u"lbf",
            bars = bars,
        )
    end
end

# ==============================================================================
# Moment-Weighted Effective Flange Width from Tributary Polygons
# ==============================================================================
#
# For irregular cell geometries, the standard ACI "clear distance between webs"
# is ambiguous. Instead, we derive the effective overhang from the parametric
# tributary polygon (s, d) profile already computed by the straight skeleton /
# directed partitioning.
#
# The tributary polygon's d(s) gives the perpendicular distance from the beam
# to the skeleton ridge (tributary boundary) at each point along the span.
# For a regular rectangular grid, d ≈ sw/2 = constant, recovering the standard
# ACI result. For irregular cells, d(s) varies and we use a moment-weighted
# average to emphasize the high-moment (midspan) region.
# ==============================================================================

"""
    _extract_tributary_width_profile(s, d) -> (Vector{Float64}, Vector{Float64})

Extract a sorted width profile from tributary polygon boundary vertices.

The polygon boundary is defined by `(s[i], d[i])` pairs in parametric coordinates.
This function sorts by `s`, takes `|d|` as the width, and merges duplicate `s`
positions keeping the maximum width.

# Returns
- `positions`: Sorted parametric coordinates ∈ [0, 1]
- `widths`: Perpendicular widths (m) at each position
"""
function _extract_tributary_width_profile(s::AbstractVector{Float64}, 
                                          d::AbstractVector{Float64})
    isempty(s) && return (Float64[], Float64[])
    
    pairs = [(s[i], abs(d[i])) for i in eachindex(s)]
    sort!(pairs, by=first)
    
    merged = Tuple{Float64, Float64}[]
    for (si, wi) in pairs
        if isempty(merged) || abs(si - merged[end][1]) > 1e-9
            push!(merged, (si, wi))
        else
            merged[end] = (merged[end][1], max(merged[end][2], wi))
        end
    end
    
    positions = clamp.([p[1] for p in merged], 0.0, 1.0)
    widths = [p[2] for p in merged]
    
    return (positions, widths)
end

"""
    _moment_weight(s::Float64, shape::Symbol) -> Float64

Moment diagram weighting function at parametric position `s ∈ [0, 1]`.

# Shapes
- `:parabolic` — simply-supported uniform load: `4s(1−s)`, peak at midspan
- `:uniform`   — constant moment (pure bending): `1.0`
- `:triangular` — cantilever (fixed at `s = 1`): `s`
"""
function _moment_weight(s::Float64, shape::Symbol)
    if shape == :parabolic
        return 4.0 * s * (1.0 - s)
    elseif shape == :triangular
        return s
    else  # :uniform
        return 1.0
    end
end

"""
    moment_weighted_avg_depth(s, d; moment_shape=:parabolic) -> Float64

Moment-weighted average perpendicular depth from a tributary polygon profile.

Given a tributary polygon with boundary vertices `(s[i], d[i])` in parametric
coordinates (s ∈ [0,1] along beam, d = perpendicular distance in meters),
computes the effective overhang depth weighted by the moment diagram shape.

For a constant-depth profile, returns `d_max` regardless of weighting.
For irregular profiles, emphasizes the midspan region.

# Arguments
- `s`: Parametric positions of polygon vertices along beam
- `d`: Perpendicular distances (m) at each vertex
- `moment_shape`: `:parabolic`, `:uniform`, or `:triangular`

# Returns
Average depth in meters (Float64).
"""
function moment_weighted_avg_depth(s::AbstractVector{Float64}, 
                                    d::AbstractVector{Float64};
                                    moment_shape::Symbol = :parabolic)
    positions, widths = _extract_tributary_width_profile(s, d)
    length(positions) < 2 && return 0.0
    
    num = 0.0  # ∫ d(s) × w(s) ds
    den = 0.0  # ∫ w(s) ds
    
    for i in 1:(length(positions) - 1)
        s1, s2 = positions[i], positions[i+1]
        d1, d2 = widths[i], widths[i+1]
        Δs = s2 - s1
        Δs < 1e-15 && continue
        
        # Simpson's rule on each segment (exact for parabolic × linear = cubic)
        s_mid = (s1 + s2) / 2
        d_mid = (d1 + d2) / 2  # linear interpolation of tributary depth
        
        w1 = _moment_weight(s1, moment_shape)
        w2 = _moment_weight(s2, moment_shape)
        wm = _moment_weight(s_mid, moment_shape)
        
        num += Δs / 6 * (d1*w1 + 4*d_mid*wm + d2*w2)
        den += Δs / 6 * (w1 + 4*wm + w2)
    end
    
    return den > 1e-15 ? num / den : 0.0
end

# Convenience: dispatch on TributaryPolygon
function moment_weighted_avg_depth(trib::TributaryPolygon; 
                                    moment_shape::Symbol = :parabolic)
    moment_weighted_avg_depth(trib.s, trib.d; moment_shape)
end

"""
    effective_flange_width_from_tributary(;
        bw, hf, ln,
        trib_left  = nothing,
        trib_right = nothing,
        moment_shape = :parabolic,
    ) -> Length

Effective flange width from adjacent-cell tributary polygons.

Generalizes ACI 318-11 §8.12.2 to irregular cell geometries by using the
**moment-weighted average perpendicular extent** of each side's tributary
polygon as the available slab overhang, then applying ACI caps.

# Arguments
- `bw`: Web width
- `hf`: Slab thickness (for ACI 8hf / 6hf cap)
- `ln`: Clear span length (for ACI ln/8 / ln/12 cap)
- `trib_left`: `TributaryPolygon` from cell on left side (`nothing` for edge beams)
- `trib_right`: `TributaryPolygon` from cell on right side (`nothing` for edge beams)
- `moment_shape`: Weighting function — `:parabolic` (default), `:uniform`, `:triangular`

# Behavior
- **Interior beam** (both tributaries present): each overhang capped at `min(8hf, ln/8)`
- **Edge beam** (one tributary `nothing`): single overhang capped at `min(6hf, ln/12)`
- **Rectangular grids**: recovers the standard ACI result exactly

# Returns
Effective flange width `bf` (with same units as `bw`).
"""
function effective_flange_width_from_tributary(;
    bw::Length, hf::Length, ln::Length,
    trib_left::Union{TributaryPolygon, Nothing} = nothing,
    trib_right::Union{TributaryPolygon, Nothing} = nothing,
    moment_shape::Symbol = :parabolic,
)
    hf_m = ustrip(u"m", hf)
    ln_m = ustrip(u"m", ln)
    
    is_edge = isnothing(trib_left) || isnothing(trib_right)
    
    # ACI overhang caps per side
    if is_edge
        cap = min(6 * hf_m, ln_m / 12)
    else
        cap = min(8 * hf_m, ln_m / 8)
    end
    
    # Left overhang
    overhang_left = if isnothing(trib_left)
        0.0
    else
        min(moment_weighted_avg_depth(trib_left; moment_shape), cap)
    end
    
    # Right overhang
    overhang_right = if isnothing(trib_right)
        0.0
    else
        min(moment_weighted_avg_depth(trib_right; moment_shape), cap)
    end
    
    return bw + (overhang_left + overhang_right) * u"m"
end
