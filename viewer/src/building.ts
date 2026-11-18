import * as THREE from "three"
import theme from "./theme.json"
import { displacementAt } from "./frame"

/** Shell kind codes, as written by `build_scene`. */
const KIND_SLAB = 0
const KIND_WALL = 1
const KIND_PATCH = 2

/** Frame `element_type` codes: beam, column, brace. */
const TYPE_BEAM = 0
const TYPE_COLUMN = 1
const TYPE_BRACE = 2

/** Distinct hues for the Categories geometry view. Sized geometry keeps the concrete greys. */
export const CATEGORY_COLOR = {
  beam: theme.catBeam,
  column: theme.catColumn,
  brace: theme.catBrace,
  slab: theme.catSlab,
  wall: theme.catWall,
  drop: theme.catDrop,
  footing: theme.catFooting,
}

const SUPPORT_BAND_M = 0.05
const WALL_COLUMN_TOL_M = 0.15

function onPlanSegment(
  px: number, pz: number, ax: number, az: number, bx: number, bz: number, tol: number,
): boolean {
  const dx = bx - ax
  const dz = bz - az
  const len2 = dx * dx + dz * dz
  if (len2 < 1e-8) return Math.hypot(px - ax, pz - az) <= tol
  const t = Math.min(1, Math.max(0, ((px - ax) * dx + (pz - az) * dz) / len2))
  return Math.hypot(px - (ax + t * dx), pz - (az + t * dz)) <= tol
}

function pushWallPlanEdge(out: number[], position: Float32Array, i: number, j: number) {
  const ax = position[i * 3] ?? 0
  const ay = position[i * 3 + 1] ?? 0
  const az = position[i * 3 + 2] ?? 0
  const bx = position[j * 3] ?? 0
  const by = position[j * 3 + 1] ?? 0
  const bz = position[j * 3 + 2] ?? 0
  const plan = Math.hypot(bx - ax, bz - az)
  if (plan < 1e-4 || Math.abs(ay - by) > Math.max(0.05, 0.2 * plan)) return
  out.push(ax, az, bx, bz)
}

/**
 * Frame elements the picture leaves out.
 *
 * A beam with both ends on the support elevation runs between foundations.
 * A column whose plan point lies on a wall is that wall's support, so the
 * stack is not drawn. The returned mask is 1 for each omitted element.
 */
export function omittedMembers(
  position: Float32Array,
  elementNodes: Uint32Array,
  elementType: Uint8Array,
  shellFaces: Uint32Array,
  shellKinds: Uint8Array,
): Uint8Array {
  const nElem = Math.min(elementType.length, Math.floor(elementNodes.length / 2))
  const hide = new Uint8Array(nElem)
  let floor = Infinity
  for (let i = 0; i < position.length / 3; i++) {
    const y = position[i * 3 + 1] ?? 0
    if (y < floor) floor = y
  }
  const walls: number[] = []
  const nTri = Math.min(shellKinds.length, Math.floor(shellFaces.length / 3))
  for (let t = 0; t < nTri; t++) {
    if ((shellKinds[t] ?? 0) !== KIND_WALL) continue
    const a = shellFaces[t * 3] ?? 0
    const b = shellFaces[t * 3 + 1] ?? 0
    const c = shellFaces[t * 3 + 2] ?? 0
    pushWallPlanEdge(walls, position, a, b)
    pushWallPlanEdge(walls, position, b, c)
    pushWallPlanEdge(walls, position, c, a)
  }
  for (let e = 0; e < nElem; e++) {
    const ia = elementNodes[e * 2] ?? 0
    const ib = elementNodes[e * 2 + 1] ?? 0
    const ax = position[ia * 3] ?? 0
    const ay = position[ia * 3 + 1] ?? 0
    const az = position[ia * 3 + 2] ?? 0
    const bx = position[ib * 3] ?? 0
    const by = position[ib * 3 + 1] ?? 0
    const bz = position[ib * 3 + 2] ?? 0
    const type = elementType[e] ?? TYPE_BEAM
    if (type === TYPE_BEAM
      && Math.abs(ay - floor) <= SUPPORT_BAND_M
      && Math.abs(by - floor) <= SUPPORT_BAND_M) {
      hide[e] = 1
      continue
    }
    if (type !== TYPE_COLUMN) continue
    const px = (ax + bx) / 2
    const pz = (az + bz) / 2
    for (let k = 0; k < walls.length; k += 4) {
      if (onPlanSegment(px, pz, walls[k] ?? 0, walls[k + 1] ?? 0, walls[k + 2] ?? 0, walls[k + 3] ?? 0, WALL_COLUMN_TOL_M)) {
        hide[e] = 1
        break
      }
    }
  }
  return hide
}

/** Drop member-solid triangles whose frame element is omitted. */
export function withoutOmittedSolids(
  faces: Uint32Array,
  owner: Uint32Array,
  hidden: Uint8Array,
): { faces: Uint32Array; owner: Uint32Array } {
  let keep = 0
  for (let t = 0; t < owner.length; t++) {
    if (!hidden[owner[t] ?? 0]) keep++
  }
  if (keep === owner.length) return { faces, owner }
  const nextFaces = new Uint32Array(keep * 3)
  const nextOwner = new Uint32Array(keep)
  let written = 0
  for (let t = 0; t < owner.length; t++) {
    if (hidden[owner[t] ?? 0]) continue
    nextFaces[written * 3] = faces[t * 3] ?? 0
    nextFaces[written * 3 + 1] = faces[t * 3 + 1] ?? 0
    nextFaces[written * 3 + 2] = faces[t * 3 + 2] ?? 0
    nextOwner[written] = owner[t] ?? 0
    written++
  }
  return { faces: nextFaces, owner: nextOwner }
}

/** Category hue of one frame element. A solid head is drawn as slab, not as a beam. */
export function memberCategory(type: number, section: string): string {
  if (section === "solid head") return CATEGORY_COLOR.slab
  if (type === TYPE_COLUMN) return CATEGORY_COLOR.column
  if (type === TYPE_BRACE) return CATEGORY_COLOR.brace
  return CATEGORY_COLOR.beam
}

/** Category hue of one shell triangle. */
export function shellCategory(kind: number): string {
  if (kind === KIND_WALL) return CATEGORY_COLOR.wall
  if (kind === KIND_PATCH) return CATEGORY_COLOR.drop
  return CATEGORY_COLOR.slab
}

/** 0 is the cold end of the deflection ramp and 1 is the hot end, the design limit. */
export function utilizationColor(ratio: number, out: THREE.Color): THREE.Color {
  if (!Number.isFinite(ratio)) return out.set(theme.ghost)
  return deflectionColor(Math.max(0, Math.min(ratio, 1)), out)
}

export const SHELL_KIND_NAME = ["Slab", "Wall", "Drop panel", "Shell"]

/**
 * Blue → cyan → yellow → red, the same stops as the Grasshopper deflection
 * mapper. `t` is the displacement divided by the scene maximum.
 */
export function deflectionColor(t: number, out: THREE.Color): THREE.Color {
  const u = Math.max(0, Math.min(t, 1))
  let r: number, g: number, b: number
  if (u <= 0.33) {
    const s = u / 0.33
    r = 40 * (1 - s)
    g = 80 + s * 175
    b = 200 * (1 - s) + s * 200
  } else if (u <= 0.66) {
    const s = (u - 0.33) / 0.33
    r = s * 240
    g = 255 - s * 55
    b = 200 * (1 - s)
  } else {
    const s = (u - 0.66) / 0.34
    r = 240 - s * 20
    g = 200 * (1 - s) + s * 30
    b = 0
  }
  return out.setRGB(r / 255, g / 255, b / 255, THREE.SRGBColorSpace)
}

/** Same ramp as deflection, centered so a negative value is the low end and a positive value the high end. */
export function signedColor(value: number, scale: number, out: THREE.Color): THREE.Color {
  const denom = Math.max(Math.abs(scale), 1e-12)
  const t = 0.5 + 0.5 * Math.max(-1, Math.min(value / denom, 1))
  return deflectionColor(t, out)
}

const STRESS_COMPRESSION = new THREE.Color(theme.magenta)
const STRESS_PAPER = new THREE.Color(theme.background)
const STRESS_TENSION = new THREE.Color(theme.cerulean)

/**
 * Compression is the palette magenta, zero is the paper background, tension is cerulean.
 * `value` is signed surface stress and `scale` is the peak absolute value.
 */
export function stressColor(value: number, scale: number, out: THREE.Color): THREE.Color {
  const denom = Math.max(Math.abs(scale), 1e-12)
  const t = Math.max(-1, Math.min(value / denom, 1))
  if (t < 0) return out.copy(STRESS_COMPRESSION).lerp(STRESS_PAPER, t + 1)
  return out.copy(STRESS_PAPER).lerp(STRESS_TENSION, t)
}

/**
 * One pastel per frame element. The golden angle keeps neighboring members apart
 * on the hue wheel, and the same index always returns the same color.
 */
export function pastelColor(index: number, out: THREE.Color): THREE.Color {
  const hue = ((index * 137.508) % 360) / 360
  return out.setHSL(hue, 0.42, 0.78)
}

/** Slabs, walls, and spread footings. Positions and displacements are already Y-up. */
export interface BuildingParts {
  shells: THREE.Mesh[]
  ghosts: THREE.Mesh[]
  footings: THREE.InstancedMesh | null
  shellTriangles: number
  footingCount: number
  maxDisplacement: number
  /** Concrete material, and the same material with the deflection colormap. */
  solidFor(kind: number): THREE.Material
  mappedFor(kind: number): THREE.Material
}

export function buildBuilding(input: {
  position: Float32Array
  displacement: Float32Array
  faces: Uint32Array
  kinds: Uint8Array
  footingCenter: Float32Array
  footingSize: Float32Array
  scale: { value: number }
  /** Member displacement to include in the shared color scale, meters. */
  colorMax?: number
}): BuildingParts {
  const { position, faces, kinds } = input
  if (faces.length !== 0 && faces.length !== kinds.length * 3) {
    throw new Error("shell faces and kinds have different counts")
  }
  const displacement = input.displacement.length === position.length
    ? input.displacement
    : new Float32Array(position.length)
  const nodeCount = position.length / 3
  const magnitude = new Float32Array(nodeCount)
  let maxDisplacement = 0
  for (let i = 0; i < nodeCount; i++) {
    const mag = Math.hypot(displacement[i * 3], displacement[i * 3 + 1], displacement[i * 3 + 2])
    magnitude[i] = mag
    if (mag > maxDisplacement) maxDisplacement = mag
  }
  const color = new Float32Array(position.length)
  const sample = new THREE.Color()
  const colorScale = Math.max(maxDisplacement, input.colorMax ?? 0)
  const denom = Math.max(colorScale, 1e-12)
  for (let i = 0; i < nodeCount; i++) {
    deflectionColor(magnitude[i] / denom, sample)
    color[i * 3] = sample.r
    color[i * 3 + 1] = sample.g
    color[i * 3 + 2] = sample.b
  }

  const positionAttr = new THREE.BufferAttribute(position, 3)
  const dispAttr = new THREE.BufferAttribute(displacement, 3)
  const colorAttr = new THREE.BufferAttribute(color, 3)
  const keep = new Float32Array(nodeCount)
  keep.fill(1)
  const keepAttr = new THREE.BufferAttribute(keep, 1)
  const byKind = new Map<number, number[]>()
  const sourceByKind = new Map<number, number[]>()
  for (let t = 0; t < kinds.length; t++) {
    const kind = kinds[t] === KIND_WALL ? KIND_WALL : kinds[t] === KIND_PATCH ? KIND_PATCH : KIND_SLAB
    let list = byKind.get(kind)
    if (!list) byKind.set(kind, (list = []))
    list.push(faces[t * 3], faces[t * 3 + 1], faces[t * 3 + 2])
    let source = sourceByKind.get(kind)
    if (!source) sourceByKind.set(kind, (source = []))
    source.push(t)
  }

  const solid = new Map<number, THREE.Material>()
  const mapped = new Map<number, THREE.Material>()
  const shells: THREE.Mesh[] = []
  const ghosts: THREE.Mesh[] = []
  for (const [kind, indices] of byKind) {
    const geometry = new THREE.BufferGeometry()
    geometry.setAttribute("position", positionAttr)
    geometry.setAttribute("aDisp", dispAttr)
    geometry.setAttribute("color", colorAttr)
    geometry.setAttribute("aKeep", keepAttr)
    geometry.setIndex(new THREE.BufferAttribute(new Uint32Array(indices), 1))
    const tint = kind === KIND_WALL ? theme.concrete : kind === KIND_PATCH ? theme.footing : theme.slab
    const solidMaterial = displacedLambert(tint, input.scale, false)
    const mappedMaterial = displacedLambert("#ffffff", input.scale, true)
    solid.set(kind, solidMaterial)
    mapped.set(kind, mappedMaterial)
    const mesh = new THREE.Mesh(geometry, solidMaterial)
    // `source[faceIndex]` is the triangle's index in `shell_faces`.
    mesh.userData = { role: "shell", kind, source: new Uint32Array(sourceByKind.get(kind) ?? []) }
    // Deflected vertices leave the undeformed bounds. The mesh is the building.
    mesh.frustumCulled = false
    shells.push(mesh)

    const ghost = new THREE.Mesh(geometry, new THREE.MeshLambertMaterial({
      color: theme.ghost,
      transparent: true,
      opacity: 0.28,
      depthWrite: false,
      side: THREE.DoubleSide,
    }))
    ghost.userData = { role: "ghost" }
    ghost.frustumCulled = false
    ghost.visible = false
    ghost.raycast = () => {}
    ghosts.push(ghost)
  }

  return {
    shells,
    ghosts,
    footings: buildFootings(input.footingCenter, input.footingSize),
    shellTriangles: kinds.length,
    footingCount: input.footingCenter.length / 3,
    maxDisplacement: colorScale,
    solidFor: (kind) => solid.get(kind) ?? solid.get(KIND_SLAB)!,
    mappedFor: (kind) => mapped.get(kind) ?? mapped.get(KIND_SLAB)!,
  }
}

/** Matte Lambert. The deflection is the shell's own nodal translation. */
function displacedLambert(color: string, scale: { value: number }, vertexColors: boolean): THREE.MeshLambertMaterial {
  const material = new THREE.MeshLambertMaterial({
    color,
    vertexColors,
    side: THREE.DoubleSide,
    flatShading: true,
    polygonOffset: true,
    polygonOffsetFactor: 1,
    polygonOffsetUnits: 1,
  })
  material.onBeforeCompile = (shader: { uniforms: Record<string, { value: number }>; vertexShader: string; fragmentShader: string }) => {
    shader.uniforms.uScale = scale
    shader.vertexShader = shader.vertexShader
      .replace("#include <common>", "#include <common>\nuniform float uScale;\nattribute vec3 aDisp;\nattribute float aKeep;\nvarying float vKeep;")
      .replace("#include <begin_vertex>", "vec3 transformed = position + uScale * aDisp;\nvKeep = aKeep;")
    shader.fragmentShader = shader.fragmentShader
      .replace("#include <common>", "#include <common>\nvarying float vKeep;")
      .replace("#include <dithering_fragment>", "gl_FragColor.rgb = mix(vec3(0.78431, 0.78431, 0.76863), gl_FragColor.rgb, clamp(vKeep, 0.0, 1.0));\n#include <dithering_fragment>")
  }
  return material
}

/**
 * Per-vertex displacement. A solid-head vertex follows the nearest node, so
 * each bay moves with its corners. Any other member uses the same Hermite
 * shape as the frame sticks, so a beam curves between its ends instead of
 * staying a straight chord.
 */
function memberSolidDisp(
  position: Float32Array,
  faces: Uint32Array,
  owner: Uint32Array,
  sections: string[],
  motion?: MemberSolidMotion,
): Float32Array {
  const disp = new Float32Array(position.length)
  if (!motion || motion.nodeDisplacement.length !== motion.nodePosition.length) return disp
  const nodes = motion.nodePosition
  const nodeDisp = motion.nodeDisplacement
  const nNodes = nodes.length / 3
  const curved = motion.localDof !== undefined && motion.lcs !== undefined &&
    motion.localDof.length > 0 && motion.lcs.length > 0
  const loadRow = motion.loadRow
  const particular = motion.particular ?? new Float32Array()
  const stations = motion.stations ?? 0
  const written = new Uint8Array(position.length / 3)
  for (let t = 0; t < owner.length; t++) {
    const e = owner[t] ?? 0
    const solid = (sections[e] ?? "") === "solid head"
    const ia = motion.elementNodes[e * 2] ?? 0
    const ib = motion.elementNodes[e * 2 + 1] ?? 0
    for (let k = 0; k < 3; k++) {
      const v = faces[t * 3 + k] ?? 0
      if (written[v]) continue
      const x = position[v * 3] ?? 0
      const y = position[v * 3 + 1] ?? 0
      const z = position[v * 3 + 2] ?? 0
      let dx = 0, dy = 0, dz = 0
      if (solid) {
        let best = 0
        let bestD = Infinity
        for (let i = 0; i < nNodes; i++) {
          const ex = x - (nodes[i * 3] ?? 0)
          const ey = y - (nodes[i * 3 + 1] ?? 0)
          const ez = z - (nodes[i * 3 + 2] ?? 0)
          const d = ex * ex + ey * ey + ez * ez
          if (d < bestD) {
            bestD = d
            best = i
          }
        }
        dx = nodeDisp[best * 3] ?? 0
        dy = nodeDisp[best * 3 + 1] ?? 0
        dz = nodeDisp[best * 3 + 2] ?? 0
      } else {
        const ax = (nodes[ib * 3] ?? 0) - (nodes[ia * 3] ?? 0)
        const ay = (nodes[ib * 3 + 1] ?? 0) - (nodes[ia * 3 + 1] ?? 0)
        const az = (nodes[ib * 3 + 2] ?? 0) - (nodes[ia * 3 + 2] ?? 0)
        const len2 = ax * ax + ay * ay + az * az
        let s = 0
        if (len2 > 0) {
          s = ((x - (nodes[ia * 3] ?? 0)) * ax + (y - (nodes[ia * 3 + 1] ?? 0)) * ay + (z - (nodes[ia * 3 + 2] ?? 0)) * az) / len2
          s = Math.min(1, Math.max(0, s))
        }
        if (curved && motion.localDof !== undefined && motion.lcs !== undefined &&
            loadRow !== undefined && e * 12 + 12 <= motion.localDof.length) {
          const d = displacementAt(motion.localDof, motion.lcs, e, s, Math.sqrt(len2), loadRow, particular, stations)
          dx = d.x
          dy = d.y
          dz = d.z
        } else {
          dx = (1 - s) * (nodeDisp[ia * 3] ?? 0) + s * (nodeDisp[ib * 3] ?? 0)
          dy = (1 - s) * (nodeDisp[ia * 3 + 1] ?? 0) + s * (nodeDisp[ib * 3 + 1] ?? 0)
          dz = (1 - s) * (nodeDisp[ia * 3 + 2] ?? 0) + s * (nodeDisp[ib * 3 + 2] ?? 0)
        }
      }
      disp[v * 3] = dx
      disp[v * 3 + 1] = dy
      disp[v * 3 + 2] = dz
      written[v] = 1
    }
  }
  return disp
}

/** Node motion used to deflect member solids with the same slider as the sticks. */
export interface MemberSolidMotion {
  nodePosition: Float32Array
  nodeDisplacement: Float32Array
  elementNodes: Uint32Array
  /** Shared with the frame, so the deflection slider moves the solids too. */
  scale: { value: number }
  /** Solved local DOF, 12 per frame element, same layout as the stick shader. */
  localDof?: Float32Array
  /** Element axes, 9 per frame element, already Y-up. */
  lcs?: Float32Array
  /** Particular-solution row of each element, or -1 when the element has none. */
  loadRow?: Int32Array
  particular?: Float32Array
  stations?: number
}

/**
 * Sized member solids from `member_solid_*` (already Y-up).
 * `userData.owner` holds the frame element of each triangle for picking.
 * Solid-head vertices follow the nearest node. Joist vertices follow their element.
 */
export function buildMemberSolids(
  position: Float32Array,
  faces: Uint32Array,
  owner: Uint32Array,
  sections: string[] = [],
  motion?: MemberSolidMotion,
): THREE.Mesh | null {
  if (faces.length === 0) return null
  if (faces.length !== owner.length * 3) throw new Error("member solid faces and owners have different counts")
  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute("position", new THREE.BufferAttribute(position, 3))
  geometry.setIndex(new THREE.BufferAttribute(faces, 1))
  geometry.computeBoundingBox()
  geometry.computeBoundingSphere()
  const keep = new Float32Array(position.length / 3)
  keep.fill(1)
  geometry.setAttribute("aKeep", new THREE.BufferAttribute(keep, 1))
  geometry.setAttribute("aDisp", new THREE.BufferAttribute(memberSolidDisp(position, faces, owner, sections, motion), 3))
  const rib = new THREE.Color(theme.concrete)
  const head = new THREE.Color(theme.solidHead)
  const color = new Float32Array(position.length)
  for (let i = 0; i < position.length / 3; i++) {
    color[i * 3] = rib.r
    color[i * 3 + 1] = rib.g
    color[i * 3 + 2] = rib.b
  }
  for (let t = 0; t < owner.length; t++) {
    if ((sections[owner[t] ?? 0] ?? "") !== "solid head") continue
    for (let k = 0; k < 3; k++) {
      const vi = faces[t * 3 + k] ?? 0
      color[vi * 3] = head.r
      color[vi * 3 + 1] = head.g
      color[vi * 3 + 2] = head.b
    }
  }
  geometry.setAttribute("color", new THREE.BufferAttribute(color, 3))
  const material = new THREE.MeshLambertMaterial({
    color: 0xffffff,
    vertexColors: true,
    flatShading: true,
    side: THREE.DoubleSide,
  })
  const scale = motion?.scale
  material.onBeforeCompile = (shader: { vertexShader: string; fragmentShader: string; uniforms: Record<string, { value: number }> }) => {
    shader.uniforms.uScale = scale ?? { value: 0 }
    shader.vertexShader = shader.vertexShader
      .replace("#include <common>", "#include <common>\nattribute float aKeep;\nattribute vec3 aDisp;\nuniform float uScale;\nvarying float vKeep;")
      .replace("#include <begin_vertex>", "vec3 transformed = vec3(position) + uScale * aDisp;\nvKeep = aKeep;")
    shader.fragmentShader = shader.fragmentShader
      .replace("#include <common>", "#include <common>\nvarying float vKeep;")
      .replace("#include <dithering_fragment>", "gl_FragColor.rgb = mix(vec3(0.78431, 0.78431, 0.76863), gl_FragColor.rgb, clamp(vKeep, 0.0, 1.0));\n#include <dithering_fragment>")
  }
  const mesh = new THREE.Mesh(geometry, material)
  mesh.userData = { role: "member-solid", owner }
  return mesh
}

/**
 * One color per shell triangle. Vertices are copied so neighboring faces do
 * not share a stress. Positions are already Y-up.
 */
export function buildStressMesh(position: Float32Array, faces: Uint32Array, stress: Float32Array, scale: number): THREE.Mesh | null {
  const triangles = stress.length
  if (triangles === 0 || faces.length !== triangles * 3) return null
  const verts = new Float32Array(triangles * 9)
  const color = new Float32Array(triangles * 9)
  const sample = new THREE.Color()
  for (let t = 0; t < triangles; t++) {
    stressColor(stress[t] ?? 0, scale, sample)
    for (let k = 0; k < 3; k++) {
      const vi = faces[t * 3 + k] ?? 0
      const o = (t * 3 + k) * 3
      verts[o] = position[vi * 3] ?? 0
      verts[o + 1] = position[vi * 3 + 1] ?? 0
      verts[o + 2] = position[vi * 3 + 2] ?? 0
      color[o] = sample.r
      color[o + 1] = sample.g
      color[o + 2] = sample.b
    }
  }
  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute("position", new THREE.BufferAttribute(verts, 3))
  geometry.setAttribute("color", new THREE.BufferAttribute(color, 3))
  const material = new THREE.MeshBasicMaterial({
    vertexColors: true,
    side: THREE.DoubleSide,
    polygonOffset: true,
    polygonOffsetFactor: -1,
    polygonOffsetUnits: -1,
  })
  const mesh = new THREE.Mesh(geometry, material)
  mesh.userData = { role: "stress" }
  mesh.frustumCulled = false
  mesh.visible = false
  mesh.raycast = () => {}
  return mesh
}

/** Column, beam, and wall tributary loops, already Y-up. Color is the support kind. */
export function buildTributary(
  position: Float32Array,
  counts: Uint32Array,
  kinds: Uint8Array,
  elements: Uint32Array,
): THREE.Group | null {
  if (counts.length === 0 || kinds.length !== counts.length || elements.length !== counts.length) return null
  const group = new THREE.Group()
  group.position.y = 0.02
  group.visible = false
  group.userData = { role: "tributary" }
  const kindColor = [theme.cerulean, theme.gold, theme.iris]
  const materials = new Map<number, THREE.MeshBasicMaterial>()
  const lineMaterial = new THREE.LineBasicMaterial({
    color: "#ffffff",
    transparent: true,
    opacity: 0.9,
    depthWrite: false,
  })
  const materialFor = (kind: number) => {
    const key = kind === 1 || kind === 2 ? kind : 0
    const existing = materials.get(key)
    if (existing) return existing
    const material = new THREE.MeshBasicMaterial({
      color: kindColor[key],
      transparent: true,
      opacity: 0.55,
      depthWrite: false,
      side: THREE.DoubleSide,
    })
    materials.set(key, material)
    return material
  }
  const discard = () => {
    group.traverse((obj: THREE.Object3D) => {
      const mesh = obj as THREE.Mesh
      mesh.geometry?.dispose()
    })
    for (const material of materials.values()) material.dispose()
    lineMaterial.dispose()
  }
  let cursor = 0
  for (let p = 0; p < counts.length; p++) {
    const n = counts[p] ?? 0
    if (n < 3 || (cursor + n) * 3 > position.length) {
      discard()
      throw new Error("tributary polygon overruns its vertices")
    }
    const y = position[cursor * 3 + 1] ?? 0
    const ring: [number, number][] = []
    for (let i = 0; i < n; i++) {
      ring.push([position[(cursor + i) * 3] ?? 0, position[(cursor + i) * 3 + 2] ?? 0])
    }
    cursor += n
    const kind = kinds[p] ?? 0
    const shape = new THREE.Shape()
    ring.forEach(([x, z], i) => (i === 0 ? shape.moveTo(x, -z) : shape.lineTo(x, -z)))
    const geometry = new THREE.ShapeGeometry(shape)
    geometry.rotateX(-Math.PI / 2)
    geometry.translate(0, y, 0)
    const mesh = new THREE.Mesh(geometry, materialFor(kind))
    mesh.userData = { elevation: y }
    mesh.raycast = () => {}
    const loop = new Float32Array(ring.length * 3)
    ring.forEach(([x, z], i) => {
      loop[i * 3] = x
      loop[i * 3 + 1] = y + 0.01
      loop[i * 3 + 2] = z
    })
    const outline = new THREE.LineLoop(new THREE.BufferGeometry().setAttribute("position", new THREE.BufferAttribute(loop, 3)), lineMaterial)
    outline.raycast = () => {}
    mesh.add(outline)
    group.add(mesh)
  }
  if (cursor * 3 !== position.length) {
    discard()
    throw new Error("tributary vertices do not match the polygon counts")
  }
  return group
}

/**
 * Slab and wall solids. Each triangle is extruded half its thickness to each
 * side of its analysis surface, as the shell is modelled. Positions are
 * already Y-up.
 */
export function buildShellVolumes(
  position: Float32Array,
  faces: Uint32Array,
  kinds: Uint8Array,
  thickness: Float32Array,
  skip: Set<number> | null = null,
): THREE.Mesh | null {
  if (thickness.length === 0 || faces.length !== thickness.length * 3) return null
  const verts: number[] = []
  const index: number[] = []
  const source: number[] = []
  const vertexSource: number[] = []
  const a = [0, 0, 0]
  const b = [0, 0, 0]
  const c = [0, 0, 0]
  for (let t = 0; t < thickness.length; t++) {
    if (skip?.has(t)) continue
    const h = thickness[t]
    if (!(h > 0)) continue
    read3(position, faces[t * 3], a)
    read3(position, faces[t * 3 + 1], b)
    read3(position, faces[t * 3 + 2], c)
    const e1x = b[0] - a[0], e1y = b[1] - a[1], e1z = b[2] - a[2]
    const e2x = c[0] - a[0], e2y = c[1] - a[1], e2z = c[2] - a[2]
    let nx = e1y * e2z - e1z * e2y
    let ny = e1z * e2x - e1x * e2z
    let nz = e1x * e2y - e1y * e2x
    const len = Math.hypot(nx, ny, nz)
    if (len < 1e-9) continue
    const low = -h / 2
    const high = h / 2
    const inv = (ny < 0 ? -1 : 1) / len
    nx *= inv; ny *= inv; nz *= inv
    const base = verts.length / 3
    for (const p of [a, b, c]) verts.push(p[0] + nx * low, p[1] + ny * low, p[2] + nz * low)
    for (const p of [a, b, c]) verts.push(p[0] + nx * high, p[1] + ny * high, p[2] + nz * high)
    for (let n = 0; n < 6; n++) vertexSource.push(t)
    const before = index.length
    index.push(base, base + 2, base + 1, base + 3, base + 4, base + 5)
    for (const [i, j, k, m] of [[0, 1, 4, 3], [1, 2, 5, 4], [2, 0, 3, 5]]) {
      index.push(base + i, base + j, base + k, base + i, base + k, base + m)
    }
    for (let n = (index.length - before) / 3; n > 0; n--) source.push(t)
  }
  if (index.length === 0) return null
  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute("position", new THREE.BufferAttribute(new Float32Array(verts), 3))
  geometry.setIndex(index)
  geometry.computeVertexNormals()
  const keep = new Float32Array(verts.length / 3)
  keep.fill(1)
  geometry.setAttribute("aKeep", new THREE.BufferAttribute(keep, 1))
  const color = new Float32Array(verts.length)
  const slab = new THREE.Color(theme.slab)
  for (let i = 0; i < color.length; i += 3) {
    color[i] = slab.r
    color[i + 1] = slab.g
    color[i + 2] = slab.b
  }
  geometry.setAttribute("color", new THREE.BufferAttribute(color, 3))
  const material = new THREE.MeshLambertMaterial({
    color: "#ffffff",
    vertexColors: true,
    side: THREE.DoubleSide,
  })
  material.onBeforeCompile = (shader: { vertexShader: string; fragmentShader: string }) => {
    shader.vertexShader = shader.vertexShader
      .replace("#include <common>", "#include <common>\nattribute float aKeep;\nvarying float vKeep;")
      .replace("#include <begin_vertex>", "vec3 transformed = vec3(position);\nvKeep = aKeep;")
    shader.fragmentShader = shader.fragmentShader
      .replace("#include <common>", "#include <common>\nvarying float vKeep;")
      .replace("#include <dithering_fragment>", "gl_FragColor.rgb = mix(vec3(0.78431, 0.78431, 0.76863), gl_FragColor.rgb, clamp(vKeep, 0.0, 1.0));\n#include <dithering_fragment>")
  }
  const mesh = new THREE.Mesh(geometry, material)
  mesh.userData = {
    role: "shell-volume",
    source: new Uint32Array(source),
    vertexSource: new Uint32Array(vertexSource),
    faces,
    kinds,
    // Analysis hides this mesh. The section fill still cuts the walls.
    sectionWhenHidden: true,
  }
  return mesh
}

/**
 * Drop each horizontal beam solid until it meets the slab soffit.
 *
 * The analysis node stays on the shell mid-plane. A section drawn about that
 * node runs through the slab, so this shifts only the picture. A steel shape
 * and a rectangular beam seat on the top fiber. A concrete T's wide top is the
 * effective flange, not the slab: that band is folded into the stem, and the
 * stem then hangs from the soffit. The shell volume is the sized slab. A solid
 * head is the same cast, so its top moves to the slab top and the rest hangs
 * below. A solid already seated, and a column, stay where they are. With no
 * slab shell the flange stays, because it is the only plate in the picture.
 */
export function seatBeamsUnderSlab(
  solids: Float32Array,
  faces: Uint32Array,
  owner: Uint32Array,
  sections: string[],
  elementNodes: Uint32Array,
  elementType: Uint8Array,
  nodePosition: Float32Array,
  shellPosition: Float32Array,
  shellFaces: Uint32Array,
  shellKinds: Uint8Array,
  shellThickness: Float32Array,
) {
  const nElem = elementType.length
  if (nElem === 0 || owner.length === 0 || shellThickness.length === 0) return
  const top = new Float32Array(nElem)
  top.fill(-Infinity)
  const vertexElement = new Int32Array(solids.length / 3)
  vertexElement.fill(-1)
  for (let t = 0; t < owner.length; t++) {
    const element = owner[t] ?? 0
    if (element >= nElem) continue
    for (let k = 0; k < 3; k++) {
      const vertex = faces[t * 3 + k] ?? 0
      if (vertexElement[vertex] < 0) vertexElement[vertex] = element
      const y = solids[vertex * 3 + 1] ?? 0
      if (y > top[element]) top[element] = y
    }
  }
  const shift = new Float32Array(nElem)
  const nTri = Math.min(shellThickness.length, shellKinds.length, shellFaces.length / 3)
  for (let element = 0; element < nElem; element++) {
    if ((elementType[element] ?? TYPE_COLUMN) !== TYPE_BEAM) continue
    if (!(top[element] > -1e8)) continue
    const ia = elementNodes[element * 2] ?? 0
    const ib = elementNodes[element * 2 + 1] ?? 0
    const ax = nodePosition[ia * 3] ?? 0
    const ay = nodePosition[ia * 3 + 1] ?? 0
    const az = nodePosition[ia * 3 + 2] ?? 0
    const bx = nodePosition[ib * 3] ?? 0
    const by = nodePosition[ib * 3 + 1] ?? 0
    const bz = nodePosition[ib * 3 + 2] ?? 0
    const len = Math.hypot(bx - ax, by - ay, bz - az)
    if (!(len > 1e-4) || Math.abs(by - ay) / len > 0.2) continue
    const mx = (ax + bx) / 2
    const my = (ay + by) / 2
    const mz = (az + bz) / 2
    let nearest = Infinity
    let thickness = 0
    let shellY = my
    for (let t = 0; t < nTri; t++) {
      if ((shellKinds[t] ?? 0) === KIND_WALL) continue
      const h = shellThickness[t] ?? 0
      if (!(h > 0)) continue
      const c = triCenter(shellPosition, shellFaces, t)
      if (Math.abs(c[1] - my) > 0.25) continue
      const d = Math.hypot(c[0] - mx, c[2] - mz)
      if (d < nearest) {
        nearest = d
        thickness = h
        shellY = c[1]
      }
    }
    if (!(nearest < 8 && thickness > 0)) continue
    // The head is cast with the slab. Its top is the slab top, not the
    // rib centroid the prism was drawn around.
    if ((sections[element] ?? "") === "solid head") {
      const slabTop = shellY + thickness / 2
      if (Math.abs(top[element] - slabTop) > 1e-3) shift[element] = slabTop - top[element]
      continue
    }
    const soffit = my - thickness / 2
    const axis = { ax, az, bx, bz }
    const stemTop = dropFlange(solids, vertexElement, element, axis, top[element])
    const fiber = stemTop ?? soffitFiber(solids, vertexElement, element, ax, az, bx, bz, top[element])
    if (!(fiber > soffit + 1e-3)) continue
    shift[element] = soffit - fiber
  }
  for (let vertex = 0; vertex < vertexElement.length; vertex++) {
    const element = vertexElement[vertex]
    if (element < 0) continue
    const drop = shift[element] ?? 0
    if (drop === 0) continue
    solids[vertex * 3 + 1] += drop
  }
}

type MemberAxis = { ax: number; az: number; bx: number; bz: number }

/** Plan distance from the member axis. The section's width is twice this. */
function planReach(x: number, z: number, axis: MemberAxis): number {
  const dx = axis.bx - axis.ax
  const dz = axis.bz - axis.az
  const len2 = dx * dx + dz * dz
  if (!(len2 > 1e-8)) return Math.hypot(x - axis.ax, z - axis.az)
  const t = ((x - axis.ax) * dx + (z - axis.az) * dz) / len2
  return Math.hypot(x - (axis.ax + t * dx), z - (axis.az + t * dz))
}

/**
 * Wide at the top only: a concrete T. An I-beam is wide at the bottom too,
 * and a rectangle is one width. The stem is the narrow bottom. The flange
 * shoulder often sits at mid-height, so the middle of the solid is not the stem.
 */
function teeShoulder(
  solids: Float32Array,
  ids: number[],
  axis: MemberAxis,
  top: number,
  yBot: number,
): { shoulder: number; stem: number } | null {
  const depth = top - yBot
  if (!(depth > 1e-4) || ids.length === 0) return null
  const band = (y0: number, y1: number) => {
    let width = 0
    for (const vertex of ids) {
      const y = solids[vertex * 3 + 1] ?? 0
      if (y < y0 || y > y1) continue
      width = Math.max(width, planReach(solids[vertex * 3] ?? 0, solids[vertex * 3 + 2] ?? 0, axis))
    }
    return width
  }
  const topW = band(top - depth * 0.2, top + 1e-6)
  const botW = band(yBot - 1e-6, yBot + depth * 0.2)
  if (!(topW > botW * 1.35 && botW > 0)) return null
  let shoulder = top
  const limit = botW * 1.2
  for (const vertex of ids) {
    if (planReach(solids[vertex * 3] ?? 0, solids[vertex * 3 + 2] ?? 0, axis) <= limit) continue
    const y = solids[vertex * 3 + 1] ?? 0
    if (y < shoulder) shoulder = y
  }
  return { shoulder, stem: botW }
}

function elementVertexIds(vertexElement: Int32Array, element: number): number[] {
  const ids: number[] = []
  for (let vertex = 0; vertex < vertexElement.length; vertex++) {
    if (vertexElement[vertex] === element) ids.push(vertex)
  }
  return ids
}

/**
 * Fold a concrete T's flange back to the stem.
 *
 * The wide top is the effective flange used in flexure. The sized slab is the
 * shell, so the solid keeps the stem only: overhanging vertices move in to the
 * stem face and down to the shoulder, which is the top of the stem. Returns
 * that shoulder, or null when the solid is not a T.
 */
function dropFlange(
  solids: Float32Array,
  vertexElement: Int32Array,
  element: number,
  axis: MemberAxis,
  top: number,
): number | null {
  let yBot = Infinity
  const ids = elementVertexIds(vertexElement, element)
  for (const vertex of ids) {
    const y = solids[vertex * 3 + 1] ?? 0
    if (y < yBot) yBot = y
  }
  const tee = teeShoulder(solids, ids, axis, top, yBot)
  if (!tee) return null
  const dx = axis.bx - axis.ax
  const dz = axis.bz - axis.az
  const len2 = dx * dx + dz * dz
  const limit = tee.stem * 1.2
  for (const vertex of ids) {
    const x = solids[vertex * 3] ?? 0
    const z = solids[vertex * 3 + 2] ?? 0
    const reach = planReach(x, z, axis)
    if (reach <= limit) continue
    let px = axis.ax
    let pz = axis.az
    if (len2 > 1e-8) {
      const t = ((x - axis.ax) * dx + (z - axis.az) * dz) / len2
      px = axis.ax + t * dx
      pz = axis.az + t * dz
    }
    const scale = tee.stem / reach
    solids[vertex * 3] = px + (x - px) * scale
    solids[vertex * 3 + 1] = tee.shoulder
    solids[vertex * 3 + 2] = pz + (z - pz) * scale
  }
  return tee.shoulder
}

/**
 * The fiber that lands on the soffit.
 *
 * A concrete T is wide at the top and narrow below. That wide band is the
 * flange, and its bottom is the top of the stem. An I-beam is wide at the
 * bottom as well, and a rectangle is one width, so those seat on the top fiber.
 */
function soffitFiber(
  solids: Float32Array,
  vertexElement: Int32Array,
  element: number,
  ax: number, az: number, bx: number, bz: number,
  top: number,
): number {
  let yBot = Infinity
  const ids = elementVertexIds(vertexElement, element)
  for (const vertex of ids) {
    const y = solids[vertex * 3 + 1] ?? 0
    if (y < yBot) yBot = y
  }
  const tee = teeShoulder(solids, ids, { ax, az, bx, bz }, top, yBot)
  return tee ? tee.shoulder : top
}

function triCenter(position: Float32Array, faces: Uint32Array, triangle: number): [number, number, number] {
  let x = 0, y = 0, z = 0
  for (let k = 0; k < 3; k++) {
    const id = faces[triangle * 3 + k] ?? 0
    x += position[id * 3] ?? 0
    y += position[id * 3 + 1] ?? 0
    z += position[id * 3 + 2] ?? 0
  }
  return [x / 3, y / 3, z / 3]
}

function read3(src: Float32Array, index: number, out: number[]) {
  out[0] = src[index * 3]
  out[1] = src[index * 3 + 1]
  out[2] = src[index * 3 + 2]
}

function buildFootings(center: Float32Array, size: Float32Array): THREE.InstancedMesh | null {
  const count = center.length / 3
  if (count === 0) return null
  if (size.length !== center.length) throw new Error("footing centers and sizes have different lengths")
  const geometry = new THREE.BoxGeometry(1, 1, 1)
  const keep = new Float32Array(count)
  keep.fill(1)
  geometry.setAttribute("aKeep", new THREE.InstancedBufferAttribute(keep, 1))
  // Instance color carries the concrete or the deflection scale. White leaves that color unchanged.
  // aKeep mixes the lit color toward the same flat grey as slabs and columns.
  const material = new THREE.MeshLambertMaterial({ color: "#ffffff" })
  material.onBeforeCompile = (shader: { vertexShader: string; fragmentShader: string }) => {
    shader.vertexShader = shader.vertexShader
      .replace("#include <common>", "#include <common>\nattribute float aKeep;\nvarying float vKeep;")
      .replace("#include <begin_vertex>", "vec3 transformed = vec3(position);\nvKeep = aKeep;")
    shader.fragmentShader = shader.fragmentShader
      .replace("#include <common>", "#include <common>\nvarying float vKeep;")
      .replace("#include <dithering_fragment>", "gl_FragColor.rgb = mix(vec3(0.78431, 0.78431, 0.76863), gl_FragColor.rgb, clamp(vKeep, 0.0, 1.0));\n#include <dithering_fragment>")
  }
  const mesh = new THREE.InstancedMesh(geometry, material, count)
  mesh.userData = { role: "footing" }
  const matrix = new THREE.Matrix4()
  const translation = new THREE.Vector3()
  const quaternion = new THREE.Quaternion()
  const scale = new THREE.Vector3()
  for (let i = 0; i < count; i++) {
    translation.set(center[i * 3], center[i * 3 + 1], center[i * 3 + 2])
    scale.set(size[i * 3], size[i * 3 + 1], size[i * 3 + 2])
    matrix.compose(translation, quaternion, scale)
    mesh.setMatrixAt(i, matrix)
    mesh.setColorAt(i, new THREE.Color(theme.concrete))
  }
  mesh.instanceMatrix.needsUpdate = true
  if (mesh.instanceColor) mesh.instanceColor.needsUpdate = true
  mesh.computeBoundingBox()
  return mesh
}
