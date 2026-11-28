# Concrete floor systems
# CIP, precast, and special concrete slabs

# ACI minimum thickness tables (deflection control, all CIP types)
include("min_thickness.jl")

# Waffle slab geometry and design (two-way joist system)
# Included before flat_plate because flat_plate/analysis/fea/ reuses
# IsoParametricPanel + bilinear mapping from waffle/geometry.jl.
include("waffle/_waffle.jl")

# Calculations and analysis (loads before sizing)
include("flat_plate/_flat_plate.jl")

# Solid-head rectangle. Included here so it can use the gross inertia and
# Eq. (13-6) already defined for the equivalent frame.
include("waffle/solid_head_section.jl")

# Frame beams sharing nodes with the story shell.
include("panel_shell_beams.jl")

# §8.3.3 coefficients or the area shell. `story_shell_bars.jl` dispatches on
# `OneWayMomentCoefficients`, so this file comes first.
include("panel_analysis.jl")

# Panel reinforcement read from a story-shell solution. Exported as
# `StoryPanelDesign`; the story shell builds one per panel.
include("story_shell_bars.jl")

# Cracked service shell: span geometry and the Ie/Ig stiffness scale.
# The re-solve that reads displacements lives in StructuralSynthesizer.
include("story_shell_service.jl")

# Slab edge outside the column centerlines. The centerline polygon stays put.
include("slab_edge.jl")

# CIP sizing for all cast-in-place types (FlatPlate, FlatSlab, TwoWay, OneWay, Waffle, PTBanded)
include("sizing.jl")

# Precast (separate sizing)
include("hollow_core.jl")