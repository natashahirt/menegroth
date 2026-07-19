#!/usr/bin/env python3
"""Scribe: commit AISC 360-16 Chapter G extractor candidates to zettelkasten."""
from __future__ import annotations

import json
import sys
from typing import Any

from zettelkasten.server import note, suggest

PROJECT = "menegroth"
SYN = "aisc-360-canon"
GRAPH = "aisc-360-16"

FACETS_DEFAULT = {
    "element": "beam",
    "limit-state": "shear",
    "stage": "strength",
    "method": "na",
}


def facet_tags(dim: str, clause: str, facets: dict[str, str]) -> list[str]:
    tags = [
        dim,
        f"clause:{clause}",
        "family:aisc-360-16",
        "edition:2016",
        "material:steel",
        f"element:{facets['element']}",
        f"limit-state:{facets['limit-state']}",
        f"stage:{facets['stage']}",
    ]
    if facets.get("method") and facets["method"] != "na":
        tags.append(f"method:{facets['method']}")
    return tags


def alias_list(clause: str, dim: str) -> list[str] | None:
    if dim in ("provision", "equation", "parameters", "applicability"):
        return [f"aisc-360-16#{clause}"]
    return None


def ncall(**kwargs: Any) -> dict:
    return json.loads(note(**kwargs))


def add_claim(c: dict) -> tuple[str | None, str | None]:
    """Returns (id, error). Reuses existing note on title match."""
    sr = ncall(action="search", graph=GRAPH, query=c["title"], limit=5)
    if isinstance(sr, list):
        for hit in sr:
            if hit.get("title") == c["title"] and hit.get("type") == c["note_type"]:
                return hit["id"], "reused"
    tags = facet_tags(c["dimension"], c["clause"], c.get("facets", FACETS_DEFAULT))
    kwargs: dict[str, Any] = dict(
        action="add",
        graph=GRAPH,
        title=c["title"],
        type=c["note_type"],
        body=c["body"],
        tags=tags,
        source_page=c["source_page"],
        project=PROJECT,
        synthesis_graph=SYN,
    )
    al = alias_list(c["clause"], c["dimension"])
    if al:
        kwargs["aliases"] = al
    r = ncall(**kwargs)
    if "error" in r:
        return None, r["error"]
    nid = r["id"]
    ar = ncall(
        action="attach",
        graph=GRAPH,
        note_id=nid,
        tag=c["dimension"],
        project=PROJECT,
        synthesis_graph=SYN,
    )
    if "error" in ar:
        return nid, f"attach:{ar['error']}"
    return nid, None


def add_quotes(c: dict, claim_id: str) -> tuple[int, list[str]]:
    dropped: list[str] = []
    n = 0
    for i, qtext in enumerate(c.get("quotes") or [], 1):
        qtitle = f"Quote {i}: {c['title']}"
        r = ncall(
            action="add",
            graph=GRAPH,
            title=qtitle,
            type="quote",
            body=qtext,
            tags=["quote", "grounding", c["dimension"]],
            source_page=c["source_page"],
            project=PROJECT,
            synthesis_graph=SYN,
            links=[{"target": claim_id, "relation": "supports", "direction": "outgoing"}],
        )
        if "error" in r:
            dropped.append(f"{qtitle}: {r['error']}")
        else:
            n += 1
    return n, dropped


# fmt: off
CANDIDATES: list[dict] = [
    {"key": "c01", "dimension": "scope", "note_type": "concept", "title": "Chapter G Scope — Shear Design", "clause": "Chapter G (overview)", "source_page": "p.16.1-70",
     "body": "Chapter G governs shear design for webs of singly/doubly symmetric members in the plane of the web, single angles, HSS, and weak-axis shear of symmetric shapes.",
     "quotes": ["This chapter addresses webs of singly or doubly symmetric members subject to shear in the\nplane of the web, single angles and HSS subject to shear, and shear in the weak direction of\nsingly or doubly symmetricshapes."],
     "facets": {"element": "beam", "limit-state": "shear", "stage": "strength", "method": "na"}},
    {"key": "c02", "dimension": "scope", "note_type": "concept", "title": "Chapter G Organization", "clause": "Chapter G (overview)", "source_page": "p.16.1-70",
     "body": "Chapter G is organized into G1–G7 with H3.3, J4.2, and J10.6 handling out-of-scope cases.",
     "quotes": ["G1. General Provisions\nG2. I-Shaped Members and Channels\nG3. Single Angles and Tees\nG4. Rectangular HSS, Box Sections, and other Singly and Doubly Symmetric\nMembers\nG5. Round HSS\nG6. Weak-Axis Shear in Doubly Symmetric and Singly Symmetric Shapes\nG7. Beams and Girders with Web Openings",
                "User Note:For cases not included in this chapter, the following sections apply:\n(cid:129) H3.3 Unsymmetric sections\n(cid:129) J4.2 Shear strength of connecting elements\n(cid:129) J10.6 Web panel zone shear"],
     "facets": {"element": "beam", "limit-state": "shear", "stage": "strength", "method": "na"}},
    {"key": "c03", "dimension": "provision", "note_type": "model", "title": "G1 Default Shear Resistance/Safety Factors", "clause": "G1(a)", "source_page": "p.16.1-70",
     "body": "Except for rolled I-shaped members qualifying under G2.1(a), design shear strength uses φv = 0.90 (LRFD) and allowable shear strength uses Ωv = 1.67 (ASD). Section G1(a) states these factors apply to all Chapter G provisions other than G2.1(a).",
     "quotes": ["The design shear strength, φ V , and the allowable shear strength, V /Ω , shall be\nv n n v\ndetermined as follows:\n(a) For all provisions in this chapter except Section G2.1(a)\nφ =0.90 (LRFD) Ω =1.67 (ASD)\nv v"],
     "facets": {"element": "beam", "limit-state": "shear", "stage": "strength", "method": "lrfd-and-asd"}},
    {"key": "c04", "dimension": "provision", "note_type": "definition", "title": "G1(b) Reference to Vn Sections", "clause": "G1(b)", "source_page": "p.16.1-70",
     "body": "The nominal shear strength Vn for any member covered by Chapter G must be computed using the specific method in Sections G2 through G7 applicable to that member type.",
     "quotes": ["(b) The nominal shear strength, V , shall be determined according to Sections G2\nn\nthrough G7."],
     "facets": {"element": "beam", "limit-state": "shear", "stage": "strength", "method": "lrfd-and-asd"}},
    {"key": "c05", "dimension": "scope", "note_type": "concept", "title": "G2 Shear Strength of Webs Without Tension Field Action", "clause": "G2.1", "source_page": "p.16.1-70",
     "body": "Section G2.1 gives the nominal shear strength of I-shaped member and channel webs when tension field action is not considered.",
     "quotes": ["G2. I-SHAPED MEMBERS AND CHANNELS\n1. Shear Strength of Webs without Tension Field Action"],
     "facets": {"element": "beam", "limit-state": "shear", "stage": "strength", "method": "na"}},
    {"key": "c06", "dimension": "equation", "note_type": "equation", "title": "Eq. G2-1 — Vn = 0.6 Fy Aw Cv1", "clause": "G2-1", "source_page": "p.16.1-70",
     "body": "$V_n = 0.6 F_y A_w C_{v1}$\n\n$F_y$ = specified minimum yield stress, ksi; $A_w$ = web area $d t_w$, in.$^2$; $C_{v1}$ = web shear strength coefficient per G2.1.",
     "quotes": ["V = 0.6F A C (G2-1)\nn y w v1"],
     "facets": {"element": "beam", "limit-state": "shear", "stage": "strength", "method": "na"}},
    {"key": "c07", "dimension": "parameters", "note_type": "definition", "title": "Parameters Fy, Aw for Eq. G2-1", "clause": "G2-1", "source_page": "p.16.1-70",
     "body": "Fy is specified minimum yield stress (ksi); Aw is web area = overall depth times web thickness d·tw (in²).",
     "quotes": ["F =specified minimum yield stress of the type of steel being used, ksi (MPa)\ny\nA =area of web, the overall depth times the web thickness, dt , in.2 (mm2)\nw w"],
     "facets": {"element": "beam", "limit-state": "shear", "stage": "strength", "method": "na"}},
    {"key": "c08", "dimension": "applicability", "note_type": "definition", "title": "Applicability — Compact Rolled I-Shape Webs (G2.1a)", "clause": "G2.1(a)", "source_page": "p.16.1-71",
     "body": "Section G2.1(a) applies to webs of rolled I-shaped members with h/tw ≤ 2.24√(E/Fy).",
     "quotes": ["(a) For webs of rolled I-shaped members with h t ≤2.24 E F\nw y"],
     "facets": {"element": "beam", "limit-state": "web-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c09", "dimension": "provision", "note_type": "model", "title": "G2.1(a) φv = 1.00, Ωv = 1.50 for Compact Rolled Webs", "clause": "G2.1(a)", "source_page": "p.16.1-71",
     "body": "For compact rolled I-shaped webs meeting G2.1(a), φv = 1.00 (LRFD) and Ωv = 1.50 (ASD), replacing the default G1 factors.",
     "quotes": ["φ =1.00 (LRFD) Ω =1.50 (ASD)\nv v"],
     "facets": {"element": "beam", "limit-state": "shear", "stage": "strength", "method": "lrfd-and-asd"}},
    {"key": "c10", "dimension": "equation", "note_type": "equation", "title": "Eq. G2-2 — Cv1 = 1.0 (Compact Rolled Webs)", "clause": "G2-2", "source_page": "p.16.1-71",
     "body": "$C_{v1} = 1.0$\n\nApplies for webs qualifying under G2.1(a).",
     "quotes": ["C =1.0 (G2-2)\nv1"],
     "facets": {"element": "beam", "limit-state": "web-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c11", "dimension": "parameters", "note_type": "definition", "title": "Parameters E, h, tw for G2.1(a)", "clause": "G2.1(a)", "source_page": "p.16.1-71",
     "body": "E = 29,000 ksi; h = clear distance between flanges less the fillet; tw = web thickness.",
     "quotes": ["E =modulus of elasticity of steel =29,000 ksi (200 000 MPa)\nh =clear distance between flanges less the fillet at each flange, in. (mm)\nt =thickness of web, in. (mm)\nw"],
     "facets": {"element": "beam", "limit-state": "shear", "stage": "strength", "method": "na"}},
    {"key": "c12", "dimension": "commentary", "note_type": "finding", "title": "Commentary — ASTM A6 Shapes Meeting G2.1(a) at Fy=50 ksi", "clause": "G2.1(a)", "source_page": "p.16.1-71",
     "body": "A User Note lists which ASTM A6 W/S/HP shapes fail G2.1(a) at Fy=50 ksi (all others qualify for φv=1.00/Ωv=1.50).",
     "quotes": ["User Note: All current ASTM A6 W, S and HP shapes except W44×230,\nW40×149,W36×135,W33×118,W30×90,W24×55,W16×26 and W12×14\nmeet the criteria stated in Section G2.1(a) for F =50 ksi (345 MPa).\ny"],
     "facets": {"element": "beam", "limit-state": "web-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c13", "dimension": "scope", "note_type": "concept", "title": "G2.1(b) — All Other I-Shaped Members and Channels", "clause": "G2.1(b)(1)", "source_page": "p.16.1-71",
     "body": "For I-shaped members/channels not covered by G2.1(a), Cv1 must be computed from web slenderness.",
     "quotes": ["(b) For all other I-shaped members and channels\n(1) The web shear strength coefficient, C , is determined as follows:\nv1"],
     "facets": {"element": "beam", "limit-state": "web-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c14", "dimension": "applicability", "note_type": "definition", "title": "Applicability — Cv1=1.0 Threshold h/tw ≤ 1.10√(kvE/Fy)", "clause": "G2.1(b)(1)(i)", "source_page": "p.16.1-71",
     "body": "Cv1 = 1.0 when h/tw ≤ 1.10√(kvE/Fy).",
     "quotes": ["(i) When h/t ≤1.10 k E/F\nw v y"],
     "facets": {"element": "beam", "limit-state": "web-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c15", "dimension": "equation", "note_type": "equation", "title": "Eq. G2-3 — Cv1 = 1.0 (Non-slender Webs)", "clause": "G2-3", "source_page": "p.16.1-71",
     "body": "$C_{v1} = 1.0$\n\nWhen $h/t_w \\le 1.10\\sqrt{k_v E/F_y}$.",
     "quotes": ["C =1.0 (G2-3)\nv1"],
     "facets": {"element": "beam", "limit-state": "web-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c16", "dimension": "parameters", "note_type": "definition", "title": "Parameters h for Built-Up Welded/Bolted Sections (G2.1b)", "clause": "G2.1(b)(1)", "source_page": "p.16.1-71",
     "body": "For built-up welded sections h is clear distance between flanges; for built-up bolted sections h is distance between fastener lines.",
     "quotes": ["where\nh =for built-up welded sections, the clear distance between flanges,\nin. (mm)\n=for built-up bolted sections, the distance between fastener lines,\nin. (mm)"],
     "facets": {"element": "beam", "limit-state": "web-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c17", "dimension": "equation", "note_type": "equation", "title": "Eq. G2-4 — Cv1 for Slender Webs", "clause": "G2-4", "source_page": "p.16.1-71",
     "body": "$C_{v1} = \\dfrac{1.10\\sqrt{k_v E/F_y}}{h/t_w}$\n\nWhen $h/t_w > 1.10\\sqrt{k_v E/F_y}$.",
     "quotes": ["Whenh/t >1.10 k E/F\nw v y\n1.10 k E/F\nC = v y (G2-4)\nv1\nh/t\nw"],
     "facets": {"element": "beam", "limit-state": "web-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c18", "dimension": "provision", "note_type": "definition", "title": "kv Determination — Introduction", "clause": "G2.1(b)(2)", "source_page": "p.16.1-71",
     "body": "The web plate shear buckling coefficient kv depends on whether the web has transverse stiffeners.",
     "quotes": ["(2) The web plate shear buckling coefficient, k , is determined as follows:\nv"],
     "facets": {"element": "beam", "limit-state": "web-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c19", "dimension": "provision", "note_type": "model", "title": "kv = 5.34 for Webs Without Transverse Stiffeners", "clause": "G2.1(b)(2)(i)", "source_page": "p.16.1-72",
     "body": "For webs without transverse stiffeners, kv = 5.34.",
     "quotes": ["(i) For webs without transverse stiffeners\nk =5.34\nv"],
     "facets": {"element": "beam", "limit-state": "web-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c20", "dimension": "equation", "note_type": "equation", "title": "Eq. G2-5 — kv for Webs With Transverse Stiffeners", "clause": "G2-5", "source_page": "p.16.1-72",
     "body": "$k_v = 5 + \\dfrac{5}{(a/h)^2}$ (=5.34 when $a/h>3.0$)",
     "quotes": ["(ii) For webs with transverse stiffeners\n5\nk = 5+ (G2-5)\nv ( )2\na/h\n=5.34 when a/h> 3.0"],
     "facets": {"element": "beam", "limit-state": "web-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c21", "dimension": "parameters", "note_type": "definition", "title": "Parameter a — Stiffener Spacing for Eq. G2-5", "clause": "G2-5", "source_page": "p.16.1-72",
     "body": "a = clear distance between transverse stiffeners (in).",
     "quotes": ["where\na =clear distance between transverse stiffeners, in. (mm)"],
     "facets": {"element": "beam", "limit-state": "web-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c22", "dimension": "commentary", "note_type": "finding", "title": "Commentary — ASTM A6 M-Shapes with Cv1=1.0", "clause": "G2.1(b)", "source_page": "p.16.1-72",
     "body": "A User Note identifies which ASTM A6 W/S/M/HP shapes fail Cv1=1.0 at Fy=50 ksi.",
     "quotes": ["User Note: For all ASTM A6 W, S, M and HP shapes except M12.5×12.4,\nM12.5×11.6,M12×11.8,M12×10.8,M12×10,M10×8 and M10×7.5,when\nF =50 ksi (345 MPa), C =1.0.\ny v1"],
     "facets": {"element": "beam", "limit-state": "web-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c23", "dimension": "scope", "note_type": "concept", "title": "G2.2 Shear Strength With Tension Field Action", "clause": "G2.2", "source_page": "p.16.1-72",
     "body": "Section G2.2 governs nominal shear strength of interior web panels with a/h ≤ 3 considering tension field action.",
     "quotes": ["2. Shear Strength of Interior Web Panels with a/h≤3\nConsidering Tension Field Action\nThe nominal shear strength, V , is determined as follows:\nn"],
     "facets": {"element": "beam", "limit-state": "tension-field-action", "stage": "strength", "method": "na"}},
    {"key": "c24", "dimension": "applicability", "note_type": "definition", "title": "Applicability — Eq. G2-6 Threshold", "clause": "G2.2(a)", "source_page": "p.16.1-72",
     "body": "Eq. G2-6 applies when h/tw ≤ 1.10√(kvE/Fy).",
     "quotes": ["(a) When h/t ≤1.10 k E/F\nw v y"],
     "facets": {"element": "beam", "limit-state": "tension-field-action", "stage": "strength", "method": "na"}},
    {"key": "c25", "dimension": "equation", "note_type": "equation", "title": "Eq. G2-6 — Vn = 0.6 Fy Aw (Below Buckling Limit)", "clause": "G2-6", "source_page": "p.16.1-72",
     "body": "$V_n = 0.6 F_y A_w$\n\nFor non-slender webs under G2.2(a).",
     "quotes": ["V =0.6F A (G2-6)\nn y w"],
     "facets": {"element": "beam", "limit-state": "tension-field-action", "stage": "strength", "method": "na"}},
    {"key": "c26", "dimension": "applicability", "note_type": "definition", "title": "Applicability — G2.2(b)(1) Flange Area and Aspect Ratio Limits", "clause": "G2.2(b)(1)", "source_page": "p.16.1-72",
     "body": "Eq. G2-7 applies when h/tw > 1.10√(kvE/Fy) AND 2Aw/(Afc+Aft) ≤ 2.5, h/bfc ≤ 6.0, h/bft ≤ 6.0.",
     "quotes": ["(b) When h/t >1.10 k E/F\nw v y\n(1) When 2A /(A +A )≤2.5, h/b ≤ 6.0 and h/b ≤ 6.0\nw fc ft fc ft"],
     "facets": {"element": "beam", "limit-state": "tension-field-action", "stage": "strength", "method": "na"}},
    {"key": "c27", "dimension": "equation", "note_type": "equation", "title": "Eq. G2-7 — Vn With Tension Field Action (Case 1)", "clause": "G2-7", "source_page": "p.16.1-72",
     "body": "$V_n = 0.6 F_y A_w \\left[ C_{v2} + \\dfrac{1 - C_{v2}}{1.15\\sqrt{1+(a/h)^2}} \\right]$",
     "quotes": ["V\nn\n=0.6F\ny\nA\nw ⎣\n⎢ ⎢⎢C\nv2\n+\n1.15\n1\n1\n−\n+\nC\n( a\nv2\n/h )2 ⎦\n⎥\n⎥\n(G2-7)"],
     "facets": {"element": "beam", "limit-state": "tension-field-action", "stage": "strength", "method": "na"}},
    {"key": "c28", "dimension": "equation", "note_type": "equation", "title": "Eq. G2-8 — Vn With Tension Field Action (Otherwise)", "clause": "G2-8", "source_page": "p.16.1-72",
     "body": "$V_n = 0.6 F_y A_w \\left[ C_{v2} + \\dfrac{1 - C_{v2}}{1.15\\left(a/h + \\sqrt{1+(a/h)^2}\\right)} \\right]$",
     "quotes": ["(2) Otherwise\n⎡ 1−C ⎤\nV n =0.6F y A w ⎣ ⎢ ⎢ C v2 + 1.15 ⎡ ⎣a/h+ 1 v2 +( a/h )2 ⎤ ⎦ ⎦ ⎥ ⎥ (G2-8)"],
     "facets": {"element": "beam", "limit-state": "tension-field-action", "stage": "strength", "method": "na"}},
    {"key": "c29", "dimension": "provision", "note_type": "definition", "title": "Cv2 Determination — Introduction", "clause": "G2.2", "source_page": "p.16.1-72",
     "body": "The web shear buckling coefficient Cv2 is determined by three h/tw ranges relative to kv.",
     "quotes": ["where\nThe web shear buckling coefficient, C , is determined as follows:\nv2"],
     "facets": {"element": "beam", "limit-state": "web-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c30", "dimension": "equation", "note_type": "equation", "title": "Eq. G2-9 — Cv2 = 1.0 (Non-slender)", "clause": "G2-9", "source_page": "p.16.1-72",
     "body": "$C_{v2} = 1.0$\n\nWhen $h/t_w \\le 1.10\\sqrt{k_v E/F_y}$.",
     "quotes": ["(i) When h/t ≤1.10 k E/F\nw v y\nC =1.0 (G2-9)\nv2"],
     "facets": {"element": "beam", "limit-state": "web-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c31", "dimension": "equation", "note_type": "equation", "title": "Eq. G2-10 — Cv2 (Inelastic Buckling Range)", "clause": "G2-10", "source_page": "p.16.1-72",
     "body": "$C_{v2} = \\dfrac{1.10\\sqrt{k_v E/F_y}}{h/t_w}$\n\nFor $1.10\\sqrt{k_v E/F_y} < h/t_w \\le 1.37\\sqrt{k_v E/F_y}$.",
     "quotes": ["(ii) When 1.10 k E/F <h/t ≤1.37 k E/F\nv y w v y\n1.10 k E/F\nC = v y (G2-10)\nv2\nh/t\nw"],
     "facets": {"element": "beam", "limit-state": "web-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c32", "dimension": "equation", "note_type": "equation", "title": "Eq. G2-11 — Cv2 (Elastic Buckling Range)", "clause": "G2-11", "source_page": "p.16.1-72",
     "body": "$C_{v2} = \\dfrac{1.51 k_v E}{(h/t_w)^2 F_y}$\n\nFor $h/t_w > 1.37\\sqrt{k_v E/F_y}$.",
     "quotes": ["(iii) When h/t >1.37 k E/F\nw v y\n1.51k E\nC = v (G2-11)\nv2 ( )2\nh/t F\nw y"],
     "facets": {"element": "beam", "limit-state": "web-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c33", "dimension": "parameters", "note_type": "definition", "title": "Parameters Afc, Aft, bfc, bft, kv for G2.2", "clause": "G2.2", "source_page": "p.16.1-72",
     "body": "Afc/Aft = compression/tension flange areas; bfc/bft = compression/tension flange widths; kv per G2.1.",
     "quotes": ["A =area of compression flange, in.2(mm2)\nfc\nA =area of tension flange, in.2(mm2)\nft\nb =width of compression flange, in. (mm)\nfc\nb =width of tension flange, in. (mm)\nft\nk is as defined in Section G2.1\nv"],
     "facets": {"element": "beam", "limit-state": "tension-field-action", "stage": "strength", "method": "na"}},
    {"key": "c34", "dimension": "provision", "note_type": "model", "title": "Provision — Larger of G2.1 or G2.2 Permitted", "clause": "G2.2", "source_page": "p.16.1-72",
     "body": "Nominal shear strength may be taken as the larger of G2.1 (no TFA) and G2.2 (with TFA).",
     "quotes": ["The nominal shear strength is permitted to be taken as the larger of the values from\nSections G2.1 and G2.2."],
     "facets": {"element": "beam", "limit-state": "tension-field-action", "stage": "strength", "method": "na"}},
    {"key": "c35", "dimension": "commentary", "note_type": "finding", "title": "Commentary — G2.1 May Exceed G2.2 for Non-Qualifying Members", "clause": "G2.2", "source_page": "p.16.1-72",
     "body": "A User Note explains G2.1 may predict higher strength than G2.2 for members not meeting G2.2(b)(1).",
     "quotes": ["User Note:Section G2.1 may predict a higher strength for members that do not\nmeet the requirements of Section G2.2(b)(1)."],
     "facets": {"element": "beam", "limit-state": "tension-field-action", "stage": "strength", "method": "na"}},
    {"key": "c36", "dimension": "scope", "note_type": "concept", "title": "G2.3 Transverse Stiffeners", "clause": "G2.3", "source_page": "p.16.1-73",
     "body": "Section G2.3 gives design requirements for transverse web stiffeners used with tension field action.",
     "quotes": ["3. Transverse Stiffeners\nFor transverse stiffeners, the following shall apply."],
     "facets": {"element": "beam", "limit-state": "transverse-stiffener-design", "stage": "strength", "method": "na"}},
    {"key": "c37", "dimension": "applicability", "note_type": "model", "title": "G2.3(a) — Transverse Stiffener Exemption", "clause": "G2.3(a)", "source_page": "p.16.1-73",
     "body": "Transverse stiffeners not required if h/tw ≤ 2.46√(E/Fy) or if G2.1 available strength with kv=5.34 exceeds required shear.",
     "quotes": ["(a) Transverse stiffeners are not required where h/t ≤2.46 E/F , or where the\nw y\navailable shear strength provided in accordance with Section G2.1 for k =5.34\nv\nis greater than the required shear strength."],
     "facets": {"element": "beam", "limit-state": "transverse-stiffener-design", "stage": "strength", "method": "lrfd-and-asd"}},
    {"key": "c38", "dimension": "provision", "note_type": "definition", "title": "G2.3(b) — Stiffener Termination and Attachment", "clause": "G2.3(b)", "source_page": "p.16.1-73",
     "body": "Stiffeners may stop short of tension flange; attaching weld terminates 4–6×tw from web-to-flange weld toe; single stiffeners attach to compression flange (rectangular plate) to resist torsional uplift.",
     "quotes": ["(b) Transverse stiffeners are permitted to be stopped short of the tension flange, pro-\nvided bearing is not needed to transmit a concentrated load or reaction. The weld\nby which transverse stiffeners are attached to the web shall be terminated not less\nthan four times nor more than six times the web thickness from the near toe of\nthe web-to-flange weld or web-to-flange fillet. When single stiffeners are used,\nthey shall be attached to the compression flange if it consists of a rectangular\nplate, to resist any uplift tendency due to torsion in the flange."],
     "facets": {"element": "beam", "limit-state": "transverse-stiffener-design", "stage": "strength", "method": "na"}},
    {"key": "c39", "dimension": "provision", "note_type": "definition", "title": "G2.3(c) — Bolt/Weld Spacing for Stiffener Attachment", "clause": "G2.3(c)", "source_page": "p.16.1-73",
     "body": "Bolts ≤ 12 in o.c.; intermittent fillet welds clear spacing ≤ 16×tw and ≤ 10 in.",
     "quotes": ["(c) Bolts connecting stiffeners to the girder web shall be spaced not more than 12 in.\n(300 mm) on center. If intermittent fillet welds are used, the clear distance\nbetween welds shall not be more than 16 times the web thickness nor more than\n10 in. (250 mm)."],
     "facets": {"element": "beam", "limit-state": "transverse-stiffener-design", "stage": "strength", "method": "na"}},
    {"key": "c40", "dimension": "equation", "note_type": "equation", "title": "Eq. G2-12 — Stiffener Width-Thickness Limit", "clause": "G2-12", "source_page": "p.16.1-73",
     "body": "$(b/t)_{st} \\le 0.56\\sqrt{E/F_{yst}}$",
     "quotes": ["(d) b t ≤0.56 (G2-12)\nst F\nyst"],
     "facets": {"element": "beam", "limit-state": "transverse-stiffener-design", "stage": "strength", "method": "na"}},
    {"key": "c41", "dimension": "equation", "note_type": "equation", "title": "Eq. G2-13 — Required Stiffener Moment of Inertia", "clause": "G2-13", "source_page": "p.16.1-73",
     "body": "$I_{st} \\ge I_{st2} + (I_{st1} - I_{st2})\\rho_w$",
     "quotes": ["(e) I st ≥I st2 +( I st1 −I st2 )ρ w (G2-13)"],
     "facets": {"element": "beam", "limit-state": "transverse-stiffener-design", "stage": "strength", "method": "na"}},
    {"key": "c42", "dimension": "parameters", "note_type": "definition", "title": "Parameters Fyst, Fyw, Ist for Eq. G2-13", "clause": "G2-13", "source_page": "p.16.1-73",
     "body": "Fyst/Fyw = stiffener/web yield stresses; Ist = stiffener moment of inertia about web centerline (pairs) or web-contact face (single).",
     "quotes": ["where\nF =specified minimum yield stress of the stiffener material, ksi (MPa)\nyst\nF =specified minimum yield stress of the web material, ksi (MPa)\nyw\nI =moment of inertia of the transverse stiffeners about an axis in the web cen-\nst\nter for stiffener pairs, or about the face in contact with the web plate for\nsingle stiffeners, in.4(mm4)"],
     "facets": {"element": "beam", "limit-state": "transverse-stiffener-design", "stage": "strength", "method": "na"}},
    {"key": "c43", "dimension": "equation", "note_type": "equation", "title": "Eq. G2-14 — Ist1 (Full Post-Buckling)", "clause": "G2-14", "source_page": "p.16.1-73",
     "body": "$I_{st1} = \\dfrac{h^4 \\rho_{st}^{1.3}}{40}\\left(\\dfrac{F_{yw}}{E}\\right)^{1.5}$",
     "quotes": ["h4ρ1.3⎛F ⎞1.5\nI st1 = 40 st ⎝ ⎜ E yw ⎠ ⎟ (G2-14)\n=minimum moment of inertia of the transverse stiffeners required for devel-\nopment of the full shear post buckling resistance of the stiffened web\npanels, V =V ,in.4(mm4)\nr c1"],
     "facets": {"element": "beam", "limit-state": "transverse-stiffener-design", "stage": "strength", "method": "na"}},
    {"key": "c44", "dimension": "equation", "note_type": "equation", "title": "Eq. G2-15 — Ist2 (Web Shear Buckling)", "clause": "G2-15", "source_page": "p.16.1-74",
     "body": "$I_{st2} = \\left[\\dfrac{2.5}{(a/h)^2} - 2\\right] b_p t_w^3 \\ge 0.5 b_p t_w^3$",
     "quotes": ["I st2 = ⎢ ⎢⎢ ( 2.5 )2 −2 ⎥ ⎥ b p t w 3 ≥0.5b p t w 3 (G2-15)\n⎣ a/h ⎦\n= minimum moment of inertia of the transverse stiffeners required for devel-\nopment of the web shear buckling resistance, V =V , in.4(mm4)\nr c2"],
     "facets": {"element": "beam", "limit-state": "transverse-stiffener-design", "stage": "strength", "method": "na"}},
    {"key": "c45", "dimension": "parameters", "note_type": "definition", "title": "Parameters Vc1, Vc2, Vr, bp, (b/t)st, ρst, ρw", "clause": "G2-13/G2-14/G2-15", "source_page": "p.16.1-73",
     "body": "Vc1 = available strength per G2.1/G2.2; Vc2 = available strength with Vn=0.6FyAwCv2; Vr = required shear; bp = smaller of a and h; ρst = larger of Fyw/Fyst and 1.0; ρw = max (Vr−Vc2)/(Vc1−Vc2) ≥ 0.",
     "quotes": ["V =available shear strength calculated with V as defined in Section G2.1 or\nc1 n\nG2.2, as applicable, kips (N)\nV =available shear strength, kips (N), calculated with V = 0.6F A C\nc2 n y w v2",
                "V =required shear strength in the panel being considered, kips (N)\nr\nb =smaller of the dimension aand h, in. (mm)\np\n(b/t) =width-to-thickness ratio of the stiffener\nst\nρ =larger of F /F and 1.0\nst yw yst\nρ =maximum shear ratio, ⎛ ⎜ V r −V c2 ⎞ ⎟ ≥ 0, within the web panels on each\nw ⎝ V −V ⎠\nc1 c2\nside of the transverse stiffener"],
     "facets": {"element": "beam", "limit-state": "transverse-stiffener-design", "stage": "strength", "method": "na"}},
    {"key": "c46", "dimension": "commentary", "note_type": "finding", "title": "Commentary — Ist1 Conservative; Linear Interpolation Intent", "clause": "G2.3", "source_page": "p.16.1-74",
     "body": "A User Note explains Ist may be taken as Ist1, G2-15 gives min inertia for post-buckling resistance, and G2-13 interpolates between buckling and post-buckling requirements.",
     "quotes": ["User Note:I may conservatively be taken as I . Equation G2-15 provides the\nst st1\nminimum stiffener moment of inertia required to attain the web shear post buck-\nling resistance according to Sections G2.1 and G2.2, as applicable. If less post\nbuckling shear strength is required, Equation G2-13 provides a linear interpola-\ntion between the minimum moment of inertia required to develop web shear\nbuckling and that required to develop the web shear post buckling strength."],
     "facets": {"element": "beam", "limit-state": "transverse-stiffener-design", "stage": "strength", "method": "na"}},
    {"key": "c47", "dimension": "scope", "note_type": "concept", "title": "G3 Single Angles and Tees", "clause": "G3", "source_page": "p.16.1-74",
     "body": "Section G3 gives nominal shear strength of a single-angle leg or tee stem.",
     "quotes": ["G3. SINGLE ANGLES AND TEES\nThe nominal shear strength, V , of a single-angle leg or a tee stem is:\nn"],
     "facets": {"element": "angle-or-tee", "limit-state": "shear", "stage": "strength", "method": "na"}},
    {"key": "c48", "dimension": "equation", "note_type": "equation", "title": "Eq. G3-1 — Vn for Single Angle Leg or Tee Stem", "clause": "G3-1", "source_page": "p.16.1-74",
     "body": "$V_n = 0.6 F_y b t C_{v2}$",
     "quotes": ["V = 0.6FbtC (G3-1)\nn y v2"],
     "facets": {"element": "angle-or-tee", "limit-state": "shear", "stage": "strength", "method": "na"}},
    {"key": "c49", "dimension": "parameters", "note_type": "definition", "title": "Parameters Cv2, b, t for Eq. G3-1", "clause": "G3-1", "source_page": "p.16.1-74",
     "body": "Cv2 per G2.2 with h/tw=b/t and kv=1.2; b = width of resisting leg/tee-stem depth; t = leg/stem thickness.",
     "quotes": ["where\nC =web shear buckling strength coefficient, as defined in Section G2.2 with\nv2\nh/t = b/tand k = 1.2\nw v\nb =width of the leg resisting the shear force or depth of the tee stem, in. (mm)\nt =thickness of angle leg or tee stem, in. (mm)"],
     "facets": {"element": "angle-or-tee", "limit-state": "shear", "stage": "strength", "method": "na"}},
    {"key": "c50", "dimension": "scope", "note_type": "concept", "title": "G4 Rectangular HSS, Box Sections, Other Symmetric Members", "clause": "G4", "source_page": "p.16.1-74",
     "body": "Section G4 gives nominal shear strength for rectangular HSS, box sections, and other symmetric members not covered by G2/G3.",
     "quotes": ["G4. RECTANGULAR HSS, BOX SECTIONS, AND OTHER SINGLY AND\nDOUBLY SYMMETRIC MEMBERS\nThe nominal shear strength, V , is:\nn"],
     "facets": {"element": "hss-or-box", "limit-state": "shear", "stage": "strength", "method": "na"}},
    {"key": "c51", "dimension": "equation", "note_type": "equation", "title": "Eq. G4-1 — Vn for HSS/Box/Other Symmetric Members", "clause": "G4-1", "source_page": "p.16.1-74",
     "body": "$V_n = 0.6 F_y A_w C_{v2}$",
     "quotes": ["V = 0.6FA C (G4-1)\nn y w v2"],
     "facets": {"element": "hss-or-box", "limit-state": "shear", "stage": "strength", "method": "na"}},
    {"key": "c52", "dimension": "parameters", "note_type": "definition", "title": "Parameters Aw, h, t, Cv2 for Rectangular HSS/Box (G4)", "clause": "G4-1", "source_page": "p.16.1-74",
     "body": "Aw = 2ht; Cv2 per G2.2 with h/tw=h/t and kv=5; h = clear distance between flanges less inside corner radius (HSS) or between flanges (box), else outside dim − 3t; t = design wall thickness per B4.2.",
     "quotes": ["For rectangular HSS and box sections\nA =2ht, in.2(mm2)\nw\nC =web shear buckling strength coefficient, as defined in Section G2.2, with\nv2\nh/t = h/tand k = 5\nw v\nh =width resisting the shear force, taken as the clear distance between the flanges\nless the inside corner radius on each side for HSS or the clear distance be tween\nflanges for box sections, in. (mm). If the corner radius is not known, hshall be\ntaken as the corresponding outside dimension minus 3 times the thickness.\nt =design wall thickness, as defined in Section B4.2, in. (mm)"],
     "facets": {"element": "hss-or-box", "limit-state": "web-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c53", "dimension": "parameters", "note_type": "definition", "title": "Parameters Aw, h, t, Cv2 for Other Symmetric Shapes (G4)", "clause": "G4-1", "source_page": "p.16.1-75",
     "body": "Aw = sum of dtw for each web; Cv2 per G2.2 with h/tw=h/t and kv=5; h = clear distance between flanges (welded) or fastener lines (bolted); t = web thickness per B4.2.",
     "quotes": ["For other singly or doubly symmetric shapes\nA =area of web or webs, taken as the sum of the overall depth times the web\nw\nthickness, dt , in.2(mm2)\nw\nC =web shear buckling strength coefficient, as defined in Section G2.2, with\nv2\nh/t = h/tand k = 5\nw v",
                "h =width resisting the shear force, in. (mm)\n=for built-up welded sections, the clear distance between flanges, in. (mm)\n=for built-up bolted sections, the distance between fastener lines, in. (mm)\nt =web thickness, as defined in Section B4.2, in. (mm)"],
     "facets": {"element": "beam", "limit-state": "web-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c54", "dimension": "scope", "note_type": "concept", "title": "G5 Round HSS", "clause": "G5", "source_page": "p.16.1-75",
     "body": "Section G5 gives nominal shear strength of round HSS, governed by shear yielding and shear buckling.",
     "quotes": ["G5. ROUND HSS\nThe nominal shear strength, V , of round HSS, according to the limit states of shear\nn\nyielding and shear buckling, shall be determined as:"],
     "facets": {"element": "round-hss", "limit-state": "shear-and-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c55", "dimension": "equation", "note_type": "equation", "title": "Eq. G5-1 — Vn = Fcr Ag / 2 for Round HSS", "clause": "G5-1", "source_page": "p.16.1-75",
     "body": "$V_n = \\dfrac{F_{cr} A_g}{2}$",
     "quotes": ["V =F A /2 (G5-1)\nn cr g"],
     "facets": {"element": "round-hss", "limit-state": "shear-and-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c56", "dimension": "provision", "note_type": "definition", "title": "Fcr for Round HSS — Larger-Of Rule", "clause": "G5-1", "source_page": "p.16.1-75",
     "body": "Fcr for round HSS is the larger of G5-2a and G5-2b, but ≤ 0.6 Fy.",
     "quotes": ["where\nF shall be the larger of\ncr"],
     "facets": {"element": "round-hss", "limit-state": "shear-and-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c57", "dimension": "equation", "note_type": "equation", "title": "Eq. G5-2a — Fcr, Long/Slender Round HSS Term", "clause": "G5-2a", "source_page": "p.16.1-75",
     "body": "$F_{cr} = \\dfrac{1.60 E}{\\dfrac{L_v}{D}\\left(\\dfrac{D}{t}\\right)^{5/4}}$",
     "quotes": ["1.60E\nF = (G5-2a)\ncr 5\nL v ⎛ ⎜ D⎞ ⎟ 4\nD⎝ t ⎠"],
     "facets": {"element": "round-hss", "limit-state": "shear-and-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c58", "dimension": "equation", "note_type": "equation", "title": "Eq. G5-2b — Fcr, Elastic Local Buckling Term", "clause": "G5-2b", "source_page": "p.16.1-75",
     "body": "$F_{cr} = \\dfrac{0.78 E}{(D/t)^{3/2}}$",
     "quotes": ["0.78E\nF = (G5-2b)\ncr 3\n⎛D⎞\n2\n⎜ ⎟\n⎝ t ⎠"],
     "facets": {"element": "round-hss", "limit-state": "shear-and-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c59", "dimension": "applicability", "note_type": "definition", "title": "Applicability — Fcr Cap at 0.6 Fy for Round HSS", "clause": "G5-1", "source_page": "p.16.1-75",
     "body": "Fcr for round HSS must not exceed 0.6 Fy.",
     "quotes": ["but shall not exceed 0.6F\ny"],
     "facets": {"element": "round-hss", "limit-state": "shear-and-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c60", "dimension": "parameters", "note_type": "definition", "title": "Parameters Ag, D, Lv, t for Round HSS", "clause": "G5-1", "source_page": "p.16.1-75",
     "body": "Ag = gross area; D = outside diameter; Lv = distance from max to zero shear; t = design wall thickness.",
     "quotes": ["A =gross cross-sectional area of member, in.2(mm2)\ng\nD =outside diameter, in. (mm)\nL =distance from maximum to zero shear force, in. (mm)\nv\nt =design wall thickness, in. (mm)"],
     "facets": {"element": "round-hss", "limit-state": "shear-and-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c61", "dimension": "commentary", "note_type": "finding", "title": "Commentary — Shear Buckling Controls for D/t > 100", "clause": "G5", "source_page": "p.16.1-75",
     "body": "A User Note explains G5-2a/G5-2b govern for D/t over 100, high-strength steels, and long lengths; else Fcr=0.6Fy governs.",
     "quotes": ["User Note:The shear buckling equations, Equations G5-2a and G5-2b, will con-\ntrol for D/tover 100, high-strength steels, and long lengths. For standard sect ions,\nshear yielding will usually control andF =0.6F .\ncr y"],
     "facets": {"element": "round-hss", "limit-state": "shear-and-shear-buckling", "stage": "strength", "method": "na"}},
    {"key": "c62", "dimension": "scope", "note_type": "concept", "title": "G6 Weak-Axis Shear in Doubly/Singly Symmetric Shapes", "clause": "G6", "source_page": "p.16.1-76",
     "body": "Section G6 gives nominal shear strength for each shear-resisting element (flange) of doubly/singly symmetric shapes loaded in the weak axis without torsion.",
     "quotes": ["G6. WEAK-AXIS SHEAR IN DOUBLY SYMMETRIC AND SINGLY\nSYMMETRIC SHAPES\nFor doubly and singly symmetric shapes loaded in the weak axis without torsion, the\nnominal shear strength, V , for each shear resisting element is:\nn"],
     "facets": {"element": "beam", "limit-state": "weak-axis-shear", "stage": "strength", "method": "na"}},
    {"key": "c63", "dimension": "equation", "note_type": "equation", "title": "Eq. G6-1 — Vn for Weak-Axis Shear", "clause": "G6-1", "source_page": "p.16.1-76",
     "body": "$V_n = 0.6 F_y b_f t_f C_{v2}$",
     "quotes": ["V =0.6FbtC (G6-1)\nn y f f v2"],
     "facets": {"element": "beam", "limit-state": "weak-axis-shear", "stage": "strength", "method": "na"}},
    {"key": "c64", "dimension": "parameters", "note_type": "definition", "title": "Parameters Cv2, bf, tf for Eq. G6-1", "clause": "G6-1", "source_page": "p.16.1-76",
     "body": "Cv2 per G2.2 with h/tw=bf/2tf (I-shapes/tees) or bf/tf (channels), kv=1.2; bf = flange width; tf = flange thickness.",
     "quotes": ["where\nC =web shear buckling strength coefficient, as defined in Section G2.2 with\nv2\nh/t = b /2t for I-shaped members and tees, or h/t = b /t for channels,\nw f f w f f\nand k =1.2\nv\nb =width of flange, in. (mm)\nf\nt =thickness of flange, in. (mm)\nf"],
     "facets": {"element": "beam", "limit-state": "weak-axis-shear", "stage": "strength", "method": "na"}},
    {"key": "c65", "dimension": "commentary", "note_type": "finding", "title": "Commentary — ASTM A6 Shapes, Cv2 = 1.0 for Weak-Axis Shear", "clause": "G6", "source_page": "p.16.1-76",
     "body": "A User Note states for all ASTM A6 W/S/M/HP shapes, Cv2 = 1.0 for weak-axis shear when Fy ≤ 70 ksi.",
     "quotes": ["User Note: For all ASTM A6 W, S, M and HP shapes, when F ≤ 70 ksi\ny\n(485 MPa), C =1.0.\nv2"],
     "facets": {"element": "beam", "limit-state": "weak-axis-shear", "stage": "strength", "method": "na"}},
    {"key": "c66", "dimension": "scope", "note_type": "concept", "title": "G7 Beams and Girders with Web Openings", "clause": "G7", "source_page": "p.16.1-76",
     "body": "Section G7 requires that the effect of web openings on the shear strength of steel and composite beams be determined.",
     "quotes": ["G7. BEAMS AND GIRDERS WITH WEB OPENINGS\nThe effect of all web openings on the shear strength of steel and composite beams\nshall be determined."],
     "facets": {"element": "beam-with-web-openings", "limit-state": "web-opening-shear", "stage": "strength", "method": "na"}},
    {"key": "c67", "dimension": "provision", "note_type": "definition", "title": "G7 — Reinforcement Requirement at Web Openings", "clause": "G7", "source_page": "p.16.1-76",
     "body": "Reinforcement is required whenever the required shear strength at a web opening exceeds the member's available strength there.",
     "quotes": ["Reinforcement shall be provided when the required strength\nexceeds the available strength of the member at the opening."],
     "facets": {"element": "beam-with-web-openings", "limit-state": "web-opening-shear", "stage": "strength", "method": "lrfd-and-asd"}},
    {"key": "c68", "dimension": "example", "note_type": "question", "title": "Gap — No Worked Examples in Chapter G Slice", "clause": "G7", "source_page": "p.16.1-76",
     "body": "This slice contains no worked-example inputs/outputs and no numeric method for sizing web-opening reinforcement under G7; such a procedure must come from elsewhere (e.g. AISC Design Guide 2), not be invented.",
     "quotes": [],
     "facets": {"element": "beam-with-web-openings", "limit-state": "web-opening-shear", "stage": "strength", "method": "na"}},
]
# fmt: on

OBSERVED = [
    ("c10", "c06", "input-to"),
    ("c15", "c06", "input-to"),
    ("c17", "c06", "input-to"),
    ("c30", "c27", "input-to"),
    ("c31", "c27", "input-to"),
    ("c32", "c27", "input-to"),
    ("c30", "c28", "input-to"),
    ("c31", "c28", "input-to"),
    ("c32", "c28", "input-to"),
    ("c28", "c27", "contrasts"),
    ("c34", "c05", "generalizes"),
    ("c34", "c23", "generalizes"),
    ("c57", "c56", "input-to"),
    ("c58", "c56", "input-to"),
    ("c56", "c55", "input-to"),
    ("c48", "c28", "specializes"),
    ("c63", "c28", "specializes"),
    ("c47", "c23", "generalizes"),
    ("c50", "c23", "generalizes"),
    ("c62", "c23", "generalizes"),
]

SUGGEST_SEEDS = ["c06", "c27", "c34", "c55"]

BACKBONE = [
    ("20260712-1906-aisc-360-provision", "20260712-1906-aisc-360-scope", "component-of"),
    ("20260712-1906-aisc-360-equation", "20260712-1906-aisc-360-provision", "input-to"),
    ("20260712-1906-aisc-360-parameters", "20260712-1906-aisc-360-equation", "input-to"),
    ("20260712-1906-aisc-360-applicability", "20260712-1906-aisc-360-provision", "qualifies"),
    ("20260712-1906-aisc-360-example", "20260712-1906-aisc-360-provision", "example-of"),
    ("20260712-1906-aisc-360-commentary", "20260712-1906-aisc-360-provision", "derives-from"),
]


def main() -> int:
    ids: dict[str, str] = {}
    stats = {
        "claims_created": 0,
        "claims_reused": 0,
        "quotes": 0,
        "dropped_quotes": [],
        "attach_dims": {},
        "errors": [],
    }
    for c in CANDIDATES:
        nid, err = add_claim(c)
        if not nid:
            stats["errors"].append({"key": c["key"], "error": err})
            continue
        ids[c["key"]] = nid
        if err == "reused":
            stats["claims_reused"] += 1
        else:
            stats["claims_created"] += 1
        stats["attach_dims"][c["dimension"]] = stats["attach_dims"].get(c["dimension"], 0) + 1
        qn, dropped = add_quotes(c, nid)
        stats["quotes"] += qn
        stats["dropped_quotes"].extend(dropped)

    for src, tgt, rel in BACKBONE:
        r = ncall(action="link", graph=SYN, source_id=src, target_id=tgt, relation=rel)
        if "error" in r:
            stats["errors"].append({"backbone": (src, rel, tgt), "error": r["error"]})
        else:
            stats.setdefault("backbone_ok", 0)
            stats["backbone_ok"] += 1

    stats["observed_edges"] = 0
    for sk, tk, rel in OBSERVED:
        if sk not in ids or tk not in ids:
            stats["errors"].append({"observed": (sk, rel, tk), "error": "missing id"})
            continue
        r = ncall(action="link", graph=GRAPH, source_id=ids[sk], target_id=ids[tk], relation=rel)
        if "error" in r:
            stats["errors"].append({"observed": (sk, rel, tk), "error": r["error"]})
        else:
            stats["observed_edges"] += 1

    stats["suggest_added"] = 0
    for key in SUGGEST_SEEDS:
        if key not in ids:
            continue
        sr = json.loads(suggest(kind="connections", graph=GRAPH, note_id=ids[key], top_k=5))
        for item in sr if isinstance(sr, list) else sr.get("suggestions", []):
            tid = item.get("note_id") or item.get("id")
            rel = item.get("relation") or "related-to"
            sim = item.get("similarity") or item.get("score") or 0
            if not tid or tid == ids[key] or sim < 0.55:
                continue
            lr = ncall(action="link", graph=GRAPH, source_id=ids[key], target_id=tid, relation=rel)
            if "error" not in lr:
                stats["suggest_added"] += 1

    print(json.dumps({"ids": ids, **stats}, indent=2))
    return 1 if stats["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
