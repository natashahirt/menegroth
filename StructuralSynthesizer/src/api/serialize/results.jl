# =============================================================================
# API Serialize — BuildingDesign → JSON output structs
#
# All length/volume/mass values are converted to the display system specified
# in design.params.display_units (from params.unit_system: "imperial" or "metric").
# Positions and displacements sent to clients (e.g. Grasshopper) are forced to
# regular length units (ft or m) so the API always returns consistent numeric data.
# =============================================================================

"""Round a number to the given decimal digits (default 3). JSON-safe: Inf/NaN → nothing."""
_round_val(x; digits=3) = isfinite(x) ? round(x; digits=digits) : nothing

"""Return sorted indices of a dict (e.g. design.slabs, design.columns)."""
_sorted_indices(d::AbstractDict) = sort(collect(keys(d)))

"""Convert a length value to display units as Float64. Accepts Number (assumed m) or Quantity.
Throws `ArgumentError` when a non-length quantity is passed into a length field.
Optional `context` (e.g. (node_id=i, position_index=j)) is included for diagnostics."""
function _to_display_length(du::DisplayUnits, value; context=nothing)
    len_unit = du.units[:length]
    if value isa Quantity
        try
            return ustrip(len_unit, uconvert(len_unit, value))
        catch e
            if e isa Unitful.DimensionError
                d = dimension(value)
                msg = context === nothing ?
                      "Expected length (𝐋), got $d in a length output field." :
                      "Expected length (𝐋), got $d in a length output field (context=$(context))."
                throw(ArgumentError(msg))
            end
            rethrow()
        end
    elseif value isa Number
        # Plain numerics are treated as SI meters by API convention.
        return ustrip(len_unit, value * u"m")
    else
        return Float64(value)
    end
end

"""Length unit string for API consumers (e.g. Grasshopper): \"ft\" or \"m\"."""
_length_unit_string(du::DisplayUnits) = du.units[:length] == u"ft" ? "ft" : "m"
_thickness_unit_string(du::DisplayUnits) = du.units[:thickness] == u"inch" ? "in" : "mm"
_volume_unit_string(du::DisplayUnits) = du.units[:volume] == u"ft^3" ? "ft3" : "m3"
_mass_unit_string(du::DisplayUnits) = du.units[:mass] == u"lb" ? "lb" : "kg"

"""
Force a 3D position (or any length-3 vector of numbers/quantities) into Float64s
in display length units. Used so Grasshopper and other clients always receive positions
in consistent units (ft or m). Non-length quantities throw immediately.
"""
function _position_to_display_lengths(du::DisplayUnits, position_vec; node_id=nothing)
    n = length(position_vec)
    out = Vector{Float64}(undef, n)
    for j in 1:n
        ctx = node_id !== nothing ? (node_id=node_id, position_index=j) : (position_index=j,)
        out[j] = _to_display_length(du, position_vec[j]; context=ctx)
    end
    return out
end

"""Convert a Quantity to display unit for a given category (:length, :thickness, :volume, :mass, etc.)."""
_to_display(du::DisplayUnits, category::Symbol, value) =
    ustrip(du.units[category], uconvert(du.units[category], value))

"""
    design_to_json(design::BuildingDesign; geometry_hash::String="") -> APIOutput

Extract a `BuildingDesign` into an `APIOutput` struct ready for JSON serialisation.
Units are converted to the display system specified in `design.params.display_units`.
"""
function design_to_json(design::BuildingDesign; geometry_hash::String="")
    du = design.params.display_units

    slabs = _serialize_slabs(design, du)
    columns = _serialize_columns(design, du)
    beams = _serialize_beams(design, du)
    foundations = _serialize_foundations(design, du)
    walls = _serialize_walls(design)
    seismic_story_drift = _serialize_story_drift(design)
    summary = _serialize_summary(design, du)
    t_vis_start = time()
    visualization = design.params.skip_visualization ? nothing : _serialize_visualization(design, du)
    t_vis = time() - t_vis_start

    phase_timings = copy(design.phase_timings)
    phase_timings["serialize_visualization"] = _round_val(t_vis; digits=3)

    return APIOutput(
        status = "ok",
        compute_time_s = _round_val(design.compute_time_s; digits=3),
        phase_timings = phase_timings,
        length_unit = _length_unit_string(du),
        thickness_unit = _thickness_unit_string(du),
        volume_unit = _volume_unit_string(du),
        mass_unit = _mass_unit_string(du),
        summary = summary,
        slabs = slabs,
        columns = columns,
        beams = beams,
        foundations = foundations,
        walls = walls,
        seismic_story_drift = seismic_story_drift,
        geometry_hash = geometry_hash,
        visualization = visualization,
    )
end

"""Serialize ordinary-wall checks. Demands stay in the checker's units."""
function _serialize_walls(design::BuildingDesign)
    out = APIWallCheck[]
    for idx in sort!(collect(keys(design.walls)))
        for rec in design.walls[idx]
            push!(out, APIWallCheck(
                wall_index = rec.wall_index,
                story = rec.story,
                direction = string(rec.direction),
                case = string(rec.case),
                combination = string(rec.combination),
                alternative = string(rec.alternative),
                check = rec.check,
                passed = rec.passed,
                ratio = rec.ratio,
                demand = rec.demand,
                capacity = rec.capacity,
                clause = rec.clause,
            ))
        end
    end
    return out
end

"""Serialize seismic story-drift comparisons. Lengths stay in metres."""
function _serialize_story_drift(design::BuildingDesign)
    out = APISeismicStoryDrift[]
    for drift in design.seismic_story_drift
        drift isa SeismicStoryDriftCheck || throw(ArgumentError(
            "design_to_json: seismic_story_drift holds $(typeof(drift))."))
        push!(out, APISeismicStoryDrift(
            story = drift.story,
            direction = string(drift.direction),
            torsion = string(drift.torsion),
            drift_m = drift.drift_m,
            allowable_m = drift.allowable_m,
            passes = drift.passes,
        ))
    end
    return out
end

# ─── Slabs ────────────────────────────────────────────────────────────────────

"""Serialize slab design results into `APISlabResult` records."""
function _serialize_slabs(design::BuildingDesign, du::DisplayUnits)
    results = APISlabResult[]
    for idx in _sorted_indices(design.slabs)
        sr = design.slabs[idx]
        t_display = _to_display(du, :thickness, sr.thickness)
        slab_ok = sr.converged && sr.deflection_ok && sr.punching_ok
        raw_reason = sr.failure_reason
        normalized_reason = _normalize_failure_reason(raw_reason)
        normalized_checks = _normalize_failing_checks(sr.failing_check)
        detail = (normalized_reason in ("solver_error", "unknown") && !isempty(raw_reason)) ?
                 raw_reason : nothing
        push!(results, APISlabResult(
            id = idx,
            ok = slab_ok,
            thickness = _round_val(t_display; digits=2),
            converged = sr.converged,
            failure_reason = normalized_reason,
            failing_checks = normalized_checks,
            failure_detail = detail,
            iterations = sr.iterations,
            deflection_ok = sr.deflection_ok,
            deflection_ratio = _round_val(sr.deflection_ratio),
            punching_ok = sr.punching_ok,
            punching_max_ratio = _round_val(sr.punching_max_ratio),
        ))
    end
    return results
end

