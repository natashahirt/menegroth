# Save composite beam report to text file (strips ANSI + solver noise)

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."))

using Logging
global_logger(NullLogger())

const REPORT_DIR = joinpath(@__DIR__, "..", "..", "StructuralSynthesizer", "test", "reports")
mkpath(REPORT_DIR)

function strip_ansi(s::AbstractString)
    replace(s, r"\e\[[0-9;]*[A-Za-z]" => "")
end

outfile = joinpath(REPORT_DIR, "composite_beam_report.txt")
script  = joinpath(@__DIR__, "..", "..", "StructuralSynthesizer", "test",
                   "report_generators", "test_composite_beam_report.jl")

open(outfile, "w") do io
    redirect_stdout(io) do
        try
            include(script)
        catch e
            println("\n\n*** ERROR ***")
            showerror(stdout, e, catch_backtrace())
        end
    end
end

raw = read(outfile, String)
clean = strip_ansi(raw)
lines = split(clean, '\n')
filtered = filter(lines) do line
    !startswith(line, "Set parameter") &&
    !startswith(line, "Academic license") &&
    !startswith(line, "****")
end
write(outfile, join(filtered, '\n'))
println(stderr, "Saved composite_beam_report.txt ($(length(filtered)) lines)")
