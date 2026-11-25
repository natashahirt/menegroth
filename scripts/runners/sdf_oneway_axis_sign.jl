#=
Is the one-way tributary partition AXIS-SIGN invariant?

A one-way slab spans identically along axis a or -a, so get_tributary_polygons
MUST give the same per-edge profile for axis=a and axis=-a. The e0c0 design
stores axis=(0,1) on EVERY cell (mirror cells included), so if the partition is
sign-dependent (fixed-handed left-normal sweep n=(-u_y,u_x)), a cell and its
reflection both get (0,1) and partition non-covariantly -> the e0c0 chirality.

Pure geometry, NO design. Tests several asymmetric polygons.

    SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
        julia --project=StructuralStudies scripts/runners/sdf_oneway_axis_sign.jl
=#

include(joinpath(@__DIR__, "sdf_rib_design.jl"))
import Meshes
_r(x) = round(x; digits = 4)

P(x, y) = Meshes.Point(Float64(x) * u"m", Float64(y) * u"m", 0.0u"m")

"""Per-edge (profile_s, profile_w) for a polygon under a given axis."""
_profiles(V, axis) = [(copy(t.profile_s), copy(t.profile_w))
                      for t in Asap.get_tributary_polygons(V; axis = collect(Float64, axis))]

function _cmp(label, pa, pb)
    worst = 0.0
    for i in eachindex(pa)
        sa, wa = pa[i]; sb, wb = pb[i]
        if length(sa) == length(sb) && length(wa) == length(wb)
            worst = max(worst, isempty(sa) ? 0.0 : maximum(abs.(sa .- sb); init = 0.0),
                        isempty(wa) ? 0.0 : maximum(abs.(wa .- wb); init = 0.0))
        else
            worst = Inf
        end
    end
    println("  [", label, "] axis (0,1) vs (0,-1): worst per-edge |Δ| = ",
            worst == Inf ? "LENGTH MISMATCH (sign-dependent)" : string(_r(worst)))
    worst > 1e-6 && for i in eachindex(pa)
        println("      e$i  (0,1): s=", _r.(pa[i][1]), " w=", _r.(pa[i][2]))
        println("      e$i  (0,-1):s=", _r.(pb[i][1]), " w=", _r.(pb[i][2]))
    end
    return worst
end

function main()
    println("\n===== ONE-WAY PARTITION AXIS-SIGN INVARIANCE =====")
    cases = Dict(
        # Asymmetric triangle (like an e0c0 hub wedge).
        "hub-wedge tri" => [P(12, 10), P(18, 15), P(12, 15)],
        # Right triangle.
        "right tri"     => [P(0, 0), P(6, 0), P(6, 5)],
        # Asymmetric quad.
        "asym quad"     => [P(0, 0), P(6, 0), P(5, 4), P(1, 3)],
    )
    overall = 0.0
    for (name, V) in cases
        pa = _profiles(V, (0.0, 1.0))
        pb = _profiles(V, (0.0, -1.0))
        overall = max(overall, _cmp(name, pa, pb))
    end
    println("\nVERDICT: ", overall <= 1e-6 ?
        "partition IS axis-sign invariant => sign is NOT the carrier." :
        "partition is AXIS-SIGN DEPENDENT (Δ=$(_r(overall))) => mirror cells sharing axis=(0,1) partition non-covariantly => THE e0c0 chirality carrier.")
    println("===== END =====\n")
end

main()
