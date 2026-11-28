# Three designs of one plan: a loose waffle, a 30 in waffle, and the loose
# module as steel beams on steel deck.
#
# Visualization is on: each finished design copies its scene model and
# appends a variant. GLMakie is not required for the scene file.
#
#     SS_SKIP_SOLVER_WARMUP=true \
#         julia --project=StructuralStudies scripts/runners/sdf_grid_qualification.jl
#
# A second argument is one tag or a comma-separated list (loose_waffle,
# dense_waffle, steel_joists). A third argument is the scene file name under
# viewer/public. Without it, the run replaces the qualification scene.

include(joinpath(@__DIR__, "sdf_rib_design.jl"))

scene_file = length(ARGS) >= 3 ? joinpath(SCENE_DIR, ARGS[3]) : nothing
design_grid_qualification(isempty(ARGS) ? "grid/x1y1" : ARGS[1];
                          only = length(ARGS) >= 2 ? ARGS[2] : nothing,
                          scene_file = scene_file)
