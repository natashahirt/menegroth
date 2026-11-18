# Experiment grid for the cluster.
#
# Pure data: no packages load, so `make_manifest.jl` counts tasks on a login
# node in a second. Each task is one Slurm array element:
#
#   id          unique, file-safe; names the task's output files
#   experiment  output folder and the name passed to submit.sh
#   kind        :heatmap (dual_heatmap_sweep) or :building (sweep_building)
#   args        keyword arguments. `methods` and `regime` are names that
#               run_task.jl resolves after the study code loads.
#
# Task order is deterministic: array index i is tasks(experiment)[i]. Edit a
# grid before submitting, never between a submission and its resubmissions.
#
# A heatmap task covers one bay (Lx × Ly), one live load, one concrete and
# one thickness regime, and runs every listed method on both flat plate and
# flat slab in a 3-story building (middle floor reported).

const SPANS            = collect(16.0:4.0:52.0)
const LIVE_LOADS       = [50.0, 100.0, 150.0, 250.0]
const HEATMAP_CONCRETES = ["NWC_4000"]
const REGIMES          = ["table_minimum", "computed_deflection"]
const MAX_ASPECT       = 2.0   # wider bays are outside DDM limits; every method rejects them

# E5: one change at a time at these square base cases.
const BASE_CASES = [(span = 20.0, ll = 150.0), (span = 32.0, ll = 50.0)]
const SENSITIVITIES = [
    ("cap_generous",   (column_cap = :adaptive,)),       # 36–60 in cap
    ("defl_L360",      (deflection_limit = :L_360,)),
    ("defl_L480",      (deflection_limit = :L_480,)),
    ("no_studs",       (punching_variants = [:no_studs],)),
    ("cols_continuous", (column_strategies = [:nlp],)),   # NLP sizing instead of the catalog
    ("fea_postproc",   (methods = "fea_postproc",)),     # FEA smoothing, torsion, averaging, footprint, mesh
]

# R3: whole-building carbon cascade.
const BUILDING_SPANS     = [16.0, 22.0, 28.0]
const BUILDING_STORIES   = [3, 6, 10]
const BUILDING_CONCRETES = ["NWC_4000", "NWC_6000", "LWC_4000"]

const EXPERIMENTS = ["smoke", "r1_heatmap", "e7_punching", "e5_sensitivity", "r3_building"]

_f(x) = replace(string(round(x; digits = 1)), "." => "p")

function _r1_tasks()
    out = NamedTuple[]
    for lx in SPANS, ly in SPANS
        max(lx, ly) / min(lx, ly) > MAX_ASPECT && continue
        for ll in LIVE_LOADS, conc in HEATMAP_CONCRETES, regime in REGIMES
            push!(out, (id = "r1_lx$(_f(lx))_ly$(_f(ly))_ll$(Int(ll))_$(conc)_$(regime)",
                        experiment = "r1_heatmap", kind = :heatmap,
                        args = (spans_x = [lx], spans_y = [ly], live_loads = [ll],
                                concretes = [conc], regime = regime, methods = "all",
                                punching_variants = [:all_levers])))
        end
    end
    return out
end

# All levers is the R1 base, so E7 runs the single-lever variants and studs
# followed by thickness.
function _e7_tasks()
    out = NamedTuple[]
    for span in SPANS, ll in LIVE_LOADS,
        pv in (:columns_only, :studs_only, :studs_then_thickness, :thickness_only)
        push!(out, (id = "e7_s$(_f(span))_ll$(Int(ll))_$(pv)",
                    experiment = "e7_punching", kind = :heatmap,
                    args = (spans_x = [span], spans_y = [span], live_loads = [ll],
                            concretes = ["NWC_4000"], regime = "table_minimum",
                            methods = "core", punching_variants = [pv])))
    end
    return out
end

function _e5_tasks()
    out = NamedTuple[]
    for bc in BASE_CASES, (name, over) in SENSITIVITIES
        base = (spans_x = [bc.span], spans_y = [bc.span], live_loads = [bc.ll],
                concretes = ["NWC_4000"], regime = "table_minimum", methods = "core",
                punching_variants = [:all_levers])
        push!(out, (id = "e5_s$(_f(bc.span))_ll$(Int(bc.ll))_$(name)",
                    experiment = "e5_sensitivity", kind = :heatmap,
                    args = merge(base, over, (sensitivity = name,))))
    end
    return out
end

function _r3_tasks()
    out = NamedTuple[]
    for span in BUILDING_SPANS, n in BUILDING_STORIES, conc in BUILDING_CONCRETES, regime in REGIMES
        push!(out, (id = "r3_s$(_f(span))_n$(n)_$(conc)_$(regime)",
                    experiment = "r3_building", kind = :building,
                    args = (spans = [span], stories = [n], concretes = [conc],
                            regime = regime, methods = "section3")))
    end
    return out
end

# Two quick tasks (ACI Min and DDM, so a heatmap task has two parts to resume) to
# check the setup end to end before a real submission.
_smoke_tasks() = NamedTuple[
    (id = "smoke_heatmap_s20_ll50", experiment = "smoke", kind = :heatmap,
     args = (spans_x = [20.0], spans_y = [20.0], live_loads = [50.0], concretes = ["NWC_4000"],
             regime = "table_minimum", methods = "smoke", punching_variants = [:all_levers])),
    (id = "smoke_building_s16_n3", experiment = "smoke", kind = :building,
     args = (spans = [16.0], stories = [3], concretes = ["NWC_4000"],
             regime = "table_minimum", methods = "smoke")),
]

"""Tasks for one experiment, in array order."""
function tasks(experiment::AbstractString)
    experiment == "smoke"          && return _smoke_tasks()
    experiment == "r1_heatmap"     && return _r1_tasks()
    experiment == "e7_punching"    && return _e7_tasks()
    experiment == "e5_sensitivity" && return _e5_tasks()
    experiment == "r3_building"    && return _r3_tasks()
    error("unknown experiment $(experiment); one of $(EXPERIMENTS)")
end
