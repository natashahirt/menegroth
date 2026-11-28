# Stable status vocabulary exposed alongside backend-native MOI status.
function _normalized_moi_status(status, primal_status)
    status == JuMP.MOI.OPTIMAL && return :optimal
    status == JuMP.MOI.TIME_LIMIT &&
        primal_status == JuMP.MOI.FEASIBLE_POINT && return :feasible
    status in (JuMP.MOI.INFEASIBLE, JuMP.MOI.INFEASIBLE_OR_UNBOUNDED) &&
        return :infeasible
    return :failed
end

