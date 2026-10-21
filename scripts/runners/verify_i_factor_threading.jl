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
