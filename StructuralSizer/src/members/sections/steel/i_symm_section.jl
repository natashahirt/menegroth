"""Doubly-symmetric I-section with computed properties."""

mutable struct ISymmSection <: AbstractSection
    name::Union{String, Nothing}
    # input geometry
    d::Length                # total depth
    bf::Length               # flange width
    tw::Length               # web thickness
    tf::Length               # flange thickness
    # derived geometry
    h::Length                # clear web height (d - 2tf)
    ho::Length               # distance between flange centroids (d - tf)
    λ_f::Float64             # flange slenderness (bf / 2tf)
    λ_w::Float64             # web slenderness (h / tw)
    d_tw::Float64            # depth-to-web ratio (d / tw)
    Aw::Area                 # web area
    Af::Area                 # flange area
    # material
    material::Union{Metal, Nothing}
    # section properties
    A::Area
    Ix::SecondMomentOfArea
    Iy::SecondMomentOfArea
    Iyc::SecondMomentOfArea
    J::SecondMomentOfArea
    Cw::WarpingConstant
    Sx::SectionModulus        # elastic section modulus (L³)
    Sy::SectionModulus
    Zx::SectionModulus        # plastic section modulus (L³)
    Zy::SectionModulus
    rx::Length
    ry::Length
    rts::Length
    # fillet geometry
    kdes::Length             # distance from outer flange face to web toe of fillet
    # fire protection perimeters (AISC Design Guide 19)
    PA::Length               # contour perimeter minus one flange (3-sided, beams)
    PB::Length               # full contour perimeter (4-sided, columns)
    # AISC preferred section flag
    is_preferred::Bool
end

# Constructor with optional database overrides for J, Cw, rts, ho, kdes
function ISymmSection(d, bf, tw, tf;
                      name=nothing, material=nothing,
                      J_db=nothing, Cw_db=nothing, rts_db=nothing, ho_db=nothing,
                      kdes_db=nothing,
                      is_preferred=false)
    kdes_val = kdes_db !== nothing ? kdes_db : tf  # default: no fillet (r=0)
    props = compute_all_properties(d, bf, tw, tf; kdes=kdes_val)
    ho  = ho_db  !== nothing ? ho_db  : props.ho
    J   = J_db   !== nothing ? J_db   : props.J
    Cw  = Cw_db  !== nothing ? Cw_db  : props.Cw
    rts = rts_db !== nothing ? rts_db : props.rts
    
    ISymmSection(name, d, bf, tw, tf,
        props.h, ho, props.λ_f, props.λ_w, props.d_tw, props.Aw, props.Af,
        material,
        props.A, props.Ix, props.Iy, props.Iyc, J, Cw,
        props.Sx, props.Sy, props.Zx, props.Zy, props.rx, props.ry, rts,
        kdes_val, props.PA, props.PB,
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
        s.kdes, s.PA, s.PB,
        s.is_preferred
    )
end

# Update in place (kdes resets to tf when geometry changes; pass kdes_db to constructor for catalog)
function update!(s::ISymmSection; d=s.d, bf=s.bf, tw=s.tw, tf=s.tf, material=s.material)
    s.d, s.bf, s.tw, s.tf, s.material = d, bf, tw, tf, material
    props = compute_all_properties(d, bf, tw, tf; kdes=s.kdes)
    s.h, s.ho = props.h, props.ho
    s.λ_f, s.λ_w, s.d_tw = props.λ_f, props.λ_w, props.d_tw
    s.Aw, s.Af = props.Aw, props.Af
    s.A, s.Ix, s.Iy, s.Iyc = props.A, props.Ix, props.Iy, props.Iyc
    s.J, s.Cw = props.J, props.Cw
    s.Sx, s.Sy, s.Zx, s.Zy = props.Sx, props.Sy, props.Zx, props.Zy
    s.rx, s.ry, s.rts = props.rx, props.ry, props.rts
    s.PA, s.PB = props.PA, props.PB
    return s
end

update!(s::ISymmSection, v::Vector) = update!(s; d=v[1], bf=v[2], tw=v[3], tf=v[4])

function update(s::ISymmSection; d=s.d, bf=s.bf, tw=s.tw, tf=s.tf, material=s.material)
    ISymmSection(d, bf, tw, tf; name=s.name, material=material, kdes_db=s.kdes)
end

geometry(s::ISymmSection) = (s.d, s.bf, s.tw, s.tf)
get_coords(s::ISymmSection) = get_coords(s.d, s.bf, s.tw, s.tf)

# Interface
section_area(s::ISymmSection) = s.A
section_depth(s::ISymmSection) = s.d
section_width(s::ISymmSection) = s.bf
Ix(s::ISymmSection) = s.Ix
Iy(s::ISymmSection) = s.Iy
Sx(s::ISymmSection) = s.Sx
Sy(s::ISymmSection) = s.Sy

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

# Fire protection perimeters (AISC Design Guide 19)
# PB = full contour perimeter (4-sided exposure, columns)
# PA = PB minus one flange surface (3-sided exposure, beams: top flange against deck)
#
# Fillet correction: at each of the 4 re-entrant web-flange corners, a quarter-
# circle fillet (radius r = kdes - tf) replaces the sharp 90° corner. Each fillet
# changes the perimeter by r(π/2 - 2) ≈ −0.429r (the arc is shorter than the
# two straight segments it replaces). With 4 fillets:
#   PB = 2d + 4bf − 2tw + 4r(π/2 − 2)
#   PA = PB − bf
#
# When kdes = tf (i.e. r = 0), this recovers the thin-wall approximation.
function compute_PB(d, bf, tw, tf, kdes)
    r = kdes - tf        # fillet radius (zero when kdes == tf)
    r = max(r, zero(r))  # guard against kdes < tf
    return 2 * d + 4 * bf - 2 * tw + 4 * r * (π / 2 - 2)
end
compute_PA(d, bf, tw, tf, kdes) = compute_PB(d, bf, tw, tf, kdes) - bf

function compute_all_properties(d, bf, tw, tf; kdes=tf)
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
    PA  = compute_PA(d, bf, tw, tf, kdes)
    PB  = compute_PB(d, bf, tw, tf, kdes)
    return (; h, ho, λ_f, λ_w, d_tw, Aw, Af, A, Ix, Iy, Iyc, J, Cw, Sx, Sy, Zx, Zy, rx, ry, rts, kdes, PA, PB)
end

"""2D outline coordinates for plotting."""
function get_coords(d, bf, tw, tf)
    return [
        [-bf/2, 0], [bf/2, 0], [bf/2, -tf], [tw/2, -tf],
        [tw/2, -(d - tf)], [bf/2, -(d - tf)], [bf/2, -d], [-bf/2, -d],
        [-bf/2, -(d - tf)], [-tw/2, -(d - tf)], [-tw/2, -tf], [-bf/2, -tf], [-bf/2, 0]
    ]
end
