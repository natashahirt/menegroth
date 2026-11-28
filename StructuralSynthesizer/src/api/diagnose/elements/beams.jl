"""
    _beam_code_clauses(br::BeamDesignResult) -> (flexure::String, shear::String)

Select the governing design-code provisions for a beam's flexure and shear
checks by the member's MATERIAL (from the designed `section_obj`), never by
string position. Steel shapes cite AISC 360-16 — the edition actually
implemented by `StructuralSizer.AISCChecker` — with the section token that
matches the shape's checker path; RC shapes cite ACI 318-19. Unsized or
unsupported sections return empty strings so `ground_check` leaves the citation
explicitly UNRESOLVED rather than mis-attributing it to the wrong code family.

Section tokens follow the AISC 360-16 chapter organization implemented by the
checkers (corpus: aisc-360-16 — F2 p.47, G2 p.70 confirmed via corpus.get_clause;
HSS provisions F7/F8/G4/G5 are correct per the shape checkers but are left
ungrounded here) and ACI 318-19 (corpus: aci-318-19 — §9.5 flexure, §22.5 shear):
- ISymm (doubly-symmetric I): flexure §F2, shear §G2.
- Rectangular/square HSS:     flexure §F7, shear §G4.
- Round HSS / pipe:           flexure §F8, shear §G5.
- RC (rectangular / T-beam):  flexure §9.5, shear §22.5.
"""
function _beam_code_clauses(br::BeamDesignResult)::Tuple{String, String}
    so = br.section_obj
    if so isa StructuralSizer.ISymmSection
        return ("AISC 360-16 F2", "AISC 360-16 G2")
    elseif so isa StructuralSizer.HSSRectSection
        return ("AISC 360-16 F7", "AISC 360-16 G4")
    elseif so isa StructuralSizer.HSSRoundSection
        return ("AISC 360-16 F8", "AISC 360-16 G5")
    elseif so isa StructuralSizer.RCTBeamSection || so isa StructuralSizer.RCBeamSection
        return ("ACI 318-19 §9.5", "ACI 318-19 §22.5")
    else
        # PixelFrame / unsized / unsupported: no single confirmed code family.
        return ("", "")
    end
end

"""
Build a Dict representing one beam's full diagnostic data.
"""
function _diagnose_beam(
    idx::Int,
    br::BeamDesignResult,
    bm_obj::Beam,
    struc::BuildingStructure,
    du::DisplayUnits,
)
    funit = _force_unit_str(du)
    munit = _moment_unit_str(du)

    governing = _beam_governing_check(br)
    max_ratio = max(br.flexure_ratio, br.shear_ratio)
    if !br.ok && max_ratio < 1.0
        max_ratio = 1.0
    end

    mu_disp = _to_display(du, :moment, br.Mu)
    vu_disp = _to_display(du, :force,  br.Vu)
    L_disp  = _to_display(du, :length, br.member_length)

    # Tributary width (one-way slab load width)
    trib_w_disp = if !isnothing(bm_obj.tributary_width)
        _to_display(du, :length, bm_obj.tributary_width)
    else
        0.0
    end

    # Material-correct governing provisions (steel → AISC 360-16, RC → ACI 318-19),
    # selected from the designed section object — NOT by string position. This is
    # the P0-A safety fix: a steel beam must never be cited to a concrete (ACI)
    # clause and vice versa (see `_beam_code_clauses` / `ground_check`).
    # AUDIT (P0-B): verified — `_beam_code_clauses` keys on `br.section_obj`, so
    # the emitted flexure/shear clauses are always the same code family that
    # computed `br.flexure_ratio` / `br.shear_ratio`.
    flexure_clause, shear_clause = _beam_code_clauses(br)

    checks = Dict{String, Any}[
        Dict{String, Any}(
            "name"        => "flexure",
            "code_clause" => flexure_clause,
            "demand"      => _round_val(mu_disp),
            "demand_unit" => munit,
            "ratio"       => _round_val(br.flexure_ratio),
            "headroom"    => _round_val(1.0 - br.flexure_ratio),
            "governing"   => governing == "flexure",
        ),
        Dict{String, Any}(
            "name"        => "shear",
            "code_clause" => shear_clause,
            "demand"      => _round_val(vu_disp),
            "demand_unit" => funit,
            "ratio"       => _round_val(br.shear_ratio),
            "headroom"    => _round_val(1.0 - br.shear_ratio),
            "governing"   => governing == "shear",
        ),
    ]

    # Attach live corpus citations (explanation-layer only; ratios untouched).
    _ground_checks!(checks)

    return Dict{String, Any}(
        "id"              => idx,
        "role"            => string(bm_obj.role),
        "section"         => br.section_size,
        "member_length"   => _round_val(L_disp),
        "length_unit"     => _length_unit_string(du),
        "tributary_width" => _round_val(trib_w_disp),
        "Mu"              => _round_val(mu_disp),
        "Vu"              => _round_val(vu_disp),
        "force_unit"      => funit,
        "moment_unit"     => munit,
        "governing_check"  => governing,
        "governing_ratio"  => _round_val(max_ratio),
        "governing_mode"   => _governing_mode(max_ratio),
        "ok"              => br.ok,
        "checks"          => checks,
        "levers"          => get(LEVER_MAP, governing, String[]),
        "limit_state_description" => get(LIMIT_STATE_DESCRIPTIONS, governing, ""),
        "ec_kgco2e"       => _round_or_nothing(_beam_ec_kgco2e(struc, idx); digits=1),
    )
end

function _diagnose_beams(design::BuildingDesign, struc::BuildingStructure, du::DisplayUnits)
    isempty(design.beams) && return Dict{String, Any}[]
    [_diagnose_beam(idx, design.beams[idx], struc.beams[idx], struc, du)
     for idx in _sorted_indices(design.beams)]
end

