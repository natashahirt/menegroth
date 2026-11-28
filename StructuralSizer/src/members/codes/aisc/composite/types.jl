# ==============================================================================
# Composite Member Types (AISC 360-16 Chapter I)
# ==============================================================================
# Type hierarchy for slab-on-beam composite action and steel anchors.

# ==============================================================================
# Abstract Types
# ==============================================================================

"""Base type for slab-on-beam configurations (solid slab, formed deck, etc.)."""
abstract type AbstractSlabOnBeam end

"""Base type for steel anchors (headed studs, channels)."""
abstract type AbstractSteelAnchor end

# ==============================================================================
# Concrete Slab Types
# ==============================================================================

"""
    SolidSlabOnBeam <: AbstractSlabOnBeam

Solid reinforced-concrete slab on steel beam (no metal deck).

# Fields
- `t_slab`: Total slab thickness
- `fc′`:    Concrete compressive strength (28-day)
- `Ec`:     Concrete modulus of elasticity
- `wc`:     Concrete unit weight (density)
- `n`:      Modular ratio Es/Ec (precomputed for transformed section)
- `beam_spacing_left`:  Distance to adjacent beam centerline (left)
- `beam_spacing_right`: Distance to adjacent beam centerline (right)
- `edge_dist_left`:     Distance to slab edge (left), `nothing` if interior
- `edge_dist_right`:    Distance to slab edge (right), `nothing` if interior

# Notes
- `Rg = 1.0`, `Rp = 0.75` for headed studs welded directly to steel (AISC I8.2a).
- `Ac` for effective width is computed as `b_eff × t_slab`.
"""
struct SolidSlabOnBeam{T_P<:Pressure, T_D<:Density} <: AbstractSlabOnBeam
    t_slab::typeof(1.0u"m")
    fc′::T_P
    Ec::T_P
    wc::T_D
    n::Float64
    beam_spacing_left::typeof(1.0u"m")
    beam_spacing_right::typeof(1.0u"m")
    edge_dist_left::Union{typeof(1.0u"m"), Nothing}
    edge_dist_right::Union{typeof(1.0u"m"), Nothing}
end

function SolidSlabOnBeam(t_slab, fc′, Ec, wc, Es,
                         beam_spacing_left, beam_spacing_right;
                         edge_dist_left=nothing, edge_dist_right=nothing)
    n = ustrip(u"Pa", Es) / ustrip(u"Pa", Ec)
    edl = edge_dist_left  === nothing ? nothing : uconvert(u"m", edge_dist_left)
    edr = edge_dist_right === nothing ? nothing : uconvert(u"m", edge_dist_right)
    SolidSlabOnBeam(uconvert(u"m", t_slab), fc′, Ec, wc, n,
                    uconvert(u"m", beam_spacing_left),
                    uconvert(u"m", beam_spacing_right),
                    edl, edr)
end

"""
    DeckSlabOnBeam <: AbstractSlabOnBeam

Metal-deck composite slab on steel beam per AISC 360-16 §I3.2c (corpus
aisc-360-16, p. 167).

# `Ac` for crushing capacity (current implementation)

`Ac = b_eff × t_slab` is used for **both** perpendicular and parallel deck.
This is the concrete strictly *above* the top of the steel deck ribs:

- **Perpendicular deck** (§I3.2c(2)): rib concrete must be neglected, so
  excluding it is required and exact.
- **Parallel deck** (§I3.2c(3)): rib concrete *may* be included when
  `wr/hr ≥ 1.5` and the longitudinal rib is uninterrupted across the beam
  flange. Excluding it here is **conservative** (it under-reports the
  available compression block, leading to a smaller plastic neutral-axis
  shift and a smaller `Mn`). Using the rib concrete on parallel deck is a
  future enhancement; until then `t_slab` alone defines the available
  block.

In all cases `t_slab` is the concrete thickness above the deck top, and
the total slab depth above the steel flange is `hr + t_slab` (used for
the composite section's elastic neutral axis and `I_transformed`).

# Fields
- `t_slab`: Concrete thickness **above** deck ribs
- `fc′`:    Concrete compressive strength (28-day)
- `Ec`:     Concrete modulus of elasticity
- `wc`:     Concrete unit weight (density)
- `n`:      Modular ratio Es/Ec
- `hr`:     Nominal rib height
- `wr`:     Average rib width
- `deck_orientation`: `:perpendicular`, `:parallel`, or `:skewed`, classified
  from `rib_angle` (see below)
- `beam_spacing_left`, `beam_spacing_right`, `edge_dist_left`, `edge_dist_right`: as `SolidSlabOnBeam`
- `e_mid_ht`: distance from the stud shank edge to the deck web, at mid-height
  of the rib, in the load-bearing direction of the stud (AISC 360-22 §I8.2a,
  corpus: aisc-360-22, PDF p. 182). `nothing` means unknown and keeps
  `Rp = 0.6` for perpendicular deck. On skewed deck it is measured
  perpendicular to the rib, never along the beam.
- `anchorage_spacing`: spacing of the deck attachments to the supporting
  member (§I3.2c(d), PDF p. 170). `nothing` means not supplied; the limit is
  then reported as unchecked, not as passing.
- `rib_angle`: angle between the deck ribs and the beam axis, radians in
  `[0, π/2]`. `0` is parallel, `π/2` perpendicular.
- `rib_pitch`: center-to-center rib spacing measured perpendicular to the
  ribs, or `nothing` when unknown. Studs on non-parallel deck can sit only
  where a low flute crosses the flange, `rib_pitch / sin(rib_angle)` apart
  along the beam.

# Skewed ribs

AISC 360-22 §I3.2c and §I8.2a (corpus: aisc-360-22, PDF pp. 170, 182) give
rules for deck parallel or perpendicular to the beam only. Any angle other
than parallel takes the perpendicular rules: rib concrete neglected, and the
perpendicular `Rg`/`Rp`, which are no larger than the parallel values.
ENGINEERING JUDGMENT, supported by push-out tests at 45° and 90°
(Jakovljević, Spremić & Marković, ce/papers 2022, doi:10.1002/cepa.1821;
Eng. Struct. 303 (2024) 117574) in which stud resistance rose as the angle
fell from 90° to 45°. Below 45° no tests were found.
"""
struct DeckSlabOnBeam{T_P<:Pressure, T_D<:Density} <: AbstractSlabOnBeam
    t_slab::typeof(1.0u"m")
    fc′::T_P
    Ec::T_P
    wc::T_D
    n::Float64
    hr::typeof(1.0u"m")
    wr::typeof(1.0u"m")
    deck_orientation::Symbol
    beam_spacing_left::typeof(1.0u"m")
    beam_spacing_right::typeof(1.0u"m")
    edge_dist_left::Union{typeof(1.0u"m"), Nothing}
    edge_dist_right::Union{typeof(1.0u"m"), Nothing}
    e_mid_ht::Union{typeof(1.0u"m"), Nothing}
    anchorage_spacing::Union{typeof(1.0u"m"), Nothing}
    rib_angle::Float64
    rib_pitch::Union{typeof(1.0u"m"), Nothing}
end

_opt_m(x) = x === nothing ? nothing : uconvert(u"m", x)

"""Floating-point tolerance, in radians, for calling a rib angle exactly
parallel or perpendicular. It is not an engineering snap: only ribs that are
truly parallel get the parallel rules."""
const RIB_ANGLE_TOL = 1e-3

"""
    rib_orientation(θ) -> Symbol

`:parallel` for `θ ≈ 0`, `:perpendicular` for `θ ≈ π/2`, otherwise `:skewed`,
within [`RIB_ANGLE_TOL`](@ref).
"""
function rib_orientation(θ::Real)
    θ <= RIB_ANGLE_TOL && return :parallel
    θ >= π / 2 - RIB_ANGLE_TOL && return :perpendicular
    return :skewed
end

"""
    rib_angle_between(rib_dir, beam_dir) -> Float64

Acute angle in `[0, π/2]` between two plan directions `(x, y)`. Either may
point either way along its line.
"""
function rib_angle_between(rib_dir, beam_dir)
    a = hypot(rib_dir[1], rib_dir[2])
    b = hypot(beam_dir[1], beam_dir[2])
    (a > 0 && b > 0) || throw(ArgumentError("Rib and beam directions must be nonzero."))
    c = abs(rib_dir[1] * beam_dir[1] + rib_dir[2] * beam_dir[2]) / (a * b)
    return acos(clamp(c, 0.0, 1.0))
end

"""
    DeckSlabOnBeam(t_slab, fc′, Ec, wc, Es, hr, wr, deck_orientation,
                   beam_spacing_left, beam_spacing_right;
                   edge_dist_left=nothing, edge_dist_right=nothing,
                   e_mid_ht=nothing, anchorage_spacing=nothing,
                   rib_angle=nothing, rib_pitch=nothing)

`deck_orientation` is `:perpendicular` or `:parallel` when `rib_angle` is not
given. With `rib_angle` (radians), the orientation is classified from the
angle and `deck_orientation` must match that classification.
"""
function DeckSlabOnBeam(t_slab, fc′, Ec, wc, Es,
                        hr, wr, deck_orientation,
                        beam_spacing_left, beam_spacing_right;
                        edge_dist_left=nothing, edge_dist_right=nothing,
                        e_mid_ht=nothing, anchorage_spacing=nothing,
                        rib_angle=nothing, rib_pitch=nothing)
    θ = if rib_angle === nothing
        deck_orientation === :perpendicular ? π / 2 :
        deck_orientation === :parallel ? 0.0 :
        throw(ArgumentError("deck_orientation :$deck_orientation needs rib_angle; " *
                            "without it use :perpendicular or :parallel."))
    else
        Float64(rib_angle)
    end
    0.0 <= θ <= π / 2 + 1e-12 ||
        throw(ArgumentError("rib_angle must lie in [0, π/2] radians, got $θ."))
    θ = min(θ, π / 2)
    derived = rib_orientation(θ)
    deck_orientation === derived || throw(ArgumentError(
        "deck_orientation :$deck_orientation does not match rib_angle " *
        "$(round(rad2deg(θ); digits=3))° (:$derived)."))
    pitch = _opt_m(rib_pitch)
    pitch === nothing || pitch > 0u"m" ||
        throw(ArgumentError("rib_pitch must be positive, got $rib_pitch."))
    n = ustrip(u"Pa", Es) / ustrip(u"Pa", Ec)
    DeckSlabOnBeam(uconvert(u"m", t_slab), fc′, Ec, wc, n,
                   uconvert(u"m", hr), uconvert(u"m", wr), derived,
                   uconvert(u"m", beam_spacing_left),
                   uconvert(u"m", beam_spacing_right),
                   _opt_m(edge_dist_left), _opt_m(edge_dist_right),
                   _opt_m(e_mid_ht), _opt_m(anchorage_spacing), θ, pitch)
end

# ==============================================================================
# Steel Anchors
# ==============================================================================

"""
    HeadedStudAnchor <: AbstractSteelAnchor

Steel headed stud anchor per AISC 360-16 Section I8.

# Fields
- `d_sa`:  Stud shank diameter
- `l_sa`:  Stud length (base to top of head, after installation)
- `Fu`:    Specified minimum tensile strength
- `Fy`:    Specified minimum yield strength
- `ρ`:     Steel density (for weight/ECC calculations)
- `ecc`:   Embodied carbon coefficient [kgCO₂e/kg]
- `n_per_row`: Number of studs per transverse row (≥1)
- `source`: Where the stud properties came from. Empty for a caller-named
  stud; [`default_headed_stud`](@ref) fills it so results can report it.

# Notes
- Single-stud mass is computed as `π/4 × d_sa² × l_sa × ρ` (shank only, head negligible).
- `n_per_row > 1` affects spacing checks and `Rg` for deck configurations.
"""
struct HeadedStudAnchor{T_P<:Pressure, T_D<:Density} <: AbstractSteelAnchor
    d_sa::typeof(1.0u"m")
    l_sa::typeof(1.0u"m")
    Fu::T_P
    Fy::T_P
    ρ::T_D
    ecc::CarbonPerMassQuantity  # Embodied carbon [kgCO₂e/kg], typed via Asap `𝐗` dimension
    n_per_row::Int
    source::String
end

function HeadedStudAnchor(d_sa, l_sa, Fu, Fy, ρ; ecc=1.72u"kgCO2e/kg", n_per_row=1,
                          source::AbstractString="")
    n_per_row >= 1 || throw(ArgumentError("n_per_row must be ≥ 1"))
    HeadedStudAnchor(uconvert(u"m", d_sa), uconvert(u"m", l_sa),
                     Fu, Fy, ρ, _normalize_ecc(ecc), n_per_row, String(source))
end

const DEFAULT_STUD_SOURCE =
    "Default stud: 3/4 in ASTM A108 Type B, Fu = 65 ksi " *
    "(AISC Steel Construction Manual 14th ed., PDF p. 165; corpus: aisc-scm-14th). " *
    "That Manual edition predates AISC 360-22."

"""
    default_headed_stud(; hr=nothing, ρ=490 lb/ft³) -> HeadedStudAnchor

Stud used when composite design is requested and no stud is named.

- `d_sa = 3/4 in`, the largest diameter AISC 360-22 §I8.1 allows through deck
  (corpus: aisc-360-22, PDF p. 181).
- `Fu = 65 ksi` for ASTM A108 Type B studs, AISC Manual 14th ed., PDF p. 165
  (corpus: aisc-scm-14th). Eq. I8-1 uses `Fu`; `Fy` is stored as zero.
- `l_sa = max(4 d_sa, hr + 1.5 in)`: §I8.2 minimum length (PDF p. 181) and,
  on deck, §I3.2c(b) projection above the deck (PDF p. 170). Whether that
  length also leaves 1/2 in of cover is checked against the slab later.

The flange limit `d_sa ≤ 2.5 tf` (§I8.1) rejects sections with `tf < 0.30 in`.
"""
function default_headed_stud(; hr=nothing, ρ=490.0u"lb/ft^3")
    d = 0.75u"inch"
    l = hr === nothing ? 4d : max(4d, uconvert(u"inch", hr) + 1.5u"inch")
    HeadedStudAnchor(d, l, 65.0u"ksi", 0.0u"ksi", ρ; source=DEFAULT_STUD_SOURCE)
end

"""
    stud_mass(anchor::HeadedStudAnchor) -> mass (kg)

Mass of a single stud shank (cylindrical approximation, head neglected).
"""
function stud_mass(a::HeadedStudAnchor)
    A_sa = π / 4 * a.d_sa^2
    return uconvert(u"kg", A_sa * a.l_sa * a.ρ)
end

# ==============================================================================
# Pre-cure loads (filled by construction.jl)
# ==============================================================================

"""
Vertical construction loads for one beam, before the candidate's own weight.

`p_Cp` is SEI/ASCE 37-02 Table 2 for `cp_class`. `p_concrete` is C_VML.
`b_trib` turns those pressures into line loads. `p_L` is the nominal live load
present during construction (the `0.5L` term). `w_D_extra` is D other than the
steel beam. `w_Cd` and `w_Cfml` are line loads.
"""
struct ConstructionStage
    cp_class::Symbol
    p_Cp::typeof(1.0u"Pa")
    p_concrete::typeof(1.0u"Pa")
    b_trib::typeof(1.0u"m")
    p_L::typeof(1.0u"Pa")
    w_D_extra::typeof(1.0u"N/m")
    w_Cd::typeof(1.0u"N/m")
    w_Cfml::typeof(1.0u"N/m")
    # Extrema of the analysis dead-load field, and the uniform line load that
    # produced them. All `nothing` keeps the simple-span statics.
    M_ref::Union{Nothing, typeof(1.0u"N*m")}
    V_ref::Union{Nothing, typeof(1.0u"N")}
    w_ref::Union{Nothing, typeof(1.0u"N/m")}
    # A varying tributary width at one pressure. `M_ref` and `V_ref` are the
    # area-load extrema under `p_ref`. `M_line` and `V_line` are the extrema
    # under a uniform 1 N/m on the same bare-steel model. `nothing` keeps the
    # uniform-line-load scale above.
    M_line::Union{Nothing, typeof(1.0u"N*m")}
    V_line::Union{Nothing, typeof(1.0u"N")}
    p_ref::Union{Nothing, typeof(1.0u"Pa")}
end

"""A stage with no varying-width shape. The eleven analysis fields are unchanged."""
function ConstructionStage(cp_class, p_Cp, p_concrete, b_trib, p_L,
                           w_D_extra, w_Cd, w_Cfml, M_ref, V_ref, w_ref)
    return ConstructionStage(cp_class, p_Cp, p_concrete, b_trib, p_L,
                             w_D_extra, w_Cd, w_Cfml, M_ref, V_ref, w_ref,
                             nothing, nothing, nothing)
end

# ==============================================================================
# Deck attachment (reported; not a strength check)
# ==============================================================================

"""Support fastener pattern of the DDM03 standard composite deck tables."""
const DEFAULT_DECK_SUPPORT_PATTERN = "36/4"

const DEFAULT_DECK_PATTERN_SOURCE =
    "SDI Diaphragm Design Manual, 3rd ed. (2004), standard composite deck " *
    "support fastener pattern (corpus: sdi-ddm-3e-2004, PDF pp. 11–12). " *
    "Those tables are filled deck at Fy = 33 ksi, one edition behind DDM04, " *
    "so no diaphragm strength is taken from them."

"""
    DeckAttachment

How the deck is fastened, and an optional diaphragm shear strength.

`support_pattern` defaults to [`DEFAULT_DECK_SUPPORT_PATTERN`](@ref).
`sidelap_per_span` is the number of side-lap connectors between supports;
`nothing` means not supplied. `Sn` is a caller-supplied nominal diaphragm
shear strength per unit length. No default exists for it: SDI C-2017 (corpus:
sdi-c-2017, PDF p. 10) sends diaphragm strength to AISI S310, which is not in
the corpus, and the Vulcraft catalog leaves it to a web tool.

Nothing here compares `Sn` with the Appendix 6 brace force. Appendix 6 gives
that force per brace and has no per-length form for deck that braces a flange
continuously.
"""
struct DeckAttachment
    support_pattern::String
    pattern_source::String
    sidelap_per_span::Union{Nothing, Int}
    Sn::Union{Nothing, typeof(1.0u"N/m")}
end

function DeckAttachment(; support_pattern::AbstractString = DEFAULT_DECK_SUPPORT_PATTERN,
                        pattern_source::Union{Nothing, AbstractString} = nothing,
                        sidelap_per_span::Union{Nothing, Int} = nothing,
                        Sn = nothing)
    isempty(strip(support_pattern)) &&
        throw(ArgumentError("Deck support pattern must not be empty."))
    if sidelap_per_span !== nothing && sidelap_per_span < 0
        throw(ArgumentError("sidelap_per_span must be ≥ 0, got $sidelap_per_span."))
    end
    src = pattern_source !== nothing ? String(pattern_source) :
          support_pattern == DEFAULT_DECK_SUPPORT_PATTERN ? DEFAULT_DECK_PATTERN_SOURCE :
          "Caller-supplied deck support fastener pattern."
    DeckAttachment(String(support_pattern), src, sidelap_per_span,
                   Sn === nothing ? nothing : uconvert(u"N/m", Sn))
end

"""Note appended to the construction check. Empty for a solid slab."""
function deck_brace_note(::Nothing, Vbr)
    return ""
end

function deck_brace_note(att::DeckAttachment, Vbr)
    sn = att.Sn === nothing ? "diaphragm strength not supplied" :
         "caller Sn = $(att.Sn), not compared"
    side = att.sidelap_per_span === nothing ? "" :
           "; side-lap $(att.sidelap_per_span) per span"
    return "; deck support pattern $(att.support_pattern); Vbr = $(Vbr); $sn$side. " *
           "Not a check: Appendix 6 gives Vbr per brace, and SDI C-2017 sends " *
           "diaphragm strength to AISI S310, which is not in the corpus."
end

# ==============================================================================
# Composite Context (passed alongside ISymmSection in the checker)
# ==============================================================================

"""
    CompositeContext

All composite-specific data needed by the `AISCChecker` for a composite beam.
This struct is built once per beam group and passed to the composite `is_feasible` path.

# Fields
- `slab`:       Slab-on-beam configuration
- `anchor`:     Steel anchor type
- `L_beam`:     Beam span (center-to-center of supports)
- `shored`:     `true` if temporary shoring used during construction
- `Lb_const`:   Unbraced length of the sagging face during construction. Deck defaults to 0 (top flange braced); a solid slab on unattached forms defaults to the span. An explicit length overrides either.
- `Asr`:        Longitudinal reinforcement within `b_eff` at the section of maximum negative moment. A positive area asserts those bars are developed (§I3.2b(c)). Strip totals do not carry bar lengths, so development length is not computed. Place the area with `asr_at_section`. The hogging check uses this one section.
- `Fysr`:       Yield strength of that reinforcement
- `neg_moment`: `true` when steel anchors connect the slab to the beam in the negative-moment region
- `ΣQn_neg`:    Nominal strength of those anchors between the maximum negative moment and the adjacent zero (§I3.2d.2). `nothing` leaves the rebar uncounted.
- `slip_checked`: `true` when the caller has already run the commentary slip model
- `construction`: Pre-cure loads (SEI/ASCE 37-02). Built from the slab when omitted.
- `L_twist`:    Spacing of points that restrain twist, for the hogging Chapter F check and Commentary Eq. C-F1-5. `nothing` uses the member span.
- `deck_attachment`: Fastener pattern and optional diaphragm strength for a deck slab. `nothing` on a solid slab. A deck defaults to the 36/4 pattern.
- `d_rebar`:    Height of the negative-reinforcement centroid above the top of the steel. `0` puts the bars on the top flange and gives the smallest cracked `I_neg`.

# Notes
- The `AISCChecker` uses this to decide between bare-steel and composite capacity paths.
- `Asr`, `Fysr`, and `ΣQn_neg` are only used when `neg_moment = true`. A missing `ΣQn_neg` keeps hogging on Chapter F.
- When `shored = false`, construction-stage deflection uses steel Ix alone.
"""
struct CompositeContext{S<:AbstractSlabOnBeam, A<:AbstractSteelAnchor,
                        T_A<:Area, T_P<:Pressure}
    slab::S
    anchor::A
    L_beam::typeof(1.0u"m")
    shored::Bool
    Lb_const::typeof(1.0u"m")
    Asr::T_A
    Fysr::T_P
    neg_moment::Bool
    slip_checked::Bool
    construction::ConstructionStage
    ΣQn_neg::Union{Nothing, Unitful.Quantity}
    L_twist::Union{Nothing, typeof(1.0u"m")}
    deck_attachment::Union{Nothing, DeckAttachment}
    d_rebar::typeof(1.0u"m")
end

"""
Unbraced length for the pre-cure Chapter F check on the sagging face.

Deck fastened to the top flange is taken as continuous bracing of that flange,
so lateral-torsional buckling does not reduce φMn (`Lb = 0`). A solid slab on
forms that are not attached keeps the member span.

AISC 360-22 Commentary §I3.1b (corpus: aisc-360-22, PDF p. 501): when forms are
not attached to the top flange, bracing during construction may not be
continuous and the unbraced length may control. The deck default is the reverse
of that sentence. It is not a check that the deck can supply the Appendix 6
brace, and it does not brace a hogging region, where the bottom flange is in
compression.
"""
default_construction_Lb(::DeckSlabOnBeam, L_beam) = 0.0u"m"
default_construction_Lb(::SolidSlabOnBeam, L_beam) = uconvert(u"m", L_beam)

function CompositeContext(slab, anchor, L_beam;
                          shored=false, Lb_const=nothing,
                          Asr=0.0u"mm^2", Fysr=0.0u"MPa",
                          neg_moment=false,
                          ΣQn_neg=nothing,
                          slip_checked::Bool=false,
                          cp_class::Union{Symbol, Nothing}=:medium,
                          construction=nothing,
                          L_twist=nothing,
                          deck_attachment=:auto,
                          d_rebar=0.0u"m")
    stage = construction === nothing ?
        construction_stage(slab; cp_class = cp_class) : construction
    lb = Lb_const === nothing ? default_construction_Lb(slab, L_beam) : Lb_const
    if L_twist !== nothing && !(ustrip(u"m", uconvert(u"m", L_twist)) > 0)
        throw(ArgumentError("L_twist must be a positive length, got $L_twist."))
    end
    # :auto puts the named 36/4 pattern on a deck and nothing on a solid slab.
    att = deck_attachment === :auto ?
        (slab isa DeckSlabOnBeam ? DeckAttachment() : nothing) : deck_attachment
    CompositeContext(slab, anchor, uconvert(u"m", L_beam), shored,
                     uconvert(u"m", lb), Asr, Fysr, neg_moment,
                     slip_checked, stage, ΣQn_neg, _opt_m(L_twist), att,
                     uconvert(u"m", d_rebar))
end

# ==============================================================================
# Slab geometry helpers
# ==============================================================================

"""
    _gap_above_steel(slab) -> Length

Gap between the top of the steel beam flange and the bottom of the concrete
slab. Zero for solid slabs, `hr` (rib height) for deck slabs.
"""
_gap_above_steel(::SolidSlabOnBeam) = 0.0u"m"
_gap_above_steel(slab::DeckSlabOnBeam) = slab.hr

"""
    _total_slab_depth(slab) -> Length

Total distance from top of steel section to top of concrete slab.
For solid slabs this equals `t_slab`. For deck slabs this equals `hr + t_slab`.
"""
_total_slab_depth(slab::SolidSlabOnBeam) = slab.t_slab
_total_slab_depth(slab::DeckSlabOnBeam) = slab.hr + slab.t_slab
