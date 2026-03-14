# =============================================================================
# FEA Bug Diagnostic Script
# =============================================================================
#
# Investigates three bugs found in the FEA comparison report:
#
#   Bug 1: Area-based CS positive ≈ 12% (expected ~50-60%)
#   Bug 2: Isoparametric Σ/M₀ = 140% (expected ~100-120%)
#   Bug 3: Projection δ-band Σ/M₀ = 118% (expected ≤100% for two-way slab)
#
# Usage:
#   julia scripts/runners/diagnose_fea_bugs.jl
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using Printf
using Unitful
using Unitful: @u_str
using Asap
using Logging

using StructuralSizer
using StructuralSynthesizer

const SR = StructuralSizer
const SS = StructuralSynthesizer

function main()

# ─────────────────────────────────────────────────────────────────────────────
# Build the same test building as the report
# ─────────────────────────────────────────────────────────────────────────────
println("═"^90)
println("  FEA BUG DIAGNOSTIC")
println("═"^90)
println()

h     = 7.0u"inch"
sdl   = 20.0u"psf"
ll    = 50.0u"psf"
fc    = 4000.0u"psi"
mat   = SR.RC_4000_60

struc = with_logger(NullLogger()) do
    _skel = SS.gen_medium_office(54.0u"ft", 42.0u"ft", 9.0u"ft", 3, 3, 1)
    _struc = SS.BuildingStructure(_skel)
    _opts = SR.FlatPlateOptions(
        material = mat,
        method   = SR.FEA(),
        cover    = 0.75u"inch",
        bar_size = 5,
    )
    SS.initialize!(_struc; floor_type=:flat_plate, floor_opts=_opts)
    for c in _struc.cells
        c.sdl       = uconvert(u"kN/m^2", sdl)
        c.live_load = uconvert(u"kN/m^2", ll)
    end
    for col in _struc.columns
        col.c1 = 16.0u"inch"
        col.c2 = 16.0u"inch"
    end
    SS.to_asap!(_struc)
    _struc
end

slab    = struc.slabs[1]
cell_set = Set(slab.cell_indices)
columns = SR.find_supporting_columns(struc, cell_set)

γ   = mat.concrete.ρ
ν   = mat.concrete.ν
wc  = ustrip(SR.pcf, γ)
Ecs = SR.Ec(fc, wc)

# Build FEA cache
cache = SR.FEAModelCache()
baseline_method = SR.FEA(design_approach=:frame, pattern_loading=false)
baseline_result = with_logger(NullLogger()) do
    SR.run_moment_analysis(
        baseline_method, struc, slab, columns, h, fc, Ecs, γ;
        ν_concrete=ν, verbose=false, cache=cache)
end

setup = SR._moment_analysis_setup(struc, slab, columns, h, γ)
span_axis = setup.span_axis
ax, ay = span_axis

M0_kf = ustrip(u"kip*ft", baseline_result.M0)
_Nm_to_kf = ustrip(u"kip*ft", 1.0u"N*m")

println("  span_axis = $span_axis")
println("  M₀ = $(round(M0_kf, digits=2)) kip·ft")
println("  Mesh: $(length(cache.model.shell_elements)) elements, $(length(cache.model.nodes)) nodes")
println("  Cells: $(sort(collect(slab.cell_indices)))")
println()

# ─────────────────────────────────────────────────────────────────────────────
# Pick a representative interior cell for diagnostics
# ─────────────────────────────────────────────────────────────────────────────
skel = struc.skeleton
cell_to_cols = SR._build_cell_to_columns(columns)

# Debug: show what cell_to_cols contains
println("  cell_to_cols keys: $(sort(collect(keys(cell_to_cols))))")
for ci in sort(collect(keys(cell_to_cols)))
    cols = cell_to_cols[ci]
    println("    cell $ci: $(length(cols)) columns [$(join([string(c.position) for c in cols], ", "))]")
end
println()

# Find a cell with elements and columns — prefer one with interior columns
diag_ci = nothing
for ci in sort(collect(slab.cell_indices))
    tri_idx_test = get(cache.cell_tri_indices, ci, Int[])
    cell_cols = get(cell_to_cols, ci, eltype(columns)[])
    if !isempty(tri_idx_test) && !isempty(cell_cols)
        n_int = count(c -> c.position == :interior, cell_cols)
        if n_int >= 1
            diag_ci = ci
            break
        end
        # Fall back to any cell with columns + elements
        if diag_ci === nothing
            diag_ci = ci
        end
    end
end

if diag_ci === nothing
    # Last resort: first cell with elements
    for ci in sort(collect(slab.cell_indices))
        tri_idx_test = get(cache.cell_tri_indices, ci, Int[])
        if !isempty(tri_idx_test)
            diag_ci = ci
            break
        end
    end
end

@assert diag_ci !== nothing "No diagnostic cell found!"

println("  Diagnostic cell: $diag_ci")
cell_cols = get(cell_to_cols, diag_ci, eltype(columns)[])
println("  Cell columns: $(length(cell_cols))")
for (j, col) in enumerate(cell_cols)
    px, py = SR._column_xy_m(skel, col)
    c1_in = round(ustrip(u"inch", col.c1), digits=1)
    c2_in = round(ustrip(u"inch", col.c2), digits=1)
    println("    Col $j ($(col.position)): vertex=$(col.vertex_idx) at ($(round(px*3.281,digits=2)), $(round(py*3.281,digits=2))) ft, c1=$(c1_in)\", c2=$(c2_in)\"")
end

geom = SR._cell_geometry_m(struc, diag_ci; _cache=cache.cell_geometries)
println("  Cell polygon (ft):")
for (i, v) in enumerate(geom.poly)
    println("    V$i: ($(round(v[1]*3.281, digits=2)), $(round(v[2]*3.281, digits=2)))")
end
cx, cy = geom.centroid
println("  Centroid: ($(round(cx*3.281, digits=2)), $(round(cy*3.281, digits=2))) ft")

tri_idx = get(cache.cell_tri_indices, diag_ci, Int[])
println("  Elements in cell: $(length(tri_idx))")

δ = SR._section_cut_bandwidth(cache, cell_cols)
println("  δ-band width: $(round(δ*1000, digits=0)) mm = $(round(δ*3.281, digits=2)) ft")
println("  mesh_edge_length: $(round(cache.mesh_edge_length*1000, digits=0)) mm")
println()

# =============================================================================
# BUG 1: Area-based CS/MS split diagnostic
# =============================================================================
println("═"^90)
println("  BUG 1: AREA-BASED CS/MS SPLIT")
println("═"^90)
println()

# Build CS polygons (same as both methods use)
neg_cs_polys = SR._build_cs_polygons_abs(geom.poly; span_axis=span_axis)
pos_cs_polys = SR._build_cs_polygons_abs(geom.poly)

println("  CS polygons (negative, span-filtered): $(length(neg_cs_polys))")
for (i, poly) in enumerate(neg_cs_polys)
    println("    Poly $i: $(length(poly)) vertices")
    for (j, v) in enumerate(poly)
        println("      V$j: ($(round(v[1]*3.281, digits=2)), $(round(v[2]*3.281, digits=2))) ft")
    end
end
println()
println("  CS polygons (positive, all edges): $(length(pos_cs_polys))")
for (i, poly) in enumerate(pos_cs_polys)
    println("    Poly $i: $(length(poly)) vertices")
    for (j, v) in enumerate(poly)
        println("      V$j: ($(round(v[1]*3.281, digits=2)), $(round(v[2]*3.281, digits=2))) ft")
    end
end
println()

# Classify elements in the midspan δ-band
half_δ = δ / 2
cent_s = ax * cx + ay * cy

n_in_band = 0
n_cs_pos = 0
n_ms_pos = 0
sum_area_cs = 0.0
sum_area_ms = 0.0

for k in tri_idx
    ed = cache.element_data[k]
    elem_s = ax * ed.cx + ay * ed.cy
    abs(elem_s - cent_s) > half_δ && continue
    n_in_band += 1
    if SR._is_in_column_strip(ed.cx, ed.cy, pos_cs_polys)
        n_cs_pos += 1
        sum_area_cs += ed.area
    else
        n_ms_pos += 1
        sum_area_ms += ed.area
    end
end

total_area = sum_area_cs + sum_area_ms
cs_area_frac = total_area > 0 ? sum_area_cs / total_area * 100 : 0.0

println("  Elements in midspan δ-band: $n_in_band")
println("    CS elements: $n_cs_pos (area = $(round(sum_area_cs, digits=4)) m²)")
println("    MS elements: $n_ms_pos (area = $(round(sum_area_ms, digits=4)) m²)")
println("    CS area fraction: $(round(cs_area_frac, digits=1))%")
println()

# Now compare the actual moment integration
# Strip method (δ-proj):
neg_cs_tri, neg_ms_tri = SR._classify_triangles(cache.element_data, tri_idx, neg_cs_polys)
pos_cs_tri, pos_ms_tri = SR._classify_triangles(cache.element_data, tri_idx, pos_cs_polys)

Mpos_cs_strip = max(0.0, -SR._integrate_at_subset(
    cache.element_data, pos_cs_tri, geom.centroid, span_axis, δ))
Mpos_ms_strip = max(0.0, -SR._integrate_at_subset(
    cache.element_data, pos_ms_tri, geom.centroid, span_axis, δ))

println("  STRIP METHOD (δ-proj) at midspan:")
println("    CS M⁺ = $(round(Mpos_cs_strip * _Nm_to_kf, digits=2)) kip·ft")
println("    MS M⁺ = $(round(Mpos_ms_strip * _Nm_to_kf, digits=2)) kip·ft")
println("    Total = $(round((Mpos_cs_strip + Mpos_ms_strip) * _Nm_to_kf, digits=2)) kip·ft")
cs_frac_strip = (Mpos_cs_strip + Mpos_ms_strip) > 0 ?
    Mpos_cs_strip / (Mpos_cs_strip + Mpos_ms_strip) * 100 : 0.0
println("    CS fraction: $(round(cs_frac_strip, digits=1))%")
println()

# Area method (area-pr):
area_method_pr = SR.FEA(design_approach=:area, moment_transform=:projection, pattern_loading=false)
area_moms_pr = SR._extract_area_design_moments(cache, area_method_pr, span_axis; verbose=false)

# Replicate the area bridge logic for this cell
Mpos_cs_area = 0.0
Mpos_ms_area = 0.0
n_zero_mx_bot = 0
n_nonzero_mx_bot = 0
sum_mx_bot_cs = 0.0
sum_mx_bot_ms = 0.0

for k in tri_idx
    k > length(area_moms_pr) && continue
    am = area_moms_pr[k]
    ed = cache.element_data[k]
    elem_s = ax * ed.cx + ay * ed.cy
    abs(elem_s - cent_s) > half_δ && continue

    M_sag = am.Mx_bot * ax^2 + am.My_bot * ay^2

    if M_sag < 1e-10
        n_zero_mx_bot += 1
    else
        n_nonzero_mx_bot += 1
    end

    if SR._is_in_column_strip(ed.cx, ed.cy, pos_cs_polys)
        Mpos_cs_area += M_sag * ed.area
        sum_mx_bot_cs += am.Mx_bot
    else
        Mpos_ms_area += M_sag * ed.area
        sum_mx_bot_ms += am.My_bot
    end
end

Mpos_cs_area /= δ
Mpos_ms_area /= δ

println("  AREA METHOD (area-pr) at midspan:")
println("    CS M⁺ = $(round(Mpos_cs_area * _Nm_to_kf, digits=2)) kip·ft")
println("    MS M⁺ = $(round(Mpos_ms_area * _Nm_to_kf, digits=2)) kip·ft")
println("    Total = $(round((Mpos_cs_area + Mpos_ms_area) * _Nm_to_kf, digits=2)) kip·ft")
cs_frac_area = (Mpos_cs_area + Mpos_ms_area) > 0 ?
    Mpos_cs_area / (Mpos_cs_area + Mpos_ms_area) * 100 : 0.0
println("    CS fraction: $(round(cs_frac_area, digits=1))%")
println("    Elements with Mx_bot ≈ 0: $n_zero_mx_bot / $(n_zero_mx_bot + n_nonzero_mx_bot)")
println()

# Detailed element-level comparison: pick 5 CS and 5 MS elements
println("  ELEMENT-LEVEL COMPARISON (first 5 CS, first 5 MS in δ-band):")
println("    ─────────────────────────────────────────────────────────────────────")
@printf("    %-6s %-6s %-10s %-10s %-10s %-10s %-10s %-10s %-10s\n",
        "Elem", "Strip", "Mn_strip", "Mx_bot", "My_bot", "Mx_top", "My_top", "M_sag", "Area")
@printf("    %-6s %-6s %-10s %-10s %-10s %-10s %-10s %-10s %-10s\n",
        "─"^6, "─"^6, "─"^10, "─"^10, "─"^10, "─"^10, "─"^10, "─"^10, "─"^10)

n_printed_cs = 0
n_printed_ms = 0
for k in tri_idx
    k > length(area_moms_pr) && continue
    ed = cache.element_data[k]
    elem_s = ax * ed.cx + ay * ed.cy
    abs(elem_s - cent_s) > half_δ && continue

    am = area_moms_pr[k]
    is_cs = SR._is_in_column_strip(ed.cx, ed.cy, pos_cs_polys)

    if is_cs && n_printed_cs >= 5
        continue
    elseif !is_cs && n_printed_ms >= 5
        continue
    elseif n_printed_cs >= 5 && n_printed_ms >= 5
        break
    end

    # Strip method's Mn at this element
    axl = (ax*ed.ex[1] + ay*ed.ex[2], ax*ed.ey[1] + ay*ed.ey[2])
    Mn_strip = ed.Mxx*axl[1]^2 + ed.Myy*axl[2]^2 + 2*ed.Mxy*axl[1]*axl[2]

    M_sag = am.Mx_bot * ax^2 + am.My_bot * ay^2
    strip_label = is_cs ? "CS" : "MS"

    @printf("    %-6d %-6s %10.1f %10.1f %10.1f %10.1f %10.1f %10.1f %10.6f\n",
            k, strip_label, Mn_strip, am.Mx_bot, am.My_bot, am.Mx_top, am.My_top, M_sag, ed.area)

    if is_cs
        n_printed_cs += 1
    else
        n_printed_ms += 1
    end
end
println()

# Check: what does the strip method's raw integration give for the SAME elements?
# (to verify the per-element moments are consistent)
Mn_cs_raw = 0.0
Mn_ms_raw = 0.0
for k in tri_idx
    ed = cache.element_data[k]
    elem_s = ax * ed.cx + ay * ed.cy
    abs(elem_s - cent_s) > half_δ && continue

    axl = (ax*ed.ex[1] + ay*ed.ex[2], ax*ed.ey[1] + ay*ed.ey[2])
    Mn = ed.Mxx*axl[1]^2 + ed.Myy*axl[2]^2 + 2*ed.Mxy*axl[1]*axl[2]

    if SR._is_in_column_strip(ed.cx, ed.cy, pos_cs_polys)
        Mn_cs_raw += Mn * ed.area
    else
        Mn_ms_raw += Mn * ed.area
    end
end
Mn_cs_raw /= δ
Mn_ms_raw /= δ

println("  RAW STRIP INTEGRATION (manual, same elements):")
println("    CS raw Mn·A/δ = $(round(Mn_cs_raw, digits=1)) N·m  ($(round(Mn_cs_raw * _Nm_to_kf, digits=2)) kip·ft)")
println("    MS raw Mn·A/δ = $(round(Mn_ms_raw, digits=1)) N·m  ($(round(Mn_ms_raw * _Nm_to_kf, digits=2)) kip·ft)")
println("    CS max(0,-) = $(round(max(0.0, -Mn_cs_raw) * _Nm_to_kf, digits=2)) kip·ft")
println("    MS max(0,-) = $(round(max(0.0, -Mn_ms_raw) * _Nm_to_kf, digits=2)) kip·ft")
println()

# =============================================================================
# BUG 2: Isoparametric Σ/M₀ = 140%
# =============================================================================
println("═"^90)
println("  BUG 2: ISOPARAMETRIC OVER-COUNTING")
println("═"^90)
println()

# Build nodal field
field = SR.build_nodal_moment_field(cache)

# Compare line-integral M⁺ at midspan vs δ-band M⁺
# First, the δ-band result (full frame width, not split)
M_full_delta = -SR._integrate_at(cache.element_data, tri_idx, geom.centroid, span_axis, δ)
println("  δ-band M⁺ at midspan (full width): $(round(max(0.0, M_full_delta) * _Nm_to_kf, digits=2)) kip·ft")

# Now the isoparametric line integral
cp = SR.build_cell_panel(geom.poly, cell_cols, span_axis, skel)
if cp !== nothing
    println("  IsoParametric panel built: ✓")

    # Generate cuts
    cuts = SR.generate_cut_lines(cp, cell_cols, span_axis, skel; n_cuts=40, n_pts=30, iso_alpha=1.0)
    n_col_cuts = count(c -> c.region == :column_face, cuts)
    n_mid_cuts = count(c -> c.region == :midspan, cuts)
    println("  Cuts: $n_col_cuts column-face, $n_mid_cuts midspan")

    # Find the midspan cut closest to centroid
    best_mid_cut = nothing
    best_mid_dist = Inf
    cent_ξ = 0.5  # centroid should be near ξ=0.5
    for cut in cuts
        cut.region == :midspan || continue
        d = abs(cut.ξ - cent_ξ)
        if d < best_mid_dist
            best_mid_dist = d
            best_mid_cut = cut
        end
    end

    if best_mid_cut !== nothing
        # Full line integral
        M_iso_full = SR.integrate_cut_Mn(cache, field, best_mid_cut, tri_idx, span_axis)
        println("  Iso line integral M at ξ=$(round(best_mid_cut.ξ, digits=3)): $(round(M_iso_full, digits=1)) N·m")
        println("    = $(round(max(0.0, -M_iso_full) * _Nm_to_kf, digits=2)) kip·ft (sagging)")

        # Split into CS/MS
        M_iso_cs, M_iso_ms = SR.integrate_cut_Mn_split(
            cache, field, best_mid_cut, tri_idx, span_axis, pos_cs_polys)
        println("  Iso split: CS=$(round(M_iso_cs, digits=1)), MS=$(round(M_iso_ms, digits=1)) N·m")
        println("    CS M⁺ = $(round(max(0.0, -M_iso_cs) * _Nm_to_kf, digits=2)) kip·ft")
        println("    MS M⁺ = $(round(max(0.0, -M_iso_ms) * _Nm_to_kf, digits=2)) kip·ft")
    end

    # Envelope over ALL midspan cuts (this is what the method actually does)
    env_cs = 0.0
    env_ms = 0.0
    for cut in cuts
        cut.region == :midspan || continue
        M_cs, M_ms = SR.integrate_cut_Mn_split(
            cache, field, cut, tri_idx, span_axis, pos_cs_polys)
        env_cs = max(env_cs, max(0.0, -M_cs))
        env_ms = max(env_ms, max(0.0, -M_ms))
    end
    println("  Iso envelope over midspan cuts (this cell):")
    println("    CS M⁺ = $(round(env_cs * _Nm_to_kf, digits=2)) kip·ft")
    println("    MS M⁺ = $(round(env_ms * _Nm_to_kf, digits=2)) kip·ft")
    println("    Total = $(round((env_cs + env_ms) * _Nm_to_kf, digits=2)) kip·ft")
    println()

    # Check: do nodes at cell boundaries have inflated values?
    # Find nodes that are on the cell boundary
    cell_poly = geom.poly
    n_boundary_nodes = 0
    n_interior_nodes = 0
    sum_Mn_boundary = 0.0
    sum_Mn_interior = 0.0

    for k in tri_idx
        nids = field.tri_node_ids[k]
        for nid in nids
            (nid < 1 || nid > field.max_node_id) && continue
            px, py = field.node_x[nid], field.node_y[nid]
            Mn_node = field.node_Mxx[nid] * ax^2 + field.node_Myy[nid] * ay^2 +
                      2 * field.node_Mxy[nid] * ax * ay

            # Check if node is near cell boundary (within 1 mesh edge)
            on_boundary = false
            for i in 1:length(cell_poly)
                j = mod1(i+1, length(cell_poly))
                v1 = cell_poly[i]
                v2 = cell_poly[j]
                # Distance from point to line segment
                dx = v2[1] - v1[1]
                dy = v2[2] - v1[2]
                len2 = dx^2 + dy^2
                if len2 > 1e-12
                    t = clamp(((px - v1[1])*dx + (py - v1[2])*dy) / len2, 0.0, 1.0)
                    dist = hypot(px - (v1[1] + t*dx), py - (v1[2] + t*dy))
                    if dist < cache.mesh_edge_length * 1.5
                        on_boundary = true
                        break
                    end
                end
            end

            if on_boundary
                n_boundary_nodes += 1
                sum_Mn_boundary += Mn_node
            else
                n_interior_nodes += 1
                sum_Mn_interior += Mn_node
            end
        end
    end

    avg_boundary = n_boundary_nodes > 0 ? sum_Mn_boundary / n_boundary_nodes : 0.0
    avg_interior = n_interior_nodes > 0 ? sum_Mn_interior / n_interior_nodes : 0.0

    println("  NODAL FIELD BOUNDARY CHECK:")
    println("    Boundary nodes: $n_boundary_nodes, avg Mn = $(round(avg_boundary, digits=1)) N·m/m")
    println("    Interior nodes: $n_interior_nodes, avg Mn = $(round(avg_interior, digits=1)) N·m/m")
    if abs(avg_interior) > 1e-3
        println("    Boundary/Interior ratio: $(round(avg_boundary / avg_interior, digits=3))")
    end
    println()

    # Check: compare the iso line integral with a manual δ-band integral
    # at the SAME ξ position (to isolate smoothing vs integration method)
    if best_mid_cut !== nothing
        # Physical position of the cut midpoint
        mid_pt = best_mid_cut.points[div(length(best_mid_cut.points), 2)]
        M_delta_at_iso = -SR._integrate_at(cache.element_data, tri_idx, mid_pt, span_axis, δ)
        println("  δ-band at iso cut position ($(round(mid_pt[1]*3.281,digits=2)), $(round(mid_pt[2]*3.281,digits=2))) ft:")
        println("    M⁺ = $(round(max(0.0, M_delta_at_iso) * _Nm_to_kf, digits=2)) kip·ft")
        println("    Iso M⁺ at same position = $(round(max(0.0, -M_iso_full) * _Nm_to_kf, digits=2)) kip·ft")
        if abs(M_delta_at_iso) > 1e-3
            ratio = max(0.0, -M_iso_full) / max(0.0, M_delta_at_iso)
            println("    Ratio (iso/δ): $(round(ratio, digits=3))")
        end
    end
else
    println("  ⚠ Could not build IsoParametric panel for cell $diag_ci")
end
println()

# =============================================================================
# BUG 2b: Check cross-cell contamination
# =============================================================================
println("  ─── Cross-cell contamination check ───")
println()

# Run the full isoparametric extraction for ALL cells and compare with δ-band
iso_method = SR.FEA(design_approach=:strip, moment_transform=:projection,
                     field_smoothing=:nodal, cut_method=:isoparametric, iso_alpha=1.0,
                     pattern_loading=false)
delta_method = SR.FEA(design_approach=:strip, moment_transform=:projection,
                       field_smoothing=:element, cut_method=:delta_band,
                       pattern_loading=false)

iso_strips = SR._dispatch_fea_strip_extraction(
    iso_method, cache, struc, slab, columns, span_axis; verbose=false)
delta_strips = SR._dispatch_fea_strip_extraction(
    delta_method, cache, struc, slab, columns, span_axis; verbose=false)

println("  Full slab comparison (iso vs δ-band, projection):")
for (lbl, key) in [("CS Ext neg", :M_neg_ext_cs), ("CS Positive", :M_pos_cs),
                    ("CS Int neg", :M_neg_int_cs), ("MS Ext neg", :M_neg_ext_ms),
                    ("MS Positive", :M_pos_ms), ("MS Int neg", :M_neg_int_ms)]
    v_iso = getfield(iso_strips, key) * _Nm_to_kf
    v_delta = getfield(delta_strips, key) * _Nm_to_kf
    ratio = abs(v_delta) > 0.01 ? v_iso / v_delta : 0.0
    @printf("    %-14s  δ=%8.1f  iso=%8.1f  ratio=%.3f\n", lbl, v_delta, v_iso, ratio)
end

iso_sum = (iso_strips.M_neg_ext_cs + iso_strips.M_neg_ext_ms +
           iso_strips.M_neg_int_cs + iso_strips.M_neg_int_ms) / 2 +
          iso_strips.M_pos_cs + iso_strips.M_pos_ms
delta_sum = (delta_strips.M_neg_ext_cs + delta_strips.M_neg_ext_ms +
             delta_strips.M_neg_int_cs + delta_strips.M_neg_int_ms) / 2 +
            delta_strips.M_pos_cs + delta_strips.M_pos_ms

println("    Σ:  δ=$(round(delta_sum * _Nm_to_kf, digits=1))  iso=$(round(iso_sum * _Nm_to_kf, digits=1))  ratio=$(round(iso_sum/delta_sum, digits=3))")
println()

# =============================================================================
# BUG 3: Projection Σ/M₀ = 118%
# =============================================================================
println("═"^90)
println("  BUG 3: PROJECTION EQUILIBRIUM (Σ/M₀ = 118%)")
println("═"^90)
println()

# The question: why does the δ-band projection give Σ/M₀ > 100%?
# Hypothesis: the δ-band integration captures secondary-direction contributions

# Test: compare span-direction vs secondary-direction moments
sec_setup = SR._secondary_moment_analysis_setup(struc, slab, columns, h, γ)
sec_span_axis = sec_setup.span_axis
sec_ax, sec_ay = sec_span_axis

println("  Primary span axis: $(span_axis)")
println("  Secondary span axis: $(sec_span_axis)")
println()

# Integrate at midspan in BOTH directions for the diagnostic cell
M_primary = -SR._integrate_at(cache.element_data, tri_idx, geom.centroid, span_axis, δ)
M_secondary = -SR._integrate_at(cache.element_data, tri_idx, geom.centroid, sec_span_axis, δ)

println("  Midspan moments (full frame width):")
println("    Primary (span axis):    M⁺ = $(round(max(0.0, M_primary) * _Nm_to_kf, digits=2)) kip·ft")
println("    Secondary (transverse): M⁺ = $(round(max(0.0, M_secondary) * _Nm_to_kf, digits=2)) kip·ft")
println()

# Check Mxx, Myy, Mxy contributions at midspan
sum_Mxx_A = 0.0
sum_Myy_A = 0.0
sum_Mxy_A = 0.0
sum_Mn_A = 0.0
sum_A = 0.0

for k in tri_idx
    ed = cache.element_data[k]
    elem_s = ax * ed.cx + ay * ed.cy
    abs(elem_s - cent_s) > half_δ && continue

    # Rotate to global
    ex1, ex2 = ed.ex
    ey1, ey2 = ed.ey
    Mxx_g = ed.Mxx * ex1^2 + ed.Myy * ey1^2 + 2 * ed.Mxy * ex1 * ey1
    Myy_g = ed.Mxx * ex2^2 + ed.Myy * ey2^2 + 2 * ed.Mxy * ex2 * ey2
    Mxy_g = ed.Mxx * ex1 * ex2 + ed.Myy * ey1 * ey2 + ed.Mxy * (ex1 * ey2 + ex2 * ey1)

    # Span-direction projection: Mn = Mxx_g * ax^2 + Myy_g * ay^2 + 2*Mxy_g * ax * ay
    axl = (ax*ed.ex[1] + ay*ed.ex[2], ax*ed.ey[1] + ay*ed.ey[2])
    Mn = ed.Mxx*axl[1]^2 + ed.Myy*axl[2]^2 + 2*ed.Mxy*axl[1]*axl[2]

    sum_Mxx_A += Mxx_g * ed.area
    sum_Myy_A += Myy_g * ed.area
    sum_Mxy_A += Mxy_g * ed.area
    sum_Mn_A += Mn * ed.area
    sum_A += ed.area
end

println("  Moment tensor components at midspan (area-weighted avg, N·m/m):")
println("    Mxx_g = $(round(sum_Mxx_A / sum_A, digits=1))  (span-direction bending)")
println("    Myy_g = $(round(sum_Myy_A / sum_A, digits=1))  (transverse bending)")
println("    Mxy_g = $(round(sum_Mxy_A / sum_A, digits=1))  (twisting)")
println("    Mn (projected) = $(round(sum_Mn_A / sum_A, digits=1))")
println()

# Integrated moments for ALL column faces (not just one cell)
println("  Frame-level integration (all cells, full width):")
envelope = SR._extract_cell_moments(cache, struc, slab, columns, span_axis; verbose=false)
col_moms = [m * _Nm_to_kf for m in envelope.col_Mneg]
M_pos_frame = ustrip(u"kip*ft", envelope.M_pos)

# Find ext/int envelope
M_neg_ext_frame = 0.0
M_neg_int_frame = 0.0
for (i, col) in enumerate(columns)
    if col.position == :interior
        col_moms[i] > M_neg_int_frame && (M_neg_int_frame = col_moms[i])
    else
        col_moms[i] > M_neg_ext_frame && (M_neg_ext_frame = col_moms[i])
    end
end

sum_frame = (M_neg_ext_frame + M_neg_int_frame) / 2 + M_pos_frame
ratio_frame = M0_kf > 0 ? sum_frame / M0_kf * 100 : 0.0

println("    M⁻_ext = $(round(M_neg_ext_frame, digits=2)) kip·ft")
println("    M⁻_int = $(round(M_neg_int_frame, digits=2)) kip·ft")
println("    M⁺     = $(round(M_pos_frame, digits=2)) kip·ft")
println("    Σ = $(round(sum_frame, digits=2)) kip·ft")
println("    M₀ = $(round(M0_kf, digits=2)) kip·ft")
println("    Σ/M₀ = $(round(ratio_frame, digits=1))%")
println()

# What does the secondary direction give?
sec_envelope = SR._extract_cell_moments(cache, struc, slab, columns, sec_span_axis; verbose=false)
sec_col_moms = [m * _Nm_to_kf for m in sec_envelope.col_Mneg]
sec_M_pos = ustrip(u"kip*ft", sec_envelope.M_pos)
sec_M0 = ustrip(u"kip*ft", sec_setup.M0)

sec_neg_ext = 0.0; sec_neg_int = 0.0
for (i, col) in enumerate(columns)
    if col.position == :interior
        sec_col_moms[i] > sec_neg_int && (sec_neg_int = sec_col_moms[i])
    else
        sec_col_moms[i] > sec_neg_ext && (sec_neg_ext = sec_col_moms[i])
    end
end
sec_sum = (sec_neg_ext + sec_neg_int) / 2 + sec_M_pos
sec_ratio = sec_M0 > 0 ? sec_sum / sec_M0 * 100 : 0.0

println("  Secondary direction:")
println("    M⁻_ext = $(round(sec_neg_ext, digits=2)) kip·ft")
println("    M⁻_int = $(round(sec_neg_int, digits=2)) kip·ft")
println("    M⁺     = $(round(sec_M_pos, digits=2)) kip·ft")
println("    Σ = $(round(sec_sum, digits=2)) kip·ft")
println("    M₀_sec = $(round(sec_M0, digits=2)) kip·ft")
println("    Σ/M₀_sec = $(round(sec_ratio, digits=1))%")
println()

# Check: does Σ_primary + Σ_secondary ≈ M₀_primary + M₀_secondary?
total_M_extracted = sum_frame + sec_sum
total_M0 = M0_kf + sec_M0
println("  Two-way equilibrium check:")
println("    Σ_primary + Σ_secondary = $(round(total_M_extracted, digits=2)) kip·ft")
println("    M₀_primary + M₀_secondary = $(round(total_M0, digits=2)) kip·ft")
println("    Ratio = $(round(total_M_extracted / total_M0 * 100, digits=1))%")
println()

# Check: Wood-Armer in both directions
wa_method = SR.FEA(design_approach=:strip, moment_transform=:wood_armer,
                    field_smoothing=:element, cut_method=:delta_band,
                    pattern_loading=false)
wa_strips = SR._dispatch_fea_strip_extraction(
    wa_method, cache, struc, slab, columns, span_axis; verbose=false)
wa_sum = (wa_strips.M_neg_ext_cs + wa_strips.M_neg_ext_ms +
          wa_strips.M_neg_int_cs + wa_strips.M_neg_int_ms) / 2 +
         wa_strips.M_pos_cs + wa_strips.M_pos_ms

println("  Wood-Armer δ-band Σ = $(round(wa_sum * _Nm_to_kf, digits=1)) kip·ft")
println("  Projection δ-band Σ = $(round(delta_sum * _Nm_to_kf, digits=1)) kip·ft")
println("  WA overhead: $(round((wa_sum - delta_sum) / delta_sum * 100, digits=1))%")
println()

# =============================================================================
# SUMMARY
# =============================================================================
println("═"^90)
println("  SUMMARY")
println("═"^90)
println()

println("  Bug 1 (Area CS/MS split):")
println("    CS area fraction at midspan: $(round(cs_area_frac, digits=1))%")
println("    Strip method CS M⁺ fraction: $(round(cs_frac_strip, digits=1))%")
println("    Area method CS M⁺ fraction:  $(round(cs_frac_area, digits=1))%")
if cs_frac_area < cs_frac_strip * 0.5
    println("    → CONFIRMED: Area method severely under-reports CS moments")
    println("    → Likely cause: per-element max(0,...) before integration")
end
println()

println("  Bug 2 (Iso over-counting):")
if cp !== nothing
    println("    δ-band Σ = $(round(delta_sum * _Nm_to_kf, digits=1)) kip·ft")
    println("    Iso Σ    = $(round(iso_sum * _Nm_to_kf, digits=1)) kip·ft")
    println("    Ratio    = $(round(iso_sum / delta_sum, digits=3))")
    if iso_sum > delta_sum * 1.1
        println("    → CONFIRMED: Isoparametric over-counts by $(round((iso_sum/delta_sum - 1)*100, digits=1))%")
    end
end
println()

println("  Bug 3 (Projection equilibrium):")
println("    Primary Σ/M₀ = $(round(ratio_frame, digits=1))%")
println("    Secondary Σ/M₀_sec = $(round(sec_ratio, digits=1))%")
println("    Combined (Σ₁+Σ₂)/(M₀₁+M₀₂) = $(round(total_M_extracted / total_M0 * 100, digits=1))%")
if ratio_frame > 110
    println("    → Primary direction captures more than M₀ — two-way coupling effect")
end
println()
println("═"^90)
println("  DIAGNOSTIC COMPLETE")
println("═"^90)

end  # function main

main()
