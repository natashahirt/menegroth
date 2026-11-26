# =============================================================================
# Shared plan-growth engine
# =============================================================================
#
# Every shallow footing is planned the same way: seed a plan from the service
# bearing demand, then enlarge it by fixed increments — holding the plan
# centered on the gravity resultant — until every ASCE 7 combination keeps the
# contact area in compression (the resultant in the ACI 336.2R §3.2.1 kern, so
# Eq. (3-1) applies as full contact) with each service combination at or below
# the allowable pressure, or refuse after a bounded number of increments.
#
# The geometry differs by footing — a square spread grows one side, a strip or
# straight wall lengthens or widens, a mat grows its overhang, an L/T corner
# only widens — but the *control flow* is identical. `_grow_until_fit` captures
# that control flow once; each designer supplies the geometry as a `step`
# closure (which also carries its own code citations) and an `onfail` closure
# (its own non-convergence message naming the dimensions it grew).
#
# Keeping the loop in one place means the increment cap, the early-return on
# fit, and the "refuse rather than apply partial contact" policy are written —
# and can be audited — exactly once, while every clause-specific calculation
# stays verbatim in the caller next to its citation.

"""
    _grow_until_fit(plan0; step, max_iters=80, onfail)

Enlarge a footing plan until it fits, or refuse.

Starting from `plan0`, repeatedly call `step(plan)`:

- `step` returns `(true, result)` when the current plan satisfies every
  combination — `result` is returned immediately and is whatever the caller
  wants to hand back (a tuple, a plan, an options block).
- `step` returns `(false, next_plan)` otherwise — `next_plan` is the plan
  grown by one increment (in the direction the caller chose) and the loop
  continues.

After `max_iters` unsuccessful increments the plan has not reached full
contact; `onfail(plan)` is called with the last plan and must throw. The cap
exists because ACI 336.2R §3.2.1 Eq. (3-1) is applied only while the contact
area is in compression (corpus: aci-336-combined-footings-mats, page 6); a
plan that never gets there is refused rather than sized from a partial-contact
pressure.
"""
function _grow_until_fit(plan0; step, max_iters::Int = 80, onfail)
    plan = plan0
    for _ in 1:max_iters
        fitted, result = step(plan)
        fitted && return result
        plan = result
    end
    return onfail(plan)
end
