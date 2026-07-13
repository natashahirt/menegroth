# ==============================================================================
# StructuralStudies Init
# ==============================================================================
# Include this file at the top of any study script to load all dependencies.
# Safe to include multiple times (guarded).
#
# Usage: include(joinpath(@__DIR__, "..", "init.jl"))
# ==============================================================================

# Bump when init semantics change (e.g. typed kgCO₂e constants) so incremental
# REPL sessions re-run this block instead of keeping stale Float64 constants.
const _STRUCTURAL_STUDIES_INIT_VERSION = 2

if !@isdefined(_STRUCTURAL_STUDIES_LOADED_VERSION) ||
   _STRUCTURAL_STUDIES_LOADED_VERSION != _STRUCTURAL_STUDIES_INIT_VERSION

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

# Core structural modules
using StructuralSizer
using StructuralSynthesizer
using Unitful
# `import Asap` loads the module (so `@u_str` can resolve `u"kgCO2e"`) without
# pulling FEM exports into the study script namespace.
import Asap

# Analysis dependencies
using DataFrames
using CSV
using Dates
using ProgressMeter

# Visualization (optional — loads if available)
try
    using GLMakie
    using ColorSchemes
    global VIS_AVAILABLE = true
    println("Visualization: GLMakie loaded ✓")
catch
    global VIS_AVAILABLE = false
    println("Visualization: GLMakie not available (run Pkg.add(\"GLMakie\") to enable)")
end

# ==============================================================================
# Study utilities
# ==============================================================================

"""Ensure directory exists, creating if needed."""
function ensure_dir(dir::String)
    isdir(dir) || mkpath(dir)
    return dir
end

"""Generate timestamped filename for study output."""
function output_filename(study_name::String, results_dir::String; ext::String="csv")
    ensure_dir(results_dir)
    timestamp = Dates.format(now(), "yyyymmdd_HHMMSS")
    return joinpath(results_dir, "$(study_name)_$(timestamp).$(ext)")
end

"""Print study header."""
function print_header(title::String)
    println("=" ^ 60)
    println(title)
    println("Started: $(now())")
    println("=" ^ 60)
    println()
end

"""Print study footer with summary."""
function print_footer(n_created::Int, n_failed::Int, output_file)
    println()
    println("=" ^ 60)
    println("Study Complete!")
    println("=" ^ 60)
    println("Records created: $n_created")
    println("Records failed:  $n_failed")
    println("Output file:     $output_file")
    println()
end

# ==============================================================================
# Common constants for RC column studies
# ==============================================================================

const TYPICAL_COLUMN_HEIGHT_M = 4.0   # meters
const TYPICAL_STORY_HEIGHT_FT = 13.0  # feet

# Embodied carbon factors (approximate) — typed as `kgCO₂e` quantities per the
# kgCO2e Unitful refactor (T3.3). Values unchanged; `Asap.kgCO2e` is the refunit.
# STEEL_DENSITY carries `kg/m^3` so the steel-carbon product closes dimensionally
# (m³ · kg/m³ · kgCO₂e/kg).
#
# NOTE: these definitions live inside the versioned guard block, which Julia
# macro-expands as a whole *before* the block's own `import` runs — so the
# `u"…"` string macro is not yet in scope here. Build units from `Asap.kgCO2e`,
# `Unitful.m`, and `Unitful.kg`, which resolve at run time after `import Asap`.
const CARBON_CONCRETE_KGCO2E_PER_M3 = 300.0  * Asap.kgCO2e / Unitful.m^3
const CARBON_REBAR_KGCO2E_PER_KG    = 1.5    * Asap.kgCO2e / Unitful.kg
const STEEL_DENSITY_KG_PER_M3       = 7850.0 * Unitful.kg / Unitful.m^3

const _CARBON_MASS_DIMENSION = Unitful.dimension(1.0 * Asap.kgCO2e)

"""Calculate embodied carbon for a column. Returns typed `kgCO₂e` quantities;
strip with `ustrip(u"kgCO2e", …)` at DataFrame / CSV boundaries."""
function calc_embodied_carbon(vol_concrete_m3::Float64, vol_steel_m3::Float64)
    carbon_concrete = vol_concrete_m3 * Unitful.m^3 * CARBON_CONCRETE_KGCO2E_PER_M3
    carbon_steel    = vol_steel_m3 * Unitful.m^3 * STEEL_DENSITY_KG_PER_M3 * CARBON_REBAR_KGCO2E_PER_KG
    total = carbon_concrete + carbon_steel
    @assert Unitful.dimension(carbon_concrete) === _CARBON_MASS_DIMENSION
    @assert Unitful.dimension(carbon_steel) === _CARBON_MASS_DIMENSION
    @assert Unitful.dimension(total) === _CARBON_MASS_DIMENSION
    return (concrete = carbon_concrete, steel = carbon_steel, total = total)
end

const _STRUCTURAL_STUDIES_LOADED_VERSION = _STRUCTURAL_STUDIES_INIT_VERSION
println("StructuralStudies initialized ✓ (init v$_STRUCTURAL_STUDIES_INIT_VERSION)")

end  # if !@isdefined
