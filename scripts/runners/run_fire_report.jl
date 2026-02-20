# Runner: Fire Rating Parametric Report
# Generates a comprehensive report on fire rating impacts across all element types.
# Output saved to StructuralSynthesizer/test/reports/fire_rating_report.txt
#
# Usage:
#   julia --project scripts/runners/run_fire_report.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))

using Logging
global_logger(NullLogger())

const REPORT_DIR = joinpath(@__DIR__, "..", "..", "StructuralSynthesizer", "test", "reports")
mkpath(REPORT_DIR)

function strip_ansi(s::AbstractString)
    replace(s, r"\e\[[0-9;]*[A-Za-z]" => "")
end

const SCRIPT = joinpath(@__DIR__, "..", "..", "StructuralSynthesizer", "test", "sizing", "test_fire_rating_report.jl")
const OUTFILE = joinpath(REPORT_DIR, "fire_rating_report.txt")

# Capture stdout to file
open(OUTFILE, "w") do io
    redirect_stdout(io) do
        try
            include(SCRIPT)
        catch e
            println("\n\n*** ERROR running fire rating report ***")
            showerror(stdout, e, catch_backtrace())
        end
    end
end

# Post-process: strip ANSI codes and solver noise
raw = read(OUTFILE, String)
clean = strip_ansi(raw)
lines = split(clean, '\n')
filtered = filter(lines) do line
    !startswith(line, "Presolving model") &&
    !startswith(line, "Solving model") &&
    !startswith(line, "Running HiGHS") &&
    !startswith(line, "Solution has") &&
    !contains(line, "HiGHS") &&
    !contains(line, "Ipopt") &&
    !startswith(line, "This is Ipopt") &&
    !contains(line, "Coin-OR") &&
    !contains(line, "mumps") &&
    !startswith(line, "Number of") &&
    !startswith(line, "Total number") &&
    !contains(line, "iteration") &&
    !contains(line, "objective value") &&
    !contains(line, "EXIT:") &&
    !startswith(line, "Optimal") &&
    !contains(line, "nlp_scaling") &&
    !contains(line, "linear_solver") &&
    !startswith(line, "Set parameter") &&
    !startswith(line, "Academic license") &&
    !startswith(line, "****")
end

# Write back — Julia strings are UTF-8; write() emits raw bytes
write(OUTFILE, join(filtered, '\n'))
println(stderr, "✓ fire_rating_report.txt ($(length(filtered)) lines)")
println(stderr, "  → $OUTFILE")

