# =============================================================================
# Diaphragm design forces
# =============================================================================
# Inertial force from ASCE 7-22 §12.10.1.1, then the shear and chord of a
# uniform load spanning between lines of vertical elements. Concrete shear
# and chord strength (ACI 318-19 §12.5) are not in this file: the equation
# glyphs in the corpus text layer for that section did not survive extraction.

"""
    diaphragm_inertial_force(Fi, wi, wpx, SDS, Ie; F_analysis=0) -> NamedTuple

Diaphragm inertial design force at one level, in one direction.

`Fi` and `wi` run from this level through the roof. `wpx` is the weight
tributary to the diaphragm and may differ from the matching entry of `wi`.

# Reference
ASCE 7-22 §12.10.1.1, Eqs. (12.10-1), (12.10-2), and (12.10-3)
(corpus: asce-7-22, PDF pp. 190–191). Eq. (12.10-3) limits Eq. (12.10-1)
and does not limit `F_analysis` when the analysis force is larger.

Transfer forces, and the §12.4.3 increase of a Table 12.3-1 Type 4
transfer, are not included. The caller adds them to `F_design`.
"""
function diaphragm_inertial_force(Fi, wi, wpx, SDS, Ie; F_analysis = 0.0)
    n = length(Fi)
    length(wi) == n || throw(ArgumentError(
        "diaphragm force: $(length(Fi)) story forces and $(length(wi)) weights."))
    n >= 1 || throw(ArgumentError("diaphragm force: no stories were given."))
    wpx = float(wpx)
    SDS = float(SDS)
    Ie = float(Ie)
    F_analysis = float(F_analysis)
    for (name, x) in (("wpx", wpx), ("SDS", SDS), ("Ie", Ie), ("F_analysis", F_analysis))
        isfinite(x) || throw(ArgumentError("diaphragm force: $name is not finite."))
    end
    wpx > 0 || throw(ArgumentError("diaphragm force: wpx must be positive, got $wpx."))
    SDS >= 0 || throw(ArgumentError("diaphragm force: SDS must be at least 0, got $SDS."))
    Ie > 0 || throw(ArgumentError("diaphragm force: Ie must be positive, got $Ie."))
    F_analysis >= 0 || throw(ArgumentError(
        "diaphragm force: the analysis force must be at least 0, got $F_analysis."))
    sum_w = 0.0
    sum_F = 0.0
    for k in 1:n
        Fk = float(Fi[k])
        wk = float(wi[k])
        isfinite(Fk) && isfinite(wk) || throw(ArgumentError(
            "diaphragm force: story $k has a non-finite force or weight."))
        wk > 0 || throw(ArgumentError(
            "diaphragm force: story $k weight must be positive, got $wk."))
        Fk >= 0 || throw(ArgumentError(
            "diaphragm force: story $k force must be at least 0, got $Fk."))
        sum_w += wk
        sum_F += Fk
    end
    # Eq. (12.10-1). Eqs. (12.10-2) and (12.10-3) bound that result only.
    F_eq = sum_F / sum_w * wpx
    F_min = 0.2 * SDS * Ie * wpx
    F_max = 0.4 * SDS * Ie * wpx
    F_code = min(max(F_eq, F_min), F_max)
    return (
        F_eq = F_eq,
        F_min = F_min,
        F_max = F_max,
        F_code = F_code,
        F_design = max(F_code, F_analysis),
    )
end

"""
    diaphragm_bay_actions(Fpx, spans, depth) -> NamedTuple

Shear at each line of vertical elements, and the midspan moment and chord
force of each bay between those lines.

The inertial force is uniform along the span. Each bay is simply supported
on the lines at its ends, so a bay of length `s` carries `Fpx · s / L`,
its end shear is half of that, and its midspan moment is `f·s²/8` with
`f = Fpx / L`. The chord force is that moment divided by `depth`.

`line_shear` has one entry per line. An interior line receives the shears
from both bays that frame it. The shears sum to `Fpx`.

# Reference
ASCE 7-22 §12.10.1 (corpus: asce-7-22, PDF p. 190) requires design for the
shear and the bending produced by the design forces. The section does not
state a continuity factor between bays, so the bays are simple spans.
This is not the collector overstrength of §12.10.2.1.
"""
function diaphragm_bay_actions(Fpx, spans, depth)
    Fpx = float(Fpx)
    depth = float(depth)
    isfinite(Fpx) && isfinite(depth) || throw(ArgumentError(
        "diaphragm bays: Fpx and depth must be finite."))
    Fpx >= 0 || throw(ArgumentError("diaphragm bays: Fpx must be at least 0, got $Fpx."))
    depth > 0 || throw(ArgumentError("diaphragm bays: depth must be positive, got $depth."))
    isempty(spans) && throw(ArgumentError("diaphragm bays: no spans were given."))
    lengths = Float64[]
    for (i, s) in enumerate(spans)
        sl = float(s)
        isfinite(sl) || throw(ArgumentError("diaphragm bays: span $i is not finite."))
        sl > 0 || throw(ArgumentError("diaphragm bays: span $i must be positive, got $sl."))
        push!(lengths, sl)
    end
    L = sum(lengths)
    f = Fpx / L
    n = length(lengths)
    line_shear = zeros(n + 1)
    bay_moment = Vector{Float64}(undef, n)
    bay_chord = Vector{Float64}(undef, n)
    for i in 1:n
        shear = f * lengths[i] / 2
        moment = f * lengths[i]^2 / 8
        line_shear[i] += shear
        line_shear[i + 1] += shear
        bay_moment[i] = moment
        bay_chord[i] = moment / depth
    end
    return (
        line_shear = line_shear,
        bay_moment = bay_moment,
        bay_chord = bay_chord,
        load_per_length = f,
    )
end
