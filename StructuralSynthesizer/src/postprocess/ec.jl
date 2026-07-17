# Embodied Carbon (EC) calculation utilities
#
# EC = Σ(volume × density × embodied_carbon_coefficient) for each material

"""
    _sorted_volume_pairs(volumes::MaterialVolumes)

Return `(material, volume)` pairs sorted by a **semantic** key so EC sums are
reproducible across Julia sessions. (`MaterialVolumes` is a `Dict`; iterating it
in raw insertion order makes floating-point totals order-dependent.)
"""
function _sorted_volume_pairs(volumes::MaterialVolumes)
    isempty(volumes) && return Tuple{AbstractMaterial, VolumeType}[]
    pairs = collect(volumes)
    sort!(pairs; by = mv -> (_material_ec_semantic_key(mv[1]), ustrip(u"m^3", mv[2])))
    return pairs
end

# Sort-key helpers below pre-strip `mat.ecc` so the resulting `Tuple{...,Float64,...}`
# is uniformly comparable; mixing typed quantities into a sort tuple would force
# Julia to widen the eltype.
_ecc_key(x) = ustrip(u"kgCO2e/kg", x)

"""Stable tuple for sorting materials in EC sums (type + salient physical fields)."""
function _material_ec_semantic_key(mat::StructuralSizer.Concrete)
    (
        1,
        Int(mat.aggregate_type),
        ustrip(u"Pa", mat.fc′),
        ustrip(u"kg/m^3", mat.ρ),
        _ecc_key(mat.ecc),
        mat.ν,
        mat.εcu,
        mat.λ,
    )
end
function _material_ec_semantic_key(mat::StructuralSizer.ReinforcedConcreteMaterial)
    (2, _material_ec_semantic_key(mat.concrete)..., ustrip(u"Pa", mat.rebar.Fy), ustrip(u"Pa", mat.rebar.Fu), _ecc_key(mat.rebar.ecc))
end
function _material_ec_semantic_key(mat::StructuralSizer.FiberReinforcedConcrete)
    c = getfield(mat, :concrete)
    (
        3,
        _material_ec_semantic_key(c)...,
        getfield(mat, :fiber_dosage),
        getfield(mat, :fR1),
        getfield(mat, :fR3),
        _ecc_key(getfield(mat, :fiber_ecc)),
    )
end
function _material_ec_semantic_key(mat::StructuralSizer.RebarSteel)
    (4, ustrip(u"Pa", mat.Fy), ustrip(u"Pa", mat.Fu), ustrip(u"Pa", mat.E), _ecc_key(mat.ecc))
end
function _material_ec_semantic_key(mat::StructuralSizer.StructuralSteel)
    (5, ustrip(u"Pa", mat.Fy), ustrip(u"Pa", mat.Fu), _ecc_key(mat.ecc), ustrip(u"kg/m^3", mat.ρ))
end
function _material_ec_semantic_key(mat::StructuralSizer.Timber)
    (6, ustrip(u"Pa", mat.E), ustrip(u"kg/m^3", mat.ρ), _ecc_key(mat.ecc))
end
function _material_ec_semantic_key(mat::AbstractMaterial)
    (999, string(typeof(mat)), repr(mat))
end

"""
    element_ec(volumes::MaterialVolumes) -> Quantity{Float64, 𝐗}

Compute total embodied carbon for an element from its material volumes dict.
Returns a typed `kgCO₂e` quantity; multiplications of volume × density × ecc
flow through Unitful and reduce to the `𝐗` (carbon-equivalent) dimension.

## Example
```julia
slab_ec = element_ec(slab.volumes)  # → 12 345.6 kgCO₂e
```
"""
function element_ec(volumes::MaterialVolumes)
    s = 0.0u"kgCO2e"
    for (mat, vol) in _sorted_volume_pairs(volumes)
        s += uconvert(u"kgCO2e", vol * mat.ρ * mat.ecc)
    end
    return s
end

"""
    ElementECResult

Breakdown of EC for a single element. `ec` is a typed `kgCO₂e` quantity; strip
to a numeric scalar via `ustrip(u"kgCO2e", r.ec)` at presentation boundaries.
"""
struct ElementECResult
    element_type::Symbol       # :slab, :member, :foundation
    element_id::Int
    ec::CarbonMassQuantity     # Total embodied carbon (kgCO₂e)
    volume_total::VolumeType   # Total material volume (m³)
    mass_total::typeof(1.0u"kg")
end

"""
    compute_element_ec(elem, element_type::Symbol, idx::Int) -> ElementECResult

Compute EC for a single element (slab, member, or foundation).
"""
function compute_element_ec(elem, element_type::Symbol, idx::Int)
    vols = elem.volumes
    ec = element_ec(vols)
    pairs = _sorted_volume_pairs(vols)
    vol_total = sum((v for (_, v) in pairs); init=0.0u"m^3")
    mass_total = sum(vol * mat.ρ for (mat, vol) in pairs; init=0.0u"kg")
    ElementECResult(element_type, idx, ec, vol_total, mass_total)
end

"""
    BuildingECResult

Complete EC breakdown for a building structure. All `*_ec` and the EC intensity
field are typed `kgCO₂e` / `kgCO₂e/m²` quantities (Asap `𝐗` dimension); strip
at the presentation / JSON / JuMP boundary using `ustrip(u"kgCO2e", ...)`.
"""
struct BuildingECResult
    # Per-element breakdowns
    slabs::Vector{ElementECResult}
    members::Vector{ElementECResult}
    foundations::Vector{ElementECResult}
    # Totals by system
    slab_ec::CarbonMassQuantity
    member_ec::CarbonMassQuantity
    foundation_ec::CarbonMassQuantity
    fireproofing_ec::CarbonMassQuantity
    total_ec::CarbonMassQuantity
    # Intensity metrics
    floor_area::typeof(1.0u"m^2")
    ec_per_floor_area::CarbonPerAreaQuantity   # kgCO₂e/m²
end

"""
    compute_building_ec(struc::BuildingStructure) -> BuildingECResult

Compute complete embodied carbon breakdown for a building structure.

## Returns
Named tuple with:
- `slabs`, `members`, `foundations`: Per-element EC breakdowns
- `slab_ec`, `member_ec`, `foundation_ec`: Total EC by system (kgCO₂e)
- `total_ec`: Grand total EC (kgCO₂e)
- `floor_area`: Total floor area
- `ec_per_floor_area`: EC intensity (kgCO₂e/m²)

## Example
```julia
ec = compute_building_ec(struc)
println("Total EC: \$(ec.total_ec) kgCO₂e")
println("Intensity: \$(ec.ec_per_floor_area) kgCO₂e/m²")
```
"""
compute_building_ec(struc::BuildingStructure) = compute_building_ec(struc, nothing)

function compute_building_ec(struc::BuildingStructure, params::Union{DesignParameters, Nothing})
    slab_results = [compute_element_ec(s, :slab, i) for (i, s) in enumerate(struc.slabs)]

    # Compute member EC for all member types (beams, columns, struts)
    member_results = ElementECResult[]
    for (i, m) in enumerate(struc.beams)
        !isempty(volumes(m)) && push!(member_results, compute_element_ec_member(m, :beam, i))
    end
    for (i, m) in enumerate(struc.columns)
        !isempty(volumes(m)) && push!(member_results, compute_element_ec_member(m, :column, i))
    end
    for (i, m) in enumerate(struc.struts)
        !isempty(volumes(m)) && push!(member_results, compute_element_ec_member(m, :strut, i))
    end

    fdn_results = [compute_element_ec(f, :foundation, i) for (i, f) in enumerate(struc.foundations) if !isempty(f.volumes)]

    # Fireproofing EC (steel members with ISymmSection + SurfaceCoating)
    fp_ec = _compute_fireproofing_ec(struc, params)

    # System sums use a typed-quantity zero so the accumulator is type-stable.
    slab_ec   = sum(r.ec for r in slab_results;   init=0.0u"kgCO2e")
    member_ec = sum(r.ec for r in member_results; init=0.0u"kgCO2e")
    fdn_ec    = sum(r.ec for r in fdn_results;    init=0.0u"kgCO2e")
    total_ec  = slab_ec + member_ec + fdn_ec + fp_ec

    # Floor area is m² → intensity is naturally kgCO₂e/m² without manual stripping.
    floor_area = sum(c.area for c in struc.cells; init=0.0u"m^2")
    ec_intensity = floor_area > 0.0u"m^2" ?
        uconvert(u"kgCO2e/m^2", total_ec / floor_area) :
        0.0u"kgCO2e/m^2"

    BuildingECResult(
        slab_results, member_results, fdn_results,
        slab_ec, member_ec, fdn_ec, fp_ec, total_ec,
        floor_area, ec_intensity
    )
end

"""
    _compute_fireproofing_ec(struc) -> Quantity{Float64, 𝐗}

Compute total embodied carbon for fire protection coatings on steel members,
returned as a typed `kgCO₂e` quantity.

Iterates over beams, columns, and struts. For each member with an `ISymmSection`,
computes the coating volume from the section's exposed perimeter (PA for beams,
PB for columns) and the design parameters' fire protection specification.
"""
function _compute_fireproofing_ec(struc::BuildingStructure, params::Union{DesignParameters, Nothing}=nothing)
    isnothing(params) && return 0.0u"kgCO2e"

    fp = params.fire_protection
    (fp isa StructuralSizer.NoFireProtection) && return 0.0u"kgCO2e"

    fire_rating = params.fire_rating
    fire_rating <= 0 && return 0.0u"kgCO2e"

    total_ec = 0.0u"kgCO2e"

    for (members, exposure) in ((struc.beams, :three_sided),
                                 (struc.columns, :four_sided),
                                 (struc.struts, :four_sided))
        for m in members
            sec = section(m)
            isnothing(sec) && continue
            sec isa StructuralSizer.ISymmSection || continue

            # Extract steel material from member volumes
            vols = volumes(m)
            isempty(vols) && continue
            mat = nothing
            for (mm, _) in _sorted_volume_pairs(vols)
                if mm isa StructuralSizer.StructuralSteel
                    mat = mm
                    break
                elseif mm isa StructuralSizer.ReinforcedConcreteMaterial
                    # No fireproofing for RC members
                    break
                end
            end
            isnothing(mat) && continue

            W_plf = ustrip(u"lb/ft", StructuralSizer.weight_per_length(sec, mat))
            P_in = ustrip(u"inch", exposure === :four_sided ? sec.PB : sec.PA)
            coating = StructuralSizer.compute_surface_coating(fp, fire_rating, W_plf, P_in)
            coating.thickness_in ≤ 0 && continue

            L_raw = sum(struc.segments[i].L for i in segment_indices(m))
            L = L_raw isa Unitful.Quantity ? L_raw : L_raw * u"m"

            total_ec += StructuralSizer.coating_ec(sec, coating, L;
                                                    exposure=exposure,
                                                    ecc=StructuralSizer.ECC_SFRM)
        end
    end

    return total_ec
end

"""Compute EC for a member (uses volumes accessor)."""
function compute_element_ec_member(m::AbstractMember, element_type::Symbol, idx::Int)
    vols = volumes(m)
    ec = element_ec(vols)
    pairs = _sorted_volume_pairs(vols)
    vol_total = sum((v for (_, v) in pairs); init=0.0u"m^3")
    
    # [BUG fix] ReinforcedConcreteMaterial has no field ρ. Extract concrete density.
    mass_total = 0.0u"kg"
    for (mat, vol) in pairs
        ρ = if hasproperty(mat, :ρ)
            mat.ρ
        elseif mat isa StructuralSizer.ReinforcedConcreteMaterial
            mat.concrete.ρ
        else
            @warn "Unknown material type in EC calculation: $(typeof(mat))"
            0.0u"kg/m^3"
        end
        mass_total += vol * ρ
    end

    ElementECResult(element_type, idx, ec, vol_total, mass_total)
end

# =============================================================================
# Serialization helpers
# =============================================================================
# `BuildingECResult` and `ElementECResult` carry Unitful quantities (floor
# area, mass), which JSON3 cannot serialize directly. The `to_dict` overloads
# below produce JSON-friendly `Dict{String, Any}` views with all units
# stripped to numeric scalars in the conventions documented per field, plus
# explicit `*_unit` fields so consumers can label values without guessing.

"""
    to_dict(r::ElementECResult) -> Dict{String, Any}

JSON-friendly view of an `ElementECResult` with all units stripped.

Units (fixed, not configurable):
- `kgco2e`: embodied carbon in kgCO₂e.
- `volume_m3`: total material volume in m³.
- `mass_kg`: total mass in kg.

Element-level numbers always use SI (m³, kg) for stability; consumers that
want imperial display should convert at the presentation layer rather than
re-encoding the structured payload.
"""
function to_dict(r::ElementECResult)
    Dict{String, Any}(
        "element_type" => string(r.element_type),
        "element_id"   => r.element_id,
        "kgco2e"       => ustrip(u"kgCO2e", r.ec),
        "volume_m3"    => ustrip(u"m^3", r.volume_total),
        "mass_kg"      => ustrip(u"kg", r.mass_total),
    )
end

"""
    to_dict(r::BuildingECResult; du::DisplayUnits=imperial) -> Dict{String, Any}

JSON-friendly view of a `BuildingECResult` with all units stripped.

# Units
EC values (`*_kgco2e`) are reported in kgCO₂e. Floor area is converted to
`du.units[:area]` (default: imperial / ft²); EC intensity is reported in
kgCO₂e per m² (the canonical comparison unit in the EPD literature) **and**
in kgCO₂e per `du.units[:area]` so the imperial view is also available
without re-conversion. Per-element breakdowns always use SI — see
[`to_dict(::ElementECResult)`](@ref).

# Keys
- `slab_kgco2e`, `member_kgco2e`, `foundation_kgco2e`, `fireproofing_kgco2e`,
  `total_kgco2e`: system subtotals and grand total.
- `floor_area`, `floor_area_unit`: total floor area in the requested display unit.
- `intensity_kgco2e_per_m2`: canonical EC intensity (kgCO₂e/m²).
- `intensity_kgco2e_per_display_area`, `intensity_kgco2e_per_display_area_unit`:
  EC intensity expressed in `kgCO₂e/<display area unit>`.
- `slabs`, `members`, `foundations`: vectors of per-element `to_dict`s.
"""
function to_dict(r::BuildingECResult; du::DisplayUnits = imperial)
    area_unit = du.units[:area]
    floor_area_display = ustrip(area_unit, r.floor_area)
    intensity_per_display = if floor_area_display > 0
        ustrip(u"kgCO2e", r.total_ec) / floor_area_display
    else
        0.0
    end

    Dict{String, Any}(
        "slab_kgco2e"          => ustrip(u"kgCO2e", r.slab_ec),
        "member_kgco2e"        => ustrip(u"kgCO2e", r.member_ec),
        "foundation_kgco2e"    => ustrip(u"kgCO2e", r.foundation_ec),
        "fireproofing_kgco2e"  => ustrip(u"kgCO2e", r.fireproofing_ec),
        "total_kgco2e"         => ustrip(u"kgCO2e", r.total_ec),
        "floor_area"           => floor_area_display,
        "floor_area_unit"      => string(area_unit),
        "intensity_kgco2e_per_m2"               => ustrip(u"kgCO2e/m^2", r.ec_per_floor_area),
        "intensity_kgco2e_per_display_area"     => intensity_per_display,
        "intensity_kgco2e_per_display_area_unit"=> "kgCO₂e/" * string(area_unit),
        "slabs"        => [to_dict(e) for e in r.slabs],
        "members"      => [to_dict(e) for e in r.members],
        "foundations"  => [to_dict(e) for e in r.foundations],
    )
end

"""
    ec_summary(design::BuildingDesign)
    ec_summary(struc::BuildingStructure; du=imperial)

Print a summary of embodied carbon for a building structure.
Display units controlled by `du` (default: `imperial`).
"""
function ec_summary(design::BuildingDesign)
    ec_summary(design.structure; du=design.params.display_units, params=design.params)
end

function ec_summary(struc::BuildingStructure; du::DisplayUnits=imperial, params::Union{DesignParameters,Nothing}=nothing)
    ec = compute_building_ec(struc, params)

    # Strip once at the print boundary so the % helper and Printf calls receive
    # bare Float64s — Unitful Quantities don't interpolate cleanly via %f.
    total       = ustrip(u"kgCO2e", ec.total_ec)
    slab_v      = ustrip(u"kgCO2e", ec.slab_ec)
    member_v    = ustrip(u"kgCO2e", ec.member_ec)
    fdn_v       = ustrip(u"kgCO2e", ec.foundation_ec)
    fp_v        = ustrip(u"kgCO2e", ec.fireproofing_ec)
    intensity_v = ustrip(u"kgCO2e/m^2", ec.ec_per_floor_area)
    pct(v) = total > 0 ? 100*v/total : 0.0

    println("\n=== Embodied Carbon Summary ===")
    println("─" ^ 50)

    println("System Breakdown:")
    Printf.@printf("  Slabs:        %10.1f kgCO₂e  (%4.1f%%)\n", slab_v,   pct(slab_v))
    Printf.@printf("  Members:      %10.1f kgCO₂e  (%4.1f%%)\n", member_v, pct(member_v))
    Printf.@printf("  Foundations:  %10.1f kgCO₂e  (%4.1f%%)\n", fdn_v,    pct(fdn_v))
    if fp_v > 0
        Printf.@printf("  Fireproofing: %10.1f kgCO₂e  (%4.1f%%)\n", fp_v, pct(fp_v))
    end
    println("─" ^ 50)
    Printf.@printf("  TOTAL:        %10.1f kgCO₂e\n", total)
    println()

    Printf.@printf("Floor Area:    %10.1f %s\n", ustrip(du.units[:area], ec.floor_area), du.units[:area])
    Printf.@printf("EC Intensity:  %10.1f kgCO₂e/m²\n", intensity_v)

    return ec
end
