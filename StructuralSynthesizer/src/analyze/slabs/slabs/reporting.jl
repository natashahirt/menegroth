# =============================================================================
# Type-specific Default Kwargs
# =============================================================================

"""
Build kwargs for `_size_span_floor` with type-specific defaults.
"""
function _build_floor_kwargs(ft::AbstractFloorSystem, span, user_kwargs::NamedTuple)
    defaults = _default_floor_kwargs(ft, span, user_kwargs)
    return merge(defaults, user_kwargs)
end

"""Fallback: no additional kwargs for generic floor systems."""
_default_floor_kwargs(::AbstractFloorSystem, span, user_kwargs::NamedTuple) = NamedTuple()

# Vault: default lambda = 10 (span/rise = 10) unless user provides rise or lambda
function _default_floor_kwargs(::Vault, span, user_kwargs::NamedTuple)
    # Only add lambda if user hasn't provided rise or lambda
    has_rise = haskey(user_kwargs, :rise) && !isnothing(user_kwargs.rise)
    has_lambda = haskey(user_kwargs, :lambda) && !isnothing(user_kwargs.lambda)

    # Respect vault rise/lambda from VaultOptions if passed via `options`
    has_options_lambda = false
    has_options_rise = false
    if haskey(user_kwargs, :options) && user_kwargs.options isa StructuralSizer.VaultOptions
        vopt = user_kwargs.options
        has_options_lambda = !isnothing(vopt.lambda)
        has_options_rise = vopt.rise !== nothing
    end
    
    if !has_rise && !has_lambda && !has_options_lambda && !has_options_rise
        return (lambda=10.0,)
    end
    return NamedTuple()
end

# =============================================================================
# Slab Summary Output
# =============================================================================

"""
    slab_summary(design::BuildingDesign)
    slab_summary(struc::BuildingStructure; du=imperial)

Print a formatted summary of all designed slabs.

Shows:
- Floor type and thickness
- Span dimensions
- Design check results (punching shear, deflection)
- Reinforcement summary (for flat plates)
- Concrete volume

Display units are controlled by `du` (default: `imperial`).
When called with a `BuildingDesign`, uses `design.params.display_units`.
"""
function slab_summary(design::BuildingDesign)
    slab_summary(design.structure; du=design.params.display_units)
end

function slab_summary(struc::BuildingStructure; du::DisplayUnits=imperial)
    isempty(struc.slabs) && return println("No slabs. Call initialize_slabs!() first.")
    
    println("\n=== Slab Design Summary ===")
    println("─" ^ 70)
    
    total_concrete = 0.0u"m^3"
    total_area = 0.0u"m^2"
    
    for (i, slab) in enumerate(struc.slabs)
        r = slab.result
        n_cells = length(slab.cell_indices)
        
        # Calculate slab area from cells
        slab_area = sum(struc.cells[ci].area for ci in slab.cell_indices)
        total_area += slab_area
        
        println("Slab $i: $(slab.floor_type) ($n_cells cells)")
        println("  Area: $(fmt(du, :area, slab_area))")
        
        if r isa StructuralSizer.FlatPlatePanelResult
            println("  Thickness: $(fmt(du, :thickness, r.h))")
            println("  Spans: $(fmt(du, :span, r.l1)) × $(fmt(du, :span, r.l2))")
            println("  M₀ (static moment): $(fmt(du, :moment, r.M0))")
            
            # Moment detail (column strip governing)
            if !isempty(r.column_strip_reinf)
                cs_neg = r.column_strip_reinf[end]   # int_neg (last entry)
                cs_pos = r.column_strip_reinf[2]      # pos (second entry)
                println("  Mu (col strip): −$(fmt(du, :moment, cs_neg.Mu)), +$(fmt(du, :moment, cs_pos.Mu))")
            end
            if !isempty(r.middle_strip_reinf)
                ms_pos = r.middle_strip_reinf[1]
                println("  Mu (mid strip): +$(fmt(du, :moment, ms_pos.Mu))")
            end
            
            # Punching check
            if hasproperty(r, :punching_check) && !isnothing(r.punching_check)
                pc = r.punching_check
                status = pc.ok ? "✓ OK" : "✗ FAIL"
                println("  Punching shear: $status (max ratio=$(round(pc.max_ratio, digits=2)))")
            end
            
            # Deflection check
            if hasproperty(r, :deflection_check) && !isnothing(r.deflection_check)
                dc = r.deflection_check
                status = dc.ok ? "✓ OK" : "✗ FAIL"
                println("  Deflection: $status (Δ=$(fmt(du, :deflection, dc.Δ_total, digits=1)), limit=$(fmt(du, :deflection, dc.Δ_limit, digits=1)))")
            end
            
            # Reinforcement summary
            if !isempty(r.column_strip_reinf)
                cs = r.column_strip_reinf[1]
                println("  Column strip: #$(cs.bar_size) @ $(fmt(du, :spacing, cs.spacing, digits=1))")
            end
            if !isempty(r.middle_strip_reinf)
                ms = r.middle_strip_reinf[1]
                println("  Middle strip: #$(ms.bar_size) @ $(fmt(du, :spacing, ms.spacing, digits=1))")
            end
            
            # Concrete volume
            vol = r.h * slab_area
            total_concrete += vol
            println("  Concrete volume: $(fmt(du, :volume, vol))")
            
        elseif r isa StructuralSizer.VaultResult
            # Vault details
            println("  Thickness: $(fmt(du, :thickness, r.thickness))")
            println("  Rise: $(fmt(du, :thickness, r.rise, digits=1))")
            println("  λ (rise ratio): $(round(r.lambda, digits=1))")
            println("  Thrust: $(round(u"kN/m", StructuralSizer.total_thrust(r), digits=1))")
            
            vol = r.volume_per_area * slab_area
            total_concrete += vol
            println("  Concrete volume: $(fmt(du, :volume, vol))")
            
        elseif r isa StructuralSizer.CIPSlabResult
            # Standard one-way/two-way slab
            println("  Thickness: $(fmt(du, :thickness, r.thickness))")
            println("  Self-weight: $(fmt(du, :pressure, r.self_weight, digits=1))")
            
            vol = r.volume_per_area * slab_area
            total_concrete += vol
            println("  Concrete volume: $(fmt(du, :volume, vol))")
            
        elseif !isnothing(r)
            # Generic result with total_depth accessor
            h = StructuralSizer.total_depth(r)
            println("  Thickness: $(fmt(du, :thickness, h))")
            
            if hasproperty(r, :volume_per_area)
                vol = r.volume_per_area * slab_area
                total_concrete += vol
                println("  Concrete volume: $(fmt(du, :volume, vol))")
            end
        else
            println("  (not sized)")
        end
        
        println()
    end
    
    println("─" ^ 70)
    println("TOTALS:")
    println("  Slabs: $(length(struc.slabs))")
    println("  Total area: $(fmt(du, :area, total_area))")
    println("  Concrete volume: $(fmt(du, :volume, total_concrete))")
    println("  Concrete weight: $(fmt(du, :mass, total_concrete * 2400u"kg/m^3", digits=0))")
end

# =============================================================================
# Flat Plate Moment Comparison (DDM / EFM / FEA)
# =============================================================================

"""
    flat_plate_moment_comparison(struc, slab_idx; opts, column_opts, verbose)

Run DDM, EFM, and FEA moment analyses on a single slab and print a comparison table.

Useful for validating that FEA moments are consistent with analytical methods
on regular geometries, and for seeing where they diverge on irregular ones.

# Example
```julia
flat_plate_moment_comparison(struc, 1; verbose=false)
```
"""
function flat_plate_moment_comparison(
    struc::BuildingStructure,
    slab_idx::Int;
    opts::StructuralSizer.FlatPlateOptions = StructuralSizer.FlatPlateOptions(),
    column_opts = StructuralSizer.ConcreteColumnOptions(),
    verbose::Bool = false
)
    slab = struc.slabs[slab_idx]
    material = opts.material
    fc = material.concrete.fc′
    γ_concrete = material.concrete.ρ
    ν_concrete = material.concrete.ν
    wc_pcf = ustrip(StructuralSizer.pcf, γ_concrete)
    Ecs = StructuralSizer.Ec(fc, wc_pcf)

    slab_cell_indices = Set(slab.cell_indices)
    columns = StructuralSizer.find_supporting_columns(struc, slab_cell_indices)
    isempty(columns) && return println("No supporting columns found for slab $slab_idx")

    # Initialize column sizes if needed
    ln_max = max(slab.spans.primary, slab.spans.secondary)
    c_min = StructuralSizer.estimate_column_size_from_span(ln_max)
    for col in columns
        if isnothing(col.c1) || col.c1 <= 0u"inch"
            col.c1 = c_min
            col.c2 = c_min
        end
    end

    has_edge = any(col.position != :interior for col in columns)
    h = StructuralSizer.min_thickness(StructuralSizer.FlatPlate(), ln_max; discontinuous_edge=has_edge)

    # Run each method (catch failures for inapplicable methods)
    methods = [
        ("DDM",  StructuralSizer.DDM()),
        ("EFM",  StructuralSizer.EFM()),
        ("FEA",  StructuralSizer.FEA()),
    ]

    results = Dict{String, Any}()
    for (name, method) in methods
        try
            r = StructuralSizer.run_moment_analysis(
                method, struc, slab, columns, h, fc, Ecs, γ_concrete;
                ν_concrete=ν_concrete, verbose=verbose,
                # ACI 318-11 §10.10.4.1 — cracked column-stub stiffness from caller (default 0.70)
                col_I_factor = opts.col_I_factor
            )
            results[name] = r
        catch e
            results[name] = e
        end
    end

    # Print comparison table
    println("\n=== Flat Plate Moment Comparison — Slab $slab_idx ===")
    println("─" ^ 74)
    println("  Spans: $(round(u"ft", slab.spans.primary, digits=1)) × $(round(u"ft", slab.spans.secondary, digits=1))")
    println("  h = $(round(u"inch", h, digits=1)),  $(length(columns)) columns")
    println("─" ^ 74)
    @printf("  %-8s  %10s  %10s  %10s  %10s  %8s\n",
            "Method", "M₀", "M⁻_ext", "M⁻_int", "M⁺", "∑/M₀")
    println("  " * "─" ^ 64)

    for (name, _) in methods
        r = results[name]
        if r isa Exception
            @printf("  %-8s  %s\n", name, "N/A ($(typeof(r).name.name))")
        else
            M0  = ustrip(StructuralSizer.kip * u"ft", r.M0)
            Mne = ustrip(StructuralSizer.kip * u"ft", r.M_neg_ext)
            Mni = ustrip(StructuralSizer.kip * u"ft", r.M_neg_int)
            Mp  = ustrip(StructuralSizer.kip * u"ft", r.M_pos)
            check = (Mne + Mni) / 2 + Mp
            ratio = M0 > 0 ? check / M0 : 0.0
            @printf("  %-8s  %10.1f  %10.1f  %10.1f  %10.1f  %7.1f%%\n",
                    name, M0, Mne, Mni, Mp, ratio * 100)
        end
    end
    println("─" ^ 74)
    println("  Units: kip·ft.  ∑/M₀ = (M⁻_ext/2 + M⁻_int/2 + M⁺) / M₀")

    return results
end

