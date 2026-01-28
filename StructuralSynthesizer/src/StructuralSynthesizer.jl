module StructuralSynthesizer

using Logging
using StructuralBase
using StructuralSizer
using AsapToolkit

# Extend StructuralSizer's floor-result interface functions for local wrapper types
# (e.g. `Slab`). In Julia, adding methods requires `import`, not `using`.
import StructuralSizer: self_weight, total_depth, structural_effects

import GLMakie
import Meshes
import Graphs
import Asap
import LinearAlgebra: norm, normalize
using Unitful
using StructuralBase: StructuralUnits  # Shared unit definitions (already registered)
import StructuralPlots  # Colors and themes for visualization

include("types.jl")
include("./core/_core.jl")
include("./generate/_generate.jl")
include("./visualization/_visualization.jl")
include("./analyze/_analyze.jl")
include("./postprocess/_postprocess.jl")

# Geometry generation
export gen_medium_office

# Core types
export BuildingSkeleton, BuildingStructure, Story
export SiteConditions, MaterialVolumes, VolumeType
export Cell, Slab, SlabGroup, thickness
export CellGroup, TributaryPolygon, SpanInfo, vertices
export Segment, MemberGroup
# Member type hierarchy
export AbstractMember, MemberBase, Beam, Column, Strut
export all_members, segment_indices, member_length, unbraced_length
export group_id, section, volumes, set_group_id!, set_section!, set_volumes!
export Support, Foundation, FoundationGroup, FoundationDemand

# Functions
export visualize
export visualize_cell_groups, visualize_cell_tributary, visualize_cell_tributaries
export visualize_vertex_tributaries, visualize_tributaries_combined
export vis_embodied_carbon_summary
export add_vertex!, add_element!, find_faces!, rebuild_stories!, to_asap!
export initialize!

# Lookup utilities (O(1) vertex/edge/face lookups)
export SkeletonLookup, enable_lookup!, build_lookup!, disable_lookup!
export find_vertex, find_edge, find_face, validate_lookup
export initialize_cells!, initialize_slabs!
export initialize_segments!, initialize_members!, update_bracing!
export build_slab_groups!, build_cell_groups!, compute_cell_tributaries!
export update_slab_loads!, update_all_slab_loads!

# Member sizing (catalog-based)
export build_member_groups!, member_group_demands, size_members_discrete!

# Foundation sizing
export initialize_supports!, initialize_foundations!, size_foundations!
export support_demands, foundation_summary, build_foundation_groups!
# Foundation grouping (standardized sizes)
export group_foundations_by_reaction!, size_foundations_grouped!, foundation_group_summary

# Internal toolkit
export AsapToolkit

# Postprocessing (Embodied Carbon)
export element_ec, compute_building_ec, ec_summary
export ElementECResult, BuildingECResult

end # module StructuralSynthesizer
