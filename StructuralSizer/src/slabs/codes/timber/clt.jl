# Cross-Laminated Timber (CLT) Panel Sizing
# Catalog-based selection from manufacturer tables

# TODO: Load CLT manufacturer data (Nordic, Structurlam, etc.)
# Key parameters: span, load, fire rating, acoustic requirements
# Common thicknesses: 3-ply (105mm), 5-ply (175mm), 7-ply (245mm), 9-ply (315mm)

"""
Select CLT panel for given span and load.

# Arguments
- `span`: Clear span
- `load`: Superimposed load (factored)
- `material`: Timber material (placeholder for future timber material types)
- `fire_rating`: Required fire rating in hours (default 1)

# Returns
- `TimberPanelResult` with panel specification
"""
function _size_span_floor(::CLT, span::L, sdl::F, live::F;
                    material::AbstractMaterial=NWC_4000,
                    fire_rating::Int=1) where {L, F}
    error("CLT sizing not yet implemented")
end
