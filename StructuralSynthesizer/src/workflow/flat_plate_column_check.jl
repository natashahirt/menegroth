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

# =============================================================================
# Run-level memo for column capacity caches, catalogs, and plan-size groups
# =============================================================================
#
# `precompute_capacities!` (the P-M diagram build over the whole RC catalog) is
# the costliest part of the member stage, and the column helpers below
# (`_stack`/`_grow`/`_fit`, plus the §10.12 joint checks) otherwise rebuild it
# on every settle round — and `_fit` re-derived the plan-size groups once per
# column. A filled `ACIColumnCapacityCache` is a pure function of the catalog
# sections, the concrete (fc, fy, Es, εcu), the objective, and the biaxial
# flag, and it is only *read* by `is_feasible` / `explain_feasibility`, so it is
# safe to memoize and share across calls and threads. Entries are validated with
# `StructuralSizer.cache_matches` plus identity guards before reuse; any mismatch
# rebuilds. The standard catalog is itself memoized so its object identity is
# stable (a cheap, deterministic key). This is speed.md opportunity #10, exact.

const _COL_MEMO_LOCK = ReentrantLock()
const _STD_CATALOG_MEMO = Dict{Tuple{Symbol, Symbol}, Vector}()

struct _ColCacheEntry
    catalog::Any      # exact catalog the cache was built against (objectid-reuse guard)
    material::Any
    objective::Any
    cache::StructuralSizer.ACIColumnCapacityCache
end
const _COL_CACHE_MEMO = Dict{Any, _ColCacheEntry}()

struct _PlanGroupsEntry
    catalog::Any
    groups::Vector{Vector{Int}}
end
const _COL_GROUPS_MEMO = Dict{Any, _PlanGroupsEntry}()

"""
    _memo_column_catalog(opts) -> Vector

Catalog for `opts`, memoized. A custom catalog is returned as given (its
identity is the user's); a standard catalog is built once per
`(section_shape, catalog)` and cached, so its object identity is stable for
keying [`_memo_capacity_cache`](@ref) and [`_memo_plan_groups`](@ref).
"""
function _memo_column_catalog(opts)
    opts.custom_catalog === nothing || return opts.custom_catalog
    key = (opts.section_shape, opts.catalog)
    return lock(_COL_MEMO_LOCK) do
        get!(() -> StructuralSizer.rc_column_catalog(opts.section_shape, opts.catalog),
             _STD_CATALOG_MEMO, key)
    end
end

"""Memo key for a full-catalog capacity cache under `checker`/`material`/`objective`."""
_capacity_cache_key(checker, catalog, material, objective) =
    (objectid(catalog), objectid(material), objectid(objective),
     checker.include_biaxial, checker.fy_ksi, checker.Es_ksi)

"""True when memo entry `e` is a valid, reusable cache for this request. The
identity guards pin the catalog/material/objective (so `εcu` and the objective
coefficients, which `cache_matches` does not compare, cannot drift) and
`cache_matches` re-checks f′c/fy/Es and the weak-axis diagrams."""
_capacity_entry_valid(e, checker, catalog, material, objective) =
    e !== nothing && e.catalog === catalog && e.material === material &&
    e.objective === objective &&
    StructuralSizer.cache_matches(checker, e.cache, catalog, material)

"""
    _memo_capacity_cache(checker, catalog, material, objective) -> ACIColumnCapacityCache

Precomputed, read-only capacity cache for `catalog` under `material` and
`objective`, memoized and shared across the run.

A validated hit is returned as-is. `StructuralSizer.cache_matches` re-checks
f′c / fy / Es and the weak-axis diagrams; the stored catalog / material /
objective identities guard against `objectid` reuse and against an objective
change (which `cache_matches` alone would miss, since it does not compare the
objective coefficients the group ordering reads).
"""
function _memo_capacity_cache(checker, catalog, material, objective)
    key = _capacity_cache_key(checker, catalog, material, objective)
    return lock(_COL_MEMO_LOCK) do
        e = get(_COL_CACHE_MEMO, key, nothing)
        _capacity_entry_valid(e, checker, catalog, material, objective) && return e.cache
        cache = StructuralSizer.create_cache(checker, length(catalog))
        StructuralSizer.precompute_capacities!(checker, cache, catalog, material, objective)
        _COL_CACHE_MEMO[key] = _ColCacheEntry(catalog, material, objective, cache)
        return cache
    end
end

"""
    _peek_capacity_cache(checker, catalog, material, objective) -> ACIColumnCapacityCache or nothing

The already-built, validated full-catalog capacity cache for this request, or
`nothing` when none is memoized. Unlike [`_memo_capacity_cache`](@ref) it never
builds one — it is for reusing a catalog diagram the sizing stage already paid
for (speed.md #20) without forcing a full-catalog precompute just to check one
installed section.
"""
function _peek_capacity_cache(checker, catalog, material, objective)
    key = _capacity_cache_key(checker, catalog, material, objective)
    return lock(_COL_MEMO_LOCK) do
        e = get(_COL_CACHE_MEMO, key, nothing)
        _capacity_entry_valid(e, checker, catalog, material, objective) ? e.cache : nothing
    end
end

"""Identity → index map of a catalog's sections, memoized by catalog identity so a
column installed from the catalog can be found in O(1)."""
const _CATALOG_INDEX_MEMO = Dict{Any, IdDict{Any, Int}}()

"""
    _catalog_section_index(opts, section) -> Int or nothing

The index `j` with `catalog[j] === section` in `opts`'s (memoized) column
catalog, or `nothing` when `section` is not a catalog section (a user-specified
section, or a non-RC section). Identity-based: a column sized from the catalog
holds the exact catalog object (`set_section!` stores it as-is), so its P-M
diagram in a full-catalog cache at `j` is the one a one-section cache would
rebuild.
"""
function _catalog_section_index(opts, section)
    catalog = _memo_column_catalog(opts)
    return lock(_COL_MEMO_LOCK) do
        idx = get!(_CATALOG_INDEX_MEMO, objectid(catalog)) do
            m = IdDict{Any, Int}()
            for (j, sec) in enumerate(catalog)
                get!(m, sec, j)   # first index wins if a section repeats
            end
            m
        end
        get(idx, section, nothing)
    end
end

"""
    _memo_plan_groups(catalog, cache, cap) -> Vector{Vector{Int}}

Plan-size groups ([`_catalog_plan_groups`](@ref)) for `catalog` at the
objective coefficients `cache.obj_coeffs` and column cap `cap`, memoized.
Keyed by the catalog and cache identities (both stable via the memos above)
and the cap.
"""
function _memo_plan_groups(catalog, cache, cap)
    capkey = cap === nothing ? nothing : round(ustrip(u"inch", cap); digits = 3)
    key = (objectid(catalog), objectid(cache), capkey)
    return lock(_COL_MEMO_LOCK) do
        e = get(_COL_GROUPS_MEMO, key, nothing)
        (e !== nothing && e.catalog === catalog) && return e.groups
        groups = _catalog_plan_groups(catalog, cache.obj_coeffs, cap)
        _COL_GROUPS_MEMO[key] = _PlanGroupsEntry(catalog, groups)
        return groups
    end
end

struct _SecCacheEntry
    section::Any
    material::Any
    objective::Any
    cache::StructuralSizer.ACIColumnCapacityCache
end
const _SEC_CACHE_MEMO = Dict{Any, _SecCacheEntry}()

"""
    _memo_section_cache(checker, section, material, objective) -> ACIColumnCapacityCache

Single-section capacity cache (one entry, index 1) for checking an already
installed section, memoized. Many columns carry the same catalog section, so
this reuses the P-M diagram across them and across settle rounds instead of
rebuilding it on each `_rc_section_check`. Same exactness guarantees and guards
as [`_memo_capacity_cache`](@ref).
"""
function _memo_section_cache(checker, section, material, objective)
    key = (objectid(section), objectid(material), objectid(objective),
           checker.include_biaxial, checker.fy_ksi, checker.Es_ksi)
    return lock(_COL_MEMO_LOCK) do
        e = get(_SEC_CACHE_MEMO, key, nothing)
        if e !== nothing && e.section === section && e.material === material &&
           e.objective === objective &&
           StructuralSizer.cache_matches(checker, e.cache, (section,), material)
            return e.cache
        end
        cache = StructuralSizer.create_cache(checker, 1)
        StructuralSizer.precompute_capacities!(checker, cache, [section], material, objective)
        _SEC_CACHE_MEMO[key] = _SecCacheEntry(section, material, objective, cache)
        return cache
    end
end

"""
    _flat_plate_joint_moments(struc, column_opts) -> Dict{Int, NamedTuple}

Slab moment (kip·ft) at the joint on top of each column, as
`(below = (Mx, My), above = (Mx, My))`: the part the column below the slab
resists and the part the column above it resists, for bending in the global
X and Y span directions.

Each flat-plate slab reports, for the columns below it, the unbalanced moment
in its primary and perpendicular directions. The primary direction is the
slab's span axis, assigned to X or Y by its larger component.

- A shell analysis reports the moment in each column stub (`Mu_below`,
  `Mu_above`, and the perpendicular pair). Those are used as they are, the
  same moments the slab loop sized the column below with.
- DDM and EFM report only the joint moment, and so does a direction whose
  stub pair is `nothing`. It is split by stiffness, per
  ACI 318-11 §13.6.9.2 (corpus: aci-318-11, page 258), with the factor from
  `StructuralSizer.column_moment_distribution_factors`. Applying that split
  at an edge or corner column is engineering judgment; the clause states it
  for an interior support.

Where several slabs report the same column, the larger value of each part
is kept: each slab analysis models the whole unbalance at that joint for its
own loading, and the slab loop already requires every one of them to pass.

A flat-plate slab that reports columns without `Mu_secondary` throws, so a
result that dropped the perpendicular moment is never read as zero.
"""
function _flat_plate_joint_moments(struc::BuildingStructure, column_opts)
    Pair2 = NTuple{2, Float64}
    joint = Dict{Int, NamedTuple{(:below, :above), Tuple{Pair2, Pair2}}}()
    kipft = Asap.kip * u"ft"
    m(v) = abs(ustrip(kipft, v))
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
            has(k) = hasproperty(r, k) && getproperty(r, k) !== nothing
            # One stiffness factor per bending direction: the primary moment
            # bends the column in the plane of the slab's span axis, the
            # secondary moment in the perpendicular plane.
            fp, fs = (has(:Mu_below) && has(:Mu_secondary_below)) ? (1.0, 1.0) :
                let dist = StructuralSizer.column_moment_distribution_factors(
                        struc, [struc.columns[cidx]], column_opts;
                        span_axis = StructuralSizer._get_span_axis(slab))
                    (dist.primary[1], dist.secondary[1])
                end
            pb, pa = has(:Mu_below) ? (m(r.Mu_below), m(r.Mu_above)) :
                (fp * m(r.Mu), (1 - fp) * m(r.Mu))
            sb, sa = has(:Mu_secondary_below) ?
                (m(r.Mu_secondary_below), m(r.Mu_secondary_above)) :
                (fs * m(r.Mu_secondary), (1 - fs) * m(r.Mu_secondary))
            below = primary_is_x ? (pb, sb) : (sb, pb)
            above = primary_is_x ? (pa, sa) : (sa, pa)
            old = get(joint, cidx, (below = (0.0, 0.0), above = (0.0, 0.0)))
            joint[cidx] = (below = max.(old.below, below), above = max.(old.above, above))
        end
    end
    return joint
end

"""
Column options the flat-plate slab loop sized with (see
[`concrete_column_options`](@ref)).
"""
_flat_plate_column_opts(params::DesignParameters) = concrete_column_options(params)

"""Concrete of a flat-plate or flat-slab floor's options."""
_floor_concrete(o::StructuralSizer.FlatSlabOptions) = _floor_concrete(o.base)
_floor_concrete(o) = o.material.concrete

"""
Lowest slab f′c of the flat-plate floors that report each column, keyed by
the index of the column below the slab.
"""
function _joint_floor_fc(struc::BuildingStructure, params::DesignParameters)
    global_opts = resolve_floor_options(params)
    fc = Dict{Int, Any}()
    for (sidx, slab) in enumerate(struc.slabs)
        slab.floor_type in (:flat_plate, :flat_slab) || continue
        dd = slab.design_details
        (dd isa NamedTuple && hasproperty(dd, :column_results)) || continue
        isnothing(dd.column_results) && continue
        f = _floor_concrete(_floor_options_for_slab(struc, sidx, params, global_opts)).fc′
        for (cidx, _) in dd.column_results
            fc[cidx] = min(get(fc, cidx, f), f)
        end
    end
    return fc
end

"""
    flat_plate_joint_demands(struc, params, column_opts) -> Dict{Int, Vector{NamedTuple}}

Column ends that ACI 318-11 §10.12 (aci-318-11, p. 158) checks: the section
of a column where it passes through a flat-plate floor whose f′c is less
than the column's by more than a factor of 1.4. Keyed by column index, one
`(Pu, Mx, My, fc)` entry (kip, kip·ft, joint strength) per such end.

A floor joint counts only when a column continues above it, since §10.12
covers load carried through the floor. At that joint the column below is
checked under its top-end moments and the column above under its
bottom-end moments, from [`_flat_plate_joint_moments`](@ref). The moments
are the end moments themselves, not magnified: slenderness magnification
applies along the member, not at the joint section. `Pu` is the column's
largest end compression. The joint strength comes from
`StructuralSizer.joint_concrete_strength`: §10.12.3 for an interior column
(slab on all four sides), §10.12.2 otherwise.
"""
function flat_plate_joint_demands(struc::BuildingStructure, params::DesignParameters, column_opts)
    out = Dict{Int, Vector{NamedTuple}}()
    column_opts isa StructuralSizer.ConcreteColumnOptions || return out
    joint = _flat_plate_joint_moments(struc, column_opts)
    floor_fc = _joint_floor_fc(struc, params)
    for (i, m) in joint
        col = struc.columns[i]
        above = col.column_above
        above === nothing && continue
        haskey(floor_fc, i) || continue
        j = findfirst(c -> c === above, struc.columns)
        for (k, M) in ((i, m.below), (j, m.above))
            k === nothing && continue
            c = struc.columns[k]
            fc = StructuralSizer.joint_concrete_strength(
                _column_concrete(c, column_opts).fc′, floor_fc[i];
                restrained_four_sides = col.position == :interior)
            fc === nothing && continue
            Pu = ustrip(Asap.kip, _column_asap_Pu(struc, c) * u"N")
            push!(get!(out, k, NamedTuple[]), (Pu = Pu, Mx = M[1], My = M[2], fc = fc))
        end
    end
    return out
end

"""Checker for a §10.12 joint section: the column checker without slenderness."""
_joint_checker(opts) = StructuralSizer.ACIColumnChecker(;
    include_slenderness = false,
    include_biaxial = opts.include_biaxial,
    fy_ksi = ustrip(Asap.ksi, opts.rebar_material.Fy),
    Es_ksi = ustrip(Asap.ksi, opts.rebar_material.E),
    max_depth = opts.max_depth,
)

"""Both axis assignments of a joint demand, as for the member check."""
_joint_demand_orientations(e) =
    _rc_demand_orientations((Pu = e.Pu, M1x = -e.Mx, M2x = e.Mx, M1y = -e.My, M2y = e.My), 0.0)

"""Column concrete at a joint's strength."""
_joint_concrete(col, opts, e) =
    StructuralSizer.with_compressive_strength(_column_concrete(col, opts), e.fc)

"""Identity-stable joint concrete, keyed by the base material and joint strength.

`_joint_concrete` builds a fresh material every call, so its `objectid` is never
stable — which would defeat [`_memo_capacity_cache`](@ref) (keyed by material
identity) and force a fresh full-catalog precompute per joint entry per settle
round. Memoising on `(base material identity, f′c)` gives one stable object per
distinct joint material, so the joint capacity cache is built once and shared
across rounds, and the §10.12 joint check in [`flat_plate_column_checks`](@ref)
peek-hits the same cache ([`_column_capacity_slot`](@ref), speed.md #20)."""
const _JOINT_CONCRETE_MEMO = Dict{Tuple{UInt, Any}, Any}()

function _memo_joint_concrete(col, opts, e)
    key = (objectid(_column_concrete(col, opts)), e.fc)
    return lock(_COL_MEMO_LOCK) do
        get!(() -> _joint_concrete(col, opts, e), _JOINT_CONCRETE_MEMO, key)
    end
end

"""Identity-stable reinforced-concrete material for a column's capacity cache.

Wraps the column's concrete ([`_column_concrete`](@ref)) with `opts`'s rebar
grades so [`_memo_capacity_cache`](@ref) routes through the
`ReinforcedConcreteMaterial` overload of `precompute_capacities!`: the objective
coefficients then count the rebar (WP 2.5 — true embodied carbon under
`MinCarbon`, matching `ec.jl`), which drives the lowest-objective pick in
[`_grow_flat_plate_columns!`](@ref) / [`_stack_flat_plate_columns!`](@ref) and
the within-plan-size pick in [`_fit_flat_plate_columns!`](@ref).

The P-M **capacity is unchanged**: the material tuple fed to
`generate_PM_diagram` is identical to the plain-`Concrete` path (same f′c, and
fy/Es from the same `rebar_material` the checker is built from), so only
`obj_coeffs` move (proven by `scripts/runners/equiv_column_rc_capacity.jl`).

A fresh `ReinforcedConcreteMaterial` every call would have an unstable
`objectid` and defeat the material-identity memo, forcing a full-catalog
precompute per column per settle round; this memoises one stable object per
`(concrete, longitudinal rebar, transverse rebar)` triple."""
const _COL_RC_MATERIAL_MEMO = Dict{Tuple{UInt, UInt, UInt}, Any}()

function _column_cache_material(col, opts)
    concrete = _column_concrete(col, opts)
    rebar = opts.rebar_material
    transverse = something(opts.transverse_rebar_material, opts.rebar_material)
    key = (objectid(concrete), objectid(rebar), objectid(transverse))
    return lock(_COL_MEMO_LOCK) do
        get!(() -> StructuralSizer.ReinforcedConcreteMaterial(concrete, rebar, transverse),
             _COL_RC_MATERIAL_MEMO, key)
    end
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
- End moments (kip·ft) from [`_flat_plate_joint_moments`](@ref). The top
  end takes the below-the-slab part of the joint on top of this column. The
  bottom end takes the above-the-slab part of the joint on top of the
  column below.
- `M1`/`M2` follow the ACI 318-19 sign convention of
  `StructuralSizer.calc_Cm`. The two ends come from different load patterns,
  so the curvature is not known and single curvature (`M1 ≤ 0`) is assumed.
  That gives the larger `Cm` (ACI 318-19 Eq. 6.6.4.5.3a).

The returned moments use global X and Y span directions. A column with no
slab-reported joint at either end is omitted.
"""
function flat_plate_column_demands(struc::BuildingStructure, column_opts)
    joint = _flat_plate_joint_moments(struc, column_opts)
    isempty(joint) && return Dict{Int, NamedTuple}()
    below = _column_below_index(struc)

    out = Dict{Int, NamedTuple}()
    for (i, col) in enumerate(struc.columns)
        (isnothing(col.c1) || isnothing(col.c2)) && continue
        top = haskey(joint, i) ? joint[i].below : (0.0, 0.0)
        b = get(below, i, 0)
        bot = (b != 0 && haskey(joint, b)) ? joint[b].above : (0.0, 0.0)
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

"""Flat-plate slab that bears on `col`, or `nothing`."""
function _column_flat_plate(struc, col)
    for slab in struc.slabs
        slab.floor_type in (:flat_plate, :flat_slab) || continue
        any(i -> i in slab.cell_indices, col.tributary_cell_indices) && return slab
    end
    return nothing
end

"""Slab thickness the column k is computed at. The installed result, or the code minimum."""
function _column_slab_thickness(slab)
    result = slab.result
    if result !== nothing && hasproperty(result, :thickness)
        return result.thickness
    end
    ln = StructuralSizer.longer_axis_span(slab.spans)
    system = slab.floor_type == :flat_slab ? StructuralSizer.FlatSlab() :
             StructuralSizer.FlatPlate()
    return StructuralSizer.min_thickness(system, ln)
end

"""
Geometry the slab loop sizes flat-plate columns with.

ACI 318-11 §10.10.5 (corpus: aci-318-11, page 154) designates the story.
A nonsway story uses k = 1 (R10.10.6.3, page 156). A sway story uses the
alignment chart, Fig. R10.10.1.1 (page 150). A column with no flat-plate
slab keeps its own `braced` flag and k = 1.
"""
function _flat_plate_column_geometry(struc, col)
    slab = _column_flat_plate(struc, col)
    slab === nothing && return StructuralSizer.ConcreteMemberGeometry(
        col.base.L; Lu = col.base.L, kx = 1.0, ky = 1.0, braced = col.braced)
    return StructuralSizer.flat_plate_column_geometry(
        col, slab, struc; h = _column_slab_thickness(slab))
end

_column_concrete(col, opts) = something(col.concrete, opts.material)

"""
    _rc_section_check(checker, opts, section, material, demands, geometry)
        -> (passed, explanation)

`passed` is the sizer's own test, `is_feasible`, under every demand.
`explanation` is the `explain_feasibility` of the demand with the highest
governing ratio, for reporting.

When `section` is a catalog section and the sizing stage already built the
full-catalog capacity cache for this `checker`/`material`/`objective`, the check
indexes into that cache instead of building a single-section one
([`_column_capacity_slot`](@ref), speed.md #20) — exactly the same diagram, so
the result is identical.
"""
function _rc_section_check(checker, opts, section, material, demands, geometry)
    cache, j = _column_capacity_slot(checker, opts, section, material)
    passed = all(d -> StructuralSizer.is_feasible(checker, cache, j, section, material, d, geometry),
                 demands)
    worst = nothing
    for d in demands
        ex = StructuralSizer.explain_feasibility(checker, cache, j, section, material, d, geometry)
        (worst === nothing || ex.governing_ratio > worst.governing_ratio) && (worst = ex)
    end
    return (passed, worst)
end

"""
    _column_capacity_slot(checker, opts, section, material) -> (cache, index)

A capacity cache and the index at which it holds `section`'s P-M diagram. Reuses
the already-built full-catalog cache at the section's catalog index when one is
memoized (speed.md #20); otherwise falls back to a single-section cache at index
1. Both carry the identical diagram for `section`, so the feasibility result is
the same either way.
"""
function _column_capacity_slot(checker, opts, section, material)
    j = haskey(ENV, "SS_DISABLE_COL_CATALOG_SLOT") ? nothing :
        _catalog_section_index(opts, section)
    if j !== nothing
        cache = _peek_capacity_cache(checker, _memo_column_catalog(opts), material, opts.objective)
        cache === nothing || return (cache, j)
    end
    return (_memo_section_cache(checker, section, material, opts.objective), 1)
end

"""Geometry of a column checked under its frame forces: its own `Lb`, `Kx`, `Ky` and bracing."""
_frame_column_geometry(col) = StructuralSizer.ConcreteMemberGeometry(col.base.L;
    Lu = col.base.Lb, kx = col.base.Kx, ky = col.base.Ky, braced = col.braced)

"""
    frame_column_demand(env) -> NamedTuple

Column demand `(Pu, M1x, M2x, M1y, M2y)` (kip, kip·ft) from one entry of
[`column_force_envelopes`](@ref), with local y as x and local z as y. `M2`
is the larger of the end moment and the peak along the member, and `M1`
keeps the end moments' relative sign (ACI 318-19 convention).
"""
function frame_column_demand(env)
    kip(N) = ustrip(Asap.kip, N * u"N")
    kipft(Nm) = ustrip(Asap.kip * u"ft", Nm * u"N*m")
    return (Pu = kip(env.Pu),
            M1x = kipft(env.M1y), M2x = kipft(max(env.My, env.M2y)),
            M1y = kipft(env.M1z), M2y = kipft(max(env.Mz, env.M2z)))
end

"""
    flat_plate_column_checks(struc, column_opts; params=nothing) -> Dict{Int, NamedTuple}

Check every flat-plate column's installed section under
[`flat_plate_column_demands`](@ref). Each entry has `passed`,
`governing_check`, `governing_ratio`, `axial_ratio`, `demand`, `joint`,
`geometry` (the slenderness geometry it was checked with) and `source`.

With `params`, the column must also pass its ACI 318-11 §10.12 joint
sections ([`flat_plate_joint_demands`](@ref)), listed in `joint`. A joint
ratio above the member's makes `governing_check` `"floor_joint_10.12"`.

In a building with flat-plate floors, an RC column that no flat-plate slab
bears on (a wall-only or core column) has no slab joint to read. It is
checked under its frame envelope instead ([`column_force_envelopes`](@ref),
[`frame_column_demand`](@ref), its own effective lengths), `source = :frame`, so the
growth and stacking rounds size it too. Its frame moments come from the
placeholder beam lines and are an estimate. A column with tributary area
in a flat-plate slab that the slab did not report stays unchecked.
"""
function flat_plate_column_checks(struc::BuildingStructure, column_opts; params = nothing)
    column_opts isa StructuralSizer.ConcreteColumnOptions || return Dict{Int, NamedTuple}()
    demands = flat_plate_column_demands(struc, column_opts)
    joints = params === nothing ? Dict{Int, Vector{NamedTuple}}() :
        flat_plate_joint_demands(struc, params, column_opts)
    checker = _aci_column_checker(column_opts)
    jchecker = _joint_checker(column_opts)
    out = Dict{Int, NamedTuple}()
    for (i, d) in demands
        col = struc.columns[i]
        geom = _flat_plate_column_geometry(struc, col)
        r = _rc_column_check(checker, column_opts, col, d, geom)
        r === nothing && continue
        entries = get(joints, i, NamedTuple[])
        passed, check, ratio = r.passed, r.governing_check, r.governing_ratio
        for e in entries
            ok, ex = _rc_section_check(jchecker, column_opts, section(col),
                                       _memo_joint_concrete(col, column_opts, e),
                                       _joint_demand_orientations(e),
                                       _flat_plate_column_geometry(struc, col))
            passed &= ok
            if ex.governing_ratio > ratio
                check, ratio = "floor_joint_10.12", ex.governing_ratio
            end
        end
        out[i] = (passed = passed, governing_check = check, governing_ratio = ratio,
                  axial_ratio = r.axial_ratio, demand = d, joint = entries,
                  geometry = geom, source = :slab)
    end
    any(s -> s.floor_type in (:flat_plate, :flat_slab), struc.slabs) || return out
    supported = flat_plate_supported_columns(struc)
    todo = [i for i in eachindex(struc.columns) if !haskey(out, i) && !(i in supported)]
    isempty(todo) && return out
    envs = column_force_envelopes(struc, something(params, DesignParameters()))
    for i in todo
        haskey(envs, i) || continue
        col = struc.columns[i]
        d = frame_column_demand(envs[i])
        geom = _frame_column_geometry(col)
        r = _rc_column_check(checker, column_opts, col, d, geom)
        r === nothing && continue
        out[i] = (passed = r.passed, governing_check = r.governing_check,
                  governing_ratio = r.governing_ratio, axial_ratio = r.axial_ratio,
                  demand = d, joint = NamedTuple[], geometry = geom, source = :frame)
    end
    return out
end

"""
True when catalog section `j` passes every §10.12 joint entry of `col`.

The joint capacity diagrams are the run-level full-catalog cache
([`_memo_capacity_cache`](@ref)) under the joint checker and each joint's
material, built once and shared across settle rounds and with the §10.12 check
in [`flat_plate_column_checks`](@ref). The joint material is identity-stable
([`_memo_joint_concrete`](@ref)) so that sharing actually hits.
"""
function _joint_feasible(jchecker, catalog, j, sec, col, opts, entries, geom)
    for e in entries
        mat = _memo_joint_concrete(col, opts, e)
        cache = _memo_capacity_cache(jchecker, catalog, mat, opts.objective)
        all(d -> StructuralSizer.is_feasible(jchecker, cache, j, sec, mat, d, geom),
            _joint_demand_orientations(e)) || return false
    end
    return true
end

"""
    _rc_column_check(checker, opts, col, demand, geometry) -> NamedTuple or nothing

`(passed, governing_check, governing_ratio, axial_ratio, demand)` for `col`'s
installed RC section under both orientations of `demand`, or `nothing` when
the section is not RC.
"""
function _rc_column_check(checker, opts, col, d, geometry)
    sec = section(col)
    (sec isa StructuralSizer.RCColumnSection || sec isa StructuralSizer.RCCircularSection) ||
        return nothing
    passed, ex = _rc_section_check(checker, opts, sec, _column_cache_material(col, opts),
                                   _rc_demand_orientations(d, opts.βdns), geometry)
    k = findfirst(c -> c.name == "axial_cap", ex.checks)
    return (passed = passed, governing_check = ex.governing_check,
            governing_ratio = ex.governing_ratio,
            axial_ratio = k === nothing ? NaN : ex.checks[k].ratio,
            demand = d)
end

"""
    rc_frame_column_check(col, opts, demand) -> NamedTuple or nothing

ACI P-M check of an RC column the flat-plate full-load check does not cover,
under its frame demand `(Pu, M1x, M2x, M1y, M2y)` (kip, kip·ft; see
[`frame_column_demand`](@ref)), in both axis assignments. The geometry is
the column's own `Lb`, `Kx`, `Ky` and `braced`.
"""
rc_frame_column_check(col, opts, d) =
    _rc_column_check(_aci_column_checker(opts), opts, col, d, _frame_column_geometry(col))

"""Indices of columns with tributary area in a flat-plate or flat-slab slab."""
function flat_plate_supported_columns(struc::BuildingStructure)
    cells = Set{Int}()
    for s in struc.slabs
        s.floor_type in (:flat_plate, :flat_slab) && union!(cells, s.cell_indices)
    end
    return Set(i for (i, col) in enumerate(struc.columns)
               if !isdisjoint(col.tributary_cell_indices, cells))
end

"""Column catalog the sizer would search for `opts`."""
_column_catalog(opts) = isnothing(opts.custom_catalog) ?
    StructuralSizer.rc_column_catalog(opts.section_shape, opts.catalog) :
    opts.custom_catalog

"""True when `sec` is at least `col`'s size in both plan directions, as `b → c1`, `h → c2`."""
_section_covers_column(sec, col) = _section_covers(sec, col.shape, col.c1, col.c2)

"""True when `sec` has `shape` and is at least `c1 × c2`, as `b → c1`, `h → c2`."""
function _section_covers(sec, shape, c1, c2)
    tol = 0.05u"inch"
    if sec isa StructuralSizer.RCCircularSection
        return shape == :circular && sec.D >= c1 - tol
    elseif sec isa StructuralSizer.RCColumnSection
        return shape != :circular && sec.b >= c1 - tol && sec.h >= c2 - tol
    end
    return false
end

"""
    _stack_flat_plate_columns!(struc, params, column_opts, checks) -> (grown, stuck)

Grow each RC column that is smaller than the RC column directly above it, in
either plan direction, to the lightest catalog section that covers both
(`max` of each dimension), stays within the flat-plate column cap and passes
the column's full-load demand in `checks`. Columns are visited from the top
story down so one pass carries a growth down the stack. Two cases are skipped
with a warning: a column whose above neighbour has a different shape or
rotation (plan dimensions do not compare axis by axis), and a column with no
demand in `checks` (a replacement section could not be checked). `stuck`
lists the columns left smaller than the one above: those without a demand
and those with no catalog section that fits.

Design policy (not a code requirement): a lower column is never smaller than
the one it supports.
"""
function _stack_flat_plate_columns!(struc, params, column_opts, checks)
    checker = _aci_column_checker(column_opts)
    jchecker = _joint_checker(column_opts)
    catalog = _memo_column_catalog(column_opts)
    cap = _flat_plate_column_cap(params)
    is_rc(c) = section(c) isa StructuralSizer.RCColumnSection ||
               section(c) isa StructuralSizer.RCCircularSection
    tol = 0.05u"inch"
    grown, stuck = Int[], Int[]
    for i in sortperm([c.story for c in struc.columns]; rev = true)
        col = struc.columns[i]
        above = col.column_above
        (above === nothing || !is_rc(col) || !is_rc(above)) && continue
        (isnothing(col.c1) || isnothing(above.c1)) && continue
        if !(above.shape == col.shape && isapprox(above.θ, col.θ; atol = 1e-6))
            @warn "Column above has a different shape or rotation; stack not compared" column = i _id = (:stack_shape, i) maxlog = 1
            continue
        end
        c1, c2 = max(col.c1, above.c1), max(col.c2, above.c2)
        (c1 > col.c1 + tol || c2 > col.c2 + tol) || continue
        if !haskey(checks, i)
            @warn "Column has no full-load demand, so a larger section could not be checked; stack left non-monotone" column = i
            push!(stuck, i)
            continue
        end

        mat = _column_cache_material(col, column_opts)
        cache = _memo_capacity_cache(checker, catalog, mat, column_opts.objective)
        demands = _rc_demand_orientations(checks[i].demand, column_opts.βdns)
        geom = checks[i].geometry
        order = sortperm(cache.obj_coeffs)
        pick = findfirst(order) do j
            sec = catalog[j]
            _section_covers(sec, col.shape, c1, c2) && _section_within_cap(sec, cap) &&
                all(d -> StructuralSizer.is_feasible(checker, cache, j, sec, mat, d, geom), demands) &&
                _joint_feasible(jchecker, catalog, j, sec, col, column_opts, checks[i].joint, geom)
        end
        if pick === nothing
            @warn "No catalog section covers the column above within the flat-plate cap; stack left non-monotone" column = i
            push!(stuck, i)
            continue
        end
        sec = catalog[order[pick]]
        bb = StructuralSizer.bounding_box(sec)
        col.c1 = bb.width
        col.c2 = bb.depth
        set_section!(col, sec)
        _set_rc_column_volumes!(col,
            something(col.concrete, column_concrete(params)),
            column_rebar(params))
        _install_column_frame_section!(struc, col, _rc_column_frame_section(col, params))
        push!(grown, i)
    end
    return (grown, stuck)
end

"""
    _non_monotone_columns(struc) -> Vector{Int}

RC columns smaller in either plan direction than the RC column directly
above, with the same shape and rotation (the comparison
[`_stack_flat_plate_columns!`](@ref) makes).
"""
function _non_monotone_columns(struc::BuildingStructure)
    is_rc(c) = section(c) isa StructuralSizer.RCColumnSection ||
               section(c) isa StructuralSizer.RCCircularSection
    tol = 0.05u"inch"
    out = Int[]
    for (i, col) in enumerate(struc.columns)
        above = col.column_above
        (above === nothing || !is_rc(col) || !is_rc(above)) && continue
        (isnothing(col.c1) || isnothing(above.c1)) && continue
        (above.shape == col.shape && isapprox(above.θ, col.θ; atol = 1e-6)) || continue
        (above.c1 > col.c1 + tol || above.c2 > col.c2 + tol) && push!(out, i)
    end
    return out
end

"""
    _mismatched_stack_columns(struc) -> Vector{Int}

RC columns whose RC column above has a different shape or rotation, so
[`_stack_flat_plate_columns!`](@ref) could not compare their plan sizes.
"""
function _mismatched_stack_columns(struc::BuildingStructure)
    is_rc(c) = section(c) isa StructuralSizer.RCColumnSection ||
               section(c) isa StructuralSizer.RCCircularSection
    out = Int[]
    for (i, col) in enumerate(struc.columns)
        above = col.column_above
        (above === nothing || !is_rc(col) || !is_rc(above)) && continue
        (above.shape == col.shape && isapprox(above.θ, col.θ; atol = 1e-6)) || push!(out, i)
    end
    return out
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
    jchecker = _joint_checker(column_opts)
    catalog = _memo_column_catalog(column_opts)
    cap = _flat_plate_column_cap(params)
    grown, unresolved = Int[], Int[]
    for i in sort(failing)
        col = struc.columns[i]
        mat = _column_cache_material(col, column_opts)
        cache = _memo_capacity_cache(checker, catalog, mat, column_opts.objective)
        demands = _rc_demand_orientations(checks[i].demand, column_opts.βdns)
        geom = checks[i].geometry
        order = sortperm(cache.obj_coeffs)
        pick = findfirst(order) do j
            sec = catalog[j]
            _section_covers_column(sec, col) && _section_within_cap(sec, cap) &&
                all(d -> StructuralSizer.is_feasible(checker, cache, j, sec, mat, d, geom), demands) &&
                _joint_feasible(jchecker, catalog, j, sec, col, column_opts, checks[i].joint, geom)
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
            something(col.concrete, column_concrete(params)),
            column_rebar(params))
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
Plan sizes of the catalog, lightest objective first within a size, sizes
lightest first. Sections above the flat-plate column cap are left out.
"""
function _catalog_plan_groups(catalog, obj, cap)
    buckets = Dict{Tuple{Float64, Float64}, Vector{Int}}()
    for (j, sec) in enumerate(catalog)
        _section_within_cap(sec, cap) || continue
        bb = StructuralSizer.bounding_box(sec)
        key = (round(ustrip(u"inch", bb.width); digits = 3),
               round(ustrip(u"inch", bb.depth); digits = 3))
        push!(get!(() -> Int[], buckets, key), j)
    end
    groups = Vector{Int}[]
    for idxs in values(buckets)
        sort!(idxs, by = j -> obj[j])
        push!(groups, idxs)
    end
    sort!(groups, by = idxs -> begin
        bb = StructuralSizer.bounding_box(catalog[idxs[1]])
        (ustrip(u"m^2", bb.width * bb.depth), obj[idxs[1]])
    end)
    return groups
end

"True when `sec`'s plan is at least `floor` in both directions."
function _plan_covers_floor(sec, floor)
    floor === nothing && return true
    bb = StructuralSizer.bounding_box(sec)
    tol = 0.05u"inch"
    return bb.width >= floor[1] - tol && bb.depth >= floor[2] - tol
end

"""
Punching demands of `col` from each flat-plate slab that was analyzed with it.

The shear and the unbalanced moments are that analysis' `column_shears` and
`unbalanced_moments`, in the order of [`find_supporting_columns`](@ref).
Empty when no stored analysis lines up with the column, so the section
search must not shrink it.
"""
@noinline function _column_punching_demands(struc, col)
    @nospecialize struc col
    out = NamedTuple[]
    for (sidx, slab) in enumerate(struc.slabs)
        slab.floor_type in (:flat_plate, :flat_slab) || continue
        dd = slab.design_details
        (dd isa NamedTuple && hasproperty(dd, :moment_results)) || continue
        mr = dd.moment_results
        (mr !== nothing && hasproperty(mr, :column_shears) &&
            hasproperty(mr, :unbalanced_moments)) || continue
        cols = StructuralSizer.find_supporting_columns(struc, Set(slab.cell_indices))
        length(cols) == length(mr.column_shears) == length(mr.unbalanced_moments) || continue
        i = findfirst(c -> c === col, cols)
        i === nothing && continue
        sr = hasproperty(dd, :secondary_results) ? dd.secondary_results : nothing
        Muy = sr !== nothing && hasproperty(sr, :unbalanced_moments) &&
              length(sr.unbalanced_moments) == length(cols) ? sr.unbalanced_moments[i] : nothing
        push!(out, (slab_idx = sidx, slab = slab, details = dd,
                    Vu = mr.column_shears[i], Mub = mr.unbalanced_moments[i], Muy = Muy,
                    qu = hasproperty(mr, :qu) ? mr.qu : nothing))
    end
    return out
end

"""
True when punching passes at `col`'s current plan size under `demands`.

`nothing` when `demands` is empty. The check is the one the slab loop ran:
[`check_punching_for_column`](@ref), or [`check_punching`](@ref) at a drop
panel, with the same span axis, openings, and §13.5.3.3 switch.
"""
@noinline function _punching_passes(struc, params, col, demands)
    @nospecialize struc params col demands
    isempty(demands) && return nothing
    global_opts = resolve_floor_options(params)
    for dem in demands
        opts = _floor_options_for_slab(struc, dem.slab_idx, params, global_opts)
        fp = opts isa StructuralSizer.FlatSlabOptions ? opts.base : opts
        fp isa StructuralSizer.FlatPlateOptions || return nothing
        h = dem.details.h_final
        cover = fp.cover
        db = StructuralSizer.bar_diameter(fp.bar_size)
        d = StructuralSizer.effective_depth(h; cover = cover, bar_diameter = db)
        fc = fp.material.concrete.fc′
        λ = isnothing(fp.λ) ? fp.material.concrete.λ : fp.λ
        transfer = fp.moment_transfer_increase &&
                   (!hasproperty(dem.details, :drop_panel) || dem.details.drop_panel === nothing) ?
                   (fy = fp.material.rebar.Fy, bar_diameter = db, cover = cover) : nothing
        kw = StructuralSizer.punching_axis_kwargs(struc, dem.slab, col)
        drop = hasproperty(dem.details, :drop_panel) ? dem.details.drop_panel : nothing
        res = if drop === nothing
            StructuralSizer.check_punching_for_column(
                col, dem.Vu, dem.Mub, d, h, fc;
                verbose = false, λ = λ, φ_shear = fp.φ_shear, Muy = dem.Muy,
                moment_transfer = transfer, kw...)
        else
            h_total = StructuralSizer.total_depth_at_drop(h, drop)
            d_total = StructuralSizer.effective_depth(h_total; cover = cover, bar_diameter = db)
            StructuralSizer.check_punching(
                col, dem.Vu, dem.Mub, h, d, h_total, d_total, fc, drop;
                qu = dem.qu, verbose = false, λ = λ, φ_shear = fp.φ_shear, Muy = dem.Muy,
                kw...)
        end
        res.ok || return false
    end
    return true
end

"Punching at plan size `(c1, c2)`, restoring the column's size afterward."
@noinline function _punching_passes_at(struc, params, col, c1, c2, demands)
    @nospecialize struc params col c1 c2 demands
    old1, old2 = col.c1, col.c2
    col.c1 = c1
    col.c2 = c2
    try
        return _punching_passes(struc, params, col, demands)
    finally
        col.c1 = old1
        col.c2 = old2
    end
end

"True when `sec` is the section already on `col`."
function _installed_section(col, sec)
    bb = StructuralSizer.bounding_box(sec)
    tol = 0.05u"inch"
    (col.c1 !== nothing && abs(col.c1 - bb.width) <= tol &&
        col.c2 !== nothing && abs(col.c2 - bb.depth) <= tol) || return false
    cur = section(col)
    cur === nothing && return false
    n1 = hasproperty(cur, :name) ? cur.name : nothing
    n2 = hasproperty(sec, :name) ? sec.name : nothing
    return n1 isa AbstractString && n2 isa AbstractString && n1 == n2
end

"""
True when some section in `group` passes both full-load orientations and the
§10.12 joint sections.

`group` is ordered lightest first. The heaviest section is tried first: under
the stored demand a heavier layout is the stronger one, so its failure rejects
the plan size without trying the lighter layouts.
"""
@noinline function _group_has_strength(group, catalog, checker, cache, mat, orient, geom,
                             jchecker, col, column_opts, joint)
    @nospecialize group catalog checker cache mat orient geom jchecker col column_opts joint
    for j in Iterators.reverse(group)
        s = catalog[j]
        all(d -> StructuralSizer.is_feasible(checker, cache, j, s, mat, d, geom), orient) || continue
        _joint_feasible(jchecker, catalog, j, s, col, column_opts, joint, geom) || continue
        return true
    end
    return false
end

"""
Index, within `group`, of the lightest section that passes strength and the joint.
"""
@noinline function _lightest_in_group(group, catalog, checker, cache, mat, orient, geom,
                            jchecker, col, column_opts, joint)
    @nospecialize group catalog checker cache mat orient geom jchecker col column_opts joint
    for j in group
        s = catalog[j]
        all(d -> StructuralSizer.is_feasible(checker, cache, j, s, mat, d, geom), orient) || continue
        _joint_feasible(jchecker, catalog, j, s, col, column_opts, joint, geom) || continue
        return j
    end
    return nothing
end

"""
True when this plan-size group covers `floor`, passes punching, and has a
section that passes strength and the joint.

Punching is cached by plan size in `punch`. `nothing` means the analysis did
not report a demand, and that does not reject the group.
"""
@noinline function _plan_group_passes(group, catalog, floor, punch, struc, params, col, demands,
                            checker, cache, mat, orient, geom,
                            jchecker, column_opts, joint)
    @nospecialize group catalog floor punch struc params col demands checker cache mat orient geom jchecker column_opts joint
    sec = catalog[group[1]]
    _plan_covers_floor(sec, floor) || return false
    bb = StructuralSizer.bounding_box(sec)
    key = (round(ustrip(u"inch", bb.width); digits = 3),
           round(ustrip(u"inch", bb.depth); digits = 3))
    pok = get!(punch, key) do
        _punching_passes_at(struc, params, col, bb.width, bb.depth, demands)
    end
    pok === false && return false
    return _group_has_strength(group, catalog, checker, cache, mat, orient, geom,
                               jchecker, col, column_opts, joint)
end

"""
Index into `groups` of the lightest plan size that passes.

Binary search finds the lightest size at which a larger section still passes.
The stored demand does not grow as the section shrinks, so a size that fails
is treated as the end of the search: every smaller size would fail it too.
Returns `nothing` when no group passes.
"""
@noinline function _lightest_passing_group(groups, catalog, floor, punch, struc, params, col, demands,
                                 checker, cache, mat, orient, geom,
                                 jchecker, column_opts, joint)
    @nospecialize groups catalog floor punch struc params col demands checker cache mat orient geom jchecker column_opts joint
    lo, hi = 1, length(groups) + 1
    while lo < hi
        mid = (lo + hi) ÷ 2
        if _plan_group_passes(groups[mid], catalog, floor, punch, struc, params, col, demands,
                              checker, cache, mat, orient, geom,
                              jchecker, column_opts, joint)
            hi = mid
        else
            lo = mid + 1
        end
    end
    lo > length(groups) && return nothing
    # One step below the hit can pass when the binary probe landed on a size
    # that was only just large enough. Stop at the first failure.
    for j in (lo - 1):-1:1
        _plan_group_passes(groups[j], catalog, floor, punch, struc, params, col, demands,
                           checker, cache, mat, orient, geom,
                           jchecker, column_opts, joint) || break
        lo = j
    end
    return lo
end

"""
    _fit_flat_plate_columns!(struc, params, column_opts, checks; floors) -> (changed, unresolved)

Install, on every checked column, the lightest catalog section that passes
the column's full-load strength, its §10.12 joint sections, and punching at
that plan size.

Punching is [`check_punching_for_column`](@ref) at the trial plan size, using
the shear and unbalanced moments of the slab analysis already stored. That
analysis was run at the installed size. Its moment is kept for the trial: a
smaller column takes less of the unbalanced moment, so the stored moment is
the heavier demand. A column with no stored punching analysis is not made
smaller. `floors` holds a plan size the slab commit or an earlier section
search grew the column to; the search does not go under it.

`changed` lists columns whose section was replaced. `unresolved` lists
columns no section within the cap passes; they keep their section.
"""
@noinline function _fit_flat_plate_columns!(struc, params, column_opts, checks; floors = Dict{Int, Tuple}())
    @nospecialize struc params column_opts checks floors
    isempty(checks) && return (Int[], Int[])
    checker = _aci_column_checker(column_opts)
    jchecker = _joint_checker(column_opts)
    catalog = _memo_column_catalog(column_opts)
    cap = _flat_plate_column_cap(params)
    changed, unresolved = Int[], Int[]
    shrink = params.uniform_column_sizing === :off
    for i in sort!(collect(keys(checks)))
        col = struc.columns[i]
        sec0 = section(col)
        (sec0 isa StructuralSizer.RCColumnSection ||
            sec0 isa StructuralSizer.RCCircularSection) || continue
        demands = _column_punching_demands(struc, col)
        known = !isempty(demands)
        floor = get(floors, i, nothing)
        if !shrink || !known
            f1 = floor === nothing ? col.c1 : max(floor[1], col.c1)
            f2 = floor === nothing ? col.c2 : max(floor[2], col.c2)
            floor = (f1, f2)
        end
        mat = _column_cache_material(col, column_opts)
        cache = _memo_capacity_cache(checker, catalog, mat, column_opts.objective)
        groups = _memo_plan_groups(catalog, cache, cap)
        orient = _rc_demand_orientations(checks[i].demand, column_opts.βdns)
        geom = checks[i].geometry
        joint = checks[i].joint
        punch = Dict{Tuple{Float64, Float64}, Union{Bool, Nothing}}()
        lo = _lightest_passing_group(
            groups, catalog, floor, punch, struc, params, col, demands,
            checker, cache, mat, orient, geom, jchecker, column_opts, joint)
        lo === nothing && (push!(unresolved, i); continue)
        pick = _lightest_in_group(
            groups[lo], catalog, checker, cache, mat, orient, geom,
            jchecker, col, column_opts, joint)
        pick === nothing && (push!(unresolved, i); continue)
        sec = catalog[pick]
        _installed_section(col, sec) && continue
        bb = StructuralSizer.bounding_box(sec)
        col.c1 = bb.width
        col.c2 = bb.depth
        set_section!(col, sec)
        _set_rc_column_volumes!(col,
            something(col.concrete, column_concrete(params)),
            column_rebar(params))
        _install_column_frame_section!(struc, col, _rc_column_frame_section(col, params))
        push!(changed, i)
    end
    return (changed, unresolved)
end

"""
    check_flat_plate_columns!(struc, params; tc=nothing, floors) -> NamedTuple

Give every flat-plate column the lightest catalog section that passes its
full-load strength, its §10.12 joints, and punching
([`_fit_flat_plate_columns!`](@ref)). Re-solve after each round, because a
different section changes the column's self-weight and the §13.6.9.2
stiffness split. Stop when a round changes nothing.

`floors` is a plan size, keyed by column index, that a later slab analysis
had to grow the column back to. The search does not go under it. A column
is not required to be at least as large as the column above it.

Returns `(grown, unresolved, nonmonotone, rounds, converged)`. `grown` lists
columns whose section changed. `unresolved` lists columns no catalog section
within the cap passes; they keep their section. `nonmonotone` lists columns
left smaller in either plan direction than the column above. A loop that
runs out of rounds records `struc.stage_diagnostics[:flat_plate_columns]`.
"""
function check_flat_plate_columns!(struc::BuildingStructure, params::DesignParameters;
                                   tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
                                   floors::Dict{Int, Tuple} = Dict{Int, Tuple}())
    column_opts = _flat_plate_column_opts(params)
    StructuralSizer.emit!(tc, :workflow, "check_flat_plate_columns!", "", :enter;
                          n_columns = length(struc.columns))
    grown_all = Set{Int}()
    unresolved = Int[]
    budget = StructuralSizer.monotone_budget(
        params.max_iterations, length(_memo_column_catalog(column_opts)))
    run = StructuralSizer.settle!(; budget) do _
        checks = flat_plate_column_checks(struc, column_opts; params)
        changed, open = _fit_flat_plate_columns!(
            struc, params, column_opts, checks; floors)
        empty!(unresolved)
        append!(unresolved, open)
        isempty(changed) && return false
        union!(grown_all, changed)
        update_structural_offsets!(struc; input_is_centerline = params.geometry_is_centerline)
        _resolve_after_column_change!(struc)
        return true
    end
    nonmonotone = _non_monotone_columns(struc)
    isempty(unresolved) || @warn "Flat-plate columns fail the full-load check and no catalog section within the column cap passes" columns = unresolved
    if run.converged
        delete!(struc.stage_diagnostics, :flat_plate_columns)
    else
        @warn "Flat-plate column section search did not settle" rounds = run.steps
        struc.stage_diagnostics[:flat_plate_columns] =
            "Flat-plate column section search had not settled after $(run.steps) rounds; " *
            "the column checks may not match the final frame."
    end
    StructuralSizer.emit!(tc, :workflow, "check_flat_plate_columns!", "", :decision;
                          n_grown = length(grown_all), n_unresolved = length(unresolved),
                          n_nonmonotone = length(nonmonotone),
                          rounds = run.steps, stop = string(run.stop))
    StructuralSizer.emit!(tc, :workflow, "check_flat_plate_columns!", "", :exit;
                          n_grown = length(grown_all))
    return (grown = sort!(collect(grown_all)), unresolved = unresolved,
            nonmonotone = sort(nonmonotone), rounds = run.steps, converged = run.converged)
end
