# ==============================================================================
# Dual-system steel frame-member strength check — AISC 360-16 Appendix 8
# ==============================================================================
#
# Increment (2) of the dual-system stage (decision deci-93f9b5ce). The moment
# frame of a dual system shares the lateral load with the core, so its columns
# and girders must be checked as beam-columns under the combined-system seismic
# demands with second-order (P-Δ / P-δ) amplification.
#
# APPROACH B — amplified first-order (AISC 360-16 Appendix 8):
#   * `_build_first_order` solves every unfactored component (D, L, roof, each
#     wind case, each seismic effect) first-order on the *full* frame+core model.
#   * For each ASCE 7-22 §2.3.1 seismic strength combo and each seismic effect,
#     the member's station forces are split into a no-translation part
#     (nt = factored gravity + the vertical seismic effect Ev) and a
#     lateral-translation part (lt = factored ρ·Eh), exactly the Mnt/Mlt split
#     Appendix 8 requires.
#   * The steel `AISCChecker` then forms the required strengths
#     `Mr = B1·Mnt + B2·Mlt` (Eq. A-8-1) and `Pr = Pnt + B2·Plt` (Eq. A-8-2)
#     through the shared `_aisc_amplified_forces` core: `B1` (Eq. A-8-3) is the
#     member P-δ amplifier, `B2` (Eq. A-8-6) the story P-Δ amplifier from
#     `story_stability_records`.
# (corpus: aisc-360-16, pages 305–306; asce-7-22 §2.3.1 page 68, §12.4 page 183.)
#
# SCOPE (this increment): check + record only. Each steel frame member gets one
# `FrameMemberCheck` (pass/fail + governing ratio); no resizing. Wind strength
# combos and RC frame members are deliberate follow-ups — the seismic combos are
# where the dual-system B2 (seismic story drift) machinery applies directly, and
# the member sizing stage already covers the gravity-only combos.

"""
    _dual_story_b2_records(elf) -> Dict{Int, StoryStability}

Per-story `StoryStability` record giving the **larger** `B2` across the two plan
directions, keyed by story index.

ENGINEERING JUDGMENT (conservative): the shared `_aisc_amplified_forces` core
applies a single story `B2` to both member axes, while AISC 360-16 Eq. A-8-6 is
direction-specific. Using the larger of the two directions' `B2` per story is
conservative (it never under-amplifies a member's lateral moments) and avoids
tying `B2` to each column's plan orientation.

`pmf_fraction = 1.0` (Pmf = ΣPu ⇒ `RM = 0.85`, Eq. A-8-8) is the largest-`B2`,
most conservative choice and matches this stage's designation that *all* columns
are moment-frame columns.
"""
function _dual_story_b2_records(elf)
    # ENGINEERING JUDGMENT: pmf_fraction=1.0 — see docstring. Not a code value.
    recs = story_stability_records(elf; pmf_fraction = 1.0)
    by_story = Dict{Int, StructuralSizer.StoryStability}()
    for ((story, _dir), rec) in recs
        cur = get(by_story, story, nothing)
        if cur === nothing || StructuralSizer.story_B2(rec) > StructuralSizer.story_B2(cur)
            by_story[story] = rec
        end
    end
    return by_story
end

"""
    _steel_frame_checker() -> AISCChecker

AISC beam-column checker for the dual frame members. Strength and stability
only (no depth or deflection limit): the dual stage verifies the installed
section against the §12.2.5.1 lateral demands, not serviceability — those are
owned by the member sizing stage. `ϕ` factors are the AISC 360-16 defaults.
"""
_steel_frame_checker() = StructuralSizer.AISCChecker()

"""Story index of a frame member for the `StoryStability`/`B2` lookup: a column
spans its `story`; a girder sits at a floor `level` (the top of that story)."""
_member_story(member) = hasproperty(member, :story) ? member.story : member.level

"""Steel grade of a member's section, falling back to A992 (Fy = 50 ksi) when
the section carries no material (corpus: aisc W-shape default grade)."""
function _steel_member_material(section)
    mat = hasproperty(section, :material) ? section.material : nothing
    return mat === nothing ? StructuralSizer.A992_Steel : mat
end

"""`SteelMemberGeometry` for a sway (unbraced) frame member. `braced=false`
flags sidesway so `is_feasible` requires a `story` for `B2`; `Cb=1.0` is the
conservative default (the installed `MemberBase` carries no frame Cb here)."""
function _steel_frame_geometry(member)
    # ENGINEERING JUDGMENT: Cb=1.0 — conservative LTB modifier for the check.
    return StructuralSizer.SteelMemberGeometry(member.base.L; Lb = member.base.Lb,
                                               Cb = 1.0, Kx = member.base.Kx,
                                               Ky = member.base.Ky, braced = false)
end

"""Signed end moments `(M1, M2)` of a station diagram, ordered so `|M2| ≥ |M1|`
for the AISC 360-16 Eq. A-8-4 `Cm` ratio."""
function _end_moments(diag)
    a, b = diag[1], diag[end]
    return abs(a) <= abs(b) ? (a, b) : (b, a)
end

"""Story P-Δ amplifier `B2` (AISC 360-16 Eq. A-8-6) of a `StoryStability`
record, or `1.0` when there is no record or the story is non-sway."""
function _story_b2_value(story)
    story === nothing && return 1.0
    return StructuralSizer.is_sway_frame(story) ? StructuralSizer.story_B2(story) : 1.0
end

"""
    _steel_nt_lt_demand(kind, index, nt, lt, b2) -> MemberDemand

Build one steel `MemberDemand` for an element from its no-translation (`nt`) and
lateral-translation (`lt`) station forces (both SI: N, N·m); `b2` is the member
story's `B2` (Eq. A-8-6).

Columns (`kind === :column`) are beam-columns: the `lt` split rides on a
`LateralTranslation` so `is_feasible` forms `Mr = B1·Mnt + B2·Mlt` (Eq. A-8-1)
and `Pr = Pnt + B2·Plt` (Eq. A-8-2). Girders (`kind === :beam`) carry negligible
axial, so `is_feasible` skips the Appendix-8 block; the sway moment is instead
pre-amplified here (`Mnt + B2·Mlt` per station, B1 = 1) and passed as the total
demand. Shear is the first-order total `nt + lt` for both (shear is not a
P-Δ/P-δ quantity, so it is not amplified). Axial is compression-positive; the
Asap station axial is tension-positive.
"""
function _steel_nt_lt_demand(kind::Symbol, index::Int, nt, lt, b2::Float64)
    Vu_strong = maximum(abs, nt.Vz .+ lt.Vz)
    Vu_weak = maximum(abs, nt.Vy .+ lt.Vy)
    if kind === :column
        # nt (Mnt / Pnt): factored gravity + Ev. Envelopes + signed end moments.
        Pnt = -minimum(nt.P); Pnt = Pnt < 0 ? 0.0 : Pnt     # compression only
        M1x_nt, M2x_nt = _end_moments(nt.My)
        M1y_nt, M2y_nt = _end_moments(nt.Mz)
        # lt (Mlt / Plt): factored ρ·Eh. is_feasible envelopes |M1lt|,|M2lt| itself.
        # ENGINEERING JUDGMENT: Plt = lt compression envelope (clamped ≥ 0) — the
        # story axial is ~constant along a column element, and crediting only the
        # compressive lt axial keeps the compression check conservative.
        Plt = -minimum(lt.P); Plt = Plt < 0 ? 0.0 : Plt
        lt_split = StructuralSizer.LateralTranslation(; Plt = Plt,
                       M1ltx = lt.My[1], M2ltx = lt.My[end],
                       M1lty = lt.Mz[1], M2lty = lt.Mz[end])
        return StructuralSizer.MemberDemand(index;
            Pu_c = Pnt, Mux = maximum(abs, nt.My), Muy = maximum(abs, nt.Mz),
            M1x = M1x_nt, M2x = M2x_nt, M1y = M1y_nt, M2y = M2y_nt,
            Vu_strong = Vu_strong, Vu_weak = Vu_weak,
            transverse_load = false, lt = lt_split)
    else
        # Girder: Pu_c ≈ 0 → is_feasible skips App. 8, so pre-amplify the sway
        # moment here (Mr = Mnt + B2·Mlt, B1 = 1) and pass the total envelope.
        Mux = maximum(abs, nt.My .+ b2 .* lt.My)
        Muy = maximum(abs, nt.Mz .+ b2 .* lt.Mz)
        return StructuralSizer.MemberDemand(index;
            Mux = Mux, Muy = Muy, Vu_strong = Vu_strong, Vu_weak = Vu_weak,
            transverse_load = true)
    end
end

"""Partition one element's factored station forces for `combo` into
`(nt, lt)`: nt = factored gravity + Ev (vertical seismic, axial only);
lt = factored ρ·Eh (horizontal seismic). Their sum is the full combination."""
function _split_nt_lt(combo, roof, D, L, C, eh, SDS, rho)
    n = length(D.P)
    nt = (P = Vector{Float64}(undef, n), My = similar(D.My), Vy = similar(D.Vy),
          Mz = similar(D.Mz), Vz = similar(D.Vz))
    lt = (P = Vector{Float64}(undef, n), My = similar(D.My), Vy = similar(D.Vy),
          Mz = similar(D.Mz), Vz = similar(D.Vz))
    for i in 1:n
        ev = vertical_seismic_load_effect(SDS, D.P[i])   # Ev = 0.2·SDS·D (axial)
        # nt: gravity + Ev (no horizontal lateral) → W=0, E=0.
        nt.P[i]  = _factored_component(combo, roof, D.P[i],  L.P[i],  C.P[i],  0.0, 0.0, ev)
        nt.My[i] = _factored_component(combo, roof, D.My[i], L.My[i], C.My[i], 0.0, 0.0, 0.0)
        nt.Vy[i] = _factored_component(combo, roof, D.Vy[i], L.Vy[i], C.Vy[i], 0.0, 0.0, 0.0)
        nt.Mz[i] = _factored_component(combo, roof, D.Mz[i], L.Mz[i], C.Mz[i], 0.0, 0.0, 0.0)
        nt.Vz[i] = _factored_component(combo, roof, D.Vz[i], L.Vz[i], C.Vz[i], 0.0, 0.0, 0.0)
        # lt: horizontal seismic only (ρ·Eh) → gravity=0, Ev=0, W=0, E=ρ·eh.
        lt.P[i]  = _factored_component(combo, roof, 0.0, 0.0, 0.0, 0.0, rho * eh.P[i],  0.0)
        lt.My[i] = _factored_component(combo, roof, 0.0, 0.0, 0.0, 0.0, rho * eh.My[i], 0.0)
        lt.Vy[i] = _factored_component(combo, roof, 0.0, 0.0, 0.0, 0.0, rho * eh.Vy[i], 0.0)
        lt.Mz[i] = _factored_component(combo, roof, 0.0, 0.0, 0.0, 0.0, rho * eh.Mz[i], 0.0)
        lt.Vz[i] = _factored_component(combo, roof, 0.0, 0.0, 0.0, 0.0, rho * eh.Vz[i], 0.0)
    end
    return nt, lt
end

"""
    _steel_member_rows(kind, index, els, set, basic, effects, inputs) -> Vector{(label, demand)}

`(label, MemberDemand)` for every seismic strength combo × seismic effect ×
frame element of one steel member. `set` is a first-order `StorySecondOrderSet`
(`set.u = [D, L, roof, wind…, qe…]`) from `_build_first_order` on the full model.
"""
function _steel_member_rows(kind, index, els, set, basic, effects, inputs, story)
    rho = Float64(inputs.rho); SDS = inputs.SDS; roof = inputs.roof
    nwind = set.nwind
    b2 = _story_b2_value(story)
    dead = [_loads_on_element(basic.loads[1], el) for el in els]
    live = [_loads_on_element(basic.loads[2], el) for el in els]
    rliv = [_loads_on_element(basic.loads[3], el) for el in els]
    rows = Tuple{String, StructuralSizer.MemberDemand}[]
    for combo in asce7_strength_combinations
        (combo.E != 0.0 || combo.Ev != 0.0) || continue   # seismic combos only
        for k in 1:length(effects)
            uqe = set.u[3 + nwind + k]
            for (j, el) in enumerate(els)
                D = _element_forces_from_u(el, set.u[1], dead[j])
                L = _element_forces_from_u(el, set.u[2], live[j])
                C = _element_forces_from_u(el, set.u[3], rliv[j])
                eh = _element_forces_from_u(el, uqe, Asap.AbstractLoad[])
                nt, lt = _split_nt_lt(combo, roof, D, L, C, eh, SDS, rho)
                demand = _steel_nt_lt_demand(kind, index, nt, lt, b2)
                push!(rows, ("$(combo.name) + $(effects[k].label)", demand))
            end
        end
    end
    return rows
end

"""
    _steel_member_report(kind, index, section, material, geometry, rows, story)
        -> FrameMemberCheck

Worst-row pass/fail of one steel member from `explain_feasibility` over every
`(label, demand)` row, amplified with the member's story `B2`. A failing row
outranks a passing one; among equals the higher demand/capacity ratio governs.
"""
function _steel_member_report(kind, index, section, material, geometry, rows, story)
    checker = _steel_frame_checker()
    cache = StructuralSizer.AISCCapacityCache(1)
    precompute_capacities!(checker, cache, [section], material, MinVolume())
    worst = nothing; worst_label = ""
    for (label, demand) in rows
        expl = explain_feasibility(checker, cache, 1, section, material, demand,
                                   geometry; story = story)
        if worst === nothing ||
           (!expl.passed, expl.governing_ratio) > (!worst.passed, worst.governing_ratio)
            worst = expl; worst_label = label
        end
    end
    worst === nothing && return FrameMemberCheck(kind, index, true, "no load row")
    detail = worst.passed ? "" : "$worst_label does not pass"
    return FrameMemberCheck(kind, index, worst.passed, detail, worst.governing_check,
                            worst.governing_ratio, worst_label)
end

"""
    dual_frame_member_checks(struc, set, basic, elf, effects, inputs, mf)
        -> (checks::Vector{FrameMemberCheck}, skipped::Int)

Steel frame-member strength check for the dual-system stage (increment 2). Each
**designated** moment-frame member (`mf.columns` / `mf.beams`) with a steel
(`ISymmSection`) section is checked as an AISC 360-16 beam-column under the
combined-system seismic demands with Appendix 8 `B1`/`B2` amplification (see the
file header). Non-steel frame members are skipped and counted (the RC path owns
them); the count is reported by the caller.

`set` is a first-order `StorySecondOrderSet` from `_build_first_order` on the
full frame+core model (`set.u = [D, L, roof, wind…, qe…]`); the caller builds it
once and shares it with the §12.2.5.1 share proxy.
"""
function dual_frame_member_checks(struc, set, basic, elf, effects, inputs, mf)
    by_story = _dual_story_b2_records(elf)
    checks = FrameMemberCheck[]
    skipped = 0
    for (kind, indices, members) in ((:column, mf.columns, struc.columns),
                                     (:beam, mf.beams, struc.beams))
        for i in indices
            member = members[i]
            section = member.base.section
            if !(section isa StructuralSizer.ISymmSection)
                skipped += 1
                continue
            end
            els = _member_frame_elements(struc, member)
            if isempty(els)
                push!(checks, FrameMemberCheck(kind, i, false, "no frame element"))
                continue
            end
            story = get(by_story, _member_story(member), nothing)
            rows = _steel_member_rows(kind, i, els, set, basic, effects, inputs, story)
            material = _steel_member_material(section)
            geometry = _steel_frame_geometry(member)
            push!(checks, _steel_member_report(kind, i, section, material, geometry,
                                               rows, story))
        end
    end
    return checks, skipped
end

# ==============================================================================
# Increment (1): §12.2.5.1 25% story-shear-share proxy (in-loop, no extra solve)
# ==============================================================================
#
# ASCE 7-22 §12.2.5.1 (corpus: asce-7-22, PDF page 177) requires the moment
# frame of a dual system to be *capable* of resisting at least 25% of the design
# seismic force. The authoritative test is the separate frame-only capability
# gate (increment 3, a bare-frame solve). This cheap proxy — decision
# deci-7d2c3467 — steers the sizing loop in between: from the already-solved
# COMBINED model it measures the moment frame's share of each story shear and
# flags any story below 25%. It is necessary but not sufficient (a 25% *share*
# in the combined model is not the same as independent 25% *capability*), so it
# never replaces the gate.

# ASCE 7-22 §12.2.5.1 (corpus: asce-7-22, PDF page 177): the moment frames shall
# be capable of resisting at least 25% of the design seismic forces.
const _DUAL_FRAME_SHARE_MIN = 0.25

"""
One story and one plan direction of the §12.2.5.1 share proxy.

`frame_shear_N` is the horizontal shear the designated moment-frame columns
carry across the story-bottom cut, projected on the loading axis; `total_shear_N`
is that of every lateral element at the cut (frame columns + core piers), so
`share = frame_shear_N / total_shear_N` is the frame's fraction of the story
shear in the combined model. Both are newtons. `share` is the governing
(smallest) value over the seismic effects of that direction.
"""
struct FrameShareCheck
    story::Int
    direction::Symbol
    frame_shear_N::Float64
    total_shear_N::Float64
    share::Float64
    passed::Bool
end

"""Asap frame-element IDs of the designated moment-frame columns (`mf.columns`)."""
function _mf_column_element_ids(struc, mf)
    ids = Set{Int}()
    for i in mf.columns
        for el in _member_frame_elements(struc, struc.columns[i])
            push!(ids, el.elementID)
        end
    end
    return ids
end

"""
    _dual_cut_shears(struc, u, z, dir, mf_ids) -> (frame_mf, total)

Horizontal story shear at the cut `z`, projected on the unit plan axis `dir`,
for displacement `u` on the combined frame+core model. `frame_mf` is the sum
over moment-frame columns (whose element IDs are in `mf_ids`); `total` adds
every other frame column and every core pier crossing the cut. By equilibrium
`total` is the applied story shear above the cut for this case, so
`frame_mf / total` is the moment frame's share.
"""
function _dual_cut_shears(struc, u::AbstractVector{<:Real}, z::Float64,
                          dir::NTuple{2, Float64}, mf_ids::Set{Int})
    model = struc.asap_model
    frame_mf = 0.0
    total = 0.0
    for el in _frame_elements(model)
        za = _node_xyz(el.nodeStart)[3]
        zb = _node_xyz(el.nodeEnd)[3]
        if abs(za - z) <= WALL_CUT_ZTOL_M && zb > z + WALL_CUT_ZTOL_M
            nd, i0 = el.nodeStart, 0
        elseif abs(zb - z) <= WALL_CUT_ZTOL_M && za > z + WALL_CUT_ZTOL_M
            nd, i0 = el.nodeEnd, 6
        else
            continue
        end
        Q = _case_fixed_end(el, nothing)
        f = _element_nodal_force(el, u; Qfixed=Q)
        fx, fy, _fz, _mx, _my, _mz = _interface_at_cut_node(f, Q, i0)
        h = fx * dir[1] + fy * dir[2]
        total += h
        el.elementID in mf_ids && (frame_mf += h)
    end
    for pier in struc.wall_mesh.piers
        isempty(pier.shells) && continue
        abs(_pier_bottom(pier) - z) <= WALL_CUT_ZTOL_M || continue
        for c in _cut_contributions(pier.shells, u, z)
            total += c.fx * dir[1] + c.fy * dir[2]
        end
    end
    return frame_mf, total
end

"""
    dual_frame_shear_shares(struc, set, elf, effects, mf) -> Vector{FrameShareCheck}

§12.2.5.1 25% story-shear-share proxy (increment 1). For every seismic effect
and every story, measure the moment frame's share of the story shear in the
already-solved COMBINED model (`set.u`), and keep the governing (smallest) share
per `(story, direction)`. A story whose frame share drops below 25% fails.

No extra solve: the effect displacements are the ones `_build_first_order`
already produced for the member checks. This is a sizing-loop steering signal,
not the authoritative capability test (that is the frame-only gate, increment 3).
"""
function dual_frame_shear_shares(struc, set, elf, effects, mf)
    mf_ids = _mf_column_element_ids(struc, mf)
    nwind = set.nwind
    best = Dict{Tuple{Int, Symbol}, FrameShareCheck}()
    for (k, effect) in enumerate(effects)
        u = set.u[3 + nwind + k]
        dir = elf_direction_vector(elf, effect.direction)
        for lv in elf.levels
            z = lv.elevation_m - lv.story_height_m
            frame_mf, total = _dual_cut_shears(struc, u, z, dir, mf_ids)
            # A story cut with no shear in this case carries no share information.
            abs(total) < 1.0 && continue
            share = abs(frame_mf) / abs(total)
            key = (lv.story, effect.direction)
            cur = get(best, key, nothing)
            (cur === nothing || share < cur.share) || continue
            # ASCE 7-22 §12.2.5.1 (corpus: asce-7-22, PDF page 177).
            best[key] = FrameShareCheck(lv.story, effect.direction, abs(frame_mf),
                abs(total), share, share >= _DUAL_FRAME_SHARE_MIN - 1e-9)
        end
    end
    return sort!(collect(values(best)); by = c -> (c.story, c.direction))
end
