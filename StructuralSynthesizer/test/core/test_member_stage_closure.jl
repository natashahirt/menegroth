# =============================================================================
# Member stage closure (steel framed floor)
#
#   - fire coating is dead-factored, tagged, replaced rather than stacked,
#     included in the pattern cases, and recovered unfactored for service;
#   - the beam/column loop ends only when a pass changes no section, and a
#     loop that runs out of passes is reported on the design;
#   - steel members get coating from the material they were sized with,
#     while their sections stay catalog sections (`material = nothing`);
#   - a `:geometry` rebuild keeps the sized frame sections, member
#     self-weight, and coating;
#   - foundation bearing is reported from the unfactored D+L reactions.
#
# Run standalone:
#   julia scripts/runners/test_quiet.jl StructuralSynthesizer core/test_member_stage_closure.jl
# =============================================================================

using StructuralSynthesizer
using StructuralSizer
using Asap
using Test
using Unitful

const _SS_MC = StructuralSynthesizer
const _SR_MC = StructuralSizer

function _mc_params(; max_iterations = 6, fire_rating = 2.0, foundations = false)
    return DesignParameters(
        name = "member_stage_closure",
        floor = OneWayOptions(),
        beams = SteelBeamOptions(composite = false),
        columns = SteelColumnOptions(),
        materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60, steel = A992_Steel),
        loads = GravityLoads(floor_LL = 50.0u"psf", floor_SDL = 15.0u"psf",
                             roof_LL = 50.0u"psf", roof_SDL = 15.0u"psf"),
        fire_rating = fire_rating,
        fire_protection = SFRM(),
        max_iterations = max_iterations,
        skip_visualization = true,
        foundation_options = foundations ?
            FoundationParameters(options = _SR_MC.FoundationOptions(strategy = :all_spread)) :
            nothing,
    )
end

_mc_struc() = BuildingStructure(gen_medium_office(24.0u"ft", 24.0u"ft", 12.0u"ft", 2, 2, 1))

_coating(model) = [ld for ld in model.loads
                   if ld isa Asap.LineLoad && ld.id === _SS_MC.FIRE_COATING_LOAD_ID]

@testset "Member stage closure" begin
    params = _mc_params(foundations = true)
    struc = _mc_struc()
    design = design_building(struc, params; restore = false)
    model = struc.asap_model
    D = Float64(_SS_MC.governing_combo(params).D)

    @testset "fire coating is dead load on the final sections" begin
        coat = _coating(model)
        groups = struc.skeleton.groups_edges
        @test length(coat) == sum(length(get(groups, g, Int[]))
                                  for g in (_SS_MC.BEAM_GROUP_SYMBOLS..., :columns))
        @test all(m -> isnothing(section(m).material), [struc.beams; struc.columns])
        @test all(m -> isequal(_SS_MC._member_steel(m), A992_Steel), [struc.beams; struc.columns])
        service = _SS_MC.unfactored_fire_coating_loads(model)
        @test length(service) == length(coat)
        for (f, s) in zip(coat, service)
            @test f.element === s.element
            @test ustrip(u"N/m", f.value[3]) ≈ D * ustrip(u"N/m", s.value[3])
            @test ustrip(u"N/m", s.value[3]) < 0
        end
        n = length(coat)
        @test _SS_MC._sync_fire_coating_loads!(struc, params) == n
        @test length(_coating(model)) == n
        cases = _SS_MC._generate_pattern_cases(struc)
        @test all(c -> count(ld -> ld isa Asap.LineLoad &&
                                   ld.id === _SS_MC.FIRE_COATING_LOAD_ID, c) == n, cases)
    end

    @testset "converged loop leaves no stage diagnostic" begin
        @test !haskey(struc.stage_diagnostics, :members)
        @test all(b -> b.ok, values(design.beams))
    end

    @testset "foundation bearing uses the service reactions" begin
        @test !isempty(design.foundations)
        R_s = _SS_MC._service_reactions(struc)
        Ps_of(fdn) = sum(R_s[model.nodes[struc.supports[s].node_idx].globalID[3]]
                         for s in fdn.support_indices) * u"N"
        # Spread footings grouped by reaction share one size, designed for the
        # largest service reaction in the group.
        group_of = Dict(fi => fg for fg in values(struc.foundation_groups)
                        for fi in fg.foundation_indices)
        for (i, f) in design.foundations
            members = haskey(group_of, i) ? group_of[i].foundation_indices : [i]
            Ps = maximum(Ps_of(struc.foundations[j]) for j in members)
            qa = params.foundation_options.soil.qa
            expected = ustrip(u"kPa", Ps / (f.length * f.width)) / ustrip(u"kPa", qa)
            @test f.bearing_ratio ≈ expected rtol = 1e-6
        end
    end

    @testset "geometry rebuild keeps sections, self-weight, and coating" begin
        sections = [el.section for el in model.frame_elements]
        n_gravity = count(ld -> ld isa Asap.GravityLoad, model.loads)
        n_coat = length(_coating(model))
        _SS_MC.update_analysis!(struc, :geometry; params)
        rebuilt = struc.asap_model
        @test rebuilt !== model
        inert = _SS_MC._inert_frame_edges(struc.skeleton)
        @test all(rebuilt.frame_elements[i].section === sections[i]
                  for i in eachindex(sections) if !(i in inert))
        @test count(ld -> ld isa Asap.GravityLoad, rebuilt.loads) == n_gravity
        @test length(_coating(rebuilt)) == n_coat
        a = _SS_MC.member_self_weight_acceleration(params)
        @test all(ld -> !(ld isa Asap.GravityLoad) || ld.factor ≈ a, rebuilt.loads)
    end

    # One-way slabs go through the story shell, whose rounds repeat the beam and
    # column loop, so the deck floor is used: one pass from the placeholder
    # sections cannot be a fixed point.
    @testset "a loop out of passes is reported" begin
        s1 = BuildingStructure(gen_medium_office(20.0u"ft", 10.0u"ft", 12.0u"ft", 2, 1, 1))
        fill = Concrete(NWC_4000.E, NWC_4000.fc′,
                        uconvert(u"kg/m^3", 145.0u"lb/ft^3"), 0.2, NWC_4000.ecc)
        p1 = DesignParameters(
            name = "member_stage_out_of_passes",
            floor = CompositeDeckOptions(deck_profile = "2VLI", fill_material = fill),
            beams = SteelBeamOptions(composite = true, composite_slab_type = :deck,
                                     composite_deck_profile = "2VLI"),
            columns = SteelColumnOptions(),
            materials = MaterialOptions(concrete = fill, steel = A992_Steel),
            loads = GravityLoads(floor_LL = 50.0u"psf", floor_SDL = 15.0u"psf",
                                 roof_LL = 50.0u"psf", roof_SDL = 15.0u"psf"),
            max_iterations = 1,
            skip_visualization = true,
        )
        d1 = design_building(s1, p1; restore = false)
        @test haskey(s1.stage_diagnostics, :members)
        @test !d1.converged
        @test any(m -> occursin("did not settle", m), d1.diagnostics)
        @test all(b -> !b.ok, values(d1.beams))
    end

    # Which global direction bends an RC column about its strong axis is not
    # recorded, so the final check tries both. The sizer has to as well, or a
    # bar layout on two faces passes it one way and fails the other.
    @testset "RC frame columns pass in both orientations" begin
        s2 = BuildingStructure(gen_medium_office(60.0u"ft", 60.0u"ft", 13.0u"ft", 2, 2, 2))
        p2 = DesignParameters(
            name = "member_stage_rc_orientation",
            floor = OneWayOptions(material = RC_4000_60),
            beams = ConcreteBeamOptions(material = NWC_4000, rebar_material = Rebar_60),
            columns = ConcreteColumnOptions(material = NWC_4000, rebar_material = Rebar_60),
            materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
            loads = GravityLoads(floor_LL = 80.0u"psf"),
            skip_visualization = true,
        )
        design_building(s2, p2; restore = false)
        # Forces before the sizing pass: the sections it picks must pass them.
        envs = _SS_MC.column_force_envelopes(s2, p2)
        _SS_MC.size_columns!(s2, p2.columns; reanalyze = false,
                             I_factor = p2.column_I_factor,
                             gravity_factor = _SS_MC.member_self_weight_acceleration(p2))
        for (i, col) in enumerate(s2.columns)
            r = _SS_MC.rc_frame_column_check(col, p2.columns,
                                             _SS_MC.frame_column_demand(envs[i]))
            @test r.passed
        end
    end
end
