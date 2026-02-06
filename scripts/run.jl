using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))  # Activate root project
Pkg.instantiate()

# Note: Revise is loaded automatically via ~/.julia/config/startup.jl

using Unitful
using StructuralSizer     # Member-level sizing (materials) - re-exports units from Asap
using StructuralSynthesizer  # Geometry & BIM logic

# =============================================================================
# Generate building geometry
# =============================================================================
skel = gen_medium_office(125.0u"ft", 90.0u"ft", 13.0u"ft", 5, 3, 3);
struc = BuildingStructure(skel);

# =============================================================================
# Run complete design pipeline via design_building()
# =============================================================================
# This single function call handles the entire workflow:
#   1. Initialize structure with floor type
#   2. Estimate initial column sizes
#   3. Convert to Asap analysis model
#   4. Size slabs (flat plate DDM/EFM with column P-M design)
#   5. Size foundations (grouped by similar reactions)
#   6. Populate BuildingDesign with all results

design = design_building(struc, DesignParameters(
    name = "3-Story Flat Plate Office",
    
    # Floor system options
    floor_options = FloorOptions(
        flat_plate = FlatPlateOptions(
            material = RC_4000_60,      # 4000 psi concrete, Grade 60 rebar
            analysis_method = :mddm,     # Modified Direct Design Method (or :ddm, :efm)
            cover = 0.75u"inch",
            bar_size = 5,
            shear_studs=:always
        ),
        tributary_axis = nothing,       # Isotropic tributary for flat plates
    ),
    
    # Foundation options
    foundation_options = FoundationParameters(
        soil = MEDIUM_SAND,
        concrete = NWC_4000,
        rebar = Rebar_60,
        pier_width = 0.35u"m",
        min_depth = 0.4u"m",
        group_tolerance = 0.15,         # ±15% for grouping
    ),
));

# =============================================================================
# Design Summary
# =============================================================================
println("\n" * "="^60)
println("DESIGN SUMMARY: $(design.params.name)")
println("="^60)
println("Compute time: $(round(design.compute_time_s, digits=2))s")
println("All checks pass: $(all_ok(design))")
println("Critical element: $(design.summary.critical_element)")
println("Critical ratio: $(round(design.summary.critical_ratio, digits=3))")

# Slab summary
println("\n--- Slabs ($(length(design.slabs))) ---")
for (idx, slab_result) in sort(collect(design.slabs), by=first)
    h_in = round(ustrip(u"inch", slab_result.thickness), digits=1)
    println("  Slab $idx: h=$(h_in)\" | deflection_ok=$(slab_result.deflection_ok)")
end

# Column summary  
println("\n--- Columns ($(length(design.columns))) ---")
for (idx, col_result) in sort(collect(design.columns), by=first)
    println("  Column $idx: $(col_result.section_size) | ok=$(col_result.ok)")
end

# Foundation summary
println("\n--- Foundations ($(length(design.foundations))) ---")
for (idx, fdn_result) in sort(collect(design.foundations), by=first)
    L_ft = round(ustrip(u"ft", fdn_result.length), digits=1)
    B_ft = round(ustrip(u"ft", fdn_result.width), digits=1)
    println("  Foundation $idx: $(L_ft)'×$(B_ft)' (group $(fdn_result.group_id)) | ok=$(fdn_result.ok)")
end

# =============================================================================
# Detailed Reports (from struc)
# =============================================================================
slab_summary(struc)
foundation_group_summary(struc)

# =============================================================================
# Build Global Analysis Model (Frame + Shell)
# =============================================================================
# After design is complete, build a separate frame+shell model for global
# deflection analysis. This preserves the original struc.asap_model (frame-only)
# while adding shell elements for the designed slabs.
build_analysis_model!(design; load_combination=SERVICE);

# =============================================================================
# Visualizations
# =============================================================================

# 1. Structure with column tributary areas (Voronoi)
visualize(struc, color_by=:tributary_vertex)

# 2. Sized design (slabs, foundations, member utilization)
visualize(design, show_sections=:solid)

# 3. Deflected design
visualize(design, mode=:deflected)

# =============================================================================
# Embodied Carbon
# =============================================================================
ec_summary(struc)
vis_embodied_carbon_summary(struc)
