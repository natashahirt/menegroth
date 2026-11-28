import {
  barElevation, cageViews, crossSection, deckSection, dropSection, longitudinalSection, rectangleSheet, ribSection, sectionDrawing, slabPlan, studElevation, wallPlan,
  type SectionMark,
  type BarGroupRecord, type ElevationFrame,
} from "./detail-draw"
import { overlayPicture, type OverlayMode, type OverlayScene } from "./detail-overlay"

/** The solve dossier carried in a scene header. Numbers are SI. Null means the solve did not record that value. */

export interface ComponentRecord {
  id: string
  kind: string
  title: string
  design_index?: number
  story?: number
  governing?: { check?: string; ratio?: number | null; ok?: boolean | null; clause?: string }
  bind?: {
    frame_elements?: number[]
    shell_kinds?: number[]
    elevation_m?: number | null
    cell_indices?: number[]
    plan_m?: unknown
    footing?: number
    plane?: { origin?: number[]; normal?: number[] }
    z0_m?: number | null
    z1_m?: number | null
  }
  drawing?: Record<string, unknown>
  checks?: CheckRow[]
  method?: Record<string, unknown>
  path?: PathEvent[]
}

export interface CheckRow {
  name?: string
  clause?: string
  ratio?: number | null
  ok?: boolean | null
  governing?: boolean
  demand?: number | null
  demand_unit?: string
  capacity?: number | null
  capacity_unit?: string
  [key: string]: unknown
}

export interface PathEvent {
  t_s?: number
  layer?: string
  stage?: string
  element_id?: string
  event?: string
  data?: Record<string, unknown>
}

export function readComponents(header: { components?: unknown }): ComponentRecord[] {
  return Array.isArray(header.components) ? header.components as ComponentRecord[] : []
}

export function matchFrame(records: ComponentRecord[], element: number): ComponentRecord | null {
  return records.find((record) => record.bind?.frame_elements?.includes(element)) ?? null
}

export function matchFooting(records: ComponentRecord[], index: number): ComponentRecord | null {
  return records.find((record) => record.bind?.footing === index) ?? null
}

/** The wall record whose `design_index` is the scene's `shell_wall` value. */
export function matchWall(records: ComponentRecord[], wallIndex: number): ComponentRecord | null {
  return records.find((record) => record.kind === "wall" && record.design_index === wallIndex) ?? null
}

/** `elevation` is viewer Y, which is structural Z. Scenes without `shell_wall` fall back to the plane test for walls. */
export function matchShell(
  records: ComponentRecord[],
  kind: number,
  elevation: number,
  point: { x: number; y: number; z: number },
): ComponentRecord | null {
  let best: ComponentRecord | null = null
  let bestGap = Infinity
  for (const record of records) {
    const kinds = record.bind?.shell_kinds ?? []
    if (!kinds.includes(kind)) continue
    if (kind === 1) {
      if (!onWall(record, point, elevation)) continue
      return record
    }
    const level = record.bind?.elevation_m
    if (typeof level !== "number") continue
    const gap = Math.abs(level - elevation)
    if (gap <= 0.5 && gap < bestGap) {
      best = record
      bestGap = gap
    }
  }
  return best
}

function onWall(record: ComponentRecord, point: { x: number; y: number; z: number }, elevation: number): boolean {
  const z0 = record.bind?.z0_m
  const z1 = record.bind?.z1_m
  if (typeof z0 === "number" && typeof z1 === "number") {
    const lo = Math.min(z0, z1) - 0.2
    const hi = Math.max(z0, z1) + 0.2
    if (elevation < lo || elevation > hi) return false
  }
  const plane = record.bind?.plane
  const origin = plane?.origin
  const normal = plane?.normal
  if (!origin || !normal || origin.length < 3 || normal.length < 3) return false
  // Structural (x, y, z-up) to viewer (x, z, y).
  const ox = origin[0], oy = origin[2], oz = origin[1]
  const nx = normal[0], ny = normal[2], nz = normal[1]
  const nl = Math.hypot(nx, ny, nz)
  if (!(nl > 1e-8)) return false
  const dist = ((point.x - ox) * nx + (point.y - oy) * ny + (point.z - oz) * nz) / nl
  return Math.abs(dist) <= 0.25
}

export function renderDetail(
  record: ComponentRecord | null,
  fallbackTitle: string,
  fallbackFacts: string,
  mode: OverlayMode = "diagram",
  scene: OverlayScene | null = null,
  onMode: (mode: OverlayMode) => void = () => {},
) {
  const title = document.querySelector("#detail-title") as HTMLElement
  const governing = document.querySelector("#detail-governing") as HTMLElement
  const facts = document.querySelector("#detail-facts") as HTMLElement
  const drawing = document.querySelector("#detail-drawing") as HTMLElement
  const checks = document.querySelector("#detail-checks") as HTMLElement
  const path = document.querySelector("#detail-path") as HTMLElement
  title.textContent = record?.title ?? fallbackTitle
  facts.textContent = fallbackFacts
  governing.textContent = record ? governingLine(record) : ""
  drawing.replaceChildren()
  checks.replaceChildren()
  path.replaceChildren()
  if (!record) {
    drawing.append(note("This scene has no component record yet. The next solve writes the drawing, the checks, and the path."))
    return
  }
  const shown = mode === "tributary" && record.kind !== "slab" ? "diagram" : mode
  drawing.append(overlayButtons(record, shown, onMode))
  if (shown === "diagram" || !scene) drawing.append(drawRecord(record))
  else {
    drawing.append(overlayPicture(record, shown, scene))
    drawing.append(factList(drawingFacts(record.kind, record.drawing ?? {})))
  }
  checks.append(checkTable(record.checks ?? []))
  if (record.method) path.append(methodBlock(record.method), pathList(record.path ?? []))
  else path.append(pathList(record.path ?? []))
}

function overlayButtons(record: ComponentRecord, mode: OverlayMode, onMode: (mode: OverlayMode) => void): HTMLElement {
  const row = document.createElement("div")
  row.className = "overlay-row"
  const modes: [OverlayMode, string][] = [
    ["diagram", "Diagram"],
    ["deflection", "Deflection"],
    ["stress", "Stress"],
    ["axial", "Axial loads"],
  ]
  if (record.kind === "slab") modes.push(["tributary", "Tributary areas"])
  for (const [name, label] of modes) {
    const button = document.createElement("button")
    button.type = "button"
    button.textContent = label
    button.classList.toggle("on", name === mode)
    button.addEventListener("click", () => onMode(name))
    row.append(button)
  }
  return row
}

/** A stored deflection of 0 / 0 is the unset default, not a check that ran. */
function deflectionUnchecked(row: CheckRow | undefined): boolean {
  if (!row || row.name !== "deflection") return false
  const empty = (value: number | null | undefined) => value == null || value === 0
  return empty(row.ratio) && empty(row.demand) && empty(row.capacity)
}

function governingLine(record: ComponentRecord): string {
  const g = record.governing
  if (!g?.check) return ""
  const deflection = (record.checks ?? []).find((row) => row.name === "deflection")
  if (g.check === "deflection" && deflectionUnchecked(deflection)) return "Deflection was not checked"
  const ratio = typeof g.ratio === "number" ? ` · ${g.ratio.toFixed(2)}` : ""
  const state = g.ok === true ? "passes" : g.ok === false ? "fails" : ""
  const clause = g.clause ? ` · ${g.clause}` : ""
  return `${label(g.check)}${ratio}${state ? ` · ${state}` : ""}${clause}`
}

function drawRecord(record: ComponentRecord): HTMLElement {
  const wrap = document.createElement("div")
  wrap.className = "drawings"
  const drawing = record.drawing ?? {}
  const detail = recordObject(drawing.detail)
  const placed = detail !== null && Array.isArray(detail.groups) && detail.groups.length > 0
  const outline = Array.isArray(drawing.outline_m) ? drawing.outline_m as number[][] : null
  const cage = placed && detail !== null
    ? cageViews(detail.groups as BarGroupRecord[], Array.isArray(detail.solid_m) ? detail.solid_m as number[] : null,
                record.kind === "beam" ? outline : null)
    : []
  const wallPlanReady = placed && detail !== null && record.kind === "wall" && detailDots(detail).length > 0
  const rebar = Array.isArray(drawing.rebar_m) ? drawing.rebar_m as number[][] : null
  let sectionLetter = ""
  if (cage.length === 0 && (record.kind === "column" || record.kind === "beam")) {
    const section = outline ? sectionDrawing(outline, rebar, drawing.transverse, text(drawing.section)) : null
    const length = record.kind === "column" ? num(drawing.height_m) : num(drawing.length_m)
    if (section) {
      if (placed) sectionLetter = "A"
      wrap.append(figure(crossSection(section, sectionLetter)))
      wrap.append(figure(longitudinalSection(section, length)))
    } else {
      const across = num(drawing.c1_m) ?? num(drawing.width_m)
      const depth = num(drawing.c2_m) ?? num(drawing.depth_m)
      if (across && depth) wrap.append(figure(rectangleSheet(across, depth, text(drawing.section) || "Section", false)))
      if (length && depth) wrap.append(figure(rectangleSheet(length, depth, "Longitudinal section", false)))
    }
    if (record.kind === "beam") {
      const studs = recordObject(drawing.studs)
      const studSheet = studs ? studElevation(length ?? 0, studs) : null
      if (studSheet) wrap.append(figure(studSheet))
    }
  } else if (cage.length === 0 && record.kind === "footing") {
    const length = num(drawing.length_m)
    const width = num(drawing.width_m)
    const depth = num(drawing.depth_m)
    if (placed) sectionLetter = "A"
    if (length && width) wrap.append(figure(rectangleSheet(length, width, "Plan", true, true, sectionLetter)))
    if (!placed && length && depth) wrap.append(figure(rectangleSheet(length, depth, "Section", true)))
  }
  if (record.kind === "slab") {
    const span = num(drawing.span_primary_m)
    const thickness = num(drawing.thickness_m)
    const deck = recordObject(drawing.deck)
    // A placed bar cage already draws its own plan. The bay plan is for the
    // floors that have a section and no bars: deck, one-way, and two-way.
    if (cage.length === 0) {
      const direction = deck && Array.isArray(deck.direction) ? deck.direction as unknown[] : null
      const pitch = deck ? num(deck.pitch_m) : null
      const ribs = direction && direction.length >= 2 && pitch
        ? { pitch, direction: [Number(direction[0]), Number(direction[1])] as [number, number] }
        : null
      const plan = slabPlan(planRings(record.bind?.plan_m), span, num(drawing.span_secondary_m), text(drawing.floor_type), ribs)
      if (plan) wrap.append(figure(plan))
    }
    const ribs = recordObject(drawing.ribs)
    // Ribs run along the primary axis, so the troughs repeat across the secondary span.
    const deckSpan = num(drawing.span_secondary_m) ?? num(drawing.span_primary_m)
    const deckSheet = deck ? deckSection(deck, deckSpan) : null
    if (deckSheet) wrap.append(figure(deckSheet))
    const drop = num(drawing.h_drop_m)
    const dropWidth = num(drawing.a_drop1_m)
    const dropSheet = thickness && drop && dropWidth && span ? dropSection(span, thickness, drop, dropWidth) : null
    if (dropSheet) wrap.append(figure(dropSheet))
    let ribDrawn = false
    if (ribs?.uniform === false) {
      wrap.append(note("Ribs on this slab do not share one section."))
    } else if (ribs && thickness) {
      const flange = num(ribs.flange_m)
      if (flange !== null && Math.abs(flange - thickness) > 0.001) {
        wrap.append(note("The slab thickness and the rib flange differ, so no combined section is drawn."))
      } else {
        const ribSheet = ribSection(thickness, num(ribs.stem_m) ?? 0, num(ribs.bw_m) ?? 0, num(ribs.spacing_m))
        if (ribSheet) {
          wrap.append(figure(ribSheet))
          ribDrawn = true
        }
      }
    }
    if (drawing.solid_head === true && span && thickness) {
      wrap.append(figure(rectangleSheet(span, thickness, "Solid slab", true)))
    } else if (!deckSheet && !dropSheet && !ribDrawn && cage.length === 0 && span && thickness) {
      wrap.append(figure(rectangleSheet(span, thickness, "Section", true)))
    }
  } else if (cage.length === 0 && record.kind === "wall") {
    const length = num(drawing.length_m)
    const height = num(drawing.height_m)
    const thickness = num(drawing.thickness_m)
    if (!placed && length && height) wrap.append(figure(rectangleSheet(length, height, "Elevation", false)))
    if (wallPlanReady) sectionLetter = "A"
    if (!wallPlanReady && thickness && height) wrap.append(figure(rectangleSheet(thickness, height, "Section", true)))
  }
  for (const svg of cage) wrap.append(figure(svg))
  if (detail && cage.length === 0) wrap.append(...barSheets(record.kind, drawing, detail, sectionLetter))
  wrap.append(factList(drawingFacts(record.kind, drawing)))
  if (record.kind === "slab") {
    wrap.append(stripTable("Column strip", drawing.column_strip))
    wrap.append(stripTable("Middle strip", drawing.middle_strip))
  }
  if (detail) wrap.append(barSchedule(detail))
  return wrap
}

/** Placed-bar elevations from `drawing.detail`. A slab shows the middle frame line of each direction. */
function barSheets(
  kind: string, drawing: Record<string, unknown>, detail: Record<string, unknown>, sectionLetter: string,
): HTMLElement[] {
  if (typeof detail.error === "string") return [note(`Bar placement failed: ${detail.error}`)]
  const groups = Array.isArray(detail.groups) ? detail.groups as BarGroupRecord[] : []
  if (groups.length === 0) return []
  const out: HTMLElement[] = []
  const add = (svg: SVGSVGElement | null) => { if (svg) out.push(figure(svg)) }
  const reach = (gs: BarGroupRecord[]) => Math.max(0, ...gs.flatMap((g) => (g.path_m ?? []).map((p) => Number(p[0]))))
  const recorded = detailOutline(detail)
  if (kind === "beam") {
    const depth = sectionDepth(drawing)
    const along = reach(groups)
    const outline = recorded ?? (depth && along ? [{ x0: 0, x1: along + 0.04, z0: 0, z1: depth }] : null)
    if (outline) add(barElevation(groups, { outline }, "Bar elevation", false, sectionLetter ? crossMark(sectionLetter) : undefined))
  } else if (kind === "column") {
    const height = num(drawing.height_m)
    const width = sectionWidth(drawing)
    const outline = recorded ?? (height && width ? [{ x0: 0, x1: height, z0: -width / 2, z1: width / 2 }] : null)
    if (outline) add(barElevation(groups, { outline }, "Bar elevation", true, sectionLetter ? crossMark(sectionLetter) : undefined))
  } else if (kind === "footing") {
    const a = num(drawing.length_m), b = num(drawing.width_m), depth = num(drawing.depth_m)
    if (a && b && depth) {
      const long = Math.max(a, b), short = Math.min(a, b)
      const shown = groups.filter((g) => g.direction !== "short")
      const outline = recorded ?? [{ x0: 0, x1: long, z0: 0, z1: depth }]
      const title = sectionLetter ? `Section ${sectionLetter} · along the long side` : "Section along the long side"
      add(barElevation(shown, { outline, dots: shortBarDots(groups, long, short) }, title))
    }
  } else if (kind === "slab") {
    const thickness = num(drawing.thickness_m)
    if (thickness) {
      for (const [dir, word] of [["primary", "Primary"], ["secondary", "Secondary"]] as const) {
        const line = middleLine(groups.filter((g) => g.direction === dir))
        if (line.length === 0) continue
        const along = reach(line)
        add(barElevation(line, { outline: [{ x0: 0, x1: along + 0.02, z0: 0, z1: thickness }] },
          `${word} frame line ${line[0].mark.split("-")[0]}`))
      }
    }
  } else if (kind === "wall") {
    const dots = detailDots(detail)
    const voids = detailVoids(detail)
    if (recorded) {
      add(barElevation(groups, { outline: recorded, voids }, "Bar elevation", false,
        sectionLetter ? planMark(sectionLetter) : undefined))
    }
    const length = num(drawing.length_m), thickness = num(drawing.thickness_m)
    const atCut = recorded ? dotsAtPlanCut(dots, voids, recorded[0]) : dots
    if (length && thickness && atCut.length) {
      add(wallPlan(atCut, length, thickness, sectionLetter ? `Section ${sectionLetter}` : "Plan"))
    }
  }
  return out
}

/** Stored plan rings, each a list of `[x, y]` in structural plan. */
function planRings(value: unknown): number[][][] {
  if (!Array.isArray(value)) return []
  const rings: number[][][] = []
  for (const ring of value) {
    if (!Array.isArray(ring)) continue
    const pts: number[][] = []
    for (const point of ring) {
      if (Array.isArray(point) && typeof point[0] === "number" && typeof point[1] === "number") {
        pts.push([point[0], point[1]])
      }
    }
    if (pts.length >= 3) rings.push(pts)
  }
  return rings
}

/** Cut through the member, seen looking back toward its start. The section view is titled to match. */
function crossMark(letter: string): SectionMark {
  return { letter, kind: "cross" }
}

/** Horizontal cut, seen looking down. The plan is titled to match. */
function planMark(letter: string): SectionMark {
  return { letter, kind: "plan" }
}

/** `detail.outline_m` as rectangles, member first; null when the solve did not record one. */
function detailOutline(detail: Record<string, unknown>): ElevationFrame["outline"] | null {
  if (!Array.isArray(detail.outline_m)) return null
  const rects = (detail.outline_m as unknown[])
    .filter((r): r is number[] => Array.isArray(r) && r.length >= 4 && r.every((v) => Number.isFinite(Number(v))))
    .map((r) => ({ x0: Number(r[0]), x1: Number(r[1]), z0: Number(r[2]), z1: Number(r[3]) }))
  return rects.length ? rects : null
}

/** Opening rectangles in the wall elevation. */
function detailVoids(detail: Record<string, unknown>): NonNullable<ElevationFrame["voids"]> {
  if (!Array.isArray(detail.voids_m)) return []
  return (detail.voids_m as unknown[])
    .filter((r): r is number[] => Array.isArray(r) && r.length >= 4 && r.every((v) => Number.isFinite(Number(v))))
    .map((r) => ({ x0: Number(r[0]), x1: Number(r[1]), z0: Number(r[2]), z1: Number(r[3]) }))
}

/**
 * Vertical dots the plan cut actually crosses. A station inside an opening is omitted
 * when the cut height falls in that opening: the bar there stops at the head or the sill.
 */
function dotsAtPlanCut(
  dots: number[][],
  voids: NonNullable<ElevationFrame["voids"]>,
  body: { z0: number; z1: number },
): number[][] {
  const z = (Math.min(body.z0, body.z1) + Math.max(body.z0, body.z1)) / 2
  return dots.filter(([x]) => !voids.some((v) => {
    const x0 = Math.min(v.x0, v.x1), x1 = Math.max(v.x0, v.x1)
    const z0 = Math.min(v.z0, v.z1), z1 = Math.max(v.z0, v.z1)
    return x > x0 + 1e-4 && x < x1 - 1e-4 && z > z0 + 1e-4 && z < z1 - 1e-4
  }))
}

/** Vertical bar dots in a wall plan: `[x, y, diameter]`. */
function detailDots(detail: Record<string, unknown>): number[][] {
  if (!Array.isArray(detail.section_dots_m)) return []
  return (detail.section_dots_m as unknown[])
    .filter((p): p is number[] => Array.isArray(p) && p.length >= 3 && p.every((v) => Number.isFinite(Number(v))))
    .map((p) => [Number(p[0]), Number(p[1]), Number(p[2])])
}

/** Groups of the middle frame line, by the `P3-` style mark prefix. */
function middleLine(groups: BarGroupRecord[]): BarGroupRecord[] {
  const prefixes = [...new Set(groups.map((g) => g.mark.split("-")[0]))]
  if (prefixes.length === 0) return []
  prefixes.sort((a, b) => Number(a.slice(1)) - Number(b.slice(1)))
  const pick = prefixes[Math.floor((prefixes.length - 1) / 2)]
  return groups.filter((g) => g.mark.split("-")[0] === pick)
}

/**
 * Short-direction footing bars cut by a section along the long side. A square footing has them
 * uniform. A rectangular one has the central band (`note` names it) over a width equal to the
 * short side, and the rest split evenly outside it.
 */
function shortBarDots(groups: BarGroupRecord[], long: number, short: number): number[][] {
  const dots: number[][] = []
  const shortGroups = groups.filter((g) => g.direction === "short")
  const cover = Math.min(...groups.flatMap((g) => (g.path_m ?? []).map((p) => Number(p[0]))).filter((x) => x >= 0), long / 4)
  const spread = (n: number, x0: number, x1: number, z: number, d: number) => {
    if (n <= 0) return
    for (let i = 0; i < n; i++) dots.push([n === 1 ? (x0 + x1) / 2 : x0 + (x1 - x0) * i / (n - 1), z, d])
  }
  for (const g of shortGroups) {
    const z = Number(g.path_m?.[0]?.[1])
    if (!Number.isFinite(z)) continue
    const band = g.note.includes("central band")
    const outside = g.note.includes("outside")
    if (outside) {
      const half = Math.ceil(g.count / 2)
      spread(half, cover, (long - short) / 2, z, g.diameter_m)
      spread(g.count - half, (long + short) / 2, long - cover, z, g.diameter_m)
    } else if (band && long > short + 1e-6) {
      spread(g.count, (long - short) / 2, (long + short) / 2, z, g.diameter_m)
    } else {
      spread(g.count, cover, long - cover, z, g.diameter_m)
    }
  }
  return dots
}

function sectionDepth(drawing: Record<string, unknown>): number | null {
  const outline = Array.isArray(drawing.outline_m) ? drawing.outline_m as number[][] : []
  const zs = outline.map((p) => Number(p[1])).filter(Number.isFinite)
  return zs.length ? Math.max(...zs) - Math.min(...zs) : null
}

function sectionWidth(drawing: Record<string, unknown>): number | null {
  const outline = Array.isArray(drawing.outline_m) ? drawing.outline_m as number[][] : []
  const ys = outline.map((p) => Number(p[0])).filter(Number.isFinite)
  return ys.length ? Math.max(...ys) - Math.min(...ys) : num(drawing.c1_m)
}

/** Bar schedule, mass, and the detailing warnings and notes. */
function barSchedule(detail: Record<string, unknown>): HTMLElement {
  const wrap = document.createElement("div")
  const groups = Array.isArray(detail.groups) ? detail.groups as BarGroupRecord[] : []
  if (groups.length === 0) return wrap
  const heading = document.createElement("h4")
  const mass = num(detail.mass_kg)
  heading.textContent = mass === null ? "Bar schedule" : `Bar schedule · ${mass.toFixed(0)} kg`
  const table = document.createElement("table")
  table.innerHTML = "<thead><tr><th>Mark</th><th>Bar</th><th>No.</th><th>Shape</th><th>Length</th><th>Laps</th><th>Mass</th></tr></thead>"
  const body = document.createElement("tbody")
  for (const g of groups) {
    const tr = document.createElement("tr")
    tr.title = [label(g.role), g.note].filter(Boolean).join(" · ")
    for (const cell of [
      g.mark, `#${g.bar_size}`, String(g.count), label(g.shape),
      meters(g.length_m) || "—", g.laps ? String(g.laps) : "", num(g.mass_kg) === null ? "—" : `${g.mass_kg.toFixed(1)} kg`,
    ]) {
      const td = document.createElement("td")
      td.textContent = cell
      tr.append(td)
    }
    body.append(tr)
  }
  table.append(body)
  wrap.append(heading, table)
  const areas = areaFacts(detail)
  if (areas) wrap.append(areas)
  const warnings = Array.isArray(detail.warnings) ? detail.warnings.map(String) : []
  const notes = Array.isArray(detail.notes) ? detail.notes.map(String) : []
  if (warnings.length) wrap.append(textList("Detailing warnings", warnings, "warnings"))
  if (notes.length) wrap.append(textList("Detailing notes", notes, "muted"))
  return wrap
}

const AREA_WORD: Record<string, string> = {
  vertical: "Vertical steel",
  horizontal: "Horizontal steel",
  bottom: "Bottom steel",
  top: "Top steel",
  stirrup: "Stirrups",
  longitudinal: "Longitudinal steel",
  long: "Long bars",
  short: "Short bars",
  dowel: "Dowels",
  primary: "Primary",
  secondary: "Secondary",
  column: "column strip",
  middle: "middle strip",
  extneg: "exterior negative",
  pos: "positive",
  intneg: "interior negative",
}

function areaLabel(key: string): string {
  return key.split("_").map((word) => AREA_WORD[word] ?? word).join(" ")
}

/** Ideal area and placed area for every pair the detail recorded. */
function areaFacts(detail: Record<string, unknown>): HTMLElement | null {
  const areas = detail.areas_in2
  if (!areas || typeof areas !== "object") return null
  const a = areas as Record<string, unknown>
  const rows: [string, string][] = []
  const names = Object.keys(a)
    .filter((key) => key.endsWith("_ideal_in2"))
    .map((key) => key.slice(0, -"_ideal_in2".length))
    .sort()
  for (const name of names) {
    const placed = num(a[`${name}_placed_in2`])
    const ideal = num(a[`${name}_ideal_in2`])
    if (placed === null || ideal === null) continue
    rows.push([
      areaLabel(name),
      `${placed.toFixed(2)} in² placed, ${ideal.toFixed(2)} in² from the design`,
    ])
  }
  return rows.length ? factList(rows) : null
}

function textList(title: string, items: string[], className: string): HTMLElement {
  const wrap = document.createElement("div")
  const heading = document.createElement("h4")
  heading.textContent = title
  const list = document.createElement("ul")
  list.className = className
  for (const item of items) {
    const li = document.createElement("li")
    li.textContent = item
    list.append(li)
  }
  wrap.append(heading, list)
  return wrap
}

function figure(svg: SVGSVGElement): HTMLElement {
  const fig = document.createElement("figure")
  if (svg.dataset.caption) {
    const cap = document.createElement("figcaption")
    cap.textContent = svg.dataset.caption
    fig.append(cap)
  }
  fig.append(svg)
  return fig
}

function factList(rows: [string, string][]): HTMLElement {
  const list = document.createElement("dl")
  list.className = "facts"
  for (const [key, value] of rows) {
    const dt = document.createElement("dt")
    dt.textContent = key
    const dd = document.createElement("dd")
    dd.textContent = value
    list.append(dt, dd)
  }
  return list
}

function drawingFacts(kind: string, drawing: Record<string, unknown>): [string, string][] {
  const rows: [string, string][] = []
  const add = (key: string, value: string) => { if (value) rows.push([key, value]) }
  add("Section", text(drawing.section))
  add("Shape", text(drawing.shape))
  add("Height", meters(drawing.height_m))
  add("Gross area", area(drawing.Ag_m2))
  add("Steel area", area(drawing.As_m2))
  add("ρg", fixed(drawing.rho_g, 4))
  add("Length", meters(drawing.length_m))
  const studs = recordObject(drawing.studs)
  if (studs) {
    add("Studs", studs.count == null ? "" : String(studs.count))
    add("Stud diameter", meters(studs.diameter_m))
    add("Stud length", meters(studs.length_m))
    add("Shear", text(studs.note))
  }
  add("Depth", meters(drawing.depth_m))
  add("Thickness", meters(drawing.thickness_m))
  add("Floor", text(drawing.floor_type))
  add("Position", text(drawing.position))
  add("Spans", pair(num(drawing.span_primary_m), num(drawing.span_secondary_m)))
  add("Self weight", drawing.self_weight_kPa == null ? "" : `${Number(drawing.self_weight_kPa).toFixed(2)} kPa`)
  add("Drop", meters(drawing.h_drop_m))
  const deck = recordObject(drawing.deck)
  if (deck) {
    add("Deck", text(deck.profile))
    add("Pitch", meters(deck.pitch_m))
    add("Fill", meters(deck.fill_m))
  }
  const ribs = recordObject(drawing.ribs)
  if (ribs?.uniform === true) {
    add("Rib stem", meters(ribs.stem_m))
    add("Rib spacing", meters(ribs.spacing_m))
  }
  add("ρl", fixed(drawing.rho_l, 4))
  add("ρt", fixed(drawing.rho_t, 4))
  add("Type", label(text(drawing.foundation_type)))
  add("Analysis", text(drawing.analysis))
  add("Utilization", drawing.utilization == null ? "" : Number(drawing.utilization).toFixed(2))
  add("Columns", drawing.n_columns == null ? "" : String(drawing.n_columns))
  const walls = Array.isArray(drawing.walls) ? drawing.walls as Record<string, unknown>[] : []
  if (walls.length > 0) {
    const openings = walls.reduce((n, wall) => n + (Array.isArray(wall.openings) ? wall.openings.length : 0), 0)
    add("Walls", String(walls.length))
    if (openings > 0) add("Openings", String(openings))
  }
  add("Concrete", volume(drawing.concrete_m3))
  add("Steel", volume(drawing.steel_m3))
  if (kind === "footing" && drawing.note) add("Note", text(drawing.note))
  if (kind === "wall" && drawing.note) add("Note", text(drawing.note))
  const punching = drawing.punching
  if (punching && typeof punching === "object") {
    const p = punching as Record<string, unknown>
    add("Punching perimeter", meters(p.perimeter_m))
    add("Unbalanced moment", p.Mub_kNm == null ? "" : `${Number(p.Mub_kNm).toFixed(1)} kN·m`)
  }
  return rows
}

function stripTable(title: string, value: unknown): HTMLElement {
  const wrap = document.createElement("div")
  if (!value || typeof value !== "object") return wrap
  const entries = Object.entries(value as Record<string, unknown>)
  if (entries.length === 0) return wrap
  const heading = document.createElement("h4")
  heading.textContent = title
  const table = document.createElement("table")
  table.innerHTML = "<thead><tr><th>Location</th><th>Bar</th><th>Spacing</th><th>As prov / req</th><th>Mu</th></tr></thead>"
  const body = document.createElement("tbody")
  for (const [loc, raw] of entries) {
    if (!raw || typeof raw !== "object") continue
    const row = raw as Record<string, unknown>
    const tr = document.createElement("tr")
    const provided = num(row.As_provided_m2)
    const required = num(row.As_required_m2)
    const ratio = provided !== null && required !== null && required > 0 ? (provided / required).toFixed(2) : "—"
    for (const cell of [
      label(loc),
      text(row.bar_size) || "—",
      meters(row.spacing_m) || "—",
      ratio,
      row.Mu_kNm == null ? "—" : `${Number(row.Mu_kNm).toFixed(1)}`,
    ]) {
      const td = document.createElement("td")
      td.textContent = cell
      tr.append(td)
    }
    body.append(tr)
  }
  table.append(body)
  wrap.append(heading, table)
  return wrap
}

function checkTable(rows: CheckRow[]): HTMLElement {
  const wrap = document.createElement("div")
  if (rows.length === 0) {
    wrap.append(note("No checks were recorded for this component."))
    return wrap
  }
  const table = document.createElement("table")
  const body = document.createElement("tbody")
  for (const row of rows) {
    const tr = document.createElement("tr")
    if (row.governing) tr.className = "governing"
    const name = document.createElement("td")
    name.textContent = label(String(row.name ?? "check"))
    const clause = document.createElement("td")
    clause.textContent = text(row.clause)
    const numbers = document.createElement("td")
    if (deflectionUnchecked(row)) {
      numbers.textContent = "not checked"
    } else {
      const demand = row.demand == null ? "" : `${fmt(row.demand)} ${text(row.demand_unit)}`.trim()
      const capacity = row.capacity == null ? "" : `${fmt(row.capacity)} ${text(row.capacity_unit)}`.trim()
      const ratio = typeof row.ratio === "number" ? row.ratio.toFixed(2) : "—"
      numbers.textContent = [demand && capacity ? `${demand} / ${capacity}` : demand, ratio].filter(Boolean).join(" · ")
    }
    tr.append(name, clause, numbers)
    body.append(tr)
  }
  table.append(body)
  wrap.append(table)
  return wrap
}

function methodBlock(method: Record<string, unknown>): HTMLElement {
  const list = factList([
    ["Requested", text(method.requested)],
    ["Used", text(method.used)],
    ["Fallback", Array.isArray(method.fallback) && method.fallback.length ? method.fallback.map(String).join("; ") : ""],
    ["Iterations", method.iterations == null ? "" : String(method.iterations)],
    ["Converged", method.converged == null ? "" : method.converged ? "yes" : "no"],
    ["Failure", text(method.failure_reason)],
    ["Failing check", text(method.failing_check)],
    ["Pattern loading", method.pattern_loading ? "yes" : ""],
    ["Analysis", text(method.analysis_status)],
    ["M0", method.M0_kNm == null ? "" : `${Number(method.M0_kNm).toFixed(1)} kN·m`],
    ["qu", method.qu_kPa == null ? "" : `${Number(method.qu_kPa).toFixed(2)} kPa`],
  ].filter((row): row is [string, string] => row[1] !== ""))
  return list
}

function pathList(events: PathEvent[]): HTMLElement {
  const wrap = document.createElement("div")
  if (events.length === 0) {
    wrap.append(note("No trace events name this component. The full solve trace is in the scene header."))
    return wrap
  }
  const list = document.createElement("ol")
  list.className = "path"
  const shown = events.slice(0, 40)
  for (const event of shown) {
    const item = document.createElement("li")
    const head = document.createElement("strong")
    head.textContent = `${text(event.event) || "event"} · ${text(event.stage)}`
    item.append(head)
    const meta = document.createElement("div")
    meta.className = "muted"
    meta.textContent = [text(event.layer), text(event.element_id), typeof event.t_s === "number" ? `${event.t_s.toFixed(2)} s` : ""].filter(Boolean).join(" · ")
    item.append(meta)
    const data = event.data
    if (data && typeof data === "object") {
      const bits = Object.entries(data).slice(0, 8).map(([key, value]) => `${key}: ${brief(value)}`)
      if (bits.length) {
        const pre = document.createElement("div")
        pre.textContent = bits.join("\n")
        item.append(pre)
      }
    }
    list.append(item)
  }
  wrap.append(list)
  if (events.length > shown.length) wrap.append(note(`${events.length - shown.length} later events are in the scene trace.`))
  return wrap
}

function note(textValue: string): HTMLElement {
  const p = document.createElement("p")
  p.className = "pending"
  p.textContent = textValue
  return p
}

function label(value: string): string {
  return value.replaceAll("_", " ")
}

function text(value: unknown): string {
  return value == null || value === "" ? "" : String(value)
}

function recordObject(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" ? value as Record<string, unknown> : null
}

function num(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null
}

function meters(value: unknown): string {
  const n = num(value)
  return n === null ? "" : `${n.toFixed(3)} m`
}

function area(value: unknown): string {
  const n = num(value)
  return n === null ? "" : `${n.toExponential(3)} m²`
}

function volume(value: unknown): string {
  const n = num(value)
  return n === null ? "" : `${n.toFixed(3)} m³`
}

function fixed(value: unknown, digits: number): string {
  const n = num(value)
  return n === null ? "" : n.toFixed(digits)
}

function pair(a: number | null, b: number | null): string {
  if (a === null && b === null) return ""
  if (a === null || b === null) return `${(a ?? b)?.toFixed(3)} m`
  return `${a.toFixed(3)} × ${b.toFixed(3)} m`
}

function fmt(value: unknown): string {
  const n = num(value)
  if (n === null) return ""
  const abs = Math.abs(n)
  return abs >= 1000 || (abs > 0 && abs < 0.01) ? n.toExponential(2) : n.toFixed(2)
}

function brief(value: unknown): string {
  if (value == null) return "null"
  if (typeof value === "number") return fmt(value)
  if (typeof value === "string" || typeof value === "boolean") return String(value)
  if (Array.isArray(value)) return `${value.length} values`
  if (typeof value === "object") {
    const record = value as Record<string, unknown>
    if (record.truncated) return `${record.length} values`
    if ("value" in record && "unit" in record) return `${fmt(record.value)} ${text(record.unit)}`
    return Object.keys(record).slice(0, 4).join(", ")
  }
  return String(value)
}
