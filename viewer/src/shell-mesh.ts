/**
 * Display mesh for a slab that was fanned from its corners.
 *
 * A composite beam is already split in the solved frame, so those nodes carry
 * the beam's displacements. The corner fan does not use them, and the slab
 * then cannot follow the beam. This inserts beam nodes that already lie on a
 * slab edge and re-fans that triangle from the opposite vertex. It adds no
 * node and does not invent a displacement. A solved shell, which has one
 * stress value per triangle, is left alone by the caller.
 */

const TYPE_BEAM = 0
const KIND_WALL = 1

export interface ConformingShell {
  faces: Uint32Array
  kinds: Uint8Array
  /** New triangle index to the triangle it was split from. */
  from: Uint32Array
}

export function conformSlabToFrame(
  faces: Uint32Array,
  kinds: Uint8Array,
  position: Float32Array,
  elementNodes: Uint32Array,
  elementType: Uint8Array,
): ConformingShell {
  const nTri = Math.min(kinds.length, Math.floor(faces.length / 3))
  const nNode = Math.floor(position.length / 3)
  const identity = (): ConformingShell => ({
    faces: faces.subarray(0, nTri * 3),
    kinds: kinds.subarray(0, nTri),
    from: Uint32Array.from({ length: nTri }, (_, i) => i),
  })
  if (nTri === 0 || nNode === 0) return identity()

  const beamNode = new Uint8Array(nNode)
  const nElem = Math.min(elementType.length, Math.floor(elementNodes.length / 2))
  for (let e = 0; e < nElem; e++) {
    if ((elementType[e] ?? 1) !== TYPE_BEAM) continue
    const a = elementNodes[e * 2] ?? 0
    const b = elementNodes[e * 2 + 1] ?? 0
    if (a < nNode) beamNode[a] = 1
    if (b < nNode) beamNode[b] = 1
  }

  const onEdge = new Map<string, number[]>()
  const nodesBetween = (u: number, v: number): number[] => {
    const lo = Math.min(u, v)
    const hi = Math.max(u, v)
    const key = `${lo}:${hi}`
    let ids = onEdge.get(key)
    if (!ids) {
      ids = beamNodesOn(lo, hi, nNode, beamNode, position)
      onEdge.set(key, ids)
    }
    return u === lo ? ids : [...ids].reverse()
  }

  const outF: number[] = []
  const outK: number[] = []
  const from: number[] = []
  let grew = false
  for (let t = 0; t < nTri; t++) {
    const a = faces[t * 3] ?? 0
    const b = faces[t * 3 + 1] ?? 0
    const c = faces[t * 3 + 2] ?? 0
    const kind = kinds[t] ?? 0
    if (kind === KIND_WALL) {
      pushTri(outF, outK, from, a, b, c, kind, t)
      continue
    }
    let tris: number[][] = [[a, b, c]]
    for (const [u, v] of [[a, b], [b, c], [c, a]] as const) {
      const extra = nodesBetween(u, v)
      if (extra.length === 0) continue
      grew = true
      const chain = [u, ...extra, v]
      const next: number[][] = []
      for (const tri of tris) next.push(...splitEdge(tri, chain, position))
      tris = next
    }
    for (const tri of tris) pushTri(outF, outK, from, tri[0] ?? 0, tri[1] ?? 0, tri[2] ?? 0, kind, t)
  }
  if (!grew) return identity()
  return {
    faces: Uint32Array.from(outF),
    kinds: Uint8Array.from(outK),
    from: Uint32Array.from(from),
  }
}

/** Copy one value per old triangle onto the triangles split from it. */
export function expandTriangles<T extends Float32Array | Uint32Array | Uint8Array>(
  values: T,
  from: Uint32Array | null,
  oldCount: number,
): T {
  if (!from || values.length !== oldCount) return values
  const out = new (values.constructor as new (length: number) => T)(from.length)
  for (let i = 0; i < from.length; i++) out[i] = values[from[i] ?? 0] as T[number]
  return out
}

function pushTri(
  faces: number[], kinds: number[], from: number[],
  a: number, b: number, c: number, kind: number, source: number,
) {
  faces.push(a, b, c)
  kinds.push(kind)
  from.push(source)
}

function beamNodesOn(
  u: number, v: number, nNode: number, beamNode: Uint8Array, position: Float32Array,
): number[] {
  const ax = position[u * 3] ?? 0
  const ay = position[u * 3 + 1] ?? 0
  const az = position[u * 3 + 2] ?? 0
  const dx = (position[v * 3] ?? 0) - ax
  const dy = (position[v * 3 + 1] ?? 0) - ay
  const dz = (position[v * 3 + 2] ?? 0) - az
  const len2 = dx * dx + dy * dy + dz * dz
  if (!(len2 > 1e-8)) return []
  const hits: { t: number; id: number }[] = []
  for (let id = 0; id < nNode; id++) {
    if (!beamNode[id] || id === u || id === v) continue
    const px = (position[id * 3] ?? 0) - ax
    const py = (position[id * 3 + 1] ?? 0) - ay
    const pz = (position[id * 3 + 2] ?? 0) - az
    const t = (px * dx + py * dy + pz * dz) / len2
    if (t <= 0.02 || t >= 0.98) continue
    const ox = px - t * dx
    const oy = py - t * dy
    const oz = pz - t * dz
    if (ox * ox + oy * oy + oz * oz > 0.02 * 0.02) continue
    hits.push({ t, id })
  }
  hits.sort((p, q) => p.t - q.t)
  const ids: number[] = []
  for (const hit of hits) {
    if (ids[ids.length - 1] !== hit.id) ids.push(hit.id)
  }
  return ids
}

export interface SlabSheet {
  /** Structural elevation, metres. The same number the component records. */
  elevation: number
  thickness: number
}

export interface GrillageSlab {
  faces: Uint32Array
  kinds: Uint8Array
  thickness: Float32Array
}

/**
 * Slab surface of a rib grillage, drawn on the solved rib nodes.
 *
 * `position` is Y-up. Each rib bay becomes two triangles of the nodes the
 * frame already has, so the surface uses those displacements. No node is
 * added. A bay above or below every recorded slab is left out.
 */
export function grillageSlab(
  position: Float32Array,
  elementNodes: Uint32Array,
  elementType: Uint8Array,
  sheets: SlabSheet[],
): GrillageSlab | null {
  if (sheets.length === 0) return null
  const nNode = Math.floor(position.length / 3)
  const nElem = Math.min(elementType.length, Math.floor(elementNodes.length / 2))
  const adj = new Map<number, number[]>()
  const link = (a: number, b: number) => {
    const list = adj.get(a)
    if (list) list.push(b)
    else adj.set(a, [b])
  }
  for (let e = 0; e < nElem; e++) {
    if ((elementType[e] ?? 1) !== TYPE_BEAM) continue
    const a = elementNodes[e * 2] ?? 0
    const b = elementNodes[e * 2 + 1] ?? 0
    if (a >= nNode || b >= nNode) continue
    if (Math.abs((position[a * 3 + 1] ?? 0) - (position[b * 3 + 1] ?? 0)) > 0.05) continue
    link(a, b)
    link(b, a)
  }
  const plan = (id: number): [number, number] => [position[id * 3] ?? 0, position[id * 3 + 2] ?? 0]
  const height = (id: number) => position[id * 3 + 1] ?? 0
  for (const [id, nbrs] of adj) {
    const [x, y] = plan(id)
    nbrs.sort((p, q) => {
      const [px, py] = plan(p)
      const [qx, qy] = plan(q)
      return Math.atan2(py - y, px - x) - Math.atan2(qy - y, qx - x)
    })
  }
  const used = new Set<string>()
  const faces: number[] = []
  const thick: number[] = []
  for (const [a, nbrs] of adj) {
    for (const b0 of nbrs) {
      if (used.has(`${a}:${b0}`)) continue
      const face: number[] = []
      let u = a
      let v = b0
      let closed = false
      for (let guard = 0; guard < 10000; guard++) {
        face.push(u)
        used.add(`${u}:${v}`)
        const nbrsV = adj.get(v)
        if (!nbrsV) break
        const idx = nbrsV.indexOf(u)
        if (idx < 0) break
        const nxt = nbrsV[(idx - 1 + nbrsV.length) % nbrsV.length] ?? v
        u = v
        v = nxt
        if (u === a && v === b0) {
          closed = true
          break
        }
      }
      if (!closed || face.length < 3) continue
      let area = 0
      for (let i = 0; i < face.length; i++) {
        const [ax, ay] = plan(face[i] ?? 0)
        const [bx, by] = plan(face[(i + 1) % face.length] ?? 0)
        area += ax * by - bx * ay
      }
      if (!(area > 2e-4)) continue
      let cz = 0
      for (const id of face) cz += height(id)
      cz /= face.length
      const sheet = sheets.find((item) => Math.abs(item.elevation - cz) <= 0.05)
      if (!sheet) continue
      for (let i = 2; i < face.length; i++) {
        faces.push(face[0] ?? 0, face[i - 1] ?? 0, face[i] ?? 0)
        thick.push(sheet.thickness)
      }
    }
  }
  if (faces.length === 0) return null
  return {
    faces: Uint32Array.from(faces),
    kinds: new Uint8Array(faces.length / 3),
    thickness: Float32Array.from(thick),
  }
}

/** Replace the triangle edge that matches `chain` with a fan from the opposite vertex. */
function splitEdge(tri: number[], chain: number[], position: Float32Array): number[][] {
  const opposite = edgeOpposite(tri, chain[0] ?? -1, chain[chain.length - 1] ?? -1)
  if (opposite === null) return [tri]
  const out: number[][] = []
  for (let i = 0; i < chain.length - 1; i++) {
    const p = chain[i] ?? 0
    const q = chain[i + 1] ?? 0
    if (triangleArea(position, opposite, p, q) > 1e-6) out.push([opposite, p, q])
  }
  return out.length > 0 ? out : [tri]
}

function edgeOpposite(tri: number[], u: number, v: number): number | null {
  const [a, b, c] = tri
  if (a === undefined || b === undefined || c === undefined) return null
  if ((a === u && b === v) || (a === v && b === u)) return c
  if ((b === u && c === v) || (b === v && c === u)) return a
  if ((c === u && a === v) || (c === v && a === u)) return b
  return null
}

function triangleArea(position: Float32Array, a: number, b: number, c: number): number {
  const ax = position[a * 3] ?? 0
  const ay = position[a * 3 + 1] ?? 0
  const az = position[a * 3 + 2] ?? 0
  const bx = (position[b * 3] ?? 0) - ax
  const by = (position[b * 3 + 1] ?? 0) - ay
  const bz = (position[b * 3 + 2] ?? 0) - az
  const cx = (position[c * 3] ?? 0) - ax
  const cy = (position[c * 3 + 1] ?? 0) - ay
  const cz = (position[c * 3 + 2] ?? 0) - az
  const nx = by * cz - bz * cy
  const ny = bz * cx - bx * cz
  const nz = bx * cy - by * cx
  return 0.5 * Math.hypot(nx, ny, nz)
}
