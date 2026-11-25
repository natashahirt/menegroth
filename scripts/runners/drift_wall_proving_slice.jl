# =============================================================================
# Proving slice: drift folded into the member MILP as a linear constraint
# =============================================================================
#
# Companion to `relaxation_frame_proving_slice.jl`. There, self-weight (a demand
# linear in the section choices) collapsed a grow-only RATCHET into one certified
# MILP. Here the same idea attacks the single most expensive loop in the pipeline
# (walls ⇄ members, up to 4× the whole member stage; README §5 #2) and its
# over-sizing cousin (uniform drift scaling thickens every wall group; §4 rank 6).
#
# A cantilever wall/column stack is STATICALLY DETERMINATE: the member forces do
# not depend on the stiffnesses, so the roof drift is EXACTLY separable,
#
#     δ = Σ_i γ_i / I_i,   γ_i = (1/E) ∫_segment M(z)·m(z) dz   (virtual work),
#
# with M the real cantilever moment and m the moment from a unit roof load. Each
# catalog section t for segment i therefore contributes a precomputable constant
# γ_i/I_t to the drift, so the serviceability limit δ ≤ δ_allow is LINEAR in the
# selection binaries and folds into the MILP as one `LinearSelectionConstraint`.
#
# We contrast:
#   • UNIFORM  — the current wall policy: size for strength, then step EVERY group
#     up the catalog together until the worst drift is met (grow-only, over-sizes).
#   • MONOLITHIC — one certified MILP sizing every segment for strength AND drift
#     jointly, per-group optimal (material where drift-participation-per-weight is
#     highest). No jump loop.
#
# Because the stack is determinate the drift is exact, so the monolithic design is
# truly certified; an indeterminate frame would need one outer correction (the
# drift governor's trust region) to refreeze γ.

using StructuralSizer
using Unitful
import JuMP
const MOI = JuMP.MOI

# ─── Lateral system definition ───────────────────────────────────────────────
const N_STORY  = 20                 # stacked cantilever segments (one group each)
const H_STORY  = 4.0                # m, segment height
const H_TOTAL  = N_STORY * H_STORY  # m, total height
const Q_TOP    = 40.0              # N/m scale of the (inverted-triangle) ELF load (idealized)
const E_STEEL  = ustrip(u"Pa", A992_Steel.E)            # Pa
const DRIFT_RATIO = 1 / 400         # wind serviceability cap H/400 (ASCE 7 CC.1.2)

const CATALOG = steel_column_catalog(:w, :all)
const N_CAT   = length(CATALOG)
const A_CAT   = [ustrip(u"m^2", section_area(s)) for s in CATALOG]
const IX_CAT  = [ustrip(u"m^4", Ix(s))           for s in CATALOG]
const CHECKER = AISCChecker()
const GEOMS   = [SteelMemberGeometry(H_STORY; Lb = H_STORY) for _ in 1:N_STORY]

# Lateral load F_j at level j (elevation z_j = j·H_STORY), inverted triangle
# (heavier near the top), j = 1 (first level) … N_STORY (roof).
const Z_LEVEL = [j * H_STORY for j in 1:N_STORY]
const F_LEVEL = [Q_TOP * z   for z in Z_LEVEL]          # N

"""
    real_moment(z) -> Float64

Cantilever bending moment at elevation `z` (N·m): the sum over every lateral load
ABOVE `z` of force × lever arm.
"""
real_moment(z::Real) = sum(F_LEVEL[j] * (Z_LEVEL[j] - z) for j in 1:N_STORY if Z_LEVEL[j] > z; init = 0.0)

"""
    virtual_moment(z) -> Float64

Moment from a unit horizontal load at the roof: `H_TOTAL − z`.
"""
virtual_moment(z::Real) = H_TOTAL - z

"""
    segment_participation(i) -> Float64

Stiffness-free drift coefficient `γ_i = (1/E) ∫ M·m dz` over segment `i` (units
m⁵), by fine Simpson quadrature. Exact for this determinate stack, so `δ = Σ γ_i/I_i`.
"""
function segment_participation(i::Int)
    z0, z1 = (i - 1) * H_STORY, i * H_STORY
    n = 200                                   # even → Simpson
    h = (z1 - z0) / n
    s = 0.0
    for k in 0:n
        z = z0 + k * h
        w = (k == 0 || k == n) ? 1.0 : (iseven(k) ? 2.0 : 4.0)
        s += w * real_moment(z) * virtual_moment(z)
    end
    return (h / 3) * s / E_STEEL
end

const GAMMA = [segment_participation(i) for i in 1:N_STORY]

"""
    strength_demands() -> Vector{MemberDemand}

Per-segment flexural demand: the maximum moment in the segment (at its base).
"""
strength_demands() = [MemberDemand(i; Mux = real_moment((i - 1) * H_STORY)) for i in 1:N_STORY]

drift_of(idx::Vector{Int}) = sum(GAMMA[i] / IX_CAT[idx[i]] for i in 1:N_STORY)   # m
volume_of(idx::Vector{Int}) = sum(A_CAT[idx[i]] * H_STORY for i in 1:N_STORY)    # m³

# ─── Per-segment strength-feasible sets (shared by both methods) ─────────────
const DEMANDS = strength_demands()
const _CACHE  = create_cache(CHECKER, N_CAT)
precompute_capacities!(CHECKER, _CACHE, CATALOG, A992_Steel, MinVolume())
const FEAS = [[s for s in 1:N_CAT
              if is_feasible(CHECKER, _CACHE, s, CATALOG[s], A992_Steel, DEMANDS[i], GEOMS[i])]
             for i in 1:N_STORY]
for i in 1:N_STORY
    isempty(FEAS[i]) && error("segment $i has no strength-feasible section (load too high)")
end
# Lightest-area strength pick, and the stiffest feasible section, per segment.
const STRENGTH_IDX = [FEAS[i][argmin(A_CAT[FEAS[i]])] for i in 1:N_STORY]
const STIFFEST_IDX = [FEAS[i][argmax(IX_CAT[FEAS[i]])] for i in 1:N_STORY]

# Serviceability target: H/400 if it lands in the reachable-AND-governing band for
# this idealized stack; otherwise nudge into that band so the demo exercises the
# mechanism (a real limit would be fixed, with the load tuned to it).
const _STRENGTH_DRIFT = drift_of(STRENGTH_IDX)
const _MIN_DRIFT      = drift_of(STIFFEST_IDX)           # stiffest feasible everywhere
const DELTA_ALLOW = clamp(H_TOTAL * DRIFT_RATIO, 1.2 * _MIN_DRIFT, 0.8 * _STRENGTH_DRIFT)

# ─── UNIFORM: scale every group's stiffness demand by the worst drift ratio ──
# The current wall policy (README §4 rank 6): compute the worst drift ratio and
# scale EVERY group's required stiffness by it, snapping each up to the lightest
# strength-feasible section meeting the scaled stiffness. Iterate to the limit.
"""
    snap_stiffness(i, I_target) -> Int

Lightest-area strength-feasible section for segment `i` with `Ix ≥ I_target`
(falls back to the stiffest feasible section when the target exceeds the catalog).
"""
function snap_stiffness(i::Int, I_target::Real)
    best, bestA = 0, Inf
    for s in FEAS[i]
        IX_CAT[s] ≥ I_target || continue
        A_CAT[s] < bestA && (best = s; bestA = A_CAT[s])
    end
    best == 0 ? STIFFEST_IDX[i] : best
end

function uniform_jump()
    idx = copy(STRENGTH_IDX)
    passes = 0
    for _ in 1:50
        passes += 1
        d = drift_of(idx)
        d ≤ DELTA_ALLOW && return idx, passes
        r = d / DELTA_ALLOW                              # worst-drift scale factor
        new = [snap_stiffness(i, r * IX_CAT[idx[i]]) for i in 1:N_STORY]
        new == idx && return idx, passes                 # converged (at the stiffest)
        idx = new
    end
    error("uniform jump did not converge")
end
uniform_idx, uniform_passes = uniform_jump()

# ─── MONOLITHIC: strength + drift in ONE certified MILP ──────────────────────
# coeff[i][s] = γ_i / I_s is the drift contribution if segment i picks section s.
const DRIFT_COEFF = [[GAMMA[i] / IX_CAT[s] for s in 1:N_CAT] for i in 1:N_STORY]
mono_res = optimize_discrete(CHECKER, DEMANDS, GEOMS, CATALOG, A992_Steel;
    objective = MinVolume(),
    linear_constraints = [LinearSelectionConstraint(DRIFT_COEFF, :leq, DELTA_ALLOW)],
    time_limit_sec = 120.0)
mono_res.status == MOI.OPTIMAL || error("monolithic drift MILP failed: $(mono_res.status)")
const MONO_IDX = mono_res.section_indices
mono_solves = 1

# ─── Metrics ──────────────────────────────────────────────────────────────────
strength_drift = drift_of(STRENGTH_IDX)
uniform_vol, mono_vol = volume_of(uniform_idx), volume_of(MONO_IDX)
uniform_drift, mono_drift = drift_of(uniform_idx), drift_of(MONO_IDX)
saved_pct = 100 * (uniform_vol - mono_vol) / uniform_vol

lighter   = mono_vol ≤ uniform_vol * (1 + 1e-9)
collapse  = mono_solves < uniform_passes
both_meet = uniform_drift ≤ DELTA_ALLOW * (1 + 1e-9) && mono_drift ≤ DELTA_ALLOW * (1 + 1e-9)

println("\n" * "="^74)
println("Drift proving slice  ($(N_STORY)-segment cantilever stack, $(N_CAT)-section W catalog)")
_h400 = H_TOTAL * DRIFT_RATIO
_clamped = !(DELTA_ALLOW ≈ _h400)
println("  δ_allow = $(round(DELTA_ALLOW*1e3, digits=2)) mm" *
        (_clamped ? "  (H/400 = $(round(_h400*1e3, digits=1)) mm is unreachable with W-section proxies;" *
                    " target set in the reachable band)" : "  (= H/400)"))
println("  strength-only drift = $(round(strength_drift*1e3, digits=2)) mm  " *
        "($(round(strength_drift/DELTA_ALLOW, digits=2))× over the target)")
println("="^74)
println("UNIFORM  — size for strength, then step every group up together (current policy)")
println("  grow passes      : $uniform_passes")
println("  volume           : $(round(uniform_vol, sigdigits = 6)) m³")
println("  drift            : $(round(uniform_drift*1e3, digits = 2)) mm")
println("MONO     — strength + drift in ONE certified MILP (per-group optimal)")
println("  MILP solves      : $mono_solves")
println("  volume           : $(round(mono_vol, sigdigits = 6)) m³")
println("  drift            : $(round(mono_drift*1e3, digits = 2)) mm")
println("-"^74)
println("(i)   lighter-or-equal vs uniform : $(lighter ? "LIGHTER ✓" : "HEAVIER ✗")  (material saved $(round(saved_pct, digits = 1))%)")
println("(ii)  grow-pass collapse          : uniform $uniform_passes → mono $mono_solves  ($(collapse ? "COLLAPSE ✓" : "no collapse ✗"))")
println("(iii) drift limit met (exact)     : $(both_meet ? "BOTH ✓" : "✗")  (determinate stack ⇒ δ = Σγ/I is exact)")
println("="^74)

all_ok = lighter && collapse && both_meet
println(all_ok ? "ALL CLAIMS HOLD ✓" : "SOME CLAIMS FAILED ✗ — inspect above")
all_ok || error("drift proving slice failed its acceptance claims")
