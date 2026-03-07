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

# Warm exact server path only (no full Pkg.precompile). Full precompile was
# hanging after InteractiveUtils (open tasks/IO in a transitive dep). This
# warms the API code path so runtime startup is fast enough for health checks.
RUN julia --project=StructuralSynthesizer -e '\
  ENV["SS_ENABLE_VISUALIZATION"]="false"; ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"]="false"; \
  using StructuralSynthesizer; register_routes!(); using Oxygen;'

# Expose port (AWS App Runner sets PORT env var)
EXPOSE 8080

# Set environment variables
ENV JULIA_PROJECT=StructuralSynthesizer
ENV SIZER_HOST=0.0.0.0

# Start the server
CMD ["julia", "--project=StructuralSynthesizer", "scripts/api/sizer_service.jl"]
