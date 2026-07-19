#!/usr/bin/env python3
"""Batch-finish scribe: quotes, supports links, attaches, backbone, observed edges."""
import json
import sys

from zettelkasten.server import note

PROJECT = "menegroth"
SYN = "aisc-360-canon"
GRAPH = "aisc-360-16"

CLAIMS = {
    "c5": "20260712-1932-web-compression-buckling-limit-state",
    "c6": "20260712-1932-web-compression-buckling-factors-and-end",
    "c7": "20260712-1932-web-panel-zone-shear-limit-state",
    "c8": "20260712-1932-panel-zone-shear-yielding-low-axial-load",
    "c9": "20260712-1932-panel-zone-shear-parameter-definitions",
    "c10": "20260712-1932-panel-zone-shear-equations-at-high-axial",
    "c11": "20260712-1932-unframed-ends-transverse-stiffeners",
    "c12": "20260712-1932-additional-stiffener-design-requirements",
    "c13": "20260712-1932-doubler-plate-design-references-by-force",
    "c14": "20260712-1932-transverse-forces-on-plate-elements",
    "c15": "20260712-1932-chapter-k-hss-box-connection-scope",
    "c16": "20260712-1932-hss-connection-design-allowable-strength",
    "c17": "20260712-1932-chapter-k-parameter-definitions",
    "c18": "20260712-1932-effective-width-for-rectangular-hss-conn",
    "c19": "20260712-1932-concentrated-forces-on-hss-limit-states",
    "c20": "20260712-1932-plate-to-round-hss-bending-strengths-k2",
    "c21": "20260712-1932-limits-of-applicability-for-plate-to-rou",
    "c22": "20260712-1932-hss-to-hss-truss-connection-classificati",
    "c23": "20260712-1933-truss-connection-geometric-parameters",
    "c24": "20260712-1933-rectangular-hss-gapped-k-truss-strengths",
    "c25": "20260712-1933-rectangular-hss-overlapped-k-branch-yiel",
    "c26": "20260712-1933-truss-connection-resistance-factors-by-l",
    "c27": "20260712-1933-truss-connection-applicability-limits-ta",
    "c28": "20260712-1933-hss-to-hss-moment-connections",
    "c29": "20260712-1933-moment-connection-combined-load-interact",
    "c30": "20260712-1933-round-moment-connection-interaction-squa",
    "c31": "20260712-1933-welds-of-plates-branches-to-rectangular",
    "c32": "20260712-1933-weld-strength-relations-k5-1-k5-4",
    "c33": "20260712-1933-weld-resistance-factors-by-weld-type",
    "c34": "20260712-1933-moment-connection-applicability-limits-t",
    "c35": "20260712-1933-chapter-l-serviceability-limit-states",
    "c36": "20260712-1933-serviceability-deflection-and-drift-limi",
    "c37": "20260712-1933-connection-slip-serviceability-provision",
    "c38": "20260712-1933-chapter-m-fabrication-and-erection",
    "c39": "20260712-1933-heat-straightening-temperature-limits",
    "c40": "20260712-1935-column-base-milling-and-fit-tolerances",
    "c41": "20260712-1933-user-note-guidance-for-hss-connections-a",
    "c42": "20260712-1933-chapter-n-quality-control-assurance",
}

QUOTE_SPECS = [
    ("c5", 2, "Web compression buckling limit state", "scope", "§J10.5", "This section applies to a pair of compressive single-concentrated forces or the com-"),
    ("c6", 1, "Web compression buckling factors and end reduction", "provision", "§J10.5", "When the pair of concentrated compressive forces to be resisted is applied at a dis-"),
    ("c6", 2, "Web compression buckling factors and end reduction", "provision", "§J10.5", "Ω=1.67 (ASD)"),
    ("c7", 1, "Web panel-zone shear limit state", "scope", "§J10.6", "6. Web Panel-Zone Shear"),
    ("c7", 2, "Web panel-zone shear limit state", "scope", "§J10.6", "This section applies to double-concentrated forces applied to one or both flanges of"),
    ("c8", 1, "Panel-zone shear yielding, low axial load", "equation", "Eq. J10-9", "Rn = 0.60Fy dc tw"),
    ("c8", 2, "Panel-zone shear yielding, low axial load", "equation", "§J10.6", "(1) For αPr ≤ 0.4Py"),
    ("c9", 1, "Panel-zone shear parameter definitions", "parameters", "§J10.6", "Ag = gross cross-sectional area of member, in.2 (mm2)"),
    ("c9", 2, "Panel-zone shear parameter definitions", "parameters", "§J10.6", "Py = FyAg, axial yield strength of the column, kips (N)"),
    ("c9", 3, "Panel-zone shear parameter definitions", "parameters", "§J10.6", "α= 1.0 (LRFD); = 1.6 (ASD)"),
    ("c10", 1, "Panel-zone shear equations at high axial load OCR-garbled", "equation", "§J10.6", "(2) For αPr > 0.4Py"),
    ("c10", 2, "Panel-zone shear equations at high axial load OCR-garbled", "equation", "§J10.6", "(1) For αP"),
    ("c11", 1, "Unframed ends transverse stiffeners", "provision", "§J10.7", "At unframed ends of beams and girders not otherwise restrained against rotation"),
    ("c12", 1, "Additional stiffener design requirements", "provision", "§J10.8", "plate girder flange(s) shall be designed as axially compressed members (columns) in"),
    ("c12", 2, "Additional stiffener design requirements", "provision", "§J10.8", "flange or moment connection plate delivering the concentrated load, nor less than"),
    ("c13", 1, "Doubler plate design references by force type", "provision", "§J10.9", "Doubler plates required for shear strength (see Section J10.6) shall be designed in"),
    ("c14", 1, "Transverse forces on plate elements", "scope", "§J10.10", "10. Transverse Forces on Plate Elements"),
    ("c14", 2, "Transverse forces on plate elements", "scope", "§J10.10", "When a force is applied transverse to the plane of a plate element, the nominal"),
    ("c15", 1, "Chapter K HSS/box connection scope", "scope", "Ch. K", "This chapter addresses additional requirements for connections to HSS members and box"),
    ("c15", 2, "Chapter K HSS/box connection scope", "scope", "Ch. K", "of Chapter J also apply."),
    ("c16", 1, "HSS connection design/allowable strength basis", "provision", "§K1", "The design strength, φRn, φMn and φPn, and the allowable strength, Rn / Ω, Mn / Ω and"),
    ("c17", 1, "Chapter K parameter definitions", "parameters", "§K1.1", "B = overall width of rectangular HSS main member, measured 90° to the plane of"),
    ("c17", 2, "Chapter K parameter definitions", "parameters", "§K1.1", "D = outside diameter of round HSS main member, in. (mm)"),
    ("c17", 3, "Chapter K parameter definitions", "parameters", "§K1.1", "t = design wall thickness of HSS main member, in. (mm)"),
    ("c18", 1, "Effective width for rectangular HSS connections OCR-garbled", "equation", "§K1.2a", "transverse to the face of the member shall be taken as:"),
    ("c18", 2, "Effective width for rectangular HSS connections OCR-garbled", "equation", "§K1.2a", "(K1-1)"),
    ("c19", 1, "Concentrated forces on HSS limit states", "scope", "§K2", "K2. CONCENTRATED FORCES ON HSS"),
    ("c19", 2, "Concentrated forces on HSS limit states", "scope", "§K2", "Limit State: HSS Local Yielding"),
    ("c19", 3, "Concentrated forces on HSS limit states", "scope", "Table K2.1", "Limit State: HSS Plastification"),
    ("c20", 1, "Plate-to-round-HSS bending strengths (K2-1b, K2-2b)", "equation", "Table K2.1", "Mn = 0.5BbRn"),
    ("c20", 2, "Plate-to-round-HSS bending strengths (K2-1b, K2-2b)", "equation", "Table K2.1", "Mn = 0.8lbRn"),
    ("c20", 3, "Plate-to-round-HSS bending strengths (K2-1b, K2-2b)", "equation", "Table K2.1", "φ=0.90 (LRFD) Ω=1.67 (ASD)"),
    ("c21", 1, "Limits of applicability for plate-to-round HSS (Table K2.1A)", "applicability", "Table K2.1A", "Material strength: Fy ≤ 52 ksi (360 MPa)"),
    ("c21", 2, "Limits of applicability for plate-to-round HSS (Table K2.1A)", "applicability", "Table K2.1A", "Ductility: Fy / Fu ≤ 0.8 Note: ASTM A500 Grade C is acceptable."),
    ("c22", 1, "HSS-to-HSS truss connection classification", "scope", "§K3", "K3. HSS-TO-HSS TRUSS CONNECTIONS"),
    ("c22", 2, "HSS-to-HSS truss connection classification", "scope", "§K3", "shear in the chord member, the connection shall be classified as a T-connection"),
    ("c22", 3, "HSS-to-HSS truss connection classification", "scope", "§K3", "nection, the connection shall be classified as a K-connection."),
    ("c23", 1, "Truss-connection geometric parameters", "parameters", "§K3.1", "g = gap between toes of branch members in a gapped K-connection, neglecting the"),
    ("c23", 2, "Truss-connection geometric parameters", "parameters", "§K3.1", "θ= acute angle between the branch and chord (degrees)"),
    ("c24", 1, "Rectangular HSS gapped-K truss strengths (K3-7..K3-9)", "equation", "Table K3.2", "Pnsinθ = Fyt 2 (9.8βeffγ0.5)Qf"),
    ("c24", 2, "Rectangular HSS gapped-K truss strengths (K3-7..K3-9)", "equation", "Table K3.2", "Pnsinθ = 0.6FytB (2η+β+β eop)"),
    ("c24", 3, "Rectangular HSS gapped-K truss strengths (K3-7..K3-9)", "equation", "Table K3.2", "Pn = Fybt b (2Hb + Bb + Be − 4tb)"),
    ("c25", 1, "Rectangular HSS overlapped-K branch yielding (K3-11, K3-12)", "equation", "Table K3.2", "Pn,i = Fybitbi (2Hbi − 4tbi + Bei + Bej)"),
    ("c25", 2, "Rectangular HSS overlapped-K branch yielding (K3-11, K3-12)", "equation", "Table K3.2", "Pn,i = Fybitbi (2Hbi − 4tbi + Bbi + Bej)"),
    ("c26", 1, "Truss-connection resistance factors by limit state", "provision", "Table K3.2", "φ=0.90 (LRFD) Ω=1.67 (ASD)"),
    ("c26", 2, "Truss-connection resistance factors by limit state", "provision", "Table K3.2", "φ=0.95 (LRFD) Ω=1.58 (ASD)"),
    ("c26", 3, "Truss-connection resistance factors by limit state", "provision", "Table K3.2", "This limit state need not be checked for square branches."),
    ("c27", 1, "Truss-connection applicability limits (Tables K3.1A, K3.2A)", "applicability", "Table K3.1A", "D / t ≤ 40 for cross-connections"),
    ("c27", 2, "Truss-connection applicability limits (Tables K3.1A, K3.2A)", "applicability", "Table K3.1A", "0.4 < Db / D ≤ 1.0 for gapped K-connections"),
    ("c27", 3, "Truss-connection applicability limits (Tables K3.1A, K3.2A)", "applicability", "Table K3.1A", "Material strength: Fy and Fyb ≤ 52 ksi (360 MPa)"),
    ("c28", 1, "HSS-to-HSS moment connections", "scope", "§K4", "K4. HSS-TO-HSS MOMENT CONNECTIONS"),
    ("c28", 2, "HSS-to-HSS moment connections", "scope", "§K4", "two branch members that are directly welded to a continuous chord that passes"),
    ("c28", 3, "HSS-to-HSS moment connections", "scope", "Table K4.2", "Limit state: Chord distortional failure, for"),
    ("c29", 1, "Moment-connection combined-load interaction (K4-8)", "provision", "§K4", "LRFD: [Pu /(φPn)] + [Mr-ip /(φMn-ip )] + [Mr-op /(φMn-op )] ≤ 1.0 (K4-8)"),
    ("c30", 1, "Round moment-connection interaction squares in-plane term", "provision", "§K4", "LRFD: [Pu /(φPn)] + [Mr-ip /(φMn-ip )]"),
    ("c31", 1, "Welds of plates/branches to rectangular HSS", "scope", "§K5", "K5. WELDS OF PLATES AND BRANCHES TO RECTANGULAR HSS"),
    ("c31", 2, "Welds of plates/branches to rectangular HSS", "scope", "§K5", "Interaction shall be considered."),
    ("c32", 1, "Weld strength relations (K5-1..K5-4)", "equation", "Table K5.1", "Pn = Fnwtwle"),
    ("c32", 2, "Weld strength relations (K5-1..K5-4)", "equation", "Table K5.1", "Mn-ip = FnwSip"),
    ("c32", 3, "Weld strength relations (K5-1..K5-4)", "equation", "Table K5.1", "Mn-op = FnwSop"),
    ("c32", 4, "Weld strength relations (K5-1..K5-4)", "equation", "Table K5.1", "le = 2Be"),
    ("c33", 1, "Weld resistance factors by weld type", "provision", "§K5", "φ = 0.75 (LRFD)"),
    ("c33", 2, "Weld resistance factors by weld type", "provision", "§K5", "φ = 0.80 (LRFD)"),
    ("c33", 3, "Weld resistance factors by weld type", "provision", "§K5", "Ω=1.88 (ASD)"),
    ("c34", 1, "Moment-connection applicability limits (Tables K4.1A, K4.2A)", "applicability", "Table K4.1A", "Width ratio: 0.2 < Db /D ≤ 1.0"),
    ("c34", 2, "Moment-connection applicability limits (Tables K4.1A, K4.2A)", "applicability", "Table K4.2A", "Chord wall slenderness: B /t and H / t ≤ 35"),
    ("c34", 3, "Moment-connection applicability limits (Tables K4.1A, K4.2A)", "applicability", "Table K4.2A", "Width ratio: Bb / B ≥ 0.25"),
    ("c35", 1, "Chapter L serviceability limit states", "scope", "Ch. L", "bility limit states of deflections, drift, vibration, wind-induced motion, thermal distortion,"),
    ("c35", 2, "Chapter L serviceability limit states", "scope", "Ch. L", "and connection slip."),
    ("c36", 1, "Serviceability deflection and drift limits", "provision", "§L2", "Deflections in structural members and structural systems shall be limited so as not to"),
    ("c36", 2, "Serviceability deflection and drift limits", "provision", "§L3", "Drift shall be limited so as not to impair the serviceability of the structure."),
    ("c36", 3, "Serviceability deflection and drift limits", "provision", "§L1", "C, are not intended for use with the provisions of this chapter."),
    ("c37", 1, "Connection slip serviceability provision", "provision", "§L7", "The effects of connection slip shall be included in the design where slip at bolted"),
    ("c38", 1, "Chapter M fabrication and erection", "scope", "Ch. M", "This chapter addresses requirements for shop drawings, fabrication, shop painting and"),
    ("c39", 1, "Heat-straightening temperature limits", "provision", "§M2.1", "not exceed 1,100°F (590°C) for ASTM A514/A514M and ASTM A852/A852M"),
    ("c39", 2, "Heat-straightening temperature limits", "provision", "§M2.1", "steels nor 1,200°F (650°C) for other steels."),
    ("c40", 1, "Column base milling and fit tolerances", "provision", "§M2.8", "faces, except as stipulated in subparagraphs (b) and (c) of this section."),
    ("c40", 2, "Column base milling and fit tolerances", "provision", "§M4.4", "Lack of contact bearing not exceeding a gap of 1/16 in. (2 mm), regardless of the type"),
    ("c41", 1, "User-note guidance for HSS connections and welding", "commentary", "§K1", "based on strength limit states only. See the"),
    ("c41", 2, "User-note guidance for HSS connections and welding", "commentary", "§M2.4", "complete-joint-penetration groove welds of HSS T-, Y- and K-connections."),
    ("c42", 1, "Chapter N quality control/assurance", "scope", "Ch. N", "QUALITY CONTROL AND QUALITY ASSURANCE"),
    ("c42", 2, "Chapter N quality control/assurance", "scope", "§N5.5b", "plete-joint-penetration (CJP) groove welds subject to transversely applied tension"),
]

ATTACHES = [
    ("20260712-1932-web-compression-buckling-limit-state", "scope"),
    ("20260712-1932-web-compression-buckling-factors-and-end", "provision"),
    ("20260712-1932-web-panel-zone-shear-limit-state", "scope"),
    ("20260712-1932-panel-zone-shear-yielding-low-axial-load", "equation"),
    ("20260712-1932-panel-zone-shear-parameter-definitions", "parameters"),
    ("20260712-1932-panel-zone-shear-equations-at-high-axial", "equation"),
    ("20260712-1932-unframed-ends-transverse-stiffeners", "provision"),
    ("20260712-1932-additional-stiffener-design-requirements", "provision"),
    ("20260712-1932-doubler-plate-design-references-by-force", "provision"),
    ("20260712-1932-transverse-forces-on-plate-elements", "scope"),
    ("20260712-1932-chapter-k-hss-box-connection-scope", "scope"),
    ("20260712-1932-hss-connection-design-allowable-strength", "provision"),
    ("20260712-1932-chapter-k-parameter-definitions", "parameters"),
    ("20260712-1932-effective-width-for-rectangular-hss-conn", "equation"),
    ("20260712-1932-concentrated-forces-on-hss-limit-states", "scope"),
    ("20260712-1932-plate-to-round-hss-bending-strengths-k2", "equation"),
    ("20260712-1932-limits-of-applicability-for-plate-to-rou", "applicability"),
    ("20260712-1932-hss-to-hss-truss-connection-classificati", "scope"),
    ("20260712-1933-truss-connection-geometric-parameters", "parameters"),
    ("20260712-1933-rectangular-hss-gapped-k-truss-strengths", "equation"),
    ("20260712-1933-rectangular-hss-overlapped-k-branch-yiel", "equation"),
    ("20260712-1933-truss-connection-resistance-factors-by-l", "provision"),
    ("20260712-1933-truss-connection-applicability-limits-ta", "applicability"),
    ("20260712-1933-hss-to-hss-moment-connections", "scope"),
    ("20260712-1933-moment-connection-combined-load-interact", "provision"),
    ("20260712-1933-round-moment-connection-interaction-squa", "provision"),
    ("20260712-1933-welds-of-plates-branches-to-rectangular", "scope"),
    ("20260712-1933-weld-strength-relations-k5-1-k5-4", "equation"),
    ("20260712-1933-weld-resistance-factors-by-weld-type", "provision"),
    ("20260712-1933-moment-connection-applicability-limits-t", "applicability"),
    ("20260712-1933-chapter-l-serviceability-limit-states", "scope"),
    ("20260712-1933-serviceability-deflection-and-drift-limi", "provision"),
    ("20260712-1933-connection-slip-serviceability-provision", "provision"),
    ("20260712-1933-chapter-m-fabrication-and-erection", "scope"),
    ("20260712-1933-heat-straightening-temperature-limits", "provision"),
    ("20260712-1935-column-base-milling-and-fit-tolerances", "provision"),
    ("20260712-1933-user-note-guidance-for-hss-connections-a", "commentary"),
    ("20260712-1933-chapter-n-quality-control-assurance", "scope"),
    ("20260712-1935-no-worked-examples-in-window", "example"),
]

BACKBONE = [
    ("20260712-1906-aisc-360-provision", "20260712-1906-aisc-360-scope", "component-of"),
    ("20260712-1906-aisc-360-equation", "20260712-1906-aisc-360-provision", "input-to"),
    ("20260712-1906-aisc-360-parameters", "20260712-1906-aisc-360-equation", "input-to"),
    ("20260712-1906-aisc-360-applicability", "20260712-1906-aisc-360-provision", "qualifies"),
    ("20260712-1906-aisc-360-commentary", "20260712-1906-aisc-360-provision", "derives-from"),
]

OBSERVED = [
    ("20260712-1932-hss-to-hss-truss-connection-classificati", "20260712-1933-truss-connection-geometric-parameters", "defines"),
    ("20260712-1932-chapter-k-hss-box-connection-scope", "20260712-1932-web-panel-zone-shear-limit-state", "depends-on"),
    ("20260712-1933-round-moment-connection-interaction-squa", "20260712-1933-moment-connection-combined-load-interact", "contrasts"),
]


def main() -> int:
    results = {"quotes": 0, "links": 0, "attaches": 0, "backbone": 0, "observed": 0, "errors": []}

    for ck, n, title, dim, page, text in QUOTE_SPECS:
        qtitle = f"Quote {n}: {title}"
        r = json.loads(note(
            action="add", graph=GRAPH, title=qtitle, type="quote", body=text,
            tags=["quote", "grounding", dim], source_page=page,
            project=PROJECT, synthesis_graph=SYN,
        ))
        if "error" in r:
            results["errors"].append({"op": "quote", "title": qtitle, "error": r["error"]})
            continue
        results["quotes"] += 1
        qid = r["id"]
        cid = CLAIMS[ck]
        lr = json.loads(note(action="link", graph=GRAPH, source_id=qid, target_id=cid, relation="supports"))
        if "error" in lr:
            results["errors"].append({"op": "link", "qid": qid, "error": lr["error"]})
        else:
            results["links"] += 1

    for nid, tag in ATTACHES:
        ar = json.loads(note(
            action="attach", graph=GRAPH, note_id=nid, tag=tag,
            project=PROJECT, synthesis_graph=SYN,
        ))
        if "error" in ar:
            results["errors"].append({"op": "attach", "id": nid, "error": ar["error"]})
        else:
            results["attaches"] += 1

    for src, tgt, rel in BACKBONE:
        br = json.loads(note(action="link", graph="aisc-360-canon", source_id=src, target_id=tgt, relation=rel))
        if "error" in br:
            results["errors"].append({"op": "backbone", "edge": (src, rel, tgt), "error": br["error"]})
        else:
            results["backbone"] += 1

    for src, tgt, rel in OBSERVED:
        or_ = json.loads(note(action="link", graph=GRAPH, source_id=src, target_id=tgt, relation=rel))
        if "error" in or_:
            results["errors"].append({"op": "observed", "edge": (src, rel, tgt), "error": or_["error"]})
        else:
            results["observed"] += 1

    print(json.dumps(results, indent=2))
    return 1 if results["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
