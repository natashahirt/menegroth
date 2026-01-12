"""
    ISymmSection{T} <: AbstractSection

Doubly-symmetric I-section. Properties computed from geometry.
Compatible with AISC W, S, HP shapes and custom plate girders.

# Fields
- `name`: Optional identifier (e.g., "W10X22")
- `d`, `bf`, `tw`, `tf`: Raw geometry
- `material`: Optional Metal for code checks
- Computed: `A`, `Ix`, `Iy`, `Iyc`, `J`, `Cw`, `Sx`, `Sy`, `Zx`, `Zy`, `rx`, `ry`
"""
mutable struct ISymmSection{T} <: AbstractSection
    # identity
    name::Union{String, Nothing}
    # geometry
    d::T      # depth
    bf::T     # flange width
    tw::T     # web thickness
    tf::T     # flange thickness
    # material (for code checks)
    material::Union{Metal, Nothing}
    # computed properties
    A::T      # area
    Ix::T     # strong axis moment of inertia
    Iy::T     # weak axis moment of inertia
    Iyc::T    # compression flange Iy
    J::T      # torsional constant
    Cw::T     # warping constant
    Sx::T     # elastic section modulus (strong)
    Sy::T     # elastic section modulus (weak)
    Zx::T     # plastic section modulus (strong)
    Zy::T     # plastic section modulus (weak)
    rx::T     # radius of gyration (strong)
    ry::T     # radius of gyration (weak)
end

# Constructor - computes all properties from geometry
function ISymmSection(d::T, bf::T, tw::T, tf::T; name=nothing, material=nothing) where T
    props = compute_all_properties(d, bf, tw, tf)
    ISymmSection{T}(name, d, bf, tw, tf, material,
        props.A, props.Ix, props.Iy, props.Iyc, props.J, props.Cw,
        props.Sx, props.Sy, props.Zx, props.Zy, props.rx, props.ry)
end

# Update in place (for optimization loops)
function update!(s::ISymmSection; d=s.d, bf=s.bf, tw=s.tw, tf=s.tf, material=s.material)
    s.d, s.bf, s.tw, s.tf, s.material = d, bf, tw, tf, material
    props = compute_all_properties(d, bf, tw, tf)
    s.A, s.Ix, s.Iy, s.Iyc = props.A, props.Ix, props.Iy, props.Iyc
    s.J, s.Cw = props.J, props.Cw
    s.Sx, s.Sy, s.Zx, s.Zy = props.Sx, props.Sy, props.Zx, props.Zy
    s.rx, s.ry = props.rx, props.ry
    return s
end

# Update from vector [d, bf, tw, tf]
update!(s::ISymmSection, v::Vector) = update!(s; d=v[1], bf=v[2], tw=v[3], tf=v[4])

# Return modified copy
function update(s::ISymmSection; d=s.d, bf=s.bf, tw=s.tw, tf=s.tf, material=s.material)
    ISymmSection(d, bf, tw, tf; name=s.name, material=material)
end

# Quick geometry extraction
geometry(s::ISymmSection) = (s.d, s.bf, s.tw, s.tf)

# Get 2D outline for plotting
get_coords(s::ISymmSection) = get_coords(s.d, s.bf, s.tw, s.tf)

# Pure geometry computation functions for symmetric I-sections
# All functions take raw dimensions: d (depth), bf (flange width), tw (web thickness), tf (flange thickness)

"""Area of symmetric I-section"""
compute_A(d, bf, tw, tf) = 2 * bf * tf + (d - 2 * tf) * tw

"""Strong-axis moment of inertia"""
function compute_Ix(d, bf, tw, tf)
    hw = d - 2 * tf
    I_web = tw * hw^3 / 12
    I_flanges = 2 * (bf * tf^3 / 12 + bf * tf * ((d - tf) / 2)^2)
    return I_web + I_flanges
end

"""Weak-axis moment of inertia"""
function compute_Iy(d, bf, tw, tf)
    hw = d - 2 * tf
    I_web = hw * tw^3 / 12
    I_flanges = 2 * tf * bf^3 / 12
    return I_web + I_flanges
end

"""Compression flange Iy (for singly-symmetric checks)"""
compute_Iyc(bf, tf) = tf * bf^3 / 12

"""Torsional constant (approximate for thin-walled)"""
function compute_J(d, bf, tw, tf)
    hw = d - 2 * tf
    return (2 * bf * tf^3 + hw * tw^3) / 3
end

"""Warping constant"""
function compute_Cw(d, bf, tf, Iy)
    ho = d - tf  # distance between flange centroids
    return Iy * ho^2 / 4
end

"""Elastic section modulus (strong axis)"""
compute_Sx(d, Ix) = Ix / (d / 2)

"""Elastic section modulus (weak axis)"""
compute_Sy(bf, Iy) = Iy / (bf / 2)

"""Plastic section modulus (strong axis)"""
function compute_Zx(d, bf, tw, tf)
    hw = d - 2 * tf
    Z_flanges = 2 * bf * tf * (d - tf) / 2
    Z_web = tw * hw^2 / 4
    return Z_flanges + Z_web
end

"""Plastic section modulus (weak axis)"""
function compute_Zy(d, bf, tw, tf)
    hw = d - 2 * tf
    return 2 * tf * bf^2 / 4 + hw * tw^2 / 4
end

"""Radius of gyration"""
compute_r(A, I) = sqrt(I / A)

"""
    compute_all_properties(d, bf, tw, tf)

Compute all section properties from raw geometry.
Returns NamedTuple with all values.
"""
function compute_all_properties(d, bf, tw, tf)
    A   = compute_A(d, bf, tw, tf)
    Ix  = compute_Ix(d, bf, tw, tf)
    Iy  = compute_Iy(d, bf, tw, tf)
    Iyc = compute_Iyc(bf, tf)
    J   = compute_J(d, bf, tw, tf)
    Cw  = compute_Cw(d, bf, tf, Iy)
    Sx  = compute_Sx(d, Ix)
    Sy  = compute_Sy(bf, Iy)
    Zx  = compute_Zx(d, bf, tw, tf)
    Zy  = compute_Zy(d, bf, tw, tf)
    rx  = compute_r(A, Ix)
    ry  = compute_r(A, Iy)
    
    return (; A, Ix, Iy, Iyc, J, Cw, Sx, Sy, Zx, Zy, rx, ry)
end

"""
    get_coords(d, bf, tw, tf)

Return 2D outline coordinates for plotting.
Section centered at (0, -d/2).
"""
function get_coords(d, bf, tw, tf)
    return [
        [-bf/2, 0],
        [bf/2, 0],
        [bf/2, -tf],
        [tw/2, -tf],
        [tw/2, -(d - tf)],
        [bf/2, -(d - tf)],
        [bf/2, -d],
        [-bf/2, -d],
        [-bf/2, -(d - tf)],
        [-tw/2, -(d - tf)],
        [-tw/2, -tf],
        [-bf/2, -tf],
        [-bf/2, 0]
    ]
end
