# =============================================================================
# Build a sysimage for sweeps (PackageCompiler)
# =============================================================================
#
# Like scripts/api/build_sysimage.jl, but the precompile trace runs small DDM
# and FEA `design_building` calls through the sweep's per-case function, so
# workers start with the flat-plate FEA path (absent from the package's
# PrecompileTools workload) already compiled.
#
#   julia scripts/runners/build_sweep_sysimage.jl [OUTPUT_PATH]
#
# Default output: build/sweep_sys.<dylib|so|dll>. Use it with
#   julia scripts/runners/sweep_design_building.jl SPEC.jl --sysimage build/sweep_sys.dylib
# Rebuild after changing package source; a stale sysimage runs stale code.
# PackageCompiler is loaded from a temporary environment, so the
# StructuralSynthesizer manifest is not modified.
# =============================================================================

using Pkg
const REPO = normpath(joinpath(@__DIR__, "..", ".."))
const PROJECT = joinpath(REPO, "StructuralSynthesizer")

ext = Sys.isapple() ? "dylib" : Sys.iswindows() ? "dll" : "so"
out_path = abspath(length(ARGS) >= 1 ? ARGS[1] : joinpath(REPO, "build", "sweep_sys.$ext"))
mkpath(dirname(out_path))

Pkg.activate(; temp = true)
Pkg.add("PackageCompiler"; io = devnull)
using PackageCompiler

ENV["SS_ENABLE_VISUALIZATION"] = "false"
@info "Building sweep sysimage (expect 10–30 min)" output=out_path project=PROJECT

PackageCompiler.create_sysimage(
    [:StructuralSynthesizer, :StructuralSizer, :Asap, :Unitful];
    sysimage_path = out_path,
    precompile_execution_file = joinpath(@__DIR__, "sweep_sysimage_precompile.jl"),
    project = PROJECT,
)

@info "Sweep sysimage built" path=out_path
