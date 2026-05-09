using StructuralSizer, Unitful

function run_test()
    b, h = 60u"inch", 60u"inch"
    Pu, Mu = 147.0, 0.0

    # Use ReinforcedConcreteMaterial as the pipeline does
    rc_mat = ReinforcedConcreteMaterial(NWC_6000, Rebar_60)

    println("=== check_PM_capacity at Mu=0 ===")
    section = RCColumnSection(b=b, h=h, bar_size=8, n_bars=8, cover=1.5u"inch")
    mat_nt = (fc=6.0, fy=60.0, Es=29000.0, εcu=0.003)
    diagram = generate_PM_diagram(section, mat_nt; n_intermediate=20)
    r = check_PM_capacity(diagram, Pu, Mu)
    println("  adequate=$(r.adequate), util=$(round(r.utilization, digits=4)), governing=$(r.governing)")
    @assert r.adequate "check_PM_capacity must pass for 60×60 at Mu=0"
    println("  ✓ PASS")

    println("\n=== design_column_reinforcement with ReinforcedConcreteMaterial ===")
    sec = design_column_reinforcement(b, h, Pu, Mu, rc_mat)
    println("  Designed: As=$(round(ustrip(u"inch^2", sec.As_total), digits=1)) in², ρg=$(round(sec.ρg, digits=4))")
    println("  ✓ PASS")

    println("\n=== resize_column_with_reinforcement ===")
    orig = RCColumnSection(b=16u"inch", h=16u"inch", bar_size=8, n_bars=8, cover=1.5u"inch")
    new_sec = resize_column_with_reinforcement(orig, b, h, Pu, Mu, rc_mat)
    println("  Resized: As=$(round(ustrip(u"inch^2", new_sec.As_total), digits=1)) in², ρg=$(round(new_sec.ρg, digits=4))")
    println("  ✓ PASS")

    println("\nAll tests passed.")
end

run_test()
