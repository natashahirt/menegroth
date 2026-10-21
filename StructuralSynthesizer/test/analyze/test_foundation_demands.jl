# Foundation demand safety: signed uplift and unfactored D+L service reactions.
# ACI 318-11 §15.8.1.2 (corpus: aci-318-11, page 275)
# ASCE 7-16 §2.3.1 / §2.4.1 (corpus: asce-7-16, pages 62–64)

using Test
using Unitful
using Asap

using StructuralSynthesizer
using StructuralSizer

function _make_foundation_plate(; sdl=100.0u"psf", ll=20.0u"psf")
    skel = gen_medium_office(40.0u"ft", 40.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    opts = FlatPlateOptions(
        material = RC_4000_60,
        method   = DDM(),
        cover    = 0.75u"inch",
        bar_size = 5,
    )
    initialize!(struc; floor_type=:flat_plate, floor_opts=opts)
    for cell in struc.cells
        cell.sdl       = uconvert(u"kN/m^2", sdl)
        cell.live_load = uconvert(u"kN/m^2", ll)
    end
    for col in struc.columns
        col.c1 = 16.0u"inch"
        col.c2 = 16.0u"inch"
    end
    return struc
end

"""Axis-aligned support pair at `target` spacing, ordered by coordinate."""
function _axis_pair_at_spacing(struc, target=20.0u"ft")
    model = struc.asap_model
    n = length(struc.supports)
    tgt = ustrip(u"ft", target)
    for a in 1:n, b in (a + 1):n
        pa = model.nodes[struc.supports[a].node_idx].position
        pb = model.nodes[struc.supports[b].node_idx].position
        dx = ustrip(u"ft", pa[1] - pb[1])
        dy = ustrip(u"ft", pa[2] - pb[2])
        dist = hypot(dx, dy)
        axis_aligned = abs(dx) < 0.5 || abs(dy) < 0.5
        (abs(dist - tgt) < 0.5 && axis_aligned) || continue
        if abs(dx) >= abs(dy)
            return dx <= 0 ? (a, b) : (b, a)
        else
            return dy <= 0 ? (a, b) : (b, a)
        end
    end
    error("no axis-aligned support pair at $target")
end

"""Y-aligned support pair at `target` spacing, southern support first."""
function _y_pair_at_spacing(struc, target=20.0u"ft")
    model = struc.asap_model
    n = length(struc.supports)
    tgt = ustrip(u"ft", target)
    for a in 1:n, b in (a + 1):n
        pa = model.nodes[struc.supports[a].node_idx].position
        pb = model.nodes[struc.supports[b].node_idx].position
        dx = ustrip(u"ft", pa[1] - pb[1])
        dy = ustrip(u"ft", pa[2] - pb[2])
        dist = hypot(dx, dy)
        (abs(dist - tgt) < 0.5 && abs(dy) > abs(dx)) || continue
        return dy <= 0 ? (a, b) : (b, a)
    end
    error("no Y-aligned support pair at $target")
end

"""Diagonal support pair at `target` × `target` (square bounding box)."""
function _diagonal_pair(struc, target=20.0u"ft")
    model = struc.asap_model
    n = length(struc.supports)
    tgt = ustrip(u"ft", target)
    for a in 1:n, b in (a + 1):n
        pa = model.nodes[struc.supports[a].node_idx].position
        pb = model.nodes[struc.supports[b].node_idx].position
        dx = abs(ustrip(u"ft", pa[1] - pb[1]))
        dy = abs(ustrip(u"ft", pa[2] - pb[2]))
        (abs(dx - tgt) < 0.5 && abs(dy - tgt) < 0.5) || continue
        return (a, b)
    end
    error("no diagonal support pair at $target")
end

@testset "Foundation signed demands and service D+L" begin

    @testset "Uplift is flagged; signed Pu stays tension" begin
        d = StructuralSynthesizer._foundation_demand_from_signed(
            1, -10.0u"kN", -4.0u"kN", 0.0u"kN", 0.0u"kN", 0.0u"kN*m", 0.0u"kN*m";
            c1=18.0u"inch", c2=18.0u"inch", shape=:rectangular)
        @test d.uplift
        @test d.Pu == -10.0u"kN"
        @test d.Ps == -4.0u"kN"
    end

    @testset "Compression keeps signed Pu; Ps is not Pu/1.4" begin
        d = StructuralSynthesizer._foundation_demand_from_signed(
            1, 140.0u"kN", 110.0u"kN", 0.0u"kN", 0.0u"kN", 0.0u"kN*m", 0.0u"kN*m";
            c1=18.0u"inch", c2=18.0u"inch", shape=:rectangular)
        @test !d.uplift
        @test d.Pu == 140.0u"kN"
        @test d.Ps == 110.0u"kN"
        @test d.Ps != d.Pu / 1.4
    end

    @testset "support_demands uses unfactored D+L when dead dominates" begin
        struc = _make_foundation_plate(sdl=100.0u"psf", ll=20.0u"psf")
        params = DesignParameters(pattern_loading = :none)
        to_asap!(struc; params)
        sync_asap!(struc; params)
        u_before = copy(struc.asap_model.u)
        initialize_supports!(struc)

        demands = support_demands(struc)
        @test struc.asap_model.u == u_before
        @test !isempty(demands)
        @test all(d -> !d.uplift, demands)
        @test all(d -> d.Pu > 0u"kN", demands)
        @test all(d -> d.Ps > 0u"kN", demands)
        # ASCE 7-16 §2.3.1 strength 1.2D+1.6L vs §2.4.1 D+L: Pu/1.4 underestimates
        # D+L when dead dominates (corpus: asce-7-16, pages 62–64).
        @test all(d -> d.Ps > d.Pu / 1.4, demands)
    end

    @testset "Compression footing is skipped on uplift" begin
        struc = _make_foundation_plate()
        params = DesignParameters(pattern_loading = :none)
        to_asap!(struc; params)
        sync_asap!(struc; params)
        initialize_supports!(struc)
        initialize_foundations!(struc)
        demands = support_demands(struc)
        @test !isempty(demands)
        uplift_demands = [StructuralSizer.FoundationDemand(d.group_idx;
            Pu=0.0u"kN", Mux=d.Mux, Muy=d.Muy, Vux=d.Vux, Vuy=d.Vuy,
            Ps=0.0u"kN", c1=d.c1, c2=d.c2, shape=d.shape, uplift=true)
            for d in demands]
        fnd = struc.foundations[1]
        n_supp = length(fnd.support_indices)
        soil = StructuralSizer.medium_sand
        opts = StructuralSizer.FoundationOptions()
        StructuralSynthesizer._size_fnd_aci!(struc, 1, fnd, n_supp, uplift_demands, soil, opts)
        r = struc.foundations[1].result
        @test StructuralSizer.footing_width(r) == 0.0u"m"
    end

    @testset "Ps equals independent unfactored D+L reaction, not Pu/1.4" begin
        # Oracle: extra service solve (ASCE 7-16 §2.4.1 D+L), not back-solved Pu/1.4.
        struc = _make_foundation_plate(sdl=100.0u"psf", ll=20.0u"psf")
        params = DesignParameters(pattern_loading = :none)
        to_asap!(struc; params)
        sync_asap!(struc; params)
        u_before = copy(struc.asap_model.u)
        initialize_supports!(struc)
        demands = support_demands(struc)
        @test struc.asap_model.u == u_before
        @test all(d -> !d.uplift, demands)
        @test all(d -> d.Ps != d.Pu / 1.4, demands)
        @test all(d -> d.Ps > d.Pu / 1.4, demands)

        model = struc.asap_model
        orig_loads = model.loads
        loads_s = StructuralSynthesizer._unfactored_DL_loads(struc)
        @test !isempty(loads_s)
        Asap.solve!(model, loads_s)
        for (i, supp) in enumerate(struc.supports)
            Fz_s = uconvert(u"kN", model.nodes[supp.node_idx].reaction[3])
            @test Fz_s > 0u"kN"
            @test demands[i].Ps ≈ Fz_s atol=1e-6u"kN"
        end
        # Restore factored solve so later assertions can reuse the model if needed.
        Asap.solve!(model, orig_loads)
        @test model.u == u_before
    end

    @testset "Uplift reaction from analysis is flagged and not designed" begin
        # Oracle: a real tensile support reaction is flagged; compression
        # footing sizing is skipped (ACI 318-11 §15.8.1.2).
        struc = _make_foundation_plate(sdl=20.0u"psf", ll=20.0u"psf")
        params = DesignParameters(pattern_loading = :none)
        to_asap!(struc; params)
        sync_asap!(struc; params)
        model = struc.asap_model
        roof = findall(n -> ustrip(u"m", n.position[3]) > 1.0, model.nodes)
        @test !isempty(roof)
        Fup = Asap.NodeForce(model.nodes[roof[1]], [0.0u"kN", 0.0u"kN", 2000.0u"kN"])
        Asap.solve!(model, Asap.AbstractLoad[model.loads; Fup])
        initialize_supports!(struc)
        demands = support_demands(struc)
        uplift_idxs = findall(d -> d.uplift, demands)
        @test !isempty(uplift_idxs)
        for i in uplift_idxs
            @test demands[i].Pu < 0.0u"kN"
            @test struc.supports[i].forces[3] < 0.0u"kN"
        end

        initialize_foundations!(struc)
        i = first(uplift_idxs)
        fnd = struc.foundations[i]
        soil = StructuralSizer.medium_sand
        opts = StructuralSizer.FoundationOptions()
        StructuralSynthesizer._size_fnd_aci!(
            struc, i, fnd, length(fnd.support_indices), demands, soil, opts)
        @test StructuralSizer.footing_width(struc.foundations[i].result) == 0.0u"m"
    end

    @testset "Grouped strip keeps signed couple; x_bar is not on the compression column" begin
        # +400 kN / −200 kN, 20 ft. Zeroing tension (max(Ps,0)) parks x_bar
        # on column 1 and yields L = 2×(20+1) = 42 ft. Signed Ps puts the
        # resultant 20 ft *outside* the compression column via the existing
        # x_bar = Σ(Ps·x)/ΣPs and yields L = 2×(20−(−20)+1) = 82 ft
        # (ACI 318-11 §15.8.1.2, corpus: aci-318-11, page 275).
        d1 = StructuralSynthesizer._foundation_demand_from_signed(
            1, 400.0u"kN", 400.0u"kN", 0.0u"kN", 0.0u"kN", 0.0u"kN*m", 0.0u"kN*m";
            c1=18.0u"inch", c2=18.0u"inch", shape=:rectangular)
        d2 = StructuralSynthesizer._foundation_demand_from_signed(
            2, -200.0u"kN", -200.0u"kN", 0.0u"kN", 0.0u"kN", 0.0u"kN*m", 0.0u"kN*m";
            c1=18.0u"inch", c2=18.0u"inch", shape=:rectangular)
        @test !d1.uplift
        @test d2.uplift
        @test d1.Pu == 400.0u"kN"
        @test d2.Pu == -200.0u"kN"
        @test d2.Ps == -200.0u"kN"

        positions = [0.0u"ft", 20.0u"ft"]
        x_bar_signed = (d1.Ps * positions[1] + d2.Ps * positions[2]) / (d1.Ps + d2.Ps)
        Ps_zeroed = [max(d1.Ps, zero(d1.Ps)), max(d2.Ps, zero(d2.Ps))]
        x_bar_zeroed = sum(Ps_zeroed .* positions) / sum(Ps_zeroed)
        # Zeroed-tension resultant sits ON the compression column; signed does not.
        @test x_bar_zeroed ≈ 0.0u"ft"
        @test x_bar_signed ≈ -20.0u"ft"
        @test x_bar_signed != x_bar_zeroed
        @test x_bar_signed < positions[1]  # outside the compression column

        # Same plan-length formula design_footing uses (1 ft overhang each side
        # of the farther column, then 2× the governing half).
        L_from_xbar(x) = 2 * max(x - positions[1] + 1.0u"ft",
                                 positions[2] - x + 1.0u"ft")
        L_zeroed = L_from_xbar(x_bar_zeroed)
        L_signed = L_from_xbar(x_bar_signed)
        @test L_zeroed ≈ 42.0u"ft"
        @test L_signed ≈ 82.0u"ft"

        soil = StructuralSizer.Soil(50.0u"ksf", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
        opts = StructuralSizer.StripParams(min_depth=12.0u"inch")
        result = StructuralSizer.design_footing(
            StructuralSizer.StripFooting(), [d1, d2], positions, soil; opts)
        # design_footing must have used signed x_bar, not the zeroed-tension layout.
        @test result.L_ftg ≈ L_signed atol=opts.width_increment
        @test result.L_ftg != L_zeroed
        @test result.L_ftg > 50.0u"ft"
        # Leftover: tensile interface steel is stored, not @info-only
        # (ACI 318-11 §15.8.1.2(b), corpus: aci-318-11, page 275).
        As_tensile_oracle = abs(d2.Pu) / (opts.ϕ_bearing * opts.material.rebar.Fy)
        @test result.As_tensile ≈ uconvert(u"m^2", As_tensile_oracle) rtol=1e-8

        # Isolated all-uplift still skips; a mixed-sign group must not.
        @test StructuralSynthesizer._all_uplift([d2, d2], [1, 2])
        @test !StructuralSynthesizer._all_uplift([d1, d2], [1, 2])
    end

    @testset "size_foundations_grouped! routes mixed-sign couple to StripFooting" begin
        # P0: groupings=[[i,j]], +400/−200 kN at 20 ft must not net to
        # SpreadFooting. Test calls size_foundations_grouped! (ACI 318-11
        # §15.10.1 / §15.8.1.2, corpus: aci-318-11, pages 277 / 275).
        struc = _make_foundation_plate()
        params = DesignParameters(pattern_loading = :none)
        to_asap!(struc; params)
        sync_asap!(struc; params)
        initialize_supports!(struc)
        i, j = _axis_pair_at_spacing(struc, 20.0u"ft")
        initialize_foundations!(struc; groupings=[[i, j]])
        @test length(struc.foundations) == 1
        @test struc.foundations[1].support_indices == [i, j]

        demands = support_demands(struc)
        demands[i] = StructuralSynthesizer._foundation_demand_from_signed(
            i, 400.0u"kN", 400.0u"kN", 0.0u"kN", 0.0u"kN", 0.0u"kN*m", 0.0u"kN*m";
            c1=18.0u"inch", c2=18.0u"inch", shape=:rectangular)
        demands[j] = StructuralSynthesizer._foundation_demand_from_signed(
            j, -200.0u"kN", -200.0u"kN", 0.0u"kN", 0.0u"kN", 0.0u"kN*m", 0.0u"kN*m";
            c1=18.0u"inch", c2=18.0u"inch", shape=:rectangular)

        soil = StructuralSizer.Soil(50.0u"ksf", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
        opts = StructuralSizer.FoundationOptions()
        size_foundations_grouped!(struc; soil=soil, opts=opts, demands=demands)

        r = struc.foundations[1].result
        @test r isa StructuralSizer.StripFootingResult
        @test !(r isa StructuralSizer.SpreadFootingResult)
        @test struc.foundations[1].foundation_type == :strip
        # Expected L from signed x_bar on the actual support axis (may be a
        # few inches off 20 ft after column offsets). Zeroed tension parks
        # x_bar on the compression column → L ≈ 2×(span+1) ≈ 42 ft.
        positions = StructuralSynthesizer._support_positions_along_axis(struc, [i, j])
        x_bar = (demands[i].Ps * positions[1] + demands[j].Ps * positions[2]) /
                (demands[i].Ps + demands[j].Ps)
        L_signed = 2 * max(x_bar - minimum(positions) + 1.0u"ft",
                           maximum(positions) - x_bar + 1.0u"ft")
        w_incr = opts.strip_params.width_increment
        L_signed = ceil(ustrip(u"inch", L_signed) / ustrip(u"inch", w_incr)) * w_incr
        L_zeroed = 2 * (maximum(positions) - minimum(positions) + 1.0u"ft")
        @test r.L_ftg ≈ uconvert(u"m", L_signed) atol=w_incr
        @test r.L_ftg != uconvert(u"m", L_zeroed)
        @test r.L_ftg > 50.0u"ft"
        @test r.n_columns == 2

        # Netted-spread oracle: 400 + (−200) = 200 kN as one isolated
        # SpreadFooting. Grouped sizing must not produce that square.
        netted = StructuralSynthesizer._foundation_demand_from_signed(
            1, 200.0u"kN", 200.0u"kN", 0.0u"kN", 0.0u"kN", 0.0u"kN*m", 0.0u"kN*m";
            c1=18.0u"inch", c2=18.0u"inch", shape=:rectangular)
        spread_200 = StructuralSizer.design_footing(
            StructuralSizer.SpreadFooting(), netted, soil; opts=opts.spread_params)
        @test spread_200 isa StructuralSizer.SpreadFootingResult
        @test r.L_ftg != spread_200.L_ftg
        @test r.L_ftg > 10 * spread_200.L_ftg
    end

    @testset "size_foundations! preserves groupings=[[i,j]]" begin
        struc = _make_foundation_plate()
        params = DesignParameters(pattern_loading = :none)
        to_asap!(struc; params)
        sync_asap!(struc; params)
        initialize_supports!(struc)
        i, j = _axis_pair_at_spacing(struc, 20.0u"ft")
        initialize_foundations!(struc; groupings=[[i, j]])
        @test length(struc.foundations) == 1
        @test struc.foundations[1].support_indices == [i, j]

        demands = support_demands(struc)
        demands[i] = StructuralSynthesizer._foundation_demand_from_signed(
            i, 400.0u"kN", 400.0u"kN", 0.0u"kN", 0.0u"kN", 0.0u"kN*m", 0.0u"kN*m";
            c1=18.0u"inch", c2=18.0u"inch", shape=:rectangular)
        demands[j] = StructuralSynthesizer._foundation_demand_from_signed(
            j, -200.0u"kN", -200.0u"kN", 0.0u"kN", 0.0u"kN", 0.0u"kN*m", 0.0u"kN*m";
            c1=18.0u"inch", c2=18.0u"inch", shape=:rectangular)

        soil = StructuralSizer.Soil(50.0u"ksf", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
        opts = StructuralSizer.FoundationOptions()
        size_foundations!(struc; soil=soil, opts=opts, demands=demands, verbose=false)

        @test length(struc.foundations) == 1
        @test struc.foundations[1].support_indices == [i, j]
        @test struc.foundations[1].result isa StructuralSizer.StripFootingResult
        @test struc.foundations[1].result.L_ftg > 50.0u"ft"
    end

    @testset "_auto_merge_to_strips! keeps the tension support" begin
        struc = _make_foundation_plate()
        params = DesignParameters(pattern_loading = :none)
        to_asap!(struc; params)
        sync_asap!(struc; params)
        initialize_supports!(struc)
        i, j = _axis_pair_at_spacing(struc, 20.0u"ft")
        initialize_foundations!(struc)

        demands = support_demands(struc)
        demands[i] = StructuralSynthesizer._foundation_demand_from_signed(
            i, 400.0u"kN", 400.0u"kN", 0.0u"kN", 0.0u"kN", 0.0u"kN*m", 0.0u"kN*m";
            c1=18.0u"inch", c2=18.0u"inch", shape=:rectangular)
        demands[j] = StructuralSynthesizer._foundation_demand_from_signed(
            j, -200.0u"kN", -200.0u"kN", 0.0u"kN", 0.0u"kN", 0.0u"kN*m", 0.0u"kN*m";
            c1=18.0u"inch", c2=18.0u"inch", shape=:rectangular)

        soil = StructuralSizer.Soil(50.0u"ksf", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
        opts = StructuralSizer.FoundationOptions(
            strip_params = StructuralSizer.StripParams(merge_gap_factor=1e6))
        StructuralSynthesizer._auto_merge_to_strips!(struc, demands, soil, opts)

        in_strip = any(f -> j in f.support_indices && length(f.support_indices) > 1,
                       struc.foundations)
        @test in_strip
    end

    @testset "P0: _size_fnd_aci! passes Y-strip strip_axis (24×12 at 20 ft)" begin
        # Columns at (0, 0) / (0, 20 ft): Δy > Δx → :y. Named c1=24 in (∥ X),
        # c2=12 in (∥ Y). Default strip_axis=:x used ACI c1=24 // the free
        # end and Ac=(24+d/2)×(12+d)=896 in² at d=16 in. Correct :c1 swap:
        # Ac=(12+d/2)×(24+d)=800 in² (ACI 318-11 §11.11.1.2 / R11.11.7.2,
        # corpus: aci-318-11, pages 200, 209–211).
        struc = _make_foundation_plate()
        params = DesignParameters(pattern_loading = :none)
        to_asap!(struc; params)
        sync_asap!(struc; params)
        initialize_supports!(struc)
        i, j = _y_pair_at_spacing(struc, 20.0u"ft")
        initialize_foundations!(struc; groupings=[[i, j]])
        @test StructuralSynthesizer._support_strip_axis(struc, [i, j]) === :y

        c1 = 24.0u"inch"
        c2 = 12.0u"inch"
        d_bug = 16.0u"inch"
        edge_par = StructuralSizer._strip_free_edge_parallel(:y)
        @test edge_par === :c1
        Ac_y = StructuralSizer._strip_edge_Ac(c1, c2, d_bug, true, edge_par)
        Ac_x = StructuralSizer._strip_edge_Ac(c1, c2, d_bug, true, :c2)
        @test ustrip(u"inch^2", Ac_y) ≈ 800 rtol=1e-12
        @test ustrip(u"inch^2", Ac_x) ≈ 896 rtol=1e-12

        demands = support_demands(struc)
        for k in (i, j)
            demands[k] = StructuralSynthesizer._foundation_demand_from_signed(
                k, 400.0u"kN", 400.0u"kN", 0.0u"kN", 0.0u"kN",
                80.0u"kN*m", 10.0u"kN*m";
                c1=c1, c2=c2, shape=:rectangular)
        end
        # min_depth so d > 1 ft overhang → first column is a free-end edge.
        soil = StructuralSizer.Soil(50.0u"ksf", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
        opts = StructuralSizer.FoundationOptions(
            strip_params = StructuralSizer.StripParams(min_depth=20.0u"inch"))
        fnd = struc.foundations[1]
        StructuralSynthesizer._size_fnd_aci!(
            struc, 1, fnd, length(fnd.support_indices), demands, soil, opts)
        r_prod = struc.foundations[1].result
        @test r_prod isa StructuralSizer.StripFootingResult

        positions = StructuralSynthesizer._support_positions_along_axis(struc, [i, j])
        strip_demands = [demands[i], demands[j]]
        r_y = StructuralSizer.design_footing(
            StructuralSizer.StripFooting(), strip_demands, positions, soil;
            opts=opts.strip_params, strip_axis=:y)
        r_x = StructuralSizer.design_footing(
            StructuralSizer.StripFooting(), strip_demands, positions, soil;
            opts=opts.strip_params, strip_axis=:x)
        @test r_prod.D ≈ r_y.D rtol=1e-12
        @test r_prod.B ≈ r_y.B rtol=1e-12
        @test r_prod.L_ftg ≈ r_y.L_ftg rtol=1e-12
        @test r_prod.utilization ≈ r_y.utilization rtol=1e-12
        @test r_y.utilization != r_x.utilization || r_y.D != r_x.D
    end

    @testset "leftover: Δx=Δy sizes both axes and does not default to :x" begin
        # SI-ulp floor is 1e-12 m (not a construction tolerance).
        Δ20 = ustrip(u"m", 20.0u"ft")
        @test StructuralSynthesizer._strip_spans_tied(Δ20, Δ20)
        # 5e-13 m is inside the 1e-12 m SI-ulp floor. Do not use `x + 1e-12`:
        # Float64 rounding of that sum can exceed the exclusive `<= 1e-12` bound.
        @test StructuralSynthesizer._strip_spans_tied(6.0, 6.0 + 5e-13)
        @test StructuralSynthesizer._strip_spans_tied(Δ20, nextfloat(Δ20))
        @test !StructuralSynthesizer._strip_spans_tied(Δ20, Δ20 + 0.0254)  # 1 inch

        struc = _make_foundation_plate()
        params = DesignParameters(pattern_loading = :none)
        to_asap!(struc; params)
        sync_asap!(struc; params)
        initialize_supports!(struc)
        i, j = _diagonal_pair(struc, 20.0u"ft")
        Δx, Δy = StructuralSynthesizer._support_span_xy_m(struc, [i, j])
        @test StructuralSynthesizer._strip_spans_tied(Δx, Δy)
        @test StructuralSynthesizer._support_strip_axes(struc, [i, j]) == [:x, :y]
        @test_throws ArgumentError StructuralSynthesizer._support_strip_axis(
            struc, [i, j])

        initialize_foundations!(struc; groupings=[[i, j]])
        c1 = 24.0u"inch"
        c2 = 12.0u"inch"
        demands = support_demands(struc)
        for k in (i, j)
            demands[k] = StructuralSynthesizer._foundation_demand_from_signed(
                k, 400.0u"kN", 400.0u"kN", 0.0u"kN", 0.0u"kN",
                0.0u"kN*m", 0.0u"kN*m";
                c1=c1, c2=c2, shape=:rectangular)
        end
        soil = StructuralSizer.Soil(50.0u"ksf", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
        opts = StructuralSizer.FoundationOptions(
            strip_params = StructuralSizer.StripParams(min_depth=12.0u"inch"))
        StructuralSynthesizer._size_fnd_aci!(
            struc, 1, struc.foundations[1], 2, demands, soil, opts)
        r_prod = struc.foundations[1].result

        pos_x = StructuralSynthesizer._support_positions_along_axis(struc, [i, j], :x)
        pos_y = StructuralSynthesizer._support_positions_along_axis(struc, [i, j], :y)
        strip_demands = [demands[i], demands[j]]
        r_x = StructuralSizer.design_footing(
            StructuralSizer.StripFooting(), strip_demands, pos_x, soil;
            opts=opts.strip_params, strip_axis=:x)
        r_y = StructuralSizer.design_footing(
            StructuralSizer.StripFooting(), strip_demands, pos_y, soil;
            opts=opts.strip_params, strip_axis=:y)
        r_gov = StructuralSynthesizer._governing_strip_result([r_x, r_y])
        @test r_prod.utilization ≈ r_gov.utilization rtol=1e-12
        @test r_prod.D ≈ r_gov.D rtol=1e-12
        # 24×12 faces make the two axes disagree — governing is not a silent :x.
        @test r_x.utilization != r_y.utilization || r_x.D != r_y.D
        ux, uy = StructuralSizer.utilization(r_x), StructuralSizer.utilization(r_y)
        @test StructuralSizer.utilization(r_gov) ≥ max(ux, uy) - 1e-12
    end
end
