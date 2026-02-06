# =============================================================================
# CIP Flat Plate Sizing Entry Point
# =============================================================================
#
# Internal span-based slab sizing helper (for initialization / quick checks).
#
# Reference: ACI 318-14/19 Chapter 8, StructurePoint Design Examples
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
- `options::FloorOptions`: Sizing options including `cip.analysis_method`
- `l2::Length`: Panel width perpendicular to span (default: same as span)
- `c1::Length`: Column dimension in span direction (default: estimated from span)
- `c2::Length`: Column dimension perpendicular to span (default: same as c1)
- `position::Symbol`: Panel position `:interior`, `:edge`, `:corner` (default: :interior)

# Analysis Methods (via `options.flat_plate.analysis_method`)
- `:mddm` - Modified Direct Design Method (simplified coefficients, fastest)
- `:ddm` - Direct Design Method (full ACI tables)
- `:efm` - Equivalent Frame Method (most accurate)

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
opts = FloorOptions(flat_plate=FlatPlateOptions(analysis_method=:efm))
result = _size_span_floor(FlatPlate(), span, sdl, live; options=opts)
```

# Reference
- ACI 318-14 Chapter 8 (Two-Way Slabs)
- ACI 318-14 Table 8.3.1.1 (Minimum Thickness)
"""
function _size_span_floor(::FlatPlate, span::L, sdl::F, live::F;
                    material::Concrete = NWC_4000,
                    options::FloorOptions = FloorOptions(),
                    l2::Union{Nothing, Length} = nothing,
                    c1::Union{Nothing, Length} = nothing,
                    c2::Union{Nothing, Length} = nothing,
                    position::Symbol = :interior) where {L<:Length, F<:Pressure}
    
    opts = options.flat_plate
    
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
    h_min = min_thickness_flat_plate(ln; discontinuous_edge=discontinuous)
    
    # Round up to nearest 0.5 inch (practical)
    h = ceil(ustrip(u"inch", h_min) * 2) / 2 * u"inch"
    
    # =========================================================================
    # Phase 2: Compute Design Moments
    # =========================================================================
    
    # Self-weight (mass density × thickness × gravity → pressure)
    sw = slab_self_weight(h, material.ρ)
    
    # Factored load
    qu = 1.2 * (sw + sdl) + 1.6 * live
    
    # Static moment M0
    M0 = total_static_moment(qu, l2_val, ln)
    
    # Distribute moments based on analysis method
    l2_l1 = l2_val / span  # dimensionless ratio
    span_type = discontinuous ? :end_span : :interior_span
    
    moments = if opts.analysis_method == :mddm
        distribute_moments_mddm(M0, span_type)
    elseif opts.analysis_method == :ddm
        distribute_moments_aci(M0, span_type, l2_l1; edge_beam=opts.has_edge_beam)
    elseif opts.analysis_method == :efm
        # For EFM, we'd need the full frame analysis
        # For now, fall back to DDM for thickness sizing
        # (EFM is used when full panel design is needed)
        distribute_moments_aci(M0, span_type, l2_l1; edge_beam=opts.has_edge_beam)
    else
        error("Unknown analysis method: $(opts.analysis_method)")
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
        if !check.passes
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
                qu = 1.2 * (sw + sdl) + 1.6 * live
                Vu = punching_demand(qu, At, c1_val, c2_val, d)
                
                check = check_punching_shear(Vu, Vc)
                check.passes && break
            end
            
            if !check.passes
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
    
    return CIPSlabResult(h_m, vol_per_area, sw_final)
end

"""
    _size_span_floor(::FlatSlab, span, sdl, live; kwargs...)

Size a cast-in-place flat slab (with drop panels) per ACI 318.

Same interface as FlatPlate, but uses flat slab thickness rules (ACI Table 8.3.1.1).
Drop panels allow for thinner slabs and better punching shear capacity.
"""
function _size_span_floor(::FlatSlab, span::L, sdl::F, live::F;
                    material::Concrete = NWC_4000,
                    options::FloorOptions = FloorOptions(),
                    l2::Union{Nothing, Length} = nothing,
                    c1::Union{Nothing, Length} = nothing,
                    c2::Union{Nothing, Length} = nothing,
                    position::Symbol = :interior) where {L<:Length, F<:Pressure}
    
    # Flat slab has slightly different thickness rules (drop panels help)
    # For now, use flat plate rules with a 10% reduction for drop panels
    fp = options.flat_plate
    opts = FloorOptions(
        flat_plate = FlatPlateOptions(
            material = fp.material,
            cover = fp.cover,
            bar_size = fp.bar_size,
            has_edge_beam = fp.has_edge_beam,
            has_drop_panels = true,
            analysis_method = fp.analysis_method,
            grouping = fp.grouping,
            deflection_limit = fp.deflection_limit
        ),
        one_way = options.one_way,
        vault = options.vault,
        composite = options.composite,
        timber = options.timber,
        tributary_axis = options.tributary_axis
    )
    
    result = _size_span_floor(FlatPlate(), span, sdl, live;
                        material=material, options=opts, l2=l2, c1=c1, c2=c2, position=position)
    
    # ACI allows 10% reduction in thickness with drop panels meeting requirements
    # ACI 8.3.1.1: For slabs with drop panels, h_min = ln/36 (interior) or ln/33 (exterior)
    # vs ln/33 and ln/30 for flat plates
    h_reduced = result.thickness * 0.9
    h = max(ceil(ustrip(u"inch", h_reduced) * 2) / 2, 5.0) * u"inch"
    
    # Recalculate self-weight
    sw = slab_self_weight(h, material.ρ)
    h_m = uconvert(u"m", h)
    vol_per_area = h_m
    
    return CIPSlabResult(h_m, vol_per_area, sw)
end

"""
    _size_span_floor(::TwoWay, span, sdl, live; kwargs...)

Size a cast-in-place two-way slab with beams per ACI 318.

Two-way slabs have beams on all sides, which provide additional support
and allow for thinner slabs than flat plates.
"""
function _size_span_floor(::TwoWay, span::L, sdl::F, live::F;
                    material::Concrete = NWC_4000,
                    options::FloorOptions = FloorOptions(),
                    l2::Union{Nothing, Length} = nothing,
                    position::Symbol = :interior) where {L<:Length, F<:Pressure}
    
    l2_val = isnothing(l2) ? span : l2
    
    # Two-way with beams: ACI Table 8.3.1.2
    # h_min depends on αfm (beam stiffness ratio)
    # For typical cases with substantial beams: h = ln/36 or greater
    
    # Simplified: use shorter span for two-way
    ln = min(span, l2_val)
    
    # ACI 8.3.1.2 for two-way slabs with beams between supports on all sides
    # When αfm ≥ 2.0: h_min = ln(0.8 + fy/200000) / 36
    fy = options.flat_plate.material.rebar.Fy
    
    # ACI formula: h = ln × (0.8 + fy/200000) / 36
    # fy / 200000psi is dimensionless
    h_min = ln * (0.8 + fy / (200000u"psi")) / 36
    h_min = max(h_min, 3.5u"inch")  # Absolute minimum for two-way with beams
    
    # Round up to nearest 0.5"
    h = ceil(ustrip(u"inch", h_min) * 2) / 2 * u"inch"
    
    # Self-weight and result
    sw = slab_self_weight(h, material.ρ)
    h_m = uconvert(u"m", h)
    vol_per_area = h_m
    
    return CIPSlabResult(h_m, vol_per_area, sw)
end

"""
    _size_span_floor(::OneWay, span, sdl, live; kwargs...)

Size a cast-in-place one-way slab per ACI 318 Table 7.3.1.1.

One-way slabs span primarily in one direction (aspect ratio > 2).
Uses `options.one_way.support` to determine thickness divisor.
"""
function _size_span_floor(::OneWay, span::L, sdl::F, live::F;
                    material::Concrete = NWC_4000,
                    options::FloorOptions = FloorOptions()) where {L<:Length, F<:Pressure}
    
    opts = options.one_way
    
    # ACI Table 7.3.1.1 - Minimum thickness for one-way slabs
    fy = opts.material.rebar.Fy
    fy_factor = 0.4 + fy / (100000u"psi")
    
    divisor = if opts.support == SIMPLE
        20
    elseif opts.support == ONE_END_CONT
        24
    elseif opts.support == BOTH_ENDS_CONT
        28
    elseif opts.support == CANTILEVER
        10
    else
        24
    end
    h_min = span * fy_factor / divisor
    h_min = max(h_min, 4.0u"inch")
    
    h_in = ceil(ustrip(u"inch", h_min) * 2) / 2
    h = h_in * u"inch"
    
    sw = slab_self_weight(h, material.ρ)
    h_m = uconvert(u"m", h)
    vol_per_area = h_m
    
    return CIPSlabResult(h_m, vol_per_area, sw)
end

"""
    _size_span_floor(::Waffle, span, sdl, live; kwargs...)

Size a cast-in-place waffle slab per ACI 318.

Waffle slabs (two-way joist system) allow for longer spans
with reduced weight compared to solid slabs.
"""
function _size_span_floor(::Waffle, span::L, sdl::F, live::F;
                    material::Concrete = NWC_4000,
                    options::FloorOptions = FloorOptions(),
                    l2::Union{Nothing, Length} = nothing,
                    position::Symbol = :interior) where {L<:Length, F<:Pressure}
    
    # Waffle slabs: ACI 9.8 (two-way joist construction)
    # Total depth typically governed by span/20 to span/24
    # Ribs are typically 6" wide at 3' or 4' on center
    
    l2_val = isnothing(l2) ? span : l2
    ln = max(span, l2_val)  # Longer span governs
    
    # Waffle depth: span/20 to span/24 (use span/22 as default)
    h_min = max(ln / 22, 8.0u"inch")  # Minimum practical waffle depth
    
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
    
    return CIPSlabResult(h_m, vol_per_area, sw)
end

"""
    _size_span_floor(::PTBanded, span, sdl, live; kwargs...)

Size a post-tensioned banded slab per ACI 318 and PTI.

PT banded slabs allow for longer spans and shallower depths
through post-tensioning.
"""
function _size_span_floor(::PTBanded, span::L, sdl::F, live::F;
                    material::Concrete = NWC_4000,
                    options::FloorOptions = FloorOptions(),
                    l2::Union{Nothing, Length} = nothing,
                    position::Symbol = :interior) where {L<:Length, F<:Pressure}
    
    # PT slabs can be thinner than RC: span/45 to span/50
    # With drop panels: even thinner
    
    l2_val = isnothing(l2) ? span : l2
    ln = max(span, l2_val)  # Longer span governs
    
    has_drops = options.flat_plate.has_drop_panels
    
    # PT thickness rules (PTI guidelines)
    divisor = has_drops ? 50.0 : 45.0
    h_min = max(ln / divisor, 5.0u"inch")  # PT minimum is typically 5"
    
    # Round up to nearest 0.5"
    h = ceil(ustrip(u"inch", h_min) * 2) / 2 * u"inch"
    
    # Self-weight
    sw = slab_self_weight(h, material.ρ)
    h_m = uconvert(u"m", h)
    vol_per_area = h_m
    
    return CIPSlabResult(h_m, vol_per_area, sw)
end

# =============================================================================
# Exports
# =============================================================================

# (internal) _size_span_floor
