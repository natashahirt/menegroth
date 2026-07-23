# =============================================================================
# DesignState + corpus grounding (Harness Phase 1, P0 + P1)
#
# Vertical slice on the medium_office generator: build a real flat-plate design,
# project it into the unified DesignState export form, round-trip it through
# JSON3, and assert fidelity of the params snapshot, stable element ids, and at
# least one LIVE building-code corpus citation. Also exercises the grounding
# adapter directly, including the adversarial unresolved / mixed-edition cases.
# =============================================================================

using StructuralSynthesizer
using StructuralSizer
using Test
using Unitful
using JSON3
using Dates  # DateTime arithmetic for the timestamp-independence test
using Asap  # registers u"kgCO2e" and Asap unit module

# Headless: no display server, no visualization serialization.
ENV["SS_ENABLE_VISUALIZATION"] = "false"

@testset "DesignState + corpus grounding" begin
    # Small DDM-applicable flat-plate building (2×2 bays, 1 story → 9 columns).
    skel  = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
    struc = BuildingStructure(skel)
    params = DesignParameters(
        name               = "harness_p1_medium_office",
        floor              = FlatPlateOptions(method = DDM()),
        materials          = MaterialOptions(concrete = NWC_4000, rebar = Rebar_60),
        max_iterations     = 3,
        skip_visualization = true,
    )
    design = design_building(struc, params; tc = TraceCollector())

    # ─── P1: grounding adapter resolves only confirmed corpus clauses ─────────
    @testset "ground_check resolves only confirmed corpus clauses" begin
        # Confirmed present in the corpus (aci-318-19): §22.4 P-M interaction.
        g = ground_check("pm_interaction", "ACI 318-19 §22.4")
        @test g["resolved"] == true
        @test g["source_id"] == "aci-318-19"
        @test g["section"] == "22.4"
        # Citation id is namespaced by matched section, requested clause, AND
        # check so neither distinct checks on the same section (P1 collision
        # testset) nor distinct sub-clauses under one check (P2-B testset) collide.
        @test g["id"] == "aci-318-19:22.4:22.4:pm_interaction"

        # Sub-clauses resolve to their parent section anchor (22.4.2 → 22.4).
        gsub = ground_check("axial_compression", "ACI 318-19 §22.4.2")
        @test gsub["resolved"] == true
        @test gsub["section"] == "22.4"
        @test gsub["clause"] == "22.4.2"

        # IBC is NOT in the corpus → must stay explicitly unresolved (no guess).
        u = ground_check("bearing", "IBC 2021 Table 1806.2")
        @test u["resolved"] == false
        @test u["source_id"] === nothing

        # Edition normalization: AISC 360-22 is absent from the corpus and must
        # NOT be conflated with the AISC 360-16 entry for the same clause.
        e = ground_check("combined_forces", "AISC 360-22 H1")
        @test e["resolved"] == false
        @test e["source_id"] === nothing
    end

    # ─── P0-A: steel/AISC checks NEVER ground to concrete (ACI) ───────────────
    # A steel check must resolve to aisc-360-16 or be left explicitly unresolved
    # — it must never fall through to an ACI (concrete) provision. This is the
    # core wrong-citation safety guarantee.
    @testset "steel checks resolve to AISC 360-16 or stay unresolved, never ACI" begin
        # AISC 360-16 IS in the corpus → grounds to the steel source.
        for (name, clause, sect) in (
            ("flexure", "AISC 360-16 F2", "F2"),
            ("shear",   "AISC 360-16 G2", "G2"),
            ("pm_interaction_compression", "AISC 360-16 H1", "H1"),
        )
            s = ground_check(name, clause)
            @test s["resolved"] == true
            @test s["source_id"] == "aisc-360-16"       # steel, NOT concrete
            @test s["source_id"] != "aci-318-19"
            @test s["section"] == sect
        end

        # AISC shapes whose governing section is not wired (HSS F7/G4) must stay
        # UNRESOLVED — never silently re-attributed to a confirmed section or to
        # a concrete clause.
        for clause in ("AISC 360-16 F7", "AISC 360-16 G4")
            h = ground_check("flexure", clause)
            @test h["resolved"] == false
            @test h["source_id"] === nothing
        end

        # A compound string whose FIRST (governing) family is AISC must never
        # cross over to the trailing ACI part — defense-in-depth against the
        # original wrong-citation bug.
        x = ground_check("flexure", "AISC 360-22 F2 / ACI 318-19 §9.5")
        @test x["resolved"] == false
        @test x["source_id"] === nothing        # never crosses to the ACI part
    end

    # ─── P0-A (columns): steel W-shape column cites AISC, never ACI ────────────
    # Regression for the second-cycle defect: `_diagnose_column` hardcoded ACI
    # clauses for ALL columns. A steel column's axial + P-M ratios are computed
    # with AISC 360-16 §E3 (flexural buckling) / §H1 (design_workflow.jl), so
    # `_column_code_clauses` must key on the section object and yield AISC clauses
    # that ground to aisc-360-16 (or stay explicitly unresolved) — NEVER
    # aci-318-19 (concrete). The axial clause is §E3 (the governing limit state),
    # NOT §E1 (general provisions / gross yield).
    @testset "steel W-shape column grounds to AISC 360-16, never ACI" begin
        wcol = StructuralSynthesizer.ColumnDesignResult(section_obj = W("W14X90"))
        axial_clause, pm_clause = StructuralSynthesizer._column_code_clauses(wcol)
        @test axial_clause == "AISC 360-16 E3"
        @test axial_clause != "AISC 360-16 E1"   # governing limit state, not general provisions
        @test pm_clause    == "AISC 360-16 H1"

        for (name, clause) in (("axial_compression", axial_clause),
                               ("pm_interaction",    pm_clause))
            g = ground_check(name, clause)
            # Steel source or explicitly unresolved — never a concrete provision.
            if g["resolved"]
                @test g["source_id"] == "aisc-360-16"
            else
                @test g["source_id"] === nothing
            end
            @test g["source_id"] != "aci-318-19"
        end
        # E3 (p.35) and H1 (p.77) are confirmed in the corpus → both resolve steel.
        @test ground_check("axial_compression", axial_clause)["source_id"] == "aisc-360-16"
        @test ground_check("axial_compression", axial_clause)["section"]   == "E3"
        @test ground_check("axial_compression", axial_clause)["page"]      == 35
        @test ground_check("pm_interaction",    pm_clause)["source_id"]     == "aisc-360-16"

        # No regression for concrete: RC column sections still cite ACI 318-19.
        rc_cr = design.columns[first(sort!(collect(keys(design.columns))))]
        rc_axial, rc_pm = StructuralSynthesizer._column_code_clauses(rc_cr)
        @test startswith(rc_axial, "ACI 318-19")
        @test startswith(rc_pm,    "ACI 318-19")
        @test ground_check("pm_interaction", rc_pm)["source_id"] == "aci-318-19"

        # Unsized / unsupported section → empty clauses → unresolved, not mis-cited.
        empty_cr = StructuralSynthesizer.ColumnDesignResult()  # section_obj = nothing
        @test StructuralSynthesizer._column_code_clauses(empty_cr) == ("", "")
        gemp = ground_check("axial_compression", "")
        @test gemp["resolved"] == false
        @test gemp["source_id"] === nothing
    end

    # ─── P1: /diagnose surfaces the citation locator per check ────────────────
    @testset "diagnose per-check dicts carry a citation locator" begin
        diag = design_to_diagnose(design)
        @test !isempty(diag["columns"])
        col = first(diag["columns"])
        pm = first(filter(ch -> get(ch, "name", "") == "pm_interaction", col["checks"]))
        @test haskey(pm, "citation")
        @test pm["citation"]["resolved"] == true
        @test pm["citation"]["source_id"] == "aci-318-19"
    end

    # ─── P0: DesignState projection + JSON3 round-trip ────────────────────────
    ds = design_to_design_state(design)

    @testset "DesignState shape and stable ids" begin
        @test ds["schema"] == "design-state/v1"
        for k in ("params", "summary", "units", "elements", "citations", "trace")
            @test haskey(ds, k)
        end
        # Tiered trace projection (not the raw dump) — default disclosure tier.
        @test ds["trace"]["tier"] == "failures"

        # Every element carries a deterministic string id "type/index".
        @test !isempty(ds["elements"])
        cols = filter(e -> e["type"] == "column", ds["elements"])
        @test length(cols) == 9
        @test all(e -> e["id"] == string(e["type"], "/", e["index"]), ds["elements"])
        # At least one element explicitly references its governing corpus citation.
        @test any(e -> !isempty(e["citation_ids"]), ds["elements"])
    end

    @testset "at least one grounded corpus citation" begin
        @test ds["citations"] isa AbstractDict
        resolved = [c for c in values(ds["citations"]) if c["resolved"] == true]
        @test !isempty(resolved)
        r = first(resolved)
        @test r["source_id"] == "aci-318-19"
        @test r["page"] isa Integer
        # Stable id = source_id : matched-section : requested-clause : check-name.
        @test r["id"] == string(r["source_id"], ":", r["section"], ":", r["clause"], ":", r["check_name"])
    end

    @testset "round-trips through JSON3 with fidelity" begin
        parsed = JSON3.read(JSON3.write(ds))

        # (a) params snapshot fidelity
        @test parsed["params"]["name"] == ds["params"]["name"]
        @test parsed["params"]["max_iterations"] == ds["params"]["max_iterations"]
        @test parsed["params"]["floor_options_type"] == ds["params"]["floor_options_type"]
        @test parsed["params"]["deflection_limit"] == ds["params"]["deflection_limit"]

        # (b) element result ids survive the round-trip
        @test length(parsed["elements"]) == length(ds["elements"])
        @test parsed["elements"][1]["id"] == ds["elements"][1]["id"]

        # (d) at least one grounded citation survives with its explicit locator
        rt_resolved = [c for c in values(parsed["citations"]) if c["resolved"] == true]
        @test !isempty(rt_resolved)
        @test first(rt_resolved)["source_id"] == "aci-318-19"
    end

    # ─── P1: citation ids do not collide across distinct checks ───────────────
    # Column punching (§22.6), slab punching (§22.6) and foundation punching
    # (§22.6.5 → parent §22.6) all resolve to the SAME corpus section. The id
    # must still distinguish them so an element's governing_citation_id can only
    # dereference its OWN citation metadata.
    @testset "punching citations on the same section do not collide" begin
        c_col  = ground_check("punching_shear_col",  "ACI 318-19 §22.6")
        c_slab = ground_check("punching_shear_slab", "ACI 318-19 §22.6")
        c_fdn  = ground_check("punching_shear_fdn",  "ACI 318-19 §22.6.5")

        # Same corpus anchor (section 22.6, aci-318-19) …
        @test c_col["source_id"] == c_slab["source_id"] == c_fdn["source_id"] == "aci-318-19"
        @test c_col["section"] == c_slab["section"] == c_fdn["section"] == "22.6"
        # … but three DISTINCT ids.
        @test c_col["id"] != c_slab["id"]
        @test c_col["id"] != c_fdn["id"]
        @test c_slab["id"] != c_fdn["id"]
    end

    @testset "governing_citation_id dereferences its own element's check" begin
        # For every element that names a governing citation, that id must resolve
        # (in the shared registry) to a citation whose check_name is the element's
        # OWN governing check — no last-writer-wins cross-element aliasing.
        n_checked = 0
        types_checked = Set{String}()
        for e in ds["elements"]
            gcid = e["governing_citation_id"]
            gcid === nothing && continue
            @test haskey(ds["citations"], gcid)
            @test ds["citations"][gcid]["check_name"] == e["governing_check"]
            n_checked += 1
            push!(types_checked, e["type"])
        end
        @test n_checked > 0
        # Columns reliably expose a governing citation in this flat-plate slice.
        @test "column" in types_checked
    end

    # ─── P2: export byte stream is deterministic / stable ─────────────────────
    @testset "DesignState serialization is byte-stable" begin
        ds_again = design_to_design_state(design)
        # Two independent projections of the same design serialize identically.
        @test JSON3.write(ds) == JSON3.write(ds_again)
        # Canonical key order: registries are emitted with sorted keys (mirrors
        # the sort already used for layers_present), so a content-hashing linker
        # sees a reproducible byte stream regardless of Julia's Dict hash order.
        for reg in ("citations", "params", "units")
            ks = collect(keys(ds[reg]))
            @test ks == sort(ks)
        end
    end

    # ─── P2-A: non-finite floats + tuples/named-tuples serialize safely ───────
    # A degenerate ratio (e.g. 0/0 capacity) can surface NaN/Inf. `_canonicalize`
    # (and `_json_scalar`) must coerce them to a JSON-safe value so `JSON3.write`
    # never emits bare `NaN` / `Infinity` tokens — which are invalid JSON and NOT
    # round-trippable — and must recurse into Tuple / NamedTuple payloads.
    @testset "NaN/Inf ratios canonicalize to valid, round-trippable JSON" begin
        payload = Dict{String, Any}(
            "ratio_nan"  => NaN,
            "ratio_inf"  => Inf,
            "ratio_ninf" => -Inf,
            "ratio_ok"   => 0.5,
            "nested"     => Any[1.0, NaN, Dict("x" => Inf)],
            "tuple"      => (1.0, NaN, :sym),
            "named"      => (a = NaN, b = 2.0),
        )
        canon = StructuralSynthesizer._canonicalize(payload)
        js = JSON3.write(canon)
        # No bare NaN / Infinity tokens survive to the byte stream.
        @test !occursin("NaN", js)
        @test !occursin("Infinity", js)
        # Round-trips cleanly through JSON3 (would throw on bare NaN/Infinity).
        parsed = JSON3.read(js)
        @test parsed["ratio_nan"]  === nothing
        @test parsed["ratio_inf"]  === nothing
        @test parsed["ratio_ninf"] === nothing
        @test parsed["ratio_ok"]   == 0.5
        # Tuple recursed element-wise (NaN → null, Symbol → string).
        @test parsed["tuple"][1] == 1.0
        @test parsed["tuple"][2] === nothing
        @test parsed["tuple"][3] == "sym"
        # NamedTuple flattened to a sorted-key dict; its NaN field coerced.
        @test parsed["named"]["a"] === nothing
        @test parsed["named"]["b"] == 2.0
        # `_json_scalar` applies the same guard at the struct-field boundary.
        @test StructuralSynthesizer._json_scalar(NaN) === nothing
        @test StructuralSynthesizer._json_scalar(Inf) === nothing
        @test StructuralSynthesizer._json_scalar(-Inf) === nothing
        @test StructuralSynthesizer._json_scalar(3.0) == 3.0
    end

    # ─── P2-B: sub-clauses under one check do not collapse onto one id ─────────
    # §22.4.2 (axial) and §22.4 (P-M) both anchor to corpus section 22.4. Under a
    # single shared check_name they must still get DISTINCT ids so an element's
    # governing_citation_id can never dereference the other sub-clause's metadata.
    @testset "sub-clauses under the same check_name get distinct citation ids" begin
        a = ground_check("axial_compression", "ACI 318-19 §22.4.2")
        b = ground_check("axial_compression", "ACI 318-19 §22.4")
        @test a["section"] == b["section"] == "22.4"   # same corpus anchor …
        @test a["clause"] == "22.4.2"
        @test b["clause"] == "22.4"
        @test a["id"] != b["id"]                        # … but distinct ids.
        # Id embeds the requested clause, not just the matched section.
        @test a["id"] == "aci-318-19:22.4:22.4.2:axial_compression"
        @test b["id"] == "aci-318-19:22.4:22.4:axial_compression"
    end

    # ─── TASK-1 (a): steel-column axial diagnostic applies §E3 flexural buckling ──
    # The diagnostic axial capacity used to be φPn = 0.9·Fy·Ag (gross yield), which
    # IGNORES buckling and OVERSTATES capacity → understated utilization. It now
    # reuses the vetted Chapter E routine (`_steel_column_ϕPnc` → get_ϕPn), so for a
    # slender steel column the capacity must be STRICTLY BELOW gross yield (buckling
    # is applied) and the E3-based utilization strictly ABOVE the old gross-yield
    # ratio. Its citation must resolve to aisc-360-16 §E3 — NOT E1, NOT aci-318-19.
    @testset "steel column axial diagnostic applies E3 buckling, not gross yield" begin
        # copy() so we do not mutate the shared W-catalog object; attach A992 steel
        # like the sizer does (ISymmSection.material starts nothing for a bare W()).
        sec = copy(W("W14X90"))
        sec.material = A992_Steel
        Fy_Pa = ustrip(u"Pa", sec.material.Fy)
        A_m2  = ustrip(u"m^2", sec.A)
        φPn_yield = 0.9 * Fy_Pa * A_m2   # old §E1 gross-yield UPPER bound (unconservative)

        # Slender column (L = 12 m, K = 1): §E3 flexural buckling must reduce capacity.
        L = 12.0u"m"
        ϕPnc = StructuralSynthesizer._steel_column_ϕPnc(sec, L; Kx = 1.0, Ky = 1.0)
        @test ϕPnc !== nothing
        @test ϕPnc > 0
        @test ϕPnc < φPn_yield           # buckling IS applied: capacity below gross yield

        # Therefore the E3-based utilization for the SAME demand is strictly greater
        # than the old gross-yield ratio would have reported (the bug understated it).
        Pu = 1.0e6  # N (arbitrary compression demand)
        @test Pu / ϕPnc > Pu / φPn_yield

        # Monotone in slenderness: a longer column buckles more → lower capacity.
        ϕPnc_longer = StructuralSynthesizer._steel_column_ϕPnc(sec, 16.0u"m"; Kx = 1.0, Ky = 1.0)
        @test ϕPnc_longer < ϕPnc

        # Citation: steel-column axial_compression grounds to aisc-360-16 §E3.
        axial_clause, _ = StructuralSynthesizer._column_code_clauses(
            StructuralSynthesizer.ColumnDesignResult(section_obj = sec))
        @test axial_clause == "AISC 360-16 E3"
        @test axial_clause != "AISC 360-16 E1"
        g = ground_check("axial_compression", axial_clause)
        @test g["resolved"] == true
        @test g["source_id"] == "aisc-360-16"
        @test g["source_id"] != "aci-318-19"
        @test g["section"]   == "E3"
        @test g["page"]      == 35
    end

    # ─── TASK-2 (b): hashed bytes are timestamp-independent ───────────────────────
    # `generated_at` is a wall-clock timestamp. Two STRUCTURALLY IDENTICAL designs
    # built at different times must serialize to identical HASHED bytes, otherwise a
    # content hash keyed on the export is meaningless. The timestamp now lives in a
    # separate, non-hashed "envelope" and is excluded from `design_state_content_bytes`.
    @testset "content bytes are timestamp-independent (envelope is non-hashed)" begin
        original_created = design.created
        ds1 = design_to_design_state(design)

        # Rebuild the SAME design at a DIFFERENT wall-clock time.
        design.created = original_created + Dates.Hour(37)
        ds2 = design_to_design_state(design)
        design.created = original_created  # restore

        # The timestamps differ and are still recoverable from the envelope …
        @test design_state_generated_at(ds1) != design_state_generated_at(ds2)
        @test design_state_generated_at(ds1) == string(original_created)
        # … and the full export bytes differ (timestamp present, just quarantined) …
        @test JSON3.write(ds1) != JSON3.write(ds2)
        # … but the HASHED content bytes are IDENTICAL (timestamp excluded).
        @test design_state_content_bytes(ds1) == design_state_content_bytes(ds2)
        # And the content bytes never carry the envelope / timestamp.
        @test !occursin("generated_at", design_state_content_bytes(ds1))
        @test !occursin("envelope",     design_state_content_bytes(ds1))
    end

    # ─── TASK-2 (b) regression: run-varying TRACE timings must not perturb hash ───
    # The test above reuses ONE in-memory `solver_trace`, so it only proves the
    # `generated_at` envelope is excluded — NOT that the trace's own wall-clock
    # fields are. `serialize_trace_event` emits `"t"` (seconds since trace start)
    # and `build_stage_timeline` emits `"duration_s"` (a stage wall-clock
    # duration); both are clock-derived and differ run-to-run for a STRUCTURALLY
    # IDENTICAL solve. Two designs that differ ONLY in those trace timings must
    # still hash identically, or the content hash is again meaningless.
    @testset "content bytes ignore run-varying trace timings (duration_s / t)" begin
        original_trace = design.solver_trace
        # Two traces with IDENTICAL structural content (same layer/stage/element/
        # type/data) but DIFFERENT timestamps → different `t` and `duration_s`.
        # An :enter/:exit pair on the :workflow layer yields both a serialized
        # event (`t`) and a stage_timeline entry (`duration_s`), and both event
        # types survive the default :failures tier filter.
        mk_trace(t_enter, t_exit) = StructuralSizer.TraceEvent[
            StructuralSizer.TraceEvent(t_enter, :workflow, "design_building", "", :enter, Dict{String, Any}()),
            StructuralSizer.TraceEvent(t_exit,  :workflow, "design_building", "", :exit,  Dict{String, Any}()),
        ]

        design.solver_trace = mk_trace(0.100, 1.334)   # duration_s = 1.234
        ds_fast = design_to_design_state(design)
        design.solver_trace = mk_trace(2.500, 12.376)  # duration_s = 9.876
        ds_slow = design_to_design_state(design)
        design.solver_trace = original_trace           # restore fixture

        # Sanity: the timings genuinely differ and ARE present in the full export …
        @test occursin("duration_s", JSON3.write(ds_fast))
        @test JSON3.write(ds_fast) != JSON3.write(ds_slow)
        # … yet the HASHED content bytes are byte-identical. Since the two traces
        # carry DIFFERENT `t`/`duration_s`, byte-equality is itself proof that both
        # timing fields are excluded from the hash (a leak would differ the bytes).
        @test design_state_content_bytes(ds_fast) == design_state_content_bytes(ds_slow)
        # Belt-and-suspenders: the timeline duration field is gone from the hash.
        @test !occursin("duration_s", design_state_content_bytes(ds_fast))
    end

    # ─── TASK-3 (c): registry is stable under a cosmetic citation-id collision ────
    # Because the id embeds source/section/requested-clause/check but NOT the
    # verbatim `code_clause`, two DIFFERENT `code_clause` SPELLINGS of the SAME
    # provision normalize to the SAME id (same source/section/page — only the
    # verbatim string differs). A last-writer-wins `citations[cid] = cit` would let
    # whichever element registered last flip the stored (cosmetic) spelling.
    # `_register_citation!` KEEPS THE FIRST registration so the stored metadata is
    # stable (order-dependent by construction, but the difference is cosmetic).
    @testset "registry keeps first on citation-id collision with differing metadata" begin
        c1 = ground_check("punching_shear_col", "ACI 318-19 §22.6")
        c2 = ground_check("punching_shear_col", "ACI 318-19 22.6")  # different spelling
        @test c1["id"] == c2["id"]                    # same normalized id …
        @test c1["code_clause"] != c2["code_clause"]  # … but distinct verbatim metadata
        @test !isequal(c1, c2)

        citations = Dict{String, Any}()
        id1 = StructuralSynthesizer._register_citation!(citations, c1)
        id2 = StructuralSynthesizer._register_citation!(citations, c2)
        @test id1 == id2
        @test length(citations) == 1
        # First registration is authoritative; the colliding second does NOT overwrite it.
        @test citations[id1]["code_clause"] == c1["code_clause"]
        @test citations[id1]["code_clause"] != c2["code_clause"]

        # Genuinely identical citations still dedup (no spurious collision handling).
        citations2 = Dict{String, Any}()
        StructuralSynthesizer._register_citation!(citations2, c1)
        StructuralSynthesizer._register_citation!(citations2, ground_check("punching_shear_col", "ACI 318-19 §22.6"))
        @test length(citations2) == 1
    end

    # ─── FIX-CYCLE regression: UNVERIFIED column propagates through /diagnose ──────
    # A steel column whose AISC 360-16 §E3/§E4 buckling capacity is unavailable is marked
    # UNVERIFIED with a NaN axial/interaction sentinel (`_populate_column_results!`) so it
    # cannot silently pass on the unconservative gross-yield bound. That state was correct on
    # the SUMMARY path but was NOT propagated to the per-element `/diagnose` path, which
    # (1) CRASHED `design_to_diagnose` (`max(nothing, nothing)` on the serialized null ratios
    # in `_diagnose_lever_impacts` under a flat-plate punching strategy) and (2) MISLABELED the
    # column `"punching_shear_col"` (every NaN comparison in `column_diagnostic_governing_check`
    # is false → fall-through). This block reproduces both defects against the pre-fix code.
    @testset "unverified column: no crash, labeled axial_compression_unverified, fails" begin
        # (b, unit) Governing check must detect the NaN sentinel FIRST — not fall through to
        # "punching_shear_col". Punching present-and-passing (ratio 0.5) is the exact
        # fall-through trap: pre-fix this returned "punching_shear_col".
        nan_col = StructuralSynthesizer.ColumnDesignResult(
            section_obj       = W("W14X90"),
            axial_ratio       = NaN,
            interaction_ratio = NaN,
            ok                = false,
            punching = StructuralSynthesizer.PunchingDesignResult(
                Vu = 0.0u"kN", φVc = 0.0u"kN", ratio = 0.5, ok = true,
                critical_perimeter = 1.0u"m", tributary_area = 1.0u"m^2"),
        )
        @test StructuralSynthesizer.column_diagnostic_governing_check(nan_col) ==
              "axial_compression_unverified"

        # (a, c) Full /diagnose integration on the real flat-plate design (grow_columns
        # punching strategy). Inject the unverified sentinel into a real column, then confirm
        # design_to_diagnose does NOT crash and the column is reported as unverified + failing.
        col_key = first(sort!(collect(keys(design.columns))))
        cr      = design.columns[col_key]
        orig    = (cr.axial_ratio, cr.interaction_ratio, cr.ok)
        try
            cr.axial_ratio       = NaN
            cr.interaction_ratio = NaN
            cr.ok                = false

            # (a) Must not throw. Pre-fix this raised a MethodError in _diagnose_lever_impacts.
            diag2 = design_to_diagnose(design)
            @test diag2 isa AbstractDict

            cdict = only(filter(c -> c["id"] == col_key, diag2["columns"]))
            # (b) Correct label — NOT "punching_shear_col".
            @test cdict["governing_check"] == "axial_compression_unverified"
            @test cdict["governing_check"] != "punching_shear_col"
            # (c) The column reads as failing, and its element-level governing_ratio is a finite
            # failing ratio (≥ 1.0) — never a null that would poison downstream max/argmax.
            @test cdict["ok"] == false
            @test cdict["governing_ratio"] isa Real
            @test cdict["governing_ratio"] >= 1.0
            # The per-check ratios stay honestly null (unverified, not zero utilization).
            @test cdict["axial_ratio"] === nothing
            @test cdict["interaction_ratio"] === nothing

            # Export propagation: the GET /result serializer must also survive the unverified
            # column. `_round_val(NaN)` → `nothing`, so a strict `Float64` APIColumnResult field
            # would throw `convert(Float64, nothing)`; the nullable field reports null + ok=false.
            col_results = StructuralSynthesizer._serialize_columns(design, design.params.display_units)
            api_col = only(filter(r -> r.id == col_key, col_results))
            @test api_col.axial_ratio === nothing
            @test api_col.interaction_ratio === nothing
            @test api_col.ok == false

            # (c) The already-correct SUMMARY path must remain in agreement: the design fails and
            # the critical element names the unverified state.
            StructuralSynthesizer._compute_design_summary!(design, struc, params)
            @test design.summary.all_checks_pass == false
            @test occursin("unverified", design.summary.critical_element)
        finally
            # Restore the fixture column and refresh the summary so later state is unperturbed.
            cr.axial_ratio, cr.interaction_ratio, cr.ok = orig
            StructuralSynthesizer._compute_design_summary!(design, struc, params)
        end
    end

    # ─── FIX-CYCLE #3 regression: unverified column on the MISSED sibling consumers ─────
    # Prior cycles fixed the diagnose + `_serialize_columns` paths. The visualization frame
    # serializer (`GET /result`, DEFAULT `skip_visualization=false`), the `report_summary`
    # ranges, and the top-level DesignState `status` were NOT guarded. Each block below is a
    # genuine guard: it CRASHES or MISREPORTS against the pre-fix code.
    du = design.params.display_units

    # (a) P0 — the DEFAULT GET /result visualization path. Pre-fix, `_serialize_visualization_
    # frame_elements` did `max(NaN, NaN)` → `_round_val` → `nothing` into the strict
    # `Float64` `utilization_ratio` field → `convert(Float64, nothing)` MethodError, crashing
    # the whole /result response. The unverified element must render as failing/attention —
    # `utilization_ratio` null or a finite failing sentinel (≥ 1.0), NEVER 0 (safe) — with ok=false.
    @testset "P0: unverified column survives visualization frame serialization" begin
        col_key = first(sort!(collect(keys(design.columns))))
        cr      = design.columns[col_key]
        orig    = (cr.axial_ratio, cr.interaction_ratio, cr.ok)
        try
            cr.axial_ratio       = NaN
            cr.interaction_ratio = NaN
            cr.ok                = false

            model = isnothing(design.asap_model) ? struc.asap_model : design.asap_model
            @test !isnothing(model)  # the FE model exists even when skip_visualization=true
            model.processed || Asap.process!(model)
            isempty(model.u) && Asap.solve!(model)

            # (a) Must not throw. Pre-fix this raised a MethodError on the strict Float64 field.
            frame_elems = StructuralSynthesizer._serialize_visualization_frame_elements(design, model, du)
            @test frame_elems isa AbstractVector

            # The unverified column's frame element(s) render as failing, never as safe 0.
            col_elems = filter(e -> e.element_type == "column" && e.element_id == col_key, frame_elems)
            @test !isempty(col_elems)
            for e in col_elems
                @test e.ok == false
                u = e.utilization_ratio
                # null OR a finite failing sentinel (≥ 1.0); a raw NaN or a 0.0 (safe) is a bug.
                @test u === nothing || (u isa Real && isfinite(u) && u >= 1.0)
                @test u !== 0.0
            end

            # FULL /result path: exercise the top-level `design_to_json` serializer with
            # visualization ENABLED (`skip_visualization = false`, the production DEFAULT), not
            # just the frame helper in isolation. Pre-fix this threw `convert(Float64, nothing)`
            # inside `_serialize_visualization` → `_serialize_visualization_frame_elements`,
            # crashing the entire GET /result response for a design containing an unverified
            # column. Post-fix it must complete and the unverified element must still render as
            # failing/attention (null or ≥ 1.0, never a safe 0).
            orig_skip = design.params.skip_visualization
            try
                design.params.skip_visualization = false
                out = design_to_json(design)                    # must NOT throw
                @test out.visualization !== nothing             # viz actually serialized
                out_cols = filter(e -> e.element_type == "column" && e.element_id == col_key,
                                  out.visualization.frame_elements)
                @test !isempty(out_cols)
                for e in out_cols
                    @test e.ok == false
                    u = e.utilization_ratio
                    @test u === nothing || (u isa Real && isfinite(u) && u >= 1.0)
                    @test u !== 0.0
                end
            finally
                design.params.skip_visualization = orig_skip
            end
        finally
            cr.axial_ratio, cr.interaction_ratio, cr.ok = orig
            StructuralSynthesizer._compute_design_summary!(design, struc, params)
        end
    end

    # (b) report_summary with a MIX of verified + unverified columns. Pre-fix, a single
    # unverified column poisoned the numeric ranges: `minimum`/`maximum` PROPAGATE NaN so the
    # verified columns' ranges collapsed to `null`, and `argmax` picked the NaN column as the
    # numeric "worst". Post-fix the verified ranges are preserved and the unverified column is
    # still counted as failing (and surfaced via `n_unverified`).
    @testset "report_summary mix: verified ranges preserved, unverified counted failing" begin
        @test length(design.columns) >= 2  # need a genuine mix (verified + one unverified)
        col_key = first(sort!(collect(keys(design.columns))))
        cr      = design.columns[col_key]
        orig    = (cr.axial_ratio, cr.interaction_ratio, cr.ok)
        try
            cr.axial_ratio       = NaN
            cr.interaction_ratio = NaN
            cr.ok                = false

            sc = StructuralSynthesizer._summary_columns(design, du)

            # The unverified column is counted as failing and surfaced, not silently dropped.
            @test sc["n_unverified"] == 1
            @test sc["failing"] >= 1

            # The verified columns' ranges are still reported — NOT collapsed to null by the
            # single unverified column (this is the exact NaN-propagation bug being guarded).
            rr = sc["ratio_range"]
            @test rr["axial"]["min"] !== nothing
            @test rr["axial"]["max"] !== nothing
            @test rr["interaction"]["min"] !== nothing
            @test rr["interaction"]["max"] !== nothing

            # The numeric "worst" is a real (finite) verified column, not the NaN column.
            @test sc["worst_interaction"]["ratio"] !== nothing
        finally
            cr.axial_ratio, cr.interaction_ratio, cr.ok = orig
            StructuralSynthesizer._compute_design_summary!(design, struc, params)
        end
    end

    # (P2) Top-level DesignState `status` must honestly reflect the overall verdict. Pre-fix it
    # was hardcoded `"ok"`, so a linker reading the export saw "ok" while an element was
    # unverified/failing.
    @testset "design_state status is fail when a column is unverified" begin
        col_key = first(sort!(collect(keys(design.columns))))
        cr      = design.columns[col_key]
        orig    = (cr.axial_ratio, cr.interaction_ratio, cr.ok)
        try
            cr.axial_ratio       = NaN
            cr.interaction_ratio = NaN
            cr.ok                = false
            StructuralSynthesizer._compute_design_summary!(design, struc, params)

            ds = design_to_design_state(design)
            @test ds["status"] == "fail"
        finally
            cr.axial_ratio, cr.interaction_ratio, cr.ok = orig
            StructuralSynthesizer._compute_design_summary!(design, struc, params)
        end
    end
end
