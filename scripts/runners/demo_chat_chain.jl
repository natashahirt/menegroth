# =============================================================================
# Demo script: exercises the full chat tool chain end-to-end WITHOUT HTTP.
#
# Creates a building with deliberately challenging geometry (long spans, flat
# plate, small-ish columns via grow_columns strategy) + non-optimal params,
# then walks through every chat-tool step a user would encounter:
#
#   1. design_building with punching-stress-inducing geometry
#   2. get_situation_card  → verify failures surface with failing_by_type
#   3. get_diagnose_summary → verify per-type counts + top critical
#   4. query_elements(ok=false) → enumerate every failing element
#   5. suggest_next_action("fix_failures") → lever map + geometry actions
#   6. narrate_element (element inspector) → deterministic fallback
#   7. micro-experiment: punching with larger columns
#   8. micro-experiment: deflection with relaxed limit
#   9. second design with improved params → compare
# =============================================================================

using Test
using Unitful
using StructuralSynthesizer
import StructuralSynthesizer as SS
using StructuralSynthesizer: DESIGN_CACHE, DesignCache,
    agent_situation_card, agent_diagnose_summary, agent_query_elements,
    agent_suggest_next_action, agent_narrate_element, agent_building_summary,
    agent_current_params, agent_compare_designs, agent_predict_geometry_effect,
    experiment_punching, experiment_deflection, list_experiments,
    evaluate_experiment, batch_evaluate,
    design_to_diagnose, condense_result
const record_design_history! = SS.record_design_history!
const DesignHistoryEntry = SS.DesignHistoryEntry
const get_design_history_entries = SS.get_design_history_entries
const clear_design_history! = SS.clear_design_history!
using Asap
using JSON3

println("=" ^ 80)
println("DEMO: Chat tool chain — end-to-end exercise")
println("=" ^ 80)

# ─── Step 1: Create a challenging building ───────────────────────────────────
# 30 ft × 30 ft bays, 3×3 grid, 2 stories — long spans stress punching shear.
# Non-optimal params: low concrete strength, no shear studs, L/480 deflection limit.
println("\n▸ Step 1: Create building with challenging geometry + non-optimal params")

skel = gen_medium_office(90.0u"ft", 90.0u"ft", 10.0u"ft", 3, 3, 2)
struc = BuildingStructure(skel)

params1 = DesignParameters(
    name = "non_optimal_baseline",
    floor = StructuralSizer.FlatPlateOptions(
        method = StructuralSizer.DDM(),
        deflection_limit = :L_480,
        punching_strategy = :grow_columns,
        shear_studs = :never,
    ),
    materials = MaterialOptions(
        concrete = StructuralSizer.NWC_3000,
    ),
    max_iterations = 3,
)

design1 = design_building(struc, params1)

# Populate the global cache so agent tools that need DESIGN_CACHE work.
lock(DESIGN_CACHE.lock) do
    DESIGN_CACHE.structure = struc
    DESIGN_CACHE.last_design = design1
    DESIGN_CACHE.last_diagnose = nothing
    DESIGN_CACHE.diagnose_design_id = UInt64(0)
end

s1 = design1.summary
println("  All pass:         $(s1.all_checks_pass)")
println("  Critical element: $(s1.critical_element)")
println("  Critical ratio:   $(round(s1.critical_ratio; digits=3))")
println("  EC (kgCO2e):      $(round(s1.embodied_carbon; digits=0))")

record_design_history!(DesignHistoryEntry(;
    geometry_hash    = "demo_90x90",
    params_patch     = Dict{String, Any}("name" => "non_optimal_baseline"),
    all_pass         = s1.all_checks_pass,
    critical_ratio   = s1.critical_ratio,
    critical_element = s1.critical_element,
    embodied_carbon  = s1.embodied_carbon,
    n_columns        = length(design1.columns),
    n_beams          = length(design1.beams),
    n_slabs          = length(design1.slabs),
    n_failing        = count(p -> !p.second.ok, design1.columns) +
                       count(p -> !p.second.ok, design1.beams) +
                       count(p -> !(p.second.converged && p.second.deflection_ok && p.second.punching_ok), design1.slabs) +
                       count(p -> !p.second.ok, design1.foundations),
    source           = "demo",
))

# ─── Step 2: Situation card ──────────────────────────────────────────────────
println("\n▸ Step 2: get_situation_card")
clear_design_history!()
card = agent_situation_card(struc, design1, get_design_history_entries())
health = card["health"]
println("  health.all_pass:         $(health["all_pass"])")
println("  health.n_failing:        $(health["n_failing"])")
println("  health.critical_element: $(health["critical_element"])")
if haskey(health, "failing_by_type")
    fbt = health["failing_by_type"]
    println("  failing_by_type:")
    for (k, v) in fbt
        v > 0 && println("    $k: $v")
    end
end

# ─── Step 3: Diagnose summary ───────────────────────────────────────────────
println("\n▸ Step 3: get_diagnose_summary")
diag_sum = agent_diagnose_summary(design1)
println("  by_type:")
for (etype, stats) in diag_sum["by_type"]
    println("    $etype: $(stats["total"]) total, $(stats["failing"]) failing")
end
println("  top_critical (first 3):")
for tc in diag_sum["top_critical"][1:min(3, end)]
    println("    $(tc["type"]) $(tc["id"]): $(tc["governing_check"]) ratio=$(tc["governing_ratio"]) ok=$(tc["ok"])")
end
if haskey(diag_sum, "failure_breakdown")
    println("  failure_breakdown:")
    for fb in diag_sum["failure_breakdown"]
        println("    $(fb["check"]): $(fb["count"])")
    end
end

# ─── Step 4: Query failing elements ─────────────────────────────────────────
println("\n▸ Step 4: query_elements(ok=false)")
failing = agent_query_elements(design1; ok=false)
println("  total_matched: $(failing["total_matched"])")
for etype in ["columns", "beams", "slabs", "foundations"]
    elems = get(failing, etype, [])
    isempty(elems) && continue
    println("  $etype:")
    for e in elems
        println("    id=$(e["id"]) governing=$(e["governing_check"]) ratio=$(e["governing_ratio"]) ok=$(e["ok"])")
    end
end

# ─── Step 5: Suggest next action ────────────────────────────────────────────
println("\n▸ Step 5: suggest_next_action(\"fix_failures\")")
suggestion = agent_suggest_next_action(design1, "fix_failures")
if haskey(suggestion, "error")
    println("  ERROR: $(suggestion["error"]) — $(get(suggestion, "message", ""))")
else
    println("  tldr: $(suggestion["tldr"])")
    if haskey(suggestion, "ranked_actions")
        println("  ranked_actions (first 3):")
        for a in suggestion["ranked_actions"][1:min(3, end)]
            println("    $(a["parameter"]): $(a["action"]) [coverage=$(get(a, "coverage_fraction", "?"))]")
        end
    end
    if haskey(suggestion, "geometry_actions")
        ga = suggestion["geometry_actions"]
        println("  geometry_actions:")
        println("    gap: $(get(ga, "gap", "?"))")
        if haskey(ga, "actions")
            for act in ga["actions"]
                println("    - $(get(act, "action", "?"))")
            end
        end
    end
end

# ─── Step 5b: predict_geometry_effect ────────────────────────────────────────
println("\n▸ Step 5b: predict_geometry_effect(\"span_length\", \"decrease\")")
geo_pred = agent_predict_geometry_effect("span_length", "decrease")
if haskey(geo_pred, "error")
    println("  ERROR: $(geo_pred["error"])")
else
    println("  affected_checks: $(length(geo_pred["affected_checks"])) entries")
    for ac in geo_pred["affected_checks"][1:min(3, end)]
        println("    $(ac["check"]): $(ac["effect"])")
    end
end

# ─── Step 6: Element inspector (narrate_element) ────────────────────────────
# Pick the first failing slab if any, else first failing column.
println("\n▸ Step 6: narrate_element (element inspector)")
failing_slabs = get(failing, "slabs", [])
failing_cols  = get(failing, "columns", [])
if !isempty(failing_slabs)
    slab_id = failing_slabs[1]["id"]
    narr = agent_narrate_element(design1, "slab", slab_id, "architect")
    println("  Element: slab $slab_id")
    println("  Narrative source: $(get(narr, "narrative_source", "?"))")
    narrative_text = get(narr, "narrative", get(narr, "error", "no narrative"))
    println("  Narrative: $(first(narrative_text, 300))...")
elseif !isempty(failing_cols)
    col_id = failing_cols[1]["id"]
    narr = agent_narrate_element(design1, "column", col_id, "engineer")
    println("  Element: column $col_id")
    println("  Narrative source: $(get(narr, "narrative_source", "?"))")
    narrative_text = get(narr, "narrative", get(narr, "error", "no narrative"))
    println("  Narrative: $(first(narrative_text, 300))...")
else
    println("  (No failing elements to narrate — this is unexpected for the demo)")
end

# ─── Step 7: Micro-experiments ───────────────────────────────────────────────
println("\n▸ Step 7a: list_experiments()")
exp_list = list_experiments()
println("  Available types: $(map(e -> e["name"], exp_list["experiments"]))")

# Punching experiment: try larger column on first column with punching data
println("\n▸ Step 7b: punching micro-experiment")
punching_col = nothing
for (idx, cr) in design1.columns
    if !isnothing(cr.punching)
        punching_col = idx
        break
    end
end
if !isnothing(punching_col)
    cr = design1.columns[punching_col]
    orig_c1 = round(ustrip(u"inch", cr.c1); digits=1)
    bigger = orig_c1 + 4.0
    println("  Column $punching_col: trying $(orig_c1)\" → $(bigger)\" (both dims)")
    pexp = experiment_punching(design1, punching_col; c1_in=bigger, c2_in=bigger)
    println("  Original ratio: $(pexp["original"]["ratio"]), ok=$(pexp["original"]["ok"])")
    println("  Modified ratio: $(pexp["modified"]["ratio"]), ok=$(pexp["modified"]["ok"])")
    println("  Improved: $(pexp["improved"])")
else
    println("  (No column with punching data found)")
end

# Deflection experiment: relax limit from L/480 to L/360
println("\n▸ Step 7c: deflection micro-experiment")
if !isempty(design1.slabs)
    slab_idx = first(keys(design1.slabs))
    dexp = experiment_deflection(design1, slab_idx; deflection_limit="L_360")
    if haskey(dexp, "error")
        println("  Slab $slab_idx: $(dexp["error"]) — $(dexp["message"])")
    else
        println("  Slab $slab_idx:")
        println("    Original: limit_in=$(dexp["original"]["limit_in"]) ratio=$(dexp["original"]["ratio"])")
        println("    Modified: limit_in=$(dexp["modified"]["limit_in"]) ratio=$(dexp["modified"]["ratio"])")
        println("    Improved: $(dexp["improved"])")
    end
end

# ─── Step 8: Second design with improved params ─────────────────────────────
println("\n▸ Step 8: Second design with improved parameters")
params2 = DesignParameters(
    name = "improved",
    floor = StructuralSizer.FlatPlateOptions(
        method = StructuralSizer.DDM(),
        deflection_limit = :L_360,
        punching_strategy = :grow_columns,
        shear_studs = :if_needed,
    ),
    materials = MaterialOptions(
        concrete = StructuralSizer.NWC_4000,
    ),
    max_iterations = 8,
)

design2 = design_building(struc, params2)

# Update cache
lock(DESIGN_CACHE.lock) do
    DESIGN_CACHE.last_design = design2
    DESIGN_CACHE.last_diagnose = nothing
    DESIGN_CACHE.diagnose_design_id = UInt64(0)
end

s2 = design2.summary
n_fail2 = count(p -> !p.second.ok, design2.columns) +
          count(p -> !p.second.ok, design2.beams) +
          count(p -> !(p.second.converged && p.second.deflection_ok && p.second.punching_ok), design2.slabs) +
          count(p -> !p.second.ok, design2.foundations)

println("  All pass:         $(s2.all_checks_pass)")
println("  Critical element: $(s2.critical_element)")
println("  Critical ratio:   $(round(s2.critical_ratio; digits=3))")
println("  EC (kgCO2e):      $(round(s2.embodied_carbon; digits=0))")
println("  n_failing:        $n_fail2")

record_design_history!(DesignHistoryEntry(;
    geometry_hash    = "demo_90x90",
    params_patch     = Dict{String, Any}("name" => "improved"),
    all_pass         = s2.all_checks_pass,
    critical_ratio   = s2.critical_ratio,
    critical_element = s2.critical_element,
    embodied_carbon  = s2.embodied_carbon,
    n_columns        = length(design2.columns),
    n_beams          = length(design2.beams),
    n_slabs          = length(design2.slabs),
    n_failing        = n_fail2,
    source           = "demo",
))

# ─── Step 9: Compare designs ────────────────────────────────────────────────
println("\n▸ Step 9: compare_designs(1, 2)")
comparison = agent_compare_designs(1, 2)
if haskey(comparison, "error")
    println("  ERROR: $(comparison["error"]) — $(get(comparison, "message", ""))")
else
    println("  deltas:")
    if haskey(comparison, "deltas")
        for (k, v) in comparison["deltas"]
            println("    $k: $v")
        end
    end
    if haskey(comparison, "changed_params")
        println("  changed_params: $(comparison["changed_params"])")
    end
end

# ─── Step 10: Condensed result ───────────────────────────────────────────────
println("\n▸ Step 10: condense_result (text summary for improved design)")
condensed = condense_result(design2)
println("  $(first(condensed, 500))...")

# ─── Summary ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 80)
println("DEMO COMPLETE")
println("=" ^ 80)
println("Design 1: all_pass=$(s1.all_checks_pass), critical=$(s1.critical_element), ratio=$(round(s1.critical_ratio; digits=3))")
println("Design 2: all_pass=$(s2.all_checks_pass), critical=$(s2.critical_element), ratio=$(round(s2.critical_ratio; digits=3))")
if s2.all_checks_pass && !s1.all_checks_pass
    println("✓ Improved parameters resolved failures.")
elseif n_fail2 < (s1.all_checks_pass ? 0 : 1)
    println("✓ Fewer failures after parameter improvement.")
else
    println("△ Some failures remain — geometry changes may be needed.")
end
ec_delta = s2.embodied_carbon - s1.embodied_carbon
println("EC delta: $(round(ec_delta; digits=0)) kgCO2e ($(round(ec_delta/max(s1.embodied_carbon,1)*100; digits=1))%)")
