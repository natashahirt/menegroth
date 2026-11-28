# Composite deck floor: pick the lightest tabulated depth and gage of one
# Vulcraft profile that carries the wet concrete unshored and then carries the
# finished loads as a composite slab.
#
# Finished slab, SDI C-2017 §2.4.B (corpus: sdi-c-2017, PDF pp. 11–13, 20):
#   §2.4.B.4  load combinations of the building code; ASCE 7 when none applies
#   §2.4.B.5  simple spans unless the slab is designed for continuity
#   §2.4.B.6  f′c ≥ 3000 psi; topping ≥ 2 in
#   §2.4.B.7  deflection per the building code, Id from Appendix 5
#   §2.4.B.9  one-way shear, Eq. 2.4.7
#   §2.4.B.15 temperature and shrinkage steel, 0.00075 × concrete above deck
#
# The catalog moment Mno/Ω and the catalog Id are the only flexural and
# stiffness sources entered; Appendices 2–4 are not implemented. Both are
# printed for f′c = 3000 psi and 145 pcf concrete (Vulcraft 2VLI PDF p. 89).

# SDI C-2017 Appendix 5 transforms Id to steel with Es = 29,500 ksi
# (corpus: sdi-c-2017, PDF p. 43; Id = (Iu + Ic)/2, Eq. A5-5, PDF p. 44).
const _SDI_ES = 29500.0u"ksi"

"""
    deck_concrete_volume_per_area(profile, topping) -> Length

Concrete volume per plan area: the topping plus the ribs, `hr · wr / pitch`,
with `wr` the average rib width ([`deck_wr`](@ref)).
"""
function deck_concrete_volume_per_area(profile::CompositeDeckProfile, topping)
    return uconvert(u"m", topping) + profile.hr * deck_wr(profile) / profile.pitch
end

"""
    deck_slab_candidate(profile, total_depth, gage, span, sdl, live; concrete,
                        n_spans=nothing, live_deflection_limit=1/360,
                        superimposed_deflection_limit=nothing,
                        bearing_length=nothing, flanges=nothing,
                        end_reaction=nothing, interior_reaction=nothing) -> NamedTuple

Every check of one depth and gage, with `ok` true when all pass.

Loads are service-level pressures. `span` is used for the construction span,
the finished-slab moment and shear, and the deflection. Passing the beam
spacing center to center is longer than the clear span the construction
table prints, which is conservative for that check.

- Construction: the published maximum unshored clear span for `n_spans`
  (1, 2, or 3). `nothing` takes the shortest of the three columns, because
  the number of deck spans is not known (ENGINEERING JUDGMENT).
- Strength, ASD: ASCE 7-22 §2.4.1 combination 2a, `D + L` (corpus: asce-7-22,
  PDF p. 69). `D` is the slab and deck weight plus `sdl`. SDI C-2017
  §2.4.B.5 makes the slab a simple span: `M = w L²/8`, `V = w L/2`.
  Moment is checked against the catalog `Mno/Ω`. Shear is checked against
  the lesser of SDI Eq. 2.4.7c at the given `f′c` and the catalog `Vno/Ω`.
  At 3000 psi the equation reproduces every 2VLI and 3VLI catalog row. On
  1.5VL the catalog is 6–11 % below the equation with the Figure 2-1 area,
  for a reason not identified, so the catalog value is kept as a bound.
- Deflection: `5 w L⁴ / (384 Es Id)`, simple span, live load against
  `live_deflection_limit · L`. SDI's commentary calls span/360 under
  superimposed live load typically acceptable. `superimposed_deflection_limit`
  also limits `sdl + live`, which is how the Vulcraft superimposed-load table
  is limited.
- Minimums: `f′c ≥ 3000 psi` and topping `≥ 2 in` (§2.4.B.6).
- `As_temperature_shrinkage` is `0.00075 × topping × 12 in` per foot
  (§2.4.B.15.a.1). The 6×6–W1.4×W1.4 floor of that clause is not compared;
  the wire area is not in the corpus.

Bearing arguments follow [`select_unshored_deck_gage`](@ref).
"""
function deck_slab_candidate(profile::CompositeDeckProfile, total_depth, gage::Integer,
        span, sdl, live; concrete::Concrete,
        n_spans::Union{Nothing, Integer}=nothing,
        live_deflection_limit::Real=1/360,
        superimposed_deflection_limit::Union{Nothing, Real}=nothing,
        bearing_length=nothing, flanges=nothing,
        end_reaction=nothing, interior_reaction=nothing,
        cantilever=nothing)
    n_spans === nothing || Int(n_spans) in 1:3 || throw(ArgumentError(
        "n_spans must be 1, 2, 3, or nothing, got $n_spans."))
    # The unshored-span, Mno/Ω, and Id tables are printed for 145 lb/ft³
    # concrete. Heavier wet concrete shortens the unshored span and a lighter
    # mix lowers Id, so neither direction is conservative for every check.
    ρ = uconvert(u"lb/ft^3", concrete.ρ)
    abs(ρ - 145.0u"lb/ft^3") <= 0.5u"lb/ft^3" || throw(ArgumentError(
        "The Vulcraft deck tables are printed for 145 lb/ft³ concrete. " *
        "Got $(round(u"lb/ft^3", ρ; digits=1)); use NWC_4000_145 or another 145 lb/ft³ fill."))
    g = _require_gage(profile, gage)
    slab = composite_slab_catalog(profile, total_depth, g)
    L = uconvert(u"ft", span)
    L > 0u"ft" || throw(ArgumentError("Deck span must be positive."))

    # §2.4.B.6 minimums.
    fc_ok = concrete.fc′ >= 3000.0u"psi"
    topping_ok = slab.topping >= 2.0u"inch" - 1e-9u"inch"

    # Construction, unshored.
    spans = _unshored_row(profile, total_depth).spans[g]
    span_limit = (n_spans === nothing ? minimum(spans) : spans[Int(n_spans)]) * u"inch"
    construction_ok = span_limit >= uconvert(u"inch", L) - 1e-9u"inch"
    bearing = if bearing_length === nothing && flanges === nothing &&
                 end_reaction === nothing && interior_reaction === nothing
        (checked = false, ok = true)
    else
        n = n_spans === nothing ? throw(ArgumentError(
            "A bearing check needs n_spans to know whether there is an interior support.")) : Int(n_spans)
        end_cap = deck_web_crippling(profile, g; flanges, location=:end, bearing=bearing_length)
        ok = uconvert(u"lbf/ft", end_reaction) <= end_cap
        int_cap = nothing
        if n > 1
            interior_reaction === nothing && throw(ArgumentError(
                "Two or three spans need interior_reaction as well as end_reaction."))
            int_cap = deck_web_crippling(profile, g; flanges, location=:interior, bearing=bearing_length)
            ok &= uconvert(u"lbf/ft", interior_reaction) <= int_cap
        end
        (checked = true, ok = ok, end_Rn_over_Ω = end_cap, interior_Rn_over_Ω = int_cap)
    end

    # Self weight from the actual geometry and density.
    vol_c = deck_concrete_volume_per_area(profile, slab.topping)
    metal = profile.gages[g]
    w_self = uconvert(u"psf", vol_c * concrete.ρ * 1.0u"gn" + metal.w_dd)

    # ASD D + L on a simple span, per foot of width. A strip that ends on an
    # unframed opening is a cantilever: SDI C-2017 item 13, the deck is only a
    # form there and the slab takes wu L²/2 (see deck_cantilever_moment).
    w_asd = uconvert(u"psf", w_self + sdl + live)
    M_asd = uconvert(u"kip*ft/ft", w_asd * L^2 / 8)
    V_asd = uconvert(u"kip/ft", w_asd * L / 2)
    if cantilever !== nothing
        Lc = uconvert(u"ft", cantilever)
        Mu = deck_cantilever_moment(w_asd * 1u"ft", Lc).Mu
        M_asd = max(M_asd, uconvert(u"kip*ft/ft", Mu / 1u"ft"))
        V_asd = max(V_asd, uconvert(u"kip/ft", w_asd * Lc))
    end
    moment_ok = M_asd <= slab.Mno_over_Ω
    shear = deck_one_way_shear(profile, g, slab.topping, concrete.fc′, concrete.ρ; design=:asd)
    V_sdi = uconvert(u"kip/ft", shear.capacity / profile.pitch)
    V_allow = min(V_sdi, slab.Vno_over_Ω)
    shear_ok = V_asd <= V_allow

    # Deflection, simple span.
    EI = _SDI_ES * slab.I_d
    δ_of(w) = uconvert(u"inch", 5 * w * L^4 / (384 * EI))
    δ_live = δ_of(live)
    δ_super = δ_of(sdl + live)
    δ_live_allow = uconvert(u"inch", L * live_deflection_limit)
    live_defl_ok = δ_live <= δ_live_allow
    super_defl_ok = superimposed_deflection_limit === nothing ||
        δ_super <= uconvert(u"inch", L * superimposed_deflection_limit)

    ok = fc_ok && topping_ok && construction_ok && bearing.ok &&
         moment_ok && shear_ok && live_defl_ok && super_defl_ok
    failed = Symbol[]
    fc_ok || push!(failed, :fc_min)
    topping_ok || push!(failed, :topping_min)
    construction_ok || push!(failed, :unshored_span)
    bearing.ok || push!(failed, :web_crippling)
    moment_ok || push!(failed, :moment)
    shear_ok || push!(failed, :shear)
    live_defl_ok || push!(failed, :live_deflection)
    super_defl_ok || push!(failed, :superimposed_deflection)

    return (;
        ok, failed,
        profile = profile.name,
        concrete,
        total_depth = uconvert(u"inch", total_depth),
        topping = slab.topping,
        gage = g,
        deck_thickness = metal.t,
        self_weight = w_self,
        catalog_weight = slab.weight,
        concrete_volume_per_area = vol_c,
        span = L,
        n_spans,
        unshored_span_limit = span_limit,
        bearing,
        w_asd, M_asd, V_asd,
        Mno_over_Ω = slab.Mno_over_Ω,
        Vn_over_Ω = V_allow,
        sdi_Vn_over_Ω = V_sdi,
        catalog_Vno_over_Ω = slab.Vno_over_Ω,
        shear,
        I_d = slab.I_d,
        δ_live, δ_live_allow, δ_superimposed = δ_super,
        As_temperature_shrinkage = uconvert(u"inch^2/ft", 0.00075 * slab.topping * 12u"inch" / 1u"ft"),
        designed_for_continuity = false,
    )
end

"""
    size_composite_deck_slab(profile, span, sdl, live; concrete,
                             total_depth=nothing, kwargs...) -> NamedTuple

Lightest passing [`deck_slab_candidate`](@ref) over the listed gages and the
tabulated total depths of `profile` (only `total_depth` when it is given).
Lightest is the smallest self weight; ties go to the shallower slab. Throws
when nothing passes, naming the checks the lightest candidate failed.
"""
function size_composite_deck_slab(profile::CompositeDeckProfile, span, sdl, live;
        concrete::Concrete, total_depth=nothing, kwargs...)
    table = _SLAB_ASD_145[_deck_key(profile)]
    depths = if total_depth === nothing
        sort(collect(keys(table)))
    else
        key = _tabulated_inch(total_depth, keys(table))
        key === nothing && throw(ArgumentError(
            "Total slab depth is not tabulated for $(profile.name). " *
            "Tabulated total depths, inches: $(join(sort(collect(keys(table))), ", "))."))
        [key]
    end
    gages = [g for g in _BEARING_GAGES if haskey(profile.gages, g)]
    candidates = [deck_slab_candidate(profile, d * u"inch", g, span, sdl, live; concrete, kwargs...)
                  for d in depths for g in gages]
    by_weight(c) = (ustrip(u"psf", c.self_weight), ustrip(u"inch", c.total_depth))
    passing = filter(c -> c.ok, candidates)
    if isempty(passing)
        lightest = argmin(by_weight, candidates)
        throw(ArgumentError(
            "No $(profile.name) depth and gage passes at span $(round(u"ft", uconvert(u"ft", span); digits=2)). " *
            "The lightest candidate ($(lightest.total_depth), gage $(lightest.gage)) fails: " *
            "$(join(string.(lightest.failed), ", "))."))
    end
    return argmin(by_weight, passing)
end

function size_composite_deck_slab(name::AbstractString, span, sdl, live; kwargs...)
    return size_composite_deck_slab(composite_deck_profile(name), span, sdl, live; kwargs...)
end

"""
    deck_temperature_bars(As_per_width, thickness) -> NamedTuple

Temperature and shrinkage bars in the concrete above a composite deck.

SDI C-2017 §2.4.B.15.a.1 (corpus: sdi-c-2017, page 20) requires an area of
at least 0.00075 times that concrete, per foot or metre of width.
`As_per_width` is that area. The same sentence also names
6×6–W1.4×W1.4 as a floor. The wire cross-section is not in the corpus,
so this function does not compare it.

Spacing is ACI 318-11 §7.12.2.2 (corpus: aci-318-11, page 106): not farther
than five times the slab thickness, nor farther than 18 in. `thickness` is
the total slab depth. The sheet remains the positive flexural reinforcement.
"""
function deck_temperature_bars(As_per_width, thickness::Length)
    thickness > zero(thickness) || throw(ArgumentError(
        "deck temperature steel needs a positive slab thickness, got $thickness"))
    b = 1.0u"m"
    As = uconvert(u"m^2", As_per_width * b)
    As > zero(As) || throw(ArgumentError(
        "deck temperature area is not positive, got $As_per_width"))
    bars = select_bars(As, b; max_spacing = min(5 * thickness, 18.0u"inch"))
    mat = StripReinforcement(:pos, 0.0u"N*m", As, As,
        uconvert(u"m^2", bars.As_provided), bars.bar_size,
        uconvert(u"m", bars.spacing), bars.n_bars, true)
    none = StripReinforcement(:neg, 0.0u"N*m", 0.0u"m^2", 0.0u"m^2", 0.0u"m^2",
        bars.bar_size, 0.0u"m", 0, true)
    return (
        bars = (pos = mat, ext_neg = none, int_neg = none),
        reasons = [
            "SDI C-2017 §2.4.B.15.a.1: 0.00075 times the concrete above the deck",
            "6×6–W1.4×W1.4 was not checked; the wire area is not in the corpus",
            "ACI 318-11 §7.12.2.2: spacing at most five times the slab thickness, and 18 in",
        ],
        analysis = :temperature,
    )
end

"""
    _size_span_floor(::CompositeDeck, span, sdl, live; material, options)

Composite deck floor from [`size_composite_deck_slab`](@ref). The fill
concrete is `options.fill_material`, or `material` when that is `nothing`.
The checks are kept on the result.
"""
function _size_span_floor(::CompositeDeck, span::L, sdl::F, live::F;
                    material::Concrete=NWC_4000_145,
                    options::AbstractFloorOptions=CompositeDeckOptions(),
                    cantilever=nothing) where {L<:Length, F<:Pressure}
    opts = _require_options(CompositeDeckOptions, options, CompositeDeck())
    concrete = something(opts.fill_material, material)
    profile = composite_deck_profile(opts.deck_profile)
    best = size_composite_deck_slab(profile, span, sdl, live; concrete,
        cantilever = cantilever,
        total_depth = opts.total_depth,
        n_spans = opts.n_spans,
        live_deflection_limit = opts.live_deflection_limit,
        superimposed_deflection_limit = opts.superimposed_deflection_limit)
    ρ_steel = opts.deck_material.ρ
    steel_vol = uconvert(u"m", profile.gages[best.gage].w_dd / (ρ_steel * 1.0u"gn"))
    return CompositeDeckResult(
        profile.name,
        uconvert(u"m", profile.hr),
        best.gage,
        uconvert(u"m", best.topping),
        uconvert(u"m", best.total_depth),
        steel_vol,
        uconvert(u"m", best.concrete_volume_per_area),
        uconvert(u"Pa", best.self_weight),
        best,
    )
end
