# Compare strong- vs weak-axis P-M capacity of square RC columns whose
# perimeter bar layout is not 90°-symmetric (n_bars = 6, 10, 14).
ENV["SS_ENABLE_VISUALIZATION"] = "false"
using StructuralSizer, Unitful

mat = StructuralSizer.to_material_tuple(StructuralSizer.NWC_4000, 60.0, 29000.0)

for (sz, nb, bs) in [(16, 6, 8), (16, 8, 8), (20, 10, 8), (24, 14, 9)]
    s = RCColumnSection(b = sz * u"inch", h = sz * u"inch", bar_size = bs, n_bars = nb)
    dx = StructuralSizer.generate_PM_diagram(s, mat)
    dy = StructuralSizer.generate_PM_diagram(s, mat, StructuralSizer.WeakAxis())
    println("\n$(s.name)  bars (x,y): ",
            [(round(ustrip(b.x), digits=1), round(ustrip(b.y), digits=1)) for b in s.bars])
    for Pu in (0.0, 100.0, 300.0, 500.0)
        cx = StructuralSizer.check_PM_capacity(dx, Pu, 0.0).φMn_at_Pu
        cy = StructuralSizer.check_PM_capacity(dy, Pu, 0.0).φMn_at_Pu
        println("  Pu=$(Pu) kip  φMnx=$(round(cx, digits=1))  φMny=$(round(cy, digits=1))  ratio y/x=$(round(cy/cx, digits=3))")
    end
end
