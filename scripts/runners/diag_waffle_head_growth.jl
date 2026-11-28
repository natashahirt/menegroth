# One 6 x 5 m panel of the 30 in qualification waffle, column at one corner.
# Prints why each solid-head growth step is taken or rejected.
#
#     SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true \
#         julia --project=StructuralSynthesizer scripts/runners/diag_waffle_head_growth.jl

using Unitful
using Asap
using StructuralSynthesizer
using StructuralSizer

const SY = StructuralSynthesizer
const SS = StructuralSizer

Lx, Ly = 6.0, 5.0
pan = ustrip(u"m", 30.0u"inch")
outline = [(0.0, 0.0), (Lx, 0.0), (Lx, Ly), (0.0, Ly)]
arr = SS.modular_rib_arrangement(outline; angle = 0.0, spacing = (pan, pan), origin = (0.0, 0.0))
pressure = ustrip(u"Pa", 194.0u"psf")
kw = (concrete = SS.NWC_4000, depth = 11.0u"inch", d_head = 9.5u"inch",
      bw = 4.0u"inch", d_rib = 9.5u"inch", h_rib = 11.0u"inch",
      fy = SS.Rebar_60.Fy, topping = 5.0u"inch",
      column_size = 22.0u"inch", column_height = 3.0u"m")
columns = [(0.0, 0.0)]
free_loops = (outline,)
heads = SS.ColumnSolidHead[SS.seed_column_head(arr, xy) for xy in columns]
println("bays in arrangement: ", length(arr.bays), "   seed bays: ", heads[1].bays)

function solve(hs)
    SY._solve_arrangement_heads(arr, hs, columns, pressure; free_loops = free_loops, kw...)
end

for step in 1:8
    _, checks = solve(heads)
    c = checks[1]
    fails = [(round(r.ratio; digits = 2), r.outward) for r in c.ribs if !r.ok]
    println("\nstep $step  bays=$(length(heads[1].bays))  ok=$(c.ok)  governing=$(c.governing)",
            "  column=$(round(c.column.ratio; digits = 2))  growth_ratio=$(round(SY._head_growth_ratio(c); digits = 2))")
    println("  failing ribs: ", fails)
    c.ok && break
    SY._head_grows(c) || (println("  does not grow"); break)
    dir = SY._head_growth_direction(c)
    println("  direction: ", dir)
    grown = try
        SS.grow_checked_column_head(arr, heads[1], merge(c, (direction = dir,));
                                    taken = Int[], free_loops = free_loops)
    catch err
        println("  grow threw: ", sprint(showerror, err)); break
    end
    grown.bays == heads[1].bays && (println("  grow returned the same bays"); break)
    trial = [grown]
    tc = try
        solve(trial)[2][1]
    catch err
        println("  trial solve threw: ", sprint(showerror, err)); break
    end
    println("  trial bays=$(length(grown.bays))  trial growth_ratio=$(round(SY._head_growth_ratio(tc); digits = 2))",
            "  trial governing=$(tc.governing)")
    SY._head_growth_ratio(tc) < SY._head_growth_ratio(c) - 1e-9 || (println("  ratio did not fall"); break)
    global heads = trial
end
