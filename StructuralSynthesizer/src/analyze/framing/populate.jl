# =============================================================================
# Framing auto-generation: populate_levels! / derive_framing_level /
# materialize_level!  — Phase 5 (plan `joists-roles-materials`)
# =============================================================================
#
# One mechanism powers both the single-level case (steel + OWSJ deck, RC waffle,
# mass-timber joists) and — through opts-driven per-level schemas — the
# multi-level case (girders + secondary beams + joists). The flow is:
#
#   populate_levels!(struc; opts)
#     └─ for each slab, for level_idx = 1, 2, …:
#          derive_framing_level(slab, level_idx, opts)  → FramingLevel | nothing
#          attach_framing_level!(struc, slab, level)    (Phase 4, if newly derived)
#          materialize_level!(struc, slab, level)        → Vector{Beam{T}}
#
# Mechanics contract (`.cursor/rules/code-accuracy.mdc`): this file invents NO
# structural formulas. Every mechanics decision reduces to an already-existing,
# already-tested utility:
#   - joist geometry (pattern → lines) comes from the slab's own sizing data via
#     the Phase-4 `joist_geometry(slab, level_idx)` trait (rib grid / joist
#     spacing / span axis) — never fabricated here;
#   - joist landings (host subdivision) reuse the skeleton `edge_chains`
#     mechanism (`api/deserialize.jl`), the same topological surgery used at
#     deserialization;
#   - joist end releases are left as `level.end_fixity` (default `:default`),
#     which the Phase-2 runtime resolver (`resolve_release`) maps through the
#     Phase-3 `(role, material, lateral_role)` dispatch (`default_release`);
#   - seat eccentricity / torsion are likewise deferred to Phase 3.
#
# The only non-code decisions this file makes are flagged `ENGINEERING JUDGMENT`
# (default joist spacing for the opts-schema path; `lateral_role = :gravity` for
# auto-generated joists). Neither is code-mandated and the corpus carries no
# SJI / NDS joist-spacing table to cite, so they are judgment defaults.

# -----------------------------------------------------------------------------
# ENGINEERING JUDGMENT defaults
# -----------------------------------------------------------------------------

# ENGINEERING JUDGMENT: default center-to-center joist spacing for the
# opts-schema path (`:one_way` / `:two_way` / `:composite_deck` /
# `:non_composite_deck`) when the caller supplies neither `opts.spacing` nor a
# resolved spacing on the pattern. ~4 ft for steel framing, ~2 ft for wood
# framing are common layout starting points; neither is code-mandated (no SJI /
# NDS spacing table exists in the corpus), so these are judgment defaults a
# caller is expected to override with `opts.spacing`.
const _JUDGMENT_STEEL_JOIST_SPACING_M = 1.2192   # 4.0 ft
const _JUDGMENT_WOOD_JOIST_SPACING_M  = 0.6096   # 2.0 ft

# -----------------------------------------------------------------------------
# populate_levels!
# -----------------------------------------------------------------------------

"""
    populate_levels!(struc::BuildingStructure; opts::NamedTuple = NamedTuple()) -> Nothing

Auto-generate the framing hierarchy above every slab in `struc` (plan
`joists-roles-materials`, Phase 5). Mutates `struc` in place and returns
`nothing`.

For each slab, iterates `level_idx = 1, 2, …`, calling
[`derive_framing_level`](@ref)`(slab, level_idx, opts)` until it returns
`nothing`. Each non-`nothing` [`FramingLevel`](@ref) is attached (via
[`attach_framing_level!`](@ref), unless it is already one of the slab's levels)
and then materialized into real `Beam{T}`s via [`materialize_level!`](@ref).

# Iteration / subdivision contract
- Level 1 is derived from the slab type + `opts` (see `derive_framing_level`).
- A level `N ≥ 2` is generated **only if the caller requested it** by supplying
  an `opts` key `Symbol("level_\$N")` whose value is a `NamedTuple` schema (this
  is how "the previous level requested subdivision" is encoded — the request
  lives in `opts`, keyed by the level it describes). Absent that key,
  `derive_framing_level` returns `nothing` and iteration stops.

# Idempotence (guardrail)
`populate_levels!` is idempotent within a `prepare!` call and across repeated
calls: `materialize_level!` stamps `level.group_id`, and `derive_framing_level`
returns `nothing` for any `level_idx` a slab already carries a **materialized**
level at, so a second call adds no new members. A manually attached level (via
`attach_framing_level!`) that has not yet been materialized IS respected — it is
materialized on the next call, not skipped.

# opts (all optional)
- `opts.materials`: `NamedTuple` of member materials by key
  (`:steel`, `:timber`, `:concrete`, `:beam`) used to fill `FramingLevel.material`
  for slab types that do not carry their own member material.
- `opts.spacing`: center-to-center joist spacing (structure length unit) for the
  opts-schema slab types.
- `opts.axis` / `opts.count`: level-1 joist run-direction / explicit joist count
  for the opts-schema slab types (ignored by the joist-sizing slab types, whose
  level-1 geometry comes from the sized result).
- `opts.end_fixity` / `opts.beam_options`: level-1 per-end release override
  and per-level sizing options (`nothing` uses the building-wide beam options).
- `opts.level_N`: `NamedTuple` schema for framing level `N ≥ 2` (keys
  `:material`, `:spacing`, `:role`, `:axis`, `:count`, `:end_fixity`,
  `:beam_options`).

Passing an empty `opts` (the pipeline default from `prepare!`) generates nothing
for the standard flat-plate / flat-slab / beam-supported flows, so existing
behavior is unchanged unless a caller opts in.
"""
function populate_levels!(struc::BuildingStructure; opts::NamedTuple = NamedTuple())
    # P2(d) fix (p5_eng_v2): count levels that actually produced ≥ 1 `Beam`, not
    # merely levels that were derived. A derived-but-empty level (pattern lays out
    # no joists on the slab) must NOT trigger the tributary cascade — the docstring
    # contract is "only IF members were generated", and the empty-opts pipeline
    # path must stay a strict no-op.
    n_beams_generated = 0
    for slab in struc.slabs
        level_idx = 1
        while true
            level = derive_framing_level(slab, level_idx, opts)
            level === nothing && break
            # Newly derived levels are attached; an existing (manual or prior)
            # level returned by derive is already on the slab — do not re-attach.
            if !any(fl -> fl === level, slab.framing_levels)
                attach_framing_level!(struc, slab, level)
            end
            beams = materialize_level!(struc, slab, level)
            if !isempty(beams)
                n_beams_generated += 1
            end
            @debug "populate_levels!: materialized framing level" slab_idx=level.slab_idx level=level.level role=level.role n_beams=length(beams) n_supports=length(level.supports)
            level_idx += 1
        end
    end

    # Layer-2+ tributary cascade (Phase 0 machinery): only refresh member
    # tributary profiles when we actually generated members, so the empty-opts
    # pipeline path is a strict no-op and leaves existing tributaries untouched.
    # A grillage with no interior rib (one bay) still owns the boundary
    # profiles, so the merge runs even though no joist beam was created.
    grillage = any(s -> _grillage_level(s) !== nothing, struc.slabs)
    if n_beams_generated > 0 || grillage
        # (1) Level-0 skeleton beams get their slab-face tributaries from the
        #     cell-edge merge; (2) the level-cascade then gives the generated
        #     joists their strip tributaries and flows each level's load down onto
        #     its `level.supports` hosts (P1(b) fix).
        compute_member_tributaries!(struc; strategy = :cell_merge)
        # The baseline was just rebuilt above; skip the redundant rebuild inside
        # the cascade (P2(e) idempotence fix, p5_eng_v3). The cascade still clears
        # the generated (`level ≥ 1`) members' stale deposits internally.
        cascade_framing_tributaries!(struc; reset_baseline = false)
    end
    # Support rank from the finished layout, including the joists just made.
    # Materialize reads `level == 0` as "skeleton host", so this runs after it.
    assign_framing_levels!(struc)
    return nothing
end

include("tributary_cascade.jl")
include("derive_schema.jl")
include("materialize.jl")
include("joist_geometry.jl")
include("host_edge_mutation.jl")
include("solid_head_split.jl")
