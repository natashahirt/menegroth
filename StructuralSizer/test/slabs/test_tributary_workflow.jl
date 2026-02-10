using Test
using Unitful
using Meshes
# Units are re-exported from StructuralSizer (via Asap)
using StructuralSizer
using Asap

# ------------------------------------------------------------------------------
# Optional dependency: StructuralSynthesizer
# This is an end-to-end workflow test that lives at the package boundary.
# ------------------------------------------------------------------------------
const HAS_STRUCTURAL_SYNTHESIZER = let ok = true
    try
        @eval using StructuralSynthesizer
    catch
        ok = false
    end
    ok
end

@testset "Tributary Load Workflow" begin
    if !HAS_STRUCTURAL_SYNTHESIZER
        @info "Skipping (StructuralSynthesizer not available in this environment)"
        @test true
    else
    # Generate a small building
    println("Generating building...")
    skel = gen_medium_office(80.0u"ft", 60.0u"ft", 13.0u"ft", 2, 2, 2)
    struc = BuildingStructure(skel)
    
    # Initialize with floor options - use vault as it has a full sizing implementation
    println("Initializing...")
    initialize!(struc; floor_type=:vault, material=NWC_4000,
                floor_kwargs=(rise=1.0u"m", thickness=0.05u"m"))
    
    @test length(struc.cells) > 0
    @test length(struc.slabs) > 0
    
    # Convert to Asap with TributaryLoads
    println("Converting to Asap with TributaryLoads...")
    to_asap!(struc)
    
    # Check that cell_tributary_loads was populated
    @test !isempty(struc.cell_tributary_loads)
    
    total_loads = sum(length, values(struc.cell_tributary_loads))
    println("Total TributaryLoads created: $total_loads")
    @test total_loads > 0
    
    # Check that model was solved
    @test struc.asap_model.processed
    
    # Show summary
    println("\n--- Summary ---")
    println("Cells: $(length(struc.cells))")
    println("Slabs: $(length(struc.slabs))")
    println("TributaryLoads: $total_loads")
    println("Asap Elements: $(length(struc.asap_model.elements))")
    println("Asap Loads: $(length(struc.asap_model.loads))")
    
    # Debug: Check Asap node positions
    println("\n--- Asap Node Positions (first 10) ---")
    for (i, node) in enumerate(struc.asap_model.nodes[1:min(10, end)])
        pos = node.position
        println("  Node $i: $(pos)")
    end
    
    # Debug: Check bounding box
    all_x = [ustrip(u"m", n.position[1]) for n in struc.asap_model.nodes]
    all_y = [ustrip(u"m", n.position[2]) for n in struc.asap_model.nodes]
    all_z = [ustrip(u"m", n.position[3]) for n in struc.asap_model.nodes]
    println("\n--- Asap Model Bounding Box ---")
    println("  X: $(minimum(all_x)) to $(maximum(all_x)) m")
    println("  Y: $(minimum(all_y)) to $(maximum(all_y)) m")
    println("  Z: $(minimum(all_z)) to $(maximum(all_z)) m")
    
    # Show loads per cell with vertex details
    println("\n--- Loads per Cell (with geometry) ---")
    skel = struc.skeleton
    for cell_idx in sort(collect(keys(struc.cell_tributary_loads)))
        loads = struc.cell_tributary_loads[cell_idx]
        n = length(loads)
        if n > 0
            cell = struc.cells[cell_idx]
            p = StructuralSynthesizer.total_factored_pressure(cell)
            p_kPa = ustrip(u"kPa", p)
            println("\n  Cell $cell_idx: $n TributaryLoads, pressure = $(round(p_kPa, digits=2)) kPa")
            
            # Print cell vertices (in meters)
            v_indices = skel.face_vertex_indices[cell.face_idx]
            println("    Cell vertices (m):")
            for (i, vi) in enumerate(v_indices)
                c = Meshes.coords(skel.vertices[vi])
                x_m = ustrip(u"m", c.x)
                y_m = ustrip(u"m", c.y)
                z_m = ustrip(u"m", c.z)
                println("      v$i: ($x_m, $y_m, $z_m)")
            end
            
            # Print tributary polygon info (from cache)
            cell_tribs = cell_edge_tributaries(struc, cell_idx)
            if !isnothing(cell_tribs)
                println("    Tributary polygons:")
                for (j, trib) in enumerate(cell_tribs)
                    println("      Edge $(trib.local_edge_idx): s=$(round.(trib.s, digits=3)), d=$(round.(trib.d, digits=3)) m")
                    println("        area=$(round(trib.area, digits=3)) m², frac=$(round(trib.fraction*100, digits=1))%")
                    
                    # Reconstruct absolute coords
                    n_verts = length(v_indices)
                    # Get beam endpoints in meters (using CCW order like vis_tributaries)
                    pts_2d = [(ustrip(u"m", Meshes.coords(skel.vertices[vi]).x),
                               ustrip(u"m", Meshes.coords(skel.vertices[vi]).y)) for vi in v_indices]
                    pts_2d = Asap._ensure_ccw(pts_2d)
                    
                    local_idx = trib.local_edge_idx
                    beam_start = pts_2d[local_idx]
                    beam_end = pts_2d[mod1(local_idx + 1, n_verts)]
                    
                    abs_verts = StructuralSizer.vertices(trib, beam_start, beam_end)
                    println("        Absolute vertices (m):")
                    for (k, v) in enumerate(abs_verts)
                        println("          v$k: ($(round(v[1], digits=3)), $(round(v[2], digits=3)))")
                    end
                end
            end
        end
    end
    
    # Test sync_asap! (replaces removed update_slab_loads!)
    println("\n--- Testing load sync ---")
    if length(struc.slabs) > 0
        # Get initial pressure for first cell
        first_cell_idx = struc.slabs[1].cell_indices[1]
        first_cell = struc.cells[first_cell_idx]
        initial_pressure = ustrip(u"Pa", StructuralSynthesizer.total_factored_pressure(first_cell))
        
        # Increase live load
        old_ll = first_cell.live_load
        first_cell.live_load = 2 * old_ll
        
        # Sync loads via sync_asap!
        StructuralSynthesizer.sync_asap!(struc)
        
        # Check that loads were updated
        new_pressure = ustrip(u"Pa", StructuralSynthesizer.total_factored_pressure(first_cell))
        println("Initial pressure: $(round(initial_pressure/1000, digits=2)) kPa")
        println("After 2x live load: $(round(new_pressure/1000, digits=2)) kPa")
        
        @test new_pressure > initial_pressure
        
        # Check that TributaryLoad pressures were updated
        if haskey(struc.cell_tributary_loads, first_cell_idx)
            for tload in struc.cell_tributary_loads[first_cell_idx]
                tload_p = ustrip(u"Pa", tload.pressure)
                @test abs(tload_p - new_pressure) < 1.0  # Within 1 Pa
            end
            println("TributaryLoad pressures updated correctly!")
        end
        
        # Restore
        first_cell.live_load = old_ll
    end
    
    println("\n✓ All tests passed!")
    
    # Visualize with tributary areas
    # println("\n--- Visualizing with tributary areas ---")
    # visualize(struc, mode=:original, color_by=:tributary)
    end
end
