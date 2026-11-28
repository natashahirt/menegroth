import * as THREE from "three"
import theme from "./theme.json"

export type DimensionView = "ground" | "front" | "back" | "left" | "right"

export interface DimensionGroups {
  ground: THREE.Group
  front: THREE.Group
  back: THREE.Group
  left: THREE.Group
  right: THREE.Group
}

/**
 * Overall and bay dimensions from the frame nodes. Ground lines lie on the
 * plan. Elevation lines sit just outside the face being viewed. When a
 * section cut replaces a face, a line keeps the same offset from the cut
 * that it had from that face.
 */
export function buildDimensions(position: Float32Array, elementNodes: Uint32Array): DimensionGroups | null {
  const stations = frameStations(position, elementNodes)
  if (stations.x.length < 2 || stations.y.length < 2 || stations.z.length < 2) return null
  const span = Math.max(
    stations.x[stations.x.length - 1] - stations.x[0],
    stations.y[stations.y.length - 1] - stations.y[0],
    stations.z[stations.z.length - 1] - stations.z[0],
  )
  const gap = Math.max(1.4, span * 0.06)
  const y0 = stations.y[0]
  const y1 = stations.y[stations.y.length - 1]
  const x0 = stations.x[0]
  const x1 = stations.x[stations.x.length - 1]
  const z0 = stations.z[0]
  const z1 = stations.z[stations.z.length - 1]

  const ground = new THREE.Group()
  ground.name = "dimensions-ground"
  addChain(ground, stations.x, (s) => new THREE.Vector3(s, y0, z0), new THREE.Vector3(0, 0, -gap), "ground")
  addChain(ground, stations.z, (s) => new THREE.Vector3(x1, y0, s), new THREE.Vector3(gap, 0, 0), "ground")

  const front = new THREE.Group()
  front.name = "dimensions-front"
  addChain(front, stations.x, (s) => new THREE.Vector3(s, y0, z1), new THREE.Vector3(0, -gap, gap * 0.35), "front")
  addChain(front, stations.y, (s) => new THREE.Vector3(x1, s, z1), new THREE.Vector3(gap, 0, gap * 0.35), "front")

  const back = new THREE.Group()
  back.name = "dimensions-back"
  addChain(back, stations.x, (s) => new THREE.Vector3(s, y0, z0), new THREE.Vector3(0, -gap, -gap * 0.35), "back")
  addChain(back, stations.y, (s) => new THREE.Vector3(x0, s, z0), new THREE.Vector3(-gap, 0, -gap * 0.35), "back")

  const right = new THREE.Group()
  right.name = "dimensions-right"
  addChain(right, stations.z, (s) => new THREE.Vector3(x1, y0, s), new THREE.Vector3(gap * 0.35, -gap, 0), "right")
  addChain(right, stations.y, (s) => new THREE.Vector3(x1, s, z1), new THREE.Vector3(gap * 0.35, 0, gap), "right")

  const left = new THREE.Group()
  left.name = "dimensions-left"
  addChain(left, stations.z, (s) => new THREE.Vector3(x0, y0, s), new THREE.Vector3(-gap * 0.35, -gap, 0), "left")
  addChain(left, stations.y, (s) => new THREE.Vector3(x0, s, z0), new THREE.Vector3(-gap * 0.35, 0, -gap), "left")

  const bounds = { x1, y1 }
  for (const group of [ground, front, back, left, right]) {
    group.userData.bounds = bounds
    markNoClip(group)
    captureDimensionRest(group)
  }
  front.visible = false
  back.visible = false
  left.visible = false
  right.visible = false
  return { ground, front, back, left, right }
}

/** A point this close to a face belongs to that face, including the offset outside it. */
const FACE_TOL_M = 0.05

/**
 * A cut that moves inside a face becomes the new face. Dimension lines keep
 * the offset they had from the original face, measured from the cut instead.
 * A string the cut shortens keeps its number, rewritten to the length that
 * remains. A string that lies entirely past the cut is removed.
 */
export function applyDimensionCuts(groups: DimensionGroups | null, cutX: number | null, cutY: number | null) {
  if (!groups) return
  for (const group of [groups.ground, groups.front, groups.back, groups.left, groups.right]) {
    const bounds = group.userData.bounds as { x1: number, y1: number }
    const cuts = activeCuts(cutX, cutY, bounds)
    group.traverse((obj: THREE.Object3D) => {
      if (!obj.userData.dimSegment || obj.userData.dimLine) return
      if (obj.parent?.userData?.dimMeasure) return
      const rest = obj.userData.rest as Float32Array | undefined
      const attr = (obj as THREE.LineSegments).geometry?.getAttribute?.("position")
      if (!rest || !attr) return
      const arr = attr.array as Float32Array
      obj.visible = fitToCuts(arr, rest, cuts)
      attr.needsUpdate = true
      ;(obj as THREE.LineSegments).geometry.computeBoundingSphere()
    })
    group.traverse((obj: THREE.Object3D) => {
      if (!obj.userData.dimMeasure) return
      const line = obj.children.find((child: THREE.Object3D) => child.userData.dimLine) as THREE.LineSegments | undefined
      const label = obj.children.find((child: THREE.Object3D) => child.userData.dimLabel) as THREE.Mesh | undefined
      if (!line || !label) return
      const attr = line.geometry.getAttribute("position")
      const arr = attr.array as Float32Array
      const rest = line.userData.rest as Float32Array
      const keep = fitToCuts(arr, rest, cuts)
      obj.visible = keep
      line.visible = keep
      attr.needsUpdate = true
      line.geometry.computeBoundingSphere()
      for (const child of obj.children) {
        if (!child.userData.dimSegment || child.userData.dimLine) continue
        const tick = child as THREE.LineSegments
        const tickRest = tick.userData.rest as Float32Array
        const tickAttr = tick.geometry.getAttribute("position")
        const tickArr = tickAttr.array as Float32Array
        if (keep) moveTick(tickArr, tickRest, rest, arr)
        tick.visible = keep
        tickAttr.needsUpdate = true
        tick.geometry.computeBoundingSphere()
      }
      if (!keep) return
      const curLen = Math.hypot(arr[3] - arr[0], arr[4] - arr[1], arr[5] - arr[2])
      label.visible = curLen >= 0.08
      redrawLabel(label, curLen)
      const nudge = label.userData.nudge as THREE.Vector3
      label.position.set(
        (arr[0] + arr[3]) * 0.5 + nudge.x,
        (arr[1] + arr[4]) * 0.5 + nudge.y,
        (arr[2] + arr[5]) * 0.5 + nudge.z,
      )
    })
  }
}

interface Cut {
  axis: 0 | 1
  limit: number
  bound: number
  delta: number
}

function activeCuts(cutX: number | null, cutY: number | null, bounds: { x1: number, y1: number }): Cut[] {
  const cuts: Cut[] = []
  if (cutX !== null && cutX < bounds.x1 - FACE_TOL_M) {
    cuts.push({ axis: 0, limit: cutX, bound: bounds.x1, delta: cutX - bounds.x1 })
  }
  if (cutY !== null && cutY < bounds.y1 - FACE_TOL_M) {
    cuts.push({ axis: 1, limit: cutY, bound: bounds.y1, delta: cutY - bounds.y1 })
  }
  return cuts
}

/**
 * Face vertices slide onto the cut and keep their offset. A vertex in the
 * opening snaps to the cut when the other end is still on the kept side.
 * A segment with nothing left on that side is dropped.
 */
function fitToCuts(arr: Float32Array, rest: Float32Array, cuts: Cut[]): boolean {
  arr.set(rest)
  for (const cut of cuts) {
    let kept = false
    let opening = false
    for (let i = cut.axis; i < rest.length; i += 3) {
      const coord = rest[i]
      if (coord <= cut.limit + 1e-4) kept = true
      else if (coord < cut.bound - FACE_TOL_M) opening = true
    }
    if (opening && !kept) return false
    for (let i = cut.axis; i < rest.length; i += 3) {
      const coord = rest[i]
      if (coord >= cut.bound - FACE_TOL_M) arr[i] = coord + cut.delta
      else if (coord > cut.limit + 1e-4) arr[i] = cut.limit
    }
  }
  return true
}

function moveTick(arr: Float32Array, rest: Float32Array, lineRest: Float32Array, lineArr: Float32Array) {
  const cx = (rest[0] + rest[3]) * 0.5
  const cy = (rest[1] + rest[4]) * 0.5
  const cz = (rest[2] + rest[5]) * 0.5
  const d0 = (cx - lineRest[0]) ** 2 + (cy - lineRest[1]) ** 2 + (cz - lineRest[2]) ** 2
  const d1 = (cx - lineRest[3]) ** 2 + (cy - lineRest[4]) ** 2 + (cz - lineRest[5]) ** 2
  const end = d0 <= d1 ? 0 : 3
  const dx = lineArr[end] - lineRest[end]
  const dy = lineArr[end + 1] - lineRest[end + 1]
  const dz = lineArr[end + 2] - lineRest[end + 2]
  arr[0] = rest[0] + dx
  arr[1] = rest[1] + dy
  arr[2] = rest[2] + dz
  arr[3] = rest[3] + dx
  arr[4] = rest[4] + dy
  arr[5] = rest[5] + dz
}

function redrawLabel(label: THREE.Mesh, length: number) {
  const text = formatLength(length)
  const canvas = label.userData.canvas as HTMLCanvasElement | undefined
  if (canvas && label.userData.dimText !== text) {
    paintCanvas(canvas, text)
    const map = (label.material as THREE.MeshBasicMaterial).map as THREE.CanvasTexture | undefined
    if (map) map.needsUpdate = true
    label.userData.dimText = text
  }
  const base = Number(label.userData.baseWidth ?? 1)
  const width = Math.min(base, Math.max(length * 0.7, 0.5))
  const scale = width / base
  label.scale.set(scale, scale, 1)
}

function captureDimensionRest(group: THREE.Group) {
  group.traverse((obj: THREE.Object3D) => {
    if (!obj.userData.dimSegment) return
    const attr = (obj as THREE.LineSegments).geometry.getAttribute("position")
    obj.userData.rest = new Float32Array(attr.array as Float32Array)
  })
}

export function disposeDimensions(groups: DimensionGroups) {
  for (const group of [groups.ground, groups.front, groups.back, groups.left, groups.right]) {
    group.traverse((obj: THREE.Object3D) => {
      const mesh = obj as THREE.Mesh
      mesh.geometry?.dispose?.()
      const material = mesh.material as THREE.Material & { map?: { dispose: () => void } }
      if (material?.map) {
        material.map.dispose()
        material.dispose()
      }
    })
  }
}

function frameStations(position: Float32Array, elementNodes: Uint32Array) {
  const xs: number[] = []
  const ys: number[] = []
  const zs: number[] = []
  const seen = new Set<number>()
  const nodes = elementNodes.length > 0 ? elementNodes : indexAll(position)
  for (let i = 0; i < nodes.length; i++) {
    const n = nodes[i]
    if (seen.has(n)) continue
    seen.add(n)
    xs.push(position[n * 3])
    ys.push(position[n * 3 + 1])
    zs.push(position[n * 3 + 2])
  }
  return { x: cluster(xs), y: cluster(ys), z: cluster(zs) }
}

function indexAll(position: Float32Array): Uint32Array {
  return Uint32Array.from({ length: position.length / 3 }, (_, i) => i)
}

function cluster(values: number[], tol = 0.02): number[] {
  const sorted = values.filter((v) => Number.isFinite(v)).sort((a, b) => a - b)
  const out: number[] = []
  for (const value of sorted) {
    if (out.length === 0 || value - out[out.length - 1] > tol) out.push(value)
  }
  return out
}

type LabelLay = "ground" | "front" | "back" | "left" | "right"

function addChain(
  parent: THREE.Group,
  stations: number[],
  at: (station: number) => THREE.Vector3,
  offset: THREE.Vector3,
  lay: LabelLay,
) {
  if (stations.length < 2) return
  const points = stations.map(at)
  for (const point of points) parent.add(segment(point, point.clone().add(offset)))
  for (let i = 0; i < points.length - 1; i++) {
    parent.add(measure(points[i].clone().add(offset), points[i + 1].clone().add(offset), offset, lay))
  }
  if (stations.length > 2) {
    const overall = offset.clone().multiplyScalar(2.15)
    parent.add(segment(points[0], points[0].clone().add(overall)))
    parent.add(segment(points[points.length - 1], points[points.length - 1].clone().add(overall)))
    parent.add(measure(points[0].clone().add(overall), points[points.length - 1].clone().add(overall), overall, lay))
  }
}

function measure(a: THREE.Vector3, b: THREE.Vector3, offset: THREE.Vector3, lay: LabelLay): THREE.Group {
  const group = new THREE.Group()
  group.userData.dimMeasure = true
  const length = a.distanceTo(b)
  const line = segment(a, b)
  line.userData.dimLine = true
  group.add(line)
  const dir = b.clone().sub(a)
  if (dir.lengthSq() < 1e-8) return group
  dir.normalize()
  const normal = new THREE.Vector3().crossVectors(dir, offset)
  if (normal.lengthSq() < 1e-8) normal.set(0, 1, 0)
  const tick = new THREE.Vector3().crossVectors(normal, dir).normalize().multiplyScalar(0.32)
  group.add(segment(a.clone().sub(tick), a.clone().add(tick)))
  group.add(segment(b.clone().sub(tick), b.clone().add(tick)))
  const label = textPlane(formatLength(length), length)
  label.position.copy(a).add(b).multiplyScalar(0.5)
  const nudge = lay === "ground" ? new THREE.Vector3(offset.x, 0, offset.z) : offset.clone()
  const planeHeight = Number(label.geometry.parameters?.height ?? 0.8)
  if (nudge.lengthSq() > 1e-8) label.position.add(nudge.normalize().multiplyScalar(planeHeight * 0.65))
  if (lay === "ground") label.position.y += 0.04
  layLabel(label, a, b, offset, lay)
  label.userData.dimLabel = true
  label.userData.nudge = label.position.clone().sub(a.clone().add(b).multiplyScalar(0.5))
  group.add(label)
  return group
}

/** Ground numbers lie on the plan. Elevation numbers face that view. */
function layLabel(mesh: THREE.Mesh, a: THREE.Vector3, b: THREE.Vector3, offset: THREE.Vector3, lay: LabelLay) {
  const along = b.clone().sub(a)
  const xAxis = new THREE.Vector3()
  const yAxis = new THREE.Vector3()
  const zAxis = new THREE.Vector3()
  if (lay === "ground") {
    zAxis.set(0, 1, 0)
    xAxis.set(along.x, 0, along.z)
    if (xAxis.lengthSq() < 1e-8) xAxis.set(1, 0, 0)
    xAxis.normalize()
    yAxis.crossVectors(zAxis, xAxis).normalize()
    const outward = new THREE.Vector3(offset.x, 0, offset.z)
    if (outward.lengthSq() > 1e-8 && yAxis.dot(outward) < 0) {
      yAxis.negate()
      xAxis.negate()
    }
  } else {
    const face = lay === "front" ? 1 : lay === "back" ? -1 : 0
    const side = lay === "right" ? 1 : lay === "left" ? -1 : 0
    zAxis.set(side, 0, face)
    const vertical = Math.abs(along.y) >= Math.abs(along.x) && Math.abs(along.y) >= Math.abs(along.z)
    if (vertical) xAxis.set(0, along.y >= 0 ? 1 : -1, 0)
    else if (face !== 0) xAxis.set(along.x >= 0 ? face : -face, 0, 0)
    else xAxis.set(0, 0, along.z >= 0 ? side : -side)
    yAxis.crossVectors(zAxis, xAxis).normalize()
    if (yAxis.y < 0) {
      yAxis.negate()
      xAxis.negate()
    }
  }
  mesh.quaternion.setFromRotationMatrix(new THREE.Matrix4().makeBasis(xAxis, yAxis, zAxis))
}

function formatLength(length: number): string {
  return `${length.toFixed(2)} m`
}

function paintCanvas(canvas: HTMLCanvasElement, text: string) {
  const ctx = canvas.getContext("2d")
  if (!ctx) return
  ctx.clearRect(0, 0, canvas.width, canvas.height)
  ctx.fillStyle = theme.charcoal
  ctx.font = "600 72px Inter, Helvetica, sans-serif"
  ctx.textAlign = "center"
  ctx.textBaseline = "middle"
  ctx.fillText(text, canvas.width / 2, canvas.height / 2)
}

const lineMaterial = new THREE.LineBasicMaterial({ color: theme.charcoal })

function segment(a: THREE.Vector3, b: THREE.Vector3): THREE.LineSegments {
  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute("position", new THREE.BufferAttribute(new Float32Array([
    a.x, a.y, a.z, b.x, b.y, b.z,
  ]), 3))
  const line = new THREE.LineSegments(geometry, lineMaterial)
  line.userData.noclip = true
  line.userData.dimSegment = true
  return line
}

function textPlane(text: string, length: number): THREE.Mesh {
  const canvas = document.createElement("canvas")
  canvas.width = 512
  canvas.height = 128
  paintCanvas(canvas, text)
  const texture = new THREE.CanvasTexture(canvas)
  texture.colorSpace = THREE.SRGBColorSpace
  const width = Math.min(4.2, Math.max(length * 0.7, 0.9))
  const height = width * (canvas.height / canvas.width)
  const mesh = new THREE.Mesh(
    new THREE.PlaneGeometry(width, height),
    new THREE.MeshBasicMaterial({
      map: texture,
      transparent: true,
      depthTest: true,
      depthWrite: false,
    }),
  )
  mesh.userData.noclip = true
  mesh.userData.canvas = canvas
  mesh.userData.dimText = text
  mesh.userData.baseWidth = width
  mesh.raycast = () => {}
  return mesh
}

function markNoClip(group: THREE.Group) {
  group.userData.noclip = true
  group.traverse((obj: THREE.Object3D) => { obj.userData.noclip = true })
}
