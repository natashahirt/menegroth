#=
Write viewer/src/theme.json from the StructuralPlots palette.

    julia scripts/runners/export_theme.jl
=#

# Reads the hex literals in StructuralPlots so the viewer cannot drift from the
# figure palette, without loading GLMakie.

const src = read(joinpath(@__DIR__, "..", "..", "StructuralPlots", "src", "colors.jl"), String)

function hx(name::String)
    matched = match(Regex("const $(name)\\s+=\\s+colorant\"(#[0-9A-Fa-f]{6})\""), src)
    matched === nothing && error("theme: $(name) is not a #RRGGBB literal in StructuralPlots/src/colors.jl")
    return uppercase(matched.captures[1])
end

const fields = [
    "font" => "Inter, \\\"Helvetica Neue\\\", sans-serif",
    "background" => hx("sp_offwhite"),
    "grid" => hx("sp_lightgray"),
    "charcoal" => hx("sp_charcoalgrey"),
    "column" => hx("sp_darkgray"),
    "brace" => hx("sp_nearblack"),
    "cerulean" => hx("sp_ceruleanblue"),
    "magenta" => hx("sp_magenta"),
    "gold" => hx("sp_gold"),
    "iris" => hx("sp_irispurple"),
    "ghost" => hx("sp_mediumgray"),
    "panel" => "#FFFFFF",
    "ink" => hx("sp_nearblack"),
    "muted" => hx("sp_darkgray"),
    # Concrete solids in the viewer. Not palette swatches: the wall is the
    # mid gray used for cast-in-place concrete, the slab a lighter warm gray so
    # floors read apart from the core, the pad a step warmer again.
    "concrete" => "#C8C8C8",
    "slab" => "#DCDAD5",
    "footing" => "#A8A49C",
]

out = joinpath(@__DIR__, "..", "..", "viewer", "src", "theme.json")
open(out, "w") do io
    println(io, "{")
    for (i, (key, value)) in enumerate(fields)
        comma = i == length(fields) ? "" : ","
        println(io, "  \"", key, "\": \"", value, "\"", comma)
    end
    println(io, "}")
end
println("wrote ", abspath(out))
