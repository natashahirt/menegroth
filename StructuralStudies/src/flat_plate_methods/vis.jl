# ==============================================================================
# Flat Plate / Flat Slab Method Comparison — Visualizations
# ==============================================================================
#
# Grid layout: rows = floor type (Flat Plate / Flat Slab), columns = PSF values.
# All panels share y-axes for direct comparison.
#
# **Line plots (01-07) use SQUARE BAYS ONLY** (Lx = Ly) for meaningful method
# comparison. Rectangular bays are dominated by the short span and mask the
# real differences between analysis methods.
#
# Usage:
#   include("src/flat_plate_methods/vis.jl")
#   df = load_results("path/to/dual_sweep.csv")
#   generate_all(df)
#
# Available:
#   01  Slab thickness vs span (grid: floor type × PSF, square bays)
#   02  Static moment M₀ vs span (grid, square bays)
#   03  Punching shear ratio vs span (grid, square bays)
#   04  Deflection ratio vs span (grid, square bays)
#   05  Column sizes vs span (bar chart grid, square bays)
#   06  Total rebar vs span (grid, square bays)
#   07  Runtime vs span (log scale, grid, square bays)
#   08  Drop panel dimensions (flat slab only, single PSF)
#   09  Depth heatmap — Flat Plate  (Lx × Ly, all aspect ratios)
#   10  Depth heatmap — Flat Slab   (Lx × Ly, all aspect ratios)
#
# ==============================================================================

include(joinpath(@__DIR__, "..", "init.jl"))

using StructuralPlots   # provides CairoMakie / GLMakie, Figure, Axis, etc.
using CairoMakie
CairoMakie.activate!(type = "png")

using GeometryBasics
using Statistics
using Printf

@isdefined(FP_FIGS_DIR)    || (const FP_FIGS_DIR    = joinpath(@__DIR__, "figs"))
@isdefined(FP_RESULTS_DIR) || (const FP_RESULTS_DIR = joinpath(@__DIR__, "results"))

# ==============================================================================
# I/O
# ==============================================================================

function load_results(path::String)
    df = CSV.read(path, DataFrame)
    println("Loaded $(nrow(df)) rows from $(basename(path))")
    return df
end

function _save_fig(fig, name)
    ensure_dir(FP_FIGS_DIR)
    path = joinpath(FP_FIGS_DIR, name)
    save(path, fig; px_per_unit = 2)
    println("  Saved: $path")
    return fig
end

# ==============================================================================
# Constants
# ==============================================================================

const METHOD_ORDER = ["ACI Min", "MDDM", "DDM (Full)", "EFM (HC)", "EFM (ASAP)", "EFM (Kc)", "FEA"]
const METHOD_COLORS = Dict(
    "ACI Min"     => :black,
    "MDDM"       => :steelblue,
    "DDM (Full)"  => :royalblue,
    "EFM (HC)"    => :darkorange,
    "EFM (ASAP)"  => :orangered,
    "EFM (Kc)"    => :gold,        # Raw column stiffness (no torsional reduction)
    "FEA"         => :forestgreen,
)
_color(m) = get(METHOD_COLORS, m, :gray)

const METHOD_LINESTYLES = Dict(
    "ACI Min"    => :dash,
    "MDDM"      => :solid,
    "DDM (Full)" => :solid,
    "EFM (HC)"   => :dashdot,
    "EFM (ASAP)" => :dashdot,
    "EFM (Kc)"   => :dot,
    "FEA"        => :dot,
)
_linestyle(m) = get(METHOD_LINESTYLES, m, :solid)

const METHOD_MARKERS = Dict(
    "ACI Min"    => :xcross,
    "MDDM"      => :circle,
    "DDM (Full)" => :rect,
    "EFM (HC)"   => :diamond,
    "EFM (ASAP)" => :utriangle,
    "EFM (Kc)"   => :dtriangle,   # Down triangle to distinguish from EFM (ASAP)
    "FEA"        => :star5,
)
_marker(m) = get(METHOD_MARKERS, m, :circle)

_at_ll(df, ll) = filter(r -> r.live_psf ≈ ll, df)

"""Pick a single min_h_rule variant for line/bar plots (avoids duplicate rows)."""
function _pick_variant(df)
    hasproperty(df, :min_h_rule) || return df
    variants = sort(unique(df.min_h_rule))
    preferred = "ACI" in variants ? "ACI" : first(variants)
    return filter(r -> r.min_h_rule == preferred, df)
end

"""Add `span_ft` column (= `lx_ft`) if missing."""
function _ensure_span(df)
    isempty(df) && return DataFrame(span_ft=Float64[], lx_ft=Float64[])
    hasproperty(df, :span_ft) && return df
    hasproperty(df, :lx_ft) || error("DataFrame has neither `span_ft` nor `lx_ft`")
    out = copy(df)
    out.span_ft = out.lx_ft
    return out
end

"""Filter to square bays only (lx_ft ≈ ly_ft) for line plots."""
function _square_bays(df)
    hasproperty(df, :ly_ft) || return df
    return filter(r -> r.lx_ft ≈ r.ly_ft, df)
end

"""Filter to rectangular bays only (lx_ft ≠ ly_ft) for line plots. Uses short span as x-axis."""
function _rect_bays(df)
    hasproperty(df, :ly_ft) || return df
    out = filter(r -> !isapprox(r.lx_ft, r.ly_ft; rtol=0.01), df)
    # Use the short span as span_ft for consistent x-axis
    out = copy(out)
    out.span_ft = min.(out.lx_ft, out.ly_ft)
    return out
end

"""Split df by floor_type; returns (flat_plate_df, flat_slab_df)."""
function _split_ft(df)
    fp = hasproperty(df, :floor_type) ? filter(r -> r.floor_type == "flat_plate", df) : df
    fs = hasproperty(df, :floor_type) ? filter(r -> r.floor_type == "flat_slab",  df) : DataFrame()
    return fp, fs
end

# ==============================================================================
# Generic grid helper (line plots): rows = floor types, columns = PSF values
# ==============================================================================

"""
    _grid_plot(df, col, ylabel, suptitle, filename; limit_line, yscale, bay_filter)

Grid layout: Flat Plate (row 1) | Flat Slab (row 2), PSF values as columns.
Shared y-axis range for direct comparison across all panels.

# Arguments
- `bay_filter`: Function to filter bays (default: `_square_bays`). Use `_rect_bays` for rectangular.
"""
function _grid_plot(df, col::Symbol, ylabel::String,
                    suptitle::String, filename::String;
                    limit_line::Union{Nothing,Float64} = nothing,
                    yscale = identity,
                    bay_filter::Function = _square_bays)
    work = bay_filter(_pick_variant(_ensure_span(df)))
    fp_all, fs_all = _split_ft(work)

    live_loads = sort(unique(work.live_psf))
    n_loads = length(live_loads)
    n_loads == 0 && return nothing

    fig = Figure(size = (350 * n_loads + 80, 700))
    Label(fig[0, 1:n_loads], suptitle;
          fontsize = 16, font = :bold, tellwidth = false)

    # Shared y range across all panels
    all_vals = filter(!isnan, work[!, col])
    if yscale === identity
        y_lo = 0.0
        y_hi = isempty(all_vals) ? 1.0 : maximum(all_vals)
        !isnothing(limit_line) && (y_hi = max(y_hi, limit_line))
        y_hi += y_hi * 0.08
    else
        y_lo = isempty(all_vals) ? 0.1 : minimum(all_vals)
        y_hi = isempty(all_vals) ? 1.0 : maximum(all_vals)
        y_lo = max(y_lo * 0.8, 1e-6)
        y_hi *= 1.2
    end

    # Shared x range
    all_spans = work.span_ft
    x_lo = isempty(all_spans) ? 0.0 : minimum(all_spans)
    x_hi = isempty(all_spans) ? 1.0 : maximum(all_spans)
    x_pad = (x_hi - x_lo) * 0.04
    x_lo -= x_pad;  x_hi += x_pad

    floor_types = [("Flat Plate", fp_all), ("Flat Slab", fs_all)]
    
    # Store axes to link them later
    axs = Matrix{Axis}(undef, 2, n_loads)

    for (i, (ft_label, ft_df)) in enumerate(floor_types)
        for (j, ll) in enumerate(live_loads)
            sub = filter(r -> r.live_psf ≈ ll, ft_df)

            ax = Axis(fig[i, j];
                      xlabel = i == 2 ? "Span (ft)" : "",
                      ylabel = j == 1 ? ylabel : "",
                      title  = i == 1 ? "LL = $(Int(ll)) psf" : "",
                      yscale = yscale,
                      width  = 300,
                      height = 250,
                      alignmode = Outside(15))
            axs[i, j] = ax

            i < 2 && hidexdecorations!(ax; ticks = false, grid = false)
            j > 1 && hideydecorations!(ax; ticks = false, grid = false)

            !isnothing(limit_line) && hlines!(ax, [limit_line];
                color = :red, linestyle = :dash, linewidth = 1, label = "Limit")

            for (k, m) in enumerate(METHOD_ORDER)
                md = filter(r -> r.method == m, sub)
                isempty(md) && continue
                sp = sort(unique(md.span_ft))
                yv = Float64[filter(r -> r.span_ft == s, md)[1, col] for s in sp]
                lw = 2.5 - 0.2 * (k - 1)
                lines!(ax, sp, yv; label = m, color = (_color(m), 0.85),
                       linestyle = _linestyle(m), linewidth = lw)
                scatter!(ax, sp, yv; color = _color(m), marker = _marker(m),
                         markersize = 9)
            end

            ylims!(ax, y_lo, y_hi)
            xlims!(ax, x_lo, x_hi)
        end

        # Row label on the left
        Label(fig[i, 0], ft_label;
              fontsize = 12, font = :bold, rotation = π/2, tellheight = false)
    end

    # Link all axes for consistent zooming/panning (and alignment)
    CairoMakie.linkaxes!(axs...)

    # Single legend at bottom
    legend_entries = [(m, _color(m), _marker(m), _linestyle(m)) for m in METHOD_ORDER]
    leg_elements = [LineElement(color = c, linestyle = ls, linewidth = 2) for (_, c, _, ls) in legend_entries]
    leg_labels = [m for (m, _, _, _) in legend_entries]
    Legend(fig[3, 1:n_loads], leg_elements, leg_labels;
           orientation = :horizontal, labelsize = 10, tellwidth = false)

    rowgap!(fig.layout, 8)
    colgap!(fig.layout, 8)
    resize_to_layout!(fig)

    return _save_fig(fig, filename)
end

# ==============================================================================
# Grid plots (01 – 04, 06 – 07): rows = floor type, columns = PSF
# ==============================================================================

# ── Square bay versions (default) ──

"""Slab thickness grid (square bays)."""
plot_thickness(df) =
    _grid_plot(df, :h_in, "h (in)", "Slab Thickness (Square Bays)", "01_thickness.png")

"""Static moment M₀ grid (square bays)."""
plot_moments(df) =
    _grid_plot(df, :M0_kipft, "M₀ (kip-ft)", "Static Moment M₀ (Square Bays)", "02_M0.png")

"""Punching shear ratio grid (square bays)."""
plot_punching(df) =
    _grid_plot(df, :punch_ratio, "Punch ratio (vu / φvc)", "Punching Shear (Square Bays)",
               "03_punching.png"; limit_line = 1.0)

"""Deflection ratio grid (square bays)."""
plot_deflection(df) =
    _grid_plot(df, :defl_ratio, "Defl ratio (Δ / Δ_limit)", "Deflection (Square Bays)",
               "04_deflection.png"; limit_line = 1.0)

"""Total rebar area grid (square bays)."""
plot_rebar(df) =
    _grid_plot(df, :As_total_in2, "Total As (in²)", "Total Rebar Area (Square Bays)",
               "06_rebar.png")

"""Runtime grid (square bays, log scale)."""
plot_runtime(df) =
    _grid_plot(df, :runtime_s, "Runtime (s)", "Runtime (Square Bays)",
               "07_runtime.png"; yscale = log10)

# ── Rectangular bay versions ──

"""Slab thickness grid (rectangular bays, x-axis = short span)."""
plot_thickness_rect(df) =
    _grid_plot(df, :h_in, "h (in)", "Slab Thickness (Rectangular Bays)",
               "01_thickness_rect.png"; bay_filter = _rect_bays)

"""Static moment M₀ grid (rectangular bays)."""
plot_moments_rect(df) =
    _grid_plot(df, :M0_kipft, "M₀ (kip-ft)", "Static Moment M₀ (Rectangular Bays)",
               "02_M0_rect.png"; bay_filter = _rect_bays)

"""Punching shear ratio grid (rectangular bays)."""
plot_punching_rect(df) =
    _grid_plot(df, :punch_ratio, "Punch ratio (vu / φvc)", "Punching Shear (Rectangular Bays)",
               "03_punching_rect.png"; limit_line = 1.0, bay_filter = _rect_bays)

"""Deflection ratio grid (rectangular bays)."""
plot_deflection_rect(df) =
    _grid_plot(df, :defl_ratio, "Defl ratio (Δ / Δ_limit)", "Deflection (Rectangular Bays)",
               "04_deflection_rect.png"; limit_line = 1.0, bay_filter = _rect_bays)

"""Total rebar area grid (rectangular bays)."""
plot_rebar_rect(df) =
    _grid_plot(df, :As_total_in2, "Total As (in²)", "Total Rebar Area (Rectangular Bays)",
               "06_rebar_rect.png"; bay_filter = _rect_bays)

"""Runtime grid (rectangular bays, log scale)."""
plot_runtime_rect(df) =
    _grid_plot(df, :runtime_s, "Runtime (s)", "Runtime (Rectangular Bays)",
               "07_runtime_rect.png"; yscale = log10, bay_filter = _rect_bays)

# ==============================================================================
# 05 — Column sizes (grouped bar chart): rows = floor type, columns = PSF
# ==============================================================================

"""Column size bar chart grid: rows = floor type, columns = PSF."""
function _plot_columns_impl(df; bay_filter::Function = _square_bays,
                                title_suffix::String = "", filename::String = "05_columns.png")
    work = bay_filter(_pick_variant(_ensure_span(df)))
    fp_all, fs_all = _split_ft(work)

    live_loads = sort(unique(work.live_psf))
    n_loads = length(live_loads)
    n_loads == 0 && return nothing

    fig = Figure(size = (350 * n_loads + 80, 700))
    Label(fig[0, 1:n_loads], "Final Column Sizes" * title_suffix;
          fontsize = 16, font = :bold, tellwidth = false)

    # Shared spans and y range across all panels
    all_spans = sort(unique(work.span_ft))
    all_col = filter(!isnan, work.col_max_in)
    y_hi = isempty(all_col) ? 40.0 : maximum(all_col) * 1.1

    floor_types = [("Flat Plate", fp_all), ("Flat Slab", fs_all)]
    nm = length(METHOD_ORDER)
    w  = 0.15
    
    # Store axes for linking
    axs = Matrix{Axis}(undef, 2, n_loads)

    for (i, (ft_label, ft_df)) in enumerate(floor_types)
        for (j, ll) in enumerate(live_loads)
            sub = filter(r -> r.live_psf ≈ ll, ft_df)

            ax = Axis(fig[i, j];
                      xlabel = i == 2 ? "Span (ft)" : "",
                      ylabel = j == 1 ? "Column size (in)" : "",
                      title  = i == 1 ? "LL = $(Int(ll)) psf" : "",
                      alignmode = Outside(15))
            axs[i, j] = ax

            i < 2 && hidexdecorations!(ax; ticks = false, grid = false)
            j > 1 && hideydecorations!(ax; ticks = false, grid = false)

            for (k, m) in enumerate(METHOD_ORDER)
                md = filter(r -> r.method == m, sub)
                isempty(md) && continue
                # Deduplicate: one row per span
                deduped = DataFrame()
                for s in sort(unique(md.span_ft))
                    row = first(filter(r -> r.span_ft == s, md))
                    push!(deduped, row; promote = true)
                end
                xs  = [findfirst(==(s), all_spans) for s in deduped.span_ft]
                off = (k - (nm + 1) / 2) * w
                barplot!(ax, xs .+ off, deduped.col_max_in;
                         width = w, color = _color(m), label = m,
                         strokewidth = 0.5, strokecolor = :black)
            end

            ax.xticks = (1:length(all_spans), string.(Int.(all_spans)))
            ylims!(ax, 0, y_hi)
        end

        # Row label
        Label(fig[i, 0], ft_label;
              fontsize = 12, font = :bold, rotation = π/2, tellheight = false)
    end

    # Equalize sizes
    for i in 1:2
        rowsize!(fig.layout, i, Fixed(250))
    end
    for j in 1:n_loads
        colsize!(fig.layout, j, Fixed(300))
    end

    CairoMakie.linkaxes!(axs...)

    # Single legend at bottom
    legend_entries = [(m, _color(m)) for m in METHOD_ORDER]
    leg_elements = [PolyElement(color = c) for (_, c) in legend_entries]
    leg_labels = [m for (m, _) in legend_entries]
    Legend(fig[3, 1:n_loads], leg_elements, leg_labels;
           orientation = :horizontal, labelsize = 10, tellwidth = false)

    rowgap!(fig.layout, 8)
    colgap!(fig.layout, 8)
    resize_to_layout!(fig)

    return _save_fig(fig, filename)
end

"""Column size bar chart (square bays)."""
plot_columns(df) = _plot_columns_impl(df; title_suffix = " (Square Bays)")

"""Column size bar chart (rectangular bays)."""
plot_columns_rect(df) = _plot_columns_impl(df;
    bay_filter = _rect_bays, title_suffix = " (Rectangular Bays)", filename = "05_columns_rect.png")

# ==============================================================================
# 08 — Drop panel dimensions (flat slab only)
# ==============================================================================

"""
    plot_drop_panels(df; ll=50.0)

Show drop panel depth (h_drop) and extent (a_drop) vs span for the flat slab
data.  Left axis = h_drop (in), right axis = a_drop (ft).
Only plots flat_slab rows; requires `h_drop_in`, `a_drop1_ft` columns.
"""
function plot_drop_panels(df; ll = 50.0)
    sub = _pick_variant(_at_ll(_ensure_span(df), ll))
    fs_all = hasproperty(sub, :floor_type) ? filter(r -> r.floor_type == "flat_slab", sub) : sub
    (isempty(fs_all) || !hasproperty(fs_all, :h_drop_in)) && begin
        println("  Skipping drop panel plot — no flat_slab data with drop panel columns")
        return nothing
    end

    fig = Figure(size = (700, 450))
    ax1 = Axis(fig[1, 1];
               xlabel = "Span (ft)", ylabel = "Drop depth h_drop (in)",
               title  = "Flat Slab — Drop Panel Dimensions (LL = $(Int(ll)) psf)",
               yticklabelcolor = :steelblue)

    ax2 = Axis(fig[1, 1];
               ylabel = "Drop extent a_drop (ft)",
               yaxisposition = :right,
               yticklabelcolor = :darkorange)
    hidexdecorations!(ax2)
    hidespines!(ax2)

    # Use first method per span (drop panel geometry is method-independent)
    first_per_span = DataFrame()
    for sp in sort(unique(fs_all.span_ft))
        rows_sp = filter(r -> r.span_ft == sp, fs_all)
        isempty(rows_sp) && continue
        push!(first_per_span, rows_sp[1, :]; promote=true)
    end

    if !isempty(first_per_span)
        sp = first_per_span.span_ft

        # h_drop
        lines!(ax1, sp, first_per_span.h_drop_in;
               color = :steelblue, linewidth = 2, label = "h_drop")
        scatter!(ax1, sp, first_per_span.h_drop_in;
                 color = :steelblue, markersize = 10)

        # a_drop (use direction 1; they're typically equal for square bays)
        lines!(ax2, sp, first_per_span.a_drop1_ft;
               color = :darkorange, linewidth = 2, linestyle = :dash, label = "a_drop")
        scatter!(ax2, sp, first_per_span.a_drop1_ft;
                 color = :darkorange, markersize = 10, marker = :utriangle)

        # Annotate total slab+drop depth
        for row in eachrow(first_per_span)
            h_total = row.h_in + row.h_drop_in
            text!(ax1, row.span_ft, row.h_drop_in;
                  text = @sprintf("h_tot=%.1f\"", h_total),
                  align = (:center, :bottom), fontsize = 9, offset = (0, 5))
        end
    end

    # Legend manually
    Legend(fig[1, 2],
           [LineElement(color=:steelblue, linewidth=2),
            LineElement(color=:darkorange, linewidth=2, linestyle=:dash)],
           ["h_drop (in)", "a_drop (ft)"];
           labelsize = 11)

    return _save_fig(fig, "08_drop_panels.png")
end

# ==============================================================================
# Smooth heatmap with sharp NaN boundaries (manual bilinear interpolation)
# ==============================================================================

"""
    interpolated_heatmap!(ax, xs, ys, Z; colormap, colorrange, k=8)

Draw a smooth heatmap with sharp boundaries at NaN edges.
Uses manual bilinear interpolation within valid cells, producing smooth
gradients inside the data domain while maintaining crisp edges at NaN boundaries.

- `xs`, `ys`: coordinate vectors (cell centers)
- `Z`: matrix of values (NaN = no data)
- `k`: subdivision factor per cell (higher = smoother, 6-12 typical)
"""
function interpolated_heatmap!(ax, xs::AbstractVector, ys::AbstractVector, Z::AbstractMatrix;
                               colormap = :viridis,
                               colorrange = extrema(filter(!isnan, Z)),
                               k::Int = 8)
    nx, ny = length(xs), length(ys)
    size(Z) == (nx, ny) || error("Z must be $(nx)×$(ny), got $(size(Z))")
    
    # Compute cell half-widths (assume uniform spacing)
    dx = nx > 1 ? (xs[2] - xs[1]) / 2 : 1.0
    dy = ny > 1 ? (ys[2] - ys[1]) / 2 : 1.0
    
    # Collect all micro-quads as a mesh
    positions = Point2f[]
    colors = Float32[]
    faces = GLTriangleFace[]
    
    # For each cell (i,j), check if it has a valid value
    for i in 1:nx, j in 1:ny
        isnan(Z[i, j]) && continue
        
        # Gather corner values for bilinear interpolation
        # Corners: (i,j), (i+1,j), (i,j+1), (i+1,j+1) in a 2×2 neighborhood
        # Use cell center value as fallback when neighbors are NaN
        z00 = Z[i, j]
        z10 = (i < nx && !isnan(Z[i+1, j])) ? Z[i+1, j] : z00
        z01 = (j < ny && !isnan(Z[i, j+1])) ? Z[i, j+1] : z00
        z11 = if i < nx && j < ny && !isnan(Z[i+1, j+1])
            Z[i+1, j+1]
        elseif i < nx && !isnan(Z[i+1, j])
            Z[i+1, j]
        elseif j < ny && !isnan(Z[i, j+1])
            Z[i, j+1]
        else
            z00
        end
        
        # Cell bounds (centered on xs[i], ys[j])
        x0, x1 = xs[i] - dx, xs[i] + dx
        y0, y1 = ys[j] - dy, ys[j] + dy
        
        # Generate k×k micro-grid within this cell
        base_idx = length(positions)
        for ki in 0:k, kj in 0:k
            # Parametric coords [0,1]
            u = ki / k
            v = kj / k
            # Bilinear interpolation of position
            px = x0 + u * (x1 - x0)
            py = y0 + v * (y1 - y0)
            # Bilinear interpolation of value
            pz = (1-u)*(1-v)*z00 + u*(1-v)*z10 + (1-u)*v*z01 + u*v*z11
            
            push!(positions, Point2f(px, py))
            push!(colors, Float32(pz))
        end
        
        # Generate triangles for the micro-grid
        stride = k + 1
        for ki in 0:(k-1), kj in 0:(k-1)
            # Vertex indices (1-based)
            v00 = base_idx + ki * stride + kj + 1
            v10 = base_idx + (ki+1) * stride + kj + 1
            v01 = base_idx + ki * stride + (kj+1) + 1
            v11 = base_idx + (ki+1) * stride + (kj+1) + 1
            # Two triangles per micro-quad
            push!(faces, GLTriangleFace(v00, v10, v01))
            push!(faces, GLTriangleFace(v10, v11, v01))
        end
    end
    
    isempty(positions) && return nothing
    
    # Draw the mesh
    mesh!(ax, positions, faces;
          color = colors, colormap = colormap, colorrange = colorrange,
          shading = NoShading)
    
    return nothing
end

# ==============================================================================
# 09/10 — Depth heatmaps (one per floor type, separate images)
# ==============================================================================

"""
    plot_depth_heatmap(df; floor_type, h_range, metric=false)

Hartwell-style heatmap grid: methods (rows) × live loads (columns).
Generates a single image for the given `floor_type`.
Pass `h_range=(lo,hi)` to lock colorbar across companion plots.
Set `metric=true` to plot spans in m and depth in mm.
"""
function plot_depth_heatmap(df; floor_type::String = "flat_plate",
                                h_range = nothing,
                                title_suffix::String = "",
                                file_suffix::String = "",
                                metric::Bool = false)
    work = hasproperty(df, :floor_type) ? filter(r -> r.floor_type == floor_type, df) : df
    isempty(work) && begin
        println("  Skipping heatmap for $floor_type — no data")
        return nothing
    end

    ft_label = floor_type == "flat_slab" ? "Flat Slab" : "Flat Plate"

    # Unit conversion factors
    span_k  = metric ? 0.3048  : 1.0   # ft → m
    depth_k = metric ? 25.4    : 1.0   # in → mm
    span_u  = metric ? "m"     : "ft"
    depth_u = metric ? "mm"    : "in"
    ll_u    = metric ? "kPa"   : "psf"
    psf2kpa = 0.047880258      # 1 psf ≈ 0.04788 kPa

    methods    = METHOD_ORDER
    live_loads = sort(unique(work.live_psf))
    lx_vals    = sort(unique(work.lx_ft)) .* span_k
    ly_vals    = sort(unique(work.ly_ft)) .* span_k

    n_methods = length(methods)
    n_loads   = length(live_loads)

    valid_h = filter(!isnan, work.h_in)
    if isempty(valid_h)
        println("  Skipping heatmap for $floor_type — no valid h_in values")
        return nothing
    end
    h_min_raw = isnothing(h_range) ? 0.0 : h_range[1]
    h_max_raw = isnothing(h_range) ? ceil(maximum(valid_h)) : h_range[2]
    # Safeguard: if h_range was passed with NaN, fall back to computed values
    if isnan(h_min_raw)
        h_min_raw = 0.0
    end
    if isnan(h_max_raw)
        h_max_raw = ceil(maximum(valid_h))
    end
    h_min = h_min_raw * depth_k
    h_max = h_max_raw * depth_k

    lo_x, hi_x = extrema(lx_vals)
    lo_y, hi_y = extrema(ly_vals)

    fig = Figure(size = (300 * n_loads + 100, 200 * n_methods + 80),
                 figure_padding = (5, 5, 5, 5))

    Label(fig[0, 1:n_loads],
          "$ft_label — Optimal Slab Depth by Plan Dimensions$title_suffix";
          fontsize = 16, font = :bold, tellwidth = false)

    # Store axes for linking
    axs = Matrix{Axis}(undef, n_methods, n_loads)

    for (i, m) in enumerate(methods)
        for (j, ll) in enumerate(live_loads)
            sub = filter(r -> r.method == m && r.live_psf ≈ ll, work)

            # Filter out DDM rows where ddm_eligible is false (L/D > 2.0)
            if m in ("MDDM", "DDM (Full)") && hasproperty(work, :ddm_eligible)
                sub = filter(r -> r.ddm_eligible, sub)
            end

            Z = fill(NaN, length(lx_vals), length(ly_vals))
            for row in eachrow(sub)
                xi = findfirst(≈(row.lx_ft * span_k), lx_vals)
                yi = findfirst(≈(row.ly_ft * span_k), ly_vals)
                if !isnothing(xi) && !isnothing(yi)
                    # Only plot h_in for converged designs
                    is_converged = hasproperty(row, :converged) ? coalesce(row.converged, false) : true
                    if is_converged && !isnan(row.h_in)
                        Z[xi, yi] = row.h_in * depth_k
                    end
                end
            end

            ll_label = metric ? @sprintf("%.1f kPa", ll * psf2kpa) :
                                "LL = $(Int(ll)) psf"

            mid_row = div(n_methods + 1, 2)
            
            # Tick interval: 5 ft (or ~1.5 m for metric)
            tick_step = metric ? 1.5 : 5.0
            x_ticks = collect(ceil(lo_x / tick_step) * tick_step : tick_step : hi_x)
            y_ticks = collect(ceil(lo_y / tick_step) * tick_step : tick_step : hi_y)
            
            ax = Axis(fig[i, j];
                      xlabel  = i == n_methods ? "Lx ($span_u)" : "",
                      ylabel  = j == 1 ? "Ly ($span_u)" : "",
                      title   = i == 1 ? ll_label : "",
                      aspect  = DataAspect(),
                      width   = 200,
                      height  = 200,
                      xticklabelsize = 9, yticklabelsize = 9,
                      titlesize = 12,
                      xticks = x_ticks, yticks = y_ticks,
                      alignmode = Outside(15))
            axs[i, j] = ax

            i < n_methods && hidexdecorations!(ax; ticks = false, grid = false)
            j > 1         && hideydecorations!(ax; ticks = false, grid = false)

            if !all(isnan.(Z))
                # Smooth interpolation with sharp NaN boundaries
                interpolated_heatmap!(ax, lx_vals, ly_vals, Z;
                                      colormap = :viridis,
                                      colorrange = (h_min, h_max),
                                      k = 8)
            end

            xlims!(ax, lo_x, hi_x)
            ylims!(ax, lo_y, hi_y)

            # Diagonal reference lines (1:1 and 1:2 aspect)
            diag_hi = min(hi_x, hi_y)
            lines!(ax, [lo_x, diag_hi], [lo_x, diag_hi];
                   color = :white, linestyle = :dash, linewidth = 0.8)

            x2_end = min(hi_x, hi_y / 2)
            x2_end > lo_x && lines!(ax, [lo_x, x2_end], [2lo_x, 2x2_end];
                                     color = :white, linestyle = :dot, linewidth = 0.7)
            y2_end = min(hi_y, hi_x / 2)
            y2_end > lo_y && lines!(ax, [2lo_y, 2y2_end], [lo_y, y2_end];
                                     color = :white, linestyle = :dot, linewidth = 0.7)

            # Annotations along the diagonal (only for converged, non-trivial results)
            # Offset up and right so labels near axes aren't clipped
            label_offset_x = (hi_x - lo_x) * 0.06
            label_offset_y = (hi_y - lo_y) * 0.06
            for row in eachrow(sub)
                row.lx_ft ≈ row.ly_ft || continue
                # Skip if not converged
                is_converged = hasproperty(row, :converged) ? coalesce(row.converged, false) : true
                is_converged || continue
                # Skip NaN or ACI minimum floor (5")
                isnan(row.h_in) && continue
                row.h_in ≤ 5.0 && continue
                
                xp = row.lx_ft * span_k + label_offset_x
                yp = row.ly_ft * span_k + label_offset_y
                dp = row.h_in * depth_k
                label = metric ? @sprintf("%.0f", dp) : @sprintf("%.0f\"", row.h_in)
                text!(ax, xp, yp;
                      text = label,
                      align = (:center, :center), fontsize = 8,
                      color = :white, strokewidth = 0.5, strokecolor = :black)
            end
        end

        Label(fig[i, 0], m;
              fontsize = 11, font = :bold, rotation = π/2, tellheight = false)
    end

    CairoMakie.linkaxes!(axs...)

    Colorbar(fig[1:n_methods, n_loads + 1];
             colormap = :viridis, colorrange = (h_min, h_max),
             label = "Depth ($depth_u)", labelsize = 11, width = 12)

    rowgap!(fig.layout, 8)
    colgap!(fig.layout, 8)
    resize_to_layout!(fig)

    tag = floor_type == "flat_slab" ? "flat_slab" : "flat_plate"
    num = floor_type == "flat_slab" ? "10" : "09"
    return _save_fig(fig, "$(num)_heatmap_$(tag)$(file_suffix).png")
end

"""Generate both heatmap images with matched color range."""
function plot_dual_heatmaps(df; title_suffix::String = "", file_suffix::String = "",
                                metric::Bool = false)
    valid_h = filter(!isnan, df.h_in)
    if isempty(valid_h)
        println("  Skipping heatmaps — no valid h_in values")
        return nothing
    end
    h_lo = 0.0
    h_hi = ceil(maximum(valid_h))
    h_range = (h_lo, h_hi)
    plot_depth_heatmap(df; floor_type = "flat_plate", h_range, title_suffix, file_suffix, metric)
    plot_depth_heatmap(df; floor_type = "flat_slab",  h_range, title_suffix, file_suffix, metric)
end

# ==============================================================================
# 12 — Failure mode heatmaps (categorical)
# ==============================================================================

const FAILURE_CATEGORIES = [
    "converged",
    "punching_shear",
    "deflection",
    "flexural",
    "reinforcement",
    "section_inadequate",
    "column_design",
    "ddm_ineligible",
    "non_convergence",
]

const FAILURE_COLORS = Dict(
    "converged"          => RGBAf(1, 1, 1, 0),  # transparent (white/blank)
    "punching_shear"     => colorant"#e74c3c",  # red
    "deflection"         => colorant"#f39c12",  # orange
    "flexural"           => colorant"#9b59b6",  # purple
    "reinforcement"      => colorant"#3498db",  # blue
    "section_inadequate" => colorant"#e67e22",  # dark orange
    "column_design"      => colorant"#1abc9c",  # teal
    "ddm_ineligible"     => colorant"#34495e",  # dark blue-gray (includes high aspect ratio)
    "non_convergence"    => colorant"#7f8c8d",  # gray
)

# Human-readable legend labels
const FAILURE_LABELS = Dict(
    "punching_shear"     => "Punching Shear",
    "deflection"         => "Deflection",
    "flexural"           => "Flexural",
    "reinforcement"      => "Rebar Spacing",
    "section_inadequate" => "Rebar Capacity",
    "column_design"      => "Max Column",
    "ddm_ineligible"     => "DDM Ineligible",
    "non_convergence"    => "Non Convergence",
)

"""Categorize failure string and failing_check into a single category."""
function _categorize_failure(failures::AbstractString, failing_check::AbstractString = "",
                             ddm_eligible::AbstractString = "true")
    f = lowercase(failures)
    fc = lowercase(failing_check)
    
    # High aspect ratio and DDM ineligibility are grouped together
    occursin("high_aspect_ratio", f) && return "ddm_ineligible"
    ddm_eligible == "false" && return "ddm_ineligible"
    occursin("ddm_ineligible", f) && return "ddm_ineligible"
    
    # Check for converged (no failures)
    isempty(f) && return "converged"
    
    # Check specific failure modes in failures string
    occursin("punching", f) && return "punching_shear"
    occursin("deflection", f) && return "deflection"
    occursin("flexural", f) && return "flexural"
    
    # For ErrorException, check failing_check for more detail
    if occursin("errorexception", f)
        occursin("section inadequate", fc) && return "section_inadequate"
        occursin("cannot fit reinforcement", fc) && return "reinforcement"
        occursin("cannot design reinforcement", fc) && return "column_design"
        return "section_inadequate"  # default for other errors
    end
    
    occursin("reinforcement", f) && return "reinforcement"
    occursin("argumenterror", f) && return "column_design"
    
    # For non_convergence, use failing_check to determine the actual failure mode
    # (the algorithm ran out of iterations but we know what check was failing)
    if occursin("non_convergence", f)
        occursin("punching", fc) && return "punching_shear"
        occursin("deflection", fc) && return "deflection"
        occursin("flexural", fc) && return "flexural"
        occursin("reinforcement", fc) && return "reinforcement"
        return "non_convergence"  # truly unknown
    end
    
    return "non_convergence"  # fallback
end
_categorize_failure(failures::AbstractString) = _categorize_failure(failures, "", "true")

"""
    plot_failure_heatmap(df; floor_type, title_suffix, file_suffix)

Categorical heatmap showing failure modes: methods (rows) × live loads (columns).
Uses discrete colors for each failure category.
"""
function plot_failure_heatmap(df; floor_type::String = "flat_plate",
                                  title_suffix::String = "",
                                  file_suffix::String = "")
    work = hasproperty(df, :floor_type) ? filter(r -> r.floor_type == floor_type, df) : df
    isempty(work) && begin
        println("  Skipping failure heatmap for $floor_type — no data")
        return nothing
    end

    ft_label = floor_type == "flat_slab" ? "Flat Slab" : "Flat Plate"

    methods    = METHOD_ORDER
    live_loads = sort(unique(work.live_psf))
    lx_vals    = sort(unique(work.lx_ft))
    ly_vals    = sort(unique(work.ly_ft))

    n_methods = length(methods)
    n_loads   = length(live_loads)

    lo_x, hi_x = extrema(lx_vals)
    lo_y, hi_y = extrema(ly_vals)

    # Map categories to integers for plotting
    cat_to_int = Dict(c => i for (i, c) in enumerate(FAILURE_CATEGORIES))
    n_cats = length(FAILURE_CATEGORIES)

    # Build categorical colormap
    cmap_colors = [FAILURE_COLORS[c] for c in FAILURE_CATEGORIES]

    fig = Figure(size = (300 * n_loads + 180, 200 * n_methods + 80),
                 figure_padding = (5, 5, 5, 5))

    Label(fig[0, 1:n_loads],
          "$ft_label — Failure Modes by Plan Dimensions$title_suffix";
          fontsize = 16, font = :bold, tellwidth = false)

    # Store axes for linking
    axs = Matrix{Axis}(undef, n_methods, n_loads)

    for (i, m) in enumerate(methods)
        for (j, ll) in enumerate(live_loads)
            sub = filter(r -> r.method == m && r.live_psf ≈ ll, work)

            # NOTE: Unlike depth heatmap, do NOT filter out ddm_eligible=false rows
            # We want to show them as DDM ineligible failures

            Z = fill(NaN, length(lx_vals), length(ly_vals))
            for row in eachrow(sub)
                xi = findfirst(≈(row.lx_ft), lx_vals)
                yi = findfirst(≈(row.ly_ft), ly_vals)
                if !isnothing(xi) && !isnothing(yi)
                    # Check if h_in is valid
                    h_val = hasproperty(row, :h_in) ? row.h_in : NaN
                    h_valid = !ismissing(h_val) && !isnan(h_val)

                    fail_str = coalesce(row.failures, "")
                    fail_check = hasproperty(row, :failing_check) ? coalesce(row.failing_check, "") : ""
                    ddm_elig = hasproperty(row, :ddm_eligible) ? string(coalesce(row.ddm_eligible, true)) : "true"
                    cat = _categorize_failure(fail_str, fail_check, ddm_elig)

                    # Only plot if it's a real failure OR (converged AND h_in is valid)
                    # Leave as NaN (white) if converged but h_in is invalid
                    if cat != "converged" || h_valid
                        Z[xi, yi] = get(cat_to_int, cat, n_cats)
                    end
                end
            end

            # Fill ALL missing grid points (cells with no data in either CSV)
            # - High aspect ratio (> 2.0) or DDM methods: ddm_ineligible
            # - Other methods: non_convergence (unknown failure)
            ddm_inelig_idx = get(cat_to_int, "ddm_ineligible", n_cats)
            nonconv_idx = get(cat_to_int, "non_convergence", n_cats)
            for (xi, lx) in enumerate(lx_vals)
                for (yi, ly) in enumerate(ly_vals)
                    if isnan(Z[xi, yi])
                        aspect = max(lx, ly) / min(lx, ly)
                        if aspect > 2.0 || m in ("MDDM", "DDM (Full)")
                            # High aspect ratio or DDM method with missing data
                            Z[xi, yi] = ddm_inelig_idx
                        else
                            # Unknown failure - data missing from sweep
                            Z[xi, yi] = nonconv_idx
                        end
                    end
                end
            end

            ll_label = "LL = $(Int(ll)) psf"
            mid_row = div(n_methods + 1, 2)
            
            # Tick interval: 5 ft
            x_ticks = collect(ceil(lo_x / 5.0) * 5.0 : 5.0 : hi_x)
            y_ticks = collect(ceil(lo_y / 5.0) * 5.0 : 5.0 : hi_y)
            
            ax = Axis(fig[i, j];
                      xlabel  = i == n_methods ? "Lx (ft)" : "",
                      ylabel  = j == 1 ? "Ly (ft)" : "",
                      title   = i == 1 ? ll_label : "",
                      aspect  = DataAspect(),
                      width   = 200,
                      height  = 200,
                      xticklabelsize = 9, yticklabelsize = 9,
                      titlesize = 12,
                      xticks = x_ticks, yticks = y_ticks,
                      alignmode = Outside(15))
            axs[i, j] = ax

            i < n_methods && hidexdecorations!(ax; ticks = false, grid = false)
            j > 1         && hideydecorations!(ax; ticks = false, grid = false)

            if !all(isnan.(Z))
                heatmap!(ax, lx_vals, ly_vals, Z;
                         colormap = cgrad(cmap_colors, n_cats, categorical = true),
                         colorrange = (0.5, n_cats + 0.5),
                         nan_color = :white)
            end

            xlims!(ax, lo_x, hi_x)
            ylims!(ax, lo_y, hi_y)

            # Diagonal reference line
            diag_hi = min(hi_x, hi_y)
            lines!(ax, [lo_x, diag_hi], [lo_x, diag_hi];
                   color = (:black, 0.5), linestyle = :dash, linewidth = 0.8)
        end

        Label(fig[i, 0], m;
              fontsize = 11, font = :bold, rotation = π/2, tellheight = false)
    end

    CairoMakie.linkaxes!(axs...)

    # Legend for categorical data - skip "converged" since it's blank/transparent
    legend_cats = filter(c -> c != "converged", FAILURE_CATEGORIES)
    legend_elements = [PolyElement(color = FAILURE_COLORS[c]) for c in legend_cats]
    legend_labels = [get(FAILURE_LABELS, c, titlecase(replace(c, "_" => " "))) for c in legend_cats]
    Legend(fig[1:n_methods, n_loads + 1], legend_elements, legend_labels;
           labelsize = 10, framevisible = false, rowgap = 2)

    # Footnote explaining failure modes
    footnote = """
    Max Column: exceeded 1.1×span limit (36-60")
    DDM Ineligible: aspect ratio >2 or LL/DL >2
    Non Convergence: design failed after 150 iterations
    """
    Label(fig[n_methods + 1, 1:n_loads], footnote;
          fontsize = 8, halign = :left, valign = :top,
          tellwidth = false, tellheight = true)

    rowgap!(fig.layout, 8)
    colgap!(fig.layout, 8)
    resize_to_layout!(fig)

    tag = floor_type == "flat_slab" ? "flat_slab" : "flat_plate"
    num = floor_type == "flat_slab" ? "13" : "12"
    return _save_fig(fig, "$(num)_failure_$(tag)$(file_suffix).png")
end

"""Generate both failure heatmap images."""
function plot_dual_failure_heatmaps(df; title_suffix::String = "", file_suffix::String = "")
    plot_failure_heatmap(df; floor_type = "flat_plate", title_suffix, file_suffix)
    plot_failure_heatmap(df; floor_type = "flat_slab",  title_suffix, file_suffix)
end

# ==============================================================================
# Generate all
# ==============================================================================

"""
    generate_all(df; include_rect=true)

Generate all comparison figures from a dual-sweep DataFrame.
Grid layout: rows = floor type (Flat Plate / Flat Slab), columns = PSF values.

Set `include_rect=true` (default) to also generate rectangular bay versions.
"""
function generate_all(df; include_rect::Bool = true)
    live_loads = sort(unique(df.live_psf))
    println("\nGenerating Flat Plate vs Flat Slab figures...")
    println("  PSF values: ", join(Int.(live_loads), ", "))

    # Square bay plots
    println("\n── Square bays ──")
    plot_thickness(df)
    plot_moments(df)
    plot_punching(df)
    plot_deflection(df)
    plot_columns(df)
    plot_rebar(df)
    plot_runtime(df)

    # Rectangular bay plots
    if include_rect
        println("\n── Rectangular bays ──")
        plot_thickness_rect(df)
        plot_moments_rect(df)
        plot_punching_rect(df)
        plot_deflection_rect(df)
        plot_columns_rect(df)
        plot_rebar_rect(df)
        plot_runtime_rect(df)
    end

    # Drop panels only for flat slab at default LL (50 psf if available)
    default_ll = 50.0 in live_loads ? 50.0 : first(live_loads)
    plot_drop_panels(df; ll = default_ll)

    println("\nDone — figures saved to $FP_FIGS_DIR")
end

# ==============================================================================
# 11 — Shear stud comparison plots
# ==============================================================================

const STUD_STYLES = Dict(
    "never"     => (color = :steelblue,   linestyle = :solid),
    "if_needed" => (color = :darkorange,  linestyle = :dash),
    "always"    => (color = :forestgreen, linestyle = :dot),
)

"""
    plot_stud_comparison(df; ll = 50.0)

Side-by-side Flat Plate | Flat Slab: compare thickness, punching ratio,
and column sizes across stud strategies.

Expects `stud_strategy` column from `stud_sweep`.
"""
function plot_stud_comparison(df; ll = 50.0)
    hasproperty(df, :stud_strategy) || begin
        println("  Skipping stud comparison — no stud_strategy column")
        return nothing
    end

    sub = _at_ll(_ensure_span(df), ll)
    fp, fs = _split_ft(sub)

    metrics = [
        (:h_in,        "h (in)",                "Slab Thickness"),
        (:punch_ratio, "Punch ratio (vu/φvc)",   "Punching Shear"),
        (:col_max_in,  "Column size (in)",       "Max Column Size"),
    ]

    for (col, ylabel, title) in metrics
        fig = Figure(size = (1100, 450))
        Label(fig[0, 1:2], "$(title) — Stud Strategy Comparison (LL=$(Int(ll)) psf)";
              fontsize = 16, font = :bold, tellwidth = false)

        for (j, (ft_df, ft_title)) in enumerate([(fp, "Flat Plate"), (fs, "Flat Slab")])
            ax = Axis(fig[1, j];
                      xlabel = "Span (ft)",
                      ylabel = j == 1 ? ylabel : "",
                      title  = ft_title,
                      width  = 400,
                      height = 300,
                      alignmode = Outside(15))

            if col === :punch_ratio
                hlines!(ax, [1.0]; color = :red, linestyle = :dash, linewidth = 1, label = "Limit")
            end

            for stud in ["never", "if_needed", "always"]
                sd = filter(r -> r.stud_strategy == stud, ft_df)
                isempty(sd) && continue
                sp = sort(unique(sd.span_ft))
                yv = Float64[]
                for s in sp
                    rows_s = filter(r -> r.span_ft == s, sd)
                    push!(yv, isempty(rows_s) ? NaN : rows_s[1, col])
                end
                sty = get(STUD_STYLES, stud, (color=:gray, linestyle=:solid))
                lines!(ax, sp, yv; label = "studs=$stud",
                       color = sty.color, linestyle = sty.linestyle, linewidth = 2)
                scatter!(ax, sp, yv; color = sty.color, markersize = 8)
            end

            ylims!(ax, 0, nothing)
            j == 2 && axislegend(ax; position = :lt, labelsize = 10)
        end

        slug = replace(string(col), r"\W" => "_")
        _save_fig(fig, "11_stud_$(slug).png")
    end
end
