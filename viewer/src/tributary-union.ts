/** Join plan loops that share an edge. A vertex on an edge splits that edge first, so a T-junction still dissolves. */

const TOL = 1e-3

type P = [number, number]

function q(v: number): number {
  return Math.round(v / TOL) * TOL
}

function signedArea(pts: P[]): number {
  let area = 0
  for (let i = 0; i < pts.length; i++) {
    const p = pts[i]
    const n = pts[(i + 1) % pts.length]
    if (!p || !n) continue
    area += p[0] * n[1] - n[0] * p[1]
  }
  return area / 2
}

function ccw(pts: P[]): P[] {
  const loop = pts.map((p) => [q(p[0]), q(p[1])] as P)
  return signedArea(loop) < 0 ? loop.reverse() : loop
}

/** Parameter of `p` along `a`→`b` when `p` lies strictly inside the segment. */
function inside(p: P, a: P, b: P): number | null {
  const dx = b[0] - a[0]
  const dy = b[1] - a[1]
  const len2 = dx * dx + dy * dy
  if (len2 <= TOL * TOL) return null
  const t = ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2
  if (t <= 1e-4 || t >= 1 - 1e-4) return null
  const x = a[0] + t * dx
  const y = a[1] + t * dy
  return Math.hypot(x - p[0], y - p[1]) <= TOL * 2 ? t : null
}

function edgeKey(a: P, b: P): string {
  return `${a[0]},${a[1]}|${b[0]},${b[1]}`
}

function pointKey(p: P): string {
  return `${p[0]},${p[1]}`
}

function dropCollinear(pts: P[]): P[] {
  if (pts.length < 4) return pts
  const kept: P[] = []
  for (let i = 0; i < pts.length; i++) {
    const a = pts[(i + pts.length - 1) % pts.length]
    const b = pts[i]
    const c = pts[(i + 1) % pts.length]
    if (!a || !b || !c) continue
    const cross = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
    if (Math.abs(cross) > 1e-6) kept.push(b)
  }
  return kept.length >= 3 ? kept : pts
}

function onOrIn(p: P, ring: P[]): boolean {
  for (let i = 0; i < ring.length; i++) {
    const a = ring[i]
    const b = ring[(i + 1) % ring.length]
    if (!a || !b) continue
    if (Math.hypot(p[0] - a[0], p[1] - a[1]) <= TOL * 2) return true
    if (inside(p, a, b) !== null) return true
  }
  let crossings = false
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const a = ring[i]
    const b = ring[j]
    if (!a || !b || a[1] === b[1]) continue
    const intersect = (a[1] > p[1]) !== (b[1] > p[1]) &&
      p[0] < ((b[0] - a[0]) * (p[1] - a[1])) / (b[1] - a[1]) + a[0]
    if (intersect) crossings = !crossings
  }
  return crossings
}

/** A loop whose vertices all lie in a larger loop is already drawn. */
function withoutContained(loops: P[][]): P[][] {
  const oriented = loops.filter((loop) => loop.length >= 3).map(ccw)
  return oriented.filter((loop, i) => {
    const mine = Math.abs(signedArea(loop))
    return !oriented.some((other, j) => {
      if (i === j || Math.abs(signedArea(other)) <= mine + 1e-6) return false
      return loop.every((p) => onOrIn(p, other))
    })
  })
}

export interface PlanUnion {
  rings: P[][]
  /** Edges shared by two pieces of the same owner. They lie inside `rings`. */
  seams: [P, P][]
}

/**
 * Outer rings of the union, plus the shared edges that the union cancelled.
 * Loops that only meet at a corner stay separate. Input loops may be clockwise.
 */
export function unionPlanLoops(loops: P[][]): PlanUnion {
  const kept = withoutContained(loops)
  const raw: { a: P; b: P }[] = []
  const points: P[] = []
  const seen = new Set<string>()
  const addPoint = (p: P) => {
    const key = pointKey(p)
    if (seen.has(key)) return
    seen.add(key)
    points.push(p)
  }
  for (const ring of kept) {
    for (let i = 0; i < ring.length; i++) {
      const a = ring[i]
      const b = ring[(i + 1) % ring.length]
      if (!a || !b || (a[0] === b[0] && a[1] === b[1])) continue
      raw.push({ a, b })
      addPoint(a)
      addPoint(b)
    }
  }
  const split: { a: P; b: P }[] = []
  for (const edge of raw) {
    const hits: { t: number; p: P }[] = []
    for (const p of points) {
      const t = inside(p, edge.a, edge.b)
      if (t !== null) hits.push({ t, p })
    }
    hits.sort((u, v) => u.t - v.t)
    let prev = edge.a
    for (const hit of hits) {
      if (hit.p[0] === prev[0] && hit.p[1] === prev[1]) continue
      split.push({ a: prev, b: hit.p })
      prev = hit.p
    }
    if (prev[0] !== edge.b[0] || prev[1] !== edge.b[1]) split.push({ a: prev, b: edge.b })
  }
  const live = new Map<string, { a: P; b: P; n: number }>()
  const seams: [P, P][] = []
  for (const edge of split) {
    const fwd = edgeKey(edge.a, edge.b)
    const rev = edgeKey(edge.b, edge.a)
    const opposite = live.get(rev)
    if (opposite) {
      opposite.n -= 1
      if (opposite.n === 0) {
        live.delete(rev)
        seams.push([opposite.a, opposite.b])
      }
      continue
    }
    const same = live.get(fwd)
    if (same) same.n += 1
    else live.set(fwd, { a: edge.a, b: edge.b, n: 1 })
  }
  const out = new Map<string, { a: P; b: P; used: boolean }[]>()
  for (const edge of live.values()) {
    const list = out.get(pointKey(edge.a)) ?? []
    list.push({ a: edge.a, b: edge.b, used: false })
    out.set(pointKey(edge.a), list)
  }
  const rings: P[][] = []
  for (const list of out.values()) {
    for (const start of list) {
      if (start.used) continue
      const ring: P[] = [start.a]
      let prev = start.a
      let cursor = start
      cursor.used = true
      let guard = 0
      while (pointKey(cursor.b) !== pointKey(start.a) && guard++ < live.size + 2) {
        ring.push(cursor.b)
        const options = (out.get(pointKey(cursor.b)) ?? []).filter((edge) => !edge.used)
        const next = leftmost(prev, cursor.b, options)
        if (!next) break
        prev = cursor.b
        cursor = next
        cursor.used = true
      }
      if (ring.length >= 3 && pointKey(cursor.b) === pointKey(start.a)) rings.push(dropCollinear(ring))
    }
  }
  return { rings, seams }
}

export function mergePlanLoops(loops: P[][]): P[][] {
  return unionPlanLoops(loops).rings
}

/** The unused edge whose turn from the arrival keeps the interior on the left. */
function leftmost(prev: P, at: P, options: { a: P; b: P; used: boolean }[]): { a: P; b: P; used: boolean } | undefined {
  if (options.length === 0) return undefined
  if (options.length === 1) return options[0]
  const vx = at[0] - prev[0]
  const vy = at[1] - prev[1]
  let best = options[0]
  let bestAngle = Infinity
  for (const edge of options) {
    const cross = vx * (edge.b[1] - at[1]) - vy * (edge.b[0] - at[0])
    const dot = vx * (edge.b[0] - at[0]) + vy * (edge.b[1] - at[1])
    let angle = Math.atan2(cross, dot)
    if (angle < 0) angle += Math.PI * 2
    if (angle < bestAngle) {
      best = edge
      bestAngle = angle
    }
  }
  return best
}
