# Seismic wall-demand gate. No building and no factor is applied.
# Each refusal is the clause that would otherwise be skipped.

using Test
using StructuralSynthesizer

function _gate(;
        sdc=:B,
        model_uses_cracked_section_stiffness=true,
        sustained_lateral_loads=false,
        sustained_lateral_divisor_applied=false,
        type1_horizontal_irregularity=false,
        type5_horizontal_irregularity=false,
        orthogonal_combination_applied=false,
        orthogonal_12_5_4_conditions_absent=false,
        ax_applied_to_accidental_torsion=false,
        theta=0.05,
        pdelta_included_in_member_forces=false,
        rho_applied_to_eh=false)
    return require_seismic_wall_demand_provisions(;
        sdc, model_uses_cracked_section_stiffness, sustained_lateral_loads,
        sustained_lateral_divisor_applied, type1_horizontal_irregularity,
        type5_horizontal_irregularity, orthogonal_combination_applied,
        orthogonal_12_5_4_conditions_absent, ax_applied_to_accidental_torsion,
        theta, pdelta_included_in_member_forces, rho_applied_to_eh)
end

@testset "seismic wall demand provisions" begin
    @test _gate() === nothing
    @test _gate(; sdc=:C) === nothing
    @test _gate(; sdc=:D, rho_applied_to_eh=true,
                orthogonal_12_5_4_conditions_absent=true) === nothing
    @test _gate(; theta=0.10) === nothing
    @test _gate(; theta=0.2, pdelta_included_in_member_forces=true) === nothing
    @test _gate(; sdc=:C, type1_horizontal_irregularity=true,
                ax_applied_to_accidental_torsion=true) === nothing
    @test _gate(; type1_horizontal_irregularity=true) === nothing

    @test_throws ArgumentError _gate(; model_uses_cracked_section_stiffness=false)
    @test_throws ArgumentError _gate(; sustained_lateral_loads=true)
    @test_throws ArgumentError _gate(; sdc=:D)
    @test_throws ArgumentError _gate(; sdc=:E, rho_applied_to_eh=true)
    @test_throws ArgumentError _gate(; sdc=:C, type5_horizontal_irregularity=true)
    @test_throws ArgumentError _gate(;
        sdc=:D, rho_applied_to_eh=true, type1_horizontal_irregularity=true,
        orthogonal_12_5_4_conditions_absent=true)
    @test_throws ArgumentError _gate(;
        sdc=:F, rho_applied_to_eh=true, type5_horizontal_irregularity=true,
        orthogonal_combination_applied=false)
    @test_throws ArgumentError _gate(;
        sdc=:C, type1_horizontal_irregularity=true)
    @test_throws ArgumentError _gate(; theta=0.11)
    @test_throws ArgumentError _gate(; theta=-0.01)
    @test_throws ArgumentError _gate(; sdc=:A)

    err = try
        _gate(; model_uses_cracked_section_stiffness=false)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    msg = sprint(showerror, err)
    @test occursin("12.7.3", msg)
    @test occursin("0.70", msg)
    @test occursin("0.35", msg)
    @test !occursin("applied 0.35", msg)

    rho = try
        _gate(; sdc=:D)
        nothing
    catch e
        e
    end
    @test occursin("12.4-3", sprint(showerror, rho))
    @test occursin("1.3", sprint(showerror, rho))

    ax = try
        _gate(; sdc=:C, type1_horizontal_irregularity=true)
        nothing
    catch e
        e
    end
    @test occursin("12.8.4.3", sprint(showerror, ax))
    @test occursin("12.8-15", sprint(showerror, ax))

    pd = try
        _gate(; theta=0.2)
        nothing
    catch e
        e
    end
    @test occursin("12.8.7", sprint(showerror, pd))
    @test occursin("1/(1", sprint(showerror, pd))
end
