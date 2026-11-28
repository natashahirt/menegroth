# Print the outer-section values for the ACI 421.1R-99 Ch. 7 example.
ENV["SS_ENABLE_VISUALIZATION"] = "false"
using Unitful, Asap, StructuralSizer
const SS = StructuralSizer

c1, c2, d = 12.0u"inch", 20.0u"inch", 5.62u"inch"
Vu, My = 110.0u"kip", 50.0u"kip*ft"
fc = 4000.0u"psi"

for αd in (22.5, 24.8)
    ext = (αd - 5.62 / 2) * u"inch"
    sec = SS.reinforcement_outer_section(c1, c2, d, ext)
    p = SS.critical_section_properties(sec.points, d; closed = sec.closed)
    chk = SS.outer_section_check(c1, c2, d, ext, fc, :interior;
                                 Vu = Vu, M_about_x = 0.0u"kip*ft", M_about_y = My, φ = 0.85)
    println("αd=$αd  b0=$(round(u"inch", p.b0; digits=2))  Ac=$(round(u"inch^2", p.Ac; digits=1))  ",
            "Iy=$(round(u"inch^4", p.Iy; digits=0))  vu=$(round(u"psi", chk.vu; digits=1))  ",
            "vu/φ=$(round(ustrip(u"psi", chk.vu) / 0.85; digits=1))  ok=$(chk.ok)")
end

inputs = (c1 = c1, c2 = c2, Vu = Vu, Mx = 0.0u"kip*ft", My = My)
r = SS.design_outer_lines(2.25u"inch", 2.75u"inch", d, fc, :interior, inputs; φ = 0.85)
println("lines needed (φ=0.85): n=$(r.n) ok=$(r.ok) vu=$(round(u"psi", r.check.vu; digits=1))")

for pos in (:interior, :edge, :corner)
    sec = SS.reinforcement_outer_section(c1, c2, d, 10.0u"inch"; position = pos)
    p = SS.critical_section_properties(sec.points, d; closed = sec.closed)
    println("$pos  b0=$(round(u"inch", p.b0; digits=2))  area=$(round(u"inch^2", sec.area; digits=1))  ",
            "xc=$(round(u"inch", p.xc; digits=2))  yc=$(round(u"inch", p.yc; digits=2))")
end

studs = SS.design_shear_studs(295.0u"psi", fc, 20 / 12, 40, 86.5u"inch", 5.625u"inch", :interior,
                              51000.0u"psi", 0.375u"inch"; c1 = c1, c2 = c2, Vu = Vu,
                              M_about_x = 0.0u"kip*ft", M_about_y = My)
println("studs: rails=$(studs.n_rails) lines=$(studs.n_studs_per_rail) s=$(round(u"inch", studs.s; digits=2)) outer_ok=$(studs.outer_ok)")
legacy = SS.design_shear_studs(295.0u"psi", fc, 20 / 12, 40, 86.5u"inch", 5.625u"inch", :interior,
                               51000.0u"psi", 0.375u"inch")
println("legacy (no forces): rails=$(legacy.n_rails) lines=$(legacy.n_studs_per_rail) outer_ok=$(legacy.outer_ok)")
