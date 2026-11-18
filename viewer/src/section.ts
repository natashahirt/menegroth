import * as THREE from "three"

/**
 * Solid black fill where a cut plane passes through a solid.
 *
 * The fill is the intersection of the plane with each closed piece (a column,
 * a footing, or one slab/wall prism). A stencil over the whole mesh leaves a
 * mark on every edge it does not cancel, including pieces the plane misses.
 */

const EPS = 1e-4
const WELD = 1e4
/** Sit just off the plane so the fill wins the depth test. */
const BIAS_M = 0.0015
/** `shell_kind` value for a wall. Slabs stay out of the analysis fill. */
const WALL_KIND = 1

interface Range {
  start: number
  count: number
  sourceId: number
  minX: number
  minY: number
  minZ: number
  maxX: number
  maxY: number
  maxZ: number
}

interface Prepared {
  mesh: THREE.Mesh
  xyz: Float32Array
  ranges: Range[]
  instanced: boolean
}

export class SectionHatch {
  readonly group = new THREE.Group()
  private readonly capX: THREE.Mesh
  private readonly capZ: THREE.Mesh
  private prepared: Prepared[] = []
  private boxLocal: Float32Array | null = null
  private bakedX: number[] | null = null
  private bakedZ: number[] | null = null
  private bakedXKey = ""
  private bakedZKey = ""
  private x = 0
  private z = 0
  private xOn = false
  private zOn = false

  constructor(private readonly clipX: THREE.Plane, private readonly clipZ: THREE.Plane) {
    this.group.name = "section-hatch"
    this.capX = this.makeCap(clipZ)
    this.capZ = this.makeCap(clipX)
    this.group.add(this.capX, this.capZ)
  }

  /**
   * Solids that can be cut. A hidden mesh draws no fill, except a shell volume
   * marked `sectionWhenHidden`: analysis hides that volume, and the cut still
   * fills the wall prisms from their stored thickness.
   */
  setSources(meshes: THREE.Mesh[]) {
    const same = meshes.length === this.prepared.length && meshes.every((mesh, i) => mesh === this.prepared[i].mesh)
    if (!same) {
      this.prepared = meshes.map((mesh) => prepare(mesh))
      this.boxLocal = null
      this.bakedX = null
      this.bakedZ = null
    }
  }

  /**
   * Rebuild the fills on the cut planes. `z` is three.js Y, the structural height.
   * An idle plane draws nothing.
   */
  place(x: number, z: number, xOn: boolean, zOn: boolean, _box: THREE.Box3) {
    this.x = x
    this.z = z
    this.xOn = xOn
    this.zOn = zOn
    this.refill()
  }

  /** Footings move with the deflection scale. The columns and slabs stay put. */
  resync() {
    this.refill()
  }

  clear() {
    this.prepared = []
    this.boxLocal = null
    this.bakedX = null
    this.bakedZ = null
    this.xOn = false
    this.zOn = false
    this.upload(this.capX, [])
    this.upload(this.capZ, [])
  }

  private refill() {
    this.upload(this.capX, this.xOn ? this.triangles(this.clipX, "x") : [])
    this.upload(this.capZ, this.zOn ? this.triangles(this.clipZ, "z") : [])
  }

  private triangles(plane: THREE.Plane, which: "x" | "z"): number[] {
    const key = `${plane.constant.toFixed(5)}:${this.prepared.map((item) => (item.mesh.visible ? "1" : "0")).join("")}`
    const cached = which === "x" ? this.bakedX : this.bakedZ
    const cachedKey = which === "x" ? this.bakedXKey : this.bakedZKey
    let staticTris = cached
    if (staticTris === null || cachedKey !== key) {
      staticTris = []
      for (const item of this.prepared) {
        if (item.instanced) continue
        const wallsOnly = !item.mesh.visible && item.mesh.userData.sectionWhenHidden === true
        if (!item.mesh.visible && !wallsOnly) continue
        fillPrepared(item, plane, staticTris, wallsOnly)
      }
      if (which === "x") {
        this.bakedX = staticTris
        this.bakedXKey = key
      } else {
        this.bakedZ = staticTris
        this.bakedZKey = key
      }
    }
    const out = staticTris.slice()
    for (const item of this.prepared) {
      if (!item.mesh.visible || !item.instanced) continue
      this.fillFootings(item, plane, out)
    }
    return out
  }

  private fillFootings(item: Prepared, plane: THREE.Plane, out: number[]) {
    const mesh = item.mesh as THREE.InstancedMesh
    if (!this.boxLocal) this.boxLocal = deindex(mesh.geometry)
    const local = this.boxLocal
    const world = new Float32Array(local.length)
    const matrix = new THREE.Matrix4()
    const composed = new THREE.Matrix4()
    mesh.updateWorldMatrix(true, false)
    for (let i = 0; i < mesh.count; i++) {
      mesh.getMatrixAt(i, matrix)
      composed.multiplyMatrices(mesh.matrixWorld, matrix)
      const e = composed.elements
      let minX = Infinity, minY = Infinity, minZ = Infinity
      let maxX = -Infinity, maxY = -Infinity, maxZ = -Infinity
      for (let v = 0; v < local.length; v += 3) {
        const x = local[v], y = local[v + 1], z = local[v + 2]
        const wx = e[0] * x + e[4] * y + e[8] * z + e[12]
        const wy = e[1] * x + e[5] * y + e[9] * z + e[13]
        const wz = e[2] * x + e[6] * y + e[10] * z + e[14]
        world[v] = wx
        world[v + 1] = wy
        world[v + 2] = wz
        if (wx < minX) minX = wx
        if (wy < minY) minY = wy
        if (wz < minZ) minZ = wz
        if (wx > maxX) maxX = wx
        if (wy > maxY) maxY = wy
        if (wz > maxZ) maxZ = wz
      }
      if (boxMisses(minX, minY, minZ, maxX, maxY, maxZ, plane)) continue
      fillSolid(world, 0, world.length / 9, plane, out)
    }
  }

  private makeCap(other: THREE.Plane): THREE.Mesh {
    const geometry = new THREE.BufferGeometry()
    geometry.setAttribute("position", new THREE.BufferAttribute(new Float32Array(0), 3))
    const material = new THREE.MeshBasicMaterial({
      color: 0x000000,
      toneMapped: false,
      side: THREE.DoubleSide,
      depthWrite: false,
      polygonOffset: true,
      polygonOffsetFactor: -4,
      polygonOffsetUnits: -4,
      clippingPlanes: [other],
    })
    const mesh = new THREE.Mesh(geometry, material)
    mesh.frustumCulled = false
    mesh.raycast = () => {}
    mesh.renderOrder = 3
    mesh.visible = false
    mesh.userData.noclip = true
    return mesh
  }

  private upload(mesh: THREE.Mesh, positions: number[]) {
    const geometry = mesh.geometry
    geometry.setAttribute("position", new THREE.BufferAttribute(new Float32Array(positions), 3))
    geometry.computeBoundingSphere()
    mesh.visible = positions.length >= 9
  }
}

function prepare(mesh: THREE.Mesh): Prepared {
  const instanced = Boolean((mesh as THREE.InstancedMesh).isInstancedMesh)
  if (instanced) return { mesh, xyz: new Float32Array(0), ranges: [], instanced: true }
  mesh.updateWorldMatrix(true, false)
  const position = mesh.geometry.getAttribute("position")
  const index = mesh.geometry.getIndex()
  const triCount = index ? index.count / 3 : position.count / 3
  const source = mesh.userData.source as Uint32Array | undefined
  const groups = source && source.length === triCount ? source : null
  const chunks: number[][] = []
  const chunkSource: number[] = []
  const slotOf = new Map<number, number>()
  const e = mesh.matrixWorld.elements
  for (let t = 0; t < triCount; t++) {
    const id = groups ? groups[t] : 0
    let slot = slotOf.get(id)
    if (slot === undefined) {
      slot = chunks.length
      slotOf.set(id, slot)
      chunks.push([])
      chunkSource.push(id)
    }
    const chunk = chunks[slot]
    for (let k = 0; k < 3; k++) {
      const vi = index ? index.getX(t * 3 + k) : t * 3 + k
      const x = position.getX(vi)
      const y = position.getY(vi)
      const z = position.getZ(vi)
      chunk.push(
        e[0] * x + e[4] * y + e[8] * z + e[12],
        e[1] * x + e[5] * y + e[9] * z + e[13],
        e[2] * x + e[6] * y + e[10] * z + e[14],
      )
    }
  }
  let count = 0
  for (const chunk of chunks) count += chunk.length
  const xyz = new Float32Array(count)
  const ranges: Range[] = []
  let cursor = 0
  for (let c = 0; c < chunks.length; c++) {
    const chunk = chunks[c]
    const start = cursor / 9
    let minX = Infinity, minY = Infinity, minZ = Infinity
    let maxX = -Infinity, maxY = -Infinity, maxZ = -Infinity
    for (let i = 0; i < chunk.length; i += 3) {
      const x = chunk[i], y = chunk[i + 1], z = chunk[i + 2]
      xyz[cursor++] = x
      xyz[cursor++] = y
      xyz[cursor++] = z
      if (x < minX) minX = x
      if (y < minY) minY = y
      if (z < minZ) minZ = z
      if (x > maxX) maxX = x
      if (y > maxY) maxY = y
      if (z > maxZ) maxZ = z
    }
    ranges.push({
      start,
      count: chunk.length / 9,
      sourceId: chunkSource[c] ?? 0,
      minX, minY, minZ, maxX, maxY, maxZ,
    })
  }
  return { mesh, xyz, ranges, instanced: false }
}

function deindex(geometry: THREE.BufferGeometry): Float32Array {
  const position = geometry.getAttribute("position")
  const index = geometry.getIndex()
  const triCount = index ? index.count / 3 : position.count / 3
  const xyz = new Float32Array(triCount * 9)
  let cursor = 0
  for (let t = 0; t < triCount; t++) {
    for (let k = 0; k < 3; k++) {
      const vi = index ? index.getX(t * 3 + k) : t * 3 + k
      xyz[cursor++] = position.getX(vi)
      xyz[cursor++] = position.getY(vi)
      xyz[cursor++] = position.getZ(vi)
    }
  }
  return xyz
}

function fillPrepared(item: Prepared, plane: THREE.Plane, out: number[], wallsOnly: boolean) {
  const kinds = item.mesh.userData.kinds as Uint8Array | undefined
  for (const range of item.ranges) {
    if (wallsOnly && (kinds?.[range.sourceId] ?? 0) !== WALL_KIND) continue
    if (boxMisses(range.minX, range.minY, range.minZ, range.maxX, range.maxY, range.maxZ, plane)) continue
    // The sized solid is clipped away, so its fill sits on the discarded side of
    // the plane. A wall in analysis is a sheet the clip keeps when the sheet lies
    // in the plane, and that sheet would hide a fill behind it. Nudge those wall
    // fills onto the kept side.
    fillSolid(item.xyz, range.start, range.count, plane, out, wallsOnly)
  }
}

function boxMisses(
  minX: number, minY: number, minZ: number, maxX: number, maxY: number, maxZ: number, plane: THREE.Plane,
): boolean {
  const n = plane.normal
  const c = plane.constant
  const maxD = n.x * (n.x >= 0 ? maxX : minX) + n.y * (n.y >= 0 ? maxY : minY) + n.z * (n.z >= 0 ? maxZ : minZ) + c
  const minD = n.x * (n.x >= 0 ? minX : maxX) + n.y * (n.y >= 0 ? minY : maxY) + n.z * (n.z >= 0 ? minZ : maxZ) + c
  return minD > EPS || maxD < -EPS
}

/** Intersection of one closed piece with the plane, appended as black triangles. */
function fillSolid(
  xyz: Float32Array, start: number, count: number, plane: THREE.Plane, out: number[], keptSide = false,
) {
  const segs: number[] = []
  const n = plane.normal
  const c = plane.constant
  for (let t = 0; t < count; t++) {
    const o = (start + t) * 9
    clipTriangle(
      xyz[o], xyz[o + 1], xyz[o + 2],
      xyz[o + 3], xyz[o + 4], xyz[o + 5],
      xyz[o + 6], xyz[o + 7], xyz[o + 8],
      n.x, n.y, n.z, c, segs,
    )
  }
  if (segs.length < 18) return
  const loops = chainLoops(segs)
  const sign = keptSide ? 1 : -1
  const biasX = sign * n.x * BIAS_M
  const biasY = sign * n.y * BIAS_M
  const biasZ = sign * n.z * BIAS_M
  for (const loop of loops) triangulate(loop, n.x, n.y, n.z, biasX, biasY, biasZ, out)
}

function clipTriangle(
  ax: number, ay: number, az: number,
  bx: number, by: number, bz: number,
  cx: number, cy: number, cz: number,
  nx: number, ny: number, nz: number, constant: number,
  segs: number[],
) {
  const d0 = nx * ax + ny * ay + nz * az + constant
  const d1 = nx * bx + ny * by + nz * bz + constant
  const d2 = nx * cx + ny * cy + nz * cz + constant
  const s0 = d0 > EPS ? 1 : d0 < -EPS ? -1 : 0
  const s1 = d1 > EPS ? 1 : d1 < -EPS ? -1 : 0
  const s2 = d2 > EPS ? 1 : d2 < -EPS ? -1 : 0
  if (s0 === 0 && s1 === 0 && s2 === 0) return
  if (s0 !== 0 && s0 === s1 && s1 === s2) return
  const s = [s0, s1, s2]
  const d = [d0, d1, d2]
  const p = [ax, ay, az, bx, by, bz, cx, cy, cz]
  for (let e = 0; e < 3; e++) {
    const a = e
    const b = (e + 1) % 3
    if (s[a] === 0 && s[b] === 0) {
      // The face across this edge emits the same segment. Keep the one whose
      // third vertex is on the negative side so the boundary is counted once.
      if (s[3 - a - b] < 0) segs.push(p[a * 3], p[a * 3 + 1], p[a * 3 + 2], p[b * 3], p[b * 3 + 1], p[b * 3 + 2])
      return
    }
  }
  const points: number[] = []
  const push = (x: number, y: number, z: number) => {
    for (let i = 0; i < points.length; i += 3) {
      const dx = points[i] - x
      const dy = points[i + 1] - y
      const dz = points[i + 2] - z
      if (dx * dx + dy * dy + dz * dz < EPS * EPS) return
    }
    points.push(x, y, z)
  }
  for (let e = 0; e < 3; e++) {
    const a = e
    const b = (e + 1) % 3
    if (s[a] === 0) push(p[a * 3], p[a * 3 + 1], p[a * 3 + 2])
    if (s[a] * s[b] < 0) {
      const t = d[a] / (d[a] - d[b])
      push(
        p[a * 3] + (p[b * 3] - p[a * 3]) * t,
        p[a * 3 + 1] + (p[b * 3 + 1] - p[a * 3 + 1]) * t,
        p[a * 3 + 2] + (p[b * 3 + 2] - p[a * 3 + 2]) * t,
      )
    }
  }
  if (points.length === 6) segs.push(points[0], points[1], points[2], points[3], points[4], points[5])
}

interface Vert { x: number, y: number, z: number, links: number[] }

function chainLoops(segs: number[]): Vert[][] {
  const verts: Vert[] = []
  const weld = new Map<string, number>()
  const idOf = (x: number, y: number, z: number) => {
    const key = `${Math.round(x * WELD)},${Math.round(y * WELD)},${Math.round(z * WELD)}`
    const found = weld.get(key)
    if (found !== undefined) return found
    const id = verts.length
    verts.push({ x, y, z, links: [] })
    weld.set(key, id)
    return id
  }
  const edges = new Map<string, { a: number, b: number, n: number }>()
  for (let i = 0; i < segs.length; i += 6) {
    const a = idOf(segs[i], segs[i + 1], segs[i + 2])
    const b = idOf(segs[i + 3], segs[i + 4], segs[i + 5])
    if (a === b) continue
    const key = a < b ? `${a}|${b}` : `${b}|${a}`
    const edge = edges.get(key)
    if (edge) edge.n += 1
    else edges.set(key, { a, b, n: 1 })
  }
  for (const edge of edges.values()) {
    if (edge.n % 2 === 0) continue
    verts[edge.a].links.push(edge.b)
    verts[edge.b].links.push(edge.a)
  }
  const used = new Set<string>()
  const undirected = (a: number, b: number) => (a < b ? `${a}|${b}` : `${b}|${a}`)
  const loops: Vert[][] = []
  for (let s = 0; s < verts.length; s++) {
    for (const n0 of verts[s].links) {
      const first = undirected(s, n0)
      if (used.has(first)) continue
      const loop = [verts[s]]
      used.add(first)
      let prev = s
      let cur = n0
      let closed = false
      for (let guard = 0; guard <= verts.length; guard++) {
        if (cur === s) {
          closed = true
          break
        }
        loop.push(verts[cur])
        let next = -1
        for (const cand of verts[cur].links) {
          if (cand === prev || used.has(undirected(cur, cand))) continue
          next = cand
          break
        }
        if (next < 0) break
        used.add(undirected(cur, next))
        prev = cur
        cur = next
      }
      if (closed && loop.length >= 3) loops.push(loop)
    }
  }
  return loops
}

function triangulate(
  loop: Vert[], nx: number, ny: number, nz: number,
  biasX: number, biasY: number, biasZ: number, out: number[],
) {
  const [ux, uy, uz, vx, vy, vz] = axes(nx, ny, nz)
  const poly = loop.map((p) => ({
    x: p.x * ux + p.y * uy + p.z * uz,
    y: p.x * vx + p.y * vy + p.z * vz,
    px: p.x + biasX,
    py: p.y + biasY,
    pz: p.z + biasZ,
  }))
  for (let i = poly.length - 1; i > 0; i--) {
    const dx = poly[i].x - poly[i - 1].x
    const dy = poly[i].y - poly[i - 1].y
    if (dx * dx + dy * dy < EPS * EPS) poly.splice(i, 1)
  }
  if (poly.length >= 2) {
    const dx = poly[0].x - poly[poly.length - 1].x
    const dy = poly[0].y - poly[poly.length - 1].y
    if (dx * dx + dy * dy < EPS * EPS) poly.pop()
  }
  if (poly.length < 3) return
  let area = 0
  for (let i = 0; i < poly.length; i++) {
    const j = (i + 1) % poly.length
    area += poly[i].x * poly[j].y - poly[j].x * poly[i].y
  }
  if (Math.abs(area) < 1e-8) return
  if (area < 0) poly.reverse()
  if (convex(poly)) {
    for (let i = 1; i < poly.length - 1; i++) emit(poly[0], poly[i], poly[i + 1], out)
    return
  }
  const idx = poly.map((_, i) => i)
  let guard = idx.length * idx.length
  while (idx.length > 3 && guard-- > 0) {
    let clipped = false
    for (let i = 0; i < idx.length; i++) {
      const i0 = idx[(i + idx.length - 1) % idx.length]
      const i1 = idx[i]
      const i2 = idx[(i + 1) % idx.length]
      const a = poly[i0], b = poly[i1], c = poly[i2]
      if (cross(a, b, c) <= 1e-12) continue
      let contains = false
      for (const j of idx) {
        if (j === i0 || j === i1 || j === i2) continue
        if (pointInTri(poly[j], a, b, c)) {
          contains = true
          break
        }
      }
      if (contains) continue
      emit(a, b, c, out)
      idx.splice(i, 1)
      clipped = true
      break
    }
    if (!clipped) break
  }
  if (idx.length === 3) emit(poly[idx[0]], poly[idx[1]], poly[idx[2]], out)
}

function convex(poly: { x: number, y: number }[]): boolean {
  for (let i = 0; i < poly.length; i++) {
    if (cross(poly[i], poly[(i + 1) % poly.length], poly[(i + 2) % poly.length]) < -1e-9) return false
  }
  return true
}

function cross(a: { x: number, y: number }, b: { x: number, y: number }, c: { x: number, y: number }): number {
  return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
}

function pointInTri(
  p: { x: number, y: number },
  a: { x: number, y: number },
  b: { x: number, y: number },
  c: { x: number, y: number },
): boolean {
  const c1 = cross(a, b, p)
  const c2 = cross(b, c, p)
  const c3 = cross(c, a, p)
  const neg = c1 < -1e-12 || c2 < -1e-12 || c3 < -1e-12
  const pos = c1 > 1e-12 || c2 > 1e-12 || c3 > 1e-12
  return !(neg && pos)
}

function emit(
  a: { px: number, py: number, pz: number },
  b: { px: number, py: number, pz: number },
  c: { px: number, py: number, pz: number },
  out: number[],
) {
  out.push(a.px, a.py, a.pz, b.px, b.py, b.pz, c.px, c.py, c.pz)
}

function axes(nx: number, ny: number, nz: number): [number, number, number, number, number, number] {
  let ux: number, uy: number, uz: number
  if (Math.abs(ny) < 0.9) {
    ux = -nz
    uy = 0
    uz = nx
  } else {
    ux = 0
    uy = nz
    uz = -ny
  }
  const ul = Math.hypot(ux, uy, uz) || 1
  ux /= ul
  uy /= ul
  uz /= ul
  return [ux, uy, uz, ny * uz - nz * uy, nz * ux - nx * uz, nx * uy - ny * ux]
}
