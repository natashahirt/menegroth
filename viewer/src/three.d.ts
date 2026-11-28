// three 0.170 publishes JavaScript without bundled declarations.
declare module "three" {
  export class Color {
    constructor(color?: string | number)
    r: number
    g: number
    b: number
    [key: string]: any
  }

  class Loose {
    constructor(...args: any[])
    [key: string]: any
  }

  export { Loose as WebGLRenderer }
  export { Loose as Scene }
  export { Loose as HemisphereLight }
  export { Loose as DirectionalLight }
  export { Loose as Camera }
  export { Loose as PerspectiveCamera }
  export { Loose as OrthographicCamera }
  export { Loose as AxesHelper }
  export { Loose as WebGLRenderTarget }
  export { Loose as Clock }
  export { Loose as Box3 }
  export { Loose as Vector2 }
  export { Loose as Vector3 }
  export { Loose as Vector4 }
  export { Loose as Quaternion }
  export { Loose as Matrix4 }
  export { Loose as Spherical }
  export { Loose as Sphere }
  export { Loose as Raycaster }
  export { Loose as GridHelper }
  export { Loose as LineSegments }
  export { Loose as LineLoop }
  export { Loose as ShaderMaterial }
  export { Loose as LineBasicMaterial }
  export { Loose as CanvasTexture }
  export { Loose as Sprite }
  export { Loose as SpriteMaterial }
  export { Loose as BufferGeometry }
  export { Loose as BufferAttribute }
  export { Loose as DataTexture }
  export { Loose as ConeGeometry }
  export { Loose as MeshLambertMaterial }
  export { Loose as MeshBasicMaterial }
  export { Loose as PlaneGeometry }
  export { Loose as Plane }
  export { Loose as Material }
  export { Loose as InstancedMesh }
  export { Loose as InstancedBufferAttribute }
  export { Loose as Object3D }
  export { Loose as BoxGeometry }
  export { Loose as Group }
  export { Loose as Mesh }
  export { Loose as Shape }
  export { Loose as ShapeGeometry }
  export const FrontSide: any
  export const BackSide: any
  export const DoubleSide: any
  export const AlwaysStencilFunc: any
  export const NotEqualStencilFunc: any
  export const ReplaceStencilOp: any
  export const IncrementWrapStencilOp: any
  export const DecrementWrapStencilOp: any
  export type Side = number
  export type StencilOp = number

  export const GLSL3: any
  export const SRGBColorSpace: any
  export const LinearSRGBColorSpace: any
  export const NoColorSpace: any
  export const UnsignedByteType: any
  export const RGBAFormat: any
  export const RedFormat: any
  export const FloatType: any
  export const NearestFilter: any
  export const ClampToEdgeWrapping: any
  export type PixelFormat = number
  export type Texture = any
  export const MathUtils: { degToRad: (degrees: number) => number }
}

declare module "three/addons/lines/LineSegments2.js" {
  export class LineSegments2 {
    constructor(geometry?: any, material?: any)
    [key: string]: any
  }
}

declare module "three/addons/lines/LineSegmentsGeometry.js" {
  export class LineSegmentsGeometry {
    constructor()
    setPositions(array: Float32Array | number[]): any
    [key: string]: any
  }
}

declare module "three/addons/lines/LineMaterial.js" {
  export class LineMaterial {
    constructor(params?: object)
    [key: string]: any
  }
}
