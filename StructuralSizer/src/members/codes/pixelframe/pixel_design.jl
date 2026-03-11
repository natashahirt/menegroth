# ==============================================================================
# PixelFrame Per-Pixel Design
# ==============================================================================
# A PixelFrame member is composed of discrete precast concrete pieces ("pixels")
# along the span. Geometry and tendon properties are constant across all pixels,
# but the concrete material (fc′, dosage → fR1, fR3) can vary per pixel.
#
# After MIP selects the governing section (worst-case material for the highest
# demand), `assign_pixel_materials` relaxes each pixel to the lowest-carbon
# material that still satisfies its local demand.
#
# Reference: Wongsittikan (2024) §2.3, §3.2
# ==============================================================================

using Unitful

# ==============================================================================
# TendonDeviationResult (defined here so PixelFrameDesign can reference it)
# ==============================================================================

"""
    TendonDeviationResult

Result of the tendon deviation force calculation for a PixelFrame member.

# Fields
- `θ`: Tendon angle at the support deviator [rad]
- `P_horizontal`: Horizontal component of PT force [kN]
- `V_max`: Maximum shear demand along the member [kN]
- `N_friction`: Required normal force for friction-based shear transfer [kN]
- `N_additional`: Additional clamping force needed beyond PT horizontal component [kN].
  Negative means the PT alone provides more than enough clamping.
- `μ_s`: Static friction coefficient used (default 0.3)
"""
struct TendonDeviationResult
    θ::Float64                   # tendon angle at support deviator [rad]
    P_horizontal::typeof(1.0u"kN")  # horizontal PT component
    V_max::typeof(1.0u"kN")         # maximum shear demand
    N_friction::typeof(1.0u"kN")    # required normal force for friction
    N_additional::typeof(1.0u"kN")  # additional clamping force needed
    μ_s::Float64                    # friction coefficient
end

"""Pretty-print a `TendonDeviationResult` showing tendon angle and additional clamping force."""
function Base.show(io::IO, r::TendonDeviationResult)
    θ_deg = round(rad2deg(r.θ); digits=2)
    N_add = round(u"kN", r.N_additional; digits=1)
    print(io, "TendonDeviationResult(θ=$(θ_deg)°, N_additional=$(N_add))")
end

# ==============================================================================
# PixelFrameDesign
# ==============================================================================

"""
    PixelFrameDesign

Per-pixel material assignment for a PixelFrame member.

Geometry and tendon properties are constant across all pixels (per thesis §3.2).
Only the concrete material (fc′, dosage, fR1, fR3) varies per pixel.

# Fields
- `section`: Governing `PixelFrameSection` (midspan / highest-demand material)
- `pixel_length`: Along-span length of each physical pixel piece
- `n_pixels`: Number of pixels along the span
- `pixel_materials`: `Vector{FiberReinforcedConcrete}` — one per pixel, ordered support→support
- `tendon_deviation`: Optional `TendonDeviationResult` — connection design output

# Material Volumes
Use `pixel_volumes(design)` to compute a `Dict{FiberReinforcedConcrete, Volume}`
mapping each distinct material to its total volume contribution.

# Example
```julia
result = size_beams(Mu, Vu, geoms, opts)
design = assign_pixel_materials(result.sections[1], demands, material_catalog, checker)
design.pixel_materials  # [FRC(fc′=30), FRC(fc′=30), FRC(fc′=57), FRC(fc′=57), FRC(fc′=30), FRC(fc′=30)]
```
"""
mutable struct PixelFrameDesign
    section::PixelFrameSection          # Governing section (geometry + highest-demand material)
    pixel_length::typeof(1.0u"mm")      # Along-span length of each pixel
    n_pixels::Int                       # Number of pixels along the span
    pixel_materials::Vector{FiberReinforcedConcrete}  # One per pixel, support→support
    tendon_deviation::Union{Nothing, TendonDeviationResult}  # Connection design output
end

"""Pretty-print a `PixelFrameDesign` showing pixel count, length, unique materials, and deviation force."""
function Base.show(io::IO, d::PixelFrameDesign)
    n_unique = length(unique(d.pixel_materials))
    print(io, "PixelFrameDesign(", d.n_pixels, " pixels × ",
          Int(ustrip(u"mm", d.pixel_length)), "mm, ",
          n_unique, " unique material", n_unique == 1 ? "" : "s")
    if d.tendon_deviation !== nothing
        N = round(u"kN", d.tendon_deviation.N_additional; digits=1)
        print(io, ", N_add=", N)
    end
    print(io, ")")
end

# ==============================================================================
# Pixel Volume Computation
# ==============================================================================

"""
    pixel_volumes(design::PixelFrameDesign) -> Dict{FiberReinforcedConcrete, Volume}

Compute per-material volumes from a PixelFrameDesign.

Each pixel contributes `section_area × pixel_length` of its assigned material.
Pixels with the same material are summed.
"""
function pixel_volumes(design::PixelFrameDesign)
    A = section_area(design.section)
    L_px = design.pixel_length
    vol_per_pixel = uconvert(u"m^3", A * L_px)

    vols = Dict{FiberReinforcedConcrete, typeof(1.0u"m^3")}()
    for mat in design.pixel_materials
        vols[mat] = get(vols, mat, 0.0u"m^3") + vol_per_pixel
    end
    return vols
end

"""
    pixel_carbon(design::PixelFrameDesign) -> Float64

Total embodied carbon [kgCO₂e] for the full member, summing per-pixel
contributions with their individual materials.
"""
function pixel_carbon(design::PixelFrameDesign)
    A_c_m2 = ustrip(u"m^2", section_area(design.section))
    A_s_m2 = ustrip(u"m^2", design.section.A_s)
    L_px_m = ustrip(u"m", design.pixel_length)
    fiber_ecc = design.section.material.fiber_ecc

    total = 0.0
    for mat in design.pixel_materials
        fc′ = mat.fc′
        dosage = mat.fiber_dosage
        ec = pf_concrete_ecc(fc′)
        carbon_concrete = ec * A_c_m2 * L_px_m
        carbon_steel = fiber_ecc * (dosage * A_c_m2 + _STEEL_DENSITY_KGM3 * A_s_m2) * L_px_m
        total += carbon_concrete + carbon_steel
    end
    return total
end

# ==============================================================================
# Span Divisibility Validation
# ==============================================================================

"""
    validate_pixel_divisibility(L_mm, pixel_length_mm; label="Member", tol=1.0)

Validate that a member span (in mm) is an exact multiple of the pixel length.
Raises `ArgumentError` if not divisible within tolerance `tol` mm.

Returns the number of pixels (Int).
"""
function validate_pixel_divisibility(L_mm::Real, pixel_length_mm::Real;
                                     label::String = "Member", tol::Real = 1.0)
    pixel_length_mm > 0 || throw(ArgumentError("pixel_length_mm must be positive"))
    n_px = L_mm / pixel_length_mm
    n_px_int = round(Int, n_px)
    if abs(n_px - n_px_int) * pixel_length_mm > tol
        throw(ArgumentError(
            "$label span $(round(L_mm, digits=1)) mm is not divisible by " *
            "pixel_length=$(round(pixel_length_mm, digits=1)) mm " *
            "(remainder=$(round(L_mm - n_px_int * pixel_length_mm, digits=1)) mm)"))
    end
    return n_px_int
end

# ==============================================================================
# Per-Pixel Material Assignment (Post-MIP Relaxation)
# ==============================================================================

"""
    assign_pixel_materials(governing, n_pixels, pixel_demands, material_pool, checker;
                           symmetric=true) -> Vector{FiberReinforcedConcrete}

Post-MIP relaxation: for each pixel position, find the lowest-carbon material
from `material_pool` that satisfies the local demand, keeping geometry and
tendon properties from `governing` fixed.

# Arguments
- `governing`: The MIP-selected `PixelFrameSection` (geometry + worst-case material)
- `n_pixels`: Number of pixels along the span
- `pixel_demands`: `Vector{MemberDemand}` — one per pixel, ordered support→support
- `material_pool`: `Vector{FiberReinforcedConcrete}` — candidate materials, sorted by carbon (ascending)
- `checker`: `PixelFrameChecker` for feasibility evaluation

# Keyword Arguments
- `symmetric`: If `true` (default), enforce symmetric material assignment
  by using the stronger material at each pair of symmetric positions.

# Returns
`Vector{FiberReinforcedConcrete}` of length `n_pixels`.
"""
function assign_pixel_materials(
    governing::PixelFrameSection,
    n_pixels::Int,
    pixel_demands::AbstractVector{<:MemberDemand},
    material_pool::AbstractVector{<:FiberReinforcedConcrete},
    checker::PixelFrameChecker;
    symmetric::Bool = true,
)
    length(pixel_demands) == n_pixels ||
        throw(ArgumentError("pixel_demands length ($(length(pixel_demands))) ≠ n_pixels ($n_pixels)"))
    isempty(material_pool) &&
        throw(ArgumentError("material_pool is empty"))

    # Sort material pool by carbon (ascending) for greedy selection
    sorted_mats = sort(material_pool; by = mat -> begin
        pf_concrete_ecc(mat.fc′) + mat.fiber_ecc * mat.fiber_dosage
    end)

    E_s = checker.E_s_MPa * u"MPa"
    f_py = checker.f_py_MPa * u"MPa"

    materials = Vector{FiberReinforcedConcrete}(undef, n_pixels)

    # Build a dummy geometry (only used for interface; PF checker ignores it)
    dummy_geom = ConcreteMemberGeometry(1.0u"m")

    for i in 1:n_pixels
        assigned = false
        for mat in sorted_mats
            # Build candidate section with this material but governing geometry/tendon
            candidate = PixelFrameSection(;
                λ      = governing.λ,
                L_px   = governing.L_px,
                t      = governing.t,
                L_c    = governing.L_c,
                material = mat,
                A_s    = governing.A_s,
                f_pe   = governing.f_pe,
                d_ps   = governing.d_ps,
            )

            # Check capacity (compute on-the-fly, not from cache)
            ax = pf_axial_capacity(candidate; E_s=E_s)
            fl = pf_flexural_capacity(candidate; E_s=E_s, f_py=f_py)
            vu = frc_shear_capacity(candidate; E_s=E_s, γ_c=checker.γ_c)

            Pu_cap = ustrip(u"N", ax.Pu)
            Mu_cap = ustrip(u"N*m", fl.Mu)
            Vu_cap = ustrip(u"N", vu)

            Pu_dem = to_newtons(pixel_demands[i].Pu_c)
            Mu_dem = to_newton_meters(pixel_demands[i].Mux)
            Vu_dem = to_newtons(pixel_demands[i].Vu_strong)

            if Pu_cap ≥ Pu_dem && Mu_cap ≥ Mu_dem && Vu_cap ≥ Vu_dem
                materials[i] = mat
                assigned = true
                break
            end
        end
        if !assigned
            # Fallback: use the governing section's material (guaranteed feasible)
            materials[i] = governing.material
        end
    end

    # Enforce symmetry: at each pair (i, n+1-i), use the higher-strength material
    if symmetric && n_pixels > 1
        for i in 1:div(n_pixels, 2)
            j = n_pixels + 1 - i
            # Pick the material with higher fc′ (more conservative)
            if ustrip(u"MPa", materials[i].fc′) < ustrip(u"MPa", materials[j].fc′)
                materials[i] = materials[j]
            else
                materials[j] = materials[i]
            end
        end
    end

    return materials
end

# ==============================================================================
# Convenience: Build PixelFrameDesign from sizing result
# ==============================================================================

"""
    build_pixel_design(governing, L, pixel_length_mm, pixel_demands, material_pool,
                       checker; symmetric=true) -> PixelFrameDesign

Convenience function that validates pixel divisibility, assigns per-pixel
materials, and returns a complete `PixelFrameDesign`.

# Arguments
- `governing`: MIP-selected `PixelFrameSection`
- `L`: Member span (Unitful length)
- `pixel_length_mm`: Pixel piece length [mm]
- `pixel_demands`: `Vector{MemberDemand}` — one per pixel
- `material_pool`: `Vector{FiberReinforcedConcrete}` sorted by carbon
- `checker`: `PixelFrameChecker`
"""
function build_pixel_design(
    governing::PixelFrameSection,
    L,
    pixel_length_mm::Real,
    pixel_demands::AbstractVector{<:MemberDemand},
    material_pool::AbstractVector{<:FiberReinforcedConcrete},
    checker::PixelFrameChecker;
    symmetric::Bool = true,
)
    L_mm = ustrip(u"mm", L)
    n_px = validate_pixel_divisibility(L_mm, pixel_length_mm)

    mats = assign_pixel_materials(governing, n_px, pixel_demands, material_pool, checker;
                                  symmetric=symmetric)

    PixelFrameDesign(governing, pixel_length_mm * u"mm", n_px, mats, nothing)
end
