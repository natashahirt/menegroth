# =============================================================================
# Monotone sizing budgets
# =============================================================================
#
# A sizing loop that only grows, on a fixed increment, up to a limit, ends
# when nothing grew. `max_iterations` stays as a caller's minimum effort and
# as a backstop, not as the only way to stop. The number of increments that
# still fit is the effort a still-growing design is allowed.

"""
    growth_steps(start, limit, increment) -> Int

How many increments fit strictly between `start` and `limit`.

Zero when `start` is already at the limit. An exact multiple counts that
multiple and not one more.
"""
function growth_steps(start::Real, limit::Real, increment::Real)
    increment > 0 || throw(ArgumentError(
        "growth increment must be positive (got $increment)"))
    start >= limit && return 0
    return ceil(Int, (limit - start) / increment - 1e-9)
end

"""
    monotone_budget(requested, span; ceiling=48) -> Int

Iterations allowed for a loop that grows for at most `span` steps.

The result is at least `requested`, so a caller that asks for more effort
gets it. It is also at least `span`, capped by `ceiling`, so a design that
is still moving is not stopped at a small `requested` while room remains.
`ceiling` bounds a runaway span; it does not reduce `requested`.
"""
function monotone_budget(requested::Integer, span::Integer; ceiling::Integer = 48)
    requested >= 1 || throw(ArgumentError(
        "iteration budget must be at least 1 (got $requested)"))
    span >= 0 || throw(ArgumentError(
        "growth span must be non-negative (got $span)"))
    ceiling >= 1 || throw(ArgumentError(
        "iteration ceiling must be at least 1 (got $ceiling)"))
    return max(Int(requested), min(Int(span), Int(ceiling)))
end

"""
    settle!(step!; budget) -> (; converged, steps, stop)

Run `step!(k)` for `k = 1, 2, …` until it returns `false`, meaning that pass
changed nothing, or until `budget` passes have run.

`step!` returns `true` when it changed state that a later pass must see. A
pass that changes nothing ends the loop with `stop = :settled`. Running out of
passes while the last one still changed state returns `converged = false` and
`stop = :budget`; the caller decides whether that is a failure.
"""
function settle!(step!; budget::Integer)
    budget >= 1 || throw(ArgumentError(
        "settle! budget must be at least 1 (got $budget)"))
    for k in 1:budget
        step!(k)::Bool || return (converged = true, steps = k, stop = :settled)
    end
    return (converged = false, steps = Int(budget), stop = :budget)
end

"""Meters as a plain number, for a length that may already be a number."""
_growth_meters(x::Real) = Float64(x)
_growth_meters(x::Unitful.Quantity) = ustrip(u"m", uconvert(u"m", x))
