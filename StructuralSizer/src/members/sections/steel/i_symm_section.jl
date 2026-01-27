"""Doubly-symmetric I-section with computed properties."""

# -----------------------------------------------------------------------------
# Unitful dimension-typed aliases (units may vary: inch, m, etc.)
# -----------------------------------------------------------------------------
const LengthQ = Unitful.Quantity{T, Unitful.𝐋, U} where {T<:Real, U}
const AreaQ   = Unitful.Quantity{T, Unitful.𝐋^2, U} where {T<:Real, U}
const ModQ    = Unitful.Quantity{T, Unitful.𝐋^3, U} where {T<:Real, U}  # Sx, Zx, etc.
const InertQ  = Unitful.Quantity{T, Unitful.𝐋^4, U} where {T<:Real, U}  # Ix, Iy, J, etc.
const WarpQ   = Unitful.Quantity{T, Unitful.𝐋^6, U} where {T<:Real, U}  # Cw

mutable struct ISymmSection <: AbstractSection
    name::Union{String, Nothing}
    # input geometry
    d::LengthQ       # total depth
    bf::LengthQ      # flange width
    tw::LengthQ      # web thickness
    tf::LengthQ      # flange thickness
    # derived geometry
    h::LengthQ       # clear web height (d - 2tf)
    ho::LengthQ      # distance between flange centroids (d - tf)
    λ_f::Float64  # flange slenderness (bf / 2tf)
    λ_w::Float64  # web slenderness (h / tw)
    d_tw::Float64 # depth-to-web ratio (d / tw)
    Aw::AreaQ        # web area
    Af::AreaQ        # flange area
    # material
    material::Union{Metal, Nothing}
    # section properties
    A::AreaQ
    Ix::InertQ
    Iy::InertQ
    Iyc::InertQ
    J::InertQ
    Cw::WarpQ
    Sx::ModQ
    Sy::ModQ
    Zx::ModQ
    Zy::ModQ
    rx::LengthQ
    ry::LengthQ
    rts::LengthQ
    # AISC preferred (bolded) section flag
    is_preferred::Bool
end

# Constructor with optional database overrides for J, Cw, rts, ho
function ISymmSection(d, bf, tw, tf;
                      name=nothing, material=nothing,
                      J_db=nothing, Cw_db=nothing, rts_db=nothing, ho_db=nothing,
                      is_preferred=false)
    props = compute_all_properties(d, bf, tw, tf)
    ho  = ho_db  !== nothing ? ho_db  : props.ho
    J   = J_db   !== nothing ? J_db   : props.J
    Cw  = Cw_db  !== nothing ? Cw_db  : props.Cw
    rts = rts_db !== nothing ? rts_db : props.rts
    
    ISymmSection(name, d, bf, tw, tf,
        props.h, ho, props.λ_f, props.λ_w, props.d_tw, props.Aw, props.Af,
        material,
        props.A, props.Ix, props.Iy, props.Iyc, J, Cw,
        props.Sx, props.Sy, props.Zx, props.Zy, props.rx, props.ry, rts,
        is_preferred)
end

function Base.copy(s::ISymmSection)
    ISymmSection(
        s.name,
        s.d, s.bf, s.tw, s.tf,
        s.h, s.ho, s.λ_f, s.λ_w, s.d_tw, s.Aw, s.Af,
        s.material,
        s.A, s.Ix, s.Iy, s.Iyc, s.J, s.Cw,
        s.Sx, s.Sy, s.Zx, s.Zy, s.rx, s.ry, s.rts,
        s.is_preferred
    )
end

# Update in place
function update!(s::ISymmSection; d=s.d, bf=s.bf, tw=s.tw, tf=s.tf, material=s.material)
    s.d, s.bf, s.tw, s.tf, s.material = d, bf, tw, tf, material
    props = compute_all_properties(d, bf, tw, tf)
    s.h, s.ho = props.h, props.ho
    s.λ_f, s.λ_w, s.d_tw = props.λ_f, props.λ_w, props.d_tw
    s.Aw, s.Af = props.Aw, props.Af
    s.A, s.Ix, s.Iy, s.Iyc = props.A, props.Ix, props.Iy, props.Iyc
    s.J, s.Cw = props.J, props.Cw
    s.Sx, s.Sy, s.Zx, s.Zy = props.Sx, props.Sy, props.Zx, props.Zy
    s.rx, s.ry, s.rts = props.rx, props.ry, props.rts
    return s
end

update!(s::ISymmSection, v::Vector) = update!(s; d=v[1], bf=v[2], tw=v[3], tf=v[4])

function update(s::ISymmSection; d=s.d, bf=s.bf, tw=s.tw, tf=s.tf, material=s.material)
    ISymmSection(d, bf, tw, tf; name=s.name, material=material)
end

geometry(s::ISymmSection) = (s.d, s.bf, s.tw, s.tf)
get_coords(s::ISymmSection) = get_coords(s.d, s.bf, s.tw, s.tf)

# Interface
area(s::ISymmSection) = s.A
depth(s::ISymmSection) = s.d
width(s::ISymmSection) = s.bf

# Geometry computation functions
compute_A(d, bf, tw, tf) = 2 * bf * tf + (d - 2 * tf) * tw

function compute_Ix(d, bf, tw, tf)
    hw = d - 2 * tf
    I_web = tw * hw^3 / 12
    I_flanges = 2 * (bf * tf^3 / 12 + bf * tf * ((d - tf) / 2)^2)
    return I_web + I_flanges
end

function compute_Iy(d, bf, tw, tf)
    hw = d - 2 * tf
    I_web = hw * tw^3 / 12
    I_flanges = 2 * tf * bf^3 / 12
    return I_web + I_flanges
end

compute_Iyc(bf, tf) = tf * bf^3 / 12

function compute_J(d, bf, tw, tf)
    hw = d - 2 * tf
    return (2 * bf * tf^3 + hw * tw^3) / 3
end

function compute_Cw(d, bf, tf, Iy)
    ho = d - tf
    return Iy * ho^2 / 4
end

compute_Sx(d, Ix) = Ix / (d / 2)
compute_Sy(bf, Iy) = Iy / (bf / 2)

function compute_Zx(d, bf, tw, tf)
    hw = d - 2 * tf
    Z_flanges = 2 * bf * tf * (d - tf) / 2
    Z_web = tw * hw^2 / 4
    return Z_flanges + Z_web
end

function compute_Zy(d, bf, tw, tf)
    hw = d - 2 * tf
    return 2 * tf * bf^2 / 4 + hw * tw^2 / 4
end

compute_r(A, I) = sqrt(I / A)
compute_rts(Iy, Cw, Sx) = sqrt(sqrt(Iy * Cw) / Sx)

function compute_all_properties(d, bf, tw, tf)
    h    = d - 2 * tf
    ho   = d - tf
    λ_f  = ustrip(bf / (2 * tf))
    λ_w  = ustrip(h / tw)
    d_tw = ustrip(d / tw)
    Aw   = h * tw
    Af   = bf * tf
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
    rts = compute_rts(Iy, Cw, Sx)
    return (; h, ho, λ_f, λ_w, d_tw, Aw, Af, A, Ix, Iy, Iyc, J, Cw, Sx, Sy, Zx, Zy, rx, ry, rts)
end

"""2D outline coordinates for plotting."""
function get_coords(d, bf, tw, tf)
    return [
        [-bf/2, 0], [bf/2, 0], [bf/2, -tf], [tw/2, -tf],
        [tw/2, -(d - tf)], [bf/2, -(d - tf)], [bf/2, -d], [-bf/2, -d],
        [-bf/2, -(d - tf)], [-tw/2, -(d - tf)], [-tw/2, -tf], [-bf/2, -tf], [-bf/2, 0]
    ]
end
