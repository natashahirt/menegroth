# Composite Steel Deck Sizing
# Steel deck + concrete fill acting compositely

# TODO: Load Vulcraft/ASC deck span tables
# Key parameters: deck profile, gauge, span, construction load, composite capacity

"""
Select composite deck system for given span and load.

# Arguments
- `span`: Clear span
- `sdl`: Superimposed dead load
- `live`: Live load
- `material`: Primary material (concrete fill)
- `deck_mat`: Steel material for deck
"""
function _size_span_floor(::CompositeDeck, span::L, sdl::F, live::F;
                    material::Concrete=NWC_4000,
                    deck_mat::Metal=A992_Steel) where {L, F}
    error("CompositeDeck sizing not yet implemented")
end
