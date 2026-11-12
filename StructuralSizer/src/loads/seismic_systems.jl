# ASCE 7-22 Table 12.2-1 rows for ordinary reinforced concrete.
#
# The ELF functions still take R, Cd, and Ω0 as arguments. This table is the
# lookup a caller uses instead of choosing those numbers. It is not the whole
# of Table 12.2-1.
#
# The tabulated Ω0 is returned as printed. Footnote b permits subtracting 1/2
# where Ω0 ≥ 2½ and the diaphragm is flexible. This lookup does not apply that
# reduction.

"""One ordinary-concrete row of ASCE 7-22 Table 12.2-1."""
struct OrdinaryConcreteSeismicSystem
    "Row label, such as `:F`."
    row::Symbol
    title::String
    "ASCE 7 section where the row's detailing requirements are specified."
    detailing::String
    R::Float64
    Ω0::Float64
    Cd::Float64
    "Categories whose height limit is NL. Every other category B–F is NP."
    permitted::Tuple{Vararg{Symbol}}
    "PDF page of the row."
    page::Int
end

# ASCE 7-22 Table 12.2-1 (corpus: asce-7-22). The table is an image in the
# PDF, so these values were read from the rendered pages, not from the text
# extraction. Height cells on these rows are NL or NP; there is no numeric hn.
# R and the B/C permissions of A.3 and B.6 agree with the text of Table
# 12.14-1 rows A.2 and B.5 (PDF page 201: R = 4 and 5, P in B and C, NP in
# D and E). Ω0, Cd, and rows C.7, E.8, and F were read from the rendered
# table (PDF pages 173–175, printed pages 112–114) on 2026-11-02. The
# numbers below are that reading.
const _ORDINARY_CONCRETE_SYSTEMS = Dict{Symbol, OrdinaryConcreteSeismicSystem}(
    # PDF page 173, bearing-wall systems, row A.3.
    :A3 => OrdinaryConcreteSeismicSystem(
        :A3, "bearing wall, ordinary reinforced concrete shear walls", "14.2",
        4.0, 2.5, 4.0, (:B, :C), 173),
    # PDF page 173, building-frame systems, row B.6.
    :B6 => OrdinaryConcreteSeismicSystem(
        :B6, "building frame, ordinary reinforced concrete shear walls", "14.2",
        5.0, 2.5, 4.5, (:B, :C), 173),
    # PDF page 174, moment-resisting frame systems, row C.7.
    :C7 => OrdinaryConcreteSeismicSystem(
        :C7, "ordinary reinforced concrete moment frames", "14.2",
        3.0, 3.0, 2.5, (:B,), 174),
    # PDF page 174, dual systems with intermediate moment frames, row E.8.
    :E8 => OrdinaryConcreteSeismicSystem(
        :E8, "dual system, intermediate moment frames with ordinary reinforced concrete shear walls",
        "14.2", 5.5, 2.5, 4.5, (:B, :C), 174),
    # PDF page 175, row F.
    :F => OrdinaryConcreteSeismicSystem(
        :F, "shear wall-frame interactive system with ordinary reinforced concrete moment frames and ordinary reinforced concrete shear walls",
        "12.2.5.8 and 14.2", 4.5, 2.5, 4.0, (:B,), 175),
)

"""
    ordinary_concrete_seismic_system(row, sdc) -> OrdinaryConcreteSeismicSystem

The Table 12.2-1 row named `row`, when `sdc` is one of its NL categories.

`row` is `:A3`, `:B6`, `:C7`, `:E8`, or `:F`. A category the row marks NP
throws. Category A is not a column of the table and throws.

# Citation
ASCE 7-22 Table 12.2-1 (corpus: asce-7-22, PDF pages 173–175). NL is not
limited and NP is not permitted, footnote d.
"""
function ordinary_concrete_seismic_system(row::Symbol, sdc::Symbol)
    system = get(_ORDINARY_CONCRETE_SYSTEMS, row, nothing)
    if system === nothing
        known = join(sort!(collect(keys(_ORDINARY_CONCRETE_SYSTEMS))), ", ")
        throw(ArgumentError(
            "ordinary concrete system: $row is not a Table 12.2-1 row carried " *
            "here ($known). ASCE 7-22 Table 12.2-1 (corpus: asce-7-22, PDF " *
            "pages 173-175)."))
    end
    sdc in (:B, :C, :D, :E, :F) || throw(ArgumentError(
        "ordinary concrete system: Seismic Design Category $sdc is not a " *
        "column of Table 12.2-1. The columns are B, C, D, E, and F " *
        "(corpus: asce-7-22, PDF pages 173-175)."))
    if !(sdc in system.permitted)
        throw(ArgumentError(
            "ordinary concrete system: Table 12.2-1 row $(system.row) " *
            "($(system.title)) is NP in Seismic Design Category $sdc. " *
            "ASCE 7-22 Table 12.2-1 (corpus: asce-7-22, PDF page $(system.page))."))
    end
    return system
end

"""One special reinforced-concrete shear-wall row of ASCE 7-22 Table 12.2-1."""
struct SpecialConcreteShearWallSystem
    row::Symbol
    title::String
    detailing::String
    R::Float64
    Ω0::Float64
    Cd::Float64
    "hn in feet for Seismic Design Categories D, E, and F, in that order."
    height_limit_ft::NTuple{3, Float64}
    page::Int
end

# PDF page 173, read from the rendered table on 2026-11-10. A.3 and B.6 on
# that same page are the ordinary rows already stored above (R 4 and 5,
# Ω0 2½, Cd 4 and 4.5). A.1 and B.4 are the special rows on the same page.
# B and C are NL. D, E, and F are numeric heights, not NP. Footnotes on the
# rows are not applied.
const _SPECIAL_CONCRETE_WALLS = Dict{Symbol, SpecialConcreteShearWallSystem}(
    :A1 => SpecialConcreteShearWallSystem(
        :A1, "bearing wall, special reinforced concrete shear walls", "14.2",
        5.0, 2.5, 5.0, (160.0, 160.0, 100.0), 173),
    :B4 => SpecialConcreteShearWallSystem(
        :B4, "building frame, special reinforced concrete shear walls", "14.2",
        6.0, 2.5, 5.0, (160.0, 160.0, 100.0), 173),
)

"""
    concrete_shear_wall_system(row, sdc) -> system

Table 12.2-1 row for a reinforced-concrete shear wall.

Ordinary rows `:A3`, `:B6`, `:C7`, `:E8`, and `:F` are
[`ordinary_concrete_seismic_system`](@ref). Special rows `:A1` and `:B4`
are returned for Seismic Design Categories B and C. In D, E, or F the table
permits those two rows up to the stored `hn`. The lookup still throws:
§12.12.4 sends a concrete frame member outside the system to ACI 318-19
§18.14, and the induced moments are not calculated, so §18.14.3.3 is
required and is not applied.

# Citation
ASCE 7-22 Table 12.2-1 (corpus: asce-7-22, PDF page 173), read from the
rendered page.
"""
function concrete_shear_wall_system(row::Symbol, sdc::Symbol)
    haskey(_ORDINARY_CONCRETE_SYSTEMS, row) &&
        return ordinary_concrete_seismic_system(row, sdc)
    system = get(_SPECIAL_CONCRETE_WALLS, row, nothing)
    if system === nothing
        throw(ArgumentError(
            "concrete shear wall: $row is not a Table 12.2-1 shear-wall row " *
            "carried here. ASCE 7-22 Table 12.2-1 (corpus: asce-7-22, PDF " *
            "pages 173-175)."))
    end
    sdc in (:B, :C, :D, :E, :F) || throw(ArgumentError(
        "concrete shear wall: Seismic Design Category $sdc is not a column " *
        "of Table 12.2-1. The columns are B, C, D, E, and F " *
        "(corpus: asce-7-22, PDF page $(system.page))."))
    sdc in (:B, :C) && return system
    limits = (; D = system.height_limit_ft[1], E = system.height_limit_ft[2],
              F = system.height_limit_ft[3])
    hn = getfield(limits, sdc)
    throw(ArgumentError(
        "concrete shear wall: Table 12.2-1 row $(system.row) is permitted in " *
        "Seismic Design Category $sdc up to hn = $(hn) ft (corpus: asce-7-22, " *
        "PDF page $(system.page)). ASCE 7-22 §12.12.4 (PDF page 195) requires " *
        "components outside the seismic force-resisting system to carry gravity " *
        "and the forces from δDE. A reinforced concrete frame member follows " *
        "ACI 318-19 §18.14. Induced moments from δu are not calculated, so " *
        "§18.14.3.1 requires §18.14.3.3 (corpus: aci-318-19, page 353). " *
        "That member design is not applied."))
end
