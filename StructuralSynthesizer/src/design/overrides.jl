
"""
    _mgo_refusal_message(reason::AbstractString) -> String

Compose the fail-loud refusal message for an un-honorable `member_group_overrides`
target. The substring `'member_group_overrides'` is always present so callers /
tests can message-pin on it.
"""
_mgo_refusal_message(reason::AbstractString) =
    "member_group_overrides cannot be honored here: " * reason * ". " *
    "Refusing rather than silently ignoring the per-group override — a dropped " *
    "catalog / deflection / depth restriction is a silent safety hazard. Phase B " *
    "honors EFFECTIVE overrides only for STEEL BEAM member groups on beam/column " *
    "floors sized via the batched size_beams! path with n_max_sections == 0 and a " *
    "single material."

# ─── [P1-2] redirect: per-gid beam/column classification REMOVED ─────────────
# The former `_honorable_member_gids` / `_member_group_kinds` / `_member_group_kind`
# helpers reproduced the sizer's collinear + par_has grouping at the PRE-SIZING door
# so the guard could classify each override target as :beams / :columns / :struts.
# That reproduction is UNRELIABLE: collinear grouping runs at SIZE time on the
# analysis structure (`group_collinear_members!` inside `size_beams!` / `size_columns!`,
# utils.jl), NOT in `prepare!`, so a door-side reproduction disagreed with the real
# size-time gids (e.g. 12 groups at the door vs 24 at size time) and false-refused
# honorable collinear beam overrides ([P1-2]). The DEFINITIVE per-gid honor/refuse
# decision now lives at the size-time choke point inside `_size_beams_impl!`
# (utils.jl), where the REAL par_has-filtered, collinear-merged beam `group_ids` are
# in scope: a column / strut / unknown / par_has-absent gid is refused fail-loud there
# ([P2-3]) BEFORE any BuildingDesign is produced. The door below refuses only what is
# decidable WITHOUT per-gid classification (floor type / non-steel / coupling /
# material, plus the looseness check).

"""
    _assert_member_group_overrides_unsupported(params::DesignParameters)
    _assert_member_group_overrides_unsupported(params::DesignParameters, struc::BuildingStructure)

Fail-loud guard (Run 4). Phase B makes `member_group_overrides` LIVE for the
HONORABLE case — an EFFECTIVE override targeting a STEEL BEAM member group on a
beam/column floor, sized via the batched `size_beams!` → `optimize_discrete` path
with `n_max_sections == 0` and a single material (see `_size_beams_impl!`). Such
overrides are threaded into that group's feasible set and DO change its result.

This guard refuses only the UN-HONORABLE effective targets that no threaded path
can honor and that would therefore be SILENTLY IGNORED:

  1. the floor system is flat-plate / flat-slab (members are sized via
     `size_flat_plate!` / `_reconcile_columns!`, never per beam group);
  2. beam sizing is NOT steel (`params.beams` is a concrete / PixelFrame / T-beam
     option) — those `_size_beams_impl!` variants are not threaded this increment;
  3. `n_max_sections > 0` on the steel beam options — that couples groups, so
     per-group narrowing is no longer exact-first-safe;
  4. the steel beam options carry a multi-material catalog (`opts.materials`) —
     per-group narrowing over the expanded catalog is out of scope this increment;
  4b. the steel beam options set `sizing_strategy != :discrete` (e.g. `:nlp`) — the
     honor-or-throw gid gate lives only in the steel-`Val{:discrete}`
     `_size_beams_impl!`, so a non-:discrete strategy has no honoring path;
  5. the override's resolved `deflection_limit` is LOOSER (numerically larger L/δ
     ratio) than the global, or its `max_depth` EXCEEDS the global `max_depth` —
     such a loosening is a silent no-op in the batched path (the global AISCChecker
     screening always intersects the per-group mask, so a per-group knob can only
     tighten), and is refused fail-loud. Tightening stays honored via the mask.

Checks 1–4b are decidable from `params` alone and run in BOTH overloads. Check 5
(looseness) compares the override knobs to the global steel-beam knobs — it needs no
per-gid geometry, so it also runs in the `struc`-aware overload (called from the
`BuildingDesign(struc, params)` constructor, `capture_design`,
`run_pre_sizing_validation`, and the incremental variation doors).

NOTE ([P1-2] redirect): this guard NO LONGER classifies each target as
:beams / :columns / :struts. Reproducing the sizer's collinear + par_has grouping
BEFORE sizing is UNRELIABLE — collinear grouping runs at SIZE time on the analysis
structure (`group_collinear_members!` inside `size_beams!` / `size_columns!`), not in
`prepare!` — so a column / strut / unknown / par_has-absent gid is now refused
fail-loud at the DEFINITIVE size-time choke point inside `_size_beams_impl!`
(utils.jl), where the REAL beam `group_ids` are in scope, NOT here. An honorable
beam-floor override therefore PASSES this door and is honored (or definitively
refused) at size time. An override whose fields are ALL unset (`_is_effective ==
false`) is a documented no-op and never throws, so the happy path stays
byte-identical. (catalog / deflection_limit / max_depth are engineering sizing
knobs — no code citation.)
"""
function _assert_member_group_overrides_unsupported(params::DesignParameters)
    (isempty(params.member_group_overrides) ||
        !any(_is_effective, values(params.member_group_overrides))) && return nothing

    # (1) Floor system that never sizes beams per-group.
    floor_type = _infer_floor_type(resolve_floor_options(params))
    if floor_type in (:flat_plate, :flat_slab)
        throw(ArgumentError(_mgo_refusal_message(
            "the floor system is :$(floor_type), which sizes members via " *
            "size_flat_plate! / _reconcile_columns! and never sizes beam groups " *
            "per-group")))
    end

    beam_opts = params.beams
    if beam_opts !== nothing
        # (2) Non-steel beam sizing (concrete / PixelFrame / T-beam paths are not
        #     threaded in this increment).
        if !(beam_opts isa StructuralSizer.SteelBeamOptions)
            throw(ArgumentError(_mgo_refusal_message(
                "beam sizing uses $(typeof(beam_opts)); per-group overrides are only " *
                "threaded for steel beam groups (SteelBeamOptions) this increment")))
        end
        # (3) n_max_sections coupling hazard. Size-time mirror (for direct callers that
        #     bypass this front door) lives beside the multi-material mirror in
        #     `_size_beams_impl!(::SteelBeamOptions, ::Val{:discrete})` (analyze/members/utils.jl,
        #     cycle-9 coupling mirror); see the MIRROR-PARITY INVARIANT there.
        if beam_opts.n_max_sections > 0
            throw(ArgumentError(_mgo_refusal_message(
                "steel beam options set n_max_sections=$(beam_opts.n_max_sections) > 0, " *
                "which couples member groups so per-group feasible narrowing is not " *
                "exact-first-safe")))
        end
        # (4) Multi-material catalog.
        if beam_opts.materials !== nothing
            throw(ArgumentError(_mgo_refusal_message(
                "steel beam options set a multi-material catalog (opts.materials); " *
                "per-group narrowing over the expanded catalog is out of scope this " *
                "increment")))
        end
        # (4b) Non-discrete sizing strategy. The honor-or-throw size-time gid gate
        #      lives ONLY in the steel-`Val{:discrete}` `_size_beams_impl!`
        #      (utils.jl); there is no steel-`:nlp` overload. `SteelBeamOptions`
        #      exposes `sizing_strategy::Symbol` (StructuralSizer options.jl:106,
        #      default `:discrete`, may be `:nlp`). A `:nlp` steel beam option with an
        #      effective override would bypass the gid gate and dispatch to
        #      `_size_beams_impl!(..., ::SteelBeamOptions, ::Val{:nlp})` — a MethodError
        #      today, and a SILENT DROP the instant an accept-and-drop `:nlp` overload
        #      is added. Refuse fail-loud so only the steel-discrete batched path (the
        #      one that carries the honor-or-throw gate this increment) accepts an
        #      effective override. Runs in BOTH overloads (params-only), so it fires on
        #      design_building AND size! AND the direct / variation doors.
        if beam_opts.sizing_strategy != :discrete
            throw(ArgumentError(_mgo_refusal_message(
                "steel beam options set sizing_strategy=:$(beam_opts.sizing_strategy); " *
                "per-group overrides are honored only on the steel-discrete batched " *
                "size_beams! path (the honor-or-throw gate lives solely in the " *
                ":discrete _size_beams_impl!), so a non-:discrete strategy would bypass " *
                "it")))
        end
    end
    return nothing
end

function _assert_member_group_overrides_unsupported(params::DesignParameters,
                                                    struc::BuildingStructure)
    # Params-only refusals first (floor type / non-steel / coupling / material).
    _assert_member_group_overrides_unsupported(params)
    isempty(params.member_group_overrides) && return nothing
    # Global steel-beam knobs actually used by the batched size_beams! path
    # (`something(params.beams, SteelBeamOptions())` mirrors `_size_beams_columns!`).
    # By the time we get here the params-only guard has already refused any non-steel
    # beam options, so a non-nothing `params.beams` is a SteelBeamOptions.
    global_opts = params.beams isa StructuralSizer.SteelBeamOptions ?
        params.beams : StructuralSizer.SteelBeamOptions()
    global_defl  = global_opts.deflection_limit    # Union{Nothing, Float64}, L/δ ratio
    global_depth = global_opts.max_depth            # Length depth cap
    # NOTE ([P1-2] redirect): per-gid classification was REMOVED from this door — a
    # column / strut / unknown / par_has-absent target is refused fail-loud at the
    # size-time gate inside `_size_beams_impl!` (utils.jl), where the real collinear-
    # merged, par_has-filtered beam `group_ids` are in scope. This door still refuses a
    # LOOSER knob (a silent no-op hazard, decidable from params alone).
    for (gid, ovr) in params.member_group_overrides
        _is_effective(ovr) || continue
        # (5) LOOSER deflection_limit / max_depth is a SILENT NO-OP hazard. The
        # batched size_beams! path always intersects the per-group feasible mask with
        # the GLOBAL AISCChecker screening, so a per-group knob can only ever TIGHTEN
        # a group relative to the global default; a knob set LOOSER than the global is
        # clamped by the global screening and silently ignored. Refuse it fail-loud
        # rather than let a per-group loosening quietly have no effect. TIGHTENING
        # stays honored via the mask. `deflection_limit` is an L/δ RATIO, so LOOSER
        # means a numerically LARGER ratio; a `nothing` global limit is the loosest
        # possible, so any finite per-group ratio is a (honored) tightening.
        if ovr.deflection_limit !== nothing && global_defl !== nothing &&
                ovr.deflection_limit > global_defl
            throw(ArgumentError(_mgo_refusal_message(
                "override on beam group $(gid) sets deflection_limit=$(ovr.deflection_limit), " *
                "LOOSER than the global deflection_limit=$(global_defl) (larger L/δ ratio); " *
                "the batched size_beams! mask can only tighten, so a looser per-group limit " *
                "would be silently ignored")))
        end
        if ovr.max_depth !== nothing && ovr.max_depth > global_depth
            throw(ArgumentError(_mgo_refusal_message(
                "override on beam group $(gid) sets max_depth=$(ovr.max_depth), LOOSER than " *
                "the global max_depth=$(global_depth); the batched size_beams! mask can only " *
                "tighten, so a looser per-group cap would be silently ignored")))
        end
    end
    return nothing
end


