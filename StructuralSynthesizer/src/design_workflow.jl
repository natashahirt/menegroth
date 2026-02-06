# =============================================================================
# Design Workflow
# =============================================================================
#
# Functions for generating BuildingDesign from BuildingStructure.
# This is the main entry point for parametric design studies.
#
# Example:
#   skel = gen_medium_office(54u"ft", 42u"ft", 13u"ft", 3, 3, 3)
#   struc = BuildingStructure(skel)
#   
#   design1 = design_building(struc, DesignParameters(
#       name = "Option A - 4ksi concrete",
#       floor_options = FloorOptions(flat_plate=FlatPlateOptions(material=RC_4000_60)),
#       foundation_options = FoundationParameters(soil=MEDIUM_SAND),
#   ))
#   
#   design2 = design_building(struc, DesignParameters(
#       name = "Option B - 6ksi concrete",
#       floor_options = FloorOptions(flat_plate=FlatPlateOptions(material=RC_6000_60)),
#   ))
#   
#   compare_designs(design1, design2)
# =============================================================================

using Dates

"""
    design_building(struc::BuildingStructure, params::DesignParameters) -> BuildingDesign

Run the complete design pipeline and return a BuildingDesign with all results.

This is the main entry point for design. It runs the full pipeline:
1. Initialize structure with floor type and options
2. Estimate initial column sizes
3. Convert to Asap analysis model
4. Size slabs (flat plate DDM/EFM with column P-M design)
5. Size foundations (if foundation_options provided)
6. Populate BuildingDesign with all results

# Arguments
- `struc`: BuildingStructure (geometry from BuildingSkeleton)
- `params`: DesignParameters specifying materials, floor options, foundation options

# Returns
- `BuildingDesign` with complete design results

# Example
```julia
skel = gen_medium_office(54u"ft", 42u"ft", 13u"ft", 3, 3, 3)
struc = BuildingStructure(skel)

design = design_building(struc, DesignParameters(
    name = "3-Story Flat Plate",
    floor_options = FloorOptions(
        flat_plate = FlatPlateOptions(
            material = RC_4000_60,
            analysis_method = :mddm,
        )
    ),
    foundation_options = FoundationParameters(
        soil = MEDIUM_SAND,
        min_depth = 0.5u"m",
    ),
))

visualize(design, show_slabs=true, show_foundations=true)
```
"""
function design_building(struc::BuildingStructure, params::DesignParameters)
    t_start = time()
    
    # ─────────────────────────────────────────────────────────────────────────
    # STEP 1: Initialize structure with floor type
    # ─────────────────────────────────────────────────────────────────────────
    opts = something(params.floor_options, StructuralSizer.FloorOptions())
    floor_type = _infer_floor_type(opts)
    
    initialize!(struc; floor_type=floor_type, floor_kwargs=(options=opts,))
    
    # ─────────────────────────────────────────────────────────────────────────
    # STEP 2: Estimate initial column sizes
    # ─────────────────────────────────────────────────────────────────────────
    fc = _get_design_fc(params)
    estimate_column_sizes!(struc; fc=fc)
    
    # ─────────────────────────────────────────────────────────────────────────
    # STEP 3: Convert to Asap analysis model
    # ─────────────────────────────────────────────────────────────────────────
    to_asap!(struc)
    
    # ─────────────────────────────────────────────────────────────────────────
    # STEP 4: Size slabs (includes column P-M design for flat plates)
    # ─────────────────────────────────────────────────────────────────────────
    StructuralSizer.size_slabs!(struc; options=opts, verbose=false, max_iterations=20)
    
    # ─────────────────────────────────────────────────────────────────────────
    # STEP 5: Size foundations (if options provided)
    # ─────────────────────────────────────────────────────────────────────────
    if !isnothing(params.foundation_options)
        _size_foundations!(struc, params.foundation_options)
    end
    
    # ─────────────────────────────────────────────────────────────────────────
    # STEP 6: Build BuildingDesign with captured results
    # ─────────────────────────────────────────────────────────────────────────
    design = BuildingDesign(struc, params)
    _populate_slab_results!(design, struc)
    _populate_column_results!(design, struc)
    _populate_beam_results!(design, struc)
    _populate_foundation_results!(design, struc)
    _compute_design_summary!(design, struc, params)
    
    design.compute_time_s = time() - t_start
    return design
end

"""
    design_building(struc::BuildingStructure; kwargs...) -> BuildingDesign

Convenience method that creates DesignParameters from keyword arguments.

# Example
```julia
design = design_building(struc,
    name = "Default Design",
    concrete = ConcreteMaterial(fc = 4000u"psi")
)
```
"""
function design_building(struc::BuildingStructure; kwargs...)
    params = DesignParameters(; kwargs...)
    return design_building(struc, params)
end

# =============================================================================
# Internal Helper Functions
# =============================================================================

"""Infer floor type from floor options."""
function _infer_floor_type(opts::StructuralSizer.FloorOptions)
    # Check which sub-options are populated to infer floor type
    if !isnothing(opts.flat_plate)
        return :flat_plate
    elseif !isnothing(opts.vault)
        return :vault
    elseif !isnothing(opts.one_way)
        return :one_way
    else
        return :flat_plate  # Default
    end
end

"""Get concrete f'c from design parameters (for initial column estimates)."""
function _get_design_fc(params::DesignParameters)
    # Try floor options first (flat plate material)
    if !isnothing(params.floor_options) && !isnothing(params.floor_options.flat_plate)
        mat = params.floor_options.flat_plate.material
        if !isnothing(mat)
            return mat.concrete.fc′
        end
    end
    # Fall back to params.concrete
    if !isnothing(params.concrete)
        return params.concrete.fc′
    end
    # Default
    return 4000u"psi"
end

"""Size foundations using FoundationParameters."""
function _size_foundations!(struc::BuildingStructure, fp::FoundationParameters)
    initialize_supports!(struc)
    initialize_foundations!(struc)
    group_foundations_by_reaction!(struc; tolerance=fp.group_tolerance)
    size_foundations_grouped!(struc;
        soil = fp.soil,
        concrete = fp.concrete,
        rebar = fp.rebar,
        pier_width = fp.pier_width,
        min_depth = fp.min_depth,
    )
end

# =============================================================================
# Result Population Functions
# =============================================================================

"""Populate slab design results from struc.slabs."""
function _populate_slab_results!(design::BuildingDesign, struc::BuildingStructure)
    for (slab_idx, slab) in enumerate(struc.slabs)
        isnothing(slab.result) && continue
        
        result = SlabDesignResult(
            thickness = StructuralSizer.total_depth(slab.result),
            self_weight = StructuralSizer.self_weight(slab.result)
        )
        
        # Extract M0 if available (FlatPlatePanelResult has it)
        if hasproperty(slab.result, :M0)
            result.M0 = slab.result.M0
        end
        
        # Extract deflection check if available
        if hasproperty(slab.result, :deflection_check)
            dc = slab.result.deflection_check
            # Field name varies: FlatPlatePanelResult uses 'passes', VaultResult uses 'ok'
            result.deflection_ok = hasproperty(dc, :passes) ? dc.passes : dc.ok
            result.deflection_ratio = dc.ratio
        end
        
        design.slabs[slab_idx] = result
    end
end

"""Populate column design results from struc.columns."""
function _populate_column_results!(design::BuildingDesign, struc::BuildingStructure)
    for (col_idx, col) in enumerate(struc.columns)
        result = ColumnDesignResult()
        
        # Capture section size
        if !isnothing(col.c1) && !isnothing(col.c2)
            c1_in = round(Int, ustrip(u"inch", col.c1))
            c2_in = round(Int, ustrip(u"inch", col.c2))
            result.section_size = "$(c1_in)×$(c2_in)"
        end
        
        # Get tributary area from cache (if available)
        trib_area = column_tributary_area(struc, col)
        if !isnothing(trib_area)
            # Create punching result placeholder
            # (actual punching check is done during slab sizing)
            result.punching = PunchingCheckResult(
                Vu = 0.0u"kN",
                φVc = 0.0u"kN",
                ratio = 0.0,
                ok = true,
                critical_perimeter = 0.0u"mm",
                tributary_area = trib_area  # Already has m² units
            )
        end
        
        design.columns[col_idx] = result
    end
end

"""Populate beam design results from struc.beams."""
function _populate_beam_results!(design::BuildingDesign, struc::BuildingStructure)
    for (beam_idx, beam) in enumerate(struc.beams)
        result = BeamDesignResult()
        
        # Beams may have existing sections from catalog sizing
        if !isnothing(beam.base.section)
            result.section_size = string(beam.base.section)
        end
        
        design.beams[beam_idx] = result
    end
end

"""Populate foundation design results from struc.foundations."""
function _populate_foundation_results!(design::BuildingDesign, struc::BuildingStructure)
    for (fdn_idx, fdn) in enumerate(struc.foundations)
        isnothing(fdn.result) && continue
        
        # SpreadFootingResult uses L_ftg (not L) to avoid type param conflict
        fdn_length = hasproperty(fdn.result, :L_ftg) ? fdn.result.L_ftg : 
                     hasproperty(fdn.result, :L) ? fdn.result.L : fdn.result.B
        
        # Sum reactions from all supports under this foundation
        total_reaction = 0.0u"kN"
        for sup_idx in fdn.support_indices
            sup = struc.supports[sup_idx]
            # Fz is the vertical reaction (index 3)
            total_reaction += uconvert(u"kN", sup.forces[3])
        end
        
        # group_id is a UInt64 hash, convert to Int for FoundationDesignResult
        gid = isnothing(fdn.group_id) ? 0 : Int(fdn.group_id % typemax(Int))
        
        result = FoundationDesignResult(
            length = fdn_length,
            width = fdn.result.B,
            depth = fdn.result.D,
            reaction = total_reaction,
            bearing_ratio = hasproperty(fdn.result, :utilization) ? fdn.result.utilization : 0.0,
            ok = !hasproperty(fdn.result, :utilization) || fdn.result.utilization <= 1.0,
            group_id = gid,
        )
        
        design.foundations[fdn_idx] = result
    end
end

"""Compute summary metrics."""
function _compute_design_summary!(design::BuildingDesign, struc::BuildingStructure, params::DesignParameters)
    summary = design.summary
    
    # Find critical ratio across all elements
    max_ratio = 0.0
    critical_elem = ""
    all_ok = true
    
    for (idx, slab_result) in design.slabs
        if slab_result.deflection_ratio > max_ratio
            max_ratio = slab_result.deflection_ratio
            critical_elem = "Slab $idx (deflection)"
        end
        if !slab_result.deflection_ok
            all_ok = false
        end
    end
    
    for (idx, col_result) in design.columns
        if !isnothing(col_result.punching) && col_result.punching.ratio > max_ratio
            max_ratio = col_result.punching.ratio
            critical_elem = "Column $idx (punching)"
        end
        if !col_result.ok
            all_ok = false
        end
    end
    
    for (idx, fdn_result) in design.foundations
        if fdn_result.bearing_ratio > max_ratio
            max_ratio = fdn_result.bearing_ratio
            critical_elem = "Foundation $idx (bearing)"
        end
        if !fdn_result.ok
            all_ok = false
        end
    end
    
    summary.critical_ratio = max_ratio
    summary.critical_element = critical_elem
    summary.all_checks_pass = all_ok
    
    # Compute total volumes (rough estimate)
    # TODO: More accurate EC calculation using ec_summary logic
    total_conc_vol = 0.0u"m^3"
    for (_, slab_result) in design.slabs
        # Rough estimate: thickness × avg cell area
        # This is a placeholder - should use actual slab areas
    end
    summary.concrete_volume = total_conc_vol
end

# =============================================================================
# Design Comparison Utilities
# =============================================================================

"""
    compare_designs(designs::Vector{BuildingDesign})

Create a comparison table of multiple designs.

Returns a Dict with design names as keys and comparison metrics as values.
"""
function compare_designs(designs::Vector{BuildingDesign})
    results = Dict{String, Dict{Symbol, Any}}()
    
    for d in designs
        results[d.params.name] = Dict(
            :concrete_volume => d.summary.concrete_volume,
            :steel_weight => d.summary.steel_weight,
            :embodied_carbon => d.summary.embodied_carbon,
            :all_ok => d.summary.all_checks_pass,
            :critical_ratio => d.summary.critical_ratio,
            :compute_time => d.compute_time_s
        )
    end
    
    return results
end

compare_designs(d1::BuildingDesign, d2::BuildingDesign) = compare_designs([d1, d2])

# =============================================================================
# Exports
# =============================================================================

export design_building, compare_designs
