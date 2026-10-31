# Whole building as one model. Each pier gets the action its stiffness
# attracts in the unified frame-shell solve.

"""
    assign_lateral_demands(::BuildingUnit, wall, pier, u) -> WallAction

The pier's cut action from the full displacement `u` of one lateral case.
"""
assign_lateral_demands(::BuildingUnit, wall, pier, u) = pier_wall_action(wall, pier, u)
