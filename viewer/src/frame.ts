import * as THREE from "three"
import theme from "./theme.json"
import { deflectionColor, pastelColor, signedColor, utilizationColor } from "./building"

const IRIS = new THREE.Color(theme.iris)
const TYPE_COLOR = [
  new THREE.Color(theme.charcoal),
  new THREE.Color(theme.column),
  new THREE.Color(theme.brace),
]

const VERTEX = /* glsl */ `
uniform float uScale;
uniform float uColorMode;
uniform float uStations;
uniform int uDofTile;
uniform int uPartTile;
uniform sampler2D dofTex;
uniform sampler2D lcsTex;
uniform sampler2D indexTex;
uniform sampler2D partTex;
in float aT;
in float aElem;
in float aLength;
in vec3 aColor;
in float aKeep;
out vec3 vColor;
out float vElem;
out float vKeep;
#include <clipping_planes_pars_vertex>

vec3 localDisplacement(int elem, float t, float L) {
  int dofCol = elem - (elem / uDofTile) * uDofTile;
  int dofRow = elem / uDofTile;
  ivec2 base = ivec2(dofCol * 3, dofRow);
  vec4 p0 = texelFetch(dofTex, base, 0);
  vec4 p1 = texelFetch(dofTex, base + ivec2(1, 0), 0);
  vec4 p2 = texelFetch(dofTex, base + ivec2(2, 0), 0);
  float uX1 = p0.x;
  float uY1 = p0.y;
  float uZ1 = p0.z;
  float uZ2 = -p1.x;
  float uY2 = p1.y;
  float uX2 = p1.z;
  float uY3 = p1.w;
  float uZ3 = p2.x;
  float uZ4 = -p2.z;
  float uY4 = p2.w;
  float x = t * L;
  float dx = (1.0 - t) * uX1 + t * uX2;
  float n1 = 1.0 - 3.0 * t * t + 2.0 * t * t * t;
  float n2 = x * (1.0 - t) * (1.0 - t);
  float n3 = 3.0 * t * t - 2.0 * t * t * t;
  float n4 = x * x / L * (-1.0 + t);
  float dyPart = 0.0;
  float dzPart = 0.0;
  int indexCol = elem - (elem / uDofTile) * uDofTile;
  int indexRow = elem / uDofTile;
  float rowf = texelFetch(indexTex, ivec2(indexCol, indexRow), 0).r;
  if (rowf >= 0.0 && uStations >= 2.0) {
    int load = int(rowf + 0.5);
    int partCol = load - (load / uPartTile) * uPartTile;
    int partRow = load / uPartTile;
    int stride = int(uStations) * 2;
    float ft = t * (uStations - 1.0);
    int i0 = int(floor(ft));
    int i1 = int(min(floor(ft) + 1.0, uStations - 1.0));
    float f = ft - float(i0);
    int x0 = partCol * stride + i0 * 2;
    int x1 = partCol * stride + i1 * 2;
    dyPart = mix(
      texelFetch(partTex, ivec2(x0, partRow), 0).r,
      texelFetch(partTex, ivec2(x1, partRow), 0).r, f);
    dzPart = mix(
      texelFetch(partTex, ivec2(x0 + 1, partRow), 0).r,
      texelFetch(partTex, ivec2(x1 + 1, partRow), 0).r, f);
  }
  float dy = n1 * uY1 + n2 * uY2 + n3 * uY3 + n4 * uY4 + dyPart;
  float dz = n1 * uZ1 + n2 * uZ2 + n3 * uZ3 + n4 * uZ4 + dzPart;
  vec3 lx = texelFetch(lcsTex, base, 0).xyz;
  vec3 ly = texelFetch(lcsTex, base + ivec2(1, 0), 0).xyz;
  vec3 lz = texelFetch(lcsTex, base + ivec2(2, 0), 0).xyz;
  return dx * lx + dy * ly + dz * lz;
}

void main() {
  int elem = int(aElem + 0.5);
  float L = max(aLength, 1e-6);
  vec3 displaced = position + uScale * localDisplacement(elem, aT, L);
  vColor = mix(aColor, vec3(${IRIS.r.toFixed(5)}, ${IRIS.g.toFixed(5)}, ${IRIS.b.toFixed(5)}), uColorMode);
  vElem = aElem;
  vKeep = aKeep;
  vec4 mvPosition = modelViewMatrix * vec4(displaced, 1.0);
  #include <clipping_planes_vertex>
  gl_Position = projectionMatrix * mvPosition;
}
`

const FRAGMENT = /* glsl */ `
#include <clipping_planes_pars_fragment>
in vec3 vColor;
in float vKeep;
out vec4 fragColor;
void main() {
  #include <clipping_planes_fragment>
  vec3 grey = vec3(0.78431, 0.78431, 0.76863);
  fragColor = vec4(mix(grey, vColor, clamp(vKeep, 0.0, 1.0)), 1.0);
}
`

const PICK_FRAGMENT = /* glsl */ `
#include <clipping_planes_pars_fragment>
in float vElem;
in float vKeep;
out vec4 fragColor;
void main() {
  #include <clipping_planes_fragment>
  int id = int(vElem + 0.5) + 1;
  fragColor = vec4(
    float(id & 255) / 255.0,
    float((id >> 8) & 255) / 255.0,
    float((id >> 16) & 255) / 255.0,
    1.0);
}
`

export interface FrameUniforms {
  uScale: { value: number }
  uColorMode: { value: number }
  uStations: { value: number }
  uDofTile: { value: number }
  uPartTile: { value: number }
  dofTex: { value: THREE.Texture }
  lcsTex: { value: THREE.Texture }
  indexTex: { value: THREE.Texture }
  partTex: { value: THREE.Texture }
}

export interface FrameView {
  high: THREE.LineSegments
  low: THREE.LineSegments
  ghost: THREE.LineSegments
  pick: THREE.LineSegments
  /** Display sticks for columns and beams, colored by deflection. */
  rods: THREE.Mesh
  uniforms: FrameUniforms
  elementCount: number
  meanLength: number
  /** Largest member displacement, meters, before the display scale. */
  maxDisplacement: number
  /** Recolor the sticks against the scene-wide deflection maximum. */
  paint(colorScale: number): void
  /** Recolor each stick by one signed value, against `scale`. */
  paintElements(values: Float32Array, scale: number): void
  /** Recolor each stick by demand/capacity. A missing ratio stays grey. */
  paintRatios(values: Float32Array): void
  /**
   * Paint each member that owns a tributary in that area's pastel.
   * Columns among them are drawn a little wider than the display stick.
   */
  paintTributary(owners: Uint32Array): void
  /** Undeflected midpoint of an element, in Y-up scene space. */
  midpoint(element: number): THREE.Vector3
  /** Global displacement at midspan, before the display scale. */
  midDisplacement(element: number): THREE.Vector3
}

interface LineBuffers {
  position: Float32Array
  aT: Float32Array
  aElem: Float32Array
  aLength: Float32Array
  aColor: Float32Array
  aKeep: Float32Array
  index: Uint32Array
}

function lineBuffers(
  pos: Float32Array,
  pairs: Uint32Array,
  types: Uint8Array,
  segments: number,
  hidden?: Uint8Array,
): { lines: LineBuffers; mean: number } {
  const nElem = pairs.length / 2
  const vertPer = segments + 1
  const position = new Float32Array(nElem * vertPer * 3)
  const aT = new Float32Array(nElem * vertPer)
  const aElem = new Float32Array(nElem * vertPer)
  const aLength = new Float32Array(nElem * vertPer)
  const aColor = new Float32Array(nElem * vertPer * 3)
  const aKeep = new Float32Array(nElem * vertPer)
  aKeep.fill(1)
  const index = new Uint32Array(nElem * segments * 2)
  let lengthSum = 0
  let drawn = 0
  let written = 0
  for (let e = 0; e < nElem; e++) {
    const a = pairs[e * 2]
    const b = pairs[e * 2 + 1]
    const ax = pos[a * 3], ay = pos[a * 3 + 1], az = pos[a * 3 + 2]
    const bx = pos[b * 3], by = pos[b * 3 + 1], bz = pos[b * 3 + 2]
    const L = Math.hypot(bx - ax, by - ay, bz - az)
    const omit = hidden?.[e] === 1
    if (!omit) {
      lengthSum += L
      drawn++
    }
    const color = TYPE_COLOR[types[e] ?? 0] ?? TYPE_COLOR[0]
    const base = e * vertPer
    for (let s = 0; s <= segments; s++) {
      const t = s / segments
      const v = base + s
      position[v * 3] = ax + (bx - ax) * t
      position[v * 3 + 1] = ay + (by - ay) * t
      position[v * 3 + 2] = az + (bz - az) * t
      aT[v] = t
      aElem[v] = e
      aLength[v] = L
      aColor[v * 3] = color.r
      aColor[v * 3 + 1] = color.g
      aColor[v * 3 + 2] = color.b
    }
    if (omit) continue
    for (let s = 0; s < segments; s++) {
      index[written++] = base + s
      index[written++] = base + s + 1
    }
  }
  return {
    lines: { position, aT, aElem, aLength, aColor, aKeep, index: index.subarray(0, written) },
    mean: drawn > 0 ? lengthSum / drawn : 1,
  }
}

function geometryOf(lines: LineBuffers): THREE.BufferGeometry {
  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute("position", new THREE.BufferAttribute(lines.position, 3))
  geometry.setAttribute("aT", new THREE.BufferAttribute(lines.aT, 1))
  geometry.setAttribute("aElem", new THREE.BufferAttribute(lines.aElem, 1))
  geometry.setAttribute("aLength", new THREE.BufferAttribute(lines.aLength, 1))
  geometry.setAttribute("aColor", new THREE.BufferAttribute(lines.aColor, 3))
  geometry.setAttribute("aKeep", new THREE.BufferAttribute(lines.aKeep, 1))
  geometry.setIndex(new THREE.BufferAttribute(lines.index, 1))
  geometry.computeBoundingSphere()
  return geometry
}

function floatTexture(data: Float32Array, width: number, height: number, format: THREE.PixelFormat): THREE.DataTexture {
  const texture = new THREE.DataTexture(data, width, Math.max(height, 1), format, THREE.FloatType)
  texture.magFilter = THREE.NearestFilter
  texture.minFilter = THREE.NearestFilter
  texture.wrapS = THREE.ClampToEdgeWrapping
  texture.wrapT = THREE.ClampToEdgeWrapping
  texture.colorSpace = THREE.NoColorSpace
  texture.needsUpdate = true
  return texture
}

/** How many items fit in one texture row without exceeding a 4096-wide texture. */
function tileSize(texelsPerItem: number): number {
  return Math.max(1, Math.floor(4096 / texelsPerItem))
}

/**
 * Pack `stride` floats per item into rows of `tile` items.
 * Returns the texture data, its width in texels, and its height.
 */
function packItems(src: Float32Array, nItem: number, stride: number, tile: number): Float32Array {
  const rows = Math.max(1, Math.ceil(Math.max(nItem, 1) / tile))
  const out = new Float32Array(tile * stride * rows)
  for (let i = 0; i < nItem; i++) {
    const col = i % tile
    const row = Math.floor(i / tile)
    out.set(src.subarray(i * stride, i * stride + stride), (row * tile + col) * stride)
  }
  return out
}

/** `[lx ly lz]` (9 floats) to one RGBA texel per axis: `[lx 0 ly 0 lz 0]`. */
function axesPerTexel(src: Float32Array, nItem: number): Float32Array {
  const out = new Float32Array(nItem * 12)
  for (let i = 0; i < nItem; i++) {
    for (let axis = 0; axis < 3; axis++) {
      out.set(src.subarray(i * 9 + axis * 3, i * 9 + axis * 3 + 3), i * 12 + axis * 4)
    }
  }
  return out
}

/** Same Hermite evaluation as the shader, at a single t. Y-up vectors in, Y-up out. */
export function displacementAt(
  dofs: Float32Array,
  lcs: Float32Array,
  element: number,
  t: number,
  length: number,
  loadRow: Int32Array,
  particular: Float32Array,
  stations: number,
): THREE.Vector3 {
  const o = element * 12
  const uX1 = dofs[o], uY1 = dofs[o + 1], uZ1 = dofs[o + 2]
  const uZ2 = -dofs[o + 4], uY2 = dofs[o + 5], uX2 = dofs[o + 6], uY3 = dofs[o + 7]
  const uZ3 = dofs[o + 8], uZ4 = -dofs[o + 10], uY4 = dofs[o + 11]
  const L = Math.max(length, 1e-6)
  const x = t * L
  const dx = (1 - t) * uX1 + t * uX2
  const n1 = 1 - 3 * t * t + 2 * t * t * t
  const n2 = x * (1 - t) * (1 - t)
  const n3 = 3 * t * t - 2 * t * t * t
  const n4 = (x * x / L) * (-1 + t)
  let dyPart = 0
  let dzPart = 0
  const row = loadRow[element]
  if (row >= 0 && stations >= 2) {
    const ft = t * (stations - 1)
    const i0 = Math.floor(ft)
    const i1 = Math.min(i0 + 1, stations - 1)
    const f = ft - i0
    const base0 = (row * stations + i0) * 2
    const base1 = (row * stations + i1) * 2
    dyPart = particular[base0] * (1 - f) + particular[base1] * f
    dzPart = particular[base0 + 1] * (1 - f) + particular[base1 + 1] * f
  }
  const dy = n1 * uY1 + n2 * uY2 + n3 * uY3 + n4 * uY4 + dyPart
  const dz = n1 * uZ1 + n2 * uZ2 + n3 * uZ3 + n4 * uZ4 + dzPart
  const c = element * 9
  const lx = lcs.subarray(c, c + 3)
  const ly = lcs.subarray(c + 3, c + 6)
  const lz = lcs.subarray(c + 6, c + 9)
  return new THREE.Vector3(
    dx * lx[0] + dy * ly[0] + dz * lz[0],
    dx * lx[1] + dy * ly[1] + dz * lz[1],
    dx * lx[2] + dy * ly[2] + dz * lz[2],
  )
}

/** Square stick around a centerline so deflection color is readable. Not a sized section. */
const STICK_WIDTH = 0.25

function rodMaterial(scale: { value: number }, widen: { value: number }): THREE.MeshLambertMaterial {
  const material = new THREE.MeshLambertMaterial({
    color: "#ffffff",
    vertexColors: true,
    flatShading: true,
  })
  material.onBeforeCompile = (shader: { uniforms: Record<string, { value: number }>; vertexShader: string; fragmentShader: string }) => {
    shader.uniforms.uScale = scale
    shader.uniforms.uWiden = widen
    shader.vertexShader = shader.vertexShader
      .replace(
        "#include <common>",
        "#include <common>\nuniform float uScale;\nuniform float uWiden;\nattribute vec3 aDisp;\nattribute vec3 aOffset;\nattribute float aColumn;\nattribute float aKeep;\nattribute float aShow;\nvarying float vKeep;\nvarying float vShow;",
      )
      .replace(
        "#include <begin_vertex>",
        "vec3 transformed = position + aOffset * (1.0 + uWiden * aColumn) + uScale * aDisp;\nvKeep = aKeep;\nvShow = aShow;",
      )
    shader.fragmentShader = shader.fragmentShader
      .replace("#include <common>", "#include <common>\nvarying float vKeep;\nvarying float vShow;")
      .replace(
        "#include <dithering_fragment>",
        "if (vShow < 0.5) discard;\ngl_FragColor.rgb = mix(vec3(0.78431, 0.78431, 0.76863), gl_FragColor.rgb, clamp(vKeep, 0.0, 1.0));\n#include <dithering_fragment>",
      )
  }
  return material
}

/**
 * A square stick along every frame member. Columns and beams share it.
 * Color is the unscaled displacement, painted later against the scene maximum.
 */
/** Extra width on a column while its tributary area is showing. 0.4 makes the 0.25 m stick 0.35 m. */
const COLUMN_WIDEN = 0.4

function buildRods(
  pos: Float32Array,
  pairs: Uint32Array,
  types: Uint8Array,
  segments: number,
  scale: { value: number },
  dispAt: (element: number, t: number, length: number) => THREE.Vector3,
  hidden?: Uint8Array,
): {
  mesh: THREE.Mesh
  maxDisplacement: number
  paint: (colorScale: number) => void
  paintElements: (values: Float32Array, scale: number) => void
  paintRatios: (values: Float32Array) => void
  paintTributary: (owners: Uint32Array) => void
} {
  const nElem = pairs.length / 2
  const trisPer = segments * 4 * 2 + 4
  const widen = { value: 0 }
  const material = rodMaterial(scale, widen)
  if (nElem === 0 || segments < 1) {
    const mesh = new THREE.Mesh(new THREE.BufferGeometry(), material)
    mesh.visible = false
    mesh.userData = { role: "member-rod", trisPer: 1 }
    return { mesh, maxDisplacement: 0, paint() {}, paintElements() {}, paintRatios() {}, paintTributary() {} }
  }
  const rings = segments + 1
  const corners = 4
  const vertPer = rings * corners
  const position = new Float32Array(nElem * vertPer * 3)
  const aOffset = new Float32Array(nElem * vertPer * 3)
  const aColumn = new Float32Array(nElem * vertPer)
  const aShow = new Float32Array(nElem * vertPer)
  const normal = new Float32Array(nElem * vertPer * 3)
  aShow.fill(1)
  const aDisp = new Float32Array(nElem * vertPer * 3)
  const magnitude = new Float32Array(nElem * vertPer)
  const color = new Float32Array(nElem * vertPer * 3)
  const index = new Uint32Array(nElem * trisPer * 3)
  const half = STICK_WIDTH / 2
  let maxDisplacement = 0
  let cursor = 0
  for (let e = 0; e < nElem; e++) {
    const ia = pairs[e * 2]
    const ib = pairs[e * 2 + 1]
    const ax = pos[ia * 3], ay = pos[ia * 3 + 1], az = pos[ia * 3 + 2]
    const bx = pos[ib * 3], by = pos[ib * 3 + 1], bz = pos[ib * 3 + 2]
    const dx = bx - ax, dy = by - ay, dz = bz - az
    const length = Math.hypot(dx, dy, dz)
    const inv = length > 1e-8 ? 1 / length : 0
    const ux = dx * inv, uy = dy * inv, uz = dz * inv
    const rx = Math.abs(uy) > 0.9 ? 1 : 0
    const ry = Math.abs(uy) > 0.9 ? 0 : 1
    const rz = 0
    let sx = uy * rz - uz * ry
    let sy = uz * rx - ux * rz
    let sz = ux * ry - uy * rx
    const sideLen = Math.hypot(sx, sy, sz) || 1
    const sxl = sx / sideLen, syl = sy / sideLen, szl = sz / sideLen
    sx = sxl * half; sy = syl * half; sz = szl * half
    let px = syl * uz - szl * uy
    let py = szl * ux - sxl * uz
    let pz = sxl * uy - syl * ux
    const upLen = Math.hypot(px, py, pz) || 1
    px = px / upLen * half; py = py / upLen * half; pz = pz / upLen * half
    const ox = [sx + px, -sx + px, -sx - px, sx - px]
    const oy = [sy + py, -sy + py, -sy - py, sy - py]
    const oz = [sz + pz, -sz + pz, -sz - pz, sz - pz]
    const column = (types[e] ?? 0) === 1 ? 1 : 0
    for (let s = 0; s < rings; s++) {
      const t = s / segments
      const disp = dispAt(e, t, length)
      const mag = disp.length()
      if (mag > maxDisplacement) maxDisplacement = mag
      for (let c = 0; c < corners; c++) {
        const v = (e * rings + s) * corners + c
        position[v * 3] = ax + dx * t
        position[v * 3 + 1] = ay + dy * t
        position[v * 3 + 2] = az + dz * t
        aOffset[v * 3] = ox[c] ?? 0
        aOffset[v * 3 + 1] = oy[c] ?? 0
        aOffset[v * 3 + 2] = oz[c] ?? 0
        const olen = Math.hypot(ox[c] ?? 0, oy[c] ?? 0, oz[c] ?? 0) || 1
        normal[v * 3] = (ox[c] ?? 0) / olen
        normal[v * 3 + 1] = (oy[c] ?? 0) / olen
        normal[v * 3 + 2] = (oz[c] ?? 0) / olen
        aColumn[v] = column
        if (hidden?.[e] === 1) aShow[v] = 0
        aDisp[v * 3] = disp.x
        aDisp[v * 3 + 1] = disp.y
        aDisp[v * 3 + 2] = disp.z
        magnitude[v] = mag
      }
    }
    const base = e * vertPer
    for (let s = 0; s < segments; s++) {
      for (let c = 0; c < corners; c++) {
        const c2 = (c + 1) % corners
        const a = base + s * corners + c
        const b = base + s * corners + c2
        const d = base + (s + 1) * corners + c
        const f = base + (s + 1) * corners + c2
        index[cursor++] = a
        index[cursor++] = b
        index[cursor++] = f
        index[cursor++] = a
        index[cursor++] = f
        index[cursor++] = d
      }
    }
    const start = base
    const end = base + (rings - 1) * corners
    index[cursor++] = start
    index[cursor++] = start + 2
    index[cursor++] = start + 1
    index[cursor++] = start
    index[cursor++] = start + 3
    index[cursor++] = start + 2
    index[cursor++] = end
    index[cursor++] = end + 1
    index[cursor++] = end + 2
    index[cursor++] = end
    index[cursor++] = end + 2
    index[cursor++] = end + 3
  }
  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute("position", new THREE.BufferAttribute(position, 3))
  geometry.setAttribute("aOffset", new THREE.BufferAttribute(aOffset, 3))
  geometry.setAttribute("aColumn", new THREE.BufferAttribute(aColumn, 1))
  geometry.setAttribute("aDisp", new THREE.BufferAttribute(aDisp, 3))
  geometry.setAttribute("normal", new THREE.BufferAttribute(normal, 3))
  const colorAttr = new THREE.BufferAttribute(color, 3)
  geometry.setAttribute("color", colorAttr)
  const kept = new Float32Array(nElem * vertPer)
  kept.fill(1)
  geometry.setAttribute("aKeep", new THREE.BufferAttribute(kept, 1))
  const showAttr = new THREE.BufferAttribute(aShow, 1)
  geometry.setAttribute("aShow", showAttr)
  geometry.setIndex(new THREE.BufferAttribute(index, 1))
  const mesh = new THREE.Mesh(geometry, material)
  mesh.frustumCulled = false
  mesh.visible = false
  mesh.userData = { role: "member-rod", trisPer, vertPer }
  const sample = new THREE.Color()
  const resetRods = () => {
    widen.value = 0
    aShow.fill(1)
    showAttr.needsUpdate = true
  }
  const paint = (colorScale: number) => {
    resetRods()
    const denom = Math.max(colorScale, 1e-12)
    for (let i = 0; i < magnitude.length; i++) {
      deflectionColor(magnitude[i] / denom, sample)
      color[i * 3] = sample.r
      color[i * 3 + 1] = sample.g
      color[i * 3 + 2] = sample.b
    }
    colorAttr.needsUpdate = true
  }
  const paintElements = (values: Float32Array, scale: number) => {
    resetRods()
    for (let e = 0; e < nElem; e++) {
      signedColor(values[e] ?? 0, scale, sample)
      for (let v = e * vertPer; v < (e + 1) * vertPer; v++) {
        color[v * 3] = sample.r
        color[v * 3 + 1] = sample.g
        color[v * 3 + 2] = sample.b
      }
    }
    colorAttr.needsUpdate = true
  }
  const paintRatios = (values: Float32Array) => {
    resetRods()
    for (let e = 0; e < nElem; e++) {
      utilizationColor(values[e] ?? Number.NaN, sample)
      for (let v = e * vertPer; v < (e + 1) * vertPer; v++) {
        color[v * 3] = sample.r
        color[v * 3 + 1] = sample.g
        color[v * 3 + 2] = sample.b
      }
    }
    colorAttr.needsUpdate = true
  }
  const paintTributary = (owners: Uint32Array) => {
    const owned = new Uint8Array(nElem)
    for (let i = 0; i < owners.length; i++) {
      const id = owners[i] ?? 0xffffffff
      if (id < nElem) owned[id] = 1
    }
    widen.value = COLUMN_WIDEN
    for (let e = 0; e < nElem; e++) {
      const on = owned[e] === 1 && hidden?.[e] !== 1
      if (on) pastelColor(e, sample)
      for (let v = e * vertPer; v < (e + 1) * vertPer; v++) {
        aShow[v] = on ? 1 : 0
        if (!on) continue
        color[v * 3] = sample.r
        color[v * 3 + 1] = sample.g
        color[v * 3 + 2] = sample.b
      }
    }
    showAttr.needsUpdate = true
    colorAttr.needsUpdate = true
  }
  paint(maxDisplacement)
  return { mesh, maxDisplacement, paint, paintElements, paintRatios, paintTributary }
}

/** Restore the type color, or paint a member in the pastel of its tributary. */
function tintLines(lines: LineBuffers, base: Float32Array, owned: Uint8Array | null, ink: THREE.Color) {
  const color = lines.aColor
  const elem = lines.aElem
  for (let v = 0; v < elem.length; v++) {
    const element = elem[v] ?? 0
    if (owned && owned[element]) {
      pastelColor(element, ink)
      color[v * 3] = ink.r
      color[v * 3 + 1] = ink.g
      color[v * 3 + 2] = ink.b
    } else {
      color[v * 3] = base[v * 3] ?? 0
      color[v * 3 + 1] = base[v * 3 + 1] ?? 0
      color[v * 3 + 2] = base[v * 3 + 2] ?? 0
    }
  }
}

export function buildFrame(input: {
  position: Float32Array
  elementNodes: Uint32Array
  elementType: Uint8Array
  localDof: Float32Array
  lcs: Float32Array
  loadElement: Uint32Array
  particular: Float32Array
  stations: number
  hidden?: Uint8Array
}): FrameView {
  const nElem = input.elementNodes.length / 2
  const highLines = lineBuffers(input.position, input.elementNodes, input.elementType, 8, input.hidden)
  const lowLines = lineBuffers(input.position, input.elementNodes, input.elementType, 2, input.hidden)
  const highGeo = geometryOf(highLines.lines)
  const lowGeo = geometryOf(lowLines.lines)

  const dofTile = tileSize(3)
  const dofRows = Math.max(1, Math.ceil(Math.max(nElem, 1) / dofTile))
  const dofSrc = input.localDof.length >= nElem * 12 ? input.localDof : new Float32Array(nElem * 12)
  const lcsSrc = input.lcs.length >= nElem * 9 ? axesPerTexel(input.lcs, nElem) : new Float32Array(nElem * 12)
  const dofTex = floatTexture(packItems(dofSrc, nElem, 12, dofTile), dofTile * 3, dofRows, THREE.RGBAFormat)
  const lcsTex = floatTexture(packItems(lcsSrc, nElem, 12, dofTile), dofTile * 3, dofRows, THREE.RGBAFormat)

  const indexData = new Float32Array(nElem)
  indexData.fill(-1)
  const loadRow = new Int32Array(nElem)
  loadRow.fill(-1)
  for (let i = 0; i < input.loadElement.length; i++) {
    const element = input.loadElement[i]
    indexData[element] = i
    loadRow[element] = i
  }
  const indexTex = floatTexture(packItems(indexData, nElem, 1, dofTile), dofTile, dofRows, THREE.RedFormat)

  const stationCount = Math.max(input.stations, 2)
  const partStride = stationCount * 2
  const partTile = tileSize(partStride)
  const nLoaded = input.loadElement.length
  const partSrc = input.particular.length >= nLoaded * partStride
    ? input.particular
    : new Float32Array(Math.max(nLoaded, 1) * partStride)
  const partRows = Math.max(1, Math.ceil(Math.max(nLoaded, 1) / partTile))
  const partTex = floatTexture(
    packItems(partSrc, nLoaded, partStride, partTile),
    partTile * partStride,
    partRows,
    THREE.RedFormat,
  )

  const uniforms: FrameUniforms = {
    uScale: { value: 0 },
    uColorMode: { value: 0 },
    uStations: { value: input.stations },
    uDofTile: { value: dofTile },
    uPartTile: { value: partTile },
    dofTex: { value: dofTex },
    lcsTex: { value: lcsTex },
    indexTex: { value: indexTex },
    partTex: { value: partTex },
  }
  const material = new THREE.ShaderMaterial({
    glslVersion: THREE.GLSL3,
    uniforms,
    vertexShader: VERTEX,
    fragmentShader: FRAGMENT,
    toneMapped: false,
    clipping: true,
  })
  const lowMaterial = material.clone()
  lowMaterial.uniforms = uniforms
  const pickMaterial = new THREE.ShaderMaterial({
    glslVersion: THREE.GLSL3,
    uniforms,
    vertexShader: VERTEX,
    fragmentShader: PICK_FRAGMENT,
    toneMapped: false,
    clipping: true,
  })
  const ghostMaterial = new THREE.LineBasicMaterial({
    color: theme.ghost,
    transparent: true,
    opacity: 0.28,
    depthWrite: false,
  })

  const solved = input.localDof.length >= nElem * 12 && input.lcs.length >= nElem * 9
  const rodsBuilt = buildRods(input.position, input.elementNodes, input.elementType, 8, uniforms.uScale, (element, t, length) => {
    if (!solved) return new THREE.Vector3()
    return displacementAt(input.localDof, input.lcs, element, t, length, loadRow, input.particular, input.stations)
  }, input.hidden)
  const highColor = highGeo.getAttribute("aColor") as THREE.BufferAttribute
  const lowColor = lowGeo.getAttribute("aColor") as THREE.BufferAttribute
  const highBase = new Float32Array(highLines.lines.aColor)
  const lowBase = new Float32Array(lowLines.lines.aColor)
  const lineInk = new THREE.Color()
  const writeLines = (owned: Uint8Array | null) => {
    tintLines(highLines.lines, highBase, owned, lineInk)
    tintLines(lowLines.lines, lowBase, owned, lineInk)
    highColor.needsUpdate = true
    lowColor.needsUpdate = true
  }

  const high = new THREE.LineSegments(highGeo, material)
  const low = new THREE.LineSegments(lowGeo, lowMaterial)
  low.visible = false
  const ghost = new THREE.LineSegments(highGeo, ghostMaterial)
  ghost.renderOrder = -1
  const pick = new THREE.LineSegments(highGeo, pickMaterial)
  pick.frustumCulled = false

  const lengths = highLines.lines.aLength
  return {
    high, low, ghost, pick, rods: rodsBuilt.mesh, uniforms,
    elementCount: nElem,
    meanLength: highLines.mean,
    maxDisplacement: rodsBuilt.maxDisplacement,
    paint(colorScale: number) {
      writeLines(null)
      rodsBuilt.paint(colorScale)
    },
    paintElements(values: Float32Array, scale: number) {
      writeLines(null)
      rodsBuilt.paintElements(values, scale)
    },
    paintRatios(values: Float32Array) {
      writeLines(null)
      rodsBuilt.paintRatios(values)
    },
    paintTributary(owners: Uint32Array) {
      const owned = new Uint8Array(nElem)
      for (let i = 0; i < owners.length; i++) {
        const id = owners[i] ?? 0xffffffff
        if (id < nElem) owned[id] = 1
      }
      writeLines(owned)
      rodsBuilt.paintTributary(owners)
    },
    midpoint(element: number) {
      const a = input.elementNodes[element * 2]
      const b = input.elementNodes[element * 2 + 1]
      return new THREE.Vector3(
        (input.position[a * 3] + input.position[b * 3]) / 2,
        (input.position[a * 3 + 1] + input.position[b * 3 + 1]) / 2,
        (input.position[a * 3 + 2] + input.position[b * 3 + 2]) / 2,
      )
    },
    midDisplacement(element: number) {
      if (input.localDof.length === 0) return new THREE.Vector3()
      const vertPer = 9
      const L = lengths[element * vertPer]
      return displacementAt(input.localDof, input.lcs, element, 0.5, L, loadRow, input.particular, input.stations)
    },
  }
}
