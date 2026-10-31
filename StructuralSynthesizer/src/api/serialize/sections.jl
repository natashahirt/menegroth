# ─── Columns ──────────────────────────────────────────────────────────────────

"""
    _api_section_type(sec_obj) -> String

Map a StructuralSizer section object to a canonical API section type code.
Reuses the geometry trait dispatch already used by the visualization layer.
"""
function _api_section_type(sec_obj)
    isnothing(sec_obj) && return ""
    sec_obj isa StructuralSizer.PixelFrameSection && return "pixelframe"
    geom = StructuralSizer.section_geometry(sec_obj)
    geom isa StructuralSizer.IShape && return "steel_w"
    geom isa StructuralSizer.HollowRect && return "steel_hss_rect"
    geom isa StructuralSizer.HollowRound && return "steel_hss_round"
    geom isa StructuralSizer.SolidRect && return "rc_rect"
    geom isa StructuralSizer.SolidRound && return "rc_circular"
    geom isa StructuralSizer.TShape && return "rc_tbeam"
    return "other"
end

"""Serialize column design results into `APIColumnResult` records."""
function _serialize_columns(design::BuildingDesign, du::DisplayUnits)
    results = APIColumnResult[]
    for idx in _sorted_indices(design.columns)
        cr = design.columns[idx]
        c1_display = _to_display(du, :thickness, cr.c1)
        c2_display = _to_display(du, :thickness, cr.c2)
        push!(results, APIColumnResult(
            id = idx,
            section = cr.section_size,
            section_type = _api_section_type(cr.section_obj),
            c1 = _round_val(c1_display; digits=1),
            c2 = _round_val(c2_display; digits=1),
            shape = string(cr.shape),
            axial_ratio = _round_val(cr.axial_ratio),
            interaction_ratio = _round_val(cr.interaction_ratio),
            ok = cr.ok,
        ))
    end
    return results
end

# ─── Beams ────────────────────────────────────────────────────────────────────

"""Serialize beam design results into `APIBeamResult` records."""
function _serialize_beams(design::BuildingDesign, du::DisplayUnits)
    results = APIBeamResult[]
    for idx in _sorted_indices(design.beams)
        br = design.beams[idx]
        sec = br.section_obj
        sec_type = _api_section_type(sec)
        d_disp = 0.0
        w_disp = 0.0
        if !isnothing(sec)
            try
                d_disp = _round_val(_to_display(du, :thickness,
                    StructuralSizer.section_depth(sec)); digits=2)
                w_disp = _round_val(_to_display(du, :thickness,
                    StructuralSizer.section_width(sec)); digits=2)
            catch
            end
        end
        push!(results, APIBeamResult(
            id = idx,
            section = br.section_size,
            section_type = sec_type,
            depth = d_disp,
            width = w_disp,
            flexure_ratio = _round_val(br.flexure_ratio),
            shear_ratio = _round_val(br.shear_ratio),
            ok = br.ok,
        ))
    end
    return results
end

# ─── Foundations ──────────────────────────────────────────────────────────────

"""Serialize foundation design results into `APIFoundationResult` records."""
function _serialize_foundations(design::BuildingDesign, du::DisplayUnits)
    results = APIFoundationResult[]
    for idx in _sorted_indices(design.foundations)
        fr = design.foundations[idx]
        push!(results, APIFoundationResult(
            id = idx,
            length = _round_val(_to_display_length(du, fr.length); digits=2),
            width = _round_val(_to_display_length(du, fr.width); digits=2),
            depth = _round_val(_to_display_length(du, fr.depth); digits=2),
            bearing_ratio = _round_val(fr.bearing_ratio),
            ok = fr.ok,
        ))
    end
    return results
end

# ─── Summary ─────────────────────────────────────────────────────────────────

"""Serialize the design summary (material quantities, critical ratio) into `APISummary`."""
function _serialize_summary(design::BuildingDesign, du::DisplayUnits)
    s = design.summary
    vol_display = _to_display(du, :volume, s.concrete_volume)
    steel_display = _to_display(du, :mass, s.steel_weight)
    rebar_display = _to_display(du, :mass, s.rebar_weight)
    return APISummary(
        all_pass = s.all_checks_pass,
        concrete_volume = _round_val(vol_display; digits=1),
        steel_weight = _round_val(steel_display; digits=0),
        rebar_weight = _round_val(rebar_display; digits=0),
        embodied_carbon_kgCO2e = _round_val(ustrip(u"kgCO2e", s.embodied_carbon); digits=0),
        critical_ratio = _round_val(s.critical_ratio),
        critical_element = s.critical_element,
    )
end

