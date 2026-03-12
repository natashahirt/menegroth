# =============================================================================
# Sysimage precompile script — run during PackageCompiler.create_sysimage
# =============================================================================
#
# Executed inside the sysimage build to trace StructuralSynthesizer and
# register_routes! so the compiled code is baked into the sysimage.
#
# register_routes! calls Oxygen macros (@get, @post) that mutate global
# router state. That state won't survive sysimage serialization, but the
# *compiled native code* for those methods will — which is the point.
# Wrapped in try/catch so a failure here doesn't abort the sysimage build.
#
# Usage: only via PackageCompiler (precompile_execution_file).
# =============================================================================

using StructuralSynthesizer

try
    Base.invokelatest(register_routes!)
    @info "Sysimage precompile: register_routes! done"
catch e
    @warn "Sysimage precompile: register_routes! failed (non-fatal)" exception=(e, catch_backtrace())
end
