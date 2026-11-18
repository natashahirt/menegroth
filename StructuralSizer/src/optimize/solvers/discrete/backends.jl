"""Lock guarding `_GUROBI_ENV_POOL` access."""
const _GUROBI_ENV_LOCK = ReentrantLock()

"""
    _reset_gurobi_env!()

Reset all cached Gurobi environments. Called from `__init__` to clear stale
pointers that survive precompilation (C pointers are invalid after deserialisation).
"""
function _reset_gurobi_env!()
    lock(_GUROBI_ENV_LOCK) do
        empty!(_GUROBI_ENV_POOL)
    end
end

"""
    _get_gurobi_env()

Get or create a thread-local cached Gurobi environment.  Each thread keeps
its own `Gurobi.Env` so that parallel `@threads` solves are safe.
"""
function _get_gurobi_env()
    tid = Threads.threadid()
    env = lock(_GUROBI_ENV_LOCK) do
        get(_GUROBI_ENV_POOL, tid, nothing)
    end
    if env === nothing || env.ptr_env == C_NULL
        new_env = Gurobi.Env()
        lock(_GUROBI_ENV_LOCK) do
            _GUROBI_ENV_POOL[tid] = new_env
        end
        return new_env
    end
    return env
end

# =============================================================================
# JuMP / Solver Warm-up
# =============================================================================

"""
    _warmup_jump_solvers()

Solve a trivial one-variable MIP through each available backend so that
JuMP's bridge / MOI layers are JIT-compiled once during package loading.
Called from `__init__`.
"""
function _warmup_jump_solvers()
    # ── HiGHS ──
    try
        m = JuMP.Model(HiGHS.Optimizer)
        JuMP.set_optimizer_attribute(m, "output_flag", false)
        JuMP.@variable(m, x >= 0, Int)
        JuMP.@objective(m, Min, x)
        JuMP.optimize!(m)
    catch e
        @debug "JuMP/HiGHS warmup skipped" exception = e
    end

    # ── Gurobi ──
    if _HAS_GUROBI[]
        try
            env = _get_gurobi_env()
            m = JuMP.Model(() -> Gurobi.Optimizer(env))
            JuMP.set_silent(m)
            JuMP.@variable(m, x >= 0, Int)
            JuMP.@objective(m, Min, x)
            JuMP.optimize!(m)
        catch e
            # No license or other Gurobi failure — use HiGHS for :auto from now on
            @info "Gurobi unavailable (e.g. no license); :auto will use HiGHS" exception = e
            _HAS_GUROBI[] = false
        end
    end
    nothing
end

# =============================================================================
# MIP Optimizer Selection
# =============================================================================

"""
    _choose_mip_optimizer(optimizer::Symbol)

Select a JuMP optimizer constructor.

- `:auto`: prefer Gurobi if available, else HiGHS
- `:gurobi`: require Gurobi
- `:highs`: use HiGHS
"""
function _choose_mip_optimizer(optimizer::Symbol)
    if optimizer === :highs
        return (() -> HiGHS.Optimizer()), :highs
    elseif optimizer === :gurobi
        _HAS_GUROBI[] || throw(ArgumentError("solver=:gurobi requested, but Gurobi.jl is not available in this environment."))
        return (() -> Gurobi.Optimizer(_get_gurobi_env())), :gurobi
    elseif optimizer === :auto
        if _HAS_GUROBI[]
            try
                _get_gurobi_env()
                return (() -> Gurobi.Optimizer(_get_gurobi_env())), :gurobi
            catch e
                @info "Gurobi not usable (e.g. no license); falling back to HiGHS" exception = e
                _HAS_GUROBI[] = false
            end
        end
        return (() -> HiGHS.Optimizer()), :highs
    else
        throw(ArgumentError("Unknown optimizer=$optimizer. Use :auto, :gurobi, or :highs."))
    end
end

# =============================================================================
# MIP Warm Start
# =============================================================================

"""
    _apply_mip_start!(x, feasible, mip_start)

Seed the branch-and-bound incumbent for the per-group assignment binaries `x`
from a prior per-group choice `mip_start` (one catalog/expanded index per group).
For each group `i`, sets `x[i,j]` start values to `1.0` on `j == mip_start[i]` and
`0.0` on the other feasible candidates, but ONLY when the prior index is still in
`feasible[i]` — a stale (now-infeasible) prior choice is skipped, leaving that
group without a start (a partial warm start is valid). This is a solver hint only;
it never adds a constraint and cannot change the optimum. Assumes `n_max_sections
== 0` (no coupling `z` variables to seed).
"""
function _apply_mip_start!(x, feasible::Vector{Vector{Int}}, mip_start::Vector{Int})
    for i in eachindex(feasible)
        prior = mip_start[i]
        prior in feasible[i] || continue
        for j in feasible[i]
            JuMP.set_start_value(x[i, j], j == prior ? 1.0 : 0.0)
        end
    end
    return nothing
end

