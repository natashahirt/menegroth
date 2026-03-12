# =============================================================================
# Build custom sysimage for the Sizer API (PackageCompiler)
# =============================================================================
#
# Builds a sysimage containing StructuralSynthesizer and the API route
# registration so that cold start is "load sysimage" instead of loading
# many .ji files (or re-precompiling).
#
# Prerequisites:
#   julia --project=StructuralSynthesizer -e 'using Pkg; Pkg.add("PackageCompiler")'
#
# Usage:
#   julia --project=StructuralSynthesizer scripts/api/build_sysimage.jl [OUTPUT_PATH]
#
# Default output: sys.so in current directory. In Docker we pass /app/sys.so.
# =============================================================================

using PackageCompiler

out_path = length(ARGS) >= 1 ? ARGS[1] : joinpath(pwd(), "sys.so")
precompile_file = joinpath(@__DIR__, "sysimage_precompile.jl")
project_dir = normpath(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

@info "Building sysimage" output=out_path precompile_file=precompile_file project=project_dir

PackageCompiler.create_sysimage(
    [:StructuralSynthesizer];
    sysimage_path=out_path,
    precompile_execution_file=precompile_file,
    project=project_dir,
    cpu_target="generic",
)

@info "Sysimage built successfully" path=out_path
