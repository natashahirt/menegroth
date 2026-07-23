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
    # with AISC 360-16 §E1 / §H1 (design_workflow.jl), so `_column_code_clauses`
    # must key on the section object and yield AISC clauses that ground to
    # aisc-360-16 (or stay explicitly unresolved) — NEVER aci-318-19 (concrete).
    @testset "steel W-shape column grounds to AISC 360-16, never ACI" begin
        wcol = StructuralSynthesizer.ColumnDesignResult(section_obj = W("W14X90"))
        axial_clause, pm_clause = StructuralSynthesizer._column_code_clauses(wcol)
        @test axial_clause == "AISC 360-16 E1"
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
        # E1 (p.33) and H1 (p.77) are confirmed in the corpus → both resolve steel.
        @test ground_check("axial_compression", axial_clause)["source_id"] == "aisc-360-16"
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
end
