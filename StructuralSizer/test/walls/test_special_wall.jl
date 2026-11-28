# ACI 318-19 §18.10.6.1 (corpus: aci-318-19, page 326).
# One edge is evaluated by §18.10.6.2 or by §18.10.6.3. §18.10.6.4 follows
# only when an element is required, and §18.10.6.5 follows only when it is not.

using Test
using Unitful
using StructuralSizer

# A wall that qualifies for §18.10.6.2 and whose zero displacement still
# trips Eq. (18.10.6.2a) through the 0.005 floor. c = 25 in. on ℓw = 100 in.
# gives ℓw/(600 c) = 0.006667, and 1.5 × 0.005 = 0.0075.
function _qualifying(; c = 25.0u"inch", δu = 0.0u"inch", b = 30.0u"inch",
                    Mu = 100.0u"kip*ft", Vu = 10.0u"kip", kwargs...)
    return special_boundary_composer(;
        lw = 100.0u"inch", hwcs = 200.0u"inch", hw = 200.0u"inch",
        continuous = true, single_critical_section = true,
        c = c, δu = δu, b = b, hu = 160.0u"inch",
        Mu = Mu, Vu = Vu, Ve = 10.0u"kip",
        fc = 4.0u"ksi", Acv = 1000.0u"inch^2",
        kwargs...)
end

@testset "NEHRP non-flanged end: the width shortcut governs and the drift is not run" begin
    # NEHRP 2020 Design Examples Vol. 1, PDF pages 156–158.
    # ℓw 164 in., hwcs 2811 in., δu 26.84 in., c 95 in., b 26 in., hu 158 in.,
    # Mu 24,976 kip·ft, Vu 576 kip. Critical section at the base, so hw = hwcs.
    lw = 164.0u"inch"
    out = special_boundary_composer(;
        lw = lw, hwcs = 2811.0u"inch", hw = 2811.0u"inch",
        continuous = true, single_critical_section = true,
        c = 95.0u"inch", δu = 26.84u"inch", b = 26.0u"inch", hu = 158.0u"inch",
        Mu = 24976.0u"kip*ft", Vu = 576.0u"kip", Ve = 576.0u"kip",
        fc = 5.0u"ksi", Acv = (26.0 * 164.0) * u"inch^2",
        # A high stress must not pull this wall onto §18.10.6.3.
        σ = 5.0u"ksi",
        in_compression = false)

    @test out.route === :displacement
    @test out.slender
    @test out.required
    @test out.required_by === :displacement
    @test out.stress === nothing
    @test out.edge === nothing
    @test out.trigger.required

    # ℓw = 164 in. Mu/(4 Vu) = 10.84 ft = 130.1 in. The length governs.
    @test out.extension_by == (:length,)
    @test out.extension.extension ≈ lw
    @test out.extension.from_shear < lw
    @test out.extension.from_shear ≈ (24976.0u"kip*ft" / 576.0u"kip") / 4

    # c − 0.1ℓw = 78.6 in. c/2 = 47.5 in. The offset governs.
    @test out.length_by == (:offset,)
    @test out.length.length ≈ (95.0u"inch" - 0.1 * lw)
    @test out.length.from_half ≈ 47.5u"inch"

    # hu/16 = 9.875 in. The 12 in. floor is open and it governs. b = 26 in. meets it.
    @test out.zone_width.floor_applies
    @test out.zone_width_by == (:floor,)
    @test out.zone_width.required ≈ 12.0u"inch"
    @test out.zone_width_meets
    @test out.zone_width_shortfall ≈ 0.0u"inch"

    # b = 26 in. meets √(0.025 ℓw c) ≈ 19.74 in. (iii) is not evaluated.
    @test out.alternative.by === :width
    @test out.alternative.satisfied
    @test out.alternative.drift === nothing
    @test out.alternative.width.required ≈ sqrt(0.025 * 95 * 164) * u"inch"
    @test out.alternative.width.required > 19.3u"inch"
    @test !out.flange.applies
end

@testset "A width that misses (ii) is decided by the drift, and the element stays required" begin
    # The child test: ℓw 120 in., c 12 in., δu 21.6 in. on hwcs 60 ft.
    # Demand 0.045 against a raw capacity of 0.038. b = 5 in. misses √36 = 6 in.
    failing = special_boundary_composer(;
        lw = 120.0u"inch", hwcs = 60.0u"ft", hw = 60.0u"ft",
        continuous = true, single_critical_section = true,
        c = 12.0u"inch", δu = 21.6u"inch", b = 5.0u"inch", hu = 160.0u"inch",
        Mu = 100.0u"kip*ft", Vu = 10.0u"kip", Ve = 0.0u"kip",
        fc = 4.0u"ksi", Acv = 1000.0u"inch^2")
    @test failing.required
    @test failing.required_by === :displacement
    @test failing.alternative.by === :drift
    @test failing.alternative.drift !== nothing
    @test !failing.alternative.drift.meets
    @test !failing.alternative.satisfied
    # (a) still set the length. c/2 = 6 in. governs over c − 0.1ℓw = −6 in? 
    # 12 − 12 = 0, and c/2 = 6, so the half governs.
    @test failing.length_by == (:half,)
    @test failing.length.length ≈ 6.0u"inch"

    # b = 12 in. meets (ii). The same failing drift is never computed.
    wide = special_boundary_composer(;
        lw = 120.0u"inch", hwcs = 60.0u"ft", hw = 60.0u"ft",
        continuous = true, single_critical_section = true,
        c = 12.0u"inch", δu = 21.6u"inch", b = 12.0u"inch", hu = 160.0u"inch",
        Mu = 100.0u"kip*ft", Vu = 10.0u"kip", Ve = 0.0u"kip",
        fc = 4.0u"ksi", Acv = 1000.0u"inch^2")
    @test wide.alternative.by === :width
    @test wide.alternative.drift === nothing
    @test wide.alternative.satisfied

    # b equal to the root still meets (ii).
    exact = special_boundary_composer(;
        lw = 120.0u"inch", hwcs = 60.0u"ft", hw = 60.0u"ft",
        continuous = true, single_critical_section = true,
        c = 12.0u"inch", δu = 21.6u"inch", b = 6.0u"inch", hu = 160.0u"inch",
        Mu = 100.0u"kip*ft", Vu = 10.0u"kip", Ve = 0.0u"kip",
        fc = 4.0u"ksi", Acv = 1000.0u"inch^2")
    @test exact.alternative.width.required ≈ 6.0u"inch"
    @test exact.alternative.by === :width
    @test exact.alternative.drift === nothing
end

@testset "Eq. (18.10.6.2a) at equality requires the element, and a high stress does not change the route" begin
    # ℓw 120 in., c 10 in.: ℓw/(600 c) = 0.02. hwcs/ℓw = 2.
    # δu/hwcs = 0.02/1.5 lands on the equation. 0.99 of that falls short of it
    # and stays above the 0.005 floor, so the floor is not what decides.
    lw = 120.0u"inch"
    hwcs = 240.0u"inch"
    δu = (0.02 / 1.5) * hwcs
    at = special_boundary_composer(;
        lw = lw, hwcs = hwcs, hw = hwcs,
        continuous = true, single_critical_section = true,
        c = 10.0u"inch", δu = δu, b = 20.0u"inch", hu = 32.0u"inch",
        Mu = 100.0u"kip*ft", Vu = 10.0u"kip", Ve = 10.0u"kip",
        fc = 4.0u"ksi", Acv = 1000.0u"inch^2",
        σ = 10.0u"ksi")
    @test at.route === :displacement
    @test at.stress === nothing
    @test at.trigger.demand ≈ at.trigger.neutral_axis_term
    @test at.required
    @test at.required_by === :displacement
    @test at.edge === nothing

    under = special_boundary_composer(;
        lw = lw, hwcs = hwcs, hw = hwcs,
        continuous = true, single_critical_section = true,
        c = 10.0u"inch", δu = 0.99 * δu,
        Mu = 100.0u"kip*ft", Vu = 200.0u"kip",
        fc = 4.0u"ksi", Acv = 1000.0u"inch^2", λ = 1.0,
        σ = 10.0u"ksi")
    @test under.route === :displacement
    @test under.stress === nothing
    @test !under.trigger.required
    @test !under.required
    @test under.required_by === :not_required
    @test under.length === nothing
    @test under.alternative === nothing
    @test under.edge !== nothing
    # σ = 2.5 f′c would have triggered §18.10.6.3. This route does not read it.
    @test under.edge.hook.hook_required
end

@testset "The 0.005 floor can require an element when the displacement is zero" begin
    floored = _qualifying()
    @test floored.trigger.drift_ratio == 0.005
    @test floored.trigger.demand ≈ 0.0075
    @test floored.required
    @test floored.required_by === :displacement

    # c = 10 in. gives ℓw/(600 c) = 0.01667, above 0.0075. The floor is visible
    # and it does not require the element.
    clear = _qualifying(; c = 10.0u"inch", λ = 1.0, Vu = 200.0u"kip")
    @test clear.trigger.drift_ratio == 0.005
    @test !clear.required
    @test clear.required_by === :not_required
    @test clear.edge.hook.hook_required
end

@testset "Vertical extension names ℓw, Mu/4Vu, or both" begin
    # ℓw = 100 in. Mu/(4 Vu) = 20 ft is the longer one.
    shear = _qualifying(; Mu = 80.0u"kip*ft", Vu = 1.0u"kip")
    @test shear.extension_by == (:shear,)
    @test shear.extension.extension ≈ 20.0u"ft"

    # Mu/(4 Vu) = 100 in., the same length as ℓw.
    tied = _qualifying(; Mu = 4 * 100.0u"inch" * 1.0u"kip", Vu = 1.0u"kip")
    @test tied.extension_by == (:length, :shear)
    @test tied.extension.from_length ≈ tied.extension.from_shear
end

@testset "Closing any one §18.10.6.2 gate selects the stress route" begin
    fc = 4.0u"ksi"
    # These c and δu would satisfy (a). The missing single-critical-section
    # statement keeps them off that route.
    quiet = special_boundary_composer(;
        lw = 100.0u"inch", hwcs = 300.0u"inch",
        continuous = true, single_critical_section = false,
        c = 50.0u"inch", δu = 20.0u"inch",
        σ = 0.10 * fc, fc = fc,
        Vu = 10.0u"kip", λ = 1.0, Acv = 1000.0u"inch^2")
    @test quiet.slender
    @test quiet.route === :stress
    @test quiet.trigger === nothing
    @test !quiet.required
    @test quiet.required_by === :may_discontinue
    @test quiet.length === nothing

    # hwcs/ℓw just under 2, with both statements. Still the stress route.
    short = special_boundary_composer(;
        lw = 10.0u"ft", hwcs = 19.0u"ft",
        continuous = true, single_critical_section = true,
        σ = 0.10 * fc, fc = fc,
        Vu = 10.0u"kip", λ = 1.0, Acv = 1000.0u"inch^2")
    @test !short.slender
    @test short.route === :stress
    @test short.slenderness ≈ 1.9

    # Exactly 2, with both statements, is the displacement route and needs c.
    @test_throws ArgumentError special_boundary_composer(;
        lw = 10.0u"ft", hwcs = 20.0u"ft",
        continuous = true, single_critical_section = true,
        σ = 0.10 * fc, fc = fc)
    opened = _qualifying()
    @test opened.slenderness ≈ 2
    @test opened.route === :displacement
end

@testset "Stress cuts are strict, and the band decides nothing" begin
    fc = 5.0u"ksi"
    edge = (Vu = 200.0u"kip", λ = 1.0, Acv = 500.0u"inch^2")
    at_start = special_boundary_composer(;
        lw = 100.0u"inch", hwcs = 100.0u"inch",
        continuous = false, single_critical_section = false,
        σ = 0.2 * fc, fc = fc, edge...)
    @test at_start.stress.ratio ≈ 0.2
    @test !at_start.stress.triggered
    @test !at_start.stress.may_discontinue
    @test at_start.required === nothing
    @test at_start.required_by === :between
    @test at_start.edge === nothing
    @test at_start.length === nothing

    at_stop = special_boundary_composer(;
        lw = 100.0u"inch", hwcs = 100.0u"inch",
        continuous = false, single_critical_section = false,
        σ = 0.15 * fc, fc = fc, edge...)
    @test at_stop.stress.ratio ≈ 0.15
    @test at_stop.required === nothing
    @test at_stop.required_by === :between

    over = special_boundary_composer(;
        lw = 100.0u"inch", hwcs = 100.0u"inch", hw = 100.0u"inch",
        continuous = false, single_critical_section = false,
        σ = 0.2 * fc + 1.0u"psi", fc = fc,
        c = 20.0u"inch", b = 16.0u"inch", hu = 32.0u"inch")
    @test over.required
    @test over.required_by === :stress
    @test over.edge === nothing
    # §18.10.6.2(b) is not this route, even with a narrow wall.
    @test over.extension === nothing
    @test over.alternative === nothing

    under = special_boundary_composer(;
        lw = 100.0u"inch", hwcs = 100.0u"inch",
        continuous = false, single_critical_section = false,
        σ = 0.15 * fc - 1.0u"psi", fc = fc, edge...)
    @test under.stress.may_discontinue
    @test !under.required
    @test under.required_by === :may_discontinue
    @test under.length === nothing
    @test under.edge.hook.hook_required

    @test_throws ArgumentError special_boundary_composer(;
        lw = 100.0u"inch", hwcs = 100.0u"inch",
        continuous = false, single_critical_section = false,
        fc = fc)
end

@testset "The 12 in. floor follows §18.10.6.4(c), including on the stress route" begin
    # hw/ℓw = 2.5 and c/ℓw = 0.5, but hwcs/ℓw = 1.5, so the route is stress.
    # Both statements are true, and the floor opens. hu/16 = 1 in.
    fc = 4.0u"ksi"
    floored = special_boundary_composer(;
        lw = 100.0u"inch", hw = 250.0u"inch", hwcs = 150.0u"inch",
        continuous = true, single_critical_section = true,
        σ = 0.25 * fc, fc = fc,
        c = 50.0u"inch", b = 20.0u"inch", hu = 16.0u"inch")
    @test floored.route === :stress
    @test floored.required_by === :stress
    @test floored.zone_width.floor_applies
    @test floored.zone_width_by == (:floor,)
    @test floored.zone_width.required ≈ 12.0u"inch"
    @test floored.zone_width_meets
    @test floored.length_by == (:offset,)
    @test floored.length.length ≈ 40.0u"inch"
    @test floored.alternative === nothing

    # The same wall without continuity loses the floor. A narrow b is a
    # shortfall of hu/16 and still does not open (ii) or (iii).
    narrow = special_boundary_composer(;
        lw = 100.0u"inch", hw = 250.0u"inch", hwcs = 150.0u"inch",
        continuous = false, single_critical_section = true,
        σ = 0.25 * fc, fc = fc,
        c = 50.0u"inch", b = 0.5u"inch", hu = 16.0u"inch")
    @test narrow.route === :stress
    @test !narrow.zone_width.floor_applies
    @test narrow.zone_width_by == (:unsupported,)
    @test narrow.zone_width.required ≈ 1.0u"inch"
    @test !narrow.zone_width_meets
    @test narrow.zone_width_shortfall ≈ 0.5u"inch"
    @test narrow.alternative === nothing

    # hu/16 = 12 in. ties the floor.
    tied = special_boundary_composer(;
        lw = 100.0u"inch", hw = 250.0u"inch", hwcs = 150.0u"inch",
        continuous = true, single_critical_section = true,
        σ = 0.25 * fc, fc = fc,
        c = 50.0u"inch", b = 12.0u"inch", hu = 192.0u"inch")
    @test tied.zone_width_by == (:unsupported, :floor)
    @test tied.zone_width_meets
    @test tied.zone_width_shortfall ≈ 0.0u"inch"
end

@testset "Where no element is required, §18.10.6.5 names the hook and, above 400/fy, the ties" begin
    fc = 4.0u"ksi"
    Acv = 1000.0u"inch^2"
    threshold = lambda_sqrt_fc_Acv(1.0, fc, Acv)
    common = (
        lw = 120.0u"inch", hwcs = 240.0u"inch",
        continuous = true, single_critical_section = true,
        c = 10.0u"inch", δu = 0.5u"inch",
        fc = fc, Acv = Acv, λ = 1.0,
    )
    # δu/hwcs = 0.5/240 is below 0.005, so the demand is the floor 0.0075.
    # ℓw/(600 c) = 0.02, so (a) does not require an element.
    at = special_boundary_composer(; common..., Vu = threshold)
    @test at.required_by === :not_required
    @test at.edge.hook.threshold ≈ threshold
    @test !at.edge.hook.exempt
    @test at.edge.hook.hook_required
    @test at.edge.ties === nothing

    under = special_boundary_composer(; common..., Vu = threshold - 1.0u"lbf")
    @test under.edge.hook.exempt
    @test !under.edge.hook.hook_required

    fy = 60.0u"ksi"
    limit = boundary_longitudinal_ratio(0.0, fy).limit
    ties = (
        fy = fy, tie_spacing = 6.0u"inch", tie_hx = 14.0u"inch",
        db = 1.0u"inch", grade = 60, within_critical_reach = true,
    )
    shut = special_boundary_composer(; common..., Vu = threshold, ρ = limit, ties...)
    @test !shut.edge.ties.exceeds
    @test shut.edge.ties.length === nothing
    @test shut.length === nothing

    # c − 0.1ℓw is negative, so the tie length is c/2.
    open = special_boundary_composer(; common..., Vu = threshold, ρ = limit + 1e-6, ties...)
    @test open.edge.ties.exceeds
    @test open.edge.ties.length ≈ 5.0u"inch"
    @test open.length === nothing
    @test open.edge.ties.spacing_meets
    @test open.edge.ties.hx_meets

    @test_throws ArgumentError special_boundary_composer(;
        common..., Vu = threshold, ρ = limit)
end

@testset "A required element carries confinement, spacing, hoops, and the flange" begin
    fc = 4.0u"ksi"
    fyt = 60.0u"ksi"
    # Ag/Ach = 1.2. The constant term governs. At 1.3 they tie. At 1.5 the cover governs.
    function stressed(; Ag, Ach, Ash = nothing, bc = nothing, hx = 14.0u"inch",
                     thickness = nothing, kwargs...)
        return special_boundary_composer(;
            lw = 100.0u"inch", hw = 100.0u"inch", hwcs = 100.0u"inch",
            continuous = false, single_critical_section = false,
            σ = 0.25 * fc, fc = fc, fyt = fyt,
            c = 40.0u"inch", b = 16.0u"inch", hu = 32.0u"inch",
            Ag = Ag, Ach = Ach,
            least_dimension = 30.0u"inch", db = 1.0u"inch", hx = hx,
            grade = 60, within_critical_reach = true,
            Ash = Ash, bc = bc, thickness = thickness,
            kwargs...)
    end

    constant = stressed(; Ag = 1.2u"inch^2", Ach = 1.0u"inch^2")
    @test constant.required_by === :stress
    @test constant.confinement_by == (:constant,)
    @test constant.edge === nothing
    # Passed-in tie ratio must not open §18.10.6.5 while the element is required.
    held = stressed(; Ag = 1.2u"inch^2", Ach = 1.0u"inch^2",
                   ρ = 0.02, fy = fyt, Vu = 50.0u"kip", λ = 1.0, Acv = 1000.0u"inch^2",
                   tie_spacing = 6.0u"inch", tie_hx = 14.0u"inch")
    @test held.edge === nothing

    tied = stressed(; Ag = 1.3u"inch^2", Ach = 1.0u"inch^2")
    @test tied.confinement_by == (:cover, :constant)

    cover = stressed(; Ag = 1.5u"inch^2", Ach = 1.0u"inch^2")
    @test cover.confinement_by == (:cover,)

    # hx = 14 in. gives so = 4 in., under the 6 in. bar and table terms and the 10 in. dimension.
    @test constant.spacing.required ≈ 4.0u"inch"
    @test constant.spacing_by == (:so,)
    six = stressed(; Ag = 1.2u"inch^2", Ach = 1.0u"inch^2", hx = 8.0u"inch")
    @test six.spacing.required ≈ 6.0u"inch"
    @test six.spacing_by == (:bar, :so, :table)

    # The vertical spacing on this wall is 4 in. Ash is set from the ratio so
    # the three comparisons are amount, the vertical cap, and a tie.
    ratio = constant.confinement.required
    amount = stressed(; Ag = 1.2u"inch^2", Ach = 1.0u"inch^2",
                     Ash = ratio * 10.0u"inch" * 1.5u"inch", bc = 10.0u"inch")
    @test amount.hoop_spacing.by === :amount
    @test amount.hoop_spacing.spacing ≈ amount.hoop_spacing.from_amount
    vertical = stressed(; Ag = 1.2u"inch^2", Ach = 1.0u"inch^2",
                       Ash = ratio * 10.0u"inch" * 6.0u"inch", bc = 10.0u"inch")
    @test vertical.hoop_spacing.by === :vertical
    @test vertical.hoop_spacing.spacing ≈ 4.0u"inch"
    both = stressed(; Ag = 1.2u"inch^2", Ach = 1.0u"inch^2",
                   Ash = ratio * 10.0u"inch" * 4.0u"inch", bc = 10.0u"inch")
    @test both.hoop_spacing.by === :both

    # 21 in. ties the hx cap. 9 in. ties the overlap cap.
    thick = stressed(; Ag = 1.2u"inch^2", Ach = 1.0u"inch^2", thickness = 21.0u"inch")
    @test thick.hoop_hx_by == (:cap, :thickness)
    @test thick.hoops.hx ≈ 14.0u"inch"
    @test thick.hoop_overlap_by == (:cap,)
    thin = stressed(; Ag = 1.2u"inch^2", Ach = 1.0u"inch^2", thickness = 9.0u"inch")
    @test thin.hoop_overlap_by == (:cap, :thickness)
    @test thin.hoops.overlap ≈ 6.0u"inch"
    @test thin.hoop_hx_by == (:thickness,)

    flanged = stressed(; Ag = 1.2u"inch^2", Ach = 1.0u"inch^2",
                      in_compression = true, effective_flange_width = 30.0u"inch",
                      height_above_section = 100.0u"inch",
                      distance_to_adjacent_web = 40.0u"inch")
    @test flanged.flange.applies
    @test flanged.flange.included_width ≈ 30.0u"inch"
    @test flanged.flange.web_extension ≈ 12.0u"inch"
    # Half of 40 in. is 20 in., under the 25 in. height limit.
    @test flanged.overhang.overhang ≈ 20.0u"inch"
    @test flanged.overhang.from_height ≈ 25.0u"inch"

    floor_ok = stressed(; Ag = 1.2u"inch^2", Ach = 1.0u"inch^2", fc_floor = 0.7 * fc)
    @test floor_ok.floor.meets
    floor_short = stressed(; Ag = 1.2u"inch^2", Ach = 1.0u"inch^2",
                          fc_floor = 0.7 * fc - 1.0u"psi")
    @test !floor_short.floor.meets

    bars = stressed(; Ag = 1.2u"inch^2", Ach = 1.0u"inch^2", web_bar_spacing = 12.0u"inch")
    @test bars.web_bars.meets
    loose = stressed(; Ag = 1.2u"inch^2", Ach = 1.0u"inch^2", web_bar_spacing = 12.1u"inch")
    @test !loose.web_bars.meets

    footing = stressed(; Ag = 1.2u"inch^2", Ach = 1.0u"inch^2",
                      ld = 10.0u"inch", into_foundation = true)
    @test footing.support.required ≈ 12.0u"inch"
    @test footing.support.from_development ≈ 10.0u"inch"

    web = 1.0u"kip" / u"inch"
    straight = stressed(; Ag = 1.2u"inch^2", Ach = 1.0u"inch^2",
                       gap = 6.0u"inch", can_develop = true,
                       web_asfy_per_s = web, boundary_asfyt_per_s = web)
    @test straight.termination.reaches
    @test straight.termination.straight_permitted
    @test !straight.termination.hook_required
    hooked = stressed(; Ag = 1.2u"inch^2", Ach = 1.0u"inch^2",
                     gap = 6.1u"inch", can_develop = true,
                     web_asfy_per_s = web + 1.0u"lbf" / u"inch",
                     boundary_asfyt_per_s = web)
    @test !hooked.termination.reaches
    @test !hooked.termination.straight_permitted
    @test hooked.termination.hook_required

    @test_throws ArgumentError stressed(; Ag = 1.2u"inch^2", Ach = nothing)
    @test_throws ArgumentError stressed(; Ag = 1.2u"inch^2", Ach = 1.0u"inch^2",
                                        Ash = 0.2u"inch^2", bc = nothing)
    @test_throws ArgumentError special_boundary_composer(;
        lw = 100.0u"inch", hw = 100.0u"inch", hwcs = 100.0u"inch",
        continuous = false, single_critical_section = false,
        σ = 0.25 * fc, fc = fc,
        c = 40.0u"inch", b = 16.0u"inch", hu = 32.0u"inch",
        distance_to_adjacent_web = 40.0u"inch")
end

# One knob at a time. The outcome moves in the direction the clause names,
# and a knob that a clause does not read leaves that clause's result alone.
@testset "Each design input moves only the clause that reads it" begin
    lw = 120.0u"inch"
    hwcs = 360.0u"inch"
    # δu/hwcs = 10/360. Demand = 1.5 × 10/360 = 0.04167, above the 0.005 floor.
    # ℓw/(600 c) drops through that demand as c grows.
    function displaced(; c, b = 40.0u"inch")
        return special_boundary_composer(;
            lw = lw, hwcs = hwcs, hw = hwcs,
            continuous = true, single_critical_section = true,
            c = c, δu = 10.0u"inch", b = b, hu = 96.0u"inch",
            Mu = 100.0u"kip*ft", Vu = 10.0u"kip", Ve = 10.0u"kip",
            fc = 4.0u"ksi", Acv = 1000.0u"inch^2", λ = 1.0)
    end
    # c = 4 in.: capacity = 120/(600×4) = 0.05 > 0.04167. Not required.
    # The half-depth length would have governed, but no element is detailed.
    shallow = displaced(; c = 4.0u"inch")
    @test !shallow.required
    @test shallow.length === nothing
    @test shallow.edge !== nothing
    # c = 0.2ℓw = 24 in. is the length tie, and it is past the trigger.
    at_tie = displaced(; c = 0.2 * lw)
    @test at_tie.required
    @test at_tie.length_by == (:offset, :half)
    @test at_tie.length.from_offset ≈ at_tie.length.from_half
    # A deeper axis keeps the element and hands the length to the offset.
    deep = displaced(; c = 48.0u"inch")
    @test deep.required
    @test deep.length_by == (:offset,)
    @test deep.length.length > at_tie.length.length
    # The same deep wall with a narrow compression zone fails (iii) on this
    # drift. Widening it to the root makes the drift disappear.
    narrow = displaced(; c = 48.0u"inch", b = 4.0u"inch")
    @test narrow.alternative.by === :drift
    @test !narrow.alternative.satisfied
    root = narrow.alternative.width.required
    wide = displaced(; c = 48.0u"inch", b = root)
    @test wide.alternative.by === :width
    @test wide.alternative.drift === nothing
    @test wide.length.length ≈ deep.length.length

    # Stress, same section. σ walks the two cuts. The length does not move with σ.
    fc = 4.0u"ksi"
    function pressed(; σ, hu = 96.0u"inch", b = 16.0u"inch")
        return special_boundary_composer(;
            lw = lw, hw = hwcs, hwcs = 100.0u"inch",
            continuous = true, single_critical_section = true,
            σ = σ, fc = fc, c = 48.0u"inch", b = b, hu = hu,
            Vu = 200.0u"kip", λ = 1.0, Acv = 1000.0u"inch^2")
    end
    low = pressed(; σ = 0.10 * fc)
    @test low.required_by === :may_discontinue
    @test low.length === nothing
    band = pressed(; σ = 0.17 * fc)
    @test band.required === nothing
    @test band.length === nothing
    high = pressed(; σ = 0.30 * fc)
    @test high.required_by === :stress
    @test high.length_by == (:offset,)
    higher = pressed(; σ = 0.50 * fc)
    @test higher.length.length ≈ high.length.length
    @test higher.zone_width.required ≈ high.zone_width.required
    # hu/16 crosses the 12 in. floor. The length still does not move.
    # 16×12 = 192 in. ties. 16×16 = 256 in. is the unsupported height.
    below_floor = pressed(; σ = 0.30 * fc, hu = 128.0u"inch")
    @test below_floor.zone_width_by == (:floor,)
    @test below_floor.zone_width_shortfall ≈ 0.0u"inch"
    above_floor = pressed(; σ = 0.30 * fc, hu = 256.0u"inch", b = 10.0u"inch")
    @test above_floor.zone_width_by == (:unsupported,)
    @test above_floor.zone_width.required ≈ 16.0u"inch"
    @test above_floor.zone_width_shortfall ≈ 6.0u"inch"
    @test above_floor.length.length ≈ high.length.length
end

@testset "The thickness is the greater of the zone width and the (ii) root" begin
    # NEHRP: the 12 in. floor governs the zone, and the (ii) root is about
    # 19.7 in. The root is the thickness. b = 26 in. already meets it.
    nehrp = special_boundary_composer(;
        lw = 164.0u"inch", hwcs = 2811.0u"inch", hw = 2811.0u"inch",
        continuous = true, single_critical_section = true,
        c = 95.0u"inch", δu = 26.84u"inch", b = 26.0u"inch", hu = 158.0u"inch",
        Mu = 24976.0u"kip*ft", Vu = 576.0u"kip", Ve = 576.0u"kip",
        fc = 5.0u"ksi", Acv = (26.0 * 164.0) * u"inch^2")
    @test boundary_minimum_thickness(nehrp) ≈ nehrp.alternative.width.required
    @test boundary_minimum_thickness(nehrp) > 12.0u"inch"
    @test nehrp.zone_width_meets

    # Stress route, no (ii). The floor is 12 in. and hu/16 is 1 in.
    fc = 4.0u"ksi"
    stress = special_boundary_composer(;
        lw = 100.0u"inch", hw = 250.0u"inch", hwcs = 150.0u"inch",
        continuous = true, single_critical_section = true,
        σ = 0.25 * fc, fc = fc,
        c = 50.0u"inch", b = 20.0u"inch", hu = 16.0u"inch")
    @test stress.alternative === nothing
    @test boundary_minimum_thickness(stress) ≈ 12.0u"inch"

    # No element. There is no thickness to raise.
    clear = special_boundary_composer(;
        lw = 100.0u"inch", hwcs = 100.0u"inch",
        continuous = false, single_critical_section = false,
        σ = 0.10 * fc, fc = fc,
        Vu = 200.0u"kip", λ = 1.0, Acv = 1000.0u"inch^2")
    @test boundary_minimum_thickness(clear) === nothing
end
