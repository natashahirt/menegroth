# =============================================================================
# Eq. (13-7) fix cycle 4 — regressions on real BuildingStructures
# =============================================================================
#
# ACI 318-11 §13.6.9.2 Eq. (13-7) (corpus: aci-318-11, page 258).
# §13.6.2.3 / §13.6.2.4: ℓ2 is half + half, or edge to panel centerline at
# an edge (corpus: aci-318-11, page 253).  §13.6.2.5 face to face (page 253).
# §13.6.3.3 flexural coefficients (page 254).  §13.6.3.6 edge transfer
# 0.3 M0 (page 255).  §9.2.1 Eq. (9-1) / (9-2) (page 123).
#
# Every oracle here runs on a gen_medium_office BuildingStructure, not a
# duck-typed fixture.  Needs StructuralSynthesizer; skips otherwise.
# =============================================================================

using Test
using Unitful
using Asap
using StructuralSizer

const SS4 = StructuralSizer

const HAS_SYNTH4 = let ok = true
    try
        @eval using StructuralSynthesizer
    catch
        ok = false
    end
    ok
end

kft4(x) = ustrip(kip * u"ft", x)

"""Structural XY (meters) of a column: vertex plus `structural_offset`."""
function _xy4(struc, col)
    vc = struc.skeleton.geometry.vertex_coords
    o = col.structural_offset
    return (vc[col.vertex_idx, 1] + Float64(o[1]), vc[col.vertex_idx, 2] + Float64(o[2]))
end

"""Sorted distinct column-line X and Y (meters)."""
function _lines4(struc, cols)
    xs = sort(unique(round.([_xy4(struc, c)[1] for c in cols], digits = 4)))
    ys = sort(unique(round.([_xy4(struc, c)[2] for c in cols], digits = 4)))
    return xs, ys
end

function _nearest4(struc, cols, x, y)
    _, i = findmin(c -> hypot(_xy4(struc, c)[1] - x, _xy4(struc, c)[2] - y), cols)
    return cols[i]
end

_mub4(res, cols, col) = res.unbalanced_moments[findfirst(c -> c.vertex_idx == col.vertex_idx, cols)]
_mflex4(res, cols, col) = res.column_moments[findfirst(c -> c.vertex_idx == col.vertex_idx, cols)]

const H4 = 8.0u"inch"
const RHO4 = NWC_4000.ρ

"""DDM along the slab primary (X) and secondary (Y) axes at the 8 in trial."""
function _analyze4(struc, slab, cols)
    Ecs = SS4.Ec(NWC_4000)
    mx = SS4.run_moment_analysis(DDM(), struc, slab, cols, H4, NWC_4000.fc′, Ecs, RHO4)
    my = SS4.run_secondary_moment_analysis(DDM(), struc, slab, cols, H4, NWC_4000.fc′, Ecs, RHO4)
    return mx, my
end

"""Service qD = sdl + 8 in self-weight, and qL, from the slab's first cell."""
function _pressures4(struc, slab)
    cell = struc.cells[first(slab.cell_indices)]
    return uconvert(psf, cell.sdl) + SS4.slab_self_weight(H4, RHO4), uconvert(psf, cell.live_load)
end

"""Build an office and return the top-storey slab with its columns."""
function _office4(n_stories::Int; floor_height = 12.0u"ft")
    skel = gen_medium_office(72.0u"ft", 72.0u"ft", floor_height, 3, 3, n_stories)
    struc = BuildingStructure(skel)
    initialize!(struc; material = NWC_4000, floor_type = :flat_plate,
                floor_opts = FlatPlateOptions(method = DDM()))
    vc = struc.skeleton.geometry.vertex_coords
    best = nothing
    best_z = -Inf
    for sl in struc.slabs
        cols = SS4.find_supporting_columns(struc, Set(sl.cell_indices))
        isempty(cols) && continue
        z = size(vc, 2) >= 3 ? maximum(vc[c.vertex_idx, 3] for c in cols) : 0.0
        if z > best_z
            best_z = z
            best = (sl, cols)
        end
    end
    return struc, best[1], best[2], best_z
end

@testset "Eq. (13-7) cycle 4 real-building regressions" begin
    if !HAS_SYNTH4
        @info "Skipping cycle-4 real-building regressions — StructuralSynthesizer not available."
        @test true
    else
        ax = (1.0, 0.0)
        ay = (0.0, 1.0)

        @testset "kept value: one-storey office roof interior 15.513 kip·ft" begin
            struc, slab, cols, _ = _office4(1; floor_height = 9.0u"ft")
            xs, ys = _lines4(struc, cols)
            interior = _nearest4(struc, cols, xs[2], ys[2])
            mx, _ = _analyze4(struc, slab, cols)
            @test kft4(_mub4(mx, cols, interior)) ≈ 15.513 rtol = 1e-3
        end

        @testset "3-storey top slab: interior vertex noise keeps both panels" begin
            # Regression for item 1: ray-cast membership halved this moment
            # when the column vertex sat 1e-12 m .. 0.02 m off the frame line.
            struc, slab, cols, _ = _office4(3)
            xs, ys = _lines4(struc, cols)
            interior = _nearest4(struc, cols, xs[2], ys[2])
            mx0, my0 = _analyze4(struc, slab, cols)
            Mx = kft4(_mub4(mx0, cols, interior))
            My = kft4(_mub4(my0, cols, interior))
            println("TOP_SLAB_INTERIOR Mx=$(round(Mx; digits=3)) My=$(round(My; digits=3))")
            @test Mx > 1.0 && My > 1.0
            vc = struc.skeleton.geometry.vertex_coords
            vi = interior.vertex_idx
            x0, y0 = vc[vi, 1], vc[vi, 2]
            ft = 0.3048
            for d in (1e-12, -1e-12, 1e-6, 1e-3, -1e-3, 0.02, 0.01ft, 0.06ft, 0.1ft, -0.1ft)
                # Perpendicular to the X frame line.
                vc[vi, 2] = y0 + d
                mx, _ = _analyze4(struc, slab, cols)
                got = kft4(_mub4(mx, cols, interior))
                @test got ≈ Mx rtol = 0.02
                @test abs(got - 0.5 * Mx) > 0.4 * Mx
                vc[vi, 2] = y0
                # Perpendicular to the Y frame line.
                vc[vi, 1] = x0 + d
                _, my = _analyze4(struc, slab, cols)
                goty = kft4(_mub4(my, cols, interior))
                @test goty ≈ My rtol = 0.02
                @test abs(goty - 0.5 * My) > 0.4 * My
                vc[vi, 1] = x0
            end
            # Diagonal 1 mm nudge, both directions at once.  The along-axis
            # shift makes the spans differ by 2 mm, so the Eq. (13-7) dead
            # term no longer cancels: 0.07·1.2·qD·ℓ2·(ℓn² − ℓn'²) ≈ 0.07
            # kip·ft here (≈ 0.5 %).  Not a membership change.
            vc[vi, 1] = x0 + 1e-3
            vc[vi, 2] = y0 - 1e-3
            mx, my = _analyze4(struc, slab, cols)
            for (got, ref) in ((kft4(_mub4(mx, cols, interior)), Mx),
                               (kft4(_mub4(my, cols, interior)), My))
                @test got ≈ ref rtol = 0.01
                @test abs(got - 0.5 * ref) > 0.4 * ref
            end
            vc[vi, 1] = x0
            vc[vi, 2] = y0
        end

        @testset "3-storey top slab: alternating ±1 mm along the frame row" begin
            struc, slab, cols, roof_z = _office4(3)
            xs, ys = _lines4(struc, cols)
            interior = _nearest4(struc, cols, xs[2], ys[2])
            mx0, _ = _analyze4(struc, slab, cols)
            M_clean = kft4(_mub4(mx0, cols, interior))
            vc = struc.skeleton.geometry.vertex_coords
            oy = vc[interior.vertex_idx, 2]
            row = [i for i in 1:size(vc, 1)
                   if abs(vc[i, 2] - oy) < 0.05 && abs(vc[i, 3] - roof_z) < 0.05]
            sort!(row; by = i -> vc[i, 1])
            @test length(row) >= 4
            for (k, i) in enumerate(row)
                vc[i, 2] += iseven(k) ? 0.001 : -0.001
            end
            mx, _ = _analyze4(struc, slab, cols)
            got = kft4(_mub4(mx, cols, interior))
            @test got ≈ M_clean rtol = 2e-3
            @test abs(got - 0.5 * M_clean) > 0.4 * M_clean
        end

        @testset "3-storey top slab: far face is the roof column, through DDM" begin
            # Item 4: ground 30 in, middle 24 in, roof 18 in.  Equal bays and
            # loads → Eq. (9-2) leaves 0.07·0.5·(1.6 qL)·ℓ2·ℓn².
            struc, slab, cols, roof_z = _office4(3)
            vc = struc.skeleton.geometry.vertex_coords
            zs = sort(unique(round.([vc[c.vertex_idx, 3] for c in struc.columns], digits = 3)))
            @test length(zs) >= 3
            for col in struc.columns
                z = round(vc[col.vertex_idx, 3], digits = 3)
                s = z == zs[1] ? 30.0u"inch" : z == zs[end] ? 18.0u"inch" : 24.0u"inch"
                col.c1 = s
                col.c2 = s
            end
            cols = SS4.find_supporting_columns(struc, Set(slab.cell_indices))
            xs, ys = _lines4(struc, cols)
            interior = _nearest4(struc, cols, xs[2], ys[2])
            east = _nearest4(struc, cols, xs[3], ys[2])
            north = _nearest4(struc, cols, xs[2], ys[3])
            @test vc[interior.vertex_idx, 3] ≈ roof_z atol = 1e-6
            @test ustrip(u"inch", interior.c1) ≈ 18.0
            qD, qL = _pressures4(struc, slab)
            bay_x = uconvert(u"ft", (_xy4(struc, east)[1] - _xy4(struc, interior)[1]) * u"m")
            ℓ2 = uconvert(u"ft", (_xy4(struc, north)[2] - _xy4(struc, interior)[2]) * u"m")
            ℓn = bay_x - 18.0u"inch"
            ℓn_wrong = bay_x - 9.0u"inch" - 15.0u"inch"
            hand = 0.07 * 0.5 * (1.6 * qL) * ℓ2 * ℓn^2
            wrong = 0.07 * 0.5 * (1.6 * qL) * ℓ2 * ℓn_wrong^2
            mx, _ = _analyze4(struc, slab, cols)
            got = kft4(_mub4(mx, cols, interior))
            println("TOP_SLAB_STACKED code=$(round(got; digits=3)) hand=$(round(kft4(hand); digits=3)) " *
                    "wrong30=$(round(kft4(wrong); digits=3)) ln=$(round(ustrip(u"ft", ℓn); digits=3))")
            @test got ≈ kft4(hand) rtol = 1e-3
            @test abs(got - kft4(wrong)) > 0.01 * kft4(hand)
        end

        @testset "inward-offset edge column: ℓ2 stays edge-to-centerline (DDM and NLP)" begin
            # Item 2: west edge columns inset 1.5 ft (past the 0.35 m band).
            # Along Y (parallel to the edge), ℓ2 = bay_x / 2 per §13.6.2.4.
            struc, slab, cols, _ = _office4(1; floor_height = 9.0u"ft")
            xs, ys = _lines4(struc, cols)
            edge = _nearest4(struc, cols, xs[1], ys[2])
            interior = _nearest4(struc, cols, xs[2], ys[2])
            north = _nearest4(struc, cols, xs[1], ys[3])
            qD, qL = _pressures4(struc, slab)
            bay_x = uconvert(u"ft", (_xy4(struc, interior)[1] - _xy4(struc, edge)[1]) * u"m")
            bay_y = uconvert(u"ft", (_xy4(struc, north)[2] - _xy4(struc, edge)[2]) * u"m")
            # Equal Y bays, equal loads, c unset: Eq. (9-2) live-only term.
            half = 0.07 * 0.5 * (1.6 * qL) * (bay_x / 2) * bay_y^2
            full = 0.07 * 0.5 * (1.6 * qL) * bay_x * bay_y^2
            _, my0 = _analyze4(struc, slab, cols)
            plain = kft4(_mub4(my0, cols, edge))
            @test plain ≈ kft4(half) rtol = 1e-3
            inset = 1.5 * 0.3048
            for col in struc.columns
                if abs(_xy4(struc, col)[1] - xs[1]) < 0.05
                    col.structural_offset = (inset, 0.0)
                end
            end
            cols = SS4.find_supporting_columns(struc, Set(slab.cell_indices))
            edge = first(c for c in cols if c.vertex_idx == edge.vertex_idx)
            @test edge.structural_offset[1] ≈ inset
            _, my1 = _analyze4(struc, slab, cols)
            shifted = kft4(_mub4(my1, cols, edge))
            println("INSET_EDGE plain=$(round(plain; digits=3)) shifted=$(round(shifted; digits=3)) " *
                    "half=$(round(kft4(half); digits=3)) full=$(round(kft4(full); digits=3))")
            @test shifted ≈ plain rtol = 1e-3
            @test abs(shifted - kft4(full)) > 0.4 * kft4(full)
            # Perpendicular to the edge it is still §13.6.3.6.
            mx1, _ = _analyze4(struc, slab, cols)
            @test kft4(_mub4(mx1, cols, edge)) > 0

            # NLP transfer on the same real building, Y axis.
            mat = RC_4000_60
            wc = ustrip(pcf, mat.concrete.ρ)
            ctx = SS4._eq137_context(struc, cols)
            i_edge = findfirst(c -> c.vertex_idx == edge.vertex_idx, cols)
            p = FlatPlateNLPProblem(
                mat, mat.concrete.fc′, mat.rebar.Fy, mat.rebar.E,
                Ec(mat.concrete.fc′, wc), mat.concrete.ρ, mat.concrete.λ,
                bay_y, bay_x, qD - SS4.slab_self_weight(H4, RHO4), qL,
                [c.position for c in cols], fill(100.0, length(cols)), 3.0,
                0.65, 0.70, 0.35,
                0.75u"inch", bar_diameter(5),
                0.90, 0.75, :L_360,
                (6.0, 12.0), (10.0, 24.0),
                [5], MinVolume(),
                (struc = struc, slab = slab, columns = cols, span_axis = ay,
                 index = ctx.index, cell_slab = ctx.cell_slab,
                 vertex_column = ctx.vertex_column),
            )
            M0 = SS4.total_static_moment(1.2 * qD + 1.6 * qL, bay_x, bay_y)
            Mnlp = SS4._nlp_transfer_moment(p, i_edge, qD, qL, bay_x / 2, bay_y,
                                            ay, 0.0u"inch", M0)
            @test kft4(Mnlp) ≈ shifted rtol = 1e-3
            @test abs(kft4(Mnlp) - kft4(full)) > 0.4 * kft4(full)
        end

        @testset "nudged corner/edge vertex is 0.3 M0, never the equal-span value" begin
            # Item 3.  A synthetic grid may tag every column :interior.  Nudge
            # the corner vertex 1 mm outward; also retag it.
            for tag in (:corner, :interior), nudge in (0.0, 0.001, -0.001)
                struc, slab, cols, _ = _office4(1; floor_height = 9.0u"ft")
                xs, ys = _lines4(struc, cols)
                corner = _nearest4(struc, cols, xs[1], ys[1])
                edge = _nearest4(struc, cols, xs[1], ys[2])
                corner.position = tag
                # A synthetic grid's :interior tag comes without boundary
                # directions, so `is_exterior_support` falls back to the tag.
                tag == :interior && empty!(corner.boundary_edge_dirs)
                vc = struc.skeleton.geometry.vertex_coords
                vc[corner.vertex_idx, 1] -= nudge
                vc[corner.vertex_idx, 2] -= nudge
                vc[edge.vertex_idx, 1] -= nudge
                qD, qL = _pressures4(struc, slab)
                qu = max(1.2 * qD + 1.6 * qL, 1.4 * qD)
                l1 = uconvert(u"ft", slab.spans.primary)
                l2 = uconvert(u"ft", slab.spans.secondary)
                M0x = uconvert(kip * u"ft", qu * l2 * l1^2 / 8)   # Eq. (13-4), c unset
                M0y = uconvert(kip * u"ft", qu * l1 * l2^2 / 8)
                eq_x = SS4.governing_interior_unbalanced_moment(qD, qL, l2, l1, qD, qL, l2, l1)
                mx, my = _analyze4(struc, slab, cols)
                @test kft4(_mub4(mx, cols, corner)) ≈ kft4(0.3 * M0x) rtol = 1e-3
                @test kft4(_mub4(my, cols, corner)) ≈ kft4(0.3 * M0y) rtol = 1e-3
                @test abs(kft4(_mub4(mx, cols, corner)) - kft4(eq_x)) > 10.0
                # West edge perpendicular (X) is also §13.6.3.6.
                @test kft4(_mub4(mx, cols, edge)) ≈ kft4(0.3 * M0x) rtol = 1e-3
                # Flexural: exterior-negative at the corner both ways.
                @test kft4(_mflex4(mx, cols, corner)) ≈ kft4(mx.M_neg_ext) rtol = 1e-9
                @test kft4(_mflex4(my, cols, corner)) ≈ kft4(my.M_neg_ext) rtol = 1e-9
                if tag == :interior
                    # Reclassification away from the tag is a trace event.
                    tc = TraceCollector()
                    SS4._eq137_transfer_moment(struc, slab, corner, ax, qD, qL, l2, l1, M0x;
                                               extra_columns = cols, γ = RHO4, tc = tc)
                    @test any(e -> e.event_type == :fallback &&
                                   get(e.data, "reason", "") == "one_sided_interior", tc.events)
                else
                    # Boundary directions classify it; no fallback is taken.
                    tc = TraceCollector()
                    SS4._eq137_transfer_moment(struc, slab, corner, ax, qD, qL, l2, l1, M0x;
                                               extra_columns = cols, γ = RHO4, tc = tc)
                    @test !any(e -> e.event_type == :fallback, tc.events)
                end
            end
        end

        @testset "precomputed maps equal scanning on every column, both axes" begin
            # Item 6, on the 3-storey top slab with sized columns and a
            # neighbour drop panel, so every map is exercised.
            struc, slab, cols, _ = _office4(3)
            for col in struc.columns
                col.c1 = 20.0u"inch"
                col.c2 = 20.0u"inch"
            end
            cols = SS4.find_supporting_columns(struc, Set(slab.cell_indices))
            qD, qL = _pressures4(struc, slab)
            l1 = uconvert(u"ft", slab.spans.primary)
            l2 = uconvert(u"ft", slab.spans.secondary)
            M0 = SS4.total_static_moment(1.2 * qD + 1.6 * qL, l2, l1)
            ctx = SS4._eq137_context(struc, cols)
            n = 0
            for col in cols, axis in (ax, ay)
                direct = SS4._eq137_transfer_moment(struc, slab, col, axis, qD, qL, l2, l1, M0;
                                                    extra_columns = cols, γ = RHO4)
                cached = SS4._eq137_transfer_moment(struc, slab, col, axis, qD, qL, l2, l1, M0;
                                                    extra_columns = cols, γ = RHO4,
                                                    index = ctx.index,
                                                    vertex_column = ctx.vertex_column,
                                                    cell_slab = ctx.cell_slab)
                @test kft4(cached) == kft4(direct)
                Md = SS4._ddm_support_moment(struc, col, axis, 1.0kip * u"ft", 2.0kip * u"ft")
                Mc = SS4._ddm_support_moment(struc, col, axis, 1.0kip * u"ft", 2.0kip * u"ft";
                                             index = ctx.index)
                @test Mc == Md
                n += 1
            end
            @test n == 2 * length(cols)
        end

        @testset "NLP flexural support moment matches DDM on every column" begin
            # Item 7, §13.6.3.3 (page 254).
            struc, slab, cols, _ = _office4(1; floor_height = 9.0u"ft")
            xs, ys = _lines4(struc, cols)
            mat = RC_4000_60
            wc = ustrip(pcf, mat.concrete.ρ)
            ctx = SS4._eq137_context(struc, cols)
            qD, qL = _pressures4(struc, slab)
            p = FlatPlateNLPProblem(
                mat, mat.concrete.fc′, mat.rebar.Fy, mat.rebar.E,
                Ec(mat.concrete.fc′, wc), mat.concrete.ρ, mat.concrete.λ,
                24.0u"ft", 24.0u"ft", qD, qL,
                [c.position for c in cols], fill(100.0, length(cols)), 3.0,
                0.65, 0.70, 0.35,
                0.75u"inch", bar_diameter(5),
                0.90, 0.75, :L_360,
                (6.0, 12.0), (10.0, 24.0),
                [5], MinVolume(),
                (struc = struc, slab = slab, columns = cols, span_axis = ax,
                 index = ctx.index, cell_slab = ctx.cell_slab,
                 vertex_column = ctx.vertex_column),
            )
            Mext = 65.0kip * u"ft"
            Mint = 70.0kip * u"ft"
            for (i, col) in enumerate(cols), axis in (ax, ay)
                @test SS4._nlp_support_moment(p, i, axis, Mext, Mint) ==
                      SS4._ddm_support_moment(struc, col, axis, Mext, Mint)
            end
            edge = _nearest4(struc, cols, xs[1], ys[2])
            ie = findfirst(c -> c.vertex_idx == edge.vertex_idx, cols)
            @test SS4._nlp_support_moment(p, ie, ax, Mext, Mint) == Mext   # perpendicular
            @test SS4._nlp_support_moment(p, ie, ay, Mext, Mint) == Mint   # along the edge
            corner = _nearest4(struc, cols, xs[1], ys[1])
            ic = findfirst(c -> c.vertex_idx == corner.vertex_idx, cols)
            @test SS4._nlp_support_moment(p, ic, ax, Mext, Mint) == Mext
            @test SS4._nlp_support_moment(p, ic, ay, Mext, Mint) == Mext
        end
    end
end
