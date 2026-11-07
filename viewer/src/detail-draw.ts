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

/** One pitch of a composite deck. Concrete is the fill plus the flute. The sheet is the gage. */
export function deckPitch(profile: Record<string, unknown>): SVGSVGElement | null {
  const pitch = Number(profile.pitch_m)
  const hr = Number(profile.hr_m)
  const fill = Number(profile.fill_m)
  const top = Number(profile.rib_top_m)
  const bottom = Number(profile.rib_bottom_m)
  const sheetT = Number(profile.sheet_m)
  if (!(pitch > top && top >= bottom && bottom > 0 && hr > 0 && fill >= 0)) return null
  const zTop = -(hr + fill)
  const zDeck = -hr
  const mid = pitch / 2
  const pts = [
    { x: 0, y: zTop }, { x: pitch, y: zTop }, { x: pitch, y: zDeck },
    { x: mid + top / 2, y: zDeck }, { x: mid + bottom / 2, y: 0 },
    { x: mid - bottom / 2, y: 0 }, { x: mid - top / 2, y: zDeck }, { x: 0, y: zDeck },
  ]
  const box = bounds(pts)
  const reach = Math.max(pitch, hr + fill)
  const sheet = openSheet(box, reach)
  concrete(sheet, pts, true)
  if (sheetT > 0) {
    const line = [
      [0, zDeck], [mid - top / 2, zDeck], [mid - bottom / 2, 0],
      [mid + bottom / 2, 0], [mid + top / 2, zDeck], [pitch, zDeck],
    ]
    sheet.svg.append(node("polyline", {
      points: line.map(([x, y]) => `${x},${y}`).join(" "),
      fill: "none", stroke: INK, "stroke-width": String(sheetT), "stroke-linejoin": "miter",
    }))
  }
  dimHorizontal(sheet, 0, pitch, 0, reach, dimText(pitch))
  dimVertical(sheet, zTop, 0, pitch, reach, dimText(hr + fill))
  const name = [typeof profile.profile === "string" ? profile.profile : "", typeof profile.gage === "number" ? `${profile.gage} gage` : ""].filter(Boolean).join(" · ")
  return finish(sheet, ["Section", name].filter(Boolean).join(" · "))
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
