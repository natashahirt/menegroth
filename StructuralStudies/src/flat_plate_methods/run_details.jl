# Per-run detail tables for post-processing.
#
# Each design run adds one row per column and one row per slab, keyed by the
# `run_id` on its main sweep row. Sweeps save them beside the main CSV as
# `<name>_columns.csv` and `<name>_slabs.csv`. The main row also gets
# building-level totals and the reported floor's demand by column position.
# Every field is optional in the sense that a missing value is NaN, so a
# failed or partial run still writes rows.

"""Fresh identifier joining a main row to its detail rows."""
_new_run_id() = bytes2hex(rand(UInt8, 6))

"""Container a sweep passes to `_run_method` to collect detail rows."""
_detail_sink() = (columns = NamedTuple[], slabs = NamedTuple[])

_num(u, x) = (isnothing(x) || x isa Missing) ? NaN : Float64(ustrip(u, x))
_kipft(x) = _num(SR.kip * u"ft", x)
_kip(x)   = _num(SR.kip, x)
_getp(x, k, default = nothing) = (!isnothing(x) && hasproperty(x, k)) ? getproperty(x, k) : default
"""Element `i` of vector field `k` of `x`, or `nothing` when absent or short."""
_at(x, k, i) = (v = _getp(x, k); (isnothing(v) || i > length(v)) ? nothing : v[i])
"""First argument that is not `nothing`, else `nothing`."""
_pick(xs...) = (i = findfirst(!isnothing, xs); isnothing(i) ? nothing : xs[i])

"""Column centre (x, y) in ft."""
function _column_xy_ft(struc, col)
    v  = struc.skeleton.vertices[col.vertex_idx]
    cc = getfield(parentmodule(typeof(v)), :coords)(v)
    return (_num(u"ft", cc.x), _num(u"ft", cc.y))
end

"""Story index for each slab index."""
function _slab_stories(struc)
    out = Dict{Int, Int}()
    for (story, idxs) in _slab_story_map(struc), i in idxs
        out[i] = story
    end
    return out
end

"""Stud fields from a punching result (`nothing` or no studs → zeros)."""
function _stud_fields(punch)
    studs = _getp(punch, :studs)
    if isnothing(studs) || !_getp(studs, :required, false)
        return (studs = false, stud_rails = 0, studs_per_rail = 0, stud_vol_in3 = 0.0)
    end
    return (studs = true,
            stud_rails = studs.n_rails,
            studs_per_rail = studs.n_studs_per_rail,
            stud_vol_in3 = _num(u"inch^3", SR.stud_steel_volume(studs)))
end

"""
One direction of a moment analysis as named fields with suffix `sfx`. The
transverse result can be a lighter NamedTuple (FEA), so every field is read
with `_getp` and missing ones are NaN.
"""
function _moment_fields(mr, sfx::String)
    mom = (:M0, :M_neg_ext, :M_neg_int, :M_pos)
    geo = (:l1, :l2, :ln)
    k_m = Tuple(Symbol(string(k) * sfx * "_kipft") for k in mom)
    k_g = Tuple(Symbol(string(k) * sfx * "_ft") for k in geo)
    return merge(NamedTuple{k_m}(Tuple(_kipft(_getp(mr, k)) for k in mom)),
                 NamedTuple{k_g}(Tuple(_num(u"ft", _getp(mr, k)) for k in geo)),
                 NamedTuple{(Symbol("Vu_max" * sfx * "_kip"),)}((_kip(_getp(mr, :Vu_max)),)))
end

"""
Collect slab and column detail rows for `struc` after a design run, and the
reported-floor and building summaries for the main row.

`design` is the captured `BuildingDesign` or `nothing`.
"""
function _collect_details(struc, design, run_id::String; cap_in::Real = NaN,
                          increment_in::Real = 0.5)
    slab_story = _slab_stories(struc)
    reported   = _select_study_slab(struc).slab_index
    col_rows   = NamedTuple[]
    slab_rows  = NamedTuple[]

    for (si, slab) in enumerate(struc.slabs)
        dd   = slab.design_details
        mr   = _getp(dd, :moment_results)
        sr   = _getp(dd, :secondary_results)
        crs  = _getp(dd, :column_results)
        res  = _getp(dd, :slab_result)
        cols = SR.find_supporting_columns(struc, Set(slab.cell_indices))

        n_stud = 0
        stud_vol = 0.0
        for (i, col) in enumerate(cols)
            gidx  = something(findfirst(c -> c === col, struc.columns), 0)
            cr    = (!isnothing(crs) && haskey(crs, gidx)) ? crs[gidx] : nothing
            punch = _getp(cr, :punching)
            sf    = _stud_fields(punch)
            n_stud += sf.studs
            stud_vol += sf.stud_vol_in3
            cd    = (!isnothing(design) && haskey(design.columns, gidx)) ? design.columns[gidx] : nothing
            x, y  = _column_xy_ft(struc, col)
            c1 = _dim_in(col.c1); c2 = _dim_in(col.c2)
            side = maximum(filter(isfinite, (c1, c2)); init = NaN)
            push!(col_rows, merge((
                run_id         = run_id,
                col_idx        = gidx,
                slab_idx       = si,
                story          = col.story,
                reported_floor = si == reported,
                position       = String(col.position),
                x_ft           = x,
                y_ft           = y,
                c1_in          = c1,
                c2_in          = c2,
                at_cap         = isfinite(cap_in) && isfinite(side) && side >= cap_in - increment_in - 1e-9,
                Mub_x_kipft    = _kipft(_at(mr, :unbalanced_moments, i)),
                Mub_y_kipft    = _kipft(_at(sr, :unbalanced_moments, i)),
                Mcol_x_kipft   = _kipft(_at(mr, :column_moments, i)),
                Mcol_y_kipft   = _kipft(_at(sr, :column_moments, i)),
                Vu_slab_kip    = _kip(_at(mr, :column_shears, i)),
                Pu_slab_kip    = _kip(_getp(cr, :Pu)),
                Mu_slab_kipft  = _kipft(_getp(cr, :Mu)),
                rho_g_slab     = Float64(something(_getp(cr, :ρg), NaN)),
                punch_ratio    = Float64(something(_getp(punch, :ratio), NaN)),
                punch_ok       = something(_getp(punch, :ok), missing),
                punch_vu_psi   = _num(u"psi", _getp(punch, :vu)),
                punch_phivc_psi = _num(u"psi", _getp(punch, :φvc)),
                punch_b0_in    = _num(u"inch", _getp(punch, :b0)),
                Pu_design_kip  = _kip(_getp(cd, :Pu)),
                Mu_x_design_kipft = _kipft(_getp(cd, :Mu_x)),
                Mu_y_design_kipft = _kipft(_getp(cd, :Mu_y)),
                rho_g_design   = Float64(something(_getp(cd, :rho_g), NaN)),
                axial_ratio    = Float64(something(_getp(cd, :axial_ratio), NaN)),
                interaction_ratio = Float64(something(_getp(cd, :interaction_ratio), NaN)),
                column_ok      = something(_getp(cd, :ok), missing),
            ), sf))
        end

        defl = _getp(res, :deflection_check)
        pchk = _getp(res, :punching_check)
        area_m2 = _num(u"m^2", sum(struc.cells[ci].area for ci in slab.cell_indices; init = 0.0u"m^2"))
        mui  = _extract_slab_mui(slab.volumes, area_m2)
        ec   = isempty(slab.volumes) ? NaN : _num(u"kgCO2e", element_ec(slab.volumes))
        push!(slab_rows, merge((
            run_id          = run_id,
            slab_idx        = si,
            story           = get(slab_story, si, -1),
            reported_floor  = si == reported,
            n_cells         = length(slab.cell_indices),
            area_m2         = area_m2,
            h_in            = _num(u"inch", _pick(_getp(dd, :h_final), _getp(res, :thickness), _getp(slab, :thickness))),
            converged       = something(_getp(dd, :converged), missing),
            iterations      = something(_getp(dd, :iterations), -1),
            failing_check   = string(something(_getp(dd, :failing_check), "")),
            governing_check = string(something(_getp(dd, :governing_check), "")),
            method_used     = string(something(_getp(dd, :method_used), "")),
            pattern_loading = something(_getp(dd, :pattern_loading), missing),
            qu_psf          = _num(SR.psf, _getp(mr, :qu)),
            qD_psf          = _num(SR.psf, _getp(mr, :qD)),
            qL_psf          = _num(SR.psf, _getp(mr, :qL)),
            defl_in         = _num(u"inch", _getp(defl, :Δ_check)),
            defl_total_in   = _num(u"inch", _getp(defl, :Δ_total)),
            defl_limit_in   = _num(u"inch", _getp(defl, :Δ_limit)),
            defl_ratio      = Float64(something(_getp(defl, :ratio), NaN)),
            punch_max_ratio = Float64(something(_getp(pchk, :max_ratio), NaN)),
            n_columns       = length(cols),
            n_stud_columns  = n_stud,
            stud_vol_in3    = stud_vol,
            slab_ec_kgco2e  = ec,
        ), _moment_fields(mr, "_x"), _moment_fields(sr, "_y"), mui))
    end
    return (columns = col_rows, slabs = slab_rows, reported = reported)
end

"""
Main-row fields from the detail rows: reported-floor demand by column
position (largest |value| per class and direction), studs, and building totals.
"""
function _summary_fields(det, design)
    rep_cols = filter(r -> r.reported_floor, det.columns)
    rep_slab = findfirst(r -> r.reported_floor, det.slabs)
    srow     = isnothing(rep_slab) ? nothing : det.slabs[rep_slab]
    pos_max(pos, k) = begin
        v = [abs(getproperty(r, k)) for r in rep_cols if r.position == pos && isfinite(getproperty(r, k))]
        isempty(v) ? NaN : maximum(v)
    end
    by_pos = (;
        (Symbol("Mub_$(d)_$(p)_kipft") => pos_max(p, Symbol("Mub_$(d)_kipft"))
         for d in ("x", "y") for p in ("corner", "edge", "interior"))...,
        (Symbol("punch_ratio_$(p)") => pos_max(p, :punch_ratio)
         for p in ("corner", "edge", "interior"))...,
    )
    s = isnothing(design) ? nothing : design.summary
    ecf(k) = isnothing(s) ? NaN : _num(u"kgCO2e", getproperty(s, k))
    ax = [r.axial_ratio for r in det.columns if isfinite(r.axial_ratio)]
    return merge(by_pos, (
        M0_x_kipft          = isnothing(srow) ? NaN : srow.M0_x_kipft,
        M0_y_kipft          = isnothing(srow) ? NaN : srow.M0_y_kipft,
        n_stud_columns      = count(r -> r.studs, rep_cols),
        stud_vol_in3        = sum((r.stud_vol_in3 for r in rep_cols); init = 0.0),
        bldg_n_stud_columns = count(r -> r.studs, det.columns),
        bldg_stud_vol_in3   = sum((r.stud_vol_in3 for r in det.columns); init = 0.0),
        bldg_max_axial_ratio = isempty(ax) ? NaN : maximum(ax),
        bldg_all_ok         = isnothing(s) ? missing : s.all_checks_pass,
        bldg_critical_element = isnothing(s) ? "" : s.critical_element,
        bldg_critical_ratio = isnothing(s) ? NaN : s.critical_ratio,
        bldg_ec_kgco2e      = ecf(:embodied_carbon),
        bldg_ec_slabs_kgco2e = ecf(:embodied_carbon_slabs),
        bldg_ec_columns_kgco2e = ecf(:embodied_carbon_columns),
        bldg_ec_foundations_kgco2e = ecf(:embodied_carbon_foundations),
        bldg_ec_concrete_kgco2e = ecf(:embodied_carbon_concrete),
        bldg_ec_rebar_kgco2e = ecf(:embodied_carbon_rebar),
        bldg_concrete_m3    = isnothing(s) ? NaN : _num(u"m^3", s.concrete_volume),
        bldg_rebar_kg       = isnothing(s) ? NaN : _num(u"kg", s.rebar_weight),
    ))
end

"""Main-row summary fields when no details could be collected."""
_blank_summary_fields() = _summary_fields((columns = NamedTuple[], slabs = NamedTuple[]), nothing)

"""Write detail tables next to `outfile` (`<stem>_columns.csv`, `<stem>_slabs.csv`)."""
function _write_details(outfile::AbstractString, sink)
    stem = splitext(outfile)[1]
    paths = String[]
    for (k, rows) in pairs(sink)
        isempty(rows) && continue
        path = "$(stem)_$(k).csv"
        CSV.write(path, DataFrame(rows))
        push!(paths, path)
    end
    return paths
end

"""
Capture the building design, collect detail rows into `sink` (if given), and
return the main-row summary fields. Never throws: a failed capture or
collection gives NaN summaries.
"""
function _attach_details!(sink, struc, params, run_id::String;
                          cap_in::Real = NaN, increment_in::Real = 0.5)
    design = try
        capture_design(struc, params)
    catch e
        @debug "capture_design failed" run_id exception = e
        nothing
    end
    det = try
        _collect_details(struc, design, run_id; cap_in, increment_in)
    catch e
        @warn "Detail collection failed" run_id exception = (e, catch_backtrace())
        nothing
    end
    isnothing(det) && return _blank_summary_fields()
    if !isnothing(sink)
        append!(sink.columns, det.columns)
        append!(sink.slabs, det.slabs)
    end
    return _summary_fields(det, design)
end

"""Rows → DataFrame, keeping the union of columns when rows differ (failure rows)."""
_rows_df(rows) = isempty(rows) ? DataFrame() :
    vcat((DataFrame([r]) for r in rows)...; cols = :union)
