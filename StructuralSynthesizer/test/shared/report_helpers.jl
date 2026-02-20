# Shared report-printing helpers for validation test suites.
#
# Usage (inside any test file):
#
#   include(joinpath(@__DIR__, "..", "shared", "report_helpers.jl"))
#   const rpt = ReportHelpers.Printer()           # default 78-char lines
#   const rpt = ReportHelpers.Printer(width = 74) # narrower
#
#   rpt.section("TITLE")
#   rpt.sub("Subtitle")
#   rpt.note("Detail line")
#   rpt.hline   # "─" * width
#   rpt.dline   # "═" * width

module ReportHelpers

"""
    Printer(; width = 78)

Lightweight callable namespace for report formatting.
Each test file gets its own `Printer` instance, so nothing leaks into `Main`.
"""
struct Printer
    hline::String
    dline::String
    section::Function
    sub::Function
    note::Function
end

function Printer(; width::Int = 78)
    hline = "─"^width
    dline = "═"^width
    section = title -> println("\n", dline, "\n  ", title, "\n", dline)
    sub     = title -> println("\n  ", hline, "\n  ", title, "\n  ", hline)
    note    = msg   -> println("    → ", msg)
    Printer(hline, dline, section, sub, note)
end

end # module ReportHelpers
