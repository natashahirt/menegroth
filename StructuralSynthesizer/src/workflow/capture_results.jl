# =============================================================================
# Internal Helpers
# =============================================================================

"""Infer floor type from floor options."""
_infer_floor_type(opts::StructuralSizer.AbstractFloorOptions) = StructuralSizer.floor_symbol(opts)

"""Column f′c for the initial size estimate. Not the slab concrete."""
function _get_design_fc(params::DesignParameters)
    return column_concrete(params).fc′
end

"""Size foundations using FoundationParameters.

Uses the strategy-aware `size_foundations!` pipeline so that
`fp.options.strategy` (:mat, :all_spread, :all_strip, :auto, :auto_strip_spread) is respected.
"""
function _size_foundations!(
    struc::BuildingStructure,
    fp::FoundationParameters;
    tc::Union{Nothing, StructuralSizer.TraceCollector} = nothing,
)
    initialize_supports!(struc)
    if isempty(struc.supports)
        @warn "Skipping foundation sizing: no supports found. Ensure support vertices are at grade."
        StructuralSizer.emit!(tc, :workflow, "_size_foundations!", "", :decision;
                              outcome="skipped", reason="no_supports")
        return
    end
    StructuralSizer.emit!(tc, :workflow, "_size_foundations!", "", :enter;
                          n_supports=length(struc.supports),
                          strategy=string(fp.options.strategy))
    size_foundations!(struc;
        soil = fp.soil,
        opts = fp.options,
        group_tolerance = fp.group_tolerance,
        concrete = fp.concrete,
        rebar = fp.rebar,
        pier_width = fp.pier_width,
        min_depth = fp.min_depth,
        tc = tc,
    )
    StructuralSizer.emit!(tc, :workflow, "_size_foundations!", "", :exit;
                          n_foundations=length(struc.foundations))
end

"""Extract column axial demands into pre-allocated buffer (zero-alloc)."""
function _extract_column_demands!(demands::Vector{Float64}, struc::BuildingStructure)
    @inbounds for (i, col) in enumerate(struc.columns)
        demands[i] = _column_asap_Pu(struc, col)
    end
    return demands
end

"""Compute maximum relative change in column demands."""
function _max_demand_change(prev::Vector{Float64}, curr::Vector{Float64})
    length(prev) == length(curr) || return 1.0
    max_change = 0.0
    for (p, c) in zip(prev, curr)
        if p > 0
            change = abs(c - p) / p
            max_change = max(max_change, change)
        elseif c > 0
            max_change = 1.0
        end
    end
    return max_change
end

# =============================================================================
# Result Population Functions
# =============================================================================

"""
Copy `method_requested`, `method_used`, and `method_fallback_reasons` from
the `size_flat_plate!` NamedTuple `dd` onto `result`.

USER DECISION: the default is to fall back to FEA and notify.  The notice
is on `SlabDesignResult` because that is what `design_building` returns.
"""
function _copy_method_notice!(result::SlabDesignResult, dd)
    isnothing(dd) && return result
    if hasproperty(dd, :method_requested) &&
       dd.method_requested isa StructuralSizer.FlatPlateAnalysisMethod
        result.method_requested = dd.method_requested
    end
    if hasproperty(dd, :method_used) &&
       dd.method_used isa StructuralSizer.FlatPlateAnalysisMethod
        result.method_used = dd.method_used
    end
    if hasproperty(dd, :method_fallback_reasons) && !isnothing(dd.method_fallback_reasons)
        result.method_fallback_reasons = String[string(r) for r in dd.method_fallback_reasons]
    end
    return result
end

"""
Copy this slab's story-shell bars onto `result`. A panel whose section
cannot carry its shell moments fails the slab as `reinforcement_design`.
"""
function _capture_shell_reinforcement!(result::SlabDesignResult, dd)
    hasproperty(dd, :shell_reinforcement) && hasproperty(dd, :shell_panels) || return result
    fields = dd.shell_reinforcement[dd.shell_panels]
    result.shell_reinforcement = fields
    if !all(f -> f.section_adequate, fields)
        result.converged = false
        result.failure_reason = "section_inadequate"
        result.failing_check = "reinforcement_design"
    end
    return result
end

"""
Populate slab design results from struc.slabs (all values normalized to SI).

Uses `slab.design_details` (the full `size_flat_plate!` NamedTuple) when
available to capture column P-M, integrity, transfer, and punching detail
that `slab.result` (FlatPlatePanelResult) alone doesn't carry.  Also copies
`method_requested`, `method_used`, and `method_fallback_reasons` onto the
`SlabDesignResult` so a `design_building` caller sees a FEA fallback.
"""
function _populate_slab_results!(design::BuildingDesign, struc::BuildingStructure)
    # Handle case where slabs haven't been initialized yet
    if isnothing(struc.slabs) || isempty(struc.slabs)
        return
    end
    head_frame = solid_head_frame_punching(struc, design.params)

    for (slab_idx, slab) in enumerate(struc.slabs)
        # Fallback: slab.result is nothing (shouldn't happen for properly initialized slabs,
        # but handle gracefully to avoid dropping the slab from visualization entirely).
        if isnothing(slab.result)
            dd = hasproperty(slab, :design_details) ? slab.design_details : nothing
            did_converge = isnothing(dd) || !hasproperty(dd, :converged) || dd.converged
            # Use initial slab thickness if available via spans (h ≈ ln/33 minimum)
            fallback_h = try
                h_init = slab.spans.primary / 33
                uconvert(u"m", h_init)
            catch
                0.2u"m"  # 200mm default
            end
            fallback = SlabDesignResult(
                thickness   = fallback_h,
                self_weight = 0.0u"kPa",
                converged       = did_converge,
                failure_reason  = !did_converge && !isnothing(dd) && hasproperty(dd, :failure_reason) ? string(dd.failure_reason) : "",
                failing_check   = !did_converge && !isnothing(dd) && hasproperty(dd, :failing_check)  ? string(dd.failing_check)  : "",
                iterations      = !isnothing(dd) && hasproperty(dd, :iterations)     ? dd.iterations      : 0,
                pattern_loading = !isnothing(dd) && hasproperty(dd, :pattern_loading) ? dd.pattern_loading : false,
            )
            design.slabs[slab_idx] = _copy_method_notice!(fallback, dd)
            continue
        end
        r_raw = slab.result   # FlatPlatePanelResult (or other AbstractFloorResult)
        # Defensive unwrap: some flows can carry `Pair(idx => result)` payloads.
        r = r_raw isa Pair ? r_raw.second : r_raw
        
        result = SlabDesignResult(
            thickness   = uconvert(u"m",   StructuralSizer.total_depth(r)),
            self_weight = uconvert(u"kPa", StructuralSizer.self_weight(r)),
        )
        
        # ── Core analysis fields ─────────────────────────────────────────
        hasproperty(r, :M0) && (result.M0 = uconvert(u"kN*m", r.M0))
        hasproperty(r, :qu) && (result.qu = uconvert(u"kPa", r.qu))
        
        # ── Deflection ───────────────────────────────────────────────────
        if hasproperty(r, :deflection_check)
            dc = r.deflection_check
            result.deflection_ok    = dc.ok
            result.deflection_ratio = dc.ratio
            if hasproperty(dc, :Δ_check)          # flat plate / flat slab (Unitful)
                result.deflection_in       = ustrip(u"inch", dc.Δ_check)
                result.deflection_limit_in = ustrip(u"inch", dc.Δ_limit)
            elseif hasproperty(dc, :δ)             # vault (dimensionless metres)
                result.deflection_in       = ustrip(u"inch", dc.δ * u"m")
                result.deflection_limit_in = ustrip(u"inch", dc.limit * u"m")
            end
        end
        
        # ── Punching shear ───────────────────────────────────────────────
        if hasproperty(r, :punching_check)
            pc = r.punching_check
            result.punching_ok        = pc.ok
            result.punching_max_ratio = pc.max_ratio
            if hasproperty(pc, :details) && !isempty(pc.details)
                result.punching_vu_max_psi = maximum(
                    ustrip(u"psi", v.vu) for v in values(pc.details); init = 0.0)
                _has_stud(v) = hasproperty(v, :studs) && !isnothing(v.studs)
                result.has_studs   = any(_has_stud(v) for v in values(pc.details))
                result.n_stud_cols = count(_has_stud, values(pc.details))
                for v in values(pc.details)
                    _has_stud(v) || continue
                    s = v.studs
                    if s.n_rails > result.stud_rails_max
                        result.stud_rails_max    = s.n_rails
                        result.stud_per_rail_max = s.n_studs_per_rail
                    end
                end
            end
        end
        
        # ── Convergence / pattern loading (from size_flat_plate! NamedTuple) ──
        dd = hasproperty(slab, :design_details) ? slab.design_details : nothing
        if !isnothing(dd)
            hasproperty(dd, :converged)       && !isnothing(dd.converged)       && (result.converged       = dd.converged)
            hasproperty(dd, :failure_reason)  && !isnothing(dd.failure_reason)  && (result.failure_reason  = dd.failure_reason)
            hasproperty(dd, :failing_check)   && !isnothing(dd.failing_check)   && (result.failing_check   = dd.failing_check)
            hasproperty(dd, :iterations)      && !isnothing(dd.iterations)      && (result.iterations      = dd.iterations)
            hasproperty(dd, :pattern_loading) && !isnothing(dd.pattern_loading) && (result.pattern_loading = dd.pattern_loading)
            hasproperty(dd, :analysis_status) && (result.analysis_status = string(dd.analysis_status))
            _capture_shell_reinforcement!(result, dd)
        end
        
        # ── Rich design details (column ρg, integrity, transfer, etc.) ───
        if !isnothing(dd)
            # Column ρg
            if hasproperty(dd, :column_results) && !isnothing(dd.column_results)
                ρg_vals = [v.ρg for v in values(dd.column_results)]
                result.col_rho_max = isempty(ρg_vals) ? 0.0 : maximum(ρg_vals)
            end
            
            # Integrity check (ACI 8.7.4.2)
            if hasproperty(dd, :integrity_check) && !isnothing(dd.integrity_check)
                result.integrity_ok = dd.integrity_check.ok
            end
            
            # Transfer reinforcement (ACI 8.4.2.3)
            if hasproperty(dd, :transfer_results) && !isnothing(dd.transfer_results)
                result.n_transfer_bars_additional = sum(
                    isnothing(tr) ? 0 : tr.n_bars_additional
                    for tr in dd.transfer_results; init = 0)
            end
            
            # ρ′ for long-term deflection
            if hasproperty(dd, :ρ_prime) && !isnothing(dd.ρ_prime)
                result.ρ_prime = dd.ρ_prime
            end
            
            # Drop panel geometry
            dp = hasproperty(dd, :drop_panel) ? dd.drop_panel : nothing
            if !isnothing(dp)
                result.h_drop_in  = ustrip(u"inch", dp.h_drop)
                result.a_drop1_ft = ustrip(u"ft",   dp.a_drop_1)
                result.a_drop2_ft = ustrip(u"ft",   dp.a_drop_2)
            end
        end

        # Capture mutable slab fields that restore! will wipe.
        # The serializer and engineering report run after restore!, so they must
        # read these from the SlabDesignResult rather than from slab.* on the
        # live structure.
        result.drop_panel = slab.drop_panel
        _copy_method_notice!(result, dd)
        result.is_vault = r isa StructuralSizer.VaultResult
        if result.is_vault
            result.vault_rise = uconvert(u"m", r.rise)
            result.vault_stress_ok = r.stress_check.ok
            result.vault_kern_ok = r.kern_check.ok
            result.converged = r.convergence_check.converged
        end
        result.sizer_result = r
        record_solid_head_punching!(result, struc, slab, design.params; frame = head_frame)

        design.slabs[slab_idx] = result
    end
end

"""
    _steel_column_φMnx(sec, Lb; Cb=1.0) -> Union{Float64, Nothing}

Chapter F strong-axis `φMn` [N·m] at the member unbraced length — the same
`get_ϕMn(; Lb, Cb, axis=:strong)` the sizer uses (AISC 360-16 §F2.2,
corpus: aisc-360-16, page 103).  Returns `nothing` if material is missing
or `get_ϕMn` is unsupported.
"""
function _steel_column_φMnx(sec, Lb; Cb::Float64 = 1.0,
                            material = nothing)::Union{Float64, Nothing}
    # A catalog W-shape often stores no material. The caller passes the
    # design steel, the same metal the sizer checked.
    mat = material !== nothing ? material :
          (hasproperty(sec, :material) ? sec.material : nothing)
    mat === nothing && return nothing
    try
        return ustrip(u"N*m", StructuralSizer.get_ϕMn(sec, mat;
                                                       Lb = Lb, Cb = Cb, axis = :strong))
    catch e
        if e isa MethodError || (isdefined(Base, :FieldError) && e isa Base.FieldError)
            return nothing
        end
        rethrow()
    end
end

"""
    _steel_column_ϕPnc(sec, L; Kx=1.0, Ky=1.0) -> Union{Float64, Nothing}

Screening-diagnostic design axial compressive strength `ϕPnc` [N] for a steel
column, governed by FLEXURAL BUCKLING (AISC 360-16 §E3), not gross yield.

This reuses the SAME vetted routine the feasibility checker uses
(`StructuralSizer.get_ϕPn`, `AISCChecker.is_feasible`): it takes
`ϕPnc = min(ϕPn_x, ϕPn_y, ϕPn_z)` over strong-axis flexural (§E3, Eq. E3-2/E3-3),
weak-axis flexural (§E3), and torsional (§E4) buckling, with the resistance
factor `φc = 0.90` (§E1). NO limit-state equation is defined or recomputed here —
this is read/reuse of the Chapter E code.

`L` is the column's real (unbraced) length; effective lengths are
`Lc_x = Kx·L` and `Lc_y = Ky·L`, and the torsional check is evaluated at `Lc_y`,
mirroring `AISCChecker.is_feasible` exactly (which passes `Lc_y` to the
`:torsional` axis). All three steel section types (`ISymmSection`,
`HSSRectSection`, `HSSRoundSection`) have a `get_ϕPn` method; the HSS methods map
`:torsional` onto `:weak`.

Returns `nothing` ONLY when the section type/axis is genuinely unsupported by
`get_ϕPn` — a `MethodError` (e.g. a non-`Metal` material, or arithmetic on an
unpopulated `Cw`/`J` field of a built-up `ISymmSection`) or a missing-field
access. Any OTHER exception is re-thrown so real bugs surface rather than being
silently swallowed. The caller treats `nothing` as UNVERIFIED (a NaN sentinel),
NOT as a safe capacity — it must never fall back to an unconservative estimate.

# Citations
- AISC 360-16 §E3 (Eq. E3-2/E3-3) flexural buckling, §E4 torsional buckling,
  §E7 effective area, §E1 `φc = 0.90` (corpus: aisc-360-16, §E3 p.35, §E1 p.33).
  Implemented in `StructuralSizer.get_ϕPn` — reused here, not re-derived.
"""
function _steel_column_ϕPnc(sec, L; Kx::Float64 = 1.0, Ky::Float64 = 1.0,
                           material = nothing)::Union{Float64, Nothing}
    mat = material !== nothing ? material :
          (hasproperty(sec, :material) ? sec.material : nothing)
    mat === nothing && return nothing
    try
        Lc_x = Kx * L
        Lc_y = Ky * L
        # Mirror AISCChecker.is_feasible: min over strong/weak flexural (§E3) and
        # torsional (§E4). Torsional axis uses Lc_y, exactly as the checker does.
        ϕPn_x = ustrip(u"N", StructuralSizer.get_ϕPn(sec, mat, Lc_x; axis = :strong))
        ϕPn_y = ustrip(u"N", StructuralSizer.get_ϕPn(sec, mat, Lc_y; axis = :weak))
        ϕPn_z = ustrip(u"N", StructuralSizer.get_ϕPn(sec, mat, Lc_y; axis = :torsional))
        return min(ϕPn_x, ϕPn_y, ϕPn_z)
    catch e
        # Narrow catch: only the genuinely-unsupported cases degrade to `nothing`.
        # A `MethodError` covers a non-`Metal` material and arithmetic on an
        # unpopulated `Cw`/`J` (`nothing`) field; a `FieldError` (Julia ≥ 1.11)
        # covers a section type that lacks a field `get_ϕPn` needs. Anything else
        # is a genuine bug and is re-thrown so it is not silently swallowed.
        if e isa MethodError || (isdefined(Base, :FieldError) && e isa Base.FieldError)
            @debug "Steel column ϕPn diagnostic unsupported for this section/axis" exception = (e, catch_backtrace())
            return nothing
        end
        rethrow()
    end
end

"""Populate column design results from struc.columns.

Extracts axial and moment demands from the Asap model, merges punching shear
results from slab design, and computes approximate capacity ratios.
"""
function _populate_column_results!(design::BuildingDesign, struc::BuildingStructure)
    params = design.params
    
    # ─── Build column-to-punching lookup from slab results ───
    # slab.result.punching_check.details is a Dict{Int, NamedTuple} keyed by column idx
    punch_map = Dict{Int, NamedTuple}()  # col_idx → punching NamedTuple
    for slab in struc.slabs
        r = slab.result
        isnothing(r) && continue
        hasproperty(r, :punching_check) || continue
        pc = r.punching_check
        hasproperty(pc, :details) || continue
        for (cidx, pr) in pc.details
            # Keep the worst ratio if a column appears in multiple panels
            if !haskey(punch_map, cidx) || pr.ratio > punch_map[cidx].ratio
                punch_map[cidx] = pr
            end
        end
    end
    
    has_model = !isnothing(struc.asap_model) && !isempty(struc.asap_model.frame_elements)
    # Columns a flat-plate slab reports get the P-M check under the full
    # building load; the frame's moments there come from placeholder beams.
    rc_opts = _flat_plate_column_opts(params)
    fp_checks = has_model ? flat_plate_column_checks(struc, rc_opts; params) : Dict{Int, NamedTuple}()
    fp_supported = flat_plate_supported_columns(struc)
    # The stacking policy is applied by the flat-plate column check only.
    nonmonotone = intersect(Set(_non_monotone_columns(struc)), fp_supported)
    mismatched = intersect(Set(_mismatched_stack_columns(struc)), fp_supported)
    # Same full-load + pattern envelope the column sizer reads.
    col_envs = has_model ? column_force_envelopes(struc, params) : Dict{Int, NamedTuple}()

    for (col_idx, col) in enumerate(struc.columns)
        result = ColumnDesignResult()
        
        # ─── Section size & geometry ───
        col_sec = section(col)
        result.section_obj = col_sec
        result.shape = hasproperty(col, :shape) ? col.shape : :rectangular

        if !isnothing(col.c1) && !isnothing(col.c2)
            result.c1 = uconvert(u"m", col.c1)
            result.c2 = uconvert(u"m", col.c2)
        end

        # Section name: use the section object's name for steel/PixelFrame, else c1×c2
        if !isnothing(col_sec) && hasproperty(col_sec, :name) && !isnothing(col_sec.name)
            result.section_size = col_sec.name
        elseif result.shape == :circular && !isnothing(col.c1)
            D_in = round(ustrip(u"inch", col.c1); digits=1)
            result.section_size = "⌀$(D_in)\""
        elseif !isnothing(col.c1) && !isnothing(col.c2)
            c1_in = round(Int, ustrip(u"inch", col.c1))
            c2_in = round(Int, ustrip(u"inch", col.c2))
            result.section_size = "$(c1_in)×$(c2_in)"
        end
        
        # ─── Material takeoff fields ───
        col_L = member_length(col)
        result.height = col_L isa Unitful.Quantity ? uconvert(u"m", col_L) : col_L * u"m"
        if !isnothing(col.c1) && !isnothing(col.c2)
            if result.shape == :circular
                result.Ag = uconvert(u"m^2", π / 4 * col.c1^2)
            else
                result.Ag = uconvert(u"m^2", col.c1 * col.c2)
            end
        end
        if !isnothing(col_sec) && hasproperty(col_sec, :As_total)
            result.As_total = uconvert(u"m^2", col_sec.As_total)
            result.rho_g = hasproperty(col_sec, :ρg) ? col_sec.ρg : 0.0
        end
        
        # ─── Demands from Asap model ───
        # Extract peak axial force and moments from solved element forces.
        # el.forces layout (12-DOF 3D frame):
        #   [Fx1, Fy1, Fz1, Mx1, My1, Mz1, Fx2, Fy2, Fz2, Mx2, My2, Mz2]
        # Sign convention: compression is negative in Asap.
        if has_model
            Pu_N = 0.0; Mu_x_Nm = 0.0; Mu_y_Nm = 0.0
            # Shear. Fy (indices 2, 8) and Fz (indices 3, 9). Compression is
            # negative, so Nu = −max(Fx1, Fx2) is the lesser end compression,
            # compression-positive. The peaks are enveloped across segments
            # and are not required to be concurrent; that pairing is
            # conservative. Which of Fy and Fz is parallel to the section
            # width is not stored on the element, so both assignments are
            # checked below and the worse one is kept. That axis choice is
            # engineering judgment, not a code rule. A square section makes
            # the two assignments the same.
            Vu_fy = 0.0; Vu_fz = 0.0; Nu_N = Inf; saw_force = false
            for seg_idx in segment_indices(col)
                seg = struc.segments[seg_idx]
                eidx = seg.edge_idx
                (eidx < 1 || eidx > length(struc.asap_model.frame_elements)) && continue
                el = struc.asap_model.frame_elements[eidx]
                isempty(el.forces) && continue
                f = el.forces
                n = length(f)
                saw_force = true
                
                # Axial: largest end compression (negative in Asap). A
                # tensile end is not compression.
                Pu_N = max(Pu_N, -f[1])
                if n >= 7; Pu_N = max(Pu_N, -f[7]); end
                
                # Moment about local y (indices 5, 11), reported as Mu_x
                if n >= 5;  Mu_x_Nm = max(Mu_x_Nm, abs(f[5])); end
                if n >= 11; Mu_x_Nm = max(Mu_x_Nm, abs(f[11])); end
                
                # Moment about local z (indices 6, 12), reported as Mu_y
                if n >= 6;  Mu_y_Nm = max(Mu_y_Nm, abs(f[6])); end
                if n >= 12; Mu_y_Nm = max(Mu_y_Nm, abs(f[12])); end

                # Shears, and the least compression (a tensile end is negative).
                if n >= 3
                    Vu_fy = max(Vu_fy, abs(f[2]))
                    Vu_fz = max(Vu_fz, abs(f[3]))
                    Nu_N = min(Nu_N, -f[1])
                end
                if n >= 9
                    Vu_fy = max(Vu_fy, abs(f[8]))
                    Vu_fz = max(Vu_fz, abs(f[9]))
                    Nu_N = min(Nu_N, -f[7])
                end
            end
            saw_force || (Nu_N = 0.0)
            isfinite(Nu_N) || (Nu_N = 0.0)
            # The sizing envelope includes the pattern cases; the element
            # forces above are the full-load solve only.
            if haskey(col_envs, col_idx)
                env = col_envs[col_idx]
                Pu_N = max(Pu_N, env.Pu)
                Mu_x_Nm = max(Mu_x_Nm, env.My)
                Mu_y_Nm = max(Mu_y_Nm, env.Mz)
            end
            
            result.Pu   = Pu_N * u"N" |> u"kN"
            result.Mu_x = Mu_x_Nm * u"N*m" |> u"kN*m"
            result.Mu_y = Mu_y_Nm * u"N*m" |> u"kN*m"
        end
        
        # ─── Approximate capacity ratios ───
        is_steel = col_sec isa StructuralSizer.ISymmSection ||
                   col_sec isa StructuralSizer.HSSRectSection ||
                   col_sec isa StructuralSizer.HSSRoundSection

        Pu_N_val = ustrip(u"N", result.Pu)
        # About local y and z. A steel section's strong axis is local y in the
        # frame; an RC check tries both assignments instead.
        Mu_Nm_val = ustrip(u"N*m", result.Mu_x)
        Mu_y_Nm_val = ustrip(u"N*m", result.Mu_y)

        design_steel = params.materials.steel
        if is_steel && hasproperty(col_sec, :A) &&
           (col_sec.material isa StructuralSizer.Metal || design_steel isa StructuralSizer.Metal)
            # ─── Steel column axial capacity — AISC 360-16 Chapter E ───
            # The governing limit state is FLEXURAL BUCKLING (§E3, Eq. E3-2/E3-3),
            # NOT gross yield. Columns do not retain the engine's sized capacity
            # (neither `Column` nor `ColumnDesignResult` stores a sizer_result or a
            # cached ϕPn/utilization), so the screening ratio is recomputed here
            # with the SAME vetted routine the feasibility check uses —
            # `StructuralSizer.get_ϕPn` (φc = 0.90), taking the minimum over
            # strong/weak flexural (§E3) and torsional (§E4) buckling
            # (see `_steel_column_ϕPnc` and `AISCChecker.is_feasible`). This is
            # read/reuse of the Chapter E limit-state code, not a new equation.
            # (corpus: aisc-360-16 — §E3 p.35, §E1 φc=0.90 p.33.)
            # Prefer the engine's real effective-length factors. `MemberBase`
            # defaults Kx = Ky = 1.0 (braced frame); the real feasibility check
            # uses these SAME Kx/Ky, so this screening ratio tracks it.
            Kx = col.base.Kx
            Ky = col.base.Ky
            # A catalog shape often carries no material. The design's steel is
            # the one the sizer used.
            steel = params.materials.steel
            mat = col_sec.material isa StructuralSizer.Metal ? col_sec.material :
                  (steel isa StructuralSizer.Metal ? steel : nothing)
            Fy_Pa = ustrip(u"Pa", mat.Fy)
            ϕPnc = _steel_column_ϕPnc(col_sec, result.height; Kx = Kx, Ky = Ky,
                                      material = mat)

            if isnothing(ϕPnc)
                # SAFETY — no silent unconservative fallback. The §E3/§E4 buckling
                # capacity could not be evaluated for this section (e.g. an
                # unsupported/built-up `ISymmSection` with unpopulated `Cw`/`J`, or
                # a non-`Metal` material — see `_steel_column_ϕPnc`). We DELIBERATELY
                # do NOT substitute the gross-yield upper bound φPn = 0.9·Fy·Ag:
                # that ignores buckling, so it would silently reinstate an
                # unconservative capacity and could render an unsafe column "OK".
                # Instead the axial capacity and P-M interaction are marked
                # UNVERIFIED with a NaN sentinel. Because `NaN ≤ 1.0` is `false`,
                # `result.ok` (below) cannot become `true`, and the governing-check
                # / global-ratio paths treat NaN as not-verified rather than
                # passing. (corpus: aisc-360-16 — §E3 p.35, §E4/§E7.)
                @warn "Steel column ϕPn (AISC §E3/§E4) unavailable — axial capacity marked UNVERIFIED (NaN), not gross-yield fallback" col_idx section=result.section_size maxlog=8
                result.axial_ratio = NaN
                result.interaction_ratio = NaN
            else
                φPn = ϕPnc  # N — §E3 flexural-buckling design strength (φc = 0.90)
                result.axial_ratio = φPn > 0 ? Pu_N_val / φPn : 0.0

                # Authoritative φMn — same Chapter F routine the sizer uses
                # (`get_ϕMn` with the member `Lb` / `Cb`).  A plastic-Mp
                # screen ignored LTB (§F2.2) and could report ok=true for a
                # long-Lb W-shape the sizer rejects.
                # AISC 360-16 §F2.2 (corpus: aisc-360-16, page 103); φb = 0.90
                # per §F1.
                Lb = col.base.Lb
                Cb = col.base.Cb
                φMnx_sizer = _steel_column_φMnx(col_sec, Lb; Cb = Float64(Cb),
                                                material = mat)
                φMnx = isnothing(φMnx_sizer) ?
                    (hasproperty(col_sec, :Zx) ?
                        0.9 * Fy_Pa * ustrip(u"m^3", col_sec.Zx) : 0.0) :
                    φMnx_sizer
                φMny = try
                    ustrip(u"N*m", StructuralSizer.get_ϕMn(col_sec, mat;
                                                            axis = :weak))
                catch
                    if hasproperty(col_sec, :Zy)
                        Mpy = Fy_Pa * ustrip(u"m^3", col_sec.Zy)
                        if col_sec isa StructuralSizer.ISymmSection && hasproperty(col_sec, :Sy)
                            Mpy = min(Mpy, 1.6 * Fy_Pa * ustrip(u"m^3", col_sec.Sy))
                        end
                        0.9 * Mpy
                    else
                        0.0
                    end
                end

                # Diagnostic P–M screen — AISC 360-16 §H1.1 Eqs. H1-1a/H1-1b
                # (corpus: aisc-360-16, page 133), same `get_ϕMn(Lb,Cb)` Chapter F
                # φMn the sizer uses.  It still OMITS B1 P-δ (App. 8).  Authoritative
                # `result.ok` is this ratio (and punching), not a plastic-Mp screen.
                Pr_Pc  = φPn  > 0 ? Pu_N_val    / φPn  : 0.0
                Mrx_Mc = φMnx > 0 ? Mu_Nm_val   / φMnx : 0.0
                Mry_Mc = φMny > 0 ? Mu_y_Nm_val / φMny : 0.0
                if Pr_Pc >= 0.2
                    result.interaction_ratio = Pr_Pc + (8.0 / 9.0) * (Mrx_Mc + Mry_Mc)  # Eq. H1-1a
                else
                    result.interaction_ratio = Pr_Pc / 2.0 + Mrx_Mc + Mry_Mc            # Eq. H1-1b
                end
            end

        elseif is_steel
            # SAFETY — steel section that FAILS the capacity-input guard above (missing `:A`,
            # missing `:material`, or `material === nothing`). Such a section is NOT RC either,
            # so without this branch NEITHER path would run and `axial_ratio`/`interaction_ratio`
            # would keep their struct default `0.0` → `result.ok = true` → a steel column would
            # SILENTLY PASS at ratio 0 with NO capacity check. Route it to the SAME UNVERIFIED
            # sentinel as the `isnothing(ϕPnc)` case: mark axial/P-M as NaN so `result.ok` cannot
            # become `true` (NaN ≤ 1.0 is `false`) and the diagnose/summary paths label it
            # `axial_compression_unverified`. We deliberately do NOT substitute the gross-yield
            # bound φPn = 0.9·Fy·Ag (it ignores buckling and could render an unsafe column "OK").
            # (corpus: aisc-360-16 — §E3 p.35, §E4/§E7; same rationale as the ϕPnc-unavailable case.)
            @warn "Steel column capacity inputs unavailable (missing area/material) — axial capacity marked UNVERIFIED (NaN), not gross-yield fallback" col_idx section=result.section_size maxlog=8
            result.axial_ratio = NaN
            result.interaction_ratio = NaN

        elseif !is_steel && !isnothing(col.c1) && !isnothing(col.c2)
            # Flat-plate buildings: the full-load check, which also covers
            # RC columns no flat-plate slab bears on (frame forces). A
            # flat-plate column that check did not reach has no trustworthy
            # moment (the frame's beam lines are placeholders) and stays
            # unverified. Any other RC column is checked under its frame forces.
            c = if haskey(fp_checks, col_idx)
                fp_checks[col_idx]
            elseif haskey(col_envs, col_idx) && !(col_idx in fp_supported)
                rc_frame_column_check(col, rc_opts, frame_column_demand(col_envs[col_idx]))
            else
                nothing
            end

            if c === nothing
                @warn "RC column has no strength check (no full-load flat-plate check, no frame forces, or a non-RC section); marked unverified" col_idx maxlog=8
                result.axial_ratio = NaN
                result.interaction_ratio = NaN
            else
                if haskey(fp_checks, col_idx)
                    kipft = Asap.kip * u"ft"
                    result.Mu_x = uconvert(u"kN*m", c.demand.M2x * kipft)
                    result.Mu_y = uconvert(u"kN*m", c.demand.M2y * kipft)
                end
                result.axial_ratio = isnan(c.axial_ratio) ? NaN :
                    (c.passed ? min(c.axial_ratio, 1.0) : c.axial_ratio)
                # `passed` is the sizer's test, whose interaction tolerance
                # can leave the reported ratio a hair above 1.
                result.interaction_ratio = c.passed ? min(c.governing_ratio, 1.0) :
                    max(c.governing_ratio, nextfloat(1.0))
            end
        end
        
        # ─── Punching shear from slab results ───
        trib_area = column_tributary_area(struc, col)
        trib_area_m2 = !isnothing(trib_area) ? uconvert(u"m^2", trib_area) : 0.0u"m^2"
        
        if haskey(punch_map, col_idx)
            pr = punch_map[col_idx]
            # Convert slab punching NamedTuple → PunchingDesignResult
            vu = ustrip(u"Pa", pr.vu)
            φvc = ustrip(u"Pa", pr.φvc)
            b0_m = ustrip(u"m", pr.b0)
            d_est = !isnothing(col.c1) ? 0.8 * ustrip(u"m", col.c1) : 0.15  # rough
            
            # Back-compute Vu = vu × b0 × d  (approximate, for display only)
            Vu_N = vu * b0_m * d_est
            φVc_N = φvc * b0_m * d_est
            
            result.punching = PunchingDesignResult(
                Vu = Vu_N * u"N" |> u"kN",
                φVc = φVc_N * u"N" |> u"kN",
                ratio = pr.ratio,
                ok = pr.ok,
                critical_perimeter = pr.b0 |> u"m",
                tributary_area = trib_area_m2,
                Mub = hasproperty(pr, :Mub) ? uconvert(u"kN*m", pr.Mub) : 0.0u"kN*m",
            )
        elseif !isnothing(trib_area)
            # A flat-plate column with no punching result was never checked.
            # Elsewhere a beam or wall takes the slab, and punching does not apply.
            unchecked = col_idx in fp_supported
            result.punching = PunchingDesignResult(
                Vu = 0.0u"kN", φVc = 0.0u"kN",
                ratio = unchecked ? NaN : 0.0, ok = !unchecked,
                critical_perimeter = 0.0u"m",
                tributary_area = trib_area_m2,
            )
        end
        
        # ─── One-way shear for an RC section (ACI 318-19 §10.5.3.1) ───
        # Steel keeps the default shear_ok = true. There is no AISC shear
        # check on this path.
        if has_model && (col_sec isa StructuralSizer.RCColumnSection ||
                         col_sec isa StructuralSizer.RCCircularSection)
            _assign_column_shear!(result, col_sec, col, params, Vu_fy, Vu_fz, Nu_N)
        end

        # ─── Overall ok ───
        # The sizer's explanation is the check that chose the section. It
        # replaces an unverified Chapter E screen (a shape with no material).
        sizer = member_check(col)
        sizer === nothing || _apply_column_sizer_check!(result, sizer)
        frame = _assign_seismic_frame!(result, struc, :column, col_idx)
        screen_ok = result.axial_ratio ≤ 1.0 &&
                    result.interaction_ratio ≤ 1.0 &&
                    result.shear_ok &&
                    (isnothing(result.punching) || result.punching.ok) &&
                    (frame === nothing || frame.passed)
        result.ok = sizer === nothing ? screen_ok :
                    (sizer.passed && result.shear_ok &&
                     (isnothing(result.punching) || result.punching.ok) &&
                     (frame === nothing || frame.passed))
        _note_under_frame_floor!(result, col, struc, params)

        if haskey(fp_checks, col_idx) && haskey(struc.stage_diagnostics, :flat_plate_columns)
            push!(result.notes, "full-load column check did not settle")
        end
        col_idx in nonmonotone &&
            push!(result.notes, "smaller than the column above (stack not monotone)")
        col_idx in mismatched &&
            push!(result.notes, "column above has a different shape or rotation; stack sizes not compared")
        
        design.columns[col_idx] = result
    end
    isempty(nonmonotone) || push!(design.diagnostics,
        "Columns smaller than the column above (stack not monotone): " *
        join(sort!(collect(nonmonotone)), ", "))
end

"""
Store ACI 318-19 §22.5 shear on an RC column result.

`Vu_fy` and `Vu_fz` are the enveloped `|Fy|` and `|Fz|` from the frame
element. The section's local axes are not on that element, so both ways of
lining them up with `(b, h)` are designed and the higher ratio is kept.
"""
function _assign_column_shear!(result::ColumnDesignResult, col_sec, col, params,
                               Vu_fy::Float64, Vu_fz::Float64, Nu_N::Float64)
    if isempty(col_sec.bars)
        result.shear_ok = false
        result.shear_ratio = 1.0
        result.shear_clause = "ACI 318-19 §22.5; no longitudinal bars, shear was not checked"
        return result
    end
    conc, reb, trans = _column_materials(params, col)
    mat = StructuralSizer.ReinforcedConcreteMaterial(conc, reb, trans)
    Nu = Nu_N * u"N"
    along = StructuralSizer.design_column_shear(col_sec, Vu_fy * u"N", Vu_fz * u"N", Nu, mat)
    swapped = StructuralSizer.design_column_shear(col_sec, Vu_fz * u"N", Vu_fy * u"N", Nu, mat)
    if along.ratio >= swapped.ratio
        shear = along
        result.Vu_x = (Vu_fy * u"N") |> u"kN"
        result.Vu_y = (Vu_fz * u"N") |> u"kN"
    else
        shear = swapped
        result.Vu_x = (Vu_fz * u"N") |> u"kN"
        result.Vu_y = (Vu_fy * u"N") |> u"kN"
    end
    result.ϕVn_x = uconvert(u"kN", shear.ϕVn_x)
    result.ϕVn_y = uconvert(u"kN", shear.ϕVn_y)
    result.shear_ratio = shear.ratio
    result.shear_ok = shear.ok
    result.tie_spacing = uconvert(u"m", shear.spacing)
    result.tie_bar_size = shear.tie_bar_size
    result.shear_clause = shear.clause
    return result
end

"""
    _section_label(sec) -> String

Display name of a sized section: its catalog or generated `name` when it has
one (e.g. `"W16X40"`, `"10x12-2#5"`), otherwise `string(sec)`.
"""
function _section_label(sec)
    name = hasproperty(sec, :name) ? getproperty(sec, :name) : nothing
    return name isa AbstractString && !isempty(name) ? String(name) : string(sec)
end

"""Populate beam design results from struc.beams with forces from the Asap model."""
function _populate_beam_results!(design::BuildingDesign, struc::BuildingStructure)
    has_model = !isnothing(struc.asap_model) && !isempty(struc.asap_model.frame_elements)
    el_loads_map = has_model ? Asap.get_elemental_loads(struc.asap_model) : nothing

    for (beam_idx, beam) in enumerate(struc.beams)
        result = BeamDesignResult()
        sec = section(beam)
        result.section_obj = sec
        if !isnothing(sec)
            result.section_size = _section_label(sec)
        end

        # Member length for material takeoff
        L_total = member_length(beam)
        result.member_length = L_total isa Unitful.Quantity ? uconvert(u"m", L_total) : L_total * u"m"

        # Extract peak Mu, Vu from Asap internal forces
        if has_model
            Mu_Nm = 0.0; Vu_N = 0.0
            for seg_idx in segment_indices(beam)
                seg = struc.segments[seg_idx]
                eidx = seg.edge_idx
                (eidx < 1 || eidx > length(struc.asap_model.frame_elements)) && continue
                el = struc.asap_model.frame_elements[eidx]
                eid = el.elementID
                loads = (eid >= 1 && eid <= length(el_loads_map)) ? el_loads_map[eid] : Asap.AbstractLoad[]
                if !isempty(loads)
                    fd = Asap.ElementForceAndDisplacement(el, loads; resolution=20)
                    fr = fd.forces
                    peaks = _strong_weak_peaks(fr.My, fr.Vy, fr.Mz, fr.Vz)
                    Mu_Nm = max(Mu_Nm, peaks.Mu)
                    Vu_N  = max(Vu_N,  peaks.Vu)
                elseif !isempty(el.forces)
                    # Local end forces only (member loads are absent on this branch).
                    peaks = _strong_weak_peaks(el.forces)
                    Mu_Nm = max(Mu_Nm, peaks.Mu)
                    Vu_N  = max(Vu_N,  peaks.Vu)
                end
            end
            result.Mu = Mu_Nm * u"N*m" |> u"kN*m"
            result.Vu = Vu_N  * u"N"   |> u"kN"
        end

        # Approximate capacity ratios and weight for steel sections
        vols = volumes(beam)
        mat = isempty(vols) ? nothing : first(keys(vols))
        if !isnothing(sec) && hasproperty(sec, :A) && !isnothing(mat) && mat isa StructuralSizer.Metal
            wpl = StructuralSizer.weight_per_length(sec, mat)
            result.weight = uconvert(u"kg", wpl * result.member_length)

            # Flexure capacity: φMn ≈ 0.9 × Fy × Zx (plastic moment, AISC F2-1)
            if hasproperty(sec, :Zx)
                Fy = mat.Fy
                φMn = 0.9 * Fy * sec.Zx
                φMn_kNm = ustrip(u"kN*m", φMn)
                Mu_kNm = ustrip(u"kN*m", result.Mu)
                result.flexure_ratio = φMn_kNm > 0 ? Mu_kNm / φMn_kNm : 0.0
            end

            # Shear capacity: φVn ≈ 1.0 × 0.6 × Fy × Aw (AISC G2, rolled I-shapes)
            if hasproperty(sec, :d) && hasproperty(sec, :tw)
                Aw = sec.d * sec.tw
                φVn = 1.0 * 0.6 * mat.Fy * Aw
                φVn_kN = ustrip(u"kN", φVn)
                Vu_kN = ustrip(u"kN", result.Vu)
                result.shear_ratio = φVn_kN > 0 ? Vu_kN / φVn_kN : 0.0
            end
        end

        # The sizer's own checks replace the estimate when it reported them:
        # they include LTB, composite action, the pattern envelope, and
        # deflection. Otherwise the ratios above are a plastic-moment and
        # web-shear estimate on the full-load forces, reported only.
        expl = member_check(beam)
        expl === nothing || _apply_beam_check!(result, expl)
        # A sized beam's verdict is its sizer's: the member loop ends at a
        # fixed point where every beam passed its checks on the final
        # analysis, and records `:members` when it did not.
        frame = _assign_seismic_frame!(result, struc, :beam, beam_idx)
        result.ok = (isnothing(sec) ?
            (result.flexure_ratio ≤ 1.0 && result.shear_ratio ≤ 1.0) :
            !haskey(struc.stage_diagnostics, :members)) &&
            (frame === nothing || frame.passed)
        design.beams[beam_idx] = result
    end
end

_is_shear_check(name) = (startswith(name, "shear") && name != "shear_anchors") ||
                        name == "construction_shear"
_is_flexure_check(name) = occursin("flexure", name) || startswith(name, "pm_interaction")

"""Copy the row F frame check for this member onto `result`, or `nothing` when it was not checked."""
function _assign_seismic_frame!(result, struc, kind::Symbol, index::Int)
    wall = struc.ordinary_wall_result
    wall === nothing && return nothing
    hasproperty(wall, :frame_members) || return nothing
    found = nothing
    for c in wall.frame_members
        if c.kind === kind && c.index == index
            found = c
            break
        end
    end
    found === nothing && return nothing
    result.seismic_frame = SeismicFrameCheck(
        passed = found.passed,
        governing_check = found.governing_check,
        ratio = found.governing_ratio,
        case_label = found.case_label,
        detail = found.detail,
    )
    return found
end

"""
Note a column whose installed section is lighter than its row F floor.

Uniform sizing can keep a column's bars on a larger cross-section, which drops
the steel below the section the frame check accepted. The next frame check
still fails that column; the note says so on the result.
"""
function _note_under_frame_floor!(result::ColumnDesignResult, col, struc, params)
    opts = params.columns
    opts isa StructuralSizer.ConcreteColumnOptions || return result
    gid = group_id(col)
    gid === nothing && return result
    floor = get(struc.frame_section_floors, gid, nothing)
    floor === nothing && return result
    sec = section(col)
    (sec === nothing || _sections_identical(sec, floor)) && return result
    under = false
    try
        obj = s -> StructuralSizer.objective_value(opts.objective, s, opts.material, 1.0u"m")
        under = obj(sec) < obj(floor) * (1 - 1e-9)
        if !under && hasproperty(sec, :As_total) && hasproperty(floor, :As_total)
            As = ustrip(u"m^2", sec.As_total)
            Af = ustrip(u"m^2", floor.As_total)
            under = As < Af * (1 - 1e-9) && obj(sec) <= obj(floor) * (1 + 1e-9)
        end
    catch
        under = false
    end
    under && push!(result.notes, "section is lighter than the row F floor for this group")
    return result
end

"""Copy the sizer's governing check, and its largest flexural and shear ratios, onto `result`."""
function _apply_beam_check!(result::BeamDesignResult, expl::StructuralSizer.FeasibilityExplanation)
    result.governing_check = expl.governing_check
    result.governing_ratio = expl.governing_ratio
    gov = findfirst(c -> c.name == expl.governing_check, expl.checks)
    if gov !== nothing
        c = expl.checks[gov]
        result.governing_clause = c.code_clause
        result.governing_demand = c.demand
        result.governing_capacity = c.capacity
    end
    result.flexure_ratio = maximum((c.ratio for c in expl.checks if _is_flexure_check(c.name));
                                   init = 0.0)
    result.shear_ratio = maximum((c.ratio for c in expl.checks if _is_shear_check(c.name));
                                 init = 0.0)
    return result
end

"""
Copy the sizer's governing check onto a column result.

The Chapter E screen in this function needs a material on the section. A
catalog W-shape is often stored without one, and that screen then stays
unverified. The sizing pass already checked the section; its explanation is
the record.
"""
function _apply_column_sizer_check!(result::ColumnDesignResult, expl::StructuralSizer.FeasibilityExplanation)
    result.governing_check = expl.governing_check
    result.governing_ratio = expl.governing_ratio
    gov = findfirst(c -> c.name == expl.governing_check, expl.checks)
    gov === nothing || (result.governing_clause = expl.checks[gov].code_clause)
    inter = maximum((c.ratio for c in expl.checks if startswith(c.name, "pm_interaction"));
                    init = NaN)
    isfinite(inter) && (result.interaction_ratio = inter)
    return result
end

"""Populate foundation design results from struc.foundations (all values normalized to SI)."""
function _populate_foundation_results!(design::BuildingDesign, struc::BuildingStructure)
    fdn_params = design.params.foundation_options
    soil = isnothing(fdn_params) ? StructuralSizer.medium_sand : fdn_params.soil
    qa = uconvert(u"kPa", soil.qa)
    any(f -> !isnothing(f.result), struc.foundations) || return

    # Unfactored D+L reactions (ASCE 7-16 §2.4.1 combo 2), the same solve the
    # footings were sized on. Factored reactions are not back-solved.
    R_s = _service_reactions(struc)
    nodes = struc.asap_model.nodes

    for (fdn_idx, fdn) in enumerate(struc.foundations)
        isnothing(fdn.result) && continue

        total_reaction = 0.0u"kN"
        Ps = 0.0u"kN"
        for sup_idx in fdn.support_indices
            sup = struc.supports[sup_idx]
            total_reaction += uconvert(u"kN", sup.forces[3])
            Ps += uconvert(u"kN", R_s[nodes[sup.node_idx].globalID[3]] * u"N")
        end

        gid = isnothing(fdn.group_id) ? 0 : Int(fdn.group_id % typemax(Int))

        r = fdn.result
        fdn_L = uconvert(u"m", StructuralSizer.footing_length(r))
        fdn_W = uconvert(u"m", StructuralSizer.footing_width(r))
        gov_util = StructuralSizer.utilization(r)

        # Per-check ratios come from the design routine. The verdict is its
        # governing utilization.
        chk = StructuralSizer.utilization_checks(r)
        bearing_ratio = if !isnan(chk.bearing)
            chk.bearing
        else
            # Routine did not report bearing: average service pressure
            # Ps / (qa × footprint).
            footprint = fdn_L * fdn_W
            ustrip(u"kPa", qa) > 0 && ustrip(u"m^2", footprint) > 0 ?
                max(ustrip(u"kPa", Ps / footprint) / ustrip(u"kPa", qa), 0.0) : 0.0
        end
        nan0(x) = isnan(x) ? 0.0 : x

        result = FoundationDesignResult(
            length = fdn_L,
            width = fdn_W,
            depth = uconvert(u"m", r.D),
            reaction = total_reaction,
            bearing_ratio = bearing_ratio,
            punching_ratio = nan0(chk.punching),
            one_way_shear_ratio = nan0(chk.one_way_shear),
            governing_ratio = gov_util,
            ok = gov_util <= 1.0,
            concrete_volume = uconvert(u"m^3", StructuralSizer.concrete_volume(r)),
            steel_volume = uconvert(u"m^3", StructuralSizer.steel_volume(r)),
            group_id = gid,
        )

        design.foundations[fdn_idx] = result
    end
end


