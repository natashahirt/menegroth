# One joist system on one plan, with the slab shell bars and the error trace.
#
#     SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#         julia --project=StructuralStudies scripts/runners/sdf_joist_diag.jl special/rhombus_8x12 steel_twoway

include(joinpath(@__DIR__, "sdf_joist_systems.jl"))

"""Print every slab's shell bar field: elements that cannot carry their moment, and the peaks."""
function print_shell_bars(design, struc)
    for (i, s) in sort(collect(design.slabs); by = first)
        fields = s.shell_reinforcement
        println("Slab $i  h=$(round(ustrip(u"inch", s.thickness); digits=2)) in  " *
                "converged=$(s.converged)  check=$(s.failing_check)  fields=$(length(fields))")
        slab = struc.slabs[i]
        println("  volumes: ", slab.volumes)
        for (k, f) in enumerate(fields)
            bad = [e for e in f.elements if !e.section_adequate]
            Mmax(e) = max(abs(e.Mu_x_bot), abs(e.Mu_x_top), abs(e.Mu_y_bot), abs(e.Mu_y_top))
            good = [e for e in f.elements if e.section_adequate]
            peak_ok = isempty(good) ? 0.0 : maximum(Mmax, good)
            As = sum(e -> (e.As_x_bot + e.As_x_top + e.As_y_bot + e.As_y_top) * e.area, good; init = 0.0)
            println("  field $k  h=$(round(f.h / 0.0254; digits=2)) in  d=$(round(f.d / 0.0254; digits=2)) in  " *
                    "elements=$(length(f.elements))  inadequate=$(length(bad))  " *
                    "max adequate |Mu|=$(round(peak_ok / 4448.22 * 0.3048; digits=2)) kip·ft/ft  " *
                    "ΣAs·area=$(round(As; sigdigits=4)) m³")
            for e in first(sort(bad; by = Mmax, rev = true), 8)
                println("    elem $(e.elem_idx) at ($(round(e.cx; digits=2)), $(round(e.cy; digits=2))) m  " *
                        "area=$(round(e.area; digits=4)) m²  " *
                        "Mu x bot/top=$(round(e.Mu_x_bot/1e3; digits=1))/$(round(e.Mu_x_top/1e3; digits=1))  " *
                        "y bot/top=$(round(e.Mu_y_bot/1e3; digits=1))/$(round(e.Mu_y_top/1e3; digits=1)) kN·m/m")
                avg = String[]
                for r in (0.25, 0.5, 1.0)
                    near = [o for o in f.elements if hypot(o.cx - e.cx, o.cy - e.cy) <= r]
                    A = sum(o -> o.area, near)
                    mx = sum(o -> o.Mu_x_bot * o.area, near) / A
                    my = sum(o -> o.Mu_y_bot * o.area, near) / A
                    push!(avg, "r=$(r) m: x/y bot $(round(mx/1e3; digits=1))/$(round(my/1e3; digits=1)) ($(length(near)) el)")
                end
                println("      averaged  ", join(avg, "  "))
            end
            # Whitney block limit at this depth, ACI 318-11 §10.2.7: 2Rn = β1 f'c.
            β1 = f.fc <= 27.58e6 ? 0.85 : max(0.65, 0.85 - 0.05 * (f.fc - 27.58e6) / 6.895e6)
            println("    section limit ϕMn ≈ $(round(0.9 * f.d^2 * β1 * f.fc / 2 / 1e3; digits=1)) kN·m/m")
        end
    end
    println("Columns:")
    for (j, c) in enumerate(struc.columns)
        try
            sec = StructuralSynthesizer.section(c)
            println("  column $j at ", struc.skeleton.vertices[c.vertex_idx], "  ",
                    sec === nothing ? "none" : sec.name)
        catch
            println("  column $j: no vertex_idx")
        end
    end
end

function diag(plan_name, system)
    params = joist_system_parameters(plan_name, system)
    struc = BuildingStructure(plan_skeleton(load_plan(plan_name)))
    t0 = time()
    try
        design = design_building(struc, params)
        println("Solved in $(round(time() - t0; digits=1)) s")
        _print_numbers(stdout, _joist_numbers(design))
        print_shell_bars(design, design.structure)
    catch err
        println("FAILED after $(round(time() - t0; digits=1)) s")
        showerror(stdout, err, catch_backtrace())
        println()
        print_short_beams(struc)
    end
end

"""Beams shorter than `L_max`: ends, section, and what else meets each end."""
function print_short_beams(struc; L_max = 1.5)
    skel = struc.skeleton
    isempty(struc.beams) && return println("no beams on the structure after the failure")
    col_v = Set(c.vertex_idx for c in struc.columns)
    degree = Dict{Int, Int}()
    for (a, b) in skel.edge_indices
        degree[a] = get(degree, a, 0) + 1
        degree[b] = get(degree, b, 0) + 1
    end
    for (bi, beam) in enumerate(struc.beams)
        L = ustrip(u"m", beam.base.L)
        L <= L_max || continue
        ends = Int[]
        for si in StructuralSynthesizer.segment_indices(beam)
            a, b = skel.edge_indices[struc.segments[si].edge_idx]
            push!(ends, a, b)
        end
        ends = [v for v in ends if count(==(v), ends) == 1]
        desc = join(["v$v $(v in col_v ? "column" : "edges=$(get(degree, v, 0))") " *
                     "at $(round.(StructuralSynthesizer._vertex_xy_m(skel, v); digits=2))"
                     for v in ends], "; ")
        sec = StructuralSynthesizer.section(beam)
        println("beam $bi  L=$(round(L; digits=3)) m  group=$(StructuralSynthesizer.group_id(beam))  " *
                "section=$(sec === nothing ? "none" : sec.name)  $desc")
    end
end

diag(ARGS[1], Symbol(ARGS[2]))
