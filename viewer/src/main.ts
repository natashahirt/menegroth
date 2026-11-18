import * as THREE from "three"
import { LineSegments2 } from "three/addons/lines/LineSegments2.js"
import { LineSegmentsGeometry } from "three/addons/lines/LineSegmentsGeometry.js"
import { LineMaterial } from "three/addons/lines/LineMaterial.js"
import CameraControls from "camera-controls"
import theme from "./theme.json"
import { assembleVariant, variantNeighbors, type DecodedScene, type SceneHeader, type SceneVariant, type VariantFile } from "./decode"
import { buildFrame, type FrameView } from "./frame"
import { buildGlyphs, type GlyphSet } from "./glyphs"
import { buildBuilding, buildMemberSolids, buildShellVolumes, buildStressMesh, buildTributary, CATEGORY_COLOR, deflectionColor, memberCategory, omittedMembers, seatBeamsUnderSlab, shellCategory, SHELL_KIND_NAME, utilizationColor, withoutOmittedSolids, type BuildingParts } from "./building"
import { applyDimensionCuts, buildDimensions, disposeDimensions, type DimensionGroups, type DimensionView } from "./dimensions"
import { matchFooting, matchFrame, matchShell, matchWall, readComponents, renderDetail, type ComponentRecord } from "./detail"
import type { OverlayMode, OverlayScene } from "./detail-overlay"
import { SectionHatch } from "./section"
import { analysisCut } from "./cut-lines"
import { buildDeckSolids, type DeckFloor } from "./deck"
import { conformSlabToFrame, expandTriangles, grillageSlab, type SlabSheet } from "./shell-mesh"

CameraControls.install({ THREE })

const canvas = document.querySelector("canvas") as HTMLCanvasElement
const statusEl = document.querySelector("#status") as HTMLElement
const infoEl = document.querySelector("#info") as HTMLElement
const scaleInput = document.querySelector("#scale") as HTMLInputElement
const scaleLabel = document.querySelector("#scale-label") as HTMLElement
const colorInput = document.querySelector("#color-mode") as HTMLInputElement
const ghostInput = document.querySelector("#ghost") as HTMLInputElement
const loadsInput = document.querySelector("#loads") as HTMLInputElement
const dimensionsInput = document.querySelector("#dimensions") as HTMLInputElement
const animateInput = document.querySelector("#animate") as HTMLInputElement
const cutXInput = document.querySelector("#cut-x") as HTMLInputElement
const cutZInput = document.querySelector("#cut-z") as HTMLInputElement
const cutXLabel = document.querySelector("#cut-x-label") as HTMLElement
const cutZLabel = document.querySelector("#cut-z-label") as HTMLElement

/** Keep the origin side of each plane. X is plan, Z is up (three.js Y). */
const clipX = new THREE.Plane(new THREE.Vector3(-1, 0, 0), 1e6)
const clipZ = new THREE.Plane(new THREE.Vector3(0, -1, 0), 1e6)
const clipPlanes = [clipX, clipZ]
const legendEl = document.querySelector("#legend") as HTMLElement
const legendMin = document.querySelector("#legend-min") as HTMLElement
const legendMax = document.querySelector("#legend-max") as HTMLElement
const legendCaption = document.querySelector("#legend-caption") as HTMLElement
const detailEl = document.querySelector("#detail") as HTMLElement
const detailTitle = document.querySelector("#detail-title") as HTMLElement
const detailFacts = document.querySelector("#detail-facts") as HTMLElement

type ViewMode = "geometry" | "analysis"
type GeometryVariant = "sized" | "categories" | "initialization"
type AnalysisVariant = "deflection" | "utilization" | "stress" | "axial" | "tributary"
let mode: ViewMode = "geometry"
let geometryVariant: GeometryVariant = "sized"
let analysisVariant: AnalysisVariant = "deflection"
const fieldNote = document.querySelector("#field-note") as HTMLElement
const VARIANT_LABEL: Record<GeometryVariant | AnalysisVariant, string> = {
  sized: "Sized",
  categories: "Categories",
  initialization: "Initialization",
  deflection: "Deflection",
  utilization: "Utilization",
  stress: "Stress",
  axial: "Axial loads",
  tributary: "Tributary areas",
}
const ABSENT_FIELD: Partial<Record<AnalysisVariant, string>> = {
  utilization: "Utilization is not in this scene.",
  stress: "Stress is not in this scene.",
  axial: "Axial loads are not in this scene.",
  tributary: "Tributary areas are not in this scene.",
}
const CATEGORY_NOTE = "Columns are blue. Beams are gold. Braces are pink. Slabs are green. Walls are purple. Footings are light blue."
const fileInput = document.querySelector("#file") as HTMLInputElement

const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true, stencil: true })
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2))
renderer.outputColorSpace = THREE.SRGBColorSpace
renderer.setClearColor(theme.background, 1)
renderer.localClippingEnabled = true
// Two passes per frame (scene, axes gizmo); stats cover both.
renderer.info.autoReset = false

const scene = new THREE.Scene()
scene.background = new THREE.Color(theme.background)
scene.add(new THREE.HemisphereLight(0xffffff, 0xd8d4cc, 1.05))
scene.add(new THREE.DirectionalLight(0xffffff, 0.55))

/** Screen-pixel width of the corner pluses and the section lines. The cut rectangle is a dotted hairline. */
const CUT_STROKE_PX = 2
/** Dot and gap of the cut rectangle, in screen pixels. */
const CUT_DOT_PX = 1.5
const CUT_GAP_PX = 3.5

const cutXMarks = cutCrosses(0x000000)
const cutZMarks = cutCrosses(0x000000)
const cutXFrame = cutFrame()
const cutZFrame = cutFrame()
const cutLineX = cutInk()
const cutLineZ = cutInk()
// Each cut line stops at the other plane. Its own plane would erase it.
;(cutLineX.material as THREE.Material).clippingPlanes = [clipZ]
;(cutLineZ.material as THREE.Material).clippingPlanes = [clipX]
scene.add(cutXFrame, cutZFrame, cutXMarks, cutZMarks, cutLineX, cutLineZ)
const sectionHatch = new SectionHatch(clipX, clipZ)
scene.add(sectionHatch.group)

// Vertical field of a 50 mm lens. Fit backs the camera up so the building still
// fills the frame, and the near corner stays close in size to the far one.
const camera = new THREE.PerspectiveCamera(27, 1, 0.01, 5000)
const ortho = new THREE.OrthographicCamera(-1, 1, 1, -1, 0.01, 5000)
let activeCamera: THREE.PerspectiveCamera | THREE.OrthographicCamera = camera
let controls = makeControls(camera)

const axesScene = new THREE.Scene()
axesScene.add(new THREE.AxesHelper(1.2))
const axesCamera = new THREE.PerspectiveCamera(50, 1, 0.1, 10)

const pickTarget = new THREE.WebGLRenderTarget(1, 1, {
  type: THREE.UnsignedByteType,
  format: THREE.RGBAFormat,
  minFilter: THREE.NearestFilter,
  magFilter: THREE.NearestFilter,
  colorSpace: THREE.NoColorSpace,
})
const pickPixel = new Uint8Array(4)

const clock = new THREE.Clock()
let frameView: FrameView | null = null
let glyphGroup: THREE.Group | null = null
let glyphs: GlyphSet | null = null
let building: BuildingParts | null = null
let grid: THREE.GridHelper | null = null
let header: SceneHeader | null = null
let baseScale = 1
let moving = false
let modelBounds = new THREE.Box3()
let nodePosition = new Float32Array()
let nodeDisplacement = new Float32Array()
let elementNodes = new Uint32Array()
let elementType = new Uint8Array()
let memberSolids: THREE.Mesh | null = null
let shellVolumes: THREE.Mesh | null = null
let deckGroup: THREE.Group | null = null
let stressMesh: THREE.Mesh | null = null
let tributaryGroup: THREE.Group | null = null
let elementAxial = new Float32Array()
let elementRatio = new Float32Array()
let footingRatio = new Float32Array()
let hasUtilization = false
let utilizationPeak = 0
let memberBase: Float32Array | null = null
let memberCategoryColors: Float32Array | null = null
let volumeBase: Float32Array | null = null
let volumeCategory: Float32Array | null = null
let shellNodeBase: Float32Array | null = null
let shellNodeUtilization: Float32Array | null = null
let maxAxial = 0
let maxStress = 0
let shellAxialPresent = false
let dimensions: DimensionGroups | null = null
let dimensionView: DimensionView = "ground"
let elementSection: string[] = []
let shellFaces = new Uint32Array()
let shellKinds = new Uint8Array()
let shellStress = new Float32Array()
let shellAxial = new Float32Array()
/** `struc.walls` index of each shell triangle (the wall record's design_index), 0 off a wall. Empty in older scenes. */
let shellWall = new Uint32Array()
let stressPresent = false
let tributaryPosition = new Float32Array()
let tributaryCount = new Uint32Array()
let tributaryKind = new Uint8Array()
let tributaryElement = new Uint32Array()
let tributaryCell = new Uint32Array()
let tributaryPresent = false
let localDof = new Float32Array()
let elementLcs = new Float32Array()
let loadElementIndex = new Uint32Array()
let loadParticular = new Float32Array()
let solvedStations = 0
let displacementPresent = false
let componentRecords: ComponentRecord[] = []
const outline = new THREE.Group()
outline.name = "selection-outline"
scene.add(outline)
let footingCenter = new Float32Array()
let footingSize = new Float32Array()
let footingKind = new Uint8Array()
let footingNodes: number[][] = []
let footingDisp = new Float32Array()
let supportIndex = new Uint32Array()
let supportFixity = new Uint8Array()
const raycaster = new THREE.Raycaster()
const ndc = new THREE.Vector2()
let orthoOn = false
let renderDirty = true

function makeControls(cam: THREE.PerspectiveCamera | THREE.OrthographicCamera) {
  const next = new CameraControls(cam, canvas)
  next.smoothTime = 0.22
  // Dragging follows the pointer. A damped drag reads as the view lagging the spin.
  next.draggingSmoothTime = 0
  next.dollyToCursor = true
  next.infinityDolly = false
  next.azimuthRotateSpeed = 1
  next.polarRotateSpeed = 1
  next.mouseButtons.left = CameraControls.ACTION.ROTATE
  next.mouseButtons.right = CameraControls.ACTION.TRUCK
  next.mouseButtons.wheel = CameraControls.ACTION.DOLLY
  next.mouseButtons.middle = CameraControls.ACTION.TRUCK
  next.touches.one = CameraControls.ACTION.TOUCH_ROTATE
  next.touches.two = CameraControls.ACTION.TOUCH_DOLLY_TRUCK
  next.addEventListener("controlstart", () => {
    moving = true
    setOrbitDetail(true)
  })
  next.addEventListener("controlend", () => {
    window.setTimeout(() => {
      moving = false
      setOrbitDetail(false)
      renderDirty = true
    }, 150)
  })
  next.addEventListener("update", () => { renderDirty = true })
  // The URL is written once the camera settles. Writing it every frame trips
  // the browser's history.replaceState throttle and stalls the orbit.
  next.addEventListener("rest", writeCameraHash)
  next.addEventListener("sleep", writeCameraHash)
  return next
}

function resize() {
  const width = canvas.clientWidth
  const height = canvas.clientHeight
  renderer.setSize(width, height, false)
  camera.aspect = width / Math.max(height, 1)
  camera.updateProjectionMatrix()
  syncOrthoFrustum()
  renderDirty = true
}

function syncOrthoFrustum() {
  const target = new THREE.Vector3()
  controls.getTarget(target)
  const dist = Math.max(activeCamera.position.distanceTo(target), 0.1)
  const height = dist * Math.tan(THREE.MathUtils.degToRad(camera.fov / 2)) * 2
  const aspect = canvas.clientWidth / Math.max(canvas.clientHeight, 1)
  ortho.top = height / 2
  ortho.bottom = -height / 2
  ortho.left = -ortho.top * aspect
  ortho.right = ortho.top * aspect
  ortho.updateProjectionMatrix()
}

function setStatus(text: string) {
  statusEl.textContent = text
}

/**
 * A stroke wider than a WebGL line. The platform draws `linewidth` of 1 as a
 * single pixel, so these are meshes in screen space.
 */
function cutStroke(color: number, opacity = 1): LineSegments2 {
  const material = new LineMaterial({
    color: new THREE.Color(color),
    linewidth: CUT_STROKE_PX,
    transparent: opacity < 1,
    opacity,
    toneMapped: false,
    depthTest: false,
    depthWrite: false,
    worldUnits: false,
  })
  const lines = new LineSegments2(new LineSegmentsGeometry(), material)
  lines.userData.noclip = true
  lines.frustumCulled = false
  lines.visible = false
  lines.renderOrder = 3
  lines.raycast = () => {}
  return lines
}

/** Four corner pluses for one cut rectangle. Not clipped, and not pickable. */
function cutCrosses(color: number): LineSegments2 {
  return cutStroke(color)
}

/** Dotted hairline around the cut rectangle. The pluses and the section stay solid. */
function cutFrame(): LineSegments2 {
  const lines = cutStroke(new THREE.Color(theme.charcoal).getHex())
  const material = lines.material as LineMaterial
  material.linewidth = 1
  material.dashed = true
  material.dashSize = CUT_DOT_PX
  material.gapSize = CUT_GAP_PX
  lines.renderOrder = 2
  return lines
}

/** Keep the rectangle's dots a constant size on screen. Dash distances are world lengths. */
function syncCutDots(target: THREE.Vector3) {
  const height = Math.max(canvas.clientHeight, 1)
  const worldPerPixel = orthoOn
    ? (ortho.top - ortho.bottom) / height
    : 2 * Math.tan(THREE.MathUtils.degToRad(camera.fov) / 2) * Math.max(camera.position.distanceTo(target), 0.1) / height
  const scale = 1 / Math.max(worldPerPixel, 1e-8)
  for (const lines of [cutXFrame, cutZFrame]) {
    ;(lines.material as LineMaterial).dashScale = scale
  }
}

/** Black intersection of an analysis cut with the shells and the frame. */
function cutInk(): LineSegments2 {
  const lines = cutStroke(0x000000)
  const material = lines.material as LineMaterial
  material.depthTest = true
  material.depthWrite = true
  material.polygonOffset = true
  material.polygonOffsetFactor = -4
  material.polygonOffsetUnits = -4
  lines.renderOrder = 4
  return lines
}

function setStroke(lines: LineSegments2, xyz: Float32Array) {
  const geometry = lines.geometry as LineSegmentsGeometry
  const empty = xyz.length < 6
  geometry.setPositions(empty ? new Float32Array(6) : xyz)
  lines.userData.empty = empty
  const material = lines.material as LineMaterial
  if (material.dashed) lines.computeLineDistances()
}

/** The four edges of the cut rectangle, in loop order. */
function writeCutFrame(lines: LineSegments2, loop: Array<[number, number, number]>) {
  const data = new Float32Array(loop.length * 6)
  let o = 0
  for (let i = 0; i < loop.length; i++) {
    const a = loop[i]
    const b = loop[(i + 1) % loop.length]
    data[o++] = a[0]
    data[o++] = a[1]
    data[o++] = a[2]
    data[o++] = b[0]
    data[o++] = b[1]
    data[o++] = b[2]
  }
  setStroke(lines, data)
}

/** A plus at each corner, along the two axes of the cut plane. */
function writeCornerPluses(
  lines: LineSegments2,
  corners: Array<[number, number, number]>,
  axisA: [number, number, number],
  axisB: [number, number, number],
  arm: number,
) {
  const data = new Float32Array(corners.length * 12)
  let o = 0
  for (const [x, y, z] of corners) {
    data[o++] = x - axisA[0] * arm
    data[o++] = y - axisA[1] * arm
    data[o++] = z - axisA[2] * arm
    data[o++] = x + axisA[0] * arm
    data[o++] = y + axisA[1] * arm
    data[o++] = z + axisA[2] * arm
    data[o++] = x - axisB[0] * arm
    data[o++] = y - axisB[1] * arm
    data[o++] = z - axisB[2] * arm
    data[o++] = x + axisB[0] * arm
    data[o++] = y + axisB[1] * arm
    data[o++] = z + axisB[2] * arm
  }
  setStroke(lines, data)
}

function clipMaterial(material: THREE.Material) {
  material.clippingPlanes = clipPlanes
  material.clipShadows = true
  material.needsUpdate = true
}

function bindClipping(root: THREE.Object3D) {
  root.traverse((obj: THREE.Object3D) => {
    if (obj.userData.noclip) return
    const material = (obj as THREE.Mesh).material as THREE.Material | THREE.Material[] | undefined
    if (!material) return
    for (const entry of Array.isArray(material) ? material : [material]) clipMaterial(entry)
  })
}

/** Colored analysis materials are not on a mesh until that mode is selected. */
function bindShellMaterials(parts: BuildingParts) {
  for (const kind of [0, 1, 2]) {
    clipMaterial(parts.solidFor(kind))
    clipMaterial(parts.mappedFor(kind))
  }
  for (const mesh of parts.ghosts) clipMaterial(mesh.material as THREE.Material)
}

/** How far past the building an idle cut sits, clear of slab thickness. */
function cutClearance(span: number) {
  return Math.max(1, span * 0.05)
}

/** Slider coordinate is the plane location. The maximum leaves the model whole. */
function paintRange(input: HTMLInputElement) {
  const min = Number(input.min)
  const max = Number(input.max)
  const span = max - min
  const pct = span > 0 ? ((Number(input.value) - min) / span) * 100 : 0
  input.style.setProperty("--fill", `${Math.min(100, Math.max(0, pct))}%`)
}

/** Corner mark, about 4.5% of the shorter cut edge. */
function crossArm(a: number, b: number) {
  return Math.min(1.1, Math.max(0.28, Math.min(Math.max(a, 0), Math.max(b, 0)) * 0.045))
}

/** Black cut lines, only while analysis mode is showing the unfilled shells. */
let cutLineKey = ""
let sceneSerial = 0

function syncAnalysisLines(x: number, z: number, xOn: boolean, zOn: boolean) {
  const analysis = mode === "analysis" && nodePosition.length > 0
  const key = `${sceneSerial}|${analysis}|${xOn}|${zOn}|${x.toFixed(4)}|${z.toFixed(4)}`
  if (key === cutLineKey) {
    cutLineX.visible = analysis && xOn && !cutLineX.userData.empty
    cutLineZ.visible = analysis && zOn && !cutLineZ.userData.empty
    return
  }
  cutLineKey = key
  if (analysis && xOn) {
    setStroke(cutLineX, analysisCut("x", x, nodePosition, shellFaces, elementNodes))
    cutLineX.visible = !cutLineX.userData.empty
  } else {
    cutLineX.visible = false
  }
  if (analysis && zOn) {
    setStroke(cutLineZ, analysisCut("y", z, nodePosition, shellFaces, elementNodes))
    cutLineZ.visible = !cutLineZ.userData.empty
  } else {
    cutLineZ.visible = false
  }
}

function syncCuts() {
  paintRange(cutXInput)
  paintRange(cutZInput)
  const box = modelBounds
  const ready = Number.isFinite(box.min.x) && Number.isFinite(box.max.x)
  const x = Number(cutXInput.value)
  const z = Number(cutZInput.value)
  const xOn = ready && x < box.max.x - 0.05
  const zOn = ready && z < box.max.y - 0.05
  clipX.constant = xOn ? x : 1e6
  clipZ.constant = zOn ? z : 1e6
  cutXLabel.textContent = xOn ? `${x.toFixed(2)} m` : "off"
  cutZLabel.textContent = zOn ? `${z.toFixed(2)} m` : "off"
  if (ready) {
    const size = box.getSize(new THREE.Vector3())
    const armX = crossArm(size.y, size.z)
    const armZ = crossArm(size.x, size.z)
    const y0 = box.min.y
    const y1 = box.max.y
    const z0 = box.min.z
    const z1 = box.max.z
    const x0 = box.min.x
    const x1 = box.max.x
    const xLoop: Array<[number, number, number]> = [
      [x, y0, z0], [x, y1, z0], [x, y1, z1], [x, y0, z1],
    ]
    const zLoop: Array<[number, number, number]> = [
      [x0, z, z0], [x1, z, z0], [x1, z, z1], [x0, z, z1],
    ]
    writeCutFrame(cutXFrame, xLoop)
    writeCutFrame(cutZFrame, zLoop)
    writeCornerPluses(cutXMarks, xLoop, [0, 1, 0], [0, 0, 1], armX)
    writeCornerPluses(cutZMarks, zLoop, [1, 0, 0], [0, 0, 1], armZ)
  }
  cutXFrame.visible = xOn
  cutZFrame.visible = zOn
  cutXMarks.visible = xOn
  cutZMarks.visible = zOn
  syncAnalysisLines(x, z, xOn, zOn)
  if (ready) sectionHatch.place(x, z, xOn, zOn, box)
  applyDimensionCuts(dimensions, xOn ? x : null, zOn ? z : null)
  renderDirty = true
}

function armCuts(box: THREE.Box3, keep: boolean) {
  const spanX = Math.max(box.max.x - box.min.x, 0.05)
  const spanZ = Math.max(box.max.y - box.min.y, 0.05)
  const prevX = Number(cutXInput.value)
  const prevZ = Number(cutZInput.value)
  cutXInput.disabled = false
  cutZInput.disabled = false
  cutXInput.min = String(box.min.x)
  cutXInput.max = String(box.max.x + cutClearance(spanX))
  cutXInput.step = String(Math.max(spanX / 400, 0.01))
  cutZInput.min = String(box.min.y)
  cutZInput.max = String(box.max.y + cutClearance(spanZ))
  cutZInput.step = String(Math.max(spanZ / 400, 0.01))
  const clamp = (value: number, min: number, max: number) => Math.min(max, Math.max(min, value))
  cutXInput.value = keep && Number.isFinite(prevX) ? String(clamp(prevX, box.min.x, Number(cutXInput.max))) : cutXInput.max
  cutZInput.value = keep && Number.isFinite(prevZ) ? String(clamp(prevZ, box.min.y, Number(cutZInput.max))) : cutZInput.max
  syncCuts()
}

function typed(arrays: Record<string, ArrayBuffer>, name: string, kind: "f32" | "u32" | "u8"): Float32Array | Uint32Array | Uint8Array {
  const buf = arrays[name]
  if (!buf) {
    if (kind === "f32") return new Float32Array()
    if (kind === "u32") return new Uint32Array()
    return new Uint8Array()
  }
  if (kind === "f32") return new Float32Array(buf)
  if (kind === "u32") return new Uint32Array(buf)
  return new Uint8Array(buf)
}

/** Structural Z-up to three.js Y-up. `stride` is the vector width (3 or 9). */
function swapYZ(values: Float32Array, stride: number) {
  for (let i = 0; i < values.length; i += stride) {
    for (let k = 0; k + 2 < stride; k += 3) {
      const y = values[i + k + 1]
      values[i + k + 1] = values[i + k + 2]
      values[i + k + 2] = y
    }
  }
}

/** Members with more than this many draw a 2-segment deflected shape while the camera moves. */
const ORBIT_LOD_MEMBERS = 5000

function setOrbitDetail(orbiting: boolean) {
  moving = orbiting
  applyView()
}

function clearModel() {
  closeDetail()
  sceneSerial += 1
  cutLineKey = ""
  sectionHatch.clear()
  for (const obj of [
    frameView?.high, frameView?.low, frameView?.ghost, frameView?.rods, glyphGroup,
    ...(building?.shells ?? []), ...(building?.ghosts ?? []), building?.footings, grid, memberSolids, shellVolumes, deckGroup, stressMesh, tributaryGroup,
    dimensions?.ground, dimensions?.front, dimensions?.back, dimensions?.left, dimensions?.right,
  ]) {
    if (obj) scene.remove(obj)
  }
  if (dimensions) disposeDimensions(dimensions)
  dimensions = null
  memberSolids?.geometry.dispose()
  memberSolids?.material.dispose()
  memberSolids = null
  shellVolumes?.geometry.dispose()
  ;(shellVolumes?.material as THREE.Material | undefined)?.dispose()
  shellVolumes = null
  deckGroup?.traverse((obj: THREE.Object3D) => {
    const body = obj as THREE.Mesh
    body.geometry?.dispose()
    ;(body.material as THREE.Material | undefined)?.dispose()
  })
  deckGroup = null
  stressMesh?.geometry.dispose()
  ;(stressMesh?.material as THREE.Material | undefined)?.dispose()
  stressMesh = null
  const tributaryMaterials = new Set<THREE.Material>()
  tributaryGroup?.traverse((obj: THREE.Object3D) => {
    const mesh = obj as THREE.Mesh
    mesh.geometry?.dispose()
    if (mesh.material instanceof THREE.Material) tributaryMaterials.add(mesh.material)
  })
  for (const material of tributaryMaterials) material.dispose()
  tributaryGroup = null
  elementAxial = new Float32Array()
  frameView?.high.geometry.dispose()
  frameView?.low.geometry.dispose()
  frameView?.rods.geometry.dispose()
  ;(frameView?.rods.material as THREE.Material | undefined)?.dispose()
  const disposed = new Set<THREE.BufferGeometry>()
  for (const mesh of building?.shells ?? []) {
    if (!disposed.has(mesh.geometry)) {
      mesh.geometry.dispose()
      disposed.add(mesh.geometry)
    }
    mesh.material.dispose()
  }
  for (const mesh of building?.ghosts ?? []) mesh.material.dispose()
  building?.footings?.dispose()
  frameView = null
  glyphGroup = null
  glyphs = null
  building = null
  grid = null
}

/** Deck floors whose profile and rib direction are in the component record. */
function deckFloors(): DeckFloor[] {
  const floors: DeckFloor[] = []
  for (const record of componentRecords) {
    if (record.kind !== "slab") continue
    const deck = record.drawing?.deck
    const elevation = record.bind?.elevation_m
    if (!deck || typeof deck !== "object" || typeof elevation !== "number") continue
    const fields = deck as Record<string, unknown>
    const direction = fields.direction
    if (!Array.isArray(direction) || direction.length < 2) continue
    const value = (key: string) => typeof fields[key] === "number" ? fields[key] as number : Number.NaN
    floors.push({
      elevation,
      direction: [Number(direction[0]), Number(direction[1])],
      hr: value("hr_m"),
      ribTop: value("rib_top_m"),
      ribBottom: value("rib_bottom_m"),
      pitch: value("pitch_m"),
      fill: value("fill_m"),
      sheet: typeof fields.sheet_m === "number" ? fields.sheet_m : null,
    })
  }
  // One story is several bay records. The same profile is one deck, so the flutes
  // run straight across the floor. Two different profiles at one elevation still fail.
  const kept: DeckFloor[] = []
  for (const floor of floors) {
    const same = kept.find((item) => Math.abs(item.elevation - floor.elevation) <= 0.5)
    if (!same) {
      kept.push(floor)
      continue
    }
    if (!sameDeck(same, floor)) throw new Error("two deck profiles share one slab elevation")
  }
  return kept
}

/** Designed slabs that are a plate, not a solid head. Elevation is structural Z. */
function slabSheets(records: ComponentRecord[]): SlabSheet[] {
  const sheets: SlabSheet[] = []
  for (const record of records) {
    if (record.kind !== "slab" || record.drawing?.solid_head === true) continue
    const thickness = Number(record.drawing?.thickness_m)
    const elevation = record.bind?.elevation_m
    if (!(thickness > 0) || typeof elevation !== "number") continue
    sheets.push({ elevation, thickness })
  }
  return sheets
}

function sameDeck(a: DeckFloor, b: DeckFloor): boolean {
  const close = (x: number, y: number) => Math.abs(x - y) <= 1e-6
  return close(a.hr, b.hr) && close(a.ribTop, b.ribTop) && close(a.ribBottom, b.ribBottom)
    && close(a.pitch, b.pitch) && close(a.fill, b.fill) && close(a.sheet ?? 0, b.sheet ?? 0)
    && close(a.direction[0], b.direction[0]) && close(a.direction[1], b.direction[1])
}

function show(decoded: DecodedScene, refit = true) {
  clearModel()
  header = decoded.header
  componentRecords = readComponents(header)
  const position = typed(decoded.arrays, "node_position", "f32") as Float32Array
  const displacement = typed(decoded.arrays, "node_displacement", "f32") as Float32Array
  const rotation = typed(decoded.arrays, "node_rotation", "f32") as Float32Array
  const lcs = typed(decoded.arrays, "element_lcs", "f32") as Float32Array
  const nodeForce = typed(decoded.arrays, "node_force", "f32") as Float32Array
  const nodeMoment = typed(decoded.arrays, "node_moment", "f32") as Float32Array
  const lineLoad = typed(decoded.arrays, "line_load", "f32") as Float32Array
  const pointLoad = typed(decoded.arrays, "point_load", "f32") as Float32Array
  const loadArrowAt = typed(decoded.arrays, "load_arrow_position", "f32") as Float32Array
  const loadArrowDir = typed(decoded.arrays, "load_arrow_vector", "f32") as Float32Array
  for (const values of [position, displacement, rotation, lcs, nodeForce, nodeMoment, lineLoad, pointLoad, loadArrowAt, loadArrowDir]) {
    swapYZ(values, values === lcs ? 9 : 3)
  }

  elementNodes = typed(decoded.arrays, "element_nodes", "u32") as Uint32Array<ArrayBuffer>
  elementType = typed(decoded.arrays, "element_type", "u8") as Uint8Array<ArrayBuffer>
  nodePosition = position as Float32Array<ArrayBuffer>
  nodeDisplacement = displacement as Float32Array<ArrayBuffer>
  displacementPresent = Boolean(decoded.arrays.node_displacement) && nodeDisplacement.length === nodePosition.length && nodePosition.length > 0
  localDof = typed(decoded.arrays, "element_local_dof", "f32") as Float32Array<ArrayBuffer>
  elementLcs = lcs as Float32Array<ArrayBuffer>
  loadElementIndex = typed(decoded.arrays, "load_element", "u32") as Uint32Array<ArrayBuffer>
  loadParticular = typed(decoded.arrays, "load_particular", "f32") as Float32Array<ArrayBuffer>
  solvedStations = Number(decoded.header.stations ?? 0)
  supportIndex = typed(decoded.arrays, "support_index", "u32") as Uint32Array<ArrayBuffer>
  supportFixity = typed(decoded.arrays, "support_fixity", "u8") as Uint8Array<ArrayBuffer>
  shellFaces = typed(decoded.arrays, "shell_faces", "u32") as Uint32Array<ArrayBuffer>
  shellKinds = typed(decoded.arrays, "shell_kind", "u8") as Uint8Array<ArrayBuffer>
  const shellCount = Math.min(shellKinds.length, Math.floor(shellFaces.length / 3))
  // A grillage file stores the rib frame and no slab. The slab surface is the
  // rib bays themselves, so it deflects on the nodes that were solved.
  let grillageThickness: Float32Array | null = null
  const analysisModelName = String((decoded.header as { analysis_model?: unknown }).analysis_model ?? "")
  if (shellCount === 0 && analysisModelName === "grillage") {
    const built = grillageSlab(position, elementNodes, elementType, slabSheets(componentRecords))
    if (built) {
      shellFaces = built.faces as Uint32Array<ArrayBuffer>
      shellKinds = built.kinds as Uint8Array<ArrayBuffer>
      grillageThickness = built.thickness
    }
  }
  // A corner fan has no surface stress. Pull in the beam nodes that already
  // lie on its edges so the slab and the beam share those displacements.
  // The grillage surface is already those nodes, one bay at a time.
  let shellFrom: Uint32Array | null = null
  if (!grillageThickness && !decoded.arrays.shell_surface_stress) {
    const refined = conformSlabToFrame(shellFaces, shellKinds, position, elementNodes, elementType)
    shellFaces = refined.faces as Uint32Array<ArrayBuffer>
    shellKinds = refined.kinds as Uint8Array<ArrayBuffer>
    shellFrom = refined.from
  }
  const hiddenMembers = omittedMembers(position, elementNodes, elementType, shellFaces, shellKinds)
  frameView = buildFrame({
    position,
    elementNodes,
    elementType,
    localDof,
    lcs,
    loadElement: loadElementIndex,
    particular: loadParticular,
    stations: solvedStations,
    hidden: hiddenMembers,
  })
  scene.add(frameView.ghost)
  scene.add(frameView.high)
  scene.add(frameView.low)
  scene.add(frameView.rods)
  glyphs = buildGlyphs({
    position,
    elementNodes,
    supportIndex,
    supportFixity,
    nodeForceIndex: typed(decoded.arrays, "node_force_index", "u32") as Uint32Array,
    nodeForce,
    nodeMomentIndex: typed(decoded.arrays, "node_moment_index", "u32") as Uint32Array,
    nodeMoment,
    lineLoadElement: typed(decoded.arrays, "line_load_element", "u32") as Uint32Array,
    lineLoad,
    pointLoadElement: typed(decoded.arrays, "point_load_element", "u32") as Uint32Array,
    pointLoadPosition: typed(decoded.arrays, "point_load_position", "f32") as Float32Array,
    pointLoad,
    loadArrowAt,
    loadArrowDir,
    shellFaces,
    shellKinds,
    meanLength: frameView.meanLength,
  })
  glyphGroup = glyphs.group
  scene.add(glyphGroup)

  footingCenter = typed(decoded.arrays, "footing_center", "f32") as Float32Array<ArrayBuffer>
  footingSize = typed(decoded.arrays, "footing_size", "f32") as Float32Array<ArrayBuffer>
  footingKind = typed(decoded.arrays, "footing_kind", "u8") as Uint8Array<ArrayBuffer>
  swapYZ(footingCenter, 3)
  swapYZ(footingSize, 3)
  footingNodes = bindFootingNodes(decoded, footingCenter.length / 3)
  footingDisp = footingDisplacement(footingNodes) as Float32Array<ArrayBuffer>
  building = buildBuilding({
    position,
    displacement,
    faces: shellFaces,
    kinds: shellKinds,
    footingCenter,
    footingSize,
    scale: frameView.uniforms.uScale,
    colorMax: frameView.maxDisplacement,
  })
  frameView.paint(Math.max(building.maxDisplacement, 1e-12))
  for (const mesh of building.shells) scene.add(mesh)
  for (const mesh of building.ghosts) scene.add(mesh)
  if (building.footings) scene.add(building.footings)
  const solidPosition = typed(decoded.arrays, "member_solid_position", "f32") as Float32Array
  swapYZ(solidPosition, 3)
  const shellThickness = grillageThickness ?? expandTriangles(
    typed(decoded.arrays, "shell_thickness", "f32") as Float32Array,
    shellFrom, shellCount,
  )
  const sectionHeader = (decoded.header as { element_section?: unknown }).element_section
  elementSection = Array.isArray(sectionHeader) ? sectionHeader.map(String) : []
  const nFrame = elementNodes.length / 2
  const loadRow = new Int32Array(nFrame)
  loadRow.fill(-1)
  for (let i = 0; i < loadElementIndex.length; i++) {
    const element = loadElementIndex[i] ?? 0
    if (element < nFrame) loadRow[element] = i
  }
  const solidKept = withoutOmittedSolids(
    typed(decoded.arrays, "member_solid_faces", "u32") as Uint32Array,
    typed(decoded.arrays, "member_solid_element", "u32") as Uint32Array,
    hiddenMembers,
  )
  const solidFaces = solidKept.faces
  const solidOwner = solidKept.owner
  seatBeamsUnderSlab(
    solidPosition, solidFaces, solidOwner, elementSection,
    elementNodes, elementType, nodePosition, position, shellFaces, shellKinds, shellThickness,
  )
  memberSolids = buildMemberSolids(
    solidPosition,
    solidFaces,
    solidOwner,
    elementSection,
    {
      nodePosition,
      nodeDisplacement,
      elementNodes,
      scale: frameView.uniforms.uScale,
      localDof,
      lcs: elementLcs,
      loadRow,
      particular: loadParticular,
      stations: solvedStations,
    },
  )
  if (memberSolids) scene.add(memberSolids)
  const deck = buildDeckSolids(position, shellFaces, shellKinds, deckFloors())
  deckGroup = deck?.group ?? null
  if (deckGroup) scene.add(deckGroup)
  shellVolumes = buildShellVolumes(position, shellFaces, shellKinds, shellThickness, deck?.skip ?? null)
  if (shellVolumes) scene.add(shellVolumes)
  elementAxial = typed(decoded.arrays, "element_axial", "f32") as Float32Array<ArrayBuffer>
  if (decoded.arrays.element_axial && elementAxial.length !== frameView.elementCount) {
    throw new Error(`element_axial has ${elementAxial.length} values for ${frameView.elementCount} frame elements`)
  }
  maxAxial = Math.abs(Number(decoded.header.max_axial_n ?? 0))
  if (elementAxial.length > 0 && !(maxAxial > 0)) {
    for (const value of elementAxial) maxAxial = Math.max(maxAxial, Math.abs(value))
  }
  shellStress = typed(decoded.arrays, "shell_surface_stress", "f32") as Float32Array<ArrayBuffer>
  const triangleCount = shellFaces.length / 3
  if (decoded.arrays.shell_surface_stress && shellStress.length !== triangleCount) {
    throw new Error(`shell_surface_stress has ${shellStress.length} values for ${triangleCount} shell triangles`)
  }
  stressPresent = Boolean(decoded.arrays.shell_surface_stress) && shellStress.length === triangleCount && triangleCount > 0
  maxStress = Math.abs(Number(decoded.header.max_surface_stress_pa ?? 0))
  shellAxial = expandTriangles(
    typed(decoded.arrays, "shell_axial", "f32") as Float32Array<ArrayBuffer>,
    shellFrom, shellCount,
  )
  if (decoded.arrays.shell_axial && shellAxial.length !== triangleCount) {
    throw new Error(`shell_axial has ${shellAxial.length} values for ${triangleCount} shell triangles`)
  }
  shellAxialPresent = Boolean(decoded.arrays.shell_axial) && shellAxial.length === triangleCount && triangleCount > 0
  shellWall = expandTriangles(
    typed(decoded.arrays, "shell_wall", "u32") as Uint32Array<ArrayBuffer>,
    shellFrom, shellCount,
  )
  if (decoded.arrays.shell_wall && shellWall.length !== triangleCount) {
    throw new Error(`shell_wall has ${shellWall.length} values for ${triangleCount} shell triangles`)
  }
  if (shellStress.length > 0 && !(maxStress > 0)) {
    for (const value of shellStress) maxStress = Math.max(maxStress, Math.abs(value))
  }
  stressMesh = buildStressMesh(position, shellFaces, shellStress, maxStress)
  if (stressMesh) scene.add(stressMesh)
  tributaryPosition = typed(decoded.arrays, "tributary_position", "f32") as Float32Array<ArrayBuffer>
  tributaryCount = typed(decoded.arrays, "tributary_count", "u32") as Uint32Array<ArrayBuffer>
  tributaryKind = typed(decoded.arrays, "tributary_kind", "u8") as Uint8Array<ArrayBuffer>
  tributaryElement = typed(decoded.arrays, "tributary_element", "u32") as Uint32Array<ArrayBuffer>
  tributaryCell = typed(decoded.arrays, "tributary_cell", "u32") as Uint32Array<ArrayBuffer>
  tributaryPresent = Boolean(
    decoded.arrays.tributary_position || decoded.arrays.tributary_count || decoded.arrays.tributary_kind || decoded.arrays.tributary_element,
  )
  if (tributaryPresent && tributaryElement.length !== tributaryCount.length) {
    throw new Error(`tributary_element has ${tributaryElement.length} values for ${tributaryCount.length} polygons`)
  }
  if (decoded.arrays.tributary_cell && tributaryCell.length !== tributaryCount.length) {
    throw new Error(`tributary_cell has ${tributaryCell.length} values for ${tributaryCount.length} polygons`)
  }
  swapYZ(tributaryPosition, 3)
  tributaryGroup = buildTributary(tributaryPosition, tributaryCount, tributaryKind, tributaryElement)
  if (tributaryPresent && !tributaryGroup) {
    throw new Error("tributary buffers are present but do not describe a polygon")
  }
  if (tributaryGroup) scene.add(tributaryGroup)
  modelBounds = boundsOf(position, footingCenter, footingSize)
  legendMax.textContent = `${(building.maxDisplacement * 1000).toFixed(1)} mm`

  const span = Math.max(frameView.meanLength * Math.sqrt(frameView.elementCount), 10)
  grid = new THREE.GridHelper(span * 4, 20, theme.grid, theme.grid)
  const plan = modelBounds.getCenter(new THREE.Vector3())
  grid.position.set(plan.x, 0, plan.z)
  scene.add(grid)

  baseScale = Number(decoded.header.suggested_scale ?? 1) || 1
  if (refit) scaleInput.value = "1"
  prepareAppearance()
  applyView()
  if (refit) fit()
  const nodes = position.length / 3
  const maxDisp = Number(decoded.header.max_displacement ?? 0)
  const solids = [
    building.shellTriangles > 0 ? `${building.shellTriangles} shell triangles` : "",
    building.footingCount > 0 ? footingStatus(building.footingCount, footingKind) : "",
  ].filter(Boolean).join(" · ")
  setStatus(`${nodes} nodes · ${frameView.elementCount} members${solids ? ` · ${solids}` : ""} · max displacement ${maxDisp.toExponential(2)} m`)
  dimensions = buildDimensions(nodePosition, elementNodes)
  if (dimensions) {
    scene.add(dimensions.ground, dimensions.front, dimensions.back, dimensions.left, dimensions.right)
    showDimensionView(dimensionView)
  }
  bindClipping(scene)
  bindClipping(frameView.pick)
  bindShellMaterials(building)
  armCuts(modelBounds, !refit)
  renderDirty = true
}

/** Node positions plus footing boxes. Independent of mesh bounding boxes. */
function boundsOf(position: Float32Array, center: Float32Array, size: Float32Array): THREE.Box3 {
  const box = new THREE.Box3()
  const p = new THREE.Vector3()
  for (let i = 0; i < position.length; i += 3) {
    p.set(position[i], position[i + 1], position[i + 2])
    if (Number.isFinite(p.x + p.y + p.z)) box.expandByPoint(p)
  }
  for (let i = 0; i < center.length; i += 3) {
    const hx = size[i] / 2
    const hy = size[i + 1] / 2
    const hz = size[i + 2] / 2
    box.expandByPoint(p.set(center[i] - hx, center[i + 1] - hy, center[i + 2] - hz))
    box.expandByPoint(p.set(center[i] + hx, center[i + 1] + hy, center[i + 2] + hz))
  }
  return box
}

function applyScale() {
  paintRange(scaleInput)
  applyView()
  if (selected) rebuildOutline()
}

/** Copy a mesh color attribute, or null when the mesh has no vertex colors. */
function colorCopy(mesh: THREE.Mesh | null): Float32Array | null {
  const attr = mesh?.geometry.getAttribute("color") as THREE.BufferAttribute | undefined
  return attr ? new Float32Array(attr.array as Float32Array) : null
}

/** Write `colors` into the mesh's color attribute. */
function paintColors(mesh: THREE.Mesh | null, colors: Float32Array | null) {
  if (!mesh || !colors) return
  const attr = mesh.geometry.getAttribute("color") as THREE.BufferAttribute | undefined
  if (!attr || attr.array.length !== colors.length) return
  ;(attr.array as Float32Array).set(colors)
  attr.needsUpdate = true
}

/** The analysis shells share one color attribute. One write updates every kind. */
function paintShellNodes(colors: Float32Array | null) {
  paintColors(building?.shells[0] ?? null, colors)
}

function paintDeck(categories: boolean) {
  if (!deckGroup) return
  for (const child of deckGroup.children) {
    const material = (child as THREE.Mesh).material as THREE.MeshLambertMaterial
    const concrete = child.userData.deckRole === "deck-concrete"
    material.color.set(concrete && categories ? CATEGORY_COLOR.slab : concrete ? theme.slab : theme.charcoal)
  }
}

function paintFootings(which: "concrete" | "category" | "utilization") {
  const mesh = building?.footings
  if (!mesh) return
  const ink = new THREE.Color()
  for (let i = 0; i < mesh.count; i++) {
    if (which === "category") ink.set(CATEGORY_COLOR.footing)
    else if (which === "utilization") utilizationColor(footingRatio[i] ?? Number.NaN, ink)
    else ink.set(theme.concrete)
    mesh.setColorAt(i, ink)
  }
  if (mesh.instanceColor) mesh.instanceColor.needsUpdate = true
}

/** Category hues for the sized solids, and demand/capacity for the analysis mesh. */
function prepareAppearance() {
  memberBase = colorCopy(memberSolids)
  memberCategoryColors = memberSolids && memberBase ? categoryMembers(memberSolids, memberBase.length) : null
  volumeBase = colorCopy(shellVolumes)
  volumeCategory = shellVolumes && volumeBase ? categoryVolume(shellVolumes, volumeBase.length) : null
  const shell = building?.shells[0] ?? null
  shellNodeBase = colorCopy(shell)
  collectUtilization()
}

function categoryMembers(mesh: THREE.Mesh, length: number): Float32Array {
  const out = new Float32Array(length)
  const owner = mesh.userData.owner as Uint32Array
  const index = mesh.geometry.getIndex()
  if (!index) return out
  const ink = new THREE.Color()
  for (let t = 0; t < owner.length; t++) {
    const element = owner[t] ?? 0
    ink.set(memberCategory(elementType[element] ?? 0, elementSection[element] ?? ""))
    for (let k = 0; k < 3; k++) {
      const vertex = index.getX(t * 3 + k)
      out[vertex * 3] = ink.r
      out[vertex * 3 + 1] = ink.g
      out[vertex * 3 + 2] = ink.b
    }
  }
  return out
}

function categoryVolume(mesh: THREE.Mesh, length: number): Float32Array {
  const out = new Float32Array(length)
  const source = mesh.userData.vertexSource as Uint32Array
  const kinds = mesh.userData.kinds as Uint8Array
  const ink = new THREE.Color()
  for (let vertex = 0; vertex < source.length; vertex++) {
    ink.set(shellCategory(kinds[source[vertex] ?? 0] ?? 0))
    out[vertex * 3] = ink.r
    out[vertex * 3 + 1] = ink.g
    out[vertex * 3 + 2] = ink.b
  }
  return out
}

/** Governing ratio of each frame element, shell node, and footing. */
function collectUtilization() {
  const nElem = frameView?.elementCount ?? 0
  elementRatio = new Float32Array(nElem)
  elementRatio.fill(Number.NaN)
  const nFoot = (building?.footingCount ?? 0)
  footingRatio = new Float32Array(nFoot)
  footingRatio.fill(Number.NaN)
  const slabs: { ratio: number, elevation: number, rings: number[][][], kinds: number[] }[] = []
  const walls = new Map<number, number>()
  let peak = 0
  let any = false
  for (const record of componentRecords) {
    const ratio = record.governing?.ratio
    if (typeof ratio !== "number" || !Number.isFinite(ratio)) continue
    any = true
    if (ratio > peak) peak = ratio
    if (record.kind === "beam" || record.kind === "column" || record.kind === "brace") {
      for (const element of record.bind?.frame_elements ?? []) {
        if (element < 0 || element >= nElem) continue
        const prev = elementRatio[element]
        elementRatio[element] = Number.isFinite(prev) ? Math.max(prev, ratio) : ratio
      }
    } else if (record.kind === "footing") {
      const index = record.bind?.footing
      if (typeof index === "number" && index >= 0 && index < nFoot) footingRatio[index] = ratio
    } else if (record.kind === "wall" && typeof record.design_index === "number") {
      walls.set(record.design_index, ratio)
    } else if (record.kind === "slab" && typeof record.bind?.elevation_m === "number") {
      slabs.push({
        ratio,
        elevation: record.bind.elevation_m,
        rings: planRings(record.bind.plan_m),
        kinds: record.bind.shell_kinds ?? [0, 2],
      })
    }
  }
  hasUtilization = any
  utilizationPeak = peak
  if (!shellNodeBase) {
    shellNodeUtilization = null
    return
  }
  const ghost = new THREE.Color(theme.ghost)
  shellNodeUtilization = new Float32Array(shellNodeBase.length)
  for (let i = 0; i < shellNodeUtilization.length; i += 3) {
    shellNodeUtilization[i] = ghost.r
    shellNodeUtilization[i + 1] = ghost.g
    shellNodeUtilization[i + 2] = ghost.b
  }
  const ink = new THREE.Color()
  const nTri = shellFaces.length / 3
  for (let pass = 0; pass < 2; pass++) {
    for (let t = 0; t < nTri; t++) {
      const kind = shellKinds[t] ?? 0
      const wall = shellKindOf(kind) === 1
      if ((pass === 0) === wall) continue
      const ratio = wall ? (shellWall[t] ? walls.get(shellWall[t]) : undefined) : slabRatio(t, slabs)
      if (typeof ratio !== "number" || !Number.isFinite(ratio)) continue
      utilizationColor(ratio, ink)
      for (let k = 0; k < 3; k++) {
        const vertex = shellFaces[t * 3 + k] ?? 0
        shellNodeUtilization[vertex * 3] = ink.r
        shellNodeUtilization[vertex * 3 + 1] = ink.g
        shellNodeUtilization[vertex * 3 + 2] = ink.b
      }
    }
  }
}

function slabRatio(
  triangle: number,
  slabs: { ratio: number, elevation: number, rings: number[][][], kinds: number[] }[],
): number {
  const kind = shellKindOf(shellKinds[triangle] ?? 0)
  let x = 0, y = 0, z = 0
  for (let k = 0; k < 3; k++) {
    const vertex = shellFaces[triangle * 3 + k] ?? 0
    x += nodePosition[vertex * 3] ?? 0
    y += nodePosition[vertex * 3 + 1] ?? 0
    z += nodePosition[vertex * 3 + 2] ?? 0
  }
  x /= 3; y /= 3; z /= 3
  let nearest = Infinity
  let ratio = Number.NaN
  for (const slab of slabs) {
    if (!slab.kinds.includes(kind)) continue
    if (Math.abs(slab.elevation - y) > 0.5) continue
    if (slab.rings.some((ring) => ringContains(ring, x, z))) return slab.ratio
    for (const ring of slab.rings) {
      let cx = 0, cz = 0
      for (const p of ring) { cx += p[0]; cz += p[1] }
      cx /= ring.length; cz /= ring.length
      const d = Math.hypot(cx - x, cz - z)
      if (d < nearest) { nearest = d; ratio = slab.ratio }
    }
  }
  return nearest < 8 ? ratio : Number.NaN
}

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

function ringContains(ring: number[][], x: number, z: number): boolean {
  let inside = false
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const xi = ring[i][0], zi = ring[i][1]
    const xj = ring[j][0], zj = ring[j][1]
    const cross = (zi > z) !== (zj > z)
    if (cross && x < (xj - xi) * (z - zi) / ((zj - zi) || 1e-12) + xi) inside = !inside
  }
  return inside
}

/**
 * Geometry / Sized is the undeflected building. Categories is that same
 * building with one hue per element type. Initialization drops the sized
 * extrusions and the footings and keeps the centerlines and shell surfaces.
 * Analysis / Deflection is the solved shape. Utilization, stress, axial force,
 * and tributary area draw their fields when the scene has them.
 */
function applyView() {
  if (!frameView) return
  const factor = Number(scaleInput.value)
  const sized = mode === "geometry" && geometryVariant !== "initialization"
  const categories = sized && geometryVariant === "categories"
  const sticks = mode === "geometry" && geometryVariant === "initialization"
  const analysis = mode === "analysis"
  const deflection = analysis && analysisVariant === "deflection"
  const colored = colorInput.checked && deflection
  const hasStress = stressMesh !== null
  const hasAxial = elementAxial.length === (frameView?.elementCount ?? -1) && elementAxial.length > 0
  const hasTributary = tributaryGroup !== null
  const stressOn = analysis && analysisVariant === "stress" && hasStress
  const axialOn = analysis && analysisVariant === "axial" && hasAxial
  const utilizationOn = analysis && analysisVariant === "utilization" && hasUtilization
  const tributaryOn = analysis && analysisVariant === "tributary" && hasTributary
  paintColors(memberSolids, categories ? memberCategoryColors : memberBase)
  paintColors(shellVolumes, categories ? volumeCategory : volumeBase)
  paintDeck(categories)
  paintFootings(categories ? "category" : utilizationOn ? "utilization" : "concrete")
  paintShellNodes(utilizationOn ? shellNodeUtilization : shellNodeBase)
  frameView.uniforms.uScale.value = deflection ? baseScale * factor : 0
  frameView.uniforms.uColorMode.value = colored ? 1 : 0
  scaleLabel.textContent = deflection ? `${(baseScale * factor).toFixed(2)}×` : "off"
  scaleInput.disabled = !deflection
  colorInput.disabled = !deflection
  ghostInput.disabled = !analysis
  animateInput.disabled = !deflection

  // Sized geometry draws the solids. Deflection draws the beam network in
  // the solved shape, colored by magnitude, so the ribs stay a frame.
  const solidsOn = sized && memberSolids !== null
  if (memberSolids) memberSolids.visible = solidsOn
  if (shellVolumes) shellVolumes.visible = sized
  const membersOn = !solidsOn
  const coarse = moving && membersOn && !axialOn && frameView.elementCount > ORBIT_LOD_MEMBERS
  const showRods = axialOn || utilizationOn || (membersOn && colored && !coarse)
  frameView.rods.visible = showRods
  frameView.high.visible = membersOn && !coarse && !axialOn && !utilizationOn && !(membersOn && colored)
  frameView.low.visible = membersOn && coarse
  frameView.ghost.visible = membersOn && !coarse && deflection && ghostInput.checked && !selected
  if (utilizationOn) frameView.paintRatios(elementRatio)
  else if (axialOn) frameView.paintElements(elementAxial, maxAxial)
  else frameView.paint(frameView.maxDisplacement)
  if (glyphGroup) glyphGroup.visible = loadsInput.checked

  for (const mesh of building?.shells ?? []) {
    const kind = Number(mesh.userData.kind)
    mesh.visible = (!sized || (shellVolumes === null && deckGroup === null)) && !stressOn
    mesh.material = colored || utilizationOn ? building!.mappedFor(kind) : building!.solidFor(kind)
  }
  building?.shells.forEach((mesh, i) => {
    const ghost = building?.ghosts[i]
    if (ghost) ghost.visible = analysis && ghostInput.checked && mesh.visible && !selected
  })
  if (building?.footings) building.footings.visible = !sticks
  if (stressMesh) stressMesh.visible = stressOn
  if (tributaryGroup) {
    tributaryGroup.visible = tributaryOn
    const story = selected?.record?.kind === "slab" ? selected.record.bind?.elevation_m : undefined
    for (const child of tributaryGroup.children) {
      const y = child.userData.elevation
      child.visible = typeof story !== "number" || (typeof y === "number" && Math.abs(y - story) <= 0.5)
    }
  }
  if (deckGroup) deckGroup.visible = sized
  // Sized geometry cuts every solid. Analysis hides the shell volume, and the
  // hatch still fills the walls inside it. Slabs keep the analysis stroke.
  const hatch = [
    solidsOn ? memberSolids : null,
    shellVolumes,
    ...(sized && deckGroup ? deckGroup.children as THREE.Mesh[] : []),
    sticks ? null : building?.footings,
  ].filter((mesh): mesh is THREE.Mesh => mesh != null)
  sectionHatch.setSources(hatch)
  const cutBox = modelBounds
  if (Number.isFinite(cutBox.min.x) && Number.isFinite(cutBox.max.x)) {
    const cutX = Number(cutXInput.value)
    const cutZ = Number(cutZInput.value)
    sectionHatch.place(
      cutX,
      cutZ,
      cutX < cutBox.max.x - 0.05,
      cutZ < cutBox.max.y - 0.05,
      cutBox,
    )
  }
  placeFootings()
  const analysisModel = String((header as { analysis_model?: unknown } | null)?.analysis_model ?? "")
  const absent = analysis && (
    (analysisVariant === "utilization" && !hasUtilization) ||
    (analysisVariant === "stress" && !hasStress) ||
    (analysisVariant === "axial" && !hasAxial) ||
    (analysisVariant === "tributary" && !hasTributary)
  ) ? (
    analysisVariant === "stress" && analysisModel === "grillage"
      ? "This floor is a rib grillage. The panel load is on the ribs, and there is no slab shell."
      : ABSENT_FIELD[analysisVariant]
  ) : undefined
  const note = absent ?? (
    tributaryOn ? "Each outline is one assigned area. Column areas are cerulean. Wall areas are iris. Beam areas are gold."
    : categories ? CATEGORY_NOTE
    : ""
  )
  fieldNote.hidden = note === ""
  fieldNote.textContent = note
  legendEl.hidden = !(colored || stressOn || axialOn || utilizationOn)
  legendEl.classList.toggle("stress", stressOn)
  if (colored) {
    legendMin.textContent = "0"
    legendMax.textContent = `${((building?.maxDisplacement ?? frameView.maxDisplacement) * 1000).toFixed(1)} mm`
    legendCaption.textContent = "Deflection magnitude"
  } else if (utilizationOn) {
    legendMin.textContent = "0"
    legendMax.textContent = "1.00"
    legendCaption.textContent = utilizationPeak > 1
      ? `Demand / capacity. Red is the limit. Peak ${utilizationPeak.toFixed(2)}.`
      : "Demand / capacity. Red is the limit."
  } else if (stressOn) {
    const mpa = maxStress / 1e6
    legendMin.textContent = `−${mpa.toFixed(2)} MPa`
    legendMax.textContent = `+${mpa.toFixed(2)} MPa`
    legendCaption.textContent = "Surface stress. Compression is magenta, tension is blue."
  } else if (axialOn) {
    const kn = maxAxial / 1000
    legendMin.textContent = `−${kn.toFixed(1)} kN`
    legendMax.textContent = `+${kn.toFixed(1)} kN`
    legendCaption.textContent = "Axial force. Tension is positive."
  }
  syncAnalysisLines(Number(cutXInput.value), Number(cutZInput.value), cutXMarks.visible, cutZMarks.visible)
  renderDirty = true
}

/** Axis-aligned extent of a packed xyz array. The scene origin is one corner, so this must not go through a mesh bounding box. */
function extentOf(values: Float32Array): { min: number[]; max: number[] } | null {
  if (values.length < 3) return null
  const min = [Infinity, Infinity, Infinity]
  const max = [-Infinity, -Infinity, -Infinity]
  for (let i = 0; i < values.length; i += 3) {
    for (let k = 0; k < 3; k++) {
      const v = values[i + k]
      if (!Number.isFinite(v)) continue
      if (v < min[k]) min[k] = v
      if (v > max[k]) max[k] = v
    }
  }
  return min[0] === Infinity ? null : { min, max }
}

/**
 * Snap the orbit onto the middle of `values`. A saved view from an earlier
 * session looks at the origin, and a damped fit kept that corner in frame.
 */
function lookAtExtent(values: Float32Array, padding: number, minRadius = 0) {
  const ext = extentOf(values)
  if (!ext) return
  const cx = (ext.min[0] + ext.max[0]) * 0.5
  const cy = (ext.min[1] + ext.max[1]) * 0.5
  const cz = (ext.min[2] + ext.max[2]) * 0.5
  const dx = ext.max[0] - ext.min[0]
  const dy = ext.max[1] - ext.min[1]
  const dz = ext.max[2] - ext.min[2]
  const radius = Math.max(0.5 * Math.hypot(dx, dy, dz) * padding, minRadius, 1)
  const aspect = Math.max(camera.aspect || 1, 0.5)
  const vFov = THREE.MathUtils.degToRad(camera.fov)
  const hFov = 2 * Math.atan(Math.tan(vFov * 0.5) * aspect)
  const distance = radius / Math.sin((aspect >= 1 ? vFov : hFov) * 0.5)
  const dir = new THREE.Vector3(1, 0.72, 1).normalize().multiplyScalar(distance)
  controls.setLookAt(cx + dir.x, cy + dir.y, cz + dir.z, cx, cy, cz, false)
  controls.update(0)
  infoEl.textContent = `Framed ${dx.toFixed(1)} × ${dy.toFixed(1)} × ${dz.toFixed(1)} m`
  if (location.hash.startsWith("#cam=")) history.replaceState(null, "", location.pathname + location.search)
  renderDirty = true
}

function fit() {
  lookAtExtent(nodePosition, 1.45, 2)
  showDimensionView("ground")
  resetElevationButton()
}

function showDimensionView(next: DimensionView) {
  dimensionView = next
  if (!dimensions) return
  const on = dimensionsInput.checked
  dimensions.ground.visible = on && next === "ground"
  dimensions.front.visible = on && next === "front"
  dimensions.back.visible = on && next === "back"
  dimensions.left.visible = on && next === "left"
  dimensions.right.visible = on && next === "right"
  renderDirty = true
}

// Cut X removes the +X side, so the first view stands on that side and looks at the cut.
const elevations = [
  { label: "Section", azimuth: Math.PI / 2, view: "right" },
  { label: "Front", azimuth: 0, view: "front" },
  { label: "Left", azimuth: -Math.PI / 2, view: "left" },
  { label: "Back", azimuth: Math.PI, view: "back" },
] as const
let elevationIndex = 0

function resetElevationButton() {
  elevationIndex = 0
  const button = document.querySelector("#front")
  if (button) button.textContent = elevations[0].label
}

function setOrtho(on: boolean) {
  if (on === orthoOn) return
  orthoOn = on
  const target = new THREE.Vector3()
  controls.getTarget(target)
  const position = activeCamera.position.clone()
  controls.dispose()
  activeCamera = orthoOn ? ortho : camera
  activeCamera.position.copy(position)
  activeCamera.up.set(0, 1, 0)
  if (orthoOn) syncOrthoFrustum()
  controls = makeControls(activeCamera)
  controls.setLookAt(position.x, position.y, position.z, target.x, target.y, target.z, false)
  document.querySelector("#proj-perspective")?.classList.toggle("on", !orthoOn)
  document.querySelector("#proj-ortho")?.classList.toggle("on", orthoOn)
  renderDirty = true
}

function zoomTo(points: THREE.Vector3[], padding = 2.4) {
  const packed = new Float32Array(points.length * 3)
  points.forEach((p, i) => packed.set([p.x, p.y, p.z], i * 3))
  lookAtExtent(packed, padding, 1)
}

function viewFrom(azimuth: number, polar: number) {
  controls.rotateTo(azimuth, polar, true)
  renderDirty = true
}

function writeCameraHash() {
  const target = new THREE.Vector3()
  controls.getTarget(target)
  const p = activeCamera.position
  const next = `#cam=${[p.x, p.y, p.z, target.x, target.y, target.z].map((v) => v.toFixed(3)).join(",")}`
  if (location.hash !== next) history.replaceState(null, "", next)
}

async function pick(clientX: number, clientY: number): Promise<number> {
  if (!frameView) return -1
  const rect = canvas.getBoundingClientRect()
  const dpr = renderer.getPixelRatio()
  const x = Math.floor((clientX - rect.left) * dpr)
  const y = Math.floor((clientY - rect.top) * dpr)
  const w = Math.floor(rect.width * dpr)
  const h = Math.floor(rect.height * dpr)
  if (x < 0 || y < 0 || x >= w || y >= h) return -1
  activeCamera.setViewOffset(w, h, x, y, 1, 1)
  const previous = renderer.outputColorSpace
  renderer.outputColorSpace = THREE.LinearSRGBColorSpace
  renderer.setRenderTarget(pickTarget)
  renderer.setViewport(0, 0, 1, 1)
  renderer.render(frameView.pick, activeCamera)
  renderer.readRenderTargetPixels(pickTarget, 0, 0, 1, 1, pickPixel)
  renderer.setRenderTarget(null)
  renderer.outputColorSpace = previous
  renderer.setViewport(0, 0, canvas.clientWidth, canvas.clientHeight)
  activeCamera.clearViewOffset()
  const id = pickPixel[0] + (pickPixel[1] << 8) + (pickPixel[2] << 16)
  return id === 0 ? -1 : id - 1
}

function decodeInWorker(buffer: ArrayBuffer): Promise<DecodedScene> {
  const worker = new Worker(new URL("./worker.ts", import.meta.url), { type: "module" })
  return new Promise((resolve, reject) => {
    worker.onmessage = (event: MessageEvent) => {
      worker.terminate()
      if (!event.data.ok) reject(new Error(event.data.message))
      else resolve({
        header: event.data.header,
        arrays: event.data.arrays,
        variants: event.data.variants,
        variantId: event.data.variantId,
      })
    }
    worker.onerror = (event) => {
      worker.terminate()
      reject(new Error(event.message))
    }
    worker.postMessage(buffer, [buffer])
  })
}

let variantFile: VariantFile | null = null
let variantId = ""
let sceneName = ""

async function openBuffer(buffer: ArrayBuffer, name: string): Promise<boolean> {
  setStatus(`Reading ${name}…`)
  sceneName = name
  try {
    const decoded = await decodeInWorker(buffer)
    variantFile = decoded.variants ?? null
    variantId = decoded.variantId ?? ""
    show(decoded)
    renderDesign()
    return true
  } catch (error) {
    setStatus(error instanceof Error ? error.message : String(error))
    return false
  }
}

const designGroup = document.querySelector("#design-group") as HTMLElement
const designAxes = document.querySelector("#design-axes") as HTMLElement
const variantMenu = document.querySelector("#variant-menu") as HTMLElement

function optionLabel(current: SceneVariant, other: SceneVariant, anchor: string): string {
  const fields = (variantFile?.axes ?? []).filter((axis) =>
    axis.anchor === anchor && current.params[axis.field]?.hash !== other.params[axis.field]?.hash)
  const labels = fields.map((axis) => other.params[axis.field]?.label ?? axis.field)
  const name = labels.join(", ") || other.id
  const bits: string[] = []
  const change = (key: string, unit: string, digits: number) => {
    const from = current.summary?.[key]
    const to = other.summary?.[key]
    if (typeof from !== "number" || typeof to !== "number") return
    const delta = to - from
    bits.push(`${delta > 0 ? "+" : ""}${delta.toFixed(digits)}${unit ? ` ${unit}` : ""}`)
  }
  change("concrete_m3", "m³", 1)
  change("embodied_carbon_kgco2e", "kg", 0)
  change("critical_ratio", "", 2)
  return bits.length ? `${name} · ${bits.join(" · ")}` : name
}

function renderDesign() {
  designAxes.replaceChildren()
  if (!variantFile || !variantId) {
    designGroup.hidden = true
    return
  }
  const current = variantFile.variants.find((item) => item.id === variantId)
  const neighbors = current ? variantNeighbors(variantFile, variantId, "none") : []
  designGroup.hidden = neighbors.length === 0
  for (const other of neighbors) {
    const button = document.createElement("button")
    button.type = "button"
    button.textContent = optionLabel(current as SceneVariant, other, "none")
    button.addEventListener("click", () => { void chooseDesign(other.id) })
    designAxes.append(button)
  }
}

function hideVariantMenu() {
  variantMenu.hidden = true
  variantMenu.replaceChildren()
}

async function chooseDesign(id: string) {
  if (!variantFile || id === variantId) return
  hideVariantMenu()
  const previous = selected?.record?.id
  const decoded = await assembleVariant(variantFile, id)
  variantId = id
  show(decoded, false)
  renderDesign()
  if (previous) reselect(previous)
}

/** Every other solved design of this plan, named by its `name` parameter. */
function floorSystemLabel(current: SceneVariant, other: SceneVariant): string {
  const name = other.params.name?.label
  const title = name && name !== "none" ? name : other.id
  const bits: string[] = []
  const change = (key: string, unit: string, digits: number) => {
    const from = current.summary?.[key]
    const to = other.summary?.[key]
    if (typeof from !== "number" || typeof to !== "number") return
    const delta = to - from
    bits.push(`${delta > 0 ? "+" : ""}${delta.toFixed(digits)}${unit ? ` ${unit}` : ""}`)
  }
  change("concrete_m3", "m³", 1)
  change("embodied_carbon_kgco2e", "kg", 0)
  change("critical_ratio", "", 2)
  return bits.length ? `${title} · ${bits.join(" · ")}` : title
}

function showVariantMenu(clientX: number, clientY: number, anchor: string) {
  if (!variantFile || !variantId) return
  const current = variantFile.variants.find((item) => item.id === variantId)
  if (!current) return
  // A floor system brings its own beams, columns, and material. A right-click
  // on the slab lists every solved system of this plan. A right-click on a
  // member still lists only the designs that change that member alone.
  const neighbors = anchor === "slab"
    ? variantFile.variants.filter((item) => item.id !== variantId)
    : variantNeighbors(variantFile, variantId, anchor)
  variantMenu.replaceChildren()
  if (neighbors.length === 0) {
    const note = document.createElement("p")
    note.textContent = anchor === "slab"
      ? "No other solved design of this plan."
      : "No other solved design changes only this."
    variantMenu.append(note)
  }
  for (const other of neighbors) {
    const button = document.createElement("button")
    button.type = "button"
    button.textContent = anchor === "slab"
      ? floorSystemLabel(current, other)
      : optionLabel(current, other, anchor)
    button.addEventListener("click", () => { void chooseDesign(other.id) })
    variantMenu.append(button)
  }
  variantMenu.hidden = false
  const width = 420
  variantMenu.style.left = `${Math.min(clientX, window.innerWidth - width - 8)}px`
  variantMenu.style.top = `${Math.min(clientY, window.innerHeight - 80)}px`
}

function loop() {
  requestAnimationFrame(loop)
  const delta = clock.getDelta()
  const started = performance.now()
  if (animateInput.checked && frameView && showingDeflection()) {
    const factor = Number(scaleInput.value)
    const wave = 0.2 + 0.8 * (0.5 + 0.5 * Math.sin(performance.now() / 700))
    frameView.uniforms.uScale.value = baseScale * factor * wave
    renderDirty = true
  }
  const moved = controls.update(delta)
  if (!moved && !renderDirty) return
  if (orthoOn) syncOrthoFrustum()
  const viewTarget = new THREE.Vector3()
  controls.getTarget(viewTarget)
  glyphs?.update(activeCamera, Math.max(canvas.clientHeight, 1), viewTarget)
  syncCutDots(viewTarget)
  renderer.info.reset()
  renderer.setRenderTarget(null)
  // three.js viewports are in CSS pixels; canvas.width is device pixels (2x on Retina).
  const w = canvas.clientWidth
  const h = canvas.clientHeight
  renderer.setViewport(0, 0, w, h)
  renderer.render(scene, activeCamera)
  axesCamera.position.copy(activeCamera.position).sub(viewTarget).normalize().multiplyScalar(3.2)
  axesCamera.up.copy(activeCamera.up)
  axesCamera.lookAt(0, 0, 0)
  renderer.setScissorTest(true)
  renderer.setViewport(w - 104, 16, 88, 88)
  renderer.setScissor(w - 104, 16, 88, 88)
  renderer.setClearColor(0x000000, 0)
  renderer.render(axesScene, axesCamera)
  renderer.setScissorTest(false)
  renderer.setClearColor(theme.background, 1)
  recordFrame(performance.now() - started)
  renderDirty = animateInput.checked
}

/** Rolling frame stats. CPU time per rendered frame and the interval between them. */
const perfEl = document.querySelector("#perf") as HTMLElement
const frameCpu: number[] = []
const frameGap: number[] = []
let lastFrameAt = 0
let perfShownAt = 0

function recordFrame(cpuMs: number) {
  const now = performance.now()
  if (lastFrameAt > 0 && now - lastFrameAt < 250) frameGap.push(now - lastFrameAt)
  lastFrameAt = now
  frameCpu.push(cpuMs)
  if (frameCpu.length > 120) frameCpu.shift()
  if (frameGap.length > 120) frameGap.shift()
  if (now - perfShownAt < 250 || !perfEl) return
  perfShownAt = now
  const p95 = (values: number[]) => {
    if (values.length === 0) return 0
    const sorted = [...values].sort((a, b) => a - b)
    return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.95))]
  }
  const gap = p95(frameGap)
  const fps = gap > 0 ? Math.min(1000 / gap, 999) : 0
  const info = renderer.info.render
  perfEl.textContent =
    `${fps ? fps.toFixed(0) : "–"} fps (p95) · cpu ${p95(frameCpu).toFixed(1)} ms · ` +
    `${info.calls} draws · ${(info.triangles / 1000).toFixed(1)}k tris · ${(info.lines / 1000).toFixed(1)}k lines`
}

scaleInput.addEventListener("input", applyScale)
cutXInput.addEventListener("input", syncCuts)
cutZInput.addEventListener("input", syncCuts)
paintRange(scaleInput)
paintRange(cutXInput)
paintRange(cutZInput)
colorInput.addEventListener("change", applyScale)
ghostInput.addEventListener("change", applyView)
loadsInput.addEventListener("change", applyView)
dimensionsInput.addEventListener("change", () => showDimensionView(dimensionView))
animateInput.addEventListener("change", applyView)
function showingDeflection(): boolean {
  return mode === "analysis" && analysisVariant === "deflection"
}

function closeMenus() {
  for (const menu of document.querySelectorAll<HTMLElement>(".menu")) {
    menu.hidden = true
    menu.parentElement?.querySelector(".caret")?.setAttribute("aria-expanded", "false")
  }
}

function selectMode(next: ViewMode) {
  mode = next
  document.querySelector("#mode-geometry")?.classList.toggle("on", next === "geometry")
  document.querySelector("#mode-analysis")?.classList.toggle("on", next === "analysis")
  applyView()
}

function selectVariant(family: ViewMode, variant: string) {
  const menu = document.querySelector(family === "geometry" ? "#geometry-menu" : "#analysis-menu")
  menu?.querySelectorAll("button").forEach((button) => {
    button.classList.toggle("on", button.dataset.variant === variant)
  })
  if (family === "geometry") {
    geometryVariant = variant as GeometryVariant
    const label = document.querySelector("#geometry-variant")
    if (label) label.textContent = VARIANT_LABEL[geometryVariant]
  } else {
    analysisVariant = variant as AnalysisVariant
    const label = document.querySelector("#analysis-variant")
    if (label) label.textContent = VARIANT_LABEL[analysisVariant]
  }
  selectMode(family)
}

document.querySelector("#mode-geometry")?.addEventListener("click", () => selectMode("geometry"))
document.querySelector("#mode-analysis")?.addEventListener("click", () => selectMode("analysis"))
for (const caret of document.querySelectorAll<HTMLButtonElement>(".caret")) {
  caret.addEventListener("click", (event) => {
    event.stopPropagation()
    const menu = caret.parentElement?.querySelector<HTMLElement>(".menu")
    if (!menu) return
    const willOpen = menu.hidden
    closeMenus()
    menu.hidden = !willOpen
    caret.setAttribute("aria-expanded", String(willOpen))
  })
}
for (const family of ["geometry", "analysis"] as const) {
  document.querySelector(`#${family}-menu`)?.addEventListener("click", (event) => {
    const button = (event.target as HTMLElement).closest("button")
    const variant = button?.dataset.variant
    if (!variant) return
    closeMenus()
    selectVariant(family, variant)
  })
}
document.addEventListener("click", (event) => {
  if ((event.target as HTMLElement).closest?.(".choice")) return
  closeMenus()
})
document.querySelector("#detail-close")?.addEventListener("click", closeDetail)
document.querySelector("#fit")?.addEventListener("click", fit)
document.querySelector("#iso")?.addEventListener("click", () => {
  setOrtho(false)
  viewFrom(Math.PI / 4, Math.PI / 3.2)
  showDimensionView("ground")
  resetElevationButton()
})
document.querySelector("#top")?.addEventListener("click", () => {
  setOrtho(true)
  viewFrom(0, 0.01)
  showDimensionView("ground")
  resetElevationButton()
})
document.querySelector("#front")?.addEventListener("click", () => {
  const face = elevations[elevationIndex]
  setOrtho(true)
  viewFrom(face.azimuth, Math.PI / 2)
  showDimensionView(face.view)
  elevationIndex = (elevationIndex + 1) % elevations.length
  const button = document.querySelector("#front")
  if (button) button.textContent = elevations[elevationIndex].label
})
document.querySelector("#proj-perspective")?.addEventListener("click", () => setOrtho(false))
document.querySelector("#proj-ortho")?.addEventListener("click", () => setOrtho(true))
document.querySelector("#png")?.addEventListener("click", () => {
  const transparent = (document.querySelector("#transparent") as HTMLInputElement).checked
  const previous = scene.background
  if (transparent) scene.background = null
  renderer.render(scene, activeCamera)
  const url = renderer.domElement.toDataURL("image/png")
  scene.background = previous
  const link = document.createElement("a")
  link.href = url
  link.download = "scene.png"
  link.click()
  renderDirty = true
})

fileInput.addEventListener("change", () => {
  const file = fileInput.files?.[0]
  if (!file) return
  file.arrayBuffer().then((buffer) => openBuffer(buffer, file.name))
})
window.addEventListener("dragover", (event) => event.preventDefault())
window.addEventListener("drop", (event) => {
  event.preventDefault()
  const file = event.dataTransfer?.files?.[0]
  if (!file) return
  file.arrayBuffer().then((buffer) => openBuffer(buffer, file.name))
})
window.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    if (!variantMenu.hidden) hideVariantMenu()
    else closeDetail()
  }
  if (event.key === "f" && !(event.target instanceof HTMLInputElement)) fit()
})
window.addEventListener("pointerdown", (event) => {
  if (variantMenu.hidden) return
  if (event.target instanceof Node && variantMenu.contains(event.target)) return
  hideVariantMenu()
})
interface FloorScene {
  file: string
  name: string
}

/** Solved floor systems of this building. Written as each design finishes. */
async function showFloorMenu(clientX: number, clientY: number) {
  const response = await fetch("/core_office_floors.json", { cache: "no-store" })
  if (!response.ok) {
    hideVariantMenu()
    return
  }
  const data = await response.json() as { scenes?: FloorScene[] }
  const scenes = data.scenes ?? []
  if (!scenes.some((item) => item.file === sceneName)) {
    hideVariantMenu()
    return
  }
  variantMenu.replaceChildren()
  const current = scenes.find((item) => item.file === sceneName)
  const note = document.createElement("p")
  note.textContent = current?.name ?? "Core office"
  variantMenu.append(note)
  for (const other of scenes) {
    if (other.file === sceneName) continue
    const button = document.createElement("button")
    button.type = "button"
    button.textContent = other.name
    button.addEventListener("click", () => {
      location.search = `?scene=${encodeURIComponent(other.file)}`
    })
    variantMenu.append(button)
  }
  variantMenu.hidden = false
  const width = 420
  variantMenu.style.left = `${Math.min(clientX, window.innerWidth - width - 8)}px`
  variantMenu.style.top = `${Math.min(clientY, window.innerHeight - 80)}px`
}

canvas.addEventListener("contextmenu", (event) => {
  event.preventDefault()
  const hit = pickComponent(event.clientX, event.clientY)
  const anchor = hit?.record?.kind
  if (variantFile && anchor && ["slab", "column", "beam", "wall", "footing"].includes(anchor)) {
    showVariantMenu(event.clientX, event.clientY, anchor)
    return
  }
  if (anchor === "slab") {
    void showFloorMenu(event.clientX, event.clientY)
    return
  }
  hideVariantMenu()
})
canvas.addEventListener("dblclick", (event) => {
  const hit = pickComponent(event.clientX, event.clientY)
  if (!hit) return
  openDetail(hit, true)
})

const MEMBER_TYPE = ["Beam", "Column", "Brace"]

function nodePoint(index: number, displaced: boolean): THREE.Vector3 {
  const p = new THREE.Vector3(nodePosition[index * 3], nodePosition[index * 3 + 1], nodePosition[index * 3 + 2])
  if (displaced && frameView) {
    p.add(new THREE.Vector3(
      nodeDisplacement[index * 3], nodeDisplacement[index * 3 + 1], nodeDisplacement[index * 3 + 2],
    ).multiplyScalar(frameView.uniforms.uScale.value))
  }
  return p
}

function nodeDispMm(index: number): number {
  return Math.hypot(
    nodeDisplacement[index * 3] ?? 0,
    nodeDisplacement[index * 3 + 1] ?? 0,
    nodeDisplacement[index * 3 + 2] ?? 0,
  ) * 1000
}

interface ComponentHit {
  title: string
  facts: string
  points: THREE.Vector3[]
  padding?: number
  role: "shell" | "member" | "footing"
  nodeIds?: number[]
  elements?: number[]
  shellKind?: number
  footing?: number
  record: ComponentRecord | null
}

let selected: ComponentHit | null = null
let overlayMode: OverlayMode = "diagram"
let overlayFor = ""
const outlineMaterial = new THREE.LineBasicMaterial({ color: theme.charcoal })

function shellKindOf(kind: number): number {
  return kind === 1 ? 1 : kind === 2 ? 2 : 0
}

/** Every analysis node of the picked slab or wall, so the zoom frames the whole surface. */
function shellZoomPoints(kind: number, ids: number[]): THREE.Vector3[] {
  const normalized = shellKindOf(kind)
  const nodes = normalized === 1 ? coplanarNodes(ids) : levelNodes(normalized, ids)
  const chosen = nodes.length > 0 ? nodes : ids
  const displaced = showingDeflection()
  return chosen.map((id) => nodePoint(id, displaced))
}

function levelNodes(kind: number, ids: number[]): number[] {
  if (ids.length === 0) return []
  let y = 0
  for (const id of ids) y += nodePosition[id * 3 + 1] ?? 0
  y /= ids.length
  const seen = new Set<number>()
  for (let t = 0; t < shellKinds.length; t++) {
    if (shellKindOf(shellKinds[t] ?? 0) !== kind) continue
    const tri = [shellFaces[t * 3], shellFaces[t * 3 + 1], shellFaces[t * 3 + 2]]
    let flat = true
    for (const id of tri) {
      if (Math.abs((nodePosition[id * 3 + 1] ?? 0) - y) > 0.5) flat = false
    }
    if (!flat) continue
    for (const id of tri) seen.add(id)
  }
  return [...seen]
}

/** Nodes of every shell triangle the scene assigns to wall `wallIndex`. */
function wallNodes(wallIndex: number): number[] {
  const seen = new Set<number>()
  for (let t = 0; t < shellWall.length; t++) {
    if (shellWall[t] !== wallIndex) continue
    seen.add(shellFaces[t * 3])
    seen.add(shellFaces[t * 3 + 1])
    seen.add(shellFaces[t * 3 + 2])
  }
  return [...seen]
}

function coplanarNodes(ids: number[]): number[] {
  if (ids.length < 3) return []
  const ax = nodePosition[ids[0] * 3]
  const ay = nodePosition[ids[0] * 3 + 1]
  const az = nodePosition[ids[0] * 3 + 2]
  const bx = nodePosition[ids[1] * 3]
  const by = nodePosition[ids[1] * 3 + 1]
  const bz = nodePosition[ids[1] * 3 + 2]
  const cx = nodePosition[ids[2] * 3]
  const cy = nodePosition[ids[2] * 3 + 1]
  const cz = nodePosition[ids[2] * 3 + 2]
  let nx = (by - ay) * (cz - az) - (bz - az) * (cy - ay)
  let ny = (bz - az) * (cx - ax) - (bx - ax) * (cz - az)
  let nz = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
  const nl = Math.hypot(nx, ny, nz)
  if (!(nl > 1e-10)) return []
  nx /= nl
  ny /= nl
  nz /= nl
  const seen = new Set<number>()
  for (let t = 0; t < shellKinds.length; t++) {
    if (shellKindOf(shellKinds[t] ?? 0) !== 1) continue
    const tri = [shellFaces[t * 3], shellFaces[t * 3 + 1], shellFaces[t * 3 + 2]]
    const p0 = tri[0] * 3
    const p1 = tri[1] * 3
    const p2 = tri[2] * 3
    const e1x = nodePosition[p1] - nodePosition[p0]
    const e1y = nodePosition[p1 + 1] - nodePosition[p0 + 1]
    const e1z = nodePosition[p1 + 2] - nodePosition[p0 + 2]
    const e2x = nodePosition[p2] - nodePosition[p0]
    const e2y = nodePosition[p2 + 1] - nodePosition[p0 + 1]
    const e2z = nodePosition[p2 + 2] - nodePosition[p0 + 2]
    const mx = e1y * e2z - e1z * e2y
    const my = e1z * e2x - e1x * e2z
    const mz = e1x * e2y - e1y * e2x
    const ml = Math.hypot(mx, my, mz)
    if (!(ml > 1e-10) || Math.abs((mx * nx + my * ny + mz * nz) / ml) < 0.9) continue
    let onPlane = true
    for (const id of tri) {
      const dx = nodePosition[id * 3] - ax
      const dy = nodePosition[id * 3 + 1] - ay
      const dz = nodePosition[id * 3 + 2] - az
      if (Math.abs(dx * nx + dy * ny + dz * nz) > 0.25) onPlane = false
    }
    if (!onPlane) continue
    for (const id of tri) seen.add(id)
  }
  return [...seen]
}

function pickComponent(clientX: number, clientY: number): ComponentHit | null {
  if (!frameView) return null
  const rect = canvas.getBoundingClientRect()
  ndc.set(((clientX - rect.left) / rect.width) * 2 - 1, -((clientY - rect.top) / rect.height) * 2 + 1)
  raycaster.setFromCamera(ndc, activeCamera)
  const target = new THREE.Vector3()
  controls.getTarget(target)
  raycaster.params.Line.threshold = Math.max(0.25, activeCamera.position.distanceTo(target) * 0.01)
  const objects: THREE.Object3D[] = []
  if (frameView.high.visible) objects.push(frameView.high)
  if (frameView.low.visible) objects.push(frameView.low)
  if (frameView.rods.visible) objects.push(frameView.rods)
  for (const mesh of building?.shells ?? []) if (mesh.visible) objects.push(mesh)
  if (building?.footings?.visible) objects.push(building.footings)
  if (memberSolids?.visible) objects.push(memberSolids)
  if (shellVolumes?.visible) objects.push(shellVolumes)
  if (deckGroup?.visible) objects.push(...deckGroup.children)
  const hit = raycaster.intersectObjects(objects, false).find((candidate: { point: THREE.Vector3 }) => (
    clipX.distanceToPoint(candidate.point) >= -1e-3 && clipZ.distanceToPoint(candidate.point) >= -1e-3
  ))
  if (!hit) return null
  const role = hit.object.userData.role
  if (role === "shell-volume" && hit.faceIndex !== undefined && hit.faceIndex !== null) {
    const tri = hit.object.userData.source[hit.faceIndex]
    const faces = hit.object.userData.faces as Uint32Array
    const kind = hit.object.userData.kinds[tri]
    const ids = [faces[tri * 3], faces[tri * 3 + 1], faces[tri * 3 + 2]]
    const mm = ids.map(nodeDispMm)
    return shellComponentHit(kind, ids, `Vertices ${ids.join(", ")}\nDeflection ${mm.map((v) => v.toFixed(2)).join(", ")} mm\nMaximum ${Math.max(...mm).toFixed(2)} mm`, tri)
  }
  if (role === "shell" && hit.face) {
    const kind = Number(hit.object.userData.kind)
    const ids = [hit.face.a, hit.face.b, hit.face.c]
    const source = hit.object.userData.source as Uint32Array | undefined
    const tri = hit.faceIndex !== undefined && hit.faceIndex !== null ? source?.[hit.faceIndex] : undefined
    const mm = ids.map(nodeDispMm)
    return shellComponentHit(kind, ids, `Vertices ${ids.join(", ")}\nDeflection ${mm.map((v) => v.toFixed(2)).join(", ")} mm\nMaximum ${Math.max(...mm).toFixed(2)} mm`, tri)
  }
  if (role === "footing" && hit.instanceId !== undefined) {
    const i = hit.instanceId
    const L = footingSize[i * 3]
    const D = footingSize[i * 3 + 1]
    const W = footingSize[i * 3 + 2]
    const c = new THREE.Vector3(footingCenter[i * 3], footingCenter[i * 3 + 1], footingCenter[i * 3 + 2])
    const record = matchFooting(componentRecords, i)
    return {
      title: record?.title ?? footingTitle(footingKind[i] ?? 0, i),
      facts: `Plan ${L.toFixed(2)} × ${W.toFixed(2)} m\nThickness ${D.toFixed(3)} m`,
      points: [
        c.clone().add(new THREE.Vector3(-L / 2, -D / 2, -W / 2)),
        c.clone().add(new THREE.Vector3(L / 2, D / 2, W / 2)),
      ],
      role: "footing",
      footing: i,
      record,
    }
  }
  if (role === "member-solid" && hit.faceIndex !== undefined && hit.faceIndex !== null) {
    return memberHit(hit.object.userData.owner[hit.faceIndex])
  }
  if (role === "member-rod" && hit.faceIndex !== undefined && hit.faceIndex !== null) {
    return memberHit(Math.floor(hit.faceIndex / Number(hit.object.userData.trisPer)))
  }
  if (hit.index === undefined) return null
  return memberHit(Math.round(hit.object.geometry.getAttribute("aElem").getX(hit.index)))
}

function memberHit(element: number): ComponentHit | null {
  if (!frameView || element < 0 || element >= elementType.length) return null
  const a = elementNodes[element * 2]
  const b = elementNodes[element * 2 + 1]
  const length = nodePoint(a, false).distanceTo(nodePoint(b, false))
  const mid = frameView.midDisplacement(element).length() * 1000
  const section = elementSection[element]
  const lines = [
    section === "solid head" ? "Solid head" : section ? `Section ${section}` : "No sized section in this scene",
    `Length ${length.toFixed(2)} m`,
    `Midspan deflection ${mid.toFixed(2)} mm`,
  ]
  const record = matchFrame(componentRecords, element)
  const elements = record?.bind?.frame_elements?.length ? record.bind.frame_elements : [element]
  const points: THREE.Vector3[] = []
  for (const index of elements) {
    const ia = elementNodes[index * 2]
    const ib = elementNodes[index * 2 + 1]
    if (ia === undefined || ib === undefined) continue
    points.push(nodePoint(ia, true), nodePoint(ib, true))
  }
  return {
    title: record?.title ?? `${MEMBER_TYPE[elementType[element] ?? 0] ?? "Member"} ${element}`,
    facts: lines.join("\n"),
    points: points.length > 0 ? points : [nodePoint(a, true), nodePoint(b, true)],
    role: "member",
    elements,
    record,
  }
}

function shellComponentHit(kind: number, ids: number[], facts: string, triangle?: number): ComponentHit {
  const normalized = shellKindOf(kind)
  const elevation = ids.reduce((sum, id) => sum + (nodePosition[id * 3 + 1] ?? 0), 0) / Math.max(ids.length, 1)
  const anchor = nodePoint(ids[0], false)
  const wall = triangle !== undefined && shellWall.length > 0 ? shellWall[triangle] ?? 0 : 0
  const record = wall > 0
    ? matchWall(componentRecords, wall)
    : matchShell(componentRecords, normalized, elevation, { x: anchor.x, y: anchor.y, z: anchor.z })
  const nodeIds = wall > 0 ? wallNodes(wall) : componentNodes(record, normalized, ids)
  return {
    title: record?.title ?? SHELL_KIND_NAME[normalized] ?? "Shell",
    facts,
    points: (nodeIds.length > 0 ? nodeIds : ids).map((id) => nodePoint(id, showingDeflection())),
    padding: 1.45,
    role: "shell",
    shellKind: normalized,
    nodeIds,
    record,
  }
}

function componentNodes(record: ComponentRecord | null, kind: number, ids: number[]): number[] {
  if (record?.kind === "slab" && typeof record.bind?.elevation_m === "number") {
    return nodesNearElevation(record.bind.elevation_m, [0, 2])
  }
  if (record?.kind === "wall") {
    const onPlane = coplanarNodes(ids)
    const z0 = record.bind?.z0_m
    const z1 = record.bind?.z1_m
    if (typeof z0 !== "number" || typeof z1 !== "number") return onPlane
    const lo = Math.min(z0, z1) - 0.2
    const hi = Math.max(z0, z1) + 0.2
    return onPlane.filter((id) => {
      const y = nodePosition[id * 3 + 1] ?? 0
      return y >= lo && y <= hi
    })
  }
  return kind === 1 ? coplanarNodes(ids) : levelNodes(kind, ids)
}

function nodesNearElevation(elevation: number, kinds: number[]): number[] {
  const seen = new Set<number>()
  for (let t = 0; t < shellKinds.length; t++) {
    if (!kinds.includes(shellKindOf(shellKinds[t] ?? 0))) continue
    const tri = [shellFaces[t * 3], shellFaces[t * 3 + 1], shellFaces[t * 3 + 2]]
    if (!tri.every((id) => Math.abs((nodePosition[id * 3 + 1] ?? 0) - elevation) <= 0.5)) continue
    for (const id of tri) seen.add(id)
  }
  return [...seen]
}

function paintKeep(hit: ComponentHit | null) {
  const nodes = hit?.role === "shell" ? new Set(hit.nodeIds ?? []) : hit ? new Set<number>() : null
  const elements = hit?.role === "member" ? new Set(hit.elements ?? []) : hit ? new Set<number>() : null
  for (const mesh of building?.shells ?? []) fillNodeKeep(mesh.geometry, nodes)
  if (frameView) {
    fillElementKeep(frameView.high.geometry, elements, false)
    fillElementKeep(frameView.low.geometry, elements, false)
    fillElementKeep(frameView.rods.geometry, elements, true)
  }
  if (memberSolids) fillSolidKeep(memberSolids, elements)
  if (shellVolumes) fillVolumeKeep(shellVolumes, nodes)
  deckGroup?.traverse((obj: THREE.Object3D) => {
    const body = obj as THREE.Mesh
    if (body.userData.vertexSource) fillVolumeKeep(body, nodes)
  })
}

function fillNodeKeep(geometry: THREE.BufferGeometry, nodes: Set<number> | null) {
  const attr = geometry.getAttribute("aKeep") as THREE.BufferAttribute | undefined
  if (!attr) return
  const values = attr.array as Float32Array
  if (nodes === null) values.fill(1)
  else for (let i = 0; i < values.length; i++) values[i] = nodes.has(i) ? 1 : 0
  attr.needsUpdate = true
}

function fillElementKeep(geometry: THREE.BufferGeometry, elements: Set<number> | null, rods: boolean) {
  const attr = geometry.getAttribute("aKeep") as THREE.BufferAttribute | undefined
  if (!attr) return
  const values = attr.array as Float32Array
  if (elements === null) {
    values.fill(1)
  } else if (rods) {
    const vertPer = Math.max(1, Number(frameView?.rods.userData.vertPer ?? 1))
    for (let i = 0; i < values.length; i++) values[i] = elements.has(Math.floor(i / vertPer)) ? 1 : 0
  } else {
    const elem = geometry.getAttribute("aElem") as THREE.BufferAttribute | undefined
    if (!elem) return
    for (let i = 0; i < values.length; i++) values[i] = elements.has(Math.round(elem.getX(i))) ? 1 : 0
  }
  attr.needsUpdate = true
}

function fillVolumeKeep(mesh: THREE.Mesh, nodes: Set<number> | null) {
  const attr = mesh.geometry.getAttribute("aKeep") as THREE.BufferAttribute | undefined
  const source = mesh.userData.vertexSource as Uint32Array | undefined
  const faces = mesh.userData.faces as Uint32Array | undefined
  if (!attr || !source || !faces) return
  const values = attr.array as Float32Array
  if (nodes === null) values.fill(1)
  else {
    for (let i = 0; i < values.length; i++) {
      const t = source[i] ?? 0
      const a = faces[t * 3]
      const b = faces[t * 3 + 1]
      const c = faces[t * 3 + 2]
      values[i] = nodes.has(a) && nodes.has(b) && nodes.has(c) ? 1 : 0
    }
  }
  attr.needsUpdate = true
}

function fillSolidKeep(mesh: THREE.Mesh, elements: Set<number> | null) {
  const attr = mesh.geometry.getAttribute("aKeep") as THREE.BufferAttribute | undefined
  const index = mesh.geometry.getIndex()
  const owner = mesh.userData.owner as Uint32Array | undefined
  if (!attr || !index || !owner) return
  const values = attr.array as Float32Array
  values.fill(elements === null ? 1 : 0)
  if (elements) {
    for (let t = 0; t < owner.length; t++) {
      if (!elements.has(owner[t])) continue
      for (let k = 0; k < 3; k++) values[index.getX(t * 3 + k)] = 1
    }
  }
  attr.needsUpdate = true
}

const FOOTING_NAMES = ["spread", "strip", "combined", "mat", "wall strip"]

function footingTitle(kind: number, index: number): string {
  const name = FOOTING_NAMES[kind] ?? "footing"
  return `${name} ${index + 1}`
}

/** "1 mat, 12 spreads". An older file has no kind buffer and counts as spreads. */
function footingStatus(count: number, kinds: Uint8Array): string {
  const plural: Record<string, string> = {
    spread: "spreads", strip: "strips", combined: "combined footings",
    mat: "mats", "wall strip": "wall strips", footing: "footings",
  }
  const tally = new Map<string, number>()
  for (let i = 0; i < count; i++) {
    const name = FOOTING_NAMES[kinds.length === count ? kinds[i] : 0] ?? "footing"
    tally.set(name, (tally.get(name) ?? 0) + 1)
  }
  return [...tally.entries()]
    .map(([name, n]) => `${n} ${n === 1 ? name : plural[name] ?? name}`)
    .join(", ")
}

function bindFootingNodes(decoded: DecodedScene, count: number): number[][] {
  const counts = typed(decoded.arrays, "footing_support_count", "u32") as Uint32Array
  const nodes = typed(decoded.arrays, "footing_support_node", "u32") as Uint32Array
  if (counts.length === count && count > 0) {
    const out: number[][] = []
    let cursor = 0
    for (let i = 0; i < count; i++) {
      const n = counts[i] ?? 0
      const group: number[] = []
      for (let k = 0; k < n; k++) {
        const id = nodes[cursor++]
        if (id === undefined || id * 3 + 2 >= nodePosition.length) {
          throw new Error(`footing support node ${id} is outside the analysis model`)
        }
        group.push(id)
      }
      out.push(group)
    }
    if (cursor !== nodes.length) throw new Error("footing support nodes do not match the counts")
    return out
  }
  return matchFootingSupports(count)
}

/** A scene written before `footing_support_node` still belongs to its fixed supports. */
function matchFootingSupports(count: number): number[][] {
  const fixed: number[] = []
  for (let i = 0; i < supportIndex.length; i++) {
    if (supportFixity[i] === 0x3f) fixed.push(supportIndex[i] ?? 0)
  }
  const out: number[][] = []
  for (let i = 0; i < count; i++) {
    const cx = footingCenter[i * 3] ?? 0
    const cz = footingCenter[i * 3 + 2] ?? 0
    const hx = (footingSize[i * 3] ?? 0) / 2 + 0.05
    const hz = (footingSize[i * 3 + 2] ?? 0) / 2 + 0.05
    const inside = fixed.filter((id) => {
      const x = nodePosition[id * 3] ?? 0
      const z = nodePosition[id * 3 + 2] ?? 0
      return Math.abs(x - cx) <= hx && Math.abs(z - cz) <= hz
    })
    if (inside.length > 0) {
      out.push(inside)
      continue
    }
    let best = -1
    let bestD = Infinity
    for (const id of fixed) {
      const dx = (nodePosition[id * 3] ?? 0) - cx
      const dz = (nodePosition[id * 3 + 2] ?? 0) - cz
      const d = dx * dx + dz * dz
      if (d < bestD) {
        bestD = d
        best = id
      }
    }
    const reach = Math.max(hx, hz, 1)
    out.push(best >= 0 && bestD <= reach * reach ? [best] : [])
  }
  return out
}

function footingDisplacement(groups: number[][]): Float32Array {
  const out = new Float32Array(groups.length * 3)
  for (let i = 0; i < groups.length; i++) {
    const ids = groups[i] ?? []
    if (ids.length === 0) continue
    let x = 0
    let y = 0
    let z = 0
    for (const id of ids) {
      x += nodeDisplacement[id * 3] ?? 0
      y += nodeDisplacement[id * 3 + 1] ?? 0
      z += nodeDisplacement[id * 3 + 2] ?? 0
    }
    out[i * 3] = x / ids.length
    out[i * 3 + 1] = y / ids.length
    out[i * 3 + 2] = z / ids.length
  }
  return out
}

/**
 * The footing is the concrete on its support nodes. Geometry uses the column
 * concrete. Analysis colors it with those nodes' displacement, on the same scale
 * as the building. A fixed support sits at the zero of that scale.
 */
function placeFootings() {
  const mesh = building?.footings
  if (!mesh) return
  const colored = colorInput.checked && showingDeflection()
  const scale = showingDeflection() ? frameView?.uniforms.uScale.value ?? 0 : 0
  const denom = Math.max(building?.maxDisplacement ?? 0, 1e-12)
  const color = new THREE.Color()
  const matrix = new THREE.Matrix4()
  const translation = new THREE.Vector3()
  const quaternion = new THREE.Quaternion()
  const box = new THREE.Vector3()
  const keepAttr = mesh.geometry.getAttribute("aKeep") as THREE.BufferAttribute | undefined
  const keep = keepAttr ? keepAttr.array as Float32Array : null
  const dimmed = selected !== null
  const kept = selected?.role === "footing" ? selected.footing ?? -1 : dimmed ? -1 : null
  for (let i = 0; i < mesh.count; i++) {
    const mag = Math.hypot(footingDisp[i * 3] ?? 0, footingDisp[i * 3 + 1] ?? 0, footingDisp[i * 3 + 2] ?? 0)
    if (colored) deflectionColor(mag / denom, color)
    else color.set(theme.concrete)
    if (keep) keep[i] = kept === null || i === kept ? 1 : 0
    mesh.setColorAt(i, color)
    translation.set(
      (footingCenter[i * 3] ?? 0) + scale * (footingDisp[i * 3] ?? 0),
      (footingCenter[i * 3 + 1] ?? 0) + scale * (footingDisp[i * 3 + 1] ?? 0),
      (footingCenter[i * 3 + 2] ?? 0) + scale * (footingDisp[i * 3 + 2] ?? 0),
    )
    box.set(footingSize[i * 3] ?? 1, footingSize[i * 3 + 1] ?? 1, footingSize[i * 3 + 2] ?? 1)
    matrix.compose(translation, quaternion, box)
    mesh.setMatrixAt(i, matrix)
  }
  mesh.instanceMatrix.needsUpdate = true
  if (mesh.instanceColor) mesh.instanceColor.needsUpdate = true
  if (keepAttr) keepAttr.needsUpdate = true
  sectionHatch.resync()
  renderDirty = true
}

function clearOutline() {
  for (const child of [...outline.children]) {
    outline.remove(child)
    ;(child as THREE.LineSegments).geometry?.dispose?.()
  }
}

function rebuildOutline() {
  clearOutline()
  if (!selected) return
  const positions: number[] = []
  if (selected.role === "shell") addShellBoundary(positions, selected.nodeIds ?? [])
  if (selected.role === "member") {
    if (memberSolids?.visible) addSolidOutline(positions, selected.elements ?? [])
    else addRodWire(positions, selected.elements ?? [])
  }
  if (selected.role === "footing" && selected.footing !== undefined) addFootingBox(positions, selected.footing)
  if (positions.length < 6) return
  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute("position", new THREE.BufferAttribute(new Float32Array(positions), 3))
  const line = new THREE.LineSegments(geometry, outlineMaterial)
  line.userData.noclip = false
  outline.add(line)
  renderDirty = true
}

function addShellBoundary(positions: number[], nodes: number[]) {
  const keep = new Set(nodes)
  const seen = new Map<string, number>()
  for (let t = 0; t < shellKinds.length; t++) {
    const tri = [shellFaces[t * 3], shellFaces[t * 3 + 1], shellFaces[t * 3 + 2]]
    if (!tri.every((id) => keep.has(id))) continue
    for (let e = 0; e < 3; e++) {
      const a = tri[e]
      const b = tri[(e + 1) % 3]
      const key = a < b ? `${a}:${b}` : `${b}:${a}`
      seen.set(key, (seen.get(key) ?? 0) + 1)
    }
  }
  for (const [key, count] of seen) {
    if (count !== 1) continue
    const [a, b] = key.split(":").map(Number)
    const pa = nodePoint(a, true)
    const pb = nodePoint(b, true)
    positions.push(pa.x, pa.y, pa.z, pb.x, pb.y, pb.z)
  }
}

function addRodWire(positions: number[], elements: number[]) {
  const mesh = frameView?.rods
  if (!mesh) return
  const pos = mesh.geometry.getAttribute("position") as THREE.BufferAttribute | undefined
  const disp = mesh.geometry.getAttribute("aDisp") as THREE.BufferAttribute | undefined
  if (!pos || !disp) return
  const vertPer = Math.max(4, Number(mesh.userData.vertPer ?? 4))
  const corners = 4
  const rings = Math.max(2, Math.floor(vertPer / corners))
  const scale = frameView?.uniforms.uScale.value ?? 0
  for (const element of elements) {
    const base = element * vertPer
    if (base + vertPer > pos.count) continue
    for (let c = 0; c < corners; c++) {
      for (let s = 0; s < rings - 1; s++) {
        pushDisplaced(positions, pos, disp, base + s * corners + c, scale)
        pushDisplaced(positions, pos, disp, base + (s + 1) * corners + c, scale)
      }
      for (const s of [0, rings - 1]) {
        pushDisplaced(positions, pos, disp, base + s * corners + c, scale)
        pushDisplaced(positions, pos, disp, base + s * corners + ((c + 1) % corners), scale)
      }
    }
  }
}

function pushDisplaced(positions: number[], pos: THREE.BufferAttribute, disp: THREE.BufferAttribute, index: number, scale: number) {
  positions.push(
    pos.getX(index) + scale * disp.getX(index),
    pos.getY(index) + scale * disp.getY(index),
    pos.getZ(index) + scale * disp.getZ(index),
  )
}

function addSolidOutline(positions: number[], elements: number[]) {
  const mesh = memberSolids
  if (!mesh) return
  const index = mesh.geometry.getIndex()
  const pos = mesh.geometry.getAttribute("position") as THREE.BufferAttribute | undefined
  const owner = mesh.userData.owner as Uint32Array | undefined
  if (!index || !pos || !owner) return
  const want = new Set(elements)
  const edges = new Map<string, { a: number; b: number; nx: number; ny: number; nz: number; nx2: number; ny2: number; nz2: number; count: number }>()
  for (let t = 0; t < owner.length; t++) {
    if (!want.has(owner[t])) continue
    const i0 = index.getX(t * 3)
    const i1 = index.getX(t * 3 + 1)
    const i2 = index.getX(t * 3 + 2)
    const n = faceNormal(pos, i0, i1, i2)
    for (const [a, b] of [[i0, i1], [i1, i2], [i2, i0]] as const) {
      const key = a < b ? `${a}:${b}` : `${b}:${a}`
      const prev = edges.get(key)
      if (!prev) edges.set(key, { a, b, nx: n[0], ny: n[1], nz: n[2], nx2: 0, ny2: 0, nz2: 0, count: 1 })
      else {
        prev.count += 1
        prev.nx2 = n[0]
        prev.ny2 = n[1]
        prev.nz2 = n[2]
      }
    }
  }
  for (const edge of edges.values()) {
    const crease = edge.nx * edge.nx2 + edge.ny * edge.ny2 + edge.nz * edge.nz2
    if (edge.count !== 1 && crease > 0.85) continue
    positions.push(pos.getX(edge.a), pos.getY(edge.a), pos.getZ(edge.a), pos.getX(edge.b), pos.getY(edge.b), pos.getZ(edge.b))
  }
}

function faceNormal(pos: THREE.BufferAttribute, i0: number, i1: number, i2: number): [number, number, number] {
  const ax = pos.getX(i1) - pos.getX(i0)
  const ay = pos.getY(i1) - pos.getY(i0)
  const az = pos.getZ(i1) - pos.getZ(i0)
  const bx = pos.getX(i2) - pos.getX(i0)
  const by = pos.getY(i2) - pos.getY(i0)
  const bz = pos.getZ(i2) - pos.getZ(i0)
  let nx = ay * bz - az * by
  let ny = az * bx - ax * bz
  let nz = ax * by - ay * bx
  const len = Math.hypot(nx, ny, nz) || 1
  return [nx / len, ny / len, nz / len]
}

function addFootingBox(positions: number[], index: number) {
  const L = footingSize[index * 3]
  const D = footingSize[index * 3 + 1]
  const W = footingSize[index * 3 + 2]
  const scale = showingDeflection() ? frameView?.uniforms.uScale.value ?? 0 : 0
  const c = [
    (footingCenter[index * 3] ?? 0) + scale * (footingDisp[index * 3] ?? 0),
    (footingCenter[index * 3 + 1] ?? 0) + scale * (footingDisp[index * 3 + 1] ?? 0),
    (footingCenter[index * 3 + 2] ?? 0) + scale * (footingDisp[index * 3 + 2] ?? 0),
  ]
  const corners: number[][] = []
  for (const sx of [-1, 1]) {
    for (const sy of [-1, 1]) {
      for (const sz of [-1, 1]) corners.push([c[0] + sx * L / 2, c[1] + sy * D / 2, c[2] + sz * W / 2])
    }
  }
  const edges = [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]]
  for (const [a, b] of edges) positions.push(...corners[a], ...corners[b])
}

function reselect(id: string) {
  const record = componentRecords.find((item) => item.id === id)
  if (!record) {
    closeDetail()
    return
  }
  if ((record.kind === "column" || record.kind === "beam") && record.bind?.frame_elements?.length) {
    const hit = memberHit(record.bind.frame_elements[0])
    if (hit) {
      openDetail(hit, false)
      return
    }
  }
  if (record.kind === "footing" && typeof record.bind?.footing === "number") {
    const i = record.bind.footing
    const L = footingSize[i * 3]
    const D = footingSize[i * 3 + 1]
    const W = footingSize[i * 3 + 2]
    if (L !== undefined && D !== undefined && W !== undefined) {
      const c = new THREE.Vector3(footingCenter[i * 3], footingCenter[i * 3 + 1], footingCenter[i * 3 + 2])
      openDetail({
        title: record.title,
        facts: `Plan ${L.toFixed(2)} × ${W.toFixed(2)} m\nThickness ${D.toFixed(3)} m`,
        points: [
          c.clone().add(new THREE.Vector3(-L / 2, -D / 2, -W / 2)),
          c.clone().add(new THREE.Vector3(L / 2, D / 2, W / 2)),
        ],
        role: "footing",
        footing: i,
        record,
      }, false)
      return
    }
  }
  if (record.kind === "slab" && typeof record.bind?.elevation_m === "number") {
    const ids = nodesNearElevation(record.bind.elevation_m, record.bind.shell_kinds ?? [0, 2])
    if (ids.length >= 3) {
      openDetail(shellComponentHit(0, ids.slice(0, 3), record.title), false)
      return
    }
  }
  closeDetail()
}

function closeDetail() {
  selected = null
  overlayMode = "diagram"
  overlayFor = ""
  detailEl.hidden = true
  document.body.classList.remove("detail-open")
  paintKeep(null)
  placeFootings()
  clearOutline()
  applyView()
  resize()
}

function overlayScene(): OverlayScene {
  return {
    nodePosition,
    nodeDisplacement,
    displacementPresent,
    maxDisplacement: building?.maxDisplacement ?? Math.abs(Number(header?.max_displacement ?? 0)),
    shellFaces,
    shellKinds,
    shellStress,
    stressPresent,
    maxStress,
    shellAxial,
    shellAxialPresent,
    shellWall,
    elementNodes,
    elementAxial,
    axialPresent: elementAxial.length > 0 && elementAxial.length === (frameView?.elementCount ?? -1),
    maxAxial,
    localDof,
    lcs: elementLcs,
    loadElement: loadElementIndex,
    particular: loadParticular,
    stations: solvedStations,
    tributaryPosition,
    tributaryCount,
    tributaryKind,
    tributaryElement,
    tributaryCell,
    tributaryPresent: tributaryGroup !== null,
    footingDisp,
  }
}

function paintDetail() {
  if (!selected) return
  const id = selected.record?.id ?? selected.title
  if (id !== overlayFor) {
    overlayMode = "diagram"
    overlayFor = id
  }
  if (overlayMode === "tributary" && selected.record?.kind !== "slab") overlayMode = "diagram"
  renderDetail(selected.record, selected.title, selected.facts, overlayMode, overlayScene(), (next) => {
    overlayMode = next
    paintDetail()
  })
}

function openDetail(hit: ComponentHit, zoom: boolean) {
  selected = hit
  paintDetail()
  detailEl.hidden = false
  document.body.classList.add("detail-open")
  resize()
  applyView()
  paintKeep(hit)
  placeFootings()
  rebuildOutline()
  infoEl.textContent = hit.title
  if (zoom) zoomTo(hit.points, hit.padding)
}

window.addEventListener("resize", resize)
resize()
loop()

/** `?view=` opens one geometry or analysis variant after the scene loads. */
function requestedView() {
  const params = new URLSearchParams(location.search)
  const view = params.get("view")
  if (view === "sized" || view === "categories" || view === "initialization") selectVariant("geometry", view)
  else if (view === "deflection" || view === "utilization" || view === "stress" || view === "axial" || view === "tributary") {
    selectVariant("analysis", view)
  }
  if (params.get("elev") === "side") {
    setOrtho(true)
    controls.rotateTo(Math.PI / 2, Math.PI / 2, false)
    renderDirty = true
  }
  const open = params.get("open")
  if (open === "deck" || open === "slab") {
    const record = componentRecords.find((item) => item.kind === "slab" && (open === "slab" || item.drawing?.deck))
    if (record) reselect(record.id)
  }
}

/** A `?scene=` name in this page's folder, or the usual default. */
function requestedScene(): string | null {
  const name = new URLSearchParams(location.search).get("scene")
  if (!name || !/^[\w.-]+\.mgscene$/.test(name)) return null
  return name
}

async function loadDefault() {
  const asked = requestedScene()
  let names = ["core_office_v7.mgscene", "core_office.mgscene", "demo.mgscene"]
  const listed = await fetch("/scenes.json").catch(() => null)
  if (listed?.ok) {
    const parsed = await listed.json().catch(() => null)
    if (Array.isArray(parsed)) {
      const valid = parsed.filter((name): name is string => typeof name === "string" && /^[\w.-]+\.mgscene$/.test(name))
      if (valid.length > 0) names = valid
    }
  }
  if (asked) names = [asked, ...names.filter((name) => name !== asked)]
  for (const name of names) {
    const response = await fetch(`/${name}`)
    if (response.ok) {
      if (await openBuffer(await response.arrayBuffer(), name)) requestedView()
      return
    }
  }
  setStatus("Drop a .mgscene file")
}
loadDefault()
