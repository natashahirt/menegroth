# Deck sheet: web shear (AISI S100-16 §G2), web crippling from the Vulcraft
# reaction tables, gage from the unshored-span tables, and the catalog's
# composite-slab moment and shear. The flat width of a web is not on the
# nominal-dimension figure, so §G2.1 and §G5 are not evaluated from that
# figure. Gage selection reads the published clear span. A support reaction
# is checked against the published Rn/Ω when the caller supplies one.

# AISI S100-16 nomenclature: E = 29,500 ksi at §A3.1.3, Poisson's ratio = 0.30
# (corpus: aisi-s100-16, PDF p. 26).
const _AISI_E_KSI = 29500.0
const _AISI_MU = 0.30

"""
    aisi_web_shear(h, t, Fy; kv=5.34) -> NamedTuple

Nominal shear strength of one web with no holes and no transverse stiffeners.

AISI S100-16 §G2.1 and §G2.3 (corpus: aisi-s100-16, PDF pp. 114–116,
printed pp. 59–61):

    Vy = 0.6 Aw Fy,  Aw = h t                         (Eq. G2.1-5, G2.1-6)
    Fcr = π² E kv / (12 (1 − μ²) (h/t)²)              (Eq. G2.3-2)
    λv = √(Vy / Vcr),  Vcr = Aw Fcr                   (Eq. G2.1-4, G2.3-1)
    λv ≤ 0.815              → Vn = Vy                 (Eq. G2.1-1)
    0.815 < λv ≤ 1.227      → Vn = 0.815 √(Vcr Vy)    (Eq. G2.1-2a)
    λv > 1.227              → Vn = Vcr                (Eq. G2.1-3a)

`h` is the depth of the flat portion of the web, measured along the web.
`kv` defaults to 5.34, the value §G2.3(a) gives for an unreinforced web.
`E` is 29,500 ksi and `μ` is 0.30.

`Ωv = 1.60` and `φv = 0.95` are the §G2 factors for a flexural member that
meets §B4. `Vn` does not use them. SDI C-2017 Eq. 2.4.7a takes this nominal
strength (two webs, one pitch) as `VD` and applies its own `φs`.
"""
function aisi_web_shear(h, t, Fy; kv::Real=5.34)
    h_in = ustrip(u"inch", uconvert(u"inch", h))
    t_in = ustrip(u"inch", uconvert(u"inch", t))
    Fy_ksi = ustrip(u"ksi", uconvert(u"ksi", Fy))
    h_in > 0 || throw(ArgumentError("Flat web depth h must be positive."))
    t_in > 0 || throw(ArgumentError("Web thickness t must be positive."))
    Fy_ksi > 0 || throw(ArgumentError("Fy must be positive."))
    kv > 0 || throw(ArgumentError("kv must be positive."))
    Aw = h_in * t_in
    Vy = 0.6 * Aw * Fy_ksi
    # Eq. G2.3-2. 1 − μ² = 0.91 for μ = 0.30.
    Fcr = (π^2 * _AISI_E_KSI * kv) / (12 * (1 - _AISI_MU^2) * (h_in / t_in)^2)
    Vcr = Aw * Fcr
    λv = sqrt(Vy / Vcr)
    if λv <= 0.815
        Vn = Vy
        branch = :yield
    elseif λv <= 1.227
        Vn = 0.815 * sqrt(Vcr * Vy)
        branch = :inelastic
    else
        Vn = Vcr
        branch = :elastic
    end
    return (;
        Vn = Vn * u"kip",
        Vy = Vy * u"kip",
        Vcr = Vcr * u"kip",
        λv = λv,
        branch = branch,
        kv = Float64(kv),
        Ωv = 1.60,
        ϕv = 0.95,
    )
end

# ASD section properties, Vulcraft Deck Solutions (April 2020 sheets in the
# September 2020 catalog). Grade 50. Per foot of deck width.
# Corpus: vulcraft-deck-solutions-2020.
#   1.5VL PDF p. 80, 2VLI PDF p. 88, 3VLI PDF p. 92.
# Fields, in catalog units: I+ and I− (in⁴/ft), Se+ and Se− (in³/ft),
# Mn+/Ω and Mn−/Ω (lb-ft/ft), Vn/Ω (lb/ft).
const _DECK_GAGE_ASD = Dict(
    "1.5VL" => Dict(
        22 => (Ipos=0.155, Ineg=0.178, Spos=0.169, Sneg=0.179, Mpos=422.0, Mneg=447.0, V=2654.0),
        20 => (Ipos=0.197, Ineg=0.217, Spos=0.224, Sneg=0.229, Mpos=559.0, Mneg=571.0, V=3207.0),
        19 => (Ipos=0.239, Ineg=0.257, Spos=0.266, Sneg=0.278, Mpos=663.0, Mneg=693.0, V=3728.0),
        18 => (Ipos=0.277, Ineg=0.290, Spos=0.306, Sneg=0.318, Mpos=763.0, Mneg=793.0, V=4209.0),
        16 => (Ipos=0.364, Ineg=0.367, Spos=0.393, Sneg=0.402, Mpos=981.0, Mneg=1003.0, V=5261.0),
    ),
    "2VLI" => Dict(
        22 => (Ipos=0.324, Ineg=0.324, Spos=0.244, Sneg=0.255, Mpos=609.0, Mneg=637.0, V=1641.0),
        20 => (Ipos=0.409, Ineg=0.407, Spos=0.326, Sneg=0.337, Mpos=813.0, Mneg=841.0, V=2419.0),
        19 => (Ipos=0.490, Ineg=0.488, Spos=0.409, Sneg=0.421, Mpos=1020.0, Mneg=1050.0, V=2863.0),
        18 => (Ipos=0.557, Ineg=0.557, Spos=0.485, Sneg=0.500, Mpos=1210.0, Mneg=1247.0, V=3240.0),
        16 => (Ipos=0.703, Ineg=0.703, Spos=0.643, Sneg=0.652, Mpos=1604.0, Mneg=1627.0, V=4069.0),
    ),
    "3VLI" => Dict(
        22 => (Ipos=0.732, Ineg=0.737, Spos=0.387, Sneg=0.410, Mpos=966.0, Mneg=1023.0, V=1407.0),
        20 => (Ipos=0.919, Ineg=0.921, Spos=0.512, Sneg=0.539, Mpos=1277.0, Mneg=1345.0, V=2485.0),
        19 => (Ipos=1.099, Ineg=1.101, Spos=0.639, Sneg=0.669, Mpos=1595.0, Mneg=1669.0, V=3389.0),
        18 => (Ipos=1.253, Ineg=1.253, Spos=0.761, Sneg=0.794, Mpos=1899.0, Mneg=1981.0, V=4361.0),
        16 => (Ipos=1.580, Ineg=1.580, Spos=1.013, Sneg=1.013, Mpos=2528.0, Mneg=2528.0, V=6126.0),
    ),
)

# Maximum unshored construction clear span, normal-weight concrete, 145 pcf.
# Vulcraft Deck Solutions, April 2020 sheets.
#   1.5VL PDF p. 81, 2VLI PDF p. 89, 3VLI PDF p. 93.
# total slab depth [in] => topping [in], and gage => (1 span, 2 spans, 3 spans)
# in inches. The catalog note says these spans do not consider web crippling.
_fi(ft, inn) = ft * 12 + inn

const _UNSHORED_SPAN_145 = Dict(
    "1.5VL" => Dict(
        3.5 => (topping=2.0, spans=Dict(
            22 => (_fi(6, 5), _fi(7, 6), _fi(7, 8)),
            20 => (_fi(7, 9), _fi(9, 1), _fi(9, 2)),
            19 => (_fi(8, 4), _fi(9, 11), _fi(10, 3)),
            18 => (_fi(8, 9), _fi(10, 7), _fi(11, 0)),
            16 => (_fi(9, 6), _fi(11, 10), _fi(11, 8)))),
        5.0 => (topping=3.5, spans=Dict(
            22 => (_fi(5, 7), _fi(6, 7), _fi(6, 8)),
            20 => (_fi(6, 9), _fi(7, 10), _fi(7, 11)),
            19 => (_fi(7, 3), _fi(8, 8), _fi(8, 10)),
            18 => (_fi(7, 8), _fi(9, 3), _fi(9, 6)),
            16 => (_fi(8, 4), _fi(10, 4), _fi(10, 4)))),
        6.0 => (topping=4.5, spans=Dict(
            22 => (_fi(5, 3), _fi(6, 1), _fi(6, 2)),
            20 => (_fi(6, 3), _fi(7, 3), _fi(7, 5)),
            19 => (_fi(6, 10), _fi(8, 0), _fi(8, 2)),
            18 => (_fi(7, 2), _fi(8, 7), _fi(8, 10)),
            16 => (_fi(7, 10), _fi(9, 7), _fi(9, 8)))),
    ),
    "2VLI" => Dict(
        4.0 => (topping=2.0, spans=Dict(
            22 => (_fi(7, 10), _fi(9, 1), _fi(9, 3)),
            20 => (_fi(9, 5), _fi(10, 5), _fi(10, 9)),
            19 => (_fi(10, 1), _fi(11, 7), _fi(12, 0)),
            18 => (_fi(10, 6), _fi(12, 8), _fi(12, 7)),
            16 => (_fi(11, 4), _fi(14, 1), _fi(13, 3)))),
        5.5 => (topping=3.5, spans=Dict(
            22 => (_fi(6, 11), _fi(7, 11), _fi(8, 1)),
            20 => (_fi(8, 3), _fi(9, 2), _fi(9, 5)),
            19 => (_fi(9, 0), _fi(10, 2), _fi(10, 6)),
            18 => (_fi(9, 4), _fi(11, 1), _fi(11, 6)),
            16 => (_fi(10, 1), _fi(12, 8), _fi(12, 1)))),
        6.5 => (topping=4.5, spans=Dict(
            22 => (_fi(6, 5), _fi(7, 4), _fi(7, 7)),
            20 => (_fi(7, 8), _fi(8, 6), _fi(8, 9)),
            19 => (_fi(8, 5), _fi(9, 6), _fi(9, 10)),
            18 => (_fi(8, 9), _fi(10, 4), _fi(10, 8)),
            16 => (_fi(9, 6), _fi(11, 9), _fi(11, 7)))),
    ),
    "3VLI" => Dict(
        5.0 => (topping=2.0, spans=Dict(
            22 => (_fi(10, 0), _fi(10, 9), _fi(11, 1)),
            20 => (_fi(11, 9), _fi(12, 6), _fi(12, 11)),
            19 => (_fi(12, 3), _fi(13, 11), _fi(14, 5)),
            18 => (_fi(12, 8), _fi(15, 2), _fi(14, 10)),
            16 => (_fi(13, 4), _fi(16, 8), _fi(15, 8)))),
        6.5 => (topping=3.5, spans=Dict(
            22 => (_fi(8, 10), _fi(8, 7), _fi(9, 9)),
            20 => (_fi(10, 5), _fi(11, 1), _fi(11, 5)),
            19 => (_fi(11, 4), _fi(12, 4), _fi(12, 9)),
            18 => (_fi(11, 8), _fi(13, 6), _fi(13, 8)),
            16 => (_fi(12, 4), _fi(15, 2), _fi(14, 6)))),
        7.5 => (topping=4.5, spans=Dict(
            22 => (_fi(8, 3), _fi(7, 6), _fi(8, 6)),
            20 => (_fi(9, 8), _fi(10, 4), _fi(10, 8)),
            19 => (_fi(10, 9), _fi(11, 7), _fi(11, 11)),
            18 => (_fi(11, 2), _fi(12, 7), _fi(13, 0)),
            16 => (_fi(11, 10), _fi(14, 3), _fi(13, 11)))),
    ),
)

# Allowable web-crippling reactions Rn/Ω, lb/ft.
# Vulcraft Deck Solutions, April 2020 sheets (corpus: vulcraft-deck-solutions-2020).
#   1.5VL PDF p. 80, 2VLI PDF p. 88, 3VLI PDF p. 92.
# SDI C-2017 §2.4.A.6 (corpus: sdi-c-2017, PDF p. 10) sends the bearing check
# to AISI S100. These sheets print the allowable reaction instead. Bearing
# lengths are not interpolated.
const _BEARING_GAGES = (22, 20, 19, 18, 16)

"""Columns of Rn/Ω. `rows` follow `_BEARING_GAGES`; each row follows `bearings`."""
function _bearing_columns(bearings, rows)
    length(rows) == length(_BEARING_GAGES) || error("web-crippling table is missing a gage")
    return Dict(bearings[j] => Dict(_BEARING_GAGES[i] => rows[i][j] for i in eachindex(_BEARING_GAGES))
                for j in eachindex(bearings))
end

const _WEB_CRIPPLING = let
    e4 = (1.5, 2.0, 3.0, 4.0)
    Dict(
        "1.5VL" => Dict(
            (:one, :end) => _bearing_columns(e4, (
                (807, 887, 1021, 1115),
                (1153, 1263, 1448, 1574),
                (1532, 1674, 1913, 2071),
                (1931, 2105, 2398, 2588),
                (2958, 3212, 3639, 3900))),
            (:one, :interior) => _bearing_columns((3.0, 4.0), (
                (1482, 1602), (2127, 2289), (2839, 3043), (3586, 3831), (5517, 5855))),
            (:two, :end) => _bearing_columns(e4, (
                (842, 908, 1017, 1093),
                (1274, 1368, 1525, 1632),
                (1766, 1891, 2100, 2239),
                (2297, 2454, 2716, 2887),
                (3713, 3950, 4347, 4590))),
            (:two, :interior) => _bearing_columns((3.0, 4.0), (
                (1834, 1994), (2662, 2881), (3579, 3859), (4546, 4884), (7050, 7523))),
        ),
        "2VLI" => Dict(
            (:one, :end) => _bearing_columns(e4, (
                (363, 399, 460, 511),
                (522, 571, 655, 726),
                (696, 761, 869, 960),
                (879, 959, 1092, 1205),
                (1354, 1470, 1666, 1830))),
            (:one, :interior) => _bearing_columns((4.0, 6.0), (
                (767, 882), (1098, 1257), (1462, 1667), (1843, 2095), (2825, 3194))),
            (:two, :end) => _bearing_columns(e4, (
                (362, 390, 437, 476),
                (554, 595, 663, 721),
                (775, 829, 921, 998),
                (1013, 1082, 1198, 1296),
                (1654, 1759, 1936, 2085))),
            (:two, :interior) => _bearing_columns((4.0, 6.0), (
                (924, 1071), (1342, 1550), (1805, 2078), (2292, 2631), (3554, 4059))),
        ),
        "3VLI" => Dict(
            (:one, :end) => _bearing_columns(e4, (
                (353, 388, 446, 496),
                (510, 559, 640, 709),
                (683, 747, 853, 943),
                (866, 944, 1075, 1186),
                (1339, 1455, 1648, 1811))),
            (:one, :interior) => _bearing_columns((4.0, 8.0), (
                (783, 910), (1121, 1388), (1493, 1879), (1881, 2356), (2884, 3579))),
            (:two, :end) => _bearing_columns(e4, (
                (333, 359, 402, 439),
                (518, 556, 620, 674),
                (731, 783, 869, 942),
                (963, 1028, 1138, 1231),
                (1589, 1690, 1860, 2003))),
            (:two, :interior) => _bearing_columns((4.0, 8.0), (
                (910, 1068), (1328, 1668), (1792, 2291), (2279, 2900), (3546, 4474))),
        ),
    )
end

# Finished composite slab, ASD, normal-weight concrete, 145 pcf.
# Same sheets as the unshored spans: 1.5VL PDF p. 81, 2VLI PDF p. 89, 3VLI PDF p. 93.
# Per gage: concrete-plus-deck weight (psf), Id (in⁴/ft), Mno/Ω (kip-ft/ft), Vno/Ω (kip/ft).
_slab_gages(rows) = Dict(_BEARING_GAGES[i] =>
    (w=rows[i][1], I=rows[i][2], M=rows[i][3], V=rows[i][4]) for i in eachindex(_BEARING_GAGES))

const _SLAB_ASD_145 = Dict(
    "1.5VL" => Dict(
        3.5 => (topping=2.0, gages=_slab_gages((
            (32.2, 2.64, 1.84, 2.01), (32.6, 2.85, 2.16, 2.01),
            (32.9, 3.03, 2.47, 2.01), (33.2, 3.19, 2.74, 2.01),
            (33.9, 3.52, 3.30, 2.01)))),
        5.0 => (topping=3.5, gages=_slab_gages((
            (50.3, 7.62, 3.22, 3.29), (50.7, 8.18, 3.83, 3.29),
            (51.0, 8.68, 4.40, 3.29), (51.3, 9.12, 4.90, 3.29),
            (52.0, 10.02, 6.00, 3.29)))),
        6.0 => (topping=4.5, gages=_slab_gages((
            (62.4, 13.11, 4.24, 4.27), (62.8, 14.02, 5.05, 4.27),
            (63.1, 14.85, 5.81, 4.27), (63.4, 15.57, 6.50, 4.27),
            (64.1, 17.06, 7.98, 4.27)))),
    ),
    "2VLI" => Dict(
        4.0 => (topping=2.0, gages=_slab_gages((
            (37.9, 4.14, 2.41, 3.03), (38.2, 4.43, 2.86, 3.07),
            (38.5, 4.68, 3.27, 3.07), (38.8, 4.92, 3.64, 3.07),
            (39.5, 5.39, 4.43, 3.07)))),
        5.5 => (topping=3.5, gages=_slab_gages((
            (56.0, 10.32, 3.46, 3.84), (56.3, 11.00, 4.12, 4.55),
            (56.6, 11.60, 4.73, 4.67), (56.9, 12.14, 5.28, 4.67),
            (57.6, 13.25, 6.47, 4.67)))),
        6.5 => (topping=4.5, gages=_slab_gages((
            (68.1, 16.78, 4.40, 4.44), (68.4, 17.83, 5.26, 5.15),
            (68.7, 18.77, 6.05, 5.55), (69.0, 19.61, 6.77, 5.87),
            (69.7, 21.36, 7.91, 5.87)))),
    ),
    "3VLI" => Dict(
        5.0 => (topping=2.0, gages=_slab_gages((
            (44.0, 7.54, 3.47, 3.16), (44.4, 8.04, 4.13, 3.74),
            (44.7, 8.49, 4.73, 3.74), (45.0, 8.89, 5.28, 3.74),
            (45.8, 9.72, 6.45, 3.74)))),
        6.5 => (topping=3.5, gages=_slab_gages((
            (62.1, 15.94, 4.57, 3.94), (62.5, 16.93, 5.45, 4.93),
            (62.8, 17.82, 6.26, 5.31), (63.1, 18.62, 7.00, 5.31),
            (63.9, 20.27, 8.57, 5.31)))),
        7.5 => (topping=4.5, gages=_slab_gages((
            (74.2, 24.12, 5.36, 4.52), (74.6, 25.57, 6.40, 5.51),
            (74.9, 26.87, 7.36, 6.33), (75.2, 28.04, 8.24, 6.47),
            (76.0, 30.47, 10.12, 6.47)))),
    ),
)

function _deck_key(profile::CompositeDeckProfile)
    haskey(_DECK_GAGE_ASD, profile.name) || throw(ArgumentError(
        "No ASD deck sheet table is entered for profile $(profile.name)."))
    return profile.name
end

function _require_gage(profile::CompositeDeckProfile, gage::Integer)
    g = Int(gage)
    haskey(profile.gages, g) || throw(ArgumentError(
        "Gage $g is not a listed gage of $(profile.name)."))
    return g
end

"""
    deck_gage_section(profile, gage) -> NamedTuple

ASD section properties of one deck gage, per foot of width, from the Vulcraft
composite-deck sheet (corpus: vulcraft-deck-solutions-2020; 1.5VL PDF p. 80,
2VLI PDF p. 88, 3VLI PDF p. 92). `Fy` is 50 ksi on each of those sheets.

`Mn_positive_over_Ω` and `Mn_negative_over_Ω` are the catalog's allowable
moments in pound-feet per foot, returned as a force. `Vn_over_Ω` is the
catalog's allowable vertical web shear per foot.
"""
function deck_gage_section(profile::CompositeDeckProfile, gage::Integer)
    g = _require_gage(profile, gage)
    row = _DECK_GAGE_ASD[_deck_key(profile)][g]
    metal = profile.gages[g]
    return (;
        gage = g,
        Fy = 50.0u"ksi",
        thickness = metal.t,
        weight = metal.w_dd,
        I_positive = row.Ipos * u"inch^4/ft",
        I_negative = row.Ineg * u"inch^4/ft",
        S_positive = row.Spos * u"inch^3/ft",
        S_negative = row.Sneg * u"inch^3/ft",
        Mn_positive_over_Ω = row.Mpos * u"lbf*ft/ft",
        Mn_negative_over_Ω = row.Mneg * u"lbf*ft/ft",
        Vn_over_Ω = row.V * u"lbf/ft",
    )
end

"""
    deck_pitch_nominal_web_shear(profile, gage) -> Force

Nominal shear strength of the deck webs on one pitch. This is `VD` in
SDI C-2017 Eq. 2.4.7a (corpus: sdi-c-2017, PDF p. 13).

The catalog column is `Vn/Ω` per foot of width (corpus:
vulcraft-deck-solutions-2020). AISI S100-16 §G2 sets `Ωv = 1.60` for a
flexural member that meets §B4 (corpus: aisi-s100-16, PDF p. 114). The
sheets say the tables conform to ANSI/SDI C-2017, and §2.4.A.1 of that
standard (PDF p. 8) computes the deck section by AISI S100. Nominal shear
per foot is the printed allowable times 1.60. One pitch then takes
`pitch / 1 ft` of that value. The flat web width is not required and is
not inferred.
"""
function deck_pitch_nominal_web_shear(profile::CompositeDeckProfile, gage::Integer)
    section = deck_gage_section(profile, gage)
    # §G2: Ωv = 1.60 where §B4 is met.
    per_length = section.Vn_over_Ω * 1.60
    return per_length * profile.pitch
end

"""
    deck_one_way_shear(profile, gage, t_slab, fc, wc; design=:lrfd) -> NamedTuple

One-way shear of the finished slab on one pitch, with `VD` taken from
[`deck_pitch_nominal_web_shear`](@ref). `Ac` is Figure 2-1.
"""
function deck_one_way_shear(profile::CompositeDeckProfile, gage::Integer, t_slab, fc, wc;
        design::Symbol=:lrfd)
    Ac = deck_shear_concrete_area(profile, t_slab)
    VD = deck_pitch_nominal_web_shear(profile, gage)
    return deck_one_way_shear(fc, Ac, wc; VD, design)
end

function _tabulated_inch(value, keys)
    inches = ustrip(u"inch", uconvert(u"inch", value))
    for key in keys
        abs(inches - key) <= 1 / 32 && return key
    end
    return nothing
end

"""
    deck_web_crippling(profile, gage; flanges, location, bearing) -> Force per length

Allowable web-crippling reaction `Rn/Ω` per foot of deck width.

`flanges` is `:one` or `:two` (the sheet's One-Flange and Two-Flange Loading).
`location` is `:end` or `:interior`. `bearing` must be a length printed for
that profile and location. SDI C-2017 §2.4.A.6 (corpus: sdi-c-2017, PDF p. 10)
requires the check. The number is the Vulcraft reaction table (corpus:
vulcraft-deck-solutions-2020, PDF pp. 80, 88, 92), not a §G5 calculation.
"""
function deck_web_crippling(profile::CompositeDeckProfile, gage::Integer;
        flanges::Symbol, location::Symbol, bearing)
    flanges in (:one, :two) || throw(ArgumentError(
        "flanges must be :one or :two, the sheet's One-Flange and Two-Flange columns."))
    location in (:end, :interior) || throw(ArgumentError(
        "location must be :end or :interior."))
    g = _require_gage(profile, gage)
    columns = _WEB_CRIPPLING[_deck_key(profile)][(flanges, location)]
    key = _tabulated_inch(bearing, keys(columns))
    if key === nothing
        listed = join(sort(collect(keys(columns))), ", ")
        throw(ArgumentError(
            "Bearing $(ustrip(u"inch", uconvert(u"inch", bearing))) in is not tabulated " *
            "for $(profile.name) $(flanges)-flange $(location) bearing. " *
            "Tabulated lengths, inches: $listed. Lengths are not interpolated."))
    end
    return columns[key][g] * u"lbf/ft"
end

"""
    composite_slab_catalog(profile, total_depth, gage) -> NamedTuple

ASD strength of the finished composite slab at a tabulated total depth, from
the Vulcraft normal-weight sheets (corpus: vulcraft-deck-solutions-2020;
1.5VL PDF p. 81, 2VLI PDF p. 89, 3VLI PDF p. 93).

`Mno_over_Ω` is the allowable moment in kip-feet per foot. `Vno_over_Ω` is
the allowable shear per foot. Both are the printed ASD values. `topping` is
the concrete thickness above the deck on that row, which is `t_slab` for
Figure 2-1.
"""
function composite_slab_catalog(profile::CompositeDeckProfile, total_depth, gage::Integer)
    g = _require_gage(profile, gage)
    table = _SLAB_ASD_145[_deck_key(profile)]
    key = _tabulated_inch(total_depth, keys(table))
    if key === nothing
        depths = join(sort(collect(keys(table))), ", ")
        throw(ArgumentError(
            "Total slab depth is not tabulated for $(profile.name) at 145 lb/ft³. " *
            "Tabulated total depths, inches: $depths."))
    end
    row = table[key]
    cell = row.gages[g]
    return (;
        gage = g,
        topping = row.topping * u"inch",
        weight = cell.w * u"psf",
        I_d = cell.I * u"inch^4/ft",
        Mno_over_Ω = cell.M * u"kip*ft/ft",
        Vno_over_Ω = cell.V * u"kip/ft",
    )
end

"""
    deck_slab_shear_report(profile, total_depth, gage, fc, wc) -> NamedTuple

Finished-slab shear from two sources, kept in the design method each one uses.

`catalog_V_over_Ω` and `catalog_M_over_Ω` are the ASD catalog values.
`ϕVn_per_length` is LRFD Eq. 2.4.7a (corpus: sdi-c-2017, PDF p. 13) per foot
of width, with `Ac` from Figure 2-1 on the topping of that catalog row and
`VD` from the deck webs. The two shears are not converted into each other.
"""
function deck_slab_shear_report(profile::CompositeDeckProfile, total_depth, gage::Integer, fc, wc)
    slab = composite_slab_catalog(profile, total_depth, gage)
    computed = deck_one_way_shear(profile, gage, slab.topping, fc, wc)
    return (;
        topping = slab.topping,
        catalog_M_over_Ω = slab.Mno_over_Ω,
        catalog_V_over_Ω = slab.Vno_over_Ω,
        catalog_design = :asd,
        ϕVn_per_length = computed.capacity / profile.pitch,
        computed_design = computed.design,
        computed = computed,
    )
end

function deck_web_crippling(name::AbstractString, gage::Integer; kwargs...)
    return deck_web_crippling(composite_deck_profile(name), gage; kwargs...)
end

function composite_slab_catalog(name::AbstractString, total_depth, gage::Integer)
    return composite_slab_catalog(composite_deck_profile(name), total_depth, gage)
end

function deck_slab_shear_report(name::AbstractString, total_depth, gage::Integer, fc, wc)
    return deck_slab_shear_report(composite_deck_profile(name), total_depth, gage, fc, wc)
end

function _unshored_row(profile::CompositeDeckProfile, total_depth)
    table = _UNSHORED_SPAN_145[_deck_key(profile)]
    d_in = ustrip(u"inch", uconvert(u"inch", total_depth))
    for (depth, row) in table
        abs(d_in - depth) <= 1 / 32 && return row
    end
    depths = join(sort(collect(keys(table))), ", ")
    throw(ArgumentError(
        "Total slab depth $(d_in) in is not a tabulated depth for $(profile.name) " *
        "at 145 lb/ft³. Tabulated total depths, inches: $depths. " *
        "Depths are not interpolated."))
end

"""
    select_unshored_deck_gage(profile, total_depth, clear_span, n_spans;
                              concrete_density=145lb/ft³,
                              bearing_length=nothing, flanges=nothing,
                              end_reaction=nothing, interior_reaction=nothing) -> NamedTuple

Lightest listed gage whose published maximum unshored clear span is at least
`clear_span`.

The spans are the Vulcraft normal-weight (145 pcf) tables (corpus:
vulcraft-deck-solutions-2020; 1.5VL PDF p. 81, 2VLI PDF p. 89, 3VLI PDF
p. 93). `n_spans` is 1, 2, or 3, the table's construction clear-span columns.
The lightest gage is the one with the smallest catalog deck weight.

Leave the bearing arguments unset and the span table is used alone.
`web_crippling_checked` is then false, which is what the catalog note says
about those spans. Set `bearing_length`, `flanges` (`:one` or `:two`), and
`end_reaction` to also require `Rn/Ω` at each end. Two or three spans also
require `interior_reaction`. Reactions are per foot of deck width. A gage
that meets the span and misses a reaction is not selected.
"""
function select_unshored_deck_gage(profile::CompositeDeckProfile, total_depth, clear_span,
        n_spans::Integer; concrete_density=145.0u"lb/ft^3",
        bearing_length=nothing, flanges=nothing,
        end_reaction=nothing, interior_reaction=nothing)
    n = Int(n_spans)
    n in 1:3 || throw(ArgumentError(
        "n_spans must be 1, 2, or 3, matching the catalog columns, got $n."))
    ρ = uconvert(u"lb/ft^3", concrete_density)
    abs(ρ - 145.0u"lb/ft^3") <= 0.5u"lb/ft^3" || throw(ArgumentError(
        "Only the 145 lb/ft³ unshored-span table is entered. " *
        "Got $(ρ). The 110 lb/ft³ table is in the catalog and is not used here."))
    check_bearing = any(!isnothing, (bearing_length, flanges, end_reaction, interior_reaction))
    if check_bearing
        (bearing_length === nothing || flanges === nothing || end_reaction === nothing) &&
            throw(ArgumentError(
                "A bearing check needs bearing_length, flanges (:one or :two), and end_reaction."))
        n == 1 && interior_reaction !== nothing && throw(ArgumentError(
            "A single span has no interior support, so interior_reaction is not used."))
        n > 1 && interior_reaction === nothing && throw(ArgumentError(
            "Two or three spans need interior_reaction as well as end_reaction."))
    end
    row = _unshored_row(profile, total_depth)
    need = ustrip(u"inch", uconvert(u"inch", clear_span))
    need > 0 || throw(ArgumentError("Clear span must be positive."))
    end_need = check_bearing ? uconvert(u"lbf/ft", end_reaction) : nothing
    interior_need = (check_bearing && n > 1) ? uconvert(u"lbf/ft", interior_reaction) : nothing
    fitting = Int[]
    span_ok = Int[]
    longest = 0.0
    for (gage, spans) in row.spans
        limit = spans[n]
        limit > longest && (longest = limit)
        limit + 1e-9 >= need || continue
        push!(span_ok, gage)
        if check_bearing
            end_cap = deck_web_crippling(profile, gage; flanges, location=:end, bearing=bearing_length)
            end_need <= end_cap || continue
            if n > 1
                interior_cap = deck_web_crippling(profile, gage;
                    flanges, location=:interior, bearing=bearing_length)
                interior_need <= interior_cap || continue
            end
        end
        push!(fitting, gage)
    end
    blank = (;
        ok = false,
        gage = nothing,
        thickness = nothing,
        weight = nothing,
        span_limit = longest * u"inch",
        n_spans = n,
        topping = row.topping * u"inch",
        web_crippling_checked = check_bearing,
        reason = isempty(span_ok) ? :span : :bearing,
        end_Rn_over_Ω = nothing,
        interior_Rn_over_Ω = nothing,
    )
    isempty(fitting) && return blank
    gage = argmin(g -> ustrip(u"psf", profile.gages[g].w_dd), fitting)
    metal = profile.gages[gage]
    end_Rn = check_bearing ? deck_web_crippling(profile, gage;
        flanges, location=:end, bearing=bearing_length) : nothing
    interior_Rn = (check_bearing && n > 1) ? deck_web_crippling(profile, gage;
        flanges, location=:interior, bearing=bearing_length) : nothing
    return (;
        ok = true,
        gage = gage,
        thickness = metal.t,
        weight = metal.w_dd,
        span_limit = row.spans[gage][n] * u"inch",
        n_spans = n,
        topping = row.topping * u"inch",
        web_crippling_checked = check_bearing,
        reason = :ok,
        end_Rn_over_Ω = end_Rn,
        interior_Rn_over_Ω = interior_Rn,
    )
end

function select_unshored_deck_gage(name::AbstractString, total_depth, clear_span,
        n_spans::Integer; kwargs...)
    return select_unshored_deck_gage(composite_deck_profile(name), total_depth,
                                      clear_span, n_spans; kwargs...)
end
