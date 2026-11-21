# Column oversize probe (Part B / plan.md O4).
#
# O4 ("Lightweight") is defined in docs/sizing-map/plan.md as: for each element,
# the final installed size versus "the lightest size its own final demands
# allow". This file measures that gap for flat-plate RC columns, read-only, on a
# finished design.
#
# It reuses the exact section search the fitter uses
# ([`_lightest_passing_group`](@ref) + [`_lightest_in_group`](@ref)), so the
# "lightest feasible" section passes the same member P-M, §10.12 joint and
# punching checks the sizer enforces. The only difference from
# [`_fit_flat_plate_columns!`](@ref) is that no grow-only floor is imposed
# (`floor = nothing`) and nothing is installed: the probe never mutates `struc`.
#
# The gap it reports is therefore a lower bound on how much lighter the columns
# could be under their *own* final demands — the motivation for the shrink-and-
# verify work. It holds every other element fixed, so it is a local measure, not
# a re-solve of the whole building.

"""Gross plan area of a column section (its bounding box), the concrete-volume
(hence carbon) proxy per unit story height. Exact gross area for rectangular RC
sections; a slight overestimate for circular sections (bounding square)."""
function _section_plan_area(sec)
    bb = StructuralSizer.bounding_box(sec)
    return bb.width * bb.depth
end

"""
    flat_plate_column_oversize(struc, params, column_opts) -> Dict{Int, NamedTuple}

For every flat-plate RC column on a finished design, the lightest catalog
section that still passes the column's full-load strength, its §10.12 joint
sections and punching **at the column's own final demands**, with no grow-only
floor.

Returns, per column index `i`, a NamedTuple:

- `installed`      — the section currently on the column,
- `lightest`       — the lightest feasible catalog section at the final demands,
- `area_installed` / `area_lightest` — their gross plan areas,
- `oversize`       — `(area_installed - area_lightest) / area_installed`, the
                     fraction of plan area that could be removed (0 if already
                     lightest, never negative since `lightest` is feasible),
- `story`, `source`.

Columns with no stored punching demand are skipped (punching cannot be assessed
without shrinking the column, the same conservatism as
[`_fit_flat_plate_columns!`](@ref)'s shrink path).

Read-only: `struc` is never mutated.
"""
@noinline function flat_plate_column_oversize(struc::BuildingStructure, params, column_opts)
    @nospecialize struc params column_opts
    checks = flat_plate_column_checks(struc, column_opts; params)
    out = Dict{Int, NamedTuple}()
    isempty(checks) && return out
    checker = _aci_column_checker(column_opts)
    jchecker = _joint_checker(column_opts)
    catalog = _memo_column_catalog(column_opts)
    cap = _flat_plate_column_cap(params)
    for i in sort!(collect(keys(checks)))
        col = struc.columns[i]
        sec0 = section(col)
        (sec0 isa StructuralSizer.RCColumnSection ||
            sec0 isa StructuralSizer.RCCircularSection) || continue
        # Punching is assessed from the stored slab analysis; without it the
        # column cannot be shrunk, so it has no measurable oversize here.
        demands = _column_punching_demands(struc, col)
        isempty(demands) && continue
        mat = _column_cache_material(col, column_opts)
        cache = _memo_capacity_cache(checker, catalog, mat, column_opts.objective)
        groups = _memo_plan_groups(catalog, cache, cap)
        orient = _rc_demand_orientations(checks[i].demand, column_opts.βdns)
        geom = checks[i].geometry
        joint = checks[i].joint
        punch = Dict{Tuple{Float64, Float64}, Union{Bool, Nothing}}()
        # `floor = nothing`: measure the lightest feasible size with no grow-only
        # floor, i.e. what the column's own final demands actually require.
        lo = _lightest_passing_group(
            groups, catalog, nothing, punch, struc, params, col, demands,
            checker, cache, mat, orient, geom, jchecker, column_opts, joint)
        lo === nothing && continue
        pick = _lightest_in_group(
            groups[lo], catalog, checker, cache, mat, orient, geom,
            jchecker, col, column_opts, joint)
        pick === nothing && continue
        lightest = catalog[pick]
        a_inst = _section_plan_area(sec0)
        a_light = _section_plan_area(lightest)
        frac = a_inst > zero(a_inst) ? Float64((a_inst - a_light) / a_inst) : 0.0
        out[i] = (installed = sec0, lightest = lightest,
                  area_installed = a_inst, area_lightest = a_light,
                  oversize = max(frac, 0.0), story = col.story,
                  source = checks[i].source)
    end
    return out
end

"""
    flat_plate_column_shrink_verify!(struc, params, column_opts) -> Vector{Int}

The "final shrink pass" of the architecture (architecture.md §2): on a finished
design, install on every oversized flat-plate RC column the lightest feasible
section [`flat_plate_column_oversize`](@ref) found, then re-solve the frame so a
following capture re-checks the whole building at the shrunk sizes.

Returns the indices of the columns that were shrunk. Mutates `struc` in place
(sections, volumes, frame sections and the frame solution). The caller verifies
by re-capturing the design and reading `summary.all_checks_pass`.

Fidelity note: the member P-M, §10.12 joint and punching checks the shrink
relies on are evaluated at the column's *final* (pre-shrink) demands, which are
heavier than a smaller column attracts (less moment, less transferred unbalanced
moment), so the column-level verification is conservative. What a re-capture does
**not** refresh is the slab FEA itself (it is embedded in the slab sizer), so the
knock-on redistribution onto other elements is only captured to the extent the
frame re-solve and the stored slab demands reflect it. A gold-standard verify
re-runs the slab analysis at the shrunk sizes (future Workstream F)."""
@noinline function flat_plate_column_shrink_verify!(struc::BuildingStructure, params, column_opts)
    @nospecialize struc params column_opts
    ov = flat_plate_column_oversize(struc, params, column_opts)
    shrunk = Int[]
    for i in sort!(collect(keys(ov)))
        r = ov[i]
        r.oversize > 1e-9 || continue
        col = struc.columns[i]
        sec = r.lightest
        bb = StructuralSizer.bounding_box(sec)
        col.c1 = bb.width
        col.c2 = bb.depth
        set_section!(col, sec)
        _set_rc_column_volumes!(col,
            something(col.concrete, column_concrete(params)),
            column_rebar(params))
        _install_column_frame_section!(struc, col, _rc_column_frame_section(col, params))
        push!(shrunk, i)
    end
    isempty(shrunk) || _reanalyze_after_section_change!(struc)
    return shrunk
end
