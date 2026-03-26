# ==============================================================================
# Solver Decision Trace
# ==============================================================================
#
# Structured tracing for solver decisions, enabling LLM-readable explanations
# of why the solver made specific choices (section selection, fallback paths,
# convergence behavior, etc.).
#
# Two main components:
#   1. TraceCollector + TraceEvent — runtime event accumulation
#   2. @traced macro — compile-time annotation declaring trace obligations
#
# Design principles:
#   - Zero runtime cost when tracing is disabled (emit! is a no-op on nothing)
#   - @traced is metadata-only — it does not modify the function body
#   - TRACE_REGISTRY enables automated audit of trace coverage
# ==============================================================================

# ==============================================================================
# Trace Events
# ==============================================================================

"""
    TraceEvent

A single recorded decision point in the solver pipeline.

# Fields
- `timestamp::Float64` — seconds since trace start
- `layer::Symbol` — one of `:pipeline`, `:workflow`, `:sizing`, `:optimizer`, `:checker`, `:slab`
- `stage::String` — human-readable stage name (e.g. "optimize_discrete", "size_flat_plate!")
- `element_id::String` — element or group identifier (e.g. "column_group_3", "slab_2")
- `event_type::Symbol` — one of `:enter`, `:exit`, `:decision`, `:iteration`, `:fallback`, `:failure`
- `data::Dict{String, Any}` — event-specific payload (ratios, thresholds, choices, reasons)
"""
struct TraceEvent
    timestamp::Float64
    layer::Symbol
    stage::String
    element_id::String
    event_type::Symbol
    data::Dict{String, Any}
end

# ==============================================================================
# Trace Collector
# ==============================================================================

"""
    TraceCollector

Accumulates `TraceEvent`s during a design run. Pass as an optional `tc` kwarg
through the pipeline; functions call `emit!(tc, ...)` at decision points.

A `nothing` collector is the default — `emit!` on `nothing` is a no-op, so
tracing adds zero overhead when not requested.

# Usage
```julia
tc = TraceCollector()
design_building(struc, params; tc=tc)
events = tc.events  # Vector{TraceEvent}
```
"""
mutable struct TraceCollector
    events::Vector{TraceEvent}
    enabled::Bool
    start_time::Float64
end

"""
    TraceCollector(; enabled=true)

Create a new trace collector. The start time is recorded at construction.
"""
function TraceCollector(; enabled::Bool = true)
    TraceCollector(TraceEvent[], enabled, time())
end

"""
    emit!(tc::TraceCollector, layer, stage, element_id, event_type; kwargs...)

Record a trace event. Each keyword argument becomes an entry in the event's
`data` dict.
"""
function emit!(tc::TraceCollector, layer::Symbol, stage::AbstractString,
               element_id::AbstractString, event_type::Symbol; kwargs...)
    tc.enabled || return nothing
    data = Dict{String, Any}(string(k) => v for (k, v) in kwargs)
    push!(tc.events, TraceEvent(time() - tc.start_time, layer, stage,
                                element_id, event_type, data))
    return nothing
end

"""No-op: when `tc` is `nothing`, tracing is disabled with zero cost."""
emit!(::Nothing, args...; kwargs...) = nothing

"""
    reset!(tc::TraceCollector)

Clear all events and reset the start time.
"""
function reset!(tc::TraceCollector)
    empty!(tc.events)
    tc.start_time = time()
    return tc
end

# ==============================================================================
# @traced Macro — Trace Contract Annotations
# ==============================================================================

"""
    TracedFunctionMeta

Metadata for a function annotated with `@traced`. Stored in `TRACE_REGISTRY`
for introspection by the audit tools.
"""
struct TracedFunctionMeta
    func_name::Symbol
    layer::Symbol
    events::Vector{Symbol}
    companion::Union{Symbol, Nothing}
    file::String
    line::Int
end

"""
Global registry of all `@traced` function contracts. Populated at compile time
by the `@traced` macro. Audit tools read this to verify trace coverage.

Keys are `(func_name, layer)` tuples to handle multiple methods of the same
function annotated for different layers.
"""
const TRACE_REGISTRY = Dict{Tuple{Symbol, Symbol}, TracedFunctionMeta}()

"""
    registered_functions()

Return the full trace registry for introspection by audit scripts.
"""
registered_functions() = TRACE_REGISTRY

"""
    @traced layer=:optimizer events=[:enter, :exit] [companion=:explain_feasibility] function f(...)
        ...
    end

Annotate a function as requiring solver trace instrumentation.

The macro **does not modify** the function body — it only registers the trace
contract in `TRACE_REGISTRY` at compile time. The function definition is
emitted unchanged.

# Arguments (keyword-style, before the function definition)
- `layer::Symbol` — required. Which trace layer this function belongs to.
- `events::Vector{Symbol}` — required. Which event types the function must emit.
- `companion::Symbol` — optional. Names a companion function (e.g. `explain_feasibility`)
  that provides trace data post-hoc instead of inline `emit!` calls.

# Purpose
1. Makes trace obligations visible to developers reading the source.
2. Enables automated audit: `TRACE_REGISTRY` lists every function that should
   be traced, what events it should emit, and whether it delegates to a companion.
3. Zero runtime cost — the function body is not wrapped or instrumented by the macro.

# Example
```julia
@traced layer=:optimizer events=[:enter, :exit, :decision] function optimize_discrete(...)
    emit!(tc, :optimizer, "optimize_discrete", "", :enter; n_groups=n)
    # ...
    emit!(tc, :optimizer, "optimize_discrete", "", :exit; status=s)
end

@traced layer=:checker companion=:explain_feasibility events=[:enter, :exit] function is_feasible(...)::Bool
    # No emit! needed — explain_feasibility provides the trace data
end
```
"""
macro traced(args...)
    # Parse keyword arguments and the function definition
    local layer::Union{Symbol, Nothing} = nothing
    local events::Union{Vector{Symbol}, Nothing} = nothing
    local companion::Union{Symbol, Nothing} = nothing
    local funcdef = nothing

    for arg in args
        if arg isa Expr && arg.head == :(=)
            key = arg.args[1]
            val = arg.args[2]
            if key == :layer
                layer = val isa QuoteNode ? val.value : val
            elseif key == :events
                if val isa Expr && val.head == :vect
                    events = Symbol[v isa QuoteNode ? v.value : v for v in val.args]
                end
            elseif key == :companion
                companion = val isa QuoteNode ? val.value : val
            end
        elseif arg isa Expr && (arg.head == :function || (arg.head == :(=) && arg.args[1] isa Expr))
            funcdef = arg
        end
    end

    if layer === nothing
        error("@traced requires `layer=:symbol`")
    end
    if events === nothing
        error("@traced requires `events=[:sym1, :sym2, ...]`")
    end
    if funcdef === nothing
        error("@traced must be followed by a function definition")
    end

    # Extract function name from the definition
    func_name = _extract_func_name(funcdef)

    # Build the registry entry at compile time
    file_str = string(__source__.file)
    line_num = __source__.line
    events_expr = Expr(:vect, [QuoteNode(e) for e in events]...)
    companion_expr = companion === nothing ? :nothing : QuoteNode(companion)

    quote
        # Register the trace contract
        StructuralSizer.TRACE_REGISTRY[($(QuoteNode(func_name)), $(QuoteNode(layer)))] =
            StructuralSizer.TracedFunctionMeta(
                $(QuoteNode(func_name)),
                $(QuoteNode(layer)),
                $(esc(events_expr)),
                $companion_expr,
                $file_str,
                $line_num
            )
        # Emit the function definition unchanged
        $(esc(funcdef))
    end
end

"""Extract the function name symbol from a function definition Expr."""
function _extract_func_name(ex::Expr)
    if ex.head == :function
        sig = ex.args[1]
    elseif ex.head == :(=) && ex.args[1] isa Expr
        sig = ex.args[1]
    else
        error("Cannot extract function name from expression: $(ex.head)")
    end
    # Handle f(...), f(...)::T, and where-clause forms
    while sig isa Expr && sig.head in (:(::), :where, :call)
        if sig.head == :call
            name = sig.args[1]
            # Handle Module.func qualified names
            if name isa Expr && name.head == :(.)
                return name.args[end] isa QuoteNode ? name.args[end].value : name.args[end]
            end
            return name isa Symbol ? name : error("Cannot extract function name from: $name")
        end
        sig = sig.args[1]
    end
    error("Cannot extract function name from signature")
end
