# Table 12.2-1 Sections D and E — a dual system: a moment frame and shear walls
# (or a concrete core) share the lateral load in proportion to their rigidities,
# and the moment frame alone is proportioned for at least 25% of the design
# seismic force (ASCE 7-22 §12.2.5.1, corpus: asce-7-22, PDF page 177).
#
# As with Table 12.2-1 row F, the story-shear share check belongs to the dual
# analysis stage (it needs the story shears); this file declares which members
# are in the system and which categories still lack a deformation check. The
# §12.2.5.1 25% rule is enforced in two tiers (decision deci-7d2c3467): a cheap
# story-shear-share proxy inside the sizing loop (`moment_frame_25pct_share`),
# and a separate frame-only capability analysis as the governing gate in the
# stage. The moment frame's members are the ones the user flags
# `lateral_role = :moment_frame`; the core reuses the existing wall FEM.

"""
    prepare_lateral_model!(struc, ::DualSystem) -> struc

Refuse a building that is missing either half of the dual system: the shear
walls / core, or the moment frame (beams and columns). Releases are left to the
material defaults and the user's `lateral_role` flags, so the designated
moment-frame members keep their moment connections while gravity framing stays
pinned (steel) or monolithic (cast-in-place concrete).

# Citation
ASCE 7-22 §12.2.5.1 (corpus: asce-7-22, PDF page 177).
"""
function prepare_lateral_model!(struc, ::DualSystem)
    isempty(struc.walls) && throw(ArgumentError(
        "DualSystem: the building has no shear walls or core. A dual system " *
        "(ASCE 7-22 §12.2.5.1, corpus: asce-7-22, PDF page 177) pairs a moment " *
        "frame with shear walls or braced frames sharing the lateral load."))
    isempty(struc.beams) && throw(ArgumentError(
        "DualSystem: the building has no beams, so there is no moment frame to " *
        "resist its §12.2.5.1 share (≥25%) of the design seismic force."))
    isempty(struc.columns) && throw(ArgumentError(
        "DualSystem: the building has no columns, so there is no moment frame to " *
        "resist its §12.2.5.1 share (≥25%) of the design seismic force."))
    return struc
end

"""
    seismic_members(struc, ::DualSystem) -> (walls, beams, columns)

The whole dual system resists the lateral load: every wall (core), beam, and
column is in the seismic force-resisting system. The §12.2.5.1 moment-frame
subset (the members flagged `lateral_role = :moment_frame`) is identified by the
capability gate, not here.
"""
seismic_members(struc, ::DualSystem) =
    (walls=collect(eachindex(struc.walls)),
     beams=collect(eachindex(struc.beams)),
     columns=collect(eachindex(struc.columns)))

"""
    system_checks(struc, ::DualSystem; seismic_design_category) -> Vector

Deformation-compatibility gate, matching the other systems: ASCE 7-22 §12.12.4
(corpus: asce-7-22, PDF page 195) applies in Seismic Design Categories D, E, and
F and is not yet built, so it refuses there; A, B, and C return no checks. The
§12.2.5.1 25% rule is enforced by the dual analysis stage (story-shear share plus
the frame-only capability gate), not by this hook.
"""
function system_checks(struc, ::DualSystem; seismic_design_category::Symbol)
    sdc = _require_sdc(seismic_design_category)
    sdc in (:D, :E, :F) || return Any[]
    throw(ArgumentError(
        "DualSystem does not yet check ASCE 7-22 §12.12.4 deformation " *
        "compatibility (corpus: asce-7-22, PDF page 195), which applies in " *
        "Seismic Design Categories D, E, and F."))
end

"""Table 12.2-1 dual row (`:D3`, `:D8`, `:D9`, `:E8`) carried by this system."""
table_12_2_1_row(system::DualSystem) = system.row

"""
    moment_frame_25pct_share(frame_shears, total_shears; tol=1e-9)
        -> (satisfies, min_share, worst_story)

Cheap in-loop proxy for ASCE 7-22 §12.2.5.1 (corpus: asce-7-22, PDF page 177):
the moment frame must resist at least 25% of the design seismic force. Given the
per-story shear carried by the moment frame and the total per-story story shear
(same ordering, consistent units) from the *combined* analysis, return whether
every story's frame share is ≥ 25%, the minimum share, and the governing story.

This is a necessary screen, **not** the governing check: a share in the combined
model is not the same as the frame's independent capability. The authoritative
test is the separate frame-only capability analysis run by the dual stage
(decision deci-7d2c3467).
"""
function moment_frame_25pct_share(frame_shears::AbstractVector{<:Real},
                                  total_shears::AbstractVector{<:Real}; tol::Real=1e-9)
    n = length(frame_shears)
    n == length(total_shears) || throw(ArgumentError(
        "moment_frame_25pct_share: frame_shears and total_shears must have equal length; " *
        "got $n and $(length(total_shears))."))
    n == 0 && throw(ArgumentError("moment_frame_25pct_share: no stories supplied."))
    min_share = Inf
    worst = 0
    @inbounds for i in 1:n
        tot = abs(total_shears[i])
        # A story with no total shear carries no requirement; skip it.
        tot ≤ tol && continue
        share = abs(frame_shears[i]) / tot
        if share < min_share
            min_share = share
            worst = i
        end
    end
    worst == 0 && return (satisfies=true, min_share=1.0, worst_story=0)   # no sheared story
    return (satisfies=min_share ≥ 0.25 - tol, min_share=min_share, worst_story=worst)
end
