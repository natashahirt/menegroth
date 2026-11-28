import * as THREE from "three"
import theme from "./theme.json"

/** One composite deck floor. Lengths are meters. `direction` is the rib run in viewer XZ. */
export interface DeckFloor {
  elevation: number
  direction: [number, number]
  hr: number
  ribTop: number
  ribBottom: number
  pitch: number
  fill: number
  sheet: number | null
}

interface Piece {
  x: number
  z: number
  s: number
  py: number
}

/**
 * Concrete flute and steel sheet for deck slabs, centered on the shell nodes.
 * The design stores no rib offset, so one flute is centered on the slab.
 * Triangles in `skip` are the ones this mesh replaces.
 */
export function buildDeckSolids(
  position: Float32Array,
  faces: Uint32Array,
  kinds: Uint8Array,
  floors: DeckFloor[],
): { group: THREE.Group, skip: Set<number> } | null {
  const ready = floors.filter((floor) => (
    floor.pitch > 1e-4 && floor.hr > 0 && floor.fill >= 0 &&
    floor.ribBottom > 0 && floor.ribTop + 1e-9 >= floor.ribBottom &&
    floor.pitch > floor.ribTop &&
    Math.hypot(floor.direction[0], floor.direction[1]) > 1e-8
  ))
  if (ready.length === 0) return null
  const concrete: number[] = []
  const concreteIndex: number[] = []
  const concreteSource: number[] = []
  const concreteVertex: number[] = []
  const steel: number[] = []
  const steelIndex: number[] = []
  const steelSource: number[] = []
  const steelVertex: number[] = []
  const skip = new Set<number>()
  const owned: { floor: DeckFloor, triangle: number, tri: Piece[] }[] = []
  for (let t = 0; t < kinds.length; t++) {
    if ((kinds[t] ?? 0) === 1 || (kinds[t] ?? 0) === 2) continue
    const ids = [faces[t * 3], faces[t * 3 + 1], faces[t * 3 + 2]]
    const tri = ids.map((id) => read(position, id))
    const y = (tri[0].py + tri[1].py + tri[2].py) / 3
    const owners = ready.filter((floor) => tri.every((p) => Math.abs(p.py - floor.elevation) <= 0.5) && Math.abs(y - floor.elevation) <= 0.5)
    if (owners.length > 1) throw new Error("two deck profiles share one slab elevation")
    if (owners.length === 0) continue
    skip.add(t)
    owned.push({ floor: owners[0], triangle: t, tri })
  }
  for (const floor of ready) {
    const mine = owned.filter((item) => item.floor === floor)
    if (mine.length === 0) continue
    const len = Math.hypot(floor.direction[0], floor.direction[1])
    const px = -floor.direction[1] / len
    const pz = floor.direction[0] / len
    let smin = Infinity
    let smax = -Infinity
    for (const item of mine) {
      for (const p of item.tri) {
        const s = p.x * px + p.z * pz
        if (s < smin) smin = s
        if (s > smax) smax = s
      }
    }
    const mid = (smin + smax) / 2
    for (const item of mine) {
      extrude(floor, item.tri, item.triangle, mid, px, pz, concrete, concreteIndex, concreteSource, concreteVertex, false)
      if ((floor.sheet ?? 0) > 0) {
        extrude(floor, item.tri, item.triangle, mid, px, pz, steel, steelIndex, steelSource, steelVertex, true)
      }
    }
  }
  if (concreteIndex.length === 0) return null
  const group = new THREE.Group()
  group.name = "deck"
  group.add(mesh(concrete, concreteIndex, concreteSource, concreteVertex, faces, kinds, theme.slab, "deck-concrete"))
  if (steelIndex.length > 0) {
    group.add(mesh(steel, steelIndex, steelSource, steelVertex, faces, kinds, theme.charcoal, "deck-sheet"))
  }
  return { group, skip }
}

function read(position: Float32Array, id: number): Piece {
  return { x: position[id * 3] ?? 0, z: position[id * 3 + 2] ?? 0, s: 0, py: position[id * 3 + 1] ?? 0 }
}

function extrude(
  floor: DeckFloor,
  tri: Piece[],
  triangle: number,
  mid: number,
  px: number,
  pz: number,
  verts: number[],
  index: number[],
  source: number[],
  vertexSource: number[],
  sheet: boolean,
) {
  const placed = tri.map((p) => ({ ...p, s: p.x * px + p.z * pz }))
  let smin = Infinity
  let smax = -Infinity
  for (const p of placed) {
    if (p.s < smin) smin = p.s
    if (p.s > smax) smax = p.s
  }
  const cuts = new Set<number>()
  const k0 = Math.floor((smin - mid) / floor.pitch) - 1
  const k1 = Math.ceil((smax - mid) / floor.pitch) + 1
  for (let k = k0; k <= k1; k++) {
    const c = mid + k * floor.pitch
    for (const at of [0, -floor.pitch / 2, floor.pitch / 2, -floor.ribBottom / 2, floor.ribBottom / 2, -floor.ribTop / 2, floor.ribTop / 2]) {
      cuts.add(c + at)
    }
  }
  let pieces: Piece[][] = [placed]
  for (const cut of [...cuts].sort((a, b) => a - b)) {
    const next: Piece[][] = []
    for (const piece of pieces) next.push(...split(piece, cut))
    pieces = next
  }
  const total = floor.hr + floor.fill
  const gage = floor.sheet ?? 0
  for (const piece of pieces) {
    if (piece.length < 3) continue
    const base = verts.length / 3
    const n = piece.length
    for (const p of piece) {
      const concreteBottom = p.py + bottomAt(p.s, mid, floor)
      const low = sheet ? concreteBottom - gage : concreteBottom
      verts.push(p.x, low, p.z)
      vertexSource.push(triangle)
    }
    for (const p of piece) {
      const concreteBottom = p.py + bottomAt(p.s, mid, floor)
      const high = sheet ? concreteBottom : p.py + total / 2
      verts.push(p.x, high, p.z)
      vertexSource.push(triangle)
    }
    for (let i = 1; i < n - 1; i++) {
      index.push(base, base + i, base + i + 1)
      index.push(base + n, base + n + i + 1, base + n + i)
      source.push(triangle, triangle)
    }
    for (let i = 0; i < n; i++) {
      const j = (i + 1) % n
      index.push(base + i, base + j, base + n + j, base + i, base + n + j, base + n + i)
      source.push(triangle, triangle)
    }
  }
}

function bottomAt(s: number, mid: number, floor: DeckFloor): number {
  const total = floor.hr + floor.fill
  let local = (s - mid) % floor.pitch
  if (local < 0) local += floor.pitch
  if (local > floor.pitch / 2) local -= floor.pitch
  const a = Math.abs(local)
  const halfBottom = floor.ribBottom / 2
  const halfTop = floor.ribTop / 2
  if (a <= halfBottom) return -total / 2
  if (a >= halfTop) return total / 2 - floor.fill
  const f = (a - halfBottom) / (halfTop - halfBottom)
  return -total / 2 + f * floor.hr
}

function split(poly: Piece[], limit: number): Piece[][] {
  const below = clip(poly, limit, true)
  const above = clip(poly, limit, false)
  return [below, above].filter((piece) => piece.length >= 3)
}

function clip(poly: Piece[], limit: number, keepBelow: boolean): Piece[] {
  const out: Piece[] = []
  for (let i = 0; i < poly.length; i++) {
    const a = poly[i]
    const b = poly[(i + 1) % poly.length]
    const aIn = keepBelow ? a.s <= limit + 1e-8 : a.s >= limit - 1e-8
    const bIn = keepBelow ? b.s <= limit + 1e-8 : b.s >= limit - 1e-8
    if (aIn && bIn) out.push(b)
    else if (aIn !== bIn && Math.abs(b.s - a.s) > 1e-12) {
      const t = (limit - a.s) / (b.s - a.s)
      const hit = {
        x: a.x + (b.x - a.x) * t,
        z: a.z + (b.z - a.z) * t,
        s: limit,
        py: a.py + (b.py - a.py) * t,
      }
      out.push(hit)
      if (bIn) out.push(b)
    }
  }
  return out
}

function mesh(
  verts: number[],
  index: number[],
  source: number[],
  vertexSource: number[],
  faces: Uint32Array,
  kinds: Uint8Array,
  color: string,
  role: string,
): THREE.Mesh {
  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute("position", new THREE.BufferAttribute(new Float32Array(verts), 3))
  geometry.setIndex(index)
  geometry.computeVertexNormals()
  const keep = new Float32Array(verts.length / 3)
  keep.fill(1)
  geometry.setAttribute("aKeep", new THREE.BufferAttribute(keep, 1))
  const material = new THREE.MeshLambertMaterial({ color, side: THREE.DoubleSide })
  material.onBeforeCompile = (shader: { vertexShader: string; fragmentShader: string }) => {
    shader.vertexShader = shader.vertexShader
      .replace("#include <common>", "#include <common>\nattribute float aKeep;\nvarying float vKeep;")
      .replace("#include <begin_vertex>", "vec3 transformed = vec3(position);\nvKeep = aKeep;")
    shader.fragmentShader = shader.fragmentShader
      .replace("#include <common>", "#include <common>\nvarying float vKeep;")
      .replace("#include <dithering_fragment>", "gl_FragColor.rgb = mix(vec3(0.78431, 0.78431, 0.76863), gl_FragColor.rgb, clamp(vKeep, 0.0, 1.0));\n#include <dithering_fragment>")
  }
  const body = new THREE.Mesh(geometry, material)
  body.userData = { role: "shell-volume", source: new Uint32Array(source), vertexSource: new Uint32Array(vertexSource), faces, kinds, deckRole: role }
  return body
}
