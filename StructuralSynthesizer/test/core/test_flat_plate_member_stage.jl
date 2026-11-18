# =============================================================================
# Flat-plate member stage
#
# After the member stage of a two-story flat plate:
#   - every frame column carries its concrete section and its self-weight at
#     the strength dead factor;
#   - no slab's stored punching and column checks were made at a column
#     smaller than the one installed;
#   - every column passes the full-load P-M check;
#   - a lower column may be smaller than the one above it, when its own checks pass;
#   - uniform column sizing has already run, so walls and foundations see it.
#
# Run standalone:
#   julia scripts/runners/test_quiet.jl StructuralSynthesizer core/test_flat_plate_member_stage.jl
# =============================================================================

using StructuralSynthesizer
using StructuralSizer
using Asap
using Test
using Unitful

const _SS_FP = StructuralSynthesizer
const _SR_FP = StructuralSizer

function _fp_member_building(; uniform = :off, method = DDM())
    skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 2)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        floor = FlatPlateOptions(method = method),
        materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
        uniform_column_sizing = uniform,
        max_iterations = 5,
        skip_visualization = true,
    )
    return struc, params
end

"""Every `(column index, column result)` the flat-plate slabs of `struc` report."""
_fp_column_results(struc) = [(cidx, r) for slab in struc.slabs
    if slab.design_details isa NamedTuple && hasproperty(slab.design_details, :column_results) &&
       slab.design_details.column_results !== nothing
    for (cidx, r) in slab.design_details.column_results]

"""Frame elements of `col`."""
_fp_col_elements(struc, col) =
    [struc.asap_model.frame_elements[struc.segments[s].edge_idx] for s in _SS_FP.segment_indices(col)]

@testset "Flat-plate member stage" begin
    @testset "settle! stops on the first pass that changes nothing" begin
        n = Ref(0)
        r = _SR_FP.settle!(; budget = 10) do k
            n[] += 1
            k < 3
        end
        @test r.converged && r.stop === :settled && r.steps == 3 && n[] == 3
        r = _SR_FP.settle!(_ -> true; budget = 4)
        @test !r.converged && r.stop === :budget && r.steps == 4
    end

    @testset "self-weight acceleration and unfactored copies" begin
        p = DesignParameters()
        a = _SS_FP.member_self_weight_acceleration(p)
        @test a ≈ Float64(_SS_FP.governing_combo(p).D) * Asap.GRAVITY
        @test a > Asap.GRAVITY
    end

    struc, params = _fp_member_building()
    design = design_building(struc, params; restore = false)
    a = _SS_FP.member_self_weight_acceleration(params)

    @testset "frame columns carry concrete section and factored self-weight" begin
        gl = Dict(objectid(ld.element) => ld for ld in struc.asap_model.loads
                  if ld isa Asap.GravityLoad)
        for col in struc.columns
            isnothing(col.c1) && continue
            A = ustrip(u"m", col.c1) * ustrip(u"m", col.c2)
            for el in _fp_col_elements(struc, col)
                @test ustrip(u"m^2", el.section.A) ≈ A rtol = 1e-9
                ld = get(gl, objectid(el), nothing)
                @test ld !== nothing
                ld === nothing || @test ld.factor ≈ a
            end
        end
    end

    @testset "service loads use unfactored self-weight" begin
        for ld in _SS_FP._unfactored_DL_loads(struc)
            ld isa Asap.GravityLoad && @test ld.factor ≈ Asap.GRAVITY
        end
    end

    @testset "every slab was checked at its installed columns" begin
        @test isempty(_SS_FP._stale_flat_plate_slabs(struc))
    end

    @testset "full-load P-M check passes on every flat-plate column" begin
        checks = _SS_FP.flat_plate_column_checks(struc, _SS_FP._flat_plate_column_opts(params))
        @test !isempty(checks)
        @test all(c -> c.passed, values(checks))
        # DDM reports only the joint moment; the check splits it by stiffness.
        @test all(((_, r),) -> r.Mu_below === nothing, _fp_column_results(struc))
    end

    @testset "a lower column is the section its own checks pass" begin
        n = 0
        checks = _SS_FP.flat_plate_column_checks(struc, _SS_FP._flat_plate_column_opts(params))
        for col in struc.columns
            above = col.column_above
            (above === nothing || isnothing(col.c1) || isnothing(above.c1)) && continue
            (above.shape == col.shape && isapprox(above.θ, col.θ; atol = 1e-6)) || continue
            n += 1
        end
        @test n > 0
        @test all(c -> c.passed, values(checks))
        @test !haskey(struc.stage_diagnostics, :flat_plate_columns)
    end

    @testset "a change to the column above makes the slab below stale" begin
        k = findfirst(eachindex(struc.slabs)) do s
            dd = struc.slabs[s].design_details
            dd isa NamedTuple && hasproperty(dd, :designed_above) &&
                any(!isnothing, values(dd.designed_above))
        end
        @test k !== nothing
        if k !== nothing
            @test _SS_FP._slab_checked_at_installed_columns(struc, k)
            cidx = first(i for (i, r) in struc.slabs[k].design_details.designed_above
                         if r !== nothing)
            above = struc.columns[cidx].column_above
            c1_old = above.c1
            above.c1 = c1_old + 2.0u"inch"
            @test !_SS_FP._slab_checked_at_installed_columns(struc, k)
            above.c1 = c1_old
            @test _SS_FP._slab_checked_at_installed_columns(struc, k)
        end
    end

    @testset "shell analysis: the full-load check uses the stub moments" begin
        s3, p3 = _fp_member_building(method = FEA())
        design_building(s3, p3; restore = false)
        opts = _SS_FP._flat_plate_column_opts(p3)
        joint = _SS_FP._flat_plate_joint_moments(s3, opts)
        rs = _fp_column_results(s3)
        @test !isempty(rs)
        kipft = Asap.kip * u"ft"
        for (cidx, r) in rs
            @test r.Mu_below !== nothing && r.Mu_above !== nothing
            # A column with nothing above has no stub above.
            isnothing(s3.columns[cidx].column_above) && @test iszero(r.Mu_above)
            # The column below is checked with the stub moment it was sized for.
            @test maximum(joint[cidx].below) >= abs(ustrip(kipft, r.Mu_below)) - 1e-9
        end
        below = _SS_FP._column_below_index(s3)
        for (i, d) in _SS_FP.flat_plate_column_demands(s3, opts)
            top = haskey(joint, i) ? joint[i].below : (0.0, 0.0)
            b = get(below, i, 0)
            bot = (b != 0 && haskey(joint, b)) ? joint[b].above : (0.0, 0.0)
            @test d.M2x ≈ max(top[1], bot[1])
            @test d.M2y ≈ max(top[2], bot[2])
        end
    end

    @testset "uniform column sizing runs inside the member stage" begin
        s2, p2 = _fp_member_building(uniform = :per_story)
        d2 = design_building(s2, p2; restore = false)
        @test d2 isa BuildingDesign
        by_story = Dict{Int, Set{Tuple{Float64, Float64}}}()
        for col in s2.columns
            isnothing(col.c1) && continue
            push!(get!(Set{Tuple{Float64, Float64}}, by_story, col.story),
                  (ustrip(u"inch", col.c1), ustrip(u"inch", col.c2)))
        end
        @test all(s -> length(s) == 1, values(by_story))
        @test isempty(_SS_FP._stale_flat_plate_slabs(s2))
        # A second pass changes nothing once the stage has settled.
        @test _SS_FP.harmonize_uniform_column_sizes!(s2, p2) == 0
    end

    @testset "§10.12: 6 ksi columns through a 4 ksi floor" begin
        s4 = BuildingStructure(gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 2))
        p4 = DesignParameters(
            floor = FlatPlateOptions(method = DDM()),
            materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60,
                                        column = _SR_FP.RC_6000_60),
            max_iterations = 5,
            skip_visualization = true,
        )
        design_building(s4, p4; restore = false)
        opts = _SS_FP._flat_plate_column_opts(p4)
        @test opts.material === NWC_6000
        joints = _SS_FP.flat_plate_joint_demands(s4, p4, opts)
        @test !isempty(joints)
        psi = u"psi"
        fcs = Set(round(ustrip(psi, e.fc)) for es in values(joints) for e in es)
        # §10.12.3 interior 0.75·6000 + 0.35·4000; §10.12.2 edge and corner 4000.
        @test fcs ⊆ Set([5900.0, 4000.0]) && 5900.0 in fcs && 4000.0 in fcs
        # Joints are only where a column continues: a column with one above,
        # or the column above another.
        supported = Set(objectid(c.column_above) for c in s4.columns if c.column_above !== nothing)
        @test all(i -> s4.columns[i].column_above !== nothing ||
                       objectid(s4.columns[i]) in supported, keys(joints))
        # A top-story column has a joint only at its bottom.
        @test any(i -> s4.columns[i].column_above === nothing, keys(joints))
        checks = _SS_FP.flat_plate_column_checks(s4, opts; params = p4)
        @test all(c -> c.passed, values(checks))
        @test any(c -> !isempty(c.joint), values(checks))
    end
end
