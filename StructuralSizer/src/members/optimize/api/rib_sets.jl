# ==============================================================================
# Rib sets: one web and one bottom bar size for a set of rib pieces
# ==============================================================================
# A rib set is a line of waffle rib pieces, or one group of one-way joists.
# The overall depth is fixed by the story. The set shares a web width and a
# bottom bar size, so each rib is prismatic and its bottom bars run through.
# Each piece takes the fewest bottom bars of that size that pass its own
# demand, and its own top bars for hogging.

"""
    rib_set_webs(h, hf, joist_spacing; webs) -> Vector{Length}

Web widths of `webs` (inches) that ACI 318-11 §8.13 joist construction allows
at overall depth `h`, topping `hf`, and center spacing `joist_spacing`
(corpus: aci-318-11, PDF page 120):

- §8.13.2: width at least 4 in, and stem `h − hf` at most 3.5 times the width;
- §8.13.3: clear spacing `joist_spacing − bw` at most 30 in.
"""
function rib_set_webs(h::Length, hf::Length, joist_spacing::Length;
                      webs = [4.0, 5.0, 6.0, 7.0, 8.0])
    stem = ustrip(u"inch", h) - ustrip(u"inch", hf)
    s_in = ustrip(u"inch", joist_spacing)
    stem > 0 || throw(ArgumentError("rib depth $h must exceed the topping $hf"))
    out = typeof(1.0u"inch")[]
    for w in webs
        w >= 4.0 || continue
        stem <= 3.5 * w + 1e-9 || continue
        0 < s_in - w <= 30.0 + 1e-9 || continue
        push!(out, Float64(w) * u"inch")
    end
    return out
end

"""
    rib_section_carbon(sec, concrete, rebar, L) -> kgCO₂e

Embodied carbon of one rib piece of length `L`: the stem below the topping,
`bw (h − hf)`, plus its longitudinal bars. The topping is the slab's and is
not counted. Stirrups are not counted.
"""
function rib_section_carbon(sec::RCTBeamSection, concrete::Concrete, rebar, L::Length)
    Ac = sec.bw * (sec.h - sec.hf)
    As = sec.As + sec.As_prime
    Vc = uconvert(u"m^3", Ac * L)
    Vs = uconvert(u"m^3", As * L)
    return uconvert(u"kgCO2e", Vc * concrete.ρ * concrete.ecc + Vs * rebar.ρ * rebar.ecc)
end

# ==============================================================================
# Per-section capacity memo (speed; bit-identical)
# ==============================================================================
# `size_rib_set` builds a fresh `RCTBeamSection` for every (web, bar size, bar
# count, piece) trial, and every rib set is re-sized across many stem-screen
# rounds and member-iteration passes. The capacities ACI 318-11 demands — φMn
# (§10.2), the hogging φMn⁻, φVn,max (Chapter 11), and the net tensile strain εt
# (§10.3.5) — are a pure function of the section geometry and the checker's
# material/strength configuration; they do not depend on a piece's demand. The
# same section+configuration therefore recurs on the order of millions of times
# across a design. This memo caches those precomputed capacities, keyed by every
# value `precompute_capacities!` reads. The feasibility decision (`is_feasible`)
# and the least-carbon pick are unchanged, so the installed sizing is byte-for-byte
# identical to recomputing the capacities on every trial.
const _RIB_CAP_MEMO = Dict{Any, NTuple{5, Float64}}()
const _RIB_CAP_MEMO_LOCK = ReentrantLock()

"""Value key over everything `precompute_capacities!` reads for one rib section + checker."""
@inline function _rib_cap_key(sec::RCTBeamSection, chk::ACIBeamChecker, mat)
    return (
        # Section geometry and reinforcement (every field but the display `name`,
        # which is a heap string that would defeat value equality).
        sec.bw, sec.h, sec.d, sec.bf, sec.hf, sec.cover,
        sec.As, sec.n_bars, sec.bar_size,
        sec.As_prime, sec.n_bars_prime, sec.bar_size_prime, sec.d_prime,
        sec.stirrup_size,
        # Material and checker configuration the capacity math depends on: fc for
        # φMn/φVn, fy for flexure, Es for nothing here but kept for completeness, λ
        # for the shear Vc, and the §8.13.8 joist-Vc inputs (spacing, direction,
        # whether stirrups are credited via `stirrup_shear`).
        fc_ksi(mat), chk.fy_ksi, chk.Es_ksi, chk.λ,
        chk.joist_spacing_in, chk.joist_direction, chk.stirrup_shear,
    )
end

"""
    _rib_section_capacities(chk, sec, mat, objective) -> (φMn, φMn_neg, φVn_max, εt, depth)

Memoized capacities for one rib section under `chk`. On a miss, runs the same
`precompute_capacities!` the fused trial loop ran and stores its results, so a
hit returns byte-identical values.
"""
function _rib_section_capacities(chk::ACIBeamChecker, sec::RCTBeamSection, mat, objective)
    key = _rib_cap_key(sec, chk, mat)
    return lock(_RIB_CAP_MEMO_LOCK) do
        hit = get(_RIB_CAP_MEMO, key, nothing)
        hit === nothing || return hit
        tmp = create_cache(chk, 1)
        precompute_capacities!(chk, tmp, [sec], mat, objective)
        v = (tmp.φMn[1], tmp.φMn_neg[1], tmp.φVn_max[1], tmp.εt[1], tmp.depths[1])
        _RIB_CAP_MEMO[key] = v
        return v
    end
end

"""
    size_rib_set(Mu, Vu, geometries, opts::ConcreteBeamOptions;
                 h, hf, flange_width, joist_spacing, Mu_neg, Nu,
                 stirrup_shear, webs, bar_sizes, cover, stirrup_size)
        -> NamedTuple

Size the pieces of one rib set at overall depth `h`.

Every candidate web from [`rib_set_webs`](@ref) and every bottom bar size in
`bar_sizes` is tried. For one (web, bar size), each piece takes the fewest
bottom bars of that size that fit one layer and pass the T-beam checker at its
own demand, the same `is_feasible` [`size_tbeams`](@ref) uses: sagging and
hogging strength, shear (with stirrups when `stirrup_shear[i]`, ACI 318-11
§8.13.8 for joists), §10.3.5, and §10.5. Top bars are the least single-layer
arrangement that carries that piece's hogging moment
([`required_top_steel`](@ref)); they are stored on the section as `As′`.

`flange_width(i, bw)` is piece `i`'s §8.12 flange at web `bw`.

Returns `(ok, bw, bar_size, sections, carbon, reason)`. `ok` is `false` when
no web and bar size pass every piece; `reason` names the first piece that
failed at the last candidate. `carbon` is [`rib_section_carbon`](@ref) summed
over the pieces.
"""
function size_rib_set(
    Mu::AbstractVector, Vu::AbstractVector, geometries::AbstractVector,
    opts::ConcreteBeamOptions;
    h::Length,
    hf::Length,
    flange_width::Function,
    joist_spacing::Length,
    Mu_neg::AbstractVector = Mu,
    Nu::AbstractVector = zeros_like(Vu),
    stirrup_shear::AbstractVector{Bool} = fill(true, length(Mu)),
    webs = [4.0, 5.0, 6.0, 7.0, 8.0],
    bar_sizes = [4, 5, 6, 7, 8],
    cover::Length = 0.75u"inch",
    stirrup_size::Int = 3,
)
    n = length(Mu)
    n > 0 || throw(ArgumentError("a rib set has at least one piece"))
    for (name, v) in (("Vu", Vu), ("geometries", geometries), ("Mu_neg", Mu_neg),
                      ("Nu", Nu), ("stirrup_shear", stirrup_shear))
        length(v) == n || throw(ArgumentError("$name has $(length(v)) entries for $n pieces"))
    end
    geoms = [to_concrete_geometry(g) for g in geometries]
    mat = opts.material
    fc_psi = ustrip(u"psi", mat.fc′)
    fy_psi = ustrip(u"psi", opts.rebar_material.Fy)
    # One checker per stirrup setting; demands are per piece.
    checkers = Dict{Bool, Any}()
    demands = Vector{Any}(undef, n)
    for flag in unique(stirrup_shear)
        idx = findall(==(flag), stirrup_shear)
        chk, dem = _tbeam_checker_and_demands(
            collect(Mu[idx]), collect(Vu[idx]), opts;
            Mu_neg = collect(Mu_neg[idx]), Nu = collect(Nu[idx]), Tu = Float64[],
            w_dead = nothing, w_live = nothing, defl_support = :simply_supported,
            defl_ξ = 2.0, sustained_live_fraction = opts.sustained_live_fraction,
            shell_spans = nothing, joist_spacing = joist_spacing,
            joist_direction = :one_way, stirrup_shear = flag,
            size_to_as_min = true)
        checkers[flag] = chk
        for (k, i) in enumerate(idx)
            demands[i] = dem[k]
        end
    end
    # One reusable single-slot cache per stirrup setting. Its material/strength
    # constants are set once, exactly as `precompute_capacities!` would; each trial
    # then writes only the memoized per-section capacities, so `is_feasible` sees
    # the same cache the fused precompute produced — at no per-trial allocation or
    # recompute cost.
    caches = Dict{Bool, ACIBeamCapacityCache}()
    for (flag, chk) in checkers
        c = create_cache(chk, 1)
        c.fc_ksi = fc_ksi(mat)
        c.fy_ksi = chk.fy_ksi
        c.Es_ksi = chk.Es_ksi
        caches[flag] = c
    end
    passes(sec, i) = begin
        flag = stirrup_shear[i]
        chk = checkers[flag]
        c = caches[flag]
        c.φMn[1], c.φMn_neg[1], c.φVn_max[1], c.εt[1], c.depths[1] =
            _rib_section_capacities(chk, sec, mat, opts.objective)
        is_feasible(chk, c, 1, sec, mat, demands[i], geoms[i])
    end
    cov_in = ustrip(u"inch", cover)
    d_stir = ustrip(u"inch", rebar(stirrup_size).diameter)

    best = nothing
    reason = "no web meets ACI 318-11 §8.13.2 and §8.13.3 at h = $(uconvert(u"inch", h))"
    for bw in rib_set_webs(h, hf, joist_spacing; webs)
        bfs = [flange_width(i, bw) for i in 1:n]
        if any(bf -> ustrip(u"inch", bf) + 1e-6 < ustrip(u"inch", bw), bfs)
            reason = "a flange is narrower than the $(uconvert(u"inch", bw)) web"
            continue
        end
        for bar in bar_sizes
            db = ustrip(u"inch", rebar(bar).diameter)
            n_max = _max_bars_in_width(ustrip(u"inch", bw), cov_in, d_stir, db, 0.75)
            n_max >= 1 || continue
            secs = Vector{RCTBeamSection}(undef, n)
            carbon = 0.0u"kgCO2e"
            ok = true
            for i in 1:n
                found = nothing
                for nb in 1:n_max
                    trial = RCTBeamSection(; bw, h, bf = bfs[i], hf, bar_size = bar,
                                           n_bars = nb, cover, stirrup_size)
                    passes(trial, i) || continue
                    found = _with_top_steel(trial, Mu_neg[i], fc_psi, fy_psi)
                    break
                end
                if found === nothing
                    ok = false
                    reason = "piece $i fails at web $(uconvert(u"inch", bw)) with #$bar bars"
                    break
                end
                secs[i] = found
                carbon += rib_section_carbon(found, mat, opts.rebar_material, geoms[i].L)
            end
            ok || continue
            if best === nothing || carbon < best.carbon
                best = (bw = bw, bar_size = bar, sections = secs, carbon = carbon)
            end
        end
    end
    best === nothing && return (ok = false, bw = nothing, bar_size = nothing,
                                sections = RCTBeamSection[], carbon = Inf * u"kgCO2e",
                                reason = reason)
    return (ok = true, bw = best.bw, bar_size = best.bar_size, sections = best.sections,
            carbon = best.carbon, reason = "")
end

"""`sec` with the least top bars that carry `Mu_neg`, or `sec` unchanged when there is no hogging."""
function _with_top_steel(sec::RCTBeamSection, Mu_neg, fc_psi::Float64, fy_psi::Float64)
    to_kipft(Mu_neg) > 0 || return sec
    top = required_top_steel(sec, Mu_neg; fc = fc_psi * u"psi", fy = fy_psi * u"psi")
    top === nothing && return sec
    return RCTBeamSection(; bw = sec.bw, h = sec.h, bf = sec.bf, hf = sec.hf,
                          bar_size = sec.bar_size, n_bars = sec.n_bars,
                          cover = sec.cover, stirrup_size = sec.stirrup_size,
                          bar_size_prime = top.bar_size, n_bars_prime = top.n_bars)
end

"""
    service_inertia(sec, Ma_pos, Ma_neg; Ec, Es, fr) -> (Ie, Ig)

Effective moment of inertia of a concrete beam element under its service
moments, ACI 318-11 §9.5.2.3 (corpus: aci-318-11, PDF p. 132):
`Ie = (Mcr/Ma)³ Ig + (1 − (Mcr/Ma)³) Icr ≤ Ig` (Eq. 9-8),
`Mcr = fr Ig / yt` (Eq. 9-9).

`Ma_pos` and `Ma_neg` are the largest sagging and hogging service moments
on the element, both as magnitudes. ENGINEERING JUDGMENT: an element takes
the Ie of the sign with the larger moment. Sagging cracks the bottom over
the transformed T (or rectangle); hogging cracks the top, with the top bars
`As_prime` in tension at `h − d_prime` and the web in compression. A hogging
element with no top bars has `Icr = 0` there.
"""
function service_inertia(sec::Union{RCTBeamSection, RCBeamSection}, Ma_pos, Ma_neg;
                         Ec, Es, fr)
    if sec isa RCTBeamSection
        bw = sec.bw
        Ig, ȳ = tbeam_gross_inertia(sec.bw, sec.bf, sec.hf, sec.h)
        Icr_pos = cracked_moment_of_inertia_tbeam(sec.As, sec.bw, sec.bf, sec.hf, sec.d, Ec, Es)
    else
        bw = sec.b
        Ig, ȳ = sec.b * sec.h^3 / 12, sec.h / 2
        Icr_pos = cracked_moment_of_inertia(sec.As, sec.b, sec.d, Ec, Es)
    end
    hog = to_kipft(Ma_neg) > to_kipft(Ma_pos)
    Ma = hog ? Ma_neg : Ma_pos
    yt = hog ? ȳ : sec.h - ȳ
    Icr = if !hog
        Icr_pos
    elseif ustrip(u"inch^2", sec.As_prime) > 0
        cracked_moment_of_inertia(sec.As_prime, bw, sec.h - sec.d_prime, Ec, Es)
    else
        0.0u"inch^4"
    end
    Mcr = fr * Ig / yt
    Ie = effective_moment_of_inertia(uconvert(u"N*m", Mcr), uconvert(u"N*m", Ma),
                                     uconvert(u"m^4", Ig), uconvert(u"m^4", Icr))
    return uconvert(u"m^4", Ie), uconvert(u"m^4", Ig)
end
