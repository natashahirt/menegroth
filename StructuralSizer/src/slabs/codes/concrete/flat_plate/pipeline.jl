# =============================================================================
# Flat Plate Design Pipeline
# =============================================================================
#
# Main orchestration for flat plate design per ACI 318-19.
# This file contains only the high-level workflow - all helper functions
# are in separate modules (helpers.jl, checks.jl, reinforcement.jl, results.jl).
#
# Workflow:
#   Phase A: Moment Analysis (method-specific: DDM or EFM)
#   Phase B: Design Loop (shared)
#     1. Column P-M design
#     2. Punching shear check
#     3. Two-way deflection check  
#     4. One-way shear check
#     5. Reinforcement design
#
# Reference: ACI 318-19 Chapters 8, 22, 24
#
# =============================================================================

using Logging

# =============================================================================
# Main Pipeline Function
# =============================================================================

"""
    size_flat_plate!(struc, slab, column_opts; method, opts, max_iterations, verbose)

Design a flat plate slab with integrated column P-M design.

# Analysis Methods
- `DDM()` - Direct Design Method (ACI 318 coefficient-based) - default
- `DDM(:simplified)` - Modified DDM with simplified coefficients
- `EFM()` - Equivalent Frame Method (ASAP stiffness analysis)

# Design Workflow
1. Identify supporting columns from Voronoi tributary areas
2. Compute column axial loads (Pu)
3. Iterate:
   a. Run moment analysis (DDM or EFM) → MomentAnalysisResult
   b. Design columns via P-M interaction → update column sizes
   c. Check punching shear → increase h or columns if needed
   d. Check two-way deflection → increase h if needed
   e. Check one-way shear → increase h if needed
4. Design strip reinforcement per ACI 8.10.5
5. Build result structures

# Arguments
- `struc::BuildingStructure`: Structure with skeleton, cells, columns
- `slab::Slab`: Slab to design (references cells via cell_indices)
- `column_opts::ConcreteColumnOptions`: Options for column P-M optimization

# Keyword Arguments
- `method::FlatPlateAnalysisMethod = DDM()`: Analysis method
- `opts::FlatPlateOptions = FlatPlateOptions()`: Design options
- `max_iterations::Int = 10`: Maximum design iterations
- `column_tol::Float64 = 0.05`: Column size change tolerance
- `h_increment::Length = 0.5u"inch"`: Thickness rounding increment
- `verbose::Bool = false`: Enable debug logging

# Returns
Named tuple `(slab_result::FlatPlatePanelResult, column_results::Dict)`

# Example
```julia
result = size_flat_plate!(struc, slab, ConcreteColumnOptions())
result = size_flat_plate!(struc, slab, col_opts; method=EFM(), verbose=true)
```
"""
function size_flat_plate!(
    struc,
    slab,
    column_opts;
    method::FlatPlateAnalysisMethod = DDM(),
    opts::FlatPlateOptions = FlatPlateOptions(),
    max_iterations::Int = 10,
    column_tol::Float64 = 0.05,
    h_increment::Length = 0.5u"inch",
    verbose::Bool = false
)
    # =========================================================================
    # PHASE 1: SETUP
    # =========================================================================
    
    # Extract material parameters
    material = opts.material
    fc = material.concrete.fc′
    fy = material.rebar.Fy
    γ_concrete = material.concrete.ρ
    cover = opts.cover
    bar_size = opts.bar_size
    φ_flexure = opts.φ_flexure
    φ_shear = opts.φ_shear
    λ = opts.λ
    Es = 29000ksi
    Ecs = Ec(fc)
    
    # Slab geometry
    slab_cell_indices = Set(slab.cell_indices)
    ln_max = max(slab.spans.primary, slab.spans.secondary)
    
    # Self-weight helper
    slab_sw(h) = slab_self_weight(h, γ_concrete)
    
    if verbose
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "FLAT PLATE DESIGN - $(method_name(method)) (ACI 318-19)"
        @debug "═══════════════════════════════════════════════════════════════════"
        @debug "Panel geometry" primary=slab.spans.primary secondary=slab.spans.secondary n_cells=length(slab.cell_indices)
        @debug "Materials" fc=fc fy=fy wc=uconvert(pcf, γ_concrete)
    end
    
    # =========================================================================
    # PHASE 2: IDENTIFY SUPPORTING COLUMNS
    # =========================================================================
    
    columns = find_supporting_columns(struc, slab_cell_indices)
    n_cols = length(columns)
    
    if n_cols == 0
        error("No supporting columns found for slab. Ensure tributary areas are computed.")
    end
    
    if verbose
        @debug "SUPPORTING COLUMNS" n_cols=n_cols
        for (i, col) in enumerate(columns)
            trib_m2 = sum(values(col.tributary_cell_areas); init=0.0)
            @debug "Column $i" vertex=col.vertex_idx position=col.position A_trib_m²=trib_m2
        end
    end
    
    # Check method applicability
    enforce_method_applicability(method, struc, slab, columns; verbose=verbose)
    
    # =========================================================================
    # PHASE 3: INITIAL ESTIMATES
    # =========================================================================
    
    has_edge = any(col.position != :interior for col in columns)
    h = min_thickness_flat_plate(ln_max; discontinuous_edge=has_edge)
    h_initial = h
    sw_estimate = slab_sw(h)
    
    bar_dia = bar_diameter(bar_size)
    c_span_min = estimate_column_size_from_span(ln_max)
    
    # Initialize column sizes
    for col in columns
        if isnothing(col.c1) || col.c1 <= 0u"inch"
            col.c1 = c_span_min
            col.c2 = c_span_min
        end
    end
    
    if verbose
        @debug "INITIAL ESTIMATES" h_min=h sw=sw_estimate c_span_min=c_span_min
    end
    
    # =========================================================================
    # PHASE 4: COMPUTE INITIAL AXIAL LOADS
    # =========================================================================
    
    Pu = compute_column_axial_loads(struc, columns, slab_cell_indices, sw_estimate)
    
    if verbose
        @debug "COLUMN AXIAL LOADS (Pu = 1.2D + 1.6L)"
        for (i, col) in enumerate(columns)
            @debug "Column $i ($(col.position))" Pu=Pu[i]*kip
        end
    end
    
    # =========================================================================
    # PHASE 5: ITERATIVE DESIGN LOOP
    # =========================================================================
    
    moment_results = nothing
    column_result = nothing
    punching_results = Dict{Int, Any}()
    final_deflection = 0.0u"inch"
    Δ_limit = 0.0u"inch"
    
    for iter in 1:max_iterations
        if verbose
            @debug "═══════════════════════════════════════════════════════════════════"
            @debug "ITERATION $iter"
            @debug "═══════════════════════════════════════════════════════════════════"
        end
        
        # ─── STEP 5a: Moment Analysis ───
        moment_results = run_moment_analysis(
            method, struc, slab, columns, h, fc, Ecs, γ_concrete;
            verbose=verbose
        )
        
        # Check pattern loading (first iteration only)
        if iter == 1
            check_pattern_loading_requirement(moment_results; verbose=verbose)
        end
        
        Mu = [ustrip(kip*u"ft", m) for m in moment_results.column_moments]
        
        # ─── STEP 5b: Column P-M Design ───
        if verbose
            @debug "COLUMN P-M DESIGN"
        end
        
        geometries = [
            ConcreteMemberGeometry(
                ustrip(u"m", col.base.L);
                Lu = ustrip(u"m", col.base.L),
                k = 1.0,
                braced = true
            )
            for col in columns
        ]
        
        column_result = size_columns(Pu, Mu, geometries, column_opts)
        
        # ─── STEP 5c: Update Column Sizes ───
        columns_changed = false
        
        for (i, col) in enumerate(columns)
            section = column_result.sections[i]
            c1_pm = section.b
            c2_pm = section.h
            c1_old = col.c1
            c2_old = col.c2
            
            # Column size = max(span_minimum, P-M_design, current_size)
            col.c1 = max(c_span_min, c1_pm, c1_old)
            col.c2 = max(c_span_min, c2_pm, c2_old)
            
            # Create section with final dimensions
            # If dimensions match P-M design, use that section directly
            # Otherwise, re-design reinforcement for the larger dimensions using P-M interaction
            if col.c1 ≈ c1_pm && col.c2 ≈ c2_pm
                col.base.section = section
            else
                # Need larger section - properly design reinforcement for new dimensions
                # Use the full ReinforcedConcreteMaterial for P-M interaction analysis
                col.base.section = resize_column_with_reinforcement(
                    section, col.c1, col.c2,
                    Pu[i], Mu[i], material
                )
            end
            
            # Check for significant change
            Δc1 = abs(ustrip(u"inch", col.c1) - ustrip(u"inch", c1_old)) / 
                  max(ustrip(u"inch", c1_old), 1.0)
            
            if Δc1 > column_tol
                columns_changed = true
            end
            
            if verbose
                status = Δc1 > column_tol ? "CHANGED" : "unchanged"
                @debug "Column $i" pm_design=c1_pm final="$(col.c1)×$(col.c2)" ρg=round(col.base.section.ρg, digits=3) status=status
            end
        end
        
        if columns_changed
            verbose && @debug "⟳ Column sizes changed, re-running analysis..."
            continue
        end
        
        # ─── STEP 5d: Punching Shear Check ───
        if verbose
            @debug "PUNCHING SHEAR CHECK (ACI 22.6)"
        end
        
        d = effective_depth(h; cover=cover, bar_diameter=bar_dia)
        
        interior_fails = Int[]
        edge_corner_fails = Int[]
        
        for (i, col) in enumerate(columns)
            Vu = moment_results.column_shears[i]
            Mub = moment_results.unbalanced_moments[i]
            
            result = check_punching_for_column(
                col, Vu, Mub, d, h, fc;
                verbose=verbose, col_idx=i, λ=λ, φ_shear=φ_shear
            )
            
            col_idx_global = findfirst(==(col), struc.columns)
            punching_results[col_idx_global] = result
            
            if !result.ok
                if col.position == :interior
                    push!(interior_fails, i)
                else
                    push!(edge_corner_fails, i)
                end
            end
        end
        
        # Handle punching failures using shear stud strategy
        # Strategies:
        #   :never = grow columns only, error if maxed
        #   :if_needed = try columns first, use studs if columns maxed
        #   :always = use studs first, grow columns if studs insufficient
        all_fails = vcat(interior_fails, edge_corner_fails)
        
        if !isempty(all_fails)
            c_max = opts.max_column_size
            c_increment = 2.0u"inch"
            stud_strategy = opts.shear_studs
            stud_mat = opts.stud_material
            stud_diam = opts.stud_diameter
            fyt = stud_mat.Fy
            
            columns_grew = false
            studs_designed = false
            
            for i in all_fails
                col = columns[i]
                col_idx_global = findfirst(==(col), struc.columns)
                ratio = punching_results[col_idx_global].ratio
                vu = punching_results[col_idx_global].vu
                
                # Get punching parameters for stud design
                c1_in = ustrip(u"inch", col.c1)
                c2_in = ustrip(u"inch", col.c2)
                β = max(c1_in, c2_in) / max(min(c1_in, c2_in), 1.0)
                αs = punching_αs(col.position)
                b0 = punching_results[col_idx_global].b0
                
                if stud_strategy == :always
                    # Design studs first
                    studs = design_shear_studs(vu, fc, β, αs, b0, d, col.position, 
                                               fyt, stud_diam; λ=λ, φ=φ_shear)
                    stud_check = check_punching_with_studs(vu, studs; φ=φ_shear)
                    
                    if stud_check.passes
                        # Studs solve it - update result
                        punching_results[col_idx_global] = (
                            ok = true,
                            ratio = stud_check.ratio,
                            vu = vu,
                            φvc = studs.vcs + studs.vs,
                            b0 = b0,
                            Jc = punching_results[col_idx_global].Jc,
                            studs = studs
                        )
                        studs_designed = true
                        if verbose
                            @info "Column $i ($(col.position)): Shear studs designed - $(studs.n_rails) rails × $(studs.n_studs_per_rail) studs"
                        end
                    else
                        # Studs insufficient - grow column as backup
                        c1_new = col.c1 + c_increment
                        if c1_new > c_max
                            # Both studs AND columns exhausted → increase h as last resort
                            h_new = round_up_thickness(h + h_increment, h_increment)
                            h = h_new
                            d = effective_depth(h; cover=cover, bar_diameter=bar_dia)
                            sw_estimate = slab_sw(h)
                            Pu = compute_column_axial_loads(struc, columns, slab_cell_indices, sw_estimate)
                            
                            @warn "Column $i: Studs and columns at max. Increasing h → $h"
                            columns_grew = true  # Triggers continue
                        else
                            col.c1 = c1_new
                            col.c2 = c1_new
                            columns_grew = true
                            if verbose
                                @warn "Column $i: Studs insufficient, growing column: $(col.c1 - c_increment) → $(c1_new)"
                            end
                        end
                    end
                    
                elseif stud_strategy == :if_needed
                    # Try growing column first
                    c1_original = col.c1
                    c1_new = col.c1 + c_increment
                    
                    if c1_new <= c_max
                        col.c1 = c1_new
                        col.c2 = c1_new
                        columns_grew = true
                        if verbose
                            @warn "Column $i punching FAILED (ratio=$(round(ratio, digits=2))). Growing: $(c1_original) → $(c1_new)"
                        end
                    else
                        # Column maxed - revert and design studs
                        col.c1 = c1_original
                        col.c2 = c1_original
                        
                        studs = design_shear_studs(vu, fc, β, αs, b0, d, col.position,
                                                   fyt, stud_diam; λ=λ, φ=φ_shear)
                        stud_check = check_punching_with_studs(vu, studs; φ=φ_shear)
                        
                        if stud_check.passes
                            punching_results[col_idx_global] = (
                                ok = true,
                                ratio = stud_check.ratio,
                                vu = vu,
                                φvc = studs.vcs + studs.vs,
                                b0 = b0,
                                Jc = punching_results[col_idx_global].Jc,
                                studs = studs
                            )
                            studs_designed = true
                            if verbose
                                @info "Column $i at max size - using shear studs: $(studs.n_rails) rails"
                            end
                        else
                            # Columns maxed AND studs insufficient → increase h as last resort
                            h_new = round_up_thickness(h + h_increment, h_increment)
                            h = h_new
                            d = effective_depth(h; cover=cover, bar_diameter=bar_dia)
                            sw_estimate = slab_sw(h)
                            Pu = compute_column_axial_loads(struc, columns, slab_cell_indices, sw_estimate)
                            
                            @warn "Column $i: Max size and studs insufficient. Increasing h → $h"
                            # Must restart iteration with new thickness
                            columns_grew = true  # Triggers continue
                        end
                    end
                    
                else  # :never (default)
                    # Only allow column growth
                    c1_new = col.c1 + c_increment
                    
                    if c1_new > c_max
                        @error "Column $i at max size ($c_max), shear_studs=:never" position=col.position ratio=ratio
                        error("Punching cannot be resolved. Set shear_studs=:if_needed to allow studs.")
                    end
                    
                    col.c1 = c1_new
                    col.c2 = c1_new
                    columns_grew = true
                    
                    if verbose
                        @warn "Column $i punching FAILED (ratio=$(round(ratio, digits=2))). Growing: $(col.c1 - c_increment) → $(c1_new)"
                    end
                end
            end
            
            if columns_grew
                # Columns changed - need to re-run analysis with new geometry
                continue
            end
            # If only studs were designed (no column changes), proceed to next checks
            # The punching_results already have the stud design stored
        end
        
        # ─── STEP 5e: Two-Way Deflection Check ───
        if verbose
            @debug "TWO-WAY DEFLECTION CHECK (ACI 24.2)"
        end
        
        deflection_result = check_two_way_deflection(
            moment_results, h, d, fc, fy, Es, Ecs, slab.spans, γ_concrete, columns;
            verbose=verbose, limit_type=opts.deflection_limit
        )
        final_deflection = deflection_result.Δ_total
        Δ_limit = deflection_result.Δ_limit
        
        if !deflection_result.ok
            h_new = round_up_thickness(h + h_increment, h_increment)
            h = h_new
            sw_estimate = slab_sw(h)
            Pu = compute_column_axial_loads(struc, columns, slab_cell_indices, sw_estimate)
            
            verbose && @warn "Deflection FAILED. Increasing h → $h"
            continue
        end
        
        # ─── STEP 5f: One-Way Shear Check ───
        if verbose
            @debug "ONE-WAY SHEAR CHECK (ACI 22.5)"
        end
        
        shear_result = check_one_way_shear(moment_results, d, fc; verbose=verbose, λ=λ, φ_shear=φ_shear)
        
        if !shear_result.ok
            h_new = round_up_thickness(h + h_increment, h_increment)
            h = h_new
            sw_estimate = slab_sw(h)
            Pu = compute_column_axial_loads(struc, columns, slab_cell_indices, sw_estimate)
            
            verbose && @warn "One-way shear FAILED. Increasing h → $h"
            continue
        end
        
        # =========================================================================
        # PHASE 6: FINAL DESIGN
        # =========================================================================
        
        # ─── Integrity Reinforcement ───
        cell = struc.cells[first(slab.cell_indices)]
        integrity = integrity_reinforcement(
            cell.area, cell.sdl + sw_estimate, cell.live_load, fy
        )
        
        if verbose
            @debug "INTEGRITY REINFORCEMENT (ACI 8.7.4.2)" As_integrity=integrity.As_integrity
        end
        
        # ─── Strip Reinforcement Design ───
        if verbose
            @debug "REINFORCEMENT DESIGN"
        end
        
        rebar_design = design_strip_reinforcement(
            moment_results, h, d, fc, fy, cover;
            verbose=verbose
        )
        
        # ─── Update Cell Self-Weights ───
        sw_final = slab_sw(h)
        for cell_idx in slab.cell_indices
            struc.cells[cell_idx].self_weight = sw_final
        end
        
        # ─── Update Asap Model ───
        update_asap_column_sections!(struc, columns, column_opts.grade)
        
        # ─── Build Results ───
        if verbose
            @debug "═══════════════════════════════════════════════════════════════════"
            @debug "DESIGN CONVERGED ✓"
            @debug "═══════════════════════════════════════════════════════════════════"
            @debug "Final slab" h=h sw=sw_final method=method_name(method)
            @debug "Final columns" sizes=["$(c.c1)×$(c.c2)" for c in columns]
            @debug "Iterations" n=iter
        end
        
        slab_result = build_slab_result(
            h, sw_final, moment_results, rebar_design,
            final_deflection, Δ_limit, punching_results
        )
        
        column_results = build_column_results(
            struc, columns, column_result,
            Pu, moment_results.column_moments, punching_results
        )
        
        return (slab_result=slab_result, column_results=column_results)
    end
    
    error("Design did not converge in $max_iterations iterations")
end

# =============================================================================
# Backward Compatibility
# =============================================================================

"""Alias for backward compatibility."""
const size_flat_plate_efm! = size_flat_plate!
