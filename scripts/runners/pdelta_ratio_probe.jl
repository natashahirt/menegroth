#=
Second-order over first-order pier moments on the ordinary-wall fixtures.

The flexible office softens its Y pier so story θ sits in (0.10, θmax].
Wind M2/M1 should sit near the sway amplification. The net ratio can exceed
1.4 where factored dead and wind moments oppose.

    julia --project=StructuralSynthesizer scripts/runners/pdelta_ratio_probe.jl
=#

using Printf

const _TEST = joinpath(@__DIR__, "..", "..", "StructuralSynthesizer", "test", "analyze",
                       "test_ordinary_wall_stage.jl")
let src = read(_TEST, String)
    cut = findfirst("@testset \"Ordinary wall stage\" begin", src)
    cut === nothing && error("fixture prefix not found in $_TEST")
    include_string(Main, src[1:first(cut) - 1], _TEST)
end

const SS = StructuralSynthesizer

function probe(label, struc; wind_index::Int=4, soften_y::Bool=false)
    println("\n================ $label ================")
    params = DesignParameters(
        lateral=LateralDesign(; system=WallsSeismicSystem(:A3), assignment=BuildingUnit()),
        wall_inputs=_stage_inputs(), skip_visualization=true)
    to_asap!(struc; params=params, diaphragms=:rigid)
    soften_y && _stage_soften_y_piers!(struc, 0.001)
    inputs = params.wall_inputs
    sys = SS.StructuralSizer.ordinary_concrete_seismic_system(
        params.lateral.system.row, inputs.sdc)
    SS.prepare_lateral_model!(struc, params.lateral.system)
    model = struc.asap_model
    links = struc.asap_rigid_links

    basic = SS.solve_gravity_basic_cases(struc; roof=inputs.roof, params=params)
    wind = SS.wind_story_analysis(struc; directions=inputs.directions, qz=inputs.qz,
        qh=inputs.qh, Kd=inputs.Kd, G=inputs.G, GCpi=inputs.GCpi,
        extra_directions=inputs.extra_directions)
    elf = SS.elf_story_analysis(struc; method=inputs.method, SDS=inputs.SDS, S1=inputs.S1,
        R=sys.R, Ie=inputs.Ie, T=inputs.T, Cd=sys.Cd, β=inputs.β, SD1=inputs.SD1,
        TL=inputs.TL, Sa=inputs.Sa, Ω0=sys.Ω0, between=inputs.between)
    second = SS._build_story_second_order(struc, basic, wind, elf)

    key = SS.GravityStiffnessKey(1.2, 0.0, 1.6)
    set = second[key]
    i = wind_index
    println("wind case: ", SS._wind_case_symbol(i, wind.cases[i]))
    wl = SS._wind_loads(wind.levels, wind.cases[i].Fx_kN, wind.cases[i].Fy_kN,
                        wind.cases[i].Mz_kN_m)
    uw1 = Asap.solve(model, [wl], links)[1]

    println("\nθ on ELF drift cases (max per direction and story):")
    for d in (:x, :y), k in eachindex(elf.levels)
        θs = [Float64(c.θ[k]) for c in elf.cases
              if c.purpose === :drift && c.direction === d && c.θ[k] !== nothing]
        isempty(θs) || @printf("  %s  L%d  θmax = %.4f\n", d, k, maximum(θs))
    end

    masters = [(lv.elevation_m, lv.master) for lv in elf.levels]
    base = first(elf.levels).elevation_m - first(elf.levels).story_height_m
    for (tag, f) in (("1.0D", (1.0, 0.0, 0.0)), ("1.2D+1.6Lr", (1.2, 0.0, 1.6)))
        u1 = f[1] .* basic.u[1] .+ f[2] .* basic.u[2] .+ f[3] .* basic.u[3]
        loads = vcat(SS.scale_story_loads(basic.loads[1], f[1]),
                     SS.scale_story_loads(basic.loads[2], f[2]),
                     SS.scale_story_loads(basic.loads[3], f[3]))
        profs = SS.story_axial_profiles(model, u1, struc.wall_mesh, masters, base; loads)
        println("\nVertical force through each story, $tag:")
        for (k, (p, lv)) in enumerate(zip(profs, elf.levels))
            wall = 0.0
            for pier in struc.wall_mesh.piers
                abs(SS._pier_bottom(pier) - p.z_bottom_m) <= SS.WALL_CUT_ZTOL_M || continue
                wall += SS.pier_wall_action(struc.walls[pier.wall_index], pier, u1;
                                            loads, fixed_end_from_loads=true).N
            end
            @printf("  L%d  ΣP = %9.1f kN   walls = %9.1f kN   ELF Px = %9.1f kN   ΣP/Px = %.2f\n",
                    k, SS.story_axial_total(p) / 1e3, wall / 1e3, lv.px_kN,
                    SS.story_axial_total(p) / 1e3 / lv.px_kN)
        end
    end

    println("\nMaster displacements, first-order → on K_G (key D=1.2 L=0 Lr=1.6):")
    @printf("  %-6s %-5s %12s %12s %8s\n", "case", "level", "u1", "u2", "u2/u1")
    for (name, u1, u2) in (("D", basic.u[1], set.u[1]),
                           ("Lr", basic.u[3], set.u[3]),
                           ("W", uw1, set.u[3 + i]))
        for (k, lv) in enumerate(elf.levels)
            g = lv.master.globalID
            for (dof, tag) in ((1, "ux"), (2, "uy"), (6, "θz"))
                a, b = u1[g[dof]], u2[g[dof]]
                abs(a) < 1e-12 && abs(b) < 1e-12 && continue
                @printf("  %-6s L%-1d %-3s %12.4e %12.4e %8.3f\n", name, k, tag, a, b,
                        abs(a) > 1e-15 ? b / a : NaN)
            end
        end
    end

    println("\nPier-bottom in-plane M [N·m], combination 1.2D + 1.6Lr + 0.5W:")
    @printf("  %-5s %-4s %12s %12s %8s %14s %14s\n",
            "pier", "comp", "M1", "M2", "M2/M1", "factored M1", "factored M2")
    for pier in struc.wall_mesh.piers
        g1 = SS.pier_gravity_actions(struc, basic, pier)
        w1 = SS.wind_pier_actions(struc, wind, pier)[i]
        g2 = SS._second_order_gravity(struc, pier, basic, set)
        w2 = SS._second_order_lateral(struc, pier, set.u[3 + i])
        tot1 = 0.0
        tot2 = 0.0
        for (comp, f, a, b) in (("D", 1.2, g1.D.M, g2.D.M),
                                ("L", 0.0, g1.L.M, g2.L.M),
                                ("Lr", 1.6, g1.companion.M, g2.companion.M),
                                ("W", 0.5, w1.M, w2.M))
            tot1 += f * a
            tot2 += f * b
            @printf("  %-5d %-4s %12.1f %12.1f %8.3f %14.1f %14.1f\n", pier.wall_index,
                    comp, a, b, abs(a) > 1e-9 ? b / a : NaN, f * a, f * b)
        end
        @printf("  %-5d %-4s %12s %12s %8.3f %14.1f %14.1f\n", pier.wall_index, "sum",
                "", "", abs(tot1) > 1e-9 ? tot2 / tot1 : NaN, tot1, tot2)
    end
end

probe("Flexible office (soft Y pier)", _stage_office_pdelta(); soften_y=true)
probe("Stiff office (walls on both axes)", _stage_office())
