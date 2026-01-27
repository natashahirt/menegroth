"""Standard deformed reinforcing bar per ASTM A615."""
struct Rebar{T} <: AbstractSection
    size::Int
    material::Metal
    diameter::T
    weight::T
    A::T
end

# Derived properties
compute_Ix(r::Rebar) = π * r.diameter^4 / 64
compute_Iy(r::Rebar) = compute_Ix(r)
compute_J(r::Rebar)  = π * r.diameter^4 / 32
compute_r(r::Rebar)  = r.diameter / 4

geometry(r::Rebar) = (r.diameter,)
get_coords(r::Rebar) = get_circle_coords(r.diameter / 2)

# Interface
area(r::Rebar) = r.A
depth(r::Rebar) = r.diameter
width(r::Rebar) = r.diameter

function get_circle_coords(radius, n=32)
    θ = range(0, 2π, length=n+1)
    return [[radius * cos(t), radius * sin(t)] for t in θ]
end

# Catalog
const REBAR_CATALOG = Dict{Int, Rebar}()

function load_rebar_catalog!()
    data = [
        (3,  0.375, 0.376, 0.11),
        (4,  0.500, 0.668, 0.20),
        (5,  0.625, 1.043, 0.31),
        (6,  0.750, 1.502, 0.44),
        (7,  0.875, 2.044, 0.60),
        (8,  1.000, 2.670, 0.79),
        (9,  1.128, 3.400, 1.00),
        (10, 1.270, 4.303, 1.27),
        (11, 1.410, 5.313, 1.56),
        (14, 1.693, 7.650, 2.25),
        (18, 2.257, 13.600, 4.00),
    ]
    for (sz, d, w, a) in data
        REBAR_CATALOG[sz] = Rebar(sz, Rebar_60, d * u"inch", w * u"lb/ft", a * u"inch^2")
    end
    @debug "Loaded $(length(REBAR_CATALOG)) rebar sizes"
end

"""Get rebar by size (e.g., `rebar(4)` for #4 bar)."""
function rebar(size::Int; material=Rebar_60)
    isempty(REBAR_CATALOG) && load_rebar_catalog!()
    haskey(REBAR_CATALOG, size) || error("Rebar #$size not found")
    r = REBAR_CATALOG[size]
    material === Rebar_60 ? r : Rebar(r.size, material, r.diameter, r.weight, r.A)
end

rebar_sizes() = (isempty(REBAR_CATALOG) && load_rebar_catalog!(); sort(collect(keys(REBAR_CATALOG))))
all_rebar() = (isempty(REBAR_CATALOG) && load_rebar_catalog!(); collect(values(REBAR_CATALOG)))
