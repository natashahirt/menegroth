# Sizing Logic Implementations
#
# NOTE:
# The legacy public span-based API `size_floor` has been removed in favor of the
# structure/slab-based API:
#   size_slabs! → size_slab! → _size_slab!
#
# We still keep an *internal* span-based helper for initialization and isolated
# checks, but it is not exported:
#   _size_span_floor(ft, span, sdl, live; ...) -> AbstractFloorResult

# Include all code implementations (define _size_span_floor methods)
include("concrete/_concrete.jl")
include("steel/_steel.jl")
include("timber/_timber.jl")
include("vault/_vault.jl")
include("custom/_custom.jl")

"""
    _size_span_floor(st::AbstractFloorSystem, span, sdl, live; kwargs...)

Internal span-based sizing helper (returns an `AbstractFloorResult`).
Used for initialization and standalone checks. Not exported.
"""
function _size_span_floor(st::AbstractFloorSystem, span, sdl, live; kwargs...)
    # This will catch cases where the specific type doesn't have an implementation
    # or doesn't match the signature.
    error("_size_span_floor not implemented for $(typeof(st)) with arguments: span=$(typeof(span)), sdl=$(typeof(sdl)), live=$(typeof(live))")
end
