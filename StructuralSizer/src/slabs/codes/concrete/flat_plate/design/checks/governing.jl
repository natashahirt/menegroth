"""
    _governing_check_label(last_failing_check, min_h) -> String

`table_minimum` when the ACI Table 9.5(c) start thickness passed on the
first pass. `search_floor` when a caller-supplied thickness floor passed
on the first pass. Otherwise the check that last forced a thickness increase.
"""
function _governing_check_label(last_failing_check, min_h)
    !isempty(last_failing_check) && return last_failing_check
    return isnothing(min_h) ? "table_minimum" : "search_floor"
end

