# Wall rebar placement and detailing — plan

Status: proposal, 2026-11-06. Nothing here is implemented. Questions that need
a decision before code are collected in [Decisions needed](#decisions-needed).

Clause text was read from the corpus (`aci-318-19`, ACI 318-19 with
commentary); PDF page numbers are given with each clause.

## Goal

Place the bars of every cast-in-place concrete wall the same way columns, beams,
flat plates, and footings are placed today: a `MemberDetail` of `BarGroup`s
with exact lengths, shapes, laps, and positions, so that

- the takeoff (mass, carbon) comes from placed bars, not `ρ · volume`;
- the scene record carries `drawing.detail` and the viewer draws a wall
  elevation and a plan section with the bars;
- detailing checks that the sizing did not make (spacing limits, curtains,
  trim bars, anchorage, splices, dowel embedment) are reported as warnings.

## What exists

| Piece | Where | What it gives the detailer |
| --- | --- | --- |
| `Wall{T}` | `StructuralSynthesizer/src/building_types/members.jl` | plan endpoints, `thickness`, `story`, `ρl`, `ρt`, `openings::Vector{WallOpening}`, `wall_above`, `concrete` |
| `WallOpening` | `building_types/wall_openings.jl` | `s0`, `z0`, `width`, `height` in wall coordinates, `kind` |
| `WallCheckRecord` | `design/results/wall.jl` | per pier, story, direction, combination: check name, demand, capacity, clause |
| Ordinary-wall reinforcement selection | `analyze/lateral/wall_ordinary_check.jl` | `ρt` from Eq. 11.5.4.3 on a 0.0005 grid, `ρl` walked up until in-plane flexure passes (memory `chec-5b4b6555`) |
| `WallAssembly.joined` | `building_types/wall_mesh.jl` | isolated pier vs walls that meet (no core tag yet) |
| Detailing core | `StructuralSizer/src/detailing/` | hooks, bend diameters, `straight_development_length`, `hooked_bar_development_length`, `compression_development_length`, `tension_lap_length`, `stock_splices`, `BarGroup`, `MemberDetail` (now with `outline`) |
| Building pass | `StructuralSynthesizer/src/postprocess/detailing.jl` | `BuildingDetail`, `detail_building`, scene `drawing.detail` |
| Viewer | `viewer/src/detail.ts`, `detail-draw.ts` | `barElevation` with outlines, callouts, transverse stations, schedule table |

The sizing result is a **smeared ratio** per pier (`ρl`, `ρt`) with uniform
vertical steel in the flexure model (`wall_axial_flexure_capacity_si` uses
`Ast = ρl · lw · t`). There is no bar size, spacing, curtain count, or boundary
steel. The detailer must turn ratios into bars without adding strength the
design did not assume and without removing any it did.

## Provisions (ordinary cast-in-place walls, Ch. 11)

- **Vertical spacing** §11.7.2.1 (p. 173): `s ≤ min(3h, 18 in.)`; if shear
  reinforcement is required for in-plane strength, `s ≤ ℓw/3`.
- **Horizontal spacing** §11.7.3.1 (p. 174): `s ≤ min(3h, 18 in.)`; if shear
  reinforcement is required for in-plane strength, `s ≤ ℓw/5`.
- **Curtains** §11.7.2.3 (p. 174): for `h > 10 in.`, except single-story
  basement walls and cantilever retaining walls, distributed reinforcement in
  each direction in at least two layers, one near each face.
- **Flexural tension steel** §11.7.2.4 (p. 174): well distributed and as close
  as practicable to the tension face.
- **Lateral support of vertical bars** §11.7.4.1 (p. 174): if longitudinal
  steel is required for compression and `Ast` exceeds the clause's fraction of
  `Ag`, the bars are tied. The text layer on this page is damaged ("0.001A"
  next to doubled letters); read the ratio from the PDF before coding it.
- **Openings** §11.7.5.1 (p. 174): in addition to the §11.6 minimum, at least
  two No. 5 bars (two-layer walls) or one No. 5 bar (single layer) around
  window, door, and similar openings, anchored to develop `fy` in tension at
  the corners.
- **Development and splices**: §25.4 and §25.5 (referenced from §11.7.1).
- **Wall to foundation** §16.3.4.2 (p. 226): vertical steel crossing the
  interface satisfies §11.6.1. §16.3.5.1: provided by extending the wall bars
  into the foundation or by dowels.

## Provisions (special structural walls, §18.10) — phase W5

- §18.10.2.1 (p. 320): `ρl, ρt ≥ 0.0025` (ρt may drop to §11.6 if
  `Vu ≤ λ√f′c·Acv`); spacing each way ≤ 18 in.; steel contributing to `Vn`
  continuous and distributed across the shear plane.
- §18.10.2.2 (p. 320): two curtains if `Vu > 2λ√f′c·Acv` or `hw/ℓw ≥ 2.0`
  (`hw`, `ℓw` of the entire wall).
- §18.10.2.3 (p. 320): developed or spliced for `fy` in tension per §25.4,
  §25.5, and (a)–(d), including extension 12 ft above the point where the bar
  is no longer needed for flexure (except at the top of the wall).
- §18.10.6.3 (p. 327): stress trigger, special boundary element where the
  extreme fiber stress exceeds `0.2f′c`, may stop where it drops below
  `0.15f′c`.
- §18.10.6.4 (p. 327–328): extent `≥ max(c − 0.1ℓw, c/2)`; width over that
  extent `≥ hu/16`; `b ≥ 12 in.` for `hw/ℓw ≥ 2.0` walls with `c/ℓw ≥ 3/8`;
  flanged sections include the effective flange and extend 12 in. into the
  web; (e) onward cover transverse reinforcement.
- §18.10.6.5 (p. 332): without special boundary elements, (a) horizontal bars
  at wall edges get a standard hook around the edge bars or U-stirrups of the
  same size and spacing spliced to them, unless `Vu < λ√f′c·Acv`; (b) where the
  boundary longitudinal ratio exceeds `400/fy`, boundary ties per §18.7.5.2(a)–(e)
  over the §18.10.6.4(a) length at the Table 18.10.6.5(b) spacing.

Phase W5 needs the neutral-axis depth `c` and the boundary stress from the
special-wall design (memory `todo-701f6fca`), which does not exist yet.

## Architecture

### StructuralSizer: `detail_wall`

New file `StructuralSizer/src/detailing/wall.jl`:

```julia
detail_wall(; length, height, thickness, ρl, ρt, openings = [],
            curtains = :auto, cover = 0.75u"inch",
            bar_sizes = (4, 5, 6), spacing_step = 0.5u"inch",
            shear_reinforcement_required = false,
            ends = (:free, :free),        # or :joined (corner / tee)
            below = :foundation,          # or :wall
            above = :wall,                # or :roof
            slab_above, slab_cover, foundation_depth = nothing,
            fc, fy, λ = 1.0, coating = :uncoated, stock = 60u"ft") -> MemberDetail
```

Elevation coordinates: `x` along the wall from its start vertex, `z` up from
the top of the slab or foundation below (same convention as `WallOpening`).

Steps:

1. **Curtains.** `h > 10 in.` → 2 (§11.7.2.3); otherwise 1. A `:two`/`:one`
   override exists for basement and retaining walls, which the clause exempts.
2. **Bars from ratios.** For each direction, the steel area per unit length is
   `ρ · h`, split equally between curtains. Pick the smallest bar in
   `bar_sizes` whose spacing, `n_curtains · Ab / (ρ · h)` rounded down to
   `spacing_step`, also satisfies the spacing cap (§11.7.2.1 / §11.7.3.1, with
   `ℓw/3` and `ℓw/5` when shear reinforcement is required). The provided ratio
   is then `≥ ρ`. Record it in a note so the drawing can show provided vs required.
3. **Vertical bars** (`role = :vertical`): stations from `cover + db/2` at each
   end, at most `s` apart. Bars interrupted by an opening are separate groups
   (below and above the opening) so lengths are exact. Length from the base to
   the floor above plus a lap with the wall above (Class B, Table 25.5.2.1,
   like `column_lap_length`), or a 90-degree hook into the roof slab when
   `above = :roof`.
4. **Horizontal bars** (`role = :horizontal`): stations up the story at `s`,
   starting `s/2` above the base. Bars stop at openings. Free ends: standard
   hook around the outermost vertical bar (see decision 3). Joined ends:
   continue around the corner with corner bars lapped Class B into each leg.
   Runs longer than stock get splices (`stock_splices`).
5. **Opening trim bars** (`role = :trim`): two No. 5 (two curtains) or one
   No. 5 per face of each opening (§11.7.5.1), each extending `ℓd` past the
   corners (develop `fy`). Where the extension runs into the wall end or
   another opening, hook it and check `ℓdh`.
6. **Dowels** (`role = :dowel`) when `below = :foundation`: one per vertical
   bar (meets §16.3.4.2 when the wall bars meet §11.6.1), 90-degree hook on the
   foundation mat, lapped with the wall bars. Embedment checked in tension
   (`ℓdh`) because wall vertical bars can be in tension under overturning;
   compression `ℓdc` (§25.4.9) also checked. Needs the foundation depth.
7. **Outline**: the wall rectangle `(0, ℓw, 0, height)` first, then the slab
   above and the foundation or wall below. Openings go in a new
   `MemberDetail.voids` field (rectangles drawn as holes), see below.
8. **Warnings**: spacing cap exceeded at the largest bar, trim bars that can
   develop neither straight nor hooked, dowels short of `ℓdh`/`ℓdc`, ties
   needed by §11.7.4.1, laps over stock.

### Data model changes

- `BarGroup.z_positions::Vector{Float64}`: stations up the member for bars
  repeated vertically (wall horizontals). Today `x_positions` covers stirrups
  and ties; the drawing and the takeoff treat both the same way.
- `MemberDetail.voids::Vector{NTuple{4, Float64}}`: holes in the outline
  (wall openings). Empty for every other member.
- `MemberDetail.section`: optional plan-section view, bar dots
  `(y, z_or_x, diameter)` and curtain lines for the through-thickness cut. A
  wall needs both an elevation and a plan section; beams and columns could use
  it later for their cross-sections drawn from placed bars.

### StructuralSynthesizer

- `_detail_wall(design, geo, idx)` in `postprocess/detailing.jl`: reads
  `struc.walls[idx]`, the largest in-plane `Vu` from `design.walls[idx]`
  records (for the shear-reinforcement-required spacing limits), `wall_above`,
  the slab above (as for columns), the grade foundation once the wall
  strip/mat path exists (memory `deci-67cf61cb`), and `WallAssembly.joined`
  plus the neighbor geometry to set `ends`.
- `BuildingDetail.walls::Dict{Int, MemberDetail}`; `building_detail_mass`
  includes them.
- Scene: the wall component record gets `drawing.detail`.

### Viewer

- `barSheets(kind === "wall")`: elevation with voids cut out, verticals drawn at
  `x_positions`, horizontals at `z_positions`, trim bars, dowels and laps;
  plan section from `detail.section`. Long walls are not exaggerated (the
  aspect ratio is near 1); a dense mesh is drawn as thin lines with only the
  first and last bar of each group labelled.
- Schedule, warnings, and notes reuse `barSchedule`.

## Phases

| Phase | Scope | Tests |
| --- | --- | --- |
| W1 | Solid ordinary wall, one story: curtains, bars from ratios, spacing caps, verticals with lap or roof hook, horizontals with end hooks, outline | hand calcs: 12 in. × 20 ft × 12 ft wall at ρ = 0.0025 (two curtains, #4 @ 13 in. → check against `3h`/18 in.), an 8 in. single-curtain wall, a shear-governed wall where `ℓw/5` governs |
| W2 | Openings: interrupted bars, trim bars, `voids` | door and window cases; trim length = opening side + 2ℓd; extension blocked by the wall end → hook + `ℓdh` warning |
| W3 | Stacks and foundations: laps at floors, dowels into strip/mat, joined ends (L, T corner bars) | three-story stack; dowel embedment warnings; corner lap lengths |
| W4 | Building pass, scene, viewer elevation + plan section, integration test on an office fixture with walls | scene record round trip; screenshot check of the drawing |
| W5 | Special walls (§18.10) after the special-wall design: 18 in. cap, curtain rule §18.10.2.2, §18.10.2.3 splices and 12 ft extension, boundary elements §18.10.6.4, edge hooks and boundary ties §18.10.6.5 | clause-boundary tests; StructurePoint `sp-de-shear-wall-aci19` as a layout oracle |

Oracles in the corpus for layouts and quantities: `sp-de-shear-wall-aci19`,
`sp-de-multi-story-solid-aci19`, `sp-de-multi-story-openings-aci19`,
`sp-de-tilt-up-wall-with-opening-aci19`.

## Decisions needed

1. **Bar menu and spacing step.** Proposed: #4–#6, spacing rounded down to
   0.5 in. Some offices use 1 in. or 3 in. steps for walls.
2. **"Shear reinforcement is required for in-plane strength"** (§11.7.2.1,
   §11.7.3.1) turns on the `ℓw/3` and `ℓw/5` caps. Proposed reading:
   `Vu > φ·αc·λ·√f′c·Acv` (concrete alone is not enough). The alternative is
   `Vu > 0.5φ·αc·λ·√f′c·Acv`, the Table 11.6.1 threshold. This should be
   confirmed against the commentary before coding.
3. **Horizontal bar ends at free edges of ordinary walls.** §18.10.6.5(a)
   requires hooks or U-stirrups only for special walls. For ordinary walls the
   code asks for development of the bars needed for shear (§25.4). Proposed:
   standard hook at free ends (engineering judgment, flagged as such).
4. **Bars interrupted by openings.** §11.7.5.1 adds trim bars *in addition to*
   the minimum. It does not ask that the interrupted distributed bars be
   replaced. Proposed: no replacement beyond §11.7.5.1 unless the user wants
   the common practice of adding the interrupted area at the opening sides.
   Diagonal corner bars likewise are practice, not code.
5. **Lap class for wall verticals.** Proposed: Class B always, the same
   conservative choice as columns, since the bar stresses are not kept.
6. **Lintels/spandrels over openings.** The wall above an opening acts as a
   beam (coupling beam in §18.10.7 for special walls). It is not designed
   today, so its bars would be detailing without a design. Proposed: flag it
   as a warning and leave it to a later design phase.
7. **Wall foundations.** Dowels need the strip or mat depth. Until the wall
   strip/mat design path exists (memory `deci-67cf61cb`), dowels are placed with
   a warning that the embedment is unchecked.
