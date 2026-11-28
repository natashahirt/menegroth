# ==============================================================================
# Axial-Member Sizing API
# ==============================================================================
# Shared sizer for pure axial steel members: braces, truss chords/webs, struts,
# and tension/compression ties. Pin-ended members with no flexural demand.
#
# This is a THIN adapter over the existing steel `size_columns` path. It adds no
# new capacity math: compression is sized by the checker's AISC 360-16 Chapter E
# routines (§E3 flexural buckling, §E4 torsional / flexural-torsional buckling,
# §E7 slender-element members) and tension by Chapter D (§D2 tensile yielding and
# rupture). `size_columns` owns the single solver path and the single source of
# truth for both limit states. corpus: aisc-360-16.

"""
Normalize `brace_type` to a per-member symbol and validate it.

`brace_type` may be a single `Symbol` (applied to every member) or a vector with
one entry per member, matching the length-validation style of the other member
APIs. Each entry must be one of `:both`, `:tension_only`, `:compression_only`.
"""
function _axial_brace_type(brace_type, i::Int, n::Int)
    bt = if brace_type isa AbstractVector
        length(brace_type) == n || throw(ArgumentError(
            "brace_type must have one entry per member (got $(length(brace_type)) for $n members)"))
        brace_type[i]
    else
        brace_type
    end
    bt in (:both, :tension_only, :compression_only) || throw(ArgumentError(
        "brace_type must be :both, :tension_only, or :compression_only (got :$bt)"))
    return bt
end

"""
    size_axial_members(Pu_c, Pu_t, geometries, opts::SteelColumnOptions;
                       brace_type = :both, catalog = nothing, kwargs...) -> NamedTuple

Size pure axial steel members (braces, truss chords/webs, struts, tension or
compression ties) against AISC 360-16. These are pin-ended members carrying
axial force only; all flexural demand is forced to zero, so the design reduces
to the two axial limit states:

- **Compression** — Chapter E: §E3 flexural buckling, §E4 torsional /
  flexural-torsional buckling, and §E7 members with slender elements.
- **Tension** — Chapter D §D2: tensile yielding on the gross section and tensile
  rupture on the net section.

corpus: aisc-360-16. No capacity formula is implemented here: the sizer delegates
to the steel [`size_columns`](@ref) path, which drives the same `AISCChecker`
(and the same discrete MIP / NLP solvers) that sizes columns and beams. This is
the member engine a future `Strut`/`Truss` layer in StructuralSynthesizer calls.

# Arguments
- `Pu_c`: Factored **compression** demand magnitudes (≥ 0) — any force unit
  (N, kN, kip, …). A compression tie/strut has `Pu_c > 0`.
- `Pu_t`: Factored **tension** demand magnitudes (≥ 0) — any force unit. A
  tension tie has `Pu_t > 0`. Must have the same length as `Pu_c`.
- `geometries`: Member geometries (`SteelMemberGeometry`); effective length
  factors `Kx`/`Ky` set the Chapter E buckling length. Flexural fields are
  irrelevant here because there is no moment demand.
- `opts`: `SteelColumnOptions` (section type, catalog, objective, material,
  sizing strategy).

# Keyword Arguments
- `brace_type`: `:both` | `:tension_only` | `:compression_only`. A scalar applies
  to every member, or pass a vector with one entry per member. Semantics:
    - `:tension_only` — the member is NOT relied on for compression (e.g. the
      slender diagonal of an X-brace whose compression strut buckles and sheds
      its load). Effective `Pu_c` is set to 0 so Chapter E does not size it;
      Chapter D tension governs.
    - `:compression_only` — effective `Pu_t` is set to 0; Chapter E compression
      governs.
    - `:both` — keep both demands; the checker takes the governing limit state.
- `catalog`: Optional per-call section catalog override, forwarded to
  `size_columns` (default `nothing`).
- Remaining keyword arguments (`mip_gap`, `output_flag`, `tc`, …) are forwarded
  unchanged to `size_columns`.

# Sizing strategy / tension restriction
The steel NLP path (`opts.sizing_strategy == :nlp`) has no Chapter D tension
check — its continuous interaction constraint is compression-only. So if any
member carries effective tension (`:both` or `:tension_only` with `Pu_t > 0`)
under `:nlp`, an `ArgumentError` directs the caller to `:discrete`, matching the
`size_columns` message style. Compression-only members may use `:nlp`.

# Returns
The same `NamedTuple` shape `size_columns` returns (`sections`,
`section_indices`, `status`, `objective_value`, …). No new result type.

# Example
```julia
using Unitful
using StructuralSizer: kip

Pu_c = [300.0, 0.0,   250.0] .* kip   # compression magnitudes
Pu_t = [0.0,   300.0, 250.0] .* kip   # tension magnitudes
geoms = [SteelMemberGeometry(5.0u"m") for _ in 1:3]

result = size_axial_members(Pu_c, Pu_t, geoms, SteelColumnOptions(section_type = :hss);
                            brace_type = [:compression_only, :tension_only, :both])
```
"""
function size_axial_members(
    Pu_c::Vector,
    Pu_t::Vector,
    geometries::Vector,
    opts::SteelColumnOptions;
    brace_type = :both,
    catalog::Union{Nothing, AbstractVector} = nothing,
    mip_gap::Real = 1e-4,
    output_flag::Integer = 0,
    tc::Union{Nothing, TraceCollector} = nothing,
)
    n = length(Pu_c)
    n == length(Pu_t) || throw(ArgumentError("Pu_c and Pu_t must have same length"))
    n == length(geometries) ||
        throw(ArgumentError("demands and geometries must have same length"))

    # Resolve brace_type → effective (Pu_c, Pu_t) per member. `zero(x)` keeps the
    # caller's unit (Unitful or plain Real), so no demand is silently stripped.
    # :tension_only drops compression (Chapter E not relied on); :compression_only
    # drops tension (Chapter D not relied on); :both keeps both limit states.
    Pu_c_eff = similar(Pu_c)
    Pu_t_eff = similar(Pu_t)
    for i in 1:n
        bt = _axial_brace_type(brace_type, i, n)
        Pu_c_eff[i] = bt === :tension_only     ? zero(Pu_c[i]) : Pu_c[i]
        Pu_t_eff[i] = bt === :compression_only ? zero(Pu_t[i]) : Pu_t[i]
    end

    # AISC 360-16 Chapter D §D2 tension (corpus: aisc-360-16, page 87) has no
    # counterpart on the steel NLP path, whose interaction constraint is
    # compression-only. Fail loudly and point at :discrete, in the style of the
    # existing `size_columns` NLP guards, rather than silently dropping tension.
    if opts.sizing_strategy === :nlp && any(!iszero, Pu_t_eff)
        throw(ArgumentError(
            "axial member sizing does not support tensile axial demand Pu_t on the " *
            "NLP path (AISC 360-16 Chapter D §D2 tension is checked only on the " *
            "discrete path); use sizing_strategy=:discrete for :both/:tension_only " *
            "members. Compression-only members may use :nlp."))
    end

    # Pure axial: all flexural demand is zero. Pass Mux/Muy = 0 and leave the
    # end-moment / transverse-load inputs at their defaults (M1 = M2 = 0,
    # transverse_load = false). With zero moment the §H1 interaction reduces to
    # the pure axial check, so Chapter E (compression) or Chapter D (tension)
    # governs. `size_columns` is the single solver + checker path.
    zero_moments = zeros(n)   # interpreted as 0 N·m by to_newton_meters
    return size_columns(
        Pu_c_eff,            # positional Pu → MemberDemand.Pu_c (Chapter E)
        zero_moments,        # positional Mux = 0
        geometries,
        opts;
        Muy = zero_moments,  # weak-axis moment = 0
        Pu_t = Pu_t_eff,     # MemberDemand.Pu_t (Chapter D §D2)
        catalog = catalog,
        mip_gap = mip_gap,
        output_flag = output_flag,
        tc = tc,
    )
end
