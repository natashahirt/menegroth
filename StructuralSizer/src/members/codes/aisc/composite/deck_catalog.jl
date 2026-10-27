# ==============================================================================
# Composite deck profile geometry — Vulcraft Deck Solutions (September 2020)
# ==============================================================================
# Geometry only. Strength of the deck and of the composite beam comes from
# SDI C-2017 and AISC 360-22, not from the catalog's ASD tables.

"""
    CompositeDeckProfile

Nominal geometry of one composite deck profile, read from the "Nominal
Dimensions" figure of its catalog page.

# Fields
- `name`:       Catalog profile name (e.g. `"3VLI"`)
- `hr`:         Nominal rib height
- `rib_top`:    Concrete rib width at the top of the deck (opening between top flanges)
- `rib_bottom`: Concrete rib width at the bottom (flat of the bottom flange)
- `pitch`:      Rib spacing
- `gages`:      Gage => (t = base metal thickness, w_dd = deck weight)
- `source`:     Catalog citation

`wr` is the average concrete rib width, `(rib_top + rib_bottom) / 2`, the
quantity AISC 360-22 §I3.2c(a) and §I8.2a use (corpus: aisc-360-22, PDF
pp. 170, 182). The ribs of these profiles widen upward, so the minimum clear
width near the top of the deck is not less than `wr` and does not cap it.
"""
struct CompositeDeckProfile
    name::String
    hr::typeof(1.0u"m")
    rib_top::typeof(1.0u"m")
    rib_bottom::typeof(1.0u"m")
    pitch::typeof(1.0u"m")
    gages::Dict{Int, NamedTuple{(:t, :w_dd), Tuple{typeof(1.0u"m"), typeof(1.0u"Pa")}}}
    source::String
end

deck_wr(p::CompositeDeckProfile) = (p.rib_top + p.rib_bottom) / 2

function _deck_profile(name, hr, top, bottom, pitch, page, gage_rows)
    gages = Dict(g => (t = uconvert(u"m", t * u"inch"), w_dd = uconvert(u"Pa", w * u"psf"))
                 for (g, t, w) in gage_rows)
    CompositeDeckProfile(name, uconvert(u"m", hr * u"inch"), uconvert(u"m", top * u"inch"),
                         uconvert(u"m", bottom * u"inch"), uconvert(u"m", pitch * u"inch"),
                         gages,
                         "Vulcraft Deck Solutions (Sept. 2020), PDF p. $page, Nominal Dimensions " *
                         "and Section Properties (corpus: vulcraft-deck-solutions-2020)")
end

# Gage rows: (gage, base metal thickness t [in], deck weight w_dd [psf]).
const VULCRAFT_COMPOSITE_DECKS = Dict(
    "1.5VL" => _deck_profile("1.5VL", 1.5, 2.625, 1.625, 6.0, 80,
        [(22, 0.0295, 1.6), (20, 0.0358, 2.0), (19, 0.0418, 2.3),
         (18, 0.0474, 2.6), (16, 0.0598, 3.3)]),
    "2VLI" => _deck_profile("2VLI", 2.0, 7.0, 5.0, 12.0, 88,
        [(22, 0.0295, 1.6), (20, 0.0358, 1.9), (19, 0.0418, 2.2),
         (18, 0.0474, 2.5), (16, 0.0598, 3.2)]),
    "3VLI" => _deck_profile("3VLI", 3.0, 7.25, 4.75, 12.0, 92,
        [(22, 0.0295, 1.7), (20, 0.0358, 2.1), (19, 0.0418, 2.4),
         (18, 0.0474, 2.7), (16, 0.0598, 3.5)]),
)

# Profiles sharing one nominal geometry on the same catalog page; they differ
# in side-lap attachment only.
const _VULCRAFT_DECK_ALIASES = Dict(
    "1.5VLI" => "1.5VL", "1.5PLVLI" => "1.5VL",
    "2VLJ" => "2VLI", "2PLVLI" => "2VLI",
    "3VLJ" => "3VLI", "3PLVLI" => "3VLI",
)

"""
    composite_deck_profile(name) -> CompositeDeckProfile

Look up a Vulcraft composite deck profile by catalog name. A trailing `-36`
(cover width) is accepted. Throws for a profile not in the catalog.
"""
function composite_deck_profile(name::AbstractString)
    key = uppercase(replace(strip(name), r"-36$"i => ""))
    key = get(_VULCRAFT_DECK_ALIASES, key, key)
    haskey(VULCRAFT_COMPOSITE_DECKS, key) || throw(ArgumentError(
        "Composite deck profile \"$name\" is not in the catalog. " *
        "Available: $(join(sort(collect(keys(VULCRAFT_COMPOSITE_DECKS))), ", ")) " *
        "and their side-lap variants."))
    return VULCRAFT_COMPOSITE_DECKS[key]
end
