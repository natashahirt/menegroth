# =============================================================================
# CIP Flat Plate Sizing Entry Point
# =============================================================================
#
# Internal span-based slab sizing helper (for initialization / quick checks).
#
# Reference: ACI 318-11 Chapter 13, StructurePoint Design Examples
#
# =============================================================================

# Use shared self-weight helper from flat_plate/calculations.jl
# slab_self_weight(h, ρ) handles mass density → weight conversion via gravity

"""
    _size_span_floor(::FlatPlate, span, sdl, live; kwargs...)

Size a cast-in-place flat plate slab per ACI 318.

# Arguments
- `span`: Governing span length (typically longer clear span)
- `sdl`: Superimposed dead load (pressure)
- `live`: Live load (pressure)

# Keyword Arguments
- `material::Concrete`: Concrete material (default: NWC_4000)
- `options::AbstractFloorOptions`: Sizing options (e.g., `FlatPlateOptions(method=EFM())`)
- `l2::Length`: Panel width perpendicular to span (default: same as span)
- `c1::Length`: Column dimension in span direction (default: estimated from span)
- `c2::Length`: Column dimension perpendicular to span (default: same as c1)
- `position::Symbol`: Panel position `:interior`, `:edge`, `:corner` (default: :interior)

# Analysis Methods (via `options.method` on `FlatPlateOptions`)
- `DDM(:simplified)` - Modified Direct Design Method (simplified coefficients, fastest)
- `DDM()` - Direct Design Method (full ACI tables)
- `EFM()` - Equivalent Frame Method (most accurate)

# Returns
- `CIPSlabResult` with thickness, volume, and self-weight

# Example
```julia
using StructuralSizer, Unitful

span = 18u"ft"
sdl = 20psf
live = 40psf

result = _size_span_floor(FlatPlate(), span, sdl, live)
# → CIPSlabResult(7 inches, ...)

# With options
opts = FlatPlateOptions(method=EFM())
result = _size_span_floor(FlatPlate(), span, sdl, live; options=opts)
```

# Reference
- ACI 318-11 Chapter 13 (Two-Way Slabs)
- ACI 318-11 Table 9.5(c) (Minimum Thickness)
"""
function _size_span_floor(::FlatPlate, span::L, sdl::F, live::F;
                    material::Concrete = NWC_4000,
                    options::AbstractFloorOptions = FlatPlateOptions(),
                    l2::Union{Nothing, Length} = nothing,
                    c1::Union{Nothing, Length} = nothing,
                    c2::Union{Nothing, Length} = nothing,
                    position::Symbol = :interior) where {L<:Length, F<:Pressure}
    
    opts = options isa FlatSlabOptions ? options.base : options
    
    # Default panel width to span (square panel)
    l2_val = isnothing(l2) ? span : l2
    
    # Estimate column size if not provided
    c1_val = isnothing(c1) ? estimate_column_size_from_span(span; ratio=15.0) : c1
    c2_val = isnothing(c2) ? c1_val : c2
    
    # Clear span
    ln = clear_span(span, c1_val)
    
    # Determine if discontinuous edge
    discontinuous = position in (:edge, :corner)
    
    # =========================================================================
    # Phase 1: Minimum Thickness (ACI 8.3.1.1)
    # =========================================================================
    h_min = min_thickness(FlatPlate(), ln; discontinuous_edge=discontinuous)
    
    # Round up to nearest 0.5 inch (practical)
    h = ceil(ustrip(u"inch", h_min) * 2) / 2 * u"inch"
    
    # =========================================================================
    # Phase 2: Compute Design Moments
    # =========================================================================
    
    # Self-weight (mass density × thickness × gravity → pressure)
    sw = slab_self_weight(h, material.ρ)
    
    # Governing factored load (ASCE 7 §2.3.1: max of 1.2D+1.6L, 1.4D)
    qu = max(factored_pressure(default_combo, sw + sdl, live),
             factored_pressure(strength_1_4D, sw + sdl, live))
    
    # Static moment M0
    M0 = total_static_moment(qu, l2_val, ln)
    
    # Distribute moments based on analysis method
    l2_l1 = l2_val / span  # dimensionless ratio
    span_type = discontinuous ? :end_span : :interior_span
    
    # Compute edge beam βt if applicable
    _βt = 0.0
    if !isnothing(opts.edge_beam_βt)
        _βt = opts.edge_beam_βt
    elseif opts.has_edge_beam
        _βt = edge_beam_βt(h, c1_val, c2_val, l2_val)
    end
    
    # Dispatch on typed method: MDDM uses simplified coefficients,
    # everything else uses full ACI DDM coefficients for initial thickness sizing.
    # (EFM/FEA refine moments later in the full pipeline.)
    moments = if opts.method isa DDM && opts.method.variant == :simplified
        distribute_moments_mddm(M0, span_type)
    else
        distribute_moments_aci(M0, span_type, l2_l1; edge_beam=opts.has_edge_beam, βt=_βt)
    end
    
    # =========================================================================
    # Phase 3: Verify Thickness via Punching Shear
    # =========================================================================
    
    # Effective depth
    d = effective_depth(h)
    
    # Punching check at interior columns
    # (This is a simplified check - full design would check all columns)
    if position == :interior
        b0 = punching_perimeter(c1_val, c2_val, d)
        fc = material.fc′
        Vc = punching_capacity_interior(b0, d, fc; c1=c1_val, c2=c2_val)
        
        # Tributary area for interior column (simplified as l1 × l2)
        At = span * l2_val
        Vu = punching_demand(qu, At, c1_val, c2_val, d)
        
        check = check_punching_shear(Vu, Vc)
        
        # If punching fails, increase thickness
        if !check.ok
            # Iterate thickness until punching passes
            h_in = ustrip(u"inch", h)
            for _ in 1:5
                h_in += 0.5
                h = h_in * u"inch"
                d = effective_depth(h)
                b0 = punching_perimeter(c1_val, c2_val, d)
                Vc = punching_capacity_interior(b0, d, fc; c1=c1_val, c2=c2_val)
                
                # Recalculate load with new self-weight
                sw = slab_self_weight(h, material.ρ)
                qu = max(factored_pressure(default_combo, sw + sdl, live),
                         factored_pressure(strength_1_4D, sw + sdl, live))
                Vu = punching_demand(qu, At, c1_val, c2_val, d)
                
                check = check_punching_shear(Vu, Vc)
                check.ok && break
            end
            
            if !check.ok
                @warn "Punching shear check fails at h=$(h). Consider drop panels or shear reinforcement."
            end
        end
    end
    
    # =========================================================================
    # Phase 4: Build Result
    # =========================================================================
    
    # Final self-weight
    sw_final = slab_self_weight(h, material.ρ)
    
    # Convert to consistent units for result struct
    h_m = uconvert(u"m", h)
    vol_per_area = h_m  # m³/m² = m
    
    return CIPSlabResult(h_m, vol_per_area, uconvert(u"kPa", sw_final))
end

"""
    _size_span_floor(::FlatSlab, span, sdl, live; kwargs...)

Size a cast-in-place flat slab (with drop panels) per ACI 318.

Same interface as FlatPlate, but uses flat slab thickness rules (ACI Table 8.3.1.1).
Drop panels allow for thinner slabs and better punching shear capacity.
"""
function _size_span_floor(::FlatSlab, span::L, sdl::F, live::F;
                    material::Concrete = NWC_4000,
                    options::AbstractFloorOptions = FlatSlabOptions(),
                    l2::Union{Nothing, Length} = nothing,
                    c1::Union{Nothing, Length} = nothing,
                    c2::Union{Nothing, Length} = nothing,
                    position::Symbol = :interior) where {L<:Length, F<:Pressure}
    
    # Flat slab minimum thickness per ACI 318-11 Table 9.5(c) (with drop panels)
    # h_min = ln/33 (exterior) or ln/36 (interior)
    fp = options isa FlatSlabOptions ? options : FlatSlabOptions()
    
    # Estimate clear span from center-to-center span
    c = isnothing(c1) ? estimate_column_size_from_span(span; ratio=15.0) : c1
    ln = span - c
    
    discontinuous = (position in (:exterior, :edge, :corner))
    h_min = min_thickness(FlatSlab(), ln; discontinuous_edge=discontinuous)
    
    # Round up to nearest 0.5 inch
    h = max(ceil(ustrip(u"inch", h_min) * 2) / 2, 4.0) * u"inch"
    
    # Self-weight (slab only — drop panel weight is localized)
    sw = slab_self_weight(h, material.ρ)
    h_m = uconvert(u"m", h)
    vol_per_area = h_m
    
    return CIPSlabResult(h_m, vol_per_area, uconvert(u"kPa", sw))
end

"""
    _size_span_floor(::TwoWay, span, sdl, live; kwargs...)

Size a cast-in-place two-way slab with beams per ACI 318.

Two-way slabs have beams on all sides, which provide additional support
and allow for thinner slabs than flat plates.
"""
function _size_span_floor(::TwoWay, span::L, sdl::F, live::F;
                    material::Concrete = NWC_4000,
                    options::AbstractFloorOptions = FlatPlateOptions(),
                    l2::Union{Nothing, Length} = nothing,
                    position::Symbol = :interior) where {L<:Length, F<:Pressure}
    
    l2_val = isnothing(l2) ? span : l2
    
    # Two-way with beams: ACI Table 8.3.1.2
    ln = min(span, l2_val)
    fp = options isa FlatSlabOptions ? options.base : options
    fy = fp.material.rebar.Fy
    h_min = min_thickness(TwoWay(), ln; fy)
    
    # Round up to nearest 0.5"
    h = ceil(ustrip(u"inch", h_min) * 2) / 2 * u"inch"
    
    # Self-weight and result
    sw = slab_self_weight(h, material.ρ)
    h_m = uconvert(u"m", h)
    vol_per_area = h_m
    
    return CIPSlabResult(h_m, vol_per_area, uconvert(u"kPa", sw))
end

"""
    _size_span_floor(::OneWay, span, sdl, live; kwargs...)

Size a cast-in-place one-way slab per ACI 318 Table 7.3.1.1.

One-way slabs span primarily in one direction (aspect ratio > 2).
Uses `options.one_way.support` to determine thickness divisor.
"""
function _size_span_floor(::OneWay, span::L, sdl::F, live::F;
                    material::Concrete = NWC_4000,
                    options::AbstractFloorOptions = OneWayOptions()) where {L<:Length, F<:Pressure}
    
    opts = options isa OneWayOptions ? options : OneWayOptions()
    h_min = min_thickness(OneWay(), span; fy=opts.material.rebar.Fy, support=opts.support)
    
    h_in = ceil(ustrip(u"inch", h_min) * 2) / 2
    h = h_in * u"inch"
    
    sw = slab_self_weight(h, material.ρ)
    h_m = uconvert(u"m", h)
    vol_per_area = h_m
    
    return CIPSlabResult(h_m, vol_per_area, uconvert(u"kPa", sw))
end

"""
    _size_span_floor(::Waffle, span, sdl, live; kwargs...)

Size a cast-in-place waffle slab per ACI 318.

Waffle slabs (two-way joist system) allow for longer spans
with reduced weight compared to solid slabs.
"""
function _size_span_floor(::Waffle, span::L, sdl::F, live::F;
                    material::Concrete = NWC_4000,
                    options::AbstractFloorOptions = FlatPlateOptions(),
                    l2::Union{Nothing, Length} = nothing,
                    position::Symbol = :interior) where {L<:Length, F<:Pressure}
    
    # Waffle slabs: ACI 9.8 (two-way joist construction)
    # Total depth typically governed by span/20 to span/24
    # Ribs are typically 6" wide at 3' or 4' on center
    
    l2_val = isnothing(l2) ? span : l2
    ln = max(span, l2_val)  # Longer span governs
    h_min = min_thickness(Waffle(), ln)
    
    # Round up to practical waffle form depths (8", 10", 12", 14", 16", 20")
    standard_depths = [8.0, 10.0, 12.0, 14.0, 16.0, 20.0, 24.0]  # inches
    h_min_in = ustrip(u"inch", h_min)
    h = first(d for d in standard_depths if d >= h_min_in) * u"inch"
    
    # Self-weight for waffle (approximately 60% of solid slab)
    # Typical void ratio is ~40%
    void_ratio = 0.40
    sw_solid = slab_self_weight(h, material.ρ)
    sw = sw_solid * (1 - void_ratio)
    
    # Volume per area accounts for voids
    h_m = uconvert(u"m", h)
    vol_per_area = h_m * (1 - void_ratio)
    
    return CIPSlabResult(h_m, vol_per_area, uconvert(u"kPa", sw))
end

"""
    _size_span_floor(::PTBanded, span, sdl, live; kwargs...)

Size a post-tensioned banded slab per ACI 318 and PTI.

PT banded slabs allow for longer spans and shallower depths
through post-tensioning.
"""
function _size_span_floor(::PTBanded, span::L, sdl::F, live::F;
                    material::Concrete = NWC_4000,
                    options::AbstractFloorOptions = FlatSlabOptions(),
                    l2::Union{Nothing, Length} = nothing,
                    position::Symbol = :interior) where {L<:Length, F<:Pressure}
    
    # PT slabs can be thinner than RC: span/45 to span/50
    l2_val = isnothing(l2) ? span : l2
    ln = max(span, l2_val)
    
    # PT thickness rules (PTI guidelines)
    fs = options isa FlatSlabOptions ? options : FlatSlabOptions()
    has_drops = !isnothing(fs.h_drop) || !isnothing(fs.a_drop_ratio)
    h_min = min_thickness(PTBanded(), ln; has_drops)
    
    # Round up to nearest 0.5"
    h = ceil(ustrip(u"inch", h_min) * 2) / 2 * u"inch"
    
    # Self-weight
    sw = slab_self_weight(h, material.ρ)
    h_m = uconvert(u"m", h)
    vol_per_area = h_m
    
    return CIPSlabResult(h_m, vol_per_area, uconvert(u"kPa", sw))
end

# =============================================================================
# Exports
# =============================================================================

# (internal) _size_span_floor
