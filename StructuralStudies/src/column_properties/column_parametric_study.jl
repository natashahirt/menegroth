# ==============================================================================
# RC Column Parametric Study
# ==============================================================================
#
# Interactive parametric sweep over RC column design parameters.
# Evaluates capacity, embodied carbon, and slenderness per ACI 318.
#
# Usage (from Julia REPL at project root):
#
#   include("src/column_properties/column_parametric_study.jl")
#
#   df = sweep()                              # full factorial (~25k sections)
#   df = material_sweep()                     # f'c × fy × ρ, geometry fixed
#   df = geometry_sweep()                     # size × AR × shape, material fixed
#   df = detailing_sweep()                    # cover × arrangement × tie type
#   df = sweep(sizes=[20,24], fc=[4.0,6.0])   # custom subset
#
#   save_results(df, "my_study")              # → results/my_study_<timestamp>.csv
#
# ==============================================================================

include(joinpath(@__DIR__, "..", "init.jl"))

@isdefined(RESULTS_DIR) || (const RESULTS_DIR = joinpath(@__DIR__, "results"))

# ==============================================================================
# Helpers
# ==============================================================================

"""ACI 318 §22.2.2.4.3 — Whitney stress block depth factor."""
calc_beta1(fc_ksi) = fc_ksi ≤ 4.0 ? 0.85 : max(0.65, 0.85 - 0.05 * (fc_ksi - 4.0))

"""Find bar configuration closest to target ρ for a given gross area (in²)."""
function find_bars_for_rho(Ag, ρ_target, bar_sizes)
    As_target = ρ_target * Ag
    best, best_err = nothing, Inf
    for bs in bar_sizes
        Ab = ustrip(u"inch^2", StructuralSizer.rebar(bs).A)
        for n in (floor(Int, As_target / Ab), ceil(Int, As_target / Ab))
            (4 ≤ n ≤ 24) || continue
            ρ = n * Ab / Ag
            (0.01 ≤ ρ ≤ 0.08) || continue
            err = abs(ρ - ρ_target)
            if err < best_err
                best_err = err
                best = (bar_size=bs, n_bars=n, ρ_actual=ρ, As=n * Ab)
            end
        end
    end
    return best
end

"""All valid 4-bar (corners_only) configs for a given Ag (in²)."""
function corners_configs(Ag, bar_sizes)
    out = NamedTuple[]
    for bs in bar_sizes
        Ab = ustrip(u"inch^2", StructuralSizer.rebar(bs).A)
        As = 4 * Ab
        ρ = As / Ag
        (0.01 ≤ ρ ≤ 0.08) && push!(out, (bar_size=bs, n_bars=4, ρ_actual=ρ, As=As))
    end
    return out
end

"""Key control points from a P-M interaction diagram."""
function extract_pm_metrics(diagram)
    cp(k) = StructuralSizer.get_control_point(diagram, k)
    pts = diagram.points
    i_Mn  = argmax(p.Mn  for p in pts)
    i_φMn = argmax(p.φMn for p in pts)

    pc  = cp(:pure_compression)
    mc  = cp(:max_compression)
    bal = cp(:balanced)
    pb  = cp(:pure_bending)
    pt  = cp(:pure_tension)

    return (
        P0   = pc.Pn,    φP0   = pc.φPn,
        Pn_max = mc.Pn,  φPn_max = mc.φPn,
        Pb   = bal.Pn,    φPb   = bal.φPn,
        Mb   = bal.Mn,    φMb   = bal.φMn,
        Mn_max = pts[i_Mn].Mn,           Pn_at_Mn_max = pts[i_Mn].Pn,
        φMn_max = pts[i_φMn].φMn,        φPn_at_φMn_max = pts[i_φMn].φPn,
        Mn_pure_bending = pb.Mn,          φMn_pure_bending = pb.φMn,
        Pn_tension = pt.Pn,
    )
end

"""Balanced eccentricity ratio eb/h."""
function balanced_eb_over_h(diagram, h_in)
    bal = StructuralSizer.get_control_point(diagram, :balanced)
    (bal.Mn * 12 / max(bal.Pn, 1e-6)) / h_in
end

"""Nonsway moment magnification at a given kLu/r."""
function slenderness_at(section, mat, kLu_r, βdns, Pu, Mu)
    kLu_r == 0 && return (δns=1.0, Pc=Inf, slender=false, penalty=0.0)

    r_in = section isa StructuralSizer.RCColumnSection ?
           0.3 * ustrip(u"inch", section.h) :
           0.25 * ustrip(u"inch", section.D)
    Lu = ustrip(u"m", kLu_r * r_in * u"inch")
    geom = StructuralSizer.ConcreteMemberGeometry(Lu; Lu=Lu, k=1.0)

    try
        res = StructuralSizer.magnify_moment_nonsway(
            section, mat, geom, Pu, 0.0, Mu; βdns=βdns)
        penalty = res.slender ? (res.Mc - Mu) / max(Mu, 1e-6) * 100 : 0.0
        (δns=res.δns, Pc=res.Pc, slender=res.slender, penalty=penalty)
    catch
        (δns=Inf, Pc=0.0, slender=true, penalty=100.0)
    end
end

const _SL_NAN = (δns=NaN, Pc=NaN, slender=false, penalty=NaN)

# ==============================================================================
# Core: analyze one section → result row
# ==============================================================================

function analyze_section(id, shape, b, h, D, ar, cover, arr, tie,
                         cfg, fc, fy; kLu_r=[30,50,70], βdns=0.6)
    section = shape == :rect ?
        StructuralSizer.RCColumnSection(
            b=b*u"inch", h=h*u"inch", bar_size=cfg.bar_size,
            n_bars=cfg.n_bars, cover=cover*u"inch",
            tie_type=tie, arrangement=arr) :
        StructuralSizer.RCCircularSection(
            D=D*u"inch", bar_size=cfg.bar_size,
            n_bars=cfg.n_bars, cover=cover*u"inch", tie_type=tie)

    mat = (fc=fc, fy=fy, Es=29000.0, εcu=0.003)
    diagram = StructuralSizer.generate_PM_diagram(section, mat)
    pm = extract_pm_metrics(diagram)

    # Volumes & carbon
    Ag = shape == :rect ? b * h : π * (D / 2)^2
    Ag_m2 = ustrip(u"m^2", Ag * u"inch^2")
    As_m2 = ustrip(u"m^2", cfg.As * u"inch^2")
    vol_c = (Ag_m2 - As_m2) * TYPICAL_COLUMN_HEIGHT_M
    vol_s = As_m2 * TYPICAL_COLUMN_HEIGHT_M
    carbon = calc_embodied_carbon(vol_c, vol_s)

    # Slenderness at 50% of capacity
    Pu, Mu = pm.φPn_max / 2, pm.φMb / 2
    sl = Dict(k => slenderness_at(section, mat, Float64(k), βdns, Pu, Mu)
              for k in kLu_r)
    sl03 = 50 in kLu_r ? slenderness_at(section, mat, 50.0, 0.3, Pu, Mu) : _SL_NAN
    sl08 = 50 in kLu_r ? slenderness_at(section, mat, 50.0, 0.8, Pu, Mu) : _SL_NAN

    h_reg = shape == :rect ? h : D

    return (
        # Geometry
        id=id, shape=shape, b_in=b, h_in=h, D_in=D, aspect_ratio=ar,
        cover_in=cover, arrangement=arr, tie_type=tie,
        Ag_in2=Ag, As_in2=cfg.As, bar_size=cfg.bar_size, n_bars=cfg.n_bars,
        rho_actual=cfg.ρ_actual,
        # Material
        fc_ksi=fc, fy_ksi=fy, beta1=calc_beta1(fc),
        # Volume & carbon
        volume_concrete_m3=vol_c, volume_steel_m3=vol_s,
        volume_total_m3=Ag_m2 * TYPICAL_COLUMN_HEIGHT_M,
        # DataFrame / CSV boundary: `calc_embodied_carbon` returns typed
        # `kgCO₂e` quantities (T3.3), so strip to bare Float64 here.
        carbon_concrete_kg=ustrip(u"kgCO2e", carbon.concrete),
        carbon_steel_kg=ustrip(u"kgCO2e", carbon.steel),
        carbon_total_kg=ustrip(u"kgCO2e", carbon.total),
        # Capacity (nominal)
        P0_kip=pm.P0, Pn_max_kip=pm.Pn_max, Pb_kip=pm.Pb, Mb_kipft=pm.Mb,
        Mn_max_kipft=pm.Mn_max, Pn_at_Mn_max_kip=pm.Pn_at_Mn_max,
        Mn_pure_bending_kipft=pm.Mn_pure_bending, Pn_tension_kip=pm.Pn_tension,
        # Capacity (factored)
        phi_P0_kip=pm.φP0, phi_Pn_max_kip=pm.φPn_max,
        phi_Pb_kip=pm.φPb, phi_Mb_kipft=pm.φMb,
        phi_Mn_max_kipft=pm.φMn_max, phi_Pn_at_phi_Mn_max_kip=pm.φPn_at_φMn_max,
        phi_Mn_pure_bending_kipft=pm.φMn_pure_bending,
        # Derived metrics
        P0_per_Ag_ksi=pm.P0 / Ag,
        Mn_max_per_Ag_kipft_in2=pm.Mn_max / Ag,
        steel_contribution_pct=cfg.As * fy / pm.P0 * 100,
        phi_Pn_max_per_carbon_kip_per_kg=pm.φPn_max / max(ustrip(u"kgCO2e", carbon.total), 1e-6),
        # Slenderness (βdns=0.6 baseline)
        kLu_r_30_delta_ns    = get(sl, 30, _SL_NAN).δns,
        kLu_r_30_penalty_pct = get(sl, 30, _SL_NAN).penalty,
        kLu_r_50_delta_ns    = get(sl, 50, _SL_NAN).δns,
        kLu_r_50_penalty_pct = get(sl, 50, _SL_NAN).penalty,
        kLu_r_70_delta_ns    = get(sl, 70, _SL_NAN).δns,
        kLu_r_70_penalty_pct = get(sl, 70, _SL_NAN).penalty,
        # Slenderness sensitivity (βdns at kLu/r=50)
        kLu_r_50_bdns_03_delta_ns = sl03.δns,
        kLu_r_50_bdns_08_delta_ns = sl08.δns,
        eb_over_h = balanced_eb_over_h(diagram, h_reg),
    )
end

# ==============================================================================
# Sweep
# ==============================================================================

"""
    sweep(; kwargs...) → DataFrame

Parametric sweep over RC column designs. Returns a DataFrame with one row per
successfully analyzed section. All parameters have defaults for a full factorial
sweep (~25k sections). Narrow any parameter to run a focused sub-study.

# Examples
```julia
df = sweep()                                # full factorial
df = sweep(sizes=[20], fc=[4.0, 6.0])       # custom subset
df = material_sweep()                       # convenience wrapper
```
"""
function sweep(;
    sizes         = [12, 16, 20, 24, 30, 36],
    aspect_ratios = [1.0, 1.33, 1.5, 2.0],
    fc            = [3.0, 4.0, 5.0, 6.0, 8.0],
    fy            = [40.0, 60.0, 75.0, 80.0],
    ρ             = [0.01, 0.02, 0.03, 0.04, 0.06],
    bar_sizes     = [6, 8, 9, 10, 11],
    covers        = [1.5, 2.0, 3.0],
    arrangements  = [:perimeter, :two_layer, :corners_only],
    tie_types     = [:tied, :spiral],
    shapes        = [:rect, :circular],
    kLu_r         = [30, 50, 70],
    βdns          = 0.6,
    save          = true,
    name          = "column_study",
)
    rows = NamedTuple[]
    id, n_ok, n_err = 0, 0, 0
    errors = String[]

    rect_arrs  = filter(a -> a ≠ :corners_only, arrangements)
    do_corners = :corners_only in arrangements

    print_header("RC Column Parametric Study")

    # ── Rectangular: standard arrangements ────────────────────────────────────
    if :rect in shapes && !isempty(rect_arrs)
        combos = collect(Iterators.product(
            sizes, aspect_ratios, fc, fy, ρ, covers, rect_arrs, tie_types))
        prog = Progress(length(combos); desc="Rect (standard): ")

        for (sz, ar, fc_v, fy_v, ρ_t, cov, arr, tie) in combos
            next!(prog)
            b, h = Float64(sz), Float64(round(Int, sz * ar))
            cfg = find_bars_for_rho(b * h, ρ_t, bar_sizes)
            isnothing(cfg) && continue
            try
                id += 1
                push!(rows, analyze_section(
                    id, :rect, b, h, 0.0, ar, cov, arr, tie,
                    cfg, fc_v, fy_v; kLu_r, βdns))
                n_ok += 1
            catch e
                n_err += 1
                length(errors) < 5 && push!(errors,
                    "RECT $(b)×$(h) $arr: $(sprint(showerror, e))")
            end
        end
        finish!(prog)
    end

    # ── Rectangular: corners_only (4 bars, iterate bar sizes) ─────────────────
    if :rect in shapes && do_corners
        combos = collect(Iterators.product(
            sizes, aspect_ratios, fc, fy, covers, tie_types))
        prog = Progress(length(combos); desc="Rect (corners):  ")

        for (sz, ar, fc_v, fy_v, cov, tie) in combos
            next!(prog)
            b, h = Float64(sz), Float64(round(Int, sz * ar))
            for cfg in corners_configs(b * h, bar_sizes)
                try
                    id += 1
                    push!(rows, analyze_section(
                        id, :rect, b, h, 0.0, ar, cov, :corners_only, tie,
                        cfg, fc_v, fy_v; kLu_r, βdns))
                    n_ok += 1
                catch e
                    n_err += 1
                    length(errors) < 5 && push!(errors,
                        "CORNERS $(b)×$(h): $(sprint(showerror, e))")
                end
            end
        end
        finish!(prog)
    end

    # ── Circular ──────────────────────────────────────────────────────────────
    if :circular in shapes
        combos = collect(Iterators.product(sizes, fc, fy, ρ, covers, tie_types))
        prog = Progress(length(combos); desc="Circular:        ")

        for (sz, fc_v, fy_v, ρ_t, cov, tie) in combos
            next!(prog)
            D  = Float64(sz)
            Ag = π * (D / 2)^2
            cfg = find_bars_for_rho(Ag, ρ_t, bar_sizes)
            (isnothing(cfg) || cfg.n_bars < 6) && continue

            n_actual = max(cfg.n_bars, 6)
            Ab = ustrip(u"inch^2", StructuralSizer.rebar(cfg.bar_size).A)
            As = n_actual * Ab
            ρ_act = As / Ag
            (0.01 ≤ ρ_act ≤ 0.08) || continue
            cfg_circ = (bar_size=cfg.bar_size, n_bars=n_actual,
                        ρ_actual=ρ_act, As=As)

            try
                id += 1
                push!(rows, analyze_section(
                    id, :circular, 0.0, 0.0, D, 1.0, cov, :perimeter, tie,
                    cfg_circ, fc_v, fy_v; kLu_r, βdns))
                n_ok += 1
            catch e
                n_err += 1
                length(errors) < 5 && push!(errors,
                    "CIRC D=$D: $(sprint(showerror, e))")
            end
        end
        finish!(prog)
    end

    # ── Assemble results ──────────────────────────────────────────────────────
    df = isempty(rows) ? DataFrame() : DataFrame(rows)

    if !isempty(errors)
        println("\nFirst errors:")
        for e in errors; println("  • $e"); end
    end

    outpath = save ? save_results(df, name) : "(not saved)"
    print_footer(n_ok, n_err, outpath)
    _print_summary(df)

    return df
end

# ==============================================================================
# Focused Sweeps
# ==============================================================================

"""Vary f'c, fy, ρ at fixed geometry (default 20\" square, tied, 1.5\" cover)."""
material_sweep(; size=20, cover=1.5, kw...) = sweep(;
    sizes=[size], aspect_ratios=[1.0], covers=[cover],
    arrangements=[:perimeter], tie_types=[:tied], shapes=[:rect], kw...)

"""Vary size, aspect ratio, shape at fixed material (default f'c=4, fy=60, ρ=2%)."""
geometry_sweep(; fc_val=4.0, fy_val=60.0, ρ_val=0.02, kw...) = sweep(;
    fc=[fc_val], fy=[fy_val], ρ=[ρ_val], covers=[1.5], kw...)

"""Vary cover, arrangement, tie type at fixed size & material."""
detailing_sweep(; size=20, fc_val=4.0, fy_val=60.0, kw...) = sweep(;
    sizes=[size], aspect_ratios=[1.0], fc=[fc_val], fy=[fy_val],
    shapes=[:rect], kw...)

# ==============================================================================
# I/O
# ==============================================================================

"""Save a DataFrame to a timestamped CSV in the results directory."""
function save_results(df::DataFrame, name::String="column_study")
    path = output_filename(name, RESULTS_DIR)
    CSV.write(path, df)
    println("Saved $(nrow(df)) rows → $path")
    return path
end

function _print_summary(df::DataFrame)
    nrow(df) == 0 && return println("No sections generated.")
    println("\nSummary")
    println("─" ^ 50)
    println("  Rectangular: $(count(df.shape .== :rect))")
    println("  Circular:    $(count(df.shape .== :circular))")
    println("  f'c:   $(minimum(df.fc_ksi))–$(maximum(df.fc_ksi)) ksi")
    println("  fy:    $(minimum(df.fy_ksi))–$(maximum(df.fy_ksi)) ksi")
    ρ_lo = round(minimum(df.rho_actual) * 100, digits=2)
    ρ_hi = round(maximum(df.rho_actual) * 100, digits=2)
    println("  ρ:     $(ρ_lo)–$(ρ_hi)%")
    println("  P0:    $(round(Int, minimum(df.P0_kip)))–$(round(Int, maximum(df.P0_kip))) kip")
    c_lo = round(minimum(df.carbon_total_kg), digits=1)
    c_hi = round(maximum(df.carbon_total_kg), digits=1)
    println("  Carbon: $(c_lo)–$(c_hi) kg CO₂e")
end

# ==============================================================================
println("\nColumn study loaded. Try:")
println("  df = sweep()                  # full factorial")
println("  df = material_sweep()         # f'c × fy × ρ, geometry fixed")
println("  df = geometry_sweep()         # size × shape, material fixed")
println("  df = detailing_sweep()        # cover × arrangement × tie type")
println("  df = sweep(sizes=[20], fc=[4.0, 6.0])  # custom")
