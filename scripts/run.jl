using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))  # Activate root project
Pkg.instantiate()

# Note: Revise is loaded automatically via ~/.julia/config/startup.jl

using Unitful
using StructuralBase      # Shared types & constants
using StructuralBase: StructuralUnits  # Custom unit definitions (kip, ksi, psf)
using StructuralSizer     # Member-level sizing (materials)
using StructuralSynthesizer  # Geometry & BIM logic
using Asap

# =============================================================================
# Generate building geometry
# =============================================================================
skel = gen_medium_office(160.0u"ft", 120.0u"ft", 13.0u"ft", 6, 4, 4, offset=1.0u"m");
visualize(skel)

struc = BuildingStructure(skel);

# =============================================================================
# Initialize structure with floor options
# =============================================================================
opts = FloorOptions(
    cip=CIPOptions(;
        support=ONE_END_CONT,
        rebar_material=Rebar_60,
        has_edge_beam=false,
        has_drop_panels=false,
    ),
    tributary_axis=(0,1)
);

initialize!(struc; floor_type=:two_way, floor_kwargs=(options=opts,));

# =============================================================================
# Convert to Asap model with TributaryLoads
# =============================================================================
# This computes tributary polygons and creates TributaryLoad for each cell-edge
to_asap!(struc);

# =============================================================================
# Slab summary
# =============================================================================
println("\n--- Slab Summary ---")
for (i, slab) in enumerate(struc.slabs)
    t = StructuralSynthesizer.thickness(slab)
    println("Slab $i: type=$(slab.floor_type), thickness=$t")
end

# =============================================================================
# Size members with deflection limit
# =============================================================================
size_members_discrete!(struc; deflection_limit=1/360);

println("\n--- Member Groups ---")
for (gid, group) in struc.member_groups
    if !isnothing(group.section)
        println("  $(group.section.name)")
    end
end

# =============================================================================
# Size Foundations (Grouped by similar reactions)
# =============================================================================
# Initialize supports from analysis results (extracts reactions)
initialize_supports!(struc);

# Create foundations (1:1 mapping by default)
initialize_foundations!(struc);

# Group foundations with similar loads (±15% tolerance)
# This standardizes footing sizes for constructability
group_foundations_by_reaction!(struc)

# Size at group level (governing load → applies to all in group)
size_foundations_grouped!(struc;
    soil=MEDIUM_SAND,
    concrete=NWC_4000,
    rebar=Rebar_60,
    pier_width=0.35u"m",  # Column width
    min_depth=0.4u"m",    # Frost depth / minimum
);

# Print grouped summary
foundation_group_summary(struc)

# Alternative: Individual sizing (uncomment to use instead)
# size_foundations!(struc; soil=MEDIUM_SAND, concrete=NWC_4000, rebar=Rebar_60)
# foundation_summary(struc)

# =============================================================================
# Example: Update loads after changing floor conditions
# =============================================================================
# Uncomment to demonstrate load updates:
#
# # Increase live load for a specific cell (e.g., storage area)
# struc.cells[1].live_load = 100.0u"psf"
# update_slab_loads!(struc, 1)
#
# # Or update all slabs after global floor type change
# # update_all_slab_loads!(struc)

# =============================================================================
# Visualize
# =============================================================================
visualize(struc, mode=:deflected, color_by=:tributary_edge, show_original_geometry=true)
visualize(struc, mode=:deflected, color_by=:displacement_local, show_original_geometry=false, show_foundations=true)
visualize_cell_tributaries(struc)
visualize_vertex_tributaries(struc)

# =============================================================================
# Embodied Carbon Calculation
# =============================================================================
ec_summary(struc)
vis_embodied_carbon_summary(struc)
