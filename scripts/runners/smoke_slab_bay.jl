# One 20 ft square bay, 3 stories, NWC_4000, 150 psf.
# Six core methods. Computed-deflection search, except ACI Min at the table.
# Pattern loading on, rigid column patch (FEA default 100), full-strip average.
#
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralStudies scripts/runners/smoke_slab_bay.jl

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "flat_plate_method_comparison.jl"))

const LX = 20.0
const LY = 20.0
const LL = 150.0

"""Column design moments (kip·ft) grouped by position.

These are the moments passed to the column, Mub times the transfer fraction.
Within a class they should match. Across methods they should stay in the
same range as DDM.
"""
function _column_moment_classes(struc)
    selected = _select_study_slab(struc)
    dd = selected.slab.design_details
    (isnothing(dd) || !hasproperty(dd, :column_results) || isnothing(dd.column_results)) &&
        return nothing
    groups = Dict{Symbol, Vector{Float64}}()
    for (idx, res) in dd.column_results
        idx > length(struc.columns) && continue
        pos = struc.columns[idx].position
        mu = ustrip(u"kip*ft", res.Mu)
        push!(get!(groups, pos, Float64[]), mu)
    end
    return groups
end

function _fmt_class(groups, pos)
    isnothing(groups) && return "—"
    vals = get(groups, pos, Float64[])
    isempty(vals) && return "—"
    lo, hi = extrema(vals)
    return @sprintf("%.0f–%.0f (n=%d)", lo, hi, length(vals))
end

_fmt_in(x) = isfinite(x) ? @sprintf("%.1f", x) : "—"
_fmt_pair(c1, c2) = _fmt_in(c1) * "×" * _fmt_in(c2)

base = _make_params(; concrete_label = "NWC_4000", max_col_in = _resolve_max_col(LX))
struc = BuildingStructure(_build_skeleton(LX, LY, _adaptive_story_ht(LX), 3; n_stories = 3))
prepare!(struc, base)

const CAP_IN = _resolve_max_col(LX)

println("\n=== ONE BAY  $(LX) ft  LL=$(LL) psf  3 stories  NWC_4000 ===")
println("Pattern on. Patch stiffness 100. Averaging width = full strip.")
println("Column cap $(CAP_IN) in. Punching grows the column, then adds studs, then thickens the slab.")
println("at_cap means the finished section is within 0.5 in of that cap.\n")

ddm_perimeter = nothing
for mcfg in CORE_METHODS
    regime = mcfg.method isa SR.RuleOfThumb ? "table_minimum" : "computed_deflection"
    min_h = mcfg.method isa SR.RuleOfThumb ? nothing : COMPUTED_DEFLECTION_SEED
    row = _run_method(struc, base, mcfg;
                      lx_ft = LX, ly_ft = LY, live_psf = LL,
                      concrete_label = "NWC_4000", min_h = min_h)
    if isnothing(row)
        println("$(mcfg.name): no row")
        flush(stdout)
        continue
    end
    groups = _column_moment_classes(struc)
    if mcfg.name == "DDM (Full)" && !isnothing(groups)
        peri = vcat(get(groups, :corner, Float64[]), get(groups, :edge, Float64[]))
        global ddm_perimeter = isempty(peri) ? nothing : sum(peri) / length(peri)
    end
    peri_now = if isnothing(groups)
        NaN
    else
        peri = vcat(get(groups, :corner, Float64[]), get(groups, :edge, Float64[]))
        isempty(peri) ? NaN : sum(peri) / length(peri)
    end
    ratio = (ddm_perimeter === nothing || !isfinite(peri_now) || ddm_perimeter == 0) ?
        NaN : peri_now / ddm_perimeter
    fail = get(row, :failure_reason, "")
    println(@sprintf("%-14s  %-22s  h=%5.2f in  story=%s (%s)  governing=%s  pattern=%s  %s",
                     mcfg.name, regime, something(get(row, :h_in, NaN), NaN),
                     something(get(row, :story, "?"), "?"),
                     something(get(row, :story_role, "?"), "?"),
                     something(get(row, :governing_check, fail), fail),
                     string(get(row, :pattern_loading, "")),
                     isempty(fail) ? "" : "FAIL $fail"))
    println(@sprintf("               corner %s   edge %s   interior %s   perimeter/DDM=%s",
                     _fmt_class(groups, :corner), _fmt_class(groups, :edge),
                     _fmt_class(groups, :interior),
                     isfinite(ratio) ? @sprintf("%.2f", ratio) : "—"))
    studs = row.has_studs ? @sprintf("studs on %d col", row.n_stud_cols) : "studs none"
    println(@sprintf("               columns in  corner %s  edge %s  interior %s  floor %s",
                     _fmt_pair(row.col_c1_corner_in, row.col_c2_corner_in),
                     _fmt_pair(row.col_c1_edge_in, row.col_c2_edge_in),
                     _fmt_pair(row.col_c1_interior_in, row.col_c2_interior_in),
                     _fmt_pair(row.col_c1_in, row.col_c2_in)))
    println(@sprintf("               cap %s in  %s  %s",
                     _fmt_in(row.max_col_in),
                     row.col_at_cap ? "at cap" : "below cap",
                     studs))
    flush(stdout)
end
