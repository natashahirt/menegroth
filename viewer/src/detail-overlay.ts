/** Colored pictures for one component, from the scene buffers. No value is invented. */

import * as THREE from "three"
import { deflectionColor, signedColor, stressColor } from "./building"
import { displacementAt } from "./frame"
import type { ComponentRecord } from "./detail"

export type OverlayMode = "diagram" | "deflection" | "stress" | "axial" | "tributary"

export interface OverlayScene {
  nodePosition: Float32Array
  nodeDisplacement: Float32Array
  displacementPresent: boolean
  maxDisplacement: number
  shellFaces: Uint32Array
  shellKinds: Uint8Array
  shellStress: Float32Array
  stressPresent: boolean
  maxStress: number
  shellAxial: Float32Array
  shellAxialPresent: boolean
  elementNodes: Uint32Array
  elementAxial: Float32Array
  axialPresent: boolean
  maxAxial: number
  localDof: Float32Array
  lcs: Float32Array
  loadElement: Uint32Array
  particular: Float32Array
  stations: number
  tributaryPosition: Float32Array
  tributaryCount: Uint32Array
  tributaryKind: Uint8Array
  tributaryElement: Uint32Array
  tributaryCell: Uint32Array
  tributaryPresent: boolean
  footingDisp: Float32Array
}

const SVG = "http://www.w3.org/2000/svg"
const ink = new THREE.Color()

interface Poly { pts: [number, number][]; color: string; stroke?: string }

/** The picture that replaces the line drawing. A sentence when the field is absent or does not belong here. */
export function overlayPicture(record: ComponentRecord, mode: OverlayMode, scene: OverlayScene): HTMLElement {
  if (mode === "deflection") return deflectionPicture(record, scene)
  if (mode === "stress") return stressPicture(record, scene)
  if (mode === "axial") return axialPicture(record, scene)
  return tributaryPicture(record, scene)
}

function deflectionPicture(record: ComponentRecord, scene: OverlayScene): HTMLElement {
  if (!scene.displacementPresent) return sentence("Deflection is not in this scene.")
  const scale = Math.max(scene.maxDisplacement, 0)
  if (record.kind === "slab" || record.kind === "wall") {
    const samples = shellSamples(record, scene, (_t, ids) => {
      let mag = 0
      for (const id of ids) mag += nodeMag(scene, id)
      return mag / Math.max(ids.length, 1)
    })
    if (samples.length === 0) return sentence(record.kind === "wall" ? "This wall has no shell in the scene." : "This slab has no shell in the scene.")
    const peak = samples.reduce((m, sample) => Math.max(m, sample.value), 0)
    const polys = samples.map((sample) => ({ pts: sample.pts, color: ramp(sample.value, peak) }))
    return sheet(record.kind === "wall" ? "Elevation" : "Plan", polys, "0", `${(peak * 1000).toFixed(1)} mm`, "Deflection of this surface", "ramp")
  }
  if (record.kind === "column" || record.kind === "beam") {
    const bar = memberBar(record, scene, (element, t, length, rows) => ramp(memberMag(scene, element, t, length, rows), scale))
    if (!bar) return sentence("This member is not in the analysis model.")
    return sheet("Along the member", bar, "0", `${(scale * 1000).toFixed(1)} mm`, "Deflection magnitude", "ramp")
  }
  if (record.kind === "footing") return footingFill(record, scene, scale)
  return sentence("Deflection is not recorded for this component.")
}

function stressPicture(record: ComponentRecord, scene: OverlayScene): HTMLElement {
  if (record.kind !== "slab" && record.kind !== "wall") return sentence("Surface stress is recorded on slabs and walls.")
  if (!scene.stressPresent) return sentence("Stress is not in this scene.")
  const samples = shellSamples(record, scene, (t) => scene.shellStress[t] ?? Number.NaN)
  const drawn = samples.filter((sample) => Number.isFinite(sample.value))
  if (drawn.length === 0) return sentence(record.kind === "wall" ? "This wall has no shell in the scene." : "This slab has no shell in the scene.")
  const peak = drawn.reduce((m, sample) => Math.max(m, Math.abs(sample.value)), 0)
  const polys = drawn.map((sample) => ({ pts: sample.pts, color: stressHex(sample.value, peak) }))
  const end = `${(peak / 1e6).toFixed(2)} MPa`
  return sheet(record.kind === "wall" ? "Elevation" : "Plan", polys, `−${end}`, `+${end}`, "Compression is magenta. Tension is blue. Scale is this surface.", "stress")
}

function axialPicture(record: ComponentRecord, scene: OverlayScene): HTMLElement {
  if (record.kind === "wall") return wallAxialPicture(record, scene)
  if (record.kind !== "column" && record.kind !== "beam") return sentence("Axial load is recorded on columns, beams, and walls.")
  if (!scene.axialPresent) return sentence("Axial loads are not in this scene.")
  const elements = frameElements(record, scene)
  if (elements.length === 0) return sentence("This member is not in the analysis model.")
  const polys: Poly[] = []
  let x = 0
  for (const element of elements) {
    const length = elementLength(scene, element)
    const value = scene.elementAxial[element]
    if (value === undefined || !(length > 0)) continue
    const y = length * 0.18
    polys.push({ pts: [[x, 0], [x + length, 0], [x + length, -y], [x, -y]], color: signed(value, scene.maxAxial) })
    x += length
  }
  if (polys.length === 0) return sentence("Axial load is not recorded for this member.")
  const end = `${(scene.maxAxial / 1000).toFixed(1)} kN`
  return sheet("Along the member", polys, `−${end}`, `+${end}`, "Axial force · tension positive", "ramp")
}

function tributaryPicture(record: ComponentRecord, scene: OverlayScene): HTMLElement {
  if (record.kind !== "slab") return sentence("Tributary areas are shown on slabs.")
  if (!scene.tributaryPresent) return sentence("Tributary areas are not in this scene.")
  const elevation = record.bind?.elevation_m
  if (typeof elevation !== "number") return sentence("This slab has no elevation, so its tributary area cannot be placed.")
  const polys: Poly[] = []
  let cursor = 0
  for (let loop = 0; loop < scene.tributaryCount.length; loop++) {
    const count = scene.tributaryCount[loop] ?? 0
    const pts: [number, number][] = []
    let y = 0
    for (let k = 0; k < count; k++) {
      const i = (cursor + k) * 3
      const px = scene.tributaryPosition[i]
      const py = scene.tributaryPosition[i + 1]
      const pz = scene.tributaryPosition[i + 2]
      if (px === undefined || py === undefined || pz === undefined) continue
      y += py
      pts.push([px, -pz])
    }
    cursor += count
    if (pts.length < 3) continue
    const cells = record.bind?.cell_indices
    if (Array.isArray(cells) && cells.length > 0 && scene.tributaryCell.length === scene.tributaryCount.length) {
      if (!cells.includes(scene.tributaryCell[loop] ?? -1)) continue
    } else if (Math.abs(y / pts.length - elevation) > 0.5) {
      continue
    }
    polys.push({ pts, color: tributaryKindColor(scene.tributaryKind[loop]), stroke: "#ffffff" })
  }
  if (polys.length === 0) return sentence("No tributary area was recorded on this slab.")
  return sheet("Plan", polys, "", "", "Column areas are cerulean. Wall areas are iris. Beam areas are gold.", "none")
}

function footingFill(record: ComponentRecord, scene: OverlayScene, scale: number): HTMLElement {
  const index = record.bind?.footing
  if (typeof index !== "number" || index * 3 + 2 >= scene.footingDisp.length) {
    return sentence("This footing is not tied to a support in the scene.")
  }
  const length = num(record.drawing?.length_m)
  const width = num(record.drawing?.width_m)
  if (length === null || width === null) return sentence("The footing size is not in this scene.")
  const mag = Math.hypot(scene.footingDisp[index * 3] ?? 0, scene.footingDisp[index * 3 + 1] ?? 0, scene.footingDisp[index * 3 + 2] ?? 0)
  const polys = [{ pts: [[0, 0], [length, 0], [length, -width], [0, -width]] as [number, number][], color: ramp(mag, scale) }]
  return sheet("Plan", polys, "0", `${(scale * 1000).toFixed(1)} mm`, "Deflection magnitude", "ramp")
}

function wallAxialPicture(record: ComponentRecord, scene: OverlayScene): HTMLElement {
  if (!scene.shellAxialPresent) return sentence("Vertical force is not in this scene.")
  const samples = shellSamples(record, scene, (t) => scene.shellAxial[t] ?? Number.NaN)
  const drawn = samples.filter((sample) => Number.isFinite(sample.value))
  if (drawn.length === 0) return sentence("This wall has no shell in the scene.")
  const peak = drawn.reduce((m, sample) => Math.max(m, Math.abs(sample.value)), 0)
  const polys = drawn.map((sample) => ({ pts: sample.pts, color: signed(sample.value, peak) }))
  const end = `${(peak / 1000).toFixed(1)} kN/m`
  return sheet("Elevation", polys, `−${end}`, `+${end}`, "Vertical force · tension positive", "ramp")
}

interface Sample { pts: [number, number][]; value: number }

function shellSamples(record: ComponentRecord, scene: OverlayScene, valueOf: (triangle: number, ids: number[]) => number): Sample[] {
  const wall = record.kind === "wall"
  const kinds = record.bind?.shell_kinds ?? (wall ? [1] : [0, 2])
  const frame = wall ? wallFrame(record, scene) : null
  const elevation = record.bind?.elevation_m
  const samples: Sample[] = []
  const triangles = scene.shellFaces.length / 3
  for (let t = 0; t < triangles; t++) {
    if (!kinds.includes(scene.shellKinds[t] ?? 0)) continue
    const ids = [scene.shellFaces[t * 3], scene.shellFaces[t * 3 + 1], scene.shellFaces[t * 3 + 2]]
    if (ids.some((id) => id === undefined || id * 3 + 2 >= scene.nodePosition.length)) continue
    if (!wall) {
      if (typeof elevation !== "number") continue
      if (!ids.every((id) => Math.abs((scene.nodePosition[id * 3 + 1] ?? 0) - elevation) <= 0.5)) continue
    } else if (frame && !frame.keeps(ids)) {
      continue
    }
    const value = valueOf(t, ids)
    if (!Number.isFinite(value)) continue
    const pts = wall && frame
      ? ids.map((id) => frame.point(id))
      : ids.map((id) => [scene.nodePosition[id * 3] ?? 0, -(scene.nodePosition[id * 3 + 2] ?? 0)] as [number, number])
    samples.push({ pts, value })
  }
  return samples
}

function wallFrame(record: ComponentRecord, scene: OverlayScene) {
  const z0 = record.bind?.z0_m
  const z1 = record.bind?.z1_m
  // A centroid pad of one mesh row lets the next story's lower triangle in and
  // leaves its partner out, so the elevation boundary becomes a sawtooth.
  // Every vertex has to sit in this story. The pad is roundoff only.
  const lo = typeof z0 === "number" && typeof z1 === "number" ? Math.min(z0, z1) - 0.02 : -Infinity
  const hi = typeof z0 === "number" && typeof z1 === "number" ? Math.max(z0, z1) + 0.02 : Infinity
  const drawing = record.drawing ?? {}
  const x1 = num(drawing.x1_m)
  const y1 = num(drawing.y1_m)
  const x2 = num(drawing.x2_m)
  const y2 = num(drawing.y2_m)
  const hasLine = x1 !== null && y1 !== null && x2 !== null && y2 !== null
  const dx = hasLine ? x2 - x1 : 1
  const dy = hasLine ? y2 - y1 : 0
  const len = Math.hypot(dx, dy) || 1
  const ux = dx / len
  const uy = dy / len
  return {
    keeps(ids: number[]): boolean {
      let cx = 0
      let cz = 0
      for (const id of ids) {
        cx += scene.nodePosition[id * 3] ?? 0
        cz += scene.nodePosition[id * 3 + 2] ?? 0
      }
      cx /= ids.length
      cz /= ids.length
      for (const id of ids) {
        const y = scene.nodePosition[id * 3 + 1] ?? 0
        if (y < lo || y > hi) return false
      }
      if (!hasLine || x1 === null || y1 === null) return true
      return segmentDistance(cx, cz, x1, y1, x2 as number, y2 as number) <= 0.5
    },
    point(id: number): [number, number] {
      const x = scene.nodePosition[id * 3] ?? 0
      const y = scene.nodePosition[id * 3 + 1] ?? 0
      const z = scene.nodePosition[id * 3 + 2] ?? 0
      const s = hasLine && x1 !== null && y1 !== null ? (x - x1) * ux + (z - y1) * uy : x
      return [s, -y]
    },
  }
}

function memberBar(
  record: ComponentRecord,
  scene: OverlayScene,
  colorAt: (element: number, t: number, length: number, rows: Int32Array) => string,
): Poly[] | null {
  const elements = frameElements(record, scene)
  if (elements.length === 0) return null
  const rows = loadRows(scene)
  const polys: Poly[] = []
  let x = 0
  for (const element of elements) {
    const length = elementLength(scene, element)
    if (!(length > 0)) continue
    const steps = 24
    const y = length * 0.18
    for (let s = 0; s < steps; s++) {
      const t0 = s / steps
      const t1 = (s + 1) / steps
      polys.push({
        pts: [[x + t0 * length, 0], [x + t1 * length, 0], [x + t1 * length, -y], [x + t0 * length, -y]],
        color: colorAt(element, (t0 + t1) / 2, length, rows),
      })
    }
    x += length
  }
  return polys.length ? polys : null
}

function frameElements(record: ComponentRecord, scene: OverlayScene): number[] {
  const listed = record.bind?.frame_elements ?? []
  const n = scene.elementNodes.length / 2
  const kept = listed.filter((element) => element >= 0 && element < n)
  kept.sort((a, b) => nodeLow(scene, a) - nodeLow(scene, b))
  return kept
}

function memberMag(scene: OverlayScene, element: number, t: number, length: number, rows: Int32Array): number {
  if (scene.localDof.length >= (element + 1) * 12 && scene.lcs.length >= (element + 1) * 9) {
    return displacementAt(scene.localDof, scene.lcs, element, t, length, rows, scene.particular, scene.stations).length()
  }
  const a = scene.elementNodes[element * 2]
  const b = scene.elementNodes[element * 2 + 1]
  return nodeMag(scene, a) * (1 - t) + nodeMag(scene, b) * t
}

function elementLength(scene: OverlayScene, element: number): number {
  const a = scene.elementNodes[element * 2] ?? 0
  const b = scene.elementNodes[element * 2 + 1] ?? 0
  return Math.hypot(
    (scene.nodePosition[b * 3] ?? 0) - (scene.nodePosition[a * 3] ?? 0),
    (scene.nodePosition[b * 3 + 1] ?? 0) - (scene.nodePosition[a * 3 + 1] ?? 0),
    (scene.nodePosition[b * 3 + 2] ?? 0) - (scene.nodePosition[a * 3 + 2] ?? 0),
  )
}

function nodeLow(scene: OverlayScene, element: number): number {
  const a = scene.nodePosition[(scene.elementNodes[element * 2] ?? 0) * 3 + 1] ?? 0
  const b = scene.nodePosition[(scene.elementNodes[element * 2 + 1] ?? 0) * 3 + 1] ?? 0
  return Math.min(a, b)
}

function nodeMag(scene: OverlayScene, id: number): number {
  return Math.hypot(scene.nodeDisplacement[id * 3] ?? 0, scene.nodeDisplacement[id * 3 + 1] ?? 0, scene.nodeDisplacement[id * 3 + 2] ?? 0)
}

function loadRows(scene: OverlayScene): Int32Array {
  const n = scene.elementNodes.length / 2
  const rows = new Int32Array(n)
  rows.fill(-1)
  for (let i = 0; i < scene.loadElement.length; i++) {
    const element = scene.loadElement[i]
    if (element !== undefined && element < n) rows[element] = i
  }
  return rows
}

function ramp(value: number, scale: number): string {
  const t = scale > 0 ? value / scale : 0
  return `#${deflectionColor(t, ink).getHexString()}`
}

function signed(value: number, scale: number): string {
  return `#${signedColor(value, scale, ink).getHexString()}`
}

function stressHex(value: number, scale: number): string {
  return `#${stressColor(value, scale, ink).getHexString()}`
}

function tributaryKindColor(kind: number | undefined): string {
  if (kind === 1) return "#df7e00"
  if (kind === 2) return "#4c2563"
  return "#00aeef"
}

function sheet(caption: string, polys: Poly[], min: string, max: string, note: string, scaleKind: "ramp" | "stress" | "none"): HTMLElement {
  let minX = Infinity
  let minY = Infinity
  let maxX = -Infinity
  let maxY = -Infinity
  for (const poly of polys) {
    for (const [x, y] of poly.pts) {
      minX = Math.min(minX, x)
      maxX = Math.max(maxX, x)
      minY = Math.min(minY, y)
      maxY = Math.max(maxY, y)
    }
  }
  const span = Math.max(maxX - minX, maxY - minY, 0.05)
  const pad = span * 0.08
  const svg = document.createElementNS(SVG, "svg")
  svg.setAttribute("class", "sheet")
  svg.setAttribute("viewBox", `${minX - pad} ${minY - pad} ${maxX - minX + 2 * pad} ${maxY - minY + 2 * pad}`)
  for (const poly of polys) {
    const polygon: Record<string, string> = {
      points: poly.pts.map(([x, y]) => `${x},${y}`).join(" "),
      fill: poly.color,
      stroke: poly.stroke ?? "none",
    }
    if (poly.stroke) {
      polygon["stroke-width"] = "1.25"
      polygon["stroke-linejoin"] = "round"
      polygon["vector-effect"] = "non-scaling-stroke"
    }
    svg.append(el("polygon", polygon))
  }
  const fig = document.createElement("figure")
  const cap = document.createElement("figcaption")
  cap.textContent = caption
  fig.append(cap, svg)
  if (scaleKind !== "none") {
    const scale = document.createElement("div")
    scale.className = scaleKind === "stress" ? "scale stress" : "scale"
    const bar = document.createElement("div")
    bar.className = "bar"
    const ends = document.createElement("div")
    ends.className = "ends"
    const left = document.createElement("span")
    left.textContent = min
    const right = document.createElement("span")
    right.textContent = max
    ends.append(left, right)
    const captionNote = document.createElement("p")
    captionNote.textContent = note
    scale.append(bar, ends, captionNote)
    fig.append(scale)
  } else {
    const captionNote = document.createElement("p")
    captionNote.className = "muted"
    captionNote.textContent = note
    fig.append(captionNote)
  }
  return fig
}

function sentence(text: string): HTMLElement {
  const p = document.createElement("p")
  p.className = "pending"
  p.textContent = text
  return p
}

function segmentDistance(px: number, py: number, x1: number, y1: number, x2: number, y2: number): number {
  const dx = x2 - x1
  const dy = y2 - y1
  const len2 = dx * dx + dy * dy
  if (len2 < 1e-12) return Math.hypot(px - x1, py - y1)
  const t = Math.max(0, Math.min(1, ((px - x1) * dx + (py - y1) * dy) / len2))
  return Math.hypot(px - (x1 + t * dx), py - (y1 + t * dy))
}

function num(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null
}

function el(name: string, attrs: Record<string, string>): SVGElement {
  const node = document.createElementNS(SVG, name)
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value)
  return node
}
