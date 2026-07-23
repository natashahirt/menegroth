# =============================================================================
# Corpus Grounding — explanation-layer join: code_clause → live corpus reference
#
# This is the P1 "explanation-layer" seam. It maps the human-readable
# `code_clause` strings that checkers and /diagnose already emit
# (e.g. "ACI 318-19 §22.6", "AISC 360-16 H1") onto a LIVE building-code corpus
# reference `{source_id, clause, page}` so an agent (via /diagnose and the
# trace-lookup tool) can cite the governing provision.
#
# SCOPE — this module attaches CITATION METADATA ONLY. It never touches a
# numeric ratio, demand, capacity, or pass/fail decision. No equations, factors,
# or checks are defined or modified here.
#
# GROUNDING PROVENANCE — every entry in `CORPUS_CITATIONS` was confirmed to
# exist in the repo corpus via the `menegroth-corpus` MCP tools
# (`corpus.list_sources` + `corpus.get_clause`) before being wired here:
#   • aci-318-19  — "ACI 318-19 (with commentary, ACI 318R-19)"  (corpus.list_sources family=aci)
#   • aisc-360-16 — "AISC 360-16"                                (corpus.list_sources family=aisc)
# `page` is the printed page number as listed in each standard's own table of
# contents (the value surfaced by `corpus.get_clause` in its TOC / running-header
# context) — i.e. the page a reader opens in the published document. For AISC
# that is the printed spec page (the "16.1-" volume prefix is omitted).
#
# EDITION NORMALIZATION — the codebase mixes editions (ACI 318-11 vs 318-19,
# AISC 360-16 vs 360-22). Editions that are NOT in the corpus (AISC 360-22,
# IBC 2021, and ACI 318-11 clauses whose pages were not confirmed) are
# intentionally absent below: `ground_check` returns an explicitly UNRESOLVED
# citation (source_id = nothing) for them rather than silently conflating them
# with a different edition or guessing a page.
#
# CODE-FAMILY SAFETY — the governing code family is fixed by the FIRST parsed
# candidate of a `code_clause` (which is chosen upstream from the member's
# MATERIAL, not by string position). `ground_check` NEVER crosses code families
# to find a citable clause: a steel (AISC) check resolves to `aisc-360-16` or is
# left explicitly unresolved — it can never fall through to an ACI (concrete)
# provision, and vice versa. This is a safety invariant, not a convenience.
# =============================================================================

"""
    CORPUS_CITATIONS

Confirmed join table `(edition, section) → (source_id, page)`.

Keys use a canonical edition token ("ACI 318-19", "AISC 360-16") and the
top-level section number/letter (e.g. "22.6", "H1"). Sub-clauses (e.g. "22.4.2")
resolve to their parent section via `ground_check`'s suffix-stripping fallback,
since the corpus is indexed at section granularity and the section start page is
the correct citation anchor.

Every `(source_id, page)` pair was verified against the corpus with
`corpus.get_clause` (see module header for the confirmed source ids). Do NOT add
an entry here without confirming it the same way.
"""
const CORPUS_CITATIONS = Dict{Tuple{String, String}, NamedTuple{(:source_id, :page), Tuple{String, Int}}}(
    # ── ACI 318-19 (corpus: aci-318-19) — pages per ACI 318-19 table of contents ──
    ("ACI 318-19", "9.5")  => (source_id = "aci-318-19", page = 133),  # Beams — Design strength
    ("ACI 318-19", "22.4") => (source_id = "aci-318-19", page = 400),  # Axial / combined flexure-axial strength
    ("ACI 318-19", "22.5") => (source_id = "aci-318-19", page = 401),  # One-way shear strength
    ("ACI 318-19", "22.6") => (source_id = "aci-318-19", page = 411),  # Two-way (punching) shear strength
    ("ACI 318-19", "24.2") => (source_id = "aci-318-19", page = 455),  # Serviceability — Deflections
    # ── AISC 360-16 (corpus: aisc-360-16) — printed spec pages per AISC 360-16 TOC ──
    # Reachable emitters (see StructuralSizer AISCChecker.explain_feasibility,
    # StructuralSynthesizer _diagnose_beam / _diagnose_column): beam flexure →
    # "AISC 360-16 F2", beam shear → "AISC 360-16 G2", steel-column axial
    # compression → "AISC 360-16 E3" (flexural buckling — the GOVERNING limit state
    # of the column axial ratio computed in design_workflow.jl via
    # `StructuralSizer.get_ϕPn`; §E1 is the Chapter E general provision that fixes
    # φc = 0.90), and P-M interaction → "AISC 360-16 H1". Pages verified against the
    # corpus TOC via corpus.get_clause (E1 p.33, E3 p.35, F2 p.47, G2 p.70, H1 p.77;
    # the TOC lists "E3. Flexural Buckling … 35").
    # NOTE (§E7): `StructuralSizer.get_ϕPn` computes Pn = Fcr·Ae (§E7 Eq. E7-1),
    # i.e. it applies the §E7 EFFECTIVE-AREA reduction on top of the §E3/§E4
    # buckling stress. §E3 is deliberately cited as the PRIMARY (flexural-buckling)
    # limit state for the column axial ratio because that governs the common
    # non-slender rolled-W case (where Ae = Ag). §E7 is the governing provision
    # only for slender-element sections and thin HSS walls; it is not separately
    # wired as its own citation, so the §E3 reference stands in for the whole
    # Chapter E axial-compression computation. (corpus: aisc-360-16 — §E7 p.42.)
    # Shape-specific steel flexure/shear provisions the checker also implements
    # (HSS: F7/F8, G4/G5) are intentionally NOT wired here: their pages are
    # unconfirmed, so `ground_check` leaves them explicitly unresolved rather than
    # citing the wrong page — never mis-attributing them to a confirmed section.
    ("AISC 360-16", "E1") => (source_id = "aisc-360-16", page = 33),   # Compression — General Provisions (φc = 0.90)
    ("AISC 360-16", "E3") => (source_id = "aisc-360-16", page = 35),   # Flexural buckling — governing column axial limit state
    ("AISC 360-16", "F2") => (source_id = "aisc-360-16", page = 47),   # Flexure — compact I-shapes / LTB
    ("AISC 360-16", "G2") => (source_id = "aisc-360-16", page = 70),   # Shear — I-shaped members
    ("AISC 360-16", "H1") => (source_id = "aisc-360-16", page = 77),   # Combined flexure + axial (P-M)
)

"""
    _parse_clause_candidates(code_clause) -> Vector{Tuple{String, String}}

Parse a human `code_clause` string into an ordered list of `(edition, section)`
candidates. Handles:
- Compound strings joined by " / " (e.g. steel/concrete beams cite both codes).
- The "§" section marker and bare section numbers.
- ACI 318 editions (`ACI 318-11`, `ACI 318-19`) with dotted sections (`22.4.2`).
- AISC 360 editions (`AISC 360-16`, `AISC 360-22`) with alphanumeric sections
  (`H1`, `F2`, `G2`).

Order is preserved. The FIRST parsed candidate fixes the governing code family
for [`ground_check`](@ref); it never crosses code families (e.g. an unresolved
AISC part is left unresolved — it does NOT fall through to an ACI part).
"""
function _parse_clause_candidates(code_clause::AbstractString)::Vector{Tuple{String, String}}
    candidates = Tuple{String, String}[]
    isempty(strip(code_clause)) && return candidates

    for part in split(code_clause, "/")
        seg = strip(part)
        isempty(seg) && continue

        # ACI 318-YY §<section> (dotted numeric)
        m = match(r"ACI\s*318[-\s]*(\d{2})\b[^0-9]*?(\d+(?:\.\d+)*)", seg)
        if m !== nothing
            push!(candidates, ("ACI 318-$(m.captures[1])", m.captures[2]))
            continue
        end

        # AISC 360-YY <section> (alphanumeric, e.g. H1, F2, G2, E3)
        m = match(r"AISC\s*360[-\s]*(\d{2})\b.*?\b([A-Z]\d+(?:\.\d+)*)\b", seg)
        if m !== nothing
            push!(candidates, ("AISC 360-$(m.captures[1])", m.captures[2]))
            continue
        end
    end

    return candidates
end

"""
    _lookup_citation(edition, section) -> Union{NamedTuple, Nothing}

Return the grounded `(source_id, page)` for `(edition, section)`, trying the
exact section first and then progressively stripping trailing dotted segments
(e.g. `22.4.2` → `22.4`) so sub-clauses resolve to their parent section anchor.
Also returns the matched section key. `nothing` when nothing resolves.
"""
function _lookup_citation(edition::AbstractString, section::AbstractString)
    key_section = String(section)
    while true
        hit = get(CORPUS_CITATIONS, (String(edition), key_section), nothing)
        if hit !== nothing
            return (source_id = hit.source_id, page = hit.page, section = key_section)
        end
        idx = findlast('.', key_section)
        idx === nothing && return nothing
        key_section = key_section[1:prevind(key_section, idx)]
    end
end

"""
    citation_id(source_id, section, clause, check_name) -> String

Deterministic, domain-agnostic stable id for a citation, derived only from the
corpus `source_id`, matched `section`, the requested `clause`, and the
`check_name` it grounds (never a random or memory-address id) so an external
linker can key on it.

`check_name` is part of the key because the corpus is indexed at section
granularity and DISTINCT checks legitimately map to the SAME section (e.g.
column punching `punching_shear_col`, slab punching `punching_shear_slab`, and
foundation punching `punching_shear_fdn` all resolve to ACI 318-19 §22.6). Keying
on `source_id:section` alone would collapse these onto one id and let one
element's `governing_citation_id` dereference another element's citation
metadata.

`clause` (the sub-clause actually requested, e.g. `22.4.2`) is ALSO part of the
key because sub-clauses under the SAME `check_name` legitimately resolve to the
SAME parent section (e.g. `§22.4.2` and `§22.4` both anchor to corpus section
`22.4`). Without the clause in the id, two distinct provisions grounding the
same check would collapse onto one id and cross-reference each other's metadata.
Namespacing by both `clause` and `check_name` keeps every citation distinct while
staying fully deterministic. Unresolved citations get a stable
`unresolved:<slug>` id (also namespaced by check) derived from the raw clause.
"""
function citation_id(source_id::AbstractString, section::AbstractString,
                     clause::AbstractString, check_name::AbstractString)::String
    return "$(source_id):$(section):$(clause):$(check_name)"
end

function _unresolved_citation_id(code_clause::AbstractString,
                                 check_name::AbstractString)::String
    slug = lowercase(strip(code_clause))
    slug = replace(slug, r"[^a-z0-9]+" => "-")
    slug = strip(slug, '-')
    base = isempty(slug) ? "unresolved:unknown" : "unresolved:$(slug)"
    cn = lowercase(strip(check_name))
    cn = strip(replace(cn, r"[^a-z0-9]+" => "-"), '-')
    return isempty(cn) ? base : "$(base):$(cn)"
end

"""
    _code_family(edition) -> String

Reduce a canonical edition token (e.g. `"AISC 360-16"`, `"ACI 318-19"`) to its
code-family key (`"AISC 360"`, `"ACI 318"`) by dropping the trailing edition
year. Used by [`ground_check`](@ref) to enforce the code-family safety invariant
(never resolve a steel check to a concrete provision or vice versa).
"""
_code_family(edition::AbstractString)::String = strip(replace(String(edition), r"[-\s]*\d{2}\s*$" => ""))

"""
    ground_check(check_name, code_clause) -> Dict{String, Any}

Explanation-layer join from a `(check_name, code_clause)` pair to a live corpus
citation. Returns a JSON-serializable Dict; NEVER throws and NEVER alters any
numeric result — it only attaches citation metadata.

# Returns
Always includes:
- `"id"`         — stable citation id (see [`citation_id`](@ref)).
- `"resolved"`   — `true` when grounded to a corpus source, else `false`.
- `"code_clause"`— the original human clause string (verbatim, for traceability).
- `"check_name"` — the check this citation grounds.

When `resolved == true`, additionally:
- `"source_id"`  — corpus source id (e.g. `"aci-318-19"`).
- `"edition"`    — canonical edition token (e.g. `"ACI 318-19"`).
- `"clause"`     — the requested section (may be a sub-clause, e.g. `"22.4.2"`).
- `"section"`    — the corpus-indexed section actually matched (e.g. `"22.4"`).
- `"page"`       — printed page in the standard (see module header).

When `resolved == false`, `"source_id"` is `nothing` and `"note"` explains why
(edition/clause not confirmed in the corpus).

# Code-family safety
The FIRST parsed candidate fixes the governing code family. Only candidates in
that SAME family are considered, so a steel (AISC) check can only ground to an
AISC source and a concrete (ACI) check only to an ACI source. If the governing
family's clause is not in the corpus the result is UNRESOLVED — the function
never crosses code families to find a citable clause.
"""
function ground_check(check_name::AbstractString, code_clause::AbstractString)::Dict{String, Any}
    candidates = _parse_clause_candidates(code_clause)
    if !isempty(candidates)
        # The first parsed candidate fixes the governing code family. Never
        # cross code families (steel↔concrete) to find a citable clause.
        governing_family = _code_family(first(candidates)[1])
        for (edition, section) in candidates
            _code_family(edition) == governing_family || continue
            hit = _lookup_citation(edition, section)
            hit === nothing && continue
            return Dict{String, Any}(
                # Id namespaced by matched section, requested clause, AND check so
                # sub-clauses (e.g. §22.4.2 vs §22.4) that anchor to the same
                # corpus section never collapse onto one id (P2-B).
                "id"          => citation_id(hit.source_id, hit.section, section, check_name),
                "resolved"    => true,
                "check_name"  => String(check_name),
                "code_clause" => String(code_clause),
                "source_id"   => hit.source_id,
                "edition"     => edition,
                "clause"      => String(section),
                "section"     => hit.section,
                "page"        => hit.page,
            )
        end
    end

    return Dict{String, Any}(
        "id"          => _unresolved_citation_id(code_clause, check_name),
        "resolved"    => false,
        "check_name"  => String(check_name),
        "code_clause" => String(code_clause),
        "source_id"   => nothing,
        "note"        => "No confirmed corpus source for this edition/clause; left unresolved rather than guessed.",
    )
end

"""
    _attach_citation!(check::AbstractDict)

In-place: read a /diagnose check dict's `"name"` and `"code_clause"` and set its
`"citation"` field to the grounded corpus reference. No-op-safe when either key
is missing (uses empty strings). Returns the mutated dict.
"""
function _attach_citation!(check::AbstractDict)
    name   = get(check, "name", "")
    clause = get(check, "code_clause", "")
    check["citation"] = ground_check(string(name), string(clause))
    return check
end

"""
    _ground_checks!(checks) -> checks

Attach a corpus citation to every check dict in a per-element `checks` vector
(as built by the `_diagnose_*` serializers). Returns the same vector.
"""
function _ground_checks!(checks::AbstractVector)
    for c in checks
        c isa AbstractDict && _attach_citation!(c)
    end
    return checks
end
