# Non-Composite Steel Deck Sizing
# Steel deck only (roof deck, form deck)

"""
Select non-composite deck for given span and load.

# Arguments
- `span`: Clear span
- `load`: Total factored load
- `material`: Steel material (default: A992_Steel)

# Returns
- `ProfileResult` with deck profile
"""
function _size_span_floor(::NonCompositeDeck, span::L, sdl::F, live::F;
                    material::Metal=A992_Steel) where {L, F}
    error("NonCompositeDeck sizing not yet implemented")
end
