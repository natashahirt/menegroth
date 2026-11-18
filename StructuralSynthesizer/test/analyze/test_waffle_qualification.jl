# A module grid is a waffle only when it can be concrete joist construction.
# ACI 318-11 §8.13.1–§8.13.4 (corpus: aci-318-11, page 120).

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

const SYM = StructuralSynthesizer
const SR = StructuralSizer

function _module_params(spacing; concrete::Bool, name::String, two_way::Bool = true)
    mats = concrete ? (concrete = SR.NWC_4000,) : (steel = SR.A992_Steel,)
    floor = two_way ? SR.TwoWayOptions() : nothing
    return DesignParameters(
        name = name,
        floor = floor,
        framing_opts = (
            materials = mats,
            module_spacing = spacing,
            analysis = :grillage,
            beam_options = concrete ?
                SR.ConcreteBeamOptions(material = SR.NWC_4000, include_flange = true) :
                SR.SteelBeamOptions(),
        ),
    )
end

@testset "A coarse or non-concrete module is not a waffle" begin
    loose = _module_params((1.25, 1.25); concrete = true, name = "waffle, 1.25 m pans")
    opts, note = @test_logs (:warn, r"§8.13.4") match_mode = :any begin
        SYM._qualify_module_framing(loose.framing_opts, loose)
    end
    @test !haskey(opts, :module_spacing)
    @test opts.analysis === :tributary
    @test opts.spacing ≈ SR.joist_fallback_center_spacing()
    @test loose.floor isa SR.OneWayOptions
    @test loose.name == "one-way concrete joists"
    @test occursin("8.13.4", note)
    @test loose.framing_opts.analysis === :tributary

    dense = _module_params((30.0u"inch", 30.0u"inch"); concrete = true, name = "waffle, 30 in pans")
    opts2, note2 = SYM._qualify_module_framing(dense.framing_opts, dense)
    @test haskey(opts2, :module_spacing)
    @test note2 == ""
    @test dense.floor isa SR.TwoWayOptions
    @test dense.name == "waffle, 30 in pans"

    steel = _module_params((1.25, 1.25); concrete = false, name = "steel joists, 1.25 m",
                           two_way = false)
    opts3, note3 = @test_logs (:warn, r"§8.13.1") match_mode = :any begin
        SYM._qualify_module_framing(steel.framing_opts, steel)
    end
    @test opts3.analysis === :tributary
    @test ustrip(u"m", opts3.spacing) ≈ 1.25
    @test steel.floor === nothing
    @test steel.name == "steel joists, 1.25 m"
    @test occursin("one-way joists", note3)
end
