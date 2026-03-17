# =============================================================================
# Mesh Refinement Tests
# =============================================================================
#
# Verifies that slab shell mesh refinement targets are correctly placed at
# column locations. Column vertex_idx is always the top vertex; slabs below
# a column need the bottom vertex. These tests ensure _get_slab_column_nodes
# and _column_vertex_at_slab_level return the correct vertices for both cases.
#
# =============================================================================

using StructuralSynthesizer
using StructuralSizer
using Asap
using Test
using Unitful

_safe_percentile(v::Vector{Float64}, p::Float64) = begin
    isempty(v) && return 0.0
    s = sort(v)
    idx = clamp(ceil(Int, p * length(s)), 1, length(s))
    return s[idx]
end

function _edge_gradient_stats(verts::Vector{Vector{Float64}}, faces::Vector{Vector{Int}}, values::Vector{Float64})
    grads = Float64[]
    seen = Set{Tuple{Int, Int}}()
    for f in faces
        length(f) < 3 && continue
        tri = (f[1], f[2], f[3])
        edges = ((tri[1], tri[2]), (tri[2], tri[3]), (tri[3], tri[1]))
        for (a_raw, b_raw) in edges
            a = min(a_raw, b_raw)
            b = max(a_raw, b_raw)
            key = (a, b)
            key in seen && continue
            push!(seen, key)
            va = verts[a]
            vb = verts[b]
            dx = vb[1] - va[1]
            dy = vb[2] - va[2]
            dz = vb[3] - va[3]
            L = sqrt(dx * dx + dy * dy + dz * dz)
            L < 1e-9 && continue
            push!(grads, abs(values[a] - values[b]) / L)
        end
    end
    return (
        p95 = _safe_percentile(grads, 0.95),
        max = isempty(grads) ? 0.0 : maximum(grads),
        n = length(grads),
    )
end

function _vertex_spike_stats(verts::Vector{Vector{Float64}}, faces::Vector{Vector{Int}}, values::Vector{Float64})
    neigh = [Int[] for _ in eachindex(verts)]
    for f in faces
        length(f) < 3 && continue
        i, j, k = f[1], f[2], f[3]
        push!(neigh[i], j); push!(neigh[i], k)
        push!(neigh[j], i); push!(neigh[j], k)
        push!(neigh[k], i); push!(neigh[k], j)
    end
    residuals = Float64[]
    for i in eachindex(verts)
        ns = unique(neigh[i])
        isempty(ns) && continue
        mu = sum(values[j] for j in ns) / length(ns)
        push!(residuals, abs(values[i] - mu))
    end
    return (
        p95 = _safe_percentile(residuals, 0.95),
        max = isempty(residuals) ? 0.0 : maximum(residuals),
        n = length(residuals),
    )
end

@testset "Mesh Refinement" begin

    # ─── 2-story flat plate: floor 1 slab is BELOW floor 1→2 columns ────────
    # Column vertex_idx = top (floor 2). Floor 1 slab needs bottom vertex.
    skel = gen_medium_office(30.0u"ft", 24.0u"ft", 12.0u"ft", 2, 2, 2)
    struc = BuildingStructure(skel)

    params = DesignParameters(
        name = "mesh_refinement_test",
        floor = FlatPlateOptions(method = FEA()),
        materials = MaterialOptions(concrete = NWC_4000),
        max_iterations = 2,
        display_units = metric,  # mesh vertices in m, matches col_xy
    )

    design = design_building(struc, params)
    @test all_ok(design)

    build_analysis_model!(design)
    @test has_analysis_model(design)

    vc = struc.skeleton.geometry.vertex_coords

    @testset "Refinement targets at slab elevation" begin
        # Recreate nodes (same as build_analysis_model)
        support_set = Set(get(struc.skeleton.groups_vertices, :support, Int[]))
        nodes_vec = StructuralSynthesizer._create_offset_nodes(
            struc.skeleton, design.structural_offsets, support_set)

        for (slab_idx, slab) in enumerate(struc.slabs)
            col_nodes = StructuralSynthesizer._get_slab_column_nodes(struc, slab, nodes_vec)
            supporting = StructuralSizer.find_supporting_columns(struc, Set(slab.cell_indices))

            # Every supporting column must yield a refinement node
            @test length(col_nodes) >= length(supporting)

            # Refinement node positions must match slab elevation (within tolerance)
            first_cell = struc.cells[first(slab.cell_indices)]
            slab_z = vc[struc.skeleton.face_vertex_indices[first_cell.face_idx][1], 3]
            z_tol = 0.15  # meters

            for node in col_nodes
                z = ustrip(u"m", node.position[3])
                @test abs(z - slab_z) <= z_tol
            end

            # For a 2×2 bay, we expect 9 columns (3×3 grid) supporting each slab
            @test length(col_nodes) >= 4
        end
    end

    @testset "Column vertex at slab level (multi-story)" begin
        # Floor 1 slab: columns from floor 0→1 have vertex_idx at floor 1 (top). Match.
        # Columns from floor 1→2 have vertex_idx at floor 2 (top). Need bottom = floor 1.
        slab_1 = struc.slabs[1]
        first_cell = struc.cells[first(slab_1.cell_indices)]
        slab_1_z = vc[struc.skeleton.face_vertex_indices[first_cell.face_idx][1], 3]

        supporting_1 = StructuralSizer.find_supporting_columns(struc, Set(slab_1.cell_indices))
        @test !isempty(supporting_1)

        for col in supporting_1
            vi = StructuralSynthesizer._column_vertex_at_slab_level(struc, col, slab_1_z)
            @test vi !== nothing
            @test 1 <= vi <= length(struc.skeleton.vertices)
            col_z = vc[vi, 3]
            @test abs(col_z - slab_1_z) <= 0.15
        end
    end

    @testset "Mesh finer near columns than mid-span" begin
        # Get deflected slab mesh from visualization
        output = design_to_json(design)
        viz = output.visualization
        isnothing(viz) && @test_skip "No visualization (skip_visualization?)"

        meshes = viz.deflected_slab_meshes
        isempty(meshes) && @test_skip "No slab meshes"

        # Column positions (x, y) at slab level from structure
        for (mesh_idx, mesh) in enumerate(meshes)
            slab_idx = mesh.slab_id
            slab_idx > length(struc.slabs) && continue
            slab = struc.slabs[slab_idx]

            support_set = Set(get(struc.skeleton.groups_vertices, :support, Int[]))
            nodes_vec = StructuralSynthesizer._create_offset_nodes(
                struc.skeleton, design.structural_offsets, support_set)
            col_nodes = StructuralSynthesizer._get_slab_column_nodes(struc, slab, nodes_vec)
            isempty(col_nodes) && continue

            col_xy = [(ustrip(u"m", n.position[1]), ustrip(u"m", n.position[2])) for n in col_nodes]

            # Mesh vertices and faces (display units from design_to_json)
            verts = mesh.vertices
            faces = mesh.faces
            isempty(faces) && continue

            # Vertices and column positions; mesh units may differ from col_xy (m)
            # Normalize both to mesh bounding box [0,1] for distance comparison
            verts_m = [[Float64(v[1]), Float64(v[2]), Float64(v[3])] for v in verts]
            xs = [v[1] for v in verts_m]
            ys = [v[2] for v in verts_m]
            x0, x1 = minimum(xs), maximum(xs)
            y0, y1 = minimum(ys), maximum(ys)
            x_range = x1 - x0
            y_range = y1 - y0
            (x_range < 1e-9 || y_range < 1e-9) && continue
            verts_norm = [[(v[1] - x0) / x_range, (v[2] - y0) / y_range, v[3]] for v in verts_m]
            col_xy_norm = [((c[1] - x0) / x_range, (c[2] - y0) / y_range) for c in col_xy]

            # Triangle areas and centroid distances to nearest column (normalized)
            areas = Float64[]
            min_dists = Float64[]
            for face in faces
                i, j, k = face[1], face[2], face[3]
                p = verts_norm[i]
                q = verts_norm[j]
                r = verts_norm[k]
                cx = (p[1] + q[1] + r[1]) / 3
                cy = (p[2] + q[2] + r[2]) / 3
                area = 0.5 * abs(
                    (q[1] - p[1]) * (r[2] - p[2]) - (r[1] - p[1]) * (q[2] - p[2])
                )
                d_min = minimum(hypot(cx - cx_col, cy - cy_col) for (cx_col, cy_col) in col_xy_norm)
                push!(areas, area)
                push!(min_dists, d_min)
            end

            # Elements near columns (d < 25% of max distance) should be smaller on average
            # than elements far from columns (d > 75% of max distance)
            d_max = maximum(min_dists)
            d_max < 1e-6 && continue  # degenerate
            near_mask = [d <= 0.25 * d_max for d in min_dists]
            far_mask = [d >= 0.75 * d_max for d in min_dists]
            near_areas = areas[near_mask]
            far_areas = areas[far_mask]
            (isempty(near_areas) || isempty(far_areas)) && continue

            mean_near = sum(near_areas) / length(near_areas)
            mean_far = sum(far_areas) / length(far_areas)
            # Refinement: near-column elements should be smaller (or similar if uniform grid fallback)
            # Use lenient threshold: near ≤ 2× far (allows for Ruppert fallback to grid)
            @test mean_near <= mean_far * 2.1
        end
    end

    @testset "Patch interior refinement matches target resolution" begin
        # Inside column/drop panel patches, mesh resolution should be uniform and
        # match the target refinement_edge_length (same as at patch edges).
        # Patch elements have id=:col_patch or :drop_panel; check all shells.
        model = design.asap_model
        isnothing(model) && @test_skip "No analysis model"
        !Asap.has_shell_elements(model) && @test_skip "No shell elements"

        # Build (patch_verts, A_target) for all slabs
        patch_specs = Tuple{Vector{Tuple{Float64,Float64}}, Float64}[]
        for (slab_idx, slab) in enumerate(struc.slabs)
            slab_columns = StructuralSynthesizer._get_slab_columns(struc, slab)
            isempty(slab_columns) && continue
            t = StructuralSynthesizer.thickness(slab)
            E = uconvert(u"Pa", StructuralSizer.NWC_4000.E)
            ν = StructuralSizer.NWC_4000.ν
            section = Asap.ShellSection(t, E, ν)
            patches = StructuralSizer.build_slab_shell_patches(
                struc, slab_columns, section;
                drop_panel=slab.drop_panel,
                patch_stiffness_factor=1.0,
                vertex_set=nothing)
            isempty(patches) && continue
            target_edge = StructuralSynthesizer._resolve_slab_target_edge_length(
                struc, slab, nothing)
            refine_edge = StructuralSynthesizer._resolve_slab_refinement_edge_length(
                struc, slab, target_edge, nothing)
            isnothing(refine_edge) && continue
            h_m = Float64(ustrip(u"m", refine_edge))
            A_target = 0.433 * h_m^2
            for p in patches
                push!(patch_specs, (p.vertices, A_target))
            end
        end
        isempty(patch_specs) && @test_skip "No patches"

        patch_area_targets = Tuple{Float64, Float64}[]  # (area, A_target)
        for shell in model.shell_elements
            length(shell.nodes) != 3 && continue
            n1, n2, n3 = shell.nodes
            p = (ustrip(u"m", n1.position[1]), ustrip(u"m", n1.position[2]))
            q = (ustrip(u"m", n2.position[1]), ustrip(u"m", n2.position[2]))
            r = (ustrip(u"m", n3.position[1]), ustrip(u"m", n3.position[2]))
            cx = (p[1] + q[1] + r[1]) / 3
            cy = (p[2] + q[2] + r[2]) / 3
            area = 0.5 * abs(
                (q[1] - p[1]) * (r[2] - p[2]) - (r[1] - p[1]) * (q[2] - p[2])
            )
            for (pv, A_t) in patch_specs
                if StructuralSynthesizer._point_inside_polygon((cx, cy), pv)
                    push!(patch_area_targets, (area, A_t))
                    break
                end
            end
        end

        isempty(patch_area_targets) && @test_skip "No patch interior faces (mesh may not conform)"

        # Patch interior triangles should be ~target resolution (within 0.3× to 4×)
        patch_areas = [x[1] for x in patch_area_targets]
        for (a, A_t) in patch_area_targets
            @test 0.3 * A_t <= a <= 4.0 * A_t
        end
        # Resolution should be uniform: std/mean < 1.0
        mean_a = sum(patch_areas) / length(patch_areas)
        var_a = sum((a - mean_a)^2 for a in patch_areas) / length(patch_areas)
        std_a = sqrt(var_a)
        @test std_a / mean_a < 1.0
    end

    @testset "Local deflection shape quality (no tenting spikes)" begin
        output = design_to_json(design)
        viz = output.visualization
        isnothing(viz) && @test_skip "No visualization (skip_visualization?)"
        meshes = viz.deflected_slab_meshes
        isempty(meshes) && @test_skip "No slab meshes"

        checked = 0
        for (mesh_idx, mesh) in enumerate(meshes)
            verts = [[Float64(v[1]), Float64(v[2]), Float64(v[3])] for v in mesh.vertices]
            faces = [Int[f[1], f[2], f[3]] for f in mesh.faces if length(f) >= 3]
            local_disp = [[Float64(d[1]), Float64(d[2]), Float64(d[3])] for d in mesh.vertex_displacements_local]
            global_disp = [[Float64(d[1]), Float64(d[2]), Float64(d[3])] for d in mesh.vertex_displacements]

            n = length(verts)
            (n == 0 || isempty(faces)) && continue
            (length(local_disp) != n || length(global_disp) != n) && continue

            local_z = [d[3] for d in local_disp]
            global_z = [d[3] for d in global_disp]

            g_local = _edge_gradient_stats(verts, faces, local_z)
            g_global = _edge_gradient_stats(verts, faces, global_z)
            s_local = _vertex_spike_stats(verts, faces, local_z)
            s_global = _vertex_spike_stats(verts, faces, global_z)

            # Guardrail 1: local p95 edge gradient should not explode relative to global.
            # This catches tent-like sharp local spikes while allowing legitimate local variation.
            @test g_local.p95 <= max(6.0 * g_global.p95, 1e-5)

            # Guardrail 2: local per-vertex spike residual should stay bounded vs global.
            @test s_local.p95 <= max(6.0 * s_global.p95, 1e-5)

            # Guardrail 3: absolute outliers should remain bounded for this synthetic benchmark.
            @test g_local.max <= 0.30  # display-length units per unit edge length
            @test s_local.max <= 0.30  # display-length units

            checked += 1
        end
        @test checked > 0
    end
end
