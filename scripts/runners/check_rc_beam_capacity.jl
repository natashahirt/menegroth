# Check max φMn in large RC beam catalog for NWC 4000 psi
using Pkg
Pkg.activate("StructuralSizer")
using StructuralSizer
using Unitful

cat = StructuralSizer.large_rc_beams()
mat = StructuralSizer.NWC_4000
fc_psi = 4000.0
fy_psi = 60000.0

best = argmax([StructuralSizer._compute_φMn(s, fc_psi, fy_psi) for s in cat])
best_sec = cat[best]
max_phiMn = StructuralSizer._compute_φMn(best_sec, fc_psi, fy_psi)

println("Large catalog: $(length(cat)) sections")
println("Max φMn = $(round(max_phiMn, digits=1)) kip·ft")
println("Best section: $(best_sec.name) (b=$(best_sec.b), h=$(best_sec.h), $(best_sec.n_bars)#$(best_sec.bar_size))")
println()
println("Required Mu = 1150.3 kip·ft")
println("Sufficient? $(max_phiMn >= 1150.3)")
