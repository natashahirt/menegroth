import * as THREE from "three"
import theme from "./theme.json"

/**
 * Flat arrows for supports and loads. The head sits on the point of
 * application and the shaft trails back along the force. Area and line loads
 * are a field: the same arrow, repeated, with the spacing following the zoom
 * so a close view reads as pressure and a far view stays quiet.
 */

const CELL_M = 2
const MIN_SPACING_M = 0.55
const MAX_SPACING_M = 8
const AREA_PX = 46
const HEAD_PX = 13
const LIFT_PX = 3.5
/** Surfaces closer than this are the same floor (a slab and its drop panel). Stories are several metres apart. */
const LEVEL_M = 0.4

export interface GlyphSet {
  group: THREE.Group
  update(camera: THREE.Camera, heightPx: number, target: THREE.Vector3): void
}

interface Rec {
  x: number
  y: number
  z: number
  dx: number
  dy: number
  dz: number
  length: number
}

interface FloorTri {
  ax: number
  ay: number
  az: number
  bx: number
  by: number
  bz: number
  cx: number
  cy: number
  cz: number
}

interface LineSpan {
  ax: number
  ay: number
  az: number
  bx: number
  by: number
  bz: number
  dx: number
  dy: number
  dz: number
  length: number
}

export function buildGlyphs(input: {
  position: Float32Array
  elementNodes: Uint32Array
  supportIndex: Uint32Array
  supportFixity: Uint8Array
  nodeForceIndex: Uint32Array
  nodeForce: Float32Array
  nodeMomentIndex: Uint32Array
  nodeMoment: Float32Array
  lineLoadElement: Uint32Array
  lineLoad: Float32Array
  pointLoadElement: Uint32Array
  pointLoadPosition: Float32Array
  pointLoad: Float32Array
  loadArrowAt: Float32Array
  loadArrowDir: Float32Array
  shellFaces: Uint32Array
  shellKinds: Uint8Array
  meanLength: number
}): GlyphSet {
  const reach = Math.max(input.meanLength * 0.32, 0.6)
  const supportLen = Math.max(input.meanLength * 0.42, 0.7)
  const supports = supportArrows(input.position, input.supportIndex, input.supportFixity, supportLen)
  const forces = scaledArrows(nodeArrows(input.position, input.nodeForceIndex, input.nodeForce), reach)
  const moments = scaledArrows(nodeArrows(input.position, input.nodeMomentIndex, input.nodeMoment), reach * 0.65)
  const points = scaledArrows(pointArrows(
    input.position, input.elementNodes, input.pointLoadElement, input.pointLoadPosition, input.pointLoad,
  ), reach)
  const lines = lineSpans(input.position, input.elementNodes, input.lineLoadElement, input.lineLoad, reach)
  const areaDir = meanDirection(input.loadArrowDir)
  const floors = areaDir ? floorIndex(input.position, input.shellFaces, input.shellKinds) : new Map<number, FloorTri[]>()
  const areaLength = reach

  const supportMesh = arrowMesh(theme.cerulean)
  const loadMesh = arrowMesh(theme.magenta)
  const momentMesh = arrowMesh(theme.gold)
  const group = new THREE.Group()
  group.name = "glyphs"
  group.add(supportMesh, loadMesh, momentMesh)

  let builtSpacing = -1
  let area: Rec[] = []
  let distributed: Rec[] = []
  let lastKey = ""

  return {
    group,
    update(camera, heightPx, target) {
      const px = worldPerPixel(camera, heightPx, target)
      const spacing = Math.min(MAX_SPACING_M, Math.max(MIN_SPACING_M, px * AREA_PX))
      const key = cameraKey(camera)
      if (Math.abs(spacing - builtSpacing) / Math.max(builtSpacing, 1e-6) > 0.12 || builtSpacing < 0) {
        builtSpacing = spacing
        distributed = sampleLines(lines, spacing)
        area = areaDir ? sampleArea(floors, areaDir, areaLength, spacing) : []
        lastKey = ""
      }
      if (key === lastKey) return
      lastKey = key
      const lift = px * LIFT_PX
      const head = px * HEAD_PX
      paint(supportMesh, supports, camera, lift, head)
      paint(loadMesh, forces.concat(points, distributed, area), camera, lift, head)
      paint(momentMesh, moments, camera, lift, head)
    },
  }
}

function supportArrows(
  position: Float32Array, index: Uint32Array, fixity: Uint8Array, length: number,
): Rec[] {
  const out: Rec[] = []
  for (let i = 0; i < index.length; i++) {
    // Bits 0–2 are the translations. A fixed rotation with every translation
    // free is an unused degree of freedom, not a support.
    if (((fixity[i] ?? 0) & 0x07) === 0) continue
    const n = index[i] * 3
    out.push({ x: position[n], y: position[n + 1], z: position[n + 2], dx: 0, dy: 1, dz: 0, length })
  }
  return out
}

function nodeArrows(position: Float32Array, index: Uint32Array, value: Float32Array): Rec[] {
  const out: Rec[] = []
  for (let i = 0; i < index.length; i++) {
    const n = index[i] * 3
    const dx = value[i * 3]
    const dy = value[i * 3 + 1]
    const dz = value[i * 3 + 2]
    const mag = Math.hypot(dx, dy, dz)
    if (mag < 1e-9) continue
    out.push({
      x: position[n], y: position[n + 1], z: position[n + 2],
      dx: dx / mag, dy: dy / mag, dz: dz / mag,
      length: mag,
    })
  }
  return out
}

function pointArrows(
  position: Float32Array,
  pairs: Uint32Array,
  elements: Uint32Array,
  fraction: Float32Array,
  value: Float32Array,
): Rec[] {
  const out: Rec[] = []
  for (let i = 0; i < elements.length; i++) {
    const e = elements[i]
    if (e * 2 + 1 >= pairs.length) continue
    const t = fraction[i]
    const a = pairs[e * 2] * 3
    const b = pairs[e * 2 + 1] * 3
    const dx = value[i * 3]
    const dy = value[i * 3 + 1]
    const dz = value[i * 3 + 2]
    const mag = Math.hypot(dx, dy, dz)
    if (mag < 1e-9) continue
    out.push({
      x: position[a] + (position[b] - position[a]) * t,
      y: position[a + 1] + (position[b + 1] - position[a + 1]) * t,
      z: position[a + 2] + (position[b + 2] - position[a + 2]) * t,
      dx: dx / mag, dy: dy / mag, dz: dz / mag,
      length: mag,
    })
  }
  return out
}

function scaledArrows(raw: Rec[], reach: number): Rec[] {
  let maxMag = 0
  for (const arrow of raw) maxMag = Math.max(maxMag, arrow.length)
  if (maxMag < 1e-9) return []
  return raw.map((arrow) => ({ ...arrow, length: reach * (arrow.length / maxMag) }))
}

function lineSpans(
  position: Float32Array,
  pairs: Uint32Array,
  elements: Uint32Array,
  value: Float32Array,
  reach: number,
): LineSpan[] {
  const raw: LineSpan[] = []
  let maxMag = 0
  for (let i = 0; i < elements.length; i++) {
    const e = elements[i]
    if (e * 2 + 1 >= pairs.length) continue
    const a = pairs[e * 2] * 3
    const b = pairs[e * 2 + 1] * 3
    const dx = value[i * 3]
    const dy = value[i * 3 + 1]
    const dz = value[i * 3 + 2]
    const mag = Math.hypot(dx, dy, dz)
    if (mag < 1e-9) continue
    maxMag = Math.max(maxMag, mag)
    raw.push({
      ax: position[a], ay: position[a + 1], az: position[a + 2],
      bx: position[b], by: position[b + 1], bz: position[b + 2],
      dx: dx / mag, dy: dy / mag, dz: dz / mag,
      length: mag,
    })
  }
  if (maxMag < 1e-9) return []
  for (const span of raw) span.length = reach * (span.length / maxMag)
  return raw
}

function sampleLines(spans: LineSpan[], spacing: number): Rec[] {
  const out: Rec[] = []
  for (const span of spans) {
    const len = Math.hypot(span.bx - span.ax, span.by - span.ay, span.bz - span.az)
    const n = Math.max(1, Math.round(len / spacing))
    for (let i = 0; i < n; i++) {
      const t = (i + 0.5) / n
      out.push({
        x: span.ax + (span.bx - span.ax) * t,
        y: span.ay + (span.by - span.ay) * t,
        z: span.az + (span.bz - span.az) * t,
        dx: span.dx, dy: span.dy, dz: span.dz,
        length: span.length,
      })
    }
  }
  return out
}

function meanDirection(dir: Float32Array): [number, number, number] | null {
  let x = 0
  let y = 0
  let z = 0
  for (let i = 0; i < dir.length; i += 3) {
    x += dir[i]
    y += dir[i + 1]
    z += dir[i + 2]
  }
  const mag = Math.hypot(x, y, z)
  if (mag < 1e-9) return null
  return [x / mag, y / mag, z / mag]
}

function floorIndex(position: Float32Array, faces: Uint32Array, kinds: Uint8Array): Map<number, FloorTri[]> {
  const cells = new Map<number, FloorTri[]>()
  const triCount = Math.min(kinds.length, Math.floor(faces.length / 3))
  for (let t = 0; t < triCount; t++) {
    if (kinds[t] !== 0 && kinds[t] !== 2) continue
    const a = faces[t * 3] * 3
    const b = faces[t * 3 + 1] * 3
    const c = faces[t * 3 + 2] * 3
    const tri: FloorTri = {
      ax: position[a], ay: position[a + 1], az: position[a + 2],
      bx: position[b], by: position[b + 1], bz: position[b + 2],
      cx: position[c], cy: position[c + 1], cz: position[c + 2],
    }
    // Plan area. A vertical wall projects to a line and is not part of the field.
    const plan = (tri.bx - tri.ax) * (tri.cz - tri.az) - (tri.bz - tri.az) * (tri.cx - tri.ax)
    if (Math.abs(plan) < 1e-4) continue
    const minX = Math.min(tri.ax, tri.bx, tri.cx)
    const maxX = Math.max(tri.ax, tri.bx, tri.cx)
    const minZ = Math.min(tri.az, tri.bz, tri.cz)
    const maxZ = Math.max(tri.az, tri.bz, tri.cz)
    const i0 = Math.floor(minX / CELL_M)
    const i1 = Math.floor(maxX / CELL_M)
    const k0 = Math.floor(minZ / CELL_M)
    const k1 = Math.floor(maxZ / CELL_M)
    for (let ix = i0; ix <= i1; ix++) {
      for (let iz = k0; iz <= k1; iz++) {
        const key = ix * 100003 + iz
        const list = cells.get(key)
        if (list) list.push(tri)
        else cells.set(key, [tri])
      }
    }
  }
  return cells
}

function sampleArea(cells: Map<number, FloorTri[]>, dir: [number, number, number], length: number, spacing: number): Rec[] {
  let minX = Infinity
  let maxX = -Infinity
  let minZ = Infinity
  let maxZ = -Infinity
  for (const list of cells.values()) {
    for (const tri of list) {
      minX = Math.min(minX, tri.ax, tri.bx, tri.cx)
      maxX = Math.max(maxX, tri.ax, tri.bx, tri.cx)
      minZ = Math.min(minZ, tri.az, tri.bz, tri.cz)
      maxZ = Math.max(maxZ, tri.az, tri.bz, tri.cz)
    }
  }
  if (!Number.isFinite(minX)) return []
  const out: Rec[] = []
  const x0 = Math.floor(minX / spacing) * spacing
  const z0 = Math.floor(minZ / spacing) * spacing
  let row = 0
  for (let x = x0; x <= maxX + spacing * 0.01; x += spacing) {
    const zShift = row % 2 === 0 ? 0 : spacing * 0.5
    row++
    for (let z = z0 + zShift; z <= maxZ + spacing * 0.01; z += spacing) {
      for (const y of floorsAt(cells, x, z)) {
        out.push({ x, y, z, dx: dir[0], dy: dir[1], dz: dir[2], length })
      }
    }
  }
  return out
}

/** Every loaded floor under this plan point. A slab and its drop panel share one arrow, on the higher surface. */
function floorsAt(cells: Map<number, FloorTri[]>, x: number, z: number): number[] {
  const list = cells.get(Math.floor(x / CELL_M) * 100003 + Math.floor(z / CELL_M))
  if (!list) return []
  const levels: number[] = []
  for (const tri of list) {
    const y = baryY(tri, x, z)
    if (y === null) continue
    let merged = false
    for (let i = 0; i < levels.length; i++) {
      if (Math.abs(levels[i] - y) < LEVEL_M) {
        levels[i] = Math.max(levels[i], y)
        merged = true
        break
      }
    }
    if (!merged) levels.push(y)
  }
  return levels
}

function baryY(tri: FloorTri, x: number, z: number): number | null {
  const den = (tri.bz - tri.cz) * (tri.ax - tri.cx) + (tri.cx - tri.bx) * (tri.az - tri.cz)
  if (Math.abs(den) < 1e-8) return null
  const u = ((tri.bz - tri.cz) * (x - tri.cx) + (tri.cx - tri.bx) * (z - tri.cz)) / den
  const v = ((tri.cz - tri.az) * (x - tri.cx) + (tri.ax - tri.cx) * (z - tri.cz)) / den
  const w = 1 - u - v
  if (u < -1e-3 || v < -1e-3 || w < -1e-3) return null
  return u * tri.ay + v * tri.by + w * tri.cy
}

function arrowMesh(color: string): THREE.Mesh {
  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute("position", new THREE.BufferAttribute(new Float32Array(9), 3))
  const material = new THREE.MeshBasicMaterial({
    color,
    side: THREE.DoubleSide,
    depthWrite: false,
    toneMapped: false,
  })
  const mesh = new THREE.Mesh(geometry, material)
  mesh.frustumCulled = false
  mesh.renderOrder = 4
  mesh.raycast = () => {}
  mesh.visible = false
  return mesh
}

function paint(mesh: THREE.Mesh, arrows: Rec[], camera: THREE.Camera, lift: number, head: number) {
  const positions: number[] = []
  const cam = camera.position
  for (const arrow of arrows) {
    writeArrow(positions, arrow, cam.x, cam.y, cam.z, lift, head)
  }
  const geometry = mesh.geometry
  geometry.setAttribute("position", new THREE.BufferAttribute(new Float32Array(positions), 3))
  geometry.computeBoundingSphere()
  mesh.visible = positions.length >= 9
}

const basisX = new THREE.Vector3()
const basisY = new THREE.Vector3()
const basisZ = new THREE.Vector3()
const basis = new THREE.Matrix4()

function writeArrow(out: number[], arrow: Rec, camX: number, camY: number, camZ: number, lift: number, head: number) {
  const shaft = Math.max(arrow.length, head * 1.35)
  const headLen = Math.min(head, shaft * 0.42)
  const headW = headLen * 0.72
  const shaftW = headW * 0.22
  orient(arrow.x, arrow.y, arrow.z, arrow.dx, arrow.dy, arrow.dz, camX, camY, camZ, lift)
  const y1 = -headLen
  const y2 = -shaft
  tri(out, 0, 0, -headW * 0.5, y1, headW * 0.5, y1)
  tri(out, -shaftW * 0.5, y1, -shaftW * 0.5, y2, shaftW * 0.5, y2)
  tri(out, -shaftW * 0.5, y1, shaftW * 0.5, y2, shaftW * 0.5, y1)
}

function orient(ax: number, ay: number, az: number, dx: number, dy: number, dz: number, camX: number, camY: number, camZ: number, lift: number) {
  basisY.set(dx, dy, dz)
  if (basisY.lengthSq() < 1e-12) basisY.set(0, 1, 0)
  basisY.normalize()
  basisZ.set(camX - ax, camY - ay, camZ - az)
  basisZ.addScaledVector(basisY, -basisZ.dot(basisY))
  if (basisZ.lengthSq() < 1e-8) basisZ.set(0, 0, 1).addScaledVector(basisY, -basisY.z)
  if (basisZ.lengthSq() < 1e-8) basisZ.set(1, 0, 0)
  basisZ.normalize()
  basisX.crossVectors(basisY, basisZ).normalize()
  basis.makeBasis(basisX, basisY, basisZ)
  basis.setPosition(ax + basisZ.x * lift, ay + basisZ.y * lift, az + basisZ.z * lift)
}

function tri(out: number[], x0: number, y0: number, x1: number, y1: number, x2: number, y2: number) {
  put(out, x0, y0)
  put(out, x1, y1)
  put(out, x2, y2)
}

function put(out: number[], x: number, y: number) {
  const e = basis.elements
  out.push(
    e[0] * x + e[4] * y + e[12],
    e[1] * x + e[5] * y + e[13],
    e[2] * x + e[6] * y + e[14],
  )
}

function worldPerPixel(camera: THREE.Camera, heightPx: number, target: THREE.Vector3): number {
  const height = Math.max(heightPx, 1)
  const ortho = camera as THREE.OrthographicCamera
  if (ortho.isOrthographicCamera) return Math.abs(ortho.top - ortho.bottom) / height
  const persp = camera as THREE.PerspectiveCamera
  const dist = Math.max(persp.position.distanceTo(target), 0.1)
  return 2 * Math.tan(THREE.MathUtils.degToRad(persp.fov) * 0.5) * dist / height
}

function cameraKey(camera: THREE.Camera): string {
  const p = camera.position
  const q = camera.quaternion
  return [p.x, p.y, p.z, q.x, q.y, q.z, q.w].map((v) => v.toFixed(3)).join(",")
}
