# Parity: FEA(source = :building) vs FEA(source = :slab) on each flat-plate slab
# of a prepared (unsized) building, at one trial thickness.
#   SS_ENABLE_VISUALIZATION=false SS_SKIP_SOLVER_WARMUP=true julia --project=StructuralSynthesizer scripts/runners/fp_building_parity.jl
using StructuralSynthesizer, StructuralSizer, Asap, Unitful, Printf

const SS = StructuralSynthesizer
const SZ = StructuralSizer

skel = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 2)
struc = BuildingStructure(skel)
params = DesignParameters(
    floor = FlatPlateOptions(),
    materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
    max_iterations = 5,
    skip_visualization = true,
)
t = @elapsed SS.prepare!(struc, params)
@printf("prepare!: %.1f s, shells %d, nodes %d\n", t,
        length(struc.asap_model.shell_elements), length(struc.asap_model.nodes))

fc = NWC_4000.fc′
γ = NWC_4000.ρ
Ecs = SZ.Ec(fc, ustrip(SZ.pcf, γ))
h = 8.0u"inch"
kipft = SZ.kip * u"ft"

for (si, slab) in enumerate(struc.slabs)
    SZ.building_fea_available(struc, slab) || (println("slab $si: not meshed"); continue)
    cols = SZ.find_supporting_columns(struc, Set(slab.cell_indices))
    tb = @elapsed rb = SZ.run_moment_analysis(SZ.FEA(source = :building), struc, slab, cols, h,
                                              fc, Ecs, γ; ν_concrete = 0.2)
    tb2 = @elapsed SZ.run_moment_analysis(SZ.FEA(source = :building), struc, slab, cols, h,
                                          fc, Ecs, γ; ν_concrete = 0.2)
    ts = @elapsed rs = SZ.run_moment_analysis(SZ.FEA(), struc, slab, cols, h, fc, Ecs, γ;
                                              ν_concrete = 0.2)
    A = sum(ustrip(u"m^2", struc.cells[ci].area) for ci in slab.cell_indices)
    @printf("\nslab %d: %d columns, %.1f m², qu = %.2f kPa, time building %.1f s (repeat %.1f s), slab %.1f s\n",
            si, length(cols), A, ustrip(u"kPa", rs.qu), tb, tb2, ts)
    @printf("  ΣVu  building %.1f kip   slab %.1f kip   qu·A %.1f kip\n",
            ustrip(SZ.kip, sum(rb.column_shears)), ustrip(SZ.kip, sum(rs.column_shears)),
            ustrip(SZ.kip, rs.qu * A * u"m^2"))
    @printf("  M⁻ext %.1f / %.1f   M⁻int %.1f / %.1f   M⁺ %.1f / %.1f  kip·ft (building / slab)\n",
            ustrip(kipft, rb.M_neg_ext), ustrip(kipft, rs.M_neg_ext),
            ustrip(kipft, rb.M_neg_int), ustrip(kipft, rs.M_neg_int),
            ustrip(kipft, rb.M_pos), ustrip(kipft, rs.M_pos))
    @printf("  Δ_panel %.3f / %.3f in\n", ustrip(u"inch", rb.fea_Δ_panel),
            ustrip(u"inch", rs.fea_Δ_panel))
    println("  col  pos        Vu_b   Vu_s   Mub_b  Mub_s")
    for (i, c) in enumerate(cols)
        @printf("  %3d  %-9s %6.1f %6.1f %6.1f %6.1f\n", i, string(c.position),
                ustrip(SZ.kip, rb.column_shears[i]), ustrip(SZ.kip, rs.column_shears[i]),
                ustrip(kipft, rb.unbalanced_moments[i]), ustrip(kipft, rs.unbalanced_moments[i]))
    end
end
