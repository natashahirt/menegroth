# ==============================================================================
# FIRST PROVING SLICE — global-F0 continuous relaxation warm-starting the member
# MIP on a coupled, STRENGTH-governed mid-rise frame
# (docs/sizing-map/optimization-architecture.md, Pillar A)
# ==============================================================================
#
# The existing `relaxation_warmstart_benchmark.jl` proves the warm-start/band/
# lower-bound claims on a DEFLECTION-governed member MIP, where the strong-axis
# second moment of area `I` is the single governing property. That is rigorous
# but one-dimensional: it exercises neither the beam-column interaction nor the
# gravity COUPLING that makes a real frame iterate.
#
# This runner closes the plan's designated FIRST PROVING SLICE on the coupled,
# strength-governed case and reports its three acceptance metrics:
#
#   (i)   sizes identical-or-lighter — the warm-started design equals (or is
#         lighter than) the cold design at the converged fixpoint;
#   (ii)  beam-column pass-count collapse — the number of coupled member-MIP
#         resize passes to reach the self-weight fixpoint collapses when the loop
#         is seeded by the continuous relaxation instead of starting from zero
#         self-weight;
#   (iii) optimality gap — the converged discrete volume against the certified
#         separable lower bound (JuMP-free), per `separable_lower_bound`.
#
# THE COUPLING (why the frame iterates). Columns are beam-columns carrying a
# gravity axial force that ACCUMULATES the self-weight of every member above
# them, plus a constant frame moment that keeps the AISC Chapter H interaction
# live. Sizing a column up raises its self-weight, which raises the axial demand
# on every column below it, which may size THOSE up — a monotone staleness
# ratchet. The demand is therefore a function of the sizes, and the member sizer
# must be re-run until the assignment stops changing (the demand fixpoint).
#
# THE EXPENSIVE MODEL. The member sizer is the section-count-capped MIP
# (`optimize_discrete` with `n_max_sections = N_MAX`), a GENUINE coupled problem:
# the whole frame may use at most `N_MAX` distinct sections (a fabrication-economy
# constraint), so the groups no longer separate and a branch-and-bound solve is
# required. This is the "true expensive model" in the fidelity ladder.
#
# COLD vs WARM — the pass-count collapse.
#   • COLD pays the expensive capped MIP on EVERY pass of the demand fixpoint,
#     ratcheting up from zero self-weight.
#   • WARM first settles the demand graph with the cheap global-F0 relaxation —
#     `optimize_binary_search`, which RELAXES the `n_max` coupling (the groups
#     separate, so each is an independent lightest-feasible scan, no solver). Only
#     once the demands have stopped moving does it invoke the expensive capped MIP,
#     warm-started from the settled seed. The expensive solve then runs a handful
#     of times near the optimum instead of across the whole ratchet.
# This is exactly the architecture doc's Pillar-C policy ("run F0/global to
# convergence first to settle the coupling graph cheaply; invoke the true
# expensive model only near the optimum, warm-started") proven on the real solver.
#
# SAFETY (O1). The F0 relaxation only GUIDES: every size the runner reports comes
# from the capped `optimize_discrete`, whose internal capacity screening certifies
# each section against the full AISC checks at the current demand. The F0 pass
# seeds the demand and the MIP incumbent (`mip_start`, a pure hint); it never
# writes a final size. `test/optimize/test_section_relaxation.jl` enforces this
# contract as a unit test.
#
# Run: julia --project=StructuralSizer scripts/runners/relaxation_frame_proving_slice.jl

using StructuralSizer
using Unitful
import JuMP
const MOI = JuMP.MOI

# ─── Frame definition ─────────────────────────────────────────────────────────
# Long-span, lightly-loaded floors: a long steel girder's own weight is a large
# fraction of its flexural demand (`M = (w_super + w_sw)·L²/8`), so sizing a beam
# up meaningfully raises its self-weight — and the accumulated beam + column
# self-weight the columns carry. That self-weight feedback is what makes the cold
# demand fixpoint ratchet over many passes.
const N_STORIES   = 30                 # stories (column groups = beam groups = 30)
const H_STORY     = 4.0                 # m, story height (column unbraced length)
const L_BAY       = 18.0                # m, long-span girder (self-weight-heavy)
const W_FLOOR     = 140.0e3             # N, superimposed gravity axial per column per floor (D+L tributary)
const M_COL_FRAME = 90.0e3             # N·m, constant strong-axis frame moment on each column (keeps H1 live)
const W_BEAM_LINE = 26.0e3             # N/m, superimposed gravity line load on each girder
const N_MAX       = 12                  # fabrication cap: ≤ N_MAX distinct sections frame-wide (the coupling)
const MAX_PASSES  = 60                  # safety cap on the coupled fixpoint

# A992 density in SI (for the self-weight coupling).
const RHO    = ustrip(u"kg/m^3",  A992_Steel.ρ)       # density
const GRAV   = 9.80665                                 # m/s²

# Catalog + SI property tables (catalog order), shared by every solve.
const CATALOG = steel_column_catalog(:w, :all)
const A_CAT   = [ustrip(u"m^2", section_area(s)) for s in CATALOG]
const N_CAT   = length(CATALOG)

const CHECKER = AISCChecker()   # strength-governed: flexure + Chapter H interaction

# Geometry: one column group and one beam group per story (2·N_STORIES groups).
# Groups 1..N_STORIES are columns (level 1 = roof, N_STORIES = ground); groups
# N_STORIES+1..2N_STORIES are the beams at the matching level.
const COL_GEOMS  = [SteelMemberGeometry(H_STORY; Lb = H_STORY) for _ in 1:N_STORIES]
const BEAM_GEOMS = [SteelMemberGeometry(L_BAY;  Lb = L_BAY)    for _ in 1:N_STORIES]
const GEOMETRIES = vcat(COL_GEOMS, BEAM_GEOMS)

col_group(s)  = s                      # story s → column group index
beam_group(s) = N_STORIES + s          # story s → beam group index

"""
    member_self_weight(sec_idx, length_m) -> Float64

Self-weight force (N) of catalog section `sec_idx` over `length_m`: `A·L·ρ·g`.
"""
member_self_weight(sec_idx::Int, length_m::Real) = A_CAT[sec_idx] * length_m * RHO * GRAV

# ─── Demand assembly: sizes → coupled demands ─────────────────────────────────
"""
    build_demands(col_idx, beam_idx) -> Vector{MemberDemand}

Assemble the full demand vector for the current section assignment. Beams are
sized by the superimposed flexure alone (a fixed, x-INDEPENDENT demand — their
own self-weight is carried to the columns but its second-order effect on the
beam's own flexure is neglected, a standard simplification that keeps the ONLY
design-dependent coupling the column axial). Each column carries a constant frame
moment plus the gravity axial ACCUMULATED from the roof down to its story: the
superimposed floor load at every level at or above it, PLUS the self-weight of
every column and beam above. `col_idx`/`beam_idx` are catalog indices per story
(`0` ⇒ not yet sized, treated as zero self-weight — the cold seed).

This is exactly the load model the monolithic `LinearCapacityCoupling` encodes,
so the one-shot coupled MILP and the iterated fixpoint converge to the same point.
"""
function build_demands(col_idx::Vector{Int}, beam_idx::Vector{Int})
    demands = Vector{MemberDemand}(undef, 2 * N_STORIES)

    # Beams: superimposed flexure only (fixed demand); self-weight still loads cols.
    beam_sw_force = zeros(N_STORIES)
    for s in 1:N_STORIES
        demands[beam_group(s)] = MemberDemand(beam_group(s);
            Mux = W_BEAM_LINE * L_BAY^2 / 8, transverse_load = true)
        beam_sw_force[s] = beam_idx[s] == 0 ? 0.0 :
                           member_self_weight(beam_idx[s], L_BAY)          # total beam weight (N)
    end

    # Columns: accumulate gravity from the roof down.
    axial_above = 0.0
    for s in 1:N_STORIES               # s = 1 is the roof, increasing downward
        col_sw = col_idx[s] == 0 ? 0.0 : member_self_weight(col_idx[s], H_STORY)
        axial_above += W_FLOOR + beam_sw_force[s] + col_sw
        demands[col_group(s)] = MemberDemand(col_group(s);
            Pu_c = axial_above,
            Mux  = M_COL_FRAME)
    end
    return demands
end

# ─── Member sizers: the cheap F0 relaxation and the expensive capped MIP ──────
split_assignment(a) = (a[1:N_STORIES], a[N_STORIES+1:end])

"""
    size_f0(col_idx, beam_idx) -> Vector{Int}

Cheap global-F0 relaxation: `optimize_binary_search` sizes each group to its
lightest feasible section INDEPENDENTLY (the `n_max` fabrication coupling is
relaxed away), with no branch-and-bound. Used only to settle the self-weight
demand graph before the expensive capped MIP is invoked.
"""
function size_f0(col_idx::Vector{Int}, beam_idx::Vector{Int})
    demands = build_demands(col_idx, beam_idx)
    res = optimize_binary_search(CHECKER, demands, GEOMETRIES, CATALOG, A992_Steel;
                                 objective = MinVolume())
    res.status == :OPTIMAL || error("F0 binary search failed: $(res.status)")
    return res.section_indices
end

"""
    size_mip(col_idx, beam_idx; seed) -> (assignment, volume)

The expensive model: the section-count-capped MIP (`n_max_sections = N_MAX`),
checker-certified, optionally warm-started from `seed` (a pure hint). This is the
coupled solve whose invocations we are trying to collapse.
"""
function size_mip(col_idx::Vector{Int}, beam_idx::Vector{Int};
                  seed::Union{Nothing,Vector{Int}} = nothing)
    demands = build_demands(col_idx, beam_idx)
    res = optimize_discrete(CHECKER, demands, GEOMETRIES, CATALOG, A992_Steel;
                            objective = MinVolume(), n_max_sections = N_MAX,
                            mip_start = seed, time_limit_sec = 120.0)
    res.status == MOI.OPTIMAL ||
        error("capped MIP did not reach OPTIMAL: $(res.status)")
    return res.section_indices, res.objective_value
end

"""
    demand_fixpoint(sizer, col0, beam0) -> (col_idx, beam_idx, passes)

Iterate `sizer(col, beam) -> assignment` to the self-weight demand fixpoint from
`(col0, beam0)` (catalog indices; `0` ⇒ zero-self-weight seed). Convergence is
`output == input`: the sizes that generated the current demands survive the
re-solve. Returns the converged assignment and the number of sizer invocations.
"""
function demand_fixpoint(sizer, col0::Vector{Int}, beam0::Vector{Int})
    col_idx, beam_idx = copy(col0), copy(beam0)
    passes = 0
    for _ in 1:MAX_PASSES
        assignment = sizer(col_idx, beam_idx)
        passes += 1
        new_col, new_beam = split_assignment(assignment)
        (new_col == col_idx && new_beam == beam_idx) && break   # fixpoint reached
        col_idx, beam_idx = new_col, new_beam
    end
    return col_idx, beam_idx, passes
end

# ─── Warm up (precompile both solver paths at this problem size) ──────────────
println("Warming up the member sizers (precompile, full size)…")
let z = fill(0, N_STORIES)
    size_f0(z, z)
    size_mip(z, z)
end

# ─── COLD: pay the expensive capped MIP on every pass of the ratchet ──────────
z = fill(0, N_STORIES)
cold_col, cold_beam, cold_mip_solves =
    demand_fixpoint((c, b) -> size_mip(c, b)[1], z, z)
_, cold_vol = size_mip(cold_col, cold_beam; seed = vcat(cold_col, cold_beam))

# ─── WARM: settle the demand graph with cheap F0, THEN the expensive MIP ──────
f0_col, f0_beam, f0_passes = demand_fixpoint(size_f0, z, z)   # cheap, not counted
warm_mip_solves = 0
warm_col, warm_beam = f0_col, f0_beam
local warm_vol
for _ in 1:MAX_PASSES
    assignment, vol = size_mip(warm_col, warm_beam; seed = vcat(warm_col, warm_beam))
    global warm_mip_solves += 1
    global warm_vol = vol
    nc, nb = split_assignment(assignment)
    (nc == warm_col && nb == warm_beam) && break
    global warm_col, warm_beam = nc, nb
end

# ─── MONOLITHIC: fold the linear self-weight coupling into ONE certified MIP ──
# The column axial is a LINEAR function of the section choices (each section adds a
# constant `A·L·ρg`), and under the fixed frame moment every section has a
# precomputable maximum axial capacity `P_cap(s)` (the AISC H1 interaction, monotone
# in axial, inverted once). So the coupled sizing is a single MILP — no ratchet.

"""
    build_axial_capacity_table() -> Vector{Float64}

`P_cap(s)` for every catalog section: the maximum axial force section `s` can carry
as a column (unbraced length `H_STORY`) under the fixed frame moment `M_COL_FRAME`,
found by bisecting the SAME `is_feasible` predicate the MIP screening uses (so the
table is exactly consistent with the checker). Sections that fail the moment alone
get `0.0` and are never selectable. One table serves every column group (identical
geometry and moment).
"""
function build_axial_capacity_table()
    cache = create_cache(CHECKER, N_CAT)
    precompute_capacities!(CHECKER, cache, CATALOG, A992_Steel, MinVolume())
    geom = COL_GEOMS[1]
    feas(t, P) = is_feasible(CHECKER, cache, t, CATALOG[t], A992_Steel,
                             MemberDemand(1; Pu_c = P, Mux = M_COL_FRAME), geom)
    P_cap = zeros(N_CAT)
    for t in 1:N_CAT
        feas(t, 0.0) || continue                       # fails moment alone ⇒ cap 0
        lo, hi = 0.0, 1.0e5                             # N; bracket the capacity
        while feas(t, hi) && hi < 1.0e12
            lo, hi = hi, 2hi
        end
        for _ in 1:40                                  # bisect to the feasibility edge
            mid = 0.5 * (lo + hi)
            feas(t, mid) ? (lo = mid) : (hi = mid)
        end
        P_cap[t] = lo
    end
    return P_cap
end

"""
    build_coupling(P_cap) -> LinearCapacityCoupling

Encode the frame's self-weight accumulation as a linear capacity coupling: for
column group `s`, the carried axial is `base[s] + Σ(self-weight of every column and
beam at or above s)`, and the chosen section must have `P_cap ≥` that load.
"""
function build_coupling(P_cap::Vector{Float64})
    col_w  = [A_CAT[t] * H_STORY * RHO * GRAV for t in 1:N_CAT]   # column self-weight force
    beam_w = [A_CAT[t] * L_BAY  * RHO * GRAV for t in 1:N_CAT]    # beam self-weight force
    weight = Vector{Vector{Float64}}(undef, 2 * N_STORIES)
    for s in 1:N_STORIES
        weight[col_group(s)]  = col_w
        weight[beam_group(s)] = beam_w
    end
    groups  = collect(1:N_STORIES)
    sources = [vcat(collect(1:s), [beam_group(k) for k in 1:s]) for s in 1:N_STORIES]
    base    = [s * W_FLOOR for s in 1:N_STORIES]                   # Σ_{k≤s} superimposed
    cap     = [P_cap for _ in 1:N_STORIES]                         # identical per column group
    return LinearCapacityCoupling(groups, sources, base, weight, cap)
end

"""
    stripped_demands() -> Vector{MemberDemand}

The x-INDEPENDENT demand the monolithic solve screens against: beams at their fixed
superimposed flexure, columns at the superimposed (self-weight-free) axial. The
load-dependent axial is added by the `LinearCapacityCoupling`, not the demand.
"""
function stripped_demands()
    d = Vector{MemberDemand}(undef, 2 * N_STORIES)
    for s in 1:N_STORIES
        d[beam_group(s)] = MemberDemand(beam_group(s);
            Mux = W_BEAM_LINE * L_BAY^2 / 8, transverse_load = true)
        d[col_group(s)]  = MemberDemand(col_group(s);
            Pu_c = s * W_FLOOR, Mux = M_COL_FRAME)
    end
    return d
end

"""
    certify_self_consistent(col_idx, beam_idx) -> Bool

Close the loop: rebuild the FULL coupled demands from an assignment and re-check
every chosen section with the real checker. The monolithic optimum must pass (its
coupling constraint guarantees it), proving the one-shot solve wrote no size that
is unsafe at its own self-consistent self-weight.
"""
function certify_self_consistent(col_idx::Vector{Int}, beam_idx::Vector{Int})
    d = build_demands(col_idx, beam_idx)
    cache = create_cache(CHECKER, N_CAT)
    precompute_capacities!(CHECKER, cache, CATALOG, A992_Steel, MinVolume())
    for g in 1:(2 * N_STORIES)
        idx = g ≤ N_STORIES ? col_idx[g] : beam_idx[g - N_STORIES]
        is_feasible(CHECKER, cache, idx, CATALOG[idx], A992_Steel, d[g], GEOMETRIES[g]) ||
            return false
    end
    return true
end

const P_CAP    = build_axial_capacity_table()
const COUPLING = build_coupling(P_CAP)
mono_res = optimize_discrete(CHECKER, stripped_demands(), GEOMETRIES, CATALOG, A992_Steel;
                             objective = MinVolume(), n_max_sections = N_MAX,
                             coupling = COUPLING, time_limit_sec = 120.0)
mono_res.status == MOI.OPTIMAL ||
    error("monolithic coupled MIP did not reach OPTIMAL: $(mono_res.status)")
mono_col, mono_beam = split_assignment(mono_res.section_indices)
mono_vol    = mono_res.objective_value
mono_solves = 1
mono_consistent = certify_self_consistent(mono_col, mono_beam)

# ─── Certified optimality gap (separable F0 bound vs the capped MIP volume) ───
conv_demands = build_demands(warm_col, warm_beam)
lb = separable_lower_bound(CHECKER, conv_demands, GEOMETRIES, CATALOG, A992_Steel;
                           objective = MinVolume())
gap = optimality_gap(warm_vol, lb)
mono_gap = optimality_gap(mono_vol,
    separable_lower_bound(CHECKER, build_demands(mono_col, mono_beam),
                          GEOMETRIES, CATALOG, A992_Steel; objective = MinVolume()))

# ─── Report ───────────────────────────────────────────────────────────────────
identical      = (warm_col == cold_col) && (warm_beam == cold_beam)
lighter        = warm_vol ≤ cold_vol * (1 + 1e-9)
collapse       = warm_mip_solves < cold_mip_solves
# The monolithic solve should reproduce the iterated fixpoint's assignment exactly
# (same coupled optimum), in ONE certified solve, and be lighter-or-equal.
mono_identical = (mono_col == warm_col) && (mono_beam == warm_beam)
mono_lighter   = mono_vol ≤ warm_vol * (1 + 1e-9)
mono_collapse  = mono_solves < warm_mip_solves

println("\n" * "="^74)
println("Coupled frame proving slice  ($(N_STORIES) stories, $(2*N_STORIES) groups, " *
        "$(N_CAT)-section W catalog, ≤$(N_MAX) distinct sections)")
println("="^74)
println("COLD  — expensive capped MIP on every ratchet pass")
println("  expensive MIP solves : $cold_mip_solves")
println("  converged volume     : $(round(cold_vol, sigdigits = 6)) m³")
println("WARM  — cheap F0 settles the demand graph ($f0_passes binary-search passes), then the MIP")
println("  expensive MIP solves : $warm_mip_solves")
println("  converged volume     : $(round(warm_vol, sigdigits = 6)) m³")
println("MONO  — self-weight folded into ONE certified coupled MIP (no ratchet)")
println("  expensive MIP solves : $mono_solves")
println("  converged volume     : $(round(mono_vol, sigdigits = 6)) m³")
println("  self-consistent      : $(mono_consistent ? "CERTIFIED ✓ (re-checked at its own self-weight)" : "FAILED ✗")")
println("-"^74)
println("(i)   sizes identical-or-lighter : $(identical ? "IDENTICAL ✓" : (lighter ? "LIGHTER ✓" : "HEAVIER ✗"))")
println("(ii)  expensive-MIP pass-count   : cold $cold_mip_solves → warm $warm_mip_solves → mono $mono_solves  ($(collapse ? "COLLAPSE ✓" : "no collapse ✗"))")
println("(iii) certified optimality gap   : warm $(round(gap * 100, digits = 3)) %  (LB $(round(lb, sigdigits = 6)) m³, JuMP-free separable bound)")
println("-"^74)
println("MONOLITHIC vs iterated fixpoint")
println("  (a) same coupled optimum         : $(mono_identical ? "IDENTICAL ✓" : (mono_lighter ? "LIGHTER ✓" : "HEAVIER ✗"))")
println("  (b) one-shot vs ratchet solves   : warm $warm_mip_solves → mono $mono_solves  ($(mono_collapse ? "SINGLE SOLVE ✓" : "no collapse ✗"))")
println("  (c) certified optimality gap     : mono $(round(mono_gap * 100, digits = 3)) %")
println("="^74)

all_ok = (identical || lighter) && collapse && gap ≥ -1e-9 &&
         (mono_identical || mono_lighter) && mono_collapse &&
         mono_consistent && mono_gap ≥ -1e-9
println(all_ok ? "ALL CLAIMS HOLD ✓" : "SOME CLAIMS FAILED ✗ — inspect above")
all_ok || error("coupled frame proving slice failed its acceptance claims")
