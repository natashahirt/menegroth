# =============================================================================
# Discrete steel member sizing (simultaneous, catalog-based)
# =============================================================================

"""
    build_member_groups!(struc::BuildingStructure; member_type::Symbol=:beams)

Populate `struc.member_groups` from the specified member collection.

- `member_type`: Which members to group - `:beams`, `:columns`, `:struts`, or `:all`
- If `member.base.group_id === nothing`, the member is treated as its own singleton group
  and a deterministic `UInt64` group id is assigned.
- If `member.base.group_id` is set, all members with the same id are grouped together.

Note: member_indices in MemberGroup refer to indices within the specific member vector
(e.g., struc.beams[idx] for beams).
"""
function build_member_groups!(struc::BuildingStructure; member_type::Symbol=:beams)
    empty!(struc.member_groups)
    
    members = if member_type == :beams
        struc.beams
    elseif member_type == :columns
        struc.columns
    elseif member_type == :struts
        struc.struts
    elseif member_type == :all
        collect(all_members(struc))
    else
        throw(ArgumentError("Unknown member_type: $member_type. Use :beams, :columns, :struts, or :all"))
    end

    for (m_idx, m) in enumerate(members)
        gid = group_id(m) === nothing ? UInt64(hash((:singleton_member_group, member_type, m_idx))) : group_id(m)
        # Persist the resolved group id back onto the member
        set_group_id!(m, gid)

        mg = get!(struc.member_groups, gid) do
            MemberGroup(gid)
        end
        push!(mg.member_indices, m_idx)
    end

    return struc.member_groups
end

"""
    _service_load_deflections(struc, params) -> (δ_LL, δ_total)

Perform a service-load multi-RHS solve using the already-factorized stiffness
matrix. Returns two `Dict{Int, Float64}` (elementID → max deflection in meters):
  - `δ_LL`:    live-load-only deflection (for L/360 check)
  - `δ_total`: dead + live deflection (for L/240 check)

Load factors from `governing_combo(params)` are divided out to yield unfactored
(service) displacements. Only cell tributary loads (cell_dead_loads / cell_live_loads)
are included; secondary effects (vault thrust, self-weight) are omitted from the
split — this is a conservative simplification since vault thrust adds to total
deflection, making the factored-solve δ from `model.u` more conservative.
"""
function _service_load_deflections(
    struc::BuildingStructure,
    params::DesignParameters;
    resolution::Int = 20,
)
    model = struc.asap_model
    combo = governing_combo(params)
    factor_D = combo.D
    factor_L = combo.L

    dead_loads = Asap.AbstractLoad[]
    live_loads = Asap.AbstractLoad[]
    for loads in values(struc.cell_dead_loads)
        append!(dead_loads, loads)
    end
    for loads in values(struc.cell_live_loads)
        append!(live_loads, loads)
    end

    if isempty(dead_loads) && isempty(live_loads)
        empty_d = Dict{Int, Float64}()
        return (empty_d, copy(empty_d))
    end

    # Unshored composite already solved dead on steel and live on the composite
    # inertia. Superimpose those displacements. Do not recover both from one K.
    staged = _unshored_stage!(struc; resolution = resolution)
    if staged !== nothing
        u_D = copy(staged.u_D)
        u_L = copy(staged.u_L)
    else
        cases = Vector{Asap.AbstractLoad}[dead_loads, live_loads]
        u_vecs = Asap.solve(model, cases)
        u_D = u_vecs[1]
        u_L = u_vecs[2]
    end

    # Unfactor to service-level displacements
    if factor_D != 0; u_D ./= factor_D; end
    if factor_L != 0; u_L ./= factor_L; end

    u_total = u_D .+ u_L

    δ_LL    = Asap.element_max_deflections(model, u_L; resolution=resolution)
    δ_total = Asap.element_max_deflections(model, u_total; resolution=resolution)

    return (δ_LL, δ_total)
end

"""
    _fem_to_aci_endmoments(M_start, M_end) -> (M1, M2)

Convert a pair of signed FEM internal end moments to ACI 318-19 / AISC 360-16
end-moment convention `(M1, M2)` with `|M2| ≥ |M1|`.

# FEM convention
For a column under purely end moments, the *internal* moment field is
linear and antisymmetric in single curvature (`M_start`, `M_end` opposite
signs) and even-symmetric in double curvature (same signs).

# ACI 318-19 / AISC 360-16 convention
`M1/M2 > 0` ⇔ **double** curvature (best case, low Cm),
`M1/M2 < 0` ⇔ **single** curvature (worst case, high Cm).

So same-sign FEM end moments map to a **positive** `M1/M2` ratio, and
opposite-sign FEM end moments map to a **negative** ratio.

`M2` is always returned positive (defines the reference direction);
`M1` carries the relative sign.
"""
function _fem_to_aci_endmoments(M_start::Real, M_end::Real)
    if abs(M_start) >= abs(M_end)
        M2_signed = M_start
        M1_signed = M_end
    else
        M2_signed = M_end
        M1_signed = M_start
    end

    M2 = abs(M2_signed)
    if M2 < 1e-12
        return (0.0, 0.0)
    end

    same_sign = sign(M2_signed) == sign(M1_signed) || iszero(M1_signed)
    M1 = same_sign ? abs(M1_signed) : -abs(M1_signed)
    return (M1, M2)
end

"""
    _asap_signed_My_envelopes(el, My) -> (sag, hog)

Asap My sign convention (scripts/runners/check_asap_moment_sign.jl, default
Ψ = π/2). Horizontal beams under downward gravity:
  +x / +y / −y: local y = +global Z, midspan My > 0 (sagging), support My < 0
  −x:           local y = −global Z, midspan My < 0 (sagging), support My > 0
Sagging tensions the underside (bottom fiber = −global Z) and equals
sign(My) × sign(local_y · ê_Z). Hogging is the opposite. When |ly·ê_Z| ≈ 0
the face cannot be classified and both envelopes take |My| (conservative).
"""
function _asap_signed_My_envelopes(el, My)
    ly_z = el.LCS[2][3]
    if abs(ly_z) < 1e-8
        mag = mapreduce(abs, max, My)
        return mag, mag
    end
    s = ly_z > 0 ? 1.0 : -1.0
    sag = 0.0
    hog = 0.0
    for M in My
        sag = max(sag, M * s)
        hog = max(hog, -M * s)
    end
    return sag, hog
end

"""
    _strong_weak_peaks(My, Vy, Mz, Vz) -> (Mu, Vu, Mu_weak, Vu_weak)
    _strong_weak_peaks(f::AbstractVector) -> (Mu, Vu)

Peak strong- and weak-axis forces on one Asap frame element.

Asap pairs `My` with `Vy` (transverse load along local y) and `Mz` with `Vz`
(load along local z); see `accumulate_force!`. A beam's default roll is
`Ψ = π/2`, so local y is vertical and gravity is the `My`/`Vy` pair — the
strong axis, same pairing as [`_asap_signed_My_envelopes`](@ref). `Mz`/`Vz`
is the weak axis. Reading `Vz` as the design shear drops gravity shear.

The 12-vector method reads `element.forces` (local end forces, no member
load). Slots 2 and 8 are `Vy`; slots 6 and 12 are the end moments Asap
integrates into `My`.
"""
function _strong_weak_peaks(My, Vy, Mz, Vz)
    mu = isempty(My) ? 0.0 : mapreduce(abs, max, My)
    vu = isempty(Vy) ? 0.0 : mapreduce(abs, max, Vy)
    mu_w = isempty(Mz) ? 0.0 : mapreduce(abs, max, Mz)
    vu_w = isempty(Vz) ? 0.0 : mapreduce(abs, max, Vz)
    return (Mu = mu, Vu = vu, Mu_weak = mu_w, Vu_weak = vu_w)
end

function _strong_weak_peaks(f::AbstractVector{<:Real})
    n = length(f)
    mu = 0.0
    vu = 0.0
    n >= 2 && (vu = max(vu, abs(f[2])))
    n >= 8 && (vu = max(vu, abs(f[8])))
    n >= 6 && (mu = max(mu, abs(f[6])))
    n >= 12 && (mu = max(mu, abs(f[12])))
    return (Mu = mu, Vu = vu)
end

"""
Station forces for `el` from a caller-supplied global displacement vector.

Mirrors `Asap.ElementForceAndDisplacement`'s force path (`R * K * u_e` then
`accumulate_force!` for the case loads) without reading `node.displacement`.
Used so pattern-case `u` from `Asap.solve(model, cases)` can be evaluated
without mutating `model.u` (full-load deflections stay on `model.u`).
"""
function _element_forces_from_u(el, u_global::AbstractVector{<:Real}, loads; resolution::Int=200)
    dofs = Asap.etype2DOF[typeof(el)]
    ep = Asap.ElementProps(el)
    L = ep.L
    rng = range(0, L, resolution)
    u_e = u_global[el.globalID]
    Ku = el.K * u_e
    Flocal = el.R * Ku
    @inbounds for i in 1:12
        Flocal[i] *= dofs[i]
    end
    Pstart  = -Flocal[1]
    Vystart =  Flocal[2]
    Mystart =  Flocal[6]
    Vzstart =  Flocal[3]
    Mzstart = -Flocal[5]
    P  = fill(Pstart, resolution)
    My = Vector{Float64}(undef, resolution)
    Vy = fill(Vystart, resolution)
    Mz = Vector{Float64}(undef, resolution)
    Vz = fill(Vzstart, resolution)
    @inbounds for i in 1:resolution
        My[i] = Vystart * rng[i] - Mystart
        Mz[i] = Vzstart * rng[i] - Mzstart
    end
    for load in loads
        Asap.accumulate_force!(load, rng, P, My, Vy, Mz, Vz, ep)
    end
    return (P=P, My=My, Vy=Vy, Mz=Mz, Vz=Vz)
end

"""
Pattern-case (loads, u) pairs for member sizing, or `nothing` if only the
full-load solve applies.

Prefers the cache written by `_solve_with_patterns!`. If that is missing but
dead/live splits exist and `params` still requests patterns, re-solves with
the cached K factorization (ACI 318-11 §13.7.6, corpus: aci-318-11, page 261).
"""
function _pattern_demand_cases(struc::BuildingStructure, params::DesignParameters)
    cached = _get_pattern_solve_cache(struc)
    if cached !== nothing
        # Prefer the cache so callers that omit `params` still envelope
        # patterns — but never reuse a pre-K / pre-GravityLoad `pattern_u`
        # (ACI 318-11 §13.7.6.3–13.7.6.4, corpus: aci-318-11, page 261).
        if !_pattern_cache_is_current(struc)
            _refresh_pattern_solve_cache!(struc)
            cached = _get_pattern_solve_cache(struc)
        end
        if cached !== nothing
            cases, u_cases = cached
            n_el = length(struc.asap_model.frame_elements)
            n_el == 0 && return nothing
            return [(u, Asap.get_elemental_loads(loads, n_el)) for (u, loads) in zip(u_cases, cases)]
        end
    end
    use = params.pattern_loading != :none &&
          !isempty(struc.cell_dead_loads) &&
          any(!isempty, values(struc.cell_dead_loads)) &&
          _should_run_patterns(struc, params)
    (use && struc.asap_model.processed) || return nothing
    cases = _generate_pattern_cases(struc)
    length(cases) <= 1 && return nothing
    u_cases = Asap.solve(struc.asap_model, cases)
    n_el = length(struc.asap_model.frame_elements)
    n_el == 0 && return nothing
    return [(u, Asap.get_elemental_loads(loads, n_el)) for (u, loads) in zip(u_cases, cases)]
end

"""
    member_group_demands(struc; member_edge_group=:beams, resolution=200, params=DesignParameters())

Compute governing demands and geometry for each `MemberGroup` by enveloping ASAP internal
forces across all segments of all members in the group.

Conventions:
- gravity bending (strong axis) demand uses `My`
- weak-axis bending demand uses `Mz`
- shear demand uses `Vy`/`Vz` (mapped to weak/strong)
- deflection uses max local Z displacement from `ElementDisplacements.ulocal`

For columns (`member_edge_group == :columns`), signed end moments are
extracted at the start of the first segment and the end of the last
segment of each member, then converted to ACI 318-19 / AISC 360-16
`(M1, M2)` convention via `_fem_to_aci_endmoments`. The group's
`M1x/M2x/M1y/M2y` are taken from the column with the largest |M2|.
This lets the slenderness path compute `Cm = 0.6 − 0.4·(M1/M2)`
instead of falling back on the conservative `M1 = 0` stand-in.

When `params` is provided and cell dead/live loads are available, a service-load
multi-RHS solve separates LL-only and total (DL+LL) deflections. Otherwise
the factored-solve deflection is used for both (conservative).

Pattern cases (ACI 318-11 §13.7.6.3–13.7.6.4, corpus: aci-318-11, page 261)
envelope STRENGTH from per-case station forces (signed M+/M− and shears).
Deflection stays on the full-load solve (`model.u`). The per-DOF abs envelope
on `el.forces` is not used as a sizing source.

For multi-segment members (shattered edges), the `δ_max` in the returned demand
is pre-scaled so that `δ_max / L_total == δ_original / L_defl`, where `L_defl`
is the longest individual sub-segment (the actual deflection span between supports).

`shell_demands` maps a beam index to its [`ShellBeamDemand`](@ref). Each beam
group's sagging moment, hogging moment, and strong-axis shear become the larger
of the frame-model value and the shell value. The shell never lowers a demand.
Deflection here is the frame model's alone. Story-shell deflection is a
separate per-span check and never enters these demands.

Returns `(group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs)`.
"""
function member_group_demands(struc::BuildingStructure;
    member_edge_group::Union{Symbol, AbstractVector{Symbol}, Tuple{Vararg{Symbol}}}=:beams,
    resolution::Int=200,
    params::DesignParameters=DesignParameters(),
    shell_demands::Union{Nothing, AbstractDict{Int, ShellBeamDemand}}=nothing)
    isempty(struc.asap_model.frame_elements) && throw(ArgumentError("ASAP model is empty. Call `to_asap!(struc)` before sizing."))

    skel = struc.skeleton
    groups = member_edge_group isa Symbol ? (member_edge_group,) : member_edge_group
    beam_edge_ids = Set{Int}()
    for g in groups
        union!(beam_edge_ids, get(skel.groups_edges, g, Int[]))
    end

    member_type = if member_edge_group === :columns || (member_edge_group isa Union{AbstractVector{Symbol}, Tuple} && :columns in member_edge_group)
        :columns
    elseif member_edge_group === :struts || (member_edge_group isa Union{AbstractVector{Symbol}, Tuple} && :struts in member_edge_group)
        :struts
    else
        :beams
    end
    member_array = member_type == :columns ? struc.columns :
                   member_type == :struts ? struc.struts : struc.beams

    # Always rebuild — groups are member-type-specific, and the shared dict
    # may hold stale groups from a previous call with a different member type.
    build_member_groups!(struc; member_type=member_type)

    all_group_ids = sort(collect(keys(struc.member_groups)))
    n_groups = length(all_group_ids)

    # Use lazy-cached element-to-loads map (avoids O(n_loads) rebuild per call)
    element_loads = Asap.get_elemental_loads(struc.asap_model)

    # Unshored composite: dead load on the steel inertia, each live pattern
    # on the composite inertia (AISC 360-22 Commentary §I3.1b, corpus:
    # aisc-360-22, PDF p. 500). Built after the stage so the steel dead load
    # has been sampled. Nothing when the mesh is absent or the beam is shored.
    staged = member_type === :beams ? _unshored_stage!(struc; resolution = resolution) : nothing
    split_patterns = _unshored_pattern_forces(struc; resolution = resolution)
    # Pattern cases (ACI 318-11 §13.7.6.3–13.7.6.4, corpus: aci-318-11,
    # page 261): per-case station forces, not the per-DOF abs envelope on
    # el.forces. Skipped when the unshored split above already has a case
    # per pattern. `nothing` ⇒ full-load only.
    pattern_cases = split_patterns === nothing ?
        _pattern_demand_cases(struc, params) : nothing
    if split_patterns === nothing
        split_patterns = _unshored_pattern_forces(struc; resolution = resolution)
    end
    n_pat = if split_patterns !== nothing
        length(split_patterns)
    elseif pattern_cases === nothing
        1
    else
        length(pattern_cases)
    end

    # Whether to extract signed end moments for ACI 318-19 slenderness Cm.
    # Only meaningful for columns; beams/struts use the conservative M1=0 default.
    extract_end_moments = member_type === :columns

    # Preallocated per-group parallel storage
    par_has  = Vector{Bool}(undef, n_groups)
    par_Pu_c = Vector{Float64}(undef, n_groups)
    par_Pu_t = Vector{Float64}(undef, n_groups)
    par_Mux  = Vector{Float64}(undef, n_groups)
    par_Mux_pos = Vector{Float64}(undef, n_groups)
    par_Mux_neg = Vector{Float64}(undef, n_groups)
    par_Muy  = Vector{Float64}(undef, n_groups)
    par_Vus  = Vector{Float64}(undef, n_groups)
    par_Vuw  = Vector{Float64}(undef, n_groups)
    par_δ    = Vector{Float64}(undef, n_groups)
    par_Ir   = Vector{Float64}(undef, n_groups)
    par_L    = Vector{Float64}(undef, n_groups)
    par_Lb   = Vector{Float64}(undef, n_groups)
    par_Cb   = Vector{Float64}(undef, n_groups)
    par_Kx   = Vector{Float64}(undef, n_groups)
    par_Ky   = Vector{Float64}(undef, n_groups)
    par_Ldefl = Vector{Float64}(undef, n_groups)  # deflection span (longest sub-segment)
    # Signed (M1, M2) per group, ACI 318-19 sign convention. Selected from the
    # member with the largest |M2| in each axis. Defaulted to (0,0) when no
    # column member is present (e.g., beam/strut groups).
    par_M1x = zeros(Float64, n_groups); par_M2x = zeros(Float64, n_groups)
    par_M1y = zeros(Float64, n_groups); par_M2y = zeros(Float64, n_groups)

    Threads.@threads for g in 1:n_groups
        gid = all_group_ids[g]
        mg = struc.member_groups[gid]

        # Group envelope: max |P| paired with max |M| (not a concurrent case).
        # CONSERVATIVE under gravity-only. Pu_t and Mux_neg are stored on the
        # demand and forwarded by the steel sizers into the existing H1 check
        # (AISC 360-16 §H1.1 page 133, §H1.2 page 134 — corpus: aisc-360-16).
        Pu_comp = 0.0; Pu_tens = 0.0
        Mux = 0.0; Mux_pos = 0.0; Mux_neg = 0.0; Muy = 0.0
        Vu_strong = 0.0; Vu_weak = 0.0
        L_total = 0.0; Lb_gov = 0.0; Cb_gov = Inf
        L_defl = 0.0  # longest individual segment (deflection span)
        Kx_gov = 0.0; Ky_gov = 0.0
        has_any = false
        δ_max = 0.0; I_ref = 0.0

        # End-moment selection (column groups only). M1 and M2 come from the
        # same pattern case — the case with the largest |M2| on that axis —
        # so Cm is not mixed across non-concurrent load patterns
        # (ACI 318-11 §13.7.6.3–13.7.6.4, corpus: aci-318-11, page 261).
        best_M2x = 0.0; best_M1x = 0.0
        best_M2y = 0.0; best_M1y = 0.0

        for m_idx in mg.member_indices
            m = member_array[m_idx]
            Kx_gov = max(Kx_gov, m.base.Kx)
            Ky_gov = max(Ky_gov, m.base.Ky)

            seg_list = segment_indices(m)
            n_segs = length(seg_list)

            # Per-case end-moment scratch (FEM internal-moment convention).
            # Walked in segment order: start = f.M[1] of first segment, end =
            # f.M[end] of last segment, both from the same pattern case.
            case_My_s = zeros(Float64, n_pat); case_My_e = zeros(Float64, n_pat)
            case_Mz_s = zeros(Float64, n_pat); case_Mz_e = zeros(Float64, n_pat)
            saw_first_seg = false; saw_last_seg = false

            for (seg_pos, seg_idx) in enumerate(seg_list)
                seg = struc.segments[seg_idx]
                edge_idx = seg.edge_idx
                edge_idx in beam_edge_ids || continue

                has_any = true
                len_val = to_meters(seg.L)
                lb_val  = to_meters(seg.Lb)
                L_total += len_val
                Lb_gov = max(Lb_gov, lb_val)
                L_defl = max(L_defl, len_val)  # track longest sub-segment
                Cb_gov = min(Cb_gov, seg.Cb)

                frame_idxs = _frame_element_indices(struc, edge_idx)
                for (child_pos, el_idx) in enumerate(frame_idxs)
                el = struc.asap_model.frame_elements[el_idx]
                el_loads = element_loads[el.elementID]

                # Displacements from the full-load solve (`model.u` / node.displacement).
                # Pattern cases envelope STRENGTH only; deflection stays full-load.
                fd = Asap.ElementForceAndDisplacement(el, el_loads; resolution=resolution)
                edisp = fd.displacements

                force_sets = if split_patterns !== nothing
                    ntuple(i -> begin
                        f = get(split_patterns[i], el.elementID, nothing)
                        f === nothing ? fd.forces : f
                    end, length(split_patterns))
                elseif pattern_cases === nothing
                    (fd.forces,)
                else
                    ntuple(i -> begin
                        u_case, case_map = pattern_cases[i]
                        loads_i = el.elementID <= length(case_map) ? case_map[el.elementID] :
                            Asap.AbstractLoad[]
                        _element_forces_from_u(el, u_case, loads_i; resolution=resolution)
                    end, length(pattern_cases))
                end
                if staged !== nothing && haskey(staged.forces, el.elementID)
                    force_sets = (force_sets..., staged.forces[el.elementID])
                end

                for (ci, f) in enumerate(force_sets)
                    min_P = minimum(f.P); max_P = maximum(f.P)
                    if min_P < 0; Pu_comp = max(Pu_comp, abs(min_P)); end
                    if max_P > 0; Pu_tens = max(Pu_tens, max_P); end

                    peaks = _strong_weak_peaks(f.My, f.Vy, f.Mz, f.Vz)
                    Mux = max(Mux, peaks.Mu)
                    sag, hog = _asap_signed_My_envelopes(el, f.My)
                    if member_type === :beams
                        Mux_pos = max(Mux_pos, sag)
                        Mux_neg = max(Mux_neg, hog)
                    end
                    Vu_strong = max(Vu_strong, peaks.Vu)
                    Muy = max(Muy, peaks.Mu_weak)
                    Vu_weak = max(Vu_weak, peaks.Vu_weak)

                    if extract_end_moments && ci <= n_pat
                        if seg_pos == 1 && child_pos == 1
                            case_My_s[ci] = Float64(f.My[1])
                            case_Mz_s[ci] = Float64(f.Mz[1])
                            saw_first_seg = true
                        end
                        if seg_pos == n_segs && child_pos == length(frame_idxs)
                            case_My_e[ci] = Float64(f.My[end])
                            case_Mz_e[ci] = Float64(f.Mz[end])
                            saw_last_seg = true
                        end
                    end
                end

                δ_local = mapreduce(j -> abs(edisp.ulocal[3, j]), max, 1:size(edisp.ulocal, 2))
                δ_max = max(δ_max, δ_local)

                I_current = ustrip(u"m^4", el.section.Ix)
                I_ref = max(I_ref, I_current)
                end
            end

            if extract_end_moments && saw_first_seg && saw_last_seg
                for ci in 1:n_pat
                    M1x_m, M2x_m = _fem_to_aci_endmoments(case_My_s[ci], case_My_e[ci])
                    M1y_m, M2y_m = _fem_to_aci_endmoments(case_Mz_s[ci], case_Mz_e[ci])
                    if M2x_m > best_M2x
                        best_M2x = M2x_m; best_M1x = M1x_m
                    end
                    if M2y_m > best_M2y
                        best_M2y = M2y_m; best_M1y = M1y_m
                    end
                end
            end
        end

        par_has[g]  = has_any
        par_Pu_c[g] = Pu_comp; par_Pu_t[g] = Pu_tens
        par_Mux[g]  = Mux;     par_Muy[g]  = Muy
        par_Mux_pos[g] = member_type === :beams ? Mux_pos : Mux
        par_Mux_neg[g] = member_type === :beams ? Mux_neg : Mux
        par_Vus[g]  = Vu_strong; par_Vuw[g] = Vu_weak
        par_δ[g]    = δ_max;   par_Ir[g]   = I_ref
        par_L[g]    = L_total; par_Lb[g]   = Lb_gov
        par_Cb[g]   = Cb_gov;  par_Kx[g]   = Kx_gov; par_Ky[g] = Ky_gov
        par_Ldefl[g] = L_defl
        par_M1x[g] = best_M1x; par_M2x[g] = best_M2x
        par_M1y[g] = best_M1y; par_M2y[g] = best_M2y
    end

    if shell_demands !== nothing && !isempty(shell_demands)
        member_type === :beams || throw(ArgumentError("shell demands apply to beams only"))
        for g in 1:n_groups
            par_has[g] || continue
            for m_idx in struc.member_groups[all_group_ids[g]].member_indices
                d = get(shell_demands, m_idx, nothing)
                d === nothing && continue
                par_Mux_pos[g] = max(par_Mux_pos[g], d.Mu_pos)
                par_Mux_neg[g] = max(par_Mux_neg[g], d.Mu_neg)
                par_Mux[g] = max(par_Mux[g], d.Mu_pos, d.Mu_neg)
                par_Vus[g] = max(par_Vus[g], d.Vu)
            end
        end
    end

    # ── Service-load deflection split (LL-only vs DL+LL) ──
    # Solve for unfactored dead and live displacements separately,
    # then extract per-element max deflections.
    has_split = !isempty(struc.cell_dead_loads) || !isempty(struc.cell_live_loads)
    local δ_LL_map::Dict{Int, Float64}
    local δ_total_map::Dict{Int, Float64}
    if has_split
        δ_LL_map, δ_total_map = _service_load_deflections(struc, params)
    else
        δ_LL_map = Dict{Int, Float64}()
        δ_total_map = Dict{Int, Float64}()
    end

    # Aggregate service deflections per group (max over all segments)
    par_δ_LL    = Vector{Float64}(undef, n_groups)
    par_δ_total = Vector{Float64}(undef, n_groups)
    Threads.@threads for g in 1:n_groups
        par_has[g] || (par_δ_LL[g] = 0.0; par_δ_total[g] = 0.0; continue)
        gid = all_group_ids[g]
        mg = struc.member_groups[gid]
        δ_ll = 0.0; δ_tot = 0.0
        for m_idx in mg.member_indices
            m = member_array[m_idx]
            for seg_idx in segment_indices(m)
                seg = struc.segments[seg_idx]
                edge_idx = seg.edge_idx
                edge_idx in beam_edge_ids || continue
                for el_idx in _frame_element_indices(struc, edge_idx)
                    el = struc.asap_model.frame_elements[el_idx]
                    eid = el.elementID
                    δ_ll  = max(δ_ll,  get(δ_LL_map, eid, 0.0))
                    δ_tot = max(δ_tot, get(δ_total_map, eid, 0.0))
                end
            end
        end
        par_δ_LL[g] = δ_ll
        par_δ_total[g] = δ_tot
    end

    # Sequential filter & renumber indices
    group_ids = UInt64[]
    demands   = StructuralSizer.MemberDemand{Float64, Nothing}[]
    L_totals  = Float64[]
    Lb_govs   = Float64[]
    Cb_govs   = Float64[]
    Kx_govs   = Float64[]
    Ky_govs   = Float64[]
    Ldefl_govs = Float64[]

    for g in 1:n_groups
        par_has[g] || continue
        push!(group_ids, all_group_ids[g])
        g_idx = length(group_ids)

        L_t = par_L[g]
        L_d = par_Ldefl[g]
        scale = (L_d > 0 && L_d < L_t) ? L_t / L_d : 1.0

        δ_ll_adj    = has_split ? par_δ_LL[g] * scale    : par_δ[g] * scale
        δ_total_adj = has_split ? par_δ_total[g] * scale  : 0.0

        # For column groups, par_M*x/par_M*y carry signed (M1, M2) per ACI
        # 318-19 from FEA. For other member types we leave M1/M2 unset so
        # the `MemberDemand` constructor falls back to its conservative
        # default (`M1 = 0`, `M2 = Mux/Muy` ⇒ Cm = 0.6).
        if extract_end_moments
            d = StructuralSizer.MemberDemand(g_idx;
                Pu_c=par_Pu_c[g], Pu_t=par_Pu_t[g],
                Mux=par_Mux[g], Muy=par_Muy[g],
                M1x=par_M1x[g], M2x=par_M2x[g],
                M1y=par_M1y[g], M2y=par_M2y[g],
                Vu_strong=par_Vus[g], Vu_weak=par_Vuw[g],
                δ_max_LL=δ_ll_adj, δ_max_total=δ_total_adj,
                I_ref=par_Ir[g],
                transverse_load=false)
        else
            d = StructuralSizer.MemberDemand(g_idx;
                Pu_c=par_Pu_c[g], Pu_t=par_Pu_t[g],
                Mux=par_Mux[g],
                Mux_pos=par_Mux_pos[g], Mux_neg=par_Mux_neg[g],
                Muy=par_Muy[g],
                Vu_strong=par_Vus[g], Vu_weak=par_Vuw[g],
                δ_max_LL=δ_ll_adj, δ_max_total=δ_total_adj,
                I_ref=par_Ir[g])
        end

        push!(demands, d)
        push!(L_totals, par_L[g])
        push!(Lb_govs, par_Lb[g])
        push!(Cb_govs, par_Cb[g])
        push!(Kx_govs, par_Kx[g])
        push!(Ky_govs, par_Ky[g])
    end

    return group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs
end

"""
    size_steel_members!(struc; catalog, material, member_edge_group, ...)

Discrete, simultaneous catalog-based sizing for steel members using a MIP.
Respects `Member.group_id` by solving at the group level.

Uses `AISCChecker` for capacity checks and `StructuralSizer.to_asap_section`
for ASAP model updates.

# Arguments
- `catalog`: Steel section catalog (default: all W shapes)
- `material`: Steel grade (default: A992_Steel)
- `member_edge_group`: Which edge group to size — `:beams`, `:columns`, `:struts` (default: `:beams`)
- `deflection_limit`: L/δ ratio, e.g. `1/360`. `nothing` = strength-only (default: `nothing`)

Side effects:
- populates/overwrites `struc.member_groups[gid].section`
- populates each `member.section` and `member.volumes`
- updates ASAP element sections for all member segments in `member_edge_group`
"""
function size_steel_members!(
    struc::BuildingStructure;
    catalog=StructuralSizer.all_W(),
    material=StructuralSizer.A992_Steel,
    member_edge_group::Symbol=:beams,
    max_depth=Inf * u"m",
    n_max_sections::Integer=0,
    solver::Symbol=:auto,
    resolution::Int=200,
    reanalyze::Bool=true,
    gravity_factor::Quantity=GRAVITY,
    deflection_limit::Union{Nothing, Real}=nothing,  # e.g., 1/360
    skel = struc.skeleton,
    edge_ids_in_group = Set(get(skel.groups_edges, member_edge_group, Int[])))
    
    _add_gravity_loads!(struc, edge_ids_in_group, gravity_factor)
    
    group_ids, demands, L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs =
        member_group_demands(struc; member_edge_group=member_edge_group, resolution=resolution)

    # Determine member array from edge group name (must match member_group_demands logic)
    member_array = if member_edge_group === :columns || (member_edge_group isa Union{AbstractVector{Symbol}, Tuple} && :columns in member_edge_group)
        struc.columns
    elseif member_edge_group === :struts || (member_edge_group isa Union{AbstractVector{Symbol}, Tuple} && :struts in member_edge_group)
        struc.struts
    else
        struc.beams
    end

    # Convert to SteelMemberGeometry objects for new API
    geometries = [StructuralSizer.SteelMemberGeometry(L; Lb=Lb, Cb=Cb, Kx=Kx, Ky=Ky)
                  for (L, Lb, Cb, Kx, Ky) in zip(L_totals, Lb_govs, Cb_govs, Kx_govs, Ky_govs)]
    
    # Create AISC checker with design constraints
    checker = StructuralSizer.AISCChecker(;
        max_depth=max_depth,
        deflection_limit=deflection_limit,
    )
    
    # Choose solver: binary search (fast, per-group optimal) when there are no
    # shared-section constraints; MIP when n_max_sections is active.
    if n_max_sections > 0
        result = StructuralSizer.optimize_discrete(
            checker, demands, geometries, catalog, material;
            n_max_sections=n_max_sections,
            optimizer=solver,
        )
        solver_name = "MIP"
    else
        result = StructuralSizer.optimize_binary_search(
            checker, demands, geometries, catalog, material,
        )
        solver_name = "binary search"
    end

    # Apply results to member groups + ASAP elements + individual members
    for (g_idx, gid) in enumerate(group_ids)
        chosen_template = result.sections[g_idx]
        
        # Create a copy with the specific material for this group
        # (Catalog sections usually have material=nothing)
        chosen = copy(chosen_template)
        chosen.material = material

        mg = struc.member_groups[gid]
        mg.section = chosen

        # Build ASAP section once per group
        asap_sec = StructuralSizer.to_asap_section(chosen, material)

        for m_idx in mg.member_indices
            m = member_array[m_idx]  # Index into appropriate member array
            
            # Compute total length and store section/volume on member
            # Ensure L_total has units (skeleton may use plain Float64)
            L_raw = sum(struc.segments[i].L for i in segment_indices(m))
            L_total = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"
            set_section!(m, chosen)
            set_volumes!(m, MaterialVolumes(
                _volume_key(material) => StructuralSizer.self_weight_area(chosen) * L_total))

            # Update ASAP elements
            for seg_idx in segment_indices(m)
                edge_idx = struc.segments[seg_idx].edge_idx
                edge_idx in edge_ids_in_group || continue
                struc.asap_model.frame_elements[edge_idx].section = asap_sec
            end
        end
    end

    if reanalyze
        Asap.process!(struc.asap_model)
        Asap.solve!(struc.asap_model)
    end

    defl_str = isnothing(deflection_limit) ? "none" : "L/$(Int(round(1/deflection_limit)))"
    @info "Sized $(length(group_ids)) steel member groups via $solver_name" n_max_sections=n_max_sections deflection_limit=defl_str
    return struc
end

