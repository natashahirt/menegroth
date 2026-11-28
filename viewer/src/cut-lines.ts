/**
 * Black lines where an analysis cut meets the shells and the frame.
 *
 * Geometry mode already fills the sized solids. Analysis mode hides those
 * solids, so the cut is the intersection with the shell triangles and the
 * member centerlines. A member that only pierces the plane is drawn as a
 * small plus in the plane, along the plane's two axes.
 */

const EPS = 1e-4
/** Sit on the kept side of the clip plane so the line is not clipped away. */
const BIAS = 0.003
/** Half-size of the cross drawn where a member centerline pierces the plane. */
const MARK = 0.22

type Axis = "x" | "y"

/** Packed xyz pairs. `axis` "y" is three.js Y, the structural height. */
export function analysisCut(
  axis: Axis,
  value: number,
  position: Float32Array,
  faces: Uint32Array,
  elementNodes: Uint32Array,
): Float32Array {
  const nx = axis === "x" ? -1 : 0
  const ny = axis === "y" ? -1 : 0
  const out: number[] = []
  const triangles = faces.length / 3
  for (let t = 0; t < triangles; t++) {
    const ia = faces[t * 3]
    const ib = faces[t * 3 + 1]
    const ic = faces[t * 3 + 2]
    if (ia === undefined || ib === undefined || ic === undefined) continue
    clipTriangle(out, position, ia, ib, ic, nx, ny, value)
  }
  const members = elementNodes.length / 2
  for (let e = 0; e < members; e++) {
    const ia = elementNodes[e * 2]
    const ib = elementNodes[e * 2 + 1]
    if (ia === undefined || ib === undefined) continue
    clipMember(out, position, ia, ib, nx, ny, value, axis)
  }
  return new Float32Array(out)
}

function dist(position: Float32Array, index: number, nx: number, ny: number, constant: number): number {
  const o = index * 3
  return nx * (position[o] ?? 0) + ny * (position[o + 1] ?? 0) + constant
}

function point(position: Float32Array, index: number): [number, number, number] {
  const o = index * 3
  return [position[o] ?? 0, position[o + 1] ?? 0, position[o + 2] ?? 0]
}

function pushBiased(out: number[], x: number, y: number, z: number, nx: number, ny: number) {
  out.push(x + nx * BIAS, y + ny * BIAS, z)
}

function pushSegment(
  out: number[],
  ax: number, ay: number, az: number,
  bx: number, by: number, bz: number,
  nx: number, ny: number,
) {
  pushBiased(out, ax, ay, az, nx, ny)
  pushBiased(out, bx, by, bz, nx, ny)
}

function clipTriangle(
  out: number[],
  position: Float32Array,
  ia: number, ib: number, ic: number,
  nx: number, ny: number, constant: number,
) {
  if (!inRange(position, ia) || !inRange(position, ib) || !inRange(position, ic)) return
  const d0 = dist(position, ia, nx, ny, constant)
  const d1 = dist(position, ib, nx, ny, constant)
  const d2 = dist(position, ic, nx, ny, constant)
  // A triangle in the plane is a wall the cut runs along. The section fill draws
  // that wall from its stored thickness; a stroke here would trace the face.
  if (Math.abs(d0) <= EPS && Math.abs(d1) <= EPS && Math.abs(d2) <= EPS) return
  const hits: number[] = []
  const add = (x: number, y: number, z: number) => {
    for (let i = 0; i < hits.length; i += 3) {
      const dx = (hits[i] ?? 0) - x
      const dy = (hits[i + 1] ?? 0) - y
      const dz = (hits[i + 2] ?? 0) - z
      if (dx * dx + dy * dy + dz * dz < 1e-10) return
    }
    hits.push(x, y, z)
  }
  const edge = (i: number, j: number, di: number, dj: number) => {
    const onI = Math.abs(di) <= EPS
    const onJ = Math.abs(dj) <= EPS
    if (onI && onJ) {
      const a = point(position, i)
      const b = point(position, j)
      add(a[0], a[1], a[2])
      add(b[0], b[1], b[2])
      return
    }
    if (onI) {
      const a = point(position, i)
      add(a[0], a[1], a[2])
      return
    }
    if (onJ) {
      const b = point(position, j)
      add(b[0], b[1], b[2])
      return
    }
    if (di * dj > 0) return
    const t = di / (di - dj)
    const a = point(position, i)
    const b = point(position, j)
    add(a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t)
  }
  edge(ia, ib, d0, d1)
  edge(ib, ic, d1, d2)
  edge(ic, ia, d2, d0)
  const n = hits.length / 3
  if (n < 2) return
  let i0 = 0
  let i1 = 1
  if (n > 2) {
    let best = -1
    for (let i = 0; i < n; i++) {
      for (let j = i + 1; j < n; j++) {
        const dx = (hits[i * 3] ?? 0) - (hits[j * 3] ?? 0)
        const dy = (hits[i * 3 + 1] ?? 0) - (hits[j * 3 + 1] ?? 0)
        const dz = (hits[i * 3 + 2] ?? 0) - (hits[j * 3 + 2] ?? 0)
        const dd = dx * dx + dy * dy + dz * dz
        if (dd > best) {
          best = dd
          i0 = i
          i1 = j
        }
      }
    }
  }
  pushSegment(
    out,
    hits[i0 * 3] ?? 0, hits[i0 * 3 + 1] ?? 0, hits[i0 * 3 + 2] ?? 0,
    hits[i1 * 3] ?? 0, hits[i1 * 3 + 1] ?? 0, hits[i1 * 3 + 2] ?? 0,
    nx, ny,
  )
}

function clipMember(
  out: number[],
  position: Float32Array,
  ia: number, ib: number,
  nx: number, ny: number, constant: number,
  axis: Axis,
) {
  if (!inRange(position, ia) || !inRange(position, ib)) return
  const d0 = dist(position, ia, nx, ny, constant)
  const d1 = dist(position, ib, nx, ny, constant)
  const a = point(position, ia)
  const b = point(position, ib)
  if (Math.abs(d0) <= EPS && Math.abs(d1) <= EPS) {
    pushSegment(out, a[0], a[1], a[2], b[0], b[1], b[2], nx, ny)
    return
  }
  if (Math.abs(d0) <= EPS) {
    pushCross(out, a[0], a[1], a[2], nx, ny, axis)
    return
  }
  if (Math.abs(d1) <= EPS) {
    pushCross(out, b[0], b[1], b[2], nx, ny, axis)
    return
  }
  if (d0 * d1 > 0) return
  const t = d0 / (d0 - d1)
  pushCross(
    out,
    a[0] + (b[0] - a[0]) * t,
    a[1] + (b[1] - a[1]) * t,
    a[2] + (b[2] - a[2]) * t,
    nx, ny, axis,
  )
}

/** A plus in the cut plane, along its two axes. A diagonal X reads as a mark, not as the plane. */
function pushCross(out: number[], x: number, y: number, z: number, nx: number, ny: number, axis: Axis) {
  if (axis === "x") {
    pushSegment(out, x, y - MARK, z, x, y + MARK, z, nx, ny)
    pushSegment(out, x, y, z - MARK, x, y, z + MARK, nx, ny)
  } else {
    pushSegment(out, x - MARK, y, z, x + MARK, y, z, nx, ny)
    pushSegment(out, x, y, z - MARK, x, y, z + MARK, nx, ny)
  }
}

function inRange(position: Float32Array, index: number): boolean {
  return index >= 0 && index * 3 + 2 < position.length
}
