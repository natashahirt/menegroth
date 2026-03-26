ENV["SS_ENABLE_VISUALIZATION"] = "false"
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] = "false"

using Test
using StructuralSizer: TraceEvent, TraceCollector, emit!,
    serialize_trace_event, build_stage_timeline, filter_trace,
    TRACE_TIERS, TRACE_LAYERS, TIER_EVENT_FILTERS, TIER_LAYER_FILTERS

@testset "Trace Serializer" begin

    @testset "serialize_trace_event" begin
        ev = TraceEvent(1.23456, :optimizer, "optimize_discrete", "col_3", :decision,
                        Dict{String, Any}("reason" => "best_ratio", "ratio" => 0.85))
        d = serialize_trace_event(ev)
        @test d["t"] == 1.235
        @test d["layer"] == "optimizer"
        @test d["stage"] == "optimize_discrete"
        @test d["type"] == "decision"
        @test d["element"] == "col_3"
        @test d["data"]["reason"] == "best_ratio"
        @test d["data"]["ratio"] == 0.85

        ev2 = TraceEvent(0.0, :pipeline, "design_building", "", :enter, Dict{String, Any}())
        d2 = serialize_trace_event(ev2)
        @test !haskey(d2, "element")
        @test !haskey(d2, "data")
    end

    @testset "build_stage_timeline" begin
        events = TraceEvent[
            TraceEvent(0.0, :pipeline, "design_building", "", :enter, Dict{String,Any}()),
            TraceEvent(0.1, :workflow, "size_slabs", "", :enter, Dict{String,Any}()),
            TraceEvent(0.5, :optimizer, "optimize_discrete", "col_1", :decision, Dict{String,Any}()),
            TraceEvent(1.0, :workflow, "size_slabs", "", :exit, Dict{String,Any}()),
            TraceEvent(1.5, :workflow, "size_beams_columns", "", :enter, Dict{String,Any}()),
            TraceEvent(2.0, :workflow, "size_beams_columns", "", :exit, Dict{String,Any}()),
            TraceEvent(2.5, :pipeline, "design_building", "", :exit, Dict{String,Any}()),
        ]
        tl = build_stage_timeline(events)

        @test length(tl) == 3
        @test tl[1]["stage"] == "size_slabs"
        @test tl[1]["duration_s"] ≈ 0.9 atol=0.01
        @test tl[2]["stage"] == "size_beams_columns"
        @test tl[2]["duration_s"] ≈ 0.5 atol=0.01
        @test tl[3]["stage"] == "design_building"
        @test tl[3]["duration_s"] ≈ 2.5 atol=0.01

        events_unmatched = TraceEvent[
            TraceEvent(0.0, :pipeline, "design_building", "", :enter, Dict{String,Any}()),
        ]
        tl2 = build_stage_timeline(events_unmatched)
        @test isempty(tl2)
    end

    @testset "filter_trace" begin
        events = TraceEvent[
            TraceEvent(0.0, :pipeline, "design_building", "", :enter, Dict{String,Any}()),
            TraceEvent(0.1, :workflow, "size_slabs", "", :enter, Dict{String,Any}()),
            TraceEvent(0.2, :slab, "size_flat_plate!", "slab_1", :iteration,
                       Dict{String,Any}("phase" => "A", "h_in" => 8.0)),
            TraceEvent(0.3, :slab, "size_flat_plate!", "slab_1", :failure,
                       Dict{String,Any}("reason" => "deflection")),
            TraceEvent(0.4, :optimizer, "optimize_discrete", "col_1", :decision,
                       Dict{String,Any}("section" => "W14x90")),
            TraceEvent(0.5, :optimizer, "optimize_discrete", "col_1", :fallback,
                       Dict{String,Any}("reason" => "infeasible")),
            TraceEvent(0.6, :workflow, "size_slabs", "", :exit, Dict{String,Any}()),
            TraceEvent(0.7, :pipeline, "design_building", "", :exit, Dict{String,Any}()),
        ]

        # Summary: only enter/exit at pipeline/workflow
        s = filter_trace(events; tier=:summary)
        @test length(s) == 4
        @test all(ev -> ev.event_type in (:enter, :exit), s)
        @test all(ev -> ev.layer in (:pipeline, :workflow), s)

        # Failures: enter/exit + failure/fallback at all layers
        f = filter_trace(events; tier=:failures)
        @test length(f) == 6  # 4 enter/exit + failure + fallback
        @test any(ev -> ev.event_type == :failure, f)
        @test any(ev -> ev.event_type == :fallback, f)
        @test !any(ev -> ev.event_type == :iteration, f)
        @test !any(ev -> ev.event_type == :decision, f)

        # Decisions: everything except... well, this tier includes all types
        d = filter_trace(events; tier=:decisions)
        @test length(d) == 8
        @test any(ev -> ev.event_type == :decision, d)
        @test any(ev -> ev.event_type == :iteration, d)

        # Full: same as decisions for this event set
        fl = filter_trace(events; tier=:full)
        @test length(fl) == 8

        # Element filter
        col_only = filter_trace(events; tier=:full, element="col_1")
        @test length(col_only) == 2
        @test all(ev -> ev.element_id == "col_1", col_only)

        # Layer filter
        slab_only = filter_trace(events; tier=:full, layer=:slab)
        @test length(slab_only) == 2
        @test all(ev -> ev.layer == :slab, slab_only)

        # Combined element + layer
        combo = filter_trace(events; tier=:full, element="slab_1", layer=:slab)
        @test length(combo) == 2
        @test all(ev -> ev.element_id == "slab_1" && ev.layer == :slab, combo)

        # Element that doesn't exist
        empty_result = filter_trace(events; tier=:full, element="nonexistent")
        @test isempty(empty_result)

        # Invalid tier
        @test_throws ErrorException filter_trace(events; tier=:bogus)
    end

    @testset "Tier constants completeness" begin
        @test Set(keys(TIER_EVENT_FILTERS)) == Set(TRACE_TIERS)
        @test Set(keys(TIER_LAYER_FILTERS)) == Set(TRACE_TIERS)

        # Each tier should be a superset of the previous
        @test TIER_EVENT_FILTERS[:summary]   ⊆ TIER_EVENT_FILTERS[:failures]
        @test TIER_EVENT_FILTERS[:failures]  ⊆ TIER_EVENT_FILTERS[:decisions]
        @test TIER_EVENT_FILTERS[:decisions] ⊆ TIER_EVENT_FILTERS[:full]

        @test TIER_LAYER_FILTERS[:summary]   ⊆ TIER_LAYER_FILTERS[:failures]
        @test TIER_LAYER_FILTERS[:failures]  ⊆ TIER_LAYER_FILTERS[:decisions]
        @test TIER_LAYER_FILTERS[:decisions] ⊆ TIER_LAYER_FILTERS[:full]
    end
end

println("\n✓ All trace serializer tests passed")
