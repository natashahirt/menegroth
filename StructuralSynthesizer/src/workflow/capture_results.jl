# =============================================================================
# Internal Helpers
# =============================================================================

"""Infer floor type from floor options."""
_infer_floor_type(opts::StructuralSizer.AbstractFloorOptions) = StructuralSizer.floor_symbol(opts)

"""Column f′c for the initial size estimate. Not the slab concrete."""
function _get_design_fc(params::DesignParameters)
    return resolve_column_concrete(params.materials).fc′
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
        end
        result.sizer_result = r
        
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
function _steel_column_φMnx(sec, Lb; Cb::Float64 = 1.0)::Union{Float64, Nothing}
    (hasproperty(sec, :material) && !isnothing(sec.material)) || return nothing
    try
        return ustrip(u"N*m", StructuralSizer.get_ϕMn(sec, sec.material;
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
function _steel_column_ϕPnc(sec, L; Kx::Float64 = 1.0, Ky::Float64 = 1.0)::Union{Float64, Nothing}
    (hasproperty(sec, :material) && !isnothing(sec.material)) || return nothing
    try
        mat = sec.material
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
    
    # Column concrete and rebar. The slab grade is a different material.
    conc = resolve_column_concrete(params.materials)
    reb  = resolve_column_rebar(params.materials)
    fc′_Pa = ustrip(u"Pa", conc.fc′)
    fy_Pa  = ustrip(u"Pa", reb.Fy)

    has_model = !isnothing(struc.asap_model) && !isempty(struc.asap_model.frame_elements)
    
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
            for seg_idx in segment_indices(col)
                seg = struc.segments[seg_idx]
                eidx = seg.edge_idx
                (eidx < 1 || eidx > length(struc.asap_model.frame_elements)) && continue
                el = struc.asap_model.frame_elements[eidx]
                isempty(el.forces) && continue
                f = el.forces
                n = length(f)
                
                # Axial (max compression magnitude)
                Pu_N = max(Pu_N, abs(f[1]))
                if n >= 7; Pu_N = max(Pu_N, abs(f[7])); end
                
                # Strong-axis moment My (indices 5, 11)
                if n >= 5;  Mu_x_Nm = max(Mu_x_Nm, abs(f[5])); end
                if n >= 11; Mu_x_Nm = max(Mu_x_Nm, abs(f[11])); end
                
                # Weak-axis moment Mz (indices 6, 12)
                if n >= 6;  Mu_y_Nm = max(Mu_y_Nm, abs(f[6])); end
                if n >= 12; Mu_y_Nm = max(Mu_y_Nm, abs(f[12])); end
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
        Mu_Nm_val = ustrip(u"N*m", result.Mu_x)     # strong-axis moment demand
        Mu_y_Nm_val = ustrip(u"N*m", result.Mu_y)   # weak-axis moment demand

        if is_steel && hasproperty(col_sec, :A) && hasproperty(col_sec, :material) &&
           !isnothing(col_sec.material)
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
            Fy_Pa = ustrip(u"Pa", col_sec.material.Fy)

            # Prefer the engine's real effective-length factors. `MemberBase`
            # defaults Kx = Ky = 1.0 (braced frame); the real feasibility check
            # uses these SAME Kx/Ky, so this screening ratio tracks it.
            Kx = col.base.Kx
            Ky = col.base.Ky
            ϕPnc = _steel_column_ϕPnc(col_sec, result.height; Kx = Kx, Ky = Ky)

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
                φMnx_sizer = _steel_column_φMnx(col_sec, Lb; Cb = Float64(Cb))
                φMnx = isnothing(φMnx_sizer) ?
                    (hasproperty(col_sec, :Zx) ?
                        0.9 * Fy_Pa * ustrip(u"m^3", col_sec.Zx) : 0.0) :
                    φMnx_sizer
                φMny = try
                    ustrip(u"N*m", StructuralSizer.get_ϕMn(col_sec, col_sec.material;
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
            # ACI 318-11 Eq. (10-2) — tied RC columns (rectangular or circular)
            Ag = result.shape == :circular ?
                 ustrip(u"m^2", π / 4 * col.c1^2) :
                 ustrip(u"m^2", col.c1 * col.c2)
            Ast = 0.01 * Ag  # §10.9.1 minimum, same assumption as column growth
            φPn0 = _tied_pn_max(Ag, fc′_Pa, fy_Pa)  # N

            result.axial_ratio = φPn0 > 0 ? Pu_N_val / φPn0 : 0.0

            # φMn ≈ 0.9 × fy × Ast × (d − a/2) — rough for rebar at mid-depth
            d_m = result.shape == :circular ?
                  ustrip(u"m", col.c1) :
                  ustrip(u"m", max(col.c1, col.c2))
            b_m = result.shape == :circular ?
                  ustrip(u"m", col.c1) :
                  ustrip(u"m", min(col.c1, col.c2))
            a_est = b_m > 0 ? fy_Pa * Ast / (0.85 * fc′_Pa * b_m) : 0.0
            φMn_est = 0.90 * fy_Pa * Ast * (d_m * 0.4 - a_est / 2)  # N·m

            if φMn_est > 0
                result.interaction_ratio = max(result.axial_ratio, Mu_Nm_val / φMn_est)
            else
                result.interaction_ratio = result.axial_ratio
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
            result.punching = PunchingDesignResult(
                Vu = 0.0u"kN", φVc = 0.0u"kN",
                ratio = 0.0, ok = true,
                critical_perimeter = 0.0u"m",
                tributary_area = trib_area_m2,
            )
        end
        
        # ─── Overall ok ───
        result.ok = result.axial_ratio ≤ 1.0 &&
                    result.interaction_ratio ≤ 1.0 &&
                    (isnothing(result.punching) || result.punching.ok)
        
        design.columns[col_idx] = result
    end
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

        result.ok = result.flexure_ratio ≤ 1.0 && result.shear_ratio ≤ 1.0
        design.beams[beam_idx] = result
    end
end

"""Populate foundation design results from struc.foundations (all values normalized to SI)."""
function _populate_foundation_results!(design::BuildingDesign, struc::BuildingStructure)
    fdn_params = design.params.foundation_options
    soil = isnothing(fdn_params) ? StructuralSizer.medium_sand : fdn_params.soil
    qa = uconvert(u"kPa", soil.qa)

    for (fdn_idx, fdn) in enumerate(struc.foundations)
        isnothing(fdn.result) && continue

        total_reaction = 0.0u"kN"
        for sup_idx in fdn.support_indices
            sup = struc.supports[sup_idx]
            total_reaction += uconvert(u"kN", sup.forces[3])
        end

        gid = isnothing(fdn.group_id) ? 0 : Int(fdn.group_id % typemax(Int))

        r = fdn.result
        fdn_L = uconvert(u"m", StructuralSizer.footing_length(r))
        fdn_W = uconvert(u"m", StructuralSizer.footing_width(r))
        gov_util = StructuralSizer.utilization(r)

        # Re-derive bearing ratio: service reaction / (qa × footprint)
        # The design routine uses service-level Ps, but we only have factored
        # reaction here. Use a 1.4 factor approximation to get service load.
        footprint = fdn_L * fdn_W
        Ps_approx = total_reaction / 1.4  # approximate service from factored
        bearing = if ustrip(u"kPa", qa) > 0 && ustrip(u"m^2", footprint) > 0
            ustrip(u"kPa", Ps_approx / footprint) / ustrip(u"kPa", qa)
        else
            0.0
        end
        bearing_ratio = clamp(bearing, 0.0, gov_util)

        # Punching ratio: if governing utilization exceeds bearing, the
        # difference is attributable to punching shear.
        punching_ratio = gov_util > bearing_ratio ? gov_util : 0.0

        result = FoundationDesignResult(
            length = fdn_L,
            width = fdn_W,
            depth = uconvert(u"m", r.D),
            reaction = total_reaction,
            bearing_ratio = bearing_ratio,
            punching_ratio = punching_ratio,
            ok = gov_util <= 1.0,
            concrete_volume = uconvert(u"m^3", StructuralSizer.concrete_volume(r)),
            steel_volume = uconvert(u"m^3", StructuralSizer.steel_volume(r)),
            group_id = gid,
        )

        design.foundations[fdn_idx] = result
    end
end

"""Axis-aligned bounding box of all slab cell vertices in meters: (xmin, xmax, ymin, ymax)."""
function _slab_bbox_m(struc::BuildingStructure, slab)
    skel = struc.skeleton
    xmin = ymin =  Inf
    xmax = ymax = -Inf
    for ci in slab.cell_indices
        cell = struc.cells[ci]
        for vi in skel.face_vertex_indices[cell.face_idx]
            c = Meshes.coords(skel.vertices[vi])
            x = ustrip(u"m", c.x)
            y = ustrip(u"m", c.y)
            x < xmin && (xmin = x)
            x > xmax && (xmax = x)
            y < ymin && (ymin = y)
            y > ymax && (ymax = y)
        end
    end
    return (xmin=xmin, xmax=xmax, ymin=ymin, ymax=ymax)
end

"""
Trimmed full plan extents (with units) of a drop panel at column center `(cx, cy)`,
clamped to the slab bounding box.  Returns `(a1_eff, a2_eff)` in meters.
"""
function _trimmed_drop_extents_m(dp::StructuralSizer.DropPanelGeometry, cx::Float64, cy::Float64, bbox)
    a1 = ustrip(u"m", dp.a_drop_1)
    a2 = ustrip(u"m", dp.a_drop_2)
    x0 = max(cx - a1, bbox.xmin)
    x1 = min(cx + a1, bbox.xmax)
    y0 = max(cy - a2, bbox.ymin)
    y1 = min(cy + a2, bbox.ymax)
    eff1 = max(x1 - x0, 0.0) * u"m"
    eff2 = max(y1 - y0, 0.0) * u"m"
    return (eff1, eff2)
end

