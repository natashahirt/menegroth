# Use official Julia image
FROM julia:1.12.4

# Set working directory
WORKDIR /app

# Use a fixed depot path so build-time precompile is reused at runtime.
ENV JULIA_DEPOT_PATH=/app/.julia
RUN mkdir -p "${JULIA_DEPOT_PATH}"

# Copy Project.toml files first (for better layer caching)
COPY Project.toml Manifest.toml ./
COPY StructuralSynthesizer/Project.toml StructuralSynthesizer/
COPY StructuralSizer/Project.toml StructuralSizer/
COPY StructuralPlots/Project.toml StructuralPlots/
COPY external/Asap/Project.toml external/Asap/

# Note: Manifest.toml files are optional - Pkg.instantiate() will create them if needed

# Fix Windows-style paths in Project.toml files to Linux-style
RUN sed -i 's|\\\\|/|g' StructuralSynthesizer/Project.toml StructuralSizer/Project.toml

# API runtime is headless; disable visualization-heavy package loading.
ENV SS_ENABLE_VISUALIZATION=false
ENV SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD=false

# Install dependencies in a cache-friendly layer.
RUN julia --project=StructuralSynthesizer -e 'using Pkg; Pkg.instantiate()'

# Copy source code after dependency installation
COPY StructuralSynthesizer/src ./StructuralSynthesizer/src
COPY StructuralSizer/src ./StructuralSizer/src
COPY StructuralPlots/src ./StructuralPlots/src
COPY StructuralVisualization/src ./StructuralVisualization/src
COPY external/Asap/src ./external/Asap/src
COPY scripts/api ./scripts/api

# Precompile Oxygen + HTTP so the bootstrap binds quickly.
RUN julia --project=StructuralSynthesizer -e 'using Oxygen; using HTTP'

# Build custom sysimage so cold start is "load sysimage" instead of many .ji files.
# PackageCompiler is added only at build time (not in Project.toml).
RUN julia --project=StructuralSynthesizer -e 'using Pkg; Pkg.add("PackageCompiler")'

# Sysimage build (timeout 45 min; typically 15–30 min).
RUN timeout 2700 julia --project=StructuralSynthesizer scripts/api/build_sysimage.jl /app/sys.so

# Expose port (AWS App Runner sets PORT env var)
EXPOSE 8080

ENV JULIA_PROJECT=StructuralSynthesizer
ENV SIZER_HOST=0.0.0.0

# Optional: set GRB_LICENSE_CONTENTS at runtime to write gurobi.lic; then start the API
RUN chmod +x /app/scripts/api/docker_entry.sh
ENTRYPOINT ["/app/scripts/api/docker_entry.sh"]
CMD ["julia", "-J", "/app/sys.so", "--project=StructuralSynthesizer", "scripts/api/sizer_bootstrap.jl"]
