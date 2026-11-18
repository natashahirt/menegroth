# Before/after comparison for the slab move from ACI 318-11 to ACI 318-19.
#
#   SS_ENABLE_VISUALIZATION=false julia scripts/runners/compare_slab_aci_edition.jl baseline
#   SS_ENABLE_VISUALIZATION=false julia scripts/runners/compare_slab_aci_edition.jl compare
#
# `baseline` writes `aci318_11.csv` with the ACI 318-11 slab provisions swapped
# back in (`_use_aci318_11!`). `compare` writes `aci318_19.csv` and prints both
# side by side. Same extraction as run_flat_plate_speedup_validation.jl, over
# more spans and live loads.

include(joinpath(@__DIR__, "run_flat_plate_speedup_validation.jl"))

const EDITION_DIR = joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                             "flat_plate_methods", "results", "aci_edition_port")
const EDITION_CASES = vcat(
    [(span, ll, SMOKE_METHODS[1]) for span in (20.0, 28.0, 36.0) for ll in (50.0, 100.0)],
    [(28.0, 50.0, SMOKE_METHODS[2])],
)
const SHOW_COLS = [:h_in, :punch_ratio, :vu_max_psi, :defl_in, :defl_ratio,
                   :As_total_in2, :col_max_in, :slab_ec_per_m2]

function run_edition_cases()
    rows = NamedTuple[]
    for span in unique(c[1] for c in EDITION_CASES)
        base_params = _make_params(; sdl_psf = 20.0, max_col_in = _adaptive_max_col(span),
                                     concrete_label = SMOKE_CONCRETE)
        struc = BuildingStructure(_build_skeleton(span, span, _adaptive_story_ht(span), SMOKE_N_BAYS))
        prepare!(struc, base_params)
        for (s, ll, mcfg) in EDITION_CASES
            s == span || continue
            println("  $(mcfg.name), $(Int(span)) ft, $(Int(ll)) psf")
            full = _run_method(struc, base_params, mcfg; lx_ft = span, ly_ft = span,
                               live_psf = ll, concrete_label = SMOKE_CONCRETE)
            isnothing(full) || push!(rows, _uniform_row(full))
        end
    end
    return rows
end

function print_side_by_side(old_rows, new_rows)
    new_by_key = Dict(_row_key(r) => r for r in new_rows)
    for rb in old_rows
        k = _row_key(rb)
        rn = get(new_by_key, k, nothing)
        println("\n$(k.method), $(Int(k.lx_ft)) ft, $(Int(k.live_psf)) psf")
        for c in SHOW_COLS
            vb = getproperty(rb, c)
            vn = isnothing(rn) ? NaN : getproperty(rn, c)
            @printf("  %-16s %10.3f -> %10.3f\n", String(c), vb, vn)
        end
    end
end

"""
Swap the ACI 318-19 slab provisions back to ACI 318-11 in this process, so the
baseline runs on the same tree: λs = 1 (§11.11.2.1), one-way Vc = 2λ√f'c bw d
(Eq. 11-3), Branson Ie (Eq. 9-8), no top steel from §8.6.1.2. For Grade 60 the
0.0018 minimum and εt = 0.005 are the same in both editions.
"""
function _use_aci318_11!()
    @eval StructuralSizer begin
        size_effect_factor(d::Length) = 1.0
        one_way_shear_capacity_without_Av(fc::Pressure, bw::Length, d::Length, As::Area;
                                          λ::Float64 = 1.0) =
            one_way_shear_capacity(fc, bw, d; λ = λ)
        effective_moment_of_inertia_function(method::Symbol) = effective_moment_of_inertia
        punching_minimum_top_steel(vuv::Pressure, bslab::Length, b0::Length, fc::Pressure,
                                   fy::Pressure, αs::Int; kwargs...) = 0.0u"inch^2"
    end
end

function edition_main(args)
    _ensure_dir(EDITION_DIR)
    mode = isempty(args) ? "compare" : args[1]
    old_csv = joinpath(EDITION_DIR, "aci318_11.csv")
    new_csv = joinpath(EDITION_DIR, "aci318_19.csv")
    mode == "baseline" && _use_aci318_11!()
    # invokelatest: methods redefined by `_use_aci318_11!` are invisible to this
    # already-running call (world age).
    rows = Base.invokelatest(run_edition_cases)
    if mode == "baseline"
        _write_csv(old_csv, rows)
        println("ACI 318-11 baseline -> $old_csv ($(length(rows)) rows)")
    else
        _write_csv(new_csv, rows)
        println("ACI 318-19 results -> $new_csv ($(length(rows)) rows)")
        isfile(old_csv) && print_side_by_side(_read_csv(old_csv), rows)
    end
end

edition_main(copy(ARGS))
