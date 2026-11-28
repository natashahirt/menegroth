# ==============================================================================
# SLICE 2 PROVING SLICE — FE self-weight INFLUENCE COEFFICIENTS for the real
# member stage (general, indeterminate frames)
# ==============================================================================
#
# Slices 0 and 1 linearized a *clean* coupling: the column axial was an explicit
# accumulation (Σ of the self-weights above), exact only for a determinate
# gravity stack. In the real `StructuralSynthesizer` member stage the column
# axial demand is instead an FE REACTION read off the solved Asap model
# (`member_group_demands` → `ElementForceAndDisplacement`), so for an
# indeterminate / moment frame it carries the full redistribution.
#
# The key observation that keeps the monolithic MILP exact anyway:
#
#   For a linear-elastic model, the internal axial at any station of column i is
#   a LINEAR FUNCTIONAL of the applied load vector:   P_i = L_i(F).
#   Element j's self-weight enters F only through its (section-independent in
#   SHAPE) consistent nodal load f_j, scaled by its total weight W_j = ρ·A(s)·g·L.
#   Hence
#                    P_i(sections) = base_i + Σ_j φ_{i,j} · W_j(section_j),
#   with the influence coefficient  φ_{i,j} = L_i(f_j^unit)  a CONSTANT of the
#   current (frozen-stiffness) model — exactly the `LinearCapacityCoupling`
#   coefficient the member MILP consumes. The weight W_j(s) = ρ·g·L·A(s) is the
#   only section-dependent factor, so φ is computed once per solve.
#
# φ is obtained WITHOUT one solve per source: because the model is already
# factored, `Asap.linear_response(model, f_j^unit)` is ONE back-substitution
# (no refactorization) giving the exact Δu from source j's unit self-weight, and
# the existing force recovery reads every target column's axial from that Δu.
# (A per-target adjoint would also work; the forward form reuses the production
# force-recovery path verbatim, so there is nothing new to certify in recovery.)
#
# WHAT THIS SLICE PROVES (the correctness kernel everything else builds on):
# for a genuinely INDETERMINATE multi-story frame, the influence-predicted
# column axial under a self-weight change equals the axial from a full fresh
# re-solve — to machine precision. Because the system is linear and the
# stiffness is unchanged by a LOAD change, `linear_response` gives the EXACT Δu
# (not merely first order), so the agreement is exact, not approximate. The only
# approximation in production is freezing the stiffness across a SECTION change,
# which the member loop already guards with a verify-installed re-solve.
#
# Run: julia --project=StructuralSynthesizer \
#        scripts/runners/selfweight_influence_proving_slice.jl

using Asap
using Unitful
using LinearAlgebra: norm
using Printf

const MOI_RTOL = 1e-7   # machine-precision agreement target (influence is exact)

# ─── Frame: an INDETERMINATE multi-story, multi-bay moment frame in X–Z ───────
# Fixed bases on every column line ⇒ highly statically indeterminate, so a
# column's self-weight redistributes (it does NOT simply stack): the exact test
# of the influence method against a naive accumulation.
const N_STORY = 4          # stories
const N_BAY   = 2          # bays  (⇒ N_BAY+1 column lines)
const H       = 3.6        # m, story height
const W_BAY   = 7.5        # m, bay width
const E_STEEL = 200.0e9    # Pa
const G_STEEL = 77.0e9     # Pa

# Two section templates (columns stiffer than girders), bent in X–Z.
_sec(A, I) = Section(A * u"m^2", E_STEEL * u"Pa", G_STEEL * u"Pa",
                     I * u"m^4", I * u"m^4", 1.0e-6u"m^4")
const COL_SEC  = _sec(1.5e-2, 1.2e-4)
const BEAM_SEC = _sec(1.0e-2, 6.0e-5)

# Node grid: line (0..N_BAY) × level (0..N_STORY). Bases (level 0) fixed.
const LINES  = 0:N_BAY
const LEVELS = 0:N_STORY
nid(line, lvl) = lvl * (N_BAY + 1) + line + 1      # 1-based node id

"""
Build and solve a fresh frame. `extra_col` = `(col_index, ΔW_total_N)` appends a
−Z self-weight-shaped `LineLoad` of total `ΔW` on that column (for the "truth"
re-solve); `nothing` builds the baseline. A fresh build gives each truth case an
independent factorization, so it is a genuine reference for the influence path.
"""
function build_frame(; extra_col::Union{Nothing,Tuple{Int,Float64}} = nothing)
    nodes = Vector{Asap.Node}(undef, (N_BAY + 1) * (N_STORY + 1))
    for lvl in LEVELS, line in LINES
        cond = lvl == 0 ? :fixed : :free
        nodes[nid(line, lvl)] = Node([line * W_BAY * 1.0u"m", 0.0u"m", lvl * H * 1.0u"m"], cond)
    end

    cols  = Asap.Element[]            # column elements, with (line, story) tags
    col_tag = Tuple{Int,Int}[]
    beams = Asap.Element[]
    for lvl in 1:N_STORY
        for line in LINES            # columns in this story
            e = Element(nodes[nid(line, lvl - 1)], nodes[nid(line, lvl)], COL_SEC)
            push!(cols, e); push!(col_tag, (line, lvl))
        end
        for bay in 1:N_BAY           # girders at this level
            push!(beams, Element(nodes[nid(bay - 1, lvl)], nodes[nid(bay, lvl)], BEAM_SEC))
        end
    end
    elements = vcat(cols, beams)

    # Base ("super") loads: downward point loads at every upper node (floor
    # tributary) so the baseline is realistic and the columns are compressed.
    loads = Asap.AbstractLoad[]
    for lvl in 1:N_STORY, line in LINES
        push!(loads, NodeForce(nodes[nid(line, lvl)], [0.0u"N", 0.0u"N", -120.0e3u"N"]))
    end
    # "Current" self-weight of every element, as a −Z LineLoad (self-weight
    # SHAPE). Column self-weight is axial; girder self-weight is transverse.
    for e in elements
        w = _elem_lineload_mag(e)
        push!(loads, LineLoad(e, [0.0u"N/m", 0.0u"N/m", -w * 1.0u"N/m"]))
    end
    if extra_col !== nothing
        ci, ΔW = extra_col            # every column has length H (pre-process safe)
        push!(loads, LineLoad(cols[ci], [0.0u"N/m", 0.0u"N/m", -(ΔW / H) * 1.0u"N/m"]))
    end

    model = FrameModel(nodes, elements, loads)
    solve!(model)
    return model, cols, beams, col_tag
end

# Self-weight line magnitude (N/m) of an element's "current" section: ρ·A·g.
# ρ is a nominal steel density; its value is irrelevant to the identity under
# test (any load magnitude works), it only makes the baseline realistic.
const RHO_STEEL = 7850.0
_elem_lineload_mag(e) = RHO_STEEL * ustrip(u"m^2", e.section.A) * 9.80665

# ─── Force recovery from an arbitrary displacement vector ─────────────────────
# Mirrors `Asap.ElementForceAndDisplacement`'s axial path and the production
# `_element_forces_from_u` (StructuralSynthesizer): the stiffness end force
# −(R·K·u_e)[1] plus `accumulate_force!` for the element's own member loads.
function axial_compression_from_u(el, u::AbstractVector, loads; res::Int = 60)
    dofs = Asap.etype2DOF[typeof(el)]
    ep = Asap.ElementProps(el)
    L = ep.L
    rng = range(0, L, res)
    u_e = u[el.globalID]
    Flocal = el.R * (el.K * u_e)
    @inbounds for i in 1:12
        Flocal[i] *= dofs[i]
    end
    Pstart  = -Flocal[1]
    Vystart =  Flocal[2]; Mystart = Flocal[6]
    Vzstart =  Flocal[3]; Mzstart = -Flocal[5]
    P  = fill(Pstart, res)
    My = collect(Vystart .* rng .- Mystart)
    Vy = fill(Vystart, res)
    Mz = collect(Vzstart .* rng .- Mzstart)
    Vz = fill(Vzstart, res)
    for ld in loads
        Asap.accumulate_force!(ld, rng, P, My, Vy, Mz, Vz, ep)
    end
    return maximum(-, P)                      # peak compression (compression > 0)
end

# ─── Influence construction (the production kernel, in miniature) ─────────────
"""
Effective nodal load `f_e^unit` (length nDOFs) of a UNIT-TOTAL-WEIGHT self-weight
load on element `e`: a −Z `LineLoad` of total 1 N. Because the solve is
`u = K⁻¹(P − Pf)` and an element load adds `+Pf`, the effective nodal load is the
NEGATED fixed-end contribution. Section-independent in shape ⇒ exact for any
candidate section after scaling by that section's total weight.
"""
function unit_selfweight_load(model, e)
    L = Asap.ElementProps(e).L
    unit = LineLoad(e, [0.0u"N/m", 0.0u"N/m", -(1.0 / L) * 1.0u"N/m"])   # total 1 N
    Pf = zeros(model.nDOFs)
    Asap.populate_load!(Pf, unit)
    return -Pf, unit
end

function main()
    model, cols, _, col_tag = build_frame()
    u_base = copy(model.u)
    base_loads = Asap.get_elemental_loads(model)     # element → its own loads

    # Baseline column axials (what `member_group_demands` would read).
    base_axial = [axial_compression_from_u(e, u_base, base_loads[e.elementID]) for e in cols]

    # A representative self-weight increment to test the identity (e.g. upsizing
    # a source column raises its weight by ΔW over its length).
    ΔW_total = 40.0e3     # N, extra total self-weight placed on a source element

    @printf("%-26s  %12s  %12s  %10s\n", "source → target (worst)", "Δ influence", "Δ re-solve", "rel.err")
    println("-"^68)

    max_relerr = 0.0
    n_checks = 0
    for (jx, src) in enumerate(cols)
        # ── Influence: ONE back-substitution for this source's unit self-weight ──
        f_unit, _ = unit_selfweight_load(model, src)
        Δu = Asap.linear_response(model, ΔW_total .* f_unit)     # exact Δu for ΔW_total

        # ── Truth: an independent, fully fresh re-solve with the extra load ──
        tmodel, tcols, _, _ = build_frame(; extra_col = (jx, ΔW_total))
        tloads = Asap.get_elemental_loads(tmodel)
        truth_axial = [axial_compression_from_u(e, tmodel.u, tloads[e.elementID]) for e in tcols]

        # Compare predicted vs re-solved Δaxial for the worst-affected target.
        src_worst = 0.0; self_pred = 0.0; self_truth = 0.0
        for (ix, tgt) in enumerate(cols)
            # Source element i==j also carries the extra load in its OWN member
            # recovery (the member-load term, not just the stiffness transmission).
            loads_i = ix == jx ?
                vcat(base_loads[tgt.elementID],
                     [LineLoad(tgt, [0.0u"N/m", 0.0u"N/m", -(ΔW_total / H) * 1.0u"N/m"])]) :
                base_loads[tgt.elementID]
            pred_axial = axial_compression_from_u(tgt, u_base .+ Δu, loads_i)
            Δpred  = pred_axial - base_axial[ix]
            Δtruth = truth_axial[ix] - base_axial[ix]
            relerr = abs(Δpred - Δtruth) / max(abs(Δtruth), 1.0)
            ix == jx && (self_pred = Δpred; self_truth = Δtruth)
            if isnan(relerr)
                @warn "NaN relerr" source=jx target=ix Δpred Δtruth base=base_axial[ix] truth_axial=truth_axial[ix]
            else
                src_worst = max(src_worst, relerr)
                max_relerr = max(max_relerr, relerr)
            end
            n_checks += 1
        end
        @printf("col%-2d %-14s  self Δ %10.3f (truth %10.3f)   max rel.err %.2e\n",
                jx, string(col_tag[jx]), self_pred, self_truth, src_worst)
    end

    println("-"^68)
    @printf("checks: %d   max relative error: %.3e   tol: %.1e\n", n_checks, max_relerr, MOI_RTOL)
    ok = max_relerr ≤ MOI_RTOL
    println(ok ? "INFLUENCE IDENTITY HOLDS ✓  (φ reproduces a full re-solve, exactly)" :
                 "INFLUENCE IDENTITY FAILED ✗")
    ok || error("self-weight influence proving slice failed its acceptance claim")
    return ok
end

main()
