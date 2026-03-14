using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using StructuralSynthesizer
using StructuralSizer
using Asap
using Unitful

function assert_polygon_ok(name::String, poly)
    @assert length(poly) >= 8 "$name polygon too small: $(length(poly)) points"
    xs = [p[1] for p in poly]
    ys = [p[2] for p in poly]
    @assert maximum(xs) - minimum(xs) > 1e-6 "$name polygon collapsed in x"
    @assert maximum(ys) - minimum(ys) > 1e-6 "$name polygon collapsed in y"
end

function main()
    du = StructuralSynthesizer.DisplayUnits(:imperial)
    frc = StructuralSizer.FiberReinforcedConcrete(StructuralSizer.NWC_6000, 20.0, 3.2, 2.5)
    concave_count = 0

    for λ in (:X2, :Y, :X4)
        sec = StructuralSizer.PixelFrameSection(
            λ = λ,
            L_px = 125.0u"mm",
            t = 30.0u"mm",
            L_c = 30.0u"mm",
            material = frc,
            A_s = 157.0u"mm^2",
            f_pe = 500.0u"MPa",
            d_ps = 200.0u"mm",
        )

        poly_local = StructuralSynthesizer._pixelframe_envelope_polygon(sec)
        assert_polygon_ok("PixelFrame $(λ) local", poly_local)

        section_poly = StructuralSynthesizer._serialize_section_polygon(sec, du, 0)
        assert_polygon_ok("PixelFrame $(λ) serialized", section_poly)

        is_convex = Asap.is_convex_polygon(poly_local)
        concave_count += is_convex ? 0 : 1
        println("$(λ): points=$(length(poly_local)), convex=$(is_convex)")
    end

    @assert concave_count >= 1 "Expected at least one non-convex PixelFrame polygon, got all convex."
    println("PixelFrame polygon check passed (concave_count=$(concave_count)).")
end

main()
