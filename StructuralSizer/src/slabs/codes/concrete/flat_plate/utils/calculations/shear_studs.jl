# =============================================================================
# Phase 6d+: Shear Stud Design (ACI 318-11 §11.11.5 / Ancon Shearfix)
# =============================================================================

"""
    _shear_sqrt_fc(fc) -> Float64

√f′c in psi for a Chapter 11 shear stress, not above 100.

ACI 318-11 §11.1.2 (corpus: aci-318-11, page 165): the values of √f′c used
in this chapter shall not exceed 100 psi, except as §11.1.2.1 allows for
beams and joists with the stated minimum web reinforcement. A slab is not
that exception. [`size_effect_factor`](@ref) is 1 on this edition.
"""
_shear_sqrt_fc(fc::Pressure) = min(sqrt(ustrip(u"psi", fc)), 100.0)

"""
    punching_capacity_with_studs(fc, β, αs, b0, d, Av, s, fyt; λ=1.0)

Punching shear capacity with headed shear stud reinforcement per ACI 318-11 §11.11.5.

# Three Failure Modes Checked:
1. Nominal capacity limit (vc_max = 8√f'c, §11.11.5.1)
2. Combined concrete + steel within studs (vcs + vs)
3. Outer critical section (checked separately, §11.11.5.4)

# Formulas (ACI 318-11, US customary psi):
- vcs = min(4λ√f'c, (2+4/β)λ√f'c, (αs d/b0+2)λ√f'c, 3λ√f'c)  §11.11.5.1
- vs  = Av × fyt / (b0 × s)
- vc_max = 8λ√f'c  (headed studs, §11.11.5.1)

# Arguments
- `fc`: Concrete compressive strength
- `β`: Column aspect ratio (long/short)
- `αs`: Location factor (40 interior, 30 edge, 20 corner)
- `b0`: Critical perimeter at column
- `d`: Effective depth
- `Av`: Total stud area per peripheral line
- `s`: Spacing between stud lines
- `fyt`: Stud yield strength
- `λ`: Lightweight concrete factor

# Returns
NamedTuple with (vcs, vs, vc_max, vc_total, compression_ok)
"""
function punching_capacity_with_studs(
    fc::Pressure,
    β::Float64,
    αs::Int,
    b0::Length,
    d::Length,
    Av::Area,
    s::Length,
    fyt::Pressure;
    λ::Float64 = 1.0
)
    sqrt_fc = sqrt(ustrip(u"psi", fc))
    b0_in = ustrip(u"inch", b0)
    d_in = ustrip(u"inch", d)
    s_in = ustrip(u"inch", s)
    Av_in2 = ustrip(u"inch^2", Av)
    fyt_psi = ustrip(u"psi", fyt)
    
    # ACI 318-11 §11.11.5.1: Vc with studs ≤ 3λ√f'c × b0 × d.
    # vc is §11.11.2.1 Eqs. (11-31)–(11-33), then capped at 3λ√f'c.
    # λs is 1 (size_effect_factor). √f'c is §11.1.2.
    λs_v = size_effect_factor(d)
    sqrt_fc_v = _shear_sqrt_fc(fc)
    vc_a = (2 + 4 / β) * λs_v * λ * sqrt_fc_v               # Eq. (11-31)
    vc_b = (αs * d_in / b0_in + 2) * λs_v * λ * sqrt_fc_v   # Eq. (11-32)
    vc_c = 4 * λs_v * λ * sqrt_fc_v                          # Eq. (11-33)
    vcs = min(min(vc_a, vc_b, vc_c), 3.0 * λs_v * λ * sqrt_fc_v)
    
    # Steel contribution: vs = Av × fyt / (b0 × s)
    vs = s_in > 0 ? Av_in2 * fyt_psi / (b0_in * s_in) : 0.0
    
    # Nominal capacity limit for headed studs (ACI 318-11 §11.11.5.1)
    # Vn ≤ 8√f'c × b0 × d
    vc_max = 8.0 * λ * sqrt_fc
    
    # Combined capacity (but limited by nominal cap)
    vc_total = min(vcs + vs, vc_max)
    compression_ok = (vcs + vs) <= vc_max
    
    return (
        vcs = vcs * u"psi",
        vs = vs * u"psi",
        vc_max = vc_max * u"psi",
        vc_total = vc_total * u"psi",
        compression_ok = compression_ok
    )
end

"""
    punching_capacity_outer(fc, d; λ=1.0)

Punching capacity at outer critical section (beyond shear studs).

    vc,out = 2 λ √f'c  (psi)

At d/2 beyond the outermost peripheral line of studs the concrete is
unreinforced. ACI 318-11 §11.11.5.4 (corpus: aci-318-11, page 208): the
shear stress there shall not exceed 2φλ√f′c. This returns the nominal
2λ√f′c; the caller applies φ. `size_effect_factor` is 1 on this edition,
and √f′c is the §11.1.2 limit.
"""
function punching_capacity_outer(fc::Pressure, d::Length; λ::Float64 = 1.0)
    vc_out = 2.0 * size_effect_factor(d) * λ * _shear_sqrt_fc(fc)
    return vc_out * u"psi"
end

"""
    minimum_stud_reinforcement(fc, b0, fyt)

Minimum shear stud reinforcement per ACI 318-11 §11.11.5.1:

    Av × fyt / (b0 × s) ≥ 2√f'c   →   Av/s ≥ 2√f'c × b0 / fyt

# Returns
Minimum Av/s ratio (Area/Length)

# Reference
- ACI 318-11 §11.11.5.1
"""
function minimum_stud_reinforcement(fc::Pressure, b0::Length, fyt::Pressure)
    sqrt_fc = sqrt(ustrip(u"psi", fc))
    b0_in = ustrip(u"inch", b0)
    fyt_psi = ustrip(u"psi", fyt)
    
    # ACI 318-11 §11.11.5.1: Av*fyt/(b0*s) ≥ 2√f'c
    Av_s_min = 2.0 * sqrt_fc * b0_in / fyt_psi
    return Av_s_min * u"inch^2/inch"
end

"""
    stud_area(diameter)

Cross-sectional area of a single headed shear stud.
"""
function stud_area(diameter::Length)
    return π * (diameter / 2)^2
end

"""
    design_shear_studs(vu, fc, β, αs, b0, d, position, fyt, stud_diameter;
                       λ, φ, c1, c2, qu, catalog, Vu, M_about_x, M_about_y, max_extent)

Design headed shear stud reinforcement for a punching shear failure.

# Design Steps (ACI 318-11 §11.11.5 / ACI 421.1R-99 §3.4):
1. Compute required vs = vu/φ − vcs
2. Place rails at both ends of each column face, adding rails so adjacent studs
   on the first peripheral line are ≤ 2d apart (§11.11.5.3)
3. Determine Av per line from n_rails × stud_area
4. Compute spacing s = Av × fyt / (b0 × vs)
5. Apply detailing limits (s ≤ 0.75d or 0.5d if high stress, §11.11.5.2)
6. Add peripheral lines until the section d/2 beyond the outermost line
   satisfies vu ≤ φ·2λ√f'c (§11.11.5.4; ACI 421.1R-99 §3.4 Step 4)

# Arguments
- `vu`: Factored shear stress demand
- `fc`: Concrete compressive strength
- `β`: Column aspect ratio
- `αs`: Location factor (40/30/20)
- `b0`: Critical perimeter
- `d`: Effective depth
- `position`: Column position (:interior, :edge, :corner)
- `fyt`: Stud yield strength
- `stud_diameter`: Stud diameter (target; snapped to catalog if provided)
- `c1`, `c2`: Column dimensions in the outer-section frame (free edge at
  x = +c1/2 for edge columns). When omitted, a square column with the same b0
  is assumed and two rails per face are used.
- `qu`: Factored uniform pressure (for outer section Vu reduction; optional)
- `catalog`: Stud catalog vector (`Vector{StudSpec}`). When provided, the stud
  is snapped to the nearest catalog product and its actual shank area is used
  instead of the generic π d²/4 formula. Pass `nothing` for generic studs.
- `Vu`, `M_about_x`, `M_about_y`: Factored shear and unbalanced moments at the
  column centre for the outer section check (see [`outer_section_check`](@ref)).
  When `Vu` is omitted the outer check uses `vu·b0·d` with no moment, which is
  an upper bound.
- `max_extent`: Optional longest distance from the column face to the
  outermost peripheral line. Omit it so the search follows §11.11.5.4 out
  to `MAX_REINFORCEMENT_LINES`.

# Returns
ShearStudDesign struct with complete stud layout

# Reference
- ACI 318-11 §11.11.5.1–§11.11.5.4 (corpus: aci-318-11, pages 207–208)
- ACI 421.1R-99 §3.4, Eq. (3.2)–(3.3), Ch. 7 (corpus: aci-421-1r-99)
"""
function design_shear_studs(
    vu::Pressure,
    fc::Pressure,
    β::Float64,
    αs::Int,
    b0::Length,
    d::Length,
    position::Symbol,
    fyt::Pressure,
    stud_diameter::Length;
    λ::Float64 = 1.0,
    φ::Float64 = 0.75,
    c1::Union{Length, Nothing} = nothing,
    c2::Union{Length, Nothing} = nothing,
    qu::Union{Pressure, Nothing} = nothing,
    catalog::Union{Vector{StudSpec}, Nothing} = nothing,
    Vu::Union{Force, Nothing} = nothing,
    M_about_x::Union{Moment, Nothing} = nothing,
    M_about_y::Union{Moment, Nothing} = nothing,
    max_extent::Union{Length, Nothing} = nothing,
)
    d_in = ustrip(u"inch", d)
    b0_in = ustrip(u"inch", b0)
    vu_psi = ustrip(u"psi", vu)
    sqrt_fc = sqrt(ustrip(u"psi", fc))
    fyt_psi = ustrip(u"psi", fyt)
    
    # Convert fyt to psi for consistent units in ShearStudDesign struct
    fyt_unit = fyt_psi * u"psi"
    
    # ─── Resolve stud from catalog (or use generic π d²/4) ───
    if !isnothing(catalog)
        spec = snap_to_catalog(catalog, stud_diameter)
        catalog_name = spec.catalog
        actual_diameter = spec.shank_diameter
        As_stud = spec.head_area           # shank cross-sectional area from catalog
    else
        catalog_name = :generic
        actual_diameter = stud_diameter
        As_stud = stud_area(stud_diameter)  # π d²/4
    end
    As_stud_in2 = ustrip(u"inch^2", As_stud)
    actual_diameter_unit = uconvert(u"inch", actual_diameter)
    
    # Maximum nominal shear strength with headed studs (ACI 318-11 §11.11.5.1)
    # Vn ≤ 8√f'c × b0 × d
    vc_max = 8.0 * λ * sqrt_fc
    
    # Check if studs can solve the problem
    if vu_psi > φ * vc_max
        # Demand exceeds maximum capacity with studs
        return ShearStudDesign(
            required = true,
            catalog_name = catalog_name,
            stud_diameter = actual_diameter_unit,
            fyt = fyt_unit,
            n_rails = 0,
            n_studs_per_rail = 0,
            s0 = 0.0u"inch",
            s = 0.0u"inch",
            Av_per_line = 0.0u"inch^2",
            vs = 0.0u"psi",
            vcs = 0.0u"psi",
            vc_max = vc_max * u"psi",
            outer_ok = false
        )
    end
    
    # ACI 318-11 §11.11.5.1: Vc with studs ≤ 3λ√f'c × b0 × d.
    # vc is §11.11.2.1 Eqs. (11-31)–(11-33), then capped at 3λ√f'c.
    # λs is 1 (size_effect_factor). √f'c is §11.1.2.
    λs_v = size_effect_factor(d)
    sqrt_fc_v = _shear_sqrt_fc(fc)
    vc_a = (2 + 4 / β) * λs_v * λ * sqrt_fc_v               # Eq. (11-31)
    vc_b = (αs * d_in / b0_in + 2) * λs_v * λ * sqrt_fc_v   # Eq. (11-32)
    vc_c = 4 * λs_v * λ * sqrt_fc_v                          # Eq. (11-33)
    vcs = min(min(vc_a, vc_b, vc_c), 3.0 * λs_v * λ * sqrt_fc_v)
    
    # Required steel contribution
    vs_reqd = max(vu_psi / φ - vcs, 0.0)
    
    outer = _outer_section_inputs(vu, b0, d, position, c1, c2, Vu, M_about_x, M_about_y)

    # Rails at both ends of each face, ≤ 2d apart on the first line (§11.11.5.3)
    n_rails = reinforcement_line_count(outer.c1, outer.c2, d, position)
    
    # Total Av per peripheral line
    Av_per_line = n_rails * As_stud_in2
    
    # Required spacing: vs = Av × fyt / (b0 × s) → s = Av × fyt / (b0 × vs)
    if vs_reqd > 0
        s_reqd = Av_per_line * fyt_psi / (b0_in * vs_reqd)
    else
        s_reqd = 0.75 * d_in  # Use max allowed if no steel required
    end
    
    # ACI 318-11 §11.11.5.2: spacing limits based on total factored shear stress
    # (a) s ≤ 0.75d when vu ≤ 6φ√f'c
    # (b) s ≤ 0.5d  when vu > 6φ√f'c
    high_stress = vu_psi > 6.0 * φ * sqrt_fc
    s_max = high_stress ? 0.5 * d_in : 0.75 * d_in
    s = min(s_reqd, s_max)
    
    # Check minimum reinforcement
    Av_s_min = minimum_stud_reinforcement(fc, b0, fyt)
    Av_s_min_val = ustrip(u"inch^2/inch", Av_s_min)
    Av_s_actual = Av_per_line / s
    if Av_s_actual < Av_s_min_val
        # Need to reduce spacing to meet minimum
        s = Av_per_line / Av_s_min_val
    end
    
    # First stud spacing (0.35d to 0.5d from column face)
    s0 = 0.5 * d_in
    
    # Actual vs provided
    vs_provided = Av_per_line * fyt_psi / (b0_in * s)
    
    # Peripheral lines until the section d/2 beyond the last line passes (§11.11.5.4)
    n_max = max_reinforcement_lines(s0 * u"inch", s * u"inch"; max_extent = max_extent)
    lines = design_outer_lines(s0 * u"inch", s * u"inch", d, fc, position, outer;
                               qu = qu, λ = λ, φ = φ, n_max = n_max)
    n_studs = lines.n
    outer_ok = lines.ok
    
    return ShearStudDesign(
        required = true,
        catalog_name = catalog_name,
        stud_diameter = actual_diameter_unit,
        fyt = fyt_unit,
        n_rails = n_rails,
        n_studs_per_rail = n_studs,
        s0 = s0 * u"inch",
        s = s * u"inch",
        Av_per_line = Av_per_line * u"inch^2",
        vs = vs_provided * u"psi",
        vcs = vcs * u"psi",
        vc_max = vc_max * u"psi",
        outer_ok = outer_ok
    )
end

"""
    check_punching_with_studs(vu, studs; φ=0.75)

Check punching shear adequacy with shear stud reinforcement.

# Returns
NamedTuple (ok, ratio, message)
"""
function check_punching_with_studs(vu::Pressure, studs::ShearStudDesign; φ::Float64 = 0.75)
    if !studs.required || studs.n_rails == 0
        return (ok=false, ratio=Inf, message="Studs not designed or inadequate")
    end
    
    vu_psi = ustrip(u"psi", vu)
    vcs_psi = ustrip(u"psi", studs.vcs)
    vs_psi = ustrip(u"psi", studs.vs)
    vc_max_psi = ustrip(u"psi", studs.vc_max)
    
    # Combined capacity
    vc_total = min(vcs_psi + vs_psi, vc_max_psi)
    
    ratio = vu_psi / (φ * vc_total)
    ok = ratio <= 1.0 && studs.outer_ok
    
    msg = if ok
        "OK (with studs): vu/φvc = $(round(ratio, digits=3))"
    elseif !studs.outer_ok
        "NG: Outer section fails - extend stud zone"
    else
        "NG (with studs): vu/φvc = $(round(ratio, digits=3)) > 1.0"
    end
    
    return (ok=ok, ratio=ratio, message=msg)
end

# =============================================================================
# Phase 6e: Moment Transfer Reinforcement (ACI 318-11 §13.5.3)
# =============================================================================

"""
    governing_transfer_reinforcement(Mux, Muy, c1, c2, h, d, fc, fy; position, free_edge_parallel)

ACI 318-11 §13.5.3.1 (corpus: aci-318-11, page 250): a fraction of the
unbalanced moment at the slab-column connection is transferred by flexure
in each direction.  γf from Eq. (13-1) / §13.5.3.2 uses `b1`, `b2` in the
direction of that moment.  `Mux` spans along the named `c1` and `Muy`
along the named `c2`; a free edge does not reassign those moments.
[`transfer_bands`](@ref) gives each its `b1`, `b2` and effective width.
Returns the governing `As` and the moment/γf that sized it.

`d` is the depth of the `Mux` layer.  `d_y` is the depth of the `Muy`
layer, the inner bar layer when `Muy` is the secondary span
(`inner_layer_effective_depth`); it defaults to `d`.

A non-finite input (moment, dimension or material) returns `As = NaN`, and
a non-finite `As` in either direction is returned as is (Inf before NaN),
so `transfer_section_inadequate` rejects it on every caller.  A NaN in one
direction must not lose the comparison to a finite `As` in the other.

`γf_x` / `γf_y` replace Eq. (13-1) for `Mux` / `Muy` when the punching check
took a §13.5.3.3 value for that moment (`moment_transfer_gamma_f`), so the
flexural fraction placed in the band is the complement of the γv the
punching check used.  The result also carries `As_x`, `As_y`, `bb_x`, `bb_y`
for the final §13.5.3.3(b) strain check on the placed steel.
"""
function governing_transfer_reinforcement(
    Mux::Moment, Muy::Moment,
    c1::Length, c2::Length, h::Length, d::Length,
    fc::Pressure, fy::Pressure;
    position::Symbol = :interior,
    free_edge_parallel::Symbol = :c2,
    γf_x::Union{Nothing, Float64} = nothing,
    γf_y::Union{Nothing, Float64} = nothing,
    d_y::Union{Nothing, Length} = nothing,
)
    dy = something(d_y, d)
    if !all(isfinite, (Mux, Muy, c1, c2, h, d, dy, fc, fy))
        Mu_bad = isfinite(Mux) ? Muy : Mux
        return (As = NaN * u"inch^2", Mu = Mu_bad, γf = NaN, bb = NaN * u"inch")
    end
    bands = transfer_bands(c1, c2, h, d; position, free_edge_parallel)
    γfx = something(γf_x, gamma_f(bands.b1_x, bands.b2_x))
    γfy = something(γf_y, gamma_f(bands.b1_y, bands.b2_y))
    function _as_for(Mu, γf, bb, depth)
        abs(ustrip(kip * u"ft", Mu)) < 1e-6 && return 0.0 * u"inch^2"
        transfer_reinforcement(abs(Mu), γf, bb, depth, fc, fy)
    end
    bb_x, bb_y = bands.bb_x, bands.bb_y
    As_x = _as_for(Mux, γfx, bb_x, d)
    As_y = _as_for(Muy, γfy, bb_y, dy)
    if isinf(As_x)
        return (As = Inf * u"inch^2", Mu = Mux, γf = γfx, bb = bb_x)
    end
    if isinf(As_y)
        return (As = Inf * u"inch^2", Mu = Muy, γf = γfy, bb = bb_y)
    end
    if isnan(As_x) || isnan(As_y)
        return (As = NaN * u"inch^2", Mu = isnan(As_x) ? Mux : Muy,
                γf = NaN, bb = isnan(As_x) ? bb_x : bb_y)
    end
    per_axis = (As_x = As_x, As_y = As_y, bb_x = bb_x, bb_y = bb_y)
    if ustrip(u"inch^2", As_y) > ustrip(u"inch^2", As_x)
        return (As = As_y, Mu = Muy, γf = γfy, bb = bb_y, axis = :y, per_axis...)
    end
    return (As = As_x, Mu = Mux, γf = γfx, bb = bb_x, axis = :x, per_axis...)
end

"""
    transfer_bands(c1, c2, h, d; position=:interior, free_edge_parallel=:c2)
        -> (b1_x, b2_x, b1_y, b2_y, bb_x, bb_y)

Critical-section sides and §13.5.3.2 effective widths for `Mux` (`_x`,
spanning along the named `c1`) and `Muy` (`_y`, along the named `c2`).
The moments stay on those axes. `b1` is the critical-section side in the
span of that moment (ACI 318-11 §13.5.3.2, corpus: aci-318-11, page 250).

`bb` is 1.5h beyond each column face that has slab (R13.5.3). A moment
spanning perpendicular to a free edge has slab on both sides of its band
(`c_parallel + 3h`; StructurePoint exterior column, corpus:
sp-de-two-way-flat-plate-aci318-14, page 18). A moment spanning along a
free edge, and both moments at a corner, have slab on one side
(`c_transverse + 1.5h`).
"""
function transfer_bands(c1::Length, c2::Length, h::Length, d::Length;
                        position::Symbol = :interior,
                        free_edge_parallel::Symbol = :c2)
    if position === :interior
        return (b1_x = c1 + d, b2_x = c2 + d, bb_x = c2 + 3h,
                b1_y = c2 + d, b2_y = c1 + d, bb_y = c1 + 3h)
    elseif position === :corner
        return (b1_x = c1 + d / 2, b2_x = c2 + d / 2, bb_x = c2 + 1.5h,
                b1_y = c2 + d / 2, b2_y = c1 + d / 2, bb_y = c1 + 1.5h)
    elseif position === :edge
        free_edge_parallel in (:c1, :c2) ||
            throw(ArgumentError("free_edge_parallel must be :c1 or :c2; got :$free_edge_parallel"))
        # The moment spanning perpendicular to the edge takes the full band.
        if free_edge_parallel === :c1
            return (b1_x = c1 + d,     b2_x = c2 + d / 2, bb_x = c2 + 1.5h,
                    b1_y = c2 + d / 2, b2_y = c1 + d,     bb_y = c1 + 3h)
        end
        return (b1_x = c1 + d / 2, b2_x = c2 + d,     bb_x = c2 + 3h,
                b1_y = c2 + d,     b2_y = c1 + d / 2, bb_y = c1 + 1.5h)
    end
    throw(ArgumentError("position must be :interior, :edge or :corner; got :$position"))
end

"""
    transfer_section_inadequate(As) -> Bool

True when `governing_transfer_reinforcement` returned a non-finite `As`
(Inf: section cannot develop the required transfer steel; NaN: the demand
itself was not finite).  The iterative pipeline treats this as
`converged=false` / `needs_more_depth`; rule-of-thumb records the same
`transfer_reinforcement` failure.  Do not skip the column.
"""
transfer_section_inadequate(As) = !isfinite(As)

"""
    transfer_reinforcement(Mu, γf, bb, d, fc, fy)

Required reinforcement for moment transfer by flexure (ACI 318-11 §13.5.3).
"""
function transfer_reinforcement(
    Mu::Moment,
    γf::Float64,
    bb::Length,
    d::Length,
    fc::Pressure,
    fy::Pressure
)
    # Moment to be transferred by flexure
    Mu_transfer = γf * Mu
    
    # Required reinforcement within effective width
    As_req = required_reinforcement(Mu_transfer, bb, d, fc, fy; εt_min = tension_controlled_strain(fy))
    
    return As_req
end

"""
    additional_transfer_bars(As_transfer, As_provided, bb, strip_width, bar_area)

Calculate additional reinforcement needed at column for moment transfer.

# Arguments
- `As_transfer`: Required As within effective width bb
- `As_provided`: Total As provided in strip
- `bb`: Effective slab width
- `strip_width`: Full strip width (column or middle strip)
- `bar_area`: Area per bar

# Returns
NamedTuple (As_within_bb, As_additional, n_bars_additional)

# Reference
- StructurePoint Table 8
"""
function additional_transfer_bars(
    As_transfer::Area,
    As_provided::Area,
    bb::Length,
    strip_width::Length,
    bar_area::Area
)
    # Portion of provided reinforcement within bb (proportional)
    # bb/strip_width is dimensionless
    As_within_bb = As_provided * (bb / strip_width)
    
    # Additional area needed
    As_additional = max(0.0 * bar_area, As_transfer - As_within_bb)
    
    # Number of additional bars (As_additional/bar_area is dimensionless)
    n_bars = ceil(Int, As_additional / bar_area)
    
    return (
        As_within_bb = As_within_bb,
        As_additional = As_additional,
        n_bars_additional = n_bars
    )
end

# =============================================================================
# Phase 6b: Structural Integrity Reinforcement (ACI 318-11 §13.3.8.5)
# =============================================================================
#
# Structural integrity reinforcement prevents progressive collapse by requiring
# bottom bars that pass continuously through or within the column core.
# This ensures a "cable" mechanism if the slab loses support at a column.

"""
    integrity_reinforcement(
        tributary_area::Area,
        qD::LinearLoad,
        qL::LinearLoad,
        fy::Pressure;
        load_factor::Float64 = 2.0
    ) -> NamedTuple

Calculate required structural integrity reinforcement per ACI 318-11 §13.3.8.5.

The required steel area provides tensile capacity to carry the reaction force
from the tributary area under a progressive collapse scenario.

# Arguments
- `tributary_area`: Area supported by the column connection
- `qD`: Dead load per unit area
- `qL`: Live load per unit area  
- `fy`: Reinforcement yield strength
- `load_factor`: Safety factor (default 2.0 per ACI)

# Returns
Named tuple with:
- `As_integrity`: Minimum bottom steel area passing through column core (in²)
- `Pu_integrity`: Factored reaction force the steel must resist (kip)

# Notes
- Bottom bars must pass through or be anchored within the column core
- Applies to all column types (interior, edge, corner)
- This is in addition to flexural reinforcement requirements

# Reference
- ACI 318-11 §13.3.8.5: Two-way slab structural integrity
- ACI 318-11 R13.3.8: Commentary on progressive collapse resistance
"""
function integrity_reinforcement(
    tributary_area::Area,
    qD::Pressure,  # psf type loads
    qL::Pressure,
    fy::Pressure;
    load_factor::Float64 = 2.0
)
    # Factored load on tributary area
    # ACI uses approximately 2×(D+L) for progressive collapse scenario
    w_total = qD + qL
    Pu = load_factor * w_total * tributary_area
    
    # Required steel area: As ≥ Pu / (ϕ × fy)
    # Using ϕ = 0.9 for tension
    ϕ = 0.9
    As_required = Pu / (ϕ * fy)
    
    return (
        As_integrity = uconvert(u"inch^2", As_required),
        Pu_integrity = uconvert(kip, Pu)
    )
end

"""
    check_integrity_reinforcement(
        As_bottom_provided::Area,
        As_integrity_required::Area
    ) -> NamedTuple

Check if provided bottom reinforcement satisfies integrity requirements.

# Arguments
- `As_bottom_provided`: Total area of bottom bars passing through column core
- `As_integrity_required`: Required area from `integrity_reinforcement()`

# Returns
Named tuple with:
- `ok`: Bool - true if check passes
- `utilization`: Float64 - ratio of required to provided
"""
function check_integrity_reinforcement(
    As_bottom_provided::Area,
    As_integrity_required::Area
)
    # Ratio is dimensionless; add small epsilon in same units to avoid div by zero
    utilization = As_integrity_required / max(As_bottom_provided, 1e-6 * As_integrity_required)
    
    return (
        ok = As_bottom_provided >= As_integrity_required,
        utilization = utilization
    )
end


