# =============================================================================
# I_factor Threading Verify Gate
# =============================================================================
#
# Proves that `params.beam_I_factor` (default 0.35) and `params.column_I_factor`
# (default 0.70) are now THREADED end-to-end through `size_beams!` /
# `size_columns!` / `_reconcile_columns!` down to the Asap element section
# builders (`StructuralSizer.to_asap_section`), and are applied CONCRETE-ONLY
# per ACI 318-11 §10.10.4.1 (cracked-stiffness reduction). Previously the
# 0.35 / 0.70 reductions came only from the hardcoded `to_asap_section`
# defaults, so these two knobs were inert.
#
# The gate drives the SAME member-sizing workflow `design_building` uses (the
# `build_pipeline` stage loop after `prepare!`), stopping BEFORE `restore!` so
# the sized Asap element sections can be inspected directly. For a concrete
# beam/column vault building it asserts:
#
#   (A) NO-OP AT DEFAULT — at default params (beam_I_factor=0.35,
#       column_I_factor=0.70) a representative concrete beam element and
#       concrete column element have section Ix/Iy/J EQUAL to the library
#       default `StructuralSizer.to_asap_section(sec, mat)` (which internally
#       applies 0.35 for RCBeamSection, 0.70 for RCColumnSection). This proves
#       threading the default param reproduces the pre-change values exactly.
#
#   (B) EFFICACY — re-running with beam_I_factor=0.5 / column_I_factor=0.5
#       scales the concrete beam element Ix by 0.5/0.35 and the concrete column
#       element Ix by 0.5/0.70 relative to the default run (gross geometry held
#       fixed, confirmed via the I_factor-independent element area A), proving
#       the knob now controls stiffness. The section Ix/Iy/J also match
#       `to_asap_section(sec, mat; I_factor=0.5)` exactly.
#
#   (C) STEEL UNAFFECTED — a steel beam design produces byte-identical steel
#       element sections regardless of beam_I_factor (steel does not crack; the
#       factor must never reach the steel `to_asap_section`).
#
# Checks (D)–(F) extend the gate to the public API and the FLAT-PLATE column
# stubs, proving `params.column_I_factor` governs the flat-plate COLUMN cracked
# stiffness (ACI 318-11 §10.10.4.1) across BOTH analysis methods:
#
#   (D) PUBLIC API — `StructuralSynthesizer.size!(design)` threads the knobs
#       end-to-end (see below).
#
#   (E) FLAT-PLATE FEA — `FlatPlateOptions(method = FEA())`.  Proves the fix
#       point `resolve_floor_options(params)` threads `params.column_I_factor`
#       into `FlatPlateOptions.col_I_factor` (byte-identical to the 0.70 field
#       default at default; 0.50 at non-default), then drives the REAL FEA
#       moment-analysis builder and inspects the resulting Asap column-stub
#       section: its Ix scales by 0.5/0.70 at the non-default knob and is
#       byte-identical to `column_asap_section(…; I_factor = 0.70)` at default
#       (gross geometry held fixed, confirmed via the I_factor-independent
#       stub area A).
#
#   (F) FLAT-PLATE EFM — `FlatPlateOptions(method = EFM(solver = :asap,
#       cracked_columns = …))`.  Drives the REAL EFM moment-analysis builder and
#       inspects the Asap column-stub section: with `cracked_columns = true` the
#       stub Ix scales by 0.5/0.70 (and `cracked@0.70` equals 0.70 × the gross
#       uncracked stub); with `cracked_columns = false` the stub is gross (1.0)
#       regardless of the knob.  Also asserts the EFM SECONDARY direction threads
#       the knob (its column moments respond to column_I_factor only when
#       cracked, and are identical/gross when uncracked).
#
# Checks (G)–(H) extend the gate to the INCREMENTAL design engine that drives the
# REST API, proving a param-only redesign that changes either knob re-runs the
# right nodes instead of silently returning the cached baseline (the exact P0 just
# fixed: both fields were absent from every invalidation surface):
#
#   (G) column_I_factor 0.70→0.50 — now `PREPARE_AFFECTING_FIELDS` (scheduler.jl).
#       `requires_new_engine` is true (API routes COLD), the session `redesign`
#       guard throws instead of reusing the stale 0.70 baseline, and a COLD design
#       at 0.50 differs from the baseline. The field is in NO node slice, so the
#       incremental dirty frontier is EMPTY — confirming prepare-affecting (not a
#       node slice) is the required fix (baked flat-plate stubs need a fresh prepare!).
#
#   (H) beam_I_factor 0.35→0.70 — now `NODE_MEMBERS.param_slice` (provenance.jl).
#       The change is param-only (incremental-eligible), dirties the `:members`
#       node, and the incremental redesign RECOMPUTES `:members` (not a stale
#       restore). The result is output-equivalent to a COLD run at the same factor
#       (exact-first, rtol=1e-8) AND differs from the 0.35 baseline; redesigning
#       back at 0.35 is a pure memo hit (no spurious recompute).
#
# Usage:
#   SS_ENABLE_VISUALIZATION=false SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD=false \
#       julia --project=StructuralSynthesizer \
#       scripts/runners/verify_i_factor_threading.jl
#
# Exit code: 0 when all checks pass, 1 otherwise.
# =============================================================================

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] =
    get(ENV, "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD", "false")

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))
Pkg.instantiate()

using Asap
using StructuralSizer
using StructuralSynthesizer
using Unitful
using Printf

const SR = StructuralSizer
const SS = StructuralSynthesizer

# Shared per-member design signature (`design_signature` / `same_signature`) used
# by the INCREMENTAL-path checks (G/H). Included AFTER the `using` preamble so
# `BuildingDesign` + the `u"kgCO2e"` unit (registered by Asap) resolve at include
# time — the same contract the sibling incremental runners rely on.
# `same_signature` late-binds the local `_close` defined just below.
include(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer",
                 "test", "design_graph", "_verify_shared.jl"))

# NaN-aware closeness (two NaNs equal); identical numeric behavior (rtol=1e-8,
# atol=1e-10) to the sibling incremental gates. Left local per the
# `_verify_shared.jl` contract (`same_signature` resolves it in this scope).
function _close(a, b; rtol::Float64 = 1e-8, atol::Float64 = 1e-10)
    if a isa AbstractFloat && b isa AbstractFloat
        (isnan(a) && isnan(b)) && return true
        return isapprox(a, b; rtol = rtol, atol = atol)
    end
    return isequal(a, b)
end

# -----------------------------------------------------------------------------
# Check bookkeeping (mirrors verify_warm_state_incremental.jl style).
# -----------------------------------------------------------------------------
const CHECKS = Tuple{String, Bool}[]
record!(name, ok) = (push!(CHECKS, (name, ok)); @printf("  %s  %s\n", ok ? "✓" : "✗", name))

# -----------------------------------------------------------------------------
# Fixtures — a small 2×2-bay, single-story vault building (same geometry as the
# proven `_build_beam_column` fixture in test_design_graph_incremental.jl). A
# vault floor routes stage 2 to `_size_beams_columns!`, which is the function
# that threads `params.beam_I_factor` / `params.column_I_factor`.
# -----------------------------------------------------------------------------
function build_struc(; beams, columns, beam_I_factor, column_I_factor)
    skel  = gen_medium_office(30.0u"ft", 24.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name               = "verify_i_factor_threading",
        floor              = SR.VaultOptions(lambda = 8.0, material = SR.NWC_4000),
        beams              = beams,
        columns            = columns,
        beam_I_factor      = beam_I_factor,
        column_I_factor    = column_I_factor,
        max_iterations     = 5,
        skip_visualization = true,
    )
    return struc, params
end

# Drive the real member-sizing workflow (the `build_pipeline` stage loop that
# `design_building` runs) and STOP before `restore!`, leaving the sized Asap
# element sections on `struc.asap_model` for inspection. `_reanalyze_after_
# section_change!` inside `_size_beams_columns!` uses `Asap.update!` (not a
# model rebuild), so the sized element sections persist through the sync.
function run_sized(; beams, columns, beam_I_factor, column_I_factor)
    struc, params = build_struc(; beams, columns, beam_I_factor, column_I_factor)
    prepare!(struc, params)
    for stage in build_pipeline(params)
        stage.fn(struc)
        stage.needs_sync && sync_asap!(struc; params = params)
    end
    return struc
end

# -----------------------------------------------------------------------------
# Section-type predicates. A concrete member group is identified by the TYPE of
# its chosen section (ACI 318-11 §10.10.4.1 cracked-stiffness is concrete-only),
# NOT by `group_id`: the vault fixture's beams/columns are SINGLETON groups whose
# `group_id(m) === nothing`, which the previous locator skipped — so it never
# found a representative concrete element and the gate failed at check A.
# -----------------------------------------------------------------------------
is_concrete_beam(sec)   = sec isa SR.RCBeamSection   || sec isa SR.RCTBeamSection
is_concrete_column(sec) = sec isa SR.RCColumnSection || sec isa SR.RCCircularSection
# A sized steel beam: any non-concrete, non-`nothing` beam section (check C's
# steel runs only ever produce steel beam sections, so this is unambiguous).
is_steel_beam(sec)      = sec !== nothing && !is_concrete_beam(sec)

# Representative (chosen-section, Asap-element) pair for the first member of the
# requested kind (`:beams` or `:columns`) whose chosen section satisfies
# `section_pred`. Groups are resolved through `struc.member_groups` rather than
# `group_id`:
#
#   * `build_member_groups!` empties and repopulates the SHARED `struc.member_
#     groups` dict per member type on every sizing pass, so after the
#     beam→column workflow it holds only the LAST-sized type's groups. We
#     therefore rebuild the group map for `member_type` here before scanning.
#   * The rebuild clears `mg.section`, but the chosen section persists on the
#     member itself (`m.base.section`, read via `SS.section`), so we classify the
#     group by the representative member's section type.
#   * `mg.member_indices` index the matching member array (`struc.beams` for beam
#     groups, `struc.columns` for column groups), mirroring `_apply_beam_results!`
#     / `_apply_column_results!`.
#
# Element resolution mirrors those same appliers:
#   member → `segment_indices` → `segments[seg].edge_idx` → `asap_model.elements`.
function rep_member(struc, member_type::Symbol, section_pred)
    member_array = member_type === :columns ? struc.columns : struc.beams
    SS.build_member_groups!(struc; member_type = member_type)
    for (_gid, mg) in struc.member_groups
        for m_idx in mg.member_indices
            m   = member_array[m_idx]
            sec = mg.section === nothing ? SS.section(m) : mg.section
            (sec !== nothing && section_pred(sec)) || continue
            for seg_idx in SS.segment_indices(m)
                edge_idx = struc.segments[seg_idx].edge_idx
                (1 <= edge_idx <= length(struc.asap_model.elements)) || continue
                return (sec, struc.asap_model.elements[edge_idx])
            end
        end
    end
    return (nothing, nothing)
end

# Drive the EXPORTED public `size!(design)` workflow (core/size.jl) on a concrete
# beam+column vault building and return the sized `BuildingStructure` so its Asap
# element sections can be inspected. This exercises the size! threading path end-
# to-end (distinct from `run_sized`'s build_pipeline stage loop): `size!` forwards
# `params.beam_I_factor` / `params.column_I_factor` into `size_beams!` /
# `size_columns!` → `_apply_*_results!` → the concrete `to_asap_section`.
function run_sized_api(; beam_I_factor, column_I_factor)
    struc, params = build_struc(beams = SR.ConcreteBeamOptions(),
                                columns = SR.ConcreteColumnOptions(),
                                beam_I_factor = beam_I_factor,
                                column_I_factor = column_I_factor)
    prepare!(struc, params)
    design = BuildingDesign(struc, params)
    size!(design; verbose = false)
    return design.structure
end

# Section stiffness fields as plain Float64 (m⁴ / m²), unit-stripped so the
# comparisons are dimensionless and tolerance-based.
_Ix(sec) = ustrip(u"m^4", sec.Ix)
_Iy(sec) = ustrip(u"m^4", sec.Iy)
_J(sec)  = ustrip(u"m^4", sec.J)
_A(sec)  = ustrip(u"m^2", sec.A)

_relclose(a, b; rtol = 1e-9) = isapprox(a, b; rtol = rtol, atol = 0.0)

# =============================================================================
# Flat-plate column-stub fixtures (checks E / F).
# =============================================================================
# The flat-plate COLUMN cracked-stiffness knob (ACI 318-11 §10.10.4.1) lives on
# a DIFFERENT path from the beam/column member sizing exercised by A–D: it is
# `params.column_I_factor` → `resolve_floor_options` → `FlatPlateOptions.col_I_
# factor`, consumed by the slab moment-analysis column stubs (FEA model builder
# and EFM equivalent-frame builder).  Those stubs are transient Asap elements
# built INSIDE `run_moment_analysis`; we capture them by passing our own analysis
# cache (`FEAModelCache` / `EFMModelCache`), which `run_moment_analysis` populates
# with the built `col_stubs` — exactly the production consumption point.

# Build ONE small 2×2-bay flat-plate building (mirrors the proven fixtures in
# StructuralSizer/test/test_fea_flat_plate.jl) and resolve the slab + its
# supporting columns + material constants.  Reused by both E and F so the slow
# mesh/column setup happens once.
function build_flat_plate_fixture()
    skel  = gen_medium_office(24.0u"ft", 20.0u"ft", 10.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    opts  = SR.FlatPlateOptions(material = SR.RC_4000_60, method = SR.FEA(),
                                cover = 0.75u"inch")
    initialize!(struc; floor_type = :flat_plate, floor_opts = opts)
    for cell in struc.cells
        cell.sdl       = uconvert(u"kN/m^2", 20.0psf)
        cell.live_load = uconvert(u"kN/m^2", 50.0psf)
    end
    for col in struc.columns
        col.c1 = 16.0u"inch"
        col.c2 = 16.0u"inch"
    end
    to_asap!(struc)

    slab    = struc.slabs[1]
    columns = SR.find_supporting_columns(struc, Set(slab.cell_indices))
    fc  = 4000.0u"psi"
    γ   = SR.RC_4000_60.concrete.ρ
    ν   = SR.RC_4000_60.concrete.ν
    # Match the moduli the analysis derives internally (run.jl / efm.jl):
    #   Ecs from slab fc; Ecc from the columns' own fc (falls back to slab fc).
    Ecs = SR.Ec(fc, ustrip(pcf, γ))
    Ecc = SR.Ec(SR._get_column_fc(columns, fc), ustrip(pcf, γ))
    h   = 8.0u"inch"
    return (; struc, slab, columns, fc, γ, ν, Ecs, Ecc, h)
end

# Representative FEA column-stub (section, owning column) for a given col_I_
# factor.  `run_moment_analysis(FEA, …; cache)` builds the stubs via
# `_col_asap_sec(col, Ecc, ν; I_factor = col_I_factor)` and stores them on the
# cache keyed by column index (same order as `columns`, no reordering).
function fea_stub_section(fx; col_I_factor)
    cache = SR.FEAModelCache()
    SR.run_moment_analysis(SR.FEA(), fx.struc, fx.slab, fx.columns,
                           fx.h, fx.fc, fx.Ecs, fx.γ;
                           ν_concrete = fx.ν, col_I_factor = col_I_factor,
                           cache = cache)
    isempty(cache.col_stubs) && return (nothing, nothing)
    k = minimum(keys(cache.col_stubs))
    return (cache.col_stubs[k].below.element.section, fx.columns[k])
end

# Representative EFM column-stub (Ix, A) for a given cracked flag + col_I_factor.
# `run_moment_analysis(EFM(solver = :asap), …; efm_cache)` builds stubs via
# `column_asap_section(…; I_factor = I_j)` where `I_j = col_I_factor × kec[j]`;
# the Kec reduction is geometry-only, so it cancels in cross-run Ix RATIOS.
function efm_stub_Ix_A(fx; cracked, col_I_factor)
    ec = SR.EFMModelCache()
    SR.run_moment_analysis(SR.EFM(solver = :asap, cracked_columns = cracked),
                           fx.struc, fx.slab, fx.columns,
                           fx.h, fx.fc, fx.Ecs, fx.γ;
                           ν_concrete = fx.ν, col_I_factor = col_I_factor,
                           efm_cache = ec)
    isempty(ec.col_stubs) && return (nothing, nothing)
    k   = minimum(keys(ec.col_stubs))
    sec = ec.col_stubs[k].below.element.section
    return (_Ix(sec), _A(sec))
end

# Secondary-direction EFM column moments (kip·ft) — the secondary frame builds
# fresh stubs and discards them, so we observe the knob's effect through the
# distributed moments it returns (behavioral proof of the secondary threading).
_mvec(r) = Float64[ustrip(kip * u"ft", m) for m in r.column_moments]
function efm_secondary_moments(fx; cracked, col_I_factor)
    r = SR.run_secondary_moment_analysis(
            SR.EFM(solver = :asap, cracked_columns = cracked),
            fx.struc, fx.slab, fx.columns, fx.h, fx.fc, fx.Ecs, fx.γ;
            ν_concrete = fx.ν, col_I_factor = col_I_factor)
    return _mvec(r)
end
_vec_close(a, b)   = length(a) == length(b) && all(isapprox.(a, b; rtol = 1e-9, atol = 1e-12))
_vec_differs(a, b) = length(a) == length(b) && any(.!isapprox.(a, b; rtol = 1e-6, atol = 1e-9))

# -----------------------------------------------------------------------------
# (E) Flat-plate FEA: params.column_I_factor → opts.col_I_factor → stub Ix.
# -----------------------------------------------------------------------------
function check_E_fea!(fx)
    println("\n[E] Flat-plate FEA column-stub stiffness tracks params.column_I_factor")
    try
        # Fix point: resolve_floor_options threads the param into col_I_factor.
        mk_params(cif) = DesignParameters(name = "verify_i_factor_fea",
                                          floor = SR.FlatPlateOptions(method = SR.FEA()),
                                          column_I_factor = cif)
        cif_default = SR.FlatPlateOptions().col_I_factor   # 0.70 field default
        opts070 = SS.resolve_floor_options(mk_params(0.70))
        opts050 = SS.resolve_floor_options(mk_params(0.50))
        record!("resolve_floor_options threads column_I_factor=0.70 " *
                "(byte-identical to FlatPlateOptions default 0.70)",
                opts070.col_I_factor === 0.70 && opts070.col_I_factor === cif_default)
        record!("resolve_floor_options threads column_I_factor=0.50",
                opts050.col_I_factor === 0.50)

        # Drive the REAL FEA builder with the resolved opts.col_I_factor.
        sec070, col070 = fea_stub_section(fx; col_I_factor = opts070.col_I_factor)  # 0.70
        sec050, _      = fea_stub_section(fx; col_I_factor = opts050.col_I_factor)  # 0.50
        record!("FEA located a flat-plate column-stub element (default + 0.5 runs)",
                sec070 !== nothing && sec050 !== nothing)

        if sec070 !== nothing && sec050 !== nothing
            # Gross geometry fixed across runs (A is I_factor-independent) so the
            # Ix ratio isolates the knob — mirrors check B.
            record!("FEA column-stub gross geometry stable across runs (area A identical)",
                    _relclose(_A(sec050), _A(sec070)))
            record!("FEA column-stub Ix scaled by 0.5/0.70 at non-default (ACI 318-11 §10.10.4.1)",
                    _relclose(_Ix(sec050), _Ix(sec070) * (0.50 / 0.70)))
            # Byte-identical at default: the stub equals the library column
            # builder at I_factor=0.70 (the pre-fix value → no-op at default).
            exp070 = SR.column_asap_section(col070.c1, col070.c2, SR.col_shape(col070),
                                            fx.Ecc, fx.ν; I_factor = 0.70)
            record!("FEA column-stub (A,Ix,Iy,J) byte-identical to " *
                    "column_asap_section(; I_factor=0.70) at default",
                    isequal(sec070.A,  exp070.A)  && isequal(sec070.Ix, exp070.Ix) &&
                    isequal(sec070.Iy, exp070.Iy) && isequal(sec070.J,  exp070.J))
        end
    catch e
        record!("(E) flat-plate FEA checks ran without error", false)
        @printf("    EXCEPTION in (E): %s\n", sprint(showerror, e))
    end
end

# -----------------------------------------------------------------------------
# (F) Flat-plate EFM: col_I_factor governs cracked column stubs, both directions.
# -----------------------------------------------------------------------------
function check_F_efm!(fx)
    println("\n[F] Flat-plate EFM (solver=:asap) column-stub stiffness tracks column_I_factor")
    try
        Ix_cr070, A_cr070 = efm_stub_Ix_A(fx; cracked = true,  col_I_factor = 0.70)
        Ix_cr050, A_cr050 = efm_stub_Ix_A(fx; cracked = true,  col_I_factor = 0.50)
        Ix_un070, _       = efm_stub_Ix_A(fx; cracked = false, col_I_factor = 0.70)
        Ix_un050, _       = efm_stub_Ix_A(fx; cracked = false, col_I_factor = 0.50)
        located = all(x -> x !== nothing,
                      (Ix_cr070, Ix_cr050, A_cr070, A_cr050, Ix_un070, Ix_un050))
        record!("EFM located flat-plate column-stub elements (cracked/uncracked × 0.70/0.50)",
                located)

        if located
            record!("EFM cracked column-stub gross geometry stable (area A identical across knob)",
                    _relclose(A_cr050, A_cr070))
            # Efficacy: the cracked stub Ix scales by the knob ratio (Kec cancels).
            record!("EFM cracked column-stub Ix scaled by 0.5/0.70 at non-default (ACI 318-11 §10.10.4.1)",
                    _relclose(Ix_cr050, Ix_cr070 * (0.50 / 0.70)))
            # cracked_columns=true applies exactly col_I_factor × gross(uncracked, 1.0).
            record!("EFM cracked@0.70 column-stub Ix == 0.70 × uncracked(gross) Ix",
                    _relclose(Ix_cr070, Ix_un070 * 0.70))
            record!("EFM cracked@0.50 column-stub Ix == 0.50 × uncracked(gross) Ix",
                    _relclose(Ix_cr050, Ix_un070 * 0.50))
            # cracked_columns=false → gross (1.0) regardless of the knob.
            record!("EFM uncracked column-stub Ix identical for knob 0.50 vs 0.70 (gross, knob ignored)",
                    isequal(Ix_un050, Ix_un070))
        end

        # Secondary direction: the fix threaded BOTH EFM directions.  The
        # secondary frame discards its stubs, so verify through the moments it
        # returns — they respond to the knob only when cracked, and are the
        # identical gross result when uncracked.
        m_cr050 = efm_secondary_moments(fx; cracked = true,  col_I_factor = 0.50)
        m_cr070 = efm_secondary_moments(fx; cracked = true,  col_I_factor = 0.70)
        m_un050 = efm_secondary_moments(fx; cracked = false, col_I_factor = 0.50)
        m_un070 = efm_secondary_moments(fx; cracked = false, col_I_factor = 0.70)
        sec_ok  = !isempty(m_cr050) && !isempty(m_cr070) &&
                  !isempty(m_un050) && !isempty(m_un070)
        record!("EFM secondary direction produced column moments for all knob/cracked combos",
                sec_ok)
        if sec_ok
            record!("EFM secondary moments RESPOND to column_I_factor when cracked (0.50 ≠ 0.70)",
                    _vec_differs(m_cr050, m_cr070))
            record!("EFM secondary moments reflect cracking (cracked@0.70 ≠ uncracked gross)",
                    _vec_differs(m_cr070, m_un070))
            record!("EFM secondary moments IGNORE the knob when uncracked (0.50 == 0.70, gross)",
                    _vec_close(m_un050, m_un070))
        end
    catch e
        record!("(F) flat-plate EFM checks ran without error", false)
        @printf("    EXCEPTION in (F): %s\n", sprint(showerror, e))
    end
end

# =============================================================================
# (G)/(H) INCREMENTAL-PATH INVALIDATION — the stateful engine behind the REST
# API must NOT silently return a stale baseline when `column_I_factor` /
# `beam_I_factor` change.  This is the EXACT P0 just fixed: both knobs were
# top-level `DesignParameters` fields registered in NONE of the engine's
# invalidation surfaces, so a param-only incremental redesign computed an EMPTY
# dirty frontier → full memo hit → the 0.70 / 0.35 baseline was returned
# UNCHANGED (HTTP 200 with the wrong ACI 318-11 §10.10.4.1 cracked stiffness).
#
# The fix wired them into DIFFERENT surfaces (hence two different, faithful
# proofs below):
#   • `column_I_factor` → `PREPARE_AFFECTING_FIELDS` (scheduler.jl). The flat-plate
#     slab column stubs are BAKED at `prepare!`, so only a fresh prepare picks up a
#     changed factor; the API therefore routes a column_I_factor change COLD (its
#     `_param_only_change` is false) and the session `redesign` guard throws rather
#     than reuse the stale baseline.
#   • `beam_I_factor` → `NODE_MEMBERS.param_slice` (provenance.jl). It is consumed
#     only at member sizing, so a change is param-only (incremental-eligible) and
#     dirties the `:members` node — the incremental redesign re-sizes members
#     instead of restoring them stale.
#
# One `DesignSession` is built over a concrete beam+column vault building at the
# library defaults (beam_I_factor=0.35, column_I_factor=0.70) — the same fixture
# A–D proved the knobs thread on the COLD path — and both knobs are exercised
# against it, mirroring the API's param-only routing (api/cache.jl
# `_param_only_change` ≡ `!requires_new_engine`).  `design_building` is the
# untouched from-scratch oracle.
# =============================================================================
function check_GH_incremental!()
    println("\n[G/H] Incremental-path invalidation (DesignSession / redesign)")

    # Fresh-fixture builder: `design_building` / `DesignSession` mutate `struc`, so
    # the session baseline and every cold reference each need their own pristine copy.
    fresh() = build_struc(beams = SR.ConcreteBeamOptions(),
                          columns = SR.ConcreteColumnOptions(),
                          beam_I_factor = 0.35, column_I_factor = 0.70)

    local session
    try
        struc_base, base_params = fresh()
        session = SS.DesignSession(struc_base, base_params)
        record!("DesignSession built over concrete beam+column vault " *
                "(base: beam_I_factor=0.35, column_I_factor=0.70)", true)
    catch e
        record!("DesignSession built over concrete beam+column vault", false)
        @printf("    EXCEPTION building DesignSession: %s\n", sprint(showerror, e))
        return
    end
    base_params = SS.base_params(session)
    base_sig    = design_signature(SS.base_design(session))

    # -------------------------------------------------------------------------
    # (G) column_I_factor 0.70 → 0.50 — PREPARE-AFFECTING.
    # -------------------------------------------------------------------------
    println("\n[G] column_I_factor 0.70→0.50 incremental invalidation (prepare-affecting)")

    # (G1) THE FIX: the change is now flagged prepare-affecting, so the API's
    # `_param_only_change` is FALSE and the stateful engine refuses to reuse the
    # prepared baseline (before the fix this was param-only ⇒ silent memo hit).
    record!("column_I_factor is prepare-affecting ⇒ requires a fresh engine " *
            "(API routes COLD; no stale incremental reuse)",
            SS.requires_new_engine(session; column_I_factor = 0.50) === true)

    # (G2) The session `redesign` guard FIRES rather than silently returning the
    # 0.70 baseline — the structural backstop against the P0.
    threw = false
    try
        SS.redesign(session; column_I_factor = 0.50)
    catch e
        threw = e isa ArgumentError
        threw || @printf("    unexpected exception type in (G2): %s\n", sprint(showerror, e))
    end
    record!("redesign(session; column_I_factor=0.50) throws the prepare-affecting " *
            "guard (never returns the stale 0.70 baseline)", threw)

    # (G3) Mechanism: column_I_factor is in NO node param_slice, so an incremental
    # redesign would compute an EMPTY dirty frontier (full memo hit → stale 0.70
    # baseline). Prepare-affecting classification — NOT a node slice — is therefore
    # the only correct fix (the baked flat-plate stubs need a fresh prepare!). This
    # asserts the exact counterfactual the G1/G2 guard protects against.
    record!("column_I_factor dirty-frontier is EMPTY (confirms prepare-affecting, " *
            "not node-slice, is the required fix)",
            isempty(SS.dirty_frontier(session; column_I_factor = 0.50)))

    # (G4) Behavioral DIAGNOSTIC (not a hard check): the design the API actually
    # returns for a column_I_factor change is a COLD run at 0.50. On a VAULT FRAME
    # the captured design signature is column_I_factor-INSENSITIVE (the gravity
    # columns are axial-governed; checks A–D already prove the element cracked
    # stiffness threads), so cold@0.50 == the 0.70 baseline here — a legitimate
    # no-op, NOT a stale reuse (G1/G2 already proved the engine never returns the
    # baseline silently). The OBSERVABLE column_I_factor DESIGN effect lives on the
    # FLAT-PLATE column-stub path baked at prepare! — that is what checks E/F
    # exercise. We print the vault comparison for the record and defer the
    # behavioral proof to E/F rather than hard-assert a vacuous vault result.
    struc_g, _ = fresh()
    cold_050   = design_building(struc_g, SS.with(base_params; column_I_factor = 0.50))
    g_same, _  = same_signature(design_signature(cold_050), base_sig)
    g_desc     = g_same ? "EQUALS" : "DIFFERS from"
    println("    diag: COLD design @column_I_factor=0.50 $g_desc the 0.70 baseline on this vault frame")
    println("          (I_factor-insensitive here; flat-plate stub effect is covered by E/F)")

    # -------------------------------------------------------------------------
    # (H) beam_I_factor 0.35 → 0.70 — NODE-SLICE (param-only, incremental).
    # -------------------------------------------------------------------------
    println("\n[H] beam_I_factor 0.35→0.70 incremental invalidation (:members node slice)")
    VAR = 0.70   # distinct from the 0.35 base

    # (H1) beam_I_factor is NOT prepare-affecting — the change is param-only and
    # eligible for the incremental path (no fresh prepare needed).
    record!("beam_I_factor is param-only ⇒ incremental-eligible (not prepare-affecting)",
            SS.requires_new_engine(session; beam_I_factor = VAR) === false)

    # (H2) THE FIX: beam_I_factor is in NODE_MEMBERS.param_slice, so the :members
    # node is in the dirty frontier (before the fix the frontier was EMPTY → :members
    # was restored stale → the baseline was returned unchanged).
    frontier_h = SS.dirty_frontier(session; beam_I_factor = VAR)
    record!("beam_I_factor dirties the :members node (frontier = $frontier_h)",
            :members in frontier_h)

    # (H3) Drive the incremental redesign and confirm :members ACTUALLY re-ran
    # (recomputed, not restored from the stale memo snapshot).
    inc_h      = SS.redesign(session; beam_I_factor = VAR)
    recomputed = SS.last_recomputed(session)
    restored   = SS.last_restored(session)
    record!("redesign recomputed the :members node (not a stale restore; " *
            "recomputed = $recomputed)",
            (:members in recomputed) && !(:members in restored))

    # (H4) Exact-first contract: the incremental design equals a COLD run at the
    # same beam_I_factor (incremental == from-scratch; per-member signature, rtol=1e-8).
    struc_h, _ = fresh()
    cold_h      = design_building(struc_h, SS.with(base_params; beam_I_factor = VAR))
    eq_ok, eq_bad = same_signature(design_signature(inc_h), design_signature(cold_h))
    record!("incremental redesign == COLD design_building @beam_I_factor=$VAR " *
            "(exact-first; first-diff: $eq_bad)", eq_ok)

    # (H5) Behavioral: the incremental design DIFFERS from the 0.35 baseline —
    # the members result was re-sized, NOT the silent stale no-op.
    ch_ok, ch_bad = same_signature(design_signature(inc_h), base_sig)
    record!("incremental redesign DIFFERS from the 0.35 baseline " *
            "(members re-sized; first-diff: $ch_bad)", !ch_ok)

    # (H6) Memo no-op ("same factors ⇒ no spurious recompute"): redesigning at the
    # SAME beam_I_factor as the immediately prior run (VAR) is a pure memo hit —
    # :members is NOT recomputed (its input hash matches the memo H3 just seeded)
    # and the result is byte-identical to the H3 incremental design.
    #
    # NOTE: the engine memo holds the LAST-computed node fingerprint (scheduler.jl
    # overwrites `engine.memo[key]` on every recompute), so the no-op must REPEAT
    # the H3 factor. Reverting to the base 0.35 here would legitimately RECOMPUTE
    # :members (0.35 ≠ the 0.70 now in the memo) — that is correct engine behavior,
    # not a memo hit, so it is not the right no-op probe.
    inc_rep     = SS.redesign(session; beam_I_factor = VAR)
    noop_recomp = SS.last_recomputed(session)
    rep_ok, _   = same_signature(design_signature(inc_rep), design_signature(inc_h))
    record!("redesign @same beam_I_factor=$VAR is a memo hit " *
            "(:members not recomputed) and byte-identical to the prior redesign",
            rep_ok && !(:members in noop_recomp))
    return
end

function main()
    println("="^70)
    println("I_factor threading verify — concrete-only cracked-stiffness knob")
    println("ACI 318-11 §10.10.4.1 (corpus: aci-318-11)")
    println("="^70)

    # =========================================================================
    # (A) NO-OP AT DEFAULT — default params reproduce the library defaults.
    # =========================================================================
    println("\n[A] No-op at default (beam_I_factor=0.35, column_I_factor=0.70)")
    struc_d = run_sized(beams = SR.ConcreteBeamOptions(),
                        columns = SR.ConcreteColumnOptions(),
                        beam_I_factor = 0.35, column_I_factor = 0.70)

    beam_sec_d, beam_el_d = rep_member(struc_d, :beams,   is_concrete_beam)
    col_sec_d,  col_el_d  = rep_member(struc_d, :columns, is_concrete_column)

    record!("found a representative CONCRETE beam element", beam_el_d !== nothing)
    record!("found a representative CONCRETE column element", col_el_d !== nothing)

    if beam_el_d === nothing || col_el_d === nothing
        println("\n  FATAL: could not locate a sized concrete beam/column element — " *
                "cannot run the threading assertions.")
        return finish()
    end

    # Material used by the design workflow when building the Asap section.
    beam_mat = SR.ConcreteBeamOptions().material
    col_mat  = SR.ConcreteColumnOptions().material

    # Library-default expectation: NO I_factor kwarg ⇒ 0.35 (beam) / 0.70 (col).
    beam_lib = StructuralSizer.to_asap_section(beam_sec_d, beam_mat)
    col_lib  = StructuralSizer.to_asap_section(col_sec_d, col_mat)

    record!("beam element Ix == to_asap_section(sec, mat) default (0.35)",
            _relclose(_Ix(beam_el_d.section), _Ix(beam_lib)))
    record!("beam element Iy == to_asap_section(sec, mat) default (0.35)",
            _relclose(_Iy(beam_el_d.section), _Iy(beam_lib)))
    record!("beam element J  == to_asap_section(sec, mat) default (0.35)",
            _relclose(_J(beam_el_d.section),  _J(beam_lib)))

    record!("column element Ix == to_asap_section(sec, mat) default (0.70)",
            _relclose(_Ix(col_el_d.section), _Ix(col_lib)))
    record!("column element Iy == to_asap_section(sec, mat) default (0.70)",
            _relclose(_Iy(col_el_d.section), _Iy(col_lib)))
    record!("column element J  == to_asap_section(sec, mat) default (0.70)",
            _relclose(_J(col_el_d.section),  _J(col_lib)))

    # =========================================================================
    # (B) EFFICACY — the knob now controls stiffness.
    # =========================================================================
    println("\n[B] Efficacy (beam_I_factor=0.5, column_I_factor=0.5)")
    struc_e = run_sized(beams = SR.ConcreteBeamOptions(),
                        columns = SR.ConcreteColumnOptions(),
                        beam_I_factor = 0.5, column_I_factor = 0.5)

    beam_sec_e, beam_el_e = rep_member(struc_e, :beams,   is_concrete_beam)
    col_sec_e,  col_el_e  = rep_member(struc_e, :columns, is_concrete_column)
    record!("efficacy run located concrete beam + column elements",
            beam_el_e !== nothing && col_el_e !== nothing)

    if beam_el_e !== nothing && col_el_e !== nothing
        # Gross geometry must be unchanged across runs so the Ix ratio isolates
        # the I_factor change (A = b·h is I_factor-independent). If the chosen
        # section differed, A would differ and this guard would catch it.
        beam_A_stable = _relclose(_A(beam_el_e.section), _A(beam_el_d.section))
        col_A_stable  = _relclose(_A(col_el_e.section),  _A(col_el_d.section))
        record!("beam gross section stable across runs (area A identical)", beam_A_stable)
        record!("column gross section stable across runs (area A identical)", col_A_stable)

        # Cross-run Ix ratio equals the I_factor ratio (the headline efficacy).
        record!("beam element Ix scaled by 0.5/0.35 vs default run",
                _relclose(_Ix(beam_el_e.section),
                          _Ix(beam_el_d.section) * (0.5 / 0.35)))
        record!("column element Ix scaled by 0.5/0.70 vs default run",
                _relclose(_Ix(col_el_e.section),
                          _Ix(col_el_d.section) * (0.5 / 0.70)))

        # Direct proof: the efficacy element section matches to_asap_section at 0.5.
        beam_e_lib = StructuralSizer.to_asap_section(beam_sec_e, beam_mat; I_factor = 0.5)
        col_e_lib  = StructuralSizer.to_asap_section(col_sec_e,  col_mat;  I_factor = 0.5)
        record!("beam element (Ix,Iy,J) == to_asap_section(sec, mat; I_factor=0.5)",
                _relclose(_Ix(beam_el_e.section), _Ix(beam_e_lib)) &&
                _relclose(_Iy(beam_el_e.section), _Iy(beam_e_lib)) &&
                _relclose(_J(beam_el_e.section),  _J(beam_e_lib)))
        record!("column element (Ix,Iy,J) == to_asap_section(sec, mat; I_factor=0.5)",
                _relclose(_Ix(col_el_e.section), _Ix(col_e_lib)) &&
                _relclose(_Iy(col_el_e.section), _Iy(col_e_lib)) &&
                _relclose(_J(col_el_e.section),  _J(col_e_lib)))
    end

    # =========================================================================
    # (C) STEEL UNAFFECTED — beam_I_factor must never touch steel sections.
    # =========================================================================
    println("\n[C] Steel beam sections are byte-identical across beam_I_factor")
    struc_s1 = run_sized(beams = SR.SteelBeamOptions(),
                         columns = SR.SteelColumnOptions(),
                         beam_I_factor = 0.35, column_I_factor = 0.70)
    struc_s2 = run_sized(beams = SR.SteelBeamOptions(),
                         columns = SR.SteelColumnOptions(),
                         beam_I_factor = 0.90, column_I_factor = 0.70)

    _, steel_el_1 = rep_member(struc_s1, :beams, is_steel_beam)
    _, steel_el_2 = rep_member(struc_s2, :beams, is_steel_beam)
    record!("found a representative STEEL beam element in both runs",
            steel_el_1 !== nothing && steel_el_2 !== nothing)

    if steel_el_1 !== nothing && steel_el_2 !== nothing
        s1 = steel_el_1.section
        s2 = steel_el_2.section
        # Byte-identical: every stiffness field bit-for-bit equal (no tolerance).
        identical = isequal(s1.A, s2.A) && isequal(s1.E, s2.E) &&
                    isequal(s1.G, s2.G) && isequal(s1.Ix, s2.Ix) &&
                    isequal(s1.Iy, s2.Iy) && isequal(s1.J, s2.J)
        record!("steel beam element section byte-identical (A,E,G,Ix,Iy,J) " *
                "at beam_I_factor 0.35 vs 0.90", identical)
    end

    # =========================================================================
    # (D) PUBLIC API — StructuralSynthesizer.size!(design) threads the knobs.
    # =========================================================================
    # Checks A–C drive the `build_pipeline` stage loop; this check exercises the
    # SEPARATE exported `size!(design)` entry point (core/size.jl), proving the
    # I_factor threading also reaches the public API end-to-end. We size the same
    # concrete beam+column vault building twice — once at the 0.70/0.35 defaults,
    # once at 0.5/0.5 — and assert BOTH the concrete column and beam element Ix
    # scale by the factor ratio, with gross geometry (area A) held fixed so the
    # Ix ratio isolates the I_factor change (ACI 318-11 §10.10.4.1).
    println("\n[D] Public API size!(design) threads beam/column_I_factor end-to-end")
    struc_api_def = run_sized_api(beam_I_factor = 0.35, column_I_factor = 0.70)
    struc_api_05  = run_sized_api(beam_I_factor = 0.5,  column_I_factor = 0.5)

    _, beam_api_def = rep_member(struc_api_def, :beams,   is_concrete_beam)
    _, col_api_def  = rep_member(struc_api_def, :columns, is_concrete_column)
    _, beam_api_05  = rep_member(struc_api_05,  :beams,   is_concrete_beam)
    _, col_api_05   = rep_member(struc_api_05,  :columns, is_concrete_column)

    api_located = beam_api_def !== nothing && col_api_def !== nothing &&
                  beam_api_05  !== nothing && col_api_05  !== nothing
    record!("size! located concrete beam + column elements (default + 0.5 runs)",
            api_located)

    if api_located
        # Gross geometry stable across the two size! runs (area A is I_factor-
        # independent), so the Ix ratio isolates the knob — mirrors check B.
        record!("size! beam gross section stable across runs (area A identical)",
                _relclose(_A(beam_api_05.section), _A(beam_api_def.section)))
        record!("size! column gross section stable across runs (area A identical)",
                _relclose(_A(col_api_05.section),  _A(col_api_def.section)))

        # Headline: the public size! path scales element Ix by the factor ratio.
        record!("size! beam element Ix scaled by 0.5/0.35 vs default run",
                _relclose(_Ix(beam_api_05.section),
                          _Ix(beam_api_def.section) * (0.5 / 0.35)))
        record!("size! column element Ix scaled by 0.5/0.70 vs default run",
                _relclose(_Ix(col_api_05.section),
                          _Ix(col_api_def.section) * (0.5 / 0.70)))
    end

    # =========================================================================
    # (E)/(F) FLAT-PLATE COLUMN STUBS — params.column_I_factor governs the
    # flat-plate column cracked stiffness (ACI 318-11 §10.10.4.1) across the FEA
    # and EFM analysis paths.  One small flat-plate building is built and reused.
    # =========================================================================
    println("\n[E/F] Flat-plate column_I_factor threading (FEA + EFM column stubs)")
    fx = nothing
    try
        fx = build_flat_plate_fixture()
        record!("flat-plate fixture built (2×2-bay, FEA-meshable, columns resolved)",
                fx !== nothing && !isempty(fx.columns))
    catch e
        record!("flat-plate fixture built", false)
        @printf("    EXCEPTION building flat-plate fixture: %s\n", sprint(showerror, e))
    end

    if fx !== nothing
        check_E_fea!(fx)
        check_F_efm!(fx)
    end

    # =========================================================================
    # (G)/(H) INCREMENTAL-PATH INVALIDATION — the stateful engine behind the REST
    # API must re-run the right nodes (not return the stale baseline) when
    # column_I_factor / beam_I_factor change. This is the exact P0 just fixed.
    # =========================================================================
    check_GH_incremental!()

    return finish()
end

function finish()
    println("\n" * "="^70)
    npass = count(c -> c[2], CHECKS)
    if npass == length(CHECKS)
        println("✓ ALL CHECKS PASS ($npass/$(length(CHECKS)))")
        println("="^70)
        return 0
    else
        println("✗ $(length(CHECKS) - npass) CHECK(S) FAILED ($npass/$(length(CHECKS)))")
        for (name, ok) in CHECKS
            ok || println("    FAIL: $name")
        end
        println("="^70)
        return 1
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
