# =============================================================================
# Tool Registry — structured metadata for agent tools + implemented provisions
#
# TOOL_REGISTRY: each entry has name, description, phase, use_when, args,
# returns, requires_design, requires_geometry. _openai_tool_specs() in chat.jl
# merges description + use_when + returns into a single OpenAI description string.
#
# IMPLEMENTED_PROVISIONS: machine-readable index of every design code clause
# the solver implements. Sourced from docs/src/reference/design_codes.md.
# =============================================================================

# ─── Implemented Provisions ───────────────────────────────────────────────────

const IMPLEMENTED_PROVISIONS = Dict{String, Any}(
    "AISC_360_16" => [
        Dict("section" => "D2",        "provision" => "Tensile yielding and rupture"),
        Dict("section" => "E3",        "provision" => "Flexural buckling without slender elements"),
        Dict("section" => "E7",        "provision" => "Members with slender elements"),
        Dict("section" => "F2",        "provision" => "Doubly symmetric compact I-shapes — yielding and LTB"),
        Dict("section" => "F3",        "provision" => "Doubly symmetric I-shapes with compact webs, noncompact flanges"),
        Dict("section" => "F4",        "provision" => "Other I-shaped members with compact or noncompact webs"),
        Dict("section" => "F5",        "provision" => "Doubly/singly symmetric I-shapes with slender webs"),
        Dict("section" => "F6",        "provision" => "I-shaped members bent about minor axis"),
        Dict("section" => "F7",        "provision" => "Square and rectangular HSS — flexure"),
        Dict("section" => "F8",        "provision" => "Round HSS — flexure"),
        Dict("section" => "G2",        "provision" => "I-shaped members — shear in web"),
        Dict("section" => "G4",        "provision" => "Rectangular HSS — shear"),
        Dict("section" => "G5",        "provision" => "Round HSS — shear"),
        Dict("section" => "G6",        "provision" => "Weak axis shear"),
        Dict("section" => "H1",        "provision" => "Combined forces — doubly and singly symmetric members"),
        Dict("section" => "H1.1",      "provision" => "P-M interaction (Eq. H1-1a, H1-1b)"),
        Dict("section" => "C2",        "provision" => "Amplified first-order analysis (B1, B2)"),
        Dict("section" => "DG9",       "provision" => "Torsional analysis of structural steel members"),
        Dict("section" => "I3.1a",     "provision" => "Composite beam — effective width"),
        Dict("section" => "I3.1b",     "provision" => "Composite beam — construction strength"),
        Dict("section" => "I3.2a",     "provision" => "Composite beam — positive flexural strength (plastic)"),
        Dict("section" => "I3.2b",     "provision" => "Composite beam — negative moment capacity"),
        Dict("section" => "I3.2c",     "provision" => "Formed metal deck — Rg/Rp factors"),
        Dict("section" => "I3.2d",     "provision" => "Composite beam — compression force Cf"),
        Dict("section" => "I8.1",      "provision" => "Stud diameter limit"),
        Dict("section" => "I8.2a",     "provision" => "Headed stud anchors — shear connector strength"),
        Dict("section" => "I8.2d",     "provision" => "Stud spacing limits"),
        Dict("section" => "C-I3.2",    "provision" => "Transformed I, lower-bound I_LB"),
        Dict("section" => "DG19",      "provision" => "Fire resistance of structural steel framing"),
    ],
    "ACI_318" => [
        Dict("section" => "6.6",       "provision" => "Second-order analysis"),
        Dict("section" => "6.6.4.4.4", "provision" => "Stiffness reduction for stability"),
        Dict("section" => "6.6.4.6.2", "provision" => "Drift limit for moment magnifier"),
        Dict("section" => "7.12.2.1",  "provision" => "Minimum shrinkage and temperature reinforcement"),
        Dict("section" => "8.4.2.3",   "provision" => "Transfer reinforcement"),
        Dict("section" => "8.6.1",     "provision" => "One-way slab minimum thickness"),
        Dict("section" => "8.7.4",     "provision" => "Structural integrity reinforcement"),
        Dict("section" => "8.7.4.2",   "provision" => "Integrity rebar at columns"),
        Dict("section" => "8.12.2",    "provision" => "Effective flange width for T-beams"),
        Dict("section" => "9.3.2",     "provision" => "Strength reduction factors"),
        Dict("section" => "9.5",       "provision" => "Beam flexure — required strength"),
        Dict("section" => "9.5(a)",    "provision" => "Minimum thickness table — beams"),
        Dict("section" => "9.5(c)",    "provision" => "Minimum thickness table — one-way slabs"),
        Dict("section" => "9.5.3.2",   "provision" => "Immediate deflection (Branson)"),
        Dict("section" => "9.5.3.3",   "provision" => "Long-term deflection multiplier"),
        Dict("section" => "9.8",       "provision" => "Two-way slab minimum thickness"),
        Dict("section" => "10.2",      "provision" => "Whitney rectangular stress block"),
        Dict("section" => "10.3.6.2",  "provision" => "Column axial capacity"),
        Dict("section" => "10.10",     "provision" => "Slenderness effects in compression members"),
        Dict("section" => "10.10.4.1", "provision" => "Moment of inertia reduction factors"),
        Dict("section" => "10.10.7",   "provision" => "Sway magnification factor"),
        Dict("section" => "11.2.1.1",  "provision" => "Concrete shear strength Vc"),
        Dict("section" => "11.4",      "provision" => "Shear reinforcement (Vs)"),
        Dict("section" => "11.11",     "provision" => "Two-way shear (punching) provisions"),
        Dict("section" => "11.11.1.2", "provision" => "Critical section for punching shear"),
        Dict("section" => "11.11.3",   "provision" => "Punching shear strength Vc"),
        Dict("section" => "11.11.3.2", "provision" => "Punching shear with moment transfer"),
        Dict("section" => "11.11.5",   "provision" => "Shear stud reinforcement"),
        Dict("section" => "11.11.5.1", "provision" => "Stud layout requirements"),
        Dict("section" => "11.11.5.2", "provision" => "Stud capacity"),
        Dict("section" => "11.11.5.4", "provision" => "Maximum spacing of studs"),
        Dict("section" => "12.13",     "provision" => "Development of reinforcement"),
        Dict("section" => "13.1.2",    "provision" => "Two-way slab applicability limits"),
        Dict("section" => "13.2",      "provision" => "Column strip, middle strip, panel definitions"),
        Dict("section" => "13.3",      "provision" => "Slab reinforcement limits"),
        Dict("section" => "13.5.3",    "provision" => "Moment transfer at columns"),
        Dict("section" => "13.6",      "provision" => "Direct Design Method (DDM)"),
        Dict("section" => "13.6.2.2",  "provision" => "DDM limitations"),
        Dict("section" => "13.6.3",    "provision" => "DDM total static moment Mo"),
        Dict("section" => "13.6.4",    "provision" => "DDM moment distribution to strips"),
        Dict("section" => "13.7",      "provision" => "Equivalent Frame Method (EFM)"),
        Dict("section" => "13.7.3",    "provision" => "EFM slab-beam stiffness"),
        Dict("section" => "13.7.4",    "provision" => "EFM column stiffness"),
        Dict("section" => "13.7.5",    "provision" => "EFM equivalent column stiffness (torsional members)"),
        Dict("section" => "13.7.6",    "provision" => "EFM loading and analysis"),
        Dict("section" => "13.7.6.2",  "provision" => "Pattern loading threshold (L/D)"),
        Dict("section" => "13.7.7.1",  "provision" => "EFM moment redistribution"),
        Dict("section" => "22.4",      "provision" => "Column P-M interaction"),
        Dict("section" => "22.5",      "provision" => "Shear strength"),
        Dict("section" => "22.5.6.1",  "provision" => "Vc with axial compression"),
        Dict("section" => "22.6",      "provision" => "Punching shear"),
        Dict("section" => "22.7",      "provision" => "Torsion"),
        Dict("section" => "24.2",      "provision" => "Deflection control"),
        Dict("section" => "T7.3.1.1",  "provision" => "Minimum slab thickness table"),
        Dict("section" => "T9.5(a)",   "provision" => "Minimum beam depth table"),
    ],
    "ACI_216_1" => [
        Dict("section" => "T4.2",      "provision" => "Minimum slab thickness for fire rating"),
        Dict("section" => "T4.3.1.1",  "provision" => "Minimum slab cover for fire rating"),
        Dict("section" => "T4.3.1.2",  "provision" => "Minimum beam cover for fire rating"),
        Dict("section" => "T4.5.1a",   "provision" => "Minimum column dimension for fire rating"),
        Dict("section" => "4.5.3",     "provision" => "Column cover for fire rating"),
    ],
    "ACI_336_2R" => [
        Dict("section" => "3.3.2",     "provision" => "Mat bearing pressure distribution"),
        Dict("section" => "4.2",       "provision" => "Allowable bearing pressure"),
        Dict("section" => "6.1.2",     "provision" => "Flexural design of mat"),
        Dict("section" => "6.4",       "provision" => "Punching shear for mat"),
        Dict("section" => "6.7",       "provision" => "One-way shear for mat"),
        Dict("section" => "6.9",       "provision" => "Minimum mat thickness"),
    ],
    "ASCE_7" => [
        Dict("section" => "2.3.1",     "provision" => "LRFD load combinations"),
    ],
    "UL" => [
        Dict("section" => "X772",      "provision" => "SFRM thickness for steel members"),
        Dict("section" => "N643",      "provision" => "Intumescent coating thickness"),
    ],
    "fib_MC2010" => [
        Dict("section" => "5.6.3",     "provision" => "Residual strength parameters (fR1, fR3 from CMOD)"),
        Dict("section" => "5.6.4",     "provision" => "Linear model for ultimate fiber tensile strength"),
        Dict("section" => "7.7.3.2.2", "provision" => "FRC shear capacity"),
    ],
    "NDS_2018" => [
        Dict("section" => "general",   "provision" => "Timber member design (GLT, LVL) — stub"),
        Dict("section" => "T4A_4B",    "provision" => "Reference design values — stub"),
    ],
)

"""
    get_provisions(; code::Union{String, Nothing}=nothing) -> Dict

Return implemented provisions, optionally filtered by code name.
"""
function get_provisions(; code::Union{String, Nothing}=nothing)
    if isnothing(code)
        return IMPLEMENTED_PROVISIONS
    end
    key = uppercase(replace(code, " " => "_", "-" => "_", "." => "_"))
    for k in keys(IMPLEMENTED_PROVISIONS)
        if uppercase(k) == key
            return Dict{String, Any}(k => IMPLEMENTED_PROVISIONS[k])
        end
    end
    return Dict{String, Any}(
        "error" => "unknown_code",
        "message" => "Code \"$code\" not found. Available: $(join(keys(IMPLEMENTED_PROVISIONS), ", ")).",
    )
end

