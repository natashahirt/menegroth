"""Print rebar schedule line for a spread footing (count × bar size each way)."""
function _print_rebar_line(r::StructuralSizer.SpreadFootingResult, du)
    println("  Rebar: $(r.rebar_count) × $(fmt(du, :rebar_dia, r.rebar_dia, digits=0)) each way")
end
"""Print rebar schedule line for a strip footing (longitudinal + transverse areas)."""
function _print_rebar_line(r::StructuralSizer.StripFootingResult, du)
    println("  Rebar: As_long=$(fmt(du, :rebar_area, r.As_long_bot)), As_trans=$(fmt(du, :rebar_area, r.As_trans))")
    if ustrip(u"m^2", r.As_tensile) > 0
        println("  As_tensile=$(fmt(du, :rebar_area, r.As_tensile)) (ACI 318-11 §15.8.1.2(b))")
    end
end
"""Print rebar schedule line for a mat footing (x- and y-direction areas)."""
function _print_rebar_line(r::StructuralSizer.MatFootingResult, du)
    println("  Rebar: As_x=$(fmt(du, :rebar_area, r.As_x_bot)), As_y=$(fmt(du, :rebar_area, r.As_y_bot))")
end
"""Fallback rebar line for unrecognised foundation result types."""
_print_rebar_line(r, du) = println("  Rebar: (see result object)")

"""
    foundation_summary(design::BuildingDesign)
    foundation_summary(struc::BuildingStructure; du=imperial)

Print a summary of all foundations in the structure.
Display units controlled by `du` (default: `imperial`).
"""
function foundation_summary(design::BuildingDesign)
    foundation_summary(design.structure; du=design.params.display_units)
end

function foundation_summary(struc::BuildingStructure; du::DisplayUnits=imperial)
    isempty(struc.foundations) && return println("No foundations designed.")
    
    println("\n=== Foundation Summary ===")
    println("─" ^ 60)
    
    total_concrete = 0.0u"m^3"
    total_steel = 0.0u"m^3"
    total_area = 0.0u"m^2"
    
    for (i, fnd) in enumerate(struc.foundations)
        r = fnd.result
        supp_str = join(fnd.support_indices, ", ")
        
        println("Foundation $i ($(fnd.foundation_type), supports: [$supp_str])")
        println("  Size: $(fmt(du, :length, r.B)) × $(fmt(du, :length, r.L_ftg)) × $(fmt(du, :length, r.D))")
        _print_rebar_line(r, du)
        println("  Concrete: $(fmt(du, :volume, r.concrete_volume, digits=3))")
        println("  Steel: $(fmt(du, :volume, r.steel_volume, digits=5))")
        println("  Utilization: $(round(r.utilization * 100, digits=1))%")
        println()
        
        total_concrete += r.concrete_volume
        total_steel += r.steel_volume
        total_area += StructuralSizer.footprint_area(r)
    end
    
    println("─" ^ 60)
    println("TOTALS:")
    println("  Foundations: $(length(struc.foundations))")
    println("  Footprint area: $(fmt(du, :area, total_area))")
    println("  Concrete volume: $(fmt(du, :volume, total_concrete))")
    println("  Steel volume: $(fmt(du, :volume, total_steel, digits=4))")
    println("  Steel weight: $(fmt(du, :mass, total_steel * 7850u"kg/m^3", digits=1))")
end

"""
    foundation_group_summary(design::BuildingDesign; demands=nothing)
    foundation_group_summary(struc::BuildingStructure; du=imperial, demands=nothing)

Print a summary organized by foundation groups.
Display units controlled by `du` (default: `imperial`).

# Arguments
- `demands`: Optional precomputed `support_demands(struc)` to avoid recomputation
"""
function foundation_group_summary(design::BuildingDesign;
                                   demands::Union{Nothing, Vector{StructuralSizer.FoundationDemand}}=nothing)
    foundation_group_summary(design.structure; du=design.params.display_units, demands=demands)
end

function foundation_group_summary(struc::BuildingStructure; 
                                   du::DisplayUnits=imperial,
                                   demands::Union{Nothing, Vector{StructuralSizer.FoundationDemand}}=nothing)
    isempty(struc.foundation_groups) && return println("No foundation groups. Call build_foundation_groups!() first.")
    
    demands = isnothing(demands) ? support_demands(struc) : demands
    
    println("\n=== Foundation Group Summary ===")
    println("─" ^ 70)
    
    total_concrete = 0.0u"m^3"
    total_steel = 0.0u"m^3"
    
    for (g_idx, (gid, fg)) in enumerate(struc.foundation_groups)
        f_indices = fg.foundation_indices
        n_ftg = length(f_indices)
        
        # Get representative foundation
        fnd = struc.foundations[f_indices[1]]
        r = fnd.result
        
        # Load range in group
        loads = Float64[]
        for f_idx in f_indices
            f = struc.foundations[f_idx]
            if length(f.support_indices) == 1
                push!(loads, ustrip(u"kN", demands[f.support_indices[1]].Pu))
            else
                push!(loads, sum(ustrip(u"kN", demands[i].Pu) for i in f.support_indices))
            end
        end
        
        load_min = minimum(loads)
        load_max = maximum(loads)
        
        println("Group $g_idx: $n_ftg foundations")
        println("  Load range: $(round(load_min, digits=1)) - $(round(load_max, digits=1)) kN")
        println("  Size: $(fmt(du, :length, r.B)) × $(fmt(du, :length, r.L_ftg)) × $(fmt(du, :length, r.D))")
        _print_rebar_line(r, du)
        println("  Concrete/footing: $(fmt(du, :volume, r.concrete_volume, digits=3))")
        println("  Group total concrete: $(fmt(du, :volume, r.concrete_volume * n_ftg))")
        println()
        
        total_concrete += r.concrete_volume * n_ftg
        total_steel += r.steel_volume * n_ftg
    end
    
    println("─" ^ 70)
    println("TOTALS:")
    println("  Groups: $(length(struc.foundation_groups))")
    println("  Foundations: $(length(struc.foundations))")
    println("  Concrete volume: $(fmt(du, :volume, total_concrete))")
    println("  Steel volume: $(fmt(du, :volume, total_steel, digits=4))")
    println("  Steel weight: $(fmt(du, :mass, total_steel * 7850u"kg/m^3", digits=1))")
end

