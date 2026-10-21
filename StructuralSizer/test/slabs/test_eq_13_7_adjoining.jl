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
                       columns = [fix.col], axis = (1.0, 0.0), γ = nothing)
    qu = max(1.4 * qD, 1.2 * qD + 1.6 * qL)
    M0 = SS.total_static_moment(qu, l2, max(ln_passed, 1.0u"ft"))
    _, _, Mub = SS._compute_column_demands_ddm(
        fix.struc, columns,
        0.26 * M0, 0.65 * M0, 0.35 * M0,
        qu, qD, qL, l2, ln_passed, axis, M0;
        slab = fix.slab, γ = γ,
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
        mub_nlp = SS._nlp_interior_mub(p, 1, qD_b, qL_b, l2, ln, (1.0, 0.0), 12.0u"inch")
        @test ustrip(kip * u"ft", mub_nlp) ≈ ustrip(kip * u"ft", hand) rtol = 1e-9
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

    @testset "ambiguous same-side panels fail loud" begin
        fix = _two_bay(west_ft = 29.0, east_ft = 20.0, ambiguous_east_ft = 26.0)
        @test_throws ArgumentError _interior_mub(fix, qD, qL)
        err = try
            _interior_mub(fix, qD, qL)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("13.6.9.2", err.msg)
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
        fix = _two_bay(west_ft = 29.0, east_ft = 20.0, ambiguous_east_ft = 26.0)
        r = SS.check_ddm_applicability(fix.struc, fix.slab, [fix.col]; throw_on_failure = false)
        @test any(v -> occursin("13.6.9.2", v), r.violations)
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
        # Empty sides: the column sits on a vertex that no cell uses (a
        # corner moved 1 mm outward onto its own vertex).  A corner position
        # must still be 0.3 M0, and the fallback is a trace event.
        fix = corner(0.0)
        vc = fix.struc.skeleton.geometry.vertex_coords
        vc2 = vcat(vc, [-0.001 -0.001])
        function orphan_at(pos)
            return (vertex_idx = 5, position = pos, c1 = 16.0u"inch",
                    c2 = 16.0u"inch", θ = 0.0, structural_offset = (0.0, 0.0))
        end
        struc = (
            cells = fix.struc.cells, slabs = fix.struc.slabs,
            columns = [orphan_at(:corner)],
            skeleton = (geometry = (vertex_coords = vc2,),
                        face_vertex_indices = fix.struc.skeleton.face_vertex_indices),
        )
        tc = TraceCollector()
        Mub = SS._eq137_transfer_moment(
            struc, fix.slab, orphan_at(:corner), (1.0, 0.0), qD, qL, 24.0u"ft", ln, M0;
            tc = tc,
        )
        @test ustrip(kip * u"ft", Mub) ≈ ustrip(kip * u"ft", edge) rtol = 1e-6
        @test any(e -> e.event_type == :fallback &&
                       get(e.data, "reason", "") == "exterior_no_panel", tc.events)
        # Same orphan vertex tagged :interior: it cannot be shown to be
        # interior, so it is never below 0.3 M0 (ENGINEERING JUDGMENT in
        # `_eq137_transfer_moment`).
        tc = TraceCollector()
        Mub = SS._eq137_transfer_moment(
            struc, fix.slab, orphan_at(:interior), (1.0, 0.0), qD, qL, 24.0u"ft", ln, M0;
            tc = tc,
        )
        @test ustrip(kip * u"ft", Mub) ≈
              max(ustrip(kip * u"ft", edge), ustrip(kip * u"ft", equal)) rtol = 1e-6
        @test any(e -> e.event_type == :fallback &&
                       get(e.data, "reason", "") == "zero_sides", tc.events)
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
        bare = _c5_plan(pts, faces, [:c, :w, :e], :c)
        err = try
            _interior_mub(bare, qD, qL)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("13.6.9.2", err.msg) && occursin("ambiguous", err.msg)
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
                                         (tee, false, M_int, "one_sided_interior_nonconforming"))
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
            # Transfer: max(equal-span, 0.3 M0) is 0.3 M0 for these loads,
            # so only the trace distinguishes the two.
            tc = TraceCollector()
            Mub = SS._eq137_transfer_moment(fix.struc, fix.slab, fix.col, (1.0, 0.0),
                                            qD, qL, 20.0u"ft", 19.0u"ft", M0; tc = tc)
            @test kft(Mub) ≈ kft(0.3 * M0) rtol = 1e-9
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
            _interior_mub((struc = bad, slab = fix.slab, col = fix.col), qD, qL)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("13.6.9.2", err.msg) && occursin("ambiguous", err.msg)
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

