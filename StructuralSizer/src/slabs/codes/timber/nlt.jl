# Nail-Laminated Timber (NLT) Panel Sizing
# Traditional nail-lam decking (2x lumber nailed together)

# NLT is often site-built from standard dimension lumber

"""
Select NLT panel for given span and load.

# Arguments
- `span`: Clear span (typically shorter than CLT/DLT)
- `load`: Superimposed load
- `material`: Timber material (placeholder for future timber material types)
- `lumber_size`: Lumber nominal size (:auto, :lumber_2x6, :lumber_2x8, :lumber_2x10, :lumber_2x12)
- `fire_rating`: Required fire rating in hours (default 1)

# Returns
- `TimberPanelResult` with panel specification
"""
function _size_span_floor(::NLT, span::L, sdl::F, live::F;
                    material::AbstractMaterial=NWC_4000,  # placeholder until Timber type exists
                    lumber_size::Symbol=:auto,
                    fire_rating::Int=1) where {L, F}
    error("NLT sizing not yet implemented")
end
