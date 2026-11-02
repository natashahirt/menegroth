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
# D and E). That table has no Ω0, Cd, moment-frame, dual, or row F entries,
# so those values rest on the rendered pages alone.
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
