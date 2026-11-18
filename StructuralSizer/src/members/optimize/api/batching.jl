# ==============================================================================
# Unified Entry Point: size_members
# ==============================================================================

"""
    size_members(arg1, arg2, geometries, opts; ...)

Unified member sizing dispatcher. Routes to `size_columns` or `size_beams`
based on the options type:

| Options type               | Interpretation       | Delegates to     |
|:-------------------------- |:-------------------- |:---------------- |
| `ConcreteColumnOptions`    | arg1=Pu, arg2=Mux    | `size_columns`   |
| `ConcreteBeamOptions`      | arg1=Mu, arg2=Vu     | `size_beams`     |
| `PixelFrameColumnOptions`  | arg1=Pu, arg2=Mux    | `size_columns`   |
| `PixelFrameBeamOptions`    | arg1=Mu, arg2=Vu     | `size_beams`     |

For steel options (`SteelColumnOptions` / `SteelBeamOptions`),
call `size_columns` or `size_beams` directly since the type system cannot
distinguish the two cases.

# Example
```julia
# Concrete columns
result = size_members(Pu, Mux, geoms, ConcreteColumnOptions())

# Concrete beams
result = size_members(Mu, Vu, geoms, ConcreteBeamOptions())

# PixelFrame beams
result = size_members(Mu, Vu, geoms, PixelFrameBeamOptions())

# PixelFrame columns
result = size_members(Pu, Mux, geoms, PixelFrameColumnOptions())

# Steel — use size_beams / size_columns directly
result = size_beams(Mu, Vu, geoms, SteelBeamOptions())
result = size_columns(Pu, Mux, geoms, SteelColumnOptions())
```
"""
function size_members end

function size_members(
    Pu::Vector, Mux::Vector, geometries::Vector,
    opts::ConcreteColumnOptions; kwargs...
)
    tc = get(kwargs, :tc, nothing)
    emit!(tc, :sizing, "size_members", "", :enter;
          dispatch="concrete_columns",
          n_members=length(Pu),
          options_type=string(typeof(opts)))
    result = size_columns(Pu, Mux, geometries, opts; kwargs...)
    emit!(tc, :sizing, "size_members", "", :exit; status=string(result.status))
    return result
end

function size_members(
    Mu::Vector, Vu::Vector, geometries::Vector,
    opts::ConcreteBeamOptions; kwargs...
)
    tc = get(kwargs, :tc, nothing)
    emit!(tc, :sizing, "size_members", "", :enter;
          dispatch="concrete_beams",
          n_members=length(Mu),
          options_type=string(typeof(opts)))
    result = size_beams(Mu, Vu, geometries, opts; kwargs...)
    emit!(tc, :sizing, "size_members", "", :exit; status=string(result.status))
    return result
end

function size_members(
    Mu::Vector, Vu::Vector, geometries::Vector,
    opts::PixelFrameBeamOptions; kwargs...
)
    tc = get(kwargs, :tc, nothing)
    emit!(tc, :sizing, "size_members", "", :enter;
          dispatch="pixelframe_beams",
          n_members=length(Mu),
          options_type=string(typeof(opts)))
    result = size_beams(Mu, Vu, geometries, opts; kwargs...)
    emit!(tc, :sizing, "size_members", "", :exit; status=string(result.status))
    return result
end

function size_members(
    Pu::Vector, Mux::Vector, geometries::Vector,
    opts::PixelFrameColumnOptions; kwargs...
)
    tc = get(kwargs, :tc, nothing)
    emit!(tc, :sizing, "size_members", "", :enter;
          dispatch="pixelframe_columns",
          n_members=length(Pu),
          options_type=string(typeof(opts)))
    result = size_columns(Pu, Mux, geometries, opts; kwargs...)
    emit!(tc, :sizing, "size_members", "", :exit; status=string(result.status))
    return result
end

