import JuMP
import HiGHS

"""Whether Gurobi.jl is available in the current environment."""
const _HAS_GUROBI = Ref(false)
try
    import Gurobi
    _HAS_GUROBI[] = true
catch
    _HAS_GUROBI[] = false
end

"""Thread-local Gurobi environment pool (one `Env` per thread)."""
const _GUROBI_ENV_POOL = Dict{Int, Any}()

"""
Identical `optimize_discrete` inputs return the stored assignment.

The key is a value token, so a catalog rebuilt with the same section
properties hits. The stored result is the same sections and indices the
solver returned. Tracing (`tc !== nothing`) skips the memo so explanations
still run. Capped so a long session does not keep every problem.
"""
const _DISCRETE_SOLVE_MEMO = Dict{Any, NamedTuple}()
const _DISCRETE_SOLVE_MEMO_LOCK = ReentrantLock()
const _DISCRETE_SOLVE_MEMO_MAX = 64
const _DISCRETE_MEMO_HITS = Ref(0)

function _memo_token(x)
    x isa Quantity && return (Float64(ustrip(x)), string(unit(x)))
    x isa Real && return Float64(x)
    x isa Symbol && return x
    x isa Bool && return x
    x isa AbstractString && return String(x)
    x isa Nothing && return nothing
    x isa AbstractSection && return _section_memo_token(x)
    x isa AbstractArray && return Tuple(_memo_token(v) for v in x)
    if isstructtype(typeof(x)) && isimmutable(x)
        nfields(x) == 0 && return typeof(x)
        return Tuple(_memo_token(getfield(x, i)) for i in 1:nfields(x))
    end
    return objectid(x)
end

function _section_memo_token(s)
    name = hasproperty(s, :name) ? getproperty(s, :name) : nothing
    nums = Float64[]
    for fld in (:A, :d, :Ix, :Iy, :b, :h, :ρg, :bf, :tw, :tf)
        hasproperty(s, fld) || continue
        v = getproperty(s, fld)
        push!(nums, v isa Quantity ? Float64(ustrip(v)) : v isa Real ? Float64(v) : 0.0)
    end
    return (name, Tuple(nums))
end

function _discrete_memo_get(key)
    lock(_DISCRETE_SOLVE_MEMO_LOCK) do
        hit = get(_DISCRETE_SOLVE_MEMO, key, nothing)
        hit === nothing || (_DISCRETE_MEMO_HITS[] += 1)
        return hit
    end
end

function _discrete_memo_put!(key, result)
    lock(_DISCRETE_SOLVE_MEMO_LOCK) do
        if length(_DISCRETE_SOLVE_MEMO) >= _DISCRETE_SOLVE_MEMO_MAX
            empty!(_DISCRETE_SOLVE_MEMO)
        end
        _DISCRETE_SOLVE_MEMO[key] = result
    end
    return result
end

