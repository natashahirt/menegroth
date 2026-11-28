"""
    FloorSource

Stable reference to one floor declaration in an owning package.

`StructuralSizer` treats this identifier as opaque. The owner resolves it to
its geometry and installs any accepted design proposal.
"""
struct FloorSource
    index::Int

    function FloorSource(index::Int)
        index > 0 || throw(ArgumentError("floor source index must be positive; got $index"))
        new(index)
    end
end

"""
    FloorDesignRequest

Immutable policy request for one floor design.

The request contains no mutable building object. Systems with a normalized
kernel carry immutable geometry, load, and support input; `source` remains an
opaque owner reference used when installing a successful proposal.
"""
struct FloorDesignRequest{
    F<:AbstractFloorSystem,
    O<:AbstractFloorOptions,
    C,
    I,
}
    source::FloorSource
    system::F
    options::O
    column_options::C
    input::I
    max_iterations::Int
    fire_rating::Float64

    function FloorDesignRequest(
        source::FloorSource,
        system::F,
        options::O,
        column_options::C = nothing;
        input = nothing,
        max_iterations::Int = 10,
        fire_rating::Real = 0.0,
    ) where {
        F<:AbstractFloorSystem,
        O<:AbstractFloorOptions,
        C,
    }
        max_iterations > 0 ||
            throw(ArgumentError("max_iterations must be positive; got $max_iterations"))
        fire_rating >= 0 ||
            throw(ArgumentError("fire_rating must be nonnegative; got $fire_rating"))
        _validate_floor_options(system, options)
        new{F, O, C, typeof(input)}(
            source,
            system,
            options,
            column_options,
            input,
            max_iterations,
            Float64(fire_rating),
        )
    end
end

"""Read-only reusable data prepared for a family of floor-design requests."""
struct FloorDesignWorkspace{C}
    column_cache::C
end

_validate_floor_options(::FlatPlate, ::FlatPlateOptions) = nothing
_validate_floor_options(::FlatSlab, ::FlatSlabOptions) = nothing
_validate_floor_options(::OneWay, ::OneWayOptions) = nothing
# Two-way thickness reads the rebar grade from either options type.
# FlatPlateOptions remains accepted: a square bay classified as :two_way
# is sized with the building's flat-plate options when that is what was passed.
_validate_floor_options(::TwoWay, ::FlatPlateOptions) = nothing
_validate_floor_options(::TwoWay, ::TwoWayOptions) = nothing
_validate_floor_options(::Vault, ::VaultOptions) = nothing
_validate_floor_options(::CompositeDeck, ::CompositeDeckOptions) = nothing
_validate_floor_options(::CLT, ::TimberOptions) = nothing
_validate_floor_options(::DLT, ::TimberOptions) = nothing
_validate_floor_options(::NLT, ::TimberOptions) = nothing
_validate_floor_options(::MassTimberJoist, ::TimberOptions) = nothing
function _validate_floor_options(system::AbstractFloorSystem, options::AbstractFloorOptions)
    throw(ArgumentError(
        "options $(typeof(options)) do not define the canonical contract for " *
        "floor system $(typeof(system))",
    ))
end

"""Terminal state of a floor-design attempt."""
@enum FloorDesignStatus begin
    FLOOR_DESIGN_SUCCEEDED
    FLOOR_DESIGN_NOT_CONVERGED
    FLOOR_DESIGN_INFEASIBLE
end

"""Typed diagnostic attached to a floor-design outcome."""
struct FloorDesignDiagnostic
    code::Symbol
    message::String
end

"""
    FloorSupportUpdate

Proposed replacement state for one supporting column. This is inert data:
only the building owner may install it.
"""
struct FloorSupportUpdate{L, S, V}
    source_index::Int
    c1::L
    c2::L
    shape::Symbol
    section::S
    volumes::V
end

"""Proposed load state for one cell owned by the designed floor."""
struct FloorCellLoadUpdate{P}
    source_index::Int
    self_weight::P
    live_load::P
end

"""
    FloorDesignProposal

Complete installable floor state produced by a successful design attempt.
"""
struct FloorDesignProposal{
    R,
    D,
    P,
    C<:FloorCellLoadUpdate,
    U<:FloorSupportUpdate,
}
    result::R
    details::D
    drop_panel::P
    cell_updates::Vector{C}
    support_updates::Vector{U}
end

"""
    FloorDesignOutcome

Typed result envelope for every supported floor-design attempt.

`proposal` is present only when `status == FLOOR_DESIGN_SUCCEEDED`. Failed
attempts retain their typed raw `details` and diagnostics for reporting but
cannot be installed.
"""
struct FloorDesignOutcome{P, D}
    status::FloorDesignStatus
    proposal::Union{Nothing, P}
    details::D
    diagnostics::Vector{FloorDesignDiagnostic}
    iterations::Int
end

"""Return `true` only when an outcome contains an installable proposal."""
is_installable(outcome::FloorDesignOutcome) =
    outcome.status == FLOOR_DESIGN_SUCCEEDED && !isnothing(outcome.proposal)

"""
    floor_design_failure(raw) -> (status, code, message)

A floor that did not converge stays [`FLOOR_DESIGN_NOT_CONVERGED`](@ref) and
is not installed. `raw.stop`, when present, says whether the loop ran out of
iterations (`:budget`) or reached its size limit (`:at_limit`).
"""
function floor_design_failure(raw)
    reason = raw isa NamedTuple ?
        String(get(raw, :failure_reason, "design_failed")) : "design_failed"
    check = raw isa NamedTuple ? String(get(raw, :failing_check, "")) : ""
    stop = raw isa NamedTuple ? get(raw, :stop, nothing) : nothing
    status = reason == "non_convergence" ?
        FLOOR_DESIGN_NOT_CONVERGED : FLOOR_DESIGN_INFEASIBLE
    message = isempty(check) ? reason : "$reason ($check)"
    stop isa Symbol && (message *= "; $stop")
    return (status, Symbol(reason), message)
end

"""
    UnsupportedFloorSystemError

Raised when no sizing implementation exists for a requested floor system.
Unsupported dispatch is a contract error, never a successful no-op.
"""
struct UnsupportedFloorSystemError <: Exception
    system_type::DataType
end

function Base.showerror(io::IO, err::UnsupportedFloorSystemError)
    print(io, "no floor-design implementation for ", err.system_type)
end
