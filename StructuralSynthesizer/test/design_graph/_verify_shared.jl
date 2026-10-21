# =============================================================================
# Shared verify fixtures / invariants — single canonical copy
# =============================================================================
#
# This `include`-only file (no module, no `using`, no `Pkg`) holds the ONE
# canonical copy of the verify helpers that were previously byte-identical
# copy-pastes across the exact-first verify runners under `scripts/runners/`:
#
#   • INVARIANT_COLS   — the 15-column aggregate invariant set.
#                        (verify_design_graph.jl, verify_design_graph_incremental.jl)
#   • design_signature — the comprehensive per-member output signature.
#                        (verify_design_graph_incremental.jl, verify_incremental_engine.jl)
#   • same_signature   — the signature comparator.
#                        (verify_design_graph_incremental.jl, verify_incremental_engine.jl)
#
# This is a REFACTOR: the three definitions below are copied VERBATIM from
# `verify_design_graph_incremental.jl` (the most complete runner). No field,
# tolerance, reduction, unit, or formula was changed — the dedup is purely
# mechanical so the exact-first safety gates keep their exact behavior.
#
# It is `include`d (textually, into the includer's global scope) from each
# runner AFTER that runner's `using Asap / StructuralSizer / StructuralSynthesizer
# / Unitful` preamble. Those packages MUST already be loaded, because:
#   - `design_signature(design::BuildingDesign)` annotates a StructuralSynthesizer
#     type, resolved at method-definition (include) time, and
#   - its body expands `u"kgCO2e"`, a unit registered by `Asap` at macro-
#     expansion (include) time.
#
# CONTRACT — `_close`: `same_signature` calls `_close(a, b)`, which is LEFT LOCAL
# to each including file and intentionally NOT consolidated here. The runners'
# `_close` copies are deliberately divergent in FORM (a docstring'd multiline
# copy, a bare one-liner, …), so moving one here would alter another file
# byte-for-byte. Every runner that includes this file already defines a
# `_close(a, b; rtol = 1e-8, atol = 1e-10)` with identical numeric behavior, which
# `same_signature` late-binds at call time (Julia resolves the free global in the
# includer's scope). This preserves each runner's own `_close` exactly.
#
# HARD HAZARD: this file MUST NOT activate or load `StructuralStudies` — doing so
# spawns a SECOND `Asap` package identity (documented in the speedup runner). It
# depends ONLY on StructuralSynthesizer + its existing deps, exactly as the
# runners already do; it performs NO `using` / `Pkg` of its own and relies solely
# on the includer's preamble.
# =============================================================================

# -----------------------------------------------------------------------------
# Invariant set — the 15 aggregate columns asserted at rtol=1e-8. Verbatim copy
# shared by verify_design_graph.jl and verify_design_graph_incremental.jl.
# -----------------------------------------------------------------------------
const INVARIANT_COLS = (
    :h_m, :M0_kNm,
    :punch_ratio, :defl_ratio,
    :As_cs_in2, :As_ms_in2, :As_total_in2,
    :col_min_in, :col_max_in,
    :ec_total_kgco2e, :ec_per_area_kgco2e_m2,
    :fdn_max_B_ft, :fdn_max_L_ft, :fdn_max_D_in, :fdn_max_util,
)

# -----------------------------------------------------------------------------
# Comprehensive per-member design signature (P2 hardening).
# -----------------------------------------------------------------------------
# The 15 INVARIANT_COLS above are an AGGREGATE summary (global maxima); they are
# NOT bit-identical — they omit per-member beam sizes, column/beam
# capacity/interaction/axial ratios, ok/feasibility flags, punching stud counts,
# and per-strip rebar, so a provenance omission (e.g. an unpatterned member) can
# slip past them (exactly how the pattern_loading P0 escaped gate 3).
# `design_signature` flattens EVERY such output field into a deterministic
# (label => value) list; equal signatures ⇒ output-equivalent across all compared
# fields (values reduced to plain Float64/Bool/String/Symbol).
function design_signature(design::BuildingDesign)
    sig = Pair{String, Any}[]

    for k in sort(collect(keys(design.columns)))
        c = design.columns[k]
        push!(sig, "col$k.c1_in"             => ustrip(u"inch", c.c1))
        push!(sig, "col$k.c2_in"             => ustrip(u"inch", c.c2))
        push!(sig, "col$k.shape"             => c.shape)
        push!(sig, "col$k.section"           => c.section_size)
        push!(sig, "col$k.axial_ratio"       => c.axial_ratio)
        push!(sig, "col$k.interaction_ratio" => c.interaction_ratio)
        push!(sig, "col$k.ok"                => c.ok)
        if c.punching !== nothing
            push!(sig, "col$k.punch_ratio" => c.punching.ratio)
            push!(sig, "col$k.punch_ok"    => c.punching.ok)
        end
    end

    for k in sort(collect(keys(design.beams)))
        b = design.beams[k]
        push!(sig, "beam$k.section"       => b.section_size)
        push!(sig, "beam$k.flexure_ratio" => b.flexure_ratio)
        push!(sig, "beam$k.shear_ratio"   => b.shear_ratio)
        push!(sig, "beam$k.ok"            => b.ok)
        push!(sig, "beam$k.len_m"         => ustrip(u"m",  b.member_length))
        push!(sig, "beam$k.weight_kg"     => ustrip(u"kg", b.weight))
    end

    for k in sort(collect(keys(design.slabs)))
        s = design.slabs[k]
        push!(sig, "slab$k.thk_m"             => ustrip(u"m", s.thickness))
        push!(sig, "slab$k.M0_kNm"            => isnothing(s.M0) ? NaN : ustrip(u"kN*m", s.M0))
        push!(sig, "slab$k.defl_ratio"        => s.deflection_ratio)
        push!(sig, "slab$k.defl_ok"           => s.deflection_ok)
        push!(sig, "slab$k.punch_ratio"       => s.punching_max_ratio)
        push!(sig, "slab$k.punch_ok"          => s.punching_ok)
        push!(sig, "slab$k.converged"         => s.converged)
        push!(sig, "slab$k.integrity_ok"      => s.integrity_ok)
        push!(sig, "slab$k.has_studs"         => s.has_studs)
        push!(sig, "slab$k.n_stud_cols"       => s.n_stud_cols)
        push!(sig, "slab$k.stud_rails_max"    => s.stud_rails_max)
        push!(sig, "slab$k.stud_per_rail_max" => s.stud_per_rail_max)
        r = s.sizer_result
        if !isnothing(r)
            for fld in (:column_strip_reinf, :middle_strip_reinf,
                        :secondary_column_strip_reinf, :secondary_middle_strip_reinf)
                hasproperty(r, fld) || continue
                for (i, sr) in enumerate(getproperty(r, fld))
                    push!(sig, "slab$k.$fld[$i].As_in2" => ustrip(u"inch^2", sr.As_provided))
                end
            end
        end
    end

    for k in sort(collect(keys(design.foundations)))
        f = design.foundations[k]
        push!(sig, "fdn$k.L_ft"           => ustrip(u"ft",   f.length))
        push!(sig, "fdn$k.W_ft"           => ustrip(u"ft",   f.width))
        push!(sig, "fdn$k.D_in"           => ustrip(u"inch", f.depth))
        push!(sig, "fdn$k.bearing_ratio"  => f.bearing_ratio)
        push!(sig, "fdn$k.punching_ratio" => f.punching_ratio)
        push!(sig, "fdn$k.flexure_ratio"  => f.flexure_ratio)
        push!(sig, "fdn$k.ok"             => f.ok)
        push!(sig, "fdn$k.group_id"       => f.group_id)
    end

    push!(sig, "sum.all_checks_pass"  => design.summary.all_checks_pass)
    push!(sig, "sum.critical_ratio"   => design.summary.critical_ratio)
    push!(sig, "sum.critical_element" => design.summary.critical_element)
    push!(sig, "sum.ec_kgco2e"        => ustrip(u"kgCO2e", design.summary.embodied_carbon))
    return sig
end

"Compare two design signatures; returns (ok, first_mismatch_label)."
function same_signature(a::Vector{Pair{String, Any}}, b::Vector{Pair{String, Any}})
    da = Dict(a); db = Dict(b)
    Set(keys(da)) == Set(keys(db)) || return (false, "field set differs")
    for (k, va) in da
        _close(va, db[k]) || return (false, k)
    end
    return (true, "none")
end
