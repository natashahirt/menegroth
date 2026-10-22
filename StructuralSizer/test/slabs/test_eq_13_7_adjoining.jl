# =============================================================================
# Per-column adjoining spans — ACI 318-11 §13.6.9.2 Eq. (13-7)
# =============================================================================
#
# Production one-panel DDM used to collapse every interior column to
# Mu = 0.07·0.5·q_Lu·ℓ2·ℓn² because no Slab defines `adjacent_slabs`.
# These oracles drive `_compute_column_demands_ddm` (the path used by
# the flat-plate pipeline and rule-of-thumb) on a duck-typed building
# whose skeleton, cells, and slabs are what that lookup reads.
#
# Eq. (13-7) (corpus: aci-318-11, page 258), primed = shorter span.
# Gravity envelope: §9.2.1 Eq. (9-1) 1.4D and Eq. (9-2) 1.2D+1.6L
# (corpus: aci-318-11, page 123).
# Successive spans: §13.6.1.3 (corpus: aci-318-11, page 252).
# =============================================================================

using Test
using Unitful
using Asap
using StructuralSizer

const SS = StructuralSizer

# Real-building oracles need StructuralSynthesizer.  Same optional-import
# pattern as test_aci_audit_tier1.jl.
const HAS_STRUCTURAL_SYNTHESIZER = let ok = true
    try
        @eval using StructuralSynthesizer
    catch
        ok = false
    end
    ok
end

"""
Two rectangular bays sharing a column at (west_ft, 0).

North panels run y = 0 to `y_ft`.  South panels (default) mirror them, so
the frame line is an interior column line and ℓ2 = `y_ft`
(§13.6.2.3: half + half).  `south=false` leaves only the north side:
§13.6.2.4 then sets ℓ2 = `y_ft` / 2.

Far supports sit on the frame line at x = 0 and x = west+east, same
column size, so the clear span is the center-to-center length minus
`c_in` (face to face, §13.6.2.5).

`north=true` adds a panel whose centroid lies on the column line
(perpendicular neighbour).  `ambiguous_east_ft` adds a second panel on
the +X side with that frame-line depth.
"""
function _two_bay(; west_ft::Float64, east_ft::Float64, y_ft::Float64 = 20.0,
                  c_in::Float64 = 12.0, c2_in::Float64 = c_in,
                  qD = 150.0psf, qL = 50.0psf,
                  qD_east = qD, qL_east = qL,
                  north::Bool = false, south::Bool = true, east::Bool = true,
                  position::Symbol = :interior,
                  θ::Float64 = 0.0,
                  ambiguous_east_ft::Union{Nothing,Float64} = nothing)
    m = 0.3048  # exact foot
    pts = NTuple{2,Float64}[]
    function V(x, y)
        push!(pts, (x * m, y * m))
        return length(pts)
    end
    v_fw = V(0.0, 0.0)
    v_col = V(west_ft, 0.0)
    v_fe = east ? V(west_ft + east_ft, 0.0) : 0
    v_wn = V(0.0, y_ft)
    v_cn = V(west_ft, y_ft)
    v_en = east ? V(west_ft + east_ft, y_ft) : 0
    faces = Vector{Int}[
        [v_fw, v_col, v_cn, v_wn],
    ]
    cells = Any[
        (face_idx = 1, sdl = qD, live_load = qL, self_weight = 0.0psf),
    ]
    if east
        push!(faces, [v_col, v_fe, v_en, v_cn])
        push!(cells, (face_idx = 2, sdl = qD_east, live_load = qL_east, self_weight = 0.0psf))
    end
    if south
        v_ws = V(0.0, -y_ft)
        v_cs = V(west_ft, -y_ft)
        push!(faces, [v_ws, v_cs, v_col, v_fw])
        push!(cells, (face_idx = length(faces), sdl = qD, live_load = qL, self_weight = 0.0psf))
        if east
            v_es = V(west_ft + east_ft, -y_ft)
            push!(faces, [v_cs, v_es, v_fe, v_col])
            push!(cells, (face_idx = length(faces), sdl = qD_east, live_load = qL_east, self_weight = 0.0psf))
        end
    end
    if north
        # Centroid x equals the column x, so this panel is not on either
        # side along the analysis direction.  Loads differ on purpose.
        vn0 = V(west_ft - 10.0, 0.0)
        vn1 = V(west_ft + 10.0, 0.0)
        vn2 = V(west_ft + 10.0, y_ft + 25.0)
        vn3 = V(west_ft - 10.0, y_ft + 25.0)
        push!(faces, [vn0, v_col, vn1, vn2, vn3])
        push!(cells, (
            face_idx = length(faces),
            sdl = 400.0psf, live_load = 200.0psf, self_weight = 0.0psf,
        ))
    end
    if !isnothing(ambiguous_east_ft)
        a1 = V(west_ft + ambiguous_east_ft, 0.0)
        a2 = V(west_ft + ambiguous_east_ft, y_ft)
        a3 = V(west_ft, y_ft)
        push!(faces, [v_col, a1, a2, a3])
        push!(cells, (
            face_idx = length(faces),
            sdl = qD_east, live_load = qL_east, self_weight = 0.0psf,
        ))
    end
    vc = zeros(length(pts), 2)
    for (i, p) in enumerate(pts)
        vc[i, 1] = p[1]
        vc[i, 2] = p[2]
    end
    c1 = c_in * u"inch"
    c2 = c2_in * u"inch"
    col = (
        vertex_idx = v_col,
        position = position,
        c1 = c1, c2 = c2, θ = θ,
        structural_offset = (0.0, 0.0),
    )
    # Far supports on the frame line, same size, so ℓn = ℓ_cc − c.
    col_w = (vertex_idx = v_fw, position = :interior, c1 = c1, c2 = c2, θ = θ,
             structural_offset = (0.0, 0.0))
    columns = Any[col, col_w]
    if east
        push!(columns, (
            vertex_idx = v_fe, position = :interior, c1 = c1, c2 = c2, θ = θ,
            structural_offset = (0.0, 0.0),
        ))
    end
    slab = (
        cell_indices = [1],
        spans = (primary = west_ft * u"ft", secondary = y_ft * u"ft", axis = (1.0, 0.0)),
    )
    slabs = Any[slab]
    for i in 2:length(cells)
        push!(slabs, (cell_indices = [i], spans = slab.spans))
    end
    struc = (
        cells = cells,
        slabs = slabs,
        columns = columns,
        skeleton = (
            geometry = (vertex_coords = vc,),
            face_vertex_indices = faces,
        ),
    )
    return (struc = struc, slab = slab, col = col)
end

"""
L-plan with the column under test at the re-entrant corner (SW, NW, SE
panels; NE missing), tagged `:corner`.  Along X the slab continues on both
sides of it (three quadrants).  Far supports on the X frame line are 12 in.
"""
function _lplan(west_ft, east_ft; qD = 150.0psf, qL = 50.0psf)
    mtr = 0.3048
    pts = NTuple{2,Float64}[]
    function V(x, y)
        push!(pts, (x * mtr, y * mtr))
        return length(pts)
    end
    y = 20.0
    a = V(0.0, 0.0); b = V(west_ft, 0.0); c = V(west_ft + east_ft, 0.0)
    d = V(0.0, y);   e = V(west_ft, y);   f = V(west_ft + east_ft, y)
    g = V(0.0, 2y);  h = V(west_ft, 2y)
    faces = Vector{Int}[
        [a, b, e, d],   # SW
        [d, e, h, g],   # NW
        [b, c, f, e],   # SE; NE is missing
    ]
    cells = [(face_idx = i, sdl = qD, live_load = qL, self_weight = 0.0psf) for i in 1:3]
    vc = zeros(length(pts), 2)
    for (i, p) in enumerate(pts)
        vc[i, 1] = p[1]; vc[i, 2] = p[2]
    end
    cdim = 12.0u"inch"
    col = (vertex_idx = e, position = :corner, c1 = cdim, c2 = cdim, θ = 0.0,
           structural_offset = (0.0, 0.0))
    far = [(vertex_idx = d, position = :edge, c1 = cdim, c2 = cdim, θ = 0.0,
            structural_offset = (0.0, 0.0)),
           (vertex_idx = f, position = :edge, c1 = cdim, c2 = cdim, θ = 0.0,
            structural_offset = (0.0, 0.0))]
    slab = (cell_indices = [1],
            spans = (primary = west_ft * u"ft", secondary = y * u"ft", axis = (1.0, 0.0)))
    struc = (cells = cells,
             slabs = [(cell_indices = [i], spans = slab.spans) for i in 1:3],
             columns = [col, far...],
             skeleton = (geometry = (vertex_coords = vc,), face_vertex_indices = faces))
    return (struc = struc, slab = slab, col = col)
end

function _interior_mub(fix, qD, qL; l2 = 20.0u"ft", ln_passed = 10.0u"ft",
                       columns = [fix.col], axis = (1.0, 0.0), γ = nothing, tc = nothing)
    qu = max(1.4 * qD, 1.2 * qD + 1.6 * qL)
    M0 = SS.total_static_moment(qu, l2, max(ln_passed, 1.0u"ft"))
    _, _, Mub = SS._compute_column_demands_ddm(
        fix.struc, columns,
        0.26 * M0, 0.65 * M0, 0.35 * M0,
        qu, qD, qL, l2, ln_passed, axis, M0;
        slab = fix.slab, γ = γ, tc = tc,
    )
    return Mub, M0
end

@testset "Eq. (13-7) per-column adjoining spans" begin
    qD = 150.0psf
    qL = 50.0psf
    ℓ2 = 20.0u"ft"
    # 29 ft and 20 ft center-to-center, 12 in columns → clear 28 ft and 19 ft.
    ℓn = 28.0u"ft"
    ℓnp = 19.0u"ft"
    # ACI 318-11 §9.2.1 Eq. (9-2) (page 123) inside Eq. (13-7) (page 258).
    qDu = 1.2 * qD
    qLu = 1.6 * qL
    expected_unequal = abs(0.07 * ((qDu + 0.5 * qLu) * ℓ2 * ℓn^2 - qDu * ℓ2 * ℓnp^2))
    equal_long = 0.07 * 0.5 * qLu * ℓ2 * ℓn^2

    @testset "a: unequal bays, not the equal-span collapse" begin
        @test ustrip(kip * u"ft", expected_unequal) ≈ 150.5 rtol = 1e-3
        @test ustrip(kip * u"ft", equal_long) ≈ 43.9 rtol = 1e-2

        fix = _two_bay(west_ft = 29.0, east_ft = 20.0)
        # Passed ℓn is intentionally wrong.  Geometry must supply 28 and 19.
        Mub, _ = _interior_mub(fix, qD, qL; ln_passed = 10.0u"ft")
        @test ustrip(kip * u"ft", Mub[1]) ≈ ustrip(kip * u"ft", expected_unequal) rtol = 1e-4
        @test ustrip(kip * u"ft", Mub[1]) > 3 * ustrip(kip * u"ft", equal_long)

        # Exterior column on the same call keeps §13.6.3.6, not Eq. (13-7).
        col_ext = (position = :corner,)
        Mub_e, M0 = _interior_mub(fix, qD, qL; columns = [fix.col, col_ext])
        @test ustrip(kip * u"ft", Mub_e[1]) ≈ ustrip(kip * u"ft", expected_unequal) rtol = 1e-4
        @test ustrip(kip * u"ft", Mub_e[2]) ≈ ustrip(kip * u"ft", 0.3 * M0) rtol = 1e-12
    end

    @testset "b: 1.4D governs qu but interior Mub stays the 1.2D+1.6L value" begin
        qD_b = 200.0psf
        qL_b = 20.0psf
        l2 = 20.0u"ft"
        ln = 24.0u"ft"
        @test 1.4 * qD_b > 1.2 * qD_b + 1.6 * qL_b
        col = (position = :interior,)
        qu = 1.4 * qD_b
        M0 = SS.total_static_moment(qu, l2, ln)
        _, _, Mub = SS._compute_column_demands_ddm(
            nothing, [col],
            0.26 * M0, 0.65 * M0, 0.35 * M0,
            qu, qD_b, qL_b, l2, ln, (1.0, 0.0), M0)
        # Eq. (9-2): equal spans → 0.07·0.5·(1.6 qL)·ℓ2·ℓn².  Eq. (9-1) is 0.
        hand = 0.07 * 0.5 * (1.6 * qL_b) * l2 * ln^2
        via_helper = SS.governing_interior_unbalanced_moment(
            qD_b, qL_b, l2, ln, qD_b, qL_b, l2, ln)
        @test ustrip(kip * u"ft", Mub[1]) > 0
        @test ustrip(kip * u"ft", Mub[1]) ≈ ustrip(kip * u"ft", hand) rtol = 1e-9
        @test ustrip(kip * u"ft", Mub[1]) ≈ ustrip(kip * u"ft", via_helper) rtol = 1e-12

        # Same envelope through the NLP entry, which has no stored geometry.
        mat = RC_4000_60
        wc = ustrip(pcf, mat.concrete.ρ)
        p = FlatPlateNLPProblem(
            mat, mat.concrete.fc′, mat.rebar.Fy, mat.rebar.E,
            Ec(mat.concrete.fc′, wc), mat.concrete.ρ, mat.concrete.λ,
            ln, l2, qD_b, qL_b,
            [:interior], [100.0], 3.0,
            0.65, 0.65, 0.35,
            0.75u"inch", bar_diameter(5),
            0.90, 0.75, :L_360,
            (6.0, 12.0), (10.0, 24.0),
            [5], MinVolume(),
        )
        # qD passed above is already total dead (no separate self-weight).
        mub_nlp = SS._nlp_transfer_moment(p, 1, qD_b, qL_b, l2, ln, (1.0, 0.0),
                                          12.0u"inch", M0)
        @test ustrip(kip * u"ft", mub_nlp) ≈ ustrip(kip * u"ft", hand) rtol = 1e-9
        # The removed `_nlp_interior_mub` passed M0 = nothing; the real path
        # gives a non-interior column 0.3 M0 (§13.6.3.6), not a MethodError.
        @test !isdefined(SS, :_nlp_interior_mub)
        p_edge = FlatPlateNLPProblem(
            mat, mat.concrete.fc′, mat.rebar.Fy, mat.rebar.E,
            Ec(mat.concrete.fc′, wc), mat.concrete.ρ, mat.concrete.λ,
            ln, l2, qD_b, qL_b,
            [:edge], [100.0], 3.0,
            0.26, 0.70, 0.52,
            0.75u"inch", bar_diameter(5),
            0.90, 0.75, :L_360,
            (6.0, 12.0), (10.0, 24.0),
            [5], MinVolume(),
        )
        mub_edge = SS._nlp_transfer_moment(p_edge, 1, qD_b, qL_b, l2, ln, (1.0, 0.0),
                                           12.0u"inch", M0)
        @test ustrip(kip * u"ft", mub_edge) ≈ ustrip(kip * u"ft", 0.3 * M0) rtol = 1e-12
    end

    @testset "c: equal bays collapse to 0.07·0.5·q_Lu·ℓ2·ℓn²" begin
        fix = _two_bay(west_ft = 29.0, east_ft = 29.0)
        Mub, _ = _interior_mub(fix, qD, qL; ln_passed = 10.0u"ft")
        @test ustrip(kip * u"ft", Mub[1]) ≈ ustrip(kip * u"ft", equal_long) rtol = 1e-4
        @test ustrip(kip * u"ft", Mub[1]) < 0.5 * ustrip(kip * u"ft", expected_unequal)
    end

    @testset "d: perpendicular neighbour does not change the result" begin
        fix = _two_bay(west_ft = 29.0, east_ft = 20.0, north = true)
        Mub, _ = _interior_mub(fix, qD, qL; ln_passed = 10.0u"ft")
        @test ustrip(kip * u"ft", Mub[1]) ≈ ustrip(kip * u"ft", expected_unequal) rtol = 1e-4
    end

    @testset "ambiguous same-side panels fail closed" begin
        # An extra east face runs past the far column (x = 49 ft) to 55 ft.
        # Cycle 10a: spans come from the column layout, so this no longer
        # throws on two face depths.  The far column lies partway along that
        # face's edge, so its neighbourhood is ambiguous: the transfer is the
        # traced envelope max(0.3 M0, Eq. (13-7)) with ℓn to the far column
        # face (§13.6.2.5, page 253), not a throw.
        fix = _two_bay(west_ft = 29.0, east_ft = 20.0, ambiguous_east_ft = 26.0)
        tc = TraceCollector()
        qu = max(1.4 * qD, 1.2 * qD + 1.6 * qL)
        M0 = SS.total_static_moment(qu, ℓ2, 10.0u"ft")
        _, _, Mub = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
            SS._compute_column_demands_ddm(fix.struc, [fix.col], 0.26 * M0, 0.65 * M0,
                                           0.35 * M0, qu, qD, qL, ℓ2, 10.0u"ft",
                                           (1.0, 0.0), M0; slab = fix.slab, tc = tc)
        end
        @test ustrip(kip * u"ft", Mub[1]) >= ustrip(kip * u"ft", expected_unequal) * (1 - 1e-4)
        @test ustrip(kip * u"ft", Mub[1]) >= ustrip(kip * u"ft", 0.3 * M0)
        @test any(e -> get(e.data, "reason", "") == "far_support_ambiguous", tc.events)
        @test any(e -> get(e.data, "reason", "") == "uncertain_far_support_envelope", tc.events)
    end

    @testset "successive spans §13.6.1.3" begin
        # 30 ft vs 18 ft center-to-center: |30-18| = 12 > 30/3 = 10.
        bad = _two_bay(west_ft = 30.0, east_ft = 18.0, qL = 40.0psf)
        r_bad = SS.check_ddm_applicability(bad.struc, bad.slab, [bad.col];
                                            throw_on_failure = false)
        @test any(v -> occursin("13.6.1.3", v), r_bad.violations)

        ok = _two_bay(west_ft = 29.0, east_ft = 29.0, qL = 40.0psf)
        r_ok = SS.check_ddm_applicability(ok.struc, ok.slab, [ok.col];
                                           throw_on_failure = false)
        @test !any(v -> occursin("13.6.1.3", v), r_ok.violations)
    end

    @testset "edges: zero load, missing geometry" begin
        col = (position = :interior,)
        z = 0.0psf
        M0 = 0.0kip * u"ft"
        _, _, Mub0 = SS._compute_column_demands_ddm(
            nothing, [col], M0, M0, M0,
            z, z, z, 20.0u"ft", 20.0u"ft", (1.0, 0.0), M0)
        @test ustrip(kip * u"ft", Mub0[1]) ≈ 0.0 atol = 1e-12

        # Column with no vertex: geometry cannot place it, equal-span of
        # the passed panel (not a throw).
        bare = (
            cells = [(face_idx = 1, sdl = qD, live_load = qL, self_weight = 0.0psf)],
            slabs = [(cell_indices = [1], spans = (primary = 20.0u"ft", secondary = 20.0u"ft", axis = (1.0, 0.0)))],
            skeleton = (
                geometry = (vertex_coords = zeros(1, 2),),
                face_vertex_indices = [[1]],
            ),
        )
        slab = bare.slabs[1]
        col_nv = (position = :interior, vertex_idx = 0, c1 = 12.0u"inch", c2 = 12.0u"inch")
        ln = 20.0u"ft"
        l2 = 20.0u"ft"
        qu = 1.2 * qD + 1.6 * qL
        M0b = SS.total_static_moment(qu, l2, ln)
        _, _, Mub_nv = SS._compute_column_demands_ddm(
            bare, [col_nv], 0.26 * M0b, 0.65 * M0b, 0.35 * M0b,
            qu, qD, qL, l2, ln, (1.0, 0.0), M0b; slab = slab)
        hand = SS.governing_interior_unbalanced_moment(qD, qL, l2, ln, qD, qL, l2, ln)
        @test ustrip(kip * u"ft", Mub_nv[1]) ≈ ustrip(kip * u"ft", hand) rtol = 1e-9
    end

    @testset "negative bracket takes the heavier short span" begin
        # ACI 318-11 R13.6.9 (page 258) names only full dead + half live on
        # the longer span.  ENGINEERING JUDGMENT: the reverse pattern is
        # also evaluated.  ℓn = 22 ft at 60/100 psf against ℓn' = 20 ft at
        # 200/100 psf, ℓ2 = 20 ft.  1.4D of the commentary pattern is 99.9
        # kip·ft; half live on the heavy short span under Eq. (9-2) is 130.4.
        fix = _two_bay(west_ft = 23.0, east_ft = 21.0,
                       qD = 60.0psf, qL = 100.0psf,
                       qD_east = 200.0psf, qL_east = 100.0psf)
        ℓn = 22.0u"ft"
        ℓnp = 20.0u"ft"
        ℓ2 = 20.0u"ft"
        # Eq. (9-2), live on the 20 ft span (corpus: aci-318-11, pages 123 and 258).
        rev = 0.07 * ((1.2 * 200.0psf + 0.5 * 1.6 * 100.0psf) * ℓ2 * ℓnp^2 -
                      1.2 * 60.0psf * ℓ2 * ℓn^2)
        commentary = 0.07 * ((1.4 * 60.0psf) * ℓ2 * ℓn^2 - (1.4 * 200.0psf) * ℓ2 * ℓnp^2)
        @test ustrip(kip * u"ft", abs(rev)) ≈ 130.4 rtol = 1e-3
        @test ustrip(kip * u"ft", abs(commentary)) ≈ 99.9 rtol = 1e-2
        Mub, _ = _interior_mub(fix, 60.0psf, 100.0psf)
        @test ustrip(kip * u"ft", Mub[1]) ≈ ustrip(kip * u"ft", abs(rev)) rtol = 1e-3
        @test ustrip(kip * u"ft", Mub[1]) > ustrip(kip * u"ft", abs(commentary)) + 20.0
    end

    @testset "same-side panels with different live loads" begin
        # §13.6.1.5 (page 252) is per panel.  Two east panels share the
        # span and carry 100 psf and 50 psf.  Line load is Σ q·ℓ2
        # (ENGINEERING JUDGMENT), not a throw.
        fix = _two_bay(west_ft = 20.0, east_ft = 20.0)
        cells = Any[c for c in fix.struc.cells]
        cells[2] = merge(cells[2], (live_load = 100.0psf,))  # east north
        struc = merge(fix.struc, (cells = cells,))
        fix2 = (struc = struc, slab = fix.slab, col = fix.col)
        ℓn = 19.0u"ft"   # 20 ft c-c, 12 in columns, §13.6.2.5
        # East tributaries 10 ft + 10 ft (§13.6.2.3).  West is 50 psf over 20 ft.
        wL_east = 100.0psf * 10.0u"ft" + 50.0psf * 10.0u"ft"
        hand = 0.07 * (0.5 * 1.6 * wL_east) * ℓn^2
        Mub, _ = _interior_mub(fix2, 150.0psf, 50.0psf)
        @test ustrip(kip * u"ft", Mub[1]) ≈ ustrip(kip * u"ft", hand) rtol = 1e-3
        # Not the full-width 100 psf reading, and not a §13.6.1.3 label.
        full = 0.07 * (0.5 * 1.6 * 100.0psf * 20.0u"ft") * ℓn^2
        @test ustrip(kip * u"ft", Mub[1]) < ustrip(kip * u"ft", full) - 5.0
        r = SS.check_ddm_applicability(struc, fix.slab, [fix.col]; throw_on_failure = false)
        @test !any(v -> occursin("13.6.1.3", v), r.violations)
    end

    @testset "ambiguous geometry is not labeled §13.6.1.3" begin
        # Cycle 10a: the overrunning face is enveloped (above), not an
        # Eq. (13-7) applicability error, and the column-layout spans (29 vs
        # 20 ft, 9 ≤ 29/3) are no §13.6.1.3 violation.
        fix = _two_bay(west_ft = 29.0, east_ft = 20.0, ambiguous_east_ft = 26.0)
        r = SS.check_ddm_applicability(fix.struc, fix.slab, [fix.col]; throw_on_failure = false)
        @test !any(v -> occursin("13.6.9.2", v), r.violations)
        @test !any(v -> occursin("13.6.1.3", v), r.violations)
    end

    @testset "§13.6.2.4 edge strip uses edge-to-centerline" begin
        # Slab only on the north side of the frame line.  ℓ2 = y/2 = 10 ft
        # (ACI 318-11 §13.6.2.4, corpus: aci-318-11, page 253), so the
        # 29/20 ft moment is half of the interior 150.5 kip·ft.
        fix = _two_bay(west_ft = 29.0, east_ft = 20.0, south = false, position = :edge)
        half = abs(0.07 * ((1.2 * qD + 0.5 * 1.6 * qL) * 10.0u"ft" * (28.0u"ft")^2 -
                           1.2 * qD * 10.0u"ft" * (19.0u"ft")^2))
        Mub, M0 = _interior_mub(fix, qD, qL; l2 = 20.0u"ft", ln_passed = 19.0u"ft")
        @test ustrip(kip * u"ft", half) ≈ 75.25 rtol = 1e-3
        @test ustrip(kip * u"ft", Mub[1]) ≈ ustrip(kip * u"ft", half) rtol = 1e-3
        # Perpendicular to the edge: one side, §13.6.3.6, not Eq. (13-7).
        Mub_y, M0y = _interior_mub(fix, qD, qL; axis = (0.0, 1.0),
                                   l2 = 20.0u"ft", ln_passed = 19.0u"ft")
        @test ustrip(kip * u"ft", Mub_y[1]) ≈ ustrip(kip * u"ft", 0.3 * M0y) rtol = 1e-9
        @test abs(ustrip(kip * u"ft", Mub_y[1]) - ustrip(kip * u"ft", half)) > 1.0
    end

    @testset "edge-column inset shortens only the end span" begin
        # 24 ft interior bay and 20 ft end bay, 20 in columns, ℓ2 = 20 ft,
        # qD = 150 / qL = 50 psf.  The edge column is inset by c/2 = 10 in.
        # Without the inset, ℓn' = 18.333 ft and Mu ≈ 68.9 kip·ft.
        # With it, ℓn' = 17.5 ft and Mu ≈ 76.5 kip·ft.
        m = 0.3048
        c = 20.0u"inch"
        inset = 10.0 / 12.0 * m   # meters, inward
        pts = NTuple{2,Float64}[]
        function V(x, y)
            push!(pts, (x * m, y * m))
            return length(pts)
        end
        y = 20.0
        v0 = V(0.0, 0.0);  v1 = V(24.0, 0.0); v2 = V(44.0, 0.0)
        n0 = V(0.0, y);    n1 = V(24.0, y);   n2 = V(44.0, y)
        s0 = V(0.0, -y);   s1 = V(24.0, -y);  s2 = V(44.0, -y)
        faces = Vector{Int}[
            [v0, v1, n1, n0],
            [v1, v2, n2, n1],
            [s0, s1, v1, v0],
            [s1, s2, v2, v1],
        ]
        cell = (sdl = qD, live_load = qL, self_weight = 0.0psf)
        cells = [(face_idx = i, cell...) for i in 1:4]
        vc = zeros(length(pts), 2)
        for (i, p) in enumerate(pts)
            vc[i, 1] = p[1]; vc[i, 2] = p[2]
        end
        col = (vertex_idx = v1, position = :interior, c1 = c, c2 = c, θ = 0.0,
               structural_offset = (0.0, 0.0))
        col_w = (vertex_idx = v0, position = :interior, c1 = c, c2 = c, θ = 0.0,
                 structural_offset = (0.0, 0.0))
        col_e = (vertex_idx = v2, position = :edge, c1 = c, c2 = c, θ = 0.0,
                 structural_offset = (-inset, 0.0))
        slab = (cell_indices = [1],
                spans = (primary = 24.0u"ft", secondary = 20.0u"ft", axis = (1.0, 0.0)))
        struc = (
            cells = cells,
            slabs = [(cell_indices = [i], spans = slab.spans) for i in 1:4],
            columns = [col, col_w, col_e],
            skeleton = (geometry = (vertex_coords = vc,), face_vertex_indices = faces),
        )
        ℓn = 24.0u"ft" - 20.0u"inch"
        ℓnp = 20.0u"ft" - 10.0u"inch" - 20.0u"inch"  # inset plus both faces
        ℓ2 = 20.0u"ft"
        hand = abs(0.07 * ((1.2 * qD + 0.5 * 1.6 * qL) * ℓ2 * ℓn^2 -
                           1.2 * qD * ℓ2 * ℓnp^2))
        no_inset = abs(0.07 * ((1.2 * qD + 0.5 * 1.6 * qL) * ℓ2 * ℓn^2 -
                               1.2 * qD * ℓ2 * (20.0u"ft" - 20.0u"inch")^2))
        @test ustrip(u"ft", ℓnp) ≈ 17.5 rtol = 1e-6
        @test ustrip(kip * u"ft", hand) ≈ 76.5 rtol = 1e-2
        @test ustrip(kip * u"ft", no_inset) ≈ 68.9 rtol = 1e-2
        Mub, _ = _interior_mub((struc = struc, slab = slab, col = col), qD, qL)
        @test ustrip(kip * u"ft", Mub[1]) ≈ ustrip(kip * u"ft", hand) rtol = 1e-3
        @test ustrip(kip * u"ft", Mub[1]) > ustrip(kip * u"ft", no_inset) + 5.0
    end

    @testset "frame-line depth ignores off-line noise and a 2° skew" begin
        function grid(xs, ys; pert = Dict{Tuple{Int,Int},Tuple{Float64,Float64}}())
            mtr = 0.3048
            vid = Dict{Tuple{Int,Int},Int}()
            pts = NTuple{2,Float64}[]
            for (i, x) in enumerate(xs), (j, y) in enumerate(ys)
                d = get(pert, (i, j), (0.0, 0.0))
                push!(pts, ((x + d[1]) * mtr, (y + d[2]) * mtr))
                vid[(i, j)] = length(pts)
            end
            faces = Vector{Int}[]
            cells = Any[]
            for i in 1:length(xs)-1, j in 1:length(ys)-1
                push!(faces, [vid[(i, j)], vid[(i+1, j)], vid[(i+1, j+1)], vid[(i, j+1)]])
                push!(cells, (face_idx = length(faces), sdl = qD, live_load = qL,
                              self_weight = 0.0psf))
            end
            vc = zeros(length(pts), 2)
            for (k, p) in enumerate(pts)
                vc[k, 1] = p[1]; vc[k, 2] = p[2]
            end
            cols = [(vertex_idx = vid[k], position = :interior, c1 = 12.0u"inch",
                     c2 = 12.0u"inch", θ = 0.0, structural_offset = (0.0, 0.0))
                    for k in keys(vid)]
            spans = (primary = 29.0u"ft", secondary = 20.0u"ft", axis = (1.0, 0.0))
            slabs = [(cell_indices = [k], spans = spans) for k in 1:length(cells)]
            struc = (cells = cells, slabs = slabs, columns = cols,
                     skeleton = (geometry = (vertex_coords = vc,),
                                 face_vertex_indices = faces))
            col = first(c for c in cols if c.vertex_idx == vid[(2, 2)])
            return (struc = struc, slab = slabs[1], col = col)
        end
        xs = [0.0, 29.0, 49.0]
        ys = [0.0, 20.0, 44.0]
        # ℓ2 = 10 + 12 = 22 ft (§13.6.2.3).  Clear 28 ft and 19 ft.
        hand = abs(0.07 * ((1.2 * qD + 0.5 * 1.6 * qL) * 22.0u"ft" * (28.0u"ft")^2 -
                           1.2 * qD * 22.0u"ft" * (19.0u"ft")^2))
        base = grid(xs, ys)
        Mub, _ = _interior_mub(base, qD, qL)
        @test ustrip(kip * u"ft", Mub[1]) ≈ ustrip(kip * u"ft", hand) rtol = 1e-3
        noisy = grid(xs, ys; pert = Dict((3, 3) => (0.1, 0.0)))
        Mub_n, _ = _interior_mub(noisy, qD, qL)
        @test ustrip(kip * u"ft", Mub_n[1]) ≈ ustrip(kip * u"ft", hand) rtol = 1e-3
        sh = 24.0 * tan(deg2rad(2.0))
        skewed = grid(xs, ys; pert = Dict((1, 3) => (sh, 0.0), (2, 3) => (sh, 0.0),
                                           (3, 3) => (sh, 0.0)))
        Mub_s, _ = _interior_mub(skewed, qD, qL)
        @test ustrip(kip * u"ft", Mub_s[1]) ≈ ustrip(kip * u"ft", hand) rtol = 1e-3
    end

    @testset "rectangular column θ rotates the clear span" begin
        # c1 = 24 in along local x, c2 = 12 in along local y.
        # θ = 0 deducts c1 along global X.  θ = 90° deducts c2.
        # ACI 318-11 §13.6.2.5 (page 253).  Equal 20 ft bays, ℓ2 = 20 ft.
        aligned = _two_bay(west_ft = 20.0, east_ft = 20.0, c_in = 24.0, c2_in = 12.0, θ = 0.0)
        turned = _two_bay(west_ft = 20.0, east_ft = 20.0, c_in = 24.0, c2_in = 12.0, θ = π / 2)
        function live_only(ln)
            return 0.07 * 0.5 * (1.6 * qL) * 20.0u"ft" * ln^2
        end
        M_a, _ = _interior_mub(aligned, qD, qL)
        M_t, _ = _interior_mub(turned, qD, qL)
        @test ustrip(kip * u"ft", M_a[1]) ≈ ustrip(kip * u"ft", live_only(18.0u"ft")) rtol = 1e-3
        @test ustrip(kip * u"ft", M_t[1]) ≈ ustrip(kip * u"ft", live_only(19.0u"ft")) rtol = 1e-3
    end

    @testset "one-sided interior column is an edge, not a repeated panel" begin
        fix = _two_bay(west_ft = 29.0, east_ft = 20.0, east = false)
        Mub, M0 = _interior_mub(fix, qD, qL; l2 = 20.0u"ft", ln_passed = 28.0u"ft")
        repeated = 0.07 * 0.5 * (1.6 * qL) * 20.0u"ft" * (28.0u"ft")^2
        @test ustrip(kip * u"ft", Mub[1]) ≈ ustrip(kip * u"ft", 0.3 * M0) rtol = 1e-9
        @test abs(ustrip(kip * u"ft", Mub[1]) - ustrip(kip * u"ft", repeated)) > 20.0
    end

    @testset "re-entrant corner uses max(Eq. 13-7, 0.3 M0)" begin
        # L-plan: three  quadrants.  ENGINEERING JUDGMENT — R13.6.9 does not
        # discuss this.  Continuous both ways along X, so Eq. (13-7) is
        # computed, then compared with §13.6.3.6.
        lplan(west_ft, east_ft) = _lplan(west_ft, east_ft; qD = qD, qL = qL)
        # Equal 20 ft bays.  West ℓ2 = 20 ft (two panels), east ℓ2 = 10 ft
        # (one panel).  Eq. (13-7) is below 0.3 M0, so the corner governs.
        eq = lplan(20.0, 20.0)
        ℓn = 19.0u"ft"
        wD_w = qD * 20.0u"ft"; wL_w = qL * 20.0u"ft"
        wD_e = qD * 10.0u"ft"; wL_e = qL * 10.0u"ft"
        mu_eq = abs(0.07 * ((1.2 * wD_w + 0.5 * 1.6 * wL_w) * ℓn^2 - 1.2 * wD_e * ℓn^2))
        Mub, M0 = _interior_mub(eq, qD, qL; l2 = 20.0u"ft", ln_passed = 19.0u"ft")
        @test ustrip(kip * u"ft", mu_eq) < ustrip(kip * u"ft", 0.3 * M0)
        @test ustrip(kip * u"ft", Mub[1]) ≈ ustrip(kip * u"ft", 0.3 * M0) rtol = 1e-9

        # 30 ft against 18 ft.  Eq. (13-7) exceeds 0.3 M0.
        big = lplan(30.0, 18.0)
        lnw = 29.0u"ft"; lne = 17.0u"ft"
        mu_big = abs(0.07 * ((1.2 * wD_w + 0.5 * 1.6 * wL_w) * lnw^2 -
                             1.2 * wD_e * lne^2))
        Mub2, M02 = _interior_mub(big, qD, qL; l2 = 20.0u"ft", ln_passed = 29.0u"ft")
        @test ustrip(kip * u"ft", mu_big) > ustrip(kip * u"ft", 0.3 * M02)
        @test ustrip(kip * u"ft", Mub2[1]) ≈ ustrip(kip * u"ft", mu_big) rtol = 1e-3
    end

    @testset "drop panel dead load is on qD and factored per combination" begin
        # 1.4D governs the bare panel.  A flat 1.2 on the drop would understate qu.
        dp = DropPanelGeometry(4.0u"inch", 5.0u"ft", 5.0u"ft")
        ρ = NWC_4000.ρ
        panel = 20.0u"ft" * 20.0u"ft"
        q_drop = SS._eq137_drop_service(dp, panel, ρ)
        # h·γ·g spread by A_drop/A_panel = 100/400.
        sw4 = SS.slab_self_weight(4.0u"inch", ρ)
        @test ustrip(psf, q_drop) ≈ ustrip(psf, 0.25 * sw4) rtol = 1e-6
        qD_bare = 200.0psf
        qL_bare = 20.0psf
        qD2, qu2, _ = SS._eq137_with_drop(qD_bare, qL_bare, 20.0u"ft", 20.0u"ft", dp, panel, ρ)
        @test ustrip(psf, qD2) ≈ ustrip(psf, qD_bare + q_drop) rtol = 1e-6
        @test 1.4 * qD2 > 1.2 * qD2 + 1.6 * qL_bare
        @test ustrip(psf, qu2) ≈ ustrip(psf, 1.4 * qD2) rtol = 1e-6
        @test ustrip(psf, qu2) > ustrip(psf, 1.4 * qD_bare + 1.2 * q_drop)

        # Neighbour slab carries the drop; the design panel does not.
        fix = _two_bay(west_ft = 20.0, east_ft = 20.0)
        slabs = Any[]
        for (i, sl) in enumerate(fix.struc.slabs)
            push!(slabs, i in (2, 4) ? merge(sl, (drop_panel = dp,)) : sl)
        end
        struc = merge(fix.struc, (slabs = slabs,))
        fixd = (struc = struc, slab = fix.slab, col = fix.col)
        ℓn = 19.0u"ft"
        ℓ2 = 20.0u"ft"
        qDe = qD + q_drop
        hand = abs(0.07 * ((1.2 * qDe + 0.5 * 1.6 * qL) * ℓ2 * ℓn^2 -
                           1.2 * qD * ℓ2 * ℓn^2))
        Mub, _ = _interior_mub(fixd, qD, qL; γ = ρ)
        @test ustrip(kip * u"ft", Mub[1]) ≈ ustrip(kip * u"ft", hand) rtol = 1e-3
    end

    @testset "neighbour self-weight comes from the slab thickness" begin
        # cell.self_weight is still 0.  The east slab has a committed thickness.
        fix = _two_bay(west_ft = 20.0, east_ft = 20.0,
                       qD = 100.0psf, qL = 50.0psf,
                       qD_east = 40.0psf, qL_east = 50.0psf)
        ρ = NWC_4000.ρ
        h = 8.0u"inch"
        sw = SS.slab_self_weight(h, ρ)   # h · γ · g
        slabs = Any[]
        for (i, sl) in enumerate(fix.struc.slabs)
            push!(slabs, i in (2, 4) ? merge(sl, (result = (thickness = h,),)) : sl)
        end
        struc = merge(fix.struc, (slabs = slabs,))
        fixs = (struc = struc, slab = fix.slab, col = fix.col)
        ℓn = 19.0u"ft"
        ℓ2 = 20.0u"ft"
        qDe = 40.0psf + sw
        # Eq. (9-2): half live on the heavier dead side (the east).
        hand = abs(0.07 * ((1.2 * qDe + 0.5 * 1.6 * 50.0psf) * ℓ2 * ℓn^2 -
                           1.2 * 100.0psf * ℓ2 * ℓn^2))
        Mub, _ = _interior_mub(fixs, 100.0psf, 50.0psf; γ = ρ)
        @test ustrip(kip * u"ft", Mub[1]) ≈ ustrip(kip * u"ft", hand) rtol = 1e-3
    end

    @testset "NLP transfer is direction-aware when geometry is stored" begin
        fix = _two_bay(west_ft = 29.0, east_ft = 20.0, south = false, position = :edge)
        mat = RC_4000_60
        wc = ustrip(pcf, mat.concrete.ρ)
        idx = SS._eq137_vertex_cell_index(fix.struc)
        p = FlatPlateNLPProblem(
            mat, mat.concrete.fc′, mat.rebar.Fy, mat.rebar.E,
            Ec(mat.concrete.fc′, wc), mat.concrete.ρ, mat.concrete.λ,
            28.0u"ft", 20.0u"ft", qD, qL,
            [:edge], [100.0], 3.0,
            0.65, 0.70, 0.35,
            0.75u"inch", bar_diameter(5),
            0.90, 0.75, :L_360,
            (6.0, 12.0), (10.0, 24.0),
            [5], MinVolume(),
            (struc = fix.struc, slab = fix.slab, columns = [fix.col],
             span_axis = (1.0, 0.0), index = idx),
        )
        half = abs(0.07 * ((1.2 * qD + 0.5 * 1.6 * qL) * 10.0u"ft" * (28.0u"ft")^2 -
                           1.2 * qD * 10.0u"ft" * (19.0u"ft")^2))
        M0 = SS.total_static_moment(1.2 * qD + 1.6 * qL, 20.0u"ft", 19.0u"ft")
        # Parallel to the edge: Eq. (13-7) with §13.6.2.4 ℓ2, not 0.3 M0.
        Mx = SS._nlp_transfer_moment(p, 1, qD, qL, 20.0u"ft", 28.0u"ft",
                                     (1.0, 0.0), 12.0u"inch", M0)
        @test ustrip(kip * u"ft", Mx) ≈ ustrip(kip * u"ft", half) rtol = 1e-3
        @test abs(ustrip(kip * u"ft", Mx) - ustrip(kip * u"ft", 0.3 * M0)) > 1.0
        # Perpendicular: §13.6.3.6.
        My = SS._nlp_transfer_moment(p, 1, qD, qL, 28.0u"ft", 19.0u"ft",
                                     (0.0, 1.0), 12.0u"inch", M0)
        @test ustrip(kip * u"ft", My) ≈ ustrip(kip * u"ft", 0.3 * M0) rtol = 1e-9
        # No stored building: position :edge stays 0.3 M0 in both directions.
        p0 = FlatPlateNLPProblem(
            mat, mat.concrete.fc′, mat.rebar.Fy, mat.rebar.E,
            Ec(mat.concrete.fc′, wc), mat.concrete.ρ, mat.concrete.λ,
            19.0u"ft", 20.0u"ft", qD, qL,
            [:edge], [100.0], 3.0,
            0.65, 0.70, 0.35,
            0.75u"inch", bar_diameter(5),
            0.90, 0.75, :L_360,
            (6.0, 12.0), (10.0, 24.0),
            [5], MinVolume(),
        )
        Mx0 = SS._nlp_transfer_moment(p0, 1, qD, qL, 20.0u"ft", 19.0u"ft",
                                      (1.0, 0.0), 12.0u"inch", M0)
        @test ustrip(kip * u"ft", Mx0) ≈ ustrip(kip * u"ft", 0.3 * M0) rtol = 1e-12
    end
end

# -----------------------------------------------------------------------------
# Real BuildingStructure oracles.  gen_medium_office is a 3×3 bay flat plate.
# Each moment below is written out from §13.6.9.2 / §9.2.1 / §13.6.2 / §13.6.3.6,
# measured on that skeleton's structural centers.  It does not call
# `governing_interior_unbalanced_moment`.
# -----------------------------------------------------------------------------

"""Magnitude of the Eq. (13-7) envelope, both patterns and both §9.2.1 combos.

ACI 318-11 §13.6.9.2 Eq. (13-7) (corpus: aci-318-11, page 258) and §9.2.1
Eq. (9-1) 1.4D, Eq. (9-2) 1.2D+1.6L (page 123).  ENGINEERING JUDGMENT: live
is tried on each span, and the larger magnitude is kept.  R13.6.9 (page 258)
names only the pattern with the longer span loaded.
"""
function _hand_eq137(qD_a, qL_a, ℓ2_a, ℓn_a, qD_b, qL_b, ℓ2_b, ℓn_b)
    best = 0.0 * kip * u"ft"
    for (Df, Lf) in ((1.2, 1.6), (1.4, 0.0))
        for (qD, qL, ℓ2, ℓn, qDo, ℓ2o, ℓno) in (
            (qD_a, qL_a, ℓ2_a, ℓn_a, qD_b, ℓ2_b, ℓn_b),
            (qD_b, qL_b, ℓ2_b, ℓn_b, qD_a, ℓ2_a, ℓn_a),
        )
            Mu = 0.07 * ((Df * qD + 0.5 * Lf * qL) * ℓ2 * ℓn^2 -
                         Df * qDo * ℓ2o * ℓno^2)
            if abs(Mu) > abs(best)
                best = Mu
            end
        end
    end
    return abs(uconvert(kip * u"ft", best))
end

"""Eq. (13-4) total static moment.  ACI 318-11 §13.6.2.2 (page 253)."""
_hand_M0(qu, ℓ2, ℓn) = uconvert(kip * u"ft", qu * ℓ2 * ℓn^2 / 8)

@testset "real BuildingStructure Eq. (13-7) oracles" begin
    if !HAS_STRUCTURAL_SYNTHESIZER
        @info "Skipping real-building Eq. (13-7) oracles — StructuralSynthesizer not available."
        @test true
    else
        # 72 ft / 3 bays is stored as 7.32 m (gen_medium_office rounds to 0.01 m).
        h = 8.0u"inch"
        ρ = NWC_4000.ρ
        ax = (1.0, 0.0)
        ay = (0.0, 1.0)

        function _xy(struc, col)
            vc = struc.skeleton.geometry.vertex_coords
            i = col.vertex_idx
            o = col.structural_offset
            return (vc[i, 1] + Float64(o[1]), vc[i, 2] + Float64(o[2]))
        end

        function _office()
            skel = gen_medium_office(72.0u"ft", 72.0u"ft", 9.0u"ft", 3, 3, 1)
            struc = BuildingStructure(skel)
            initialize!(struc; material = NWC_4000, floor_type = :flat_plate,
                        floor_opts = FlatPlateOptions(method = DDM()))
            slab = first(struc.slabs)
            cols = SS.find_supporting_columns(struc, Set(slab.cell_indices))
            return struc, slab, cols
        end

        function _lines(cols, struc)
            xs = sort(unique(round.([_xy(struc, c)[1] for c in cols], digits = 4)))
            ys = sort(unique(round.([_xy(struc, c)[2] for c in cols], digits = 4)))
            return xs, ys
        end

        function _nearest(cols, struc, x, y)
            best, bd = cols[1], Inf
            for c in cols
                p = _xy(struc, c)
                d = hypot(p[1] - x, p[2] - y)
                if d < bd
                    best, bd = c, d
                end
            end
            return best
        end

        function _pressures(struc, slab)
            cell = struc.cells[first(slab.cell_indices)]
            qD = uconvert(psf, cell.sdl) + SS.slab_self_weight(h, ρ)
            qL = uconvert(psf, cell.live_load)
            return qD, qL
        end

        function _mub(res, cols, col)
            i = findfirst(c -> c.vertex_idx == col.vertex_idx, cols)
            return res.unbalanced_moments[i]
        end

        function _analyze(struc, slab, cols)
            fc′ = NWC_4000.fc′
            Ecs = SS.Ec(NWC_4000)
            mx = SS.run_moment_analysis(DDM(), struc, slab, cols, h, fc′, Ecs, ρ)
            my = SS.run_secondary_moment_analysis(DDM(), struc, slab, cols, h, fc′, Ecs, ρ)
            return mx, my
        end

        function _poly(struc, ci)
            fi = struc.cells[ci].face_idx
            vis = struc.skeleton.face_vertex_indices[fi]
            vc = struc.skeleton.geometry.vertex_coords
            return [(vc[v, 1], vc[v, 2]) for v in vis]
        end

        function _cells_at(struc, slab, col)
            vi = col.vertex_idx
            out = Int[]
            for ci in slab.cell_indices
                fi = struc.cells[ci].face_idx
                vi in struc.skeleton.face_vertex_indices[fi] && push!(out, ci)
            end
            return out
        end

        # ℓ2 on each side of the frame line: sum of edge-to-centerline
        # distances (§13.6.2.1, §13.6.2.3, §13.6.2.4, page 253).
        function _side_ℓ2(struc, col, axis, cis)
            origin = _xy(struc, col)
            perp = (-axis[2], axis[1])
            acc = Dict(-1 => 0.0u"ft", 1 => 0.0u"ft")
            for ci in cis
                poly = _poly(struc, ci)
                n = length(poly)
                c = (sum(p[1] for p in poly) / n, sum(p[2] for p in poly) / n)
                along = (c[1] - origin[1]) * axis[1] + (c[2] - origin[2]) * axis[2]
                abs(along) < 0.05 && continue
                side = along > 0 ? 1 : -1
                ts = [(p[1] - origin[1]) * perp[1] + (p[2] - origin[2]) * perp[2]
                      for p in poly]
                lo, hi = minimum(ts), maximum(ts)
                trib_m = (lo < -1e-6 && hi > 1e-6) ? (hi - lo) : abs((lo + hi) / 2)
                acc[side] += uconvert(u"ft", trib_m * u"m")
            end
            return acc
        end

        # Face-to-face ℓn to the next column on the frame line (§13.6.2.5).
        function _side_ℓn(struc, cols, col, axis; half = 0.0u"inch")
            origin = _xy(struc, col)
            out = Dict{Int,typeof(1.0u"ft")}()
            for side in (1, -1)
                dir = (side * axis[1], side * axis[2])
                best = nothing
                for c in cols
                    c.vertex_idx == col.vertex_idx && continue
                    p = _xy(struc, c)
                    d = (p[1] - origin[1], p[2] - origin[2])
                    along = d[1] * dir[1] + d[2] * dir[2]
                    perp = abs(-d[1] * dir[2] + d[2] * dir[1])
                    (along < 0.15 || perp > 0.05) && continue
                    if best === nothing || along < best
                        best = along
                    end
                end
                best === nothing && continue
                out[side] = uconvert(u"ft", best * u"m" - half - half)
            end
            return out
        end

        function _split_east!(struc, slab, cols, col)
            ox = _xy(struc, col)[1]
            east = Int[]
            for ci in collect(slab.cell_indices)
                poly = _poly(struc, ci)
                n = length(poly)
                cx = sum(p[1] for p in poly) / n
                cx > ox + 0.05 && push!(east, ci)
            end
            filter!(ci -> !(ci in east), slab.cell_indices)
            neigh = Slab(east, slab.result, slab.spans;
                         floor_type = slab.floor_type, position = :edge)
            push!(struc.slabs, neigh)
            cols2 = SS.find_supporting_columns(struc, Set(slab.cell_indices))
            # The column under test still has its west panels on this slab.
            @assert any(c -> c.vertex_idx == col.vertex_idx, cols2)
            return neigh, cols2
        end

        @testset "interior, edge, and corner of a 3×3 office" begin
            struc, slab, cols = _office()
            xs, ys = _lines(cols, struc)
            @test length(xs) == 4 && length(ys) == 4
            interior = _nearest(cols, struc, xs[2], ys[2])
            edge = _nearest(cols, struc, xs[1], ys[2])
            corner = _nearest(cols, struc, xs[1], ys[1])
            east = _nearest(cols, struc, xs[3], ys[2])
            north = _nearest(cols, struc, xs[2], ys[3])
            south = _nearest(cols, struc, xs[2], ys[1])

            # Four cells meet at the interior column.
            @test length(_cells_at(struc, slab, interior)) == 4

            qD, qL = _pressures(struc, slab)
            west = _nearest(cols, struc, xs[1], ys[2])
            bay_x = uconvert(u"ft", (_xy(struc, east)[1] - _xy(struc, interior)[1]) * u"m")
            bay_xw = uconvert(u"ft", (_xy(struc, interior)[1] - _xy(struc, west)[1]) * u"m")
            bay_y = uconvert(u"ft", (_xy(struc, north)[2] - _xy(struc, interior)[2]) * u"m")
            bay_ys = uconvert(u"ft", (_xy(struc, interior)[2] - _xy(struc, south)[2]) * u"m")
            # §13.6.2.3: ℓ2 is the average of the adjacent transverse spans,
            # which is half + half.  c1 is unset, so ℓn is center to center.
            ℓ2_int = (bay_y + bay_ys) / 2
            Mu_int = _hand_eq137(qD, qL, ℓ2_int, bay_xw, qD, qL, ℓ2_int, bay_x)
            qu = max(1.2 * qD + 1.6 * qL, 1.4 * qD)
            # Slab M0 uses the panel spans, not a half-width edge strip.
            l1 = uconvert(u"ft", slab.spans.primary)
            l2 = uconvert(u"ft", slab.spans.secondary)
            M0 = _hand_M0(qu, l2, l1)   # clear span = span when c = 0
            # §13.6.2.4: edge column, direction parallel to the edge.
            # ℓ2 is the edge-to-panel-centerline distance (half the bay).
            Mu_edge_parallel = _hand_eq137(qD, qL, bay_xw / 2, bay_y,
                                           qD, qL, bay_xw / 2, bay_ys)
            M_edge = 0.3 * M0   # §13.6.3.6, page 255

            mx, my = _analyze(struc, slab, cols)
            @test ustrip(kip * u"ft", _mub(mx, cols, interior)) ≈
                  ustrip(kip * u"ft", Mu_int) rtol = 1e-3
            @test ustrip(kip * u"ft", _mub(my, cols, interior)) ≈
                  ustrip(kip * u"ft", Mu_int) rtol = 1e-3
            # West edge: X is perpendicular (one side → 0.3 M0), Y is parallel.
            @test SS.is_exterior_support(edge, ax)
            @test !SS.is_exterior_support(edge, ay)
            @test ustrip(kip * u"ft", _mub(mx, cols, edge)) ≈
                  ustrip(kip * u"ft", M_edge) rtol = 1e-3
            @test ustrip(kip * u"ft", _mub(my, cols, edge)) ≈
                  ustrip(kip * u"ft", Mu_edge_parallel) rtol = 1e-3
            @test abs(ustrip(kip * u"ft", _mub(my, cols, edge)) -
                      ustrip(kip * u"ft", M_edge)) > 1.0
            @test ustrip(kip * u"ft", _mub(mx, cols, corner)) ≈
                  ustrip(kip * u"ft", M_edge) rtol = 1e-3
            @test ustrip(kip * u"ft", _mub(my, cols, corner)) ≈
                  ustrip(kip * u"ft", M_edge) rtol = 1e-3
        end

        @testset "inset edge column shortens the interior column's end span" begin
            struc, slab, cols = _office()
            xs, ys = _lines(cols, struc)
            interior = _nearest(cols, struc, xs[2], ys[2])
            c = uconvert(u"m", 20.0u"inch")
            half = c / 2
            for col in cols
                col.c1 = c
                col.c2 = c
                if _xy(struc, col)[1] < 0.05
                    # Inset by c/2, the same shift update_structural_offsets!
                    # applies once the column has a size.  Meters.
                    col.structural_offset = (ustrip(u"m", half), 0.0)
                end
            end
            qD, qL = _pressures(struc, slab)
            # Rebuild the column list so faces and offsets are the ones analyzed.
            cols = SS.find_supporting_columns(struc, Set(slab.cell_indices))
            interior = _nearest(cols, struc, xs[2], ys[2])
            ℓn = _side_ℓn(struc, cols, interior, ax; half = half)
            ℓ2s = _side_ℓ2(struc, interior, ax, _cells_at(struc, slab, interior))
            @test length(ℓn) == 2
            Mu = _hand_eq137(qD, qL, ℓ2s[1], ℓn[1], qD, qL, ℓ2s[-1], ℓn[-1])
            # Vertex-to-vertex would ignore the 10 in inset and deduct only
            # the 20 in column.  Those two clear spans are not these.
            bay = uconvert(u"ft", (xs[2] - xs[1]) * u"m")
            Mu_no_inset = _hand_eq137(qD, qL, bay, bay - 20.0u"inch",
                                      qD, qL, bay, bay - 20.0u"inch")
            @test abs(ustrip(kip * u"ft", Mu - Mu_no_inset)) > 1.0
            mx, _ = _analyze(struc, slab, cols)
            @test ustrip(kip * u"ft", _mub(mx, cols, interior)) ≈
                  ustrip(kip * u"ft", Mu) rtol = 1e-3
        end

        @testset "neighbour slab thickness, not a stale self-weight" begin
            struc, slab, cols = _office()
            xs, ys = _lines(cols, struc)
            interior = _nearest(cols, struc, xs[2], ys[2])
            h_result = slab.result.thickness
            sw_trial = SS.slab_self_weight(h, ρ)
            sw_result = SS.slab_self_weight(h_result, ρ)
            # The initialized thickness is not the 8 in trial.  That gap is
            # what makes this oracle see the neighbour path.
            @test abs(ustrip(psf, sw_result - sw_trial)) > 1.0
            neigh, cols2 = _split_east!(struc, slab, cols, interior)
            interior = _nearest(cols2, struc, xs[2], ys[2])
            # Stale stored self-weight must lose to the result thickness.
            for ci in neigh.cell_indices
                struc.cells[ci].self_weight = uconvert(unit(struc.cells[ci].self_weight),
                                                       500.0psf)
            end
            cell = struc.cells[first(slab.cell_indices)]
            sdl = uconvert(psf, cell.sdl)
            qL = uconvert(psf, cell.live_load)
            qD_west = sdl + sw_trial
            qD_east = sdl + sw_result
            ℓ2s = _side_ℓ2(struc, interior, ax, _cells_at(struc, slab, interior))
            # East cells left the design slab; measure both sides from every
            # slab cell that still touches the vertex.
            touch = Int[]
            vi = interior.vertex_idx
            for sl in struc.slabs
                for ci in sl.cell_indices
                    fi = struc.cells[ci].face_idx
                    if vi in struc.skeleton.face_vertex_indices[fi]
                        push!(touch, ci)
                    end
                end
            end
            ℓ2s = _side_ℓ2(struc, interior, ax, touch)
            # Far supports live on struc.columns.  The design slab's own
            # column list drops the east line once those panels move.
            ℓn = _side_ℓn(struc, struc.columns, interior, ax)
            @test haskey(ℓ2s, 1) && haskey(ℓ2s, -1) && haskey(ℓn, 1) && haskey(ℓn, -1)
            Mu = _hand_eq137(qD_west, qL, ℓ2s[-1], ℓn[-1],
                             qD_east, qL, ℓ2s[1], ℓn[1])
            mx, _ = _analyze(struc, slab, cols2)
            @test ustrip(kip * u"ft", _mub(mx, cols2, interior)) ≈
                  ustrip(kip * u"ft", Mu) rtol = 1e-3
        end

        @testset "neighbour drop panel is factored with D" begin
            struc, slab, cols = _office()
            xs, ys = _lines(cols, struc)
            interior = _nearest(cols, struc, xs[2], ys[2])
            neigh, cols2 = _split_east!(struc, slab, cols, interior)
            interior = _nearest(cols2, struc, xs[2], ys[2])
            dp = DropPanelGeometry(4.0u"inch", 6.0u"ft", 6.0u"ft")
            neigh.drop_panel = dp
            # Service drop pressure spread over the neighbour panel.
            # ENGINEERING JUDGMENT in the lookup: A_drop / (ℓ1·ℓ2).
            A_drop = drop_extent_1(dp) * drop_extent_2(dp)
            A_panel = neigh.spans.primary * neigh.spans.secondary
            q_drop = SS.slab_self_weight(dp.h_drop, ρ) * (A_drop / A_panel)
            # Neighbour self-weight follows the owning slab's result thickness,
            # which initialize! set independently of the 8 in trial.
            cell = struc.cells[first(slab.cell_indices)]
            sdl = uconvert(psf, cell.sdl)
            qL = uconvert(psf, cell.live_load)
            qD = sdl + SS.slab_self_weight(h, ρ)
            qD_east = sdl + SS.slab_self_weight(neigh.result.thickness, ρ) + q_drop
            touch = Int[]
            vi = interior.vertex_idx
            for sl in struc.slabs, ci in sl.cell_indices
                fi = struc.cells[ci].face_idx
                vi in struc.skeleton.face_vertex_indices[fi] && push!(touch, ci)
            end
            ℓ2s = _side_ℓ2(struc, interior, ax, touch)
            ℓn = _side_ℓn(struc, struc.columns, interior, ax)
            Mu = _hand_eq137(qD, qL, ℓ2s[-1], ℓn[-1],
                             qD_east, qL, ℓ2s[1], ℓn[1])
            # Same neighbour thickness, no drop.  The envelope must move.
            Mu_ignore = _hand_eq137(qD, qL, ℓ2s[-1], ℓn[-1],
                                    qD_east - q_drop, qL, ℓ2s[1], ℓn[1])
            @test ustrip(kip * u"ft", Mu) > ustrip(kip * u"ft", Mu_ignore) + 1.0
            mx, _ = _analyze(struc, slab, cols2)
            @test ustrip(kip * u"ft", _mub(mx, cols2, interior)) ≈
                  ustrip(kip * u"ft", Mu) rtol = 1e-3
        end

        @testset "same-side panels with different live loads" begin
            struc, slab, cols = _office()
            xs, ys = _lines(cols, struc)
            interior = _nearest(cols, struc, xs[2], ys[2])
            ox, oy = _xy(struc, interior)
            qD, qL0 = _pressures(struc, slab)
            for ci in slab.cell_indices
                cell = struc.cells[ci]
                poly = _poly(struc, ci)
                n = length(poly)
                cx = sum(p[1] for p in poly) / n
                cy = sum(p[2] for p in poly) / n
                qL = (cx > ox && cy > oy) ? 100.0psf : 50.0psf
                cell.live_load = uconvert(unit(cell.live_load), qL)
            end
            ℓ2s = _side_ℓ2(struc, interior, ax, _cells_at(struc, slab, interior))
            ℓn = _side_ℓn(struc, cols, interior, ax)
            # East side is two panels.  §13.6.1.5 (page 252) is per panel;
            # the frame term is Σ q·ℓ2, half the bay each.
            # East-north 100 psf, east-south 50 psf → 75 psf over the full ℓ2.
            # West is 50 psf.  Dead matches, so the live pattern on the east
            # governs: 0.07·0.5·1.6·wL_east·ℓn².
            wL_east = 100.0psf * (ℓ2s[1] / 2) + 50.0psf * (ℓ2s[1] / 2)
            wL_west = 50.0psf * ℓ2s[-1]
            Mu = _hand_eq137(qD, wL_west / ℓ2s[-1], ℓ2s[-1], ℓn[-1],
                             qD, wL_east / ℓ2s[1], ℓ2s[1], ℓn[1])
            Mu_full_100 = _hand_eq137(qD, 50.0psf, ℓ2s[-1], ℓn[-1],
                                      qD, 100.0psf, ℓ2s[1], ℓn[1])
            @test ustrip(kip * u"ft", Mu_full_100) > ustrip(kip * u"ft", Mu) + 1.0
            mx, _ = _analyze(struc, slab, cols)
            @test ustrip(kip * u"ft", _mub(mx, cols, interior)) ≈
                  ustrip(kip * u"ft", Mu) rtol = 1e-3
            r = SS.check_ddm_applicability(struc, slab, cols; throw_on_failure = false)
            @test !any(v -> occursin("13.6.1.3", v), r.violations)
        end

        @testset "negative bracket: heavier dead on one equal span" begin
            # R13.6.9 (page 258) puts live on the longer span only.  The spans
            # here are equal and the east dead is heavier, so the larger
            # magnitude is live on the east under Eq. (9-2), which beats 1.4D.
            struc, slab, cols = _office()
            xs, ys = _lines(cols, struc)
            interior = _nearest(cols, struc, xs[2], ys[2])
            ox = _xy(struc, interior)[1]
            sw = SS.slab_self_weight(h, ρ)
            for ci in slab.cell_indices
                cell = struc.cells[ci]
                poly = _poly(struc, ci)
                n = length(poly)
                cx = sum(p[1] for p in poly) / n
                sdl = cx > ox ? 200.0psf : 60.0psf
                cell.sdl = uconvert(unit(cell.sdl), sdl)
                cell.live_load = uconvert(unit(cell.live_load), 100.0psf)
            end
            qL = 100.0psf
            qD_west = 60.0psf + sw
            qD_east = 200.0psf + sw
            ℓ2s = _side_ℓ2(struc, interior, ax, _cells_at(struc, slab, interior))
            ℓn = _side_ℓn(struc, cols, interior, ax)
            Mu = _hand_eq137(qD_west, qL, ℓ2s[-1], ℓn[-1],
                             qD_east, qL, ℓ2s[1], ℓn[1])
            # Commentary pattern is not a separate assignment when the spans
            # match; 1.4D on the dead difference is the other candidate.
            Mu_14 = abs(0.07 * (1.4 * qD_east * ℓ2s[1] * ℓn[1]^2 -
                                1.4 * qD_west * ℓ2s[-1] * ℓn[-1]^2))
            @test ustrip(kip * u"ft", Mu) > ustrip(kip * u"ft", Mu_14) + 1.0
            mx, _ = _analyze(struc, slab, cols)
            @test ustrip(kip * u"ft", _mub(mx, cols, interior)) ≈
                  ustrip(kip * u"ft", Mu) rtol = 1e-3
        end

        @testset "off-line vertex noise and a 2° skew do not throw" begin
            struc, slab, cols = _office()
            xs, ys = _lines(cols, struc)
            interior = _nearest(cols, struc, xs[2], ys[2])
            mx0, _ = _analyze(struc, slab, cols)
            M0 = _mub(mx0, cols, interior)
            vc = struc.skeleton.geometry.vertex_coords
            saved = [vc[i, j] for i in 1:size(vc, 1), j in 1:size(vc, 2)]
            oy = _xy(struc, interior)[2]
            function _nudge!(dx)
                for i in 1:size(vc, 1)
                    abs(vc[i, 2] - oy) < 0.05 && continue
                    # Only corners of panels that touch this column.
                    touched = false
                    for ci in _cells_at(struc, slab, interior)
                        fi = struc.cells[ci].face_idx
                        if i in struc.skeleton.face_vertex_indices[fi]
                            touched = true
                        end
                    end
                    touched && (vc[i, 1] += dx)
                end
            end
            _nudge!(ustrip(u"m", 0.1u"ft"))
            mx1, _ = _analyze(struc, slab, cols)
            @test ustrip(kip * u"ft", _mub(mx1, cols, interior)) ≈
                  ustrip(kip * u"ft", M0) rtol = 1e-4
            for i in 1:size(vc, 1), j in 1:size(vc, 2)
                vc[i, j] = saved[i, j]
            end
            _nudge!(ustrip(u"m", 24.0u"ft" * tan(2π / 180)))
            mx2, _ = _analyze(struc, slab, cols)
            @test ustrip(kip * u"ft", _mub(mx2, cols, interior)) ≈
                  ustrip(kip * u"ft", M0) rtol = 1e-4
        end

        @testset "nudged interior column vertex keeps both panels" begin
            # Regression: a ray from a column vertex a hair off the frame
            # line ran inside only one of the two cells sharing that line,
            # so the other was dropped and Mub halved (13.04 → 6.52 kip-ft).
            # Membership is now vertex-adjacent geometry.
            struc, slab, cols = _office()
            xs, ys = _lines(cols, struc)
            interior = _nearest(cols, struc, xs[2], ys[2])
            mx0, _ = _analyze(struc, slab, cols)
            M_clean = ustrip(kip * u"ft", _mub(mx0, cols, interior))
            vc = struc.skeleton.geometry.vertex_coords
            vi = interior.vertex_idx
            y0 = vc[vi, 2]
            for dy in (1e-12, 1e-6, 1e-3, 0.02, ustrip(u"m", 0.1u"ft"))
                vc[vi, 2] = y0 + dy
                mx, _ = _analyze(struc, slab, cols)
                got = ustrip(kip * u"ft", _mub(mx, cols, interior))
                @test got ≈ M_clean rtol = 0.02
                @test abs(got - 0.5 * M_clean) > 0.4 * M_clean
            end
            vc[vi, 2] = y0
        end

        @testset "re-entrant corner is max(Eq. 13-7, 0.3 M0)" begin
            # gen_medium_office has no L-plan.  Dropping the north-east panel
            # of an interior column leaves three quadrants on this skeleton.
            struc, slab, cols = _office()
            xs, ys = _lines(cols, struc)
            interior = _nearest(cols, struc, xs[2], ys[2])
            ox, oy = _xy(struc, interior)
            drop_ci = nothing
            for ci in _cells_at(struc, slab, interior)
                poly = _poly(struc, ci)
                n = length(poly)
                cx = sum(p[1] for p in poly) / n
                cy = sum(p[2] for p in poly) / n
                if cx > ox && cy > oy
                    drop_ci = ci
                end
            end
            @test drop_ci !== nothing
            filter!(ci -> ci != drop_ci, slab.cell_indices)
            cols = SS.find_supporting_columns(struc, Set(slab.cell_indices))
            interior = _nearest(cols, struc, xs[2], ys[2])
            qD, qL = _pressures(struc, slab)
            qu = max(1.2 * qD + 1.6 * qL, 1.4 * qD)
            l1 = uconvert(u"ft", slab.spans.primary)
            l2 = uconvert(u"ft", slab.spans.secondary)
            M0x = _hand_M0(qu, l2, l1)
            M0y = _hand_M0(qu, l1, l2)
            cis = _cells_at(struc, slab, interior)
            @test length(cis) == 3
            function _at(axis, M0)
                ℓ2s = _side_ℓ2(struc, interior, axis, cis)
                ℓn = _side_ℓn(struc, cols, interior, axis)
                Mu = _hand_eq137(qD, qL, ℓ2s[-1], ℓn[-1], qD, qL, ℓ2s[1], ℓn[1])
                return max(Mu, 0.3 * M0)
            end
            mx, my = _analyze(struc, slab, cols)
            @test ustrip(kip * u"ft", _mub(mx, cols, interior)) ≈
                  ustrip(kip * u"ft", _at(ax, M0x)) rtol = 1e-3
            @test ustrip(kip * u"ft", _mub(my, cols, interior)) ≈
                  ustrip(kip * u"ft", _at(ay, M0y)) rtol = 1e-3
        end

        @testset "closed-form interior column from measured qL, ℓ2, ℓn" begin
            # Independent of `_hand_eq137` and of the slab's stored spans.
            # Equal adjoining bays, equal service loads: the dead terms of
            # Eq. (13-7) cancel.  ACI 318-11 §9.2.1 Eq. (9-1) (page 123) is
            # then 0, and Eq. (9-2) leaves
            #   Mu = 0.07 · 0.5 · (1.6 qL) · ℓ2 · ℓn²
            # ACI 318-11 §13.6.9.2 Eq. (13-7) (corpus: aci-318-11, page 258).
            # ℓ2 is the full transverse bay (§13.6.2.1 / §13.6.2.3, page 253:
            # centerline to centerline).  ℓn is face to face (§13.6.2.5).
            # A qL = 100 psf reading of a 24 ft bay is about 77 kip·ft.  This
            # office's cell live load is whatever initialize! stored (a
            # one-story skeleton's designed slab is the roof, LL = 20 psf).
            struc, slab, cols = _office()
            xs, ys = _lines(cols, struc)
            interior = _nearest(cols, struc, xs[2], ys[2])
            east = _nearest(cols, struc, xs[3], ys[2])
            north = _nearest(cols, struc, xs[2], ys[3])
            qD, qL = _pressures(struc, slab)
            bay_x = uconvert(u"ft", (_xy(struc, east)[1] - _xy(struc, interior)[1]) * u"m")
            bay_y = uconvert(u"ft", (_xy(struc, north)[2] - _xy(struc, interior)[2]) * u"m")
            # Square, axis-aligned: full width along the span is c1.
            # nothing → no face deduction.
            function _c(col)
                c1 = col.c1
                c1 === nothing && return 0.0u"ft"
                return uconvert(u"ft", c1)
            end
            ℓn = bay_x - _c(interior) / 2 - _c(east) / 2
            ℓ2 = bay_y
            # Eq. (9-2) only.  Eq. (9-1) cancels on equal spans.
            closed = 0.07 * 0.5 * (1.6 * qL) * ℓ2 * ℓn^2
            half_ℓn = 0.07 * 0.5 * (1.6 * qL) * ℓ2 * (ℓn / 2)^2
            as_100 = 0.07 * 0.5 * (1.6 * 100.0psf) * ℓ2 * ℓn^2
            mx, _ = _analyze(struc, slab, cols)
            got = ustrip(kip * u"ft", _mub(mx, cols, interior))
            exp = ustrip(kip * u"ft", closed)
            println("INTERIOR_ORACLE code=$(round(got; digits=3)) hand=$(round(exp; digits=3)) ",
                    "qL_psf=$(round(ustrip(psf, qL); digits=2)) ",
                    "qD_psf=$(round(ustrip(psf, qD); digits=2)) ",
                    "ℓ2_ft=$(round(ustrip(u"ft", ℓ2); digits=4)) ",
                    "ℓn_ft=$(round(ustrip(u"ft", ℓn); digits=4)) ",
                    "c1_ft=$(round(ustrip(u"ft", _c(interior)); digits=4)) ",
                    "half_ℓn=$(round(ustrip(kip * u"ft", half_ℓn); digits=3)) ",
                    "qL100=$(round(ustrip(kip * u"ft", as_100); digits=3)) ",
                    "floor_type=$(struc.cells[first(slab.cell_indices)].floor_type)")
            @test got ≈ exp rtol = 1e-3
            # Half the clear span is the failure mode that also lands near
            # 15 kip·ft when qL is about 80 psf.  It must not match.
            @test abs(got - ustrip(kip * u"ft", half_ℓn)) > 0.25 * abs(exp)
        end

        @testset "far face is the column on this storey" begin
            # Three storeys, columns 30 / 24 / 18 in from the ground up.
            # The roof slab's clear span must deduct the 18 in roof column,
            # not the 30 in column stacked on the same XY at the ground.
            skel = gen_medium_office(72.0u"ft", 72.0u"ft", 12.0u"ft", 3, 3, 3)
            struc = BuildingStructure(skel)
            initialize!(struc; material = NWC_4000, floor_type = :flat_plate,
                        floor_opts = FlatPlateOptions(method = DDM()))
            vc = struc.skeleton.geometry.vertex_coords
            @test size(vc, 2) >= 3
            zs = sort(unique(round.([vc[c.vertex_idx, 3] for c in struc.columns], digits = 3)))
            @test length(zs) >= 3
            size_at = Dict{Float64, typeof(1.0u"inch")}(
                z => (i == 1 ? 30.0u"inch" : i == length(zs) ? 18.0u"inch" : 24.0u"inch")
                for (i, z) in enumerate(zs)
            )
            for col in struc.columns
                z = round(vc[col.vertex_idx, 3], digits = 3)
                col.c1 = size_at[z]
                col.c2 = size_at[z]
            end
            roof = nothing
            roof_z = -Inf
            for sl in struc.slabs
                cols = SS.find_supporting_columns(struc, Set(sl.cell_indices))
                isempty(cols) && continue
                z = maximum(vc[c.vertex_idx, 3] for c in cols)
                if z > roof_z
                    roof_z = z
                    roof = (sl, cols)
                end
            end
            @test roof !== nothing
            slab, cols = roof
            xs, ys = _lines(cols, struc)
            interior = _nearest(cols, struc, xs[2], ys[2])
            east = _nearest(cols, struc, xs[3], ys[2])
            @test vc[interior.vertex_idx, 3] ≈ roof_z atol = 1e-6
            bay = uconvert(u"ft", (_xy(struc, east)[1] - _xy(struc, interior)[1]) * u"m")
            sides = SS._eq137_resolved_sides(struc, slab, interior, (1.0, 0.0);
                                             extra_columns = cols)
            @test sides !== nothing && length(sides) == 2
            # Both faces are the 18 in roof column.  A ground-storey match
            # would deduct 30 in on the far face: ℓn about 0.5 ft shorter.
            expect = bay - 18.0u"inch"
            wrong = bay - 9.0u"inch" - 15.0u"inch"
            for s in sides
                @test ustrip(u"ft", s.ln) ≈ ustrip(u"ft", expect) atol = 0.05
                @test abs(ustrip(u"ft", s.ln) - ustrip(u"ft", wrong)) > 0.25
            end
        end
    end
end

@testset "evaluate() edge column parallel to the edge" begin
    # ACI 318-11 §13.6.2.4 (page 253): at an edge, ℓ2 is edge to panel
    # centerline.  §13.6.9.2 Eq. (13-7) (page 258) still applies along the
    # edge, where the slab continues on both sides.  §13.6.3.6 (page 255)
    # 0.3 M0 is only the direction perpendicular to the edge.
    # `evaluate` must classify the same way.  A positional :edge fallback
    # would return 0.3 M0 on this axis.
    sdl = 20.0psf
    qL = 40.0psf
    fix = _two_bay(west_ft = 29.0, east_ft = 20.0, south = false, position = :edge,
                   qD = sdl, qL = qL)
    mat = RC_4000_60
    wc = ustrip(pcf, mat.concrete.ρ)
    idx = SS._eq137_vertex_cell_index(fix.struc)
    p = FlatPlateNLPProblem(
        mat, mat.concrete.fc′, mat.rebar.Fy, mat.rebar.E,
        Ec(mat.concrete.fc′, wc), mat.concrete.ρ, mat.concrete.λ,
        29.0u"ft", 20.0u"ft", sdl, qL,
        [:edge], [50.0], 3.0,
        0.65, 0.70, 0.35,
        0.75u"inch", bar_diameter(5),
        0.90, 0.75, :L_360,
        (6.0, 24.0), (10.0, 36.0),
        [4, 5, 6, 7, 8], MinVolume(),
        (struc = fix.struc, slab = fix.slab,
         # Edge runs in X.  ACI 318-11 §13.6.3.3 (page 254): this column is
         # an interior support of the X span and an exterior support of the
         # Y span.
         columns = [merge(fix.col, (boundary_edge_dirs = [(1.0, 0.0)],))],
         span_axis = (1.0, 0.0), index = idx),
    )
    found = nothing
    for h_in in (16.0, 18.0, 14.0, 20.0, 12.0)
        found !== nothing && break
        for c_in in (18.0, 24.0, 16.0, 30.0, 12.0)
            ok, _, res = SS.evaluate(p, [h_in, c_in])
            if ok
                found = (h_in, c_in, res)
                break
            end
        end
    end
    @test found !== nothing
    if found !== nothing
        h_in, c_in, res = found
        c = c_in * u"inch"
        sw = SS.slab_self_weight(h_in * u"inch", mat.concrete.ρ)
        qD = sdl + sw
        # Design slab is the west panel only, so the trial size replaces
        # the west support and the column under test.  The east support
        # keeps the fixture's 12 in (§13.6.2.5 face to face).
        ℓn_w = 29.0u"ft" - c
        ℓn_e = 20.0u"ft" - c / 2 - 6.0u"inch"
        ℓ2_edge = 10.0u"ft"   # §13.6.2.4, y/2
        hand = _hand_eq137(qD, qL, ℓ2_edge, ℓn_w, qD, qL, ℓ2_edge, ℓn_e)
        full = _hand_eq137(qD, qL, 20.0u"ft", ℓn_w, qD, qL, 20.0u"ft", ℓn_e)
        got = res.moment_results.unbalanced_moments[1]
        M0 = res.moment_results.M0
        println("EVALUATE_EDGE h=$(h_in) c=$(c_in) ",
                "code=$(round(ustrip(kip * u"ft", got); digits=3)) ",
                "hand=$(round(ustrip(kip * u"ft", hand); digits=3)) ",
                "full_ℓ2=$(round(ustrip(kip * u"ft", full); digits=3)) ",
                "0.3M0=$(round(ustrip(kip * u"ft", 0.3 * M0); digits=3))")
        @test ustrip(kip * u"ft", got) ≈ ustrip(kip * u"ft", hand) rtol = 1e-3
        @test abs(ustrip(kip * u"ft", got) - ustrip(kip * u"ft", 0.3 * M0)) > 1.0
        @test abs(ustrip(kip * u"ft", hand) - ustrip(kip * u"ft", full)) > 1.0
        @test ustrip(kip * u"ft", hand) ≈ ustrip(kip * u"ft", full / 2) rtol = 1e-6
        # Flexural moment is the interior-negative coefficient along the
        # edge.  ACI 318-11 §13.6.3.3 (corpus: aci-318-11, page 254).
        # `position == :edge` would have used the exterior-negative 0.65 M0.
        Mflex = res.moment_results.column_moments[1]
        @test ustrip(kip * u"ft", Mflex) ≈ ustrip(kip * u"ft", 0.70 * M0) rtol = 1e-3
        @test abs(ustrip(kip * u"ft", Mflex) - ustrip(kip * u"ft", 0.65 * M0)) > 1.0
    end
end

@testset "flexural M uses the transfer classification; DDM and NLP agree" begin
    # ACI 318-11 §13.6.3.3 (corpus: aci-318-11, page 254): exterior-negative
    # at the exterior edge, interior-negative at the interior support.  The
    # column's global tag (:interior / :edge / :corner) must not override the
    # direction-specific continuity that the transfer moment already uses.
    # Coefficients 0.65 / 0.70 are the NLP problem's c_neg_ext / c_neg_int.
    sdl = 20.0psf
    qL = 40.0psf
    mat = RC_4000_60
    wc = ustrip(pcf, mat.concrete.ρ)
    function nlp(fix, l1, pos)
        idx = SS._eq137_vertex_cell_index(fix.struc)
        return FlatPlateNLPProblem(
            mat, mat.concrete.fc′, mat.rebar.Fy, mat.rebar.E,
            Ec(mat.concrete.fc′, wc), mat.concrete.ρ, mat.concrete.λ,
            l1, 20.0u"ft", sdl, qL,
            [pos], [100.0], 3.0,
            0.65, 0.70, 0.35,
            0.75u"inch", bar_diameter(5),
            0.90, 0.75, :L_360,
            (6.0, 24.0), (10.0, 36.0),
            [4, 5, 6, 7, 8], MinVolume(),
            (struc = fix.struc, slab = fix.slab, columns = [fix.col],
             span_axis = (1.0, 0.0), index = idx),
        )
    end
    # DDM column moment for the same column, coefficients, and axis.
    function ddm_M(fix, M_ext, M_int, axis)
        return SS._ddm_support_moment(fix.struc, fix.col, axis, M_ext, M_int)
    end
    M_ext = 0.65 * 100.0kip * u"ft"
    M_int = 0.70 * 100.0kip * u"ft"
    kft(x) = ustrip(kip * u"ft", x)

    @testset "re-entrant corner tagged :corner: evaluate() gets the interior side" begin
        # Three quadrants, slab on both sides along X.  The :corner tag would
        # give 0.65 M0.  ENGINEERING JUDGMENT: max(0.65, 0.70) M0, matching
        # the transfer moment's max(Eq. 13-7, 0.3 M0).
        fix = _lplan(20.0, 20.0; qD = sdl, qL = qL)
        p = nlp(fix, 20.0u"ft", :corner)
        found = nothing
        for h_in in (12.0, 14.0, 16.0, 10.0, 18.0), c_in in (16.0, 18.0, 24.0, 12.0, 30.0)
            ok, _, res = SS.evaluate(p, [h_in, c_in])
            if ok
                found = res
                break
            end
        end
        @test found !== nothing
        if found !== nothing
            mr = found.moment_results
            Mflex = mr.column_moments[1]
            @test kft(Mflex) ≈ kft(0.70 * mr.M0) rtol = 1e-9
            @test abs(kft(Mflex) - kft(0.65 * mr.M0)) > 1.0
            # DDM on the same column and coefficients returns the same M.
            M_ddm, _, _ = SS._compute_column_demands_ddm(
                fix.struc, [fix.col], mr.M_neg_ext, mr.M_neg_int, mr.M_pos,
                mr.qu, mr.qD, mr.qL, mr.l2, mr.ln, (1.0, 0.0), mr.M0;
                slab = fix.slab, c_override = found.c, γ = mat.concrete.ρ,
            )
            @test kft(M_ddm[1]) ≈ kft(Mflex) rtol = 1e-12
        end
        # Along Y the corner is also continuous on both sides.
        @test kft(SS._nlp_support_moment(p, 1, (0.0, 1.0), M_ext, M_int)) ≈ kft(M_int)
        @test kft(ddm_M(fix, M_ext, M_int, (0.0, 1.0))) ≈ kft(M_int)
    end

    @testset ":edge tag without boundary_edge_dirs is interior along the edge" begin
        # is_exterior_support's position fallback would call this exterior
        # in both directions.
        fix = _two_bay(west_ft = 29.0, east_ft = 20.0, south = false,
                       position = :edge, qD = sdl, qL = qL)
        p = nlp(fix, 29.0u"ft", :edge)
        @test SS.is_exterior_support(fix.col, (1.0, 0.0))
        for (axis, want) in (((1.0, 0.0), M_int), ((0.0, 1.0), M_ext))
            got = SS._nlp_support_moment(p, 1, axis, M_ext, M_int)
            @test kft(got) ≈ kft(want)
            @test kft(got) ≈ kft(ddm_M(fix, M_ext, M_int, axis))
        end
    end

    @testset ":interior tag with slab on one side is exterior" begin
        fix = _two_bay(west_ft = 29.0, east_ft = 20.0, east = false,
                       qD = sdl, qL = qL)
        p = nlp(fix, 29.0u"ft", :interior)
        @test !SS.is_exterior_support(fix.col, (1.0, 0.0))
        got = SS._nlp_support_moment(p, 1, (1.0, 0.0), M_ext, M_int)
        @test kft(got) ≈ kft(M_ext)
        @test kft(got) ≈ kft(ddm_M(fix, M_ext, M_int, (1.0, 0.0)))
        # Along Y it has slab north and south: interior.
        @test kft(SS._nlp_support_moment(p, 1, (0.0, 1.0), M_ext, M_int)) ≈ kft(M_int)
    end

    @testset "no stored geometry keeps the position fallback" begin
        for (pos, want) in ((:corner, M_ext), (:edge, M_ext), (:interior, M_int))
            p0 = FlatPlateNLPProblem(
                mat, mat.concrete.fc′, mat.rebar.Fy, mat.rebar.E,
                Ec(mat.concrete.fc′, wc), mat.concrete.ρ, mat.concrete.λ,
                20.0u"ft", 20.0u"ft", sdl, qL,
                [pos], [100.0], 3.0,
                0.65, 0.70, 0.35,
                0.75u"inch", bar_diameter(5),
                0.90, 0.75, :L_360,
                (6.0, 12.0), (10.0, 24.0),
                [5], MinVolume(),
            )
            got = SS._nlp_support_moment(p0, 1, (1.0, 0.0), M_ext, M_int)
            @test kft(got) ≈ kft(want)
            @test kft(got) ≈ kft(SS._ddm_support_moment(nothing, (position = pos,),
                                                        (1.0, 0.0), M_ext, M_int))
        end
    end
end

@testset "Eq. (13-7) frame-line membership" begin
    qD = 115.0psf
    qL = 100.0psf

    function _moment(fix)
        Mub, _ = _interior_mub(fix, qD, qL; l2 = 24.0u"ft", ln_passed = 22.0u"ft",
                               columns = fix.struc.columns)
        return ustrip(kip * u"ft", Mub[1])
    end

    @testset "vertex noise does not halve an interior moment" begin
        clean = _two_bay(west_ft = 24.0, east_ft = 24.0, y_ft = 24.0, qD = qD, qL = qL)
        m_clean = _moment(clean)
        half = 0.5 * m_clean
        noises = [
            1e-6,
            1e-3,
            0.01 * 0.3048,
            0.06 * 0.3048,
            0.1 * 0.3048,
        ]
        for dy in noises
            for which in (:origin, :far)
                fix = _two_bay(west_ft = 24.0, east_ft = 24.0, y_ft = 24.0,
                               qD = qD, qL = qL)
                vi = which == :origin ? fix.col.vertex_idx : fix.struc.columns[end].vertex_idx
                vc = fix.struc.skeleton.geometry.vertex_coords
                vc[vi, 2] += dy
                got = _moment(fix)
                # A 0.1 ft nudge may move a centerline by a fraction of the
                # nudge.  It must not drop the second panel.
                @test got ≈ m_clean rtol = 0.02
                @test abs(got - half) > 0.4 * m_clean
            end
        end
        # Alternating ±1 mm along the frame-line row.
        fix = _two_bay(west_ft = 24.0, east_ft = 24.0, y_ft = 24.0, qD = qD, qL = qL)
        vc = fix.struc.skeleton.geometry.vertex_coords
        row = Int[]
        for i in 1:size(vc, 1)
            abs(vc[i, 2]) < 1e-9 && push!(row, i)
        end
        for (k, vi) in enumerate(row)
            vc[vi, 2] += iseven(k) ? 0.001 : -0.001
        end
        got = _moment(fix)
        @test got ≈ m_clean rtol = 1e-3
        @test abs(got - half) > 0.4 * m_clean
    end

    @testset "inward offset does not widen an edge strip" begin
        # ACI 318-11 §13.6.2.4 (corpus: aci-318-11, page 253): ℓ2 is the
        # distance from the edge to the panel centerline.  The edge is the
        # architectural frame line.  An inward structural offset larger than
        # the on-line tolerance must not make the panel look like it
        # straddles that line.
        function edge_fix(off)
            fix = _two_bay(west_ft = 24.0, east_ft = 24.0, y_ft = 24.0,
                           south = false, position = :edge, qD = qD, qL = qL)
            cols = [(
                vertex_idx = c.vertex_idx, position = c.position,
                c1 = c.c1, c2 = c.c2, θ = c.θ, structural_offset = off,
            ) for c in fix.struc.columns]
            struc = (
                cells = fix.struc.cells, slabs = fix.struc.slabs, columns = cols,
                skeleton = fix.struc.skeleton,
            )
            return (struc = struc, slab = fix.slab, col = cols[1])
        end
        inset = (0.0, 1.5 * 0.3048)  # 1.5 ft inward, past the 0.35 m band
        plain = _moment(edge_fix((0.0, 0.0)))
        shifted = _moment(edge_fix(inset))
        full = _moment(_two_bay(west_ft = 24.0, east_ft = 24.0, y_ft = 24.0,
                                qD = qD, qL = qL))
        @test shifted ≈ plain rtol = 1e-3
        @test abs(shifted - full) > 0.4 * full

        mat = RC_4000_60
        wc = ustrip(pcf, mat.concrete.ρ)
        fix = edge_fix(inset)
        idx = SS._eq137_vertex_cell_index(fix.struc)
        M0 = SS.total_static_moment(1.2 * qD + 1.6 * qL, 24.0u"ft", 22.0u"ft")
        p = FlatPlateNLPProblem(
            mat, mat.concrete.fc′, mat.rebar.Fy, mat.rebar.E,
            Ec(mat.concrete.fc′, wc), mat.concrete.ρ, mat.concrete.λ,
            24.0u"ft", 24.0u"ft", qD, qL,
            [:edge], [100.0], 3.0,
            0.65, 0.70, 0.35,
            0.75u"inch", bar_diameter(5),
            0.90, 0.75, :L_360,
            (6.0, 12.0), (10.0, 24.0),
            [5], MinVolume(),
            (struc = fix.struc, slab = fix.slab, columns = [fix.col],
             span_axis = (1.0, 0.0), index = idx),
        )
        Mx = SS._nlp_transfer_moment(p, 1, qD, qL, 12.0u"ft", 22.0u"ft",
                                     (1.0, 0.0), 12.0u"inch", M0)
        @test ustrip(kip * u"ft", Mx) ≈ shifted rtol = 1e-3
        @test abs(ustrip(kip * u"ft", Mx) - full) > 0.4 * full
    end

    @testset "a nudged corner is 0.3 M0, not the equal-span pattern" begin
        # One panel, column tagged :interior the way a synthetic grid tags
        # every column.  Geometrically it is a corner.  ACI 318-11 §13.6.3.6
        # (corpus: aci-318-11, page 255).
        function corner(nudge)
            m = 0.3048
            vc = zeros(4, 2)
            vc[1, :] .= (-nudge, -nudge)
            vc[2, :] .= (24.0 * m, 0.0)
            vc[3, :] .= (24.0 * m, 24.0 * m)
            vc[4, :] .= (0.0, 24.0 * m)
            cell = (face_idx = 1, sdl = qD, live_load = qL, self_weight = 0.0psf)
            col = (vertex_idx = 1, position = :interior, c1 = 16.0u"inch",
                   c2 = 16.0u"inch", θ = 0.0, structural_offset = (0.0, 0.0))
            far = (vertex_idx = 2, position = :interior, c1 = 16.0u"inch",
                   c2 = 16.0u"inch", θ = 0.0, structural_offset = (0.0, 0.0))
            slab = (cell_indices = [1],
                    spans = (primary = 24.0u"ft", secondary = 24.0u"ft",
                             axis = (1.0, 0.0)))
            struc = (
                cells = [cell], slabs = [slab], columns = [col, far],
                skeleton = (geometry = (vertex_coords = vc,),
                            face_vertex_indices = [[1, 2, 3, 4]]),
            )
            return (struc = struc, slab = slab, col = col)
        end
        ln = 24.0u"ft" - 16.0u"inch"
        M0 = SS.total_static_moment(1.2 * qD + 1.6 * qL, 24.0u"ft", ln)
        edge = 0.3 * M0
        equal = SS.governing_interior_unbalanced_moment(
            qD, qL, 24.0u"ft", ln, qD, qL, 24.0u"ft", ln)
        for nudge in (0.0, 0.001)
            Mub, _ = _interior_mub(corner(nudge), qD, qL; l2 = 24.0u"ft",
                                   ln_passed = ln, columns = corner(nudge).struc.columns)
            got = ustrip(kip * u"ft", Mub[1])
            @test got ≈ ustrip(kip * u"ft", edge) rtol = 1e-3
            @test abs(got - ustrip(kip * u"ft", equal)) > 10.0
        end
        # The column sits on its own vertex that no cell uses, moved `d` m
        # diagonally outward from the panel corner.
        fix = corner(0.0)
        vc = fix.struc.skeleton.geometry.vertex_coords
        function orphan_at(pos)
            return (vertex_idx = 5, position = pos, c1 = 16.0u"inch",
                    c2 = 16.0u"inch", θ = 0.0, structural_offset = (0.0, 0.0))
        end
        orphan_struc(d, pos) = (
            cells = fix.struc.cells, slabs = fix.struc.slabs,
            columns = [orphan_at(pos)],
            skeleton = (geometry = (vertex_coords = vcat(vc, [-d -d]),),
                        face_vertex_indices = fix.struc.skeleton.face_vertex_indices),
        )
        function orphan_mub(d, pos)
            tc = TraceCollector()
            Mub = SS._eq137_transfer_moment(
                orphan_struc(d, pos), fix.slab, orphan_at(pos), (1.0, 0.0),
                qD, qL, 24.0u"ft", ln, M0; tc = tc,
            )
            return ustrip(kip * u"ft", Mub), tc
        end
        has(tc, ev, r) = any(e -> e.event_type == ev &&
                                  get(e.data, "reason", "") == r, tc.events)
        # 1 mm off: a nudged duplicate of the corner vertex
        # (`_EQ137_WELD_M`), so the panel adjoins the column; one side is a
        # corner, 0.3 M0, whatever the tag.
        for pos in (:corner, :interior)
            got, tc = orphan_mub(0.001, pos)
            @test got ≈ ustrip(kip * u"ft", edge) rtol = 1e-6
            @test has(tc, :decision, "duplicate_vertex_merged")
        end
        # 0.3 m each way (0.42 m): beyond the on-line floor, so the column
        # touches no panel.  A corner position must still be 0.3 M0, and the
        # fallback is a trace event.
        got, tc = orphan_mub(0.3, :corner)
        @test got ≈ ustrip(kip * u"ft", edge) rtol = 1e-6
        @test has(tc, :fallback, "exterior_no_panel")
        # Same orphan vertex tagged :interior: it cannot be shown to be
        # interior, so it is never below 0.3 M0 (ENGINEERING JUDGMENT in
        # `_eq137_transfer_moment`).
        got, tc = orphan_mub(0.3, :interior)
        @test got ≈ max(ustrip(kip * u"ft", edge), ustrip(kip * u"ft", equal)) rtol = 1e-6
        @test has(tc, :fallback, "zero_sides")
        # 0.2 m each way (0.28 m): the panel is within the column
        # neighbourhood but does not adjoin it, so the column is ambiguous and
        # the corner tag takes the envelope.
        got, tc = orphan_mub(0.2, :corner)
        @test got ≈ max(ustrip(kip * u"ft", edge), ustrip(kip * u"ft", equal)) rtol = 1e-6
        @test has(tc, :decision, "ambiguous_neighbourhood_envelope")
    end

    @testset "neighbour trial self-weight excludes the design drop" begin
        sw = 50.0psf
        drop = 20.0psf
        sdl = 100.0psf
        qD_design = sdl + sw + drop
        # One cell on each side, so the east cell is only a neighbour.
        fix = _two_bay(west_ft = 24.0, east_ft = 24.0, y_ft = 24.0,
                       south = false, qD = sdl, qL = qL)
        ln = 24.0u"ft" - 12.0u"inch"
        ℓ2 = 12.0u"ft"
        _, _, Mub = SS._compute_column_demands_ddm(
            fix.struc, fix.struc.columns,
            0.26 * 1.0kip * u"ft", 0.65 * 1.0kip * u"ft", 0.35 * 1.0kip * u"ft",
            1.2 * qD_design + 1.6 * qL, qD_design, qL, ℓ2, ln, (1.0, 0.0),
            SS.total_static_moment(1.2 * qD_design + 1.6 * qL, ℓ2, ln);
            slab = fix.slab, design_drop = drop,
        )
        # West is the design panel (drop included once).  East is a
        # neighbour with no thickness and no drop of its own.
        hand = _hand_eq137(qD_design, qL, ℓ2, ln, sdl + sw, qL, ℓ2, ln)
        doubled = _hand_eq137(qD_design, qL, ℓ2, ln, qD_design, qL, ℓ2, ln)
        got = ustrip(kip * u"ft", Mub[1])
        @test got ≈ ustrip(kip * u"ft", hand) rtol = 1e-3
        @test abs(got - ustrip(kip * u"ft", doubled)) > 1.0
    end

    @testset "stacked columns do not set the far face" begin
        fix = _two_bay(west_ft = 24.0, east_ft = 24.0, y_ft = 24.0,
                       c_in = 18.0, qD = qD, qL = qL)
        vc = fix.struc.skeleton.geometry.vertex_coords
        n = size(vc, 1)
        vc3 = vcat(hcat(vc, fill(9.0, n)), hcat(vc, fill(0.0, n)), hcat(vc, fill(4.5, n)))
        function at(vi, cin)
            return (vertex_idx = vi, position = :interior, c1 = cin * u"inch",
                    c2 = cin * u"inch", θ = 0.0, structural_offset = (0.0, 0.0))
        end
        columns = vcat(
            [at(n + i, 30.0) for i in 1:n],
            [at(2n + i, 24.0) for i in 1:n],
            [at(i, 18.0) for i in 1:n],
        )
        struc = (
            cells = fix.struc.cells, slabs = fix.struc.slabs, columns = columns,
            skeleton = (geometry = (vertex_coords = vc3,),
                        face_vertex_indices = fix.struc.skeleton.face_vertex_indices),
        )
        col = columns[2n + fix.col.vertex_idx]
        sides = SS._eq137_resolved_sides(struc, fix.slab, col, (1.0, 0.0);
                                         extra_columns = columns)
        @test sides !== nothing && length(sides) == 2
        for s in sides
            @test ustrip(u"ft", s.ln) ≈ 22.5 atol = 0.05
            @test abs(ustrip(u"ft", s.ln) - 22.0) > 0.2
        end
    end

    @testset "precomputed maps give the same moment as a direct call" begin
        # The DDM and NLP paths pass `_eq137_context` once per analysis.  A
        # direct call builds the same maps itself.  Neighbour thickness and
        # drop come through the cell → slab map, so the two must agree.
        ρ = NWC_4000.ρ
        dp = DropPanelGeometry(4.0u"inch", 5.0u"ft", 5.0u"ft")
        fix = _two_bay(west_ft = 20.0, east_ft = 26.0, y_ft = 24.0,
                       qD = 100.0psf, qL = 60.0psf, qD_east = 40.0psf)
        slabs = Any[]
        for (i, sl) in enumerate(fix.struc.slabs)
            push!(slabs, i in (2, 4) ?
                merge(sl, (result = (thickness = 9.0u"inch",), drop_panel = dp)) : sl)
        end
        struc = merge(fix.struc, (slabs = slabs,))
        cmap = SS._eq137_cell_slab_map(struc)
        @test cmap[2] === slabs[2]
        ln = 19.0u"ft"
        M0 = SS.total_static_moment(1.2 * 100.0psf + 1.6 * 60.0psf, 24.0u"ft", ln)
        direct = SS._eq137_transfer_moment(
            struc, fix.slab, fix.col, (1.0, 0.0), 100.0psf, 60.0psf,
            24.0u"ft", ln, M0; extra_columns = struc.columns, γ = ρ)
        ctx = SS._eq137_context(struc, struc.columns)
        cached = SS._eq137_transfer_moment(
            struc, fix.slab, fix.col, (1.0, 0.0), 100.0psf, 60.0psf,
            24.0u"ft", ln, M0; extra_columns = struc.columns, γ = ρ,
            index = ctx.index, vertex_column = ctx.vertex_column,
            cell_slab = ctx.cell_slab)
        @test ustrip(kip * u"ft", cached) == ustrip(kip * u"ft", direct)
        # USER DECISION (cycle 5): a cell listed by two slabs has no single
        # owner.  A 30 in duplicate of cell 2 would add about 260 psf of dead
        # load on the east side, so list order must not pick the answer.
        # Both orders throw, naming the cell and both slabs.
        dup = (cell_indices = [2], spans = fix.slab.spans,
               result = (thickness = 30.0u"inch",))
        for (order, names) in ((vcat(slabs, Any[dup]), ("slab 2", "slab 5")),
                               (vcat(Any[dup], slabs), ("slab 1", "slab 3")))
            bad = merge(struc, (slabs = order,))
            err = try
                SS._eq137_cell_slab_map(bad)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("cell 2", err.msg)
            @test all(n -> occursin(n, err.msg), names)
            @test_throws ArgumentError SS._eq137_context(bad, bad.columns)
            @test_throws ArgumentError SS._eq137_transfer_moment(
                bad, fix.slab, fix.col, (1.0, 0.0), 100.0psf, 60.0psf,
                24.0u"ft", ln, M0; extra_columns = bad.columns, γ = ρ)
            # The scan used without a precomputed map rejects it too.
            @test_throws ArgumentError SS._eq137_owning_slab(nothing, bad, 2)
        end
    end

    @testset "geometry-only applicability header is §13.6.9.2" begin
        geom = DDMApplicabilityError([
            "ACI 318-11 §13.6.9.2 Eq. (13-7) (corpus: aci-318-11, page 258): ambiguous",
        ])
        msg = sprint(showerror, geom)
        @test occursin("13.6.9.2", msg)
        @test !occursin("13.6.1", msg)
        with_alt = DDMApplicabilityError(geom.violations,
                                         ["FEA (Finite Element Analysis): method=FEA()"])
        msg_alt = sprint(showerror, with_alt)
        @test !occursin("13.6.1", msg_alt)
        @test occursin("method=FEA()", msg_alt)
        mixed = DDMApplicabilityError([
            "§13.6.1.3: successive spans",
            "ACI 318-11 §13.6.9.2 Eq. (13-7): ambiguous",
        ])
        @test occursin("13.6.1", sprint(showerror, mixed))
    end
end

"""
Duck-typed plan from named points (ft).  `faces` are lists of point names;
`cols` name the column vertices (square, `cdim`).  Points and column θ are
rotated by `θ` about the origin.  `col` names the column under test, which
gets `position`; the slab under design is the first face.
"""
function _c5_plan(pts, faces, cols, col; θ = 0.0, position = :interior,
                  qD = 150.0psf, qL = 50.0psf, cdim = 12.0u"inch")
    mtr = 0.3048
    id = Dict{Symbol,Int}()
    vc = zeros(length(pts), 2)
    for (k, (s, p)) in enumerate(pts)
        id[s] = k
        vc[k, 1] = (p[1] * cos(θ) - p[2] * sin(θ)) * mtr
        vc[k, 2] = (p[1] * sin(θ) + p[2] * cos(θ)) * mtr
    end
    fvi = [[id[s] for s in f] for f in faces]
    cells = [(face_idx = i, sdl = qD, live_load = qL, self_weight = 0.0psf)
             for i in eachindex(faces)]
    mk(s) = (vertex_idx = id[s], position = s == col ? position : :interior,
             c1 = cdim, c2 = cdim, θ = θ, structural_offset = (0.0, 0.0))
    columns = Any[mk(s) for s in cols]
    spans = (primary = 20.0u"ft", secondary = 20.0u"ft", axis = (cos(θ), sin(θ)))
    slabs = [(cell_indices = [i], spans = spans) for i in eachindex(faces)]
    struc = (cells = cells, slabs = slabs, columns = columns,
             skeleton = (geometry = (vertex_coords = vc,), face_vertex_indices = fvi))
    c = first(x for x in columns if x.vertex_idx == id[col])
    return (struc = struc, slab = slabs[1], col = c)
end

@testset "Eq. (13-7) cycle 5: ℓ2 cap, rotated quadrants, tag trust" begin
    qD = 150.0psf
    qL = 50.0psf
    kft(x) = ustrip(kip * u"ft", x)
    has_reason(tc, r) = any(e -> get(e.data, "reason", "") == r, tc.events)
    qu = max(1.4 * qD, 1.2 * qD + 1.6 * qL)
    M0 = SS.total_static_moment(qu, 20.0u"ft", 19.0u"ft")

    @testset "a face straddling the frame line is capped half-to-half" begin
        # ACI 318-11 §13.6.2.1 / §13.6.2.3 (corpus: aci-318-11, page 253).
        # West: one 18×40 ft face crossing the X frame line, the columns at
        # (0,0) and (-18,0) collinear vertices on its edges.  East: two
        # 25×20 ft panels.  ℓ2 = 10 + 10 = 20 ft each side, not 40 ft.
        pts = [:c => (0.0, 0.0), :w => (-18.0, 0.0), :e => (25.0, 0.0),
               :wn => (-18.0, 20.0), :ws => (-18.0, -20.0),
               :cn => (0.0, 20.0), :cs => (0.0, -20.0),
               :en => (25.0, 20.0), :es => (25.0, -20.0)]
        faces = [[:ws, :cs, :c, :cn, :wn, :w], [:c, :e, :en, :cn], [:cs, :es, :e, :c]]
        fix = _c5_plan(pts, faces, [:c, :w, :e, :wn, :ws, :cn, :cs, :en, :es], :c)
        hand = 0.07 * ((1.2 * qD + 0.5 * 1.6 * qL) * 20.0u"ft" * (24.0u"ft")^2 -
                       1.2 * qD * 20.0u"ft" * (17.0u"ft")^2)
        @test kft(hand) ≈ 104.58 rtol = 1e-4
        sides = SS._eq137_resolved_sides(fix.struc, fix.slab, fix.col, (1.0, 0.0);
                                         extra_columns = fix.struc.columns)
        @test length(sides) == 2
        for s in sides
            @test ustrip(u"ft", s.l2) ≈ 20.0 rtol = 1e-9
        end
        Mub, _ = _interior_mub(fix, qD, qL; ln_passed = 17.0u"ft")
        @test kft(Mub[1]) ≈ kft(hand) rtol = 1e-4
        @test abs(kft(Mub[1]) - 32.87) > 50.0
        # No column line off the frame line on the straddling face: the
        # half-to-half width is unknown.  Ambiguous geometry, not 40 ft.
        # The side resolution throws; the transfer path rejects the
        # connection (NaN, traced) instead of aborting (cycle 11a).
        bare = _c5_plan(pts, faces, [:c, :w, :e], :c)
        err = try
            SS._eq137_resolved_sides(bare.struc, bare.slab, bare.col, (1.0, 0.0);
                                     extra_columns = bare.struc.columns)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("13.6.9.2", err.msg) && occursin("ambiguous", err.msg)
        tc = TraceCollector()
        Mub_bare, _ = _interior_mub(bare, qD, qL; tc = tc)
        @test isnan(ustrip(Mub_bare[1]))
        @test any(e -> e.event_type == :failure &&
                       get(e.data, "reason", "") == "adjoining_spans_unresolved", tc.events)
    end

    @testset "re-entrant corner counted in the span-axis frame" begin
        # USER DECISION / ENGINEERING JUDGMENT: max(Eq. 13-7, 0.3 M0) and
        # max(M_ext, M_int) at a re-entrant corner.  The `_lplan` L (20/20 ft,
        # 12 in) rotated by θ and analysed along (cos θ, sin θ) is the same
        # corner; global-axis quadrants counted 0 at 45° (65.70 vs 70.40).
        # The merged plan has one west cell straddling the frame line.
        pts = [:a => (0.0, 0.0), :b => (20.0, 0.0), :c => (40.0, 0.0),
               :d => (0.0, 20.0), :e => (20.0, 20.0), :f => (40.0, 20.0),
               :g => (0.0, 40.0), :h => (20.0, 40.0)]
        split = [[:a, :b, :e, :d], [:d, :e, :h, :g], [:b, :c, :f, :e]]
        merged = [[:a, :b, :e, :h, :g, :d], [:b, :c, :f, :e]]
        cols = [:a, :b, :c, :d, :e, :f, :g, :h]
        M_ext = 80.0kip * u"ft"
        M_int = 70.0kip * u"ft"
        @test kft(0.3 * M0) ≈ 70.40 rtol = 1e-3
        for (faces, θs) in ((split, (0.0, π / 6, π / 4)), (merged, (0.0, π / 6, π / 4)))
            for θ in θs
                fix = _c5_plan(pts, faces, cols, :e; θ = θ, position = :corner)
                axis = (cos(θ), sin(θ))
                idx = SS._eq137_vertex_cell_index(fix.struc)
                @test SS._eq137_quadrant_count(fix.struc, fix.col, idx, axis) == 3
                Mub, _ = _interior_mub(fix, qD, qL; l2 = 20.0u"ft",
                                       ln_passed = 19.0u"ft", axis = axis)
                @test kft(Mub[1]) ≈ kft(0.3 * M0) rtol = 1e-6
                tc = TraceCollector()
                SS._eq137_transfer_moment(fix.struc, fix.slab, fix.col, axis, qD, qL,
                                          20.0u"ft", 19.0u"ft", M0; tc = tc)
                @test any(e -> e.event_type == :decision &&
                               get(e.data, "reason", "") == "reentrant_corner", tc.events)
                tc = TraceCollector()
                @test SS._ddm_support_moment(fix.struc, fix.col, axis, M_ext, M_int;
                                             tc = tc) == M_ext
                @test any(e -> e.event_type == :decision && e.stage == "_ddm_support_moment" &&
                               get(e.data, "reason", "") == "reentrant_corner", tc.events)
            end
        end
    end

    @testset "tag/geometry disagreement: geometry if conforming, else envelope" begin
        # USER DECISION.  Interior tag, slab only west of the column in the
        # vertex index.  `lone` has no east slab.  In `tee` an east face runs
        # past the column without listing its vertex (a T-junction), so the
        # east panel is hidden and the larger moment is used.
        pts = [:w => (0.0, 0.0), :c => (20.0, 0.0), :wn => (0.0, 20.0),
               :cn => (20.0, 20.0), :ws => (0.0, -20.0), :cs => (20.0, -20.0),
               :en => (40.0, 20.0), :es => (40.0, -20.0)]
        west = [[:w, :c, :cn, :wn], [:ws, :cs, :c, :w]]
        cols = [:w, :c, :cn, :cs, :en, :es]
        lone = _c5_plan(pts, west, cols, :c)
        tee = _c5_plan(pts, vcat(west, [[:cs, :es, :en, :cn]]), cols, :c)
        M_ext = 65.0kip * u"ft"
        M_int = 70.0kip * u"ft"
        mat = RC_4000_60
        wc = ustrip(pcf, mat.concrete.ρ)
        for (fix, conforms, want, r) in ((lone, true, M_ext, "one_sided_interior"),
                                         (tee, false, M_int, "ambiguous_neighbourhood_envelope"))
            idx = SS._eq137_vertex_cell_index(fix.struc)
            vmap = SS._eq137_vertex_column_map(fix.struc, ())
            @test SS._eq137_mesh_conforms(fix.struc, fix.col, idx, vmap) == conforms
            tc = TraceCollector()
            @test SS._ddm_support_moment(fix.struc, fix.col, (1.0, 0.0), M_ext, M_int;
                                         tc = tc) == want
            @test has_reason(tc, r)
            # The NLP flexural moment uses the same classification.
            p = FlatPlateNLPProblem(
                mat, mat.concrete.fc′, mat.rebar.Fy, mat.rebar.E,
                Ec(mat.concrete.fc′, wc), mat.concrete.ρ, mat.concrete.λ,
                20.0u"ft", 20.0u"ft", qD, qL,
                [:interior], [100.0], 3.0,
                0.65, 0.70, 0.35,
                0.75u"inch", bar_diameter(5),
                0.90, 0.75, :L_360,
                (6.0, 12.0), (10.0, 24.0),
                [5], MinVolume(),
                (struc = fix.struc, slab = fix.slab, columns = [fix.col],
                 span_axis = (1.0, 0.0), index = idx),
            )
            @test SS._nlp_support_moment(p, 1, (1.0, 0.0), M_ext, M_int) == want
            # Transfer `lone`: max(equal-span, 0.3 M0) is 0.3 M0 for these
            # loads.  `tee` (cycle 11a): the envelope also reads the hidden
            # east face as the east side (slab coverage, `_eq137_cell_sides`);
            # with no column at (40, 0) that side ends at the slab edge, whose
            # admitted range runs down to ℓn = 0, so Eq. (13-7) (§13.6.9.2,
            # corpus: aci-318-11, page 258) is the west term alone:
            # 0.07 (1.2 qD + 0.5·1.6 qL) ℓ2 ℓn² with ℓ2 = 20 ft, ℓn = 19 ft.
            want_Mub = conforms ? 0.3 * M0 :
                0.07 * (1.2 * qD + 0.5 * 1.6 * qL) * 20.0u"ft" * (19.0u"ft")^2
            tc = TraceCollector()
            Mub = SS._eq137_transfer_moment(fix.struc, fix.slab, fix.col, (1.0, 0.0),
                                            qD, qL, 20.0u"ft", 19.0u"ft", M0; tc = tc)
            @test kft(Mub) ≈ kft(want_Mub) rtol = 1e-9
            @test kft(Mub) >= kft(0.3 * M0) * (1 - 1e-9)
            @test has_reason(tc, r)
        end

        # Exterior tag (:edge without boundary directions), slab on both
        # sides along X.  `stray` puts a column partway along the east
        # panel's north edge without being one of its vertices.
        pts2 = [:w => (0.0, 0.0), :c => (29.0, 0.0), :e => (49.0, 0.0),
                :wn => (0.0, 20.0), :cn => (29.0, 20.0), :en => (49.0, 20.0),
                :s => (39.0, 20.0)]
        faces2 = [[:w, :c, :cn, :wn], [:c, :e, :en, :cn]]
        clean = _c5_plan(pts2, faces2, [:w, :c, :e], :c; position = :edge)
        stray = _c5_plan(pts2, faces2, [:w, :c, :e, :s], :c; position = :edge)
        half = abs(0.07 * ((1.2 * qD + 0.5 * 1.6 * qL) * 10.0u"ft" * (28.0u"ft")^2 -
                           1.2 * qD * 10.0u"ft" * (19.0u"ft")^2))
        M0_long = SS.total_static_moment(qu, 20.0u"ft", 28.0u"ft")
        @test kft(0.3 * M0_long) > kft(half) + 50.0
        M_ext2 = 80.0kip * u"ft"
        for (fix, want_M, want_Mub, r) in
                ((clean, M_int, half, "exterior_tag_two_sided"),
                 (stray, M_ext2, 0.3 * M0_long, "exterior_tag_nonconforming"))
            tc = TraceCollector()
            @test SS._ddm_support_moment(fix.struc, fix.col, (1.0, 0.0), M_ext2, M_int;
                                         tc = tc) == want_M
            @test has_reason(tc, r)
            tc = TraceCollector()
            Mub = SS._eq137_transfer_moment(fix.struc, fix.slab, fix.col, (1.0, 0.0),
                                            qD, qL, 20.0u"ft", 28.0u"ft", M0_long; tc = tc)
            @test kft(Mub) ≈ kft(want_Mub) rtol = 1e-3
            @test has_reason(tc, r)
        end
    end

    @testset "two columns at one far vertex must agree" begin
        # ENGINEERING JUDGMENT: neither the smaller nor the larger far face is
        # conservative for Eq. (13-7) in general, so different sizes throw.
        fix = _two_bay(west_ft = 29.0, east_ft = 20.0)
        far = fix.struc.columns[end]
        same = merge(far, (position = :edge,))
        big = merge(far, (c1 = 24.0u"inch", c2 = 24.0u"inch"))
        ref, _ = _interior_mub(fix, qD, qL)
        ok = merge(fix.struc, (columns = vcat(fix.struc.columns, Any[same]),))
        got, _ = _interior_mub((struc = ok, slab = fix.slab, col = fix.col), qD, qL)
        @test kft(got[1]) == kft(ref[1])
        bad = merge(fix.struc, (columns = vcat(fix.struc.columns, Any[big]),))
        err = try
            SS._eq137_resolved_sides(bad, fix.slab, fix.col, (1.0, 0.0);
                                     extra_columns = bad.columns)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("13.6.9.2", err.msg) && occursin("ambiguous", err.msg)
        # The transfer path rejects the connection (NaN, traced), cycle 11a.
        tc = TraceCollector()
        Mub_bad, _ = _interior_mub((struc = bad, slab = fix.slab, col = fix.col), qD, qL;
                                   tc = tc)
        @test isnan(ustrip(Mub_bad[1]))
        @test any(e -> e.event_type == :failure &&
                       get(e.data, "reason", "") == "adjoining_spans_unresolved", tc.events)
        r = SS.check_ddm_applicability(bad, fix.slab, [fix.col]; throw_on_failure = false)
        @test any(v -> occursin("13.6.9.2", v), r.violations)
        @test !any(v -> occursin("13.6.1.3", v), r.violations)
    end

    @testset "non-positive clear span has its own header" begin
        # 240 in columns on a 20 ft bay: ℓn = 20 − 10 − 10 = 0 (§13.6.2.5).
        fix = _two_bay(west_ft = 29.0, east_ft = 20.0, c_in = 240.0)
        err = try
            SS._eq137_resolved_sides(fix.struc, fix.slab, fix.col, (1.0, 0.0);
                                     extra_columns = fix.struc.columns)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("non-positive", err.msg)
        msg = sprint(showerror, DDMApplicabilityError([err.msg]))
        @test occursin("column faces consume the clear span", msg)
        @test !occursin("ambiguous", msg)
        @test !occursin("13.6.1:", msg) && !occursin("§13.6.1:", msg)
        both = sprint(showerror, DDMApplicabilityError([
            err.msg, "ACI 318-11 §13.6.9.2 Eq. (13-7): ambiguous"]))
        @test occursin("ambiguous", both) && occursin("clear span", both)
        amb = sprint(showerror, DDMApplicabilityError([
            "ACI 318-11 §13.6.9.2 Eq. (13-7): ambiguous"]))
        @test !occursin("column faces consume", amb)
    end
end

# =============================================================================
# Fix cycle 5 part 2: every Eq. (13-7) / §13.6.3.3 fallback is a trace event,
# on the DDM, NLP, and rule-of-thumb paths, not only a once-per-process warning.
# =============================================================================

@testset "Eq. (13-7) fallbacks emit trace events" begin
    qD = 150.0psf
    qL = 50.0psf
    kft(x) = ustrip(kip * u"ft", x)
    has_reason(tc, r) = any(e -> e.event_type == :fallback &&
                                 get(e.data, "reason", "") == r, tc.events)
    qu = max(1.4 * qD, 1.2 * qD + 1.6 * qL)
    M0 = SS.total_static_moment(qu, 20.0u"ft", 28.0u"ft")
    mat = RC_4000_60
    wc = ustrip(pcf, mat.concrete.ρ)
    nlp(positions, eq137 = nothing, tc = nothing) = FlatPlateNLPProblem(
        mat, mat.concrete.fc′, mat.rebar.Fy, mat.rebar.E,
        Ec(mat.concrete.fc′, wc), mat.concrete.ρ, mat.concrete.λ,
        20.0u"ft", 20.0u"ft", 20.0psf, 40.0psf,
        positions, fill(100.0, length(positions)), 3.0,
        0.26, 0.70, 0.52,
        0.75u"inch", bar_diameter(5),
        0.90, 0.75, :L_360,
        (6.0, 12.0), (10.0, 24.0),
        [5], MinVolume(), eq137, tc,
    )

    @testset "NLP positional fallback is traced, in helpers and evaluate()" begin
        # Without stored geometry the NLP uses the position tag.  That
        # fallback used to be silent.
        p0 = nlp([:edge, :interior])
        tc = TraceCollector()
        SS._nlp_transfer_moment(p0, 1, qD, qL, 20.0u"ft", 19.0u"ft",
                                (1.0, 0.0), 12.0u"inch", M0; tc = tc)
        SS._nlp_support_moment(p0, 2, (1.0, 0.0), 1.0kip * u"ft", 2.0kip * u"ft"; tc = tc)
        @test any(e -> e.stage == "_nlp_transfer_moment" && e.element_id == "nlp_col_1", tc.events)
        @test any(e -> e.stage == "_nlp_support_moment" && e.element_id == "nlp_col_2", tc.events)
        @test has_reason(tc, "no_geometry_position")

        # A column index past the stored geometry is a data mismatch.
        fix = _two_bay(west_ft = 29.0, east_ft = 20.0)
        pm = nlp([:interior], (struc = fix.struc, slab = fix.slab, columns = Any[],
                               span_axis = (1.0, 0.0)))
        tc = TraceCollector()
        SS._nlp_support_moment(pm, 1, (1.0, 0.0), 1.0kip * u"ft", 2.0kip * u"ft"; tc = tc)
        @test has_reason(tc, "column_not_in_geometry")

        # evaluate() threads the problem's collector.  Every grid point
        # raises the same fallbacks; each distinct event is kept once.
        tc = TraceCollector()
        p = nlp([:edge, :interior], nothing, tc)
        SS.evaluate(p, [8.0, 16.0])
        n1 = length(tc.events)
        @test any(e -> e.stage == "_nlp_transfer_moment", tc.events)
        @test any(e -> e.stage == "_nlp_support_moment", tc.events)
        @test has_reason(tc, "no_geometry_position")
        SS.evaluate(p, [9.0, 18.0])
        @test length(tc.events) == n1
        ids = [(e.stage, e.element_id, e.data) for e in tc.events]
        @test length(unique(ids)) == length(ids)
        # No collector: no trace state is touched.
        @test isnothing(nlp([:edge]).tc)
    end

    @testset "neighbour self-weight fallbacks are traced" begin
        # `_two_bay` neighbours have zero cell.self_weight and no slab
        # result, so Eq. (13-7) uses the design trial self-weight there.
        fix = _two_bay(west_ft = 29.0, east_ft = 20.0, qD = 100.0psf)
        tc = TraceCollector()
        SS._eq137_transfer_moment(fix.struc, fix.slab, fix.col, (1.0, 0.0),
                                  qD, qL, 20.0u"ft", 28.0u"ft", M0;
                                  γ = mat.concrete.ρ, tc = tc)
        @test any(e -> e.stage == "_eq137_neighbour_sw" &&
                       get(e.data, "reason", "") == "missing_neighbour_sw", tc.events)
        # DDM primary path threads the same collector.
        tc = TraceCollector()
        SS._compute_column_demands_ddm(
            fix.struc, [fix.col], 0.26 * M0, 0.65 * M0, 0.35 * M0,
            qu, qD, qL, 20.0u"ft", 28.0u"ft", (1.0, 0.0), M0;
            slab = fix.slab, γ = mat.concrete.ρ, tc = tc)
        @test has_reason(tc, "missing_neighbour_sw")

        # Stored self-weight disagrees with the owning slab's result
        # thickness: the thickness wins, and that is traced too.
        γ = mat.concrete.ρ
        cells = copy(fix.struc.cells)
        cells[2] = merge(cells[2], (self_weight = 50.0psf,))
        slabs = copy(fix.struc.slabs)
        slabs[2] = merge(slabs[2], (result = (thickness = 10.0u"inch",),))
        struc = merge(fix.struc, (cells = cells, slabs = slabs))
        tc = TraceCollector()
        sw = SS._eq137_neighbour_sw(struc, 2, 75.0psf, γ; tc = tc)
        @test ustrip(psf, sw) ≈ ustrip(psf, SS.slab_self_weight(10.0u"inch", γ)) rtol = 1e-9
        @test any(e -> e.element_id == "cell_2" &&
                       get(e.data, "reason", "") == "stale_self_weight", tc.events)
    end

    @testset "far support that is not a column is traced; ℓn has no far face" begin
        # Only the column under test is a column.  Both frame-line ends are
        # slab boundary, so ℓn runs from the near face to the boundary vertex.
        fix = _two_bay(west_ft = 29.0, east_ft = 20.0)
        struc = merge(fix.struc, (columns = Any[fix.col],))
        tc = TraceCollector()
        sides = SS._eq137_resolved_sides(struc, fix.slab, fix.col, (1.0, 0.0);
                                         extra_columns = struc.columns, tc = tc)
        @test length(sides) == 2
        for s in sides
            @test ustrip(u"ft", s.ln) ≈ ustrip(u"ft", s.l_cc) - 0.5 rtol = 1e-9
        end
        @test count(e -> e.stage == "_eq137_resolved_sides" &&
                         get(e.data, "reason", "") == "far_support_not_column", tc.events) == 2
        tc = TraceCollector()
        SS._eq137_transfer_moment(struc, fix.slab, fix.col, (1.0, 0.0),
                                  qD, qL, 20.0u"ft", 28.0u"ft", M0; tc = tc)
        @test has_reason(tc, "far_support_not_column")
        # Columns at both ends: no such event.
        tc = TraceCollector()
        SS._eq137_resolved_sides(fix.struc, fix.slab, fix.col, (1.0, 0.0);
                                 extra_columns = fix.struc.columns, tc = tc)
        @test !has_reason(tc, "far_support_not_column")
    end

    @testset "rule-of-thumb transfer: non-finite demand is infeasible and traced" begin
        # ACI 318-11 §13.5.3 (corpus: aci-318-11, page 250).  An infinite
        # or NaN transfer moment must not become a design.
        col = (c1 = 16.0u"inch", c2 = 16.0u"inch", position = :interior)
        h = 8.0u"inch"
        d = 6.75u"inch"
        fc = mat.concrete.fc′
        fy = mat.rebar.Fy
        for bad in (Inf * kip * u"ft", NaN * kip * u"ft")
            for (mx, my) in ((bad, nothing), (10.0kip * u"ft", bad))
                failures = String[]
                out = Union{Nothing, NamedTuple}[nothing]
                tc = TraceCollector()
                sec = isnothing(my) ? nothing : (unbalanced_moments = [my],)
                ok = SS._rot_transfer_reinforcement!(
                    out, failures, [col], (unbalanced_moments = [mx],), sec,
                    nothing, h, d, fc, fy; tc = tc, slab_id = "slab_7")
                @test ok == false
                @test failures == ["transfer_reinforcement"]
                @test isnothing(out[1])
                @test any(e -> e.event_type == :failure && e.element_id == "slab_7" &&
                               get(e.data, "reason", "") == "transfer_moment_non_finite",
                          tc.events)
            end
        end
        # A NaN steel area is also inadequate (not only Inf).
        @test SS.transfer_section_inadequate(NaN * u"inch^2")
        @test SS.transfer_section_inadequate(Inf * u"inch^2")
        @test !SS.transfer_section_inadequate(1.0u"inch^2")
    end

    @testset "non-finite transfer input is inadequate on every path" begin
        # ACI 318-11 §13.5.3 (corpus: aci-318-11, page 250).  Mux = 20 kip·ft
        # with Muy = NaN used to return the x-direction As (0.40 in²) because
        # `NaN > As_x` is false, so the section passed.
        col = (c1 = 16.0u"inch", c2 = 16.0u"inch", position = :interior)
        h = 8.0u"inch"
        d = 6.75u"inch"
        fc = mat.concrete.fc′
        fy = mat.rebar.Fy
        good = 20.0kip * u"ft"
        for bad in (NaN * kip * u"ft", Inf * kip * u"ft", -Inf * kip * u"ft"),
            pos in (:interior, :edge, :corner)
            for (mx, my) in ((good, bad), (bad, good), (bad, bad))
                gov = SS.governing_transfer_reinforcement(
                    mx, my, col.c1, col.c2, h, d, fc, fy; position = pos)
                @test SS.transfer_section_inadequate(gov.As)
            end
        end
        @test SS.transfer_section_inadequate(SS.governing_transfer_reinforcement(
            good, good, NaN * u"inch", col.c2, h, d, fc, fy).As)
        @test SS.transfer_section_inadequate(SS.governing_transfer_reinforcement(
            good, good, col.c1, col.c2, h, NaN * u"inch", fc, fy).As)
        ok_gov = SS.governing_transfer_reinforcement(good, good, col.c1, col.c2, h, d, fc, fy)
        @test !SS.transfer_section_inadequate(ok_gov.As)
        @test ustrip(u"inch^2", ok_gov.As) > 0

        # Iterative pipeline (`_run_final_design` → `_pipeline_transfer_reinforcement`).
        nanM = NaN * kip * u"ft"
        for (prim, sec) in ((good, nanM), (nanM, good), (nanM, nothing))
            secr = isnothing(sec) ? nothing : (unbalanced_moments = [sec],)
            r = SS._pipeline_transfer_reinforcement(
                [col], (unbalanced_moments = [prim],), secr, nothing, h, d, fc, fy)
            @test r.ok == false
            @test r.column == 1
            @test isnothing(r.results[1])
        end

        # NLP rebar evaluation.
        p = nlp([:interior])
        mres = (l2 = 20.0u"ft", M_neg_ext = 30.0kip * u"ft",
                M_pos = 40.0kip * u"ft", M_neg_int = 60.0kip * u"ft",
                unbalanced_moments = [good])
        for my in (nanM, Inf * kip * u"ft")
            r = SS._evaluate_rebar_for_size(p, mres, h, d, 5, 16.0u"inch", [my])
            @test isinf(ustrip(u"inch^2", r.total_As))
        end
        r_ok = SS._evaluate_rebar_for_size(p, mres, h, d, 5, 16.0u"inch", [good])
        @test isfinite(ustrip(u"inch^2", r_ok.total_As))

        # Rule-of-thumb: finite moments, non-finite column size reaches
        # `governing_transfer_reinforcement` and is rejected there.
        bad_col = (c1 = NaN * u"inch", c2 = 16.0u"inch", position = :interior)
        failures = String[]
        out = Union{Nothing, NamedTuple}[nothing]
        tc = TraceCollector()
        ok = SS._rot_transfer_reinforcement!(
            out, failures, [bad_col], (unbalanced_moments = [good],),
            (unbalanced_moments = [good],), nothing, h, d, fc, fy;
            tc = tc, slab_id = "slab_3")
        @test ok == false
        @test failures == ["transfer_reinforcement"]
        @test isnothing(out[1])
        @test any(e -> e.event_type == :failure &&
                       get(e.data, "reason", "") == "transfer_section_inadequate", tc.events)
    end

    @testset "edge-beam keywords reach every moment analysis call" begin
        # Pipeline phase A, phase B and the rule-of-thumb pass all give the
        # analysis `has_edge_beam` / explicit `edge_beam_βt` beside `βt`.
        kw = SS._edge_beam_analysis_kwargs(FlatPlateOptions())
        @test kw == (has_edge_beam = false, edge_beam_βt = 0.0)
        kw = SS._edge_beam_analysis_kwargs(FlatPlateOptions(has_edge_beam = true))
        @test kw == (has_edge_beam = true, edge_beam_βt = 0.0)
        kw = SS._edge_beam_analysis_kwargs(FlatPlateOptions(edge_beam_βt = 1.5))
        @test kw == (has_edge_beam = false, edge_beam_βt = 1.5)
        fp_dir = joinpath(pkgdir(SS), "src", "slabs", "codes", "concrete", "flat_plate")
        for (file, n_calls) in (("pipeline.jl", 4), (joinpath("design", "rule_of_thumb.jl"), 2))
            src = read(joinpath(fp_dir, file), String)
            @test count(r"\brun_(secondary_)?moment_analysis\(", src) == n_calls
            @test count("_edge_beam_analysis_kwargs(opts)...", src) == n_calls
        end
    end

    if HAS_STRUCTURAL_SYNTHESIZER
        @testset "rule-of-thumb path traces DDM fallbacks" begin
            # One-storey 3×3 office; tag an interior column :corner so the
            # geometry (slab on both sides) and the tag disagree.  On a
            # conforming mesh both §13.6.3.3 and Eq. (13-7) follow geometry
            # and trace it, so the ROT path must deliver those events.
            skel = gen_medium_office(72.0u"ft", 72.0u"ft", 9.0u"ft", 3, 3, 1)
            struc = BuildingStructure(skel)
            opts = FlatPlateOptions(method = RuleOfThumb())
            initialize!(struc; material = NWC_4000, floor_type = :flat_plate,
                        floor_opts = opts)
            slab = first(struc.slabs)
            cols = SS.find_supporting_columns(struc, Set(slab.cell_indices))
            interior = first(c for c in cols if c.position == :interior)
            interior.position = :corner
            tc = TraceCollector()
            SS.size_flat_plate!(struc, slab, ConcreteColumnOptions();
                                method = RuleOfThumb(), opts = opts, tc = tc)
            @test any(e -> e.stage == "_eq137_transfer_moment" &&
                           get(e.data, "reason", "") == "exterior_tag_two_sided", tc.events)
            @test any(e -> e.stage == "_ddm_support_moment" &&
                           get(e.data, "reason", "") == "exterior_tag_two_sided", tc.events)
        end

        @testset "NLP rebuilds stale Eq. (13-7) maps after struc.slabs changes" begin
            skel = gen_medium_office(72.0u"ft", 72.0u"ft", 9.0u"ft", 3, 3, 1)
            struc = BuildingStructure(skel)
            initialize!(struc; material = NWC_4000, floor_type = :flat_plate,
                        floor_opts = FlatPlateOptions(method = DDM()))
            slab = first(struc.slabs)
            cols = SS.find_supporting_columns(struc, Set(slab.cell_indices))
            tc = TraceCollector()
            p = FlatPlateNLPProblem(struc, slab, cols, FlatPlateOptions(); tc = tc)
            @test !SS._nlp_eq137_stale(p)
            dropped = pop!(slab.cell_indices)
            try
                before = SS._nlp_eq137_maps(p)
                @test haskey(before.cell_slab, dropped)
                @test SS._nlp_eq137_stale(p)
                SS.evaluate(p, [9.0, 18.0])
                @test !SS._nlp_eq137_stale(p)
                @test !haskey(SS._nlp_eq137_maps(p).cell_slab, dropped)
                # The old snapshot is replaced, not emptied and refilled.
                @test haskey(before.cell_slab, dropped)
                @test SS._nlp_eq137_maps(p).cell_slab !== before.cell_slab
                @test any(e -> e.event_type == :decision &&
                               get(e.data, "reason", "") == "eq137_maps_rebuilt", tc.events)
            finally
                push!(slab.cell_indices, dropped)
            end
        end

        @testset "NLP Eq. (13-7) maps: geometry staleness and atomic swap" begin
            # A moved skeleton vertex or a re-pointed cell face changes the
            # maps' inputs, so it must trigger a rebuild.  The rebuild swaps
            # a whole new map set; grid-search threads evaluating while it
            # happens must give the same answers as a serial run.
            skel = gen_medium_office(72.0u"ft", 72.0u"ft", 9.0u"ft", 3, 3, 1)
            struc = BuildingStructure(skel)
            initialize!(struc; material = NWC_4000, floor_type = :flat_plate,
                        floor_opts = FlatPlateOptions(method = DDM()))
            slab = first(struc.slabs)
            cols = SS.find_supporting_columns(struc, Set(slab.cell_indices))
            p = FlatPlateNLPProblem(struc, slab, cols, FlatPlateOptions())

            vc = struc.skeleton.geometry.vertex_coords
            vi = SS.col_vertex_idx(first(cols))
            x0 = vc[vi, 1]
            try
                vc[vi, 1] = x0 + 1e-3
                @test SS._nlp_eq137_stale(p)
                SS.evaluate(p, [9.0, 18.0])
                @test !SS._nlp_eq137_stale(p)
            finally
                vc[vi, 1] = x0
            end
            @test SS._nlp_eq137_stale(p)
            SS.evaluate(p, [9.0, 18.0])
            @test !SS._nlp_eq137_stale(p)

            cell = struc.cells[first(slab.cell_indices)]
            fi0 = cell.face_idx
            try
                cell.face_idx = fi0 + 1
                @test SS._nlp_eq137_stale(p)
            finally
                cell.face_idx = fi0
            end
            @test !SS._nlp_eq137_stale(p)

            lb, ub = SS.variable_bounds(p)
            grid = [[h, c] for h in range(lb[1], ub[1]; length = 3)
                           for c in range(lb[2], ub[2]; length = 3)]
            ref = [SS.evaluate(p, x)[1:2] for x in grid]
            @test any(r -> r[1], ref)
            n = 6 * length(grid)
            out = Vector{Any}(undef, n)
            mid = n ÷ 2
            Threads.@threads for k in 1:n
                if k == mid
                    # Force a rebuild while other threads are evaluating:
                    # the stored slab cell lists no longer match, while the
                    # maps and geometry the threads read are unchanged.
                    cur = SS._nlp_eq137_maps(p)
                    @atomic p.eq137.maps.ctx = merge(cur, (slab_cells = Any[],))
                end
                out[k] = SS.evaluate(p, grid[mod1(k, length(grid))])[1:2]
            end
            @test all(out[k] == ref[mod1(k, length(grid))] for k in 1:n)
            @test !SS._nlp_eq137_stale(p)
        end

        @testset "NLP evaluate reads one frozen geometry (no old-maps/new-geometry mix)" begin
            # P2-4 regression: the maps snapshot also freezes the vertex
            # coordinates, faces and column sizes they were built from.  A
            # mutation of `struc` after the snapshot is taken must not reach
            # a call holding that snapshot (Mub and Muy of one grid point see
            # one geometry); the next `evaluate` rebuilds from the new one.
            skel = gen_medium_office(72.0u"ft", 72.0u"ft", 9.0u"ft", 3, 3, 1)
            struc = BuildingStructure(skel)
            initialize!(struc; material = NWC_4000, floor_type = :flat_plate,
                        floor_opts = FlatPlateOptions(method = DDM()))
            slab = first(struc.slabs)
            cols = SS.find_supporting_columns(struc, Set(slab.cell_indices))
            p = FlatPlateNLPProblem(struc, slab, cols, FlatPlateOptions())
            ax = SS._get_span_axis(slab)
            qD, qL = 150.0psf, 50.0psf
            l2, ln = 24.0u"ft", 22.5u"ft"
            M0 = SS.total_static_moment(1.2 * qD + 1.6 * qL, l2, ln)
            i = findfirst(eachindex(cols)) do k
                s = SS._eq137_resolved_sides(struc, slab, cols[k], ax;
                                             extra_columns = cols)
                s !== nothing && length(s) == 2
            end
            @test i !== nothing
            maps = SS._nlp_eq137_maps(p)
            mub(m) = SS._nlp_transfer_moment(p, i, qD, qL, l2, ln, ax, 18.0u"inch", M0;
                                             maps = m)
            ref = mub(maps)
            vc = struc.skeleton.geometry.vertex_coords
            vi = SS.col_vertex_idx(cols[i])
            x0, y0 = vc[vi, 1], vc[vi, 2]
            try
                # Move the column 0.5 ft along the span: both adjoining
                # clear spans change, so a live read would change Mub.
                vc[vi, 1] = x0 + 0.1524 * ax[1]
                vc[vi, 2] = y0 + 0.1524 * ax[2]
                @test SS._nlp_eq137_stale(p)
                @test mub(maps) == ref
                live = SS._eq137_transfer_moment(struc, slab, cols[i], ax, qD, qL, l2, ln, M0;
                                                 c_override = 18.0u"inch",
                                                 extra_columns = cols, γ = p.γ_concrete)
                @test !isapprox(ustrip(kip * u"ft", live), ustrip(kip * u"ft", ref); rtol = 1e-6)
                SS.evaluate(p, [9.0, 18.0])
                @test !SS._nlp_eq137_stale(p)
                @test mub(SS._nlp_eq137_maps(p)) ≈ live rtol = 1e-12
            finally
                vc[vi, 1] = x0
                vc[vi, 2] = y0
            end
            SS.evaluate(p, [9.0, 18.0])
            @test mub(SS._nlp_eq137_maps(p)) == ref
        end
    end
end

# =============================================================================
# Fix cycle 6: one on-line predicate for membership and the ℓ2 cap, a
# T-junction check that does not depend on the tag, and the FrameLine DDM
# classified by the same rule as the single-panel DDM.
# =============================================================================

"""
3×3 column grid sheared by `deg`: every column row is tilted by `deg`
relative to the X span axis, pivoting on the column under test at
(`west_ft`, 0).  Columns at x = 0, west, west + east on rows y = −20, 0, 20;
all 12 in square, θ = 0.  The column under test is `:interior`, the rest
`:edge`.
"""
function _c6_sheared(deg; west_ft = 29.0, east_ft = 40.0, y_ft = 20.0,
                     qD = 150.0psf, qL = 50.0psf)
    mtr = 0.3048
    s = tand(deg)
    xs = (0.0, west_ft, west_ft + east_ft)
    ys = (-y_ft, 0.0, y_ft)
    id = Dict{Tuple{Int,Int},Int}()
    vc = zeros(9, 2)
    k = 0
    for (i, x) in enumerate(xs), (j, y) in enumerate(ys)
        k += 1
        id[(i, j)] = k
        vc[k, 1] = x * mtr
        vc[k, 2] = (y + (x - west_ft) * s) * mtr
    end
    faces = [[id[(i, j)], id[(i + 1, j)], id[(i + 1, j + 1)], id[(i, j + 1)]]
             for i in 1:2 for j in 1:2]
    cells = [(face_idx = f, sdl = qD, live_load = qL, self_weight = 0.0psf) for f in 1:4]
    c = 12.0u"inch"
    cols = Any[(vertex_idx = id[(i, j)], position = (i, j) == (2, 2) ? :interior : :edge,
                c1 = c, c2 = c, θ = 0.0, structural_offset = (0.0, 0.0))
               for i in 1:3 for j in 1:3]
    col = cols[findfirst(x -> x.vertex_idx == id[(2, 2)], cols)]
    spans = (primary = west_ft * u"ft", secondary = y_ft * u"ft", axis = (1.0, 0.0))
    slabs = [(cell_indices = [f], spans = spans) for f in 1:4]
    struc = (cells = cells, slabs = slabs, columns = cols,
             skeleton = (geometry = (vertex_coords = vc,), face_vertex_indices = faces))
    return (struc = struc, slab = slabs[1], col = col)
end

@testset "Eq. (13-7) cycle 6: on-line predicate, T-junctions, FrameLine" begin
    qD = 150.0psf
    qL = 50.0psf
    kft(x) = ustrip(kip * u"ft", x)
    has_reason(tc, r) = any(e -> get(e.data, "reason", "") == r, tc.events)

    @testset "sheared grid: ℓ2 and Mub do not collapse up to 5°" begin
        # ACI 318-11 §13.6.9.2 Eq. (13-7) (corpus: aci-318-11, page 258).
        # 0°: ℓ2 = 20 ft both sides, ℓn = 39 ft east and 28 ft west:
        #   Mu = 0.07[(1.2·150 + 0.5·1.6·50)·20·39² − 1.2·150·20·28²] = 270.9 kip-ft.
        # Shearing the rows moves the far column off the X line by
        # ℓ_cc·tan θ (2.10 ft east at 3°, 3.50 ft at 5°), inside the
        # §13.6.1.4 10% offset (page 252).  The rows stay parallel, so the
        # perpendicular distance between adjacent column lines measured at
        # each panel's own column vertices stays 20 ft, and the far columns
        # keep their along-axis distance.  Each panel's centreline width
        # trades between its two halves (e.g. 9.30 + 10.70 ft at 2°), so
        # Σℓ2 and ℓn, and with them Mub, equal the 0° values to float
        # precision: rtol 1e-6.  Cycle 5 gave east widths [0.70, 9.49] ft
        # and Mub 58.0 at 2° (far column counted as the next column line).
        qu = max(1.4 * qD, 1.2 * qD + 1.6 * qL)
        M0 = SS.total_static_moment(qu, 20.0u"ft", 28.0u"ft")
        mub(fix) = SS._compute_column_demands_ddm(
            fix.struc, [fix.col], 0.26 * M0, 0.65 * M0, 0.35 * M0,
            qu, qD, qL, 20.0u"ft", 28.0u"ft", (1.0, 0.0), M0; slab = fix.slab)[3][1]
        ref = mub(_c6_sheared(0.0))
        @test kft(ref) ≈ 270.9 rtol = 1e-4
        for deg in (1.5, 2.0, 3.0, 5.0)
            fix = _c6_sheared(deg)
            sides = SS._eq137_resolved_sides(fix.struc, fix.slab, fix.col, (1.0, 0.0);
                                             extra_columns = fix.struc.columns)
            @test length(sides) == 2
            for s in sides
                @test ustrip(u"ft", s.l2) ≈ 20.0 rtol = 1e-6
                @test all(t -> ustrip(u"ft", t) > 8.0, s.tribs)
            end
            @test sort([ustrip(u"ft", s.ln) for s in sides]) ≈ [28.0, 39.0] rtol = 1e-9
            @test kft(mub(fix)) ≈ kft(ref) rtol = 1e-6
        end
    end

    @testset "a column on the own transverse line is not the next column line" begin
        # A column vertex 1.4 ft north of the column under test, on the
        # east panel's west edge, used to cap that panel at 0.70 ft.
        pts = [:w => (0.0, 0.0), :c => (29.0, 0.0), :e => (69.0, 0.0),
               :wn => (0.0, 20.0), :cn => (29.0, 20.0), :en => (69.0, 20.0),
               :ws => (0.0, -20.0), :cs => (29.0, -20.0), :es => (69.0, -20.0),
               :k => (29.0, 1.4)]
        faces = [[:w, :c, :cn, :wn], [:c, :e, :en, :cn, :k],
                 [:ws, :cs, :c, :w], [:cs, :es, :e, :c]]
        base = [:w, :c, :e, :wn, :cn, :en, :ws, :cs, :es]
        for cols in (base, vcat(base, [:k]))
            fix = _c5_plan(pts, faces, cols, :c)
            sides = SS._eq137_resolved_sides(fix.struc, fix.slab, fix.col, (1.0, 0.0);
                                             extra_columns = fix.struc.columns)
            for s in sides
                @test [ustrip(u"ft", t) for t in s.tribs] ≈ [10.0, 10.0] rtol = 1e-9
            end
        end
    end

    @testset "T-junction tagged exterior: envelope, not the one-sided answer" begin
        # ACI 318-11 §13.6.3.3 (corpus: aci-318-11, page 254).  The east face
        # runs past :c without listing it.  Production tags such a column
        # :edge or :corner from its single-face edges (boundary direction
        # along Y), which agrees with the wrong one-sided geometry.  The
        # mesh check now runs whatever the tag: 0.70 M0, not 0.26 M0.
        pts = [:w => (0.0, 0.0), :c => (20.0, 0.0), :wn => (0.0, 20.0),
               :cn => (20.0, 20.0), :ws => (0.0, -20.0), :cs => (20.0, -20.0),
               :en => (40.0, 20.0), :es => (40.0, -20.0)]
        west = [[:w, :c, :cn, :wn], [:ws, :cs, :c, :w]]
        tee_faces = vcat(west, [[:cs, :es, :en, :cn]])
        cols = [:w, :c, :cn, :cs, :en, :es]
        qu = max(1.4 * qD, 1.2 * qD + 1.6 * qL)
        M0 = SS.total_static_moment(qu, 20.0u"ft", 19.0u"ft")
        @test kft(0.26 * M0) ≈ 61.009 rtol = 1e-4
        @test kft(0.70 * M0) ≈ 164.255 rtol = 1e-4
        equal_span = SS.governing_interior_unbalanced_moment(
            qD, qL, 20.0u"ft", 19.0u"ft", qD, qL, 20.0u"ft", 19.0u"ft")
        # Cycle 11a: the envelope also reads the hidden east face as the east
        # side (slab coverage).  No column at (40, 0), so that side ends at
        # the slab edge with ℓn admitted down to 0, and Eq. (13-7)
        # (§13.6.9.2, corpus: aci-318-11, page 258) is the west term alone,
        # 0.07 (1.2 qD + 0.5·1.6 qL) ℓ2 ℓn², ℓ2 = 20 ft, ℓn = 19 ft.
        west_only = 0.07 * (1.2 * qD + 0.5 * 1.6 * qL) * 20.0u"ft" * (19.0u"ft")^2
        want_Mub = max(kft(equal_span), kft(0.3 * M0), kft(west_only))
        for (pos, dirs) in ((:edge, nothing), (:corner, [(0.0, 1.0), (0.0, -1.0)]))
            fix = _c5_plan(pts, tee_faces, cols, :c; position = pos)
            col = dirs === nothing ? fix.col : merge(fix.col, (boundary_edge_dirs = dirs,))
            @test SS._eq137_position_exterior(col, (1.0, 0.0))
            tc = TraceCollector()
            M = SS._ddm_support_moment(fix.struc, col, (1.0, 0.0), 0.26 * M0, 0.70 * M0; tc = tc)
            @test kft(M) ≈ kft(0.70 * M0) rtol = 1e-9
            @test has_reason(tc, "ambiguous_neighbourhood_envelope")
            tc = TraceCollector()
            Mub = SS._eq137_transfer_moment(fix.struc, fix.slab, col, (1.0, 0.0),
                                            qD, qL, 20.0u"ft", 19.0u"ft", M0; tc = tc)
            @test kft(Mub) ≈ want_Mub rtol = 1e-9
            @test has_reason(tc, "ambiguous_neighbourhood_envelope")
            # The precomputed index gives the same answer as the direct scan.
            ctx = SS._eq137_context(fix.struc, [col])
            @test !isempty(ctx.partway.near[col.vertex_idx])
            @test SS._ddm_support_moment(fix.struc, col, (1.0, 0.0), 0.26 * M0, 0.70 * M0;
                                         index = ctx.index, vertex_column = ctx.vertex_column,
                                         partway = ctx.partway) == M
        end
        # Same tag on a conforming mesh (no east face): exterior moments,
        # and no trace event because tag and geometry agree.
        lone = _c5_plan(pts, west, cols, :c; position = :edge)
        tc = TraceCollector()
        @test SS._ddm_support_moment(lone.struc, lone.col, (1.0, 0.0),
                                     0.26 * M0, 0.70 * M0; tc = tc) == 0.26 * M0
        @test isempty(tc.events)
    end

    @testset "zero-sided edge column is traced on the flexural path" begin
        # An :edge column nudged off every panel: §13.6.3.3 exterior moment,
        # now with the same `exterior_no_panel` event as the transfer path.
        pts = [:a => (0.0, 0.0), :b => (20.0, 0.0), :cc => (20.0, 20.0),
               :d => (0.0, 20.0), :x => (20.0, -5.0)]
        fix = _c5_plan(pts, [[:a, :b, :cc, :d]], [:a, :b, :cc, :d, :x], :x; position = :edge)
        tc = TraceCollector()
        @test SS._ddm_support_moment(fix.struc, fix.col, (1.0, 0.0),
                                     61.0kip * u"ft", 164.0kip * u"ft"; tc = tc) == 61.0kip * u"ft"
        @test any(e -> e.event_type == :fallback && e.stage == "_ddm_support_moment" &&
                       get(e.data, "reason", "") == "exterior_no_panel", tc.events)
    end

    @testset "wall far support: ℓ_cc from the structural centre" begin
        # ACI 318-11 §13.6.2.5 (corpus: aci-318-11, page 253).  The column
        # under test is inset 0.5 ft east of its vertex; neither frame-line
        # end is a column.  ℓ_cc runs from the structural centre, as on the
        # column-to-column path: 20 − 0.5 = 19.5 ft east, 29 + 0.5 = 29.5 ft
        # west.  ℓn = ℓ_cc − 6 in (no far face).
        fix = _two_bay(west_ft = 29.0, east_ft = 20.0)
        col = merge(fix.col, (structural_offset = (0.5 * 0.3048, 0.0),))
        struc = merge(fix.struc, (columns = Any[col],))
        sides = SS._eq137_resolved_sides(struc, fix.slab, col, (1.0, 0.0);
                                         extra_columns = struc.columns)
        by_side = Dict(s.side => s for s in sides)
        @test ustrip(u"ft", by_side[1].l_cc) ≈ 19.5 rtol = 1e-9
        @test ustrip(u"ft", by_side[-1].l_cc) ≈ 29.5 rtol = 1e-9
        @test ustrip(u"ft", by_side[1].ln) ≈ 19.0 rtol = 1e-9
        @test ustrip(u"ft", by_side[-1].ln) ≈ 29.0 rtol = 1e-9
    end

    @testset "FrameLine DDM classifies columns like the single-panel DDM" begin
        # ACI 318-11 §13.6.3.3 (corpus: aci-318-11, page 254).  The FrameLine
        # used to take its first and last joints as exterior.  Here the
        # first joint (x = 20) has slab on both sides along X and is tagged
        # :edge (no boundary directions), so it is an interior support on
        # this conforming mesh, as `_ddm_support_moment` says.
        pts = Pair{Symbol,Tuple{Float64,Float64}}[]
        for (i, x) in enumerate((0.0, 20.0, 40.0, 60.0)), (j, y) in enumerate((-20.0, 0.0, 20.0))
            push!(pts, Symbol("v$(i)$(j)") => (x, y))
        end
        faces = [[Symbol("v$(i)$(j)"), Symbol("v$(i+1)$(j)"),
                  Symbol("v$(i+1)$(j+1)"), Symbol("v$(i)$(j+1)")] for i in 1:3 for j in 1:2]
        allv = [first(p) for p in pts]
        fix = _c5_plan(pts, faces, allv, :v22; position = :edge)
        byv = Dict(c.vertex_idx => c for c in fix.struc.columns)
        line = [fix.col, byv[fix.col.vertex_idx + 3], byv[fix.col.vertex_idx + 6]]
        ln = 19.0u"ft"
        fl = (direction = (1.0, 0.0), columns = line, tributary_width = 20.0u"ft",
              span_lengths = [ln, ln], joint_positions = [:exterior, :interior, :exterior])
        qu = 1.2 * qD + 1.6 * qL
        tc = TraceCollector()
        # Two-span frame lines (§13.6.1.1) are analysed in isolation here,
        # so the FrameLine DDM gate is told to proceed.
        res = SS.run_moment_analysis(DDM(), fl, fix.struc, qu, qD, qL; tc = tc,
                                     on_inapplicable = :proceed)
        M0 = SS.total_static_moment(qu, 20.0u"ft", ln)
        # Span 1 has two interior supports: 0.65 M0 at the first joint.
        # Span 2 ends at a one-sided column: 0.26 M0 at the last joint.
        @test kft(res.column_moments[1]) ≈ kft(0.65 * M0) rtol = 1e-9
        @test kft(res.column_moments[3]) ≈ kft(0.26 * M0) rtol = 1e-9
        for (k, (Me, Mi)) in ((1, (0.26 * M0, 0.65 * M0)), (3, (0.26 * M0, 0.70 * M0)))
            want = SS._ddm_support_moment(fix.struc, line[k], (1.0, 0.0), Me, Mi)
            @test kft(res.column_moments[k]) ≈ kft(want) rtol = 1e-9
        end
        @test any(e -> e.stage == "_ddm_support_moment" &&
                       get(e.data, "reason", "") == "exterior_tag_two_sided", tc.events)
        @test any(e -> e.stage == "_ddm_support_moment" &&
                       get(e.data, "reason", "") == "one_sided_interior", tc.events)

        # T-junction at the last joint: envelope of the exterior and interior
        # span-end coefficients, the same max the single-panel DDM takes.
        tpts = [:w => (0.0, 0.0), :c => (20.0, 0.0), :wn => (0.0, 20.0),
                :cn => (20.0, 20.0), :ws => (0.0, -20.0), :cs => (20.0, -20.0),
                :en => (40.0, 20.0), :es => (40.0, -20.0)]
        tfaces = [[:w, :c, :cn, :wn], [:ws, :cs, :c, :w], [:cs, :es, :en, :cn]]
        tee = _c5_plan(tpts, tfaces, [:w, :c, :cn, :cs, :en, :es], :c; position = :edge)
        wcol = first(c for c in tee.struc.columns if c.vertex_idx == 1)
        tfl = (direction = (1.0, 0.0), columns = [wcol, tee.col], tributary_width = 20.0u"ft",
               span_lengths = [ln], joint_positions = [:exterior, :exterior])
        tc = TraceCollector()
        tres = SS.run_moment_analysis(DDM(), tfl, tee.struc, qu, qD, qL; tc = tc,
                                      on_inapplicable = :proceed)
        @test kft(tres.column_moments[1]) ≈ kft(0.26 * M0) rtol = 1e-9
        @test kft(tres.column_moments[2]) ≈ kft(0.70 * M0) rtol = 1e-9
        @test kft(tres.column_moments[2]) ≈
              kft(SS._ddm_support_moment(tee.struc, tee.col, (1.0, 0.0), 0.26 * M0, 0.70 * M0)) rtol = 1e-9
        @test has_reason(tc, "ambiguous_neighbourhood_envelope")

        # No skeleton geometry: the FrameLine joints, traced `no_geometry`.
        bare = (cells = (), slabs = ())
        tc = TraceCollector()
        bres = SS.run_moment_analysis(DDM(), fl, bare, qu, qD, qL; tc = tc,
                                      on_inapplicable = :proceed)
        @test kft(bres.column_moments[1]) ≈ kft(0.26 * M0) rtol = 1e-9
        @test has_reason(tc, "no_geometry")
    end
end

@testset "Eq. (13-7) cycle 7: non-finite inputs, FrameLine classes, §13.6.1.4" begin
    qD = 150.0psf
    qL = 50.0psf
    kft(x) = ustrip(kip * u"ft", x)
    has_event(tc, ev, r) = any(e -> e.event_type == ev &&
                                    get(e.data, "reason", "") == r, tc.events)
    qu = max(1.4 * qD, 1.2 * qD + 1.6 * qL)
    M0 = SS.total_static_moment(qu, 20.0u"ft", 28.0u"ft")
    mat = RC_4000_60
    h = 8.0u"inch"
    d = 6.75u"inch"
    fc = mat.concrete.fc′
    fy = mat.rebar.Fy
    mub(fix; tc = nothing) = SS._compute_column_demands_ddm(
        fix.struc, [fix.col], 0.26 * M0, 0.70 * M0, 0.35 * M0,
        qu, qD, qL, 20.0u"ft", 28.0u"ft", (1.0, 0.0), M0; slab = fix.slab, tc = tc)[3][1]
    nan_sdl(; kw...) = _two_bay(; west_ft = 29.0, east_ft = 40.0, qD_east = NaN * psf, kw...)
    function nan_far_c1(; kw...)
        fix = _two_bay(; west_ft = 29.0, east_ft = 40.0, kw...)
        cols = collect(fix.struc.columns)
        cols[3] = merge(cols[3], (c1 = NaN * u"inch", c2 = NaN * u"inch"))
        return (struc = merge(fix.struc, (columns = cols,)), slab = fix.slab, col = fix.col)
    end

    @testset "Eq. (13-7) envelope propagates NaN" begin
        # ACI 318-11 §13.6.9.2 Eq. (13-7) (corpus: aci-318-11, page 258).
        # `abs(Mu) > abs(best)` is false for NaN, so a NaN pattern used to
        # leave the 0 start value and return a finite 0 kip·ft.
        w = 150.0psf * 20.0u"ft"
        wl = 50.0psf * 20.0u"ft"
        @test isnan(SS._eq137_governing_line_loads(w, wl, 28.0u"ft", NaN * w, wl, 19.0u"ft"))
        @test isnan(SS._eq137_governing_line_loads(NaN * w, wl, 28.0u"ft", w, wl, 19.0u"ft"))
        @test isnan(SS._eq137_governing_line_loads(w, wl, 28.0u"ft", w, wl, NaN * u"ft"))
        @test isnan(SS._eq137_governing_line_loads(w, wl, 28.0u"ft", Inf * w, wl, 19.0u"ft"))
        @test isnan(SS.governing_interior_unbalanced_moment(
            qD, qL, 20.0u"ft", 28.0u"ft", NaN * psf, qL, 20.0u"ft", 19.0u"ft"))
        @test isnan(SS.governing_interior_unbalanced_moment(
            qD, qL, 20.0u"ft", NaN * u"ft", qD, qL, 20.0u"ft", 19.0u"ft"))
        # Finite inputs are unchanged (the 130.4 kip·ft reverse-pattern oracle).
        @test kft(SS.governing_interior_unbalanced_moment(
            60.0psf, 100.0psf, 20.0u"ft", 22.0u"ft",
            200.0psf, 100.0psf, 20.0u"ft", 20.0u"ft")) ≈ 130.4 rtol = 1e-3
    end

    @testset "NaN neighbour sdl / far-column c1: Mub is NaN, not 0" begin
        @test kft(mub(_two_bay(west_ft = 29.0, east_ft = 40.0))) ≈ 270.9 rtol = 1e-4
        @test isnan(mub(nan_sdl()))
        tc = TraceCollector()
        @test isnan(mub(nan_far_c1(); tc = tc))
        # ℓn (§13.6.2.5, page 253) is undefined with a NaN far face.
        @test has_event(tc, :failure, "non_finite_clear_span")
        f = nan_far_c1()
        sides = SS._eq137_resolved_sides(f.struc, f.slab, f.col, (1.0, 0.0);
                                         extra_columns = f.struc.columns)
        @test count(s -> isnan(s.ln), sides) == 1
    end

    @testset "NaN Eq. (13-7) is rejected on pipeline, rule-of-thumb and NLP" begin
        # ACI 318-11 §13.5.3 (corpus: aci-318-11, page 250).  The non-finite
        # demand must reach `transfer_section_inadequate`, not be skipped as
        # a negligible moment.
        col = (c1 = 16.0u"inch", c2 = 16.0u"inch", position = :interior)
        for fix in (nan_sdl(), nan_far_c1())
            Mub = mub(fix)
            r = SS._pipeline_transfer_reinforcement(
                [col], (unbalanced_moments = [Mub],), nothing, nothing, h, d, fc, fy)
            @test r.ok == false
            @test r.column == 1
            failures = String[]
            out = Union{Nothing, NamedTuple}[nothing]
            @test SS._rot_transfer_reinforcement!(
                out, failures, [col], (unbalanced_moments = [Mub],), nothing,
                nothing, h, d, fc, fy) == false
            @test failures == ["transfer_reinforcement"]
        end

        # NLP: `evaluate` with the stored building.  The finite fixture has a
        # feasible point; the same point is infeasible with either NaN.
        sdl = 20.0psf
        qLn = 40.0psf
        wc = ustrip(pcf, mat.concrete.ρ)
        nlp(fix) = FlatPlateNLPProblem(
            mat, mat.concrete.fc′, mat.rebar.Fy, mat.rebar.E,
            Ec(mat.concrete.fc′, wc), mat.concrete.ρ, mat.concrete.λ,
            29.0u"ft", 20.0u"ft", sdl, qLn,
            [:interior], [100.0], 3.0,
            0.65, 0.70, 0.35,
            0.75u"inch", bar_diameter(5),
            0.90, 0.75, :L_360,
            (6.0, 30.0), (10.0, 48.0),
            [4, 5, 6, 7, 8], MinVolume(),
            (struc = fix.struc, slab = fix.slab, columns = [fix.col],
             span_axis = (1.0, 0.0), index = SS._eq137_vertex_cell_index(fix.struc)),
        )
        p_ok = nlp(_two_bay(west_ft = 29.0, east_ft = 40.0, qD = sdl, qL = qLn))
        found = nothing
        for h_in in (16.0, 20.0, 24.0, 28.0), c_in in (24.0, 30.0, 36.0, 42.0)
            found === nothing || break
            SS.evaluate(p_ok, [h_in, c_in])[1] && (found = [h_in, c_in])
        end
        @test found !== nothing
        if found !== nothing
            for fix in (nan_sdl(qD = sdl, qL = qLn), nan_far_c1(qD = sdl, qL = qLn))
                p = nlp(fix)
                @test SS.evaluate(p, found)[1] == false
                Mx = SS._nlp_transfer_moment(p, 1, sdl, qLn, 20.0u"ft", 28.0u"ft",
                                             (1.0, 0.0), found[2] * u"inch", M0)
                @test isnan(Mx)
            end
        end
    end

    @testset "FrameLine transfer moment follows the support class" begin
        # Same class rule as the cell path (`_eq137_transfer_moment`):
        # :exterior → §13.6.3.6 0.3 M0 (page 255); :interior → Eq. (13-7)
        # (page 258); :envelope → the larger of the two.
        l2 = 20.0u"ft"
        lnL = 19.0u"ft"
        lnR = 29.0u"ft"
        M0L = SS.total_static_moment(qu, l2, lnL)
        M0R = SS.total_static_moment(qu, l2, lnR)
        sm = [(span_idx = 1, ln = lnL, M0 = M0L, M_neg_left = 0.26 * M0L,
               M_pos = 0.52 * M0L, M_neg_right = 0.70 * M0L),
              (span_idx = 2, ln = lnR, M0 = M0R, M_neg_left = 0.70 * M0R,
               M_pos = 0.52 * M0R, M_neg_right = 0.26 * M0R)]
        cols = [(position = :interior,), (position = :interior,), (position = :interior,)]
        eq137 = SS.governing_interior_unbalanced_moment(qD, qL, l2, lnL, qD, qL, l2, lnR)
        demands(classes; tc = nothing) = SS._compute_column_demands_from_spans(
            nothing, cols, classes, sm, qu, qD, qL, l2; tc = tc)[3]

        m = demands([:exterior, :interior, :exterior])
        @test kft(m[1]) ≈ kft(0.3 * M0L) rtol = 1e-12
        @test kft(m[2]) ≈ kft(eq137) rtol = 1e-12
        @test kft(m[3]) ≈ kft(0.3 * M0R) rtol = 1e-12
        # Middle :exterior with no geometry to say which side the slab is
        # on: the larger adjoining 0.3 M0, traced.
        tc = TraceCollector()
        m = demands([:exterior, :exterior, :exterior]; tc = tc)
        @test kft(m[2]) ≈ kft(0.3 * M0R) rtol = 1e-12
        @test has_event(tc, :fallback, "frameline_exterior_side_unknown")
        m = demands([:exterior, :envelope, :exterior])
        @test kft(m[2]) ≈ max(kft(eq137), kft(0.3 * M0R)) rtol = 1e-12
        # Bool input keeps its old meaning at the ends.
        @test kft(demands([true, false, true])[2]) ≈ kft(eq137) rtol = 1e-12
        # Interior end with no geometry: span beyond unknown → NaN, :failure,
        # never 0.3 M0.
        tc = TraceCollector()
        m = demands([:interior, :interior, :exterior]; tc = tc)
        @test isnan(m[1])
        @test has_event(tc, :failure, "frameline_end_beyond_span_unresolved")
        @test kft(m[3]) ≈ kft(0.3 * M0R) rtol = 1e-12
        r = SS._pipeline_transfer_reinforcement(
            [(c1 = 16.0u"inch", c2 = 16.0u"inch", position = :interior)],
            (unbalanced_moments = [m[1]],), nothing, nothing, h, d, fc, fy)
        @test r.ok == false
    end

    @testset "FrameLine with geometry: interior end and one-sided middle" begin
        # 3×2 bays on x = 0…60, y = −20…20; the frame line starts at x = 20,
        # where the slab continues west.  That end column is an interior
        # support: Eq. (13-7) with ℓn = 19 ft both sides, ℓ2 = 20 ft:
        #   Mu = 0.07·0.5·1.6·50·20·19² = 20.216 kip·ft (dead cancels),
        # not 0.3 M0 = 70.40 kip·ft.
        pts = Pair{Symbol,Tuple{Float64,Float64}}[]
        for (i, x) in enumerate((0.0, 20.0, 40.0, 60.0)), (j, y) in enumerate((-20.0, 0.0, 20.0))
            push!(pts, Symbol("v$(i)$(j)") => (x, y))
        end
        faces = [[Symbol("v$(i)$(j)"), Symbol("v$(i+1)$(j)"),
                  Symbol("v$(i+1)$(j+1)"), Symbol("v$(i)$(j+1)")] for i in 1:3 for j in 1:2]
        fix = _c5_plan(pts, faces, [first(p) for p in pts], :v22)
        byv = Dict(c.vertex_idx => c for c in fix.struc.columns)
        line = [fix.col, byv[fix.col.vertex_idx + 3], byv[fix.col.vertex_idx + 6]]
        ln = 19.0u"ft"
        fl = (direction = (1.0, 0.0), columns = line, tributary_width = 20.0u"ft",
              span_lengths = [ln, ln], joint_positions = [:exterior, :interior, :exterior])
        tc = TraceCollector()
        res = SS.run_moment_analysis(DDM(), fl, fix.struc, qu, qD, qL; tc = tc,
                                     on_inapplicable = :proceed)
        M0f = SS.total_static_moment(qu, 20.0u"ft", ln)
        hand = 0.07 * 0.5 * 1.6 * qL * 20.0u"ft" * ln^2
        @test kft(hand) ≈ 20.216 rtol = 1e-4
        @test kft(res.unbalanced_moments[1]) ≈ kft(hand) rtol = 1e-9
        @test kft(res.unbalanced_moments[2]) ≈ kft(hand) rtol = 1e-9
        @test kft(res.unbalanced_moments[3]) ≈ kft(0.3 * M0f) rtol = 1e-9
        @test kft(0.3 * M0f) ≈ 70.40 rtol = 1e-4

        # Panels only west of x = 20: the middle frame column is one-sided
        # (:exterior), so 0.3 M0 of the frame span on the panel side (19 ft),
        # not the 29 ft span on the empty side and not Eq. (13-7).
        wpts = [:a => (0.0, -20.0), :b => (0.0, 0.0), :c => (0.0, 20.0),
                :d => (20.0, -20.0), :e => (20.0, 0.0), :f => (20.0, 20.0),
                :g => (40.0, 0.0)]
        wfix = _c5_plan(wpts, [[:a, :d, :e, :b], [:b, :e, :f, :c]],
                        [:a, :b, :c, :d, :e, :f, :g], :e)
        wb = Dict(c.vertex_idx => c for c in wfix.struc.columns)
        wline = [wb[2], wfix.col, wb[7]]
        wfl = (direction = (1.0, 0.0), columns = wline, tributary_width = 20.0u"ft",
               span_lengths = [19.0u"ft", 29.0u"ft"],
               joint_positions = [:exterior, :interior, :exterior])
        @test SS._frameline_support_classes(wfix.struc, wfl)[2] == :exterior
        wres = SS.run_moment_analysis(DDM(), wfl, wfix.struc, qu, qD, qL;
                                      on_inapplicable = :proceed)
        @test kft(wres.unbalanced_moments[2]) ≈
              kft(0.3 * SS.total_static_moment(qu, 20.0u"ft", 19.0u"ft")) rtol = 1e-9
    end

    @testset "inadequate transfer section reports the offending direction" begin
        # ACI 318-11 §13.5.3 (corpus: aci-318-11, page 250).  Only the
        # y-direction moment exceeds what the section can develop; the
        # report names Muy and the y-direction effective width c1 + 3h.
        c = 16.0u"inch"
        small = 10.0kip * u"ft"
        huge = 5000.0kip * u"ft"
        gy = SS.governing_transfer_reinforcement(small, huge, c, c, h, d, fc, fy)
        @test isinf(gy.As)
        @test gy.Mu == huge
        @test gy.bb == c + 3h
        gx = SS.governing_transfer_reinforcement(huge, small, c, c, h, d, fc, fy)
        @test isinf(gx.As)
        @test gx.Mu == huge
    end

    @testset "§13.6.1.4 offset check is not relaxed by the on-line floor" begin
        # ACI 318-11 §13.6.1.4 (corpus: aci-318-11, page 252): offset ≤ 10%
        # of the span between successive column centerlines.  A 10 ft bay
        # (3.048 m) with the next column 0.33 m off the line: on the frame
        # line by the 0.35 m floor of `_eq137_on_line`, so Eq. (13-7) uses
        # it as the far support, but 0.33 m > 10% of 3.048 m.
        mtr = 0.3048
        mk(vi) = (vertex_idx = vi, position = :interior, c1 = 12.0u"inch",
                  c2 = 12.0u"inch", θ = 0.0, structural_offset = (0.0, 0.0))
        function plan(off_m)
            vc = [0.0 0.0; 10.0 * mtr off_m; 20.0 * mtr 0.0]
            return (skeleton = (geometry = (vertex_coords = vc,), face_vertex_indices = Vector{Int}[]),
                    columns = Any[mk(1), mk(2), mk(3)])
        end
        bad = plan(0.33)
        @test SS._eq137_on_line(10.0 * mtr, 0.33)
        v = SS._column_offset_violations(bad, bad.columns, (1.0, 0.0))
        @test !isempty(v)
        @test all(s -> occursin("13.6.1.4", s), v)
        # 0.25 ft over 10 ft (2.5%): within the limit.
        ok = plan(0.25 * mtr)
        @test isempty(SS._column_offset_violations(ok, ok.columns, (1.0, 0.0)))
        # 3.5 ft over 40 ft (8.75%, a 5° skew): within the limit.
        sk = (skeleton = (geometry = (vertex_coords = [0.0 0.0; 40.0 * mtr 3.5 * mtr],),
                          face_vertex_indices = Vector{Int}[]),
              columns = Any[mk(1), mk(2)])
        @test isempty(SS._column_offset_violations(sk, sk.columns, (1.0, 0.0)))
    end
end

# =============================================================================
# Fix cycle 7, part B: duplicated / nudged column vertices, and the
# thread-safe warn-once set.
# =============================================================================

"""
`_two_bay` with the column vertex duplicated: the faces listed in `swap`
(default: east-north and east-south) reference a second vertex index at
the column XY moved by `dx_m` metres along X.  `swap = :all` re-points
every face, leaving the column's own vertex in no face (a column-less
duplicate carries the whole plan).
"""
function _two_bay_dup(; dx_m::Float64 = 0.0, swap = (2, 4), kw...)
    f = _two_bay(; kw...)
    vc = f.struc.skeleton.geometry.vertex_coords
    vcol = f.col.vertex_idx
    vc2 = vcat(vc, vc[vcol:vcol, :])
    vc2[end, 1] += dx_m
    vdup = size(vc2, 1)
    fvi = f.struc.skeleton.face_vertex_indices
    ks = swap === :all ? eachindex(fvi) : swap
    faces = [k in ks ? [v == vcol ? vdup : v for v in fc] : copy(fc)
             for (k, fc) in enumerate(fvi)]
    struc = merge(f.struc, (skeleton = (geometry = (vertex_coords = vc2,),
                                        face_vertex_indices = faces),))
    return (struc = struc, slab = f.slab, col = f.col, vdup = vdup)
end

@testset "Eq. (13-7) cycle 7b: duplicated column vertices" begin
    qD = 150.0psf
    qL = 50.0psf
    kft(x) = ustrip(kip * u"ft", x)
    has_event(tc, ev, r) = any(e -> e.event_type == ev &&
                                    get(e.data, "reason", "") == r, tc.events)
    l2 = 20.0u"ft"
    ln = 19.0u"ft"
    qu = max(1.4 * qD, 1.2 * qD + 1.6 * qL)
    M0 = SS.total_static_moment(qu, l2, ln)
    function demands(fix; tc = nothing)
        M, _, Mub = SS._compute_column_demands_ddm(
            fix.struc, [fix.col], 0.26 * M0, 0.70 * M0, 0.35 * M0,
            qu, qD, qL, l2, ln, (1.0, 0.0), M0; slab = fix.slab, tc = tc)
        return kft(M[1]), kft(Mub[1])
    end
    # Merged mesh oracle: interior flexure 0.70 M0 and Eq. (13-7) for the
    # 20 ft / 30 ft bays (ACI 318-11 §13.6.3.3 page 254, §13.6.9.2 page 258).
    M_ref, Mub_ref = demands(_two_bay(west_ft = 20.0, east_ft = 30.0))
    @test M_ref ≈ 164.3 rtol = 1e-3
    @test Mub_ref ≈ 168.1 rtol = 1e-3

    @testset "coincident duplicate: east faces adjoin the column" begin
        # Critic repro: the east faces use an unmerged copy of the column
        # vertex.  Before the fix the column was exterior (61.0 / 70.4).
        fix = _two_bay_dup(west_ft = 20.0, east_ft = 30.0)
        tc = TraceCollector()
        M, Mub = demands(fix; tc = tc)
        @test M ≈ M_ref rtol = 1e-12
        @test Mub ≈ Mub_ref rtol = 1e-12
        @test has_event(tc, :decision, "duplicate_vertex_merged")
        @test !has_event(tc, :fallback, "one_sided_interior")
        idx = SS._eq137_vertex_cell_index(fix.struc)
        @test sort(idx[fix.col.vertex_idx]) == collect(1:4)
    end

    @testset "duplicate nudged by 3 mm is the same support" begin
        fix = _two_bay_dup(west_ft = 20.0, east_ft = 30.0, dx_m = 0.003)
        tc = TraceCollector()
        M, Mub = demands(fix; tc = tc)
        @test M ≈ M_ref rtol = 1e-9
        @test Mub ≈ Mub_ref rtol = 1e-9
        @test has_event(tc, :decision, "duplicate_vertex_merged")
    end

    @testset "column vertex in no face; a column-less duplicate carries the plan" begin
        fix = _two_bay_dup(west_ft = 20.0, east_ft = 30.0, swap = :all)
        tc = TraceCollector()
        M, Mub = demands(fix; tc = tc)
        @test M ≈ M_ref rtol = 1e-12
        @test Mub ≈ Mub_ref rtol = 1e-12
        @test has_event(tc, :decision, "duplicate_vertex_merged")
        @test !has_event(tc, :fallback, "zero_sides")
    end

    @testset "unmerged near-duplicate (0.25 m): ambiguous envelope" begin
        # Farther than `_EQ137_COINCIDE_M`, inside the 0.35 m neighbourhood,
        # and not explained by the column's own faces.  Flexure takes
        # max(M_neg,ext, M_neg,int); transfer takes the larger of the
        # equal-span pattern, 0.3 M0 (§13.6.3.6, page 255) and Eq. (13-7)
        # with the near faces counted as adjoining, so it is never below the
        # merged answer for this plan.
        fix = _two_bay_dup(west_ft = 20.0, east_ft = 30.0, dx_m = 0.25)
        tc = TraceCollector()
        M, Mub = demands(fix; tc = tc)
        @test M ≈ max(0.26, 0.70) * kft(M0) rtol = 1e-12
        @test Mub >= Mub_ref * (1 - 1e-9)
        @test Mub >= 0.3 * kft(M0)
        @test has_event(tc, :decision, "ambiguous_neighbourhood_envelope")
        @test !has_event(tc, :decision, "duplicate_vertex_merged")
        vmap = SS._eq137_vertex_column_map(fix.struc, ())
        idx = SS._eq137_vertex_cell_index(fix.struc)
        @test !SS._eq137_mesh_conforms(fix.struc, fix.col, idx, vmap)
        pw = SS._eq137_partway_index(fix.struc, keys(vmap))
        @test sort(pw.near[fix.col.vertex_idx]) == [2, 4]
    end

    @testset "a short face edge from the column is not a duplicate" begin
        # Vertex 3 is 0.25 m from the column and joined to it by an edge of
        # the sliver face [2, 3, 6].  Face [3, 4, 5, 6] does not have the
        # column vertex as a corner but reaches it through that edge: mesh
        # topology, not an unmerged duplicate.
        mtr = 0.3048
        vc = [0.0 0.0; 20.0 * mtr 0.0; 20.0 * mtr + 0.25 0.0; 40.0 * mtr 0.0;
              40.0 * mtr 20.0 * mtr; 20.0 * mtr 20.0 * mtr; 0.0 20.0 * mtr]
        faces = [[1, 2, 6, 7], [2, 3, 6], [3, 4, 5, 6]]
        col = (vertex_idx = 2, position = :interior, c1 = 12.0u"inch", c2 = 12.0u"inch",
               θ = 0.0, structural_offset = (0.0, 0.0))
        cells = Any[(face_idx = k, sdl = qD, live_load = qL, self_weight = 0.0psf) for k in 1:3]
        struc = (cells = cells,
                 slabs = Any[(cell_indices = [k],) for k in 1:3],
                 columns = Any[col],
                 skeleton = (geometry = (vertex_coords = vc,), face_vertex_indices = faces))
        pw = SS._eq137_partway_index(struc, [2])
        @test isempty(pw.near[2])
        @test !(2 in pw.merged)
        @test SS._eq137_mesh_conforms(struc, col, SS._eq137_vertex_cell_index(struc),
                                      SS._eq137_vertex_column_map(struc, ()))
    end

    @testset "duplicates on another storey are not merged" begin
        # Same XY, 3 m higher: a stacked storey, not a duplicate.
        fix = _two_bay_dup(west_ft = 20.0, east_ft = 30.0)
        vc = fix.struc.skeleton.geometry.vertex_coords
        vc3 = hcat(vc, zeros(size(vc, 1)))
        vc3[fix.vdup, 3] = 3.0
        st = merge(fix.struc, (skeleton = merge(fix.struc.skeleton,
                                                (geometry = (vertex_coords = vc3,),)),))
        v = fix.col.vertex_idx
        pw = SS._eq137_partway_index(st, [v])
        @test sort(pw.adjoin[v]) == [1, 3]
        @test !(v in pw.merged)
        pw2 = SS._eq137_partway_index(fix.struc, [v])
        @test sort(pw2.adjoin[v]) == collect(1:4)
        @test v in pw2.merged
    end

    @testset "warn-once set is safe under threads" begin
        key = Symbol("c7b_thread_probe_", time_ns())
        Threads.@threads for _ in 1:200
            Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
                SS._eq137_warn_once(key, "thread probe")
            end
        end
        @test key in SS._EQ137_WARNED
        @test SS._EQ137_WARNED_LOCK isa ReentrantLock
    end
end

# =============================================================================
# Fix cycle 8, part A: weld ownership, far-support aliases, near-duplicate
# topology, non-finite vertices.
# =============================================================================

"""
Two 20 ft × 20 ft slab panels north and south of an edge column at
(20 ft, 0) (slab A, cells 1–2), and a second slab B (cells 3–4) that starts
`gap_m` east of it across an expansion joint, with a corner vertex there
and no column.  `merged = true` builds slab B on the column's own vertices
instead (two slab objects meeting at an interior column, as the default
one-slab-per-cell building does).  `one_slab = true` lists all four cells
in one slab object.  `joint_col = true` puts a column of slab B on its
corner vertex (a double column at the joint).
"""
function _joint_slabs(; gap_m::Float64 = 0.10, pos::Symbol = :interior,
                      merged::Bool = false, one_slab::Bool = false,
                      joint_col::Bool = false, qD = 150.0psf, qL = 50.0psf)
    m = 0.3048
    pts = NTuple{2,Float64}[]
    V(x, y) = (push!(pts, (x, y)); length(pts))
    L = 20.0 * m
    v_fw = V(0.0, 0.0); v_col = V(L, 0.0)
    v_wn = V(0.0, L); v_cn = V(L, L); v_ws = V(0.0, -L); v_cs = V(L, -L)
    if merged
        e0, en, es = v_col, v_cn, v_cs
        x0 = L
    else
        x0 = L + gap_m
        e0 = V(x0, 0.0); en = V(x0, L); es = V(x0, -L)
    end
    f0 = V(x0 + L, 0.0); fn = V(x0 + L, L); fs = V(x0 + L, -L)
    faces = Vector{Int}[[v_fw, v_col, v_cn, v_wn], [v_ws, v_cs, v_col, v_fw],
                        [e0, f0, fn, en], [es, fs, f0, e0]]
    cells = Any[(face_idx = k, sdl = qD, live_load = qL, self_weight = 0.0psf) for k in 1:4]
    vc = zeros(length(pts), 2)
    for (i, p) in enumerate(pts)
        vc[i, 1] = p[1]
        vc[i, 2] = p[2]
    end
    mk(v, p) = (vertex_idx = v, position = p, c1 = 12.0u"inch", c2 = 12.0u"inch",
                θ = 0.0, structural_offset = (0.0, 0.0))
    col = mk(v_col, pos)
    cols = Any[col, mk(v_fw, :edge), mk(f0, :edge)]
    joint_col && push!(cols, mk(e0, :edge))
    sp = (primary = 20.0u"ft", secondary = 20.0u"ft", axis = (1.0, 0.0))
    slabA = (cell_indices = one_slab ? [1, 2, 3, 4] : [1, 2], spans = sp)
    slabs = one_slab ? Any[slabA] : Any[slabA, (cell_indices = [3, 4], spans = sp)]
    struc = (cells = cells, slabs = slabs, columns = cols,
             skeleton = (geometry = (vertex_coords = vc,), face_vertex_indices = faces))
    return (struc = struc, slab = slabA, col = col, e0 = e0)
end

"""`_two_bay` with far-support vertex `v` re-pointed to a coincident copy in faces `ks`."""
function _two_bay_far_dup(v::Int, ks; kw...)
    f = _two_bay(; kw...)
    vc = f.struc.skeleton.geometry.vertex_coords
    vc2 = vcat(vc, vc[v:v, :])
    vdup = size(vc2, 1)
    faces = [k in ks ? [u == v ? vdup : u for u in fc] : copy(fc)
             for (k, fc) in enumerate(f.struc.skeleton.face_vertex_indices)]
    struc = merge(f.struc, (skeleton = (geometry = (vertex_coords = vc2,),
                                        face_vertex_indices = faces),))
    return (struc = struc, slab = f.slab, col = f.col, vdup = vdup)
end

@testset "Eq. (13-7) cycle 8a: weld ownership, far aliases, near topology" begin
    qD = 150.0psf
    qL = 50.0psf
    kft(x) = ustrip(kip * u"ft", x)
    has_event(tc, ev, r) = any(e -> e.event_type == ev &&
                                    get(e.data, "reason", "") == r, tc.events)
    l2 = 20.0u"ft"
    ln = 19.0u"ft"
    qu = max(1.4 * qD, 1.2 * qD + 1.6 * qL)
    M0 = SS.total_static_moment(qu, l2, ln)
    function demands(fix; tc = nothing)
        M, _, Mub = SS._compute_column_demands_ddm(
            fix.struc, [fix.col], 0.26 * M0, 0.70 * M0, 0.35 * M0,
            qu, qD, qL, l2, ln, (1.0, 0.0), M0; slab = fix.slab, tc = tc)
        return kft(M[1]), kft(Mub[1])
    end
    quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())

    @testset "slab across a 0.05–0.25 m gap: ambiguous envelope, no joint inferred" begin
        # Cycle 8a asserted 0.3 M0 = 70.4 kip·ft and 0.26 M0 here, treating
        # slab B as a separate slab across an expansion joint because its
        # faces share no vertex with the column's.  Nothing in the model is
        # positive evidence of a joint (the skeleton has no joint flag), and
        # the same picture arises from an un-deduplicated mesh of one
        # continuous slab.  So slab B, inside the 0.35 m neighbourhood and
        # not adjoining the column, makes the column ambiguous for either
        # tag: flexure max(0.26, 0.70) M0 = 0.70 M0 (§13.6.3.3, page 254);
        # transfer the larger of 0.3 M0 (§13.6.3.6, page 255) and Eq. (13-7)
        # (§13.6.9.2, page 258) with slab B counted as adjoining.
        @test 0.3 * kft(M0) ≈ 70.40 atol = 0.01
        for gap in (0.05, 0.10, 0.14, 0.25), pos in (:interior, :edge)
            fix = _joint_slabs(gap_m = gap, pos = pos)
            tc = TraceCollector()
            M, Mub = quiet(() -> demands(fix; tc = tc))
            @test M ≈ 0.70 * kft(M0) rtol = 1e-9
            @test Mub >= 0.3 * kft(M0) * (1 - 1e-9)
            @test has_event(tc, :decision, "ambiguous_neighbourhood_envelope")
            @test !has_event(tc, :decision, "duplicate_vertex_merged")
            @test sort(SS._eq137_vertex_cell_index(fix.struc)[fix.col.vertex_idx]) == [1, 2]
            pw = SS._eq137_partway_index(fix.struc, [fix.col.vertex_idx])
            @test sort(pw.near[fix.col.vertex_idx]) == [3, 4]
        end
    end

    @testset "a double column at the joint is ambiguous too" begin
        fix = _joint_slabs(gap_m = 0.10, joint_col = true)
        tc = TraceCollector()
        M, Mub = quiet(() -> demands(fix; tc = tc))
        @test M ≈ 0.70 * kft(M0) rtol = 1e-9
        @test Mub >= 0.3 * kft(M0) * (1 - 1e-9)
        @test has_event(tc, :decision, "ambiguous_neighbourhood_envelope")
    end

    @testset "two slab objects meeting at an interior column stay interior" begin
        # Slab B built on the column's own vertices: continuity is the shared
        # mesh, not the slab object, so this is an interior support
        # (§13.6.3.3 interior negative 0.70 M0; Eq. (13-7), page 258) and
        # identical to listing all four cells in one slab object.
        tc = TraceCollector()
        M2, Mub2 = quiet(() -> demands(_joint_slabs(merged = true); tc = tc))
        M1, Mub1 = quiet(() -> demands(_joint_slabs(merged = true, one_slab = true)))
        @test M2 ≈ 0.70 * kft(M0) rtol = 1e-9
        @test Mub2 ≈ Mub1 rtol = 1e-9
        @test Mub2 < 0.3 * kft(M0)
        @test !has_event(tc, :decision, "ambiguous_neighbourhood_envelope")
        @test !has_event(tc, :fallback, "one_sided_interior")
    end

    @testset "far support with a duplicated vertex is still the far column" begin
        # Reviewer repro: the far support's vertex is duplicated in the faces
        # of its span.  ℓn must stay face to face (§13.6.2.5, page 253):
        # 29.0 ft (east, loaded span) and 19.0 ft (west, D-only span), and
        # Mub the merged-mesh 168.1 kip·ft, with no boundary fallback.  A
        # longer ℓn on the D-only span would lower Eq. (13-7).
        ref = _two_bay(west_ft = 20.0, east_ft = 30.0)
        _, Mub_ref = demands(ref)
        @test Mub_ref ≈ 168.1 rtol = 1e-3
        v_fw = ref.struc.columns[2].vertex_idx
        v_fe = ref.struc.columns[3].vertex_idx
        for (v, ks) in ((v_fe, (2, 4)), (v_fw, (1, 3)), (v_fe, (2,)))
            fix = _two_bay_far_dup(v, ks; west_ft = 20.0, east_ft = 30.0)
            tc = TraceCollector()
            _, Mub = quiet(() -> demands(fix; tc = tc))
            @test Mub ≈ Mub_ref rtol = 1e-12
            @test !has_event(tc, :fallback, "far_support_not_column")
            sides = SS._eq137_resolved_sides(fix.struc, fix.slab, fix.col, (1.0, 0.0);
                                             extra_columns = fix.struc.columns)
            lns = Dict(s.side => ustrip(u"ft", s.ln) for s in sides)
            @test lns[1] ≈ 29.0 rtol = 1e-12
            @test lns[-1] ≈ 19.0 rtol = 1e-12
        end
    end

    @testset "opening corner near an interior column is not a near-duplicate" begin
        # Interior column at the origin, closed face fan.  A 0.2 m × 0.8 m
        # opening corner sits 0.28 m away diagonally, on face B, which does
        # not have the column as a corner and is not joined to it by an
        # edge.  The column's own faces close around it, so the corner is
        # real geometry, not an unmerged duplicate.
        P = [(-6.0, -6.0), (0.0, -6.0), (0.0, 0.0), (-6.0, 0.0),   # 1–4
             (6.0, -6.0), (6.0, 0.0), (0.0, 6.0), (-6.0, 6.0),     # 5–8
             (0.0, 0.2), (6.0, 0.2), (1.0, 0.2), (0.2, 0.2),       # 9–12
             (0.2, 1.0), (0.2, 6.0), (6.0, 6.0), (1.0, 1.0)]       # 13–16
        vc = [p[k] for p in P, k in 1:2]
        faces = [[1, 2, 3, 4], [2, 5, 6, 3], [4, 3, 9, 7, 8],
                 [3, 6, 10, 11, 12, 9], [9, 12, 13, 14, 7],
                 [11, 10, 15, 14, 13, 16]]
        cells = Any[(face_idx = k, sdl = qD, live_load = qL, self_weight = 0.0psf)
                    for k in eachindex(faces)]
        col = (vertex_idx = 3, position = :interior, c1 = 12.0u"inch",
               c2 = 12.0u"inch", θ = 0.0, structural_offset = (0.0, 0.0))
        struc = (cells = cells, slabs = Any[(cell_indices = collect(eachindex(faces)),)],
                 columns = Any[col],
                 skeleton = (geometry = (vertex_coords = vc,), face_vertex_indices = faces))
        pw = SS._eq137_partway_index(struc, [3])
        @test isempty(pw.near[3])
        @test isempty(pw.by_cell)
        @test SS._eq137_mesh_conforms(struc, col, SS._eq137_vertex_cell_index(struc),
                                      SS._eq137_vertex_column_map(struc, ()))
    end

    @testset "0.25 m near-duplicate on the same slab still triggers" begin
        fix = _two_bay_dup(west_ft = 20.0, east_ft = 30.0, dx_m = 0.25)
        pw = SS._eq137_partway_index(fix.struc, [fix.col.vertex_idx])
        @test sort(pw.near[fix.col.vertex_idx]) == [2, 4]
    end

    @testset "non-finite vertex used by Eq. (13-7) gives NaN, traced" begin
        # Advisory: a NaN far-column coordinate used to drop that vertex and
        # return a finite boundary fallback.  Now the transfer moment is NaN
        # (`transfer_section_inadequate` rejects it) and flexure takes the
        # larger of the §13.6.3.3 moments, each with a `:failure` event.
        for (k, ax) in ((3, 1), (2, 2))   # far east column X; column itself Y
            fix = _two_bay(west_ft = 20.0, east_ft = 30.0)
            vc = copy(fix.struc.skeleton.geometry.vertex_coords)
            vc[k, ax] = NaN
            st = merge(fix.struc, (skeleton = merge(fix.struc.skeleton,
                                                    (geometry = (vertex_coords = vc,),)),))
            tc = TraceCollector()
            M, Mub = quiet(() -> demands((struc = st, slab = fix.slab, col = fix.col); tc = tc))
            @test isnan(Mub)
            @test M ≈ 0.70 * kft(M0) rtol = 1e-12
            @test has_event(tc, :failure, "non_finite_vertex")
        end
    end
end

# =============================================================================
# Fix cycle 9, part A: continuity from coordinates, not vertex indices.
# =============================================================================

"""
`_two_bay` whose east faces (2 and 4) carry their own copies of every vertex
on the column line (column, north and south corners), moved `eps_m` in X:
an un-deduplicated mesh of one continuous slab.  The column keeps tag `pos`.
"""
function _two_bay_soup(eps_m::Float64; pos::Symbol = :interior, kw...)
    f = _two_bay(; position = pos, kw...)
    vc = f.struc.skeleton.geometry.vertex_coords
    fvi = f.struc.skeleton.face_vertex_indices
    vcol = f.col.vertex_idx
    line = sort(unique(v for k in (2, 4) for v in fvi[k] if abs(vc[v, 1] - vc[vcol, 1]) < 1e-9))
    rows = copy(vc)
    remap = Dict{Int,Int}()
    for v in line
        r = vc[v:v, :]
        r[1, 1] += eps_m
        rows = vcat(rows, r)
        remap[v] = size(rows, 1)
    end
    faces = [k in (2, 4) ? [get(remap, v, v) for v in fc] : copy(fc) for (k, fc) in enumerate(fvi)]
    col = merge(f.col, (position = pos,))
    cols = Any[c.vertex_idx == vcol ? col : c for c in f.struc.columns]
    struc = merge(f.struc, (columns = cols,
                            skeleton = (geometry = (vertex_coords = rows,),
                                        face_vertex_indices = faces)))
    return (struc = struc, slab = f.slab, col = col)
end

"""`_two_bay` with vertex `v` copied (copy X moved `dx`) into faces `ks`; optional NaN X."""
function _two_bay_redup(v::Int, ks; nan_copy::Bool = false, nan_orig::Bool = false, kw...)
    f = _two_bay(; kw...)
    vc = f.struc.skeleton.geometry.vertex_coords
    vc2 = vcat(vc, vc[v:v, :])
    vd = size(vc2, 1)
    nan_copy && (vc2[vd, 1] = NaN)
    nan_orig && (vc2[v, 1] = NaN)
    faces = [k in ks ? [u == v ? vd : u for u in fc] : copy(fc)
             for (k, fc) in enumerate(f.struc.skeleton.face_vertex_indices)]
    struc = merge(f.struc, (skeleton = (geometry = (vertex_coords = vc2,),
                                        face_vertex_indices = faces),))
    return (struc = struc, slab = f.slab, col = f.col)
end

@testset "Eq. (13-7) cycle 9a: geometric neighbourhood, fail-closed" begin
    qD = 150.0psf
    qL = 50.0psf
    kft(x) = ustrip(kip * u"ft", x)
    has_event(tc, ev, r) = any(e -> e.event_type == ev &&
                                    get(e.data, "reason", "") == r, tc.events)
    quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
    l2 = 20.0u"ft"
    ln = 19.0u"ft"
    qu = max(1.4 * qD, 1.2 * qD + 1.6 * qL)
    M0 = SS.total_static_moment(qu, l2, ln)
    function demands(fix; tc = nothing)
        M, _, Mub = SS._compute_column_demands_ddm(
            fix.struc, [fix.col], 0.26 * M0, 0.70 * M0, 0.35 * M0,
            qu, qD, qL, l2, ln, (1.0, 0.0), M0; slab = fix.slab, tc = tc)
        return kft(M[1]), kft(Mub[1])
    end
    # Merged-mesh oracle (§13.6.3.3 page 254 interior negative 0.70 M0;
    # §13.6.9.2 Eq. (13-7) page 258 for the 20 ft / 30 ft bays).
    M_ref, Mub_ref = demands(_two_bay(west_ft = 20.0, east_ft = 30.0))
    @test M_ref ≈ 164.3 rtol = 1e-3
    @test Mub_ref ≈ 168.1 rtol = 1e-3

    @testset "duplicated column line reads like the merged mesh (C1)" begin
        # Critic repro: east faces on their own copies of the column-line
        # vertices.  Before, the column was exterior (61.0 / 70.4 kip·ft).
        # Within `_EQ137_COINCIDE_M` (5 mm) the faces adjoin the column and
        # the answer is the merged one exactly; at 10 mm the east faces are
        # nearby but not adjoining, so the column is ambiguous and the
        # envelope is never below the merged answer.  Both tags.
        for eps in (0.0, 1e-6, 1e-3, 0.01), pos in (:interior, :edge)
            fix = _two_bay_soup(eps; pos = pos, west_ft = 20.0, east_ft = 30.0)
            tc = TraceCollector()
            M, Mub = quiet(() -> demands(fix; tc = tc))
            if eps <= 1e-3
                @test M ≈ M_ref rtol = 1e-9
                @test Mub ≈ Mub_ref rtol = 1e-6
                @test has_event(tc, :decision, "duplicate_vertex_merged")
                @test !has_event(tc, :decision, "ambiguous_neighbourhood_envelope")
            else
                @test M >= M_ref * (1 - 1e-9)
                @test Mub >= Mub_ref * (1 - 1e-9)
                @test has_event(tc, :decision, "ambiguous_neighbourhood_envelope")
            end
        end
        # 29 ft / 40 ft bays, exact duplicate: the 270.9 kip·ft oracle.
        ref = _two_bay(west_ft = 29.0, east_ft = 40.0)
        _, Mub29 = demands(ref)
        _, Mub29s = quiet(() -> demands(_two_bay_soup(0.0; west_ft = 29.0, east_ft = 40.0)))
        @test Mub29s ≈ Mub29 rtol = 1e-12
    end

    @testset "non-finite vertex never drops out of the lookup (C3, C4)" begin
        # C4: the east faces' copy of the column vertex has X = NaN.  C3: a
        # far column duplicated in all its faces, original X = NaN.  Either
        # used to read as finite geometry (exterior 70.4, or far-support
        # fallback 163.2 < 168.1).  Now: NaN transfer, flexural envelope.
        vcol = _two_bay(west_ft = 20.0, east_ft = 30.0).col.vertex_idx
        for fix in (_two_bay_redup(vcol, (2, 4); nan_copy = true, west_ft = 20.0, east_ft = 30.0),
                    _two_bay_redup(3, (2, 4); nan_orig = true, west_ft = 20.0, east_ft = 30.0),
                    _two_bay_redup(1, (1, 3); nan_orig = true, west_ft = 20.0, east_ft = 30.0))
            tc = TraceCollector()
            M, Mub = quiet(() -> demands(fix; tc = tc))
            @test isnan(Mub)
            @test M ≈ 0.70 * kft(M0) rtol = 1e-12
            @test has_event(tc, :failure, "non_finite_vertex")
            pw = SS._eq137_partway_index(fix.struc,
                                         [c.vertex_idx for c in fix.struc.columns])
            @test fix.col.vertex_idx in pw.nonfinite
        end
    end
end


# =============================================================================
# Fix cycle 8, part B: §13.6.1.4 successive-column search, FrameLine end
# transfer γ / drop, negative service loads, NLP staleness, and the
# geometry/tag flexural envelope at cross-slab columns.
# =============================================================================

"""
`n` columns along X at `span_ft` spacing (structural offset 0); column `k`
moved `off_frac × span_ft` in Y.  Duck-typed for `_column_offset_violations`.
"""
function _offset_line(span_ft::Float64, n::Int, k::Int, off_frac::Float64)
    m = 0.3048
    vc = zeros(n, 2)
    for i in 1:n
        vc[i, 1] = (i - 1) * span_ft * m
    end
    vc[k, 2] = off_frac * span_ft * m
    cols = Any[(vertex_idx = i, position = :interior, c1 = 12.0u"inch", c2 = 12.0u"inch",
                θ = 0.0, structural_offset = (0.0, 0.0)) for i in 1:n]
    return (skeleton = (geometry = (vertex_coords = vc,), face_vertex_indices = Vector{Int}[]),
            columns = cols)
end

"""
`nx × ny` column grid at `sx_ft` × `sy_ft`, rotated by `θ`; column `k` moved
by (`dx`, `dy`) × the spacing in that direction (before rotation).
"""
function _offset_grid(; nx::Int = 3, ny::Int = 3, sx_ft::Float64 = 30.0,
                      sy_ft::Float64 = 30.0, k::Int = 0, dx::Float64 = 0.0,
                      dy::Float64 = 0.0, θ::Float64 = 0.0)
    m = 0.3048
    vc = zeros(nx * ny, 2)
    cols = Any[]
    v = 0
    for i in 0:nx-1, j in 0:ny-1
        v += 1
        x = i * sx_ft + (v == k ? dx * sx_ft : 0.0)
        y = j * sy_ft + (v == k ? dy * sy_ft : 0.0)
        vc[v, 1] = (x * cos(θ) - y * sin(θ)) * m
        vc[v, 2] = (x * sin(θ) + y * cos(θ)) * m
        push!(cols, (vertex_idx = v, position = :interior, c1 = 12.0u"inch",
                     c2 = 12.0u"inch", θ = 0.0, structural_offset = (0.0, 0.0)))
    end
    return (skeleton = (geometry = (vertex_coords = vc,), face_vertex_indices = Vector{Int}[]),
            columns = cols)
end

"""
"Polygon soup": `n × n` square faces of `s_ft`, each with its own four
vertices (no shared vertex indices).  One column per grid point, on the
vertex of the first face that has that point; interior grid points are
tagged `:interior`, the rest `:edge` / `:corner`.  All cells in one slab.
"""
function _soup_grid(; n::Int = 3, s_ft::Float64 = 20.0, qD = 150.0psf, qL = 50.0psf)
    m = 0.3048
    pts = NTuple{2,Float64}[]
    faces = Vector{Int}[]
    owner = Dict{NTuple{2,Int},Int}()
    for i in 0:n-1, j in 0:n-1
        f = Int[]
        for (a, b) in ((i, j), (i + 1, j), (i + 1, j + 1), (i, j + 1))
            push!(pts, (a * s_ft * m, b * s_ft * m))
            push!(f, length(pts))
            get!(owner, (a, b), length(pts))
        end
        push!(faces, f)
    end
    vc = [p[k] for p in pts, k in 1:2]
    cells = Any[(face_idx = k, sdl = qD, live_load = qL, self_weight = 0.0psf)
                for k in eachindex(faces)]
    pos(a, b) = (a in (0, n) && b in (0, n)) ? :corner :
                (a in (0, n) || b in (0, n)) ? :edge : :interior
    cols = Any[(vertex_idx = owner[(a, b)], position = pos(a, b), c1 = 12.0u"inch",
                c2 = 12.0u"inch", θ = 0.0, structural_offset = (0.0, 0.0))
               for a in 0:n, b in 0:n]
    sp = (primary = s_ft * u"ft", secondary = s_ft * u"ft", axis = (1.0, 0.0))
    slab = (cell_indices = collect(eachindex(faces)), spans = sp)
    struc = (cells = cells, slabs = Any[slab], columns = cols,
             skeleton = (geometry = (vertex_coords = vc,), face_vertex_indices = faces))
    centre = first(c for c in cols if c.vertex_idx == owner[(1, 1)])
    return (struc = struc, slab = slab, col = centre)
end

@testset "Eq. (13-7) cycle 8b: §13.6.1.4 search, FrameLine γ, negative loads, F8" begin
    qD = 150.0psf
    qL = 50.0psf
    kft(x) = ustrip(kip * u"ft", x)
    has_event(tc, ev, r) = any(e -> e.event_type == ev &&
                                    get(e.data, "reason", "") == r, tc.events)
    quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
    l2 = 20.0u"ft"
    ln = 19.0u"ft"
    qu = max(1.4 * qD, 1.2 * qD + 1.6 * qL)
    M0 = SS.total_static_moment(qu, l2, ln)
    nviol(p, ax = (1.0, 0.0)) = length(SS._column_offset_violations(p, p.columns, ax))

    @testset "§13.6.1.4 flags offsets above 10% of the span" begin
        # ACI 318-11 §13.6.1.4 (corpus: aci-318-11, page 252): "Offset of
        # columns by a maximum of 10 percent of the span ... shall be
        # permitted."  The successive column used to be searched only within
        # the 10% on-line tolerance, so no offset above 10% was ever seen
        # (reviewer / critic repros: 30 ft at 10.4/13/20%, 20 ft at 12/15/30%).
        for (span, frac) in ((30.0, 0.104), (30.0, 0.13), (30.0, 0.20),
                             (20.0, 0.12), (20.0, 0.15), (20.0, 0.30), (20.0, 0.101))
            p3 = _offset_line(span, 3, 2, frac)
            p4 = _offset_line(span, 4, 2, frac)
            @test nviol(p3) >= 1
            @test nviol(p4) >= 1
            v = SS._column_offset_violations(p4, p4.columns, (1.0, 0.0))
            @test all(s -> occursin("§13.6.1.4", s) && occursin("page 252", s), v)
        end
        # Within the limit: 5% and 9.9% of a 20 ft span; also a 30 ft span.
        for (span, frac) in ((20.0, 0.05), (20.0, 0.099), (30.0, 0.05))
            @test nviol(_offset_line(span, 4, 2, frac)) == 0
        end
        # The span is measured along the frame line between the successive
        # columns (`_ddm_offset_span_m`), as before.
        @test SS._ddm_offset_span_m((9.0, 1.2), (1.0, 0.0)) ≈ 9.0
        @test SS._ddm_offset_span_m((1.2, -9.0), (0.0, 1.0)) ≈ 9.0
    end

    @testset "§13.6.1.4 on a 3×3 grid, offset in either direction" begin
        # Regular 30 ft grid: no violation.  Centre column (index 5) moved
        # 13% in Y is offset from the X-direction column line; moved 13% in X
        # it is offset from the Y-direction line.  Either span axis checks
        # both directions.
        @test nviol(_offset_grid()) == 0
        @test nviol(_offset_grid(), (0.0, 1.0)) == 0
        for (dx, dy) in ((0.0, 0.13), (0.13, 0.0)), ax in ((1.0, 0.0), (0.0, 1.0))
            g = _offset_grid(k = 5, dx = dx, dy = dy)
            v = SS._column_offset_violations(g, g.columns, ax)
            @test length(v) >= 1
            @test any(s -> occursin("Column 5", s) || occursin("column 5", s), v)
        end
        @test nviol(_offset_grid(k = 5, dy = 0.05)) == 0
    end

    @testset "§13.6.1.4 regular layouts stay clean" begin
        # l_long / l_short = 2 (§13.6.1.2, page 252): the adjacent column
        # line is at 50% of the span, one full transverse spacing away, so
        # it is not taken as the successive column.
        @test nviol(_offset_grid(nx = 4, ny = 4, sx_ft = 30.0, sy_ft = 15.0)) == 0
        @test nviol(_offset_grid(nx = 4, ny = 4, sx_ft = 15.0, sy_ft = 30.0)) == 0
        # A uniformly 5° skewed grid against an unrotated axis: tan 5° ≈ 8.7%.
        @test nviol(_offset_grid(nx = 4, ny = 3, θ = deg2rad(5.0))) == 0
        # Unequal bays (28 / 19 ft), still on line.
        g = _offset_line(28.0, 3, 2, 0.0)
        g.skeleton.geometry.vertex_coords[3, 1] = (28.0 + 19.0) * 0.3048
        @test nviol(g) == 0
    end

    @testset "FrameLine end transfer charges the neighbour's thickness and drop" begin
        # 3×2 bays; the frame line runs x = 20…60 and the slab continues
        # west of its first column, where a separate slab (cells 1–2) has a
        # 10 in result thickness, a 4 in × 10 ft × 10 ft drop panel and a
        # stale cell.self_weight of 50 psf.  The cell path reads the result
        # thickness and the drop; the FrameLine path used to drop γ and use
        # the stale 50 psf with no drop.
        #   West wD = (150 + 125 + 12.5) psf × 20 ft = 5750 lb/ft, wL = 1000.
        #   East wD = 150 × 20 = 3000 lb/ft (design slab, trial sw 0).
        #   Eq. (13-7), §9.2.1 Eq. (9-2), west carries D + 0.5L:
        #   0.07 × 19² × (1.2·5750 + 0.5·1.6·1000 − 1.2·3000) = 103.607 kip·ft.
        pts = Pair{Symbol,Tuple{Float64,Float64}}[]
        for (i, x) in enumerate((0.0, 20.0, 40.0, 60.0)), (j, y) in enumerate((-20.0, 0.0, 20.0))
            push!(pts, Symbol("v$(i)$(j)") => (x, y))
        end
        faces = [[Symbol("v$(i)$(j)"), Symbol("v$(i+1)$(j)"),
                  Symbol("v$(i+1)$(j+1)"), Symbol("v$(i)$(j+1)")] for i in 1:3 for j in 1:2]
        base = _c5_plan(pts, faces, [first(p) for p in pts], :v22)
        ρ = 150.0u"lb/ft^3"
        sp = (primary = 20.0u"ft", secondary = 20.0u"ft", axis = (1.0, 0.0))
        west = (cell_indices = [1, 2], spans = sp, result = (thickness = 10.0u"inch",),
                drop_panel = SS.DropPanelGeometry(4.0u"inch", 60.0u"inch", 60.0u"inch"))
        east = (cell_indices = [3, 4, 5, 6], spans = sp)
        cells = Any[merge(c, (self_weight = k <= 2 ? 50.0psf : 0.0psf,))
                    for (k, c) in enumerate(base.struc.cells)]
        struc = merge(base.struc, (cells = cells, slabs = Any[west, east]))
        byv = Dict(c.vertex_idx => c for c in struc.columns)
        line = [base.col, byv[base.col.vertex_idx + 3], byv[base.col.vertex_idx + 6]]
        fl = (direction = (1.0, 0.0), columns = line, tributary_width = l2,
              span_lengths = [ln, ln], joint_positions = [:exterior, :interior, :exterior])
        tc = TraceCollector()
        res = quiet(() -> SS.run_moment_analysis(DDM(), fl, struc, qu, qD, qL;
                                                 γ_concrete = ρ, tc = tc,
                                                 on_inapplicable = :proceed))
        hand = 0.07 * 19.0^2 * (1.2 * 5750 + 0.5 * 1.6 * 1000 - 1.2 * 3000) / 1000
        @test hand ≈ 103.607 rtol = 1e-4
        @test kft(res.unbalanced_moments[1]) ≈ hand rtol = 1e-6
        @test has_event(tc, :fallback, "stale_self_weight")
        # Same as the cell path at that column with γ.
        cell = quiet(() -> SS._eq137_transfer_moment(struc, east, base.col, (1.0, 0.0),
                                                     qD, qL, l2, ln, M0;
                                                     extra_columns = line, γ = ρ))
        @test kft(res.unbalanced_moments[1]) ≈ kft(cell) rtol = 1e-9
        # Without γ the stale 50 psf and no drop: 50.54 kip·ft (unconservative).
        res0 = quiet(() -> SS.run_moment_analysis(DDM(), fl, struc, qu, qD, qL;
                                                  on_inapplicable = :proceed))
        @test kft(res0.unbalanced_moments[1]) ≈ 0.07 * 361 * (1.2 * 4000 + 800 - 1.2 * 3000) / 1000 rtol = 1e-6
        @test kft(res0.unbalanced_moments[1]) < kft(res.unbalanced_moments[1])
        # Middle and far end are unchanged by γ.
        @test kft(res.unbalanced_moments[2]) ≈ kft(res0.unbalanced_moments[2]) rtol = 1e-12
        @test kft(res.unbalanced_moments[3]) ≈ kft(0.3 * M0) rtol = 1e-9
    end

    @testset "negative service loads are invalid (NaN, :failure)" begin
        # ACI 318-11 §13.6.1.5 (corpus: aci-318-11, page 252): gravity loads
        # only.  qD = −500 psf used to return a finite Eq. (13-7) moment.
        @test isnan(SS.governing_interior_unbalanced_moment(
            -500.0psf, qL, l2, ln, qD, qL, l2, ln))
        @test isnan(SS.governing_interior_unbalanced_moment(
            qD, qL, l2, ln, qD, -1.0psf, l2, ln))
        @test isnan(SS.governing_interior_unbalanced_moment(
            qD, qL, l2, -1.0u"ft", qD, qL, l2, ln))
        w = qD * l2
        wl = qL * l2
        @test isnan(SS._eq137_governing_line_loads(-w, wl, ln, w, wl, ln))
        @test isnan(SS._eq137_governing_line_loads(w, wl, ln, w, -wl, ln))
        @test isnan(SS._eq137_governing_line_loads(w, wl, -ln, w, wl, ln))
        # Zero loads stay valid: zero live, equal spans → 0 under Eq. (9-2)
        # and Eq. (9-1).
        @test kft(SS.governing_interior_unbalanced_moment(
            qD, 0.0psf, l2, ln, qD, 0.0psf, l2, ln)) == 0.0
        @test kft(SS.governing_interior_unbalanced_moment(
            0.0psf, 0.0psf, l2, ln, 0.0psf, 0.0psf, l2, ln)) == 0.0
        # Cell path: negative design qD, and a negative neighbour sdl.
        fix = _two_bay(west_ft = 29.0, east_ft = 40.0)
        for (f, q) in ((fix, -500.0psf),
                       (_two_bay(west_ft = 29.0, east_ft = 40.0, qD_east = -500.0psf), qD))
            tc = TraceCollector()
            Mub = quiet(() -> SS._compute_column_demands_ddm(
                f.struc, [f.col], 0.26 * M0, 0.70 * M0, 0.35 * M0,
                qu, q, qL, l2, ln, (1.0, 0.0), M0; slab = f.slab, tc = tc)[3][1])
            @test isnan(Mub)
            @test has_event(tc, :failure, "negative_service_load")
            r = SS._pipeline_transfer_reinforcement(
                [(c1 = 16.0u"inch", c2 = 16.0u"inch", position = :interior)],
                (unbalanced_moments = [Mub],), nothing, nothing, 8.0u"inch", 6.75u"inch",
                RC_4000_60.concrete.fc′, RC_4000_60.rebar.Fy)
            @test r.ok == false
        end
        # FrameLine (no geometry): every column, traced.
        sm = [(span_idx = 1, ln = ln, M0 = M0, M_neg_left = 0.26 * M0,
               M_pos = 0.52 * M0, M_neg_right = 0.70 * M0),
              (span_idx = 2, ln = ln, M0 = M0, M_neg_left = 0.70 * M0,
               M_pos = 0.52 * M0, M_neg_right = 0.26 * M0)]
        cols = [(position = :interior,), (position = :interior,), (position = :interior,)]
        tc = TraceCollector()
        m = SS._compute_column_demands_from_spans(
            nothing, cols, [:exterior, :interior, :exterior], sm, qu, -500.0psf, qL, l2;
            tc = tc)[3]
        @test all(isnan, m)
        @test has_event(tc, :failure, "negative_service_load")
        # Zero live load on the FrameLine is finite.
        m0 = SS._compute_column_demands_from_spans(
            nothing, cols, [:exterior, :interior, :exterior], sm, qu, qD, 0.0psf, l2)[3]
        @test all(isfinite, m0)
    end

    @testset "NLP staleness check survives shrunk arrays" begin
        # A live array shorter than the frozen copy reads as stale (rebuilt),
        # never a BoundsError.
        fix = _two_bay(west_ft = 29.0, east_ft = 40.0)
        cols = Any[fix.col]
        ctx = SS._nlp_eq137_build(fix.struc, cols)
        @test SS._nlp_eq137_differs(ctx, fix.struc, cols) == false
        @test SS._nlp_eq137_differs(ctx, merge(fix.struc, (cells = fix.struc.cells[1:end-1],)), cols)
        @test SS._nlp_eq137_differs(ctx, merge(fix.struc, (columns = fix.struc.columns[1:end-1],)), cols)
        @test SS._nlp_eq137_differs(ctx, merge(fix.struc, (slabs = Any[],)), cols)
        @test SS._nlp_eq137_differs(ctx, fix.struc, Any[])
    end

    @testset "slab across a gap: same envelope on the cell and FrameLine paths" begin
        # Cycle 9a: no joint is inferred from vertex indices (see cycle 8a),
        # so for either tag the column is ambiguous.  §13.6.3.3 flexure
        # (page 254) takes max(0.26, 0.70) M0; transfer is at least
        # §13.6.3.6 0.3 M0 = 70.40 kip·ft (page 255).  The FrameLine path
        # gives the same flexural envelope and the cell-path transfer.
        for pos in (:interior, :edge)
            fix = _joint_slabs(gap_m = 0.10, pos = pos)
            tc = TraceCollector()
            M = quiet(() -> SS._ddm_support_moment(fix.struc, fix.col, (1.0, 0.0),
                                                   0.26 * M0, 0.70 * M0; tc = tc))
            @test kft(M) ≈ 0.70 * kft(M0) rtol = 1e-12
            @test has_event(tc, :decision, "ambiguous_neighbourhood_envelope")
            Mub = quiet(() -> SS._eq137_transfer_moment(fix.struc, fix.slab, fix.col, (1.0, 0.0),
                                                        qD, qL, l2, ln, M0))
            @test kft(Mub) >= 70.40 - 0.01
            w = first(c for c in fix.struc.columns if c.vertex_idx == 1)
            fl = (direction = (1.0, 0.0), columns = [w, fix.col], tributary_width = l2,
                  span_lengths = [ln], joint_positions = [:exterior, :exterior])
            res = quiet(() -> SS.run_moment_analysis(DDM(), fl, fix.struc, qu, qD, qL;
                                                     on_inapplicable = :proceed))
            @test kft(res.column_moments[2]) ≈ 0.70 * kft(M0) rtol = 1e-12
            @test kft(res.unbalanced_moments[2]) >= 70.40 - 0.01
        end
    end

    @testset "polygon-soup grid classifies like a merged grid" begin
        # Every face has its own vertices (cycle 9a: continuity from
        # coordinates).  The interior-tagged centre column is interior
        # (0.70 M0); an :edge column on the boundary is exterior, 0.26 M0
        # flexure and §13.6.3.6 0.3 M0 transfer (page 255).  No ambiguity.
        soup = _soup_grid(n = 3)
        pw = SS._eq137_partway_index(soup.struc,
                                     [c.vertex_idx for c in soup.struc.columns])
        @test all(isempty, values(pw.near))
        tc = TraceCollector()
        M = quiet(() -> SS._compute_column_demands_ddm(
            soup.struc, [soup.col], 0.26 * M0, 0.70 * M0, 0.35 * M0,
            qu, qD, qL, l2, ln, (1.0, 0.0), M0; slab = soup.slab, tc = tc)[1][1])
        @test kft(M) ≈ 0.70 * kft(M0) rtol = 1e-12
        @test has_event(tc, :decision, "duplicate_vertex_merged")
        @test !has_event(tc, :decision, "ambiguous_neighbourhood_envelope")
        vc = soup.struc.skeleton.geometry.vertex_coords
        edge = first(c for c in soup.struc.columns
                     if c.position == :edge && abs(vc[c.vertex_idx, 1]) < 1e-9)
        tc = TraceCollector()
        Me, _, Mube = quiet(() -> SS._compute_column_demands_ddm(
            soup.struc, [edge], 0.26 * M0, 0.70 * M0, 0.35 * M0,
            qu, qD, qL, l2, ln, (1.0, 0.0), M0; slab = soup.slab, tc = tc))
        @test kft(Me[1]) ≈ 0.26 * kft(M0) rtol = 1e-12
        @test kft(Mube[1]) ≈ 0.3 * kft(M0) rtol = 1e-12
        @test !has_event(tc, :decision, "ambiguous_neighbourhood_envelope")
    end
end


# =============================================================================
# Fix cycle 9, part B: §13.6.1.4 successive columns are genuine neighbours,
# the NLP staleness check off the lock, and invalid FrameLine spans.
# =============================================================================

"""
Columns at plan points `pts` (meters, structural offset 0).  Duck-typed
for `_column_offset_violations`.
"""
function _plan_points(pts)
    vc = zeros(length(pts), 2)
    for (i, p) in enumerate(pts)
        vc[i, 1], vc[i, 2] = p
    end
    cols = Any[(vertex_idx = i, position = :interior, c1 = 12.0u"inch", c2 = 12.0u"inch",
                θ = 0.0, structural_offset = (0.0, 0.0)) for i in eachindex(pts)]
    return (skeleton = (geometry = (vertex_coords = vc,), face_vertex_indices = Vector{Int}[]),
            columns = cols)
end

"""
L-plan in feet: rows at `y_rows_ft` spanning x = 0…120 ft, plus a row at
y = 0 ending at x = 60 ft; 30 ft bays.  Returned in meters.
"""
function _l_plan(y_rows_ft)
    m = 0.3048
    pts = NTuple{2,Float64}[]
    for y in y_rows_ft, x in 0.0:30.0:120.0
        push!(pts, (x * m, y * m))
    end
    for x in 0.0:30.0:60.0
        push!(pts, (x * m, 0.0))
    end
    return _plan_points(pts)
end

@testset "Eq. (13-7) cycle 9b: §13.6.1.4 neighbours, NLP staleness, FrameLine spans" begin
    qD = 150.0psf
    qL = 50.0psf
    kft(x) = ustrip(kip * u"ft", x)
    has_event(tc, ev, r) = any(e -> e.event_type == ev &&
                                    get(e.data, "reason", "") == r, tc.events)
    quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
    viol(p, ax = (1.0, 0.0)) = SS._column_offset_violations(p, p.columns, ax)
    L = 20.0 * 0.3048

    @testset "§13.6.1.4: twins and other column lines are not successive columns" begin
        # ACI 318-11 §13.6.1.4 (corpus: aci-318-11, page 252): offset is
        # measured "between centerlines of successive columns".
        # (a) A twin column 0.40 m north / 0.06 m east of a line column (a
        # doubled column) used to be its successive column along Y:
        # "offset 0.06 m (15.0% of the 0.4 m span)".  Twins are one support
        # group; the twin itself is 0.40 m off a 6.04 m span (6.6%).
        @test isempty(viol(_plan_points([(0.0, 0.0), (L, 0.0), (L + 0.06, 0.40),
                                         (2L, 0.0), (3L, 0.0)])))
        # (b) One column of a line missing: the search used to jump to the
        # other line inside the cone ("offset 5.79 m (47.5%)").  That is a
        # span-length (§13.6.1.3) matter, not an offset.
        @test isempty(viol(_plan_points([(0.0, 0.0), (2L, 0.0), (3L, 0.0), (L, 0.95L)])))
        # (c) L-plan: the y = 0 row ends at x = 60 ft; the y = 20 ft column
        # two bays ahead (33.3%) used to be flagged.  It is a full row
        # spacing (20 ft) off the y = 0 line, so it is on the y = 20 line
        # (cycle 10b column-line membership).
        @test isempty(viol(_l_plan((20.0, 40.0))))
        @test isempty(viol(_l_plan((20.0, 40.0)), (0.0, 1.0)))
        # Same at l_long / l_short = 2 (rows 15 ft apart): the column two
        # bays ahead is at 25% of its span but a full row spacing off.
        @test isempty(viol(_l_plan((15.0, 30.0))))
        # Aspect-2 grid with an interior column removed: no offset.
        g = _offset_grid(nx = 4, ny = 3, sx_ft = 30.0, sy_ft = 15.0)
        keep = [k for k in eachindex(g.columns) if k != 5]
        gm = _plan_points([Tuple(g.skeleton.geometry.vertex_coords[k, :]) for k in keep])
        @test isempty(viol(gm))
        @test isempty(viol(gm, (0.0, 1.0)))
    end

    @testset "§13.6.1.4: true offsets still flagged next to twins and gaps" begin
        # Column 2 of a 20 ft line offset 15% (0.91 m): flagged, also with a
        # twin beside column 4 and with column 5 missing from the line.
        base = [(0.0, 0.0), (L, 0.15L), (2L, 0.0), (3L, 0.0)]
        for pts in (base, vcat(base, [(3L + 0.06, 0.40)]), vcat(base, [(5L, 0.0)]))
            v = viol(_plan_points(pts))
            @test length(v) >= 1
            @test all(s -> occursin("§13.6.1.4", s) && occursin("page 252", s), v)
            @test any(s -> occursin("Column 2", s), v)
        end
        # A twin is checked against its own successive column: a twin
        # 0.40 m off a 3.5 m span (11.4%) is flagged, not hidden by its
        # on-line partner.
        sp = 3.5
        v = viol(_plan_points([(0.0, 0.0), (sp, 0.0), (sp - 0.06, 0.40), (2sp, 0.0), (3sp, 0.0)]))
        @test any(t -> occursin("Column 3", t) || occursin("column 3", t), v)
        # 30% and 40% of a 20 ft span: flagged.  40% used to fall outside
        # the old 35% search band and was taken as another column line
        # (cycle 10b: column-line membership, `_DDM_LINE_MEMBER_FRAC`).
        @test !isempty(viol(_offset_line(20.0, 4, 2, 0.30)))
        @test !isempty(viol(_offset_line(20.0, 4, 2, 0.40)))
    end

    @testset "FrameLine: negative or non-finite span → NaN transfer, traced" begin
        l2 = 20.0u"ft"
        ln = 19.0u"ft"
        qu = max(1.4 * qD, 1.2 * qD + 1.6 * qL)
        M0 = SS.total_static_moment(qu, l2, ln)
        span(k, l) = (span_idx = k, ln = l, M0 = M0, M_neg_left = (k == 1 ? 0.26 : 0.70) * M0,
                      M_pos = 0.52 * M0, M_neg_right = (k == 2 ? 0.26 : 0.70) * M0)
        cols = [(position = :interior,), (position = :interior,), (position = :interior,)]
        classes = [:exterior, :interior, :exterior]
        demands(sm; tc = nothing) = SS._compute_column_demands_from_spans(
            nothing, cols, classes, sm, qu, qD, qL, l2; tc = tc)[3]
        # Span 1 negative: the end column used to get a finite 0.3 M0 and
        # the middle column an untraced NaN.  Span 2 is valid, so the far
        # end keeps 0.3 M0.
        for bad in (-19.0u"ft", NaN * u"ft", Inf * u"ft")
            tc = TraceCollector()
            m = demands([span(1, bad), span(2, ln)]; tc = tc)
            @test isnan(m[1]) && isnan(m[2])
            @test kft(m[3]) ≈ 0.3 * kft(M0) rtol = 1e-12
            @test has_event(tc, :failure, "negative_span")
            @test count(e -> get(e.data, "reason", "") == "negative_span", tc.events) == 2
        end
        tc = TraceCollector()
        m = demands([span(1, ln), span(2, -1.0u"ft")]; tc = tc)
        @test kft(m[1]) ≈ 0.3 * kft(M0) rtol = 1e-12
        @test isnan(m[2]) && isnan(m[3])
        @test has_event(tc, :failure, "negative_span")
        # The NaN transfer moment is rejected downstream.
        r = SS._pipeline_transfer_reinforcement(
            [(c1 = 16.0u"inch", c2 = 16.0u"inch", position = :interior)],
            (unbalanced_moments = [m[3]],), nothing, nothing, 8.0u"inch", 6.75u"inch",
            RC_4000_60.concrete.fc′, RC_4000_60.rebar.Fy)
        @test r.ok == false
        # Valid spans (zero included) are not failures.
        tc = TraceCollector()
        m = demands([span(1, ln), span(2, ln)]; tc = tc)
        @test all(isfinite, m)
        @test !has_event(tc, :failure, "negative_span")
        tc = TraceCollector()
        demands([span(1, 0.0u"ft"), span(2, ln)]; tc = tc)
        @test !has_event(tc, :failure, "negative_span")
    end

    if HAS_STRUCTURAL_SYNTHESIZER
        @testset "NLP: staleness checked once per frozen sweep" begin
            skel = gen_medium_office(72.0u"ft", 72.0u"ft", 9.0u"ft", 3, 3, 1)
            struc = BuildingStructure(skel)
            initialize!(struc; material = NWC_4000, floor_type = :flat_plate,
                        floor_opts = FlatPlateOptions(method = DDM()))
            slab = first(struc.slabs)
            cols = SS.find_supporting_columns(struc, Set(slab.cell_indices))
            tc = TraceCollector()
            p = FlatPlateNLPProblem(struc, slab, cols, FlatPlateOptions(); tc = tc)
            sweeps() = @atomic p.eq137.maps.sweeps
            x = [9.0, 18.0]
            ref = SS.evaluate(p, x)[1:2]

            # Stale maps are rebuilt once on entry; evaluate inside the sweep
            # uses them and the counter is restored.
            dropped = pop!(slab.cell_indices)
            try
                @test SS._nlp_eq137_stale(p)
                r = SS._nlp_frozen_sweep(p) do
                    @test sweeps() == 1
                    @test !SS._nlp_eq137_stale(p)
                    SS.evaluate(p, x)[1:2]
                end
                @test sweeps() == 0
                @test has_event(tc, :decision, "eq137_maps_rebuilt")
                @test !haskey(SS._nlp_eq137_maps(p).cell_slab, dropped)
            finally
                push!(slab.cell_indices, dropped)
            end
            @test SS.evaluate(p, x)[1:2] == ref

            # A mutation during the sweep is not picked up per call; it is
            # detected afterwards and the sweep's result is refused.
            vc = struc.skeleton.geometry.vertex_coords
            vi = SS.col_vertex_idx(first(cols))
            x0 = vc[vi, 1]
            before = SS._nlp_eq137_maps(p)
            try
                @test_throws ErrorException SS._nlp_frozen_sweep(p) do
                    vc[vi, 1] = x0 + 1e-3
                    SS.evaluate(p, x)
                    @test SS._nlp_eq137_maps(p) === before
                    true
                end
                @test sweeps() == 0
                @test has_event(tc, :failure, "eq137_geometry_mutated_during_sweep")
            finally
                vc[vi, 1] = x0
            end
            # An exception inside the sweep also restores the counter.
            @test_throws ArgumentError SS._nlp_frozen_sweep(() -> throw(ArgumentError("x")), p)
            @test sweeps() == 0

            # Outside a sweep, evaluate still rebuilds stale maps itself
            # (lock-free check, lock only to rebuild).
            try
                vc[vi, 1] = x0 + 1e-3
                @test SS._nlp_eq137_stale(p)
                SS.evaluate(p, x)
                @test !SS._nlp_eq137_stale(p)
            finally
                vc[vi, 1] = x0
            end
            SS.evaluate(p, x)
            @test !SS._nlp_eq137_stale(p)

            # The driver runs its threaded grid search inside a frozen sweep
            # (it used to read a missing `n_evals` field of the solver result).
            res = quiet(() -> size_flat_plate_optimized(struc, slab, FlatPlateOptions();
                                                        n_grid = 4, n_refine = 0))
            @test res.status in (:optimal, :infeasible)
            @test res.n_evals == 16
        end
    end
end


# =============================================================================
# Fix cycle 10, part A: Eq. (13-7) spans from the column layout, not from
# face corners.  ACI 318-11 §13.6.2.5 (corpus: aci-318-11, page 253): ℓn
# runs face to face of columns; §13.6.9.2 Eq. (13-7) (page 258).
# =============================================================================

@testset "Eq. (13-7) cycle 10a: column-layout spans, far supports" begin
    qD = 150.0psf
    qL = 50.0psf
    ft = 0.3048
    kft(x) = ustrip(kip * u"ft", x)
    has_event(tc, ev, r) = any(e -> e.event_type == ev &&
                                    get(e.data, "reason", "") == r, tc.events)
    quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
    l2 = 20.0u"ft"
    ln = 19.0u"ft"
    qu = max(1.4 * qD, 1.2 * qD + 1.6 * qL)
    M0 = SS.total_static_moment(qu, l2, ln)
    mk(v; pos = :interior, c = 12.0) = (vertex_idx = v, position = pos, c1 = c * u"inch",
                                        c2 = c * u"inch", θ = 0.0, structural_offset = (0.0, 0.0))
    # Duck building: `pts` in ft (z in m when given), every face in one slab
    # unless `slabcells` says otherwise.
    function build(pts, faces, cols; z = nothing, slabcells = [collect(eachindex(faces))])
        vc = zeros(length(pts), z === nothing ? 2 : 3)
        for (i, p) in enumerate(pts)
            vc[i, 1] = p[1] * ft
            vc[i, 2] = p[2] * ft
            z === nothing || (vc[i, 3] = z[i])
        end
        cells = Any[(face_idx = k, sdl = qD, live_load = qL, self_weight = 0.0psf)
                    for k in eachindex(faces)]
        sp = (primary = l2, secondary = l2, axis = (1.0, 0.0))
        slabs = Any[(cell_indices = sc, spans = sp) for sc in slabcells]
        return (cells = cells, slabs = slabs, columns = cols,
                skeleton = (geometry = (vertex_coords = vc,), face_vertex_indices = faces))
    end
    # Quads between grid lines `xs`, `ys` (ft); `V(x, y)` is the vertex index.
    function grid(xs, ys)
        pts = NTuple{2,Float64}[]
        id = Dict{Tuple{Float64,Float64},Int}()
        V(x, y) = get!(id, (x, y)) do
            push!(pts, (x, y))
            length(pts)
        end
        faces = Vector{Int}[]
        for i in 1:length(xs)-1, j in 1:length(ys)-1
            push!(faces, [V(xs[i], ys[j]), V(xs[i+1], ys[j]), V(xs[i+1], ys[j+1]), V(xs[i], ys[j+1])])
        end
        return pts, faces, V
    end
    function demands(st, col; tc = nothing)
        M, _, Mub = SS._compute_column_demands_ddm(
            st, [col], 0.26 * M0, 0.70 * M0, 0.35 * M0,
            qu, qD, qL, l2, ln, (1.0, 0.0), M0; slab = st.slabs[1], tc = tc)
        return kft(M[1]), kft(Mub[1])
    end
    # Two bays 20 ft / 30 ft, y = -20..20 ft, 12 in columns at x = 0, 20, 50
    # on y = 0; the design column is the one at x = 20.
    function two_bay(xs, ys)
        pts, faces, V = grid(xs, ys)
        cols = Any[mk(V(20.0, 0.0)), mk(V(0.0, 0.0); pos = :edge), mk(V(50.0, 0.0); pos = :edge)]
        return build(pts, faces, cols), cols, pts, faces, V
    end
    st, cols = two_bay([0.0, 20.0, 50.0], [-20.0, 0.0, 20.0])
    M_ref, Mub_ref = demands(st, cols[1])
    # §13.6.3.3 (page 254) interior negative 0.70 M0; Eq. (13-7) page 258.
    @test M_ref ≈ 164.255 rtol = 1e-4
    @test Mub_ref ≈ 168.056 rtol = 1e-4

    @testset "sub-panel meshing does not cut the span (D1)" begin
        # Before: 42.01, 84.03 (untraced), 42.01 (untraced), 21.01 and 0.01
        # kip·ft.  Faces split at grid lines without columns are one panel.
        for (xs, ys) in (([0.0, 10.0, 20.0, 35.0, 50.0], [-20.0, 0.0, 20.0]),
                         ([0.0, 20.0, 50.0], [-20.0, -10.0, 0.0, 10.0, 20.0]),
                         ([0.0, 20.0, 50.0], [-20.0, -5.0, 0.0, 5.0, 20.0]),
                         ([0.0, 10.0, 20.0, 35.0, 50.0], [-20.0, -10.0, 0.0, 10.0, 20.0]),
                         ([0.0, 19.0, 20.0, 21.0, 50.0], [-20.0, 0.0, 20.0]))
            st, cols = two_bay(xs, ys)
            tc = TraceCollector()
            M, Mub = quiet(() -> demands(st, cols[1]; tc = tc))
            @test M ≈ M_ref rtol = 1e-9
            @test Mub ≈ Mub_ref rtol = 1e-9
            @test isempty(tc.events)
            # §13.6.1.3 (page 252) reads the same column-layout spans: 20 vs
            # 30 ft differ by 10 ft ≤ 30/3, no violation.
            @test isempty(SS._successive_span_violations(st, st.slabs[1], cols))
        end
    end

    @testset "near-duplicate far column fails closed (D3)" begin
        # The two faces on one side use a copy of the far column vertex moved
        # `dx` toward the design column.  Before: 1 cm and 0.1 m gave the
        # `far_support_not_column` fallback, 163.53 / 166.4 < 168.06 on the
        # D-only (west) span.  Now the short gap is ambiguous: envelope ≥
        # the merged answer, traced.  Both the D-only (west, 20 ft) and the
        # loaded (east, 30 ft) span.
        for (far_x, sgn) in ((0.0, 1.0), (50.0, -1.0)), dx in (0.01, 0.1)
            st0, cols, pts, faces, V = two_bay([0.0, 20.0, 50.0], [-20.0, 0.0, 20.0])
            fv = V(far_x, 0.0)
            pts2 = vcat(pts, [(far_x + sgn * dx / ft, 0.0)])
            cp = length(pts2)
            west = far_x < 20.0
            faces2 = [(sum(pts[u][1] for u in f) / length(f) < 20.0) == west ?
                      [u == fv ? cp : u for u in f] : f for f in faces]
            st = build(pts2, faces2, cols)
            tc = TraceCollector()
            M, Mub = quiet(() -> demands(st, cols[1]; tc = tc))
            @test M >= M_ref * (1 - 1e-9)
            @test Mub >= Mub_ref * (1 - 1e-9)
            @test has_event(tc, :decision, "far_support_ambiguous")
            @test has_event(tc, :decision, "uncertain_far_support_envelope")
            @test !has_event(tc, :fallback, "far_support_not_column")
        end
    end

    @testset "T-junction re-resolve envelopes, never aborts (D4)" begin
        # NW and NE faces end at the column at (20, 0); a south face's top
        # edge runs through it from x = 0 to 60 ft.  The `with_near`
        # re-resolve used to throw ("more than one frame-line span").
        pts = [(0.0, 0.0), (20.0, 0.0), (40.0, 0.0), (0.0, 20.0), (20.0, 20.0), (40.0, 20.0),
               (0.0, -20.0), (60.0, -20.0), (60.0, 0.0)]
        faces = [[1, 2, 5, 4], [2, 3, 6, 5], [7, 8, 9, 1]]
        cols = Any[mk(2), mk(1; pos = :edge), mk(3), mk(9; pos = :edge)]
        st = build(pts, faces, cols)
        tc = TraceCollector()
        M, Mub = quiet(() -> demands(st, cols[1]; tc = tc))
        @test M ≈ 0.70 * kft(M0) rtol = 1e-9
        @test isfinite(Mub)
        @test Mub >= 0.3 * kft(M0) * (1 - 1e-9)
        @test has_event(tc, :decision, "ambiguous_neighbourhood_envelope")
    end

    @testset "coincident far columns of different size (D5)" begin
        # A 30 in column on its own vertex at the far east support, beside
        # the 12 in one.  Before: the vertex order picked one (154.83 or
        # 168.06).  §13.6.2.5 measures ℓn to the support face, which is
        # undefined here, and neither size is conservative in general, so
        # both orders are rejected like the same-vertex conflict: NaN with a
        # `:failure` trace event on the transfer path (cycle 11a), never an
        # abort.
        pts, faces, V = grid([0.0, 20.0, 50.0], [-20.0, 0.0, 20.0])
        pts2 = vcat(pts, [(50.0, 0.0)])
        fe, fe2 = V(50.0, 0.0), length(pts2)
        for (a, b) in ((mk(fe; pos = :edge), mk(fe2; pos = :edge, c = 30.0)),
                       (mk(fe2; pos = :edge, c = 30.0), mk(fe; pos = :edge)),
                       (mk(fe; pos = :edge, c = 30.0), mk(fe2; pos = :edge)))
            cs = Any[mk(V(20.0, 0.0)), mk(V(0.0, 0.0); pos = :edge), a, b]
            st = build(pts2, faces, cs)
            tc = TraceCollector()
            @test isnan(quiet(() -> demands(st, cs[1]; tc = tc))[2])
            @test has_event(tc, :failure, "adjoining_spans_unresolved")
        end
        # Same size on both vertices: one support, the merged answer.
        cs = Any[mk(V(20.0, 0.0)), mk(V(0.0, 0.0); pos = :edge), mk(fe; pos = :edge),
                 mk(fe2; pos = :edge)]
        st = build(pts2, faces, cs)
        @test quiet(() -> demands(st, cs[1]))[2] ≈ Mub_ref rtol = 1e-9
    end

    @testset "NaN z taints the storey (D6)" begin
        # Lower storey (z = 0): west faces only, edge column at (20, 0).
        # Upper storey (z = 3.5 m): west and east faces.  A NaN z used to
        # match every storey and give a finite, untraced answer.
        pts = [(0.0, 0.0), (20.0, 0.0), (0.0, 20.0), (20.0, 20.0), (0.0, -20.0), (20.0, -20.0),
               (0.0, 0.0), (20.0, 0.0), (0.0, 20.0), (20.0, 20.0), (0.0, -20.0), (20.0, -20.0),
               (40.0, 0.0), (40.0, 20.0), (40.0, -20.0)]
        z = [0.0, 0, 0, 0, 0, 0, 3.5, 3.5, 3.5, 3.5, 3.5, 3.5, 3.5, 3.5, 3.5]
        faces = [[1, 2, 4, 3], [5, 6, 2, 1], [7, 8, 10, 9], [11, 12, 8, 7], [8, 13, 14, 10],
                 [12, 15, 13, 8]]
        cols = Any[mk(2; pos = :edge), mk(1; pos = :edge), mk(8), mk(7; pos = :edge),
                   mk(13; pos = :edge)]
        st = build(pts, faces, cols; z = z, slabcells = [[1, 2], [3, 4, 5, 6]])
        tc = TraceCollector()
        _, Mub = quiet(() -> demands(st, cols[1]; tc = tc))
        @test Mub ≈ 0.3 * kft(M0) rtol = 1e-9
        @test !has_event(tc, :failure, "non_finite_vertex")
        for vi in (2, 8, 13)
            z2 = copy(z)
            z2[vi] = NaN
            st = build(pts, faces, cols; z = z2, slabcells = [[1, 2], [3, 4, 5, 6]])
            tc = TraceCollector()
            _, Mub = quiet(() -> demands(st, cols[1]; tc = tc))
            @test isnan(Mub)
            @test has_event(tc, :failure, "non_finite_vertex")
        end
    end
end


# =============================================================================
# Fix cycle 10, part B: §13.6.1.4 column-line membership and §13.6.1.2
# rectangular panels from geometry.
# =============================================================================

"""
Faced grid with column lines at `xs_ft` × `ys_ft` (one quad face per bay,
all cells in one slab, a 16 in column at every node).  `move` maps a node
index `(i, j)` to a plan shift `(dx_ft, dy_ft)`.  `spans` defaults to the
first bay.  Duck-typed for `check_ddm_applicability`.
"""
function _faced_grid(xs_ft, ys_ft; move = Dict{Tuple{Int,Int},NTuple{2,Float64}}(),
                     spans = nothing, extra = (;))
    m = 0.3048
    nx, ny = length(xs_ft), length(ys_ft)
    id(i, j) = (j - 1) * nx + i
    vc = zeros(nx * ny, 2)
    for i in 1:nx, j in 1:ny
        d = get(move, (i, j), (0.0, 0.0))
        vc[id(i, j), 1] = (xs_ft[i] + d[1]) * m
        vc[id(i, j), 2] = (ys_ft[j] + d[2]) * m
    end
    faces = [[id(i, j), id(i + 1, j), id(i + 1, j + 1), id(i, j + 1)]
             for j in 1:ny-1 for i in 1:nx-1]
    cells = Any[(face_idx = k, sdl = 20.0psf, live_load = 50.0psf, self_weight = 0.0psf)
                for k in eachindex(faces)]
    cols = Any[(vertex_idx = v, position = :interior, c1 = 16.0u"inch", c2 = 16.0u"inch",
                θ = 0.0, structural_offset = (0.0, 0.0)) for v in 1:nx*ny]
    sp = spans === nothing ?
        (primary = (xs_ft[2] - xs_ft[1]) * u"ft", secondary = (ys_ft[2] - ys_ft[1]) * u"ft",
         axis = (1.0, 0.0)) : spans
    slab = merge((cell_indices = collect(eachindex(faces)), spans = sp), extra)
    struc = (cells = cells, slabs = Any[slab], columns = cols,
             skeleton = (geometry = (vertex_coords = vc,), face_vertex_indices = faces))
    return (struc = struc, slab = slab, columns = cols)
end

@testset "Eq. (13-7) cycle 10b: §13.6.1.4 column lines, §13.6.1.2 panels" begin
    quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
    viol(p, ax = (1.0, 0.0)) = SS._column_offset_violations(p, p.columns, ax)
    applic(g) = quiet(() -> SS.check_ddm_applicability(g.struc, g.slab, g.columns;
                                                        throw_on_failure = false))
    xs, ys = [0.0, 20.0, 40.0, 60.0], [0.0, 40.0, 80.0, 120.0]
    ft = 0.3048

    @testset "§13.6.1.4: 36–49% offsets on a line are flagged" begin
        # ACI 318-11 §13.6.1.4 (corpus: aci-318-11, page 252): "Offset of
        # columns by a maximum of 10 percent of the span ... shall be
        # permitted."  Critic repro: on straight lines of 4–5 columns,
        # 12–34% offsets were flagged but 36/40/45/49% gave no violation
        # (outside the old 35% search band).
        for frac in (0.36, 0.40, 0.45, 0.49), (n, k) in ((4, 2), (5, 3))
            v = viol(_offset_line(20.0, n, k, frac))
            @test !isempty(v)
            @test all(s -> occursin("§13.6.1.4", s) && occursin("page 252", s), v)
            @test any(s -> occursin("Column $(k)", s), v)
        end
    end

    @testset "§13.6.1.4: 36–49% offsets on a faced grid fail DDM" begin
        # 20 × 40 ft bays; node (20, 40) moved in y by frac × 20 ft.  It
        # stays far nearer its own line (y = 40) than the next (40 ft away),
        # so it is an offset of that line.  38% used to return ok = true
        # while 30% failed.
        for frac in (0.30, 0.36, 0.38, 0.40, 0.45, 0.49)
            g = _faced_grid(xs, ys; move = Dict((2, 2) => (0.0, frac * 20.0)))
            r = applic(g)
            @test !r.ok
            @test any(s -> occursin("§13.6.1.4", s) && occursin("Column 6", s), r.violations)
        end
        # Regular grid (panels at exactly l_long / l_short = 2): DDM applies.
        @test applic(_faced_grid(xs, ys)).ok
        # A 5% offset (within §13.6.1.4 and the rectangular-panel
        # tolerance) on 20 × 30 ft bays: no violation at all.  On the
        # 20 × 40 ft grid the same offset makes one panel 20 × 41 ft, beyond
        # the §13.6.1.2 ratio of 2, which is reported as such.
        ys30 = [0.0, 30.0, 60.0, 90.0]
        r = applic(_faced_grid(xs, ys30; move = Dict((2, 2) => (0.0, 0.05 * 20.0))))
        @test r.ok
        @test isempty(r.violations)
        r = applic(_faced_grid(xs, ys; move = Dict((2, 2) => (0.0, 0.05 * 20.0))))
        @test !any(s -> occursin("13.6.1.4", s) || occursin("not rectangular", s), r.violations)
        @test any(s -> occursin("§13.6.1.2", s) && occursin("2.05 > 2", s), r.violations)
    end

    @testset "§13.6.1.4: a column between two lines fails closed" begin
        # Node (20, 40) moved to y = 60: halfway between the y = 40 and
        # y = 80 lines (50% of the transverse spacing).  It belongs to
        # neither; it is checked against the line it leaves and flagged.
        g = _faced_grid(xs, ys; move = Dict((2, 2) => (0.0, 20.0)))
        v = viol((skeleton = g.struc.skeleton, columns = g.columns))
        @test any(s -> occursin("Column 6", s) && occursin("between column lines", s), v)
        @test !applic(g).ok
        # The adjacent lines themselves are not offsets of each other.
        @test isempty(viol((skeleton = _faced_grid(xs, ys).struc.skeleton,
                            columns = g.columns)))
    end

    @testset "§13.6.1.4: twins, gaps, L-plans and regular grids stay clean" begin
        # Unchanged cases (cycles 8b / 9b), re-checked under line membership.
        @test isempty(viol(_offset_line(20.0, 4, 2, 0.0)))
        @test isempty(viol(_plan_points([(0.0, 0.0), (20.0 * ft, 0.0),
                                         (20.0 * ft + 0.06, 0.40), (40.0 * ft, 0.0),
                                         (60.0 * ft, 0.0)])))
        @test isempty(viol(_plan_points([(0.0, 0.0), (40.0 * ft, 0.0), (60.0 * ft, 0.0),
                                         (20.0 * ft, 0.95 * 20.0 * ft)])))
        for rows in ((20.0, 40.0), (15.0, 30.0)), ax in ((1.0, 0.0), (0.0, 1.0))
            @test isempty(viol(_l_plan(rows), ax))
        end
        for g in (_offset_grid(nx = 4, ny = 4, sx_ft = 30.0, sy_ft = 15.0),
                  _offset_grid(nx = 4, ny = 4, sx_ft = 15.0, sy_ft = 30.0),
                  _offset_grid(nx = 4, ny = 3, θ = deg2rad(5.0)),
                  _offset_grid(nx = 5, ny = 4, sx_ft = 28.0, sy_ft = 20.0))
            @test isempty(viol(g))
            @test isempty(viol(g, (0.0, 1.0)))
        end
        # Aspect-2 grid (lines 15 ft apart, 30 ft spans) with the columns
        # at (30, 0) and (30, 15) replaced by one at (30, y).  At y = 2.7 ft
        # it is 82% of the way from the y = 15 line to the y = 0 line: it
        # belongs to y = 0, 9% of the span off it (permitted), and y = 15
        # just has a missing column.  At y = 4.5 ft (30% / 70% of the
        # spacing) it belongs to neither line and is flagged (15% offset).
        lay(yk) = _plan_points(vcat(
            [(x * ft, y * ft) for x in 0.0:30.0:90.0 for y in 0.0:15.0:30.0
             if !((x, y) in ((30.0, 0.0), (30.0, 15.0)))],
            [(30.0 * ft, yk * ft)]))
        @test isempty(viol(lay(2.7)))
        @test isempty(viol(lay(2.7), (0.0, 1.0)))
        @test any(s -> occursin("between column lines", s), viol(lay(4.5)))
    end

    @testset "§13.6.1.2: panel rectangularity from the face geometry" begin
        # ACI 318-11 §13.6.1.2 (corpus: aci-318-11, page 252): "Panels shall
        # be rectangular".  Tolerance: corner offsets within the §13.6.1.4
        # 10% (page 252) are rectangular.
        nr(pts) = SS._ddm_panel_not_rectangular([(p[1] * ft, p[2] * ft) for p in pts], (1.0, 0.0))
        rot(pts, θ) = [(x * cos(θ) - y * sin(θ), x * sin(θ) + y * cos(θ)) for (x, y) in pts]
        rect = [(0.0, 0.0), (30.0, 0.0), (30.0, 20.0), (0.0, 20.0)]
        @test nr(rect) === nothing
        @test nr(reverse(rect)) === nothing
        @test nr([(0.0, 0.0), (15.0, 0.0), (30.0, 0.0), (30.0, 20.0), (0.0, 20.0)]) === nothing
        @test nr(rot(rect, deg2rad(30.0))) === nothing
        # Slightly offset corner (5% and 9.5% of the 20 ft edge) and a 5°
        # skew (8.7%): rectangular within the §13.6.1.4 tolerance.
        @test nr([(0.0, 0.0), (30.0, 0.0), (31.0, 20.0), (0.0, 20.0)]) === nothing
        @test nr([(0.0, 0.0), (30.0, 0.0), (31.9, 20.0), (0.0, 20.0)]) === nothing
        @test nr([(0.0, 0.0), (30.0, 0.0), (30.0 + 20tand(5), 20.0), (20tand(5), 20.0)]) === nothing
        # A 10° parallelogram is within tolerance of the rectangular array
        # rotated by 5° (every edge tan 5° = 8.7% off it); 15° (13.2%) is not.
        sheared(θ) = [(0.0, 0.0), (30.0, 0.0), (30.0 + 20tand(θ), 20.0), (20tand(θ), 20.0)]
        @test nr(sheared(10.0)) === nothing
        @test nr(sheared(15.0)) !== nothing
        # Trapezoid (30% lean of one edge), triangle, L-shape, and a
        # re-entrant quadrilateral: not rectangular.
        @test occursin("> 10%", nr([(0.0, 0.0), (30.0, 0.0), (24.0, 20.0), (0.0, 20.0)]))
        @test occursin("3 corners", nr([(0.0, 0.0), (30.0, 0.0), (0.0, 20.0)]))
        @test occursin("6 corners", nr([(0.0, 0.0), (30.0, 0.0), (30.0, 10.0), (15.0, 10.0),
                                        (15.0, 20.0), (0.0, 20.0)]))
        @test nr([(0.0, 0.0), (30.0, 0.0), (10.0, 5.0), (0.0, 20.0)]) !== nothing

        # Through check_ddm_applicability: a trapezoidal bay fails.  The
        # east line's top node leans 6 ft west over 40 ft (15%).
        g = _faced_grid(xs, ys; move = Dict((4, 4) => (-6.0, 0.0)))
        r = applic(g)
        @test any(s -> occursin("§13.6.1.2", s) && occursin("not rectangular", s), r.violations)
        # Manual override: `is_rectangular = true` skips the geometric test
        # (the §13.6.1.4 offset is still reported); `false` forces a
        # violation on a rectangular grid.
        go = _faced_grid(xs, ys; move = Dict((4, 4) => (-6.0, 0.0)),
                         extra = (is_rectangular = true,))
        r = applic(go)
        @test !any(s -> occursin("not rectangular", s), r.violations)
        @test any(s -> occursin("§13.6.1.4", s), r.violations)
        r = applic(_faced_grid(xs, ys; extra = (is_rectangular = false,)))
        @test any(s -> occursin("§13.6.1.2", s) && occursin("is_rectangular = false", s),
                  r.violations)
    end

    @testset "§13.6.1.2: panel aspect ratio from the column layout" begin
        # 21 × 10 ft bays (2.1 > 2), with slab spans that would pass: the
        # column-layout panels fail.  20 × 10 ft (exactly 2) passes.
        sp = (primary = 20.0u"ft", secondary = 20.0u"ft", axis = (1.0, 0.0))
        g = _faced_grid([0.0, 21.0, 42.0, 63.0], [0.0, 10.0, 20.0, 30.0]; spans = sp)
        r = applic(g)
        @test any(s -> occursin("§13.6.1.2", s) && occursin("2.1 > 2", s), r.violations)
        g = _faced_grid([0.0, 20.0, 40.0, 60.0], [0.0, 10.0, 20.0, 30.0]; spans = sp)
        @test !any(s -> occursin("13.6.1.2", s), applic(g).violations)
        # Slab-span check: 2.1 from slab.spans alone is still a violation.
        sp21 = (primary = 10.0u"ft", secondary = 21.0u"ft", axis = (1.0, 0.0))
        g = _faced_grid(xs, ys; spans = sp21)
        @test any(s -> occursin("§13.6.1.2", s) && occursin("aspect ratio", s),
                  applic(g).violations)
    end
end


# =============================================================================
# Fix cycle 11, part A: side existence and ℓ2 from slab coverage, openings on
# the frame line, twin supports, and fail-closed side resolution.
# =============================================================================

@testset "Eq. (13-7) cycle 11a: coverage sides, strip-clipped ℓ2, openings, twins" begin
    qD = 150.0psf
    qL = 50.0psf
    ft = 0.3048
    kft(x) = ustrip(kip * u"ft", x)
    has_event(tc, ev, r) = any(e -> e.event_type == ev &&
                                    get(e.data, "reason", "") == r, tc.events)
    has_failure(tc) = any(e -> e.event_type == :failure, tc.events)
    quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
    l2 = 20.0u"ft"
    ln = 19.0u"ft"
    qu = max(1.4 * qD, 1.2 * qD + 1.6 * qL)
    M0 = SS.total_static_moment(qu, l2, ln)
    # ACI 318-11 Eq. (13-7) (corpus: aci-318-11, page 258), kip·ft, ℓ2 = 20 ft
    # both sides, longer span unprimed; the larger of §9.2.1 Eq. (9-2)
    # 1.2D + 1.6L and Eq. (9-1) 1.4D (page 123).
    function hand(lnA, lnB)
        lnA < lnB && ((lnA, lnB) = (lnB, lnA))
        D = ustrip(psf, qD)
        L = ustrip(psf, qL)
        f(qDu, qLu) = 0.07 * ((qDu + 0.5 * qLu) * 20.0 * lnA^2 - qDu * 20.0 * lnB^2) / 1000
        return max(f(1.2D, 1.6L), f(1.4D, 0.0))
    end
    @test hand(29.0, 19.0) ≈ 168.056 rtol = 1e-6
    mk(v; pos = :interior, c = 12.0) = (vertex_idx = v, position = pos, c1 = c * u"inch",
                                        c2 = c * u"inch", θ = 0.0, structural_offset = (0.0, 0.0))
    # Duck building: `pts` in ft, every face in one slab.
    function build(pts, faces, cols)
        vc = zeros(length(pts), 2)
        for (i, p) in enumerate(pts)
            vc[i, 1] = p[1] * ft
            vc[i, 2] = p[2] * ft
        end
        cells = Any[(face_idx = k, sdl = qD, live_load = qL, self_weight = 0.0psf)
                    for k in eachindex(faces)]
        sp = (primary = l2, secondary = l2, axis = (1.0, 0.0))
        slabs = Any[(cell_indices = collect(eachindex(faces)), spans = sp)]
        return (cells = cells, slabs = slabs, columns = cols,
                skeleton = (geometry = (vertex_coords = vc,), face_vertex_indices = faces))
    end
    # Quads between grid lines `xs`, `ys` (ft), skipping bays `(i, j)` in
    # `drop`; `V(x, y)` is the vertex index.
    function grid(xs, ys; drop = Set{Tuple{Int,Int}}())
        pts = NTuple{2,Float64}[]
        id = Dict{Tuple{Float64,Float64},Int}()
        V(x, y) = get!(id, (x, y)) do
            push!(pts, (x, y))
            length(pts)
        end
        faces = Vector{Int}[]
        for i in 1:length(xs)-1, j in 1:length(ys)-1
            (i, j) in drop && continue
            push!(faces, [V(xs[i], ys[j]), V(xs[i+1], ys[j]), V(xs[i+1], ys[j+1]), V(xs[i], ys[j+1])])
        end
        return pts, faces, V
    end
    # Single-panel DDM demands at `col` (flexure M, transfer Mub; kip·ft).
    function demands(st, col; tc = nothing)
        M, _, Mub = SS._compute_column_demands_ddm(
            st, [col], 0.26 * M0, 0.70 * M0, 0.35 * M0,
            qu, qD, qL, l2, ln, (1.0, 0.0), M0; slab = st.slabs[1], tc = tc)
        return kft(M[1]), kft(Mub[1])
    end
    # Eq. (13-7) transfer at `col` with every column of `st` (kip·ft).
    function transfer(st, col; ax = (1.0, 0.0), tc = TraceCollector())
        ctx = SS._eq137_context(st, st.columns)
        M = quiet(() -> SS._eq137_transfer_moment(
            st, st.slabs[1], col, ax, qD, qL, l2, ln, M0;
            extra_columns = st.columns, index = ctx.index, vertex_column = ctx.vertex_column,
            cell_slab = ctx.cell_slab, partway = ctx.partway, tc = tc))
        return kft(M), tc
    end
    # Two bays 20 / 30 ft, y = -20..20 ft, 12 in columns at x = 0, 20, 50 on
    # y = 0; the design column is the one at x = 20.
    function two_bay(xs; ys = [-20.0, 0.0, 20.0], drop = Set{Tuple{Int,Int}}())
        pts, faces, V = grid(xs, ys; drop = drop)
        cols = Any[mk(V(20.0, 0.0)), mk(V(0.0, 0.0); pos = :edge), mk(V(50.0, 0.0); pos = :edge)]
        return build(pts, faces, cols), cols
    end
    st_ref, cols_ref = two_bay([0.0, 20.0, 50.0])
    M_ref, Mub_ref = demands(st_ref, cols_ref[1])
    @test M_ref ≈ 164.255 rtol = 1e-4
    @test Mub_ref ≈ 168.056 rtol = 1e-4

    @testset "F1: sliver faces at the column continue the frame line" begin
        # Before: 61.009 / 70.395 (`one_sided_interior`) and 164.255 / 70.395
        # (`zero_sides`): a thin face touching the column was discarded as a
        # perpendicular neighbour.  Side existence now reads slab coverage.
        for xs in ([0.0, 19.9, 20.0, 50.0], [0.0, 19.7, 20.0, 50.0],
                   [0.0, 19.75, 20.0, 50.0], [0.0, 19.9, 20.0, 20.1, 50.0])
            st, cols = two_bay(xs)
            tc = TraceCollector()
            M, Mub = quiet(() -> demands(st, cols[1]; tc = tc))
            @test M ≈ 164.255 atol = 0.01
            @test Mub ≈ 168.056 atol = 0.01
            @test !has_failure(tc)
            @test !has_event(tc, :fallback, "one_sided_interior")
            @test !has_event(tc, :fallback, "zero_sides")
        end
    end

    @testset "F2: faces past the far support enter ℓ2 clipped to the span" begin
        # One face per side spans x = 20..90 ft; the 12 in column at (50, 0)
        # lies on their shared edge.  Before: east ℓ2 = 0, Mub 111.188.
        pts, faces, V = grid([0.0, 20.0, 90.0], [-20.0, 0.0, 20.0])
        push!(pts, (50.0, 0.0))
        cols = Any[mk(V(20.0, 0.0)), mk(V(0.0, 0.0); pos = :edge), mk(length(pts)),
                   mk(V(90.0, 0.0); pos = :edge)]
        st = build(pts, faces, cols)
        _, Mub = quiet(() -> demands(st, cols[1]))
        @test Mub >= 168.056 * (1 - 1e-6)
        sides = quiet(() -> SS._eq137_resolved_sides(st, st.slabs[1], cols[1], (1.0, 0.0);
                                                     extra_columns = cols))
        east = only(s for s in sides if s.side == 1)
        @test ustrip(u"ft", east.l2) ≈ 20.0 rtol = 1e-9
        @test ustrip(u"ft", east.ln) ≈ 29.0 rtol = 1e-9
        # Mirror: one face per side spans x = -40..20 ft, column at (0, 0).
        # Before: 259.03 (conservative by luck, west ℓ2 = 0).
        pts, faces, V = grid([-40.0, 20.0, 50.0], [-20.0, 0.0, 20.0])
        push!(pts, (0.0, 0.0))
        cols = Any[mk(V(20.0, 0.0)), mk(length(pts)), mk(V(-40.0, 0.0); pos = :edge),
                   mk(V(50.0, 0.0); pos = :edge)]
        st = build(pts, faces, cols)
        _, Mub = quiet(() -> demands(st, cols[1]))
        @test Mub >= 168.056 * (1 - 1e-6)
        sides = quiet(() -> SS._eq137_resolved_sides(st, st.slabs[1], cols[1], (1.0, 0.0);
                                                     extra_columns = cols))
        west = only(s for s in sides if s.side == -1)
        @test ustrip(u"ft", west.l2) ≈ 20.0 rtol = 1e-9
    end

    # 3 × 3 bays: x spans 20 / 30 / 20 ft, y spans 20 / 20 / 20 ft, a 12 in
    # column at every grid node.
    xc = [0.0, 20.0, 50.0, 70.0]
    yc = [0.0, 20.0, 40.0, 60.0]
    cols_xy = [(x, y) for x in xc for y in yc]

    @testset "F3: hanging node on a merged face gives the conforming value" begin
        # The two 30 ft bays between y = 0 and 40 are one face, so the columns
        # at (20, 20) and (50, 20) lie partway along its edges.  The plan is
        # the regular grid, so Eq. (13-7) must equal the conforming mesh:
        # 29 ft vs 19 ft clear, ℓ2 = 20 ft.  Before: 70.4 (0.3 M0).
        pts = NTuple{2,Float64}[]
        id = Dict{Tuple{Float64,Float64},Int}()
        V(x, y) = get!(id, (x, y)) do
            push!(pts, (x, y))
            length(pts)
        end
        faces = Vector{Int}[]
        for i in 1:3, j in 1:3
            if i == 2 && j in (1, 2)
                j == 1 && push!(faces, [V(20.0, 0.0), V(50.0, 0.0), V(50.0, 40.0), V(20.0, 40.0)])
                continue
            end
            push!(faces, [V(xc[i], yc[j]), V(xc[i+1], yc[j]), V(xc[i+1], yc[j+1]), V(xc[i], yc[j+1])])
        end
        st = build(pts, faces, Any[mk(V(x, y)) for (x, y) in cols_xy])
        for xy in ((20.0, 20.0), (50.0, 20.0))
            col = st.columns[findfirst(==(xy), cols_xy)]
            M, tc = transfer(st, col)
            @test M ≈ hand(29.0, 19.0) rtol = 1e-4
            @test !has_failure(tc)
        end
        col = st.columns[findfirst(==((50.0, 20.0)), cols_xy)]
        ctx = SS._eq137_context(st, st.columns)
        @test quiet(() -> SS._ddm_support_moment(st, col, (1.0, 0.0), 0.26, 0.70;
                                                 index = ctx.index,
                                                 vertex_column = ctx.vertex_column,
                                                 partway = ctx.partway)) == 0.70
    end

    @testset "F4: an opening on the frame line does not end the span" begin
        # Square opening of side `hw` ft at x = hx..hx+hw on the y = 20 column
        # line.  Before: 111.19 at x = 35 (`far_support_not_column`), and a
        # false §13.6.1.3 rejection ("16.5 ft differ") at x = 45.
        for (hx, hw) in ((35.0, 1.5), (45.0, 1.5))
            xs = sort(vcat(xc, [hx, hx + hw]))
            ys = sort(vcat(yc, [20.0 - hw / 2, 20.0 + hw / 2]))
            i = findfirst(==(hx), xs)
            drop = Set((i, j) for j in 1:length(ys)-1
                       if ys[j] >= 20.0 - hw / 2 - 1e-9 && ys[j+1] <= 20.0 + hw / 2 + 1e-9)
            pts, faces, V = grid(xs, ys; drop = drop)
            st = build(pts, faces, Any[mk(V(x, y)) for (x, y) in cols_xy])
            for xy in ((20.0, 20.0), (50.0, 20.0))
                col = st.columns[findfirst(==(xy), cols_xy)]
                M, tc = transfer(st, col)
                @test M >= hand(29.0, 19.0) * (1 - 1e-6)
                @test has_event(tc, :decision, "far_support_across_opening")
                @test !has_event(tc, :fallback, "far_support_not_column")
            end
            v = quiet(() -> SS._successive_span_violations(st, st.slabs[1], st.columns))
            @test !any(s -> occursin("13.6.1.3", s), v)
        end
        # 2 ft × 0.5 ft slot across the y = 0 line of the two-bay plan,
        # x = 30..32 ft.  Before: 111.19.
        st, cols = two_bay([0.0, 20.0, 30.0, 32.0, 50.0];
                           ys = [-20.0, -0.25, 0.0, 0.25, 20.0], drop = Set([(3, 2), (3, 3)]))
        M, tc = transfer(st, cols[1])
        @test M >= Mub_ref * (1 - 1e-6)
        @test has_event(tc, :decision, "far_support_across_opening")
    end

    @testset "F7: twin columns ahead form one support" begin
        # 16 in columns at x = 20 and 20 + dx on the frame line, then x = 50.
        # Before: untraced `ArgumentError` (non-positive ℓn) at 0.5 / 1.0 ft;
        # 107.32 from a 0.07 ft east span at 1.4 ft.  Now the far support is
        # x = 50 and the east range runs from the twin's outer face (27.7 to
        # 28.2 ft) to the design column's own face (28.67 ft).
        for dx in (0.5, 1.0, 1.4)
            pts, faces, V = grid([0.0, 20.0, 20.0 + dx, 50.0], [-20.0, 0.0, 20.0])
            cols = Any[mk(V(0.0, 0.0); c = 16.0), mk(V(20.0, 0.0); c = 16.0),
                       mk(V(20.0 + dx, 0.0); c = 16.0), mk(V(50.0, 0.0); c = 16.0)]
            st = build(pts, faces, cols)
            M, tc = transfer(st, cols[2])
            @test isfinite(M)
            @test has_event(tc, :decision, "twin_support_group")
            @test M ≈ hand(30.0 - 16.0 / 12, 20.0 - 16.0 / 12) rtol = 1e-4
            sides = quiet(() -> SS._eq137_resolved_sides(st, st.slabs[1], cols[2], (1.0, 0.0);
                                                         extra_columns = cols))
            east = only(s for s in sides if s.side == 1)
            @test ustrip(u"ft", east.ln_range[1]) ≈ 30.0 - dx - 16.0 / 12 rtol = 1e-9
            @test ustrip(u"ft", east.l_cc) ≈ 30.0 rtol = 1e-9
            # The twin itself sees the column at x = 20 as its twin.
            M3, tc3 = transfer(st, cols[3])
            @test isfinite(M3) || has_failure(tc3)
        end
    end

    @testset "ambiguous side geometry is NaN + :failure, never a throw" begin
        # Voronoi-style honeycomb, columns only at interior (degree-3)
        # vertices: cells cross the frame line with no column line on one
        # side.  Before: 16 of 36 transfers threw an untraced ArgumentError.
        R = 12.0
        pts = NTuple{2,Float64}[]
        id = Dict{Tuple{Int,Int},Int}()
        V(p) = get!(id, (round(Int, p[1] * 100), round(Int, p[2] * 100))) do
            push!(pts, p)
            length(pts)
        end
        faces = Vector{Int}[]
        w = sqrt(3) * R
        for i in 0:3, j in 0:3
            cx = i * w + (isodd(j) ? w / 2 : 0.0)
            cy = j * 1.5R
            push!(faces, [V((cx + R * cosd(60k + 30), cy + R * sind(60k + 30))) for k in 0:5])
        end
        deg = zeros(Int, length(pts))
        for f in faces, v in f
            deg[v] += 1
        end
        st = build(pts, faces, Any[mk(v) for v in eachindex(pts) if deg[v] >= 3])
        nnan = 0
        for col in st.columns, ax in ((1.0, 0.0), (0.0, 1.0))
            M, tc = transfer(st, col; ax = ax)
            if !isfinite(M)
                nnan += 1
                @test has_failure(tc)
            end
        end
        @test nnan > 0
        # Coincident far columns: 12 / 12 / 12.25 in agree (1/4 in, float
        # error allowed); 12 / 12 / 12.5 in are rejected, NaN + :failure.
        pts, faces, V = grid([0.0, 20.0, 50.0], [-20.0, 0.0, 20.0])
        pts2 = vcat(pts, [(50.0, 0.0), (50.0, 0.0)])
        n = length(pts)
        for (c3, ok) in ((12.25, true), (12.5, false))
            cs = Any[mk(V(20.0, 0.0)), mk(V(0.0, 0.0); pos = :edge),
                     mk(V(50.0, 0.0); pos = :edge), mk(n + 1; pos = :edge),
                     mk(n + 2; pos = :edge, c = c3)]
            st = build(pts2, faces, cs)
            tc = TraceCollector()
            _, Mub = quiet(() -> demands(st, cs[1]; tc = tc))
            if ok
                @test Mub ≈ Mub_ref rtol = 1e-9
            else
                @test isnan(Mub)
                @test has_event(tc, :failure, "adjoining_spans_unresolved")
            end
        end
    end
end
