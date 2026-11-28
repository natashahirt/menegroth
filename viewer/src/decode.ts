/** Decode a `.mgscene` packet. Version 1 is one design. Version 2 is several. */

export interface SceneBufferInfo {
  name: string
  dtype: string
  count: number
  offset: number
}

export interface SceneHeader {
  version: number
  stages: string[]
  origin: [number, number, number]
  buffers: SceneBufferInfo[]
  stations: number
  max_displacement: number
  max_axial_n?: number
  max_surface_stress_pa?: number
  suggested_scale: number
  counts?: { nodes: number; elements: number; stations: number }
  hashes?: { geometry: string; analysis: string }
  components?: unknown
  design_trace?: unknown
  element_section?: string[]
  analysis_model?: string
}

const DTYPE_SIZE: Record<string, number> = { f32: 4, u32: 4, u16: 2, u8: 1, i16: 2 }
const DTYPE_NAME: Record<number, string> = { 1: "f32", 2: "u32", 3: "u16", 4: "u8", 5: "i16", 6: "json" }
const MAGIC = 0x4353474d

export interface VariantAxis {
  field: string
  anchor: string
}

export interface VariantParam {
  hash: string
  label: string
}

export interface SceneVariant {
  id: string
  params: Record<string, VariantParam>
  summary: Record<string, number | null>
  origin: [number, number, number]
  stages: string[]
  stations: number
  max_displacement: number
  max_axial_n: number
  max_surface_stress_pa: number
  suggested_scale: number
  counts?: SceneHeader["counts"]
  components: string
  design_trace: string
  parts: { id: string; role: string; sections?: string[]; blocks: Record<string, string> }[]
  analysis_model?: string
}

export interface VariantBlock {
  storage: number
  dtype: string
  count: number
  scale: number
  gzip: ArrayBuffer
}

export interface VariantFile {
  geometryHash: string
  axes: VariantAxis[]
  variants: SceneVariant[]
  blocks: Record<string, VariantBlock>
  cache: Record<string, { dtype: string; bytes: Uint8Array } | { dtype: "json"; text: string }>
}

export interface DecodedScene {
  header: SceneHeader
  arrays: Record<string, ArrayBuffer>
  variants?: VariantFile
  variantId?: string
}

export async function decodeScene(buf: ArrayBuffer, variantId?: string): Promise<DecodedScene> {
  const view = new DataView(buf)
  if (buf.byteLength < 8) throw new Error("scene file is too short")
  if (view.getUint32(0, true) !== MAGIC) throw new Error("not a scene packet")
  const version = view.getUint16(4, true)
  if (version === 1) return decodeV1(buf)
  if (version === 2) return decodeV2(buf, variantId)
  throw new Error(`unsupported scene version ${version}`)
}

function decodeV1(buf: ArrayBuffer): DecodedScene {
  const view = new DataView(buf)
  const hlen = view.getUint32(8, true)
  const headerStart = 12
  if (headerStart + hlen > buf.byteLength) throw new Error("scene header overruns the file")
  const header = JSON.parse(new TextDecoder().decode(new Uint8Array(buf, headerStart, hlen))) as SceneHeader
  let region = (headerStart + hlen + 7) & ~7
  const arrays: Record<string, ArrayBuffer> = {}
  for (const entry of header.buffers) {
    const size = DTYPE_SIZE[entry.dtype]
    if (size === undefined) throw new Error(`unknown scene dtype ${entry.dtype}`)
    const start = region + entry.offset
    const nbytes = entry.count * size
    if (start < region || start + nbytes > buf.byteLength) {
      throw new Error(`scene buffer ${entry.name} overruns the file`)
    }
    arrays[entry.name] = buf.slice(start, start + nbytes)
  }
  return { header, arrays }
}

function decodeV2(buf: ArrayBuffer, variantId?: string): Promise<DecodedScene> {
  const view = new DataView(buf)
  const blocks: Record<string, VariantBlock> = {}
  let index: {
    geometry_hash: string
    axes: VariantAxis[]
    variants: SceneVariant[]
  } | null = null
  let offset = 8
  while (offset + 8 <= buf.byteLength) {
    const kind = view.getUint32(offset, true)
    const nbytes = view.getUint32(offset + 4, true)
    const start = offset + 8
    const stop = start + nbytes
    if (stop > buf.byteLength) throw new Error("scene record overruns the file")
    const payload = new Uint8Array(buf.slice(start, stop))
    if (kind === 1) blocks[bytesToHex(payload.subarray(0, 32))] = readBlock(payload)
    else if (kind === 2) index = JSON.parse(new TextDecoder().decode(payload))
    else throw new Error(`unknown scene record type ${kind}`)
    offset = (stop + 7) & ~7
  }
  if (!index || index.variants.length === 0) throw new Error("scene has no designs")
  const file: VariantFile = {
    geometryHash: index.geometry_hash,
    axes: index.axes,
    variants: index.variants,
    blocks,
    cache: {},
  }
  const id = variantId ?? index.variants[0].id
  return assembleVariant(file, id)
}

function readBlock(payload: Uint8Array): VariantBlock {
  if (payload.length < 44) throw new Error("scene block is truncated")
  if (payload[32] !== 1) throw new Error("scene block uses an unknown codec")
  const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength)
  const dtypeCode = view.getUint16(34, true)
  const dtype = DTYPE_NAME[dtypeCode]
  if (!dtype) throw new Error(`unknown scene dtype code ${dtypeCode}`)
  return {
    storage: payload[33],
    dtype,
    count: view.getUint32(36, true),
    scale: view.getFloat32(40, true),
    gzip: payload.buffer.slice(payload.byteOffset + 44, payload.byteOffset + payload.byteLength) as ArrayBuffer,
  }
}

export async function assembleVariant(file: VariantFile, id: string): Promise<DecodedScene> {
  const variant = file.variants.find((item) => item.id === id)
  if (!variant) throw new Error(`variant ${id} is not in the scene`)
  const needed = new Set<string>([variant.components, variant.design_trace])
  for (const part of variant.parts) for (const hash of Object.values(part.blocks)) needed.add(hash)
  for (const hash of needed) {
    if (!file.cache[hash]) file.cache[hash] = await inflate(file, hash)
  }
  const frames = variant.parts.filter((part) => part.role === "frame").sort(byId)
  const shells = variant.parts.filter((part) => part.role === "shell").sort(byId)
  const bytes: Record<string, Uint8Array[]> = {}
  const sections: string[] = []
  let nodeCursor = 0
  const take = (part: SceneVariant["parts"][number], name: string) => {
    const hash = part.blocks[name]
    if (!hash) return new Uint8Array()
    const block = file.cache[hash]
    if (!block || !("bytes" in block)) throw new Error(`scene part ${part.id} block ${name} is not numeric`)
    return block.bytes
  }
  const push = (name: string, chunk: Uint8Array) => {
    if (chunk.length === 0) return
    ;(bytes[name] ??= []).push(chunk)
  }
  for (const part of frames) {
    const position = take(part, "node_position")
    push("node_position", position)
    push("node_displacement", take(part, "node_displacement"))
    push("element_nodes", offsetU32(take(part, "element_nodes"), nodeCursor))
    for (const name of ["element_type", "element_story", "element_eccentricity", "element_local_dof", "element_lcs", "element_axial"]) {
      push(name, take(part, name))
    }
    if (part.sections) sections.push(...part.sections)
    nodeCursor += position.length / 12
  }
  for (const part of shells) {
    const position = take(part, "node_position")
    push("node_position", position)
    push("node_displacement", take(part, "node_displacement"))
    push("shell_faces", offsetU32(take(part, "shell_faces"), nodeCursor))
    for (const name of ["shell_kind", "shell_thickness", "shell_surface_stress", "shell_axial", "shell_wall"]) push(name, take(part, name))
    nodeCursor += position.length / 12
  }
  for (const role of ["loads", "arrows", "footings", "solids", "tributary"]) {
    const parts = variant.parts.filter((part) => part.role === role)
    if (parts.length > 1) throw new Error(`scene has more than one ${role} part`)
    const part = parts[0]
    if (!part) continue
    for (const name of Object.keys(part.blocks)) push(name, take(part, name))
  }
  const arrays: Record<string, ArrayBuffer> = {}
  for (const [name, chunks] of Object.entries(bytes)) arrays[name] = copyBytes(concat(chunks))
  const components = jsonBlock(file, variant.components)
  const trace = jsonBlock(file, variant.design_trace)
  const header: SceneHeader = {
    version: 2,
    stages: variant.stages,
    origin: variant.origin,
    buffers: [],
    stations: Number(variant.stations ?? 0),
    max_displacement: Number(variant.max_displacement ?? 0),
    max_axial_n: Number(variant.max_axial_n ?? 0),
    max_surface_stress_pa: Number(variant.max_surface_stress_pa ?? 0),
    suggested_scale: Number(variant.suggested_scale ?? 1),
    counts: variant.counts,
    hashes: { geometry: file.geometryHash, analysis: "" },
    components,
    design_trace: trace,
    element_section: sections,
    analysis_model: variant.analysis_model,
  }
  return { header, arrays, variants: file, variantId: id }
}

async function inflate(file: VariantFile, hash: string) {
  const block = file.blocks[hash]
  if (!block) throw new Error(`scene is missing block ${hash.slice(0, 12)}`)
  const raw = await gunzip(block.gzip)
  const countBytes = u32Bytes(block.count)
  const scaleBytes = f32Bytes(block.scale)
  const digest = await sha256([new TextEncoder().encode(block.dtype), countBytes, scaleBytes, raw])
  if (digest !== hash) throw new Error(`scene block ${hash.slice(0, 12)} does not match its bytes`)
  if (block.storage === 1) {
    if (block.dtype !== "i16" || raw.byteLength !== block.count * 2) {
      throw new Error("quantized scene block has the wrong length")
    }
    const aligned = copyBytes(raw)
    const steps = new Int16Array(aligned)
    const values = new Float32Array(block.count)
    for (let i = 0; i < block.count; i++) values[i] = steps[i] * block.scale
    return { dtype: "f32", bytes: new Uint8Array(values.buffer) }
  }
  if (block.dtype === "json") {
    if (raw.byteLength !== block.count) throw new Error("json scene block has the wrong length")
    return { dtype: "json" as const, text: new TextDecoder().decode(raw) }
  }
  const width = DTYPE_SIZE[block.dtype]
  if (width === undefined || raw.byteLength !== block.count * width) {
    throw new Error(`scene block ${hash.slice(0, 12)} has the wrong length`)
  }
  return { dtype: block.dtype, bytes: raw }
}

function jsonBlock(file: VariantFile, hash: string): unknown {
  const block = file.cache[hash]
  if (!block || !("text" in block)) throw new Error("scene record block is not JSON")
  return JSON.parse(block.text)
}

/** Designs that differ from `currentId` only in axes anchored at `anchor`. */
export function variantNeighbors(file: VariantFile, currentId: string, anchor: string): SceneVariant[] {
  const current = file.variants.find((item) => item.id === currentId)
  if (!current) throw new Error(`variant ${currentId} is not in the scene`)
  const mine = file.axes.filter((axis) => axis.anchor === anchor)
  const other = file.axes.filter((axis) => axis.anchor !== anchor)
  return file.variants.filter((variant) => {
    if (variant.id === currentId) return false
    const same = other.every((axis) => current.params[axis.field]?.hash === variant.params[axis.field]?.hash)
    const differs = mine.some((axis) => current.params[axis.field]?.hash !== variant.params[axis.field]?.hash)
    return same && differs
  })
}

async function gunzip(gzip: ArrayBuffer): Promise<Uint8Array> {
  const stream = new Blob([gzip]).stream().pipeThrough(new DecompressionStream("gzip"))
  return new Uint8Array(await new Response(stream).arrayBuffer())
}

async function sha256(parts: Uint8Array[]): Promise<string> {
  const bytes = concat(parts)
  const digest = await crypto.subtle.digest("SHA-256", copyBytes(bytes))
  return bytesToHex(new Uint8Array(digest))
}

function u32Bytes(value: number): Uint8Array {
  const out = new Uint8Array(4)
  new DataView(out.buffer).setUint32(0, value, true)
  return out
}

function f32Bytes(value: number): Uint8Array {
  const out = new Uint8Array(4)
  new DataView(out.buffer).setFloat32(0, value, true)
  return out
}

function offsetU32(bytes: Uint8Array, add: number): Uint8Array {
  if (bytes.length === 0 || add === 0) return bytes
  const copy = new Uint8Array(bytes)
  const values = new Uint32Array(copy.buffer)
  for (let i = 0; i < values.length; i++) values[i] += add
  return copy
}

function concat(chunks: Uint8Array[]): Uint8Array {
  const total = chunks.reduce((sum, chunk) => sum + chunk.length, 0)
  const out = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    out.set(chunk, offset)
    offset += chunk.length
  }
  return out
}

function copyBytes(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer
}

function bytesToHex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("")
}

function byId(a: { id: string }, b: { id: string }): number {
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0
}
