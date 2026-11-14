# =============================================================================
# Flat-plate columns under the full building load
# =============================================================================
#
# The slab loop sizes each supporting column against one panel's tributary
# axial load and that panel's unbalanced moment. This check uses the axial
# force from the frame model, which carries every floor above, and the
# unbalanced slab moment at both ends of the column.
#
# The frame's beam-line members in a flat-plate building keep the placeholder
# section `to_asap!` gives them, so the frame's column moments are not used.

"""
    _flat_plate_joint_moments(struc) -> Dict{Int, NTuple{2, Float64}}

Unbalanced slab moment (kip·ft) at the joint on top of each column, as
`(Mx, My)` for bending in the global X and Y span directions.

Each flat-plate slab reports, for the columns below it, the unbalanced moment
in its primary and perpendicular directions. The primary direction is the
slab's span axis, assigned to X or Y by its larger component. Where several
slabs report the same column, the larger moment in each direction is kept:
each slab analysis models the whole unbalance at that joint for its own
loading, and the slab loop already requires every one of them to pass.

A flat-plate slab that reports columns without `Mu_secondary` throws, so a
result that dropped the perpendicular moment is never read as zero.
"""
function _flat_plate_joint_moments(struc::BuildingStructure)
    joint = Dict{Int, NTuple{2, Float64}}()
    kipft = Asap.kip * u"ft"
    for slab in struc.slabs
        slab.floor_type in (:flat_plate, :flat_slab) || continue
        dd = slab.design_details
        (dd isa NamedTuple && hasproperty(dd, :column_results)) || continue
        crs = dd.column_results
        isnothing(crs) && continue
        ax = slab.spans.axis
        primary_is_x = abs(ax[1]) >= abs(ax[2])
        for (cidx, r) in crs
            hasproperty(r, :Mu_secondary) || throw(ArgumentError(
                "flat-plate column $cidx: the slab result has no Mu_secondary, so " *
                "the perpendicular unbalanced moment is unknown"))
            mp = abs(ustrip(kipft, r.Mu))
            ms = abs(ustrip(kipft, r.Mu_secondary))
            mx, my = primary_is_x ? (mp, ms) : (ms, mp)
            old = get(joint, cidx, (0.0, 0.0))
            joint[cidx] = (max(old[1], mx), max(old[2], my))
        end
    end
    return joint
end

"""
Column options the flat-plate slab loop sized with: `params.columns` when it
is concrete, otherwise the kernel's default `ConcreteColumnOptions()`.
"""
function _flat_plate_column_opts(params::DesignParameters)
    opts = params.columns
    return opts isa StructuralSizer.ConcreteColumnOptions ? opts :
        StructuralSizer.ConcreteColumnOptions()
end

"""Index of the column directly below each column that has one."""
function _column_below_index(struc::BuildingStructure)
    below = Dict{Int, Int}()
    for (i, col) in enumerate(struc.columns)
        above = col.column_above
        isnothing(above) && continue
        j = findfirst(c -> c === above, struc.columns)
        j === nothing || (below[j] = i)
    end
    return below
end

"""
    flat_plate_column_demands(struc, column_opts) -> Dict{Int, NamedTuple}

Full-load demand on every column that a flat-plate slab reports.

- `Pu` (kip): compression in the frame model, the larger end of the
  column's segments ([`_column_asap_Pu`](@ref)). It includes every floor
  above.
- End moments (kip·ft), per ACI 318-11 §13.6.9.2 (corpus: aci-318-11,
  page 258): the elements above and below a slab resist its unbalanced
  moment in proportion to their stiffnesses. The top end takes the
  below-the-slab share of the joint on top of this column, the factor from
  `StructuralSizer.column_moment_distribution_factors`. The bottom end
  takes the rest of the joint on top of the column below.
- `M1`/`M2` follow the ACI 318-19 sign convention of
  `StructuralSizer.calc_Cm`. The two ends come from different load patterns,
  so the curvature is not known and single curvature (`M1 ≤ 0`) is assumed.
  That gives the larger `Cm` (ACI 318-19 Eq. 6.6.4.5.3a).

The returned moments use global X and Y span directions. A column with no
slab-reported joint at either end is omitted.
"""
function flat_plate_column_demands(struc::BuildingStructure, column_opts)
    joint = _flat_plate_joint_moments(struc)
    isempty(joint) && return Dict{Int, NamedTuple}()
    below = _column_below_index(struc)
    df(i) = StructuralSizer.column_moment_distribution_factors(
        struc, [struc.columns[i]], column_opts)[1]

    out = Dict{Int, NamedTuple}()
    for (i, col) in enumerate(struc.columns)
        (isnothing(col.c1) || isnothing(col.c2)) && continue
        top = haskey(joint, i) ? df(i) .* joint[i] : (0.0, 0.0)
        b = get(below, i, 0)
        bot = (b != 0 && haskey(joint, b)) ? (1.0 - df(b)) .* joint[b] : (0.0, 0.0)
        (haskey(joint, i) || (b != 0 && haskey(joint, b))) || continue
        Pu = ustrip(Asap.kip, _column_asap_Pu(struc, col) * u"N")
        M2x, M2y = max(top[1], bot[1]), max(top[2], bot[2])
        M1x, M1y = -min(top[1], bot[1]), -min(top[2], bot[2])
        out[i] = (Pu = Pu, M1x = M1x, M2x = M2x, M1y = M1y, M2y = M2y)
    end
    return out
end

"""
Both assignments of the global moments to the section axes.

Which global direction bends a rectangular section about its strong axis is
not recorded, so both are checked and the worse governs. A square section
with a symmetric bar layout gives the same result both ways.
"""
function _rc_demand_orientations(d, βdns)
    a = StructuralSizer.RCColumnDemand(1; Pu = d.Pu, Mux = d.M2x, Muy = d.M2y,
        M1x = d.M1x, M2x = d.M2x, M1y = d.M1y, M2y = d.M2y, βdns = βdns)
    b = StructuralSizer.RCColumnDemand(2; Pu = d.Pu, Mux = d.M2y, Muy = d.M2x,
        M1x = d.M1y, M2x = d.M2y, M1y = d.M1x, M2y = d.M2x, βdns = βdns)
    return (a, b)
end

"""The same ACI column checker the column sizer builds from `opts`."""
_aci_column_checker(opts) = StructuralSizer.ACIColumnChecker(;
    include_slenderness = opts.include_slenderness,
    include_biaxial = opts.include_biaxial,
    fy_ksi = ustrip(Asap.ksi, opts.rebar_material.Fy),
    Es_ksi = ustrip(Asap.ksi, opts.rebar_material.E),
    max_depth = opts.max_depth,
)

"""
Geometry the slab loop sizes flat-plate columns with: braced, `k = 1` about
both axes, unsupported length equal to the member length.
"""
_flat_plate_column_geometry(col) = StructuralSizer.ConcreteMemberGeometry(
    col.base.L; Lu = col.base.L, kx = 1.0, ky = 1.0, braced = true)

_column_concrete(col, opts) = something(col.concrete, opts.material)

"""
    _rc_section_check(checker, opts, section, material, demands, geometry)
        -> (passed, explanation)

`passed` is the sizer's own test, `is_feasible`, under every demand.
`explanation` is the `explain_feasibility` of the demand with the highest
governing ratio, for reporting.
"""
function _rc_section_check(checker, opts, section, material, demands, geometry)
    cache = StructuralSizer.create_cache(checker, 1)
    StructuralSizer.precompute_capacities!(checker, cache, [section], material, opts.objective)
    passed = all(d -> StructuralSizer.is_feasible(checker, cache, 1, section, material, d, geometry),
                 demands)
    worst = nothing
    for d in demands
        ex = StructuralSizer.explain_feasibility(checker, cache, 1, section, material, d, geometry)
        (worst === nothing || ex.governing_ratio > worst.governing_ratio) && (worst = ex)
    end
    return (passed, worst)
end

"""
    flat_plate_column_checks(struc, column_opts) -> Dict{Int, NamedTuple}

Check every flat-plate column's installed section under
[`flat_plate_column_demands`](@ref). Each entry has `passed`,
`governing_check`, `governing_ratio`, `axial_ratio`, and `demand`.
"""
function flat_plate_column_checks(struc::BuildingStructure, column_opts)
    column_opts isa StructuralSizer.ConcreteColumnOptions || return Dict{Int, NamedTuple}()
    demands = flat_plate_column_demands(struc, column_opts)
    checker = _aci_column_checker(column_opts)
    out = Dict{Int, NamedTuple}()
    for (i, d) in demands
        col = struc.columns[i]
        sec = section(col)
        (sec isa StructuralSizer.RCColumnSection || sec isa StructuralSizer.RCCircularSection) ||
            continue
        passed, ex = _rc_section_check(checker, column_opts, sec,
                                       _column_concrete(col, column_opts),
                                       _rc_demand_orientations(d, column_opts.βdns),
                                       _flat_plate_column_geometry(col))
        k = findfirst(c -> c.name == "axial_cap", ex.checks)
        out[i] = (passed = passed, governing_check = ex.governing_check,
                  governing_ratio = ex.governing_ratio,
                  axial_ratio = k === nothing ? NaN : ex.checks[k].ratio,
                  demand = d)
    end
    return out
end

"""Column catalog the sizer would search for `opts`."""
_column_catalog(opts) = isnothing(opts.custom_catalog) ?
    StructuralSizer.rc_column_catalog(opts.section_shape, opts.catalog) :
    opts.custom_catalog

"""True when `sec` is at least `col`'s size in both plan directions, as `b → c1`, `h → c2`."""
function _section_covers_column(sec, col)
    tol = 0.05u"inch"
    if sec isa StructuralSizer.RCCircularSection
        return col.shape == :circular && sec.D >= col.c1 - tol
    elseif sec isa StructuralSizer.RCColumnSection
        return col.shape != :circular && sec.b >= col.c1 - tol && sec.h >= col.c2 - tol
    end
    return false
end

function _section_within_cap(sec, cap)
    cap === nothing && return true
    bb = StructuralSizer.bounding_box(sec)
    return bb.width <= cap + 0.05u"inch" && bb.depth <= cap + 0.05u"inch"
end

"""Largest column the flat-plate options allow, or `nothing`."""
function _flat_plate_column_cap(params::DesignParameters)
    fo = resolve_floor_options(params)
    fp = fo isa StructuralSizer.FlatSlabOptions ? fo.base : fo
    return hasproperty(fp, :max_column_size) ? fp.max_column_size : nothing
end

"""
    _grow_flat_plate_columns!(struc, params, column_opts, checks) -> (grown, unresolved)

For each failing check, install the lightest catalog section (by the
sizer's objective) that covers the column, stays within the flat-plate
column cap, and passes the same checker under both demand orientations.
That is the single-member choice the discrete sizer makes. A column with no
such section keeps its section and is returned in `unresolved`.
"""
function _grow_flat_plate_columns!(struc, params, column_opts, checks)
    failing = [i for (i, c) in checks if !c.passed]
    isempty(failing) && return (Int[], Int[])
    checker = _aci_column_checker(column_opts)
    catalog = _column_catalog(column_opts)
    cap = _flat_plate_column_cap(params)
    caches = Dict{Any, Any}()
    grown, unresolved = Int[], Int[]
    for i in sort(failing)
        col = struc.columns[i]
        mat = _column_concrete(col, column_opts)
        cache = get!(caches, mat) do
            c = StructuralSizer.create_cache(checker, length(catalog))
            StructuralSizer.precompute_capacities!(checker, c, catalog, mat, column_opts.objective)
            c
        end
        demands = _rc_demand_orientations(checks[i].demand, column_opts.βdns)
        geom = _flat_plate_column_geometry(col)
        order = sortperm(cache.obj_coeffs)
        pick = findfirst(order) do j
            sec = catalog[j]
            _section_covers_column(sec, col) && _section_within_cap(sec, cap) &&
                all(d -> StructuralSizer.is_feasible(checker, cache, j, sec, mat, d, geom), demands)
        end
        if pick === nothing
            push!(unresolved, i)
            continue
        end
        sec = catalog[order[pick]]
        bb = StructuralSizer.bounding_box(sec)
        col.c1 = bb.width
        col.c2 = bb.depth
        set_section!(col, sec)
        _set_rc_column_volumes!(col,
            something(col.concrete, resolve_column_concrete(params.materials)),
            resolve_column_rebar(params.materials))
        _install_column_frame_section!(struc, col, _rc_column_frame_section(col, params))
        push!(grown, i)
    end
    return (grown, unresolved)
end

StructuralSizer.TRACE_REGISTRY[(:check_flat_plate_columns!, :workflow)] =
    StructuralSizer.TracedFunctionMeta(
        :check_flat_plate_columns!,
        :workflow,
        [:enter, :exit, :decision],
        nothing,
        @__FILE__,
        @__LINE__,
    )

"""
    check_flat_plate_columns!(struc, params; tc=nothing) -> NamedTuple

Check every flat-plate column under the full building load and grow the ones
that fail, re-solving after each round, until a round grows nothing.

Growth only increases a column, so the rounds end. Each round re-solves the
frame because a larger column carries more self-weight and changes the
§13.6.9.2 stiffness split. Returns `(grown, unresolved, rounds, converged)`.
`unresolved` lists columns that no catalog section within the flat-plate
column cap satisfies; they keep their section and fail the captured check.
"""
function check_flat_plate_columns!(struc::BuildingStructure, params::DesignParameters;
                                   tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing)
    column_opts = _flat_plate_column_opts(params)
    StructuralSizer.emit!(tc, :workflow, "check_flat_plate_columns!", "", :enter;
                          n_columns = length(struc.columns))
    grown_all = Set{Int}()
    unresolved = Int[]
    budget = StructuralSizer.monotone_budget(
        params.max_iterations, length(_column_catalog(column_opts)))
    run = StructuralSizer.settle!(; budget) do _
        checks = flat_plate_column_checks(struc, column_opts)
        grown, unresolved = _grow_flat_plate_columns!(struc, params, column_opts, checks)
        stacked, _ = _stack_flat_plate_columns!(struc, params, column_opts, checks)
        append!(grown, stacked)
        isempty(grown) && return false
        union!(grown_all, grown)
        update_structural_offsets!(struc; input_is_centerline = params.geometry_is_centerline)
        _resolve_after_column_change!(struc)
        return true
    end
    _shrink_flat_plate_columns!(struc, params, column_opts)
    isempty(unresolved) || @warn "Flat-plate columns fail the full-load P-M check and no catalog section within the column cap passes" columns = unresolved
    run.converged || @warn "Flat-plate column check still growing when its budget ran out" rounds = run.steps
    StructuralSizer.emit!(tc, :workflow, "check_flat_plate_columns!", "", :decision;
                          n_grown = length(grown_all), n_unresolved = length(unresolved),
                          rounds = run.steps, stop = string(run.stop))
    StructuralSizer.emit!(tc, :workflow, "check_flat_plate_columns!", "", :exit;
                          n_grown = length(grown_all))
    return (grown = sort!(collect(grown_all)), unresolved = unresolved,
            rounds = run.steps, converged = run.converged)
end

"""Plan area of a column section, m². A circular column uses `c1` as the diameter."""
function _column_plan_area(col)
    (isnothing(col.c1) || isnothing(col.c2)) && return 0.0
    col.shape == :circular && return ustrip(u"m^2", π / 4 * col.c1^2)
    return ustrip(u"m^2", col.c1 * col.c2)
end

function _install_rc_column_section!(struc, params, col, sec)
    bb = StructuralSizer.bounding_box(sec)
    col.c1 = bb.width
    col.c2 = bb.depth
    set_section!(col, sec)
    _set_rc_column_volumes!(col,
        something(col.concrete, resolve_column_concrete(params.materials)),
        resolve_column_rebar(params.materials))
    _install_column_frame_section!(struc, col, _rc_column_frame_section(col, params))
    return sec
end

"""
Lower column adopts the column above as a whole section.

Design policy, not a code check: the lower column is not given the larger
side of each plan axis. A 12×20 under a 20×12 stays the lighter of those two
whole sections. The adopted section has to pass the lower column's full-load
demand and the flat-plate size cap. A column above with a different shape is
left alone.
"""
function _stack_flat_plate_columns!(struc, params, column_opts, checks)
    checker = _aci_column_checker(column_opts)
    catalog = _column_catalog(column_opts)
    cap = _flat_plate_column_cap(params)
    is_rc(c) = section(c) isa StructuralSizer.RCColumnSection ||
               section(c) isa StructuralSizer.RCCircularSection
    grown, stuck = Int[], Int[]
    order = sortperm([c.story for c in struc.columns]; rev = true)
    for i in order
        col = struc.columns[i]
        above = col.column_above
        (above === nothing || !is_rc(col) || !is_rc(above)) && continue
        _column_plan_area(col) + 1e-6 >= _column_plan_area(above) && continue
        haskey(checks, i) || (push!(stuck, i); continue)
        above_sec = section(above)
        above_sec === nothing && continue
        mat = _column_concrete(col, column_opts)
        demands = _rc_demand_orientations(checks[i].demand, column_opts.βdns)
        geom = _flat_plate_column_geometry(col)
        candidates = StructuralSizer.AbstractSection[above_sec]
        if col.shape != :circular
            for sec in catalog
                bb = StructuralSizer.bounding_box(sec)
                (bb.width ≈ above.c2 && bb.depth ≈ above.c1) || continue
                push!(candidates, sec)
                break
            end
        end
        cache = StructuralSizer.create_cache(checker, length(candidates))
        StructuralSizer.precompute_capacities!(checker, cache, candidates, mat, column_opts.objective)
        pick = nothing
        best = Inf
        for (j, sec) in enumerate(candidates)
            _section_within_cap(sec, cap) || continue
            all(d -> StructuralSizer.is_feasible(checker, cache, j, sec, mat, d, geom), demands) || continue
            cost = cache.obj_coeffs[j]
            cost < best || continue
            best = cost
            pick = sec
        end
        if pick === nothing
            @warn "Column above is a larger section and neither that section nor its rotation passes the lower column" column = i
            push!(stuck, i)
            continue
        end
        _install_rc_column_section!(struc, params, col, pick)
        push!(grown, i)
    end
    return (grown, stuck)
end

"""True when every flat-plate slab this column supports still punches at the column's current size."""
function _column_punching_still_ok(struc, params, col)
    fo = resolve_floor_options(params)
    fp = fo isa StructuralSizer.FlatSlabOptions ? fo.base : fo
    fp isa StructuralSizer.FlatPlateOptions || return true
    cover = fp.cover
    bar_dia = StructuralSizer.bar_diameter(fp.bar_size)
    fc = fp.material.concrete.fc′
    λ = isnothing(fp.λ) ? fp.material.concrete.λ : fp.λ
    saw = false
    for slab in struc.slabs
        slab.floor_type in (:flat_plate, :flat_slab) || continue
        cols = StructuralSizer.find_supporting_columns(struc, Set(slab.cell_indices))
        i = findfirst(c -> c === col, cols)
        i === nothing && continue
        saw = true
        dd = slab.design_details
        (dd isa NamedTuple && hasproperty(dd, :moment_results) && dd.moment_results !== nothing) ||
            return false
        mr = dd.moment_results
        length(mr.column_shears) == length(cols) || return false
        length(mr.unbalanced_moments) == length(cols) || return false
        h = thickness(slab)
        d = StructuralSizer.effective_depth(h; cover = cover, bar_diameter = bar_dia)
        sr = hasproperty(dd, :secondary_results) ? dd.secondary_results : nothing
        Muy = (sr === nothing || !hasproperty(sr, :unbalanced_moments)) ? nothing :
              sr.unbalanced_moments[i]
        pr = StructuralSizer.check_punching_for_column(
            col, mr.column_shears[i], mr.unbalanced_moments[i], d, h, fc;
            Muy = Muy, λ = λ, φ_shear = fp.φ_shear,
            StructuralSizer.punching_axis_kwargs(struc, slab, col)...)
        pr.ok || return false
    end
    return saw || true
end

"""
Try a lighter catalog section after the column loop has settled.

The section has to pass the same full-load P-M check and the stored slab
punching shear at the new size. One re-solve confirms the forces. A column
that then fails goes back to the section it had.
"""
function _shrink_flat_plate_columns!(struc, params, column_opts)
    column_opts isa StructuralSizer.ConcreteColumnOptions || return Int[]
    checks = flat_plate_column_checks(struc, column_opts)
    isempty(checks) && return Int[]
    checker = _aci_column_checker(column_opts)
    catalog = _column_catalog(column_opts)
    cap = _flat_plate_column_cap(params)
    caches = Dict{Any, Any}()
    saved = Dict{Int, Any}()
    shrunk = Int[]
    for (i, chk) in checks
        chk.passed || continue
        col = struc.columns[i]
        mat = _column_concrete(col, column_opts)
        cache = get!(caches, mat) do
            c = StructuralSizer.create_cache(checker, length(catalog))
            StructuralSizer.precompute_capacities!(checker, c, catalog, mat, column_opts.objective)
            c
        end
        demands = _rc_demand_orientations(chk.demand, column_opts.βdns)
        geom = _flat_plate_column_geometry(col)
        cur = _column_plan_area(col)
        order = sortperm(cache.obj_coeffs)
        pick = nothing
        for j in order
            sec = catalog[j]
            bb = StructuralSizer.bounding_box(sec)
            area = ustrip(u"m^2", bb.width * bb.depth)
            area < cur - 1e-8 || continue
            _section_within_cap(sec, cap) || continue
            all(d -> StructuralSizer.is_feasible(checker, cache, j, sec, mat, d, geom), demands) || continue
            old_c1, old_c2, old_sec = col.c1, col.c2, section(col)
            _install_rc_column_section!(struc, params, col, sec)
            if _column_punching_still_ok(struc, params, col)
                pick = sec
                saved[i] = old_sec
                break
            end
            col.c1, col.c2 = old_c1, old_c2
            old_sec === nothing || _install_rc_column_section!(struc, params, col, old_sec)
        end
        pick === nothing || push!(shrunk, i)
    end
    isempty(shrunk) && return shrunk
    update_structural_offsets!(struc; input_is_centerline = params.geometry_is_centerline)
    _resolve_after_column_change!(struc)
    again = flat_plate_column_checks(struc, column_opts)
    restored = false
    for i in shrunk
        haskey(again, i) && again[i].passed && _column_punching_still_ok(struc, params, struc.columns[i]) && continue
        sec = saved[i]
        sec === nothing && continue
        _install_rc_column_section!(struc, params, struc.columns[i], sec)
        restored = true
    end
    restored && _resolve_after_column_change!(struc)
    return shrunk
end
