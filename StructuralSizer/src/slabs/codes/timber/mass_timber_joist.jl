# Mass Timber Joist Floor Sizing
# Glulam or LVL joists with panel/deck topping

# Similar concept to steel joist + deck but with timber

"""
Select mass timber joist floor system.

# Arguments
- `span`: Clear span of joists
- `load`: Total superimposed load
- `material`: Timber material (placeholder for future timber material types)
- `spacing`: Joist spacing (default 1.2m / 4')
- `deck_type`: Topping (:plywood, :osb, :nlt, :clt)

# Returns
- `TimberJoistResult` with joist and deck parameters
"""
function _size_span_floor(::MassTimberJoist, span::L, sdl::F, live::F;
                    material::AbstractMaterial=NWC_4000,
                    spacing::L=uconvert(unit(span), 1.2u"m"),
                    deck_type::Symbol=:plywood) where {L, F}
    error("MassTimberJoist sizing not yet implemented")
end
