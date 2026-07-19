# TEMPORARY diagnostic (Run 3 design). Deleted after use.
ENV["SS_ENABLE_VISUALIZATION"] = "false"
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] = "false"

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using Asap, StructuralSizer, StructuralSynthesizer, Unitful
const SR = StructuralSizer
const SS = StructuralSynthesizer

println("nthreads = ", Threads.nthreads())

function diag_flat_plate(nstories)
    skel  = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, nstories)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name = "diag",
        floor = FlatPlateOptions(method = DDM()),
        materials = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
        max_iterations = 5,
        skip_visualization = true,
        foundation_options = FoundationParameters(
            soil = SR.medium_sand,
            options = SR.FoundationOptions(strategy = :all_spread)),
    )
    SS.prepare!(struc, params)
    println("\n== FLAT PLATE 54x42, 2x2x$nstories ==")
    println("n_slabs = ", length(struc.slabs))
    println("n_columns = ", length(struc.columns))
    println("slab_parallel_batches = ", struc.slab_parallel_batches)
    # supporting columns per slab
    col_sets = Vector{Set{Int}}()
    for (i, slab) in enumerate(struc.slabs)
        cells = Set(slab.cell_indices)
        s = Set{Int}()
        for (ci, col) in enumerate(struc.columns)
            if !isempty(col.tributary_cell_indices) &&
               !isempty(intersect(col.tributary_cell_indices, cells))
                push!(s, ci)
            end
        end
        push!(col_sets, s)
        println("slab $i: cells=$(length(slab.cell_indices)) supporting_cols=$(sort(collect(s)))")
    end
    # pairwise sharing
    println("shared-column pairs:")
    for i in 1:length(col_sets), j in (i+1):length(col_sets)
        sh = intersect(col_sets[i], col_sets[j])
        isempty(sh) || println("  slab$i & slab$j share $(sort(collect(sh)))")
    end
end

function diag_beam_column()
    skel  = gen_medium_office(30.0u"ft", 24.0u"ft", 12.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name = "diag_bc",
        floor = SR.VaultOptions(lambda = 8.0, material = SR.NWC_4000),
        max_iterations = 5,
        skip_visualization = true,
    )
    SS.prepare!(struc, params)
    println("\n== VAULT/BEAM-COLUMN 30x24, 2x2x1 ==")
    println("n_slabs = ", length(struc.slabs))
    println("slab_parallel_batches = ", struc.slab_parallel_batches)
    println("n_beams = ", length(struc.beams))
    # build beam groups
    SS.build_member_groups!(struc; member_type=:beams)
    println("n_beam_member_groups = ", length(struc.member_groups))
    println("beam group ids (sorted) = ", sort(collect(keys(struc.member_groups))))
    for (gid, mg) in struc.member_groups
        println("  group $gid: members=$(mg.member_indices)")
    end
end

diag_flat_plate(1)
diag_flat_plate(3)
diag_beam_column()
println("\nDONE-DIAG")
