/** Line drawings for the detail sheet. Coordinates are meters. Section z is up. */

const SVG = "http://www.w3.org/2000/svg"
const INK = "#1a1a1a"
let hatchSerial = 0

interface Pt { x: number; y: number }
interface Transverse {
  kind?: string
  diameter_m?: number
  cover_m?: number
  bar_size?: number | null
  loop_m?: number[][] | null
  radius_m?: number | null
  spacing_m?: number | null
}

export interface SectionDrawing {
  outline: Pt[]
  bars: { x: number; y: number; d: number }[]
  transverse: Transverse | null
  name: string
}

/** Section frame (y across, z up) to the sheet (x right, y down). */
export function sectionDrawing(
  outline: number[][],
  rebar: number[][] | null,
  transverse: unknown,
  name: string,
): SectionDrawing | null {
  const pts = outline.filter((p) => Array.isArray(p) && p.length >= 2)
    .map((p) => ({ x: Number(p[0]), y: -Number(p[1]) }))
    .filter((p) => Number.isFinite(p.x) && Number.isFinite(p.y))
  if (pts.length < 3) return null
  const bars = (rebar ?? []).filter((bar) => Array.isArray(bar) && bar.length >= 3)
    .map((bar) => ({ x: Number(bar[0]), y: -Number(bar[1]), d: Number(bar[2]) }))
    .filter((bar) => bar.d > 0 && Number.isFinite(bar.x) && Number.isFinite(bar.y))
  return { outline: pts, bars, transverse: readTransverse(transverse), name }
}

export function crossSection(section: SectionDrawing, mark = ""): SVGSVGElement {
  const box = bounds(section.outline)
  const span = Math.max(box.maxX - box.minX, box.maxY - box.minY, 0.05)
  const sheet = openSheet(box, span)
  concrete(sheet, section.outline, true)
  centerline(sheet, box, span, true)
  drawTransverse(sheet, section.transverse, true)
  for (const bar of section.bars) disk(sheet, bar.x, bar.y, bar.d / 2)
  const label = dimText(box.maxX - box.minX)
  const depth = dimText(box.maxY - box.minY)
  dimHorizontal(sheet, box.minX, box.maxX, box.maxY, span, label)
  dimVertical(sheet, box.minY, box.maxY, box.maxX, span, depth)
  const head = mark ? `Section ${mark}` : "Cross section"
  return finish(sheet, [head, section.name, transverseCallout(section.transverse)].filter(Boolean).join(" · "))
}

export function longitudinalSection(section: SectionDrawing, length: number | null): SVGSVGElement {
  const cross = bounds(section.outline)
  const depth = Math.max(cross.maxY - cross.minY, 0.05)
  const known = length !== null && length > 0
  const along = known ? length : depth * 4
  const box = { minX: 0, minY: cross.minY, maxX: along, maxY: cross.maxY }
  const span = Math.max(along, depth)
  const sheet = openSheet(box, span)
  concrete(sheet, [
    { x: 0, y: cross.minY },
    { x: along, y: cross.minY },
    { x: along, y: cross.maxY },
    { x: 0, y: cross.maxY },
  ], true)
  const cover = section.transverse?.cover_m
  const inset = typeof cover === "number" && cover > 0 ? cover : 0
  for (const layer of layers(section.bars)) {
    const y = layer.y - layer.d / 2
    filled(sheet, inset, y, Math.max(along - 2 * inset, layer.d), layer.d)
  }
  drawStirrupElevation(sheet, section.transverse, along, cross)
  if (known) dimHorizontal(sheet, 0, along, cross.maxY, span, dimText(along))
  else breakMark(sheet, along / 2, cross.minY, cross.maxY, span)
  dimVertical(sheet, cross.minY, cross.maxY, along, span, dimText(depth))
  const notes = ["Longitudinal section"]
  if (!known) notes.push("length not recorded")
  if (section.transverse && !(Number(section.transverse.spacing_m) > 0)) notes.push("spacing not recorded")
  return finish(sheet, notes.join(" · "))
}

/**
 * Plan, section, or elevation. `axes` keeps the centerlines when the rectangle is hatched.
 * `mark` draws a section cut along the long side, viewed looking down the sheet.
 */
export function rectangleSheet(
  width: number, height: number, title: string, cut: boolean, axes = !cut, mark = "",
): SVGSVGElement {
  const box = { minX: 0, minY: 0, maxX: width, maxY: height }
  const span = Math.max(width, height, 0.05)
  const sheet = openSheet(box, span)
  concrete(sheet, [
    { x: 0, y: 0 }, { x: width, y: 0 }, { x: width, y: height }, { x: 0, y: height },
  ], cut)
  if (axes) centerline(sheet, box, span, false)
  const bubbles = mark
    ? drawSectionMark(sheet, span, { x: 0, y: height / 2 }, { x: width, y: height / 2 }, mark, { x: 0, y: 1 })
    : []
  dimHorizontal(sheet, 0, width, height, span, dimText(width))
  dimVertical(sheet, 0, height, width, span, dimText(height), bubbles)
  return finish(sheet, title)
}

/**
 * Three true-scale views of stored bar centerlines. `solid` is
 * `[x0, x1, y0, y1, z0, z1]` in the same frame. The section is a cut at
 * mid-length looking along +x: a bar through the cut is a disk, and a
 * stirrup is the one nearest the cut. The elevation looks along +y and the
 * plan along +z; there a bar end-on is a disk and anything else is its
 * centerline at the bar diameter. Only the section is hatched.
 *
 * `outline` is the section polygon `(y, z)` about its centroid, as in
 * `drawing.outline_m`. When given, the cut draws it, seated on the cage
 * soffit, instead of the bounding box.
 */
export function cageViews(
  groups: BarGroupRecord[], solid: number[] | null, outline: number[][] | null = null,
): SVGSVGElement[] {
  const located = groups.filter((g) => Array.isArray(g.centerlines_m) && g.centerlines_m.length > 0)
  if (located.length === 0) return []
  const views: { title: string; u: 0 | 1 | 2; v: 0 | 1 | 2; hatch: boolean }[] = [
    { title: "Section", u: 1, v: 2, hatch: true },
    { title: "Elevation", u: 0, v: 2, hatch: false },
    { title: "Plan", u: 0, v: 1, hatch: false },
  ]
  return views.map((view) => view.u === 1 && view.v === 2
    ? cageSection(located, solid, outline)
    : cageView(view.title, view.u, view.v, view.hatch, located, solid))
}

/** `x` where the section is cut: mid-length of the solid, else of the bars. */
function cutStation(groups: BarGroupRecord[], solid: number[] | null): number | null {
  if (solid && solid.length >= 6) {
    const x0 = Number(solid[0]), x1 = Number(solid[1])
    if (Number.isFinite(x0) && Number.isFinite(x1)) return (x0 + x1) / 2
  }
  let lo = Infinity, hi = -Infinity
  for (const g of groups) for (const w of g.centerlines_m ?? []) for (const p of w) {
    const x = Number(p[0])
    if (Number.isFinite(x)) { lo = Math.min(lo, x); hi = Math.max(hi, x) }
  }
  return Number.isFinite(lo) ? (lo + hi) / 2 : null
}

/** Points `(y, z)` where a wire crosses the plane `x = cut`. */
function wireCrossings(wire: number[][], cut: number): Pt[] {
  const out: Pt[] = []
  for (let i = 0; i + 1 < wire.length; i++) {
    const a = wire[i], b = wire[i + 1]
    const xa = Number(a[0]), xb = Number(b[0])
    if (xa === xb || (xa - cut) * (xb - cut) > 0) continue
    const t = (cut - xa) / (xb - xa)
    out.push({ x: Number(a[1]) + t * (Number(b[1]) - Number(a[1])),
               y: -(Number(a[2]) + t * (Number(b[2]) - Number(a[2]))) })
  }
  return out
}

function cageSection(groups: BarGroupRecord[], solid: number[] | null, outline: number[][] | null): SVGSVGElement {
  const cut = cutStation(groups, solid)
  const disks: { p: Pt; r: number }[] = []
  const loops: { line: Pt[]; width: number }[] = []
  for (const group of groups) {
    const diameter = Number(group.diameter_m) > 0 ? Number(group.diameter_m) : 0.01
    const wires = (group.centerlines_m ?? []).filter((w) => w.length >= 2 && w.every((p) => p.length >= 3))
    const along = (w: number[][]) => Math.max(...w.map((p) => Number(p[0]))) - Math.min(...w.map((p) => Number(p[0])))
    const flat = wires.filter((w) => along(w) <= diameter)
    if (flat.length > 0 && cut !== null) {
      const at = (w: number[][]) => Math.abs(Number(w[0][0]) - cut)
      const nearest = flat.reduce((best, w) => (at(w) < at(best) ? w : best))
      loops.push({ line: nearest.map((p) => ({ x: Number(p[1]), y: -Number(p[2]) })), width: diameter })
    }
    if (cut === null) continue
    for (const w of wires) {
      if (along(w) <= diameter) continue
      for (const p of wireCrossings(w, cut)) disks.push({ p, r: diameter / 2 })
    }
  }
  let concretePts: Pt[] = []
  const poly = (outline ?? []).filter((p) => Array.isArray(p) && p.length >= 2).map((p) => [Number(p[0]), Number(p[1])])
  if (poly.length >= 3 && poly.every(([a, b]) => Number.isFinite(a) && Number.isFinite(b))) {
    const z0 = solid && solid.length >= 6 && Number.isFinite(Number(solid[4])) ? Number(solid[4]) : 0
    const zmin = Math.min(...poly.map(([, b]) => b))
    concretePts = poly.map(([a, b]) => ({ x: a, y: -(b - zmin + z0) }))
  } else {
    concretePts = solidCorners(solid, 1, 2).map(([a, b]) => ({ x: a, y: -b }))
  }
  const pts: Pt[] = [...concretePts, ...disks.map((d) => d.p), ...loops.flatMap((l) => l.line)]
  const box = pts.length ? bounds(pts) : { minX: 0, minY: 0, maxX: 1, maxY: 1 }
  const span = Math.max(box.maxX - box.minX, box.maxY - box.minY, 0.05)
  const sheet = openSheet(box, span)
  if (concretePts.length >= 3) concrete(sheet, concretePts, true)
  for (const l of loops) {
    sheet.svg.append(node("polyline", {
      points: l.line.map((p) => `${p.x},${p.y}`).join(" "),
      fill: "none", stroke: INK, "stroke-width": String(l.width),
      "stroke-linecap": "round", "stroke-linejoin": "round",
    }))
  }
  for (const d of disks) disk(sheet, d.p.x, d.p.y, Math.max(d.r, 1e-4))
  if (concretePts.length >= 3) {
    const cb = bounds(concretePts)
    dimHorizontal(sheet, cb.minX, cb.maxX, cb.maxY, span, dimText(cb.maxX - cb.minX))
    dimVertical(sheet, cb.minY, cb.maxY, cb.maxX, span, dimText(cb.maxY - cb.minY))
  }
  return finish(sheet, cut === null ? "Section" : `Section at mid-length, x = ${dimText(cut)}`)
}

function cageView(
  title: string, u: 0 | 1 | 2, v: 0 | 1 | 2, hatch: boolean,
  groups: BarGroupRecord[], solid: number[] | null,
): SVGSVGElement {
  const project = (p: number[]) => ({ x: Number(p[u]), y: -Number(p[v]) })
  const pts: Pt[] = []
  const concretePts = solidCorners(solid, u, v).map(([a, b]) => ({ x: a, y: -b }))
  pts.push(...concretePts)
  for (const group of groups) {
    for (const wire of group.centerlines_m ?? []) {
      for (const p of wire) if (p.length >= 3) pts.push(project(p))
    }
  }
  const box = pts.length ? bounds(pts) : { minX: 0, minY: 0, maxX: 1, maxY: 1 }
  const span = Math.max(box.maxX - box.minX, box.maxY - box.minY, 0.05)
  const sheet = openSheet(box, span)
  if (concretePts.length >= 3) concrete(sheet, concretePts, hatch)
  for (const group of groups) {
    const diameter = Number(group.diameter_m)
    const width = diameter > 0 ? diameter : span * 0.004
    const tol = Math.max(1e-4, 0.25 * (diameter > 0 ? diameter : 0))
    for (const wire of group.centerlines_m ?? []) {
      const line = wire.filter((p) => Array.isArray(p) && p.length >= 3).map(project)
        .filter((p) => Number.isFinite(p.x) && Number.isFinite(p.y))
      if (line.length === 0) continue
      const origin = line[0]
      const flat = line.every((p) => Math.hypot(p.x - origin.x, p.y - origin.y) <= tol)
      if (flat) {
        disk(sheet, origin.x, origin.y, Math.max(width / 2, 1e-4))
      } else {
        sheet.svg.append(node("polyline", {
          points: line.map((p) => `${p.x},${p.y}`).join(" "),
          fill: "none", stroke: INK, "stroke-width": String(width),
          "stroke-linecap": "round", "stroke-linejoin": "round",
        }))
      }
    }
  }
  if (solid && solid.length >= 6) {
    const u0 = Number(solid[u * 2]), u1 = Number(solid[u * 2 + 1])
    const v0 = Number(solid[v * 2]), v1 = Number(solid[v * 2 + 1])
    if ([u0, u1, v0, v1].every((n) => Number.isFinite(n))) {
      dimHorizontal(sheet, Math.min(u0, u1), Math.max(u0, u1), -Math.min(v0, v1), span, dimText(Math.abs(u1 - u0)))
      dimVertical(sheet, -Math.max(v0, v1), -Math.min(v0, v1), Math.max(u0, u1), span, dimText(Math.abs(v1 - v0)))
    }
  }
  if (title === "Plan") reinforcementArrows(sheet, groups, concretePts, box, span)
  return finish(sheet, title)
}

/**
 * Direction of the bars, drawn outside the plan.
 *
 * A bar along the member runs across the sheet; a bar across the member runs
 * down it. The arrows sit on the sides opposite the dimension lines.
 */
function reinforcementArrows(
  sheet: Sheet, groups: BarGroupRecord[], concretePts: Pt[],
  box: { minX: number; minY: number; maxX: number; maxY: number }, span: number,
) {
  let alongX = false
  let alongY = false
  for (const group of groups) {
    for (const wire of group.centerlines_m ?? []) {
      let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
      for (const p of wire) {
        if (!Array.isArray(p) || p.length < 2) continue
        const x = Number(p[0]), y = Number(p[1])
        if (!Number.isFinite(x) || !Number.isFinite(y)) continue
        minX = Math.min(minX, x)
        maxX = Math.max(maxX, x)
        minY = Math.min(minY, y)
        maxY = Math.max(maxY, y)
      }
      const dx = maxX - minX
      const dy = maxY - minY
      if (dx > dy * 3 && dx > span * 0.05) alongX = true
      if (dy > dx * 3 && dy > span * 0.05) alongY = true
    }
  }
  if (!alongX && !alongY) return
  const cb = concretePts.length >= 3 ? bounds(concretePts) : box
  const w = cb.maxX - cb.minX
  const h = cb.maxY - cb.minY
  const head = Math.max(span * 0.035, 0.04)
  if (alongX && w > 0) {
    const y = cb.minY - span * 0.16
    const x0 = cb.minX + w * 0.12
    const x1 = cb.maxX - w * 0.12
    spanArrow(sheet, x0, y, x1, y, span)
    growSheet(sheet, x0, y, head)
    growSheet(sheet, x1, y, head)
  }
  if (alongY && h > 0) {
    const x = cb.minX - span * 0.16
    const y0 = cb.maxY - h * 0.12
    const y1 = cb.minY + h * 0.12
    spanArrow(sheet, x, y0, x, y1, span)
    growSheet(sheet, x, y0, head)
    growSheet(sheet, x, y1, head)
  }
}

function growSheet(sheet: Sheet, x: number, y: number, margin: number) {
  sheet.minX = Math.min(sheet.minX, x - margin)
  sheet.minY = Math.min(sheet.minY, y - margin)
  sheet.maxX = Math.max(sheet.maxX, x + margin)
  sheet.maxY = Math.max(sheet.maxY, y + margin)
}

function solidCorners(solid: number[] | null, u: number, v: number): number[][] {
  if (!solid || solid.length < 6) return []
  const u0 = Number(solid[u * 2]), u1 = Number(solid[u * 2 + 1])
  const v0 = Number(solid[v * 2]), v1 = Number(solid[v * 2 + 1])
  if (![u0, u1, v0, v1].every((n) => Number.isFinite(n))) return []
  return [[u0, v0], [u1, v0], [u1, v1], [u0, v1]]
}

/** Drop panel centered on the slab mid-plane. The thickened plate is `thickness + drop`. */
export function dropSection(span: number, thickness: number, drop: number, width: number): SVGSVGElement | null {
  if (!(span > width && width > 0 && thickness > 0 && drop > 0)) return null
  const half = span / 2
  const dropHalf = width / 2
  const slab = thickness / 2
  const deep = (thickness + drop) / 2
  const pts = [
    { x: -half, y: -slab }, { x: -dropHalf, y: -slab }, { x: -dropHalf, y: -deep },
    { x: dropHalf, y: -deep }, { x: dropHalf, y: -slab }, { x: half, y: -slab },
    { x: half, y: slab }, { x: dropHalf, y: slab }, { x: dropHalf, y: deep },
    { x: -dropHalf, y: deep }, { x: -dropHalf, y: slab }, { x: -half, y: slab },
  ]
  const box = bounds(pts)
  const reach = Math.max(span, thickness + drop)
  const sheet = openSheet(box, reach)
  concrete(sheet, pts, true)
  dimHorizontal(sheet, -half, half, box.maxY, reach, dimText(span))
  dimVertical(sheet, -deep, deep, half, reach, dimText(thickness + drop))
  return finish(sheet, "Drop")
}

/** Topping between two rib centerlines. The stem hangs below the soffit. */
export function ribSection(
  topping: number,
  stem: number,
  width: number,
  spacing: number | null,
): SVGSVGElement | null {
  if (!(topping > 0 && stem > 0 && width > 0)) return null
  const known = spacing !== null && spacing > width
  const across = known ? spacing : Math.max(topping * 6, width * 3)
  const half = width / 2
  const pts = [
    { x: 0, y: -topping }, { x: across, y: -topping }, { x: across, y: stem },
    { x: across - half, y: stem }, { x: across - half, y: 0 }, { x: half, y: 0 },
    { x: half, y: stem }, { x: 0, y: stem },
  ]
  const box = bounds(pts)
  const reach = Math.max(across, topping + stem)
  const sheet = openSheet(box, reach)
  concrete(sheet, pts, true)
  if (known) dimHorizontal(sheet, 0, across, box.maxY, reach, dimText(across))
  else breakMark(sheet, across / 2, -topping, stem, reach)
  dimVertical(sheet, -topping, stem, across, reach, dimText(topping + stem))
  const caption = known ? "Section" : "Section · spacing not recorded"
  return finish(sheet, caption)
}

/**
 * Composite deck cut across one bay.
 *
 * `span` is the bay width perpendicular to the ribs, the same length a concrete
 * slab section uses. The flute repeats at the recorded pitch, centered on the
 * bay. With no span, one pitch is drawn.
 */
export function deckSection(profile: Record<string, unknown>, span: number | null): SVGSVGElement | null {
  const pitch = Number(profile.pitch_m)
  const hr = Number(profile.hr_m)
  const fill = Number(profile.fill_m)
  const top = Number(profile.rib_top_m)
  const bottom = Number(profile.rib_bottom_m)
  const sheetT = Number(profile.sheet_m)
  if (!(pitch > top && top >= bottom && bottom > 0 && hr > 0 && fill >= 0)) return null
  const across = span !== null && span > pitch * 0.5 ? span : pitch
  const zTop = -(hr + fill)
  const mid = across / 2
  const soffit = (x: number) => deckSoffit(x, mid, pitch, hr, top, bottom)
  const xs = deckStations(across, mid, pitch, top, bottom)
  const pts: Pt[] = [{ x: 0, y: zTop }, { x: across, y: zTop }]
  for (let i = xs.length - 1; i >= 0; i--) pts.push({ x: xs[i], y: soffit(xs[i]) })
  const box = bounds(pts)
  const reach = Math.max(across, hr + fill)
  const sheet = openSheet(box, reach)
  concrete(sheet, pts, true)
  if (sheetT > 0) {
    sheet.svg.append(node("polyline", {
      points: xs.map((x) => `${x},${soffit(x)}`).join(" "),
      fill: "none", stroke: INK, "stroke-width": "1.6", "stroke-linejoin": "miter",
      "vector-effect": "non-scaling-stroke",
    }))
  }
  dimHorizontal(sheet, 0, across, 0, reach, dimText(across))
  dimVertical(sheet, zTop, 0, across, reach, dimText(hr + fill))
  const name = [typeof profile.profile === "string" ? profile.profile : "", typeof profile.gage === "number" ? `${profile.gage} gage` : ""].filter(Boolean).join(" · ")
  return finish(sheet, ["Section", name].filter(Boolean).join(" · "))
}

/**
 * Plan of one slab bay, looking down. Structural y is up on the sheet.
 *
 * `rings` are the stored plan polygons. With none, the bay is the rectangle
 * of the two spans, secondary along x and primary along y. One-way draws a
 * span arrow along the primary span. Two-way draws both. A deck draws the
 * flutes along the stored rib direction.
 */
export function slabPlan(
  rings: number[][][],
  primary: number | null,
  secondary: number | null,
  floor: string,
  ribs: { pitch: number; direction: [number, number] } | null,
): SVGSVGElement | null {
  const source = rings.filter((ring) => ring.length >= 3)
  const drawn = source.length > 0 ? source : fallbackBay(primary, secondary)
  if (drawn.length === 0) return null
  const pts: Pt[] = []
  const polys = drawn.map((ring) => ring.map((p) => {
    const q = { x: p[0], y: -p[1] }
    pts.push(q)
    return q
  }))
  const box = bounds(pts)
  const reach = Math.max(box.maxX - box.minX, box.maxY - box.minY, 0.05)
  const sheet = openSheet(box, reach)
  for (const poly of polys) concrete(sheet, poly, true)
  if (ribs && ribs.pitch > 1e-4 && Math.hypot(ribs.direction[0], ribs.direction[1]) > 1e-8) {
    drawPlanRibs(sheet, polys, ribs)
  } else if (floor === "one_way" || floor === "two_way") {
    drawSpanArrows(sheet, box, floor, primary)
  }
  dimHorizontal(sheet, box.minX, box.maxX, box.maxY, reach, dimText(box.maxX - box.minX))
  dimVertical(sheet, box.minY, box.maxY, box.maxX, reach, dimText(box.maxY - box.minY))
  const caption = floor === "one_way" ? "Plan · one-way"
    : floor === "two_way" ? "Plan · two-way"
    : floor === "composite_deck" ? "Plan · deck"
    : "Plan"
  return finish(sheet, caption)
}

function fallbackBay(primary: number | null, secondary: number | null): number[][][] {
  if (!(primary !== null && primary > 0 && secondary !== null && secondary > 0)) return []
  return [[[0, 0], [secondary, 0], [secondary, primary], [0, primary]]]
}

/** Flute centerlines, parallel to the rib direction and centered on the bay. */
function drawPlanRibs(
  sheet: Sheet,
  polys: Pt[][],
  ribs: { pitch: number; direction: [number, number] },
) {
  const len = Math.hypot(ribs.direction[0], ribs.direction[1])
  const ux = ribs.direction[0] / len
  const uy = -ribs.direction[1] / len
  const nx = -uy
  const ny = ux
  for (const poly of polys) {
    let smin = Infinity
    let smax = -Infinity
    for (const p of poly) {
      const s = p.x * nx + p.y * ny
      if (s < smin) smin = s
      if (s > smax) smax = s
    }
    const mid = (smin + smax) / 2
    const k0 = Math.ceil((smin - mid) / ribs.pitch - 1e-6)
    const k1 = Math.floor((smax - mid) / ribs.pitch + 1e-6)
    for (let k = k0; k <= k1; k++) {
      const ends = clipLine(poly, nx, ny, mid + k * ribs.pitch)
      if (ends) hairline(sheet, ends[0].x, ends[0].y, ends[1].x, ends[1].y, "")
    }
  }
}

/** The two farthest crossings of `n · p = s` with a polygon. */
function clipLine(poly: Pt[], nx: number, ny: number, s: number): [Pt, Pt] | null {
  const hits: Pt[] = []
  for (let i = 0; i < poly.length; i++) {
    const a = poly[i]
    const b = poly[(i + 1) % poly.length]
    const sa = a.x * nx + a.y * ny
    const sb = b.x * nx + b.y * ny
    const d = sb - sa
    if (Math.abs(d) < 1e-9) continue
    const t = (s - sa) / d
    if (t < -1e-6 || t > 1 + 1e-6) continue
    hits.push({ x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y) })
  }
  let best = 0
  let ia = 0
  let ib = 1
  for (let i = 0; i < hits.length; i++) {
    for (let j = i + 1; j < hits.length; j++) {
      const dist = Math.hypot(hits[i].x - hits[j].x, hits[i].y - hits[j].y)
      if (dist > best) {
        best = dist
        ia = i
        ib = j
      }
    }
  }
  return best > 1e-4 ? [hits[ia], hits[ib]] : null
}

/** Span arrows. One-way follows the primary span; two-way draws both. */
function drawSpanArrows(
  sheet: Sheet,
  box: { minX: number; minY: number; maxX: number; maxY: number },
  floor: string,
  primary: number | null,
) {
  const w = box.maxX - box.minX
  const h = box.maxY - box.minY
  const cx = (box.minX + box.maxX) / 2
  const cy = (box.minY + box.maxY) / 2
  const alongY = !(primary !== null && primary > 0) || Math.abs(h - primary) <= Math.abs(w - primary)
  const inset = 0.18
  const reach = Math.max(w, h)
  if (floor === "two_way" || alongY) {
    spanArrow(sheet, cx, box.minY + h * inset, cx, box.maxY - h * inset, reach)
  }
  if (floor === "two_way" || !alongY) {
    spanArrow(sheet, box.minX + w * inset, cy, box.maxX - w * inset, cy, reach)
  }
}

function spanArrow(sheet: Sheet, x0: number, y0: number, x1: number, y1: number, span: number) {
  hairline(sheet, x0, y0, x1, y1, "")
  const ang = Math.atan2(y1 - y0, x1 - x0)
  const head = Math.max(span * 0.035, 0.04)
  arrowHead(sheet, x0, y0, ang + Math.PI, head)
  arrowHead(sheet, x1, y1, ang, head)
}

function arrowHead(sheet: Sheet, x: number, y: number, ang: number, head: number) {
  const wing = 2.6
  const tip = (th: number) => `${x + Math.cos(th) * head},${y + Math.sin(th) * head}`
  sheet.svg.append(node("polygon", {
    points: `${x},${y} ${tip(ang + wing)} ${tip(ang - wing)}`,
    fill: INK,
  }))
}

/** Stations of one repeating flute, including the two ends of the bay. */
function deckStations(across: number, mid: number, pitch: number, top: number, bottom: number): number[] {
  const xs = new Set<number>([0, across])
  const k0 = Math.floor((0 - mid) / pitch) - 1
  const k1 = Math.ceil((across - mid) / pitch) + 1
  for (let k = k0; k <= k1; k++) {
    const center = mid + k * pitch
    for (const at of [0, -bottom / 2, bottom / 2, -top / 2, top / 2, -pitch / 2, pitch / 2]) {
      const x = center + at
      if (x > 1e-6 && x < across - 1e-6) xs.add(x)
    }
  }
  return [...xs].sort((a, b) => a - b)
}

/** Sheet elevation at `x`. Zero is the bottom of a flute and `-hr` is the pan. */
function deckSoffit(x: number, mid: number, pitch: number, hr: number, top: number, bottom: number): number {
  let local = (x - mid) % pitch
  if (local < 0) local += pitch
  if (local > pitch / 2) local -= pitch
  const a = Math.abs(local)
  const halfBottom = bottom / 2
  const halfTop = top / 2
  if (a <= halfBottom + 1e-9) return 0
  if (!(halfTop > halfBottom + 1e-9) || a >= halfTop - 1e-9) return -hr
  return -hr * (a - halfBottom) / (halfTop - halfBottom)
}

/** One group of identical placed bars from `drawing.detail.groups`. Paths are `[x, z]` in the member's elevation plane. */
export interface BarGroupRecord {
  mark: string
  role: string
  direction: string
  bar_size: number
  diameter_m: number
  count: number
  length_m: number
  shape: string
  path_m: number[][]
  /** One polyline per bar, `[x, y, z]` meters in the member frame. Empty when the bar was not located. */
  centerlines_m?: number[][][]
  x_positions_m: number[]
  z_positions_m?: number[]
  laps: number
  note: string
  mass_kg: number
}

/**
 * Concrete drawn behind the bars, in elevation coordinates (x along, z up). The first
 * rectangle is the member itself: it sets the dimensions, the depth exaggeration, and
 * which bars are labelled above or below. The rest are context (supports, slab, column).
 */
export interface ElevationFrame {
  outline: { x0: number; x1: number; z0: number; z1: number }[]
  /** Holes in the elevation, same rectangles as `outline`. */
  voids?: { x0: number; x1: number; z0: number; z1: number }[]
  /** Bars cut by the elevation, drawn as dots: `[x, z, diameter]`. */
  dots?: number[][]
}

const TRANSVERSE = new Set(["stirrup", "tie", "crosstie", "spiral"])

/**
 * A section cut drawn on the view you cut through.
 * `cross` is a cut through the depth at one station, looking back toward the start of the member.
 * `plan` is a horizontal cut, looking down.
 */
export interface SectionMark {
  letter: string
  kind: "cross" | "plan"
}

/**
 * Placed bars in elevation. Longitudinal bars are their centerline paths; stirrups and ties
 * are a stroke at each recorded station. A long, thin member is drawn with its depth
 * exaggerated so the bar layers separate; the caption states the factor. `upright` draws
 * the member axis vertically (columns). `mark` names the section taken from this view.
 */
export function barElevation(
  groups: BarGroupRecord[], frame: ElevationFrame, title: string, upright = false, mark?: SectionMark,
): SVGSVGElement | null {
  if (frame.outline.length === 0) return null
  const body = frame.outline[0]
  const minX = Math.min(body.x0, body.x1), maxX = Math.max(body.x0, body.x1)
  const minZ = Math.min(body.z0, body.z1), maxZ = Math.max(body.z0, body.z1)
  const length = maxX - minX
  const depth = maxZ - minZ
  if (!(length > 0 && depth > 0)) return null
  const aspect = length / depth
  const k = upright || aspect <= 10 ? 1 : aspect / 10
  const at = (x: number, z: number): Pt => upright ? { x: z, y: -x } : { x, y: -z * k }
  const corners = frame.outline.flatMap((r) => [at(r.x0, r.z0), at(r.x1, r.z1)])
  const box = bounds(corners)
  const span = Math.max(box.maxX - box.minX, box.maxY - box.minY, 0.05)
  const sheet = openSheet(box, span)
  for (const r of frame.outline) {
    const a = at(r.x0, r.z0), b = at(r.x1, r.z1)
    concrete(sheet, [a, { x: b.x, y: a.y }, b, { x: a.x, y: b.y }], false)
  }
  for (const [x, z, d] of frame.dots ?? []) {
    const p = at(x, z)
    disk(sheet, p.x, p.y, Math.max(d / 2, span * 0.004))
  }
  const labelled: Pt[] = []
  const callouts: Callout[] = []
  const midZ = (minZ + maxZ) / 2
  const cutY = mark?.kind === "cross" ? at(minX + (maxX - minX) * 0.62, midZ).y : undefined
  for (const group of groups) {
    const path = (group.path_m ?? []).filter((p) => Array.isArray(p) && p.length >= 2)
    if (path.length < 2) continue
    const xs = group.x_positions_m ?? []
    const zs = group.z_positions_m ?? []
    if (TRANSVERSE.has(group.role) && group.role !== "spiral") {
      const zSpan = path.map((p) => Number(p[1]))
      const z0 = Math.min(...zSpan), z1 = Math.max(...zSpan)
      for (const x of xs) stroke(sheet, [at(x, z0), at(x, z1)], 0.8)
      continue
    }
    const copies: [number, number][] = xs.length ? xs.map((x) => [x, 0])
      : zs.length ? zs.map((z) => [0, z]) : [[0, 0]]
    copies.forEach(([dx, dz], i) => {
      const moved = path.map((p) => [Number(p[0]) + dx, Number(p[1]) + dz])
      const pts = moved.map((p) => at(p[0], p[1]))
      stroke(sheet, pts, group.role === "spiral" ? 0.8 : 1.4)
      const labelThis = copies.length <= 2 || i === 0 || i === copies.length - 1
      if (!labelThis) return
      if (upright) {
        const spot = markSpot(pts, labelled, span, cutY)
        labelled.push(spot)
        callouts.push({ anchor: spot, text: group.mark, above: true })
      } else if (i === 0) {
        callouts.push({ anchor: markSpot(pts, [], span), text: group.mark, above: runHeight(moved) >= midZ })
      }
    })
  }
  paintVoids(sheet, frame, at)
  const bubbles = mark ? drawMemberSectionMark(sheet, span, at, minX, maxX, minZ, maxZ, mark) : []
  const a = at(minX, minZ), b = at(maxX, maxZ)
  if (upright) {
    placeUprightCallouts(sheet, callouts, Math.min(a.x, b.x), span, bubbles)
    dimVertical(sheet, Math.min(a.y, b.y), Math.max(a.y, b.y), Math.max(a.x, b.x), span, dimText(length), bubbles)
    dimHorizontal(sheet, Math.min(a.x, b.x), Math.max(a.x, b.x), Math.max(a.y, b.y), span, dimText(depth))
  } else {
    const below = placeCallouts(sheet, callouts, b.y, a.y)
    dimHorizontal(sheet, a.x, b.x, below, span, dimText(length))
    sheet.maxY = Math.max(sheet.maxY, below + span * 0.16)
    dimVertical(sheet, b.y, a.y, b.x, span, dimText(depth), bubbles)
  }
  const caption = [title, k > 1 ? `depth drawn ×${k.toFixed(1)}` : ""].filter(Boolean).join(" · ")
  return finish(sheet, caption)
}

/**
 * Section symbol: a dashed cut with a lettered circle and a view arrow at each end.
 * The arrows point the way the section is seen. Circles sit just outside the cut faces.
 */
interface Bubble { x: number; y: number; r: number }

/** Opening rectangles, drawn over the bars so the hole stays empty. */
function paintVoids(sheet: Sheet, frame: ElevationFrame, at: (x: number, z: number) => Pt) {
  for (const r of frame.voids ?? []) {
    const a = at(r.x0, r.z0), b = at(r.x1, r.z1)
    sheet.svg.append(node("polygon", {
      points: [a, { x: b.x, y: a.y }, b, { x: a.x, y: b.y }].map((p) => `${p.x},${p.y}`).join(" "),
      fill: "#fff", stroke: INK, "stroke-width": "1.2", "stroke-linejoin": "miter",
      "vector-effect": "non-scaling-stroke",
    }))
  }
}

function drawSectionMark(sheet: Sheet, span: number, faceA: Pt, faceB: Pt, letter: string, look: Pt): Bubble[] {
  const r = labelSize(sheet) * 0.72
  const ux = faceB.x - faceA.x
  const uy = faceB.y - faceA.y
  const n = Math.hypot(ux, uy) || 1
  const dx = ux / n
  const dy = uy / n
  const gap = r * 0.35
  const cA = { x: faceA.x - dx * (r + gap), y: faceA.y - dy * (r + gap) }
  const cB = { x: faceB.x + dx * (r + gap), y: faceB.y + dy * (r + gap) }
  const dash = `${Math.max(span * 0.018, r * 0.35)} ${Math.max(span * 0.01, r * 0.22)}`
  hairline(sheet, cA.x + dx * r, cA.y + dy * r, cB.x - dx * r, cB.y - dy * r, dash)
  sectionBubble(sheet, cA, r, letter, look)
  sectionBubble(sheet, cB, r, letter, look)
  return [{ ...cA, r }, { ...cB, r }]
}

function sectionBubble(sheet: Sheet, c: Pt, r: number, letter: string, look: Pt) {
  sheet.svg.append(node("circle", {
    cx: String(c.x), cy: String(c.y), r: String(r),
    fill: "#fff", stroke: INK, "stroke-width": "1.1", "vector-effect": "non-scaling-stroke",
  }))
  const label = node("text", {
    x: String(c.x), y: String(c.y),
    "text-anchor": "middle", "dominant-baseline": "middle",
    "font-family": "Inter, sans-serif", "font-size": String(r * 1.15), fill: INK,
  })
  label.textContent = letter
  sheet.svg.append(label)
  const tip = { x: c.x + look.x * r * 1.85, y: c.y + look.y * r * 1.85 }
  const base = { x: c.x + look.x * r * 1.05, y: c.y + look.y * r * 1.05 }
  const w = r * 0.38
  const px = -look.y * w
  const py = look.x * w
  sheet.svg.append(node("polygon", {
    points: `${tip.x},${tip.y} ${base.x + px},${base.y + py} ${base.x - px},${base.y - py}`,
    fill: INK,
  }))
  const reach = r * 2.1
  sheet.minX = Math.min(sheet.minX, c.x - reach, tip.x)
  sheet.maxX = Math.max(sheet.maxX, c.x + reach, tip.x)
  sheet.minY = Math.min(sheet.minY, c.y - reach, tip.y)
  sheet.maxY = Math.max(sheet.maxY, c.y + reach, tip.y)
}

/** Cut on a member elevation. The cross cut is at 62% of the length, clear of the midspan marks. */
function drawMemberSectionMark(
  sheet: Sheet,
  span: number,
  at: (x: number, z: number) => Pt,
  minX: number, maxX: number, minZ: number, maxZ: number,
  mark: SectionMark,
): Bubble[] {
  if (mark.kind === "cross") {
    const x = minX + (maxX - minX) * 0.62
    const midZ = (minZ + maxZ) / 2
    const start = at(minX, midZ)
    const end = at(maxX, midZ)
    return drawSectionMark(sheet, span, at(x, minZ), at(x, maxZ), mark.letter, unit(start.x - end.x, start.y - end.y))
  }
  const z = (minZ + maxZ) / 2
  const midX = (minX + maxX) / 2
  const up = at(midX, maxZ)
  const down = at(midX, minZ)
  return drawSectionMark(sheet, span, at(minX, z), at(maxX, z), mark.letter, unit(down.x - up.x, down.y - up.y))
}

function unit(x: number, y: number): Pt {
  const n = Math.hypot(x, y) || 1
  return { x: x / n, y: y / n }
}

/**
 * Wall plan. `dots` are `[x along the wall, y through the thickness, diameter]`,
 * with `y = 0` at the wall center. A long wall is drawn with its thickness
 * stretched so the two curtains separate; the caption states the factor.
 */
export function wallPlan(dots: number[][], length: number, thickness: number, title: string): SVGSVGElement | null {
  if (!(length > 0 && thickness > 0)) return null
  const aspect = length / thickness
  const k = aspect > 8 ? aspect / 8 : 1
  const at = (x: number, y: number): Pt => ({ x, y: -y * k })
  const half = thickness / 2
  const corners = [at(0, -half), at(length, half)]
  const box = bounds(corners)
  const span = Math.max(box.maxX - box.minX, box.maxY - box.minY, 0.05)
  const sheet = openSheet(box, span)
  const a = at(0, -half), b = at(length, half)
  concrete(sheet, [a, { x: b.x, y: a.y }, b, { x: a.x, y: b.y }], false)
  for (const dot of dots) {
    if (dot.length < 3) continue
    const p = at(dot[0], dot[1])
    disk(sheet, p.x, p.y, Math.max(dot[2] / 2, span * 0.003))
  }
  dimHorizontal(sheet, a.x, b.x, Math.max(a.y, b.y), span, dimText(length))
  const caption = [title, k > 1 ? `thickness drawn ×${k.toFixed(1)}` : ""].filter(Boolean).join(" · ")
  return finish(sheet, caption)
}

/** Mean z of the path's longest segment: the bar's layer, ignoring hook tails. */
function runHeight(path: number[][]): number {
  let best = -1, z = Number(path[0][1])
  for (let j = 0; j + 1 < path.length; j++) {
    const len = Math.hypot(Number(path[j + 1][0]) - Number(path[j][0]), Number(path[j + 1][1]) - Number(path[j][1]))
    if (len > best) { best = len; z = (Number(path[j][1]) + Number(path[j + 1][1])) / 2 }
  }
  return z
}

/** A point on the path's longest segment, nudged along it until clear of earlier labels. */
function markSpot(pts: Pt[], taken: Pt[], span: number, avoidY?: number): Pt {
  let i = 0, best = -1
  for (let j = 0; j + 1 < pts.length; j++) {
    const len = Math.hypot(pts[j + 1].x - pts[j].x, pts[j + 1].y - pts[j].y)
    if (len > best) { best = len; i = j }
  }
  const p = pts[i], q = pts[i + 1]
  const clear = span * 0.06
  const offCut = span * 0.08
  for (const t of [0.5, 0.3, 0.7, 0.15, 0.85, 0.4, 0.6]) {
    const spot = { x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t }
    if (avoidY !== undefined && Math.abs(spot.y - avoidY) < offCut) continue
    if (taken.every((o) => Math.hypot(o.x - spot.x, o.y - spot.y) > clear)) return spot
  }
  return { x: (p.x + q.x) / 2, y: (p.y + q.y) / 2 }
}

/**
 * Bar marks for an upright member, set to the left of the concrete and of any section
 * bubble. The leader stays on the bar until it is clear of the cut, then runs out.
 */
function placeUprightCallouts(sheet: Sheet, callouts: Callout[], leftFace: number, span: number, bubbles: Bubble[]) {
  const size = labelSize(sheet) * 0.7
  const height = size * 1.1
  const gap = size * 0.5
  const left = bubbles.filter((b) => b.x <= leftFace + span * 0.02)
  const outer = left.reduce((edge, b) => Math.min(edge, b.x - b.r), leftFace)
  const sorted = [...callouts].sort((p, q) => p.anchor.y - q.anchor.y)
  let prev = -Infinity
  for (const c of sorted) {
    let y = c.anchor.y
    for (const b of left) {
      if (Math.abs(y - b.y) < b.r + height) y = b.y + b.r + height
    }
    if (y < prev + height + gap * 0.35) y = prev + height + gap * 0.35
    prev = y
    const width = Math.max(c.text.length * size * 0.62, size)
    const x = outer - gap - width / 2
    const endX = x + width / 2
    if (Math.abs(y - c.anchor.y) > 1e-6) hairline(sheet, c.anchor.x, c.anchor.y, c.anchor.x, y, "")
    hairline(sheet, c.anchor.x, y, endX, y, "")
    disk(sheet, c.anchor.x, c.anchor.y, size * 0.12)
    markLabel(sheet, x, y, c.text)
    sheet.minX = Math.min(sheet.minX, x - width / 2)
    sheet.minY = Math.min(sheet.minY, y - height)
    sheet.maxY = Math.max(sheet.maxY, y + height)
  }
}

interface Callout {
  anchor: Pt
  text: string
  above: boolean
}

/**
 * Bar marks as leader callouts outside a horizontal member: top-layer bars above `topY`,
 * bottom-layer bars below `bottomY`, stacked in rows so no two labels overlap. Grows the
 * sheet to fit and returns the lowest y used, where the length dimension can start.
 */
function placeCallouts(sheet: Sheet, callouts: Callout[], topY: number, bottomY: number): number {
  const size = labelSize(sheet) * 0.7
  const height = size * 1.1
  const gap = size * 0.5
  let lowest = bottomY
  for (const above of [true, false]) {
    const rows: [number, number][][] = []
    const side = callouts.filter((c) => c.above === above).sort((p, q) => p.anchor.x - q.anchor.x)
    for (const c of side) {
      const half = (c.text.length * size * 0.62 + gap) / 2
      const lo = c.anchor.x - half, hi = c.anchor.x + half
      let row = rows.findIndex((r) => r.every(([s, e]) => hi < s || lo > e))
      if (row < 0) row = rows.push([]) - 1
      rows[row].push([lo, hi])
      const offset = gap + (height + gap) * row + height / 2
      const y = above ? topY - offset : bottomY + offset
      hairline(sheet, c.anchor.x, c.anchor.y, c.anchor.x, above ? y + height / 2 : y - height / 2, "")
      disk(sheet, c.anchor.x, c.anchor.y, size * 0.12)
      markLabel(sheet, c.anchor.x, y, c.text)
      sheet.minY = Math.min(sheet.minY, y - height)
      sheet.maxY = Math.max(sheet.maxY, y + height)
      if (!above) lowest = Math.max(lowest, y + height / 2)
    }
  }
  return lowest
}

function stroke(sheet: Sheet, pts: Pt[], width: number) {
  sheet.svg.append(node("polyline", {
    points: pts.map((p) => `${p.x},${p.y}`).join(" "),
    fill: "none", stroke: INK, "stroke-width": String(width),
    "stroke-linejoin": "round", "vector-effect": "non-scaling-stroke",
  }))
}

function markLabel(sheet: Sheet, x: number, y: number, text: string) {
  const size = labelSize(sheet) * 0.7
  const width = text.length * size * 0.62
  const height = size * 1.1
  sheet.svg.append(node("rect", {
    x: String(x - width / 2), y: String(y - height / 2),
    width: String(width), height: String(height), fill: "#ffffff", stroke: INK,
    "stroke-width": "0.5", "vector-effect": "non-scaling-stroke",
  }))
  const label = node("text", {
    x: String(x), y: String(y),
    "text-anchor": "middle", "dominant-baseline": "middle",
    "font-family": "Inter, sans-serif", "font-size": String(size), fill: INK,
  })
  label.textContent = text
  sheet.svg.append(label)
}

interface Sheet {
  svg: SVGSVGElement
  hatch: string
  minX: number
  minY: number
  maxX: number
  maxY: number
}

function openSheet(box: { minX: number; minY: number; maxX: number; maxY: number }, span: number): Sheet {
  const svg = document.createElementNS(SVG, "svg")
  svg.setAttribute("class", "sheet")
  const hatch = `hatch-${++hatchSerial}`
  const defs = node("defs")
  const spacing = span * 0.045
  const pattern = node("pattern", {
    id: hatch, patternUnits: "userSpaceOnUse",
    width: String(spacing), height: String(spacing), patternTransform: "rotate(45)",
  })
  pattern.append(node("line", {
    x1: "0", y1: "0", x2: "0", y2: String(spacing),
    stroke: INK, "stroke-width": String(spacing * 0.08),
  }))
  defs.append(pattern)
  svg.append(defs)
  const pad = span * 0.28
  return { svg, hatch, minX: box.minX - pad, minY: box.minY - pad * 0.55, maxX: box.maxX + pad, maxY: box.maxY + pad }
}

function finish(sheet: Sheet, caption: string): SVGSVGElement {
  const w = Math.max(sheet.maxX - sheet.minX, 1e-4)
  const h = Math.max(sheet.maxY - sheet.minY, 1e-4)
  sheet.svg.setAttribute("viewBox", `${sheet.minX} ${sheet.minY} ${w} ${h}`)
  sheet.svg.dataset.caption = caption
  return sheet.svg
}

function concrete(sheet: Sheet, pts: Pt[], cut: boolean) {
  const poly = node("polygon", {
    points: pts.map((p) => `${p.x},${p.y}`).join(" "),
    fill: cut ? `url(#${sheet.hatch})` : "none",
    stroke: INK,
    "stroke-width": "1.4",
    "stroke-linejoin": "miter",
    "vector-effect": "non-scaling-stroke",
  })
  sheet.svg.append(poly)
}

function centerline(
  sheet: Sheet,
  box: { minX: number; minY: number; maxX: number; maxY: number },
  span: number,
  throughOrigin: boolean,
) {
  const over = span * 0.08
  const dash = `${span * 0.05} ${span * 0.012} ${span * 0.008} ${span * 0.012}`
  const midX = throughOrigin && box.minX <= 0 && box.maxX >= 0 ? 0 : (box.minX + box.maxX) / 2
  const midY = throughOrigin && box.minY <= 0 && box.maxY >= 0 ? 0 : (box.minY + box.maxY) / 2
  hairline(sheet, box.minX - over, midY, box.maxX + over, midY, dash)
  hairline(sheet, midX, box.minY - over, midX, box.maxY + over, dash)
}

function drawTransverse(sheet: Sheet, transverse: Transverse | null, inSection: boolean) {
  if (!transverse || !inSection) return
  const diameter = Number(transverse.diameter_m)
  if (!(diameter > 0)) return
  const radius = Number(transverse.radius_m)
  if (radius > 0) {
    sheet.svg.append(node("circle", {
      cx: "0", cy: "0", r: String(radius),
      fill: "none", stroke: INK, "stroke-width": String(diameter),
    }))
    return
  }
  const loop = transverse.loop_m
  if (!Array.isArray(loop) || loop.length < 3) return
  const pts = loop.filter((p) => Array.isArray(p) && p.length >= 2)
    .map((p) => `${Number(p[0])},${-Number(p[1])}`)
  sheet.svg.append(node("polygon", {
    points: pts.join(" "),
    fill: "none", stroke: INK, "stroke-width": String(diameter),
    "stroke-linejoin": "miter",
  }))
}

function drawStirrupElevation(
  sheet: Sheet,
  transverse: Transverse | null,
  length: number,
  cross: { minY: number; maxY: number },
) {
  if (!transverse) return
  const spacing = Number(transverse.spacing_m)
  const diameter = Number(transverse.diameter_m)
  if (!(spacing > 0) || !(diameter > 0)) return
  const loop = transverse.loop_m
  let top = cross.minY
  let bot = cross.maxY
  if (Array.isArray(loop)) {
    const zs = loop.filter((p) => Array.isArray(p) && p.length >= 2).map((p) => -Number(p[1]))
    if (zs.length) {
      top = Math.min(...zs)
      bot = Math.max(...zs)
    }
  }
  const cover = Number(transverse.cover_m)
  const start = cover > 0 ? cover : spacing / 2
  for (let x = start; x <= length - start + 1e-6; x += spacing) {
    filled(sheet, x - diameter / 2, top, diameter, bot - top)
  }
}

function disk(sheet: Sheet, x: number, y: number, r: number) {
  sheet.svg.append(node("circle", { cx: String(x), cy: String(y), r: String(r), fill: INK }))
}

function filled(sheet: Sheet, x: number, y: number, w: number, h: number) {
  if (!(w > 0) || !(h > 0)) return
  sheet.svg.append(node("rect", { x: String(x), y: String(y), width: String(w), height: String(h), fill: INK }))
}

function hairline(sheet: Sheet, x1: number, y1: number, x2: number, y2: number, dash: string) {
  const line = node("line", {
    x1: String(x1), y1: String(y1), x2: String(x2), y2: String(y2),
    stroke: INK, "stroke-width": "0.7", "vector-effect": "non-scaling-stroke",
  })
  if (dash) line.setAttribute("stroke-dasharray", dash)
  sheet.svg.append(line)
}

function dimHorizontal(sheet: Sheet, x0: number, x1: number, yObj: number, span: number, text: string) {
  const y = yObj + span * 0.1
  const tick = span * 0.012
  const ext = span * 0.02
  hairline(sheet, x0, yObj + ext, x0, y + tick, "")
  hairline(sheet, x1, yObj + ext, x1, y + tick, "")
  hairline(sheet, x0, y, x1, y, "")
  slash(sheet, x0, y, tick)
  slash(sheet, x1, y, tick)
  dimLabel(sheet, (x0 + x1) / 2, y, text, span)
}

function dimVertical(sheet: Sheet, y0: number, y1: number, xObj: number, span: number, text: string, bubbles: Bubble[] = []) {
  const size = labelSize(sheet)
  const halfW = text.length * size * 0.62 / 2
  const halfH = size * 1.15 / 2
  const mid = (y0 + y1) / 2
  let x = xObj + span * 0.12
  for (const b of bubbles) {
    const reach = b.r * 2.2
    const overlapsY = mid + halfH > b.y - reach && mid - halfH < b.y + reach
    if (!overlapsY || b.x + b.r < xObj) continue
    x = Math.max(x, b.x + b.r + halfW + span * 0.04)
  }
  const tick = span * 0.012
  const ext = span * 0.02
  hairline(sheet, xObj + ext, y0, x + tick, y0, "")
  hairline(sheet, xObj + ext, y1, x + tick, y1, "")
  hairline(sheet, x, y0, x, y1, "")
  slash(sheet, x, y0, tick)
  slash(sheet, x, y1, tick)
  dimLabel(sheet, x, (y0 + y1) / 2, text, span)
}

function slash(sheet: Sheet, x: number, y: number, size: number) {
  hairline(sheet, x - size, y + size, x + size, y - size, "")
}

/** Same on-screen size for every sheet. A squarer plan was coming out smaller than a long section. */
function labelSize(sheet: Sheet): number {
  const viewW = Math.max(sheet.maxX - sheet.minX, 1e-6)
  const viewH = Math.max(sheet.maxY - sheet.minY, 1e-6)
  const frame = 1.75
  const ofHeight = 0.038
  return viewW / viewH > frame ? ofHeight * viewW / frame : ofHeight * viewH
}

function dimLabel(sheet: Sheet, x: number, y: number, text: string, _span: number) {
  const size = labelSize(sheet)
  const width = text.length * size * 0.62
  const height = size * 1.15
  sheet.svg.append(node("rect", {
    x: String(x - width / 2), y: String(y - height / 2),
    width: String(width), height: String(height), fill: "#ffffff",
  }))
  const label = node("text", {
    x: String(x), y: String(y),
    "text-anchor": "middle", "dominant-baseline": "middle",
    "font-family": "Inter, sans-serif", "font-size": String(size), fill: INK,
  })
  label.textContent = text
  sheet.svg.append(label)
}

function breakMark(sheet: Sheet, x: number, y0: number, y1: number, span: number) {
  const mid = (y0 + y1) / 2
  const w = span * 0.03
  sheet.svg.append(node("polyline", {
    points: `${x},${y0} ${x - w},${mid - w} ${x + w},${mid + w} ${x},${y1}`,
    fill: "none", stroke: INK, "stroke-width": "1.1", "vector-effect": "non-scaling-stroke",
  }))
}

function layers(bars: { y: number; d: number }[]): { y: number; d: number }[] {
  const out: { y: number; d: number }[] = []
  for (const bar of bars) {
    const found = out.find((layer) => Math.abs(layer.y - bar.y) < 1e-3)
    if (!found) out.push({ y: bar.y, d: bar.d })
  }
  return out
}

function readTransverse(value: unknown): Transverse | null {
  if (!value || typeof value !== "object") return null
  return value as Transverse
}

function transverseCallout(transverse: Transverse | null): string {
  if (!transverse?.kind) return ""
  const size = typeof transverse.bar_size === "number" ? `#${transverse.bar_size}` : ""
  const word = transverse.kind === "spiral" ? "spiral" : transverse.kind === "tie" ? "ties" : "stirrups"
  const spacing = Number(transverse.spacing_m)
  const at = spacing > 0 ? `at ${dimText(spacing)}` : ""
  return [size, word, at].filter(Boolean).join(" ")
}

/** Stud shanks on the beam elevation, rising from the top of steel. */
export function studElevation(span: number, studs: Record<string, unknown>): SVGSVGElement | null {
  const stations = Array.isArray(studs.s_m) ? studs.s_m as number[] : []
  const length = Number(studs.length_m)
  const diameter = Number(studs.diameter_m)
  if (stations.length === 0 || !(length > 0)) return null
  const beam = span > 0 ? span : Math.max(...stations)
  const pad = Math.max(length * 0.35, 0.02)
  const top = 0
  const steel = length
  const svg = node("svg", {
    viewBox: `${-pad} ${-pad} ${beam + 2 * pad} ${steel + 2 * pad}`,
  }) as SVGSVGElement
  svg.dataset.caption = `${stations.length} studs, from the top of steel`
  svg.append(node("line", {
    x1: "0", y1: String(steel), x2: String(beam), y2: String(steel),
    stroke: INK, "stroke-width": "1.6", "vector-effect": "non-scaling-stroke",
  }))
  const shank = diameter > 0 ? Math.max(diameter, beam * 0.004) : beam * 0.004
  for (const station of stations) {
    svg.append(node("line", {
      x1: String(station), y1: String(steel),
      x2: String(station), y2: String(top),
      stroke: INK, "stroke-width": "1.25", "vector-effect": "non-scaling-stroke",
    }))
    svg.append(node("circle", {
      cx: String(station), cy: String(top), r: String(shank),
      fill: INK,
    }))
  }
  return svg
}

function dimText(meters: number): string {
  const mm = Math.abs(meters) * 1000
  if (mm < 1000) return `${mm.toFixed(mm < 20 ? 1 : 0)} mm`
  return `${meters.toFixed(2)} m`
}

function bounds(pts: Pt[]) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
  for (const p of pts) {
    minX = Math.min(minX, p.x)
    maxX = Math.max(maxX, p.x)
    minY = Math.min(minY, p.y)
    maxY = Math.max(maxY, p.y)
  }
  return { minX, minY, maxX, maxY }
}

function node(name: string, attrs: Record<string, string> = {}): SVGElement {
  const el = document.createElementNS(SVG, name)
  for (const [key, value] of Object.entries(attrs)) el.setAttribute(key, value)
  return el
}
