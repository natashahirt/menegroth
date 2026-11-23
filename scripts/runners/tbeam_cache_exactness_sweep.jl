#=
Exactness A/B for the T-beam capacity cache across several waffle geometries.

For each plan this designs the waffle twice in one process — once with the
content-keyed capacity cache ON (default) and once OFF
(`SS_TBEAM_CAP_NOCACHE=1`) — and asserts the installed design is bit-identical:
`all_checks_pass`, `critical_element`, `critical_ratio`, and the embodied-carbon
total/intensity must match exactly. The cache only reuses a section's precompute
across member iterations, so correctness means ON == OFF on every geometry, not
just grid/x1y1.

`max_iterations` is reduced (default 6, override with `SWEEP_MAX_ITER`) purely to
keep the sweep tractable: the A/B holds at any iteration count, and a handful of
iterations already exercises cross-iteration cache reuse (where a staleness bug
would surface). Pass plan names as CLI args to override the default set.

    SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
        julia --project=StructuralStudies \
        scripts/runners/tbeam_cache_exactness_sweep.jl [plan ...]
=#

include(joinpath(@__DIR__, "sdf_rib_design.jl"))

# A typical orthogonal grid and two "weirder" geometries (a rhombus and a star)
# so the sweep covers non-rectangular bays and joist-fallback paths, not only the
# clean grid already validated by profile_waffle_stages.jl.
const SWEEP_PLANS = ["grid/x1y1", "special/rhombus_8x12", "star/e0c0"]
const SWEEP_MAX_ITER = parse(Int, get(ENV, "SWEEP_MAX_ITER", "6"))

"""The installed-design fingerprint that must be identical cache ON vs OFF."""
function _design_fingerprint(plan_name::AbstractString)
    params = rib_parameters(plan_name, :waffle)
    params.max_iterations = SWEEP_MAX_ITER
    struc = BuildingStructure(plan_skeleton(load_plan(plan_name)))
    design = design_building(struc, params; restore = false)
    s = design.summary
    ec = compute_building_ec(design.structure, params)
    return (;
        all_checks_pass = s.all_checks_pass,
        critical_element = string(s.critical_element),
        critical_ratio = s.critical_ratio,
        total_ec = ustrip(u"kgCO2e", ec.total_ec),
        ec_intensity = ustrip(u"kgCO2e/m^2", ec.ec_per_floor_area),
    )
end

"""Run one plan's waffle with the cache ON then OFF and compare, fail-loud on drift."""
function _compare_plan(plan_name::AbstractString)
    println("\n=== $plan_name (max_iterations=$SWEEP_MAX_ITER) ===")
    flush(stdout)

    delete!(ENV, "SS_TBEAM_CAP_NOCACHE")           # cache ON (default)
    on = _design_fingerprint(plan_name)

    ENV["SS_TBEAM_CAP_NOCACHE"] = "1"              # cache OFF (pre-cache behavior)
    off = try
        _design_fingerprint(plan_name)
    finally
        delete!(ENV, "SS_TBEAM_CAP_NOCACHE")
    end

    identical = on == off
    for k in keys(on)
        same = on[k] == off[k]
        println("    ", rpad(string(k), 17), rpad(string(on[k]), 28),
                same ? "== " : ">>> DIFFERS: ", same ? "" : string(off[k]))
    end
    println(identical ? "  PASS — bit-identical cache ON vs OFF" :
                        "  FAIL — cache changed the installed design")
    return (; plan = plan_name, identical, on, off)
end

function main(args)
    plans = isempty(args) ? SWEEP_PLANS : String.(args)
    println("T-beam cache exactness sweep over ", length(plans), " plan(s)")
    results = NamedTuple[]
    for plan_name in plans
        try
            push!(results, _compare_plan(plan_name))
        catch err
            println("    ERROR designing $plan_name: ", sprint(showerror, err))
            push!(results, (; plan = plan_name, identical = false,
                            on = nothing, off = nothing))
        end
    end

    println("\n==== summary ====")
    for r in results
        println("    ", rpad(r.plan, 24),
                r.on === nothing ? "ERROR" : (r.identical ? "PASS" : "FAIL"))
    end
    all(r -> r.on !== nothing && r.identical, results) ||
        error("T-beam cache exactness sweep FAILED on at least one plan")
    println("\nAll plans bit-identical cache ON vs OFF ✓")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
