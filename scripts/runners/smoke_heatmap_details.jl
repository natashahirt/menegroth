# Smoke runs for the heatmap sweep with detail tables (3-story buildings,
# middle floor reported, span/15 cap, L/240, table minimum).
#
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralStudies \
#       scripts/runners/smoke_heatmap_details.jl <mode>
#
# Modes:
#   core     20 ft bay, 150 psf, all core methods, all punching levers
#   long     40 ft bay, 50 psf, DDM / EFM / FEA frame (deflection under L/240)
#   levers   20 ft bay, 150 psf, DDM and FEA frame, each punching variant
#
# Each mode writes the main CSV plus `_columns.csv` and `_slabs.csv` to the
# flat-plate results folder and prints a short summary.

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "flat_plate_method_comparison.jl"))

const MODE = isempty(ARGS) ? "core" : ARGS[1]
_pick_methods(names) = filter(m -> m.name in names, CORE_METHODS)

cfg = if MODE == "core"
    (spans = [20.0], ll = [150.0], methods = CORE_METHODS, variants = [:all_levers])
elseif MODE == "long"
    (spans = [40.0], ll = [50.0],
     methods = _pick_methods(["DDM (Full)", "EFM (ASAP)", "FEA (frame)"]), variants = [:all_levers])
elseif MODE == "levers"
    (spans = [20.0], ll = [150.0],
     methods = _pick_methods(["DDM (Full)", "FEA (frame)"]),
     variants = [:all_levers, :columns_only, :studs_only, :studs_then_thickness, :thickness_only])
else
    error("unknown mode $(MODE); use core, long or levers")
end

df = dual_heatmap_sweep(; spans_x = cfg.spans, spans_y = cfg.spans, live_loads = cfg.ll,
                        methods = cfg.methods, punching_variants = cfg.variants,
                        save = true)

println("\n=== $(MODE) ===")
isempty(df) && (println("no converged rows"); exit(0))
for r in eachrow(sort(df, [:floor_type, :punching_variant, :method]))
    @printf("%-10s %-14s %-12s h=%5.2f in  gov=%-16s studs=%d  cols c/e/i=%s/%s/%s in  Mub_x c/e/i=%.0f/%.0f/%.0f  defl=%.2f  EC=%.0f t  ok=%s\n",
            r.floor_type, r.punching_variant, r.method, r.h_in, r.governing_check,
            r.n_stud_columns,
            string(r.col_c1_corner_in), string(r.col_c1_edge_in), string(r.col_c1_interior_in),
            r.Mub_x_corner_kipft, r.Mub_x_edge_kipft, r.Mub_x_interior_kipft,
            r.defl_ratio, r.bldg_ec_kgco2e / 1000, string(r.bldg_all_ok))
end
